# Dwarf Fortress: High Adventure

This directory is the workspace for a family of new content mods for Dwarf Fortress 50.x,
grouped under the name **"Dwarf Fortress: High Adventure"**. The mods add several new playable
civilizations. All of them should work well **together or individually**.

The subdirectories here are reference mods downloaded from the Steam Workshop (via steamcmd,
app 975370) — study material and fork sources — plus **`high-adventure/`, our suite's source
code** (one folder per mod, installed copies live in the game's `mods/` directory). Final
art assets sit at this directory's top level (drider and elder-brain PNGs, tile-ready).

## Ground rules

* **Do not modify vanilla items/tools or vanilla behaviors — this is the highest-priority
  rule, ranked above "don't add new items", and we'd rather avoid both.**
  * No patching of vanilla weapon/armor definitions (no `MINIMUM_SIZE` edits, no
    `SELECT_ITEM`, no `CUT_ITEM`).
  * No new weapon/armor items specifically for a new race.
  * Acceptable degraded outcomes instead: if small kobolds can only wield vanilla daggers,
    that's fine. They need picks and axes for digging/tree-cutting — if only *large* kobolds
    (a larger caste meeting vanilla `MINIMUM_SIZE`) can do those activities, that's fine too.
* **Every mod in the suite is a standalone fork.** Where we build on a reference mod
  (kobolds, mind flayers, succubi), we copy it, rename every ID with our prefix, make
  **minimal documented changes** (each fork keeps a `CHANGES.md` diff log), and ship it
  self-contained. No `REQUIRES_ID_BEFORE_ME` dependencies on third-party mods; originals and
  forks can coexist in one world without ID collisions.
* New *non-equipment* content that a planned feature explicitly requires is allowed: custom
  workshops, reactions, phantom plants, a healing drink, castes, positions, interactions,
  graphics, DFHack scripts.
* Prefer `SELECT_*` (append) edits over `CUT_*` (replace) on the few vanilla objects we must
  touch (playable-civs mod only).
* Every new object ID gets the `HA_` prefix.
* Where raws physically cannot express a required behavior, a small companion **DFHack
  script** is the preferred tool (this repo is a DFHack scripts codebase).

## Reference mods (downloaded)

| Folder | Mod (Steam ID) | Author | Role |
|---|---|---|---|
| `all-races-playable/` | All Races Playable (2898713241) | Arkbrik | Original playable-vanilla-civs mod; CUT+redefine idiom. |
| `all-races-playable-redo/` | All Races Playable Redo (3738520568) | Lord Nich | Newer, mostly `SELECT_ENTITY`-based. **Baseline for normal-elf behavior** (no mining/chopping/farming; `GROW_WOOD_ARP` seed→phantom-"grown wood" reactions) and model for the Shaping Tree. |
| `vanilla-drow-expanded/` | Vanilla Drow Expanded Playable (2923379473) | LeDouke | Caste-gated matriarchy pattern (`ALLOWED_CLASS`/`REJECTED_CLASS`). |
| `dark-elves-redux/` | Dark Elves Redux (3243046197) | Endali | Clean additive civ structure; consumables-without-equipment precedent. |
| `fantastic-fantasy-fortress/` | Fantastic Fantasy Fortress (2905522743) | chipathingy | `SIEGE_SKILLED_MINERS`, rage castes, healing-adjacent syndromes. Not copying its fixed pseudo-divine metals. |
| `succubus-dungeon/` | Succubus Dungeon (2950544248) | Boltie | **Fork source** for our succubus mod (see fork spec below). Also the model for reaction+DFHack invader conversion (`corruption.lua`). |
| `topples-orcs/` | Topples' Orcs (2946888253) | Topples | Caste-champion pattern (rare `SKULL_CRUNCHER`, NOFEAR/NOPAIN brute). |
| `nauts-procedural-dragons/` | Naut's Procedural Dragons (3424029801) | Nautilus | Dragon bodies, `BIG_FIRE_SACK` + `CDI:FLOW:DRAGONFIRE`, giant size curves, no-MAXAGE immortality. Warning: cuts vanilla DRAGON/HYDRA. |
| `cute-kobold-caverns/` | Cute Kobold Caverns (3477662286) | Ottfried & GadgetPatch (DeltaFire) | **Fork source** for our kobold civs (`CUTEKOBOLD`, `KOBOLD_CAVES`). |
| `kobold-caverns-skulking-filth/` | Kobold Caverns – Skulking Filth (2925069486) | GadgetPatch | The `ITEM_THIEF` hard-mode flag our kobold forks bake in. |
| `illithids/` | Illithids (3027569318) | Myphicbowser | **Fork source** for our mind flayers (ULITHARID caste, mind blast/psychic shield, Penumbra metal, language, dormant `ELDERBRAIN` stub). |

## Planned mods

### 1. Existing Civilizations Playable
Make the existing civilizations playable, very similar to **All Races Playable** (behavior
baseline: **ARP Redo**), and allow them all to be **outsiders in adventure mode**
(`OUTSIDER_CONTROLLABLE` on creatures; `SITE_CONTROLLABLE` + `ALL_MAIN_POPS_CONTROLLABLE` on
entities — Redo omits the outsider part, so we add it). This mod also carries our few
vanilla-entity additions (goblin caravan `ACTIVE_SEASON`, goblin bronze+iron permits).

### 2. High Elves
* Wooden gear like their forest cousins (ARP-Redo-style grow-wood economy), but **champions**
  use divine metal arms and armor: **glowing, bright, pale, shining, translucent, frosty,
  singing, multicolored, clear blue, twinkling, crashing, and blazing metal**.
* **Use only the vanilla divine metals** — the procedurally generated `[DIVINE]` inorganics,
  never hand-authored clones. Each world generates 10 of 26; use whichever of the 12
  adjectives above exist in the world; **if all 12 are absent (very rare, ≈0.02%), use any
  divine metal.**
* Implementation: raws cannot reference generated materials, so a companion **DFHack script**
  runs at world load, finds the generated divine inorganics, filters by adjective, and adds
  them to the high-elf civs' entity resources so soldiers, sieges, and caravans use them.
  * *Why worldgen-era gear won't be divine:* the civ's metal resource list is consulted
    whenever history generates equipment, and worldgen runs **before** any DFHack script can
    touch the loaded world — there is no raws hook to grant a civ a generated material, and
    DFHack only gets the world after worldgen finishes. So items minted during history lack
    divine metal; everything equipped after first load (sieges, caravans, new armies) has it.
* Fortress mode: divine metal is never free — you **trade** for it. Caravans bring: divine
  metal bars, divine clothing, grown wooden items, gold and platinum items, and coke.
* **Rare trade good: healing potions** ("mysterious liquor" etc.) — a drink whose ingested
  syndrome uses `CE_STOP_BLEEDING`, `CE_CLOSE_OPEN_WOUNDS`, `CE_HEAL_TISSUES`,
  `CE_HEAL_NERVES`, `CE_REGROW_PARTS`.
* Only trade with other (good) elves — see Trade restrictions.
* Metalworking: **any metal, up to and including adamantine**.
* Get the **Shaping Tree** workshop (see Workshops).
* Live in **castles**: `DEFAULT_SITE_TYPE:CITY` + `BUILDS_OUTDOOR_FORTIFICATIONS` (the
  token that "builds castles from mead halls" on hamlet/town sites). `FORTRESS` is no
  longer a valid site type in current DF.

### 3. Elder Dragons (intelligent dragons)
* **One-creature civilizations**, alongside existing dragons (new creature ID, `HA_` prefix).
* Live in **castles** (`CITY` + `BUILDS_OUTDOOR_FORTIFICATIONS`, same mechanism as high
  elves) — when they don't steal their lairs from other locations in battle.
* Twice a giant elephant at maturity, **age 1000** (≈ **50,000,000 cm³**).
* Skin-material castes: **Copper, Tin, Gold, Silver, Iron, Platinum, Steel Dragon**.
* **Dragonfire** (`BIG_FIRE_SACK` + `CDI:FLOW:DRAGONFIRE`) and **flight** (`FLIER`).
  * Engine caveat that matters here: **fliers path as walkers** — a route must be walkable
    for the AI to take it; flight is used opportunistically once moving and in combat.
    Pure-flight siege approaches can stall against walled forts. Elder dragons compensate
    exactly as designed: `BUILDINGDESTROYER:2` lets them make their own ground path.
* Very **greedy** (`PERSONALITY:GREED` high, `HABIT:COLLECT_WEALTH`), **likely evil**.
* **Cannot equip armor.** No `MAXAGE` → near-never necromancers. Solitary dragons do **not
  trade** (no `ACTIVE_SEASON`).

### 4. Kobolds (with draconic overlords)
Standalone forks of Cute Kobold Caverns (+ Skulking Filth's `ITEM_THIEF` baked in), IDs
renamed `HA_*`, diffs documented. **Three entities/creatures produce the civilization mix**
— worldgen instantiates several civs of each entity, so the world naturally contains all
three kinds side by side:
* **`HA_KOBOLD_CIV`** — kobold-only: fork of `KOBOLD_CAVES`/`CUTEKOBOLD` with no dragon
  content at all (separate creature fork, so a dragon can never appear in these civs).
* **`HA_KOBOLD_DRACONIC`** — draconic overlords: a second creature fork whose caste list is
  kobold castes **plus a very rare Elder Dragon caste**; rulership positions are
  `ALLOWED_CLASS`-gated to the dragon caste (the Vanilla Drow matriarchy technique). The
  dragon **migrates in like the monarch** and **can fight in the military** (it's a normal
  unit; it just can't wear armor).
  * **If the civ has no living dragon for the throne**: the position sits vacant — and yes,
    we can mint one. Unit *spawning* is broken on this build, but *transformation* is proven
    tech: a DFHack "ascension" hook (or ritual reaction) applies a `CE_BODY_TRANSFORMATION`
    syndrome converting a kobold into the Elder Dragon caste. New dragon, no spawning.
* **`HA_ELDER_DRAGON`** — solitary dragons with no kobolds (mod 3's entity).
* Kobold equipment: entirely the forked CKC content (their items, carried through the fork
  as-is). Our layer adds no items and no vanilla item patches.

### 5. Dark Dwarves
* **Carnivorous cannibal dwarves**, evil: `CARNIVORE`, ethics allowing `EAT_SAPIENT_*`.
* Ally only with **drow and goblins**, rarely; **trade with goblins** (evil bloc).
* **Never tantrum or have bad thoughts** (zeroed `STRESS_VULNERABILITY`/`ANGER_PROPENSITY`,
  high loyalty values).
* Otherwise vanilla dwarves. **Any metal.** Sieges **often** bring picks.
* Sites: `CAVE_DETAILED` like vanilla dwarves — fortresses on mountain edges, **mountain
  halls** in the interior (whose inhabitants the wiki literally calls "deep dwarves" —
  the flavor fit is exact). **Hillocks: tried to exclude them and reverted (v0.2–v0.4
  finding)** — worldgen welds dwarven-family expansion to surface `SETTLEMENT_BIOME`
  settlements; with mountain-only settlement the civs founded zero sites all history and
  were exterminated in wars, and subterranean `SETTLEMENT_BIOME`s are inert. Dark dwarves
  keep vanilla-style surface settlement (hillocks included) as the cost of a living,
  expanding civilization.
* **Commonly become necromancers.**

### 6. Drow (+ Driders)
* **Evil elves in fortresses** — dwarven-style underground fortress complexes:
  `DEFAULT_SITE_TYPE:CAVE_DETAILED`, whose procedural output IS the fortress (Ω) /
  mountain-halls / hillocks site family (the raw token value `FORTRESS` is invalid, but
  the fortress *sites* come from CAVE_DETAILED — vanilla dwarves work this way). Both
  reference drow mods use this. **Hillocks caveat** (from the dark-dwarf experiments):
  suppressing surface settlement also suppresses all worldgen expansion — for drow,
  decide between vanilla-style expansion (with hillocks) or deliberately insular
  single-fortress civs (both reference drow mods live with the latter). Trade with
  **goblins and dark dwarves** (evil bloc).
* Adventure mode: **immediately hostile, always, to non-drow** (`BABYSNATCHER`-class
  fundamental hostility).
* **Driders**: rare caste (**~4%** `POP_RATIO`), **playable in adventure mode** (civ-member
  play via `ALL_MAIN_POPS_CONTROLLABLE`; verify the adv-mode caste picker exposes them —
  see Open problems): humanoid top on spider lower half, web spray, `WEBIMMUNE`,
  ~200,000 cm³ adult. Art from the right-hand half of
  [this image](https://images-wixmp-ed30a86b8c4ca887773594c2.wixmp.com/f/ce5f21be-645b-418a-839a-1a8919053faf/d8gnaq1-93de25ba-0162-4f9a-bf91-41e83d7be16d.png/v1/fill/w_784,h_744,q_80,strp/draw_this_again___drider_by_lakan_inocencio_d8gnaq1-fullview.jpg?token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1cm46YXBwOjdlMGQxODg5ODIyNjQzNzNhNWYwZDQxNWVhMGQyNmUwIiwiaXNzIjoidXJuOmFwcDo3ZTBkMTg4OTgyMjY0MzczYTVmMGQ0MTVlYTBkMjZlMCIsIm9iaiI6W1t7ImhlaWdodCI6Ijw9NzQ0IiwicGF0aCI6Ii9mL2NlNWYyMWJlLTY0NWItNDE4YS04MzlhLTFhODkxOTA1M2ZhZi9kOGduYXExLTkzZGUyNWJhLTAxNjItNGY5YS1iZjkxLTQxZTgzZDdiZTE2ZC5wbmciLCJ3aWR0aCI6Ijw9Nzg0In1dXSwiYXVkIjpbInVybjpzZXJ2aWNlOmltYWdlLm9wZXJhdGlvbnMiXX0.T5w_y4fUoCA5GBO5hdFg2auDRMsGaz8NFD4M3aniaPI).
* **Scimitars and bows only**; always **steel**; **no shields**; **no Shaping Tree**.
* **Giant spiders always domesticated** (`ANIMAL` block, vanilla `SPIDER_CAVE_GIANT`,
  `ANIMAL_ALWAYS_PRESENT`).
* Sieges bring **enslaved goblins with picks**.
* Necromancers ~like elves (almost never). **Rare good individuals** — much rarer than
  goblins: `VARIABLE_VALUE` ranges skewed heavily evil with a thin good tail; defection
  frequency is emergent worldgen behavior.

### 7. Orcs
* **Sites — human-style buildings, never dwarven**: `CAMP` isn't a valid civ site type,
  so orcs live in the humblest human-family settlements: `DEFAULT_SITE_TYPE:CITY` with
  broad surface `SETTLEMENT_BIOME`s → a town capital plus **hamlet** satellites, with a
  low `MAX_SITE_POP_NUMBER` keeping everything camp-scale, and no
  `BUILDS_OUTDOOR_FORTIFICATIONS` (no castles). Orcs **never found dwarven site types**
  — but they **conquer them frequently**: `TOLERATES_SITE:CAVE_DETAILED` (+`CITY`) so
  captured dwarf hillocks/fortresses and human hamlets/towns become occupied orc sites,
  and aggressive worldgen war tokens make that common. Adventure mode: **immediately
  hostile to non-orcs**.
* **Bigger than humans** (adult > 70,000 cm³). Hostile to all civilizations (incl. evil bloc).
* **Iron only — non-alloys**: no bronze, no steel; iron common.
* **~20% champion caste**: larger, `NOPAIN`, frequently tantrums (`PRONE_TO_RAGE`, high
  `ANGER_PROPENSITY`).
* Sieges only **rarely** bring picks. **Never** necromancers.
* Get the **Breeding Pit** workshop (see Workshops).

### 8. Mind Flayers
Standalone fork of the Illithids mod (`HA_` IDs, `CHANGES.md` diff log). Changes from the
original:
* **Elder brain** — a new caste (replacing the dormant `ELDERBRAIN` stub):
  * **Immigrates like the monarch** (MONARCH-style position `ALLOWED_CLASS`-locked to the
    caste), and is **playable in adventure mode** like any other caste.
  * **Moves very, very slowly** — not immobile. Implemented with a custom crawl `GAIT` at an
    enormous tick cost, so it *can* relocate (and an adventurer elder brain can creep around)
    but in practice stays put. It keeps grasp tentacles so it can perform its one job.
  * **Its only labor is "Resonate"** at the **Brain Pool** workshop (see Workshops): while
    the elder brain is resonating there, **all illithids get maxed happiness**.
  * Stretch: **promotion** — a DFHack hook watches the position assignment and transforms
    the appointee into the elder-brain caste via `CE_BODY_TRANSFORMATION`.
  * **Killing the elder brain kills all other mind flayers** — DFHack on-death hook applies
    a lethal syndrome to every unit of the race (no raws on-death broadcast exists).
* **Illithids (and the elder brain) fly** (`FLIER`) and remain fortress-playable. Assessment:
  safe — fliers path as walkers, so jobs/hauling never depend on air routes and nothing
  breaks; flight shows up in combat, fleeing, and falls (no fall deaths, immune to pit
  drops). It won't let civilians take air-only shortcuts (engine limitation), so the fun is
  real but bounded. Same engine rule applies to elder dragons (see mod 3). Adventure-mode
  manual flight probably isn't available to player characters — verify (Open problems).
* **Immediately hostile to all non-mind-flayers**; **no trade** (no `ACTIVE_SEASON`).
* **Dark pits** (`DEFAULT_SITE_TYPE:DARK_FORTRESS`).
* **No bad thoughts, no pain** (`NOPAIN`, zeroed stress/anger facets).
* **Cannot equip armor** (fork removes armor-level gear from the entity; clothing stays).
  Adventurer players can still physically don armor — see Open problems.
* **Any metal.** **Never** necromancers.
* Get the **Ceremorphosis Chamber** workshop.

### 9. Succubi (fork)
Standalone fork of Succubus Dungeon (`HA_` IDs) with minimal documented changes:
* **Remove** the blade-whip and pitchfork weapons → permit vanilla **pikes, halberds,
  scourges, and whips** instead.
* **Remove** all custom clothing (bustier, corset, short pants, stockings, bodysuit).
* **Remove** the doll toy.
* **Tools**: both the tablet and slip are just writing media (`TOOL_USE:CONTAIN_WRITING`) —
  not load-bearing. **Remove both**, permit vanilla quires/scrolls, and drop (or repoint to
  vanilla quires) the four slip reactions (`SUCCUBUS_BONE/METAL/STONE/WOOD_SLIP`).
* **One caravan season: Summer** (trivial in a fork — just edit the `ACTIVE_SEASON` lines;
  the old SELECT-can't-remove problem disappears).
* Everything else (corruption system, summons, secrets, magmawell, language) carries over.

## Workshops (custom 5x5 buildings)

* **Shaping Tree** (elves and high elves; NOT drow): grow wooden items from seeds.
  ARP Redo's model: seed → logs of a phantom plant literally named **"grown wood"** →
  finished wooden gear. *Why the real `grown` flag needs DFHack:* "grown" is an **item
  flag**, and reaction raws have no token that sets item flags on products — products only
  carry material/quality/dimension. So the raws version reads right but isn't flag-grown;
  a tiny DFHack reaction hook sets `item.flags.grown` on products so elf caravans accept
  them as genuine.
* **Brain Pool** (mind flayers): hosts the **Resonate** job. Raws provide the building +
  reaction; DFHack enforces that only the elder-brain caste takes the job and, while
  resonation is active, maxes happiness for all illithid citizens (stress floor + euphoric
  thoughts; optionally a `CE_FEEL_EMOTION` gas as raws-side flavor).
* **Ceremorphosis Chamber** (mind flayers): caged sapient invaders → adult mind flayers,
  very quickly. Model: Succubus `SUCCUBUS_CORRUPT_INVADERS` + `corruption.lua` (reaction
  targets a caged prisoner; script applies the transformation syndrome and handles
  citizenship).
* **Breeding Pit** (orcs): very slowly converts meat into adult orcs. **Mechanism
  validated live** (see test results below). Design: the pit's reaction consumes meat and
  produces a boiling-gas syndrome granting the worker a short-lived
  `CE_CAN_DO_INTERACTION` summon ability (usage-hint-triggered, so it fires organically —
  no forced casting); the summoned orc arrives adult; a tiny DFHack watcher adopts any
  new no-civ/no-histfig orc via `dfhack.units.makeown()` → full citizen with a minted
  historical figure. Pacing comes from reagent cost + reaction rarity.

### SUMMON_UNIT test plan (breeding pit prerequisite)
Facts established from the raws:
* Syntax: `[I_EFFECT:SUMMON_UNIT]` + `[IE_TARGET:<location>]`, `[IE_IMMEDIATE]`,
  `[CREATURE:X:CASTE]`, optional `[IE_TIME_RANGE:min:max]` (expiry) and
  `[IE_MAKE_PET_IF_POSSIBLE]`.
* **Vanilla shrine blessings summon with NO time range** — permanent summoned pets have
  vanilla precedent. (Succubus soul summons expire only because they opt into
  `IE_TIME_RANGE`; necromancer-secret summons also expire.)
* **The vanilla blessing generator explicitly forbids `CAN_LEARN` creatures** as summon
  targets — sapient-summon citizenship is exactly the open question.
* `makeown` working is a good sign — the historical defect of summons is
  ownership/citizenship, which `makeown` repairs.

**TEST RESULTS (2026-07-20, live fort): the pipeline works.**
* Summoned **dogs** (6): no histfig, but `tame=true` and **assigned to the fort civ** —
  `IE_MAKE_PET_IF_POSSIBLE` yields real pets with no despawn timer.
* Summoned **dwarf** (sapient probe): spawned adult, but `citizen=false, civ=-1, hf=-1` —
  the predicted citizenship gap.
* **`dfhack.units.makeown(unit)` (direct API) fixed it completely**: `isCitizen=true`,
  civ set, and a historical figure minted for the unit.
* Remaining checks: persistence across save/reload (expected fine — no `IE_TIME_RANGE`,
  vanilla blessing precedent), and that the adopted citizen takes labors normally.

## Graphics

* Vanilla mechanism for big creatures: sprites live on ordinary **32×32 tile pages**, and a
  creature claims a rectangle of tiles with `LARGE_IMAGE:x1:y1:x2:y2` — the vanilla dragon
  is **96×64** (3×2 tiles). Sizes must be multiples of 32 in each dimension. (Vault angels
  are procedural and have no bespoke vanilla art to compare against.)
* **Elder brain art at 96×120: yes, workable** — pad the canvas to **96×128** (3×4 tiles,
  transparent padding) and declare `LARGE_IMAGE` over 3×4. No upscale needed.
* Drider art: crop/adapt the referenced image's right half to a `LARGE_IMAGE` block
  (probably 64×64, 2×2 tiles, given adult size).

## Trade restrictions

No raw token exists for "trades only with X" — partnerships emerge from war/peace, steered
with `BABYSNATCHER`/`ITEM_THIEF` blocs, ethics, and seasons:

| Civ | Trades with | Caravan season | Mechanism |
|---|---|---|---|
| High elves | other (good) elves only | Spring | non-snatcher; ethics friction + DFHack caravan filter if needed (see caveat) |
| Elves (vanilla) | as vanilla | as vanilla | untouched |
| Kobolds | each other only | (own-civ caravans) | `ITEM_THIEF` baked into forks |
| Goblins | evil bloc | **Autumn** | already `BABYSNATCHER`; season added in playable-civs mod |
| Dark dwarves | evil bloc | **Winter** | `BABYSNATCHER` + one season |
| Drow | evil bloc | **Spring** | `BABYSNATCHER` + one season |
| Succubi (fork) | evil bloc | **Summer** | `BABYSNATCHER` ✓; season fixed in fork |
| Orcs | nobody | none | hostile to everyone incl. evil bloc |
| Mind flayers | nobody | none | fork omits `ACTIVE_SEASON` |
| Elder dragons (solitary) | nobody | none | no `ACTIVE_SEASON` |
| Dragon-ruled kobolds | as kobolds | (own-civ) | inherits kobold behavior — acceptable |

**High-elf caveat:** raws can't stop a friendly civ from trading with non-elf neighbors
without making high elves hostile (wrong for a good civ). Plan: ethics/values friction +
very high `PROGRESS_TRIGGER_TRADE`; if insufficient, a DFHack rule suppresses high-elf
caravans to non-elf player civs.

## Material restrictions (fort-mode tech tree)

| Civ | Metals workable |
|---|---|
| High elves | any, up to and including adamantine |
| Elves | none — exactly ARP Redo (gather + grown wood) |
| Drow | any (steel gear in practice) |
| Dark dwarves | any |
| Goblins | bronze and iron only — no steel/adamantine (playable-fort entity; worldgen goblins untouched) |
| Humans | unchanged from vanilla |
| Kobolds | as CKC fork (GIVE_CIV reactions, no smelting) |
| Succubi | as Succubus fork |
| Mind flayers | any — but **cannot equip armor** |
| Elder dragons | n/a — **cannot equip armor**, no crafting economy |
| Orcs | **non-alloys only** — no bronze, no steel; iron common |

## Cross-cutting rules

### Guaranteed on-sight hostility (adventure mode)
Raws cannot guarantee that *every member* of a civ attacks outsiders on sight — vanilla
goblins prove it (snatcher war + evil ethics still leaves many indifferent civilians).
The raws-only "stronger" option, creature-level `[CRAZED]` (species-scoped berserk), is
disqualified: snatcher civs are multiracial (snatched children, conquests), so members
would slaughter their own; evil-bloc caravans visiting drow/dark-dwarf forts would be
attacked; worldgen self-destruction risk. Therefore:
* Raws provide the *war footing* (BABYSNATCHER/ITEM_THIEF, evil ethics, BANDITRY —
  vanilla reference: goblins 50+LOCAL, humans 10, kobolds 10+LOCAL; dark dwarves ship
  20+LOCAL).
* The *guarantee* is a suite DFHack script (**`ha-always-hostile`**): in adventure mode,
  units of the designated races — **dark dwarves, drow, mind flayers, kobolds, orcs** —
  are forced hostile to any adventurer not of their race/bloc, civilians included.
  Race-scoped, so "drow attack non-drow" is exact; fort mode and worldgen untouched.

### Wall destruction & picks
Confirmed native in current DF (v53 siege update): sieges bring **miner invaders**; vanilla
adds the two-handed **great pick** (`ITEM_WEAPON_PICK_GREAT`) for them, vanilla dwarves
carry `SIEGE_SKILLED_MINERS` (miner invaders ×5 skill), and ARP Redo already hands goblins
`DIGGER:ITEM_WEAPON_PICK_GREAT` "with siege". So wall-breaching is a supported system —
we just distribute it:
* **Dark dwarves** — DIGGER pick + great pick + `SIEGE_SKILLED_MINERS` → *often* sap.
* **Orcs** — DIGGER pick only, no `SIEGE_SKILLED_MINERS` → *rarely*/weakly sap.
* **Elder dragons** — all, innate (`BUILDINGDESTROYER:2`), no picks.
* **Drow sieges** — **enslaved goblins with picks** (slave-goblin caste + great-pick
  DIGGER; verify caste appears among siege miners).
* **Mind flayers and high elves do not dig** (no DIGGER entries at all).

### Necromancy
* **Orcs, mind flayers, kobolds** — never. **Dark dwarves** — commonly.
* **Elder dragons, drow** — like elves, almost never (ageless / elf-like MAXAGE).

### Siege pressure management
With many always-hostile civs, sieges could become constant. Levers (as used by
Masterwork-style packs — civ toggles + trigger tuning):
1. Staggered `PROGRESS_TRIGGER_*_SIEGE`: orcs early (1–2), evil bloc mid (2–3),
   drow/mind flayers late (3–5).
2. Modest `MAX_POP_NUMBER`/`MAX_SITE_POP_NUMBER` on hostiles bounds siege size and spread.
3. Low `BANDITRY` on civs that already siege.
4. v50 custom difficulty settings documented as the player-side dial.
5. Each civ its own mod = the pack's toggle is worldgen mod selection.

## Compatibility rules

1. **Never edit vanilla raw files**; complete `info.txt` in every mod.
2. **`SELECT_*` over `CUT_*`** on vanilla objects (playable-civs mod only). SELECT can't
   remove tokens — that's why every derived mod is a fork, never a patch.
3. **`HA_` prefixed IDs everywhere**; reuse shared assets (`TRANSLATION:ELF`) rather than
   duplicating.
4. Forks coexist with their originals (different IDs); document diffs in each fork's
   `CHANGES.md`.
5. **Playability trio**: entity `SITE_CONTROLLABLE` + `ALL_MAIN_POPS_CONTROLLABLE`,
   creature `OUTSIDER_CONTROLLABLE`.
6. Bump `NUMERIC_VERSION` to force new installed copies; always check `errorlog.txt`.
7. Known external conflict: Naut's Procedural Dragons cuts vanilla DRAGON/HYDRA; our
   creatures use `HA_` IDs so the suite works with or without it.

## Open problems / research list

1. ~~"Castle" site type~~ **RESOLVED**: valid site types are DARK_FORTRESS, CAVE,
   CAVE_DETAILED, TREE_CITY, CITY, PLAYER_FORTRESS (`FORTRESS` invalid, `MONUMENT` crashy,
   `CAMP` invalid). Castles = `CITY` + `BUILDS_OUTDOOR_FORTIFICATIONS`.
2. ~~Orc camps~~ **RESOLVED (negatively)**: no `CAMP` civ site type exists; orcs fall back
   to DARK_FORTRESS with camp flavor.
3. ~~Breeding pit spawning~~ **RESOLVED**: SUMMON_UNIT + `dfhack.units.makeown()` tested
   live — permanent pets and adoptable sapient citizens both confirmed. Only save/reload
   persistence and labor behavior remain to spot-check.
4. **Elder-brain / dragon monarch arrival**: verify worldgen produces an eligible caste
   histfig for `ALLOWED_CLASS` positions (POP_RATIO tuning); the DFHack
   transformation-minting path is the fallback for both.
5. **Drow siege sappers**: siege miners + great picks are native (see Wall destruction);
   remaining question is only whether a specific *caste* (slave goblins) can be steered
   into the miner role, and how pick frequency is tuned.
6. **Adventure-mode caste picker**: confirm v50 character creation lets you pick a specific
   caste (drider, elder brain, champion orc) of a playable race.
7. **Adventure-mode flight**: confirm whether a FLIER player character can fly manually in
   current adv mode (historically not); flight still helps passively (no fall damage).
8. **Mind-flayer armor in adventure mode**: entity-level armor removal doesn't stop a player
   adventurer from wearing found armor; decide if acceptable.
9. **Fort-mode flier QoL**: verify current-version behavior of flying citizens (job pathing
   walks, combat flies) matches expectations on DF 50.x/51.x before shipping flying civs.
