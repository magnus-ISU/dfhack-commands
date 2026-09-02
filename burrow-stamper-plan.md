# fort/burrow-stamper — plan

Turn a burrow into a district. Pick a burrow, pick a preset (`housing`, `hovels`,
`noble quarters`, `guildhalls`, `temples`, or your own), and the stamper lays out a random
but fully connected arrangement of quickfort blueprints inside it, shows the layout, and
then digs and furnishes rooms one at a time as the fort needs them. Same machinery, with
different presets and a different "free tile" test, places houses along streets in an
above-ground village.

Everything that applies a blueprint to the map is `fort/quickfort` (the sequenced applier).
The stamper is a planner in front of it.

---

## 0. Decisions already made

These came out of the design discussion and are not reopened here.

| Decision | Rule |
|---|---|
| Roads | **Not** in the stamp. The packer generates them, as in-memory blueprint data, and hands them to quickfort. This is what makes random placement safe: connectivity is guaranteed by construction. |
| Doors | **In** the stamp. The stamp declares (or the packer infers) which door is the *entrance*. |
| Placement | Random, seeded, so the same burrow + preset + seed gives the same layout and "reroll" is one keypress. |
| Persistence | The burrow cannot carry a flag; the plan lives in site persistent data keyed by `burrow.id`. |
| Scanning | The burrow scan and the packer are frame-paced from an overlay, never one RPC call. |
| Z-levels | v1 plans one z-slab per plan. A burrow spanning several z-levels gets one plan per slab, each with its own entry. Stairs are later. |
| Digging | Lazy. Nothing is dug at commit. Rooms open on demand, and only the road needed to reach each opened room is dug with it. |

## 1. Walls: the rule that fixes every packing number

The question left open: do a room's walls belong to the room, or to the space between rooms?

**Recommendation: the stamp owns its interior; the packer owns a rock shell around it.**

- A stamp's **footprint** is the set of cells its blueprint actually designates (dig, build,
  place, zone). Not the csv bounding box. Blank cells are not footprint.
- Its **shell** is the 8-neighbourhood of the footprint minus the footprint: the ring of
  rock that becomes the room's walls when the interior is dug.
- **Hard rule:** no footprint may overlap another footprint *or another footprint's shell*.
  Shells may overlap each other. Two rooms whose shells coincide share a wall.
- **`margin`** is extra clearance beyond the shell, and it is a *per-stamp* setting
  because designs differ on whether walls may be shared. `margin 0` means shared walls: a
  room's engraving on the shared wall belongs to whichever room DF credits. `margin 1`
  gives every room its own wall, two rock tiles between neighbours, so every engraved
  wall counts for exactly one room. **Standard 3x3 housing uses `margin 1`.** Hovels use
  `margin 0`. Above ground the shell is empty space, not rock, so `margin` is the gap
  between houses and 1 or 2 reads as a village.
- **Roads may not enter a shell**, with one exception: the shell tile directly outside a
  declared entrance. That tile is the door's frontage and the road must reach it.

Consequences worth stating:

- A blueprint that draws its own walls as blank cells just works; the blanks are not
  footprint, and the shell computed around the dug cells is exactly those blanks.
- A blueprint that draws its walls as *constructed* walls (above-ground house) has those
  cells in its footprint, and the shell is a one-tile clearance around the building. Correct
  for a village.
- Usable area is now a computed number, not an argument: the preview reports
  `rooms placed / burrow tiles used`, and `margin`, `corridor_width` and `spine` are the
  knobs. Tune on a real burrow, once.

## 2. Stamp format

A stamp is a normal quickfort blueprint that still runs standalone in `fort/quickfort`,
plus an optional sidecar:

```
dfhack/data/blueprints/stamps/<name>.csv     the blueprint (hidden sections + #meta fine)
dfhack/data/blueprints/stamps/<name>.json    optional manifest
```

Manifest fields, every one optional:

| field | meaning | default / inference |
|---|---|---|
| `entrance` | `[[x,y], ...]` local coords of entrance tile(s), relative to the blueprint's cursor cell; any one may be used | door build-cells (`d`) on the footprint perimeter; failing that, any perimeter tile |
| `kind` | `unit` = tile repeatedly; `district` = already packed, stamp at most once per plan | `unit` if the footprint is under 12x12, else `district` |
| `rotate` | `true`/`false`, whether the packer may rotate/flip | `true` |
| `weight` | relative pick weight inside a preset | `1` |
| `margin` | clearance beyond the shell, per stamp | preset's value |
| `demand` | which oracle opens this stamp (see §5) | preset's value |
| `role` | free text shown in the GUI ("bedroom", "office") | filename |

