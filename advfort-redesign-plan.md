# adv/advfort redesign plan

Status: **IMPLEMENTED as `dfhack/adv/fort.lua`** (2026-08-11). It is fully
self-contained: advfort's job logic (choosers, predicates, item matching,
workshop handling) is duplicated inside it, and `dfhack/adv/advfort.lua` was
REMOVED from the repo (it survives in git history). The original user bug list
(2026-08-11), all addressed by adv/fort:

- Right-clicking closed the overlay window, which reopened only after a delay.
- With the channel tool selected, clicking a tile one z down and one over
  channeled there instead of walking.
- Could not build a workshop whose footprint overlaps your own tile.
- Clicking to build a workshop sometimes didn't start the job.
- Selecting materials sometimes clicked things BEHIND the submenu.
- Panels overlapped; wanted menu on the left + ONE aux panel, materials built
  into the build panel's bottom.
- Using a workshop sometimes didn't start, or started in an invalid location.
- No keyboard shortcuts/search for the auxiliary panels.
- Interrupted jobs stuck around unfinishable without being canceled.

Amendments settled after this plan was written:

- The channeled-area bug, clarified: with the channel tool selected, clicking a
  tile one z DOWN and one over (the floor exposed by a channel) channeled there
  instead of walking. Fix: **mouse job clicks are same-z only** (the old reach
  test used Chebyshev distance including z); jobs above/below keep Ctrl+D/E.
- The per-item material picker stays a **separate modal panel** that takes
  complete focus until an item is chosen or it is canceled (Esc or right-click)
  — only the slot LIST is embedded in the build/workshop panels.

## Why a redesign and not more patches

Nearly every reported bug traces to three structural decisions inherited from the
old gui/advfort:

1. **The tool is a modal `gui.Screen` (`usetool`) sitting on top of the game.**
   Fed clicks are dead to DF's native right-click and hover-gated toolbar
   (measured, see memory), so every native interaction requires the
   dismiss → pick-icon → `auto_restore` state-machine round-trip
   (`onInput` `_MOUSE_R` branch, `AdvfortIcon:overlay_onupdate`, 2 s timeout).
   That round-trip IS the "closes, appears closed, reopens after a delay" bug,
   and its input-forwarding (`fieldInput` → `sendInputToParent`) is where the
   move-into-channel click and "click didn't start the job" weirdness live.
2. **Every auxiliary UI is its own stacked Screen** — `BuildPicker`, `JobPicker`,
   `MaterialsPicker`, `openShopWindowButtoned`, plus `dialog.*` popups — each with
   private geometry, private input handling, `close_open_pickers()` loops, and
   2-frame deferred opens to dodge click-through. Overlapping panels and
   "selecting things behind the submenu" are the direct symptoms.
3. **Job lifecycle has no single owner.** `makeJob` / `ContinueJob` / `CancelJob`
   / `smart_job_delete` / the ~350-line `usetool:onIdle` each mutate job state on
   their own heuristics; nothing tracks "the job WE created" from birth to death.
   Walk away mid-job and the job (and any planned building shell) is orphaned
   forever — the "old jobs can't finish and aren't canceled" bug.

The redesign replaces those three foundations. Individual job-type logic
(predicates, choosers, item assignment, the smooth/detail/fell/web machinery)
is mostly sound and gets carried over, not rewritten.

## Target architecture

### A. Overlay, not modal Screen

