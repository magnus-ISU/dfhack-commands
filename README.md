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
| `auto-mandate` | enableable | ✅ done | Queues manager work orders for Make mandates using cheap renewable materials |
| `no-pausing` | enableable | ✅ done | Forces the game to never pause (overrides GUIs/events). Manual toggle |
| `raid-status` | one-shot | 🟡 partial | Reports raiding parties (leader/target/goal/time-gone + rough travel estimate); auto-retrieves stuck units. **Planning-screen overlay TODO** |
| `squad-buttons` | overlay | ✅ done | Kill-order screen buttons: "Target all invaders" + "Target all hostiles" (uses DF's native targeting; confirm as normal) |
| `attack-invaders` | one-shot | 🔴 superseded | Direct kill-orders don't make squads engage. Use `squad-buttons` instead |

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
2. **TODO — select-all-squads button at the top of the squads screen.** Need the
   multi-select representation in `main_interface.squads` (`squad_selected`
   vector<bool> parallel to `squad_id` vector<int32>[9]). Inspect the live
   squads list screen to get its focus string + button placement.

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
