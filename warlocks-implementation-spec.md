# ha-warlocks — implementation spec

Everything needed to build the mod, in one place. Background, provenance and the reasoning
behind these choices are in `warlocks-design-notes.md`; reference material is in
`content-mods/warlocks/` (gitignored).

Standard suite rules apply: standalone fork, `HA_` prefix on every ID, own `CHANGES.md`,
mod scripts live in `scripts_modactive/`, bundle rebuilt + version-bumped after any change.

---

## 1. Souls

The single currency. **Entirely lua-produced — no vanilla creature is edited.**

- **Item**: `[INORGANIC:HA_SOUL]`, issued as a `BOULDER`. Define its material properties
  directly; **do not** use `STONE_TEMPLATE`, so the material is not `IS_STONE` and therefore
  cannot satisfy `BUILDMAT`, `ANY_STONE_MATERIAL`, masonry or construction. Add `[SPECIAL]`.
  Souls appear in **no** reaction but ours.
- **Produced by lua, two ways:**
  1. **On kill** — any sapient or large creature killed by the fort.
  2. **On butchery** — `JOB_COMPLETED` on `job_type.ButcherAnimal`, but only for **prisoners
     and large animals**.
- **Size threshold**: one constant, `SOUL_MIN_BODY_SIZE` (start at 50000 — human is 70000,
  dog 15000 — tune after play).
- Souls are created with `dfhack.items.createItem` at the workshop/corpse tile. Mind the
  known trap: `no_floor` placement drops items into limbo permanently.

Sapient corpses cannot be butchered in fortress mode at all, which is why kills mint souls
directly — otherwise a siege would be worthless.

## 2. Creatures

| Thing | Kind | Notes |
|---|---|---|
| Warlock | civ creature, playable castes | immortal, **no migrants, can have children** |
| Skeleton | caste of the warlock creature | weak **citizen**, can do labour |
| Bone golem | caste of the warlock creature | powerful, **large**, **citizen**, can do labour |
| Elemental (per element) | **pet** creature | strong war animal, no labour, capped (§5) |
| Gargoyle — melee / fire / ice | `[IMMOBILE]` pet creature | fire and ice get breath weapons via `[CAN_DO_INTERACTION]` + `CDI` |
| Mephit | pet creature, 4 castes (Acid/Air/Ice/Fire) | dog-sized flier, `PET_EXOTIC` |
| Prisoner | non-sapient pet creature | livestock; model on `ha-drow`'s `HA_GOBLIN_SLAVE` (`[PET]`, no `CAN_LEARN`/`CAN_SPEAK`, butcherable) |

**Add nothing else.** Vanilla already supplies ravens, crows, giant ravens/crows, giant bark
scorpions, and five snake lines (tame them the way `HA_HELMET_SNAKE_TAME` is tamed).

Bone golems being a large caste has equipment consequences — check the armour-sizing notes
before setting body size.

## 3. Buildings

| Building | Build cost | Worker |
|---|---|---|
| Elemental shrine, one per element | **10 gold bars + 1 artifact book** | warlock |
| Necromantic shrine | **14 gems** | warlock |
| Gargoyle Mason | (TBD, cheap) | warlock |
| Obsidian Factory | **1 soul** | **warlock** (it is magic) |
| Liaison's Office | (TBD) | warlock |

Raws for the book requirement:

```
[BUILD_ITEM:1:TOOL:NONE:NONE:NONE][HAS_TOOL_USE:CONTAIN_WRITING][CAN_USE_ARTIFACT]
[BUILD_ITEM:10:BAR:NO_SUBTYPE:METAL:GOLD]
```

`[CAN_USE_ARTIFACT]` is mandatory — without it DF will not haul an artifact to a site.

**`BUILD_ITEM`s are not consumed.** They sit in `bld.contained_items` with `use_mode = 2` and
are returned on deconstruction, so the book and gold are a deposit, not a payment. This is
intended.

## 4. Reactions and costs

