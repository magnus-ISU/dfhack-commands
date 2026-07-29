# ha-playable-civs — fork changelog

## v0.6 — vanilla kobolds no longer playable
- Removed `[SELECT_ENTITY:SKULKING][SITE_CONTROLLABLE]`. Making vanilla kobolds
  (entity SKULKING) fort-playable produced broken forts where the kobolds appeared
  as **livestock** rather than citizens. The **ha-kobolds** mod now supplies the
  proper playable kobold civilization (HA_KOBOLD_CAVES, with Ancient Dragon rulers),
  so vanilla kobolds are intentionally left un-playable to avoid the two colliding.

## v0.5
- Shaping Tree pacing hook fixed (same onReactionComplete bug as the breeding pit
  - it never fired). Now uses `eventful.registerReaction`; early harvests cancel
  the reaction natively instead of deleting products.
- Script renamed to **high-adventure/playable-civs** (auto-enables next reload).

## v0.3
- Companion script auto-enables on fort load (shaping-tree pacing, goblin ghost
  dispel, tree indestructibility) — no manual `enable` needed.

Standalone fork of **All Races Playable Redo** v2.2-53.14 (Steam 3738520568, Lord Nich;
descended from Arkbrik's All Races Playable). Per High Adventure policy, every ID is
renamed so fork and original can coexist.

## Renames
- Mod ID `arp_nich` → `HA_playable_civs`; files `*_arp.txt` → `*_ha.txt` (headers updated).
- All object IDs suffixed `_ARP` → `_HA` (reactions `MAKE_WOODEN_*`, `GROW_WOOD`,
  `GROW_FEATHER`, `TAN_A_HIDE_ADV`, leather `*_ADV`; plants `GROWN`/`FEATHER`; and every
  entity `PERMITTED_REACTION` reference to them).
- Steam metadata removed.

## Behavioral changes from the source mod
1. **Adventure-mode outsiders** (new `creature_ha_playable.txt`): `OUTSIDER_CONTROLLABLE`
   added via `SELECT_CREATURE` to DWARF, ELF, GOBLIN, KOBOLD (vanilla HUMAN already has it).
   Purely additive.
2. **Goblins: one caravan season** — the redefined `EVIL` entity had all four
   `ACTIVE_SEASON`s; now only `AUTUMN` (High Adventure evil-trade-bloc schedule).
3. **Goblins: bronze** — added `PERMITTED_REACTION:BRONZE_MAKING` and `BRONZE_MAKING2`
   next to the existing furnace jobs. Goblins now work bronze and iron, still no steel or
   adamantine.

## Inherited from the source mod (unchanged)
- `SELECT_ENTITY` additions for FOREST (elves), PLAINS (humans), SKULKING (kobolds);
  CUT+redefine of EVIL (goblins) — the one unavoidable replace.
- Elf economy: no mining/chopping/farming; gathering plus grow-wood-from-seed reactions
  producing the phantom "grown wood"/"grown feather tree" plants at the craftsman shop.
- Kobold civ marked playable with the author's caveat that UTTERANCES limits them.

## v0.2 — Shaping Tree & fodder customs
- **Shaping Tree** (elves): 5×5 workshop grown from a seed (+1 buildmat), custom
  top-down trunk art (roots, growth rings, mossy verge, glowing heartwood). The
  grow-wood and grow-feather-wood reactions moved here from the craftsman's shop and
  now use the **strand extraction** skill (`PERMITTED_JOB:STRAND_EXTRACTOR` added).
- **Companion DFHack script** (`enable ha-playable-civs`):
  - one grow-job per tree per **month** (legendary strand extractor: half); early
    harvests wither with an announcement;
  - Shaping Trees **cannot be deconstructed** (removal jobs are cancelled — "The
    shaping tree refuses to be unmade.");
  - **goblin ghosts are dispelled** — goblins are used to sending out fodder and do
    not memorialize their dead (orcs get the same in ha-orcs).

## 0.5 -- vanilla-elf embark food & drink
- Playable FOREST (vanilla elf) civs had empty crop/seed/booze resource lists (plants=0 seeds=0
  booze=0 live), so elf embarks offered no food or drink. Added [OUTDOOR_FARMING]
  [OUTDOOR_GARDENS] + PLANTER/COOK/MILLER jobs + PROCESS_PLANT_TO_BAG / MILL_SEEDS_NUTS_TO_PASTE
  (BREWER + brew reactions were already present). Needs a fresh world.
