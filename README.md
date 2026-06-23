# dfhack-commands

A personal pack of DFHack scripts for Dwarf Fortress (v50 / DFHack on Steam).

Scripts live in `dfhack-config/scripts/`. Copy them there (or symlink) and they
become commands. This repo is the source of truth — see **Status & TODO** below
so in-progress work doesn't get lost.

## Quick start

```
magnus-scripts          # turn on all the always-on helpers (see below)
```

Add `magnus-scripts` to `dfhack-config/init/dfhack.init` to enable everything
every session.

`magnus-scripts` runs/enables the persistent helpers only:
`needs-tomb-notification`, `mandate-notification`, `raid-notification`,
`enable auto-mandate`, and `military-uniforms` (creates the steel uniform
templates + registers the Equip-screen auto-gear overlay; the gear-order service
itself stays off until you toggle it on that screen). It does **not** enable
`no-pausing` (that stops *all* pausing — manual toggle).

`magnus-scripts lovely` *also* sets two standing orders (no automatic weaving, no
automatic web collection) and enables a batch of stock DFHack tools —
`enable`: autobutcher, autoclothing, autonestbox, autotraining, prioritize,
seedwatch, suspendmanager, timestream; `tweak`: fast-heat, realistic-melting. The
timer-driven ones (autocheese/automilk/autoshear/cleanowned/orders-reevaluate)
aren't plain enables — turn those on in `gui/control-panel`.

---

## Commands

| Command | Type | Status | What it does |
|---|---|---|---|
| `magnus-scripts` | one-shot | ✅ done | Enables all the always-on helpers at once |
| `destroy-forbidden` | one-shot | ✅ done | Destroys loose forbidden items on the ground (skips inventory/buildings/artifacts) |
| `clear-flows` | one-shot | ✅ done | Wipes airborne flow clouds (miasma/smoke/…) — miasma FPS fix. `clear-flows Miasma Smoke` to filter |
| `needs-tomb-notification` | register | ✅ done | Notify-panel alert for dead dwarves with no tomb; click → list of dead + cause of death + memorial-slab button |
| `mandate-notification` | register | ✅ done | Shows mandates the moment they exist (overrides built-in `mandates_expiring`) |
| `raid-notification` | register | ✅ done | Notify-panel entry for squads out raiding (rough ETA / "back any minute now") + weekly auto-unstuck |
| `auto-mandate` | enableable | ✅ done | Queues manager work orders for Make mandates using cheap renewable materials |
| `no-pausing` | enableable | ✅ done | Forces the game to never pause (overrides GUIs/events). Manual toggle |
| `raid-status` | one-shot | 🟡 partial | Reports raiding parties (leader/target/goal/time-gone + rough travel estimate); auto-retrieves stuck units. **Planning-screen overlay TODO** |
| `squad-buttons` | overlay | ✅ done | Squads-screen buttons: "Select all/no squads" (always), + "Target all invaders"/"Target all hostiles" while giving a kill order (native targeting; confirm as normal) |
| `attack-invaders` | one-shot | 🔴 superseded | Direct kill-orders don't make squads engage. Use `squad-buttons` instead |
| `dfhack-stocks` | overlay+menu | 🟡 on hold | Searchable/filterable item designation menu (origin/exotic/rarity filters, sorted by origin→quality→type, view/melt/forbid/dump, click-to-apply, select-all-visible); replaces the vanilla Stocks screen (Esc to dismiss). **Currently disabled & not deployed — revisiting implementation** (source kept in repo) |
| `quick-order` | overlay+module | 🟡 partial | "new order" text box on the Work Orders screen: freeform text → manager order ("3 steel swords", "four gabbro rock mechanisms", "10 raw green glass"). Fuzzy item/material resolve, magma-safe/most-in-stock picks, inserts at top. **One-time only — repeating (`r3 …`) + suggested conditions still TODO** |
| `statue-description` | overlay | ✅ done | Shows the statue's exact description + value on its building info sheet |
| `creature-description` | overlay | ✅ done | Shows the selected creature's description (bottom-left); great for forgotten beasts |
| `auto-pasture` | overlay+service | ✅ done | Graze/Scavenge pasture toggles on the pen screen; background service pens new tame animals (grazers→graze pen, others→scavenge pen) |
| `military-uniforms` | one-shot+enableable+overlay | ✅ done | Creates a "Steel - <weapon>" uniform template per typical weapon (short sword/war hammer/battle axe/spear/pick/mace/crossbow): full steel armour set + steel weapon, replace-clothing on; silver war hammer + copper crossbow w/ steel buckler. Deletes default metal uniforms (leather stays). Three toggles on the Equip screen overlay (`dwarfmode/Squads/Equipment/Default`): **Queue gear orders** (`Shift-G`) runs a daily service that, for every soldier in a squad, **self-manages a manager order per gear piece in the exact item+material their uniform specifies** (copper armour + iron sword → those orders, not just steel) — queues **one** unit only when total stock `< need` **and** a metal `BAR` of that material exists, deleting the order once the need is met so **nothing is force-produced** (DF makes an order's items on submit regardless of conditions, so we don't lean on repeating conditional orders); **Upgrade to masterwork** (`Shift-M`) makes one extra and marks inferior (non-masterwork, non-artifact) copies for melting to re-forge; **Train surplus war dogs** (`Shift-D`) war-trains adult male dogs beyond `BREEDER_MALES` (2) breeders via the Pets/Livestock `training_assignments` list (`train_war`) — verified end-to-end (an Animal Trainer turns them into `TRAINED_WAR`). State persisted per site; generic per world. **TODO: auto-assign finished war dogs to squad members** (squad-pet data path still being mapped). |

