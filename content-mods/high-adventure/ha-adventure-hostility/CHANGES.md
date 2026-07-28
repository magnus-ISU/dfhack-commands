# High Adventure - Adventure Hostility -- change log

A DFHack behavior component for the High Adventure suite. No raws (no creatures,
items, or entity) -- it ships a single overlay script,
`scripts_modactive/high-adventure/adventure-hostility.lua`, auto-discovered on
world load.

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
