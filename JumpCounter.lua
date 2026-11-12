-- JumpCounter: counts your jumps and shares totals with your guild and friends
-- who also run the addon, so you can compete on a leaderboard.

local ADDON_NAME = ...
local PREFIX = "JumpCounter"      -- addon message prefix (max 16 chars)
local BROADCAST_INTERVAL = 30     -- seconds between automatic score broadcasts
-- A normal jump on flat ground keeps you in the air for about 0.82 s (jump
-- speed ~7.96 yd/s, gravity ~19.29 yd/s^2). Running uphill you land sooner:
-- ~0.70 s on a 10 degree slope, ~0.55 s at 20 degrees. Counted jumps on land
-- must be at least this far apart (and you must have landed in between), so
-- tiny hops (e.g. jumping into a wall and getting "stuck") can't be spammed,
-- while real jumps up a hill still count.
local JUMP_MIN_INTERVAL = 0.5
local SWIM_JUMP_COOLDOWN = 0.6    -- min seconds between counted jumps in water
local PEER_EXPIRY_DAYS = 14       -- drop players not heard from in this long (60 before 1.8.10)
local BOARD_ROWS = 15             -- visible rows; the list scrolls

local playerKey                   -- "Name-Realm" of the current character
local charData                    -- JumpCounterDB.chars[playerKey]
local acct                        -- JumpCounterDB.account: progress shared by all your characters
local sessionJumps = 0
local lastJumpTime = 0
local dirty = false               -- total changed since last broadcast
local lastReplyTime = 0
local heardThisSession = {}       -- [account id or key] = true once we've had their score

local counterFrame, boardFrame
local ScoreMessage                -- defined in the networking section
local OnPeerScore                 -- defined in the notifications section
local ToggleChallenges            -- defined in the progression section
local CheckChallenges             -- defined in the progression section
local OnDuelMessage               -- defined in the jump duels section
local ShowUpdateWindow            -- defined after the counter window
local CrownTick                   -- defined in the crown section
local crownKey                    -- leaderboard key of whoever holds the crown this hour
local settings                    -- JumpCounterDB.settings

local DEFAULT_SETTINGS = {
    myMilestones = true,          -- chat message when you hit a milestone
    friendRankUps = true,         -- chat message when a friend earns a jump rank
    friendMilestones = false,     -- ...and also at every friend's 100/500/1,000s
    friendLevels = true,          -- chat message when a friend's character levels up (30+)
    overtakes = true,             -- chat message when you pass / get passed
    myDeaths = true,              -- short chat line (only to you) when you die
    duels = true,                 -- take part in random jump duels
    duelNews = true,              -- chat line with the result of other players' duels
    crownNews = true,             -- chat line when the crown changes hands / is won
    myProgress = true,            -- jump level-ups and completed challenges
    sounds = false,               -- off by default; can be enabled in options
    minimapButton = true,         -- JumpCounter button on the minimap edge
}

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = GetMetadata(ADDON_NAME, "Version") or "0"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Jumps|r: " .. msg)
end

-- In combat (boss fights especially) the game hides some values from addons
-- ("secret values"): testing, comparing or doing math on one is an error.
-- Plain(v) gives nil for a hidden value, so it's treated as unknown.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
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
-- Update notice: when someone with a newer version is seen, one short chat
-- line - once per session for each version (1.8.10: so a second release on
-- the same day is announced too, not only the first). The newest version
-- seen is saved, so it also shows right after logging in. /jumps update
-- opens the window with the link.
---------------------------------------------------------------------------
-- Unlisted project: only reachable through this link.
local CURSEFORGE_URL = "https://www.curseforge.com/wow/addons/jumps"
local updateShown = false

-- The newer version we know of, or nil if we're up to date.
local function NewestVersion()
    local v = JumpCounterDB and JumpCounterDB.newestVersion
    if v and IsNewerVersion(v, VERSION) then return v end
end

local function ShowUpdateNotice()
    local v = NewestVersion()
    if not v or updateShown == v then return end
    updateShown = v                   -- the version we've told you about
    Print(("|cffffd100v%s is out|r (you have v%s) - update in the CurseForge app. "
        .. "|cff999999/jumps update for the link.|r"):format(v, VERSION))
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

-- The hour's id (whole hours since 1970, server time): the same everywhere.
local function CurrentHourId()
    return math.floor(GetServerTime() / 3600)
end

-- Jumps this hour for an entry (0 if its count is from an earlier hour).
local function HourCount(data)
    if data.hourId == CurrentHourId() then return data.hour or 0 end
    return 0
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

-- Duel ranks. 1.8.3: a rating (like chess): the winner gains what the loser
-- loses, weighted by their duel points - beating someone stronger pays more,
-- losing to them costs less. Below PROTECTED points you only gain (learning
-- the ropes), and after 3 losses in a row the next loss is free (a shield).
-- Points from before 1.8.3 (win +20, draw +10, loss +5) carry over.
-- (One table, not separate locals: Lua 5.1 allows 200 per file.)
local DUEL_POINTS = {
    win = 20, draw = 10, loss = 5,        -- the 1.8.2 rules, for converting old duels
    K = 32, scale = 400,                  -- rating: +-16 against an equal opponent
    protected = 120,                      -- Contender: no losses below this
    shieldAfter = 3,                      -- losses in a row before a free one
}

-- Points change for us: result 1 = win, 0.5 = draw, 0 = loss.
function DUEL_POINTS.Change(mine, theirs, result)
    local expected = 1 / (1 + 10 ^ (((theirs or mine) - mine) / DUEL_POINTS.scale))
    local change = DUEL_POINTS.K * (result - expected)
    change = change >= 0 and math.floor(change + 0.5) or -math.floor(-change + 0.5)
    if result == 1 then change = math.max(2, math.min(30, change)) end
    if result == 0 then change = math.min(-2, math.max(-30, change)) end
    return change
end
local DUEL_RANKS = {
    { 0,    "Unranked" },
    { 20,   "Novice Duelist" },
    { 60,   "Scrapper" },
    { 120,  "Contender" },
    { 200,  "Challenger" },
    { 320,  "Rival" },
    { 480,  "Duelist" },
    { 700,  "Champion" },
    { 1000, "Grand Champion" },
    { 1400, "Jump Gladiator" },
    { 2000, "Duel Legend" },
}

-- Duel rank for some points: title, next title, points needed for it.
local function DuelRank(points)
    local title, nextTitle, nextAt = DUEL_RANKS[1][2]
    for _, r in ipairs(DUEL_RANKS) do
        if (points or 0) >= r[1] then title = r[2] else nextTitle, nextAt = r[2], r[1] break end
    end
    return title, nextTitle, nextAt
end

-- Returns the rank title for a total, and the threshold it was earned at.
local function GetJumpRank(total)
    local title, threshold
    for _, r in ipairs(JUMP_RANKS) do
        if total >= r[1] then threshold, title = r[1], r[2] else break end
    end
    return title, threshold
end

---------------------------------------------------------------------------
-- Jump levels: XP = 1 per jump + challenge, daily, duel and crown rewards.
-- 1.8.3: going from level L to L+1 costs 60 + 3*(L-1) XP (it was
-- 50 + 25*(L-1)). 1.8.6: a prestige star needs level 100 (20,493 XP, it
-- was level 50 and 6,468 XP) - about one star every 3 to 4 weeks.
---------------------------------------------------------------------------
local function XPForLevel(level)
    return 60 + 3 * (level - 1)
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
-- 1.8.3 and 1.8.6: everyone's stars were recalculated from total XP (once,
-- when you update: PRESTIGE_MODEL). Friends still on an older version are
-- recalculated the same way on our screen, so the same XP always shows the
-- same stars and level. 1.8.6 also halved challenge rewards (and the XP of
-- challenges already done) - friends' own addons do that when they update.
local PRESTIGE_LEVEL = 100
local PRESTIGE_XP = 0
for l = 1, PRESTIGE_LEVEL - 1 do PRESTIGE_XP = PRESTIGE_XP + XPForLevel(l) end   -- 20,493
local PRESTIGE_MODEL = 3          -- 1 = old rules, 2 = level 50 (1.8.3), 3 = level 100 (1.8.6)
local PRESTIGE_SINCE = "1.8.6"    -- versions from here on send stars of the current model

-- A friend on an older version: their stars follow the old rules.
local function OldPrestigeModel(data)
    return data.version ~= nil and IsNewerVersion(PRESTIGE_SINCE, data.version)
end

-- Stars an amount of XP is worth (used for the recalculation).
local function StarsForXP(xp)
    return math.floor(math.max(0, xp or 0) / PRESTIGE_XP)
end

local function EntryPrestige(data)
    if OldPrestigeModel(data) then return StarsForXP(EntryXP(data)) end
    return data.prestige or 0
end

-- XP used up by an entry's prestige stars.
local function PrestigeSpent(data)
    if OldPrestigeModel(data) then return StarsForXP(EntryXP(data)) * PRESTIGE_XP end
    return data.prestigeSpent or EntryPrestige(data) * PRESTIGE_XP
end

-- Current jump level (after prestige resets): level, XP into it, XP needed.
local function EntryLevel(data)
    return LevelFromXP(math.max(0, EntryXP(data) - PrestigeSpent(data)))
end

-- 1.8.6: the star changes look with your prestige - a tier at 1, 3, 8 and
-- 15 stars (the same steps as the prestige challenges). The icons are our
-- own images in Media\; a game that hasn't been restarted since the update
-- that added them can't find them (see Media\Media.lua), and then every
-- star is the old gold one (the star raid marker).
-- Returns the tier's number and name.
local function PrestigeTier(n)
    n = n or 0
    if n >= 15 then return 4, "Radiant" end
    if n >= 8 then return 3, "Gold" end
    if n >= 3 then return 2, "Silver" end
    if n >= 1 then return 1, "Bronze" end
    return 0
end

local function PrestigeIcon(n)
    if not JumpCounter_MediaLoaded then
        return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"
    end
    return ("|TInterface\\AddOns\\JumpCounter\\Media\\tier%d:0|t"):format(math.max(1, (PrestigeTier(n))))
end

-- Tier star + number, or "" without prestige.
local function PrestigeTag(n)
    if not n or n <= 0 then return "" end
    return ("%s|cffffd100%d|r "):format(PrestigeIcon(n), n)
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
    { id = "mount1",  name = "Saddle Hopper",     xp = 125,  goal = 100,
      desc = "Jump 100 times while mounted.",                 progress = function() return Stat("mounted") end },
    { id = "mount2",   name = "Cavalry Bounce",    xp = 375,  goal = 1000,
      desc = "Jump 1,000 times while mounted.",               progress = function() return Stat("mounted") end },
    { id = "swim",     name = "Splash Jumper",     xp = 125,  goal = 100,
      desc = "Jump 100 times at the surface of water.",       progress = function() return Stat("swim") end },
    { id = "ghost",    name = "Ghost Hop",         xp = 125,  goal = 25,
      desc = "Jump 25 times as a ghost.",                     progress = function() return Stat("ghost") end },
    { id = "combat",   name = "Battle Bunny",      xp = 250,  goal = 250,
      desc = "Jump 250 times in combat.",                     progress = function() return Stat("combat") end },
    { id = "dungeon",  name = "Dungeon Bouncer",   xp = 250,  goal = 500,
      desc = "Jump 500 times inside dungeons or raids.",      progress = function() return Stat("instance") end },
    { id = "party",    name = "Party Hopper",      xp = 150,  goal = 100,
      desc = "Jump 100 times in a full group of 5 or more.",  progress = function() return Stat("group") end },
    { id = "zones1",   name = "Wanderer",          xp = 150,  goal = 10,
      desc = "Jump in 10 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "zones2",   name = "Globetrotter",      xp = 500,  goal = 30,
      desc = "Jump in 30 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "capitals", name = "Capital Tourist",   xp = 250,  goal = 3,
      desc = "Jump in all three capital cities of your faction.",
      progress = CapitalCount },
    { id = "enemycap", name = "Diplomatic Incident", xp = 500,  goal = 1,
      desc = "Jump in an enemy faction's capital city.",      progress = function() return Stat("enemyCapital") end },
    { id = "session1", name = "Marathon",          xp = 150,  goal = 500,
      desc = "Jump 500 times in one session.",                progress = function() return Stat("bestSession") end },
    { id = "session2", name = "Ultramarathon",     xp = 500,  goal = 2500,
      desc = "Jump 2,500 times in one session.",              progress = function() return Stat("bestSession") end },
    { id = "sprint",   name = "Bunny Sprint",      xp = 150,  goal = 50,
      desc = "Jump 50 times within 60 seconds.",              progress = function() return Stat("bestMinute") end },
    { id = "nodeath1", name = "Untouchable",       xp = 250,  goal = 1000,
      desc = "Jump 1,000 times without dying.",               progress = function() return Stat("bestSinceDeath") end },
    { id = "nodeath2", name = "Immortal Hopper",   xp = 1000, goal = 10000,
      desc = "Jump 10,000 times without dying.",              progress = function() return Stat("bestSinceDeath") end },
    { id = "days1",    name = "Daily Hopper",      xp = 250,  goal = 7,
      desc = "Jump on 7 different days.",                     progress = function() return CountKeys(acct.stats.days) end },
    { id = "days2",    name = "Devoted Hopper",    xp = 750,  goal = 30,
      desc = "Jump on 30 different days.",                    progress = function() return CountKeys(acct.stats.days) end },

    -- 1.3.0: harder tiers of the challenges above...
    { id = "mount3",   name = "Kangaroo Cavalry",  xp = 1000, goal = 10000,
      desc = "Jump 10,000 times while mounted.",              progress = function() return Stat("mounted") end },
    { id = "swim2",    name = "Dolphin Leap",      xp = 375,  goal = 1000,
      desc = "Jump 1,000 times at the surface of water.",     progress = function() return Stat("swim") end },
    { id = "swim3",    name = "Flying Fish",       xp = 1000, goal = 5000,
      desc = "Jump 5,000 times at the surface of water.",     progress = function() return Stat("swim") end },
    { id = "ghost2",   name = "Restless Spirit",   xp = 375,  goal = 250,
      desc = "Jump 250 times as a ghost.",                    progress = function() return Stat("ghost") end },
    { id = "combat2",  name = "Dodge Master",      xp = 500,  goal = 2500,
      desc = "Jump 2,500 times in combat.",                   progress = function() return Stat("combat") end },
    { id = "combat3",  name = "War Kangaroo",      xp = 1250, goal = 10000,
      desc = "Jump 10,000 times in combat.",                  progress = function() return Stat("combat") end },
    { id = "dungeon2", name = "Raid Rabbit",       xp = 750,  goal = 5000,
      desc = "Jump 5,000 times inside dungeons or raids.",    progress = function() return Stat("instance") end },
    { id = "party2",   name = "Conga Line",        xp = 375,  goal = 1000,
      desc = "Jump 1,000 times in a full group of 5 or more.", progress = function() return Stat("group") end },
    { id = "zones3",   name = "World Hopper",      xp = 1000, goal = 50,
      desc = "Jump in 50 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "session3", name = "Iron Legs",         xp = 1500, goal = 10000,
      desc = "Jump 10,000 times in one session.",             progress = function() return Stat("bestSession") end },
    { id = "sprint2",  name = "Turbo Bunny",       xp = 375,  goal = 65,
      desc = "Jump 65 times within 60 seconds.",              progress = function() return Stat("bestMinute") end },
    { id = "nodeath3", name = "Deathless Legend",  xp = 2000, goal = 25000,
      desc = "Jump 25,000 times without dying.",              progress = function() return Stat("bestSinceDeath") end },
    { id = "days3",    name = "Hopping Habit",     xp = 2000, goal = 100,
      desc = "Jump on 100 different days.",                   progress = function() return CountKeys(acct.stats.days) end },
    { id = "week1",    name = "Weekly Warrior",    xp = 750,  goal = 10000,
      desc = "Jump 10,000 times in one week.",                progress = function() return Stat("bestWeek") end },
    { id = "week2",    name = "Weekly Legend",     xp = 1500, goal = 25000,
      desc = "Jump 25,000 times in one week.",                progress = function() return Stat("bestWeek") end },

    -- ...and new kinds.
    { id = "streak1",  name = "On a Roll",         xp = 375,  goal = 7,
      desc = "Jump every day for 7 days in a row.",           progress = function() return Stat("bestStreak") end },
    { id = "streak2",  name = "Unbreakable Habit", xp = 1500, goal = 30,
      desc = "Jump every day for 30 days in a row.",          progress = function() return Stat("bestStreak") end },
    { id = "resting",  name = "Inn Hopper",        xp = 150,  goal = 1000,
      desc = "Jump 1,000 times while resting in an inn or city.", progress = function() return Stat("resting") end },
    { id = "stealth",  name = "Sneaky Hop",        xp = 200,  goal = 100,
      desc = "Jump 100 times while stealthed.",               progress = function() return Stat("stealth") end },
    { id = "shape",    name = "Shapeshifter Spring", xp = 200, goal = 500,
      desc = "Jump 500 times in a druid form or Ghost Wolf.", progress = function() return Stat("shapeshift") end },
    { id = "pvp",      name = "Battleground Bounce", xp = 375, goal = 250,
      desc = "Jump 250 times in a battleground.",             progress = function() return Stat("pvp") end },
    { id = "night",    name = "Night Owl",         xp = 250,  goal = 500,
      desc = "Jump 500 times between midnight and 4 AM.",     progress = function() return Stat("night") end },
    -- (Was "below 20% health in combat" - health is a hidden "secret" value
    -- in combat on Forever, so addons can't read it. Same id, so anyone who
    -- already completed it keeps it.)
    { id = "lowhp",    name = "Living Dangerously", xp = 375, goal = 500,
      desc = "Jump 500 times while flagged for PvP.",         progress = function() return Stat("pvpFlagged") end },
    { id = "maxlevel", name = "Seasoned Hopper",   xp = 750,  goal = 5000,
      desc = "Jump 5,000 times at max character level.",      progress = function() return Stat("maxLevel") end },
    { id = "classes1", name = "Jack of All Hops",  xp = 500,  goal = 3,
      desc = "Jump 100 times on characters of 3 different classes.", progress = function() return ClassCount() end },
    { id = "classes2", name = "Master of Many",    xp = 1250, goal = 5,
      desc = "Jump 100 times on characters of 5 different classes.", progress = function() return ClassCount() end },
    { id = "prestige1", name = "Born Again",       xp = 250,  goal = 3,
      desc = "Reach Prestige 3.",                             progress = function() return acct.prestige end },
    { id = "prestige2", name = "Star Collector",   xp = 750,  goal = 8,
      desc = "Reach Prestige 8.",                            progress = function() return acct.prestige end },
    { id = "prestige3", name = "Constellation",    xp = 1500, goal = 15,
      desc = "Reach Prestige 15.",                            progress = function() return acct.prestige end },

    -- 1.5.0: jump duels.
    { id = "duel1",    name = "Duelist",           xp = 150,  goal = 1,
      desc = "Win a jump duel.",                              progress = function() return acct.duelWins or 0 end },
    { id = "duel2",    name = "Duel Champion",     xp = 750,  goal = 10,
      desc = "Win 10 jump duels.",                            progress = function() return acct.duelWins or 0 end },
    { id = "duel3",    name = "Undisputed",        xp = 2000, goal = 50,
      desc = "Win 50 jump duels.",                            progress = function() return acct.duelWins or 0 end },

    -- 1.8.0: the crown (most jumps in an hour).
    { id = "crown1",   name = "Crowned",           xp = 150,  goal = 1,
      desc = "Win the crown: most jumps in an hour.",         progress = function() return acct.crowns or 0 end },
    { id = "crown2",   name = "Royal Leaper",      xp = 750,  goal = 10,
      desc = "Win the crown 10 times.",                       progress = function() return acct.crowns or 0 end },
    { id = "crown3",   name = "Jump Monarch",      xp = 2000, goal = 50,
      desc = "Win the crown 50 times.",                       progress = function() return acct.crowns or 0 end },

    -- 1.8.2: daily challenges.
    { id = "daily1",   name = "Daily Hopper",      xp = 250,  goal = 10,
      desc = "Complete 10 daily challenges.",                 progress = function() return acct.dailyDone or 0 end },
    { id = "daily2",   name = "Creature of Habit", xp = 1500, goal = 100,
      desc = "Complete 100 daily challenges.",                progress = function() return acct.dailyDone or 0 end },

    -- 1.8.7: eleven new kinds. Most count from the update on.
    { id = "hour1",    name = "Power Hour",        xp = 250,  goal = 1000,
      desc = "Jump 1,000 times in one hour.",                 progress = function() return Stat("bestHour") end },
    { id = "hour2",    name = "Hour of Power",     xp = 750,  goal = 2500,
      desc = "Jump 2,500 times in one hour.",                 progress = function() return Stat("bestHour") end },
    { id = "air1",     name = "Hang Time",         xp = 125,  goal = 2,
      desc = "Stay in the air for 2 seconds after a jump - and survive.",
      progress = function() return math.floor(Stat("bestAir")) end },
    { id = "air2",     name = "Leap of Faith",     xp = 500,  goal = 5,
      desc = "Stay in the air for 5 seconds after a jump - and survive.",
      progress = function() return math.floor(Stat("bestAir")) end },
    { id = "clock1",   name = "Half a Day",        xp = 250,  goal = 12,
      desc = "Jump in 12 different hours of the day.",        progress = function() return CountKeys(acct.stats.hours) end },
    { id = "clock2",   name = "Around the Clock",  xp = 1000, goal = 24,
      desc = "Jump in all 24 hours of the day.",              progress = function() return CountKeys(acct.stats.hours) end },
    { id = "indoor1",  name = "House Hopper",      xp = 125,  goal = 500,
      desc = "Jump 500 times indoors.",                       progress = function() return Stat("indoors") end },
    { id = "indoor2",  name = "Cabin Fever",       xp = 500,  goal = 5000,
      desc = "Jump 5,000 times indoors.",                     progress = function() return Stat("indoors") end },
    { id = "tour1",    name = "Dungeon Tourist",   xp = 250,  goal = 5,
      desc = "Jump in 5 different dungeons or raids.",        progress = function() return CountKeys(acct.stats.instances) end },
    { id = "tour2",    name = "Seen It All",       xp = 750,  goal = 15,
      desc = "Jump in 15 different dungeons or raids.",       progress = function() return CountKeys(acct.stats.instances) end },
    { id = "perfect1", name = "Perfect Day",       xp = 250,  goal = 1,
      desc = "Complete all three daily challenges on the same day.",
      progress = function() return Stat("perfectDays") end },
    { id = "perfect2", name = "Perfect Week",      xp = 1000, goal = 7,
      desc = "Complete all three daily challenges on 7 different days.",
      progress = function() return Stat("perfectDays") end },
    { id = "winrow1",  name = "Hot Streak",        xp = 375,  goal = 3,
      desc = "Win 3 jump duels in a row.",                    progress = function() return Stat("bestWinStreak") end },
    { id = "winrow2",  name = "Unstoppable",       xp = 1000, goal = 5,
      desc = "Win 5 jump duels in a row.",                    progress = function() return Stat("bestWinStreak") end },
    { id = "burst1",   name = "Quick Feet",        xp = 250,  goal = 30,
      desc = "Jump 30 times in a single jump duel.",          progress = function() return Stat("bestDuel") end },
    { id = "burst2",   name = "Blur",              xp = 750,  goal = 35,
      desc = "Jump 35 times in a single jump duel.",          progress = function() return Stat("bestDuel") end },
    { id = "pass1",    name = "Overtaker",         xp = 250,  goal = 10,
      desc = "Pass other players on the leaderboard 10 times.", progress = function() return Stat("overtakes") end },
    { id = "pass2",    name = "Fast Lane",         xp = 1000, goal = 50,
      desc = "Pass other players on the leaderboard 50 times.", progress = function() return Stat("overtakes") end },
    { id = "crowd1",   name = "Among Friends",     xp = 125,  goal = 10,
      desc = "Have 10 other players on your leaderboard.",    progress = function() return CountKeys(JumpCounterDB.peers) end },
    { id = "crowd2",   name = "Crowd Pleaser",     xp = 500,  goal = 25,
      desc = "Have 25 other players on your leaderboard.",    progress = function() return CountKeys(JumpCounterDB.peers) end },
    { id = "level1",   name = "Halfway There",     xp = 500,  goal = 50,
      desc = "Reach jump level 50.",                          progress = function() return Stat("bestLevel") end },
    { id = "level2",   name = "Top of the Ladder", xp = 1500, goal = 100,
      desc = "Reach jump level 100.",                         progress = function() return Stat("bestLevel") end },

    -- 1.8.10: up to 100 challenges - harder tiers of the ones above, and the weekly goal.
    { id = "hour3",    name = "Sixty Minute Storm", xp = 1500, goal = 3500,
      desc = "Jump 3,500 times in one hour.",                 progress = function() return Stat("bestHour") end },
    { id = "air3",     name = "Skydiver",          xp = 1000, goal = 8,
      desc = "Stay in the air for 8 seconds after a jump - and survive.",
      progress = function() return math.floor(Stat("bestAir")) end },
    { id = "indoor3",  name = "Never Leaves the House", xp = 1500, goal = 25000,
      desc = "Jump 25,000 times indoors.",                    progress = function() return Stat("indoors") end },
    { id = "tour3",    name = "Dungeon Master",    xp = 1500, goal = 30,
      desc = "Jump in 30 different dungeons or raids.",       progress = function() return CountKeys(acct.stats.instances) end },
    { id = "perfect3", name = "Perfect Month",     xp = 2000, goal = 30,
      desc = "Complete all three daily challenges on 30 different days.",
      progress = function() return Stat("perfectDays") end },
    { id = "winrow3",  name = "Untouchable Streak", xp = 2000, goal = 10,
      desc = "Win 10 jump duels in a row.",                   progress = function() return Stat("bestWinStreak") end },
    { id = "pass3",    name = "Left Lane Only",    xp = 2000, goal = 250,
      desc = "Pass other players on the leaderboard 250 times.", progress = function() return Stat("overtakes") end },
    { id = "zones4",   name = "Cartographer",      xp = 1500, goal = 75,
      desc = "Jump in 75 different zones.",                   progress = function() return CountKeys(acct.stats.zones) end },
    { id = "ghost3",   name = "Poltergeist",       xp = 1000, goal = 1000,
      desc = "Jump 1,000 times as a ghost.",                  progress = function() return Stat("ghost") end },
    { id = "party3",   name = "Bouncing Band",     xp = 1500, goal = 5000,
      desc = "Jump 5,000 times in a full group of 5 or more.", progress = function() return Stat("group") end },
    { id = "dungeon3", name = "Boss Room Bunny",   xp = 2000, goal = 25000,
      desc = "Jump 25,000 times inside dungeons or raids.",   progress = function() return Stat("instance") end },
    { id = "stealth2", name = "Shadow Hopper",     xp = 750,  goal = 1000,
      desc = "Jump 1,000 times while stealthed.",             progress = function() return Stat("stealth") end },
    { id = "shape2",   name = "Wild at Heart",     xp = 1000, goal = 5000,
      desc = "Jump 5,000 times in a druid form or Ghost Wolf.", progress = function() return Stat("shapeshift") end },
    { id = "pvp2",     name = "Flag Room Frolic",  xp = 1250, goal = 2500,
      desc = "Jump 2,500 times in a battleground.",           progress = function() return Stat("pvp") end },
    { id = "night2",   name = "Insomniac",         xp = 1000, goal = 5000,
      desc = "Jump 5,000 times between midnight and 4 AM.",   progress = function() return Stat("night") end },
    { id = "lowhp2",   name = "Marked for Mischief", xp = 1250, goal = 5000,
      desc = "Jump 5,000 times while flagged for PvP.",       progress = function() return Stat("pvpFlagged") end },
    { id = "maxlevel2", name = "Veteran Hopper",   xp = 1500, goal = 25000,
      desc = "Jump 25,000 times at max character level.",     progress = function() return Stat("maxLevel") end },
    { id = "sprint3",  name = "Lightning Legs",    xp = 1000, goal = 70,
      desc = "Jump 70 times within 60 seconds.",              progress = function() return Stat("bestMinute") end },
    { id = "daily3",   name = "A Year of Days",    xp = 2500, goal = 365,
      desc = "Complete 365 daily challenges.",                progress = function() return acct.dailyDone or 0 end },
    { id = "duelplay1", name = "Seasoned Duelist", xp = 1000, goal = 100,
      desc = "Take part in 100 jump duels.",
      progress = function() return (acct.duelWins or 0) + (acct.duelLosses or 0) + (acct.duelDraws or 0) end },
    { id = "week3",    name = "Weekly Titan",      xp = 2000, goal = 50000,
      desc = "Jump 50,000 times in one week.",                progress = function() return Stat("bestWeek") end },
    { id = "team1",    name = "Team Player",       xp = 500,  goal = 1,
      desc = "Reach a weekly goal together with your leaderboard.",
      progress = function() return Stat("weeklyTiers") end },
    { id = "team2",    name = "Golden Month",      xp = 2000, goal = 4,
      desc = "Reach the gold weekly goal together 4 times.",  progress = function() return Stat("weeklyGold") end },
}

