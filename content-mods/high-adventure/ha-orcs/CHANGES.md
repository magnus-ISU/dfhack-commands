# ha-orcs — fork changelog

## v0.17
- **PEON caste**: identical to the common orc but with no baby/child stage (born
  a working adult) at POP_RATIO 1 against 100,000 (all other ratios scaled x1000,
  succubus-style) - effectively pit-only, though one in a hundred thousand is
  birthed naturally. The breeding pit now spawns PEONs born **today, age 0,
  accurately**. Wears the common orc's art. Script falls back to SNAGA in worlds
  generated before this version.

## v0.15
- **Green-blooded faith**: orcs now worship good gods of nature and mirth -
  spheres NATURE/ANIMALS/TREES/FESTIVALS/REVELRY/GAMES/MUSIC/STRENGTH (thralldom,
  war, victory, and fortresses dropped); values NATURE -15 → **+50** and
  **MERRIMENT +40** added. The horde raids joyfully under laughing forest gods -
  ideological opposites of the illithids (nature -50, merriment -30, thralldom
  deities) and at odds with cityfolk, while remaining thieves at war with all.

## v0.13
- **All seven founders are champions**: on first fort load per site, every
  common-caste founder is converted to a random champion caste (size and cached
  flags updated), with an announcement. Migrants and pit-spawn remain 80/20
  commons.

## v0.12
- Breeding grants 70 script xp per attempt (+~30 native from the reaction skill
  = ~100 total, as intended).

