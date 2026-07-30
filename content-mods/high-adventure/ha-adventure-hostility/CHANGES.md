# High Adventure - Adventure Hostility -- change log

A DFHack behavior component for the High Adventure suite. No raws (no creatures,
items, or entity) -- it ships a single overlay script,
`scripts_modactive/high-adventure/adventure-hostility.lua`, auto-discovered on
world load.

## v0.4 -- own-civ members never attack the adventurer
- Civ membership now beats race: units sharing the adventurer's `civ_id` are
  never force-hostiled. Previously the rules matched on creature race only, so
  e.g. a dwarf adventurer born/raised in a drow civilization was attacked on
  sight by their own people. Other civs of the same hostile race still attack.
- The dragon challenge is deliberately exempt: rival ancient dragons (and the
  kobolds standing with them) still turn on a dragon adventurer within one civ.

## v0.3 -- militant good (high elves + dwarves); kobolds are evil
- Kobolds (`HA_KOBOLD`) are now part of the EVIL set, so the good factions treat a
  kobold adventurer as an enemy. The evil set is now orc, kobold, goblin, succubus,
  dark dwarf, drow and mind flayer.
- New "militant good" faction: high elves (`HA_HIGH_ELF`) and dwarves (`DWARF`) are
  hostile to any EVIL adventurer -- same target set as the plain good civs -- but
  they NEVER break (NOFEAR) and NEVER yield (unreachable Pacify threshold), unlike
  the weaker good civs.
- `DWARF` moved from the yielding "good civs" group into "militant good"; the good
  civs are now just `HUMAN` and `ELF`.

## v0.2 -- kobold civ + dragon overlords
- The kobold civ is now a hostile faction: `HA_KOBOLD` (which includes its dragon
  overlords, the `ANCIENT_DRAGON` caste of the same creature) is hostile to any
  adventurer who is not a kobold.
- Special pacify thresholds for kobolds: a plain kobold's surrender sticks at Pacify
  1, but rises to 12 while one of their ancient-dragon overlords is on screen; a
  dragon overlord itself always needs Pacify 12.
- The standalone `HA_ANCIENT_DRAGON` MEGABEAST (a different creature) is deliberately
  left out -- only the civ kobolds and their overlords are affected.

## v0.1
- Adventure-mode overlay that forces designated civs hostile to the adventurer by
  injecting nearby members into a Conflict activity opposing the player (creating
  one on-sight if needed) -- targeted at the player only, so they never berserk
  their own immigrants (unlike a raw `[CRAZED]`).
- Per-turn de-yield (`flags3.adv_yield`) gated on the adventurer's Pacify skill vs
  a per-race threshold: Goblin 1, Orc 3, Drow/Succubus/Dark Dwarf 6, Mind Flayer 12.
- Sets `[NOFEAR]` (session-only) on the always-hostile evil civs; good civs keep
  fear (can flee/yield).
- Config: `RULES` (loners / evil_bloc / good_civs) + `PACIFY_THRESHOLD`. Races
  absent from the loaded world are ignored.
