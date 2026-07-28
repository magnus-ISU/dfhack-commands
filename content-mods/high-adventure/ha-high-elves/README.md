# HA — High Elves (plan + status)

Elf-stock artisans with the **metal artifice of dwarves** but **no fey moods**.
They mine and forge (picks, metalwork) yet still **never cut trees** — growing
what wood they need at the Shaping Tree. Their signature material is **twinkling
metal**, a fixed divine metal they *catch from the sky* and weave into near-armour
fabric or forge into bars. They live in a few **human-style castles** (low total
population, few but populous sites), keep **peaceful elven ethics** (but are **not
cannibals** and **prize craftsmanship**), and **do not trade**.

**Self-contained** -- its own `HA_HE_SHAPING_TREE` building, `HA_HE_GROWN` wood, and reactions; depends on no other mod.

## Twinkling metal & the "divine fabric" decision

Vanilla "divine fabric" is just fireproof silk — weak. We rejected that. Instead
twinkling metal (`objects/inorganic_ha_twinkling.txt`) takes its **material
properties from the generated divine metal** (`divine.lua`) — most importantly
`[MELTING_POINT:NONE][BOILING_POINT:NONE]`, which is what actually makes divine
metal **dragonfire-safe** (it can't melt at any temperature; adamantine melts at
25000 and is *not* dragonfire-safe). We then add adamantine's **thread-metal
flags** (`[ITEMS_SOFT][WAFERS][STOCKPILE_THREAD_METAL]`) so this divine metal is
ALSO weavable → twinkling fabric is metal-strength AND fireproof, so cloaks are
near-armour. Name/colour = the STARS-sphere divine metal literally called
"twinkling metal" in `divine.lua`. No `[DEEP_SPECIAL]` — it is grown, not mined.

## Fortress-mode chain (`objects/reaction_ha_high_elf.txt`)

1. **Catch starlight** (Shaping Tree): 1 plant thread + 1 silk thread → 1 twinkling
   strand (a `THREAD` item of `HA_TWINKLING_METAL`).
2. Either **weave** at a loom → twinkling cloth → clothes (vanilla adamantine path),
   **or forge a bar**: 1 strand + 1 silver bar + fuel (magma smelter / coke) →
   1 twinkling bar, then smith normally.

⚠️ **OPEN VERIFICATION:** the loom weaving a *custom* thread-metal is an engine
behaviour I could not confirm from raws (adamantine may be special-cased). **Test
in-game** (gen world → catch starlight → weave). If the loom refuses it, add a
`HA_WEAVE_STARLIGHT` reaction (strand → cloth) at the Shaping Tree as a fallback.

## Worldgen gear: NOT possible in raws → DFHack

Civs draw worldgen gear only from geology-available metals; divine metals (and
reaction-made metals) are outside that system, so high elves **cannot** spawn in
twinkling metal. Handled by DFHack instead:

- `scripts_modactive/high-adventure/high-elves.lua` — re-gears high-elf
  **invaders / visitors** and the high-elf **adventurer** to full twinkling metal
  (weapons + armour) and twinkling cloth (clothing) on load / arrival. First pass
  = material-swap of their existing metal/cloth items. (DFHack cannot alter the
  historical-generation sim itself; it only rewrites units once a world is loaded.)

## Sibling DFHack work (noted, not yet built)

- **Drow → steel, always**: same material-swap script for drow invaders/visitors/
  adventurers (they know steel but worldgen scatters them across 25 soft metals).
  Keep drow `MAX_SITE_POP` **as-is** (massive cities are wanted).
- **Drow siege cull** *(future)*: when a drow siege/ambush loads, cull **~½** of the
  invaders, **never** historical figures. Runs in the same pass as the steel swap.
- **Shaping-tree sky access**: enforce (in `ha-playable-civs/…/playable-civs.lua`,
  for regular elves too) that a Shaping Tree's work tile is `outside` (open to sky);
  cancel the build otherwise.

## Build status

| Piece | File | Status |
|---|---|---|
| Twinkling metal inorganic | `objects/inorganic_ha_twinkling.txt` | ✅ |
| Catch-starlight + forge-bar reactions | `objects/reaction_ha_high_elf.txt` | ✅ (verify loom weave) |
| Creature (elf clone) | `objects/creature_ha_high_elf.txt` | ✅ |
| Entity (elf + artifice, CITY, low-pop, no-trade, ethics) | `objects/entity_ha_high_elf.txt` | ✅ |
| Twinkling gear DFHack script | `scripts_modactive/high-adventure/high-elves.lua` | 🟡 first pass |
| Graphics (reuse elf) | `graphics/` | ⛔ TODO |
| Drow steel + cull script | (ha-drow) | ⛔ TODO |
| Sky-access enforcement | (ha-playable-civs) | ⛔ TODO |

**Graphics:** the vanilla layered elf graphics are ~8k lines; rather than hand-clone
them, the plan is to fetch the workshop art (`2917231690`) via steamcmd and
desaturate off blue. Until then high elves fall back to the creature tile (`e`,
white). Reusing elf sprites = clone `CREATURE_GRAPHICS:ELF`→`HA_HIGH_ELF` if you
want an interim look.

## Testing (raws need a new world)

Gen a world with `HA_high_elves` active, confirm the civ
spawns in CITY sites, then embark/adventure to test: catch starlight → weave (the
open question) → clothes, and forge → bar. Reaction reagent tokens
(`ANY_SILK_MATERIAL`, dimensions) are best-effort and may need tuning on first gen.