| Reaction | Cost | Where |
|---|---|---|
| Melee gargoyle | **15 boulders** | Gargoyle Mason |
| Fire gargoyle | 15 boulders + **15 souls** | Gargoyle Mason |
| Ice gargoyle | 15 boulders + 15 souls + **1 gem** | Gargoyle Mason |
| Skeleton | souls | Necromantic shrine |
| Elemental (any element) | souls | that element's shrine |
| Power up a warlock | souls + **1 gem** | Necromantic shrine |
| Bone golem | souls + **10 gold bars** + **1 gem** | Necromantic shrine |
| Resurrect a warlock citizen | **10 gold bars + 1 diamond** | Necromantic shrine |
| Obsidian boulders | **nothing** | Obsidian Factory |
| Summon a caravan | souls | Liaison's Office |

**Every gem line ships as two reactions** — glass is not `IS_GEM`, so one takes
`[REAGENT:gem:1:SMALLGEM:NONE:INORGANIC:NONE][ANY_GEM_MATERIAL]` (real gemstones) and one takes
cut clear glass. Diamonds for resurrection: any diamond, so filter by material, not by
`ANY_GEM_MATERIAL`.

Gold: `[REAGENT:gold:10:BAR:NO_SUBTYPE:METAL:GOLD]`.

**Cut, unless it earns a distinct niche:** imps. Elementals already cover "stronger warrior, no
labour" and mephits cover "small flying elemental pet".

## 5. Caps — elementals

```
type_cap(T) = 5 x (COMPLETED shrines of type T)
global_cap  = 5 x (COMPLETED shrines, all types)
allowed  <=>  living(T) < type_cap(T)  AND  living(all) < global_cap
```

- **Living**, not lifetime — a dead elemental frees its slot.
- Count only `construction_stage >= bld:getMaxBuildStage()`.
- No per-building state: building counters are defeated by deconstruct-and-rebuild, since
  `BUILD_ITEM`s refund. Census the units instead.
- Over-cap after a teardown is a stable, harmless state.
- Type comes from `bld.custom_type` and from the elemental's caste — no bookkeeping.

## 6. Gargoyle placement

`[IMMOBILE]` creatures cannot walk to a pasture, so the script moves them: after a delay, and
only while the player is not looking at them, teleport the gargoyle into the pasture it is
assigned to.

## 7. Nobles

| Position | Raw slot | Responsibilities | Squad |
|---|---|---|---|
| Sorcerer Supreme | `EXPEDITION_LEADER`, auto-filled | meet workers, receive diplomats, military goals | — |
| Death | appointed | law enforcement, executions | `[SQUAD:1:death:deaths]` |
| Hunger | appointed | trade, accounting, stocks | `[SQUAD:1:hunger:hungers]` |
| Pestilence | appointed | health management | `[SQUAD:1:pestilence:pestilences]` |
| War | appointed | military strategy, manage production | `[SQUAD:1:war:wars]` |
| Crypt Lord | `AS_NEEDED`, warlock-only | warlock squad leader | normal |
| Death Knight | militia commander, non-warlock castes | skeleton/golem squad leader | normal |

**Omit `[REPLACED_BY:...]` on the Sorcerer Supreme and define no `MAYOR`** — vanilla's
expedition leader carries `[REPLACED_BY:MAYOR]` and `MAYOR` is `[ELECTED]` with
`[REQUIRES_POPULATION:50]`, so without this the position is displaced at 50 citizens and the
fort loses its only auto-filled noble.

## 8. Population

- **No migrants**: the script erases `Migrants` entries for the player civ from
  `df.global.timed_events` (the inverse of the `force` caravan trick).
- **Children yes** — `[CHILD:n]` and ordinary reproduction. A deliberate change from the
  original, where warlocks were sterile.
- Summoned units use `dfhack.units.create` + pos-seed + active-insert + teleport + `makeown`.
  **Known risk: emigration destroys created units**, and this civ's whole population is
  summoned. Mitigation plan and a long-running test are required before release.

