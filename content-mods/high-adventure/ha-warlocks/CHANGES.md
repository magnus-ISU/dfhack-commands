# ha-warlocks — changes

Design source: Meph's ☼Warlocks☼ (bay12 thread 175304). The 1.0 release no longer exists
anywhere; this is a fresh implementation from the forum description, the surviving
Masterwork-era raws and the thread's cheat sheet — see `content-mods/warlocks/README.md`
(gitignored) and the repo-root `warlocks-design-notes.md` / `warlocks-implementation-spec.md`.
No code is copied from it. The map sprites ARE its art, cut from the cheat sheet posted in
the thread — see 0.2 below and LICENSE.md section 3.

## 0.5 — placement, done the way the suite already does it

Supersedes 0.4, which reached the right outcome by the wrong mechanism.

- **Towers rise where humans start.** `[EXCLUSIVE_START_BIOME:ANY_GRASSLAND]`, with the other
  two human biomes present only as `BIOME_SUPPORT` (grassland 3, savanna 2, shrubland 2 — the
  vanilla PLAINS weights).
- **They never expand**, by the same means as `ha-forest-golems` and `ha-high-elves`:
  `EXCLUSIVE_START_BIOME` with **no `SETTLEMENT_BIOME` and no `START_BIOME`**. Those two tokens
  are what grant a civ the right to build, so withholding them founds one settlement and no
  more. `BIOME_SUPPORT` is not the limiter — its numbers are relative to each other only — but
  it cannot be dropped either, since worldgen rejects a world where a civ has none at all.
- Population caps are back to ordinary values (`MAX_POP_NUMBER:10000`,
  `MAX_SITE_POP_NUMBER:120`). 0.4 had squeezed them to 80/80 to make expansion arithmetically
  impossible; that is no longer load-bearing, and a cap that tight risked the civ dying out
  during history.

Untested: whether several `EXCLUSIVE_START_BIOME` entries are legal. Every use in vanilla and in
this suite is a single biome, which is why savanna and shrubland are support-only rather than
start biomes.

## 0.3 — adventure mode, and constructs made of bone

- **`[OUTSIDER_CONTROLLABLE]`** on `HA_WARLOCK`, creature-level as on every other playable High
  Adventure race. The entity already carried `SITE_CONTROLLABLE` and
  `ALL_MAIN_POPS_CONTROLLABLE`, so warlock adventurers now roll. The construct castes come along
  with it — a skeleton adventurer is a feature, not an accident.
- **Skeletons and bone golems are now bone all the way through.** The shared tissue plan moved
  out of `SELECT_CASTE:ALL`: the living castes take
  `VERTEBRATE_TISSUE_LAYERS:SKIN:FAT:MUSCLE:BONE:CARTILAGE`, the constructs take
  `:BONE:BONE:BONE:BONE:CARTILAGE`. Feeding the plan BONE in the skin, fat and muscle slots makes
  every layer the same bone, so a blow that would open a warlock's gut just scrapes. The
  constructs also no longer declare blood, pus, sweat, tears, hair, nails or wound infection —
  none of it is theirs. Body parts stay identical across castes, which is the half of
  caste-difference that is safe.

### Fixes found while doing it
- **Gaits were missing entirely** on `HA_WARLOCK` and `HA_GARGOYLE`. Every other creature in the
  suite declares four; a creature with none moves unpredictably rather than not at all. Living
  castes get ordinary humanoid gaits, constructs get slower ones (25 kph — they trudge), and the
  gargoyle gets a profile despite being `[IMMOBILE]`.
- Dropped `[SPEED:...]` — deprecated in v50, where gaits replaced it. The constructs' sluggishness
  is now expressed the way the engine expects.
- Dropped `[CASTE_TILE:...]` (appears nowhere in vanilla; `CASTE_COLOR`, which does, is kept) and
  `[ANIMAL_NEVER_WILD]` (not a real entity token — vanilla's set is `ANIMAL_ALWAYS_PET`,
  `ANIMAL_ALWAYS_SIEGE`, `ANIMAL_CLASS`, `ANIMAL_FORBIDDEN_CLASS`, `ANIMAL_NEVER_MOUNT`,
  `ANIMAL_NEVER_PACK_ANIMAL`, `ANIMAL_NEVER_WAGON_PULLER`).

## 0.2 — graphics

Map sprites for all fifteen castes, cut from the ☼Warlocks☼ cheat sheet posted in bay12 thread
175304 — one 8x2 tile page, `graphics/images/ha_warlock_creatures.png` (256x64).

- Native 32 px, untouched: warlock, witch, skeleton, the five prisoners and the three mephits.
  Those blocks of the sheet are 1:1 pixel art on a 32 px grid.
- Trimmed to their own bounds and centred rather than upscaled: bone golem and the three
  gargoyles. Those blocks are drawn smaller on the sheet, and enlarging 20 px art to 32 px only
  makes it soft.
