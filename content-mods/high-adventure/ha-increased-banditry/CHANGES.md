# High Adventure - Increased Banditry — change log

A tiny standalone raws mod that bumps bandit-group generation for the two vanilla
base civilizations, deliberately kept out of `ha-playable-civs` so base-civ
banditry can be toggled independently of the playable/outsider-controllable edits.

Banditry is a worldgen entity raw (`[BANDITRY:n]` = ~percent chance the civ spins
off outlaw bands; `[LOCAL_BANDITRY]` confines them near the civ's own territory).
It is read during worldgen, so this is a raws mod, not a DFHack script.

## v0.1
- `SELECT_ENTITY:PLAINS` (Humans): appends `[BANDITRY:30]`. The later value
  overrides vanilla's `[BANDITRY:10]` at worldgen. No `LOCAL_BANDITRY` (matches
  vanilla human scope).
- `SELECT_ENTITY:FOREST` (Elves): appends `[BANDITRY:20]` + `[LOCAL_BANDITRY]`
  (vanilla elves have no banditry at all).

The suite's own civilizations are untouched here; their banditry lives in their
own mods (Goblins 50 in ha-playable-civs; Orcs 50; Succubi/Dark Dwarves/Drow/Mind
Flayers 40).