## 9. Caravans

A Liaison's Office reaction summons a caravan from one specific civ by appending to
`df.global.timed_events`:

```lua
df.global.timed_events:insert('#', {new=true, type=df.timed_event_type.Caravan,
    season=df.global.cur_season, season_ticks=df.global.cur_season_tick,
    entity=<historical_entity>, feature_ind=-1})
```

Guards: **no-op if that civ already has a caravan outstanding** (DF then schedules none of its
own — see `dfhack/fort/caravan-unstick.lua`), and pick a specific met, non-hostile entity rather
than the first matching `entity_raw.code`.

Generalises to `ha-high-elves`, `ha-orcs`, `ha-kobolds` and `ha-illithids` — a shared
`high-adventure/summon-caravan` helper, each mod supplying the workshop and the reagent.

## 10. Raws vs lua

| In raws | In lua |
|---|---|
| creatures, castes, entity, positions, `[SQUAD:n]` | soul creation (kill + butchery hooks) |
| buildings, `BUILD_ITEM` (incl. gold + writing-tool) | artifact-book validation, cancel build |
| all reactions and their reagents | gating every magic job to warlock castes |
| `[IMMOBILE]`, `CAN_DO_INTERACTION` / `CDI` breath | elemental caps (per-type + global) |
| `[CHILD:n]`, graphics, language | gargoyle teleport into pasture |
| | unit creation for skeletons/golems/elementals/gargoyles |
| | migrant suppression, caravan summoning |

Two proven in-repo patterns to copy rather than reinvent:

- **Cancel a build that fails a rule** — `ha-playable-civs` shaping tree: watch
  `world.buildings.all` for `custom_type` with `construction_stage < bld:getMaxBuildStage()`,
  then `dfhack.buildings.deconstruct(bld)` + `dfhack.gui.showAnnouncement(...)`.
- **Gate and cancel jobs** — `ha-illithids` neural bath: check conditions **at assignment
  time, never at completion**, so reagents are not spent before the refusal; pin
  `building.profile.permitted_workers` to one legal worker; cancel with `removeWorker` **first**,
  then `removeJob`, then announce. Cancelling a unit's `current_job` directly segfaults.

## 11. Graphics

- Sprites are recoverable from `content-mods/warlocks/art/cheatsheet_white.png` at native
  resolution: it is 1:1 pixel scale on a **32 px grid** (measured column runs 30–32 px; the
  gargoyle band is 96 px = three 32 px rows).
- Portraits are 96×96. `LARGE_IMAGE` needs layered sets, 3×2 max. A large caste sprite not
  wrapped in a `LAYER_SET` flashes grey under status greying.
- **Licensing is unresolved** — the art traces to Denzi (CC-BY-SA 3.0, share-alike),
  Redshrike (attribution), Vordak (permission granted to Meph, not to us) and Meph. Decision on
  record: credit all four. See `LICENSE.md` §3.

## 12. Assumed working, but UNVERIFIED

Proceed on these; test before release.

1. `[SQUAD:n]` with n ≠ 10 on the Steam build (vanilla only ever uses 10). Affects the Death
   Knight's squad size; the Horsemen's `[SQUAD:1]` is the safer half.
2. Forcing a caravan from a **hostile** civ (the goblin-caravan case).
3. Erasing `Migrants` timed events as the no-migrants mechanism.
4. `[CAN_USE_ARTIFACT]` + `HAS_TOOL_USE:CONTAIN_WRITING` actually pulling an artifact book to a
   construction site.
5. Where a non-`IS_STONE` boulder lands in the stockpile UI.

## 13. Still undecided

- Obsidian Factory: confirmed to consume nothing, but does it still need magma?
- Gargoyle Mason and Liaison's Office build costs.
- Embark: how many warlocks, and with what (the original started 13).
- Do warlocks eat and drink normally, now that potions are cut?
- Adventure mode: playable outsider, or fortress-only?
