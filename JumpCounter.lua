-- JumpCounter: counts your jumps and shares totals with guild/group members
-- who also run the addon, so you can compete on a leaderboard.

local ADDON_NAME = ...
local PREFIX = "JumpCounter"      -- addon message prefix (max 16 chars)
local BROADCAST_INTERVAL = 30     -- seconds between automatic score broadcasts
-- A normal jump on flat ground keeps you in the air for about 0.82 s (jump
-- speed ~7.96 yd/s, gravity ~19.29 yd/s^2). Counted jumps on land must be at
-- least this far apart, so tiny hops (e.g. jumping into a wall and getting
-- "stuck") can't be spammed faster than real jumps. A little under the full
-- air time so continuous bunny-hopping never loses a jump to frame timing.
local JUMP_MIN_INTERVAL = 0.75
local SWIM_JUMP_COOLDOWN = 0.6    -- min seconds between counted jumps in water
local PEER_EXPIRY_DAYS = 60       -- drop players not heard from in this long
local BOARD_ROWS = 15             -- visible rows; the list scrolls

local playerKey                   -- "Name-Realm" of the current character
local charData                    -- JumpCounterDB.chars[playerKey]
local acct                        -- JumpCounterDB.account: progress shared by all your characters
local sessionJumps = 0
local lastJumpTime = 0
local dirty = false               -- total changed since last broadcast
local lastReplyTime = 0

local counterFrame, boardFrame
local ScoreMessage                -- defined in the networking section
local OnPeerScore                 -- defined in the notifications section
local ToggleChallenges            -- defined in the progression section
local CheckChallenges             -- defined in the progression section
local OnDuelMessage               -- defined in the jump duels section
local settings                    -- JumpCounterDB.settings

local DEFAULT_SETTINGS = {
    myMilestones = true,          -- chat message when you hit a milestone
    friendRankUps = true,         -- chat message when a friend earns a jump rank
    friendMilestones = false,     -- ...and also at every friend's 100/500/1,000s
    overtakes = true,             -- chat message when you pass / get passed
    myDeaths = true,              -- short chat line (only to you) when you die
    duels = true,                 -- take part in random jump duels
    duelNews = true,              -- chat line with the result of other players' duels
    myProgress = true,            -- jump level-ups and completed challenges
    sounds = false,               -- off by default; can be enabled in options
    minimapButton = true,         -- JumpCounter button on the minimap edge
}

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = GetMetadata(ADDON_NAME, "Version") or "0"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99JumpCounter|r: " .. msg)
end

-- "1.10.0" > "1.9.2"
local function IsNewerVersion(a, b)
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
    for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

---------------------------------------------------------------------------
-- Update notice: when someone with a newer version is seen, show a popup
-- with the download link (once per session). The newest version seen is
-- saved, so the notice also shows right after logging in.
---------------------------------------------------------------------------
local DOWNLOAD_URL = "https://github.com/Jonjan95/JumpCounter/releases/latest"
local updateShown = false

-- The newer version we know of, or nil if we're up to date.
local function NewestVersion()
    local v = JumpCounterDB and JumpCounterDB.newestVersion
    if v and IsNewerVersion(v, VERSION) then return v end
end

