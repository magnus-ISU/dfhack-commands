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

### 5. `no-sparring-spam.lua` — DELETED, then REWRITTEN
The original ran a `units.active` scan every 10 ticks (the most frequent tick in the pack), to find
reports filed under `unit_report_type.Sparring`, and didn't work reliably. It was deleted outright.

The script now back under that name does a different job with none of that cost: it drops the
sparring *alert button* rather than the reports. `world.status.announcement_alert` holds one entry
per live button and each names its own category, so a sparring button is just
`type == df.announcement_alert_type.SPARRING`. The pass walks that vector — a handful of entries —
so the 10-tick cadence is affordable here. It skips entirely while the alert panel is open.

It also waits out the bout: the button is only removed once three seconds have passed with no new
sparring report, since clearing mid-flurry just makes DF rebuild it. That check is bounded the same
way — the button names the units in the bout, and their own Sparring report counts are summed, so it
reads a handful of units the button already points at and never the unit list.

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

## 2026-09-21 — live profile of the notify panel, per callback

The July audit was static. This time DF was running (145 citizens, 54k items) and the
frame profiler (`dfhack.internal.resetPerfCounters()` + `script-manager.print_timers()`)
put `gui/notify.panel` at **10–20% of wall time**. The panel is one line in that report,
so every registered `dwarf_fn` was wrapped in a timer at runtime (swap `entry.dwarf_fn`
for a closure that calls the original and accumulates `dfhack.getTickCount()` deltas by
name) and the game left to run:

| callback | per call | share of wall |
|---|---|---|
| `planner_orders` | 456 ms | 6.0% |
| `moody_items` | 114 ms | 1.5% |
| `raids` (stock) | 15 ms | 0.2% |
| the other 23 | ≤ 4 ms | ~0.1% |

The panel polls every callback every ~7.6 s, and `planner-orders` cached for 5 s, so it
rescanned on every poll: a half-second stall every eight seconds. A sampling profiler over
one scan (`debug.sethook` on an instruction count, tallying `debug.getinfo(2, 'Sl')`
lines) put 70% of it on five full-vector walks, each with a virtual call per item:

- `hair_wool_present` — all 52k IN_PLAY with a `matinfo.decode` each, **and wrong**: the raw
  wool to spin is the `CORPSEPIECE` "stray alpaca wool [7]" it excluded as finished. Now the
  1.5k CORPSEPIECE vector, and correct.
- `boulder_present` / `present_metal_ores` — IN_PLAY per question, several questions per
  scan. Now one BOULDER-vector index built once per scan (`memo`, cleared in `get_scan`).
- `ws_exists` — all 1,852 buildings per requirement, a dozen requirements per scan. Now one
  built-shops index per scan.
- the sand probe — `pcall(isSandBearing)` on all 52k; now `items.other.ANY_GLASSABLE` (649).
- `melt_count` — IN_PLAY flag walk; now `#items.other.ANY_MELT_DESIGNATED`.
- `reaction_stock` — `items.all` with `getType()` each, per supply; now the type's own vector.

`moody-items-warning`'s survey counted every category exactly, so it walked 8,555 boulders
to learn a number the notification only compares with 3: the notification survey now stops
at `MOOD_WANTS` per category and the click-through dialog does the exact count. Its
`usable()` ran eight `pcall`'d closures per item (65% of the survey); the flag names are
resolved once now, the same fix `auto-needs` needed.

After, over 90 s: notify.panel **2.4%**, all callbacks together 0.8% (stock `raids` is the
top one at 18 ms), DFHack as a whole 19% → **7.4%** of wall time.

Method worth keeping: the frame profiler names the panel; wrapping the callbacks names the
script; `debug.sethook` sampling names the line.