local function CountCompleted(data)
    return CountKeys(data and data.done)
end

---------------------------------------------------------------------------
-- Jumps per hour: jumps / online time (not AFK) over the last RATE_DAYS
-- days, so everyone is compared on what they did recently - long-time
-- players aren't dragged down by old playtime, new players aren't boosted
-- by a short burst. Only shown once RATE_MIN_SECONDS of online time is in
-- the window. Kept account-wide in one bucket per (server) day.
---------------------------------------------------------------------------
local RATE_MIN_SECONDS = 1800
local RATE_DAYS = 7
local RATE_SINCE = "1.8.2"        -- older versions send an all-time rate: not comparable

local function RateDay() return math.floor(GetServerTime() / 86400) end

-- Add jumps / online seconds to today's bucket; drop days out of the window.
local function AddRate(jumps, seconds)
    local days = acct.rateDays
    local today = RateDay()
    local b = days[today]
    if not b then
        for d in pairs(days) do
            if d <= today - RATE_DAYS then days[d] = nil end
        end
        b = { 0, 0 }
        days[today] = b
    end
    b[1], b[2] = b[1] + jumps, b[2] + seconds
end

-- Jumps and online seconds over the last RATE_DAYS days.
local function RecentRate()
    local jumps, seconds, first = 0, 0, RateDay() - RATE_DAYS + 1
    for d, b in pairs(acct.rateDays) do
        if d >= first then jumps, seconds = jumps + b[1], seconds + b[2] end
    end
    return jumps, seconds
end

-- Ours: from the raw numbers. Peers send the finished rate.
local function JumpsPerHour(data)
    if data.rate then
        if (data.rate.seconds or 0) < RATE_MIN_SECONDS then return nil end
        return data.rate.jumps / data.rate.seconds * 3600
    end
    if data.version and not IsNewerVersion(RATE_SINCE, data.version) then return data.jph end
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

    -- Forget players we haven't heard from in PEER_EXPIRY_DAYS (left the guild,
    -- quit, turned the addon off...). Rows from versions before 1.1.0 (no
    -- account id: nobody active is still on those) go after 3 days. Anyone
    -- who comes back is simply added again by their next score.
    local cutoff, oldCutoff = time() - PEER_EXPIRY_DAYS * 86400, time() - 3 * 86400
    for key, data in pairs(db.peers) do
        if (data.seen or 0) < (data.acct and cutoff or oldCutoff) then db.peers[key] = nil end
    end
    -- 1.8.11: your board is your guild, your friends and the people they
    -- know directly. Once, drop everything passed along by older versions
    -- (that could be second-hand or a stranger from someone's group). Your
    -- friends' current versions send theirs again within minutes. Players
    -- met in a group are sorted out a minute after login (DropGroupStrangers),
    -- once the guild roster and friends lists have loaded.
    if (db.circles or 0) < 1 then
        for key, data in pairs(db.peers) do
            if data.via == "RELAY" then db.peers[key] = nil end
        end
        db.circles = 1
    end
    -- 1.8.13: "Best duel" starts over (duel jumps are capped at normal jump
    -- speed from this version), and only shows for players on it.
    for _, data in pairs(db.peers) do
        if data.duelBest and (not data.version or IsNewerVersion("1.8.13", data.version)) then data.duelBest = nil end
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
    charData.hidden = nil             -- logged in on it again: shown again (1.8.11)

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
    -- 1.8.8: "this session" carries on after a /reload or a quick restart
    -- (updating the addon): the count is saved, with the time we were last
    -- online, and picked up again if that was under 10 minutes ago.
    local sess = acct.session
    if sess and time() - (sess.at or 0) <= 600 then sessionJumps = sess.jumps or 0 end
    acct.session = { jumps = sessionJumps, at = time() }
    if not acct.id then
        -- Random id so others can tell your characters belong together
        -- (nothing about your Battle.net account is shared).
        local hex = {}
        for i = 1, 12 do hex[i] = ("%x"):format(math.random(0, 15)) end
        acct.id = table.concat(hex)
    end
    acct.prestige = acct.prestige or 0
    acct.prestigeSpent = acct.prestigeSpent or acct.prestige * PRESTIGE_XP
    -- 1.8.2: duels played before duel ranks count too.
    acct.duelPoints = acct.duelPoints or ((acct.duelWins or 0) * DUEL_POINTS.win
        + (acct.duelDraws or 0) * DUEL_POINTS.draw + (acct.duelLosses or 0) * DUEL_POINTS.loss)
    acct.challengeXP = acct.challengeXP or 0
    acct.done = acct.done or {}
    acct.stats = acct.stats or {}
    local st = acct.stats
    st.zones = st.zones or {}
    st.capitals = st.capitals or {}
    st.days = st.days or {}
    acct.rateDays = acct.rateDays or {}   -- 1.8.2: [server day] = { jumps, online seconds }
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
-- The group leader crown, shown next to whoever jumped most this hour.
local CROWN_ICON = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14:14|t "

-- Your account as one leaderboard entry: every character's jumps, deaths,
-- week and online time added up, plus the shared level and challenges.
-- Shown under the character you are playing.
local function Me()
    local wid = CurrentWeekId()
    local me = { total = 0, week = 0, weekId = wid, deaths = 0, rate = { jumps = 0, seconds = 0 },
        challengeXP = acct.challengeXP + (acct.duelXP or 0) + (acct.crownXP or 0) + (acct.dailyXP or 0)
            + (acct.weeklyXP or 0),
        prestige = acct.prestige, prestigeSpent = acct.prestigeSpent, done = acct.done,
        duelWins = acct.duelWins or 0, duelPoints = acct.duelPoints or 0, faction = MyFaction(),
        duelBest = acct.stats and acct.stats.bestDuel or 0,
        guild = GetGuildInfo and Plain((GetGuildInfo("player"))) or nil,
        hourId = acct.hourId, hour = acct.hour, crowns = acct.crowns or 0,
        class = charData.class, display = charData.display }
    for _, c in pairs(JumpCounterDB.chars) do
        me.total = me.total + (c.total or 0)
        if wid and c.weekId == wid then me.week = me.week + (c.week or 0) end
        me.deaths = me.deaths + (c.deaths or 0)
    end
    me.rate.jumps, me.rate.seconds = RecentRate()     -- last 7 days, whole account
    return me
end

-- Your characters, most jumps first: { { key, name, total, class }, ... }
-- (1.8.11: characters hidden with /jumps forget are left out - their jumps
-- still count in your total)
local function MyCharacters()
    local list = {}
    for key, c in pairs(JumpCounterDB.chars) do
        if not c.hidden then
            table.insert(list, { key = key, name = c.display or c.name or key:match("^[^-]+") or key,
                total = c.total or 0, class = c.class })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

---------------------------------------------------------------------------
-- Networking (guild, friends and Battle.net friends)
---------------------------------------------------------------------------
-- 1.8.11: no more party / raid / instance chat. Everyone in your group who
-- belongs on your board is in your guild or on a friends list anyway, and a
-- random player from a dungeon or battleground shouldn't end up on it.
local function GetChannels()
    local channels = {}
    if IsInGuild() then table.insert(channels, "GUILD") end
    return channels
end

-- Friends who have shown they run JumpCounter this session. Regular score
-- updates only go to these; everyone else is contacted once at login
-- ("discovery") so we don't keep messaging people without the addon.
local knownWhisper = {}   -- [WhisperId(character name)] = true

-- Forever's two-part names can be written differently by the friends list
-- ("Akropil", "Akropil Resotrange") and by whispers ("Akropil Resotrange-Realm"),
-- so friends are matched on the first name, lowercased.
local function WhisperId(name)
    return ((name or ""):match("^[^%s%-]+") or name or ""):lower()
end
local knownBNet = {}      -- [gameAccountID] = GetTime() we last heard from them
local BNET_HEARD_RECENTLY = 3600

-- Online characters on your WoW friends list who aren't reached via the guild.
local function GetOnlineFriends()
    local names = {}
    if not (C_FriendList and C_FriendList.GetNumFriends) then return names end
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then
            -- (Friends in your group are whispered too: group chat isn't used.)
            local inGuild = false
            if IsInGuild() and C_GuildInfo and C_GuildInfo.MemberExistsByName then
                inGuild = C_GuildInfo.MemberExistsByName(info.name)
            end
            if not inGuild then table.insert(names, info.name) end
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
-- never exceeds the game's addon message limit: a burst of about 10, then
-- about 1 per second - anything over it is silently dropped by the game.
-- 1.8.2: paced to that limit (SEND_BURST, then SEND_RATE per second), most
-- important first (duels, then scores, then passed-along scores), and a
-- message the game still refuses goes back to the front and is retried.
local Enqueue, QueuedCount          -- the send queue (in a block: Lua 5.1's 200-local limit)
do
    local SEND_INTERVAL = 0.2
    local SEND_BURST = 8
    local SEND_RATE = 1
    local sendQueue = {}
    local queuedKeys = {}     -- avoid queueing the same message to the same target twice
    local sendTicker
    local sendTokens, sendTokensAt = SEND_BURST, 0

    local function ProcessQueue()
        local now = GetTime()
        sendTokens = math.min(SEND_BURST, sendTokens + (now - sendTokensAt) * SEND_RATE)
        sendTokensAt = now
        if sendTokens >= 1 and sendQueue[1] then
            local item = table.remove(sendQueue, 1)
            queuedKeys[item.id] = nil
            sendTokens = sendTokens - 1
            local throttled = false
            if item.bnet then
                pcall(BNSendGameData, item.target, PREFIX, item.msg)
            else
                local result = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, item.channel, item.target)
                local THROTTLED = Enum and Enum.SendAddonMessageResult
                    and Enum.SendAddonMessageResult.AddonMessageThrottle
                throttled = THROTTLED ~= nil and result == THROTTLED
            end
            if throttled and (item.tries or 0) < 5 then
                -- The game says "too fast": wait a moment and try again.
                item.tries = (item.tries or 0) + 1
                table.insert(sendQueue, 1, item)
                queuedKeys[item.id] = true
                sendTokens = 0
            end
        end
        if #sendQueue == 0 and sendTicker then
            sendTicker:Cancel()
            sendTicker = nil
        end
    end

    -- 1 = duel messages (time-critical), 2 = scores and requests, 3 = passed-along scores.
    local function SendPriority(msg)
        local tag = msg:match("^[^:]+")
        if tag == "R" or tag == "R2" then return 3 end
        if tag and tag:match("^D[QAGPF]$") then return 1 end
        return 2
    end

    function Enqueue(msg, channel, target, bnet)
        -- Relayed scores ("R2:<acct>:...") are one message per account.
        local kind = msg:match("^(R2?:[^:]+)") or msg:match("^[^:]+") or msg
        local id = (bnet and "bn" or channel) .. ":" .. tostring(target) .. ":" .. kind
        if queuedKeys[id] then
            -- Already waiting to go out: just send the newest content.
            for _, item in ipairs(sendQueue) do
                if item.id == id then item.msg = msg end
            end
            return
        end
        queuedKeys[id] = true
        local item = { id = id, msg = msg, channel = channel, target = target, bnet = bnet, prio = SendPriority(msg) }
        -- After everything at least as important, before anything less important.
        local pos = #sendQueue + 1
        for i, other in ipairs(sendQueue) do
            if other.prio > item.prio then pos = i break end
        end
        table.insert(sendQueue, pos, item)
        if not sendTicker then sendTicker = C_Timer.NewTicker(SEND_INTERVAL, ProcessQueue) end
    end
    function QueuedCount() return #sendQueue end
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
        if discover or knownWhisper[WhisperId(name)] then
            SendWhisper(name, msg)
        end
    end
    local listed = {}
    for _, id in ipairs(GetBNetGameAccounts()) do
        listed[id] = true
        if discover or knownBNet[id] then SendBNet(id, msg) end
    end
    -- Battle.net sometimes shows a friend as offline although they're
    -- online (their messages still arrive). Anyone whose addon messaged us
    -- in the last BNET_HEARD_RECENTLY is online: keep sending to them too.
    local now = GetTime()
    for id, heard in pairs(knownBNet) do
        if not listed[id] and now - heard < BNET_HEARD_RECENTLY then SendBNet(id, msg) end
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
        Plain(UnitLevel("player")) or 0, EntryXP(me), CountCompleted(me),
        jph and math.floor(jph + 0.5) or "", EntryPrestige(me), acct.id }, ":")
    -- 1.5.0: duels won, after the character list (older versions ignore it).
    -- 1.6.0: faction ("A" / "H") after that.
    -- 1.7.3: duels lost and drawn after that.
    -- 1.8.0: hour id, jumps this hour and crowns won after that.
    local suffix = ":" .. (acct.duelWins or 0) .. ":" .. (MyFaction() or "")
        .. ":" .. (acct.duelLosses or 0) .. ":" .. (acct.duelDraws or 0)
        .. ":" .. CurrentHourId() .. ":" .. HourCount(me) .. ":" .. (acct.crowns or 0)
        .. ":" .. (acct.prestigeSpent or 0)                     -- 1.8.2: XP used by prestige stars
        .. ":" .. (acct.duelPoints or 0)                        -- 1.8.2: duel rank points
        .. ":" .. (acct.stats.bestDuel or 0)                    -- 1.8.9: most jumps in one duel
    -- 1.8.11: guild name ("" = none), for the leaderboard's guild filter and
    -- ranking. Left out altogether in the rare case it doesn't fit (the
    -- receiver then falls back on the channel the score came through).
    local guild = (tostring(GetGuildInfo and Plain((GetGuildInfo("player"))) or ""):gsub(":", ""))
    if #msg + 1 + #suffix + 1 + #guild <= MAX_MESSAGE then suffix = suffix .. ":" .. guild end
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
    -- Only rows without an account id (versions before 1.1.0) can be stale.
    -- Almost everyone has one by now, so usually there's nothing to do -
    -- and this runs for every score that arrives.
    local any = false
    for _, data in pairs(peers) do
        if not data.acct then any = true break end
    end
    if not any then return end
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
                -- (A first name alone is never enough here: two players can
                -- share one. A leftover row for someone's alt - "Small Nose",
                -- listed by its account as just "Small" - goes with the
                -- 3-day rule for old versions instead.)
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

