# migration-plan: working around the Seven Animal Limit with DFHack

A plan for a DFHack script (working name **`wildlife-migration`**) that brings more of Dwarf
Fortress's wildlife to your fort despite the per-region "7 animals per bucket" limit, by
**occasionally spawning extra wild animals drawn from the wider regional pool** — and, rarely,
a **migration-wave** event where a herd crosses the map.

This is a userspace workaround (we never touch worldgen); it just adds visitors on top of the
animals DF already spawns. It is the script-pack analogue of the reddit plea: "let wildlife
roam free."

---

## 1. How DF's system actually works (verified on a live fort)

Confirmed by poking the running game:

- Worlds hold `df.global.world.world_data.regions[]` (644 on this world). Each region has a
  `type` (`df.world_region_type`, e.g. `Mountains`) and a **`population` vector of
  `world_population`** entries.
- Each `world_population` has:
  - `type` — `df.world_population_type`: **`Animal`=0**, `Vermin`=1, `VerminInnumerable`=3,
    `ColonyInsect`=4, `Tree`=5, `Grass`=6, `Bush`=7.
  - `race` — index into `df.global.world.raws.creatures.all` (for animals/vermin).
  - `plant` — index into plant raws (for Tree/Grass/Bush).
  - `count_min` / `count_max` — the modelled population size.
- The fort's region: `df.global.world.world_data.active_site[0].pos` → look up
  `world_data.region_map[x][y].region_id` → `world_data.regions[region_id]`.

**The limit, observed:** this fort's region (id 347, biome **Mountains**) has exactly **7**
`Animal` populations: `WOLVERINE, CHINCHILLA, BIRD_KEA, YAK, MARMOT_HOARY, COYOTE, KINGSNAKE`.
That's the whole on-map roster — exactly the rant's complaint (yes, the kea made the cut).

**The opportunity, observed:** **40 regions** on this world share the `Mountains` biome type.
Each rolled its own nearest-7 from a different origin-point draw, so the **union of their
`Animal` populations is much larger than 7** and contains the species this fort will otherwise
never see (the proverbial deer/moose). We can build a rich candidate pool from real game data
**without needing the creatures' raw `[BIOME:...]` tokens** (which are not conveniently exposed
in the loaded `creature_raw`/`caste_raw` — searched; no biome flag field found).

`modtools/create-unit` is present and gives us everything we need to add animals:
`-race`, `-caste`, `-quantity`, `-location [x y z]`, `-locationRange [dx dy dz]` (randomised
spread, re-rolled per unit — ideal for herds), `-age`, and **`-duration ticks`**. Created
without `-setUnitToFort`/`-civId`, the unit is **wild** (huntable, flees/wanders like native
wildlife).

> **Note on `-duration` (checked the source):** the arg is internally `vanishDelay`, and the
> docs say the unit *"will vanish in a puff of smoke once the specified number of ticks has
> elapsed."* It is an **instant disappear**, **not** a graceful walk off the map edge. So we do
> NOT use it as the "they leave" mechanism — see §3.4 / §4.3 for how wildlife actually departs
> (wild animals wander off the map edges on their own).

---

## 2. Design principles

1. **Additive & non-destructive.** Never edit worldgen, region populations, or raws. We only
   add transient wild units. Disabling the script returns the fort to vanilla behaviour.
