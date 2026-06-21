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
`needs-tomb-notification`, `mandate-notification`, and `enable auto-mandate`.
It does **not** enable `no-pausing` (that stops *all* pausing — manual toggle).

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
| `dfhack-stocks` | overlay+menu | 🔨 planned | Melt-focused searchable/filterable stocks menu (foreign/exotic filters, focus/melt/forbid/dump) — see spec |
| `statue-description` | overlay | ✅ done | Shows the statue's exact description + value on its building info sheet |
| `creature-description` | overlay | ✅ done | Shows the selected creature's description (bottom-left); great for forgotten beasts |
| `auto-pasture` | overlay+service | 📋 spec | (graze)/(scavenge) pasture buttons; auto-assign new tame animals — see spec |

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

### 🔨 dfhack-stocks — melt-focused stocks menu (in progress)

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

### 📋 auto-pasture

On the pen/pasture zone UI, render **(graze)** and **(scavenge)** buttons
**below DFHack's existing "DFHack assign" button** (from the `zone.pasturepond`
overlay). Clicking marks the current pasture as the grazing and/or scavenger
pasture (both allowed, even the same zone). A background service then
auto-assigns **new tame animals**: grazers → the graze pasture, non-grazers →
the scavenge pasture.

- Grazer test: `world.raws.creatures.all[u.race].caste[u.caste].flags.GRAZER`
  (verified). Tame fort animal: `isTame` + `civ_id == plotinfo.civ_id`.
- New-animal hook: `repeat-util` scan (or `onStateChange`) for tame animals not
  yet pastured; assign to the stored zone.
- Persist the graze/scavenge civzone ids with the fort
  (`dfhack.persistent.saveSiteData`); enableable service.
- **Needs live UI:** the pen/pasture zone viewscreen + "DFHack assign" button
  position (to place the buttons below it); the pasture-assignment API
  (assign a unit to a pen/pasture civzone).
