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
| `raid-status` | one-shot | 🟡 partial | Reports how long raiding parties have been gone; auto-retrieves stuck units. **ETA + planning overlay TODO** |
| `attack-invaders` | one-shot | 🔴 not working | Orders all squads to kill invaders — squads don't actually engage. **Needs fix / UI buttons** |

---

## Status & TODO (full implementation notes)

### 🟡 raid-status — add ETA and planning-screen estimate

**Done:** lists active raiding parties + how long each has been gone, and
auto-retrieves units stuck off-map.

**Data model (verified):**
- Active raids = `df.global.world.armies.all[i]` where `flags.player == true`.
  (Currently 0 out; most of the 600+ armies are world NPCs.)
- Each player army has `.controller` → an `army_controller` with:
  - `year`, `year_tick` — **departure timestamp** (use for "time gone")
  - `goal` — mission type, `master_hf` — leader histfig, `assigned_squads`,
    `pos_x`/`pos_y` — current world pos, `mission_report`
  - travel fields on the army itself: `travel_count`, `travel_rate`, `watch_time`
- Time math: 1 day = 1200 ticks, 1 month = 28 days, 1 year = 403200 ticks.
  `elapsed = now - (controller.year*403200 + controller.year_tick)`.

**TODO (needs a LIVE raid or the planning screen — can't inspect with 0 raids out):**
1. **ETA** — find where the *estimated duration / return time* lives. Candidates:
   the army's `travel_count`/`travel_rate` (remaining distance ÷ rate) or the
   mission-planning viewscreen's computed estimate. Read it off a live mission.
2. **Planning-screen overlay** — identify the raid/mission planning viewscreen
   (focus string) and its estimated-time field, then add a DFHack overlay widget
   (see `gui/notify.lua` pattern) to display departure-based ETA there.
3. The user wants the command to "only show the estimated time based on the time
   the dwarves left and the estimation."

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

**Preferred fix = UI buttons (work *with* DF's native flow):**
1. **Button on the squad kill-target selection screen** → "target all invaders".
   - Squad UI state: `df.global.game.main_interface.squads` with
     `giving_kill_order`, `kill_doing_rectangle`, `kill_unid`,
     `squad_selected`, `squad_id`, `viewing_squad_index`.
   - Old-style state also in `df.global.plotinfo.squads`: `in_kill_list`,
     `kill_targets`, `kill_rect_targets`, `sel_kill_targets`.
2. **select-all-squads button at the top of the squads screen.**
   - Same `main_interface.squads` panel; need the multi-select representation.
- Both require a DFHack **overlay widget** (`OVERLAY_WIDGETS`, OverlayWidget
  targeting the squads viewscreen focus string). **Must inspect the live
  viewscreen** (open Squads screen + enter give-kill-order targeting) to get the
  focus string and confirm button placement/actions. `dfhack.gui.getCurFocus(true)`
  on those screens gives the focus path. Models: `gui/notify.lua` (overlay),
  `uniform-unstick.lua`, `gui/civ-alert.lua` (squad-screen overlays).

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