2. **Proximity-biased** (Textual_Aberration's idea): a creature from a nearby same-biome region
   is more likely than one from across the map. An island with only skunks should stay skunky.
3. **Rare and immersive**, not a zoo. Tune so extra fauna feels like "oh, a deer wandered in,"
   not a constant stampede. Default to a few opt-in spawns per season.
4. **Cheap.** Build the pool once (cache it; rebuild only on map load / season). Spawn on a
   slow heartbeat. Prefer temporary units so they don't bloat the unit list / FPS / save.
5. **Safe roster.** Exclude things that would be griefy or nonsensical as ambient wildlife
   (megabeasts, night creatures, intelligent animal-people, domestic livestock, etc. — §4.2).

---

## 3. Feature A — Wandering wildlife (the core fix)

Periodically, with low probability, spawn a small number of a wild animal **drawn from the
regional pool, ignoring the native 7**, at the map edge so it wanders in.

### 3.1 Build the candidate pool
On map load (and refresh each season):

1. Find the fort region `R` and its biome `type` via the path in §1.
2. Collect **donor regions**: all `regions[i]` with the same `type` as `R` (optionally also
   `R`'s immediate world-map neighbours of *any* biome, to model edge mixing). Record each
   donor's world-map distance to `R` (Chebyshev/Euclidean over region coords).
3. For each donor, walk its `population[]`; for every entry with `type == Animal` and a valid
   `race`, add the creature to a `pool` keyed by race id, accumulating a **weight**:
   `weight += 1 / (1 + distance)` (nearer donors contribute more — the proximity bias).
   Native-7 species naturally get high weight (they're in `R` itself, distance 0); the point is
   that *non-native* species now appear in the pool at all, weighted by how close they roam.
4. Apply the eligibility filter (§4.2). Keep `pool = { {race, weight, group_min, group_max}, … }`
   where group sizes come from the creature's `population_number`.

This yields, for the Mountains fort above, a pool spanning the combined draws of 40 regions —
dozens of species — instead of 7.

### 3.2 Spawn cadence & selection
- Heartbeat every game-day (calendar-gated, like the pack's other services). Each tick, roll a
  small chance (config `daily_chance`, default ~8%). On success:
  - Weighted-pick a `race` from the pool.
  - Pick a caste (default first non-egg caste; optionally low chance of the `GIANT_` variant if
    one exists and is enabled).
  - Group size = random in `[group_min, group_max]` (herd animals arrive in numbers).
- Avoid piling on: skip if the map already has more than `max_extra_wildlife` (config) live
  script-spawned animals (tag them — see §3.4).

### 3.3 Where to spawn
- Choose a random **walkable surface tile on the map edge** matching the animal's medium
  (land animals on land edge, swimmers in water edge). Reuse the edge-finding approach DF/its
  ambushers use: scan edge columns for an outdoor, walkable, non-building tile at ground height
  (`dfhack.maps` + tile flags). Fall back to a known-good edge tile.
- `create-unit -race R -caste C -quantity N -location [x y z] -locationRange [3 3 1]`
  (wild — no civ/group), so they enter as a loose cluster and disperse.

### 3.4 Lifecycle / cleanup
- Tag spawned units (a persistent set of unit ids) so we can count them and not exceed
  `max_extra_wildlife`.
- **Let them leave naturally.** Wild animals wander and exit via the map edges on their own over
  time, so wanderers self-clear with no forced removal — keep the cap and don't fight DF.
- **Any forced cleanup must not poof them.** `-duration` makes a unit *vanish in a puff of
  smoke* (it does NOT walk off the map), which looks silly mid-map. If a fort accumulates
  stragglers over the cap, prefer relocating an *off-screen* one to a map-edge tile so it walks
  off; treat `-duration` as an explicit, opt-in last resort only. (Animals dwarves kill/tame
  leave our tracking naturally.)

---

## 4. Feature B — Migration wave (rare event)

Once in a long while, a **group of one species crosses the map**: many appear at one edge, move
through, and leave — the "huge piles of bison" image from the thread. Unlike the wanderers, the
species is drawn from **far afield** (anywhere in the world) and can be **any animal**, not just
a local herd herbivore — that's what makes a migration feel like it came from somewhere distant.

### 4.1 Trigger & species
- Very low per-season chance (config `wave_chance`, default ~once/2 years), or a manual command
  `wildlife-migration wave`.
- **Draw from a far wider pool than the wandering spawns — a migration comes from *afar*.** Use
  **all regions across the world** (any biome), not just same-biome neighbours, with only a weak
  long-tail distance bias (e.g. `weight += 1/(1 + distance/K)` with a large `K`, plus a small
  flat floor so even the most distant regions contribute). This is precisely where you finally
  see creatures that roam nowhere near home — the point of a migration.
- **Any kind of animal is eligible**, not just gregarious herd herbivores: predators, solitary
  beasts, oddities — anything that passes the safety filter (§4.2). Group size still comes from
  the species' own `population_number`, so "any animal" reads naturally (a wolf wave is a small
  pack; a yak wave is a throng; a lone-hunter wave might be one or two).

### 4.2 Eligibility filter (shared by both features)
Include a `race` only if it is plausible ambient megafauna-or-smaller wildlife. Exclude when the
creature/caste has any of:
- **Megabeast / semimegabeast / unique** (`flags.MEGABEAST`, `SEMIMEGABEAST`, `UNIQUE_DEMON`),
  **night creature**, **feature/HFS beast** — no surprise dragons.
- **Intelligent / civilised** (caste `CAN_SPEAK` or `CAN_LEARN`) — excludes animal-people like
  `PENGUIN MAN` that share the population list.
- **Domestic-only** livestock/pets/mounts that wouldn't roam wild (caste `PET`, `PET_EXOTIC`,
  `MOUNT`, `DOMESTIC` with no wild presence) — though anything genuinely in a wild
  `population` entry is usually fine.
- Optional toggles: `allow_predators` (default on, lower weight), `allow_giant_variants`
  (default low chance), `allow_vermin` (default off — vermin aren't the point).

### 4.3 Wave mechanics
- Spawn `wave_size` (e.g. 20–60) of the chosen race along **one** map edge:
  `create-unit -quantity N -location [edge] -locationRange [span 2 1]`.
- Make them cross and exit *naturally*: spawn at one edge; being wild, they wander and leave via
  the map edges on their own. To make a wave move briskly opposite-ward, optionally nudge their
  goal toward the far edge (investigate whether a wild unit's wander/flee target can be set;
  otherwise rely on natural wandering). Do **not** use `-duration` to "end" the wave — that
  poofs them mid-map in a puff of smoke. Fire a DF announcement + pause-worthy popup
  ("A great herd of yaks is migrating across the area!").
- Respect `max_extra_wildlife` so a wave doesn't tank FPS; cap `wave_size` accordingly.

---

## 5. Configuration (persisted per fort)

| key | default | meaning |
|---|---|---|
| `enabled` | off | master toggle (`enable wildlife-migration`) |
| `daily_chance` | 0.08 | chance/day of a wandering-wildlife spawn |
| `group_scale` | 1.0 | multiplier on natural group sizes |
| `max_extra_wildlife` | 40 | cap on live script-spawned animals |
| `wander_radius` | same-biome | wanderer (Feature A) donor set: same-biome union, or N-region radius |
| `allow_predators` | true | include `LARGE_PREDATOR` (reduced weight for wanderers) |
| `allow_giant_variants` | rare | chance to substitute a `GIANT_` caste/creature |
| `allow_vermin` | false | include vermin-type populations |
| `wave_chance` | per ~2 yr | migration-wave probability per season |
| `wave_size` | 30 | herd size for a wave (capped by `max_extra_wildlife`) |
| `wave_distance_k` | large | flattens the wave's distance bias — bigger = reaches further afield |
| `unit_duration` | 0 (off) | hard-cleanup timer; >0 makes spawns *poof* (puff of smoke) after N ticks. Off by default — prefer natural map-edge exit |

Surface this as overlay/notify status like the rest of the pack, and wire `enable
wildlife-migration` into `magnus-scripts`.

---

## 6. Implementation phases

1. **Pool builder** (read-only): region lookup → same-biome donor union → weighted, filtered
   candidate pool. Ship a `wildlife-migration pool` debug command that prints the pool (species
   + weight + group size) so we can eyeball that the Mountains fort now lists deer/moose/etc.,
   not just the 7.
2. **Edge-tile finder**: robust "random walkable outdoor edge tile for medium M" helper.
3. **Wandering spawns**: heartbeat + weighted pick + `create-unit` + tagging/cap + `-duration`
   cleanup. Tune cadence.
4. **Migration wave**: species selection, edge spawn, cross-map goal/announcement, manual
   `wave` trigger first, then the rare auto-trigger.
5. **Polish**: config, persistence, notify-panel status, magnus-scripts integration, docs.

Each phase is independently testable (esp. phase 1, which is pure data).

---

## 7. Risks & mitigations

- **FPS / save bloat.** Many wild units cost path/think time. → Hard cap (`max_extra_wildlife`),
  slow cadence, small default groups, and **natural map-edge exit** (wild animals wander off on
  their own). `-duration` is NOT a graceful exit (it poofs them in a puff of smoke); use it only
  as an opt-in last resort if a fort really accumulates stragglers.
- **Spawning something nasty.** → §4.2 filter (no megabeasts/night creatures/feature beasts);
  predators optional and down-weighted.
- **Animal-people / sapients in the pool.** → exclude `CAN_SPEAK`/`CAN_LEARN`.
- **Wrong medium** (fish on land, etc.). → match spawn tile to the creature's locomotion
  (flier/swimmer/walker) via caste flags; skip if no valid tile.
- **Cavern/aquatic biomes & savagery.** → start with surface land biomes; treat cavern layers
  and ocean/lake/river pools as later extensions (their populations live in the same structures;
  the edge-finder and filters differ).
- **`GIANT_` variants double-dipping** the limit (the rant's savage-biome complaint). → giant
  variants are just other `race`s in the pool; they're handled like any creature and gated by
  `allow_giant_variants`.
- **create-unit quirks across versions.** → call it via `dfhack.run_script('modtools/create-unit', …)`
  and validate the resulting unit; degrade gracefully if an arg is unsupported.
- **Interactions with hunting/taming/butchering.** Spawned wild animals are normal wildlife, so
  hunters/cages/traps all work — a feature (you can finally trap that deer), but note tamed
  ones leave our tracking (fine).

---

## 8. Open questions & future work

- **True biome eligibility from raws.** If a future DFHack exposes per-creature `[BIOME]` flags,
  the pool could include species that *could* live here but aren't in any nearby region's draw
  at all — the fullest fix. Until then, the same-biome union is a strong proxy.
- **Seasonal / migratory routes** (thread idea): tie certain species to seasons (spawn turkeys
  in autumn, etc.) using `cur_season`; give waves a fixed entry/exit edge per species.
- **Goal-driven visitors** (thread idea): nesting birds that lay and leave, foragers, etc.,
  using temporary stations/goals.
- **"Capture tameable animal" missions** (OP's wish) are an army/worldmap feature beyond a
  local script, but a lightweight analogue: a command that spawns a tameable herd near the fort
  to catch.
- **Tuning to taste.** Expose enough knobs that someone running a flora/fauna-diversity mod can
  crank variety up; the defaults stay conservative.

---

### TL;DR
DF already stores, per region, the realised animal `population`; the 7-limit is just how few
land in *your* region. Two features draw on it: **wanderers** union the `Animal` populations of
nearby **same-biome** regions (proximity-weighted) and occasionally walk one in; **migration
waves** draw from **all regions worldwide** with only a weak distance bias and allow **any
animal**, so far-flung species cross the map. Both filter for safe ambient wildlife and spawn
via `modtools/create-unit` at the map edge — additive, opt-in, reversible. Wildlife **leaves by
wandering off the edges**, not by `-duration` (which just poofs them in a puff of smoke).
Verified the data path on a live Mountains fort that currently shows exactly 7 species while 40
mountain regions' draws sit ready to be
pooled.
