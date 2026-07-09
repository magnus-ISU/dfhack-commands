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
automatic web collection), enables `auto-name` (letter-per-wave migrant renamer),
applies **autobutcher embark protection** once per fort (any animal you embark
with in numbers above autobutcher's category target gets that race's target
raised to the embark count — raise-only, so your starting animals are never
butchered; later-bred surplus still is), and enables a batch of stock DFHack
tools —
`enable`: autobutcher, autoclothing, autonestbox, autotraining, burrow (auto-grow
`name+` burrows), prioritize, seedwatch, suspendmanager, timestream; `tweak`:
fast-heat, realistic-melting. The
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
| `squad-buttons` | overlay | ✅ done | Squads-screen button: "Select all/no squads" (toggles selection of every squad). (The old "Target all invaders"/"Target all hostiles" kill-order buttons were removed — `dwarf-rts`'s drag-box attack handles group targeting now) |
| `dwarf-rts` | overlay | ✅ done | RTS squad control on the Squads screen. Opening it selects all squads; keys 1-9 select a squad (press again to camera-follow its leader, then each further press follows the next member). A left-click commands the selection — attack a hostile on the tile (Shift appends), else select your own dwarf, else move there; with nothing selected the click passes through to DF. A left-drag box acts on its contents: attack hostiles within ±3 z (Shift folds them into the kill order), else select/conscript boxed dwarves (loose dwarves are drafted into a temporary "Conscription N" militia, auto-disbanded when the screen closes), else dig a box fully on stone, else chop a boxed tree. Right-click closes the window / backs out. Press-vs-drag is disambiguated so nothing fires on a plain press. **TODO:** click an individual squad member to open their unit sheet |
| `labor-groups` | one-shot | ✅ done | Orders the Labor screen and creates any missing crafting Work Details (stone carving, metal/weapon/armour smithing, carpentry, stone/glass crafting, brewing, cooking, jewelry, + a group for every remaining moodable skill) — **non-destructive**: reorders details and refreshes icons, never deletes or reassigns, only creates ones that don't exist. Layout: dig/grow defaults first, crafts next, Cook/Brewer then Military last. `labor-groups` / `labor-groups dry` / `labor-groups once` |
| `quick-order` | overlay+module | ✅ done | "new order" text box on the Work Orders screen: freeform text → manager order. Matches **every orderable job** — fort-permitted reactions, furniture, weapons/armour by subtype, and collection/processing jobs (collect webs/clay/sand, butcher, mint coins, make charcoal/ash/lye/potash, …) — with material + **legality** resolution (magma-safe, most-in-stock, CAN_STONE weapons; rejects impossible combos like obsidian shoes / iron cloaks). `r`/`rN` prefix → **repeating "keep N in stock"** order: checked **daily** but gated on a stock condition so it only runs while you have fewer than N of the **output** item (any material, matching subtype — never counts the inputs); jobs with no single countable product (collect sand, mint coins, butcher…) fall back to a monthly repeat. Amount as digits or a spelled number. Live autocomplete lists the legal matches one per row; Esc unfocuses; inserts at the top of the list |
| `statue-description` | overlay | ✅ done | Shows the statue's exact description + value on its building info sheet |
| `civ-alert-notification` | register | ✅ done | While the **civilian alert** is on, notify-panel warning `N citizens outside the fortress` — fort civilians (non-soldiers) whose tile isn't inside the alert's burrow(s). Clears when everyone's in or the alert is off; click cycles/zooms to each straggler. Gate: `plotinfo.alerts.civ_alert_idx` → active alert with ≥1 burrow (the "No alert" entry has none); inside-test via `dfhack.burrows.isAssignedTile(burrow, unit.pos)` |
| `creature-description` | overlay | ✅ done | Shows the selected creature's description (bottom-left); great for forgotten beasts |
| `auto-name` | enableable+service | ✅ done | Renames each migrant's FIRST name so a whole wave shares a starting letter — wave 1→A, wave 2→B, … (wraps after Z), each name unique within the wave and gender-correct. Names come from `dfhack-config/auto-name-names.txt` (editable: male block, blank line, female block; ~1390 mixed Greek/Roman/Norse/medieval names). Skips the original 7, nicknamed dwarves, and fort-born kids; waves grouped by the real in-game arrival event so grouping is exact. Works on an already-running fort (one-time retroactive pass, then watches for new waves); re-running does nothing already-handled. `enable auto-name` / `auto-name` / `auto-name scan` / `auto-name status` |
| `binnable-stockpile` | overlay | ✅ done | Buttons bottom-left of the stockpile customize screen, each toggling only its own group so they compose: **all binnables** (`Ctrl-B`) overwrites the pile to the container categories (Ammo/Armor/Bars/Cloth/Coins/Finished goods/Gems/Leather/Sheets/Weapons), or toggles them off if already full — and resets their quality to "all"; **all food** (`Ctrl-F`) = everything edible except seeds and drinks, with the Extract (animal) category trimmed to just milk + honey (rest is procedural venom/extract clutter); **all drink** (`Ctrl-D`) = Drink (plant)+(animal); a **quality** tri-state (`Ctrl-Q`: all / masterwork / inferior) over armour/finished goods/furniture/weapons. Also: click an already-selected main category — or a middle-column sub-category — again to toggle it all on/off. Uses `cat_*.dfstock` presets + direct edits |
| `auto-pasture` | overlay+service | ✅ done | Graze/Scavenge pasture toggles on the pen screen; background service pens new tame animals (grazers→graze pen, others→scavenge pen); overcrowding notify-panel warning whose click cycles/zooms/selects each overcrowded pen and opens its repaint UI |
| `mood-burrow` | overlay+service | ✅ done | `[Mood burrow: <name>]` selector (top right of the burrow screen, click to cycle none→each burrow→none): a dwarf struck by a strange mood (fey/secretive/possessed/macabre — NOT fell) is confined to that burrow until the **first item** of the creation is claimed (first item = artifact base material, so a burrow with the forge + only steel bars ⇒ steel artifacts), then released to gather the rest anywhere. Burrow's unit list is fully managed (don't hand-assign to it); designation persists with the fort |
| `training-barracks` | overlay+service | ✅ done | `[Basic training]` toggle on the Barracks zone screen: marks THIS barracks as the fort's basic-training barracks — every fort squad (current and future, via a background service) is assigned to **train** there, on both sides of the link (`squad.rooms` + `zone.squad_room_info`), touching only the train flag. Never designated automatically; toggling off stops future assignment but leaves existing ones. Designation + enabled state persist with the fort |
| `embark-prep` | overlay | ✅ done | Embark "Prepare carefully" Dwarves tab (`setupdwarfgame/Dwarves`): three buttons that give the **selected** dwarf 1 point in each skill that affects an office — Manager→Organizer (`Ctrl-M`), Bookkeeper→Record Keeper (`Ctrl-K`), Broker→Appraiser+Comedian/Flatterer/Intimidator/Judge of Intent/Liar/Negotiator/Persuader (`Ctrl-B`, 8 picks) — skills already ≥1 aren't re-bought; overspending the 10-pick budget still sets the skills but is reported. Plus a **Preferences window** (lower-left) listing the selected dwarf's likes (materials/creatures/foods/items/plants/colors/shapes/art forms), updating with the selection. Data: `viewscreen_setupdwarfgamest.dwarf_info[selected_u].skilllevel[job_skill]` (0-5, each level = 1 of `skill_picks_left`); prefs via `s_unit[selected_u].status.current_soul.preferences` (NB fish/egg food prefs put the creature race id in `mattype`, `matindex=-1`; `dwarf_info.name` is empty pre-embark — use the unit) |
| `embark-nobles` | one-shot | 🔴 **UNFINISHED — not in the pack** | Meant to fill **vacant** key fort positions by skill (chief medical dwarf, militia commander, broker, manager, bookkeeper, + expedition leader as a separate dwarf). **Removed from `magnus-scripts`** — it appears to interfere with position assignments and needs rework. Run `embark-nobles` by hand only if you want it (`embark-nobles dry` previews). **TODO: fix the assignment interference.** |
| `inside-burrow` | enableable | ✅ done | Armed at embark (via magnus-scripts): when the fort has **no burrows yet**, watches for the **first tile any miner digs out** and seeds a one-tile burrow named `inside+` there, then disables itself. The trailing `+` makes DFHack's `burrow` plugin auto-expand it as you keep digging, so it grows to cover the whole fort interior. Does nothing if any burrow already exists. `inside-burrow status` reports state |
| `military-uniforms` | one-shot+enableable+overlay | ✅ done | Creates a "Steel - <weapon>" uniform template per typical weapon (short sword/war hammer/battle axe/spear/pick/mace/crossbow): full steel armour set + steel weapon, replace-clothing on; silver war hammer + copper crossbow w/ steel buckler. Deletes default metal uniforms (leather stays). Three toggles on the Equip screen overlay (`dwarfmode/Squads/Equipment/Default`): **Queue gear orders** (`Shift-G`) runs a daily service that **self-manages a manager order per gear piece in the exact item+material each soldier's uniform specifies**, queuing **one** unit at a time and deleting orders once met so **nothing is force-produced**. It forges **one soldier's set at a time, per metal** (steel finishes one soldier while silver/copper independently progresses another — so full sets, breastplates included, actually complete), **serves dwarves in the "Military" work detail first**, and **keeps 3 bars of each metal in reserve** for moods/other jobs. **Iron/copper backup stock** (the uniform is never edited): gear is made in the uniform's metal (steel), but whenever the soldiers don't have enough wearable pieces for an armour slot in the backup metal (desired steel + backup stock < the number who need it), it also stocks a backup version of that piece — **IRON** when there's iron to spare after the steel still owed (else **COPPER**) — (**armour, shield, and weapon** — a cheap weapon beats an empty hand; pieces already in the backup metal are skipped, and the **leather cloak is never metal-backed**, it's always leather) so nobody's left naked or unarmed. **Not gated on steel supply** — even while steel is slowly forging, the backup metal fills the gap; it stops once steel+backup covers everyone. Soldiers choose what to wear themselves. **Gear is SIZED per wearer:** a non-dwarf soldier (e.g. a human mercenary) gets armor forged to their size by setting the manager order's `specdata.race` to their race; requirements and stock are tracked per size (via each item's `maker_race`), so dwarf-sized armor never counts as covering a human, and their iron/copper backups are sized too. **Gauntlets and high boots are targeted as pairs (2 per soldier); gauntlets are handed, so it requires one masterwork of EACH hand (left+right), while boots need any 2 masterwork.** **Upgrade to masterwork** (`Shift-M`) upgrades **every soldier's pieces in parallel** (not one soldier at a time — so a later soldier's shield isn't blocked behind an earlier soldier's hard-to-masterwork gauntlet), and each cycle **melts enough surplus inferior copies to cover the masterwork shortfall** (out of bars → recycle the extras into bars; clears forbid so they actually melt). **Forge Steel Tools** (`Shift-P`, default OFF) keeps one steel pick per miner (Mining-labor dwarves) **and one steel axe per woodcutter** in stock — excluding military fighters, so squad-held picks/axes aren't miscounted — one at a time, honouring the masterwork toggle and recycling surplus steel gear into bars when out of steel. **Train surplus war dogs** (`Shift-D`) war-trains adult male dogs beyond `BREEDER_MALES` (2) breeders via the Pets/Livestock `training_assignments` list (`train_war`) — verified end-to-end (an Animal Trainer turns them into `TRAINED_WAR`). State persisted per site; generic per world. **TODO: auto-assign finished war dogs to squad members** (squad-pet data path still being mapped). |
| `military-labor` | enableable+service | ✅ done | Daily, keeps the **"Military"** Work Detail's members in sync with your squads — adds new soldiers, drops those who leave. Excludes DFHack-autotraining non-leaders and off-duty squads, so the detail tracks your real standing military. Pairs with the "Military" detail `labor-groups` creates. `enable military-labor` / `military-labor` |
| `right-click-cancel` | overlay | ✅ done | Mouse helpers for designation/build tools: **left-drag a box** applies the designation in one gesture (dig + channel/ramp/stairs, chop, gather); a plain dig box drawn entirely over removable tiles auto-becomes a **Remove**. **Right-drag** erases everything in the box (dig/chop/gather + smoothing/engraving/fortification designations & their queued jobs + in-progress buildings) with a red-X preview; **right single-click** cancels the designation/construction under the cursor. Guards keep clicks on UI/notifications from designating |
| `enemies-inside-notification` | register | ✅ done | Companion to `civ-alert-notification`: while the civilian alert is on, warns **"N enemies inside the fortress"** — invaders / dangerous creatures / agitated animals whose tile is inside the alert burrow(s), **excluding hidden and caged** ones. Click zooms to each; clears when the burrow's clear or the alert's off |
| `trader-notification` | register | ✅ done | Notify-panel countdown **"Trader is ready to trade for N days"** while a caravan is at the depot (N = the longest still-present); click zooms to the trade depot |
| `planner-orders` | register | ✅ done | Notify-panel **"N planned items have no manager order"** for `buildingplan` items nothing produces. Click walks each missing item and offers the materials it can actually be made of (generics first, then your metals/stones; magma-safe tagged/filtered); picking one creates a **daily order gated to run only while you have 0** of that item |
| `auto-tomb` | enableable+service | ✅ done | Drops a 1×1 activity zone onto furniture that needs one — a **Tomb** zone on every coffin (so it's instantly assignable) and a **Pen/Pasture** zone on every nest box (for egg-layers). Idempotent; leaves furniture that already has its zone alone. `enable auto-tomb` / `auto-tomb` |
| `statue-redirect` | overlay+enableable | ✅ done | Selecting a statue redirects you to the statue **item's sheet** (DF's full prose description; press native "View" to go back). Also adds a **Remove** button on any built item's sheet that deconstructs its building. `enable statue-redirect` |
| `item-description` | overlay | ✅ done | Redraws an item view-sheet's description in place using up to **half the screen height** — DF's own box truncates long ones (artifacts, decorated items, books, engraved slabs) to ~8 rows |
| `empty-labor-notification` | register | ✅ done | Notify-panel warning when a Work Detail is "Only Selected Does This" but has **no usable worker** (nothing selected, the selected dwarves died/left, or they're all on Military duty). Click → the offending details + their labors. The pack's "Military" detail is exempt |
| `dig-shapes` | overlay | ✅ done | RTS map interactions (overlay `dig-shapes.watcher`): **right-click** the exposed map → enter mining (Dig) mode; **shaped Dig boxes** are reclassified on completion — a 1×1×N column → staircase, a selection through open air → **real constructed walls/floors** (bottom-up), a box of only constructions → designated for **Remove**, tree tiles → chop, natural rock → ordinary mining. Guarded so clicks on panels/notifications/other overlays aren't hijacked. (Building placement moved to `dig-building`.) |
| `dig-building` | overlay | ✅ done | Companion to `dig-shapes`: while the **Dig tool is active** (normal mining mode), a **building picker** window docks on the **left** listing every buildable thing — workshops (+ farming/furnace sub-shops), constructions (wall/floor/ramp/stair/fortification/track/grates/bars/windows), doors/hatches, machines, traps, cages/restraints, military buildings, trade depot, and all furniture. Two columns, vertically **scrollable** when it overflows; the window leaves **10 rows of negative space at the top and 4 at the bottom** uncovered. Clicking an entry drives **DF's own build menu** straight to that building's **native placement action** — it drops the Dig tool, opens the build menu (`D_BUILDING`), then reads the rendered menu and injects mouse-clicks through the category→(subcategory)→building by exact button text. So you land in the exact native placement/buildingplan flow, and a **slab** gets DF's own "which slab" chooser with no buildingplan interference (no special-casing needed — native handles it). (Why drive the menu: in v50 the `HOTKEY_BUILDING_*` keys aren't wired to fed input and setting build-mode by hand opens an empty menu; clicking rendered buttons is the only path that works. Verified end-to-end via injected clicks.) |

---

## Known bugs

| Script | Bug | Status |
| --- | --- | --- |
| `dwarf-rts` | The **first time** you open the Squads screen in a session, it must be opened with the native **Squads toolbar button** — right-clicking the right-hand side of the screen won't open it that first time (it works on every subsequent open). Cause: the right-click opened the panel by flag-flipping `squads.open`, which skips DF's open logic that builds `squad_id` (empty until a native open). Fix: right-click now feeds DF's own `D_SQUADS` key so it runs the real open. | ✅ fixed (confirmed live) |

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

### Overlay registration (learned)

A `--@module = true` script with `OVERLAY_WIDGETS = {name=Widget}` in
`dfhack-config/scripts/` is auto-discovered on DFHack start
(`script-manager.foreach_module_script` scans all script paths). To pick it up
mid-session, call `require('plugins.overlay').rescan()` from lua — the `overlay
rescan` *command* form does not work. Model: `uniform-unstick.lua`
(`widgets.TextButton{label, key, on_activate}`, `overlay.OverlayWidget`).

(The old `attack-invaders` approach — directly inserting `squad_order_kill_listst`
orders — is gone: the orders landed on squads but dwarves never engaged. Driving
DF's native targeting via `squad-buttons` is the working path.)

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

### General map-click UI guard (DONE, shared) — `map_pos_if_clear`

Every map-interaction feature (squad commands, and the planned RTS mining/building
below) must route clicks through ONE guard so clicks on any UI element do the normal
thing instead of firing the script. The load-bearing signal is the STRICT
`dfhack.gui.getMousePos()` (no arg): it returns a tile ONLY over the exposed map
viewport and `nil` over ANY UI — bottom toolbar, minimap, right-side panels, open
menus/lists, designation palettes, notifications' region, etc. (The permissive
`getMousePos(true)` returns a map tile even under those, which caused the click-through.)
`dwarf-rts.lua` exposes `map_pos_if_clear(mx,my)`: returns the map pos if the click is
clear (strict getMousePos non-nil, `current_hover == -1`, and not over another DFHack
overlay via `over_other_overlay`), else nil → pass the click to DF. Applied to the squad
press-poller + onInput; reuse it for the mining/building feature.

### 🟡 RTS mining + building mode (requested, **incomplete**) — `dig-shapes.lua`

`dig-shapes.lua` handles digging and constructing walls/floors/stairs from the map. Placing
**furniture, workshops, and other buildings** is handled by its companion **`dig-building.lua`**
(the left-hand building picker — see its own entry below).

All of this lives in **`dig-shapes.lua`** (overlay `dig-shapes.watcher`), gated through
`map_pos_if_clear()` — strict `getMousePos()` is nil over any panel, `current_hover` flags DF
buttons, and `over_other_overlay()` stands off other DFHack overlays. (The old `mining-build.lua`
"Build …" button was **removed** — it didn't work.)

1. **Right-click on the map → enter mining (Dig) mode.** On `dwarfmode/Default`, a right-click
   routed through `map_pos_if_clear()` sets `main_interface.main_designation_selected = DIG_DIG`.
   Because the guard also excludes other overlays, **right-clicking a notification dismisses the
   notification** (the click passes through) instead of entering mining. Scoped to
   `dwarfmode/Default` so it never steals a right-click meant to back out of a menu/tool.
2. **1×1×N single column → staircase.** Wall tiles are carved (`designation.dig =
   tile_dig_designation.UpStair/UpDownStair/DownStair`: up at the bottom, up-down in the middle,
   down at the top); open-air tiles get a **REAL constructed stair**; tree tiles get chopped.
3. **Any selection through open-air tiles → constructed walls / floors, bottom-up.** A tile
   becomes a **WALL** if the tile directly below is a wall — natural rock **OR an already-placed
   construction wall** (so `findAtTile` sees planned walls as solid and courses stack upward) —
   otherwise a **FLOOR**. Works for flat `N×1×1` lines, tall `N×1×N` planes, etc. Open tiles are
   processed **bottom-up** (sorted by z) so each course sees the one below. Natural rock is left
   as an ordinary dig (mining); existing floors are left alone.
4. **A selection whose only contents are constructed walls/pillars → designated for removal**
   (`dfhack.constructions.designateRemove`). **Tree tiles → chop** (`designation.dig = Default`).

Constructions are **REAL, not buildingplan blueprints**: `dfhack.buildings.constructBuilding`
alone attaches a `ConstructBuilding` job with the standard "any building material" filter
(`isPlannedBuilding=false`), so dwarves build them with available materials — calling
`addPlannedBuilding` (the old code) is what made them blueprints.

The box is captured by the watcher: it tracks `selection_rect` (corner 1) + the live cursor
(corner 2) while the Dig tool is active, then on box-apply defers one frame and reclassifies
(`convert_dig_box`). **Verified via safe probes:** `constructBuilding` yields real (non-planned)
constructions; `findAtTile` sees a just-placed construction (bottom-up stacking); stair-carve
designations are correct. NOTE: the interactive box-capture + right-click paths read the OS
cursor (`getMousePos`), so they can only be fully exercised with a live cursor in-game — verify
there. `tree → chop` via `designation.dig = Default` also wants an in-game confirmation.

### ✅ dwarf-rts — RTS-style squad control (`dwarf-rts.lua`)

The DF squad UI is clunky; this makes commanding squads feel like an RTS.
**STATUS: implemented** — behaviours 1-6 below are all live (the table entry up
top describes the shipped behaviour). The one remaining TODO is clicking an
individual squad member to open their **unit sheet** (view them, not command
them). The spec below is kept for its data-model and gotcha references.

Behaviours:

1. **~~Open Squads → select all + movement mode.~~ ABANDONED.** `giving_move_order`
   *pauses the game inherently* and stays open until an order is placed/cancelled,
   so auto-arming it on open froze the fort. Replaced by click-to-move (below).
2. **Click map → move the selected squads, no paused UI. (IMPLEMENTED.)**
   On the Squads screen, a left-click on the map flicks `giving_move_order` on for
   the single frame DF needs to register the click as a move target, then a
   `dfhack.timeout(2,'frames',...)` clears it unconditionally — so the click
   commands the squads but the game is never left paused (and a closed menu can't
   strand the flag). If nothing is selected it selects all squads first. It is
   inert (`busy()`) while a kill/patrol/burrow order is being given. KEY LESSON:
   do NOT drive this from the overlay's `overlay_onupdate` — that clock stalls
   while the order-giving sub-mode steals focus, which re-fires logic and traps
   the player; use `onInput` (event-driven) and a self-clearing one-shot only.
3. **Click a hostile → attack.** A left-click on a hostile (with a squad selected,
   on the map) switches to kill mode and targets that unit instead of moving;
   **Shift** appends to the target list. **(IMPLEMENTED — sets `giving_kill_order`
   + pushes onto `kill_unid`; engage with DF's normal confirm. Entering kill mode
   pauses by DF design, unlike the flicked move mode. If closing the menu mid-
   targeting ever leaves the fort paused, add a falling-edge cleanup.)**
4. **Click leader portrait / unit camera → follow.** Clicking a squad leader's
   portrait (which already selects them) also makes the camera follow them;
   clicking a unit's camera icon selects that unit and follows it too.
5. **Right-click → close menu + cancel station/move order.** While the squad menu
   is open, a right-click closes the menu *and* removes the squad's station/move
   order (recall). Deferred — likely needs a unified left/right `onInput` handler,
   which may shake out of how #3 (click-enemy → attack) is built.
6. **Drag-to-select — area command (left-drag a box). LARGE, TODO.** Left-click
   and drag a rectangle on the map; the action is decided by what the box contains,
   checked in this order:
   - **Offensive:** if the box contains hostiles within **±3 Z-levels** of the
     drag, the **presently selected squad** attacks them.
   - **Select / conscript dwarves:** else if the area contains dwarves, **open +
     select their squads**. *Secret:* any boxed dwarf **not in a squad** is drafted
     (only as many as needed) into a new **temporary militia "Conscription N"** (N
     increments each use); those squads are then selected. When the squads screen
     is **closed, all Conscription militia are auto-disbanded**.
   - **Mining:** else if the box selects no one and lands **fully on stone tiles**,
     designate it for **digging** instead of any military action.
   - **Tree-chopping:** else a **3×3 drag around a single tree** designates that
     tree for **chopping**.
   The **select/conscript + defensive path must work even when the squads screen is
   closed** (box dwarves to raise a militia straight from plain map view). Data:
   box units via `dfhack.units.getUnitsInBox`; temp squads via
   `dfhack.military.makeSquad` + `addToSquad` (disband on close); dig/chop via the
   designation APIs.

**Gotchas learned:** `getMousePos` returns a map tile *under the command-menu
buttons too*, so click-to-move must guard on `main_interface.current_hover ~= -1`
(cursor is on a UI button, not the map) or it hijacks the Station/Kill/Patrol/etc.
buttons. And only act when a squad is selected — with nothing selected, leave the
click alone.

**Data model (`df.global.game.main_interface.squads`):** mode flags
`giving_move_order` / `giving_kill_order` / `giving_patrol_order` /
`giving_burrow_order` (booleans — settable directly); `squad_selected[]` (parallel
to `squad_id[]`) is the per-squad selection; `kill_unid[]` holds kill-order
targets. Camera follow is `df.global.plotinfo.follow_unit` (= unit id, or -1).
Map tile under the cursor: `dfhack.gui.getMousePos()`; the unit on a tile:
`dfhack.units.getUnitsInBox`/iterate `units.active` by `pos`; hostile test:
`dfhack.units.isDanger` / `isInvader` / enemy check.

**Implementation notes / TODO:**
- #1 is an overlay on `dwarfmode/Squads/Default` whose `overlay_onupdate` fires
  `select_all_and_move()` once per screen open (detected by a >500 ms gap in its
  update clock, since the overlay only ticks while that screen is focused).
- #2/#3 use **map-click interception** in the overlay's `onInput` (`_MOUSE_L` +
  `dfhack.gui.getMousePos(true)`, which works regardless of the overlay's tiny
  frame — same as DFHack's burrow-paint overlay). If a hostile is on the clicked
  tile → #3 (`giving_move_order=false`, `giving_kill_order=true`, push the unit
  onto `kill_unid`, clearing it first unless `dfhack.internal.getModifiers().shift`);
  the click is consumed so no move happens, and the squad engages on the normal
  confirm. Otherwise → #2: the click is passed through so DF issues the move
  natively, and the next `overlay_onupdate` re-sets `giving_move_order=true`
  (a `rearm` flag distinguishes "a move was issued" from an Esc/cancel).
  NOTE: `getMousePos` returns the tile *under* the squad list panel too, so a
  hostile standing behind the panel could be mis-targeted on a panel click — a
  panel-bounds guard is a possible refinement.
- #4 needs to detect a portrait/camera-icon click in the squads panel (find the
  clickable rects / the selected leader histfig) and set `plotinfo.follow_unit`.

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

### 🔴 embark-nobles (UNFINISHED — removed from the pack)

`embark-nobles` assigns the six key fort positions in one shot (handy right after
embark). `embark-nobles dry` previews the picks without changing anything.

**Status:** removed from `magnus-scripts` because it appears to interfere with
position assignments. It is NOT finished — needs rework before being auto-run
again. Use by hand at your own risk for now.

- **Only vacant positions are filled** — already-assigned nobles are left
  untouched, so it's safe to re-run and to auto-run from magnus-scripts.
- **Selection (for the vacant ones):** five roles each go to the best-skilled
  dwarf (by summed skill; a dwarf MAY hold several of them); only the expedition
  leader is forced to be a different dwarf from whoever holds those five:
  - chief medical dwarf → Diagnosis/Surgery/Set Bone/Suture/Dress Wounds/Crutch
  - militia commander → weapon skills + Melee Combat/Discipline/Leadership/Teaching
  - broker → Appraisal/Negotiation/Judging Intent/Console/Pacify/Intimidation/Lying
  - manager → Organization/Record Keeping (+Appraisal/Negotiation)
  - bookkeeper → Record Keeping/Organization (+Appraisal)
  - expedition leader → a different dwarf, by Leadership/social skill
  - DF has no dedicated manager/bookkeeper skill, so those use Record Keeping /
    Organization as the closest proxy.
- **Assignment mechanics (verified live):** positions live on the **fortress
  group entity** (`df.global.plotinfo.group_id`, == `plotinfo.main.fortress_entity`),
  *not* the civ. Every position already has an assignment slot in
  `entity.positions.assignments` (vacant = `histfig == -1`), so we reuse it —
  no creation needed. To assign (mirrors `make-monarch`): set
  `assignment.histfig = unit.hist_figure_id`, remove the previous holder's
  `histfig_entity_link_positionst` for that `assignment_id`/`entity_id`, then
  insert a fresh one on the new holder (`entity_id`, `link_strength=100`,
  `assignment_id`, `assignment_vector_idx`, `start_year`). To vacate: clear that
  link and set `histfig = histfig2 = -1`. Verified by assigning Sheriff +
  Hammerer (titles updated, links landed) then removing them (slots back to -1).
- Module exports `assign_position(code, unit)`, `unassign_position(code)`,
  `current_holder(code)`, `plan()` for reuse/testing.

### ✅ inside-burrow (DONE)

`inside-burrow` auto-seeds the self-expanding `inside+` burrow on the first tile a
miner digs. Armed at embark via magnus-scripts (`enable inside-burrow`); persists
with the fort and re-arms on load. One-time seeder — disables itself after it
fires (or if a burrow already exists).

- **Trigger:** a per-frame heartbeat (this pack's house style — no eventful)
  records every wall a miner takes a dig job on (`utils.listpairs` over
  `world.jobs.list`, filtered to `Dig`/`Carve*Staircase`/`CarveRamp` whose target
  is currently a `WALL`). When a watched wall becomes any passable (non-`WALL`)
  tile, that's the first dig-out — interior or not, anything triggers it.
- **"if no burrow exists":** acts only when `#plotinfo.burrows.list == 0`. If any
  burrow appears first (player-made, or a second run), it stands down and disables.
- **Seeding (mirrors quickfort's `create_burrow`):** `df.burrow:new()` with
  `id = burrows.next_id` (bumped), name `inside+`, random `symbol_index`/texture,
  inserted into `plotinfo.burrows.list`; the tile is added via
  `dfhack.burrows.setAssignedTile(b, pos, true)`. Then it runs `enable burrow` so
  the plugin's `+`-suffix auto-expansion is live and the burrow grows as you dig
  (it absorbs dug-out walls bordering the burrow; open cavern space is excluded).
- `inside-burrow status` reports armed / idle. `enable`/`disable`/bare-toggle as
  usual; state persisted per site via `dfhack.persistent`.

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
- **Overcrowding warning** (notify panel, `pasture_overcrowd`): fires when a
  designated pen holds more than ~1 animal per 4 grass tiles (graze) / 4 tiles
  (scavenge). Wording reports the **overflow** (animals beyond comfortable
  capacity), e.g. `Graze pasture 3, scavenge 15 over comfortable capacity`.
  **Clicking it** (`entry.on_click`) cycles through the overcrowded
  pens — each click zooms to the next one (`revealInDwarfmodeMap` on the pen
  centre), selects it (`civzone.cur_bld = pen`,
  `bottom_mode_selected = main_bottom_mode_type.ZONE`), then 3 frames later opens
  its repaint UI (`bottom_mode_selected = ZONE_PAINT`, `civzone.repainting=true`).
  The frame delay lets DF settle the selection first. Verified live: cycles
  between both overcrowded pens and lands in `dwarfmode/Zone/Paint`.

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
- **BLOCKED (investigated 2026-06-24):** the vanilla Work Details screen's unit
  list is **not reachable from lua**. `info.labor.work_details` is a
  `shared_ptr<labor_work_details_interfacest>` that df-structures defines only as an
  opaque `widget_container` — with the screen open it exposes **no fields** (no
  `:get()`, `labor.children` is empty), so there's no rows vector to filter. The
  sort plugin's `work_details_search` exists but is **never registered** for the
  same reason (so there's nothing to coordinate with, but also no hook). Hiding rows
  would need raw-memory hacking of the widget — too fragile to ship.
- **Feasible alternative (meets the goal "only civilians do these labors"):**
  `work_detail.assigned_units` IS accessible, so a one-shot or background service
  could keep military units out of work details (un-assign + clear those labors).
  Not the same as a visual filter, but achieves the intent. Awaiting a decision.

### ✅ auto-create labor groups (Work Details) — DONE (`labor-groups.lua`)
`labor-groups` creates the crafting Work Details (stone carving, metal/weapon/
armour smithing, carpentry, stone/glass crafting, brewing, cooking, jewelry, +
one for every remaining moodable skill) with the matching labor(s), and orders
the whole Labor screen (dig/grow defaults first, crafts next, Cook/Brewer then
Military last) — **non-destructively**: existing details are reordered and their
icons refreshed, never deleted or reassigned; only missing ones are created.
`labor-groups` / `labor-groups dry` (preview) / `labor-groups once` (magnus-scripts).

### ✅ work-orders quick text input ("3 steel swords") — DONE (`quick-order.lua`)

**Built:** the `quick-order.entry` overlay "new order" box on
`dwarfmode/Info/WORK_ORDERS/Default`. Parses digits/spelled amounts and the
`r`/`rN` repeat prefix; a subsequence fuzzy matcher over the full orderable set
(fort-permitted reactions + furniture + weapons/armour subtypes + collection/
processing jobs), material resolution (category/class/specific, magma-safe,
most-in-stock, plant materials, raw-glass colours), **material legality**
(rejects impossible combos, allows CAN_STONE weapons), one-legal-match-per-row
autocomplete, and `create_order` inserting at the **top** — **one-time OR
repeating** (`r`/`rN` → `frequency = Monthly`). Verified live.
**Still TODO:** *suggested conditions* — auto-adding an order's `item_conditions`
(the "add suggested conditions" DF does when you make a repeating order); the
frequency is set, but no conditions are attached yet.

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
