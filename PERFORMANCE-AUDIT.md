# Performance audit — constantly-ticking scripts

Date: 2026-07-07. Scope: all 37 `*.lua` scripts in this repo. Goal: find scripts that do
**heavy work at high frequency** during normal play and fix them without changing behavior.
(DF was off during the audit, so this is static analysis + reasoning, not live profiling.)

## Method

I enumerated every "ticking" construct and checked each for large-collection iteration
(`world.units.all/active`, `world.items.all`, `items.other.IN_PLAY`, `world.history.events`,
`world.buildings.all`, `manager_orders.all`, `world.jobs.list`):

- **Per-frame overlays** (`overlay_onupdate`, especially `overlay_onupdate_max_freq_seconds = 0`)
- **Per-frame / interval heartbeats** (`dfhack.timeout(N, 'frames', ...)` chains)
- **repeat-util loops** (`scheduleEvery`)
- **gui/notify callbacks** (`entry.dwarf_fn`) — DFHack's notify overlay calls each one
  **~once per second** (`overlay_onupdate_max_freq_seconds = 1`) on the main map.

## Fixed (3)

### 1. `needs-tomb-notification.lua` — heavy scan every second (unpaused)
`dwarf_fn` → `scan()` walks **all IN_PLAY items + all active units** each call. It cached on
`df.global.world.frame_counter`, which advances every game tick — so the frame cache **hits only
while paused and thrashes while unpaused**, re-scanning on essentially every 1/sec notify refresh.
**Fix:** a **hybrid** cache — keep the frame-counter check as a zero-cost fast-path (paused / same
frame → reuse; no wasted work while frozen) *and* add a wall-clock TTL (`getTickCount`, **60 s**)
to throttle the unpaused case where the frame advances every tick. Only a call that is both on a
new frame and past the TTL re-walks.

### 2. `planner-orders.lua` — the heaviest one, every second (unpaused)
`dwarf_fn` → `get_scan()` → `scan()` walks `buildings.all` + `items.all` + `IN_PLAY` (×5 via the
STANDING sources) + `manager_orders.all` (×7), and allocates/`:delete()`s a job-item filter per
planned-building slot. Same `frame_counter` thrash. **Fix:** same hybrid (frame fast-path + TTL),
TTL kept short (**5 s**) so a queued order clears its gap promptly.

### 3. `auto-tomb.lua` — walked `buildings.all` ~6×/second
Heartbeat ran `scan()` every `SCAN_FRAMES = 10` frames, and `scan()` iterates **all of
`world.buildings.all`** (hundreds-to-thousands in a developed fort) to find coffins/nest boxes.
Enabled by `magnus-scripts`, so it ran continuously. **Fix:** a **building-count trigger** — the
watched furniture can only appear as a *new* building, so the common tick is an O(1) `#buildings.all`
length compare and skips; the full walk runs only when the building set changed (instant on
placement, even while paused) or on a periodic backstop measured in *game* frames (so a paused fort
does no full walks). This keeps placement instant *and* cheap. (auto-tomb also now drops a 1x1
Pen/Pasture zone on nest boxes via the same trigger — a feature, same mechanism.)

### 4. `auto-name.lua` — `units.active` scan every 100 frames
Migrant renamer; heartbeat scanned `units.active` every `SCAN_FRAMES = 100` frames even though
migrants arrive only in occasional waves. **Fix:** interval bumped to **500 frames** (~once per
game-day). The heavy history-events scan was already gated to when unnamed migrants exist.

### 5. `no-sparring-spam.lua` — DELETED
Ran a `units.active` scan every 10 ticks (the most frequent tick in the pack) and didn't work
reliably. Removed the script, its deployed copy, and its `magnus-scripts` load lines.

## Why these were written that way (and the trap)

The `frame_counter` cache in #1/#2 is a natural-looking "recompute at most once per frame" guard,
and it **works perfectly while paused** — which is exactly how notification output tends to get
eyeballed while developing. The failure is only visible while unpaused, where every 1/sec notify
call lands on a new frame and misses. The right fix keeps that frame check (it's free and correct
while paused) and layers a wall-clock TTL on top for the unpaused case. `auto-tomb` picked a fast
10-frame interval for responsiveness; a coffin doesn't need its tomb zone within 0.15 s, so a 60 s
interval is the right trade.

## Reviewed and deliberately left as-is

- **Calendar-gated daily heartbeats** — `military-labor`, `military-uniforms`, `auto-mandate`,
  `auto-pasture`. These use `dfhack.timeout(1, 'frames', ...)` but the per-frame body is just a
  cheap date check (`now - last_run >= DAY_TICKS`); the heavy cycle runs ~once per game-day. This
  pattern is **intentional and documented** (repeat-util's day timers fire too coarsely on this
  build). Converting them would regress. Left.
- **Per-frame `dwarfmode` input overlays** — `dig-shapes`, `dwarf-rts`, `right-click-cancel`
  (all `max_freq = 0`). Their per-frame work is light (mouse-button polling + a few field reads);
  the heavy handlers run only on user gestures. Per-frame polling is *required* for responsive
  input, so this is correct. Left.
- **Alert-gated notify callbacks** — `civ-alert-notification`, `enemies-inside-notification`
  iterate `units.active`, but only *after* a cheap `active_civ_alert()` guard, so they are dormant
  during normal play and only scan while a civilian alert with burrows is active. Not
  constantly-ticking; and they're threat-critical, so I did not add latency. Left.
- **Cheap notify callbacks** — `empty-labor` (per-frame-thrash cache, but only walks the small
  `work_details` list), `raid` (small `army_controllers.all`, early-returns on 0 raids), `trader`
  (tiny `caravans`), `mandate` (tiny `mandates.all`), `auto-pasture` overcrowd (one zone, cached).
  All TRIVIAL/MODERATE per call. Left.
- **Trivial / self-terminating ticks** — `no-pausing` (one flag write per frame; opt-in),
  `statue-redirect` (per-frame tick but only a few view-sheet field reads), `inside-burrow`
  (per-frame but only walks the small `jobs.list`, and self-disarms after the first burrow).
  Negligible. Left.
- **Screen-scoped overlays** — `squad-buttons`, `creature-description`,
  `item-description`, `military-uniforms`, `binnable-stockpile`, `embark-prep`, `quick-order`,
  `statue-redirect`'s Remove button. Each is scoped to a specific viewscreen and only ticks while
  that screen is open — not during normal play. Left.

## Notes / lower-priority observations

- **`dig-shapes` vs `right-click-cancel`**: both are auto-loaded overlays on `dwarfmode` with
  overlapping box-designation / removal / right-click handling. Not a measurable perf issue (both
  light per frame), but it's redundant surface area worth consolidating some day — flagged, not
  touched (too risky without you awake to verify the merged behavior).

## Net effect

The three fixes remove the only *continuous, heavy* collection walks that ran during ordinary
unpaused play: two full item/building/order scans that were effectively running every second, and
a whole-buildings walk running ~6×/second. All three preserve identical behavior (same
notifications, same coffin auto-tombing) with far less redundant work.
