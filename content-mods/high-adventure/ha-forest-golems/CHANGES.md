# ha-forest-golems

## v0.1 — first cut

Adds `HA_FOREST_GOLEM` (creature + entity) and two custom body modules.

**Design decisions**

- **Kill switch is `THOUGHT`, not `CIRCULATION`.** A thought centre is an instant
  kill when destroyed; a heart kills by bleed-out, and a `NOT_LIVING` creature
  with no blood has nothing to bleed. The golden heart is therefore a `THOUGHT`
  part in the `UPPERBODY`, `INTERNAL` so the torso must be opened first. No brain
  and no skull are on the body line at all, so the head and neck are cosmetic.
- **`FIREJET`, not `DRAGONFIRE`.** Dragonfire melts iron — it would cook the
  golem casting it and every golem beside it. `CDI:BP_REQUIRED:BY_CATEGORY:FLAMETHROWER`
  ties the ability to the glass nozzle so breaking it disarms them for good.
- **`NOEMOTION` yes, `NOTHOUGHT` no.** Constructs feel nothing and a fort of them
  never tantrums, but `NOTHOUGHT` would empty the thoughts/needs panels that fort
  and adventure mode are built around.
- **One `MALE` caste.** A genderless civ does not generate — the same trap that
  produced zero kobold civs when a `[MALE]`/`[FEMALE]` pair was commented out.
- **Skills:** `DODGING:10`, every other combat skill `20`.

**Unverified — test before trusting**

1. **The `THOUGHT`-in-upper-body kill.** Vanilla ships the identical primitive
   (`BODY:UB_BRAIN`) but **no vanilla creature uses it**, so the behaviour is
   unproven. Arena-test: does destroying the golden heart kill instantly, and
   does severing the head do nothing?
2. **`[CON:LH]` across body modules.** The flamethrower attaches to the left hand
   by token from a separate module. Vanilla only ever uses `CONTYPE:` across
   modules; `CONTYPE:GRASP` would have given them two nozzles, one per hand.
   Check `errorlog.txt` for an unresolved connection.
3. **`CDI:BP_REQUIRED` on a custom category.** Vanilla only uses it with `MOUTH`,
   `GRASP` and `UPPERBODY`.
4. **Nozzle fragility.** `TISSUE_LAYER` for a specific category *adds* a layer
   rather than replacing the blanket `ALL:IRON`, so the nozzle is glass over iron
   rather than solid glass. Its small `RELSIZE` is what makes it severable. If it
   proves too tough, drop the blanket layer and assign iron category by category.
5. **Skill tokens `SHIELD`, `ARMOR`, `MISC_WEAPON`, `CROSSBOW`, `BLOWGUN`.** These
   do not appear as `NATURAL_SKILL` anywhere in vanilla; the rest of the list does.
   An invalid token is an errorlog line, not a crash.
6. **Whether dropping `WANDERER` costs adventure-mode start options.** The civ is
   `ALL_MAIN_POPS_CONTROLLABLE` + `SITE_CONTROLLABLE` and the creature is
   `OUTSIDER_CONTROLLABLE`, but the roaming-histfig tokens are all absent by
   design and may prune background choices.

## v0.2 — token fixes + art

- **Graphics**: full art set — the vanilla bronze colossus sprites recoloured
  iron-gray on our own tile pages (map sprite 3x2, list icon, corpse, statue,
  96x96 portrait). The map sprite is LAYERED (`LAYER_SET`+`LAYER`), not a simple
  `DEFAULT:LARGE_IMAGE`, so it is exempt from DF's status-grayscale and does not
  flicker. No item layers on purpose: worn gear would land at random spots on a
  3x2 sprite.
- **Raw token fixes** (all named by errorlog): `SPHERE:FORESTS` → `TREES`;
  glass tissue material `INORGANIC:GLASS_CLEAR` → builtin `GLASS_CLEAR:NONE`
  (the bad token failed creature finalization, leaving the nozzle glassless);
  `GEM_SHAPE:ALL`/`STONE_SHAPE:ALL` → written-out shape lists (no ALL wildcard
  exists); dropped unrecognised entity tokens (`WOOD_PREF` etc.), added
  `GEM_PREF`.