Inference is the default on purpose: blueprints get designed while playing, and a bare csv
should place correctly. The manifest exists for the case where inference guesses wrong, and
the GUI shows the inferred entrance on the preview so the wrong guess is visible before it
matters.

The existing `house.csv`, `housing.csv`, `Noble Suite.csv` are not the starter set. The
stamper ships its own library (§7 Phase 3), designed for packing: door on a short edge,
walls left blank, nothing outside the interior.

## 3. Districts and presets

Three levels. A **stamp** is one blueprint. A **district** is a group of stamps with a
packing rule. A **preset** is the list of districts a burrow may hold, with weights, plus
its road widths.

**Two district kinds:**

- `repeat`: stamps lined along a road, doors on the road, until the district's capped
  stamps are used or its `max_len` of road is spent, then the next district starts.
  Hovels, 2x2 houses, 3x3 houses, luxury 3x3 houses (margin 1) are repeat districts with
  one stamp. Catacombs and hero memorials carry `max: 1`, so one district is exactly one
  catacomb or one memorial and the next district starts right after it.
- `set`: a suite. The first slot is the **hub** and carries the district's only door onto
  the road; every other slot attaches to an already placed room through a shared wall, at
  whichever spot grows the suite's bounding box least. Underground the child's door
  replaces a tile of the parent's rock wall and opens onto its floor; on the surface the
  child's built wall row coincides with the parent's built wall and the door sits in it. A slot may list **sized
  alternatives** and one is picked per suite. **Optional slots** roll 0 to `max` copies.
  Noble quarters: dining room (hub, 5x4 or 7x5), bedroom (3x3, 4x4, 3x5), office, tomb
  required; 0 to 2 sculpture gardens and at most one of throne room or library optional.
  Manor: a walled courtyard is the hub with the road door; great hall (7x4, two floors),
  a tower (3x3, five floors), master bedroom (5x4) and servants' quarters (5x3) share its
  walls; a second tower and a kitchen are optional.

**Temples** (weighted): shrine of the forge 5x5 (altar, pedestal, weapon rack, armor
stands), shrine of the sea 5x7, chapel of the dead 5x5 (coffins), grove of nature 7x8
(statues), plus two complexes: temple complex (sanctum hub 7x7, vestry, cloister; crypt and
library optional) and great temple (nave hub 9x8 with pews, two side chapels, vestry; crypts
optional). **Guildhalls**: masons', smiths', scholars', brewers' halls 7x6 or 5x6 with the
trade's furniture, plus merchants' guild (hall, counting room, vault) and warriors' guild
(hall, armory, barracks) as sets. Every temple and guildhall hall carries at least one
pedestal.

A **preset** also lists its **hallway blueprints** (road stamps): pieces the road
generator may use on the roads it lays. They belong to the preset, not to a district,
because they dress the roads every district shares. A piece as wide as the road (13x3
statue row, 13x3 coffin row) dresses the middle of a straight segment; a square one (7x7
statue garden, 5x5 shrine) is a plaza on a junction square.

Stamp names give the **interior** size. Every bedroom stamp includes a cabinet and a
chest. Hovels are a 4x1 strip: door, bed, cabinet, chest. The luxury house is 3x3 with bed,
cabinet, chest, weapon rack, armor stand, altar and statue. Tombs: 7x9 catacombs with
coffins along both side walls, 5x5 hero memorials, 3x5 family tombs. Town (surface): 3x3
bungalows, thin townhouses (2x5 interior, four floors, shared walls; the district mixes a
flush template and one set back a tile with a path, and neighbours still share a wall
along the overlap), big townhouses (4x3 interior, two floors, shared walls), 9x6
farm plots, manors. A district with `shared: true` overlaps its stamps' built walls with
the neighbour's, so a terrace is one wall thick.

**Multi-z stamps.** A stamp may be a list of floors, ground first. The ground floor decides
fit, door and frontage; upper floors are applied by quickfort at z+1, z+2 over the same
anchor, and the stamp is expected to carry its own stairs. Surface stamps put their walls
in the footprint; underground stamps leave walls blank and the packer owns the rock ring.