---

## Status & TODO (full implementation notes)

### 🟡 raid-status — planning-screen overlay still TODO

**Done (verified on a live raid):** detects active raids, reports leader, target
site, goal, time-gone, and squad count; plus a rough travel estimate; and
auto-retrieves units stuck off-map.

**Data model (verified — note: NOT `flags.player`):**
- Active raids = `df.global.world.army_controllers.all[i]` where
  `#assigned_squads > 0` and those squads belong to the fort
  (`squad.entity_id == plotinfo.group_id`). `assigned_squads` clears when the
  mission ends, so non-empty = active. The travelling army (`armies.all` with
  `controller_id == c.id`) is **NOT** flagged `player`.
- `army_controller` fields used: `year`/`year_tick` (**departure**), `goal`
  (`df.army_controller_goal_type`, e.g. SITE_INVASION), `master_hf` (leader),
  `site_id` (target → `df.world_site.find`), `assigned_squads`, `mission_report`
  (has `.title` like "Raze Clutchwheels (Set out Summer 116)", `origin_x/y` =
  target world pos, `campaigns` vector).
- Time math: 1 day = 1200 ticks, 1 year = 403200 ticks.
  `elapsed = now - (c.year*403200 + c.year_tick)`.
- **Travel estimate:** `army.pos / 48` = world tiles (verified: target world pos
  × 48 ≈ `controller.pos_x/pos_y`). Speed = distance(fort, army) / days-gone;
  one-way trip ≈ distance(fort, target) / speed. `army.travel_rate` (=16
  observed) units unconfirmed, so we use the empirical speed instead. The
  estimate is rough (assumes steady outbound travel) and labelled `~`.

**TODO:**
1. **Planning-screen overlay** — show the estimate while planning a raid. Need to
   identify the mission/raid planning viewscreen (focus string via
   `dfhack.gui.getCurFocus(true)` *while on that screen*) and its computed
   estimate, then add a DFHack overlay widget (see `gui/notify.lua` pattern).
2. Optionally verify the travel estimate against a long live raid and refine
   (direction detection: outbound vs returning — needs cross-call state).

### 🔴 attack-invaders — squads don't engage; build UI buttons instead

**Current approach (creates orders but they don't trigger attacks):**
- Targets = `world.units.active` where `isInvader` and not dead and not
  `flags1.caged`/`flags1.chained` (caged prisoners excluded — 30 of 33 were caged).
- Fort squads = `world.squads.all[i]` where `entity_id == plotinfo.group_id`
  (9 squads; `plotinfo.squads.list` was empty — use the world list).
- For each squad: clear `squad.orders`, then insert a fresh
  `df.squad_order_kill_listst:new()` with:
  - `units` — int vector of target unit ids (accepts ints)
  - `histfigs` — parallel int vector of histfig ids (or -1)
  - `title`, `year`, `year_tick`. Other fields: `flags`, `issuer_hf`,
    `recipient_hf`, `origin_army_controller`.

**Problem:** orders land on the squads (verified) but the dwarves don't attack.
Likely the squads aren't put on active duty by just adding the order (need an
alert/schedule activation), or a required field/flag is missing, or DF only acts
on kill orders created through its own targeting flow.

