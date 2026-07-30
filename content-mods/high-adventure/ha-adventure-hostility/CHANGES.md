# High Adventure - Adventure Hostility -- change log

A DFHack behavior component for the High Adventure suite. No raws (no creatures,
items, or entity) -- it ships a single overlay script,
`scripts_modactive/high-adventure/adventure-hostility.lua`, auto-discovered on
world load.

## v0.6 -- hostility is site-scoped: guests in a town leave you alone
- While the adventurer stands inside a settlement, only that settlement's OWN
  people can be forced hostile. Anyone else there is a guest and is skipped --
  fixing a drow merchant who attacked on sight in a high elf town the moment the
  player joined it.
- Ownership is read from the site under the adventurer (same world-tile
  arithmetic `adv/fear-no-goblin` uses). BOTH of the site's ids count as "local":
  residents carry the site government id (`cur_owner_id`) while citizens and
  adventurers of the owning civ carry the parent `civ_id` -- measured live in a
  high elf town whose locals were civ 32 and whose adventurer was civ 31.
- Invaders are exempt: a siege is not a social visit, so `active_invader` /
  `invader_origin` / `marauder` units still attack inside anyone's walls. Visiting
  NPCs carry NO merchant/diplomat/visitor flag at all (the drow merchant had every
  one clear), which is why ownership rather than flags is the discriminator.
- Out in the wilderness nothing changes -- the faction rules apply in full, so
  travel stays as dangerous as before.

## v0.5 -- passive "in conflict" units actually fight now
- `make_hostile` re-asserts conflict_level 5 (fighting) in both directions on
  every sweep. Previously level 5 was only set when the script CREATED a
  conflict: units added to an existing event inherited its stale level, and DF
  decays levels over time -- either way targets ended up "in conflict" at
  level 0 and stood around peacefully (observed: six HA_KOBOLDs sharing the
  adventurer's conflict, all passive).

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
