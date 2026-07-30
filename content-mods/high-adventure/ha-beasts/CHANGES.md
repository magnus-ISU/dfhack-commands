# HA - Beasts — change log

A wild-monster pack for the Dwarf Fortress: High Adventure suite. Adds hostile,
world-populating creatures (no civilization, no entity) that make travel — and
especially evil regions — dangerous. Standalone; no dependency on other suite mods
or on Highfantasy.

## Gibberling (`HA_GIBBERLING`)

**Origin.** Forked from Highfantasy 1.5.08's "feral goblin"
(`creature_highfantasy_evil_placeholder.txt`, creature `hordes_GOBLIN_FERAL`,
Kiiranaux et al), which is itself a berserk re-skin of the vanilla goblin body.
Re-themed into a blue swarm-beast and made self-contained against vanilla only.
Named for the gibberlings that killed the parents of Cacame Awemedinade.

**Creature changes vs. the feral-goblin source:**
- Renamed to `gibberling` / `gibberlings`; creature ID `HA_GIBBERLING`.
- New blue-themed description.
- ASCII tile recolored blue: `[CREATURE_TILE:'g'][COLOR:1:0:1]`; dropped the
  source's `GLOWTILE`/`GLOWCOLOR`.
- Skin colors changed from goblin greens to a full blue range
  (`LIGHT_BLUE`…`MIDNIGHT_BLUE`); hair set to blacks/dark indigos.
- Removed Highfantasy crossplay tags (`CREATURE_CLASS:GOBLIN`, `GREENSKIN`,
  `SPOUSE_CONVERSION_TARGET`, `SLAIN_SPEECH:slain_goblin`) so the creature is
  self-contained against vanilla; kept `MAMMAL` and `GENERAL_POISON`.
- **Group size set to 1–20** as requested: `[CLUSTER_NUMBER:1:20]`
  (source was `10:20`); `POPULATION_NUMBER:20:100`, `FREQUENCY:50`.
- Kept the guaranteed-hostility core: `[OPPOSED_TO_LIFE][CRAZED]`. `CRAZED` is
  race-scoped (attacks everything **except** its own species), which is exactly
  what we want for a wild swarm — no DFHack script needed for these, unlike
  civilized always-hostile races.
- Kept `[EVIL]` so gibberlings spawn **only in evil-aligned regions**. This is
  the direct fix for "evil locations are underwhelming": the region wildlife
  itself is now lethal. To make them roam the whole world instead, delete the
  `[EVIL]` line.
- Kept `[NO_EAT][NO_DRINK]` so worldgen never starves them; body, attacks
  (punch/kick/scratch/bite-latch), gaits, spit interaction, castes, and size
  curve carried over from the source unchanged.

**Graphics — "goblin art, but blue".** `graphics_ha_gibberling.txt` and
`graphics_ha_gibberling_portrait.txt` are the **vanilla goblin graphics files
copied verbatim**, with only:
1. the creature header rebound `CREATURE_GRAPHICS:GOBLIN` → `:HA_GIBBERLING`
   (and the line-1 filename token updated to match the new filename);
2. `LS_PALETTE_FILE` repointed at this mod's palettes;
3. the four skin-tone `TISSUE_MAY_HAVE_COLOR` condition lists swapped from greens
   to the matching blues (so both the rendered sprite **and** the unit's text
   description read blue and agree with each other).

The `LAYER` lines still reference the **vanilla** tile pages `GOBLIN_BODY` /
`GOBLIN_WEARABLES` / `PORTRAIT_GOBLIN_*` by ID — so we reuse the actual goblin
sprites with **zero art copied**. Only the small palette strips are shipped:
- `images/gibberling_body_palettes.png` — vanilla `goblin_body_palettes.png`
  with skin rows 0–3 hue-rotated to blue (brightness/shading preserved).
- `images/gibberling_portrait_body_palette.png` — same treatment on the portrait
  palette.
- `images/gibberling_clothes_palettes.png` — vanilla clothes palette copied
  unchanged (only matters if a gibberling ever equips clothing).

The lone stray `]` near line ~3773 is present in the vanilla source and is
inert (vanilla ships and loads it); left byte-identical on purpose.

## v0.2 — naked cannibal brawlers (BG1-style)

Retuned the gibberling toward its Baldur's Gate 1 inspiration and stripped the
remaining Highfantasy-isms.