```
districts.json (excerpt)
  "hovels":       {"kind": "repeat", "margin": 0, "max_len": 16, "stamps": ["hovel-1x4"]}
  "luxury 3x3":   {"kind": "repeat", "margin": 1, "max_len": 16, "stamps": ["luxury-3x3"]}
  "catacombs":    {"kind": "repeat", "margin": 0, "max_len": 12,
                   "stamps": [{"name": "catacomb-7x9", "max": 1}]}
  "noble":        {"kind": "set", "margin": 1, "depth": 16,
                   "stamps":   [{"name": "dining", "alts": ["noble-dining-5x4", "noble-dining-7x5"]},
                                {"name": "bedroom", "alts": ["noble-bedroom-3x3", "noble-bedroom-4x4", "noble-bedroom-3x5"]},
                                {"name": "office", "alts": ["noble-office-3x3", "noble-office-4x4"]},
                                {"name": "tomb", "alts": ["noble-tomb-3x3", "noble-tomb-5x3"]}],
                   "optional": [{"name": "sculpture garden", "max": 2, "alts": ["garden-3x3", "garden-5x5"]},
                                {"name": "hall", "max": 1, "alts": ["throne-room-5x5", "library-5x5"]}]}
  "manor":        {"kind": "set", "margin": 2, "depth": 18,
                   "stamps": ["manor-house-9x6-2f", "stable-7x4", "garden-7x5"], "optional": [{"name": "well", "max": 1, "alts": ["well-3x3"]}]}
presets.json
  "hovels":         {"main": 1, "side": 1, "districts": [{"name": "hovels"}]}
  "housing 3x3":    {"main": 1, "side": 1, "districts": [{"name": "houses 3x3"}]}
  "luxury housing": {"main": 3, "side": 3, "districts": [{"name": "luxury 3x3"}]}
  "varied housing": {"main": 3, "side": 1, "road": ["statue-row-13x3"], "districts": [
                       {"name": "hovels", "weight": 1}, {"name": "houses 2x2", "weight": 2},
                       {"name": "houses 3x3", "weight": 2}, {"name": "luxury 3x3", "weight": 1}]}
  "noble quarters": {"main": 3, "side": 3, "road": ["statue-row-13x3", "statue-garden-7x7"], "districts": [{"name": "noble"}]}
  "tombs":          {"main": 3, "side": 3, "road": ["coffin-row-13x3", "shrine-5x5", "statue-row-13x3"], "districts": [
                       {"name": "catacombs", "weight": 2}, {"name": "memorials", "weight": 1}, {"name": "family tombs", "weight": 2}]}
  "town":           {"main": 3, "side": 1, "surface": true, "districts": [
                       {"name": "bungalows", "weight": 2}, {"name": "thin townhouses", "weight": 2},
                       {"name": "tall townhouses", "weight": 1}, {"name": "farms", "weight": 1}, {"name": "manor", "weight": 1}]}
```

## 4. The packer: roads grow, districts hang off them

Input: the burrow's tile set on one z-slab, the preset, a seed. Output: a **layout**: road
segments (start, direction, width, length), road stamps, districts and their rooms (stamp,
rotation, anchor, door, frontage tile), and the designation layer. Frame-paced; the
preview redraws as it grows. Prototyped in the browser mockup (§9); every rule below is
what that mockup does.

**4.1 Free tiles.** Scan `dfhack.burrows.listBlocks(b)` then `isAssignedBlockTile` per
tile, budgeted at a few blocks per frame. Underground a tile is free when it is undug wall
with no designation and no building; on the surface when it is open floor with no
building, tree, construction, water or magma. **The burrow's border ring is always rock:**
only a tile whose whole 8-neighbourhood is in the burrow may be dug, so the outermost ring
becomes wall. Existing rough or smoothed rock may be dug through for a road; engraved walls
(every wall a room owns) may not.