**Fix = UI buttons (work *with* DF's native flow):**
1. ✅ **DONE — `squad-buttons.lua`** overlay on the kill-target screen. While
   `main_interface.squads.giving_kill_order` is true (focus
   `dwarfmode/Squads/Default`), it shows "Target all invaders" / "Target all
   hostiles" buttons that append unit ids to `main_interface.squads.kill_unid`
   (verified: this marks the targets; the player then hits DF's "Confirm").
   Hostiles = `isDanger` & not `isInvader` & not `isFortControlled`.
2. ✅ **DONE — "Select all/no squads"** button (always shown on the squads
   screen, focus `dwarfmode/Squads/Default`). Toggles every entry of
   `main_interface.squads.squad_selected` (vector<bool>[9], parallel to
   `squad_id`). Lives in the same `squad-buttons.killtargets` widget,
   bottom-right (`overlay position` / `gui/overlay` to move).

**Overlay registration (learned):** a `--@module = true` script with
`OVERLAY_WIDGETS = {name=Widget}` in `dfhack-config/scripts/` is auto-discovered
on DFHack start (`script-manager.foreach_module_script` scans all script paths).
To pick it up mid-session, call `require('plugins.overlay').rescan()` from lua —
the `overlay rescan` *command* form does not work. Model: `uniform-unstick.lua`
(`widgets.TextButton{label, key, on_activate}`, `overlay.OverlayWidget`).

---

## Reference notes (shared mechanics discovered)

**⚠️ FOOTGUN — `df.global.world.items.all` is NOT "items the fort owns".** It also
lists **named artifacts and gear carried by units that aren't yours** — offsite
historical figures (their unit isn't even loaded, so `df.unit.find(holder)` returns
nil), visitors, and enemies. On one test fort that was **64 steel gear items + 95
artifacts** that don't physically exist in the fort. Naively counting stock off
`items.all` over-counts, so a "make until stock ≥ N" tool **under-produces** (it
thought 5 masterwork battle axes existed — all artifacts held by offsite figures —
and skipped forging a real one the soldier could equip). When you need "what the
fort actually has", filter each item: walk `item.general_refs`, and if there's a
`UNIT_HOLDER` whose `df.unit.find(unit_id)` is missing or `not isOwnCiv`, **skip
it** (it's carried by someone not ours). Items with no unit holder
(stockpile/building/ground) or held by your own loaded dwarves are real stock.
Separately, artifacts (`item.flags.artifact`) are quality 5 but never auto-equip
and can't be melted, so exclude them from any "masterwork available" count too.
See `military-uniforms.lua` `not_fort_stock()`.

**DFHack notify framework** (`hack/scripts/internal/notify/notifications.lua` +
`gui/notify.lua`): the notify panel (where "stranded civilians" etc. appear)
iterates `NOTIFICATIONS_BY_IDX`, gates each on `config.data[name].enabled`, calls
`notification.dwarf_fn()`, shows the returned string/text-table. To add one:
`reqscript('internal/notify/notifications')`, push an entry
`{name, version, default, dwarf_fn, on_click}` into `NOTIFICATIONS_BY_IDX` +
`NOTIFICATIONS_BY_NAME`, and set `config.data[name] = {enabled=true}` (else the
overlay nil-indexes). Re-apply on `SC_MAP_LOADED` via `dfhack.onStateChange`.
`needs-tomb-notification` adds a new one; `mandate-notification` overrides the
built-in `mandates_expiring`.

**Manager work orders** (`df.global.world.manager_orders`): `.all` is the vector,
`.manager_order_next_id` the id source. A valid order: `id`, `job_type`,
`item_type`/`item_subtype` (or -1), `amount_total`/`amount_left`, `frequency=0`,
`status.validated=true` + `status.active=true` (`status.whole==3`). Material:
`material_category.wood=true` for wood; copper = `mat_type=0, mat_index=3`
(`dfhack.matinfo.find('COPPER')`); no `stone`/`metal` category exists. **Memorial
slab** order: `job_type=EngraveSlab` (211) with `specdata.hist_figure_id` = the
dead dwarf. Item→job map and material policy live in `auto-mandate.lua` (`MAP`);
it exposes `has_order_for(m)`.

**Mandates** (`df.global.world.mandates.all`): `mode` ∈ {Export, Make, Guild};
`item_type`/`item_subtype`, `mat_type`/`mat_index`, `amount_remaining`/`amount_total`,
`timeout_counter`/`timeout_limit` (counts up to limit; `<2500` left = urgent),
`unit` (the issuing noble). Room requirements (not mandates): fort entity =
`world.entities.all` where `id == plotinfo.group_id`; `positions.own[i]` has
`required_office/bedroom/dining/tomb`; `positions.assignments[i].histfig` → unit →
`owned_buildings` (civzones).

**Stuck units / raids:** `fix/retrieve-units` is a module —
`reqscript('fix/retrieve-units')`, `.shouldRetrieve(u)` + `.retrieveUnits()`.

**No-pausing mechanism:** `df.global.pause_state = false` every graphical frame
via self-rescheduling `dfhack.timeout(1, 'frames', cb)` (frame timeouts fire even
while paused / in GUIs — verified).

**Output quirk:** `dfhack-run <cmd>` / `dfhack.run_script(...)` output sometimes
prints to the DF console, not stdout. Verify state via a follow-up
`dfhack-run lua` read.

**Overlay widgets (recap):** a `--@module = true` script with
`OVERLAY_WIDGETS = {name=Widget}` in the scripts dir is auto-discovered on DFHack
start. Mid-session: `require('plugins.overlay').rescan()` (the `overlay rescan`
command does NOT work). Position: `overlay position <script>.<name> <x> <y>`
(negative x/y = from right/bottom edge) or `gui/overlay` to drag. Model:
`uniform-unstick.lua`.

---

## Planned features (full specs — mostly need live UI inspection)

All of these are GUI features. Each needs the relevant viewscreen opened so the
focus string (`dfhack.gui.getCurFocus(true)`), data path, and button placement
can be confirmed before/while building.

### 🟡 dfhack-stocks — melt-focused stocks menu (ON HOLD)

**Currently disabled and NOT deployed** — the `dfhack-stocks.redirect` overlay was
disabled (`overlay disable dfhack-stocks.redirect`) and the copy in
`dfhack-config/scripts/` was deleted, so it no longer loads or intercepts the
vanilla Stocks screen. Source is kept here pending a rework of the implementation.
To bring it back: copy `dfhack-stocks.lua` to `dfhack-config/scripts/` and
`overlay enable dfhack-stocks.redirect`.

Core is functional; further polish/features (and a revisit of the redirect
approach) ongoing.

`dfhack-stocks` (or the toolbar overlay button `dfhack-stocks.button`) opens a
`gui.ZScreen` item designation menu. **Implemented:**
- Lists **all** items (`world.items.all`, skipping `garbage_collect`), built once
  per open with a per-item `pcall` guard. When **Action = melt** the list is
  restricted to metal-meltable items (`dfhack.items.canMelt`); the other actions
  list everything. **Action defaults to `view`** (view/melt/forbid/dump; view
  opens the item's sheet) — artifacts can never be melted (`canMelt` excludes
  them), so a melt-default list could never lead with the most-recent artifact.
- Rows show `M/F/D` flag tags, a quality tag, the value, `F`(foreign)/`X`(exotic)
  markers, and the **decorated description** (`getDescription(item,0,true)`).
- **Sort:** origin (foreign first) → quality (artifact→ordinary) → item type
  (alphabetical, so masterwork axes before swords) → value → newest.
- **Search** `EditField` (top-left, focused on open) drives the `FilteredList`
  text filter; **Action** cycle sits to its right; a totals label shows the count
  + summed value of the shown items.
- **Filters:** origin all/foreign/local (`item.flags.foreign`); exotic all/only/not
  (= the fort civ **cannot produce** it — subtype not in `resources.*_type`,
  diggers counted; material can't be forged into that class; or an unused metal);
  and a **rarity range slider** (Ordinary..Artifact) mirroring buildingplan's
  `RangeSlider` + min/max `CycleHotkeyLabel`s.
- **Interaction (mouse only — the search field captures the keyboard, so there
  are no hotkeys):** click a row once to select it (full description + value at
  the bottom); click it again / double-click / shift-click to apply the current
  action. Shift-click applies to the range from the anchor; **Apply to all
  visible** applies to everything shown. melt toggles via
  `markForMelting`/`cancelMelting`; forbid/dump toggle the flag; view opens the
  item sheet and dismisses the menu. After each apply the row's flags re-render
  and selection is preserved by item id.
- A three-line `Melt / Forbid / Dump` header is staggered to line up under the
  `M`/`F`/`D` flag columns. The right panel shows the expected **metal-bar yield**
  of the items currently marked for melting, grouped by metal/bar type (sorted by
  yield), using the realistic-melt formula (0.95 × forging cost − 0.10/wear; ammo
  → vanilla 30%).
- On open the **most recent artifact** (last entry of `world.artifacts.all` that
  has a movable `item`) is selected and scrolled to the top of the list; falls
  back to the newest item if no artifact is in view. Artifact rows are detected
  from that same id set (so they rank above Masterful in the sort).
- No custom toolbar button. Instead an invisible overlay (`dfhack-stocks.redirect`,
  `viewscreens='dwarfmode/Stocks'`, `overlay_onupdate_max_freq_seconds=0`) fires
  the instant the player opens the **vanilla Stocks screen**: it sets
  `main_interface.stocks.open=false` (the safe close idiom DFHack itself uses) and
  pops our window on the next frame via `dfhack.timeout`. Esc dismisses our window
  back to normal play — it does not reopen the vanilla screen.
  - NB: never force `stocks.open=true` from a script to *open* it — that bypasses
    DF's initialization of the stocks lists and crashes the game. The redirect
    only ever closes it, in response to DF legitimately opening it.

Original spec (for reference):

A "DFHack stocks" overlay button rendered **above the vanilla Stocks button**;
clicking it opens a searchable/filterable menu (styled like `gui/trade` /
`gui/sitemap`) for picking items — primarily to melt.

Menu behavior:
- **On open:** the search field is immediately focused, and the **most recent
  artifact is selected with its description shown**.
- **Click an item row** → show its description
  (`dfhack.items.getReadableDescription` / `getDescription`).
- **Foreign / locally-produced** filter — `item.flags.foreign` (true = foreign;
  false = made locally). Cycles all / foreign-only / local-only.
- **Exotic toggle (3-state):** include (all) → **only** exotic → **not** exotic.
  "Exotic" = weapons/armor dwarves can't normally use. *Detection TBD* (item
  subtype not usable by the fort race / wrong size) — verify live.
- **Action cycle toggle:** focus → melt → forbid → dump.
  - **focus** = "Focus on Item's Sheet": `main_interface.view_sheets` —
    set `active_sheet` to the ITEM type + `viewing_itid = item.id`
    (`df.view_sheet_type`, -1..7; confirm exact open call live).
  - **melt** = `dfhack.items.markForMelting(item)` (`cancelMelting`, `canMelt`).
  - **forbid** = set `item.flags.forbid`. **dump** = set `item.flags.dump`.
  - melt/forbid/dump support multi-select (apply to all selected; the latest
    click wins). focus acts on the focused row only.

Verified mechanics: `flags.melt/forbid/dump/foreign/artifact`;
`dfhack.items.markForMelting/cancelMelting/canMelt`; `world.artifacts.all`
(most-recent = last entry, id 472 now); `view_sheets.viewing_itid`;
`items.getDescription/getReadableDescription`.

**Needs live UI:** the bottom toolbar viewscreen + Stocks-button position (for
the overlay button); exotic-detection method; the exact focus-on-sheet call.

### ✅ statue-description (DONE)

Overlay on `dwarfmode/ViewSheets/BUILDING/Statue` showing the statue's **exact
prose description + value**. DF generates the prose on the fly (not stored on the
item) into the single global buffer
`view_sheets.raw_description`, and ONLY while an *item* sheet is showing -- the
building sheet does NOT populate it for the statue (it's left stale from the last
item sheet viewed).

So the overlay fetches it itself: the first time a statue is selected, it flips
`view_sheets` to the contained item (`active_sheet=ITEM`, `active_id=item.id`,
push `viewing_itid`), waits a frame or two for DF to regenerate
`raw_description`, reads it, then flips back (`active_sheet=BUILDING`,
`active_id=bld.id`). Driven by `dfhack.timeout(n,'frames',...)` so it works while
the item sheet is briefly shown. Results are cached by item id -- **the cache is
the loop guard** (each statue fetched once; a `fetching` flag prevents
re-entry). Brief 1-2 frame flash on first view of each statue. Value via
`dfhack.items.getValue` on the contained STATUE item. Cache cleared on
`SC_MAP_UNLOADED`. This fetch-and-cache trick generalises to any ViewSheets prose.

### ✅ creature-description (DONE)

Overlay on `dwarfmode/ViewSheets/UNIT` showing the selected creature's
description in a wrapping block, bottom-left. Source:
`world.raws.creatures.all[u.race].caste[u.caste].description` (readable from any
tab — it's creature-raw data). For forgotten beasts / titans / generated
creatures this is the full generated flavor (body, materials, special attacks);
for ordinary creatures it's the species blurb.

Note: the Health tab's *individual* appearance text (hair styling, scars, the
attribute-traits sentence) is generated live on render and is NOT exposed
(no `view_sheets` buffer, no `dfhack.units` generator) -- so this uses the
caste description instead, which is what's accessible and is the useful part for
beasts. (Attribute-traits like "incredibly quick to heal, susceptible to disease"
could be reconstructed from `unit` attributes if wanted.)

### ✅ auto-pasture (DONE)

Overlay `auto-pasture.pasture` on `dwarfmode/Zone/Some/Pen` with two
`ToggleHotkeyLabel`s — **Graze pasture** (Ctrl+G) and **Scavenge pasture**
(Ctrl+R) — rendered at default pos `{x=7,y=17}`, **directly below** the
`zone.pasturepond` overlay (which sits at `{x=7,y=13}`, h=4, holding "DFHack
assign" + "DFHack autobutcher"). Toggling marks the current pen as the
graze and/or scavenge pasture (both allowed, even the same pen); the overlay
`render()` reflects each pen's current designation. A background service then
pens **new** tame fort animals: grazers → the graze pen, non-grazers → the
scavenge pen.

**Verified mechanics (live):**
- Current pen = `df.global.game.main_interface.civzone.cur_bld`
  (a `building_civzonest`, `.type == df.civzone_type.Pen`).
- Grazer test: `dfhack.units.isGrazer(unit)` (matches `caste.flags.GRAZER`).
  Pasturable: `isFortControlled` + `isAlive` + `isAnimal` + not `isMerchant`.
- "Unpastured" = no `BUILDING_CIVZONE_ASSIGNED`, `CONTAINED_IN_ITEM`, or
  `BUILDING_CHAIN` general_ref.
- **Assignment API** (mirrors `plugins.zone` `attach_to_zone`, verified with a
  live assign+rollback): `df.new(df.general_ref_building_civzone_assignedst)`,
  set `.building_id = pen.id`, `unit.general_refs:insert('#', ref)`, then
  `utils.insert_sorted(pen.assigned_units, unit.id)`. Both the ref and the
  pen's `assigned_units` list update.
- **Respects manual removal:** a session `known` set marks every animal once
  it's been seen pastured or auto-assigned, so an animal you deliberately
  unpasture is not re-grabbed. First enable does an initial sweep of all
  currently-roaming animals.
- Designated pen ids + enabled state persist via
  `dfhack.persistent.saveSiteData('auto-pasture', ...)`. Setting a pen via the
  overlay auto-starts the service; `enable/disable auto-pasture` also works.
  Stale (deleted) pen ids are forgotten on the next cycle. `repeat-util`
  `scheduleEvery(1,'days')` drives the watcher.

---

## 📋 Planned / TODO (requested, not yet built)

These need the fort loaded + the relevant screen open to nail down the
viewscreen focus strings and data structures before building.

### labor-screen "hide military" filter button
A button on the labor / Work Details assignment screen that filters **military
units out** of the unit list, so you only assign labors to civilians.
- **Focus string (found):** `dwarfmode/Info/LABOR/WORK_DETAILS` (`/Default`).
- **Model on:** DFHack `sort` plugin's `WorkDetailsOverlay`
  (`hack/lua/plugins/sort.lua` ~line 1000–1306) — it already adds search +
  filters (e.g. `labor_conflict only/exclude` via `has_labor_conflict(unit)` and
  `filter_matches`) to this exact screen. Add a "hide military" cycle the same
  way, filtering rows where `unit.military.squad_id ~= -1`. Coordinate with /
  extend the sort overlay rather than stacking a conflicting one.
- Still needs the fort loaded to confirm the unit-list path and that a second
  overlay doesn't fight the sort plugin's own filtering before shipping.

### auto-create labor groups (Work Details)
One-shot/command to create Work Details (labor groups) for each of:
stone carving, metal crafting, weaponsmithing, armorsmithing, carpentry, stone
crafting, glass making, brewing, cooking, jewelry — each with the matching
labor(s) enabled. Work Details live in
`df.global.plotinfo.labor_info.work_details` (verify); create one per type with
its `allowed_labors` set.

### 🟡 work-orders quick text input ("3 steel swords") — PARTIAL (`quick-order.lua`)

**Built (one-time orders):** the `quick-order.entry` overlay "new order" box on
`dwarfmode/Info/WORK_ORDERS/Default` (auto-focused, right of the DFHack search);
parse (digits/spelled/rN, fuzzy item+material split), all three material kinds
(category/concrete-class/specific), magma-safe + most-in-stock (non-economic,
capability-filtered) picks, raw-glass colour items, and `create_order` inserting
a one-time `manager_order` at the **top** of the list. Verified live.
**Still TODO:** repeating orders (`r3 …`) + suggested conditions (Phase 5 below).

**Goal:** a text field on the Work Orders screen that turns freeform text into a
manager order.
- `3 steel swords` → **one-time** order, 3× steel short sword.
- `r3 steel sword` (leading `r`) → **repeating** order, 3× steel short sword,
  with **all suggested conditions** added.
- `four gabbro rock mechanisms` → **one-time** order, 4× mechanisms made
  specifically of **gabbro** (a *specific* stone, not generic "stone"); "four"
  parses as 4, the filler word "rock" is tolerated.
- `magma safe rock mechanism` → 1× mechanism of a **magma-safe stone**. Here the
  material part is a multi-word **property constraint** ("magma safe"), not a
  material name — the resolver must (a) split the property+category descriptor
  from the item name, and (b) pick a concrete material satisfying the constraint.
- Ambiguous or unresolvable → **fail**, create nothing, report why.

**Implementation approach — UI automation is allowed and is the recommended path
for conditions.** Rather than hand-build `manager_order` + `item_conditions`,
the resolver can *drive DF's own "add work order" flow* (navigate the add-order
viewscreens via simulated key input, picking the same item → material → quantity
→ repeat → "add suggested conditions" the player would) — fast, and it produces
exactly what DF would, so **suggested conditions come for free**. SAFETY: only
feed keys to DF's *native* viewscreens (`gui.simulateInput` / `feed_key`); never
force `breakdown_level`/dismiss on a lua viewscreen (that crashes DF). Direct
struct-building (below, proven by auto-mandate) stays the simple path for
one-time orders where conditions aren't needed; pick per case.

**Reuse:** `auto-mandate.lua` (order construction + job/material `MAP`),
`dfhack-stocks.lua` (`material_can_make`, civ metals), DFHack `orders.lua`
(item_conditions construction in its JSON import = the model for conditions).

**Verified data:** `df.manager_order` fields = `job_type, item_type,
item_subtype, mat_type, mat_index, material_category, amount_total, amount_left,
frequency, item_conditions, order_conditions, status, id, reaction_name, …`.
Conditions live in `item_conditions`. (auto-mandate already builds & inserts
orders; this extends it with parsing + conditions.)

**Phase 0 — UI (needs fort loaded to confirm).** Overlay on the Work Orders
screen (focus `dwarfmode/Info/WORK_ORDERS`, verify `/Default`): an `EditField`
for the text + a status line for the parse result / error. Enter = parse →
resolve → create or report. Register like dfhack-stocks/squad-buttons.

**Phase 1 — parse.** Trim; leading `r`/`R` → repeating; amount = first integer
**or spelled-out number** (`one`..`twenty`, `a`/`an`→1, default 1); rest =
description tokens; normalize plural→singular (`swords`→`sword`,
`mechanisms`→`mechanism`); drop only true fillers (`made`, `of`). NOTE: `rock`/
`stone` is **not** filler — it's the stone-*class* signal (`stone` is not a
material; see Phase 2/3), so keep it.

**Phase 1b — split material vs item, FUZZILY (the hard split).** The whole thing
must be a **fuzzy finder**, so partials like `rock short s` or `wood bed` resolve.
Boundary can't be found by position, and item words may be abbreviated, so:
- Try **every split point**; for each, fuzzy-score the left tokens as a material
  descriptor and the right tokens as an item name; combine the two scores.
- Fuzzy match = per-token prefix/abbrev (`short s`→`short sword`, `bed`→`bed`)
  + substring + edit-distance, case-insensitive, plural-folded.
- Pick the split with the best combined score. If the top two candidates resolve
  to **different items** with comparable scores → ambiguous → fail (list them).
- Examples: `magma safe rock | mechanism`, `gabbro rock | short sword`,
  `rock | short s`(→short sword), `wood | bed`.

**Phase 2 — vocabularies (built once, cached).**
- *Items:* name → `{job_type, item_type, item_subtype}`. Weapons+diggers from
  `world.raws.itemdefs.weapons` (`name`/`name_plural` → `MakeWeapon`+subtype);
  armor/helm/pants/gloves/shoes/shield from their itemdefs; ammo, tools,
  trapcomps, instruments likewise; fixed-job furniture/crafts (door→ConstructDoor,
  mechanism→ConstructMechanisms …) from auto-mandate's `RAW`.
- *Materials — three kinds (this is the key model fix):*
  1. **Category materials** = the real `job_material_category` flags (verified, 14
     of them: `plant, wood, cloth, silk, leather, bone, shell, soap, tooth, horn,
     pearl, yarn, strand`). For these, the order just sets
     `material_category.<x> = true` (any of that class) — e.g. `wood bed` →
     `material_category.wood`. **There is NO `stone`, `metal`, or `glass` flag.**
  2. **Concrete-only classes** = `stone`/`rock`, `metal`, `glass`. These are NOT
     order materials — a bare class word must be resolved to a **specific**
     `{mat_type, mat_index}` (Phase 3), defaulting to the most-numerous in stock.
  3. **Specific materials** = a named inorganic/glass: from all
     `world.raws.inorganics` (`.id`→`{0, idx}`: `gabbro`, `granite`, `steel`,
     `iron` …) and glass types (`clear/green/crystal glass`). A specific name
     beats a bare class. (Inorganic raws need the loaded world; empty at title.)
- *Material properties (constraints, not names):* a small phrase table —
  `magma safe`/`magma-safe`, `fire safe`/`fireproof`, maybe `noneconomic`. These
  **filter** the candidate concrete materials, they don't name one. Magma-safe =
  the material's heat points are above magma temp (`material.heat.melting_point`,
  `boiling_point`, `ignite_point`, `heatdam_point` all `> 12000`, the `NO_MELT`/
  unset sentinel counts as safe); fire-safe = above ignite. (Confirm the exact
  magma-temp constant + field names live; `dfhack.matinfo` may expose a helper.)
  **Only ~⅓ of stones are magma-safe**, so this filter is significant, not a
  near-no-op.

**Phase 3 — resolve the material descriptor** (item already matched in 1b).
1. Pull any **property phrases** out first (`magma safe`, `fire safe` …) → a set
   of constraints; remove those tokens.
2. Classify what remains: a **category flag** (wood/cloth/leather…), a **concrete
   class** (stone/metal/glass), and/or a **specific material** name (gabbro,
   steel), preferring specific > class > category.
3. **Produce the order's material:**
   - category flag (no constraint) → set `material_category.<x>` (e.g. `wood bed`
     → any wood). (Constraints rarely apply to these.)
   - specific material → use its `{mat_type, mat_index}`; if it violates a
     constraint (`magma safe <unsafe-stone>`) → fail.
   - concrete class (`stone`/`metal`/`glass`), with or without constraints → take
     that class's candidate materials, filter by the constraint(s), and pick one
     concretely: **the type the fort has the most of in stock**
     (boulders/bars/etc.). So `rock short sword` → your most-numerous stone;
     `magma safe rock mechanism` → your most-numerous **magma-safe** stone. If
     none qualify → fail ("no magma-safe stone in stock").
4. Validate the item+material combo with `material_can_make` (a mechanism wants a
   hard stone/metal; reject e.g. cloth) — bad combo → fail.

Note: DF's add-order material picker has no "magma-safe"/most-in-stock filter, so
the **concrete-class + constraint case needs this direct resolution** (we pick
the specific stone) rather than pure UI automation; UI automation still works
once a concrete material is chosen.

**Phase 4 — create order.** Build `df.manager_order` exactly like auto-mandate
(job_type, item_type/subtype per kind, mat_type/mat_index or material_category,
amount_total=amount_left=N, status.validated+active=true), assign id from
`manager_orders.manager_order_next_id`, insert into `.all`. `frequency`: one-time
vs repeating (confirm the enum value live; auto-mandate uses 0 for one-time).

**Phase 5 — suggested conditions (repeating).** Two ways, pick whichever proves
easier live:
- *(preferred) UI automation:* let DF make the order through its own add-order
  flow (see Implementation approach) and hit its "add suggested conditions" step
  — the conditions are then whatever DF would produce, no struct reverse-
  engineering. This is why UI automation is recommended for the repeating case.
- *(direct) replicate the struct:* create an order in-game, add suggested
  conditions, dump `order.item_conditions` to learn the exact struct, then build
  it (model on `orders.lua`'s JSON import). More work; only if UI automation is
  unreliable.
- *MVP fallback:* ship repeating orders WITHOUT conditions first (fully
  functional, just ungated).

**Open questions (need the loaded fort):** Work Orders focus string + overlay
slot; the add-order viewscreen navigation (for UI automation) **or** the
`frequency` enum + `item_conditions` struct (for direct building); tie-break
aggressiveness.

### military uniform button + auto-orders
A button (general military screen or squad equipment assignment) that:
- Creates a **default uniform per typical weapon type** — one group each of:
  short sword, war hammer, battle axe, spear, pick, mace, crossbow.
- Each uniform = **steel**: breastplate, (chain/mail) shirt, helm, gauntlets,
  greaves, leggings, high boots, shield, **+ a steel weapon of that type**.
  - Exceptions: **crossbow** uniform → **copper** crossbow + steel **buckler**;
    **war hammer** uniform → **silver** war hammer + steel shield.
- **Deletes the existing default *metal* uniforms** (leather uniforms stay).
- Also **creates/increases manager orders** for the steel (and other requested)
  items by the quantity the squad orders require.
- Live UI needed: the squad/military screen focus; reuse auto-mandate for the
  manager-order side.

**Verified data model (live):**
- **Uniform templates live on the fort entity:** `entity.uniforms` (vector of
  `entity_uniform`) + `entity.next_uniform_id`. This fort has 4: `Melee, leather
  armor` / `Melee, metal armor` / `Crossbows, leather armor` / `Crossbows, metal
  armor` — so **"delete default metal uniforms" = remove the two whose material
  is metal** (the "metal armor" ones), leaving leather.
- An `entity_uniform` has `id`, `type`, `name`, `flags`, and **7 parallel slot
  vectors**: `uniform_item_types[slot]` (`vector<item_type>`),
  `uniform_item_subtypes[slot]` (`vector<int16>`), `uniform_item_info[slot]`
  (`vector<entity_uniform_item>`). **Slots: 0=body, 1=head, 2=legs(pants),
  3=hands(gloves), 4=feet(shoes), 5=shield, 6=weapon** (confirmed from a populated
  squad uniform). Multiple entries per slot = layers (e.g. breastplate + mail).
- `entity_uniform_item` = the material spec: `mattype`/`matindex` (specific, e.g.
  `0`/steel-idx) OR `material_class` (`df.entity_material_category`: Armor=16,
  WeaponMelee=11, WeaponRanged=12, Pick=15, Leather=1, …), plus `item_color`,
  `random_dye`, `armorlevel`, `maker_race`, `indiv_choice`.
- The per-squad assignment copy is `squad.positions[p].equipment.uniform[slot]`
  (`vector<squad_uniform_spec>`); `squad_uniform_spec` =
  `{item, item_type, item_subtype, material_class | mattype/matindex, color,
  assigned[], indiv_choice}`.
- Military screens: `main_interface.squad_equipment`, `main_interface.assign_uniform`.
- Item subtypes come from `world.raws.itemdefs` (weapons/armor/helms/…); steel =
  inorganic id `STEEL` (`mattype=0`). For the steel armour set: breastplate +
  mail shirt (body), helm, gauntlets, greaves+leggings (legs), high boots, shield.

**Build order (all ✅ done — verified live against the running fort, reversibly):**
1. ✅ Build & insert ONE steel uniform template into `entity.uniforms`.
2. ✅ Generalise to the weapon group (short sword / war hammer / battle axe / spear /
   pick / mace / crossbow) with the per-weapon material exceptions (copper
   crossbow + steel buckler; silver war hammer).
3. ✅ Delete the metal templates (leather stays).
4. ✅ Auto manager orders, but **per soldier's actual uniform spec, not just steel**:
   `compute_required()` tallies every assigned squad soldier's gear by exact
   `item_type/subtype/mattype/matindex` (so copper armour + iron sword each get
   their own order); `ensure_order()` creates/reuses a **repeating Daily** order
   with conditions [item `LessThan need`, `BAR` of that material `AtLeast 1`] and
   **no fuel condition**. Verified: 9 orders for the one outfitted soldier, each
   with the right job/material/conditions.
5. ✅ Second (masterwork) toggle: `need` becomes `count+1` and `melt_inferior()`
   marks non-masterwork, non-artifact, meltable copies for re-forging. Verified
   amounts bump to 2 and melt path runs cleanly.

Both toggles live on the Equip-screen overlay (`Shift-G` queue, `Shift-M`
masterwork); a per-frame calendar-gated heartbeat (repeat-util is too coarse on
this build) re-runs the cycle ~once a game-day; state persisted per site.

**Second toggle — auto-upgrade steel gear to masterwork:** when on, continuously
churns inferior steel arms/armor into (eventually) masterwork:
- Scan for **non-masterwork, "extra" steel weapons/armor** (steel item, quality <
  Masterful, not currently equipped/assigned/reserved) and **mark them for
  melting** (`markForMelting`) — recycling the steel and giving the re-forge a
  fresh shot at masterwork.
- For each melted inferior item, **add or bump a manager work order** to re-make
  one of that exact item type+material (so the stock is replaced, not just lost).
  Reuse auto-mandate's job/material mapping + the #3 order-creation/condition
  code.
- Idempotent: don't re-mark an item already flagged, and don't pile up duplicate
  replacement orders (increment an existing matching order instead). Stop once
  everything steel is masterwork. Toggle persists with the fort.