## v0.11
- **Breeding actually works now**: the reaction hook was registered via
  `eventful.onReactionComplete`, which silently requires a JOB_COMPLETED event
  subscription we never made — 21 attempts, zero callbacks (the ~30xp you saw was
  the raw SKILL token's native grant). Switched to `eventful.registerReaction`,
  the native per-reaction hook. The +100xp and the birth roll now fire per attempt.
- Breeding costs **1 meat** per attempt (was 5), fitting the high failure rate.
- Art: purple troll-blood removed; blood is now **scattered spatter clusters**
  across the whole pool, no fully-red tiles. Render position fixed (was one tile
  too high — workshop graphics rows are 1-based).
- Script renamed to **high-adventure/orcs** (auto-enables; effective next reload).

## v0.10
- **Construction-stage art**: the pit now grows as it is built — stage 0 is a few
  splotches of vomit, stage 1 a small pool, stage 2 a wide pool with the churned
  work-spot, stage 3 the full rimmed pit with gaps, blood, and troll blood
  (640x160 four-column sheet, same organic boundary seed so the pool grows in
  place).

## v0.9
- Breeding Pit art redrawn: organic pool boundary with a proper dark rim in the
  border tiles (no more center-texture edges); gaps, blood, and troll blood kept.
- Build cost reduced to **1 skull totem**.
- Note: the pit cannot replace or occupy the Trade Depot slot - the depot is a
  hardcoded building, not raw-defined, and custom buildings can only appear under
  Workshops. It stays a workshop.

## v0.8 — Breeding Pit rework: direct spawning
- **Unit creation works on current DFHack** (validated live: create → place →
  makeown → rename produces a full flesh-and-blood citizen). The gas/syndrome
  contraption is gone.
- Each breeding job now attempts a birth **immediately**: base **75% failure**,
  falling **linearly to 0% at legendary** strand extractor; **100 xp** per attempt
  (was 1000). Success spawns a common orc at the worker as a full citizen, named
  **Peon** plus an orcish surname.
- **Pit is reusable** and built from **3 skull totems** (corpses and loose bones
  are not valid build items - that was why it demanded random anvils/thread; the
  totem filter is the bone-cutter-proven pattern).
- The spawnmist inorganic remains defined but inert (removing raws from live
  worlds shifts material indices).

## v0.7
- Breeding Pit build cost corrected: **3 corpses**, nothing else (was wrongly
  3 logs + 2 of any item via BUILDMAT/BONES tokens). Flesh for the flesh pit.

## v0.6
- Caste flavor text set: commons "A medium-sized creature, ready to give its life
  for the horde." / champions "A hulking brute whose bloodlust drives the horde."
- **Breeding Pit art**: 5x5 pool of vomit with two tiles of blood, two of troll
  blood, three ragged gaps where the floor shows through, and a churned swirl at
  the work spot. Wired to all four construction stages.

## v0.4 — all fourteen arts, two stat profiles
- All 14 Topples caste arts restored (36 graphics files, 72 images), but stats no
  longer vary by art: **6 smaller-sprite castes** (SNAGA, SNUFFLER, PUS_PICKER,
  FILTH_CALLER, MUTT, HOBBLER) share the common-orc profile ("orc", POP 80 total),
  and **8 larger-sprite castes** (SKINNER, MUSH_FACE, SOMBOLG, JOBBER, GRISHNAHRK,
  GORE_BAG, SAW_GOD, SKULL_CRUNCHER) share the champion profile ("orc champion",
  POP 20 total, 130k size, NOPAIN, rage, leadership class). Skull-cruncher special
  attacks extended to all champion castes. Original caste genders preserved.
- Companion script now **auto-enables on fort load** (no manual `enable ha-orcs`).

## v0.2
- **Two castes only** (design simplification): the other 12 Topples castes removed.
  - **SNAGA** = "orc" — the common caste, FEMALE, `POP_RATIO:80`.
  - **SKULL_CRUNCHER** = "orc champion" — MALE, `POP_RATIO:20`, 130k cm³, NOPAIN,
    rage-prone. Breeding: champion fathers × orc mothers; children roll 80/20.
- **All leadership champion-gated**: great warlord, horde master, war chiefs, raid
  bosses, boss/big boss (site leaders), war boss and raid leaders (militia — "even
  squad commander"). Only the taskmaster and enforcer are open to common orcs.
- **Breeding Pit implemented** (5×5 workshop, built from 3 buildmat + 2 bone stacks):
  the "breed orcs from meat" reaction consumes 5 units of unrotten meat and releases
  a *spawning musk* gas; orcs who inhale it gain a short-lived "spawn orcling"
  ability that fires on social contact, summoning a **SNAGA-caste orc only — the pit
  never produces champions**. Summons are permanent (no expiry); the bundled DFHack
  watcher (`enable ha-orcs`) adopts each orcling into the fort as a full citizen via
  `makeown` with an announcement.
- Graphics: fixed the caste-key rename (`CREATURE_CASTE_GRAPHICS:ORC:*` →
  `HA_ORC:*` — v0.1 art was still keyed to Topples' creature) and deleted the 12
  unused castes' art (mod shrinks ~7MB → 1.3MB).

Sources: creature + all 14-caste layered art forked from **Topples' Orcs** (Steam
2946888253) with caste names preserved so the art maps untouched; entity forked from
**vanilla PLAINS** (humans). IDs renamed: creature `HA_ORC`, entity `HA_ORC_CIV`,
translation `HA_BLACK_SPEECH`, all interactions `HA_*`-prefixed, graphics pages
`HA_ORC_*`. Coexists with Topples' Orcs.

## Creature changes vs Topples
- **Bigger than humans**: adult sizes raised 55–65k → **80–90k** across all castes.
- **Champion caste**: SKULL_CRUNCHER `POP_RATIO` 1 → **25** (~20%), grows to
  **130,000 cm³**, gains `NOPAIN`, `PRONE_TO_RAGE:12`, anger propensity 60:85:100,
  and `CREATURE_CLASS:HA_ORC_CHAMPION` (gates leadership). SAW_GOD's NOFEAR/NOPAIN
  flavor retained.
- `OUTSIDER_CONTROLLABLE` added (adventure outsiders).

## Entity (vanilla-human fork)
- **Sites**: CITY family — camp-scale via `MAX_SITE_POP_NUMBER:80`; no
  `BUILDS_OUTDOOR_FORTIFICATIONS` (no castles); founds towns/hamlets only, and
  `TOLERATES_SITE:CAVE_DETAILED`+CITY → occupies conquered dwarf/human sites.
- **Hostile to all**: `ITEM_THIEF` (universal fundamental hostility, including toward
  the snatcher bloc) + `SIEGER` + `AMBUSHER` + `ABUSE_BODIES` + `BANDITRY:30` +
  `LOCAL_BANDITRY`; progress triggers 1/1/1 with sieges at 2 — the early-game threat.
- **No trade**: all `ACTIVE_SEASON`s removed.
- **Metals**: 14 alloy/steel reactions stripped — pure smelted metals only, iron king.
- **Never necromancers**: religion = war pantheon (WAR/STRENGTH/VICTORY/THRALLDOM/
  FORTRESSES), no DEATH sphere for their gods to grant secrets from.
- Ethics: killing/torture/trophies/slavery acceptable; fixed warlike values replace
  human variable values (martial prowess/power high, peace/mercy negative).
- **Primitive warband nobility** (replaces humans' generated positions): great warlord
  (monarch, champions only), horde master (general, champions only), war chiefs and
  raid bosses (officers), boss → big boss (site leaders), war boss + raid leaders
  (militia), **taskmaster** (manager+bookkeeper+broker in one), **enforcer**
  (law + executions by axe).

## Known gaps / verify
- Sieges: orcs keep the pick as a digger tool but no great picks and no
  `SIEGE_SKILLED_MINERS` → picks in sieges rare/weak, per spec.
- Worldgen survival while hostile to everyone — watch civ counts in legends.

## v0.22
- Banditry 10 -> 50 (+LOCAL). Also removed a duplicate `[BANDITRY:10]` lower in the entity that was silently overriding the intended value (last-wins), so orcs were effectively at 10 before.