Rebuild the main window as an **overlay widget** on `dungeonmode/Default` (the
proven adv-automation pattern: `overlay_onupdate` fires even paused; the game
receives all input we don't explicitly consume).

- The left-edge job menu renders permanently while the tool is enabled; there is
  no dismiss/restore cycle, **no pick icon, no `auto_restore`, no
  `dismiss_pending` drain** — right-click anywhere simply reaches the game
  natively and the menu never blinks. (Fixes: right-click close/reopen delay.)
- Input rule: hit-test our panels first — inside a panel we consume; everything
  else falls through untouched. Movement keys are *observed*, not intercepted:
  CAREFUL-move job triggering keys and our Ctrl+shortcuts are the only keys we
  consume.
- Constraints from hard-won lessons: never name a widget field `self.active`
  (reserved — overlay skips `overlay_onupdate`; use `self.show`); no `assign`/
  `init`/`delete` method names on defclasses; drive all timers from
  `overlay_onupdate`, never frame timers (they freeze in menus).

### B. One window manager: main menu + exactly one aux panel

A single layout owner with two slots:

- **Slot 1 (always):** the advfort menu on the left border (current
  `draw_job_window` content: mode list, Build line, status/countdown line).
- **Slot 2 (at most one):** the auxiliary panel, anchored immediately to the
  menu's right edge. Opening any aux panel closes the previous one. Aux panels:
  - **Build picker** — the flat searchable buildable list, with the **materials
    pane merged into its bottom section** (slot rows + click-to-cycle item
    choice, absorbing `MaterialsPicker` and the side pane of the current
    `BuildPicker`). Picking + materials + confirm all happen in this one panel.
  - **Workshop job picker** — replaces `openShopWindowButtoned`'s Screen; same
    frame, same search field.
  - Small choosers (width/height/dir, track stop config, siege, put-item) become
    aux-panel pages too — no more `dialog.showListPrompt` stacks.
- Because one widget owns all drawing and all hit-testing, clicks can never land
  on a row *behind* another panel, and panels can never overlap. (Fixes: overlap
  bug, click-behind-submenu bug; removes `close_open_pickers`, the 2-frame
  deferred open, and the held-button drain hacks — the single input path can
  swallow the press/release pair properly.)

### C. Job engine with a single state machine

One module-level engine owns every job the tool creates:

```
IDLE -> PLACING (shell/planned building exists, items not assigned)
     -> QUEUED  (job created, worker attached, Job action pending)
     -> WORKING (countdown ticking; position + safety watched)
     -> DONE | FAILED | CANCELED   (always cleaned up, always reported)
```

- The engine records `job.id`, the building id (if any), target pos, and creation
  tick. Every transition is driven from `overlay_onupdate`.
- **Watchdog:** in QUEUED, if the unit has no `Job` action after N ticks and is
  idle, re-add the action once; if it still doesn't take, cancel with a visible
  status reason. No more silently-started-but-never-continuing jobs.
- **Walk-away rule:** in QUEUED/WORKING, if the adventurer leaves reach of the
  target, the engine cancels *its own* job and deconstructs an empty planned
  shell it created. (Fixes: orphaned unfinishable jobs.)
- **Safe cancel only:** detach the worker ref first, then delete the job on a
  LATER tick — never `removeJob` a unit's `current_job` (SIGSEGV, see memory),
  never mutate a live `job.items` from the update callback.
- **Startup sweep:** when the tool opens, scan for leftover advfort jobs /
  planned shells referencing the adventurer (bounded: the site's buildings +
  `world.jobs` postings at reach, never map scans) and clean them with an
  announcement.
- `ContinueJob`'s fetch logic (`unit.path.dest` writes) moves into the engine so
  fetching, suspends, and the too-long-prompt dismissal are all sequenced in one
  place instead of three.

### D. Click routing and the build flow

One dispatcher decides what a left-click means, in order: panel hit → job click
(adjacent / footprint-reach, current `map_click_job` logic) → native
fall-through. Two specific fixes ride on it:

- **Move-into-channeled-area:** the report was cut off — first reproduce and pin
  the exact misbehavior (most likely the job-click predicate or reach test
  claiming a click that should have been a native walk/climb into the channel).
  The dispatcher must only claim a click when the target predicates *pass*;
  everything else stays native. Add the repro to the test checklist below.
- **Workshop overlapping yourself:** placement fails because the adventurer
  occupies a footprint tile. Fix in `BuildingChosen`/`CheckAndFinishBuilding`:
  if the footprint covers `adv.pos`, step the adventurer to the nearest open
  adjacent tile first (the `unstick` teleport logic already written for
  post-completion), then place, then anchor the job at the worker's side
  (existing `AnchorJobAtWorker`). If no open tile exists, refuse with a status
  message instead of failing silently.
- **"Build click sometimes does nothing":** every claimed click must end in
  either a job transition or a status-line reason — `try_job` already reports
  refusals; the redesign makes that an invariant of the dispatcher (no path may
  `return` without either passing the click on or setting status).

### E. Using workshops

- `use_nearby_workshop` keeps its adjacency search but validates through the job
  engine: the workshop job is only created if the engine can anchor the worker at
  a legal adjacent/on-building tile; otherwise the aux panel shows why.
  (Fixes: "starts in an invalid location".)
- The workshop menu trusts only the last `fillSidebarMenu` button pointers and
  gates on `#building.button > 0` (known SIGSEGV traps, see memories).

### F. Keyboard model

- **Search:** every aux panel embeds a `fort/dig-building`-style search field
  (EditField; capture text in `on_change` — remember the `''`-stomp trap).
  Typing filters; Enter picks the top match.
- **Ctrl+letter shortcuts:** main menu rows and aux-panel actions get stable
  `CUSTOM_CTRL_<letter>` bindings, drawn on the rows. Letters only — digit keys
  (`CUSTOM_1`) are invalid interface keys and kill the widget at render.
  Proposed: Ctrl+B build picker, Ctrl+U use workshop, Ctrl+J job list focus,
  Ctrl+X cancel current job, Ctrl+F focus search, Shift+R/T keep cycling jobs.
- Esc closes the aux panel if one is open, else collapses the menu (tool stays
  enabled, jobs keep running under the engine — collapse is purely visual now,
  since the overlay doesn't block anything).

## What carries over unchanged

Predicates and choosers (`Is*`, `*Chooser`), `makeJob`/`AssignJobItems`/
`isSuitableItem` and the advfort_items module, the smooth/detail tiletype fixes,
tree-fell and web-gather work loops (they become engine states), the too-long
prompt dismissal, recipe entity union, `smart_job_delete`, the unsafe-condition
checks, economic-stone fix.

## Phasing (each phase ships + hot-reloads independently)

1. **Repro pass:** pin each listed bug live (especially the truncated
   channeled-area one) and write the regression checklist.
2. **Window manager + overlay conversion** — biggest structural change; the old
   Screens keep working underneath until each panel is ported. Kills the
   right-click bug immediately.
3. **Job engine** — port makeJob/ContinueJob/onIdle continuation into the state
   machine; watchdog + walk-away cancel + startup sweep.
4. **Build panel** — picker with embedded materials section; overlap-self fix;
   click-dispatcher invariant.
5. **Workshop-use panel** — port `openShopWindowButtoned`; placement validation.
6. **Keyboard + search polish**, then a full regression pass over the checklist
   and the header bug lists.

Deploy/test loop per phase: `make install-scripts`, overlay rescan, verify the
NEW widget version is live (reqscript output + `overlay.get_state()`), and
remember reqscript does NOT re-register or bump heartbeat generations — test
through the callbacks the UI actually calls.