- Every caste is drawn through a `LAYER_SET`, not a plain `DEFAULT`. DF greys out a creature
  whenever it flashes it or it is underwater, and layered graphics are exempt while simple ones
  flicker — the same fix the ancient golem and the drider already carry.
- No item layers: worn clothing, armour and weapons are only drawn where a graphic declares a
  layer for them, and these sprites have no anchor points.

Attribution is Meph, Vordak, Redshrike and Denzi. The CC-BY-SA question is recorded in
`LICENSE.md` §3 and is **still unresolved** — Denzi's work is share-alike and we cannot tell
which sprite is whose.

## 0.1 — first cut

Everything below is new.

### Content
- **`HA_WARLOCK`** civ creature, four castes on one body plan: witch and warlock (ageless, no
  MAXAGE, fertile), **skeleton** (weak citizen, tireless, no food or sleep) and **bone golem**
  (triple mass, huge strength, still a labourer). Neither construct has a gender or `CHILD`, so
  neither breeds, and both sit at `POP_RATIO:0` so worldgen never rolls one.
- **`HA_PRISONER`** livestock, five castes (goblin, kobold, dwarf, human, elf). Deliberately not
  sapient — fortress mode will not butcher a sapient corpse — and deliberately not a grazer,
  since only grazers eat, which makes them zero-upkeep.
- **`HA_MEPHIT`**, three castes: air (sleeping gas), acid (blistering spray), ice (freezing
  shard), each 5 tiles on a 300-tick cooldown. The fourth sibling is the **vanilla fire imp**.
- **`HA_GARGOYLE`**, three castes: melee, fire (firejet) and ice (freezing shard). `[IMMOBILE]`,
  built on vanilla's elemental-man construct idiom, and leaves a granite statue when destroyed.
- **`[INORGANIC:HA_SOUL]`** — the only new material. Built from `STONE_TEMPLATE` but
  **without `IS_STONE`**, so no masonry job, construction, `BUILDMAT` or `ANY_STONE_MATERIAL`
  reagent can ever take one.
- **Ten buildings**: Gargoyle Forge, Obsidian Factory, Liaison's Office, Necromantic Shrine, and
  six elemental shrines (amethyst, fire, gabbro, iron, magma, mud).
- **35 reactions.** Every gem line ships twice — gemstone and cut clear glass — because glass is
  not `IS_GEM` and an `ANY_GEM_MATERIAL` reagent silently rejects it. Resurrection ships once per
  diamond (DF has eight and they share no reaction class).
- **Nobles**: Sorcerer Supreme (auto-filled) plus Death, Hunger, Pestilence and War, each with a
  one-warlock squad; Crypt Lords lead warlocks, a Death Knight leads everything else.

### Vanilla reuse, on purpose
Elementals are the **vanilla elemental men**; the fire familiar is the **vanilla fire imp**;
ravens, crows, giant bark scorpions and snakes are vanilla pets granted by the entity. No
vanilla creature, item or reaction is modified — there is no `creature_edits.txt` here at all.

### Script (`scripts_modactive/high-adventure/warlocks.lua`)
- **Souls** minted on a kill, and on butchering a prisoner or anything over 50000 body size.
  A lua hook instead of Meph's `EXTRA_BUTCHER_OBJECT`, which would have meant `SELECT_CREATURE`
  edits to every butcherable creature in the game.
- **Warlock-only work** for every workshop, by pinning `profile.permitted_workers`.
- **Shrine books**: a shrine under construction over a non-artifact book is deconstructed with a
  message. An original written work is an artifact; a scribe's copy is not.
- **Elemental caps**: 5 per shrine of that type and 5 × all standing shrines, counted off the
  living population so tearing a shrine down and rebuilding it gains nothing.
- **Gargoyles** teleport into their assigned pasture after a day, only while off screen.
- **No migrants** (Migrants timed events erased), **raid prisoners** (new mission reports land
  0–3 prisoners of the raided civ's race two days later), **caravan lures**, and **riots** —
  a dwarf, human or elf prisoner occasionally goes wild.
- Jobs are refused at **assignment** time, never at completion, so a refusal never costs souls.
  `removeWorker` always precedes `removeJob`.

## Known gaps
- **Buildings have no graphics** — only creatures do. The workshop art on the cheat sheet is
  isometric and would need per-stage building sprites.
- The art's licence is unresolved (Denzi is CC-BY-SA); see `LICENSE.md` §3.
- Unverified on a live world: `[SQUAD:n]` at n ≠ 10, luring a caravan from a hostile civ,
  migrant suppression, `CAN_USE_ARTIFACT` pulling an artifact book to a construction site, and
  where a non-`IS_STONE` boulder lands in the stockpile UI.
- The spawn pipeline leans on `modtools/create-unit`; created units are historically vulnerable
  to being destroyed by emigration, and this civ's whole population is created. Needs a long
  soak test.
