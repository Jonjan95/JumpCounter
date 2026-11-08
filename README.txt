JumpingCounter
==============

Counts your jumps and deaths, gives you jump levels, ranks and challenges,
and puts you on a leaderboard with your friends.

INSTALL
  Easiest: install "JumpingCounter" with the CurseForge app (game version
  Forever) from https://www.curseforge.com/wow/addons/jumpingcounter
  - updates are then one click. Or by hand from
  https://github.com/Jonjan95/JumpCounter/releases/latest :
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

  Type /jumps, click the JumpingCounter button on the minimap (drag it to
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

  Friends also pass on the scores they know, so friends of friends show up
  too - including the other faction through a Battle.net friend. Those rows
  say "via friends" on hover. The faction icon is shown next to each name.

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

  There are lots of challenges to find - open the Challenges tab to see
  what you're working towards.

JUMP DUELS
  Now and then two players who are jumping around get paired for a
  2-minute jump duel: a small window counts down and shows both scores,
  and whoever jumps most wins bonus XP. Everyone online with the addon
  sees the result in chat. At most one random duel every 30 minutes;
  turn them off (or the results of others' duels) in Settings.
  Both players need v1.7.0 or newer.

JUMPS PER HOUR
  Jumps divided by your online time, not counting time flagged AFK. Shown
  after 30 minutes of online time (counted from v0.9.0).

JUMP RANKS
  Your all-time jumps earn you rank titles, from your first 100 jumps to
  far beyond what anyone has reached yet. Only your next rank is shown
  in the window - the rest are up to you to discover.

COMMANDS (/jumps or /jc)
  /jumps             open the JumpingCounter window
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
  /jumps update      the CurseForge link
  /jumps duel        challenge a random player who is jumping right now
  /jumps clear       remove other players from your leaderboard
  /jumps reset       reset this character's jump count (others keep theirs)
  /jumps help        list commands
