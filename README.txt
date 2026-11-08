JumpCounter
===========

Counts your jumps and deaths, gives you jump levels, ranks and challenges,
and puts you on a leaderboard with your friends.

INSTALL
  1. Unzip so you get a folder named "JumpCounter".
  2. Put it in:  World of Warcraft\_forever_\Interface\AddOns\
     (the .toc file must be at AddOns\JumpCounter\JumpCounter.toc,
      not AddOns\JumpCounter\JumpCounter\JumpCounter.toc)
  3. Restart the game, or type /reload if you're already logged in.

OPEN IT
  Everything counts for your whole account: jumps, deaths, this week,
  jumps per hour, jump level, prestige and challenges are shared by all
  your characters (on the same computer). The leaderboard shows one row
  for you, under the character you're playing; hover it to see each
  character's jumps. Jumps from before a character had the addon aren't
  known, and a character's deaths are added the first time you log it in.

  Type /jumps, click the JumpCounter button on the minimap (drag it to
  move it, hide it in Settings), or use the addon menu next to the minimap.
  Everything is in that one window:

    Top        your name, prestige stars, jump level, rank, next rank and
               an XP bar. A "Prestige!" button appears here at level 30.
    Stat row   total jumps, this week, jumps per hour, deaths, challenges
               and your position on the leaderboard.
    Tabs       Leaderboard - All time / This week / Per hour / Level / Deaths.
                             Hover a player for all their details. Your own
                             row is always shown at the bottom.
               Challenges  - progress on every challenge, closest first.
               Settings    - which chat messages you get, and the small
                             on-screen counter.

HOW SCORES SYNC
  Friends on v1.1.0 or newer see your whole account as one row. Friends on
  older versions still see a row for each of your characters until they
  update.

  Your score is shared automatically with anyone running the addon who is:
    - in your guild
    - in your party or raid
    - on your in-game friends list and online
    - your Battle.net friend and online in WoW (works across factions!)

CHAT MESSAGES (change them in the Settings tab)
    - your milestones: 100, 500 and every 1,000 jumps
    - your level-ups, completed challenges and new ranks
    - friends' new ranks and prestiges
    - when you pass someone on the leaderboard, or they pass you

JUMP LEVELS, CHALLENGES & PRESTIGE
  Every jump on any of your characters gives 1 XP, and challenges (once per
  account) give bonus XP (about level 8 at 1,000 XP, 27 at 10,000). At jump
  level 30 you can prestige: your level goes back to 1 and you get a star.
  Total jumps, ranks, total XP and challenges are kept.

  46 challenges: mounted, swimming, ghost, combat, dungeon, group, zone,
  session, sprint, no-death, day and week goals in several tiers, plus
  day streaks, inns, stealth, druid forms / Ghost Wolf, battlegrounds,
  night owl, low health, max level, different classes and prestige.

JUMPS PER HOUR
  Jumps divided by your online time, not counting time flagged AFK. Shown
  after 30 minutes of online time (counted from v0.9.0).

JUMP RANKS
       100 Hopper            7,500 Trampoline Artist   87,500 Comet Rider
       250 Skipper          10,000 Moon Boots         100,000 Legend of the Leap
       500 Bunny Hopper     12,500 Bounce Baron       125,000 Starhopper
       750 Spring Step      15,000 Cloud Hopper       150,000 Jumpmaster
     1,000 Leapfrog         20,000 Featherfoot        200,000 Gravity's Bane
     1,750 Cricket          25,000 Gravity Defier     250,000 Sky Sovereign
     2,500 Kangaroo         30,000 Jet Hopper         350,000 Eclipse Leaper
     3,250 Wallaby          35,000 Rocket Legs        500,000 Ascended
     4,000 Jackrabbit       42,500 Skybound           750,000 Celestial
     5,000 Pogo Master      50,000 Low Orbit        1,000,000 The Unfallen
     6,250 Springheel       62,500 Meteor           1,500,000 Myth of the Leap
                            75,000 Stratosphere     2,500,000 Eternal Bounce
                                                    5,000,000 Defier of Worlds

COMMANDS (/jumps or /jc)
  /jumps             open the JumpCounter window
  /jumps board       open it on the leaderboard
  /jumps challenges  open it on challenges
  /jumps settings    open it on settings
  /jumps prestige    prestige (at jump level 30)
  /jumps counter     show/hide the small on-screen counter
  /jumps minimap     show/hide the minimap button
  /jumps name <full name>  set this character's full name if only the
                     first name shows (e.g. /jumps name Zivv Pewpew)
  /jumps lock        lock/unlock the counter position
  /jumps share       post your total in chat
  /jumps version     your version, and who is on an older one
  /jumps clear       remove other players from your leaderboard
  /jumps reset       reset this character's jump count (others keep theirs)
  /jumps help        list commands