-- Login: ask friends directly (cheap), not the whole guild.
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
-- Battle.net friend. Scores are passed on once (1.8.11; twice before): only
-- players we heard ourselves - our guild and our friends - so each group of
-- friends and each guild keeps its own board, and a friend's friend's guild
-- never shows up. Only if updated in the last RELAY_MAX_AGE, in small batches:
--  * to a friend (whisper / Battle.net) whenever we hear from them (at most
--    once a minute, and every minute while we've heard from them lately):
--    only scores they haven't had from us yet, or that changed (RELAY_RESEND;
--    RELAY_LIVE when their jumps this hour changed - the crown race);
--  * to the guild, only scores that didn't come from the guild: everything
--    every RELAY_GUILD_INTERVAL, changed hour counts every RELAY_LIVE,
--    skipping what someone else already sent.
-- R2:<acct>:<key>:<name>:<class>:<faction>:<total>:<weekId>:<week>:<deaths>
--  :<char level>:<xp>:<challenges>:<jph>:<prestige>:<duel wins>:<version>:<seen>:<hops>
---------------------------------------------------------------------------
-- Lua 5.1 allows at most 200 locals per file, so helpers live in do-blocks
-- and only what other code needs is declared outside.
local RELAY_GUILD_INTERVAL = 600
local RelayToContact, RelayToGuild, ApplyRelay, RelayTick
do
    local RELAY_MAX_AGE = 3 * 86400
    local RELAY_MAX_HOPS = 1          -- 1.8.11: first-hand only (2 before)
    local RELAY_BATCH = 40
    local RELAY_CONTACT_GAP = 60      -- at most one batch a minute per friend
    local RELAY_RESEND = 600          -- resend a score to a friend at most every 10 min
    -- 1.8.1: a score whose jumps this hour changed goes out again after
    -- 90 s, so the crown race is close to live for friends of friends too.
    -- Scores that don't change keep the slow 10-minute pace.
    local RELAY_LIVE = 90
    local CONTACT_QUIET = 900         -- stop sending to friends not heard from in 15 min
    local contacts = {}               -- [contact key] = { last, heard, reply, acct, sent = { [acct] = seen }, sentHour = {} }
    local guildRelayed = {}           -- [acct] = newest "seen" already passed around the guild
    local guildHour = {}              -- [acct] = jumps this hour last passed around the guild
    local lastGuildRelay = -RELAY_GUILD_INTERVAL
    local lastGuildFull = -RELAY_GUILD_INTERVAL

    -- Jumps this hour changed since we last passed this score on?
    local function HourChanged(d, sentHour, sentSeen)
        return d.hourId == CurrentHourId() and (d.hour or 0) > 0 and d.hour ~= sentHour
            and (d.seen or 0) - (sentSeen or 0) >= RELAY_LIVE
    end

    local function NoColon(v) return (tostring(v or ""):gsub(":", "")) end

    local function RelayMessage(key, data)
        local function n(v) return v ~= nil and tostring(v) or "" end
        local parts = { "R2", data.acct, NoColon(key), NoColon(data.display), n(data.class),
            n(data.faction), n(data.total), n(data.weekId), n(data.week), n(data.deaths),
            n(data.charLevel), n(data.xp), n(data.challenges), n(data.jph), n(data.prestige),
            n(data.duelWins), n(data.version), n(data.seen), (data.hops or 0) + 1,
            -- 1.7.3: after the hop count, so older versions ignore them
            n(data.duelLosses), n(data.duelDraws),
            n(data.hourId), n(data.hour), n(data.crowns),          -- 1.8.0
            n(data.prestigeSpent), n(data.duelPoints),              -- 1.8.2
            n(data.duelBest) }                                      -- 1.8.9
        local msg = table.concat(parts, ":")
        -- 1.8.11: their guild, when there's room for it.
        local guild = NoColon(data.guild)
        if #msg + 1 + #guild <= MAX_MESSAGE then msg = msg .. ":" .. guild end
        return msg
    end

    -- Up to RELAY_BATCH passable scores (newest first) that pass filter(data).
    local function RelayBatch(filter)
        local list = {}
        local now = time()
        for key, data in pairs(JumpCounterDB.peers) do
            if data.acct and (data.hops or 0) < RELAY_MAX_HOPS and data.via ~= "GROUP" and data.via ~= "RELAY"
                and now - (data.seen or 0) <= RELAY_MAX_AGE
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
    -- fromTick = called by RelayTick, not because they just sent us something.
    function RelayToContact(contactKey, reply, contactAcct, fromTick)
        local c = contacts[contactKey]
        if not c then
            c = { last = -RELAY_CONTACT_GAP, sent = {}, sentHour = {} }
            contacts[contactKey] = c
        end
        c.reply, c.acct = reply, contactAcct
        if not fromTick then c.heard = GetTime() end
        if GetTime() - c.last < RELAY_CONTACT_GAP then return end
        c.last = GetTime()
        local batch = RelayBatch(function(d)
            if d.acct == contactAcct then return false end
            local sentSeen = c.sent[d.acct]
            return not sentSeen or (d.seen or 0) - sentSeen >= RELAY_RESEND
                or HourChanged(d, c.sentHour[d.acct], sentSeen)
        end)
        for _, e in ipairs(batch) do
            c.sent[e.data.acct] = e.data.seen
            c.sentHour[e.data.acct] = e.data.hour
            reply(RelayMessage(e.key, e.data))
        end
    end

    -- Tell the guild about players it can't hear itself.
    -- Every 10 minutes everything new; in between (every 90 s at most) only
    -- scores whose jumps this hour changed.
    function RelayToGuild()
        if not IsInGuild() or GetTime() - lastGuildRelay < RELAY_LIVE then return end
        lastGuildRelay = GetTime()
        local full = GetTime() - lastGuildFull >= RELAY_GUILD_INTERVAL
        if full then lastGuildFull = GetTime() end
        local batch = RelayBatch(function(d)
            if d.via == "GUILD" or (guildRelayed[d.acct] or 0) >= (d.seen or 0) then return false end
            return full or HourChanged(d, guildHour[d.acct], guildRelayed[d.acct])
        end)
        for _, e in ipairs(batch) do
            guildRelayed[e.data.acct] = e.data.seen
            guildHour[e.data.acct] = e.data.hour
            Enqueue(RelayMessage(e.key, e.data), "GUILD")
        end
    end

    -- Every minute: the guild, and friends we've heard from lately (also
    -- the ones who stopped jumping, so they still get others' news).
    function RelayTick()
        RelayToGuild()
        for key, c in pairs(contacts) do
            if c.reply and GetTime() - (c.heard or 0) < CONTACT_QUIET then
                RelayToContact(key, c.reply, c.acct, true)
            end
        end
    end

    function ApplyRelay(msg, via)
        local _, rAcct, rKey, rDisplay, rClass, rFaction, rTotal, rWeekId, rWeek, rDeaths, rLevel,
            rXP, rChallenges, rJph, rPrestige, rDuels, rVersion, rSeen, rHops, rLosses, rDraws,
            rHourId, rHour, rCrowns, rSpent, rPoints, rBest, rGuild = strsplit(":", msg)
        rTotal, rSeen = tonumber(rTotal), tonumber(rSeen)
        if not rAcct or rAcct == "" or rAcct == acct.id or not rTotal or not rSeen
            or not rKey or rKey == "" then return end
        if tonumber(rHops) ~= RELAY_MAX_HOPS then return end      -- first-hand scores only
        if via == "GUILD" then
            -- Someone else already passed this around the guild.
            guildRelayed[rAcct] = math.max(guildRelayed[rAcct] or 0, rSeen)
            if tonumber(rHourId) == CurrentHourId() then guildHour[rAcct] = tonumber(rHour) end
        end
        rSeen = math.min(rSeen, time())             -- other computers' clocks may run ahead
        if time() - rSeen > RELAY_MAX_AGE then return end

        local peers = JumpCounterDB.peers
        local key, entry
        for k, d in pairs(peers) do
            if d.acct == rAcct then key, entry = k, d break end
        end
        if entry and (entry.seen or 0) >= rSeen then return end   -- we know newer
        -- 1.8.4: heard from them directly in the last 10 minutes? Then that
        -- line wins. Passed-along copies carry the passer's clock, which can
        -- run ahead and made direct friends look like "via friends".
        if entry and entry.directSeen and time() - entry.directSeen < 600 then return end
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
        entry.duelLosses, entry.duelDraws = num(rLosses), num(rDraws)   -- nil before 1.7.3
        entry.hourId, entry.hour, entry.crowns = num(rHourId), num(rHour), num(rCrowns)   -- 1.8.0
        entry.prestigeSpent, entry.duelPoints = num(rSpent), num(rPoints)               -- 1.8.2
        entry.duelBest = num(rBest)                                                     -- 1.8.9
        -- 1.8.13: best duels from before the duel jump cap don't compare.
        if not rVersion or rVersion == "" or IsNewerVersion("1.8.13", rVersion) then entry.duelBest = nil end
        if rGuild and rGuild ~= "" then entry.guild = rGuild end                        -- 1.8.11
        entry.version = (rVersion ~= "" and rVersion) or entry.version
        entry.seen = rSeen
        entry.hops = RELAY_MAX_HOPS
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
-- via: "GUILD", "WHISPER" or "BNET" ("GROUP" before 1.8.11).
local function HandleMessage(msg, key, display, reply, via)
    if msg:match("^D[QAGPFN]:") then
        OnDuelMessage(msg, reply, via)
        return
    end
    -- 1.8.11: only "R2" - first-hand scores. Older versions' "R" could be
    -- second-hand or a stranger from their group, so it's ignored.
    if msg:match("^R2:") then
        ApplyRelay(msg, via)
        return
    end
    if msg:match("^R:") then return end
    local tag, total, class, version, sentKey, sentDisplay, weekId, weekCount, guid, deaths,
        charLevel, xp, challenges, jph, prestige, acctId, characters, duelWins, faction,
        duelLosses, duelDraws, hourId, hourCount, crowns, prestigeSpent, duelPoints, duelBest,
        guildName = strsplit(":", msg)
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
        -- Character level before this score, if it's the same character.
        local oldCharLevel = previous and guid and previous.guid == guid and previous.charLevel
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
        entry.duelLosses = tonumber(duelLosses)   -- these two are nil before 1.7.3
        entry.duelDraws = tonumber(duelDraws)
        entry.hourId = tonumber(hourId)           -- these three are nil before 1.8.0
        entry.hour = tonumber(hourCount)
        entry.crowns = tonumber(crowns)
        entry.prestigeSpent = tonumber(prestigeSpent)   -- these two are nil before 1.8.2
        entry.duelPoints = tonumber(duelPoints)
        entry.duelBest = tonumber(duelBest)       -- nil before 1.8.9
        -- 1.8.13: best duels from before the duel jump cap don't compare.
        if not version or version == "" or IsNewerVersion("1.8.13", version) then entry.duelBest = nil end
        -- 1.8.11: their guild ("" = none). Older versions don't say: someone
        -- heard on the guild channel is in ours.
        if guildName then
            entry.guild = guildName ~= "" and guildName or nil
        elseif via == "GUILD" then
            entry.guild = GetGuildInfo and Plain((GetGuildInfo("player"))) or entry.guild
        end
        -- Reached through the friends list or Battle.net: a friend (kept).
        if via == "WHISPER" or via == "BNET" then entry.friend = true end
        entry.via, entry.hops = via, 0            -- heard directly
        entry.directSeen = time()
        entry.version = (version and version ~= "") and version or nil
        entry.seen = time()
        -- Their total went up since their last score: they're jumping right
        -- now (duels only pick players who are). A reply to a login doesn't count.
        if oldTotal and total > oldTotal then entry.lastJumped = time() end
        JumpCounterDB.peers[key] = entry
        -- A guild member we haven't heard from this session (they just logged
        -- in or installed): answer once with our score, so they see us - and
        -- our jumps this hour - even if we're standing still. The login
        -- request skips the guild to keep big guilds quiet; this covers it.
        local who = acctId or key
        if via == "GUILD" and not heardThisSession[who] and GetTime() - lastReplyTime > 10 then
            lastReplyTime = GetTime()
            C_Timer.After(1 + math.random() * 9, function() BroadcastScore() end)
        end
        heardThisSession[who] = true
        PruneStalePeers()
        if JumpCounterDB.peers[key] ~= entry then return end   -- itself a leftover copy
        OnPeerScore(key, oldTotal, total, entry.class, oldPrestige, entry.prestige, oldCharLevel)

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
            -- Someone asked the guild; answer once, after a random
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
    -- 1.8.11: party / raid / instance chat is ignored - older versions still
    -- send there, and that's how strangers from a random group got on the board.
    if channel ~= "GUILD" and channel ~= "WHISPER" then return end
    local key, display = NormalizeSender(sender)
    local reply
    if channel == "WHISPER" then
        knownWhisper[WhisperId(sender)] = true
        reply = function(m) SendWhisper(sender, m) end
    end
    local via = channel == "GUILD" and "GUILD" or "WHISPER"
    HandleMessage(msg, key, display, reply, via)
end

local function OnBNetAddonMessage(prefix, msg, _, gameAccountID)
    if prefix ~= PREFIX or not gameAccountID then return end
    knownBNet[gameAccountID] = GetTime()
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
    local level, into, need = EntryLevel(me)
    counterFrame.level:SetText(PrestigeTag(EntryPrestige(me)) .. "|cffffffffLevel " .. level .. "|r")
    counterFrame.bar:SetMinMaxValues(0, need)
    counterFrame.bar:SetValue(into)
    counterFrame.session:SetText(("Week |cffffffff%s|r   Session |cffffffff%s|r"):format(
        BreakUpLargeNumbers(MyWeekCount(me)), BreakUpLargeNumbers(sessionJumps)))
    -- Our place by total jumps: everyone with more than us, plus one.
    local place = 1
    for key, data in pairs(JumpCounterDB.peers) do
        if (data.total or 0) > me.total and not JumpCounterDB.chars[key] then place = place + 1 end
    end
    counterFrame.place:SetText("#" .. place)
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

-- The look of the small windows (on-screen counter, duel): dark like the main
-- window, a gold-bronze edge, and a bronze title plate across the top like
-- the leaderboard's column headers. Returns the plate's text.
local function StyleBox(f, title)
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.06, 0.05, 0.04, 0.92)
    f:SetBackdropBorderColor(0.78, 0.62, 0.3)
    local plate = f:CreateTexture(nil, "BORDER")
    plate:SetPoint("TOPLEFT", 4, -4)
    plate:SetPoint("TOPRIGHT", -4, -4)
    plate:SetHeight(17)
    plate:SetColorTexture(0.30, 0.23, 0.11, 0.9)
    local shine = f:CreateTexture(nil, "ARTWORK")
    shine:SetPoint("TOPLEFT", plate)
    shine:SetPoint("TOPRIGHT", plate)
    shine:SetHeight(1)
    shine:SetColorTexture(0.62, 0.5, 0.28, 0.9)
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT", plate)
    line:SetPoint("BOTTOMRIGHT", plate)
    line:SetHeight(1)
    line:SetColorTexture(0, 0, 0, 0.9)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", 0, -7)
    f.title:SetText(title or "")
    return f.title
end

---------------------------------------------------------------------------
-- Update window: a new version is out, plus the CurseForge link to copy.
---------------------------------------------------------------------------
do
    local frame

    -- A box holding a link; clicking it selects the whole link for Ctrl+C.
    local function LinkBox(parent, url, width)
        local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        eb:SetSize(width, 20)
        eb:SetAutoFocus(false)
        eb:SetFontObject("ChatFontNormal")
        eb:SetText(url)
        eb:SetCursorPosition(0)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        eb:SetScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
        -- Keep the link intact if someone types in the box.
        eb:SetScript("OnTextChanged", function(self, userInput)
            if userInput and self:GetText() ~= url then
                self:SetText(url)
                self:HighlightText()
            end
        end)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() frame:Hide() end)
        return eb
    end

    local function Create()
        local W = 460
        local f = CreateFrame("Frame", "JumpCounterUpdateFrame", UIParent, "BackdropTemplate")
        f:SetSize(W, 262)
        f:SetPoint("CENTER", 0, 120)
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        MakeMovable(f)
        tinsert(UISpecialFrames, "JumpCounterUpdateFrame")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -18)
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
        f.text:SetWidth(W - 40)

        local cfLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cfLabel:SetPoint("TOPLEFT", 24, -92)
        cfLabel:SetText("Update on CurseForge |cff999999(Jumps)|r")
        f.cf = LinkBox(f, CURSEFORGE_URL, W - 56)
        f.cf:SetPoint("TOPLEFT", cfLabel, "BOTTOMLEFT", 6, -4)

        local auto = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        auto:SetPoint("TOP", 0, -144)
        auto:SetWidth(W - 40)
        auto:SetText("Want automatic updates? Right-click Jumps in the "
            .. "CurseForge app > |cffffd100Install settings|r > |cffffd100Automatic|r.")

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOP", 0, -194)
        hint:SetWidth(W - 40)
        hint:SetText("Click the link, press Ctrl+C and paste it in your browser.\n"
            .. "After updating, type /reload (or restart the game).")

        local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        ok:SetSize(110, 22)
        ok:SetPoint("BOTTOM", 0, 14)
        ok:SetText(OKAY or "Okay")
        ok:SetScript("OnClick", function() f:Hide() end)
        return f
    end

    -- newer: the version that's out, or nil to just show the links.
    function ShowUpdateWindow(newer)
        frame = frame or Create()
        if newer then
            frame.title:SetText(("Jumps v%s is out!"):format(newer))
            frame.text:SetText(("You have v%s. Update to get the latest features and fixes - "
                .. "and to keep playing with friends on the newest version."):format(VERSION))
        else
            frame.title:SetText("Get Jumps")
            frame.text:SetText(("You have v%s, the newest version seen so far. "
                .. "Share this link with friends:"):format(VERSION))
        end
        frame:Show()
        frame.cf:SetFocus()
        frame.cf:HighlightText()
    end
end

local function CreateCounterFrame()
    local f = CreateFrame("Frame", "JumpCounterFrame", UIParent, "BackdropTemplate")
    f:SetSize(180, 78)
    StyleBox(f)
    f:SetFrameStrata("MEDIUM")

    local pos = JumpCounterDB.ui.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
    MakeMovable(f, "pos")

    -- On the title plate: tier star and jump level (left), our place on the
    -- leaderboard (right). Then the total in big gold digits, an XP bar
    -- framed like the main window's, and week / session.
    f.title:Hide()
    f.level = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.level:SetPoint("TOPLEFT", 10, -7)
    f.place = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.place:SetPoint("TOPRIGHT", -10, -7)

    f.total = f:CreateFontString(nil, "OVERLAY", GameFontNormalHuge and "GameFontNormalHuge" or "GameFontNormalLarge")
    f.total:SetPoint("TOP", 0, -25)

    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetHeight(6)
    f.bar:SetPoint("BOTTOMLEFT", 11, 23)
    f.bar:SetPoint("BOTTOMRIGHT", -11, 23)
    f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    f.bar:SetStatusBarColor(0.58, 0.0, 0.55)
    local barEdge = f.bar:CreateTexture(nil, "BACKGROUND", nil, -1)
    barEdge:SetPoint("TOPLEFT", -1, 1)
    barEdge:SetPoint("BOTTOMRIGHT", 1, -1)
    barEdge:SetColorTexture(0.45, 0.38, 0.22, 0.9)
    local barBg = f.bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0, 0, 0, 0.9)

    f.session = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.session:SetPoint("BOTTOM", 0, 9)

    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            if boardFrame:IsShown() then boardFrame:Hide() else boardFrame:Show() end
        end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Jumps")
        GameTooltip:AddLine("Drag to move, right-click to open Jumps.", 1, 1, 1)
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
        elseif mode == "hour" then
            score = HourCount(data)
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

    -- Anyone sitting exactly on our previous total was just passed. Counted
    -- (1.8.7, for challenges) even with the chat message turned off.
    local passed
    for key, data in pairs(JumpCounterDB.peers) do
        if data.total == newTotal - 1 and not JumpCounterDB.chars[key] and OvertakeAllowed(key) then
            passed = passed or {}
            table.insert(passed, ColoredName(key, data.class))
        end
    end
    if passed then
        acct.stats.overtakes = (acct.stats.overtakes or 0) + #passed
        if settings.overtakes then
            Notify(("You passed %s! You're now #%d."):format(table.concat(passed, ", "), MyRank() or 0))
        end
    end
end