**4.2 Entry and existing geometry.** Always inferred. When the slab already holds roads
and rooms (a previous plan, or the fort's own corridors), **they are the starting point**:
every existing road's end square and every gap along its sides becomes a head, and the plan
grows out of the existing network. Only a slab with nothing on it starts from the dug floor
touching the burrow edge. A burrow touching nothing and holding nothing is reported
unplannable with the reason in the GUI.

**4.3 Heads and segments.** A road head is a tile, a direction and a width. Heads are
processed breadth-first, so the plan grows outward from the entry. Main-road segments are
at least as long as the preset's widest hub needs to find clear frontage between the
end-square turns. A segment advances
tile by tile from its head: its full-width footprint must be free rock claimed by nobody,
and the tiles just beyond both edges may not be road, so two roads never lie side by side
or touch at a corner. It ends at its wanted length, at rock, or one tile short of an
existing road it meets across its full width, which makes a T junction and closes a loop.
Every free-standing segment ends in a full square cap, so a turn is two rectangles meeting
at a square and a T is a rectangle meeting a straight edge. **Corners are valid by
construction; there is no repair pass.**

**4.4 Dress the segment at once.** (Statue rows only on road tiles; a plaza may dig.) If the segment is long enough, roll a statue or coffin
row from the road-stamp pool into its middle, on road tiles only. If the segment will end
in a junction, roll a plaza onto the junction square before anything else can claim the
space; a plaza may dig into free rock around the square. Statues and coffins are claimed as
blocked road, so no door is ever placed facing one.

**4.5 Reserve continuations, then line the segment.** Before any room goes down, every
continuation from the end square that can be reserved (straight, left, right; deeper side
streets try straight and one turn) is reserved for its whole intended length, so a later
road never runs through a room and a room never puts its wall on a future road. Then each
side of the segment is a sequence of districts chosen by **quota** (the district furthest
below its weighted share goes first): a repeat district lines the road until its caps or
its `max_len` are spent; a set district puts its hub door on the road and grows its suite
inward, bounded by the district's `depth`. Each district hands over with a gap wide enough
for a side street. The end square stays clear for junctions. Side streets are then found in
the gaps the districts left, never reserved through them.

**4.6 No road without rooms.** A segment that ends up with no room along it is undone,
together with the stamps on it and the continuations it reserved. That is the only pruning
rule, and it is what makes exhaustive continuations safe: the network grows as dense as the
districts can fill and no denser. Roads that reserve their way into an existing road across
their full width are laid as joins and close loops. In towns, an angled connector (a
two-tile-thick diagonal band so every step touches by edges) may leave a junction square
and is kept only if it reaches another road.

**4.6c Caverns and throats.** Roads never leave the burrow, so a burrow painted over a
cavern is a set of pockets joined by throats narrower than the road. When a continuation
or a gap side street is blocked by rock outside the burrow (never by rooms), the packer
pushes a narrower **connector** through the throat, down to one tile wide, up to three
connectors in a chain. No district is packed along a connector, so the preset's road
widths still hold everywhere rooms are, and a connector survives only if roads with rooms
grew beyond it; otherwise it is removed at the end. A segment that reserved no
continuation is a dead end and may use its end square for rooms, and a continuation
shorter than the preset's wanted length is still tried, since the no-rooms rule undoes
any that turn out useless. The entry on an empty slab is the boundary tile whose
main-road-wide open run is longest, in any of the four directions.

**4.6d Re-seeding.** When the network from the entry or from the existing geometry has
exhausted, every segment of the network itself re-seeds heads from its end square and its
gaps, with throat connectors allowed from any of them, and growth runs again (twice at
most). A root segment (one with nothing behind it, such as an existing road whose entry
was the edge of an older, smaller burrow) also re-seeds from its start square, backward
and to both sides; a root long enough to afford it keeps its start square clear of rooms
for that purpose, the way every segment keeps its end square. Existing geometry that holds
no road at all is treated as an empty slab and growth starts from the edge. Every road therefore starts on a road that is already connected; the packer never
creates a second network and never needs a connectivity check. On a fresh slab the entry
is the boundary tile with the best main-road-wide open run, scored by the free rock
around it. A roomless road is refused unless its flanks are a cave passage (too shallow
for any room before the burrow ends) and it leads somewhere, in which case it stays as a
connector; a connector pruned at the end takes its road stamps with it. Before a road is
refused for holding nothing from the first list, the fill list is tried on it, so a cave
too tight for a full noble suite still gets minor nobles.

**4.6a Fill pass.** With the road network settled, every road edge is walked again with
the preset's `second` district list (defaults to the first list), placing whatever still
fits in the leftover frontage: the gaps left for side streets that never came, margins,
short stretches. Presets add smaller or shared stamps here: luxury housing adds a 7x3
dining hall; noble quarters adds the minor noble, a 3x3 suite whose bedroom is guaranteed
and whose dining room, office and tomb are placed only if they fit.

**4.6b Existing geometry.** The packer starts from whatever claims are already on the
slab: existing rooms, walls and roads. New roads may join existing roads, and districts
avoid existing rooms. Two rules keep an existing road usable as a start: a seed head steps
outward past any plaza on the old end square before reserving, and whenever a road's
straight continuation could not be reserved (the burrow ended) the first three tiles of
that lane are kept clear of room bodies and walls, so a later plan on a bigger burrow can
grow through the old dead end instead of finding it fenced by engraved walls. The GUI demonstrates it by generating a smaller preset on a central
patch first, then growing the main preset around it (a noble district around a tomb).

**4.7 Designations.** Room floors smoothed, room walls (the rock ring the packer owns)
engraved, road floors smoothed, rock beside a road that no room owns smoothed. The
burrow's border ring takes part like any rock: engraved where a room's wall lands on it,
smoothed where a road runs beside it. Emitted as
`#dig` smooth/engrave cells in the same job as the dig, so quickfort sequences them after
the dig finishes.

**4.8 Report.** Districts per type, rooms and upper floors, segments, loops closed, road
stamps, tiles used / burrow tiles, road share of dug tiles, designation counts.

**4.9 Re-plan.** If the burrow is edited later, every segment with a dug or running room
is kept as is; growth resumes from the dead ends of the kept network into the new rock. A
room never moves once the fort has started on it.

## 4b. The in-game UI

`fort/burrow-stamper` is run by hand and opens a picker:

- **Burrow** (the fort's burrows by name), **Preset**, and **Build when**: apply now, a
  noble needs rooms, a house is needed, a guildhall is needed, a temple is needed, a tomb
  is needed. Confirming plans the burrow and, if "apply now", starts every blueprint job
  through `fort/quickfort` at once; otherwise the plan is stored and the pump opens rooms
  as the chosen condition fires (§5).
- **New preset… / Edit preset…** opens the preset editor, three columns:
  1. actions and settings: name, main and side road width, surface; *Paste JSON from
     clipboard* (creates the preset at once from `dfhack.internal.getClipboardTextCp437`);
     *Create district*; *Add blueprint* (to the selected district, or as an alternative of
     the selected blueprint, or as a hallway piece); *Remove selected*; the settings of the
     selection (district: weight, margin, max length, depth, suite, shared walls;
     blueprint: weight, setback, per-district max, optional and its max); *Different
     second pass* (splits column two, bottom half is the fill list, starting as a copy);
     *Add hallway blueprints* (splits again, bottom third is the road-stamp list);
     *Save preset*, *Cancel*.
  2. the passes: first pass districts with their blueprints as chips (dashed = optional,
     indented = alternative), then the second pass and the hallway blueprints when
     enabled, each section scrollable and of equal height.
  3. the blueprint library, filtered by what is being edited: rooms when a pass, district
     or room is selected, hallway pieces when the hallway section is. Rooms are typed from
     the furniture they place (bedroom, office, dining room, tomb, temple, meeting area,
     multi, other; an altar makes a temple, pedestals mark a meeting area, statues count
     only when nothing else defines the room, all floors count) and listed in that order,
     then surface blueprints (a built wall in a corner) in the same order as "surface
     bedroom", "surface office" and so on; by name within a type. Clicking a selected
     entry adds it: to the selected district, as an alternative of the selected blueprint,
     or, with only a pass selected, in a new district named after it.
- **Copy preset JSON** puts the current preset on the clipboard, so presets travel as text.

Roads of any width from 1 to 5 are valid, even widths included.

## 5. Demand

Each stamp has a `demand` oracle; the pump asks each oracle "how many more of you?" and
opens that many rooms, nearest-to-entry first, plus **10% spare** (rounded up, minimum 1)
so a migrant wave never waits on miners.

| oracle | count = | notes |
|---|---|---|
| `bedroom` | citizens with no owned bedroom, minus rooms already open and unowned | solid; measured in the test fort |
| `noble` | positions whose holder lacks a room of that type meeting `required_bedroom/office/dining` value | thresholds are values, not counts; needs a room-value read per holder |
| `manual` | whatever the user asks for in the GUI ("open N") | guildhalls and temples until a petition oracle is confirmed |
| `all` | everything at commit | for people who just want the district dug |

Guild/temple petitions: not found in the sampled agreements. Ship `manual` and look for a
live petition later; do not promise the oracle first.

**Opening a room** = start a `fort/quickfort` job for the stamp at its anchor with its
rotation, plus a road job for the shortest road-graph path from an entry to its frontage
that is not already dug. Jobs are tagged with the plan id and room index so the GUI can
show them grouped.

## 6. Persistence and progress

Site data under `burrow-stamper`, one record per plan:

```
{burrow_id, z, preset, seed, params, entries,
 rooms = [{stamp, rot, anchor, entrance, state = planned|open|done}],
 roads = [cells], generated_at}
```

The layout is stored explicitly, not replayed from the seed: the stamp library can change
between sessions and a replay would silently move rooms. Room state is *derived* from the
map and quickfort's job list on load, the same way quickfort does it, so the stored record
cannot disagree with the world. A plan whose burrow no longer exists is dropped on load.

## 7. Delivery phases

**Phase 0 — `fort/quickfort` prerequisites**
- `start_job(entry, pos, {transform = ..., data = ..., tag = ...})`: rotation/flip passed
  through to `process_section` (currently `nil` at the call), in-memory data jobs for
  roads, and a tag for grouping. Check first that stock `apply_blueprint` honours
  `transform`; if it does not, rotate the parsed grid in `build_plan` instead.
- Footprint/entrance inference as an exported helper, so the stamper and the picker share it.

**Phase 1 — shipped as `fort/builder-burrow` (packer port, picker, apply now).**

**Phase 1 (original) — scan, pack, preview. No digging.**
- `fort/burrow-stamper` opens a window: burrow list → preset → params (spine, width,
  margin, seed) → *Plan*. Frame-paced scan and pack, preview overlay on the map (roads one
  colour, each stamp its own, entrances marked, shells dotted), the §4.6 report, *Reroll*.
- Ships first so layouts can be judged on a real burrow before anything commits.

**Phase 2 — commit and lazy digging.**
- *Commit* stores the plan. Pump overlay runs the oracles, opens rooms, digs roads on the
  way. Plan list view with per-room state and *Open N* / *Cancel plan*.
- `bedroom`, `manual`, `all` oracles.

**Phase 3 — districts, presets, editor, starter library** (the editor of §4b).
- The districts and presets of §3, the starter stamps (`hovel-1x4`, `house-2x2`,
  `house-3x3`, `luxury-3x3`, `noble-dining`, `noble-bedroom`, `noble-office`,
  `noble-tomb`, `statue-row-13x3`, `statue-garden-7x7`, `catacomb-7x9`, `memorial-5x5`,
  `family-3x5`, `coffin-row-13x3`, `shrine-5x5`, `guildhall-7x7`, `temple-7x9`,
  `temple-5x5`, `cottage-5x5`, `longhouse-5x7`) as ordinary quickfort csv files, district
  and preset editor in the GUI (add one stamp, add every stamp in a folder, weights,
  per-district margin and corridor width, road stamps), manifest editing for entrance
  overrides. Any user blueprint can be dropped into a district: footprint and door are read
  from the csv the same way.
- `noble` oracle.

**Phase 4 — surface mode, multi-z stamps and re-plan.**
- `surface: true` free-tile test, roads as constructed road/floor, angled connectors, the
  town districts (bungalows, thin and big townhouses with shared walls and setbacks, farms,
  manors), multi-floor stamps applied per z by quickfort with their own stairs, §4.9
  re-plan on burrow edit.

**Later, not promised:** multi-z with stairwells; petition-driven guildhalls/temples;
treating the stamper as a component an AI player calls with "I need N more bedrooms".

## 8. Decisions taken

1. **Walls rule** (§1): stamp owns interior, packer owns shell, `margin` per stamp.
   Housing 3x3 ships with `margin 1` so engravings always credit one room.
2. **Entry** (§4.2): always inferred.
3. **Spare rooms** (§5): 10% over demand.

## 9. Before writing Lua

The packer is prototyped as a throwaway browser mockup (not committed) so layouts can be
judged on synthetic burrows first: presets, burrow shapes, road width, cell size and seed
as controls, the district and stamp JSON editable in place, and the §4.7 report per layout.
§3 and §4 describe what that mockup does now. Known limits it shows: a 3-wide main road
cannot grow through a cave-shaped burrow's narrow throats, so presets with 3-wide roads
place little there; growth is bounded by a depth budget from the entry rather than by
filling the burrow, so a large burrow needs a bigger budget or several entries; and the
altar and bookcase build codes are placeholders until checked against quickfort's alias
list.
