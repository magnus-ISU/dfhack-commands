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
`df.global.world.frame_counter`, which advances every game tick — so the cache **hits only while
paused and thrashes while unpaused**, re-scanning on essentially every 1/sec notify refresh.
**Fix:** wall-clock TTL cache (`dfhack.getTickCount()`, 5 s). The heavy scan now runs at most every
~5 s regardless of pause state. Deaths/burials/memorials change slowly, so the few-seconds latency
is imperceptible.

### 2. `planner-orders.lua` — the heaviest one, every second (unpaused)
`dwarf_fn` → `get_scan()` → `scan()` walks `buildings.all` + `items.all` + `IN_PLAY` (×5 via the
STANDING sources) + `manager_orders.all` (×7), and allocates/`:delete()`s a job-item filter per
planned-building slot. Same `frame_counter` cache that thrashes while unpaused → the full scan ran
~1/sec during all normal play. **Fix:** same wall-clock TTL cache (5 s). A queued order clears its
gap within the TTL, so no visible change.

### 3. `auto-tomb.lua` — walks `buildings.all` ~6×/second
Heartbeat runs `scan()` every `SCAN_FRAMES = 10` frames, and `scan()` iterates **all of
`world.buildings.all`** (hundreds-to-thousands in a developed fort) to find coffins. It's enabled
by `magnus-scripts`, so this ran continuously. A coffin can only appear as a **new** building, so
walking the whole list 6×/sec is pure overhead. **Fix:** guard the walk on an O(1)
`#buildings.all` length check — the common "nothing changed" tick returns immediately — with a
periodic full-walk backstop (every 30 heartbeats) for the rare cases a bare count can miss (a
net-zero add+remove in one window, or a transient `make_tomb` failure). The count is re-read after
the walk because placing a tomb appends a civzone building.

## Why these were written that way (and the trap)

The `frame_counter` cache in #1/#2 is a natural-looking "recompute at most once per frame" guard,
and it **works perfectly while paused** — which is exactly how notification output tends to get
eyeballed while developing. The failure is only visible while unpaused, where every 1/sec notify
call lands on a new frame and misses the cache. The TTL cache keeps the original intent (avoid
redundant scans) and fixes the unpaused case. `auto-tomb` picked a fast 10-frame interval for
responsiveness; the comment even admits "coffins aren't placed every tick" — the count guard keeps
that responsiveness while removing the cost.

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
- **Screen-scoped overlays** — `squad-buttons`, `dfhack-stocks`, `creature-description`,
  `item-description`, `military-uniforms`, `binnable-stockpile`, `embark-prep`, `quick-order`,
  `statue-redirect`'s Remove button. Each is scoped to a specific viewscreen and only ticks while
  that screen is open — not during normal play. Left.

## Notes / lower-priority observations (not changed)

- **`auto-name.lua`** (migrant renamer, toggled by magnus-scripts): heartbeat every
  `SCAN_FRAMES = 100` frames (~1.6/sec) calls `living_citizens()` (iterates `units.active`). The
  *expensive* history-events scan is gated (runs only when unnamed migrants exist), so the constant
  cost is just a citizen filter — modest. A count guard won't help (`units.active` is volatile from
  wildlife). Could bump the interval since migrants arrive only a few times per game-year, but the
  benefit is small and I avoided touching it without a live test.
- **`no-sparring-spam.lua`**: `repeat-util` `scheduleEvery(..., 10, 'ticks', ...)` iterates
  `units.active` every 10 ticks — the most *frequent* tick — but the per-cycle work is modest
  (`units.active`, not items/buildings), and it early-outs of the report-vector scans unless there
  are new sparring reports. A clean O(1) guard would need a monotonic "new report" signal I
  couldn't verify with DF off, and you care about prompt sparring removal, so I left it.
- **`dig-shapes` vs `right-click-cancel`**: both are auto-loaded overlays on `dwarfmode` with
  overlapping box-designation / removal / right-click handling. Not a measurable perf issue (both
  light per frame), but it's redundant surface area worth consolidating some day — flagged, not
  touched (too risky without you awake to verify the merged behavior).

## Net effect

The three fixes remove the only *continuous, heavy* collection walks that ran during ordinary
unpaused play: two full item/building/order scans that were effectively running every second, and
a whole-buildings walk running ~6×/second. All three preserve identical behavior (same
notifications, same coffin auto-tombing) with far less redundant work.