-- Called whenever a friend's score arrives. oldTotal is nil the first time
-- we ever hear from them, so we don't announce anything for new players.
function OnPeerScore(key, oldTotal, newTotal, class, oldPrestige, newPrestige, oldCharLevel)
    if not oldTotal then return end
    -- Character level-up (same character as before). The early levels come
    -- every few minutes, so only 10 and 20 - then every level from 30.
    local data = JumpCounterDB.peers[key]
    local level = data and data.charLevel
    if level and oldCharLevel and level > oldCharLevel and settings.friendLevels
        and (level >= 30 or math.floor(level / 10) > math.floor(oldCharLevel / 10)) then
        -- "is now a level 42 Warrior" - the class makes it clear it's the
        -- character's level, not the jump level.
        local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
        local className = class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]
        local what = className and ("a level %d %s"):format(level, className)
            or ("character level %d"):format(level)
        Notify(("%s is now %s%s"):format(ColoredName(key, class), what,
            level >= maxLevel and " - max level!" or "!"), level >= maxLevel)
    end
    if newPrestige and newPrestige > (oldPrestige or 0) and settings.friendRankUps then
        -- A new tier (bronze, silver...) is a big one.
        local tier, tierName = PrestigeTier(newPrestige)
        local newTier = tier > (PrestigeTier(oldPrestige))
        Notify(("%s reached Prestige %d %s%s"):format(ColoredName(key, class), newPrestige,
            PrestigeIcon(newPrestige), newTier and (" - %s tier!"):format(tierName) or "!"), newTier)
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
        -- Levels come quickly now: a chat line every 5 levels.
        if math.floor(level / 5) > math.floor(knownLevel / 5) then
            Print(GOLD:format(("Jump level %d!"):format(level)))
        end
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
    acct.prestigeSpent = acct.prestigeSpent + PRESTIGE_XP
    knownLevel = EntryLevel(Me())
    dirty = true
    local tier, tierName = PrestigeTier(acct.prestige)
    Notify(GOLD:format(("Prestige %d %s%s Your jump level starts over - total jumps and ranks are kept.")
        :format(acct.prestige, PrestigeIcon(acct.prestige),
            tier > (PrestigeTier(acct.prestige - 1)) and (" - %s tier!"):format(tierName) or "!")), true)
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
    -- 1.8.7: the highest jump level reached (a star means you've been at the top).
    -- (knownLevel: from the check before this one - no need to add it all up again)
    acct.stats.bestLevel = math.max(acct.stats.bestLevel or 0, knownLevel or 0,
        (acct.prestige or 0) > 0 and PRESTIGE_LEVEL or 0)
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

---------------------------------------------------------------------------
-- Daily challenges: three a day (easy, medium, hard) for extra XP, reset
-- with the game's daily reset. Everyone gets the same three each day (picked
-- from the day's id), so friends can race each other on them. Only things
-- you can do on your own.
---------------------------------------------------------------------------
local Daily = {}
do
    local TIERS = {
        { key = "easy",   label = "Easy",   xp = 100, color = "|cff1eff00" },
        { key = "medium", label = "Medium", xp = 250, color = "|cff0070dd" },
        { key = "hard",   label = "Hard",   xp = 500, color = "|cffa335ee" },
    }
    -- stat: what's counted today. bestMinute/bestHour: most jumps within one
    -- minute / one clock hour; streak: most jumps in a row without dying.
    local POOLS = {
        easy = {
            { stat = "jumps",      goal = 200,  desc = "Jump 200 times." },
            { stat = "mounted",    goal = 50,   desc = "Jump 50 times while mounted." },
            { stat = "swim",       goal = 25,   desc = "Jump 25 times in water." },
            { stat = "zones",      goal = 3,    desc = "Jump in 3 different zones." },
            { stat = "resting",    goal = 100,  desc = "Jump 100 times in a city or inn." },
            { stat = "bestMinute", goal = 25,   desc = "Jump 25 times within one minute." },
        },
        medium = {
            { stat = "jumps",      goal = 1000, desc = "Jump 1,000 times." },
            { stat = "mounted",    goal = 300,  desc = "Jump 300 times while mounted." },
            { stat = "combat",     goal = 150,  desc = "Jump 150 times in combat." },
            { stat = "zones",      goal = 6,    desc = "Jump in 6 different zones." },
            { stat = "bestHour",   goal = 300,  desc = "Jump 300 times in one hour." },
            { stat = "streak",     goal = 500,  desc = "Jump 500 times without dying." },
            { stat = "bestMinute", goal = 45,   desc = "Jump 45 times within one minute." },
        },
        hard = {
            { stat = "jumps",      goal = 3000, desc = "Jump 3,000 times." },
            { stat = "bestHour",   goal = 1000, desc = "Jump 1,000 times in one hour." },
            { stat = "bestMinute", goal = 65,   desc = "Jump 65 times within one minute." },
            { stat = "combat",     goal = 500,  desc = "Jump 500 times in combat." },
            { stat = "instance",   goal = 300,  desc = "Jump 300 times in a dungeon or raid." },
            { stat = "streak",     goal = 2000, desc = "Jump 2,000 times without dying." },
            { stat = "zones",      goal = 12,   desc = "Jump in 12 different zones." },
        },
    }

    local function SecondsLeft()
        if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
            local secs = Plain(C_DateAndTime.GetSecondsUntilDailyReset())
            if secs and secs > 0 then return secs end
        end
        return 86400 - GetServerTime() % 86400      -- fallback: midnight UTC
    end
    Daily.SecondsLeft = SecondsLeft

    -- The day's id: the hour (since 1970) of the next daily reset - the same
    -- on every computer.
    local function DayId()
        return math.floor((GetServerTime() + SecondsLeft()) / 3600 + 0.5)
    end

    -- Today's state, started fresh when the day changes.
    local function State()
        local d = acct.daily
        local id = DayId()
        if not d or d.day ~= id then
            d = { day = id, c = {}, zones = {}, done = {} }
            acct.daily = d
        end
        return d
    end

    -- The day's three challenges, the same for everyone; no two on the same stat.
    local picked = {}
    local function Today()
        local id = DayId()
        if picked.day == id then return picked.list end
        local used, list = {}, {}
        for t, tier in ipairs(TIERS) do
            local pool = POOLS[tier.key]
            local i = math.floor(((id * 2654435761 + t * 40503) % 4294967296) / 65536) % #pool + 1
            for _ = 1, #pool do
                if not used[pool[i].stat] then break end
                i = i % #pool + 1
            end
            used[pool[i].stat] = true
            list[t] = { tier = tier, def = pool[i] }
        end
        picked.day, picked.list = id, list
        return list
    end

    local function Progress(d, def) return math.min(d.c[def.stat] or 0, def.goal) end

    -- For the window: { label, color, desc, goal, progress, xp, done } x3.
    function Daily.List()
        local d = State()
        local out = {}
        for i, e in ipairs(Today()) do
            out[i] = { label = e.tier.label, color = e.tier.color, desc = e.def.desc, goal = e.def.goal,
                progress = Progress(d, e.def), xp = e.tier.xp, done = d.done[e.tier.key] }
        end
        return out
    end

    function Daily.DoneCount()
        local d, n = State(), 0
        for _, tier in ipairs(TIERS) do if d.done[tier.key] then n = n + 1 end end
        return n
    end

    local function Check()
        local d = State()
        for _, e in ipairs(Today()) do
            local key = e.tier.key
            if not d.done[key] and (d.c[e.def.stat] or 0) >= e.def.goal then
                d.done[key] = time()
                acct.dailyXP = (acct.dailyXP or 0) + e.tier.xp
                acct.dailyDone = (acct.dailyDone or 0) + 1
                dirty = true
                -- 1.8.7: all three on the same day is a "perfect day".
                if not d.perfect and Daily.DoneCount() == #TIERS then
                    d.perfect = true
                    acct.stats.perfectDays = (acct.stats.perfectDays or 0) + 1
                end
                if settings.myProgress then
                    Notify(GOLD:format(("Daily challenge complete (%s): %s (+%d XP)")
                        :format(e.tier.label, e.def.desc, e.tier.xp)), true)
                end
            end
        end
    end

    -- After every counted jump. flags: what kind of jump (mounted, swim, ...).
    function Daily.OnJump(flags, mapID, minuteCount)
        local d = State()
        local c = d.c
        c.jumps = (c.jumps or 0) + 1
        for name in pairs(flags) do c[name] = (c[name] or 0) + 1 end
        if mapID and not d.zones[mapID] then
            d.zones[mapID] = true
            c.zones = (c.zones or 0) + 1
        end
        c.bestMinute = math.max(c.bestMinute or 0, minuteCount or 0)
        if acct.hourId == CurrentHourId() then c.bestHour = math.max(c.bestHour or 0, acct.hour or 0) end
        d.run = (d.run or 0) + 1
        c.streak = math.max(c.streak or 0, d.run)
        Check()
    end

    -- Weekly goal (1.8.10): everyone on your leaderboard works on it together.
    -- This week's jumps of all of you are added up (they're shared already),
    -- against three goals that grow with the number of ACTIVE players - those
    -- with WEEKLY_ACTIVE jumps or more that week - so people who rarely jump
    -- don't make it harder. The first WEEKLY_FULL active players count in
    -- full, each one beyond that for half; and the goals are never sized for
    -- fewer than WEEKLY_FLOOR players (or your whole leaderboard, if that's
    -- smaller), so one keen player can't finish them alone on Monday. Each
    -- goal reached gives XP to everyone who has done their bit that week
    -- (WEEKLY_MIN jumps). Every player sees their own leaderboard's total, so
    -- the goal is per circle of friends.
    local WEEKLY = {
        { label = "Bronze", per = 2500,  xp = 250,  color = "|cffe0915a" },
        { label = "Silver", per = 6000,  xp = 500,  color = "|cffd0d8e6" },
        { label = "Gold",   per = 12000, xp = 1000, color = "|cffffd100" },
    }
    local WEEKLY_MIN = 500
    local WEEKLY_ACTIVE, WEEKLY_FULL, WEEKLY_FLOOR = 100, 10, 3

    function Daily.Weekly()
        local wid = CurrentWeekId()
        local w = acct.weekly
        -- (A test build of 1.8.10 counted the whole week from the start and
        -- paid out at once: take that back. Nobody else has such data.)
        if w and not w.v then
            acct.weeklyXP, acct.stats.weeklyTiers, acct.stats.weeklyGold = nil, nil, nil
            if acct.done.team1 then
                acct.done.team1 = nil
                acct.challengeXP = math.max(0, acct.challengeXP - 500)
            end
            w = nil
        end
        if not w or w.id ~= wid then
            w = { id = wid, claimed = {}, v = 2 }
            -- The very first week starts when you get the weekly goal (in the
            -- middle of a week): only jumps from then on count. base = what
            -- everyone had done that week already.
            if not acct.weeklySince then
                acct.weeklySince = wid
                w.base, w.baseMine = {}, MyWeekCount()
            end
            acct.weekly = w
        end
        local base = w.base
        local mine = math.max(0, MyWeekCount() - (w.baseMine or 0))
        local total, members = mine, 1
        local active = mine >= WEEKLY_ACTIVE and 1 or 0
        for key, data in pairs(JumpCounterDB.peers) do
            if not JumpCounterDB.chars[key] then
                members = members + 1
                if wid and data.weekId == wid then
                    local week = data.week or 0
                    if base then
                        -- (someone first seen later that week: from then on)
                        base[key] = base[key] or week
                        week = math.max(0, week - base[key])
                    end
                    total = total + week
                    if week >= WEEKLY_ACTIVE then active = active + 1 end
                end
            end
        end
        -- How many players the goals are sized for.
        local size = math.max(active, math.min(WEEKLY_FLOOR, members))
        size = math.min(size, WEEKLY_FULL) + math.max(0, size - WEEKLY_FULL) * 0.5
        local tiers = {}
        for i, t in ipairs(WEEKLY) do
            tiers[i] = { label = t.label, color = t.color, xp = t.xp, goal = math.floor(t.per * size + 0.5),
                done = w.claimed[i] and true or false }
        end
        return { total = total, members = members, active = active, mine = mine, min = WEEKLY_MIN,
            tiers = tiers, state = w, partial = base ~= nil }
    end

    -- Hands out the goals reached (after your jumps and at login).
    function Daily.CheckWeekly()
        local info = Daily.Weekly()
        if info.mine < WEEKLY_MIN then return end
        for i, t in ipairs(info.tiers) do
            if not t.done and info.total >= t.goal then
                info.state.claimed[i] = true
                acct.weeklyXP = (acct.weeklyXP or 0) + t.xp
                acct.stats.weeklyTiers = (acct.stats.weeklyTiers or 0) + 1
                if i == #info.tiers then acct.stats.weeklyGold = (acct.stats.weeklyGold or 0) + 1 end
                dirty = true
                if settings.myProgress then
                    Notify(GOLD:format(("Weekly goal reached together (%s): %s jumps this week! (+%d XP)")
                        :format(t.label, BreakUpLargeNumbers(t.goal), t.xp)), true)
                end
            end
        end
    end

    function Daily.OnDeath()
        State().run = 0
    end
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
    local flags = {}                  -- for today's daily challenges
    local function inc(name) st[name] = (st[name] or 0) + 1; flags[name] = true end
    local plain = Plain

    if plain(IsMounted()) then inc("mounted") end
    if inWater then inc("swim") end
    if plain(UnitIsGhost("player")) then inc("ghost") end
    if plain(UnitAffectingCombat("player")) then inc("combat") end
    local inInstance, instanceType = IsInInstance()
    inInstance, instanceType = plain(inInstance), plain(instanceType)
    if inInstance and (instanceType == "party" or instanceType == "raid") then
        inc("instance")
        -- 1.8.7: which dungeons and raids you've jumped in (by name).
        local name = GetInstanceInfo and plain((GetInstanceInfo()))
        if type(name) == "string" and name ~= "" then
            st.instances = st.instances or {}
            st.instances[name] = true
        end
    end
    if IsInGroup() and (plain(GetNumGroupMembers()) or 0) >= 5 then inc("group") end
    if inInstance and instanceType == "pvp" then inc("pvp") end
    if plain(IsResting()) then inc("resting") end
    if IsIndoors and plain(IsIndoors()) then inc("indoors") end          -- 1.8.7
    if IsStealthed and plain(IsStealthed()) then inc("stealth") end
    if UnitIsPVP and plain(UnitIsPVP("player")) then inc("pvpFlagged") end
    -- Only druid forms and Ghost Wolf (warrior stances are "forms" too).
    local class = charData.class
    if (class == "DRUID" or class == "SHAMAN") and (plain(GetShapeshiftForm()) or 0) > 0 then inc("shapeshift") end
    local hour = tonumber(date("%H"))
    if hour and hour < 4 then inc("night") end
    if hour then                      -- 1.8.7: the hours of the day you've jumped in
        st.hours = st.hours or {}
        st.hours[hour] = true
    end
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
    st.bestHour = math.max(st.bestHour or 0, acct.hour or 0)             -- 1.8.7

    local now = GetTime()
    table.insert(minuteJumps, now)
    while minuteJumps[1] and minuteJumps[1] < now - 60 do table.remove(minuteJumps, 1) end
    st.bestMinute = math.max(st.bestMinute or 0, #minuteJumps)

    inc("sinceDeath")
    st.bestSinceDeath = math.max(st.bestSinceDeath or 0, st.sinceDeath)
    flags.sinceDeath = nil
    Daily.OnJump(flags, mapID, #minuteJumps)
    Daily.CheckWeekly()

    CheckChallenges()
end

---------------------------------------------------------------------------
-- Jump duels: now and then two players who are jumping around are paired
-- for a 30-second jump-off. Whoever jumps most wins, and everyone online
-- with the addon sees the result.
--
-- Messages (sent like scores: guild and friends who use the addon):
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
    local DUEL_LENGTH = 30            -- 1.8.4: 30 s (60 s in 1.8.x, 120 s in 1.7.x - the invite says which)
    local OLD_DUEL_LENGTH = 180       -- invites from 1.5.0 / 1.6.0
    local DUEL_LEAD = 15              -- seconds from invite to start (countdown)
    -- 1.8.2: cooldowns per opponent, so a bigger group gets more duels (with
    -- different people) while two players still meet at most every 30 min.
    local DUEL_COOLDOWN = 600         -- after any duel: 10 minutes before the next
    local PAIR_COOLDOWN = 1800        -- the same two players: once per 30 minutes
    local DUEL_CHANCE = 1 / 90        -- chance per minute to start one with a single opponent around
    local DUEL_ACTIVE = 300           -- opponents must have jumped in the last 5 min
    local DUEL_MIN_VERSION = "1.7.0"   -- older versions would count 3 minutes
    -- In a duel, jumps count no faster than normal jumping on flat ground
    -- (one per DUEL_JUMP_TIME, with one jump of slack), wherever you stand:
    -- up a slope, on stairs, under a low roof or at the water surface a jump
    -- lands sooner. Outside duels those jumps all count as before.
    -- Older versions don't cap their own count (52 in 30 s on a steep slope),
    -- so a score we're told is cut to the most the cap allows (DuelMax).
    local DUEL_JUMP_TIME = 0.82
    local function DuelMax(length) return math.floor((length or 30) / DUEL_JUMP_TIME) + 2 end
    -- 1.8.13: a tie goes to whoever reached that score first. Each player
    -- sends when their last counted jump was (hundredths of a second after
    -- the start, on the server's clock) with their final score. The server
    -- clock only gives whole seconds, so we watch for the moment it ticks.
    local duelClock = { sec = 0, at = 0 }
    function duelClock.Now()
        local s = GetServerTime()
        if s ~= duelClock.sec then return s end
        return s + math.min(GetTime() - duelClock.at, 0.99)
    end
    local DUEL_WIN_XP, DUEL_PLAY_XP = 100, 25

    local duel                        -- our duel: { id, start, finish, state, opp, mine, theirs, route, ... }
    local SendDuelTo, ChallengeNext
    -- When our last duel ended (server time) is saved account-wide in
    -- acct.lastDuelEnd, so /reload or switching characters doesn't reset the
    -- cooldown.
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

    -- Only to the opponent: the way their messages reach us (whisper /
    -- Battle.net directly, else guild chat). Unknown: everyone.
    function SendDuelTo(d, ...)
        local parts = { ... }
        for i = 1, select("#", ...) do parts[i] = tostring(parts[i] or "") end
        local msg = table.concat(parts, ":")
        local route = d.route
        if route and route.reply then
            route.reply(msg)
        elseif route and route.via == "GUILD" and IsInGuild() then
            Enqueue(msg, "GUILD")
        else
            Send(msg)
        end
    end

    -- True when we can't jump right now: on a flight path, in a vehicle or
    -- swimming (1.8.5: under water you can't jump at all, so no duel starts
    -- while you're in the water - at the surface we can't tell the difference).
    local function CantJump()
        local function on(f)
            if not f then return false end
            local v = f("player")
            if issecretvalue and issecretvalue(v) then return false end
            return v and true or false
        end
        -- 1.8.4: being dead or a ghost doesn't stop you - you can duel as a ghost.
        return on(UnitOnTaxi) or on(UnitInVehicle) or on(IsSwimming)
    end

    -- Seconds until we may duel again (0 = now). Applies to every duel,
    -- random or started with /jumps duel (1.8.2: /jumps duel used to skip it).
    local function CooldownLeft(now)
        return math.max(0, DUEL_COOLDOWN - (now - (acct.lastDuelEnd or 0)))
    end

    -- Seconds until we may duel this opponent again (0 = now). Saved
    -- account-wide in acct.duelPairs = { [their acct] = server time it ended }.
    local function PairLeft(now, oppAcct)
        local last = acct.duelPairs and oppAcct and acct.duelPairs[oppAcct]
        return last and math.max(0, PAIR_COOLDOWN - (now - last)) or 0
    end

    local function CanDuel(now, oppAcct)
        return settings.duels and not duel and not Plain(UnitIsAFK("player")) and not CantJump()
            and CooldownLeft(now) == 0 and PairLeft(now, oppAcct) == 0
    end

    -- 1.8.4: why we can't duel this opponent now (sent back as DN), with the
    -- seconds until we can (for cooldowns), or nil if we can.
    local function DeclineReason(now, oppAcct)
        local function on(f)
            if not f then return false end
            local v = f("player")
            if issecretvalue and issecretvalue(v) then return false end
            return v and true or false
        end
        if not settings.duels then return "off" end
        if duel then return "busy" end
        if Plain(UnitIsAFK("player")) then return "afk" end
        if on(UnitOnTaxi) then return "taxi" end
        if on(UnitInVehicle) then return "vehicle" end
        if on(IsSwimming) then return "swim" end
        if PairLeft(now, oppAcct) > 0 then return "pair", PairLeft(now, oppAcct) end
        if CooldownLeft(now) > 0 then return "cooldown", CooldownLeft(now) end
    end

    local DECLINE_TEXT = {
        off = "%s has jump duels turned off.",
        busy = "%s is already in a jump duel.",
        afk = "%s is AFK.",
        taxi = "%s is on a flight path.",
        vehicle = "%s is in a vehicle.",
        swim = "%s is swimming.",
        dead = "%s is dead.",
        cooldown = "%s just had a duel - they can duel again in %d min.",
        pair = "You and %s dueled recently - you can duel each other again in %d min.",
    }
    -- How long to skip someone after they declined (seconds) when picking.
    local DECLINE_SKIP = { off = 1800, busy = 90, afk = 300, taxi = 180, vehicle = 180, swim = 60, dead = 120 }

    -- Players on 1.5.0+ who jumped recently and aren't in a duel.
    local function DuelCandidates(now)
        local list = {}
        for key, data in pairs(JumpCounterDB.peers) do
            -- Cheap checks first: this runs every minute over everyone we know.
            if data.acct and (data.hops or 0) == 0          -- heard directly, so we can reach them
                and time() - (data.lastJumped or 0) <= DUEL_ACTIVE and (busyUntil[data.acct] or 0) < now
                and PairLeft(now, data.acct) == 0
                and data.version and not IsNewerVersion(DUEL_MIN_VERSION, data.version) then
                table.insert(list, { acct = data.acct, name = DisplayName(key), class = data.class })
            end
        end
        return list
    end

    -- The duel window: small, as it always was - who you're up against, the
    -- score, and the clock - in the same look as the on-screen counter (1.8.9).
    -- timeText: the line under the score (clock or result).
    local function FillDuelFrame(d, timeText)
        local f = duelFrame
        local mine, theirs = d.mine or 0, d.theirs or 0
        f.title:SetText("Jump duel vs " .. ClassColored(d.opp.name, d.opp.class))
        local lead = mine > theirs and "|cff33ff33%d|r" or (mine < theirs and "|cffff5555%d|r" or "|cffffffff%d|r")
        f.score:SetText(("You " .. lead .. "  -  %d"):format(mine, theirs))
        f.time:SetText(timeText)
    end

    local function UpdateDuelFrame(now)
        local f = duelFrame
        if not f then return end
        if duel and duel.state == "on" then
            local text
            if now < duel.start then
                text = ("Starts in %d..."):format(duel.start - now)
            elseif now < duel.finish then
                local left = duel.finish - now
                text = ("%d:%02d left - jump!"):format(math.floor(left / 60), left % 60)
            else
                text = "Time! Waiting for the final score..."
            end
            FillDuelFrame(duel, text)
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
        acct.lastDuelEnd = now
        acct.duelPairs = acct.duelPairs or {}
        for a, t in pairs(acct.duelPairs) do
            if now - t > PAIR_COOLDOWN then acct.duelPairs[a] = nil end
        end
        if d.opp and d.opp.acct then acct.duelPairs[d.opp.acct] = now end
        if duelFrame then
            FillDuelFrame(d, text)
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
            -- No result: no pair cooldown, and only 5 minutes before the next.
            acct.lastDuelEnd = acct.lastDuelEnd - DUEL_COOLDOWN + 300
            if acct.duelPairs then acct.duelPairs[d.opp.acct] = nil end
            return
        end
        local me, them = d.mine, d.theirs
        local xp, text, short = DUEL_PLAY_XP
        local myPoints = acct.duelPoints or 0
        local rankBefore = DuelRank(myPoints)
        -- Their duel points, if we know them (1.8.2+); otherwise treat them as equal.
        local theirPoints
        for _, data in pairs(JumpCounterDB.peers) do
            if data.acct == d.opp.acct and data.duelPoints then theirPoints = data.duelPoints end
        end
        local result = (me > them and 1) or (me < them and 0) or 0.5
        -- 1.8.13: a tie goes to whoever got there first (if both said when).
        local first = ""
        if result == 0.5 and me > 0 and d.oppFinal and d.lastAt and d.oppAt and d.lastAt ~= d.oppAt then
            result = d.lastAt < d.oppAt and 1 or 0
            first = result == 1 and " - you got there first" or " - they got there first"
        end
        -- 1.8.7: best score in one duel, and wins in a row.
        acct.stats.bestDuel = math.max(acct.stats.bestDuel or 0, me)
        acct.winStreak = (result == 1) and (acct.winStreak or 0) + 1 or 0
        acct.stats.bestWinStreak = math.max(acct.stats.bestWinStreak or 0, acct.winStreak)
        local change = DUEL_POINTS.Change(myPoints, theirPoints, result)
        local note = ""
        if change < 0 and myPoints < DUEL_POINTS.protected then
            change, note = 0, " |cff999999(no points lost below " .. DuelRank(DUEL_POINTS.protected) .. ")|r"
        elseif result == 0 and (acct.lossStreak or 0) >= DUEL_POINTS.shieldAfter then
            change, note = 0, " |cff999999(shield: no points lost after 3 losses in a row)|r"
        end
        change = math.max(change, -myPoints)            -- never below 0
        local pts = (change >= 0 and "+" or "") .. change .. " duel points"
        if result == 1 then
            acct.duelWins = (acct.duelWins or 0) + 1
            acct.lossStreak = 0
            xp = DUEL_WIN_XP
            text = ("You won the jump duel against %s, %d - %d%s! (+%d XP, %s)"):format(opp, me, them, first, xp, pts)
            short = "|cff33ff33You won!|r"
        elseif result == 0 then
            acct.duelLosses = (acct.duelLosses or 0) + 1
            -- The shield resets the streak, so it comes again after 3 more.
            if change == 0 and note:find("shield") then
                acct.lossStreak = 0
            else
                acct.lossStreak = (acct.lossStreak or 0) + 1
            end
            text = ("%s won the jump duel, %d - %d%s. (+%d XP for playing, %s)"):format(opp, them, me, first, xp, pts)
            short = "Good fight!"
        else
            acct.duelDraws = (acct.duelDraws or 0) + 1
            acct.lossStreak = 0
            text = ("The jump duel against %s is a draw, %d - %d! (+%d XP, %s)"):format(opp, me, them, xp, pts)
            short = "Draw!"
        end
        text = text .. note
        if not d.oppFinal then text = text .. " |cff999999(their last known score)|r" end
        acct.duelXP = (acct.duelXP or 0) + xp
        acct.duelPoints = myPoints + change
        dirty = true
        Notify(GOLD:format(text), true)
        local rankAfter = DuelRank(acct.duelPoints)
        if acct.duelPoints > myPoints and rankAfter ~= rankBefore then
            Notify(GOLD:format(("Duel rank up: %s!"):format(rankAfter)), true)
        elseif acct.duelPoints < myPoints and rankAfter ~= rankBefore then
            Print(("Your duel rank is now %s."):format(rankAfter))
        end
        EndDuel(d, short)
        CheckChallenges()
        RefreshBoardSoon()
    end

    local function DuelTick()
        local now = GetServerTime()
        local d = duel
        if d and d.state ~= "on" and now >= d.start then
            -- The invite was never confirmed.
            duel = nil
            if d.manual and d.state == "invited" then
                -- No answer (versions before 1.8.4 don't say why).
                Print(("%s didn't accept the duel (busy, AFK, on a flight path, dueled recently, "
                    .. "or duels turned off)."):format(
                    ClassColored(d.opp.name, d.opp.class)))
                busyUntil[d.opp.acct] = now + 300
                ChallengeNext((d.tries or 1) + 1)
            end
        elseif d and d.state == "on" then
            if now >= d.finish and not d.sentFinal then
                d.sentFinal, d.doneAt = true, now
                SendDuel("DF", d.id, acct.id, Clean(MyDuelName()), charData.class, d.mine, d.lastAt or "")
            elseif now < d.finish and d.mine ~= (d.sentCount or 0) and GetTime() - (d.lastProgress or 0) >= 0.95 then
                -- 1.8.3: about once a second (was every 5 s), and only to the
                -- opponent, so it stays within the game's message limit.
                d.sentCount, d.lastProgress = d.mine, GetTime()
                SendDuelTo(d, "DP", d.id, acct.id, d.mine)
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
        local length = duel.finish - duel.start
        local lengthText = length % 60 == 0
            and (length == 60 and "1 minute" or ("%d minutes"):format(length / 60))
            or ("%d seconds"):format(length)
        Notify(GOLD:format(("JUMP DUEL vs %s! Most jumps in %s wins - starts in %d seconds!")
            :format(ClassColored(duel.opp.name, duel.opp.class), lengthText,
            math.max(0, duel.start - now))), true)
        UpdateDuelFrame(now)
    end

    -- Invite a random active player. Returns the opponent, or nil.
    local function TryStartDuel(manual, tries)
        local now = GetServerTime()
        local list = DuelCandidates(now)
        if #list == 0 then return nil end
        local opp = list[math.random(#list)]
        local start = now + DUEL_LEAD
        duel = { id = acct.id .. now .. (tries or 1), start = start, finish = start + DUEL_LENGTH, state = "invited",
            opp = opp, mine = 0, theirs = 0, manual = manual, tries = tries or 1 }
        SendDuel("DQ", duel.id, start, acct.id, Clean(MyDuelName()), charData.class,
            opp.acct, manual and "1" or "", DUEL_LENGTH)
        StartDuelTicker()
        return opp
    end

    function OnDuelMessage(msg, reply, via)
        local tag, id, a1, a2, a3, a4, a5, a6, a7 = strsplit(":", msg)
        local now = GetServerTime()
        if not id or id == "" then return end
        -- Remember how this message reached us, to send our progress back the
        -- same way (a direct route - whisper / Battle.net - beats the guild).
        local from = (tag == "DQ" or tag == "DG") and a2 or a1
        local function Learn()
            if duel and duel.id == id and duel.opp.acct == from then
                if reply or not duel.route then duel.route = { reply = reply, via = via } end
            end
        end
        if tag == "DQ" then
            -- Invite: a1 start, a2 their acct, a3 name, a4 class, a5 target acct, a6 manual, a7 length
            local start = tonumber(a1)
            local length = tonumber(a7) or OLD_DUEL_LENGTH
            if length < 30 or length > 600 then return end
            if a5 ~= acct.id or a2 == acct.id or not start then return end
            if start - now < 5 or start - now > 60 then return end
            local reason, secs = DeclineReason(now, a2)
            if reason then
                if a6 == "1" then
                    SendDuelTo({ route = { reply = reply, via = via } }, "DN", id, acct.id, reason, secs or 0)
                end
                return
            end
            duel = { id = id, start = start, finish = start + length, state = "accepted",
                opp = { acct = a2, name = a3, class = (a4 ~= "" and a4) or nil }, mine = 0, theirs = 0 }
            Learn()
            SendDuel("DA", id, acct.id)
            StartDuelTicker()
        elseif tag == "DA" then
            Learn()
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
            -- Both are busy for the duel and their cooldown after it.
            busyUntil[a2], busyUntil[a5] = start + DUEL_LENGTH + DUEL_COOLDOWN, start + DUEL_LENGTH + DUEL_COOLDOWN
            if duel and duel.id == id and duel.state == "accepted" then
                duel.state, duel.finish, duel.start = "on", start + (duel.finish - duel.start), start
                AnnounceDuelStart()
            end
        elseif tag == "DN" then
            -- Declined: a1 their acct, a2 reason, a3 seconds until they can.
            if duel and duel.id == id and duel.state == "invited" and a1 == duel.opp.acct then
                local d, secs = duel, tonumber(a3) or 0
                local name = ClassColored(d.opp.name, d.opp.class)
                local text = DECLINE_TEXT[a2] or "%s can't duel right now."
                Print(text:format(name, math.ceil(secs / 60)))
                if a2 == "pair" then
                    acct.duelPairs = acct.duelPairs or {}
                    acct.duelPairs[a1] = now - (PAIR_COOLDOWN - secs)
                else
                    busyUntil[a1] = now + ((a2 == "cooldown") and secs or (DECLINE_SKIP[a2] or 300))
                end
                duel = nil
                if d.manual then ChallengeNext((d.tries or 1) + 1) end
            end
        elseif tag == "DP" then
            if duel and duel.id == id and a1 == duel.opp.acct then
                Learn()
                duel.theirs = math.min(math.max(duel.theirs, tonumber(a2) or 0), DuelMax(duel.finish - duel.start))
                duel.heard = true
                UpdateDuelFrame(now)
            end
        elseif tag == "DF" then
            -- Final: a1 acct, a2 name, a3 class, a4 count, a5 when they got there (1.8.13)
            local count = tonumber(a4)
            if not count or a1 == acct.id then return end
            local most = DuelMax(duel and duel.id == id and (duel.finish - duel.start) or DUEL_LENGTH)
            local at = count <= most and tonumber(a5) or nil
            count = math.min(count, most)
            if duel and duel.id == id then
                if a1 == duel.opp.acct then
                    duel.theirs, duel.oppFinal, duel.heard, duel.oppAt = count, true, true, at
                end
                return
            end
            -- Someone else's duel: announce once both final scores are in.
            local r = duelResults[id] or { finish = now, players = {} }
            duelResults[id] = r
            if r.shown or r.players[a1] then return end
            r.players[a1] = { name = a2, class = (a3 ~= "" and a3) or nil, count = count, at = at }
            local list = {}
            for _, p in pairs(r.players) do table.insert(list, p) end
            if #list == 2 then
                r.shown = true
                if settings.duelNews then
                    table.sort(list, function(x, y) return x.count > y.count end)
                    local a, b = list[1], list[2]
                    -- A tie goes to whoever got there first (1.8.13).
                    local draw, first = a.count == b.count, ""
                    if draw and a.count > 0 and a.at and b.at and a.at ~= b.at then
                        if b.at < a.at then a, b = b, a end
                        draw, first = false, " - got there first"
                    end
                    Print(("|cffffd100Jump duel:|r %s %s %s, %d - %d%s!"):format(
                        ClassColored(a.name, a.class), draw and "and" or "beat",
                        ClassColored(b.name, b.class), a.count, b.count, first)
                        .. (draw and " It's a draw." or ""))
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
                -- No faster than normal jumping (see DUEL_JUMP_TIME).
                local t = GetTime()
                if t >= (duel.capAt or 0) then
                    duel.capAt = math.max(duel.capAt or 0, t - DUEL_JUMP_TIME) + DUEL_JUMP_TIME
                    duel.mine = duel.mine + 1
                    duel.lastAt = math.max(0, math.floor((duelClock.Now() - duel.start) * 100 + 0.5))
                    UpdateDuelFrame(now)
                end
            end
        end
    end

    function CreateDuelFrame()
        -- Watches the server clock tick while a duel is on (see duelClock).
        CreateFrame("Frame"):SetScript("OnUpdate", function()
            if not duel then return end
            local s = GetServerTime()
            if s ~= duelClock.sec then duelClock.sec, duelClock.at = s, GetTime() end
        end)
        local f = CreateFrame("Frame", "JumpCounterDuelFrame", UIParent, "BackdropTemplate")
        f:SetSize(250, 70)
        StyleBox(f, "Jump duel")
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
        -- The title is on the plate ("Jump duel vs <name>"); then the score
        -- and the clock.
        f.title:SetWidth(232)
        f.title:SetWordWrap(false)
        f.score = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        f.score:SetPoint("TOP", 0, -27)
        f.time = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.time:SetPoint("TOP", f.score, "BOTTOM", 0, -4)
        f:Hide()
        duelFrame = f
    end

    -- Every minute, maybe start a random duel.
    -- The more opponents are around, the likelier. Measured in the simulator
    -- (players hopping on and off): with two of you about one duel per hour
    -- each (as before), with 4 about one per 25 min, with 6 about one per 20.
    function MaybeStartRandomDuel()
        local now = GetServerTime()
        if not CanDuel(now) then return end
        local n = #DuelCandidates(now)
        local chance = (n == 1) and DUEL_CHANCE or math.min(5, n) / 30
        if n > 0 and math.random() < chance then TryStartDuel(false) end
    end

    -- /jumps duel: challenge a random player who is jumping around right now.
    function DuelCommand()
        if not settings.duels then
            Print("Jump duels are turned off - turn them on in /jumps settings.")
        elseif duel then
            Print("You're already in a jump duel.")
        elseif Plain(IsSwimming()) then
            Print("You can't start a jump duel while swimming - get out of the water first.")
        elseif CooldownLeft(GetServerTime()) > 0 then
            Print(("You had a jump duel recently - you can duel again in %d min.")
                :format(math.ceil(CooldownLeft(GetServerTime()) / 60)))
        else
            ChallengeNext(1)
        end
    end

    -- /jumps duel, try number "tries": challenge someone; after a decline the
    -- next player is tried automatically (up to 3 tries).
    function ChallengeNext(tries)
        if tries > 3 then
            Print("No one could duel right now - try again in a few minutes.")
            return
        end
        do
            local opp = TryStartDuel(true, tries)
            if opp then
                Print(("%s %s to a jump duel..."):format(tries > 1 and "Trying" or "Challenging",
                    ClassColored(opp.name, opp.class)))
            elseif tries > 1 then
                Print("Nobody else to duel right now.")
            else
                -- Anyone left out only because we dueled them recently?
                local now, waits = GetServerTime(), {}
                for key, data in pairs(JumpCounterDB.peers) do
                    local left = data.acct and PairLeft(now, data.acct) or 0
                    if left > 0 and time() - (data.lastJumped or 0) <= DUEL_ACTIVE then
                        table.insert(waits, ("%s (%d min)"):format(
                            ClassColored(DisplayName(key), data.class), math.ceil(left / 60)))
                    end
                end
                if #waits > 0 then
                    Print("You dueled them recently - the same two players can duel once per 30 minutes: "
                        .. table.concat(waits, ", ") .. ".")
                else
                    Print("Nobody to duel right now - opponents need v" .. DUEL_MIN_VERSION
                        .. " or newer and must have jumped in the last 5 minutes.")
                end
            end
        end
    end
end


---------------------------------------------------------------------------
-- The crown: whoever has jumped most this (clock) hour holds it, shown on
-- the leaderboard. When the hour ends, whoever holds it wins it: bonus XP
-- and a crown on their record. A fresh race every hour, so newer players
-- have a real shot. Each player's addon decides from the scores it knows.
---------------------------------------------------------------------------
do
    local CROWN_MIN = 25              -- jumps this hour needed to hold the crown
    local CROWN_XP = 50
    local CROWN_NEWS_GAP = 300        -- at most one "took the crown" line per 5 minutes
    local CROWN_QUIET = 1200          -- no "took the crown" lines in an hour's first 20 minutes
                                      -- (everyone starts at 0 and the lead flips constantly)
    local holderHour, holderKey, holderClass, holderCount
    local started = false
    local lastNews = -CROWN_NEWS_GAP

    -- The leader this hour: key, jumps, class (a tie keeps the crown with
    -- whoever had it). Runs every few seconds, so it just scans for the
    -- highest count instead of building and sorting the whole leaderboard.
    local function Leader()
        local hid = CurrentHourId()
        local bestKey, bestCount, bestClass = nil, 0, nil
        local function consider(key, count, class)
            if count > bestCount or (count == bestCount and key == holderKey) then
                bestKey, bestCount, bestClass = key, count, class
            end
        end
        consider(playerKey, (acct.hourId == hid) and (acct.hour or 0) or 0, charData.class)
        local chars = JumpCounterDB.chars
        for key, data in pairs(JumpCounterDB.peers) do
            if data.hourId == hid and data.hour and not chars[key] then consider(key, data.hour, data.class) end
        end
        if bestCount < CROWN_MIN then return nil end
        return bestKey, bestCount, bestClass
    end

    -- Who the chat last said holds the crown. Changes in between (too soon
    -- after the last line, or early in the hour) aren't lost: once a line is
    -- allowed again and the holder differs, the current holder is announced.
    local announcedKey

    -- Returns true if the line was shown.
    local function CrownNews(key, prev, class, count)
        if not settings.crownNews or GetTime() - lastNews < CROWN_NEWS_GAP then return false end
        if GetServerTime() % 3600 < CROWN_QUIET then return false end
        lastNews = GetTime()
        local name = ColoredName(key, class)
        if key == playerKey then
            Notify(GOLD:format(("You took the crown! Most jumps this hour: %d."):format(count)))
        elseif prev == playerKey then
            Print(("%s%s took your crown! (%d jumps this hour)"):format(CROWN_ICON, name, count))
        else
            Print(("%s%s took the crown with %d jumps this hour."):format(CROWN_ICON, name, count))
        end
        return true
    end

    -- Every few seconds: has the crown changed hands, or has the hour ended?
    function CrownTick()
        local hid = CurrentHourId()
        if holderHour and holderHour ~= hid then
            -- The hour is over: whoever held the crown wins it.
            if holderKey == playerKey then
                acct.crowns = (acct.crowns or 0) + 1
                acct.crownXP = (acct.crownXP or 0) + CROWN_XP
                dirty = true
                Notify(GOLD:format(("You won the crown with %d jumps this hour! (+%d XP)")
                    :format(holderCount, CROWN_XP)), true)
                CheckChallenges()
            elseif holderKey and settings.crownNews then
                Print(("%s%s won the crown with %d jumps this hour!"):format(CROWN_ICON,
                    ColoredName(holderKey, holderClass), holderCount))
            end
            holderKey, announcedKey = nil, nil
        end
        holderHour = hid

        local key, count, class = Leader()
        holderKey = key
        if key then holderClass, holderCount = class, count end
        if not started then
            announcedKey = key            -- no news for whoever had it when we logged in
        elseif key and key ~= announcedKey then
            if CrownNews(key, announcedKey, class, count) then announcedKey = key end
        end
        started = true
        if crownKey ~= key then
            crownKey = key
            RefreshBoardSoon()
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
-- In water (measured in game): a real surface hop takes you out of the water
-- - falling and no longer submerged - within a few hundredths of a second.
-- A press under the surface just swims you upward and you never leave the
-- water, with or without water breathing. So a press in water only counts
-- once we see you leave the water.
-- Also: if the jump key is still down when you come back down onto the
-- water, the game hops you straight out again. You never show as swimming
-- (only "submerged" for a frame or two), so that press happened in the air.
-- Count that hop too. (On land a held key does NOT make you jump again.)
local airPress = {
    pressAt = nil,     -- jump pressed in the water, waiting to see us leave it
    leave = 0.3,       -- ...which a surface hop does well within this
    inAir = false,     -- falling and out of the water
    touchAt = nil,     -- when we came down onto the water from the air
    rehop = 0.15,      -- a hop out of the water must follow the touch this quickly
    full = 0.82,       -- seconds a normal jump on flat ground takes
    -- 1.8.10: presses that don't lift you off the ground (netted, stunned,
    -- sitting...). The game reports the key press anyway. Once a counted
    -- press turns out to be one of those ("dud"), the next presses are only
    -- counted when we see you in the air (landPress = waiting for that).
    dudAfter = 0.25,   -- still on the ground this long after a press: it did nothing
    dud = false,
    landPress = nil,
    seesAir = false,   -- we've seen a counted jump in the air (the game reports it)
    -- 1.8.10: a jump pressed on the very frame you land. The game jumps
    -- again at once, but we never see you on the ground in between: the
    -- press looks like one made in mid-air, and the jump was skipped (3 of
    -- 51 in a recorded trace of normal jumping). Such a press is remembered
    -- (rejumpAt) when it comes right when a normal jump lands (rejumpFrom ..
    -- rejumpTo seconds after take-off), and counted when you do land, if
    -- what followed was another jump's worth of air (rejumpAir .. rejumpTo).
    rejumpAt = nil, rejumpFrom = 0.74, rejumpTo = 0.90, rejumpAir = 0.40,
}
local groundTracker = CreateFrame("Frame")
groundTracker:SetScript("OnUpdate", function()
    wasSwimming = Plain(IsSwimming()) and true or false
    local falling = Plain(IsFalling())
    local grounded = not (falling or wasSwimming or Plain(IsFlying()) or Plain(UnitOnTaxi("player")))
    -- /jumps debug: report how long each jump was in the air.
    if debugMode and jumpStartedAt and grounded and not wasGrounded then
        Print(("debug: landed after %.2f s in the air"):format(GetTime() - jumpStartedAt))
        jumpStartedAt = nil
    end
    local now = GetTime()
    local wet = wasSwimming or Plain(IsSubmerged and IsSubmerged())
    -- 1.8.7: how long a jump on land kept you in the air (jump off something
    -- high). Landing dead doesn't count; flying or a flight path cancels it.
    if airPress.jumpAt and falling then airPress.flew, airPress.seesAir = true, true end
    if airPress.jumpAt and (grounded or wet) then
        local air = now - airPress.jumpAt
        if airPress.flew or wet then
            -- Two jumps in one: a press right when the first one landed,
            -- then another jump's worth of air (see rejumpAt).
            local again = airPress.rejumpAt
            airPress.rejumpAt = nil
            if again and airPress.flew and not wet and now - again >= airPress.rejumpAir
                and now - again <= airPress.rejumpTo then
                if debugMode then
                    Print(("debug: two jumps without touching down (%.2f s + %.2f s) - second one counted")
                        :format(again - airPress.jumpAt, now - again))
                end
                airPress.Count(false, again)
                air = now - again
                airPress.flew = true
            end
            airPress.jumpAt = nil
            -- Only a time we really saw: in the air on at least one frame.
            airPress.lastAir = airPress.flew and air or nil
            if acct and airPress.flew and air > (acct.stats.bestAir or 0) and air < 120
                and not (UnitIsDeadOrGhost and Plain(UnitIsDeadOrGhost("player"))) then
                acct.stats.bestAir = air
                if air >= 2 then CheckChallenges() end
            end
        elseif air > airPress.dudAfter then
            -- Counted at the press, but you never left the ground: the press
            -- did nothing (netted, stunned, sitting...). From now on presses
            -- have to be seen in the air to count, until one is.
            airPress.jumpAt, airPress.lastAir = nil, nil
            if airPress.seesAir and not airPress.dud then
                airPress.dud = true
                if debugMode then Print("debug: that press didn't lift you off the ground") end
            end
        end
    end
    -- A press waiting to be seen in the air (after a dud).
    if airPress.landPress then
        if falling and not wet then
            airPress.landPress, airPress.dud = nil, false
            airPress.Count(false, now)
            if airPress.jumpAt then airPress.flew = true end
        elseif now - airPress.landPress > airPress.dudAfter then
            if debugMode then Print("debug: pressed but stayed on the ground - not counted") end
            airPress.landPress = nil
        end
    end
    if Plain(IsFlying()) or Plain(UnitOnTaxi("player")) then
        airPress.jumpAt, airPress.lastAir, airPress.landPress, airPress.rejumpAt = nil, nil, nil, nil
        airPress.inAir, airPress.touchAt, airPress.pressAt = false, nil, nil
    elseif falling and not wet then
        -- Out of the water and in the air: a surface hop, if it follows a
        -- press in the water or a touch of the surface right away.
        local press, touch = airPress.pressAt, airPress.touchAt
        local hopped = (press and now - press <= airPress.leave)
            or (touch and now - touch <= airPress.rehop and lastJumpTime < touch)
        if hopped and now - lastJumpTime >= SWIM_JUMP_COOLDOWN then
            if debugMode then Print("debug: hopped out of the water - counted") end
            airPress.Count(true, now)
        end
        airPress.inAir, airPress.touchAt, airPress.pressAt = true, nil, nil
    elseif wet then
        if airPress.inAir then airPress.touchAt = now end
        airPress.inAir = false
        if airPress.pressAt and now - airPress.pressAt > airPress.leave then
            if debugMode then Print("debug: pressed in the water but stayed in it (underwater) - not counted") end
            airPress.pressAt = nil
        end
    else
        airPress.inAir, airPress.touchAt, airPress.pressAt = false, nil, nil
    end
    wasGrounded = grounded
end)

local function OnJump()
    if debugMode then
        Print(("debug: falling=%s swimming=%s grounded=%s - %.2f s since last counted jump"):format(
            tostring(Plain(IsFalling())), tostring(Plain(IsSwimming())), tostring(wasGrounded),
            GetTime() - lastJumpTime))
    end
    if Plain(UnitOnTaxi("player")) or Plain(IsFlying()) then return end
    -- 1.8.10: dead and not released, you lie on the ground and the jump key
    -- does nothing - but the game still reports the press, and every press
    -- used to count (2 a second, also in a duel). As a ghost you really
    -- jump, and those count as before.
    if UnitIsDead and Plain(UnitIsDead("player")) and not Plain(UnitIsGhost("player")) then
        if debugMode then Print("debug: dead and not released - not counted") end
        return
    end
    local now = GetTime()
    if wasSwimming or Plain(IsSwimming()) then
        -- In the water: counted once we see you leave it (see above).
        airPress.pressAt = now
        return
    end
    -- On land: only count jumps that start from the ground (no mid-air spam).
    if not wasGrounded then
        -- ...except one pressed on the very frame you land: remembered, and
        -- counted on landing if it turns out to have been a jump (see rejumpAt).
        local took = airPress.jumpAt
        if took and airPress.flew and now - took >= airPress.rejumpFrom and now - took <= airPress.rejumpTo then
            airPress.rejumpAt = now
        end
        return
    end
    wasGrounded = false
    if debugMode then jumpStartedAt = now end
    -- After a press that did nothing: count this one only once we see you
    -- in the air (the tracker above does that).
    if airPress.dud then
        airPress.landPress = now
        return
    end
    airPress.Count(false, now)
end

function airPress.Count(inWater, now)
    if not inWater then
        -- Too soon after the last counted jump to be a full jump.
        local since = now - lastJumpTime
        if since < JUMP_MIN_INTERVAL then return end
        -- 1.8.7: the short interval is for real jumps that land early (running
        -- uphill: 0.55 s or more in the air). A hop that came down sooner than
        -- that - stuck against a tree, a wall or a ledge - doesn't let you
        -- jump again sooner than a normal jump would (airPress.full). One
        -- such hop on its own is let through (clipping a ledge while
        -- running); from the second in a row the rule applies.
        local air = airPress.lastAir
        if airPress.jumpAt and airPress.flew then air = now - airPress.jumpAt end
        local short = air ~= nil and air < JUMP_MIN_INTERVAL
        if short and airPress.shortBefore and since < airPress.full then return end
        airPress.shortBefore = short
    else
        airPress.shortBefore = false
    end
    lastJumpTime = now
    -- Timed until you land (1.8.7), for the rule above and the air time record.
    airPress.jumpAt, airPress.flew, airPress.lastAir = (not inWater) and now or nil, false, nil
    airPress.rejumpAt = nil

    charData.total = charData.total + 1
    sessionJumps = sessionJumps + 1
    acct.session.jumps, acct.session.at = sessionJumps, time()
    charData.rate.jumps = charData.rate.jumps + 1   -- all-time, kept per character
    AddRate(1, 0)
    local wid = CurrentWeekId()
    if wid then
        if charData.weekId ~= wid then
            charData.weekId = wid
            charData.week = 0
        end
        charData.week = charData.week + 1
    end
    local hid = CurrentHourId()
    if acct.hourId ~= hid then acct.hourId, acct.hour = hid, 0 end
    acct.hour = acct.hour + 1
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
    local charLevel = isMe and Plain(UnitLevel("player")) or data.charLevel
    if data.faction then line("Faction", FactionIcon(data.faction) .. FACTION_NAMES[data.faction]) end
    line("Character level", charLevel and tostring(charLevel) or "?")
    line("Total jumps", Fmt(entry.total))
    line("This week", Fmt(MyWeekCount(data)))
    if isMe or data.hourId then                     -- 1.8.0+
        line("This hour", (entry.key == crownKey and CROWN_ICON or "") .. Fmt(HourCount(data)))
        line("Crowns won", Fmt(isMe and (acct.crowns or 0) or data.crowns))
    end
    local jph = JumpsPerHour(data)
    line("Avg / hour (7 days)", jph and Fmt(jph) or (isMe and "after 30 min online"
        or (data.version and IsNewerVersion(RATE_SINCE, data.version) and "needs v" .. RATE_SINCE) or "?"))
    line("Deaths", data.deaths and Fmt(data.deaths) or "?")
    local challenges = isMe and CountCompleted(acct) or data.challenges
    line("Challenges", challenges and ("%d / %d"):format(challenges, #CHALLENGES) or "?")
    local points = isMe and (acct.duelPoints or 0) or data.duelPoints
    if points then                                         -- 1.8.2+
        line("Duel rank", ("%s |cff999999(%d pts)|r"):format(DuelRank(points), points))
    end
    local wins = isMe and (acct.duelWins or 0) or data.duelWins
    if wins then line("Duels won", tostring(wins)) end
    local best = isMe and (acct.stats.bestDuel or 0) or data.duelBest
    if best and best > 0 then line("Best duel", best .. " jumps") end   -- 1.8.9+

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
        local how = (data.hops or 0) > 0 and "via friends"
            or ({ GUILD = "guild", BNET = "Battle.net", WHISPER = "friend", GROUP = "group" })[data.via or ""]
        line("Last update", (ago < 60 and "just now" or (FormatDuration(ago) .. " ago"))
            .. (how and (" (" .. how .. ")") or ""))
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- WoW-style building blocks. Blizzard's own templates make the window look
-- like part of the game. Forever may not have every template, so check
-- first and fall back to a plain look rather than breaking.
---------------------------------------------------------------------------
local function HasTemplate(t)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, t)
        return ok and info ~= nil
    end
    return true   -- can't tell: callers check for the parts they use
end

-- A thin divider line.
local function Divider(parent, alpha)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(1, 0.82, 0, alpha or 0.25)
    t:SetHeight(1)
    return t
end

-- A section title like the Character window's ("Attributes"): gold text
-- with a faint line under it.
local function SectionTitle(parent, text)
    local s = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s:SetText(text)
    local line = Divider(parent, 0.3)
    line:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -3)
    s.line = line
    return s
end

-- The list highlight Blizzard uses for quest log / who list rows.
local function RowHighlight(button)
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints()
    hl:SetAlpha(0.5)
    return hl
end

---------------------------------------------------------------------------
-- Overview tab: your "character sheet" - level, rank, XP and your numbers.
---------------------------------------------------------------------------
local function BuildOverviewTab(page, width)
    -- Your name, jump level and XP bar are in the window's header (on every
    -- tab). Here (1.8.7): four big numbers, what's next (rank, prestige and
    -- the challenges you're closest to), your last 7 days, records, and the
    -- rest of your numbers.
    local me, standings, myPos
    local ROW_H = 20

    local function Tip(frame, title, text)
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", function(self)
            local t, body = title, text
            if type(t) == "function" then t, body = t() end
            if not t then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(t)
            if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        frame:SetScript("OnLeave", GameTooltip_Hide)
    end

    -- Four tiles across the top.
    local TILE_H = 46
    local tileW = math.floor((width - 8 - 3 * 8) / 4)
    local tiles = {}
    local function Tile(label, get, tip)
        local i = #tiles + 1
        local t = CreateFrame("Frame", nil, page)
        t:SetSize(tileW, TILE_H)
        t:SetPoint("TOPLEFT", 4 + (i - 1) * (tileW + 8), -4)
        local bg = t:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.05)
        for _, side in ipairs({ "TOP", "BOTTOM" }) do
            local edge = t:CreateTexture(nil, "BORDER")
            edge:SetColorTexture(0.6, 0.5, 0.3, side == "TOP" and 0.7 or 0.25)
            edge:SetHeight(1)
            edge:SetPoint(side .. "LEFT")
            edge:SetPoint(side .. "RIGHT")
        end
        t.value = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        t.value:SetPoint("TOP", 0, -7)
        t.label = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        t.label:SetPoint("BOTTOM", 0, 6)
        t.label:SetText(label)
        t.get = get
        if tip then Tip(t, label, tip) end
        tiles[i] = t
    end
    Tile("Total jumps", function() return Fmt(me.total) end)
    Tile("Leaderboard", function()
        return myPos and ("#%d |cff999999of %d|r"):format(myPos, #standings) or "-" end)
    Tile("Average per hour", function()
        local jph = JumpsPerHour(me)
        return jph and Fmt(jph) or GRAY:format(("%d / 30 min"):format(math.floor(me.rate.seconds / 60)))
    end, "Jumps per hour of online time over the last 7 days (time flagged AFK doesn't count).")
    Tile("Duel rank", function()
        return (DuelRank(acct.duelPoints)), ("Duel rank  -  %d wins"):format(acct.duelWins or 0)
    end, "Duel points: win and you take points from your opponent, lose and they take yours - more "
        .. "for beating someone stronger, less for losing to them. No losses below Contender, and "
        .. "after 3 losses in a row the next one is free.")

    -- "Next up": the next rank and the four challenges closest to done. (How
    -- far it is to prestige is the XP bar in the header, and that's also
    -- where the Prestige button appears at jump level 100.)
    local TOP = -4 - TILE_H - 12
    local leftW = math.floor((width - 8) * 0.56)
    local rightX = 4 + leftW + 18
    local rightW = width - 4 - rightX
    local nextTitle = SectionTitle(page, "Next up")
    nextTitle:SetPoint("TOPLEFT", 4, TOP)
    nextTitle.line:SetWidth(leftW)
    local SLOT_H = 34
    local slots = {}
    for i = 1, 5 do
        local s = CreateFrame("Frame", nil, page)
        s:SetSize(leftW, SLOT_H - 2)
        s:SetPoint("TOPLEFT", 4, TOP - 22 - (i - 1) * SLOT_H)
        s.left = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        s.left:SetPoint("TOPLEFT", 2, 0)
        s.right = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        s.right:SetPoint("TOPRIGHT", -2, 0)
        s.bar = ProgressBar(s, 13, 0.1, 0.6, 0.1)
        s.bar:SetPoint("BOTTOMLEFT", 2, 3)
        s.bar:SetPoint("BOTTOMRIGHT", -2, 3)
        local frame = s.bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        frame:SetPoint("TOPLEFT", -1, 1)
        frame:SetPoint("BOTTOMRIGHT", 1, -1)
        frame:SetColorTexture(0.45, 0.38, 0.22, 0.9)
        Tip(s, function() return s.tipTitle, s.tipText end)
        slots[i] = s
    end

    -- Rows of "label ... value", like the Character window's stats.
    local function Rows(x, y, w, defs)
        local rows = {}
        for i, d in ipairs(defs) do
            local r = CreateFrame("Frame", nil, page)
            r:SetSize(w, ROW_H)
            r:SetPoint("TOPLEFT", x, y - (i - 1) * ROW_H)
            if i % 2 == 1 then
                local bg = r:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetColorTexture(1, 1, 1, 0.05)
            end
            r.label = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.label:SetPoint("LEFT", 8, 0)
            r.label:SetText(d.label)
            r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.value:SetPoint("RIGHT", -8, 0)
            if d.tip then Tip(r, d.label, d.tip) end
            r.get = d.get
            rows[i] = r
        end
        return rows
    end

    -- The rest of your numbers, in two columns under "Next up".
    local MORE_TOP = TOP - 22 - 5 * SLOT_H - 8
    local moreTitle = SectionTitle(page, "Your numbers")
    moreTitle:SetPoint("TOPLEFT", 4, MORE_TOP)
    moreTitle.line:SetWidth(leftW)
    local halfW = math.floor((leftW - 10) / 2)
    local numbersA = Rows(4, MORE_TOP - 20, halfW, {
        { label = "This session", get = function() return Fmt(sessionJumps) end },
        { label = "This hour", get = function()
            return (crownKey == playerKey and CROWN_ICON or "") .. Fmt(HourCount(me)) end,
          tip = "Your jumps since the hour started. Whoever has the most holds the crown." },
        { label = "This week", get = function() return Fmt(MyWeekCount(me)) end },
        { label = "Deaths", get = function() return Fmt(me.deaths) end },
        { label = "Jumps since last death", get = function() return Fmt(acct.stats.sinceDeath or 0) end },
    })
    local numbersB = Rows(4 + halfW + 10, MORE_TOP - 20, halfW, {
        { label = "Total XP", get = function() return Fmt(EntryXP(me)) end },
        { label = "Challenges", get = function()
            return ("%d / %d"):format(CountCompleted(acct), #CHALLENGES) end },
        { label = "Today's challenges", get = function()
            return ("%d / 3"):format(Daily.DoneCount()) end,
          tip = "Three new challenges every day - easy, medium and hard - for extra XP. See the Challenges tab." },
        { label = "Crowns won", get = function() return Fmt(acct.crowns or 0) end,
          tip = "Hours you finished with the most jumps of everyone you can see." },
        { label = "Characters", get = function() return tostring(#MyCharacters()) end },
    })
    -- "This week" builds its tooltip when shown (the time left changes).
    Tip(numbersA[3], function()
        local secs = SecondsUntilReset()
        return "This week", secs and ("Resets in " .. FormatDuration(secs) .. ".") or "Weeks start Monday 00:00 UTC."
    end)

    -- Last 7 days: a bar for each day's jumps, today in gold.
    local dayTitle = SectionTitle(page, "Last 7 days")
    dayTitle:SetPoint("TOPLEFT", rightX, TOP)
    dayTitle.line:SetWidth(rightW)
    local CHART_H = 70
    local BASE = TOP - 22 - 14 - CHART_H          -- the bars stand on this line
    local colW = math.floor(rightW / RATE_DAYS)
    local days = {}
    for i = 1, RATE_DAYS do
        local d = {}
        d.bar = page:CreateTexture(nil, "ARTWORK")
        d.bar:SetPoint("BOTTOM", page, "TOPLEFT", rightX + (i - 0.5) * colW, BASE)
        d.bar:SetWidth(math.max(8, colW - 12))
        d.value = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        d.value:SetPoint("BOTTOM", d.bar, "TOP", 0, 2)
        d.day = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        d.day:SetPoint("TOP", page, "TOPLEFT", rightX + (i - 0.5) * colW, BASE - 4)
        days[i] = d
    end
    local baseLine = page:CreateTexture(nil, "ARTWORK")
    baseLine:SetColorTexture(0.6, 0.5, 0.3, 0.6)
    baseLine:SetHeight(1)
    baseLine:SetPoint("TOPLEFT", rightX, BASE)
    baseLine:SetWidth(rightW)

    -- Records.
    local REC_TOP = BASE - 26
    local recTitle = SectionTitle(page, "Records")
    recTitle:SetPoint("TOPLEFT", rightX, REC_TOP)
    recTitle.line:SetWidth(rightW)
    local records = Rows(rightX, REC_TOP - 20, rightW, {
        { label = "Best minute", get = function() return Fmt(acct.stats.bestMinute or 0) end },
        { label = "Best hour", get = function() return Fmt(acct.stats.bestHour or 0) end,
          tip = "Your most jumps in one hour (counted since version 1.8.7)." },
        { label = "Best session", get = function() return Fmt(acct.stats.bestSession or 0) end },
        { label = "Best week", get = function() return Fmt(acct.stats.bestWeek or 0) end },
        { label = "Best day streak", get = function()
            local n = acct.stats.bestStreak or 0
            return n .. (n == 1 and " day" or " days") end },
        { label = "Longest time in the air", get = function()
            local air = acct.stats.bestAir or 0
            return air > 0 and ("%.1f s"):format(air) or GRAY:format("-") end,
          tip = "The longest a jump kept you in the air - and you survived the landing "
              .. "(counted since version 1.8.7)." },
    })

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 4, 4)
    hint:SetPoint("BOTTOMRIGHT", -4, 4)
    hint:SetJustifyH("LEFT")
    hint:SetText("Every jump on any of your characters gives 1 XP; challenges, daily challenges, "
        .. "duels and crowns give more.")

    local function Short(n)
        if n <= 0 then return GRAY:format("-") end
        if n < 1000 then return tostring(n) end
        return ("%.1fk"):format(n / 1000)
    end

    function page:Refresh()
        me = Me()
        standings = BuildStandings("all")
        myPos = MyRank()
        for _, t in ipairs(tiles) do
            local value, label = t.get()
            t.value:SetText(value)
            if label then t.label:SetText(label) end
        end

        -- Next rank.
        local s = slots[1]
        local nextRank, nextAt = NextJumpRank(me.total)
        s.bar:SetStatusBarColor(1, 0.82, 0)
        if nextRank then
            s.left:SetText("Next rank: |cffffd100" .. nextRank .. "|r")
            s.right:SetText(Fmt(nextAt - me.total) .. " jumps to go")
            s.bar:SetMinMaxValues(0, nextAt)
            s.bar:SetValue(me.total)
            s.bar.text:SetText(("%s / %s"):format(Fmt(me.total), Fmt(nextAt)))
        else
            s.left:SetText("|cffffd100Highest rank reached!|r")
            s.right:SetText("")
            s.bar:SetMinMaxValues(0, 1)
            s.bar:SetValue(1)
            s.bar.text:SetText(Fmt(me.total))
        end
        s.tipTitle, s.tipText = "Jump ranks", "Your all-time jumps earn you rank titles."

        -- The unfinished challenges closest to done fill the other lines.
        local open = {}
        for _, c in ipairs(CHALLENGES) do
            if not acct.done[c.id] then
                local p = math.min(c.progress(), c.goal)
                table.insert(open, { c = c, p = p, frac = p / c.goal })
            end
        end
        table.sort(open, function(a, b)
            if a.frac ~= b.frac then return a.frac > b.frac end
            return a.c.xp < b.c.xp
        end)
        local first = 2
        for i = first, #slots do
            s = slots[i]
            local o = open[i - first + 1]
            s:SetShown(o ~= nil)
            if o then
                s.left:SetText(o.c.name)
                s.right:SetText("+" .. Fmt(o.c.xp) .. " XP")
                s.bar:SetStatusBarColor(0.1, 0.6, 0.1)
                s.bar:SetMinMaxValues(0, o.c.goal)
                s.bar:SetValue(o.p)
                s.bar.text:SetText(("%s / %s"):format(Fmt(o.p), Fmt(o.c.goal)))
                s.tipTitle, s.tipText = o.c.name, o.c.desc
            end
        end

        -- Last 7 days (the same day buckets as the average per hour).
        local today = RateDay()
        local most = 1
        for i = 1, RATE_DAYS do
            local b = acct.rateDays[today - RATE_DAYS + i]
            days[i].jumps = b and b[1] or 0
            most = math.max(most, days[i].jumps)
        end
        for i, d in ipairs(days) do
            local isToday = i == RATE_DAYS
            d.bar:SetHeight(math.max(1, CHART_H * d.jumps / most))
            if isToday then d.bar:SetColorTexture(1, 0.82, 0, 0.9) else d.bar:SetColorTexture(0.15, 0.62, 0.15, 0.9) end
            d.value:SetText(Short(d.jumps))
            d.day:SetText(isToday and "|cffffd100Today|r"
                or date("%a", (today - RATE_DAYS + i) * 86400 + 43200))
        end

        for _, list in ipairs({ numbersA, numbersB, records }) do
            for _, r in ipairs(list) do r.value:SetText(r.get()) end
        end
    end
end

---------------------------------------------------------------------------
-- Leaderboard tab: a table like the Guild / Who list. Click a column
-- header to sort by it.
---------------------------------------------------------------------------
local BOARD_COLUMNS = {
    { label = "#",          width = 28,  justify = "RIGHT" },
    { label = "Player",     width = 150, justify = "LEFT" },
    { label = "Level",      width = 52,  justify = "LEFT",  sort = "level",
      tip = "Jump level (and prestige stars). Sorts by total XP." },
    { label = "Title",      width = 112, justify = "LEFT",
      tip = "Jump rank title, earned by all-time jumps." },
    { label = "Total",      width = 64,  justify = "RIGHT", sort = "all",  tip = "All-time jumps." },
    { label = "This hour",  width = 62,  justify = "RIGHT", sort = "hour",
      tip = function()
          return ("Jumps since the hour started (%s-%s). Whoever has the most holds the crown.")
              :format(date("%H:00"), date("%H:00", time() + 3600))
      end },
    { label = "Avg/hour",   width = 66,  justify = "RIGHT", sort = "rate",
      tip = "Average jumps per hour of online time over the last 7 days (time flagged AFK doesn't count)." },
    { label = "Deaths",     width = 48,  justify = "RIGHT", sort = "deaths" },
    { label = "Duel rank",  width = 112, justify = "LEFT",  sort = "duels",
      tip = "Duel rank and duel points. Winning takes points from your opponent - more if they're "
          .. "ranked higher - and losing gives them yours. No losses below Contender." },
    { label = "Wins",       width = 46,  justify = "RIGHT", sort = "wins", tip = "Jump duels won." },
    { label = "Best duel",  width = 64,  justify = "RIGHT", sort = "best",
      tip = "Most jumps in a single jump duel (counted since version 1.8.7; shown for players on 1.8.9 or newer)." },
}

-- Everyone on the board with every column's value, sorted by one of them.
-- Players without a value for that column (older versions) go last.
-- filter (1.8.11): "guild" = only your guild, "friends" = only your friends
-- (you are always there). view "guilds": one row per guild, its members
-- added up.
local function BuildTable(sort, filter, view)
    local wid = CurrentWeekId()
    local rows = {}
    local myGuild = GetGuildInfo and Plain((GetGuildInfo("player"))) or nil
    -- First names (lower case) on your friends list and of Battle.net
    -- friends in the game, looked up once when needed.
    local friendNames
    local function IsFriend(key, data)
        if data.friend then return true end
        if not friendNames then
            friendNames = {}
            if C_FriendList and C_FriendList.GetNumFriends then
                for i = 1, C_FriendList.GetNumFriends() do
                    local info = C_FriendList.GetFriendInfoByIndex(i)
                    if info and info.name then friendNames[FirstWord(info.name:match("^[^-]+") or info.name)] = true end
                end
            end
            if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
                for i = 1, (BNGetNumFriends()) do
                    for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                        local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                        if g and g.characterName then friendNames[FirstWord(g.characterName)] = true end
                    end
                end
            end
        end
        return friendNames[FirstWord(key:match("^[^-]+") or key)] or false
    end
    local function Shown(key, data)
        if view == "guilds" or not filter or filter == "all" then return true end
        if filter == "guild" then return myGuild ~= nil and data.guild == myGuild end
        if filter == "friends" then return IsFriend(key, data) end
        return true
    end
    local function add(key, data, mine)
        table.insert(rows, { key = key, data = data, class = data.class, total = data.total or 0, mine = mine,
            all = data.total or 0, hour = HourCount(data),
            week = (wid and data.weekId == wid) and (data.week or 0) or 0,
            rate = JumpsPerHour(data), level = EntryXP(data), deaths = data.deaths,
            duels = data.duelPoints, duelWins = data.duelWins, wins = data.duelWins,
            best = data.duelBest })
    end
    add(playerKey, Me(), true)
    local byName = {}
    for key, data in pairs(JumpCounterDB.peers) do
        if not JumpCounterDB.chars[key] then
            local name = data.acct and ("#" .. data.acct) or DisplayName(key):lower()
            local best = byName[name]
            if not best or (data.seen or 0) > (best.data.seen or 0) then byName[name] = { key = key, data = data } end
        end
    end
    for _, e in pairs(byName) do
        if Shown(e.key, e.data) then add(e.key, e.data) end
    end
    if view == "guilds" then
        -- One row per guild: its members' numbers added up.
        local guilds, list = {}, {}
        for _, r in ipairs(rows) do
            local name = r.data.guild
            if name and name ~= "" then
                local g = guilds[name]
                if not g then
                    g = { key = "guild:" .. name, guild = name, isGuild = true, data = {}, members = {},
                        total = 0, all = 0, hour = 0, level = 0, deaths = 0, wins = 0, best = 0 }
                    guilds[name] = g
                    table.insert(list, g)
                end
                g.all, g.total = g.all + r.all, g.total + r.all
                g.hour = g.hour + (r.hour or 0)
                g.level = g.level + (r.level or 0)
                g.deaths = g.deaths + (r.deaths or 0)
                g.wins = g.wins + (r.wins or 0)
                g.best = math.max(g.best, r.best or 0)
                g.mine = g.mine or r.mine
                table.insert(g.members, r)
            end
        end
        for _, g in ipairs(list) do
            table.sort(g.members, function(a, b) return a.all > b.all end)
        end
        rows = list
    end
    table.sort(rows, function(a, b)
        local x, y = a[sort], b[sort]
        if x ~= nil and y ~= nil and x ~= y then return x > y end
        if (x == nil) ~= (y == nil) then return x ~= nil end
        if a.total ~= b.total then return a.total > b.total end
        return a.key < b.key
    end)
    return rows
end

local function BuildLeaderboardTab(page, width)
    -- The last column takes whatever width is left, so the header row ends
    -- exactly where the rows do (rows stop 24 px short, for the scroll bar).
    local used = 0
    for i = 1, #BOARD_COLUMNS - 1 do used = used + BOARD_COLUMNS[i].width end
    BOARD_COLUMNS[#BOARD_COLUMNS].width = math.max(40, width - 24 - used)
    local ROW_H = 18
    local ROWS = BOARD_ROWS
    local HEAD_H = 22
    local TOP = -26                       -- room for the filter buttons above the headers (1.8.11)
    local listTop = TOP - HEAD_H - 4
    local listHeight = ROWS * ROW_H

    -- Who's shown: everyone, your guild or your friends - or the guilds
    -- themselves, ranked by their members' jumps added up.
    local filterButtons = {}
    local function FilterButton(id, label, anchor, x, tip)
        local b = CreateFrame("Button", nil, page)
        b:SetSize(96, 20)
        b:SetPoint(anchor, x, 0)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.15)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetPoint("CENTER")
        b.text:SetText(label)
        b:SetScript("OnClick", function()
            local ui = JumpCounterDB.ui
            if id == "guilds" then
                ui.boardView = (ui.boardView == "guilds") and "players" or "guilds"
            else
                ui.boardFilter, ui.boardView = id, "players"
            end
            page.scrollOffsetReset = true
            page:Refresh()
            if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(label)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        b.id = id
        table.insert(filterButtons, b)
    end
    FilterButton("all", "Everyone", "TOPLEFT", 0, "Everyone you can see: your guild, your friends and the people they know.")
    FilterButton("guild", "My guild", "TOPLEFT", 100, "Only players in your guild.")
    FilterButton("friends", "Friends", "TOPLEFT", 200,
        "Only players on your friends list or your Battle.net friends.")
    FilterButton("guilds", "Guild ranking", "TOPRIGHT", -24,
        "The guilds themselves: every guild's jumps added up (of its members with the addon that you can see).")

    -- Column headers (clickable for sorting).
    local headers = {}
    local x = 0
    for i, col in ipairs(BOARD_COLUMNS) do
        local h = CreateFrame("Button", nil, page)
        h:SetSize(col.width - 2, HEAD_H)
        h:SetPoint("TOPLEFT", x, TOP)
        -- A bronze plate with a light top edge and a dark bottom edge, like
        -- the column buttons of the Who and Guild lists.
        local bg = h:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.30, 0.23, 0.11, 0.9)
        h.bg = bg
        local top = h:CreateTexture(nil, "BORDER")
        top:SetColorTexture(0.62, 0.5, 0.28, 0.9)
        top:SetHeight(1)
        top:SetPoint("TOPLEFT")
        top:SetPoint("TOPRIGHT")
        local bottom = h:CreateTexture(nil, "BORDER")
        bottom:SetColorTexture(0, 0, 0, 0.9)
        bottom:SetHeight(1)
        bottom:SetPoint("BOTTOMLEFT")
        bottom:SetPoint("BOTTOMRIGHT")
        local hl = h:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.15)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetPoint("LEFT", 5, 0)
        h.text:SetPoint("RIGHT", -5, 0)
        h.text:SetJustifyH(col.justify)
        h.text:SetWordWrap(false)
        h.text:SetText(col.label)
        h.line = h:CreateTexture(nil, "ARTWORK")
        h.line:SetColorTexture(1, 0.82, 0, 1)
        h.line:SetHeight(2)
        h.line:SetPoint("BOTTOMLEFT")
        h.line:SetPoint("BOTTOMRIGHT")
        if col.sort then
            h:SetScript("OnClick", function()
                JumpCounterDB.ui.boardMode = col.sort
                page.scrollOffsetReset = true
                page:Refresh()
                if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
                    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                end
            end)
            h:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(col.label)
                local tip = type(col.tip) == "function" and col.tip() or col.tip
                if tip then GameTooltip:AddLine(tip, 1, 1, 1, true) end
                GameTooltip:AddLine("Click to sort by this column.", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end)
            h:SetScript("OnLeave", GameTooltip_Hide)
        else
            h:EnableMouse(false)
        end
        h.col = col
        headers[i] = h
        x = x + col.width
    end

    local function Cell(row, i, xOff, y, font)
        local col = BOARD_COLUMNS[i]
        local fs = page:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", xOff + 5, y)
        fs:SetWidth(col.width - 10)
        fs:SetJustifyH(col.justify)
        fs:SetWordWrap(false)
        return fs
    end

    local function MakeRow(y)
        local row = { cells = {}, y = y }
        row.hover = CreateFrame("Button", nil, page)
        row.hover:SetPoint("TOPLEFT", 0, y + 3)
        row.hover:SetPoint("TOPRIGHT", -24, y + 3)
        row.hover:SetHeight(ROW_H)
        RowHighlight(row.hover)
        row.bg = row.hover:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        local xOff = 0
        for i, col in ipairs(BOARD_COLUMNS) do
            row.cells[i] = Cell(row, i, xOff, y, i == 2 and "GameFontHighlight" or "GameFontHighlightSmall")
            xOff = xOff + col.width
        end
        -- Places 1-3: the number sits on a gold, silver or bronze medal
        -- (our own images - see Media\Media.lua; plain coloured numbers
        -- until the game has been restarted).
        row.medal = page:CreateTexture(nil, "ARTWORK")      -- under the number (an OVERLAY text)
        row.medal:SetSize(16, 16)
        row.medal:SetPoint("TOPRIGHT", page, "TOPLEFT", BOARD_COLUMNS[1].width - 3, y + 3)
        row.medal:Hide()
        row.hover:SetScript("OnEnter", function(self)
            local e = row.entry
            if e and e.isGuild then
                -- A guild: its members, most jumps first.
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(e.guild)
                GameTooltip:AddLine(("%d %s with the addon"):format(#e.members,
                    #e.members == 1 and "player" or "players"), 1, 1, 1)
                GameTooltip:AddLine(" ")
                for i, m in ipairs(e.members) do
                    if i > 15 then
                        GameTooltip:AddLine(("...and %d more"):format(#e.members - 15), 0.6, 0.6, 0.6)
                        break
                    end
                    GameTooltip:AddDoubleLine(ColoredName(m.key, m.class), Fmt(m.all), 1, 1, 1, 1, 1, 1)
                end
                GameTooltip:Show()
            elseif e then
                ShowEntryTooltip(self, e)
            end
        end)
        row.hover:SetScript("OnLeave", GameTooltip_Hide)

        function row:Set(pos, entry, sort, stripe)
            row.entry = entry
            row.hover:SetShown(entry ~= nil)
            row.medal:Hide()
            if not entry then
                for _, c in ipairs(row.cells) do c:SetText("") end
                return
            end
            local data = entry.data or {}
            if entry.mine then
                row.bg:SetColorTexture(1, 0.82, 0, 0.14)
            else
                row.bg:SetColorTexture(1, 1, 1, stripe and 0.04 or 0)
            end
            local function num(v, key)
                if v == nil then return GRAY:format("-") end
                local s = (v == 0) and GRAY:format("0") or Fmt(v)
                return (key == sort or v == 0) and s or ("|cffc8c8c8" .. s .. "|r")
            end
            local c = row.cells
            if pos and pos <= 3 and JumpCounter_MediaLoaded then
                row.medal:SetTexture("Interface\\AddOns\\JumpCounter\\Media\\medal" .. pos)
                row.medal:Show()
                c[1]:SetWidth(16)
                c[1]:SetJustifyH("CENTER")
                c[1]:SetPoint("TOPLEFT", BOARD_COLUMNS[1].width - 19, row.y)
                c[1]:SetShadowOffset(0, 0)
                c[1]:SetText("|cff2a1600" .. pos .. "|r")
            else
                c[1]:SetWidth(BOARD_COLUMNS[1].width - 10)
                c[1]:SetJustifyH("RIGHT")
                c[1]:SetPoint("TOPLEFT", 5, row.y)
                c[1]:SetShadowOffset(1, -1)
                local medal = pos and ({ "|cffffd100", "|cffd0d8e6", "|cffe0915a" })[pos]
                c[1]:SetText(pos and (medal and (medal .. pos .. ".|r") or GRAY:format(pos .. ".")) or "")
            end
            if entry.isGuild then
                -- A guild's row: name, players, its top jumper, and the sums.
                local top = entry.members[1]
                c[2]:SetText("|cffffd100" .. entry.guild .. "|r")
                c[3]:SetText("|cffc8c8c8" .. #entry.members .. "|r")
                c[4]:SetText(top and ColoredName(top.key, top.class) or "")
                c[5]:SetText(num(entry.all, "all"))
                c[6]:SetText(num(entry.hour, "hour"))
                c[7]:SetText(GRAY:format("-"))
                c[8]:SetText(num(entry.deaths, "deaths"))
                c[9]:SetText(GRAY:format("-"))
                c[10]:SetText(num(entry.wins, "wins"))
                c[11]:SetText(entry.best > 0 and num(entry.best, "best") or GRAY:format("-"))
                return
            end
            c[2]:SetText(FactionIcon(data.faction)
                .. (entry.key == crownKey and CROWN_ICON or "") .. ColoredName(entry.key, entry.class))
            c[3]:SetText(PrestigeTag(EntryPrestige(data)) .. ((sort == "level") and "" or "|cffc8c8c8")
                .. (EntryLevel(data)) .. ((sort == "level") and "" or "|r"))
            local title = GetJumpRank(entry.total)
            c[4]:SetText(title and ("|cffffd100" .. title .. "|r") or GRAY:format("-"))
            c[5]:SetText(num(entry.all, "all"))
            c[6]:SetText(num(entry.hour, "hour"))
            c[7]:SetText(entry.rate and num(entry.rate, "rate") or GRAY:format("-"))
            c[8]:SetText(num(entry.deaths, "deaths"))
            if entry.duels then
                local rank = DuelRank(entry.duels)
                c[9]:SetText(((sort == "duels") and "|cffffffff" or "|cffc8c8c8") .. rank .. "|r "
                    .. GRAY:format(Fmt(entry.duels)))
            else
                c[9]:SetText(GRAY:format("-"))
            end
            c[10]:SetText(entry.wins and num(entry.wins, "wins") or GRAY:format("-"))
            c[11]:SetText(entry.best and num(entry.best, "best") or GRAY:format("-"))
        end
        return row
    end

    page.rows = {}
    for i = 1, ROWS do
        page.rows[i] = MakeRow(listTop - 4 - (i - 1) * ROW_H)
    end

    local scroll = CreateFrame("ScrollFrame", "JumpCounterMainBoardScroll", page, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, listTop)
    scroll:SetPoint("BOTTOMRIGHT", page, "TOPRIGHT", -24, listTop - listHeight)
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

    -- Your own row, pinned under the list when it's scrolled out of view.
    local divider = Divider(page, 0.4)
    page.divider = divider
    divider:SetPoint("TOPLEFT", 0, listTop - 6 - listHeight)
    divider:SetPoint("TOPRIGHT", -24, listTop - 6 - listHeight)
    page.meRow = MakeRow(listTop - 12 - listHeight)

    -- Bottom line: how far it is to the player above you (right), and the
    -- number of players with a note about the column (left).
    page.gap = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    page.gap:SetPoint("BOTTOMRIGHT", -2, 2)
    page.gap:SetJustifyH("RIGHT")
    page.footer = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.footer:SetPoint("BOTTOMLEFT", 2, 2)
    page.footer:SetPoint("RIGHT", page.gap, "LEFT", -12, 0)
    page.footer:SetJustifyH("LEFT")
    page.footer:SetWordWrap(false)

    function page:Update()
        local list = self.list or {}
        FauxScrollFrame_Update(scroll, #list, ROWS, ROW_H)
        local offset = FauxScrollFrame_GetOffset(scroll)
        for i, row in ipairs(self.rows) do
            row:Set(i + offset, list[i + offset], self.mode, (i + offset) % 2 == 0)
        end
        local pos = self.myPos
        local visible = pos and pos > offset and pos <= offset + ROWS
        local showPinned = pos ~= nil and not visible
        self.meRow:Set(showPinned and pos or nil, showPinned and self.myEntry or nil, self.mode)
        self.divider:SetShown(showPinned)
    end

    function page:Refresh()
        -- Sorted by this hour (the crown race) until you pick a column yourself.
        local mode = JumpCounterDB.ui.boardMode or "hour"
        local valid = false
        for _, col in ipairs(BOARD_COLUMNS) do if col.sort == mode then valid = true end end
        if not valid then mode = "hour" end
        self.mode = mode
        local ui = JumpCounterDB.ui
        local view = ui.boardView == "guilds" and "guilds" or "players"
        local filter = ui.boardFilter or "all"
        local guildLabels = { [2] = "Guild", [3] = "Players", [4] = "Top jumper" }
        for i, h in ipairs(headers) do
            local on = h.col.sort == mode
            h.line:SetShown(on)
            h.text:SetTextColor(1, on and 1 or 0.82, on and 1 or 0)
            h.text:SetText(view == "guilds" and guildLabels[i] or h.col.label)
        end
        for _, b in ipairs(filterButtons) do
            local on = (b.id == "guilds" and view == "guilds") or (view ~= "guilds" and b.id == filter)
            b.bg:SetColorTexture(on and 0.45 or 0.30, on and 0.35 or 0.23, on and 0.14 or 0.11, on and 1 or 0.6)
            b.text:SetTextColor(1, on and 1 or 0.82, on and 1 or 0)
        end
        if self.scrollOffsetReset then
            self.scrollOffsetReset = nil
            FauxScrollFrame_SetOffset(scroll, 0)
            if bar then bar:SetValue(0) end
        end
        self.list = BuildTable(mode, filter, view)
        self.myPos, self.myEntry = nil, nil
        for i, entry in ipairs(self.list) do
            if entry.mine then self.myPos, self.myEntry = i, entry break end
        end
        self:Update()

        local count
        if view == "guilds" then
            count = #self.list .. (#self.list == 1 and " guild" or " guilds")
        else
            count = #self.list .. (#self.list == 1 and " player" or " players")
                .. (filter == "guild" and " in your guild" or (filter == "friends" and " among your friends" or ""))
        end
        local note = ({
            hour = ("crown to the most jumps this hour - %d min left"):format(
                math.ceil((3600 - GetServerTime() % 3600) / 60)),
            week = SecondsUntilReset() and ("week resets in " .. FormatDuration(SecondsUntilReset()))
                or "weeks start Monday 00:00 UTC",
            rate = "average jumps per hour online, last 7 days (not AFK)",
            level = "XP = jumps + challenge, duel and crown rewards",
            duels = "duel points: win them from your opponent - more against stronger players",
            wins = "jump duels won",
            best = "most jumps in a single jump duel",
        })[mode] or "click a column to sort - hover a player for details"
        self.footer:SetText(count .. "  -  " .. note)

        -- The gap to the player above (or your lead), in the sorted column.
        local unit = ({ all = "jumps", hour = "jumps this hour", level = "XP",
            duels = "duel points", wins = "wins" })[mode]
        local gap = ""
        local mine = self.myEntry and self.myEntry[mode]
        if unit and mine and self.myPos then
            local other = self.list[self.myPos > 1 and self.myPos - 1 or 2]
            local theirs = other and other[mode]
            if theirs then
                local name = other.isGuild and ("|cffffd100" .. other.guild .. "|r")
                    or ColoredName(other.key, other.class)
                if self.myPos > 1 then
                    gap = theirs > mine and ("%s %s behind %s"):format(Fmt(theirs - mine), unit, name)
                        or ("level with %s"):format(name)
                elseif mine > theirs then
                    gap = ("In the lead, %s %s ahead of %s"):format(Fmt(mine - theirs), unit, name)
                end
            end
        end
        self.gap:SetText(gap)
    end
end

---------------------------------------------------------------------------
-- Challenges tab: rows like the Achievements window.
---------------------------------------------------------------------------
local function BuildChallengesTab(page, width)
    -- An icon for each kind of challenge (the id without its number). All of
    -- them are icons the game has had since the start; anything not listed
    -- gets the addon's own icon.
    local CHALLENGE_ICONS = {
        mount = "Ability_Mount_RidingHorse", swim = "Spell_Frost_SummonWaterElemental",
        ghost = "Spell_Holy_Resurrection", combat = "Ability_Warrior_OffensiveStance",
        dungeon = "INV_Misc_Head_Dragon_01", party = "INV_Misc_GroupLooking", zones = "INV_Misc_Map_01",
        capitals = "INV_BannerPVP_02", enemycap = "Ability_Rogue_Disguise", session = "INV_Misc_PocketWatch_01",
        sprint = "Ability_Rogue_Sprint", nodeath = "Spell_Holy_DivineIntervention", days = "INV_Misc_Book_09",
        week = "INV_Misc_PocketWatch_02", streak = "Spell_Fire_Fire", resting = "INV_Misc_Rune_01",
        stealth = "Ability_Stealth", shape = "Ability_Druid_CatForm", pvp = "INV_BannerPVP_01",
        night = "Spell_Nature_Sleep", lowhp = "Ability_DualWield", maxlevel = "Spell_Holy_SurgeOfLight",
        classes = "INV_Misc_Book_11", prestige = "Spell_Holy_MagicalSentry", duel = "Ability_Parry",
        crown = "INV_Crown_01", daily = "INV_Misc_Note_01",
        -- 1.8.7
        hour = "INV_Misc_PocketWatch_03", air = "Spell_Magic_FeatherFall", clock = "Spell_Nature_TimeStop",
        indoor = "INV_Misc_Key_03", tour = "INV_Misc_Bone_HumanSkull_01", perfect = "Spell_Holy_PrayerOfHealing",
        winrow = "Ability_Warrior_BattleShout", burst = "Ability_Hunter_RunningShot",
        pass = "Ability_Mount_JungleTiger", crowd = "INV_Misc_GroupNeedMore", level = "INV_Boots_05",
        duelplay = "INV_Sword_27", team = "Spell_Holy_PrayerOfFortitude",        -- 1.8.10
    }
    local ROW_H = 48
    local WEEK_H = 58                     -- the weekly goal's block at the top (1.8.10)
    local DAILY_TOP, DAILY_ROW = -22 - WEEK_H, 28
    local BAR_W = 190

    -- A progress bar with a dark frame, like the bars in the Achievements window.
    local function Bar(parent, w, h)
        local bar = ProgressBar(parent, h, 0.1, 0.6, 0.1)
        bar:SetWidth(w)
        local frame = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        frame:SetPoint("TOPLEFT", -1, 1)
        frame:SetPoint("BOTTOMRIGHT", 1, -1)
        frame:SetColorTexture(0.45, 0.38, 0.22, 0.9)
        return bar
    end

    -- Today's three daily challenges: a stripe in the tier's colour, the
    -- task, a bar and the reward.
    -- This week's goal, for everyone on your leaderboard together: one bar
    -- towards the next goal, and the three goals with their rewards.
    local weekTitle = SectionTitle(page, "This week - together")
    weekTitle:SetPoint("TOPLEFT", 4, -2)
    weekTitle.line:SetWidth(width - 8)
    local weekLeft = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    weekLeft:SetPoint("TOPRIGHT", -6, -4)
    local weekBar = Bar(page, width - 8 - 2, 15)
    weekBar:SetPoint("TOPLEFT", 5, -23)
    weekBar:SetStatusBarColor(1, 0.82, 0)
    local weekInfo = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    weekInfo:SetPoint("TOPLEFT", 5, -42)
    local weekMine = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    weekMine:SetPoint("TOPRIGHT", -6, -42)

    local todayTitle = SectionTitle(page, "Today's challenges")
    todayTitle:SetPoint("TOPLEFT", 4, -2 - WEEK_H)
    todayTitle.line:SetWidth(width - 8)
    local resets = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    resets:SetPoint("TOPRIGHT", -6, -4 - WEEK_H)
    local daily = {}
    for i = 1, 3 do
        local r = CreateFrame("Frame", nil, page)
        r:SetSize(width - 8, DAILY_ROW - 3)
        r:SetPoint("TOPLEFT", 4, DAILY_TOP - (i - 1) * DAILY_ROW)
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.stripe = r:CreateTexture(nil, "BORDER")
        r.stripe:SetPoint("TOPLEFT")
        r.stripe:SetPoint("BOTTOMLEFT")
        r.stripe:SetWidth(3)
        r.tier = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        r.tier:SetPoint("LEFT", 12, 0)
        r.tier:SetWidth(54)
        r.tier:SetJustifyH("LEFT")
        r.desc = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.desc:SetPoint("LEFT", 70, 0)
        r.xp = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.xp:SetPoint("RIGHT", -10, 0)
        r.xp:SetWidth(70)
        r.xp:SetJustifyH("RIGHT")
        r.bar = Bar(r, BAR_W, 13)
        r.bar:SetPoint("RIGHT", -90, 0)
        r.check = r:CreateTexture(nil, "OVERLAY")
        r.check:SetSize(16, 16)
        r.check:SetPoint("RIGHT", r.bar, "LEFT", -8, 0)
        r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        daily[i] = r
    end

    -- All challenges.
    local LIST_TOP = DAILY_TOP - 3 * DAILY_ROW - 8
    local allTitle = SectionTitle(page, "Challenges")
    allTitle:SetPoint("TOPLEFT", 4, LIST_TOP)
    allTitle.line:SetWidth(width - 8)
    -- How many are done, as a small bar next to the title.
    local doneBar = Bar(page, 150, 11)
    doneBar:SetPoint("LEFT", allTitle, "RIGHT", 14, 0)
    doneBar:SetStatusBarColor(1, 0.82, 0)
    local summary = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("LEFT", doneBar, "RIGHT", 10, 0)

    local hide = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    hide:SetSize(22, 22)
    hide:SetPoint("TOPRIGHT", -120, LIST_TOP + 4)
    local hideText = hide:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hideText:SetPoint("LEFT", hide, "RIGHT", 2, 1)
    hideText:SetText("Hide completed")
    hide:SetScript("OnClick", function(self)
        JumpCounterDB.ui.hideDone = self:GetChecked() and true or false
        page:Refresh()
    end)

    local scroll = CreateFrame("ScrollFrame", "JumpCounterMainChallengeScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, LIST_TOP - 22)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 28, #CHALLENGES * ROW_H)
    scroll:SetScrollChild(content)

    -- One row: icon | name and what to do | reward above the progress bar
    -- (or the day it was completed).
    local rows = {}
    for i, c in ipairs(CHALLENGES) do
        local r = CreateFrame("Frame", nil, content)
        r:SetSize(width - 30, ROW_H - 4)
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.border = r:CreateTexture(nil, "BORDER")
        r.border:SetPoint("TOPLEFT")
        r.border:SetPoint("BOTTOMLEFT")
        r.border:SetWidth(3)
        -- The icon in a thin frame (gold once the challenge is done).
        r.iconEdge = r:CreateTexture(nil, "BORDER")
        r.iconEdge:SetSize(36, 36)
        r.iconEdge:SetPoint("LEFT", 9, 0)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(32, 32)
        r.icon:SetPoint("CENTER", r.iconEdge)
        local kind = c.id:gsub("%d+$", "")
        r.icon:SetTexture(CHALLENGE_ICONS[kind] and ("Interface\\Icons\\" .. CHALLENGE_ICONS[kind]) or MINIMAP_ICON)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.check = r:CreateTexture(nil, "OVERLAY")
        r.check:SetSize(16, 16)
        r.check:SetPoint("BOTTOMRIGHT", r.iconEdge, "BOTTOMRIGHT", 5, -4)
        r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("TOPLEFT", r.iconEdge, "TOPRIGHT", 10, -3)
        r.desc = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.desc:SetPoint("BOTTOMLEFT", r.iconEdge, "BOTTOMRIGHT", 10, 4)
        r.desc:SetPoint("RIGHT", r, "RIGHT", -(BAR_W + 24), 0)
        r.desc:SetJustifyH("LEFT")
        r.desc:SetWordWrap(false)
        r.desc:SetText(c.desc)
        r.reward = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.reward:SetPoint("TOPRIGHT", -10, -6)
        r.bar = Bar(r, BAR_W, 13)
        r.bar:SetPoint("BOTTOMRIGHT", -10, 7)
        r.bar:SetMinMaxValues(0, c.goal)
        r.status = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.status:SetPoint("BOTTOMRIGHT", -10, 8)
        r.challenge = c
        rows[i] = r
    end

    function page:Refresh()
        local hideDone = JumpCounterDB.ui.hideDone
        hide:SetChecked(hideDone)
        local completed = CountCompleted(acct)
        doneBar:SetMinMaxValues(0, #CHALLENGES)
        doneBar:SetValue(completed)
        doneBar.text:SetText(("%d / %d"):format(completed, #CHALLENGES))
        summary:SetText(("complete  |cff999999-|r  |cffffd100+%s XP|r earned"):format(Fmt(acct.challengeXP)))

        -- The weekly goal.
        local week = Daily.Weekly()
        local secs = SecondsUntilReset()
        weekLeft:SetText((week.partial and "Counting from when you got the weekly goal  -  " or "")
            .. (secs and ("new week in " .. FormatDuration(secs)) or ""))
        local nextTier
        local parts = {}
        for _, t in ipairs(week.tiers) do
            if not nextTier and week.total < t.goal then nextTier = t end
            local mark = t.done and " |TInterface\\RaidFrame\\ReadyCheck-Ready:0|t" or ""
            table.insert(parts, ("%s%s|r %s%s  |cff999999+%s XP|r"):format(t.color, t.label, Fmt(t.goal), mark, Fmt(t.xp)))
        end
        local target = nextTier or week.tiers[#week.tiers]
        weekBar:SetMinMaxValues(0, target.goal)
        weekBar:SetValue(math.min(week.total, target.goal))
        weekBar.text:SetText(nextTier
            and ("%s / %s jumps - %s"):format(Fmt(week.total), Fmt(target.goal), target.label)
            or ("%s jumps - all three goals reached!"):format(Fmt(week.total)))
        weekInfo:SetText(table.concat(parts, "     "))
        weekMine:SetText(week.mine >= week.min
            and ("Your part: |cffffd100%s|r  |cff999999(%d active %s)|r"):format(Fmt(week.mine), week.active,
                week.active == 1 and "player" or "players")
            or ("Your part: |cffff5555%s|r / %s to share the rewards"):format(Fmt(week.mine), Fmt(week.min)))

        resets:SetText("New challenges in " .. FormatDuration(Daily.SecondsLeft()))
        for i, d in ipairs(Daily.List()) do
            local r = daily[i]
            r.tier:SetText(d.color .. d.label .. "|r")
            -- The stripe takes the tier's colour ("|cffRRGGBB").
            local hr, hg, hb = d.color:match("|cff(%x%x)(%x%x)(%x%x)")
            if hr then
                r.stripe:SetColorTexture(tonumber(hr, 16) / 255, tonumber(hg, 16) / 255, tonumber(hb, 16) / 255, 0.9)
            end
            r.desc:SetText(d.desc)
            r.xp:SetText("+" .. d.xp .. " XP")
            r.bar:SetMinMaxValues(0, d.goal)
            r.bar:SetValue(d.progress)
            r.bar.text:SetText(d.done and "Done!" or ("%s / %s"):format(Fmt(d.progress), Fmt(d.goal)))
            if d.done then
                r.bg:SetColorTexture(0.35, 0.28, 0.05, 0.35)
                r.bar:SetStatusBarColor(1, 0.82, 0)
                r.check:Show()
                r.desc:SetTextColor(1, 0.82, 0)
            else
                r.bg:SetColorTexture(1, 1, 1, 0.05)
                r.bar:SetStatusBarColor(0.1, 0.6, 0.1)
                r.check:Hide()
                r.desc:SetTextColor(1, 1, 1)
            end
        end

        -- Unfinished first (closest to done at the top), finished at the bottom.
        local order = {}
        for _, r in ipairs(rows) do
            local c = r.challenge
            local done = acct.done[c.id]
            r.sortKey = done and (2 + 1 / done) or (1 - math.min(c.progress(), c.goal) / c.goal)
            if done and hideDone then r:Hide() else r:Show() table.insert(order, r) end
        end
        table.sort(order, function(a, b) return a.sortKey < b.sortKey end)
        content:SetHeight(math.max(1, #order * ROW_H))

        for i, r in ipairs(order) do
            local c = r.challenge
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            local done = acct.done[c.id]
            local p = math.min(c.progress(), c.goal)
            r.reward:SetText("+" .. Fmt(c.xp) .. " XP")
            r.name:SetText(c.name)
            if done then
                r.bg:SetColorTexture(0.35, 0.28, 0.05, 0.35)
                r.border:SetColorTexture(1, 0.82, 0, 0.9)
                r.iconEdge:SetColorTexture(1, 0.82, 0, 0.9)
                r.icon:SetDesaturated(false)
                r.icon:SetAlpha(1)
                r.check:Show()
                r.name:SetTextColor(1, 0.82, 0)
                r.desc:SetTextColor(0.8, 0.8, 0.8)
                r.reward:SetTextColor(1, 0.82, 0)
                r.bar:Hide()
                r.status:SetText("Completed " .. date("%Y-%m-%d", done))
            else
                r.bg:SetColorTexture(1, 1, 1, 0.04)
                r.border:SetColorTexture(0.5, 0.5, 0.5, 0.5)
                r.iconEdge:SetColorTexture(0.35, 0.35, 0.35, 0.9)
                -- Started ones are in colour; untouched ones are greyed out.
                r.icon:SetDesaturated(p == 0)
                r.icon:SetAlpha(p == 0 and 0.6 or 1)
                r.check:Hide()
                r.name:SetTextColor(1, 1, 1)
                r.desc:SetTextColor(0.75, 0.75, 0.75)
                r.reward:SetTextColor(0.7, 0.7, 0.7)
                r.bar:Show()
                r.bar:SetValue(p)
                r.bar:SetStatusBarColor(0.1, 0.6, 0.1)
                r.bar.text:SetText(("%s / %s"):format(Fmt(p), Fmt(c.goal)))
                r.status:SetText("")
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
    AddCheck("Show minimap button", "The Jumps button on the edge of the minimap. "
        .. "Click it to open Jumps, right-click for settings, drag to move it.",
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
    SettingCheck("friendLevels", "Friends' character levels",
        "A chat message when someone on your leaderboard levels up their character: "
        .. "at level 10 and 20, then every level from 30 (the early levels come too fast).")
    SettingCheck("overtakes", "Overtakes",
        "When you pass someone on the leaderboard or they pass you (at most once per person every 10 min).")

    Section("Duels, crown & sound")
    SettingCheck("duels", "Random jump duels",
        "Now and then you're paired with another player who is jumping around for a 30-second "
        .. "jump-off. Most jumps wins. At most one duel every 10 minutes, and the same two players "
        .. "once per 30 minutes (also with /jumps duel). More players around means more duels.")
    SettingCheck("duelNews", "Other players' duel results",
        "A chat line with the result when two other players finish a jump duel.")
    SettingCheck("crownNews", "The crown",
        "Whoever jumps most in an hour holds the crown. A chat line when someone takes it "
        .. "(not in the first 20 minutes of the hour, at most every 5 minutes) and when the hour's winner is decided.")
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
-- The window itself: a standard WoW panel (portrait, title, close button,
-- inset) with tabs along the bottom, like the Character window.
---------------------------------------------------------------------------
local TABS = {
    { id = "overview",   label = "Overview",    build = BuildOverviewTab },
    { id = "board",      label = "Leaderboard", build = BuildLeaderboardTab },
    { id = "challenges", label = "Challenges",  build = BuildChallengesTab },
    { id = "settings",   label = "Settings",    build = BuildSettingsTab },
}

local function CreateMainFrame()
    local W, H = 860, 520
    local f
    if HasTemplate("ButtonFrameTemplate") then
        f = CreateFrame("Frame", "JumpCounterMain", UIParent, "ButtonFrameTemplate")
    else
        f = CreateFrame("Frame", "JumpCounterMain", UIParent)
    end
    -- Did the template give us the Blizzard frame art?
    local function Part(obj, key)
        local v = obj and obj[key]
        if type(v) == "table" then return v end
    end
    local native = Part(f, "Inset") ~= nil
        and (Part(f, "CloseButton") or Part(f, "TitleText") or Part(f, "TitleContainer")) ~= nil
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:Hide()
    MakeMovable(f)
    tinsert(UISpecialFrames, "JumpCounterMain")

    if not native then
        -- Fallback look: a tooltip-style box with a close button.
        local bg = CreateFrame("Frame", nil, f, "BackdropTemplate")
        bg:SetAllPoints()
        bg:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
        bg:SetBackdrop(BACKDROP)
        bg:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
    end

    -- Title.
    local title = "Jumps"
    if Part(f, "TitleText") then
        f.TitleText:SetText(title)
    elseif Part(Part(f, "TitleContainer"), "TitleText") then
        f.TitleContainer.TitleText:SetText(title)
    elseif native and type(f.SetTitle) == "function" then
        f:SetTitle(title)
    else
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOP", 0, -8)
        t:SetText(title)
    end

    -- Portrait: your character, like the Character window.
    local portrait = Part(f, "portrait") or Part(f, "Portrait") or Part(Part(f, "PortraitContainer"), "portrait")

    -- Content area.
    local content = Part(f, "Inset")
    if content then
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", 4, -60)
        content:SetPoint("BOTTOMRIGHT", -6, 6)
    else
        content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", 8, -60)
        content:SetPoint("BOTTOMRIGHT", -8, 8)
    end

    -- The strip between title and content, on every tab: who you are, your
    -- jump level, and an XP bar (plus the update notice when there is one).
    local strip = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    strip:SetPoint("TOPRIGHT", -12, -27)
    strip:SetJustifyH("RIGHT")
    local who = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    who:SetPoint("TOPLEFT", 66, -27)
    who:SetPoint("RIGHT", strip, "LEFT", -10, 0)
    who:SetJustifyH("LEFT")
    who:SetWordWrap(false)
    -- The Prestige button: in the header, left of your jump level, once you
    -- have reached jump level 100 (1.8.8; it used to be on the Overview tab).
    local prestigeButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prestigeButton:SetSize(92, 18)
    prestigeButton:SetPoint("RIGHT", strip, "LEFT", -10, 0)
    prestigeButton:SetText("Prestige!")
    prestigeButton:SetScript("OnClick", function() AskPrestige() end)
    prestigeButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Prestige")
        GameTooltip:AddLine("You've reached jump level " .. PRESTIGE_LEVEL .. "! Reset your jump level to 1 and "
            .. "earn a prestige star. Total jumps, ranks, total XP and challenges are kept.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    prestigeButton:SetScript("OnLeave", GameTooltip_Hide)
    prestigeButton:Hide()
    local headBar = ProgressBar(f, 11, 0.58, 0.0, 0.55)
    headBar:SetPoint("TOPLEFT", 68, -45)
    headBar:SetPoint("TOPRIGHT", -14, -45)
    headBar.text:SetFontObject("TextStatusBarText")
    for _, side in ipairs({ "TOP", "BOTTOM" }) do
        local edge = headBar:CreateTexture(nil, "OVERLAY")
        edge:SetColorTexture(0.6, 0.5, 0.3, 0.8)
        edge:SetHeight(1)
        edge:SetPoint(side .. "LEFT", -1, side == "TOP" and 1 or -1)
        edge:SetPoint(side .. "RIGHT", 1, side == "TOP" and 1 or -1)
    end

    -- Pages.
    local PAD = 10
    local innerW = W - 10 - PAD * 2
    local pages = {}
    for _, tab in ipairs(TABS) do
        local page = CreateFrame("Frame", nil, content)
        page:SetPoint("TOPLEFT", PAD, -PAD)
        page:SetPoint("BOTTOMRIGHT", -PAD, PAD)
        page:Hide()
        tab.build(page, innerW)
        pages[tab.id] = page
    end

    -- Tabs along the bottom (Blizzard tab art if available).
    local tabTemplate = (HasTemplate("PanelTabButtonTemplate") and "PanelTabButtonTemplate")
        or (HasTemplate("CharacterFrameTabButtonTemplate") and "CharacterFrameTabButtonTemplate") or nil
    local tabs = {}
    for i, tab in ipairs(TABS) do
        local b = CreateFrame("Button", "JumpCounterMainTab" .. i, f, tabTemplate)
        b:SetID(i)
        local art = Part(b, "Left") or Part(b, "LeftActive") or Part(b, "LeftDisabled")
        if not art then
            -- No Blizzard tab art: a simple flat tab.
            b:SetSize(110, 26)
            local bg = b:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.12, 0.1, 0.06, 0.95)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 0.82, 0, 0.12)
            if not b:GetFontString() then
                local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("CENTER")
                b:SetFontString(fs)
            end
        end
        b:SetText(tab.label)
        if art and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0) end
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, art and 2 or -2)
        else
            -- New (Dragonflight-style) tab art sits apart, old art overlaps.
            b:SetPoint("TOPLEFT", tabs[i - 1], "TOPRIGHT", (not art or Part(b, "LeftActive")) and 3 or -15, 0)
        end
        b:SetScript("OnClick", function()
            f:ShowTab(tab.id)
            if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
        end)
        b.tabId = tab.id
        tabs[i] = b
    end
    f.Tabs = tabs
    f.numTabs = #tabs
    if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, f, #tabs) end

    local function SelectTab(index)
        if PanelTemplates_SetTab and pcall(PanelTemplates_SetTab, f, index) then return end
        for i, b in ipairs(tabs) do
            local fs = b:GetFontString()
            if fs then
                if i == index then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(1, 0.82, 0) end
            end
        end
    end

    function f:ShowTab(id)
        if not pages[id] then id = "overview" end
        JumpCounterDB.ui.mainTab = id
        for i, tab in ipairs(TABS) do
            pages[tab.id]:SetShown(tab.id == id)
            if tab.id == id then SelectTab(i) end
        end
        if id == "board" then RequestScores() end
        pages[id]:Refresh()
    end

    function f:RefreshHeader()
        local newer = NewestVersion()
        local me = Me()
        local level, into, need = EntryLevel(me)
        local rankTitle = GetJumpRank(me.total)
        who:SetText(FactionIcon(MyFaction()) .. ColoredName(playerKey, charData.class)
            .. (rankTitle and ("  |cffffffff<%s>|r"):format(rankTitle) or "")
            .. (newer and ("   |cffff5555Update available: v%s|r |cff999999(/jumps update)|r"):format(newer) or ""))
        strip:SetText(PrestigeTag(EntryPrestige(me)) .. "Jump level |cffffd100" .. level .. "|r")
        prestigeButton:SetShown(CanPrestige())
        headBar:SetMinMaxValues(0, need)
        headBar:SetValue(into)
        headBar.text:SetText(("XP %s / %s"):format(Fmt(into), Fmt(need)))
        if portrait and SetPortraitTexture then pcall(SetPortraitTexture, portrait, "player") end
    end

    function f:Refresh()
        self:RefreshHeader()
        local id = JumpCounterDB.ui.mainTab or "overview"
        if pages[id] and pages[id]:IsShown() then pages[id]:Refresh() end
    end

    f:SetScript("OnShow", function(self)
        self:ShowTab(JumpCounterDB.ui.mainTab or "overview")
        self:RefreshHeader()
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
    end)
    f:SetScript("OnHide", function()
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
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
    panel.name = "Jumps"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Jumps " .. GRAY:format("v" .. VERSION))

    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetWidth(520)
    text:SetJustifyH("LEFT")
    text:SetText("Everything - your stats, the leaderboard, challenges and settings - is in the "
        .. "Jumps window. Open it with /jumps or from the addon menu next to the minimap.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(180, 26)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    open:SetText("Open Jumps")
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
    Daily.OnDeath()
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
    elseif cmd == "forget" then
        -- /jumps forget <name> (1.8.11): hide one of your characters - deleted,
        -- or just not worth listing - from your character list, here and for
        -- friends. Its jumps stay in your total and its data is kept; logging
        -- in on it shows it again.
        local want = ((input or ""):match("^%s*%S+%s+(.-)%s*$") or ""):lower()
        local mine = {}
        for key, c in pairs(JumpCounterDB.chars) do
            local full = c.display or c.name or key:match("^[^-]+") or key
            table.insert(mine, { key = key, c = c, full = full })
        end
        table.sort(mine, function(a, b) return (a.c.total or 0) > (b.c.total or 0) end)
        local function List()
            for _, m in ipairs(mine) do
                Print(("  %s - %s jumps%s%s"):format(m.full, BreakUpLargeNumbers(m.c.total or 0),
                    m.c == charData and " |cff999999(you're on it)|r" or "",
                    m.c.hidden and " |cff999999(forgotten)|r" or ""))
            end
        end
        if want == "" then
            Print("/jumps forget <name> hides one of your characters (one you've deleted, say) from your "
                .. "character list - for friends too. Its jumps stay in your total; logging in on it shows it again. "
                .. "Your characters:")
            List()
            return
        end
        -- The full name, or the first name if only one character has it.
        local found, matches = nil, 0
        for _, m in ipairs(mine) do
            if m.full:lower() == want then found, matches = m, 1 break end
        end
        if not found then
            for _, m in ipairs(mine) do
                if FirstWord(m.full) == want then found, matches = m, matches + 1 end
            end
        end
        if matches ~= 1 then
            Print(((matches == 0 and "None of your characters is called \"%s\"." or
                "More than one of your characters is called \"%s\" - use the full name.") .. " Your characters:")
                :format(want))
            List()
        elseif found.c == charData then          -- (saved by GUID, not by name)
            Print("That's the character you're playing - log in on another one to forget this one.")
        elseif found.c.hidden then
            Print(("%s is already forgotten. Log in on it to show it again."):format(found.full))
        else
            found.c.hidden = true
            dirty = true
            RefreshBoardSoon()
            Print(("%s is no longer listed among your characters. Its %s jumps still count in your total. "
                .. "Log in on it to show it again."):format(found.full, BreakUpLargeNumbers(found.c.total or 0)))
        end
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
        ShowUpdateWindow(NewestVersion())
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
            Print(("Friends confirmed using Jumps: whisper=%d, Battle.net=%d. Queued messages: %d")
                :format(nWhisper, nBNet, QueuedCount()))
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
            and (" - |cffff5555v" .. newest .. " is out!|r Type /jumps update for the link.") or " (newest seen)"))
        if #outdated > 0 then
            table.sort(outdated)
            Print("Players on older versions: " .. table.concat(outdated, ", "))
        end
    elseif cmd == "reset" then
        charData.total = 0
        sessionJumps = 0
        acct.session.jumps = 0
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
        Print("/jumps - open the Jumps window (stats, leaderboard, challenges, settings)")
        Print("/jumps board | challenges | settings - open the window on that tab")
        Print("/jumps counter - show/hide the small on-screen counter")
        Print(("/jumps prestige - reset your jump level at level %d for a prestige star"):format(PRESTIGE_LEVEL))
        Print("/jumps name <full name> - set this character's full name (if only the first shows)")
        Print("/jumps duel - challenge a random player who is jumping right now")
        Print("/jumps update - the CurseForge link for the newest version")
        Print("/jumps minimap - show/hide the minimap button")
        Print("/jumps lock - lock/unlock counter position")
        Print("/jumps share - announce your jumps in chat")
        Print("/jumps clear - remove other players from your leaderboard")
        Print("/jumps version - your version and who is on an older one")
        Print("/jumps reset - reset this character's jump count (others on the account keep theirs)")
        Print("/jumps forget <name> - stop listing one of your characters (a deleted one); its jumps still count")
        Print("Scores sync with your guild, your WoW and Battle.net friends, and the people they know.")
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
    GameTooltip:AddDoubleLine("Jumps", "v" .. VERSION, 1, 0.82, 0, 0.6, 0.6, 0.6)
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
    GameTooltip:AddLine("Click: open Jumps", 0.8, 0.8, 0.8)
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
        -- 1.8.3 / 1.8.6: prestige was rebalanced - recalculate our stars
        -- from total XP, once. 1.8.6 also halved challenge rewards: the XP of
        -- the challenges already done is worked out again from the list
        -- (duel, crown and daily XP stay as they are).
        if (acct.prestigeModel or 1) < PRESTIGE_MODEL then
            local before, xpBefore = acct.prestige or 0, EntryXP(Me())
            local cxp = 0
            for _, c in ipairs(CHALLENGES) do
                if acct.done[c.id] then cxp = cxp + c.xp end
            end
            acct.challengeXP = cxp
            local stars = StarsForXP(EntryXP(Me()))
            acct.prestige, acct.prestigeSpent, acct.prestigeModel = stars, stars * PRESTIGE_XP, PRESTIGE_MODEL
            dirty = true
            if before > 0 or xpBefore > 0 then
                C_Timer.After(6, function()
                    Print(GOLD:format(("Prestige has been rebalanced: stars now come at jump level %d, and "
                        .. "challenges give half the XP (also the ones you've done). Your stars were "
                        .. "recalculated from your total XP: %d prestige %s, jump level %d."):format(
                        PRESTIGE_LEVEL, stars, stars == 1 and "star" or "stars", (EntryLevel(Me())))))
                end)
            end
        end
        knownLevel = EntryLevel(Me())
        LearnMyNameFromUnit()
        -- Stats combined from several characters (or new challenges) may
        -- already be finished.
        UpdateDerivedStats()
        Daily.CheckWeekly()               -- a weekly goal the others reached while we were away
        CheckChallenges()
        -- 1.8.13: "Best duel" starts over, once (duel jumps are capped from
        -- this version). After the check above, so a best that already beat
        -- a challenge's goal still completes it.
        if (acct.bestDuelFrom or 0) < 1 then
            acct.stats.bestDuel, acct.bestDuelFrom = nil, 1
            dirty = true
        end
        JumpCounterDB.jumpTrace = nil      -- left over from a 1.8.5 test build
        hooksecurefunc("JumpOrAscendStart", OnJump)
        Print(("v%s loaded - type /jumps to open."):format(VERSION))

        -- 1.8.11: once, players last heard in a dungeon/raid/battleground
        -- group (older versions sent scores there) leave the board - unless
        -- they're in your guild or on your friends list. Waits for the guild
        -- roster; until then nobody is dropped.
        local groupTries = 0
        local function DropGroupStrangers()
            local db = JumpCounterDB
            if (db.circles or 0) >= 2 then return end
            local any = false
            for _, d in pairs(db.peers) do
                if d.via == "GROUP" and not d.friend then any = true break end
            end
            if any and IsInGuild() and GetNumGuildMembers and (GetNumGuildMembers() or 0) == 0 then
                groupTries = groupTries + 1
                if groupTries > 10 then return end      -- roster never came: next login
                if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
                elseif GuildRoster then GuildRoster() end
                C_Timer.After(30, DropGroupStrangers)
                return
            end
            if any then
                local known = {}          -- first names on your friends lists
                if C_FriendList and C_FriendList.GetNumFriends then
                    for i = 1, C_FriendList.GetNumFriends() do
                        local info = C_FriendList.GetFriendInfoByIndex(i)
                        if info and info.name then known[FirstWord(info.name:match("^[^-]+") or info.name)] = true end
                    end
                end
                if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
                    for i = 1, (BNGetNumFriends()) do
                        for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                            if g and g.characterName then known[FirstWord(g.characterName)] = true end
                        end
                    end
                end
                local myGuild = GetGuildInfo and Plain((GetGuildInfo("player"))) or nil
                for key, d in pairs(db.peers) do
                    if d.via == "GROUP" and not d.friend then
                        local first = key:match("^[^-~]+") or key
                        local keep = known[FirstWord(first)] or (d.display and known[FirstWord(d.display)])
                            or (myGuild and d.guild == myGuild)
                        if not keep and IsInGuild() and C_GuildInfo and C_GuildInfo.MemberExistsByName then
                            local ok, yes = pcall(C_GuildInfo.MemberExistsByName, first)
                            keep = ok and yes
                        end
                        if not keep then db.peers[key] = nil end
                    end
                end
            end
            db.circles = 2
        end
        if (JumpCounterDB.circles or 0) < 2 then
            if IsInGuild() then
                if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
                elseif GuildRoster then GuildRoster() end
            end
            C_Timer.After(45, DropGroupStrangers)
        end

        CreateDuelFrame()
        C_Timer.NewTicker(60, MaybeStartRandomDuel)
        C_Timer.NewTicker(5, CrownTick)
        -- Pass scores on to the guild and quiet friends every minute (random
        -- delay so guild members don't all send at once). Most minutes there's
        -- nothing new to send.
        C_Timer.NewTicker(60, function()
            C_Timer.After(math.random() * 30, RelayTick)
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
            acct.session.at = time()          -- still online (see "this session")
            if not Plain(UnitIsAFK("player")) then
                local before = JumpsPerHour(Me())
                charData.rate.seconds = charData.rate.seconds + dt
                AddRate(0, dt)
                -- Share the rate once it first becomes available.
                if not before and JumpsPerHour(Me()) then dirty = true end
            end
        end)
        -- Announce ourselves and ask friends for their scores shortly
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
    end
end)