StaticPopupDialogs["JUMPCOUNTER_UPDATE"] = {
    text = "%s\n\nCopy this link (Ctrl+C) and open it in your browser:",
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 330,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if eb then
            eb:SetText(DOWNLOAD_URL)
            eb:SetFocus()
            eb:HighlightText()
        end
    end,
    -- Keep the link intact if someone types in the box.
    EditBoxOnTextChanged = function(self)
        if self:GetText() ~= DOWNLOAD_URL then
            self:SetText(DOWNLOAD_URL)
            self:HighlightText()
        end
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ShowUpdateNotice()
    local v = NewestVersion()
    if not v or updateShown then return end
    updateShown = true
    Print(("|cffff5555v%s is out - you have v%s.|r Get it at %s"):format(v, VERSION, DOWNLOAD_URL))
    StaticPopup_Show("JUMPCOUNTER_UPDATE",
        ("|cffffd100JumpCounter v%s is out!|r\nYou have v%s."):format(v, VERSION))
end

-- Called with the version of every score we receive.
local function NoteVersion(version)
    if not version or not version:match("^%d+%.%d+%.%d+$") then return end
    if IsNewerVersion(version, JumpCounterDB.newestVersion or VERSION) then
        JumpCounterDB.newestVersion = version
    end
    ShowUpdateNotice()
end

-- Turn a chat sender into a player key ("Name-Realm") plus a display name.
-- This server gives characters a first and second name ("Zivv Gg-Realm"),
-- but UnitName("player") only returns the first, so keys use the first name
-- and the full name is kept separately for display.
-- The realm name is sometimes not loaded yet right after login, so fall back
-- to the display realm name with spaces and dashes removed.
local function MyRealm()
    local realm = GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return realm
end

local function NormalizeSender(sender)
    sender = sender:gsub("%-$", "")            -- "Name-" from a realm-less key
    local namePart, realm = sender:match("^([^-]+)-(.+)$")
    if not namePart then namePart = sender end
    local name = namePart:match("^(%S+)") or namePart
    return name .. "-" .. (realm or MyRealm()), namePart
end

---------------------------------------------------------------------------
-- Weeks (follow the game's weekly reset so everyone agrees on the week)
---------------------------------------------------------------------------
local cachedWeekId

local function SecondsUntilReset()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        return C_DateAndTime.GetSecondsUntilWeeklyReset()
    end
end

-- The week's id is the hour (since 1970) of its upcoming weekly reset.
-- Rounding to the hour means every client computes the same number.
local function CurrentWeekId()
    local now = GetServerTime()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local secs = SecondsUntilReset()
        if secs and secs > 0 then
            cachedWeekId = math.floor((now + secs) / 3600 + 0.5)
        end
        return cachedWeekId
    end
    -- No reset API: weeks start Monday 00:00 UTC. Expressed the same way.
    local WEEK = 604800
    local nextMonday = (math.floor((now - 345600) / WEEK) + 1) * WEEK + 345600
    return math.floor(nextMonday / 3600)
end

local function FormatDuration(secs)
    local days = math.floor(secs / 86400)
    local hours = math.floor((secs % 86400) / 3600)
    if days > 0 then return ("%dd %dh"):format(days, hours) end
    return ("%dh %dm"):format(hours, math.floor((secs % 3600) / 60))
end

---------------------------------------------------------------------------
-- Jump ranks (by all-time total)
---------------------------------------------------------------------------
local JUMP_RANKS = {
    { 100,     "Hopper" },
    { 250,     "Skipper" },
    { 500,     "Bunny Hopper" },
    { 750,     "Spring Step" },
    { 1000,    "Leapfrog" },
    { 1750,    "Cricket" },
    { 2500,    "Kangaroo" },
    { 3250,    "Wallaby" },
    { 4000,    "Jackrabbit" },
    { 5000,    "Pogo Master" },
    { 6250,    "Springheel" },
    { 7500,    "Trampoline Artist" },
    { 10000,   "Moon Boots" },
    { 12500,   "Bounce Baron" },
    { 15000,   "Cloud Hopper" },
    { 20000,   "Featherfoot" },
    { 25000,   "Gravity Defier" },
    { 30000,   "Jet Hopper" },
    { 35000,   "Rocket Legs" },
    { 42500,   "Skybound" },
    { 50000,   "Low Orbit" },
    { 62500,   "Meteor" },
    { 75000,   "Stratosphere" },
    { 87500,   "Comet Rider" },
    { 100000,  "Legend of the Leap" },
    { 125000,  "Starhopper" },
    { 150000,  "Jumpmaster" },
    { 200000,  "Gravity's Bane" },
    { 250000,  "Sky Sovereign" },
    { 350000,  "Eclipse Leaper" },
    { 500000,  "Ascended" },
    { 750000,  "Celestial" },
    { 1000000, "The Unfallen" },
    { 1500000, "Myth of the Leap" },
    { 2500000, "Eternal Bounce" },
    { 5000000, "Defier of Worlds" },
}

-- Returns the rank title for a total, and the threshold it was earned at.
local function GetJumpRank(total)
    local title, threshold
    for _, r in ipairs(JUMP_RANKS) do
        if total >= r[1] then threshold, title = r[1], r[2] else break end
    end
    return title, threshold
end

---------------------------------------------------------------------------
-- Jump levels: XP = 1 per jump + challenge rewards.
-- Going from level L to L+1 costs 50 + 25*(L-1) XP, so roughly
-- level 8 at 1,000 XP, 27 at 10,000 and 88 at 100,000.
---------------------------------------------------------------------------
local function XPForLevel(level)
    return 50 + 25 * (level - 1)
end

-- Returns level, XP into the current level, XP needed for the next level.
local function LevelFromXP(xp)
    local level = 1
    xp = xp or 0
    while xp >= XPForLevel(level) do
        xp = xp - XPForLevel(level)
        level = level + 1
    end
    return level, xp, XPForLevel(level)
end

-- Total XP for a saved entry (ours or a peer's). Peers on versions before
-- 0.8.0 don't send XP, so for them it's just their jumps.
local function EntryXP(data)
    if data.xp then return data.xp end
    return (data.total or 0) + (data.challengeXP or 0)
end

---------------------------------------------------------------------------
-- Prestige: at PRESTIGE_LEVEL you can reset your jump level to 1 and gain a
-- prestige star. Each prestige uses up exactly PRESTIGE_XP (the XP it takes
-- to reach PRESTIGE_LEVEL); extra XP carries over. Total jumps, ranks, total
-- XP and challenges are kept.
---------------------------------------------------------------------------
local PRESTIGE_LEVEL = 30
local PRESTIGE_XP = 0
for l = 1, PRESTIGE_LEVEL - 1 do PRESTIGE_XP = PRESTIGE_XP + XPForLevel(l) end   -- 11,600

local function EntryPrestige(data)
    return data.prestige or 0
end

-- Current jump level (after prestige resets): level, XP into it, XP needed.
local function EntryLevel(data)
    return LevelFromXP(math.max(0, EntryXP(data) - EntryPrestige(data) * PRESTIGE_XP))
end

-- Gold star (the star raid marker) + number, or "" without prestige.
local function PrestigeTag(n)
    if not n or n <= 0 then return "" end
    return ("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t|cffffd100%d|r "):format(n)
end

---------------------------------------------------------------------------
-- Challenges. Each has a goal and a function returning current progress
-- (from acct.stats). Completing one gives bonus XP once per account.
---------------------------------------------------------------------------
-- Capital city map IDs (C_Map uiMapIDs in Classic).
local CAPITALS = {
    Alliance = { [1453] = "Stormwind", [1455] = "Ironforge", [1457] = "Darnassus" },
    Horde    = { [1454] = "Orgrimmar", [1458] = "Undercity", [1456] = "Thunder Bluff" },
}

local function Stat(name) return (acct.stats and acct.stats[name]) or 0 end

local function CountKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Capitals of one faction visited (alts on both factions don't mix).
local function CapitalCount()
    local best = 0
    for _, cities in pairs(CAPITALS) do
        local n = 0
        for id in pairs(cities) do
            if acct.stats.capitals[id] then n = n + 1 end
        end
        best = math.max(best, n)
    end
    return best
end

-- Different classes among your characters with at least 100 jumps.
local function ClassCount()
    local seen = {}
    for _, c in pairs(JumpCounterDB.chars) do
        if c.class and (c.total or 0) >= 100 then seen[c.class] = true end
    end
    return CountKeys(seen)
end

local CHALLENGES = {
    { id = "mount1",  name = "Saddle Hopper",     xp = 250,  goal = 100,
      desc = "Jump 100 times while mounted.",                 progress = function() return Stat("mounted") end },
    { id = "mount2",   name = "Cavalry Bounce",    xp = 750,  goal = 1000,
      desc = "Jump 1,000 times while mounted.",               progress = function() return Stat("mounted") end },
    { id = "swim",     name = "Splash Jumper",     xp = 250,  goal = 100,
      desc = "Jump 100 times at the surface of water.",       progress = function() return Stat("swim") end },
    { id = "ghost",    name = "Ghost Hop",         xp = 250,  goal = 25,
      desc = "Jump 25 times as a ghost.",                     progress = function() return Stat("ghost") end },
    { id = "combat",   name = "Battle Bunny",      xp = 500,  goal = 250,
      desc = "Jump 250 times in combat.",                     progress = function() return Stat("combat") end },
    { id = "dungeon",  name = "Dungeon Bouncer",   xp = 500,  goal = 500,
      desc = "Jump 500 times inside dungeons or raids.",      progress = function() return Stat("instance") end },
    { id = "party",    name = "Party Hopper",      xp = 300,  goal = 100,
      desc = "Jump 100 times in a full group of 5 or more.",  progress = function() return Stat("group") end },
    { id = "zones1",   name = "Wanderer",          xp = 300,  goal = 10,
      desc = "Jump in 10 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "zones2",   name = "Globetrotter",      xp = 1000, goal = 30,
      desc = "Jump in 30 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "capitals", name = "Capital Tourist",   xp = 500,  goal = 3,
      desc = "Jump in all three capital cities of your faction.",
      progress = CapitalCount },
    { id = "enemycap", name = "Diplomatic Incident", xp = 1000, goal = 1,
      desc = "Jump in an enemy faction's capital city.",      progress = function() return Stat("enemyCapital") end },
    { id = "session1", name = "Marathon",          xp = 300,  goal = 500,
      desc = "Jump 500 times in one session.",                progress = function() return Stat("bestSession") end },
    { id = "session2", name = "Ultramarathon",     xp = 1000, goal = 2500,
      desc = "Jump 2,500 times in one session.",              progress = function() return Stat("bestSession") end },
    { id = "sprint",   name = "Bunny Sprint",      xp = 300,  goal = 50,
      desc = "Jump 50 times within 60 seconds.",              progress = function() return Stat("bestMinute") end },
    { id = "nodeath1", name = "Untouchable",       xp = 500,  goal = 1000,
      desc = "Jump 1,000 times without dying.",               progress = function() return Stat("bestSinceDeath") end },
    { id = "nodeath2", name = "Immortal Hopper",   xp = 2000, goal = 10000,
      desc = "Jump 10,000 times without dying.",              progress = function() return Stat("bestSinceDeath") end },
    { id = "days1",    name = "Daily Hopper",      xp = 500,  goal = 7,
      desc = "Jump on 7 different days.",                     progress = function() return CountKeys(acct.stats.days) end },
    { id = "days2",    name = "Devoted Hopper",    xp = 1500, goal = 30,
      desc = "Jump on 30 different days.",                    progress = function() return CountKeys(acct.stats.days) end },

    -- 1.3.0: harder tiers of the challenges above...
    { id = "mount3",   name = "Kangaroo Cavalry",  xp = 2000, goal = 10000,
      desc = "Jump 10,000 times while mounted.",              progress = function() return Stat("mounted") end },
    { id = "swim2",    name = "Dolphin Leap",      xp = 750,  goal = 1000,
      desc = "Jump 1,000 times at the surface of water.",     progress = function() return Stat("swim") end },
    { id = "swim3",    name = "Flying Fish",       xp = 2000, goal = 5000,
      desc = "Jump 5,000 times at the surface of water.",     progress = function() return Stat("swim") end },
    { id = "ghost2",   name = "Restless Spirit",   xp = 750,  goal = 250,
      desc = "Jump 250 times as a ghost.",                    progress = function() return Stat("ghost") end },
    { id = "combat2",  name = "Dodge Master",      xp = 1000, goal = 2500,
      desc = "Jump 2,500 times in combat.",                   progress = function() return Stat("combat") end },
    { id = "combat3",  name = "War Kangaroo",      xp = 2500, goal = 10000,
      desc = "Jump 10,000 times in combat.",                  progress = function() return Stat("combat") end },
    { id = "dungeon2", name = "Raid Rabbit",       xp = 1500, goal = 5000,
      desc = "Jump 5,000 times inside dungeons or raids.",    progress = function() return Stat("instance") end },
    { id = "party2",   name = "Conga Line",        xp = 750,  goal = 1000,
      desc = "Jump 1,000 times in a full group of 5 or more.", progress = function() return Stat("group") end },
    { id = "zones3",   name = "World Hopper",      xp = 2000, goal = 50,
      desc = "Jump in 50 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "session3", name = "Iron Legs",         xp = 3000, goal = 10000,
      desc = "Jump 10,000 times in one session.",             progress = function() return Stat("bestSession") end },
    { id = "sprint2",  name = "Turbo Bunny",       xp = 750,  goal = 65,
      desc = "Jump 65 times within 60 seconds.",              progress = function() return Stat("bestMinute") end },
    { id = "nodeath3", name = "Deathless Legend",  xp = 4000, goal = 25000,
      desc = "Jump 25,000 times without dying.",              progress = function() return Stat("bestSinceDeath") end },
    { id = "days3",    name = "Hopping Habit",     xp = 4000, goal = 100,
      desc = "Jump on 100 different days.",                   progress = function() return CountKeys(acct.stats.days) end },
    { id = "week1",    name = "Weekly Warrior",    xp = 1500, goal = 10000,
      desc = "Jump 10,000 times in one week.",                progress = function() return Stat("bestWeek") end },
    { id = "week2",    name = "Weekly Legend",     xp = 3000, goal = 25000,
      desc = "Jump 25,000 times in one week.",                progress = function() return Stat("bestWeek") end },

    -- ...and new kinds.
    { id = "streak1",  name = "On a Roll",         xp = 750,  goal = 7,
      desc = "Jump every day for 7 days in a row.",           progress = function() return Stat("bestStreak") end },
    { id = "streak2",  name = "Unbreakable Habit", xp = 3000, goal = 30,
      desc = "Jump every day for 30 days in a row.",          progress = function() return Stat("bestStreak") end },
    { id = "resting",  name = "Inn Hopper",        xp = 300,  goal = 1000,
      desc = "Jump 1,000 times while resting in an inn or city.", progress = function() return Stat("resting") end },
    { id = "stealth",  name = "Sneaky Hop",        xp = 400,  goal = 100,
      desc = "Jump 100 times while stealthed.",               progress = function() return Stat("stealth") end },
    { id = "shape",    name = "Shapeshifter Spring", xp = 400, goal = 500,
      desc = "Jump 500 times in a druid form or Ghost Wolf.", progress = function() return Stat("shapeshift") end },
    { id = "pvp",      name = "Battleground Bounce", xp = 750, goal = 250,
      desc = "Jump 250 times in a battleground.",             progress = function() return Stat("pvp") end },
    { id = "night",    name = "Night Owl",         xp = 500,  goal = 500,
      desc = "Jump 500 times between midnight and 4 AM.",     progress = function() return Stat("night") end },
    -- (Was "below 20% health in combat" - health is a hidden "secret" value
    -- in combat on Forever, so addons can't read it. Same id, so anyone who
    -- already completed it keeps it.)
    { id = "lowhp",    name = "Living Dangerously", xp = 750, goal = 500,
      desc = "Jump 500 times while flagged for PvP.",         progress = function() return Stat("pvpFlagged") end },
    { id = "maxlevel", name = "Seasoned Hopper",   xp = 1500, goal = 5000,
      desc = "Jump 5,000 times at max character level.",      progress = function() return Stat("maxLevel") end },
    { id = "classes1", name = "Jack of All Hops",  xp = 1000, goal = 3,
      desc = "Jump 100 times on characters of 3 different classes.", progress = function() return ClassCount() end },
    { id = "classes2", name = "Master of Many",    xp = 2500, goal = 5,
      desc = "Jump 100 times on characters of 5 different classes.", progress = function() return ClassCount() end },
    { id = "prestige1", name = "Born Again",       xp = 500,  goal = 1,
      desc = "Prestige once.",                                progress = function() return acct.prestige end },
    { id = "prestige2", name = "Star Collector",   xp = 1500, goal = 3,
      desc = "Reach Prestige 3.",                             progress = function() return acct.prestige end },
    { id = "prestige3", name = "Constellation",    xp = 3000, goal = 5,
      desc = "Reach Prestige 5.",                             progress = function() return acct.prestige end },

    -- 1.5.0: jump duels.
    { id = "duel1",    name = "Duelist",           xp = 300,  goal = 1,
      desc = "Win a jump duel.",                              progress = function() return acct.duelWins or 0 end },
    { id = "duel2",    name = "Duel Champion",     xp = 1500, goal = 10,
      desc = "Win 10 jump duels.",                            progress = function() return acct.duelWins or 0 end },
    { id = "duel3",    name = "Undisputed",        xp = 4000, goal = 50,
      desc = "Win 50 jump duels.",                            progress = function() return acct.duelWins or 0 end },
}

local function CountCompleted(data)
    return CountKeys(data and data.done)
end

---------------------------------------------------------------------------
-- Jumps per hour: only shown once RATE_MIN_SECONDS of online time is tracked.
---------------------------------------------------------------------------
local RATE_MIN_SECONDS = 1800

-- Our own characters keep the raw numbers; peers send the finished rate.
local function JumpsPerHour(data)
    if data.rate then
        if (data.rate.seconds or 0) < RATE_MIN_SECONDS then return nil end
        return data.rate.jumps / data.rate.seconds * 3600
    end
    return data.jph
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
local function InitDB()
    JumpCounterDB = JumpCounterDB or {}
    local db = JumpCounterDB
    db.chars = db.chars or {}     -- your own characters
    db.peers = db.peers or {}     -- scores received from other players
    db.ui = db.ui or { shown = false, locked = false }   -- counter hidden for new installs
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    settings = db.settings
    -- 0.4.0: sounds became opt-in, so switch them off once for existing installs.
    if (db.settingsVersion or 0) < 2 then
        settings.sounds = false
        db.settingsVersion = 2
    end
    -- 0.6.0: friends' every-1,000 milestones get spammy in a big guild; only
    -- rank-ups are on by default now.
    if db.settingsVersion < 3 then
        settings.friendMilestones = false
        db.settingsVersion = 3
    end

    -- Forget players we haven't heard from in PEER_EXPIRY_DAYS (left the guild, quit...).
    local cutoff = time() - PEER_EXPIRY_DAYS * 86400
    for key, data in pairs(db.peers) do
        if (data.seen or 0) < cutoff then db.peers[key] = nil end
    end

    local name = UnitName("player")
    playerKey = name .. "-" .. MyRealm()

    -- Older versions could save this character as "Name-" (realm not loaded
    -- yet at login). Fold that copy into the proper entry.
    local broken = db.chars[name .. "-"]
    if broken and playerKey ~= name .. "-" then
        local proper = db.chars[playerKey] or { total = 0 }
        proper.total = (proper.total or 0) + (broken.total or 0)
        proper.display = proper.display or broken.display
        db.chars[playerKey] = proper
        db.chars[name .. "-"] = nil
    end

    -- Clean up entries saved by older versions under odd names ("Zivv Gg-Realm").
    local cleaned = {}
    for key, data in pairs(db.peers) do
        local fixed = NormalizeSender(key)
        if not db.chars[fixed] and fixed ~= playerKey then
            local existing = cleaned[fixed]
            if not existing or (data.seen or 0) > (existing.seen or 0) then
                cleaned[fixed] = data
            end
        end
    end
    db.peers = cleaned

    -- Your characters are saved by GUID (1.2.1). Before that they were saved
    -- by first name, so "Zivv Gg" and "Zivv Pewpew" shared one entry. That
    -- old entry goes to the character of the class it was last played as;
    -- any other character with the same first name starts its own.
    local class = select(2, UnitClass("player"))
    local charKey = UnitGUID("player") or playerKey
    if not db.chars[charKey] then
        local old = db.chars[playerKey]
        if charKey ~= playerKey and old and (not old.class or old.class == class) then
            db.chars[charKey] = old
            db.chars[playerKey] = nil
        else
            db.chars[charKey] = { total = 0 }
        end
    end
    charData = db.chars[charKey]
    charData.class = class
    charData.name = name

    -- If this client tracks statistics, start the death counter from the
    -- game's own "Total deaths" (statistic 60). Otherwise it starts at 0.
    if charData.deaths == nil then
        local ok, value = pcall(function() return GetStatistic and GetStatistic(60) end)
        charData.deaths = (ok and tonumber(value)) or 0
    end

    -- Jumps per hour (0.9.0): jumps and online (non-AFK) seconds, both
    -- counted from this version on so the rate is fair.
    charData.rate = charData.rate or { jumps = 0, seconds = 0 }

    -- 1.1.0: jump level, prestige, challenges and challenge stats are shared
    -- by every character on the account. The first time, combine what each
    -- character earned on its own (the old per-character data is left as is).
    if not db.account then
        local a = { prestige = 0, challengeXP = 0, done = {}, stats = {} }
        -- Counters add up; "best" values and the rest keep the highest.
        local SUMMED = { mounted = true, swim = true, ghost = true, combat = true,
            instance = true, group = true }
        for _, c in pairs(db.chars) do
            a.prestige = a.prestige + (c.prestige or 0)
            a.challengeXP = a.challengeXP + (c.challengeXP or 0)
            for id, when in pairs(c.done or {}) do
                if not a.done[id] or when < a.done[id] then a.done[id] = when end
            end
            for stat, v in pairs(c.stats or {}) do
                if type(v) == "table" then
                    a.stats[stat] = a.stats[stat] or {}
                    for k in pairs(v) do a.stats[stat][k] = true end
                elseif type(v) == "number" then
                    if SUMMED[stat] then
                        a.stats[stat] = (a.stats[stat] or 0) + v
                    else
                        a.stats[stat] = math.max(a.stats[stat] or 0, v)
                    end
                end
            end
        end
        db.account = a
    end
    acct = db.account
    if not acct.id then
        -- Random id so others can tell your characters belong together
        -- (nothing about your Battle.net account is shared).
        local hex = {}
        for i = 1, 12 do hex[i] = ("%x"):format(math.random(0, 15)) end
        acct.id = table.concat(hex)
    end
    acct.prestige = acct.prestige or 0
    acct.challengeXP = acct.challengeXP or 0
    acct.done = acct.done or {}
    acct.stats = acct.stats or {}
    local st = acct.stats
    st.zones = st.zones or {}
    st.capitals = st.capitals or {}
    st.days = st.days or {}
end

-- "A" / "H" for the character you're playing.
local function MyFaction()
    local f = UnitFactionGroup("player")
    return (f == "Alliance" and "A") or (f == "Horde" and "H") or nil
end

local FACTION_NAMES = { A = "Alliance", H = "Horde" }
local FACTION_ICONS = {
    A = "|TInterface\\Icons\\INV_BannerPVP_02:14:14:0:0:64:64:5:59:5:59|t ",
    H = "|TInterface\\Icons\\INV_BannerPVP_01:14:14:0:0:64:64:5:59:5:59|t ",
}
local function FactionIcon(f) return FACTION_ICONS[f or ""] or "" end

-- Your account as one leaderboard entry: every character's jumps, deaths,
-- week and online time added up, plus the shared level and challenges.
-- Shown under the character you are playing.
local function Me()
    local wid = CurrentWeekId()
    local me = { total = 0, week = 0, weekId = wid, deaths = 0, rate = { jumps = 0, seconds = 0 },
        challengeXP = acct.challengeXP + (acct.duelXP or 0), prestige = acct.prestige, done = acct.done,
        duelWins = acct.duelWins or 0, faction = MyFaction(),
        class = charData.class, display = charData.display }
    for _, c in pairs(JumpCounterDB.chars) do
        me.total = me.total + (c.total or 0)
        if wid and c.weekId == wid then me.week = me.week + (c.week or 0) end
        me.deaths = me.deaths + (c.deaths or 0)
        if c.rate then
            me.rate.jumps = me.rate.jumps + (c.rate.jumps or 0)
            me.rate.seconds = me.rate.seconds + (c.rate.seconds or 0)
        end
    end
    return me
end

-- Your characters, most jumps first: { { key, name, total, class }, ... }
local function MyCharacters()
    local list = {}
    for key, c in pairs(JumpCounterDB.chars) do
        table.insert(list, { key = key, name = c.display or c.name or key:match("^[^-]+") or key,
            total = c.total or 0, class = c.class })
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

---------------------------------------------------------------------------
-- Networking (guild / party / raid addon messages)
---------------------------------------------------------------------------
local function GetChannels()
    local channels = {}
    if IsInGuild() then table.insert(channels, "GUILD") end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        table.insert(channels, "INSTANCE_CHAT")
    elseif IsInRaid() then
        table.insert(channels, "RAID")
    elseif IsInGroup() then
        table.insert(channels, "PARTY")
    end
    return channels
end

-- Friends who have shown they run JumpCounter this session. Regular score
-- updates only go to these; everyone else is contacted once at login
-- ("discovery") so we don't keep messaging people without the addon.
local knownWhisper = {}   -- [character name] = true
local knownBNet = {}      -- [gameAccountID] = true

-- Online characters on your WoW friends list who aren't reached via guild/group.
local function GetOnlineFriends()
    local names = {}
    if not (C_FriendList and C_FriendList.GetNumFriends) then return names end
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then
            local short = info.name:match("^[^-]+")
            local inGuildOrGroup = UnitInParty(short) or UnitInRaid(short)
            if not inGuildOrGroup and IsInGuild() and C_GuildInfo and C_GuildInfo.MemberExistsByName then
                inGuildOrGroup = C_GuildInfo.MemberExistsByName(info.name)
            end
            if not inGuildOrGroup then table.insert(names, info.name) end
        end
    end
    return names
end

-- Online Battle.net friends playing this same WoW game. Battle.net game data
-- reaches them even on the other faction, unlike normal addon messages.
local function GetBNetGameAccounts()
    local ids = {}
    if not (BNSendGameData and BNGetNumFriends and C_BattleNet
            and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo) then
        return ids
    end
    for i = 1, (BNGetNumFriends()) do
        for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if g and g.isOnline and g.gameAccountID
                and g.clientProgram == (BNET_CLIENT_WOW or "WoW")
                and (not g.wowProjectID or not WOW_PROJECT_ID or g.wowProjectID == WOW_PROJECT_ID) then
                table.insert(ids, g.gameAccountID)
            end
        end
    end
    return ids
end

-- Outgoing messages go through a queue so a burst (guild + many friends)
-- never exceeds the game's addon message limits. One message per tick.
local SEND_INTERVAL = 0.2
local sendQueue = {}
local queuedKeys = {}     -- avoid queueing the same message to the same target twice
local sendTicker

local function ProcessQueue()
    local item = table.remove(sendQueue, 1)
    if item then
        queuedKeys[item.id] = nil
        if item.bnet then
            pcall(BNSendGameData, item.target, PREFIX, item.msg)
        else
            C_ChatInfo.SendAddonMessage(PREFIX, item.msg, item.channel, item.target)
        end
    end
    if #sendQueue == 0 and sendTicker then
        sendTicker:Cancel()
        sendTicker = nil
    end
end

local function Enqueue(msg, channel, target, bnet)
    -- Relayed scores ("R:<acct>:...") are one message per account.
    local kind = msg:match("^(R:[^:]+)") or msg:match("^[^:]+") or msg
    local id = (bnet and "bn" or channel) .. ":" .. tostring(target) .. ":" .. kind
    if queuedKeys[id] then
        -- Already waiting to go out: just send the newest content.
        for _, item in ipairs(sendQueue) do
            if item.id == id then item.msg = msg end
        end
        return
    end
    queuedKeys[id] = true
    table.insert(sendQueue, { id = id, msg = msg, channel = channel, target = target, bnet = bnet })
    if not sendTicker then sendTicker = C_Timer.NewTicker(SEND_INTERVAL, ProcessQueue) end
end

local function SendBNet(gameAccountID, msg)
    Enqueue(msg, nil, gameAccountID, true)
end

local function SendWhisper(name, msg)
    Enqueue(msg, "WHISPER", name)
end

-- discover = true also contacts friends who haven't shown they use the addon.
-- skipGuild = true leaves out the guild channel.
local function Send(msg, discover, skipGuild)
    for _, channel in ipairs(GetChannels()) do
        if not (skipGuild and channel == "GUILD") then Enqueue(msg, channel) end
    end
    for _, name in ipairs(GetOnlineFriends()) do
        if discover or knownWhisper[name] or knownWhisper[name:match("^[^-]+")] then
            SendWhisper(name, msg)
        end
    end
    for _, id in ipairs(GetBNetGameAccounts()) do
        if discover or knownBNet[id] then SendBNet(id, msg) end
    end
end

-- This week's jumps for an entry (0 if its count is from an old week).
-- Without an entry: your whole account.
local function MyWeekCount(data)
    data = data or Me()
    local wid = CurrentWeekId()
    if wid and data.weekId == wid then return data.week or 0 end
    return 0
end

local MAX_MESSAGE = 250   -- addon messages are limited to 255 bytes

-- T:<total>:<class>:<version>:<playerKey>:<display name>:<weekId>:<week count>:<GUID>
--  :<deaths>:<character level>:<XP>:<challenges completed>:<jumps per hour or empty>:<prestige>
--  :<account id>:<characters as "Name=jumps,Name=jumps">
-- Since 1.1.0 the numbers are for the whole account. The key, display name
-- and GUID let receivers identify us the same way no matter which channel
-- (guild, whisper, Battle.net) the message came through; the account id
-- lets them replace the row of whichever of our characters they saw before.
function ScoreMessage()
    local me = Me()
    local jph = JumpsPerHour(me)
    local msg = table.concat({ "T", me.total, charData.class or "", VERSION,
        playerKey, charData.display or "", CurrentWeekId() or "", MyWeekCount(me),
        UnitGUID("player") or "", me.deaths,
        UnitLevel("player") or 0, EntryXP(me), CountCompleted(me),
        jph and math.floor(jph + 0.5) or "", EntryPrestige(me), acct.id }, ":")
    -- 1.5.0: duels won, after the character list (older versions ignore it).
    -- 1.6.0: faction ("A" / "H") after that.
    local suffix = ":" .. (acct.duelWins or 0) .. ":" .. (MyFaction() or "")
    -- Character list for the hover tooltip, as many as fit.
    local chars = {}
    local length = #msg + 1 + #suffix
    for _, c in ipairs(MyCharacters()) do
        local part = (c.name:gsub("[:,=]", "")) .. "=" .. c.total
        if length + #part + 1 > MAX_MESSAGE then break end
        table.insert(chars, part)
        length = length + #part + 1
    end
    return msg .. ":" .. table.concat(chars, ",") .. suffix
end

-- "Zivv Gg=3200,Alt=450" -> { { name = "Zivv Gg", total = 3200 }, ... }
local function ParseCharacters(text)
    local list = {}
    for part in (text or ""):gmatch("[^,]+") do
        local name, total = part:match("^(.-)=(%d+)$")
        if name and name ~= "" then table.insert(list, { name = name, total = tonumber(total) }) end
    end
    return list
end

local function FirstWord(name)
    return (name:match("^(%S+)") or name):lower()
end

-- Remove leftover rows that newer data has replaced. Old versions saved
-- players under their first name only ("Lo" next to "Lo Oz"), or under a
-- different realm spelling, so the same player could show up twice:
--  * a row from before 1.1.0 for a name that is now part of a 1.1.0+
--    account (or one of your own characters) is dropped;
--  * a first-name-only row is dropped when a newer row has the full name;
--  * of two rows with the same full name, the older one is dropped.
local function PruneStalePeers()
    local peers = JumpCounterDB.peers
    local covered = {}    -- full names / "first:" first names of known accounts
    local function cover(name)
        if not name or name == "" then return end
        covered[name:lower()] = true
        covered["first:" .. FirstWord(name)] = true
    end
    for _, c in pairs(JumpCounterDB.chars) do cover(c.display or c.name) end
    cover(UnitName("player"))

    local fullSeen = {}   -- first name -> newest update of a row with a full name
    for _, data in pairs(peers) do
        if data.acct then
            cover(data.display)
            for _, c in ipairs(ParseCharacters(data.characters)) do cover(c.name) end
        end
        if data.display and data.display:find("%s") then
            local f = FirstWord(data.display)
            fullSeen[f] = math.max(fullSeen[f] or 0, data.seen or 0)
            local full = data.display:lower()
            fullSeen[full] = math.max(fullSeen[full] or 0, data.seen or 0)
        end
    end

    for key, data in pairs(peers) do
        if not data.acct then
            local name = data.display or key:match("^[^-]+") or key
            local stale
            if name:find("%s") then
                -- Same full name: keep only the most recently updated row.
                local full = name:lower()
                stale = covered[full] or (fullSeen[full] or 0) > (data.seen or 0)
            else
                local f = FirstWord(name)
                stale = covered["first:" .. f] or (fullSeen[f] and fullSeen[f] >= (data.seen or 0))
            end
            if stale then peers[key] = nil end
        end
    end
end

local function BroadcastScore(discover)
    Send(ScoreMessage(), discover)
    dirty = false
end

-- Ask others for their scores. Every guild member with the addon answers a
-- guild request, so those are limited to once per REQUEST_COOLDOWN.
local REQUEST_COOLDOWN = 300
local lastRequestTime = -REQUEST_COOLDOWN

-- Login: ask friends and group directly (cheap), not the whole guild.
local function RequestScoresAtLogin()
    Send("REQ", true, true)
end

-- Board opened (or /jumps clear with force = true): include the guild.
local function RequestScores(force)
    if not force and GetTime() - lastRequestTime < REQUEST_COOLDOWN then return end
    lastRequestTime = GetTime()
    Send("REQ", force)
end

-- Refresh the board at most a few times a second, however many scores arrive.
local boardRefreshPending = false
local function RefreshBoardSoon()
    if boardRefreshPending or not (boardFrame and boardFrame:IsShown()) then return end
    boardRefreshPending = true
    C_Timer.After(0.3, function()
        boardRefreshPending = false
        if boardFrame:IsShown() then boardFrame:Refresh() end
    end)
end

---------------------------------------------------------------------------
-- Passing scores along (1.6.0). Players also share the scores they know, so
-- friends of friends show up too - including the other faction through a
-- Battle.net friend. Scores are passed on at most twice (hops), only if
-- updated in the last RELAY_MAX_AGE, and in small batches:
--  * to a friend (whisper / Battle.net) whenever we hear from them (at most
--    once a minute, and every 10 minutes anyway): only scores they haven't
--    had from us yet, or that changed since we last sent them (RELAY_RESEND);
--  * to the guild, only scores that didn't come from the guild, at most
--    every RELAY_GUILD_INTERVAL, skipping what someone else already sent.
-- R:<acct>:<key>:<name>:<class>:<faction>:<total>:<weekId>:<week>:<deaths>
--  :<char level>:<xp>:<challenges>:<jph>:<prestige>:<duel wins>:<version>:<seen>:<hops>
---------------------------------------------------------------------------
-- Lua 5.1 allows at most 200 locals per file, so helpers live in do-blocks
-- and only what other code needs is declared outside.
local RELAY_GUILD_INTERVAL = 600
local RelayToContact, RelayToGuild, ApplyRelay, RelayTick
do
    local RELAY_MAX_AGE = 3 * 86400
    local RELAY_MAX_HOPS = 2
    local RELAY_BATCH = 40
    local RELAY_CONTACT_GAP = 60      -- at most one batch a minute per friend
    local RELAY_RESEND = 600          -- resend a score to a friend at most every 10 min
    local contacts = {}               -- [contact key] = { last, reply, acct, sent = { [acct] = seen } }
    local guildRelayed = {}           -- [acct] = newest "seen" already passed around the guild
    local lastGuildRelay = -RELAY_GUILD_INTERVAL

    local function NoColon(v) return (tostring(v or ""):gsub(":", "")) end

    local function RelayMessage(key, data)
        local function n(v) return v ~= nil and tostring(v) or "" end
        return table.concat({ "R", data.acct, NoColon(key), NoColon(data.display), n(data.class),
            n(data.faction), n(data.total), n(data.weekId), n(data.week), n(data.deaths),
            n(data.charLevel), n(data.xp), n(data.challenges), n(data.jph), n(data.prestige),
            n(data.duelWins), n(data.version), n(data.seen), (data.hops or 0) + 1 }, ":")
    end

    -- Up to RELAY_BATCH passable scores (newest first) that pass filter(data).
    local function RelayBatch(filter)
        local list = {}
        local now = time()
        for key, data in pairs(JumpCounterDB.peers) do
            if data.acct and (data.hops or 0) < RELAY_MAX_HOPS and now - (data.seen or 0) <= RELAY_MAX_AGE
                and filter(data) then
                table.insert(list, { key = key, data = data })
            end
        end
        table.sort(list, function(a, b) return (a.data.seen or 0) > (b.data.seen or 0) end)
        for i = #list, RELAY_BATCH + 1, -1 do list[i] = nil end
        return list
    end

    -- A friend we heard from directly: tell them who we know that they
    -- haven't heard about from us yet (or not for a while).
    function RelayToContact(contactKey, reply, contactAcct)
        local c = contacts[contactKey]
        if not c then
            c = { last = -RELAY_CONTACT_GAP, sent = {} }
            contacts[contactKey] = c
        end
        c.reply, c.acct = reply, contactAcct
        if GetTime() - c.last < RELAY_CONTACT_GAP then return end
        c.last = GetTime()
        local batch = RelayBatch(function(d)
            if d.acct == contactAcct then return false end
            local sentSeen = c.sent[d.acct]
            return not sentSeen or (d.seen or 0) - sentSeen >= RELAY_RESEND
        end)
        for _, e in ipairs(batch) do
            c.sent[e.data.acct] = e.data.seen
            reply(RelayMessage(e.key, e.data))
        end
    end

    -- Tell the guild about players it can't hear itself.
    function RelayToGuild()
        if not IsInGuild() or GetTime() - lastGuildRelay < RELAY_GUILD_INTERVAL then return end
        lastGuildRelay = GetTime()
        local batch = RelayBatch(function(d)
            return d.via ~= "GUILD" and (guildRelayed[d.acct] or 0) < (d.seen or 0)
        end)
        for _, e in ipairs(batch) do
            guildRelayed[e.data.acct] = e.data.seen
            Enqueue(RelayMessage(e.key, e.data), "GUILD")
        end
    end

    -- Every 10 minutes: the guild, and friends who've gone quiet.
    function RelayTick()
        RelayToGuild()
        for key, c in pairs(contacts) do
            if c.reply then RelayToContact(key, c.reply, c.acct) end
        end
    end

    function ApplyRelay(msg, via)
        local _, rAcct, rKey, rDisplay, rClass, rFaction, rTotal, rWeekId, rWeek, rDeaths, rLevel,
            rXP, rChallenges, rJph, rPrestige, rDuels, rVersion, rSeen, rHops = strsplit(":", msg)
        rTotal, rSeen = tonumber(rTotal), tonumber(rSeen)
        if not rAcct or rAcct == "" or rAcct == acct.id or not rTotal or not rSeen
            or not rKey or rKey == "" then return end
        if via == "GUILD" then guildRelayed[rAcct] = math.max(guildRelayed[rAcct] or 0, rSeen) end
        rSeen = math.min(rSeen, time())             -- other computers' clocks may run ahead
        if time() - rSeen > RELAY_MAX_AGE then return end

        local peers = JumpCounterDB.peers
        local key, entry
        for k, d in pairs(peers) do
            if d.acct == rAcct then key, entry = k, d break end
        end
        if entry and (entry.seen or 0) >= rSeen then return end   -- we know newer
        if not key then
            key = NormalizeSender(rKey)
            if key == playerKey or JumpCounterDB.chars[key] then return end
            local taken = peers[key]
            if taken and taken.acct and taken.acct ~= rAcct then key = key .. "~" .. rAcct:sub(1, 6) end
        end
        entry = entry or {}
        local function num(v) return tonumber(v) end
        entry.acct = rAcct
        entry.display = (rDisplay ~= "" and rDisplay) or entry.display
        entry.class = (rClass ~= "" and rClass) or entry.class
        entry.faction = (rFaction == "A" or rFaction == "H") and rFaction or entry.faction
        entry.total = rTotal
        entry.weekId, entry.week = num(rWeekId), num(rWeek)
        entry.deaths = num(rDeaths)
        entry.charLevel = num(rLevel) or entry.charLevel
        entry.xp, entry.challenges, entry.jph = num(rXP), num(rChallenges), num(rJph)
        entry.prestige, entry.duelWins = num(rPrestige), num(rDuels)
        entry.version = (rVersion ~= "" and rVersion) or entry.version
        entry.seen = rSeen
        entry.hops = tonumber(rHops) or RELAY_MAX_HOPS
        entry.via = "RELAY"
        peers[key] = entry
        NoteVersion(entry.version)
        PruneStalePeers()
        RefreshBoardSoon()
    end
end

-- UnitName("player") only gives the first name; messages we receive from
-- ourselves carry the full one ("Zivv Pewpew").
local function LearnMyName(display)
    if charData.nameSetByHand then return end      -- /jumps name wins
    if not display or display == "" or display == charData.display then return end
    if (display:match("^(%S+)") or display) ~= UnitName("player") then return end
    charData.display = display
    dirty = true
    RefreshBoardSoon()
end

-- The second name may be part of the unit's name or title rather than chat
-- only. Try what the game offers: "First Second" counts, anything else
-- (titles like "Private Zivv", "Zivv of the ...") doesn't.
local function NameCandidates()
    local list = {}
    local function try(label, fn)
        local ok, value = pcall(fn)
        table.insert(list, { label = label, value = ok and type(value) == "string" and value or nil })
    end
    try("UnitPVPName", function() return UnitPVPName and UnitPVPName("player") end)
    try("GetUnitName", function() return GetUnitName and GetUnitName("player", true) end)
    try("UnitFullName", function() return UnitFullName and UnitFullName("player") end)
    try("UnitName", function() return UnitName("player") end)
    return list
end

local function LearnMyNameFromUnit()
    local first = UnitName("player")
    for _, c in ipairs(NameCandidates()) do
        local v = c.value and c.value:gsub("%-.*$", "")      -- drop "-Realm"
        local second = v and v:match("^" .. first:gsub("%p", "%%%0") .. " (%S+)$")
        if second and second:lower() ~= "the" and second:lower() ~= "of" then
            LearnMyName(v)
            return
        end
    end
end

-- key/display: who sent it, as best the channel can tell us.
-- reply(msg): sends a message straight back to the sender, or nil.
-- via: "GUILD", "GROUP", "WHISPER" or "BNET".
local function HandleMessage(msg, key, display, reply, via)
    if msg:match("^D[QAGPF]:") then
        OnDuelMessage(msg)
        return
    end
    if msg:match("^R:") then
        ApplyRelay(msg, via)
        return
    end
    local tag, total, class, version, sentKey, sentDisplay, weekId, weekCount, guid, deaths,
        charLevel, xp, challenges, jph, prestige, acctId, characters, duelWins, faction = strsplit(":", msg)
    if tag == "T" and tonumber(total) then
        total = tonumber(total)
        -- Newer clients tell us their key and full name directly.
        if sentKey and sentKey ~= "" then key = NormalizeSender(sentKey) end
        local senderName = display               -- the name the channel shows
        if sentDisplay and sentDisplay ~= "" then display = sentDisplay end
        if guid == "" then guid = nil end
        if acctId == "" then acctId = nil end      -- nil before 1.1.0

        if key == playerKey or (guid and guid == UnitGUID("player")) or acctId == acct.id then
            -- Our own message echoed back: learn our full name from it.
            if guid and guid == UnitGUID("player") then LearnMyName(senderName) end
            return
        end
        if JumpCounterDB.chars[key] then return end   -- one of our alts (old save format)
        -- Two players can share a first name ("Zivv Gg" / "Zivv Pewpew").
        -- Different accounts get separate rows.
        local taken = JumpCounterDB.peers[key]
        if acctId and taken and taken.acct and taken.acct ~= acctId then
            key = key .. "~" .. acctId:sub(1, 6)
        end

        local previous = JumpCounterDB.peers[key]
        -- Same character (by GUID) saved under another key? Merge into this one.
        if guid and not (previous and previous.guid == guid) then
            for otherKey, data in pairs(JumpCounterDB.peers) do
                if otherKey ~= key and data.guid == guid then
                    previous = previous or data
                    JumpCounterDB.peers[otherKey] = nil
                end
            end
        end
        local oldTotal = previous and previous.total
        local oldPrestige = previous and previous.prestige
        if acctId then
            -- One row per account: drop the rows of their other characters
            -- (whichever was online before) and continue from the newest.
            local sameAccount = previous and previous.acct == acctId and previous or nil
            for otherKey, data in pairs(JumpCounterDB.peers) do
                if otherKey ~= key and data.acct == acctId then
                    if not sameAccount or (data.seen or 0) > (sameAccount.seen or 0) then
                        sameAccount = data
                    end
                    JumpCounterDB.peers[otherKey] = nil
                end
            end
            -- First account-wide score from them: the jump from a single
            -- character's total to the account total isn't a real gain, so
            -- don't announce ranks or overtakes for it.
            oldTotal = sameAccount and sameAccount.total
            oldPrestige = sameAccount and sameAccount.prestige
            if sameAccount then previous = sameAccount end
        end
        local entry = previous or {}
        entry.total = total
        entry.class = (class and class ~= "") and class or entry.class
        entry.display = display or entry.display
        entry.guid = guid or entry.guid
        entry.weekId = tonumber(weekId)
        entry.week = tonumber(weekCount)
        entry.deaths = tonumber(deaths)           -- nil from versions before 0.7.0
        local lvl = tonumber(charLevel)           -- these three are nil before 0.8.0
        entry.charLevel = (lvl and lvl > 0) and lvl or entry.charLevel
        entry.xp = tonumber(xp)
        entry.challenges = tonumber(challenges)
        entry.jph = tonumber(jph)                 -- nil before 0.9.0 or < 30 min tracked
        entry.prestige = tonumber(prestige)       -- nil before 0.10.0
        entry.acct = acctId                       -- these two are nil before 1.1.0
        entry.characters = (characters and characters ~= "") and characters or nil
        entry.duelWins = tonumber(duelWins)       -- nil before 1.5.0
        entry.faction = (faction == "A" or faction == "H") and faction or entry.faction   -- 1.6.0
        entry.via, entry.hops = via, 0            -- heard directly
        entry.version = (version and version ~= "") and version or nil
        entry.seen = time()
        JumpCounterDB.peers[key] = entry
        PruneStalePeers()
        if JumpCounterDB.peers[key] ~= entry then return end   -- itself a leftover copy
        OnPeerScore(key, oldTotal, total, entry.class, oldPrestige, entry.prestige)

        NoteVersion(version)
        -- A friend heard directly: pass on the scores we know.
        if reply and acctId then RelayToContact(key, reply, acctId) end
        RefreshBoardSoon()
    elseif tag == "ME" then
        -- Our own "who am I" whisper (see LOGIN): the sender is our full name.
        if total == UnitGUID("player") then LearnMyName(display) end
    elseif tag == "REQ" and key ~= playerKey then
        if reply then
            -- Asked directly (whisper / Battle.net); answer directly.
            reply(ScoreMessage())
        elseif GetTime() - lastReplyTime > 10 then
            -- Someone asked the guild/group; answer once, after a random
            -- delay so a big guild doesn't all answer in the same second.
            lastReplyTime = GetTime()
            C_Timer.After(math.random() * 10, function()
                BroadcastScore()
                if via == "GUILD" then RelayToGuild() end
            end)
        end
    end
end

local function OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX then return end
    local key, display = NormalizeSender(sender)
    local reply
    if channel == "WHISPER" then
        knownWhisper[sender] = true
        knownWhisper[sender:match("^[^-]+")] = true
        reply = function(m) SendWhisper(sender, m) end
    end
    local via = (channel == "GUILD" and "GUILD") or (channel == "WHISPER" and "WHISPER") or "GROUP"
    HandleMessage(msg, key, display, reply, via)
end

local function OnBNetAddonMessage(prefix, msg, _, gameAccountID)
    if prefix ~= PREFIX or not gameAccountID then return end
    knownBNet[gameAccountID] = true
    local key, display
    local info = C_BattleNet and C_BattleNet.GetGameAccountInfoByID
        and C_BattleNet.GetGameAccountInfoByID(gameAccountID)
    if info and info.characterName then
        local realm = (info.realmName or ""):gsub("[%s%-]", "")
        key, display = NormalizeSender(info.characterName .. "-" .. realm)
    end
    -- Messages from current versions carry their own key, so a missing name is fine.
    HandleMessage(msg, key or ("bnet-" .. gameAccountID), display,
        function(m) SendBNet(gameAccountID, m) end, "BNET")
end

---------------------------------------------------------------------------
-- Counter window
---------------------------------------------------------------------------
local function UpdateCounter()
    if not counterFrame then return end
    local me = Me()
    counterFrame.total:SetText(BreakUpLargeNumbers(me.total))
    counterFrame.session:SetText(("Week: %s  Session: %s"):format(
        BreakUpLargeNumbers(MyWeekCount(me)), BreakUpLargeNumbers(sessionJumps)))
end

local function MakeMovable(frame, savedKey)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(self)
        if not (savedKey and JumpCounterDB.ui.locked) then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if savedKey then
            local point, _, relPoint, x, y = self:GetPoint()
            JumpCounterDB.ui[savedKey] = { point, relPoint, x, y }
        end
    end)
end

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function CreateCounterFrame()
    local f = CreateFrame("Frame", "JumpCounterFrame", UIParent, "BackdropTemplate")
    f:SetSize(160, 50)
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.7)
    f:SetFrameStrata("MEDIUM")

    local pos = JumpCounterDB.ui.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
    MakeMovable(f, "pos")

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", 0, -7)
    label:SetText("Jumps")

    f.total = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.total:SetPoint("TOP", label, "BOTTOM", 0, -1)

    f.session = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.session:SetPoint("TOP", f.total, "BOTTOM", 0, -1)

    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            if boardFrame:IsShown() then boardFrame:Hide() else boardFrame:Show() end
        end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("JumpCounter")
        GameTooltip:AddLine("Drag to move, right-click to open JumpCounter.", 1, 1, 1)
        GameTooltip:AddLine("/jumps help for commands.", 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", GameTooltip_Hide)

    f:SetShown(JumpCounterDB.ui.shown)
    counterFrame = f
    UpdateCounter()
end

---------------------------------------------------------------------------
-- Leaderboard window
---------------------------------------------------------------------------
local function DisplayName(key)
    if key == playerKey then return charData.display or UnitName("player") end
    local data = JumpCounterDB.peers[key]
    if data and data.display then return data.display end
    return key:match("^[^-]+") or key
end

local function ColoredName(key, class)
    local name = DisplayName(key)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color and color.WrapTextInColorCode then
        return color:WrapTextInColorCode(name)
    end
    return name
end

-- mode "all" ranks by all-time jumps, "week" by this week's jumps,
-- "deaths" by deaths (players on versions before 0.7.0 don't send deaths).
local function BuildStandings(mode)
    local wid = CurrentWeekId()
    local list = {}
    local function add(key, data, mine)
        local score = data.total
        if mode == "week" then
            score = (wid and data.weekId == wid) and (data.week or 0) or 0
            if score == 0 and key ~= playerKey then return end
        elseif mode == "deaths" then
            if data.deaths == nil and key ~= playerKey and not mine then return end
            score = data.deaths or 0
        elseif mode == "level" then
            score = EntryXP(data)
        elseif mode == "rate" then
            local jph = JumpsPerHour(data)
            if not jph and key ~= playerKey then return end
            score = jph or 0
        end
        table.insert(list, { key = key, score = score, total = data.total,
            class = data.class, mine = mine, data = data })
    end
    add(playerKey, Me(), true)    -- all your characters as one row

    -- Show each account (or, for old versions, each name) once: keep the
    -- most recently updated entry.
    local byName = {}
    for key, data in pairs(JumpCounterDB.peers) do
        if not JumpCounterDB.chars[key] then
            local name = data.acct and ("#" .. data.acct) or DisplayName(key):lower()
            local best = byName[name]
            if not best or (data.seen or 0) > (best.data.seen or 0) then
                byName[name] = { key = key, data = data }
            end
        end
    end
    for _, e in pairs(byName) do add(e.key, e.data) end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end


---------------------------------------------------------------------------
-- Notifications: milestones and overtakes
---------------------------------------------------------------------------
-- Milestones: 100, 500, then every 1,000. 1,000 and every 5,000 are "big".
local function IsMilestone(n)
    return n == 100 or n == 500 or (n >= 1000 and n % 1000 == 0)
end

local function HighestMilestone(n)
    if n >= 1000 then return n - n % 1000 end
    if n >= 500 then return 500 end
    if n >= 100 then return 100 end
    return 0
end

local function IsBigMilestone(n)
    return n == 1000 or (n >= 5000 and n % 5000 == 0)
end

local function PlaySoundKit(name)
    if settings.sounds and SOUNDKIT and SOUNDKIT[name] then
        PlaySound(SOUNDKIT[name])
    end
end

local function Notify(text, big)
    Print(text)
    if big then
        if RaidNotice_AddMessage and RaidWarningFrame then
            RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
        end
        PlaySoundKit("RAID_WARNING")
    else
        PlaySoundKit("IG_QUEST_LIST_COMPLETE")
    end
end

local GOLD = "|cffffd100%s|r"

local function MyRank()
    for i, entry in ipairs(BuildStandings()) do
        if entry.key == playerKey then return i end
    end
end

local function ShortName(key)
    return key:match("^[^-]+") or key
end

-- When two players keep passing each other, only announce it once per
-- OVERTAKE_COOLDOWN per person (in either direction).
-- In a big guild, also at most one overtake message per OVERTAKE_GLOBAL_COOLDOWN.
local OVERTAKE_COOLDOWN = 600
local OVERTAKE_GLOBAL_COOLDOWN = 120
local lastOvertakeMsg = {}
local lastAnyOvertake = -OVERTAKE_GLOBAL_COOLDOWN

local function OvertakeAllowed(key)
    local id = DisplayName(key):lower()
    local now = GetTime()
    if now - lastAnyOvertake < OVERTAKE_GLOBAL_COOLDOWN then return false end
    if lastOvertakeMsg[id] and now - lastOvertakeMsg[id] < OVERTAKE_COOLDOWN then
        return false
    end
    lastOvertakeMsg[id] = now
    lastAnyOvertake = now
    return true
end

-- Called after each of your own jumps.
local function CheckMyNotifications(newTotal)
    if settings.myMilestones then
        local title, threshold = GetJumpRank(newTotal)
        if threshold == newTotal then
            -- New jump rank: always a big announcement.
            Notify(GOLD:format(("%s jumps - you are now a %s!")
                :format(BreakUpLargeNumbers(newTotal), title)), true)
        elseif IsMilestone(newTotal) then
            Notify(GOLD:format(("You reached %s jumps!"):format(BreakUpLargeNumbers(newTotal))),
                IsBigMilestone(newTotal))
        end
    end

    if settings.overtakes then
        -- Anyone sitting exactly on our previous total was just passed.
        local passed = {}
        for key, data in pairs(JumpCounterDB.peers) do
            if data.total == newTotal - 1 and not JumpCounterDB.chars[key] and OvertakeAllowed(key) then
                table.insert(passed, ColoredName(key, data.class))
            end
        end
        if #passed > 0 then
            Notify(("You passed %s! You're now #%d."):format(table.concat(passed, ", "), MyRank() or 0))
        end
    end
end

-- Called whenever a friend's score arrives. oldTotal is nil the first time
-- we ever hear from them, so we don't announce anything for new players.
function OnPeerScore(key, oldTotal, newTotal, class, oldPrestige, newPrestige)
    if not oldTotal then return end
    if newPrestige and newPrestige > (oldPrestige or 0) and settings.friendRankUps then
        Notify(("%s reached %sPrestige %d!"):format(ColoredName(key, class),
            PrestigeTag(newPrestige), newPrestige))
    end
    if newTotal <= oldTotal then return end
    local name = ColoredName(key, class)

    local title, threshold = GetJumpRank(newTotal)
    local milestone = HighestMilestone(newTotal)
    if threshold and threshold > oldTotal then
        if settings.friendRankUps then
            Notify(("%s reached %s jumps and is now a %s!")
                :format(name, BreakUpLargeNumbers(threshold), GOLD:format(title)))
        end
    elseif milestone > oldTotal and settings.friendMilestones then
        Notify(("%s reached %s jumps!"):format(name, BreakUpLargeNumbers(milestone)))
    end

    if settings.overtakes then
        local mine = Me().total
        if oldTotal <= mine and newTotal > mine and OvertakeAllowed(key) then
            Notify(("%s just passed you! You're now #%d (%s behind).")
                :format(name, MyRank() or 0, BreakUpLargeNumbers(newTotal - mine)))
        end
    end
end

---------------------------------------------------------------------------
-- Progression: challenge tracking, level-ups, challenges window
---------------------------------------------------------------------------
local challengeFrame
local knownLevel                  -- jump level last time we checked
local minuteJumps = {}            -- timestamps of jumps in the last 60 seconds

local function CheckLevelUp()
    local level = EntryLevel(Me())
    if knownLevel and level > knownLevel and settings.myProgress then
        Print(GOLD:format(("Jump level %d!"):format(level)))
        if level >= PRESTIGE_LEVEL and knownLevel < PRESTIGE_LEVEL then
            Notify(GOLD:format("You can now Prestige! Open /jumps to do it."), true)
        end
    end
    knownLevel = level
end

local function CanPrestige()
    return (EntryLevel(Me())) >= PRESTIGE_LEVEL
end

local function DoPrestige()
    if not CanPrestige() then
        Print(("You need jump level %d to prestige."):format(PRESTIGE_LEVEL))
        return
    end
    acct.prestige = acct.prestige + 1
    knownLevel = EntryLevel(Me())
    dirty = true
    Notify(GOLD:format(("%sPrestige %d! Your jump level starts over - total jumps and ranks are kept.")
        :format(PrestigeTag(acct.prestige), acct.prestige)), true)
    CheckChallenges()                 -- prestige challenges
    RefreshBoardSoon()
end

StaticPopupDialogs["JUMPCOUNTER_PRESTIGE"] = {
    text = "Prestige?\n\nYour jump level goes back to 1 and you get a prestige star.\n"
        .. "Total jumps, ranks, total XP and challenges are kept.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() DoPrestige() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function AskPrestige()
    if not CanPrestige() then
        Print(("You need jump level %d to prestige (you are level %d).")
            :format(PRESTIGE_LEVEL, (EntryLevel(Me()))))
        return
    end
    StaticPopup_Show("JUMPCOUNTER_PRESTIGE")
end

function CheckChallenges()
    local completed, xp = {}, 0
    for _, c in ipairs(CHALLENGES) do
        if not acct.done[c.id] and c.progress() >= c.goal then
            acct.done[c.id] = time()
            acct.challengeXP = acct.challengeXP + c.xp
            table.insert(completed, c.name)
            xp = xp + c.xp
        end
    end
    if #completed > 0 then
        dirty = true
        if settings.myProgress then
            if #completed <= 2 then
                for _, name in ipairs(completed) do
                    for _, c in ipairs(CHALLENGES) do
                        if c.name == name then
                            Notify(GOLD:format(("Challenge complete: %s (+%s XP)")
                                :format(name, BreakUpLargeNumbers(c.xp))), true)
                        end
                    end
                end
            else
                -- Several at once (e.g. new challenges you already qualify for).
                Notify(GOLD:format(("%d challenges complete (+%s XP)!"):format(#completed,
                    BreakUpLargeNumbers(xp))), true)
                Print(table.concat(completed, ", "))
            end
        end
    end
    CheckLevelUp()
end

-- Longest run of consecutive days in a set of "YYYY-MM-DD" keys.
local function LongestStreak(days)
    local nums = {}
    for d in pairs(days) do
        local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            -- Noon avoids daylight-saving edges; /86400 gives a day number.
            nums[#nums + 1] = math.floor(time({ year = tonumber(y), month = tonumber(m),
                day = tonumber(dd), hour = 12 }) / 86400)
        end
    end
    table.sort(nums)
    local best, run = 0, 0
    for i, n in ipairs(nums) do
        if i > 1 and n == nums[i - 1] + 1 then run = run + 1
        elseif i == 1 or n ~= nums[i - 1] then run = 1 end
        best = math.max(best, run)
    end
    return best
end

-- Stats worked out from others: day streak and best week.
local function UpdateDerivedStats()
    local st = acct.stats
    st.bestStreak = math.max(st.bestStreak or 0, LongestStreak(st.days))
    st.bestWeek = math.max(st.bestWeek or 0, MyWeekCount())
end

-- Record what kind of jump this was. inWater = it was a surface jump.
local function TrackJump(inWater)
    local st = acct.stats
    local function inc(name) st[name] = (st[name] or 0) + 1 end
    -- In combat the game hides some values from addons ("secret values");
    -- using one is an error. Treat a hidden value as unknown instead.
    local function plain(v)
        if issecretvalue and issecretvalue(v) then return nil end
        return v
    end

    if plain(IsMounted()) then inc("mounted") end
    if inWater then inc("swim") end
    if plain(UnitIsGhost("player")) then inc("ghost") end
    if plain(UnitAffectingCombat("player")) then inc("combat") end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "party" or instanceType == "raid") then inc("instance") end
    if IsInGroup() and (plain(GetNumGroupMembers()) or 0) >= 5 then inc("group") end
    if inInstance and instanceType == "pvp" then inc("pvp") end
    if plain(IsResting()) then inc("resting") end
    if IsStealthed and plain(IsStealthed()) then inc("stealth") end
    if UnitIsPVP and plain(UnitIsPVP("player")) then inc("pvpFlagged") end
    -- Only druid forms and Ghost Wolf (warrior stances are "forms" too).
    local class = charData.class
    if (class == "DRUID" or class == "SHAMAN") and (plain(GetShapeshiftForm()) or 0) > 0 then inc("shapeshift") end
    local hour = tonumber(date("%H"))
    if hour and hour < 4 then inc("night") end
    local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    if (plain(UnitLevel("player")) or 0) >= maxLevel then inc("maxLevel") end

    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID then
        st.zones[mapID] = true
        local faction = UnitFactionGroup("player")
        for side, cities in pairs(CAPITALS) do
            if cities[mapID] then
                if side == faction then
                    st.capitals[mapID] = true
                else
                    st.enemyCapital = 1
                end
            end
        end
    end
    local today = date("%Y-%m-%d")
    if not st.days[today] then
        st.days[today] = true
        st.bestStreak = math.max(st.bestStreak or 0, LongestStreak(st.days))
    end
    st.bestWeek = math.max(st.bestWeek or 0, MyWeekCount())

    st.bestSession = math.max(st.bestSession or 0, sessionJumps)

    local now = GetTime()
    table.insert(minuteJumps, now)
    while minuteJumps[1] and minuteJumps[1] < now - 60 do table.remove(minuteJumps, 1) end
    st.bestMinute = math.max(st.bestMinute or 0, #minuteJumps)

    inc("sinceDeath")
    st.bestSinceDeath = math.max(st.bestSinceDeath or 0, st.sinceDeath)

    CheckChallenges()
end

---------------------------------------------------------------------------
-- Jump duels: now and then two players who are jumping around are paired
-- for a 2-minute jump-off. Whoever jumps most wins, and everyone online
-- with the addon sees the result.
--
-- Messages (sent like scores: guild, group and friends who use the addon):
--   DQ:<id>:<start>:<acct>:<name>:<class>:<target acct>:<manual>:<length>  invite
--   DA:<id>:<acct>                                              accept
--   DG:<id>:<start>:<acct>:<name>:<class>:<acct>:<name>:<class>  go (from the inviter)
--   DP:<id>:<acct>:<count>                                       progress
--   DF:<id>:<acct>:<name>:<class>:<count>                        final count
-- Times are server times, so both players count the same seconds. The
-- invite says how long the duel is (1.5.0/1.6.0 invites don't: 3 minutes).
---------------------------------------------------------------------------
local DuelOnJump, CreateDuelFrame, MaybeStartRandomDuel, DuelCommand
do
    local DUEL_LENGTH = 120
    local OLD_DUEL_LENGTH = 180       -- invites from 1.5.0 / 1.6.0
    local DUEL_LEAD = 15              -- seconds from invite to start (countdown)
    local DUEL_COOLDOWN = 1800        -- at most one random duel per 30 minutes each
    local DUEL_CHANCE = 1 / 90        -- chance per minute to start one (~every 1.5 h)
    local DUEL_ACTIVE = 300           -- opponents must have jumped in the last 5 min
    local DUEL_MIN_VERSION = "1.7.0"   -- older versions would count 3 minutes
    local DUEL_WIN_XP, DUEL_PLAY_XP = 100, 25

    local duel                        -- our duel: { id, start, finish, state, opp, mine, theirs, ... }
    local lastDuelEnd = 0             -- server time
    local busyUntil = {}              -- [acct id] = server time their duel ends
    local duelResults = {}            -- other players' duels: [id] = { finish, shown, players = {} }
    local duelTicker, duelFrame

    local function Clean(s) return (tostring(s or ""):gsub(":", "")) end
    local function MyDuelName() return charData.display or UnitName("player") end

    local function ClassColored(name, class)
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(name) end
        return name
    end

    local function SendDuel(...)
        local parts = { ... }
        for i = 1, select("#", ...) do parts[i] = tostring(parts[i] or "") end
        Send(table.concat(parts, ":"))
    end

    -- manual = someone typed /jumps duel: skip the cooldown.
    local function CanDuel(now, manual)
        return settings.duels and not duel and not UnitIsAFK("player")
            and (manual or now - lastDuelEnd >= DUEL_COOLDOWN)
    end

    -- Players on 1.5.0+ who jumped recently and aren't in a duel.
    local function DuelCandidates(now)
        local list = {}
        for key, data in pairs(JumpCounterDB.peers) do
            if data.acct and data.version and not IsNewerVersion(DUEL_MIN_VERSION, data.version)
                and (data.hops or 0) == 0          -- heard directly, so we can reach them
                and time() - (data.seen or 0) <= DUEL_ACTIVE and (busyUntil[data.acct] or 0) < now then
                table.insert(list, { acct = data.acct, name = DisplayName(key), class = data.class })
            end
        end
        return list
    end

    local function UpdateDuelFrame(now)
        local f = duelFrame
        if not f then return end
        if duel and duel.state == "on" then
            f.title:SetText("Jump duel vs " .. ClassColored(duel.opp.name, duel.opp.class))
            local mine, theirs = duel.mine, duel.theirs
            local lead = mine > theirs and "|cff33ff33%d|r" or (mine < theirs and "|cffff5555%d|r" or "|cffffffff%d|r")
            f.score:SetText(("You " .. lead .. "  -  %d"):format(mine, theirs))
            if now < duel.start then
                f.time:SetText(("Starts in %d..."):format(duel.start - now))
            elseif now < duel.finish then
                local left = duel.finish - now
                f.time:SetText(("%d:%02d left - jump!"):format(math.floor(left / 60), left % 60))
            else
                f.time:SetText("Time! Waiting for the final score...")
            end
            f:Show()
        elseif f.resultUntil and now < f.resultUntil then
            f:Show()
        else
            f:Hide()
        end
    end

    local function EndDuel(d, text)
        local now = GetServerTime()
        duel = nil
        lastDuelEnd = now
        if duelFrame then
            duelFrame.title:SetText("Jump duel vs " .. ClassColored(d.opp.name, d.opp.class))
            duelFrame.score:SetText(("You %d  -  %d"):format(d.mine, d.theirs))
            duelFrame.time:SetText(text)
            duelFrame.resultUntil = now + 10
        end
    end

    local function FinishDuel()
        local d = duel
        local opp = ClassColored(d.opp.name, d.opp.class)
        if not d.heard then
            -- Nothing ever arrived from them (disconnected?): no result.
            Print(("The jump duel against %s was cancelled - no score arrived from them."):format(opp))
            EndDuel(d, "Cancelled")
            lastDuelEnd = lastDuelEnd - DUEL_COOLDOWN + 300   -- try again soon
            return
        end
        local me, them = d.mine, d.theirs
        local xp, text, short = DUEL_PLAY_XP
        if me > them then
            acct.duelWins = (acct.duelWins or 0) + 1
            xp = DUEL_WIN_XP
            text = ("You won the jump duel against %s, %d - %d! (+%d XP)"):format(opp, me, them, xp)
            short = "|cff33ff33You won!|r"
        elseif me < them then
            acct.duelLosses = (acct.duelLosses or 0) + 1
            text = ("%s won the jump duel, %d - %d. (+%d XP for playing)"):format(opp, them, me, xp)
            short = "|cffff5555You lost|r"
        else
            acct.duelDraws = (acct.duelDraws or 0) + 1
            text = ("The jump duel against %s is a draw, %d - %d! (+%d XP)"):format(opp, me, them, xp)
            short = "Draw!"
        end
        if not d.oppFinal then text = text .. " |cff999999(their last known score)|r" end
        acct.duelXP = (acct.duelXP or 0) + xp
        dirty = true
        Notify(GOLD:format(text), true)
        EndDuel(d, short)
        CheckChallenges()
        RefreshBoardSoon()
    end

    local function DuelTick()
        local now = GetServerTime()
        local d = duel
        if d and d.state ~= "on" and now >= d.start then
            -- The invite was never confirmed.
            if d.manual and d.state == "invited" then
                Print(("%s didn't accept the duel (busy, AFK or duels turned off)."):format(
                    ClassColored(d.opp.name, d.opp.class)))
            end
            duel = nil
        elseif d and d.state == "on" then
            if now >= d.finish and not d.sentFinal then
                d.sentFinal, d.doneAt = true, now
                SendDuel("DF", d.id, acct.id, Clean(MyDuelName()), charData.class, d.mine)
            elseif now < d.finish and d.mine ~= (d.sentCount or 0) and now - (d.lastProgress or 0) >= 5 then
                d.sentCount, d.lastProgress = d.mine, now
                SendDuel("DP", d.id, acct.id, d.mine)
            end
            if d.sentFinal and (d.oppFinal or now - d.doneAt >= 15) then FinishDuel() end
        end
        for id, r in pairs(duelResults) do
            if now - r.finish > 300 then duelResults[id] = nil end
        end
        UpdateDuelFrame(now)
        local showing = duelFrame and duelFrame:IsShown()
        if not duel and not next(duelResults) and not showing and duelTicker then
            duelTicker:Cancel()
            duelTicker = nil
        end
    end

    local function StartDuelTicker()
        if not duelTicker then duelTicker = C_Timer.NewTicker(0.5, DuelTick) end
    end

    local function AnnounceDuelStart()
        local now = GetServerTime()
        Notify(GOLD:format(("JUMP DUEL vs %s! Most jumps in %d minutes wins - starts in %d seconds!")
            :format(ClassColored(duel.opp.name, duel.opp.class), math.floor((duel.finish - duel.start) / 60 + 0.5),
            math.max(0, duel.start - now))), true)
        UpdateDuelFrame(now)
    end

    -- Invite a random active player. Returns the opponent, or nil.
    local function TryStartDuel(manual)
        local now = GetServerTime()
        local list = DuelCandidates(now)
        if #list == 0 then return nil end
        local opp = list[math.random(#list)]
        local start = now + DUEL_LEAD
        duel = { id = acct.id .. now, start = start, finish = start + DUEL_LENGTH, state = "invited",
            opp = opp, mine = 0, theirs = 0, manual = manual }
        SendDuel("DQ", duel.id, start, acct.id, Clean(MyDuelName()), charData.class,
            opp.acct, manual and "1" or "", DUEL_LENGTH)
        StartDuelTicker()
        return opp
    end

    function OnDuelMessage(msg)
        local tag, id, a1, a2, a3, a4, a5, a6, a7 = strsplit(":", msg)
        local now = GetServerTime()
        if not id or id == "" then return end
        if tag == "DQ" then
            -- Invite: a1 start, a2 their acct, a3 name, a4 class, a5 target acct, a6 manual, a7 length
            local start = tonumber(a1)
            local length = tonumber(a7) or OLD_DUEL_LENGTH
            if length < 30 or length > 600 then return end
            if a5 ~= acct.id or a2 == acct.id or not start then return end
            if not CanDuel(now, a6 == "1") or start - now < 5 or start - now > 60 then return end
            duel = { id = id, start = start, finish = start + length, state = "accepted",
                opp = { acct = a2, name = a3, class = (a4 ~= "" and a4) or nil }, mine = 0, theirs = 0 }
            SendDuel("DA", id, acct.id)
            StartDuelTicker()
        elseif tag == "DA" then
            if duel and duel.id == id and duel.state == "invited" and a1 == duel.opp.acct then
                duel.state = "on"
                SendDuel("DG", id, duel.start, acct.id, Clean(MyDuelName()), charData.class,
                    duel.opp.acct, Clean(duel.opp.name), duel.opp.class)
                AnnounceDuelStart()
            end
        elseif tag == "DG" then
            -- Go: a1 start, a2/a3/a4 inviter, a5/a6/a7 invited
            local start = tonumber(a1)
            if not start then return end
            busyUntil[a2], busyUntil[a5] = start + OLD_DUEL_LENGTH, start + OLD_DUEL_LENGTH
            if duel and duel.id == id and duel.state == "accepted" then
                duel.state, duel.finish, duel.start = "on", start + (duel.finish - duel.start), start
                AnnounceDuelStart()
            end
        elseif tag == "DP" then
            if duel and duel.id == id and a1 == duel.opp.acct then
                duel.theirs = math.max(duel.theirs, tonumber(a2) or 0)
                duel.heard = true
            end
        elseif tag == "DF" then
            -- Final: a1 acct, a2 name, a3 class, a4 count
            local count = tonumber(a4)
            if not count or a1 == acct.id then return end
            if duel and duel.id == id then
                if a1 == duel.opp.acct then
                    duel.theirs, duel.oppFinal, duel.heard = count, true, true
                end
                return
            end
            -- Someone else's duel: announce once both final scores are in.
            local r = duelResults[id] or { finish = now, players = {} }
            duelResults[id] = r
            if r.shown or r.players[a1] then return end
            r.players[a1] = { name = a2, class = (a3 ~= "" and a3) or nil, count = count }
            local list = {}
            for _, p in pairs(r.players) do table.insert(list, p) end
            if #list == 2 then
                r.shown = true
                if settings.duelNews then
                    table.sort(list, function(x, y) return x.count > y.count end)
                    local a, b = list[1], list[2]
                    Print(("|cffffd100Jump duel:|r %s %s %s, %d - %d!"):format(
                        ClassColored(a.name, a.class), a.count == b.count and "and" or "beat",
                        ClassColored(b.name, b.class), a.count, b.count)
                        .. (a.count == b.count and " It's a draw." or ""))
                end
            end
            StartDuelTicker()
        end
    end

    -- Called for every counted jump.
    function DuelOnJump()
        if duel and duel.state == "on" then
            local now = GetServerTime()
            if now >= duel.start and now < duel.finish then
                duel.mine = duel.mine + 1
                UpdateDuelFrame(now)
            end
        end
    end

    function CreateDuelFrame()
        local f = CreateFrame("Frame", "JumpCounterDuelFrame", UIParent, "BackdropTemplate")
        f:SetSize(250, 64)
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(0, 0, 0, 0.8)
        f:SetFrameStrata("HIGH")
        local pos = JumpCounterDB.ui.duelPos
        if pos then
            f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            f:SetPoint("TOP", UIParent, "TOP", 0, -140)
        end
        MakeMovable(f)
        f:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint()
            JumpCounterDB.ui.duelPos = { point, relPoint, x, y }
        end)
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOP", 0, -8)
        f.score = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        f.score:SetPoint("TOP", f.title, "BOTTOM", 0, -3)
        f.time = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.time:SetPoint("TOP", f.score, "BOTTOM", 0, -3)
        f:Hide()
        duelFrame = f
    end

    -- Every minute, maybe start a random duel.
    function MaybeStartRandomDuel()
        if CanDuel(GetServerTime()) and math.random() < DUEL_CHANCE then TryStartDuel(false) end
    end

    -- /jumps duel: challenge a random player who is jumping around right now.
    function DuelCommand()
        if not settings.duels then
            Print("Jump duels are turned off - turn them on in /jumps settings.")
        elseif duel then
            Print("You're already in a jump duel.")
        else
            local opp = TryStartDuel(true)
            if opp then
                Print(("Challenging %s to a jump duel..."):format(ClassColored(opp.name, opp.class)))
            else
                Print("Nobody to duel right now - opponents need v" .. DUEL_MIN_VERSION
                    .. " or newer and must have jumped in the last 5 minutes.")
            end
        end
    end
end


---------------------------------------------------------------------------
-- Jump detection
---------------------------------------------------------------------------
-- Our hook runs *after* the jump starts, so IsFalling() may already be true.
-- Track whether we were on the ground on the previous frame instead.
local wasGrounded = true
local wasSwimming = false
local debugMode = false
local jumpStartedAt               -- debug: when the last land jump left the ground
local groundTracker = CreateFrame("Frame")
groundTracker:SetScript("OnUpdate", function()
    wasSwimming = IsSwimming() and true or false
    local grounded = not (IsFalling() or wasSwimming or IsFlying() or UnitOnTaxi("player"))
    -- /jumps debug: report how long each jump was in the air.
    if debugMode and jumpStartedAt and grounded and not wasGrounded then
        Print(("debug: landed after %.2f s in the air"):format(GetTime() - jumpStartedAt))
        jumpStartedAt = nil
    end
    wasGrounded = grounded
end)

-- Is the breath bar draining? That only happens while under the surface.
local function IsBreathDraining()
    for i = 1, (MIRRORTIMER_NUMTIMERS or 3) do
        local timer, _, _, scale = GetMirrorTimerInfo(i)
        if timer == "BREATH" and scale and scale < 0 then return true end
    end
    return false
end

-- IsSubmerged() exists on this client but is also true at the surface, so it
-- can't tell the two apart. The breath bar draining is the reliable signal.
local function IsUnderwater()
    return IsBreathDraining()
end

local function OnJump()
    if debugMode then
        Print(("debug: falling=%s swimming=%s grounded=%s breath=%s - %.2f s since last counted jump"):format(
            tostring(IsFalling()), tostring(IsSwimming()), tostring(wasGrounded),
            tostring(IsBreathDraining()), GetTime() - lastJumpTime))
    end
    if UnitOnTaxi("player") or IsFlying() then return end
    local now = GetTime()
    local inWater = wasSwimming or IsSwimming()
    if inWater then
        -- Pressing jump underwater just swims upward; only surface hops count.
        if IsUnderwater() then return end
        -- The surface can still be spammed, so allow at most one jump per
        -- SWIM_JUMP_COOLDOWN (about one real jump's length).
        if now - lastJumpTime < SWIM_JUMP_COOLDOWN then return end
    else
        -- On land: only count jumps that start from the ground (no mid-air spam).
        if not wasGrounded then return end
        wasGrounded = false
        if debugMode then jumpStartedAt = now end
        -- Too soon after the last counted jump to be a full jump.
        if now - lastJumpTime < JUMP_MIN_INTERVAL then return end
    end
    lastJumpTime = now

    charData.total = charData.total + 1
    sessionJumps = sessionJumps + 1
    charData.rate.jumps = charData.rate.jumps + 1
    local wid = CurrentWeekId()
    if wid then
        if charData.weekId ~= wid then
            charData.weekId = wid
            charData.week = 0
        end
        charData.week = charData.week + 1
    end
    dirty = true
    UpdateCounter()
    RefreshBoardSoon()
    CheckMyNotifications(Me().total)
    DuelOnJump()
    TrackJump(inWater)
end

---------------------------------------------------------------------------
-- Main window: everything in one place.
--   Header   - your name, prestige, jump level, rank, XP bar, Prestige button
--   Stats    - total jumps, this week, per hour, deaths, challenges, position
--   Tabs     - Leaderboard | Challenges | Settings
---------------------------------------------------------------------------
local mainFrame
local optionsCategory, optionsPanel

local function SetCounterShown(shown)
    JumpCounterDB.ui.shown = shown
    counterFrame:SetShown(shown)
end

---------------------------------------------------------------------------
-- Minimap button: click to open, right-click for settings, drag to move it
-- around the minimap edge.
---------------------------------------------------------------------------
local minimapButton
local MINIMAP_ICON = GetMetadata(ADDON_NAME, "IconTexture") or "Interface\\Icons\\Ability_Rogue_Sprint"

local function PlaceMinimapButton()
    local angle = math.rad(JumpCounterDB.ui.minimapAngle or 200)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
    if not Minimap then return end
    local b = CreateFrame("Button", "JumpCounterMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(MINIMAP_ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button) JumpCounter_OnAddonCompartmentClick(nil, button) end)
    b:SetScript("OnEnter", function(self)
        JumpCounter_OnAddonCompartmentEnter(nil, self)
        GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    -- Dragging moves the button along the minimap edge.
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            JumpCounterDB.ui.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
            PlaceMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    minimapButton = b
    PlaceMinimapButton()
    b:SetShown(settings.minimapButton)
end

local function SetMinimapShown(shown)
    settings.minimapButton = shown
    if minimapButton then minimapButton:SetShown(shown) end
end

local GRAY = "|cff999999%s|r"

local function Fmt(n) return BreakUpLargeNumbers(math.floor((n or 0) + 0.5)) end

-- A flat button with hover highlight and a gold underline when selected.
local function FlatButton(parent, width, height, label, font)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    local text = b:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetPoint("CENTER", 0, 1)
    text:SetText(label)
    local line = b:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(2)
    line:SetColorTexture(1, 0.82, 0, 1)
    function b:SetSelected(selected)
        line:SetShown(selected)
        bg:SetColorTexture(1, 1, 1, selected and 0.10 or 0.04)
        if selected then text:SetTextColor(1, 0.82, 0) else text:SetTextColor(0.85, 0.85, 0.85) end
    end
    b:SetSelected(false)
    return b
end

-- A stat tile: small gray label, big value, optional small line under it.
local function StatTile(parent, label)
    local t = CreateFrame("Frame", nil, parent)
    local bg = t:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.label:SetPoint("TOP", 0, -6)
    t.label:SetText(label)
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    t.value:SetPoint("TOP", t.label, "BOTTOM", 0, -3)
    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.sub:SetPoint("TOP", t.value, "BOTTOM", 0, -2)
    return t
end

local function ProgressBar(parent, height, r, g, b)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(r, g, b)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.55)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", 0, 0)
    return bar
end

-- Next rank above a total: title, threshold (or nil at the top).
local function NextJumpRank(total)
    for _, r in ipairs(JUMP_RANKS) do
        if total < r[1] then return r[2], r[1] end
    end
end

-- Hover tooltip for a player on the leaderboard.
local function ShowEntryTooltip(owner, entry)
    local data = entry.data or {}
    local isMe = entry.key == playerKey
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ColoredName(entry.key, entry.class))
    local title = GetJumpRank(entry.total)
    GameTooltip:AddLine(("%sJump level %d%s"):format(PrestigeTag(EntryPrestige(data)), (EntryLevel(data)),
        title and (" - " .. title) or ""), 1, 0.82, 0)

    local function line(label, value) GameTooltip:AddDoubleLine(label, value, 0.75, 0.75, 0.75, 1, 1, 1) end
    local charLevel = isMe and UnitLevel("player") or data.charLevel
    if data.faction then line("Faction", FactionIcon(data.faction) .. FACTION_NAMES[data.faction]) end
    line("Character level", charLevel and tostring(charLevel) or "?")
    line("Total jumps", Fmt(entry.total))
    line("This week", Fmt(MyWeekCount(data)))
    local jph = JumpsPerHour(data)
    line("Jumps per hour", jph and Fmt(jph) or (isMe and "after 30 min online" or "?"))
    line("Deaths", data.deaths and Fmt(data.deaths) or "?")
    local challenges = isMe and CountCompleted(acct) or data.challenges
    line("Challenges", challenges and ("%d / %d"):format(challenges, #CHALLENGES) or "?")
    local duelWins = isMe and (acct.duelWins or 0) or data.duelWins
    if isMe then
        line("Jump duels", ("%d won, %d lost, %d draws"):format(acct.duelWins or 0,
            acct.duelLosses or 0, acct.duelDraws or 0))
    elseif duelWins then
        line("Jump duels won", tostring(duelWins))
    end

    -- Characters on the account (from 1.1.0; older versions count one character).
    local chars
    if isMe then
        chars = MyCharacters()
    elseif data.characters then
        chars = ParseCharacters(data.characters)
    end
    if chars and #chars > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("Characters (%d)"):format(#chars), 1, 0.82, 0)
        for i, c in ipairs(chars) do
            if i > 10 then
                GameTooltip:AddLine(("...and %d more"):format(#chars - 10), 0.6, 0.6, 0.6)
                break
            end
            local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
            local name = (color and color.WrapTextInColorCode) and color:WrapTextInColorCode(c.name) or c.name
            GameTooltip:AddDoubleLine("  " .. name, Fmt(c.total), 1, 1, 1, 1, 1, 1)
        end
    elseif not isMe and not data.acct then
        GameTooltip:AddLine("Only this character (older version)", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")

    local version = isMe and VERSION or data.version
    if not version then
        GameTooltip:AddDoubleLine("Addon version", "older than 0.7", 0.75, 0.75, 0.75, 1, 0.3, 0.3)
    elseif IsNewerVersion(VERSION, version) then
        GameTooltip:AddDoubleLine("Addon version", "v" .. version .. " (outdated)", 0.75, 0.75, 0.75, 1, 0.3, 0.3)
    else
        GameTooltip:AddDoubleLine("Addon version", "v" .. version, 0.75, 0.75, 0.75, 0.3, 1, 0.3)
    end
    if not isMe and data.seen then
        local ago = time() - data.seen
        line("Last update", (ago < 60 and "just now" or (FormatDuration(ago) .. " ago"))
            .. ((data.hops or 0) > 0 and " (via friends)" or ""))
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Leaderboard tab
---------------------------------------------------------------------------
local BOARD_CATEGORIES = {
    { mode = "all",    label = "All time" },
    { mode = "week",   label = "This week" },
    { mode = "rate",   label = "Per hour" },
    { mode = "level",  label = "Level" },
    { mode = "deaths", label = "Deaths" },
}

local function BuildLeaderboardTab(page, width)
    local ROW_H = 18
    local ROWS = BOARD_ROWS
    local listTop = -30
    local listHeight = ROWS * ROW_H

    local cats = {}
    local catWidth = math.floor((width - 4 * 4) / #BOARD_CATEGORIES)
    for i, c in ipairs(BOARD_CATEGORIES) do
        local b = FlatButton(page, catWidth, 20, c.label)
        b:SetPoint("TOPLEFT", (i - 1) * (catWidth + 4), 0)
        b:SetScript("OnClick", function()
            JumpCounterDB.ui.boardMode = c.mode
            page.scrollOffsetReset = true
            page:Refresh()
        end)
        cats[c.mode] = b
    end

    -- Column headers.
    local function Header(text, point, x, justify)
        local h = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        h:SetPoint(point, x, -24 + 0)
        h:SetJustifyH(justify)
        h:SetText(text)
        return h
    end
    Header("#", "TOPLEFT", 14, "RIGHT")
    Header("Player", "TOPLEFT", 48, "LEFT")
    Header("Level & rank", "TOPLEFT", 222, "LEFT")
    local scoreHeader = Header("Jumps", "TOPRIGHT", -30, "RIGHT")

    local function MakeRow(y)
        local row = {}
        row.hover = CreateFrame("Button", nil, page)
        row.hover:SetPoint("TOPLEFT", 0, y + 2)
        row.hover:SetPoint("TOPRIGHT", -24, y + 2)
        row.hover:SetHeight(ROW_H)
        local hl = row.hover:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.bg = row.hover:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        row.rank = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.rank:SetPoint("TOPLEFT", 0, y)
        row.rank:SetWidth(30)
        row.rank:SetJustifyH("RIGHT")
        row.name = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", 48, y)
        row.name:SetWidth(168)
        row.name:SetWordWrap(false)
        row.name:SetJustifyH("LEFT")
        row.level = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.level:SetPoint("TOPLEFT", 222, y - 1)
        row.level:SetWidth(width - 222 - 110)
        row.level:SetWordWrap(false)
        row.level:SetJustifyH("LEFT")
        row.score = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.score:SetPoint("TOPRIGHT", -30, y)
        row.score:SetJustifyH("RIGHT")

        row.hover:SetScript("OnEnter", function(self)
            if row.entry then ShowEntryTooltip(self, row.entry) end
        end)
        row.hover:SetScript("OnLeave", GameTooltip_Hide)

        function row:Set(pos, entry, mode)
            row.entry = entry
            row.hover:SetShown(entry ~= nil)
            if not entry then
                row.rank:SetText(""); row.name:SetText(""); row.level:SetText(""); row.score:SetText("")
                return
            end
            local isMe = entry.key == playerKey
            row.bg:SetColorTexture(1, 0.82, 0, isMe and 0.12 or 0)
            row.rank:SetText(pos and (pos .. ".") or "")
            row.name:SetText(FactionIcon((entry.data or {}).faction) .. ColoredName(entry.key, entry.class))
            local data = entry.data or {}
            local rankTitle = GetJumpRank(entry.total)
            row.level:SetText(("%sLv %d %s"):format(PrestigeTag(EntryPrestige(data)), (EntryLevel(data)),
                GRAY:format(rankTitle or "")))
            if mode == "level" then
                row.score:SetText(Fmt(entry.score) .. " XP")
            elseif mode == "rate" then
                local jph = JumpsPerHour(data)
                row.score:SetText(jph and (Fmt(jph) .. "/h") or "-")
            else
                row.score:SetText(Fmt(entry.score))
            end
        end
        return row
    end

    page.rows = {}
    for i = 1, ROWS do
        page.rows[i] = MakeRow(listTop - 10 - (i - 1) * ROW_H)
    end

    local scroll = CreateFrame("ScrollFrame", "JumpCounterMainBoardScroll", page, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, listTop - 8)
    scroll:SetPoint("BOTTOMRIGHT", page, "TOPRIGHT", -24, listTop - 8 - listHeight)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() page:Update() end)
    end)
    local bar = scroll.ScrollBar or _G["JumpCounterMainBoardScrollScrollBar"]
    for _, row in ipairs(page.rows) do
        row.hover:SetFrameLevel(scroll:GetFrameLevel() + 2)
        row.hover:EnableMouseWheel(true)
        row.hover:SetScript("OnMouseWheel", function(_, delta)
            if bar then bar:SetValue(bar:GetValue() - delta * ROW_H * 3) end
        end)
    end

    -- Your own row, always visible under the list.
    local divider = page:CreateTexture(nil, "ARTWORK")
    page.divider = divider
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 0, listTop - 12 - listHeight)
    divider:SetPoint("TOPRIGHT", -24, listTop - 12 - listHeight)
    page.meRow = MakeRow(listTop - 18 - listHeight)

    page.footer = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.footer:SetPoint("BOTTOMLEFT", 0, 0)

    function page:Update()
        local list = self.list or {}
        FauxScrollFrame_Update(scroll, #list, ROWS, ROW_H)
        local offset = FauxScrollFrame_GetOffset(scroll)
        for i, row in ipairs(self.rows) do
            row:Set(i + offset, list[i + offset], self.mode)
        end

        -- Pinned "you" row: only when your own row is scrolled out of view.
        local pos = self.myPos
        local visible = pos and pos > offset and pos <= offset + ROWS
        local showPinned = pos ~= nil and not visible
        self.meRow:Set(showPinned and pos or nil, showPinned and self.myEntry or nil, self.mode)
        self.divider:SetShown(showPinned)
    end

    function page:Refresh()
        local mode = JumpCounterDB.ui.boardMode or "all"
        self.mode = mode
        for m, b in pairs(cats) do b:SetSelected(m == mode) end
        scoreHeader:SetText(({ all = "Jumps", week = "This week", rate = "Per hour",
            level = "Total XP", deaths = "Deaths" })[mode] or "")

        if self.scrollOffsetReset then
            self.scrollOffsetReset = nil
            FauxScrollFrame_SetOffset(scroll, 0)
            if bar then bar:SetValue(0) end
        end
        self.list = BuildStandings(mode)
        self.myPos, self.myEntry = nil, nil
        for i, entry in ipairs(self.list) do
            if entry.key == playerKey then self.myPos, self.myEntry = i, entry break end
        end
        self:Update()

        local count = #self.list .. (#self.list == 1 and " player" or " players")
        local note = ({
            week = SecondsUntilReset() and ("week resets in " .. FormatDuration(SecondsUntilReset()))
                or "weeks start Monday 00:00 UTC",
            rate = "online time, not AFK, shown after 30 min",
            level = "XP = jumps + challenge rewards",
            deaths = "deaths counted since v0.7.0",
        })[mode] or "syncs with guild, group & friends - hover a player for details"
        self.footer:SetText(count .. "  -  " .. note)
    end
end

---------------------------------------------------------------------------
-- Challenges tab
---------------------------------------------------------------------------
local function BuildChallengesTab(page, width)
    local ROW_H = 44
    local summary = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", 0, -2)

    local scroll = CreateFrame("ScrollFrame", "JumpCounterMainChallengeScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -20)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 28, #CHALLENGES * ROW_H)
    scroll:SetScrollChild(content)

    local rows = {}
    for i, c in ipairs(CHALLENGES) do
        local r = CreateFrame("Frame", nil, content)
        r:SetSize(width - 32, ROW_H - 4)
        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("TOPLEFT", 6, -4)
        r.reward = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.reward:SetPoint("TOPRIGHT", -6, -5)
        r.desc = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.desc:SetPoint("TOPLEFT", 6, -18)
        r.desc:SetText(c.desc)
        r.bar = ProgressBar(r, 8, 1, 0.7, 0)
        r.bar:SetPoint("BOTTOMLEFT", 6, 4)
        r.bar:SetPoint("BOTTOMRIGHT", -150, 4)
        r.bar:SetMinMaxValues(0, c.goal)
        r.bar.text:Hide()
        r.status = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.status:SetPoint("BOTTOMRIGHT", -6, 2)
        r.challenge = c
        rows[i] = r
    end

    function page:Refresh()
        summary:SetText(("%d of %d challenges complete - %s bonus XP earned")
            :format(CountCompleted(acct), #CHALLENGES, Fmt(acct.challengeXP)))

        -- Unfinished first (closest to done at the top), finished at the bottom.
        local order = {}
        for _, r in ipairs(rows) do
            local c = r.challenge
            local done = acct.done[c.id]
            r.sortKey = done and (2 + 1 / done) or (1 - math.min(c.progress(), c.goal) / c.goal)
            table.insert(order, r)
        end
        table.sort(order, function(a, b) return a.sortKey < b.sortKey end)

        for i, r in ipairs(order) do
            local c = r.challenge
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            local done = acct.done[c.id]
            local p = math.min(c.progress(), c.goal)
            r.reward:SetText("+" .. Fmt(c.xp) .. " XP")
            if done then
                r.name:SetText("|cff33ff33" .. c.name .. "|r")
                r.bar:SetValue(c.goal)
                r.bar:SetStatusBarColor(0.2, 0.8, 0.2)
                r.status:SetText("|cff33ff33Complete|r " .. GRAY:format(date("%Y-%m-%d", done)))
            else
                r.name:SetText(c.name)
                r.bar:SetValue(p)
                r.bar:SetStatusBarColor(1, 0.7, 0)
                r.status:SetText(("%s / %s"):format(Fmt(p), Fmt(c.goal)))
            end
        end
    end
end

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildSettingsTab(page, width)
    local checks = {}
    local col, y = 0, -4
    local colWidth = math.floor(width / 2)

    local function Section(text)
        if col == 1 then col, y = 0, y - 26 end
        y = y - 6
        local s = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s:SetPoint("TOPLEFT", 0, y)
        s:SetText(text)
        y = y - 20
    end

    local function AddCheck(label, tooltip, get, set)
        local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", col * colWidth, y)
        local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        text:SetWidth(colWidth - 32)
        text:SetJustifyH("LEFT")
        text:SetText(label)
        cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(label)
            GameTooltip:AddLine(tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
        cb.get = get
        table.insert(checks, cb)
        if col == 0 then col = 1 else col, y = 0, y - 26 end
    end

    local function SettingCheck(key, label, tooltip)
        AddCheck(label, tooltip, function() return settings[key] end, function(v) settings[key] = v end)
    end

    Section("On screen")
    AddCheck("Show minimap button", "The JumpCounter button on the edge of the minimap. "
        .. "Click it to open JumpCounter, right-click for settings, drag to move it.",
        function() return settings.minimapButton end, SetMinimapShown)
    AddCheck("Show jump counter on screen", "The small movable window with your total.",
        function() return JumpCounterDB.ui.shown end, SetCounterShown)
    AddCheck("Lock counter position", "Stop the counter window from being dragged.",
        function() return JumpCounterDB.ui.locked end, function(v) JumpCounterDB.ui.locked = v end)

    Section("Messages about you")
    SettingCheck("myMilestones", "My milestones",
        "A chat message at 100, 500 and every 1,000 jumps. 1,000 and every 5,000 also flash on screen.")
    SettingCheck("myProgress", "My level-ups and challenges",
        "A chat line when your jump level goes up, and a big announcement when you complete a challenge.")
    SettingCheck("myDeaths", "Tell me when I die", "A short chat line with your death count. Only you see it.")

    Section("Messages about others")
    SettingCheck("friendRankUps", "Friends' ranks and prestige",
        "A chat message when someone on your leaderboard earns a jump rank or prestiges.")
    SettingCheck("friendMilestones", "All friends' milestones",
        "Also a chat message at every friend's 100, 500 and every 1,000 jumps. Busy in a big guild.")
    SettingCheck("overtakes", "Overtakes",
        "When you pass someone on the leaderboard or they pass you (at most once per person every 10 min).")

    Section("Jump duels & sound")
    SettingCheck("duels", "Random jump duels",
        "Now and then you're paired with another player who is jumping around for a 2-minute "
        .. "jump-off. Most jumps wins. At most one random duel every 30 minutes.")
    SettingCheck("duelNews", "Other players' duel results",
        "A chat line with the result when two other players finish a jump duel.")
    SettingCheck("sounds", "Play sounds", "Play a sound with milestone and overtake messages.")

    local help = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("BOTTOMLEFT", 0, 0)
    help:SetPoint("BOTTOMRIGHT", 0, 0)
    help:SetJustifyH("LEFT")
    help:SetText("Open this window with /jumps or from the addon menu by the minimap. "
        .. "/jumps help lists all commands. Version " .. VERSION .. ".")

    function page:Refresh()
        for _, cb in ipairs(checks) do cb:SetChecked(cb.get()) end
    end
end

---------------------------------------------------------------------------
-- The window itself
---------------------------------------------------------------------------
local TABS = {
    { id = "board",      label = "Leaderboard", build = BuildLeaderboardTab },
    { id = "challenges", label = "Challenges",  build = BuildChallengesTab },
    { id = "settings",   label = "Settings",    build = BuildSettingsTab },
}

local function CreateMainFrame()
    local W, H = 600, 600
    local PAD = 16
    local innerW = W - PAD * 2

    local f = CreateFrame("Frame", "JumpCounterMain", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.94)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:Hide()
    MakeMovable(f)
    tinsert(UISpecialFrames, "JumpCounterMain")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local appName = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    appName:SetPoint("TOPLEFT", PAD, -12)
    appName:SetText("JumpCounter " .. GRAY:format("v" .. VERSION))

    -- Header: who you are and your level.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", PAD, -34)
    header:SetSize(innerW, 74)
    local hbg = header:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(1, 1, 1, 0.05)

    local nameText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    nameText:SetPoint("TOPLEFT", 10, -8)
    local levelText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    levelText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -4)
    local nextRankText = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nextRankText:SetPoint("TOPRIGHT", -10, -12)
    nextRankText:SetJustifyH("RIGHT")

    local xpBar = ProgressBar(header, 14, 0.58, 0.2, 0.85)
    xpBar:SetPoint("BOTTOMLEFT", 10, 8)
    xpBar:SetPoint("BOTTOMRIGHT", -120, 8)

    local prestigeButton = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    prestigeButton:SetSize(100, 22)
    prestigeButton:SetPoint("BOTTOMRIGHT", -10, 4)
    prestigeButton:SetText("Prestige!")
    prestigeButton:SetScript("OnClick", function() AskPrestige() end)
    prestigeButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Prestige")
        GameTooltip:AddLine("Reset your jump level to 1 and earn a prestige star. "
            .. "Total jumps, ranks, total XP and challenges are kept.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    prestigeButton:SetScript("OnLeave", GameTooltip_Hide)
    local prestigeInfo = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    prestigeInfo:SetPoint("BOTTOMRIGHT", -10, 9)
    prestigeInfo:SetWidth(104)
    prestigeInfo:SetJustifyH("RIGHT")

    -- Stat tiles.
    local tileDefs = { "Total jumps", "This week", "Per hour", "Deaths", "Challenges", "Leaderboard" }
    local tiles = {}
    local gap = 6
    local tileW = (innerW - gap * (#tileDefs - 1)) / #tileDefs
    for i, label in ipairs(tileDefs) do
        local t = StatTile(f, label)
        t:SetSize(tileW, 58)
        t:SetPoint("TOPLEFT", PAD + (i - 1) * (tileW + gap), -116)
        tiles[i] = t
    end

    -- Tabs.
    local tabButtons, pages = {}, {}
    local tabW = 120
    local contentTop = -218
    for i, tab in ipairs(TABS) do
        local b = FlatButton(f, tabW, 24, tab.label, "GameFontHighlight")
        b:SetPoint("TOPLEFT", PAD + (i - 1) * (tabW + 4), -184)
        b:SetScript("OnClick", function() f:ShowTab(tab.id) end)
        tabButtons[tab.id] = b

        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", PAD, contentTop)
        page:SetPoint("BOTTOMRIGHT", -PAD, PAD)
        page:Hide()
        tab.build(page, innerW)
        pages[tab.id] = page
    end
    local tabLine = f:CreateTexture(nil, "ARTWORK")
    tabLine:SetColorTexture(1, 1, 1, 0.15)
    tabLine:SetHeight(1)
    tabLine:SetPoint("TOPLEFT", PAD, -208)
    tabLine:SetPoint("TOPRIGHT", -PAD, -208)

    function f:ShowTab(id)
        JumpCounterDB.ui.mainTab = id
        for tid, page in pairs(pages) do
            page:SetShown(tid == id)
            tabButtons[tid]:SetSelected(tid == id)
        end
        if id == "board" then RequestScores() end
        pages[id]:Refresh()
    end

    function f:RefreshHeader()
        local newer = NewestVersion()
        appName:SetText("JumpCounter " .. GRAY:format("v" .. VERSION)
            .. (newer and ("   |cffff5555Update available: v%s - /jumps update|r"):format(newer) or ""))
        local me = Me()
        local prestige = EntryPrestige(me)
        nameText:SetText(PrestigeTag(prestige) .. FactionIcon(MyFaction()) .. ColoredName(playerKey, charData.class))
        local level, into, need = EntryLevel(me)
        local rankTitle = GetJumpRank(me.total)
        levelText:SetText(("Jump level |cffffd100%d|r   %s"):format(level,
            rankTitle and ("|cffffd100" .. rankTitle .. "|r") or GRAY:format("no rank yet")))
        local nextTitle, nextAt = NextJumpRank(me.total)
        nextRankText:SetText(nextTitle
            and ("Next rank: |cffffffff%s|r\nat %s jumps (%s to go)"):format(nextTitle, Fmt(nextAt), Fmt(nextAt - me.total))
            or "Highest rank reached!")

        xpBar:SetMinMaxValues(0, need)
        xpBar:SetValue(into)
        xpBar.text:SetText(("%s / %s XP to level %d"):format(Fmt(into), Fmt(need), level + 1))

        if CanPrestige() then
            prestigeButton:Show()
            prestigeInfo:Hide()
        else
            prestigeButton:Hide()
            prestigeInfo:Show()
            prestigeInfo:SetText(("Prestige at level %d%s"):format(PRESTIGE_LEVEL,
                prestige > 0 and ("\n" .. PrestigeTag(prestige) .. "earned") or ""))
        end

        tiles[1].value:SetText(Fmt(me.total))
        local numChars = CountKeys(JumpCounterDB.chars)
        tiles[1].sub:SetText(numChars > 1 and ("%d characters"):format(numChars)
            or ("this session: " .. Fmt(sessionJumps)))
        tiles[2].value:SetText(Fmt(MyWeekCount(me)))
        local secs = SecondsUntilReset()
        tiles[2].sub:SetText(secs and ("resets in " .. FormatDuration(secs)) or "")
        local jph = JumpsPerHour(me)
        tiles[3].value:SetText(jph and Fmt(jph) or "-")
        tiles[3].sub:SetText(jph and "jumps / hour"
            or ("%d / 30 min online"):format(math.floor(me.rate.seconds / 60)))
        tiles[4].value:SetText(Fmt(me.deaths))
        tiles[4].sub:SetText(("%s jumps since"):format(Fmt(acct.stats.sinceDeath)))
        tiles[5].value:SetText(("%d / %d"):format(CountCompleted(acct), #CHALLENGES))
        tiles[5].sub:SetText("+" .. Fmt(acct.challengeXP) .. " XP")
        local list = BuildStandings("all")
        local pos = MyRank()
        tiles[6].value:SetText(pos and ("#" .. pos) or "-")
        tiles[6].sub:SetText(("of %d players"):format(#list))
    end

    function f:Refresh()
        self:RefreshHeader()
        local id = JumpCounterDB.ui.mainTab or "board"
        if pages[id] and pages[id]:IsShown() then pages[id]:Refresh() end
    end

    f:SetScript("OnShow", function(self)
        self:ShowTab(JumpCounterDB.ui.mainTab or "board")
        self:RefreshHeader()
    end)

    mainFrame = f
    -- Older code refreshes these; they're all the main window now.
    boardFrame = f
    challengeFrame = f
end

-- Open the main window (optionally on a given tab), or close it if it's
-- already open on that tab.
local function ToggleMain(tab)
    if not mainFrame then return end
    if mainFrame:IsShown() and (not tab or JumpCounterDB.ui.mainTab == tab) then
        mainFrame:Hide()
        return
    end
    if tab then JumpCounterDB.ui.mainTab = tab end
    if mainFrame:IsShown() then mainFrame:ShowTab(tab) else mainFrame:Show() end
end

function ToggleChallenges() ToggleMain("challenges") end

local function OpenOptions() ToggleMain("settings") end

-- Esc > Options > AddOns > JumpCounter: just points to the main window.
local function CreateOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "JumpCounter"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("JumpCounter " .. GRAY:format("v" .. VERSION))

    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetWidth(520)
    text:SetJustifyH("LEFT")
    text:SetText("Everything - your stats, the leaderboard, challenges and settings - is in the "
        .. "JumpCounter window. Open it with /jumps or from the addon menu next to the minimap.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(180, 26)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    open:SetText("Open JumpCounter")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
        ToggleMain("board")
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
    optionsPanel = panel
end

---------------------------------------------------------------------------
-- Death counting
---------------------------------------------------------------------------
local lastDeathTime = -60

local function OnPlayerDead()
    -- PLAYER_DEAD can fire more than once for one death in some cases.
    local now = GetTime()
    if now - lastDeathTime < 5 then return end
    lastDeathTime = now

    charData.deaths = (charData.deaths or 0) + 1
    acct.stats.sinceDeath = 0           -- "without dying" challenges start over
    dirty = true
    UpdateCounter()
    RefreshBoardSoon()
    if settings.myDeaths then
        Print(("You died. Deaths: |cffff5555%s|r"):format(BreakUpLargeNumbers(Me().deaths)))
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_JUMPCOUNTER1 = "/jumps"
SLASH_JUMPCOUNTER2 = "/jc"
SlashCmdList.JUMPCOUNTER = function(input)
    local cmd = (input or ""):lower():match("^%s*(%S*)")
    if cmd == "" or cmd == "show" or cmd == "open" then
        ToggleMain()
    elseif cmd == "counter" or cmd == "toggle" then
        SetCounterShown(not counterFrame:IsShown())
    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        ToggleMain("settings")
    elseif cmd == "prestige" then
        AskPrestige()
    elseif cmd == "challenges" or cmd == "ch" or cmd == "level" then
        ToggleMain("challenges")
    elseif cmd == "board" or cmd == "lb" then
        ToggleMain("board")
    elseif cmd == "name" then
        -- /jumps name Zivv Pewpew  - set this character's full name by hand.
        local full = (input or ""):match("^%s*%S+%s+(.-)%s*$")
        local first = UnitName("player")
        if not full or full == "" then
            Print(("Name: %s. Set it with /jumps name %s <second name>."):format(
                charData.display or first, first))
        elseif (full:match("^(%S+)") or ""):lower() ~= first:lower() then
            Print(("The name must start with %s, e.g. /jumps name %s Pewpew."):format(first, first))
        else
            full = first .. full:sub(#first + 1)
            charData.display = full:gsub("[:,=~]", "")
            charData.nameSetByHand = true
            dirty = true
            if mainFrame and mainFrame:IsShown() then mainFrame:Refresh() end
            Print("This character is now shown as " .. charData.display .. ".")
        end
    elseif cmd == "duel" then
        DuelCommand()
    elseif cmd == "update" or cmd == "download" then
        -- The download link, newer version or not.
        local newer = NewestVersion()
        StaticPopup_Show("JUMPCOUNTER_UPDATE", newer
            and ("|cffffd100JumpCounter v%s is out!|r\nYou have v%s."):format(newer, VERSION)
            or ("You have v%s, the newest version seen so far."):format(VERSION))
    elseif cmd == "minimap" then
        SetMinimapShown(not settings.minimapButton)
        Print("Minimap button " .. (settings.minimapButton and "shown." or "hidden - /jumps minimap brings it back."))
    elseif cmd == "lock" then
        JumpCounterDB.ui.locked = not JumpCounterDB.ui.locked
        Print("Counter window " .. (JumpCounterDB.ui.locked and "locked." or "unlocked."))
    elseif cmd == "share" then
        local msg = ("I have jumped %s times!"):format(BreakUpLargeNumbers(Me().total))
        local channel = IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT"
            or IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY"
        SendChatMessage(msg, channel)
    elseif cmd == "clear" then
        wipe(JumpCounterDB.peers)
        if boardFrame:IsShown() then boardFrame:Refresh() end
        RequestScores(true)
        Print("Leaderboard cleared; asking online players for fresh scores.")
    elseif cmd == "debug" then
        debugMode = not debugMode
        Print("Debug " .. (debugMode and "on - every jump press prints its state." or "off."))
        if debugMode then
            local nWhisper, nBNet = 0, 0
            for _ in pairs(knownWhisper) do nWhisper = nWhisper + 1 end
            for _ in pairs(knownBNet) do nBNet = nBNet + 1 end
            Print(("Syncing with: channels=%s, WoW friends=%d, Battle.net WoW accounts=%d"):format(
                table.concat(GetChannels(), ","), #GetOnlineFriends(), #GetBNetGameAccounts()))
            local names = {}
            for _, c in ipairs(NameCandidates()) do
                table.insert(names, c.label .. "=" .. tostring(c.value))
            end
            Print("Name sources: " .. table.concat(names, ", ") .. " - saved: " .. tostring(charData.display)
                .. (charData.nameSetByHand and " (set by hand)" or ""))
            Print(("Friends confirmed using JumpCounter: whisper=%d, Battle.net=%d. Queued messages: %d")
                :format(nWhisper, nBNet, #sendQueue))
        end
    elseif cmd == "version" then
        -- Your version, plus who on the leaderboard is on an older one.
        local newest, outdated = VERSION, {}
        for _, data in pairs(JumpCounterDB.peers) do
            if data.version and IsNewerVersion(data.version, newest) then newest = data.version end
        end
        for key, data in pairs(JumpCounterDB.peers) do
            if not data.version or IsNewerVersion(newest, data.version) then
                table.insert(outdated, ("%s (%s)"):format(DisplayName(key), data.version or "<0.7"))
            end
        end
        Print("You have v" .. VERSION .. (newest ~= VERSION
            and (" - |cffff5555v" .. newest .. " is out!|r Get it at " .. DOWNLOAD_URL) or " (newest seen)"))
        if #outdated > 0 then
            table.sort(outdated)
            Print("Players on older versions: " .. table.concat(outdated, ", "))
        end
    elseif cmd == "reset" then
        charData.total = 0
        sessionJumps = 0
        dirty = true
        UpdateCounter()
        Print("Jump count reset for this character (" .. playerKey .. ").")
    elseif cmd == "help" or cmd == "?" then
        local me = Me()
        local title = GetJumpRank(me.total)
        Print("v" .. VERSION .. " - Total jumps: " .. BreakUpLargeNumbers(me.total)
            .. " (this week: " .. MyWeekCount(me) .. ", this session: " .. sessionJumps .. ")"
            .. (title and (" - " .. title) or "")
            .. " - Deaths: " .. BreakUpLargeNumbers(me.deaths))
        Print("/jumps - open the JumpCounter window (stats, leaderboard, challenges, settings)")
        Print("/jumps board | challenges | settings - open the window on that tab")
        Print("/jumps counter - show/hide the small on-screen counter")
        Print(("/jumps prestige - reset your jump level at level %d for a prestige star"):format(PRESTIGE_LEVEL))
        Print("/jumps name <full name> - set this character's full name (if only the first shows)")
        Print("/jumps duel - challenge a random player who is jumping right now")
        Print("/jumps update - the download link for the newest version")
        Print("/jumps minimap - show/hide the minimap button")
        Print("/jumps lock - lock/unlock counter position")
        Print("/jumps share - announce your jumps in chat")
        Print("/jumps clear - remove other players from your leaderboard")
        Print("/jumps version - your version and who is on an older one")
        Print("/jumps reset - reset this character's jump count (others on the account keep theirs)")
        Print("Scores sync with your guild, group and online WoW friends.")
    else
        Print("Unknown command - type /jumps help.")
    end
end

-- Addon compartment (the addon menu button by the minimap)
function JumpCounter_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then
        ToggleMain("settings")
    else
        ToggleMain()
    end
end

function JumpCounter_OnAddonCompartmentEnter(_, frame)
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine("JumpCounter", "v" .. VERSION, 1, 0.82, 0, 0.6, 0.6, 0.6)
    if charData then
        local me = Me()
        GameTooltip:AddLine("Deaths: " .. BreakUpLargeNumbers(me.deaths), 1, 1, 1)
        GameTooltip:AddLine("Total jumps: " .. BreakUpLargeNumbers(me.total), 1, 1, 1)
        GameTooltip:AddLine("This week: " .. BreakUpLargeNumbers(MyWeekCount(me)), 1, 1, 1)
        local jph = JumpsPerHour(me)
        GameTooltip:AddLine("Jumps per hour: " .. (jph and BreakUpLargeNumbers(math.floor(jph + 0.5))
            or ("after 30 min online (%d so far)"):format(math.floor(me.rate.seconds / 60))), 1, 1, 1)
        local title = GetJumpRank(me.total)
        if title then GameTooltip:AddLine("Rank: " .. title, 1, 0.82, 0) end
        local level, into, need = EntryLevel(me)
        GameTooltip:AddLine(("%sJump level %d (%s / %s XP)"):format(PrestigeTag(EntryPrestige(me)), level,
            BreakUpLargeNumbers(into), BreakUpLargeNumbers(need)), 1, 0.82, 0)
        GameTooltip:AddLine(("Challenges: %d / %d"):format(CountCompleted(acct), #CHALLENGES), 1, 1, 1)
    end
    GameTooltip:AddLine("Click: open JumpCounter", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function JumpCounter_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
pcall(events.RegisterEvent, events, "BN_CHAT_MSG_ADDON")   -- may not exist on every client
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_DEAD")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        InitDB()
        PruneStalePeers()
        -- Updated since we last saw a newer version? Then forget it.
        if JumpCounterDB.newestVersion and not NewestVersion() then JumpCounterDB.newestVersion = nil end
        C_Timer.After(5, ShowUpdateNotice)
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        CreateCounterFrame()
        CreateMainFrame()
        CreateOptionsPanel()
        CreateMinimapButton()
        knownLevel = EntryLevel(Me())
        LearnMyNameFromUnit()
        -- Stats combined from several characters (or new challenges) may
        -- already be finished.
        UpdateDerivedStats()
        CheckChallenges()
        hooksecurefunc("JumpOrAscendStart", OnJump)
        Print(("v%s loaded - type /jumps to open."):format(VERSION))

        CreateDuelFrame()
        C_Timer.NewTicker(60, MaybeStartRandomDuel)
        -- Pass scores from outside the guild on to the guild now and then
        -- (random delay so guild members don't all send at once).
        C_Timer.NewTicker(RELAY_GUILD_INTERVAL, function()
            C_Timer.After(math.random() * 120, RelayTick)
        end)

        C_Timer.NewTicker(BROADCAST_INTERVAL, function()
            if dirty then BroadcastScore() end
        end)

        -- Online time for jumps per hour. Time flagged AFK doesn't count, and
        -- a single step is capped so a frozen client can't add a big chunk.
        local lastTick = GetTime()
        C_Timer.NewTicker(10, function()
            local now = GetTime()
            local dt = math.min(now - lastTick, 30)
            lastTick = now
            if not UnitIsAFK("player") then
                local before = JumpsPerHour(Me())
                charData.rate.seconds = charData.rate.seconds + dt
                -- Share the rate once it first becomes available.
                if not before and JumpsPerHour(Me()) then dirty = true end
            end
        end)
        -- Announce ourselves and ask friends/group for their scores shortly
        -- after login. Spread over a random delay so a guild logging in after
        -- a server restart doesn't all send at once.
        C_Timer.After(8 + math.random() * 6, function()
            -- Whisper ourselves once: the reply shows our full name.
            LearnMyNameFromUnit()
            local guid = UnitGUID("player")
            if guid then Enqueue("ME:" .. guid, "WHISPER", UnitName("player")) end
            BroadcastScore(true)
            RequestScoresAtLogin()
        end)
    elseif event == "CHAT_MSG_ADDON" then
        if charData then OnAddonMessage(...) end
    elseif event == "BN_CHAT_MSG_ADDON" then
        if charData then OnBNetAddonMessage(...) end
    elseif event == "PLAYER_DEAD" then
        if charData then OnPlayerDead() end
    elseif event == "PLAYER_LEVEL_UP" then
        if charData then dirty = true end   -- share the new character level

    elseif event == "GROUP_ROSTER_UPDATE" then
        if charData then dirty = true end   -- share with new group members on next tick
    end
end)