- **Naked, no gear.** Removed `[EQUIPS]` — gibberlings cannot pick up, wield, or
  wear anything. They fight only with fists, feet, and teeth.
- **Random brawling skill** via six POP_RATIO-weighted castes (two sexes × three
  competence tiers), all named simply "gibberling":
  - `*_RUNT` (POP_RATIO 4): no natural skill — clumsy flailers.
  - base `MALE`/`FEMALE` (POP_RATIO 8): `WRESTLING 2`, `GRASP_STRIKE 1` (striking),
    `STANCE_STRIKE 1` (kicking), `BITE 1`.
  - `*_SAVAGE` (POP_RATIO 3): `WRESTLING 5`, `GRASP_STRIKE 4`, `STANCE_STRIKE 3`,
    `BITE 2`, plus `MELEE_COMBAT 2` and `DODGING 2`.
  - DF has no per-individual random-skill token; caste tiers are the only way to
    get a spread, so a given gibberling rolls one of these tiers. The graphics
    `CONDITION_CASTE:MALE`/`FEMALE` lines were widened to
    `MALE:MALE_RUNT:MALE_SAVAGE` / `FEMALE:FEMALE_RUNT:FEMALE_SAVAGE` so every
    tier still renders with the correct sex body.
- **Cannibals.** Removed `[NO_EAT]`/`[NO_DRINK]` (Highfantasy had made goblins
  need neither) so gibberlings actually get hungry, and added `[BONECARN]`
  alongside `[CARNIVORE]` — a hungry gibberling devours meat and bone from any
  corpse, its own dead kin included. Added `[LARGE_PREDATOR]` so they actively
  hunt (matching BG1's aggressive charge), reinforcing `[CRAZED]`.

### Strange Highfantasy properties found and removed

The feral-goblin source carried several Highfantasy-only tokens that are dead
weight (or wrong) in a standalone BG1-style beast:

- **`CREATURE_CLASS:GENERAL_POISON`** — *removed.* This is not poison immunity; it
  is Highfantasy's hook that makes a creature a valid **target** for its cave-plague
  interactions (`hordes_CAVE_BLIGHT` / `_LICE` / `_MITES` in
  `interaction_hordes_goblins.txt` — contagious fever/blister/necrosis diseases).
  Without that interaction file shipped, the class is a no-op tag. *If you ever
  want disease-ridden plague-gibberlings, porting those three interactions + this
  class is exactly how — a natural fit for filthy cannibals, but its own feature.*
- **Spit attack** (`CAN_DO_INTERACTION:MATERIAL_EMISSION` + the `SPIT` material) —
  *removed.* A Highfantasy ranged glob-spit; not a BG1 gibberling behavior and it
  contradicts "fists/feet/jaws only."
- **`MEMORY:5000` (max mental memory)** — *already dropped in v0.1.* Perfect recall
  on a feral beast was a Highfantasy oddity.
- **Purple/amethyst hair, `GREENSKIN`/`GOBLIN` crossplay classes,
  `SPOUSE_CONVERSION_TARGET`, `SLAIN_SPEECH`** — *already dropped in v0.1.*
- Kept as harmless flavor: red pupils (`PUPIL_EYE_RED`), sweat/tears secretions,
  and `GETS_WOUND_INFECTIONS`/`GETS_INFECTIONS_FROM_ROT` (fittingly grimy).

## v0.3 — named caste tiers

Replaced the runt/typical/vicious castes with three **named, sex-split** tiers
(caste IDs renamed `DISEASED_*` / base / `MUTATED_*`; graphics `CONDITION_CASTE`
lists repointed to match). `POP_RATIO` values are the exact percentages (they sum
to 100), and males are more skilled than females within each tier:

| Caste (name shown in game) | Sex | % | Skills |
|---|---|---|---|
| diseased gibberling | female | 23 | none |
| diseased gibberling | male | 23 | Wrestling/Striking/Kicking/Bite 1 |
| gibberling | female | 17 | all 2 |
| gibberling | male | 17 | all 3 |
| mutated gibberling | female | 10 | all 4, +Fighter/Dodger 2 |
| mutated gibberling | male | 10 | all 6, +Fighter/Dodger 4 |

"Striking" = `GRASP_STRIKE`, "Kicking" = `STANCE_STRIKE`, "Fighter" =
`MELEE_COMBAT`, "Dodger" = `DODGING`.

**"Diseased" is a name only.** These castes carry no disease-spreading mechanic;
the only illness any gibberling has is the ordinary `GETS_WOUND_INFECTIONS` /
`GETS_INFECTIONS_FROM_ROT` wound infection (kept from v0.2). The Highfantasy
cave-plague hook (`CREATURE_CLASS:GENERAL_POISON` + `interaction_hordes_goblins`)
remains **not** ported — if you later want diseased gibberlings to actually spread
a plague, that class + those three interactions is the wiring to add.

**Verify in-game (not yet render-tested):** graphics only index at game launch,
so start DF fresh, gen a world with this mod, and confirm gibberlings render as
blue goblins (world sprite + portrait, all six castes) and that a blue `g` shows
in ASCII mode.

## v0.4 — FIX: gibberlings rendered green, not blue

Root cause: the palette recolor was wrong. In DF's layered palette system the
`LS_PALETTE_DEFAULT` row (row 0) is the *reference* the base sprite's pixels are
matched against; `USE_PALETTE:BODY:n` remaps row 0 -> row n. v0.1-0.3 hue-shifted
row 0 itself to blue, so the vanilla-green goblin sprite pixels no longer matched
any row -> no remap -> creatures rendered plain green.

Fix (graphics-only, so it needs only a DF restart, no creature-raw change):
- Recolored the actual body sprite blue (`gibberling_body.png`, same hue transform
  as the palette) and shipped it under our own tile page `HA_GIBBERLING_BODY`;
  repointed all body `LAYER` refs from vanilla `GOBLIN_BODY` to it. Now sprite blue
  pixels match palette row-0 blue columns, so every skin tone remaps to blue.
- Same for the three portrait body pages (`HA_GIBBERLING_PORTRAIT_BODY/_CHILD_BODY/
  _BABY`). Clothing tile pages stay on vanilla (dormant on naked gibberlings).
- Palette files unchanged (already blue); no creature-raw edit needed - blueness no
  longer depends on which skin color a gibberling rolls.

## v0.5 — chitin redesign toward the canonical Cacame gibberling

Reworked the creature from the humanoid goblin fork toward the canonical gibberling
body while keeping our blue theme, cannibalism, and skill-tiered castes:
- **Intelligent but babbling:** added `CAN_LEARN` + `CAN_SPEAK` + `UTTERANCES`.
- **New body:** chitin exoskeleton, `TAIL`, clawed toes (`4TOES_FQ_REG`/`4TOES_RQ_REG`
  + `CLAW_TEMPLATE`), **no hands** (cannot wield), **ICHOR** blood. All tokens are
  vanilla, so still self-contained. Replaced the humanoid body/tissues/hair/face.
- **Attacks:** bite (MAIN, latch) + claw (MAIN, `GRASP_STRIKE`) + kick (`STANCE_STRIKE`);
  dropped punch/scratch (no hands).
- **Size:** adult ~50,000 cm³ (10,000 below dwarves/goblins at 60,000).
- **Agility** set to the elf range (`450:950:1150:1250:1350:1550:2250`).
- `MAXAGE:20:30`; matures at `CHILD:2`.
- **No longer `[EVIL]`-restricted** — spawns in any region. Dropped `CREATURE_CLASS:MAMMAL`
  (it's a chitin creature now).
- Kept the blue **goblin sprite** (user's request): the graphics' skin-tissue colour
  conditions were repointed from `SKIN` → `CHITIN` (the carapace is coloured with the
  same blues), so the existing art renders on the new body. The sprite is still a
  humanoid goblin — an art placeholder that no longer matches the anatomy; bespoke
  gibberling art is a future task.
- **On `EAT_SAPIENT` ethics:** skipped — ethics only apply to *entity* members, and
  gibberlings have no entity (they're wildlife), so it would do nothing; their
  cannibalism stays mechanical (`CARNIVORE` + `BONECARN`).

**Verify in-game (not yet render/spawn-tested):** (1) that `CAN_LEARN` wildlife with
no entity still spawns as roaming predators (if not, add `FEATURE_ATTACK_GROUP` or an
entity); (2) that the sprite renders blue on the chitin body (the `CHITIN` graphics
condition). Only affects newly-generated worlds (creature raws are baked per world).

## v0.8 — renamed to "HA - Beasts"
- Mod display name changed from "High Fantasy - Beasts" to "HA - Beasts" to match
  the rest of the High Adventure suite. No content changes.
