ha-playable-civs — HA - Existing Civilizations Playable
========================================================

Standalone fork of "All Races Playable Redo" (Steam 3738520568, Lord Nich;
descended from Arkbrik's All Races Playable), reworked for the High Adventure
suite. See CHANGES.md for the full changelog and diff from the source mod.

Fortress mode
-------------
Dwarves (vanilla), HUMANS, ELVES, and GOBLINS are fort-playable:

- Elves (SELECT_ENTITY:FOREST): adds SITE_CONTROLLABLE, a full noble/position
  roster, and the crafting jobs + reactions a fort needs that elves lack.
- Humans (SELECT_ENTITY:PLAINS): adds SITE_CONTROLLABLE and a full position
  roster.
- Goblins: the vanilla EVIL entity is CUT and rebuilt. Diff vs vanilla:
  SITE_CONTROLLABLE + ALL_MAIN_POPS_CONTROLLABLE, bronze-making permitted
  (BRONZE_MAKING + BRONZE_MAKING2 -- their only alloy; METAL_PREF and gear
  lists untouched), ACTIVE_SEASON cut from all four seasons to AUTUMN only
  (single caravan window), trolls guaranteed in pops and sieges, nest boxes
  craftable, fishing jobs disabled (FISH_CLEANER bug), and an explicit fort
  position roster (overseer, pit guard, shadow master, executioner, ...)
  replacing SITE_VARIABLE_POSITIONS:ALL. Everything else is token-identical
  to vanilla.

KOBOLDS ARE NOT FORT-PLAYABLE HERE. Making vanilla SKULKING kobolds
SITE_CONTROLLABLE produced broken embarks where citizens appeared as
livestock (see CHANGES.md v0.6). The ha-kobolds mod supplies the proper
playable kobold civilization (HA_KOBOLD_CAVES) instead.

Adventure mode
--------------
DWARF, ELF, GOBLIN, and KOBOLD creatures gain OUTSIDER_CONTROLLABLE (humans
already have it in vanilla), so all five races can start as adventure-mode
outsiders. Kobold ADVENTURERS are playable -- just not kobold forts.

Also included
-------------
The Shaping Tree workshop (grow wood / feather wood, wooden weapon+armor
reactions, adventure-mode leather reactions) with its companion DFHack script
scripts_modactive/high-adventure/playable-civs.lua.
