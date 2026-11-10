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
  Everything is in that one window. Your name, rank, jump level and XP bar
  are always at the top, with tabs along the bottom:

    Overview     your big numbers, your next rank and the challenges you're
                 closest to, your jumps over the last 7 days, your records
                 and all your numbers. A "Prestige!" button appears here at
                 level 100.
    Leaderboard  everyone you can see: level, title, total jumps, this hour,
                 this week, average per hour, deaths, duel rank and wins. It
                 opens sorted by this hour; click a column header to sort
                 by another (your choice is remembered), and
                 hover a player for all their details. Your own row is
                 always shown at the bottom, and the bottom line tells you
                 how far it is to the player above you.
    Challenges   today's three daily challenges, then every challenge,
                 closest to done first.
    Settings     which chat messages you get, and the small on-screen
                 counter (your total, level, XP bar and leaderboard place).

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
    - friends' character levels: at 10 and 20, then every level from 30
    - when you pass someone on the leaderboard, or they pass you

JUMP LEVELS, CHALLENGES & PRESTIGE
  Every jump on any of your characters gives 1 XP, and challenges, daily
  challenges, duels and the crown give bonus XP (about level 13 at 1,000 XP,
  42 at 5,000). At jump level 100 (20,493 XP) you can prestige: your level
  goes back to 1 and you get a star - about one every few weeks of normal
  play. Total jumps, ranks, total XP and challenges are kept. (In v1.8.6
  prestige moved from level 50 to 100 and challenge rewards were halved,
  also for challenges already done; everyone's stars were recalculated from
  their total XP, so the same XP always means the same stars.)
  Your star changes look as you collect more of them. (The addon's own
  images - stars and medals in v1.8.6, the duel figures in v1.8.7 - are
  only found when the game starts: restart it once after updating to see
  them.)

  There are lots of challenges to find - open the Challenges tab to see
  what you're working towards.

  DAILY CHALLENGES: three new ones every day - easy, medium and hard - for
  extra XP. Everyone gets the same three, so you can race your friends.
  They're at the top of the Challenges tab and reset with the daily reset.

JUMP DUELS
  Now and then two players who are jumping around get paired for a
  30-second jump duel: a window shows the two of you - portrait, name and
  score on each side, and a little figure for each that hops when that
  player jumps - and whoever jumps most wins bonus XP. Everyone online with the addon
  sees the result in chat. The more of you are jumping, the more often
  duels happen: at most one every 10 minutes for you, and the same two
  players once per 30 minutes (also with /jumps duel). Turn them off (or
  the results of others' duels) in Settings. No duels while swimming.
  Hopping on the spot against a tree or a wall counts no faster than
  normal jumping (v1.8.7).
  Both players need v1.7.0 or newer.

  DUEL RANKS: duels are rated, like chess. Win and you take duel points
  from your opponent - more for beating someone ranked higher - and lose
  and they take yours (less if they were ranked higher). New duelists
  don't lose points until they reach the third rank, and after 3 losses in
  a row the next one is free. So the top ranks belong to whoever wins the
  most. Others see your rank and wins (hover your name, or sort the
  leaderboard by the Duel rank column).

THE CROWN
  Whoever jumps the most in the current hour holds the crown (shown next
  to their name on the leaderboard - see the "This hour" tab). When the
  hour ends, the holder wins it and gets bonus XP. A fresh race every
  hour, so anyone can take it. Needs at least 25 jumps that hour.

AVERAGE JUMPS PER HOUR (Avg / hour)
  Your jumps divided by your online time over the last 7 days, not
  counting time flagged AFK - so everyone is compared on what they did
  recently, whether they've had the addon for a day or a month. Shown
  after 30 minutes of online time in those 7 days (counted from v1.8.2).

JUMP RANKS
  Your all-time jumps earn you rank titles, from your first 100 jumps to
  far beyond what anyone has reached yet. Only your next rank is shown
  in the window - the rest are up to you to discover.

COMMANDS (/jumps or /jc)
  /jumps             open the JumpingCounter window
  /jumps board       open it on the leaderboard
  /jumps challenges  open it on challenges
  /jumps settings    open it on settings
  /jumps prestige    prestige (at jump level 100)
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
