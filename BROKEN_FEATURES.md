# Broken features

Everything here still ships. These are grouped out of the feature lists so the main README
only advertises things that work; most still run exactly as they always did, and the ones
that have been switched off say so in their own entry.

Four groups, most urgent first:

- **Fixer Uppers** — broken *and still switched on*, so they are acting on your fort right now.
- **TODO** — work with a plan attached: broken tools that are switched off, plus repairs
  queued against tools that do ship and work (each of those says so).
- **Planned** — not built at all: features that have been asked for, with what each would take.
- **Broken** — everything else: no plan, or not yet decided whether it is worth keeping.

**Difficulty** is given on every TODO and Planned entry, and means the same thing throughout:

| | |
|---|---|
| **Easy** | The data is known and reachable, nothing new has to be discovered, and it is mostly writing. A session. |
| **Moderate** | One or two things still have to be pinned down live (a focus string, a struct, a job shape), but nothing about it is known to be blocked. Two or three sessions. |
| **Hard** | A real unsolved problem sits in the middle of it — 3D pathing, forcing a decision DF makes for itself, or a mechanism that has already crashed DF once. Expect a spike first, and a real chance the answer is "not this way". |
| **Blocked** | A specific thing is known to be impossible or unavailable today. The entry says what, and what would unblock it. |

# Fixer Uppers

Broken, and **enabled every session by `magnus-scripts`** — these are the ones that can still
affect a live fort.

### **`fort/military-uniforms`**
Creates the steel uniform templates and auto-forges each soldier's gear. The **re-equip logic
is unreliable** (`dwarf-reequip` in `DEVNOTES.md`): it sometimes can't explain why a dwarf
won't re-equip a piece it has been assigned, and sometimes picks the wrong thing to forge.
Known residuals on top of that: a soldier with the **mining labor** can't be uniformed at all
(a DF conflict), and one civilian-squad manager's **cloak** slot refuses every assignable
cloak. Run by `magnus-scripts` every session, which also registers its Equip-screen overlay.

`military-uniforms altsched` is the fort's **schedule** half and works: it builds the **even
month / odd month** training routines (each trains on its months and stands Ready the rest, with
three "at least 3" Train orders per training month so the squad spars in shifts instead of mobbing
one barracks), and sets the two stock routines the way a fort wants them — **Ready** sleeps
*room/at will* (own bedroom, never a barracks bed at need) and **Off duty** equips *always*, so a
squad does not spend eleven months of the year undressed. `altsched once` re-applies whenever the
schedules are found **empty**, not merely when the routines are missing: a fort was found running
both routines with every month blank, and because the names were there the once-check skipped it
every session and those squads never trained.

**Difficulty of the repair: Moderate–Hard** — see `BROKEN_FEATURES.md` § Planned →
`fort/military-reequip`, which is where that work is planned to land.

### **`fort/tarrasque`**
Each winter solstice, a dead megabeast may return and attack again, so the world's megabeasts
never go extinct. **Enabled by `magnus-scripts`.**

### **`fort/inside-burrow`**
Seeds a self-growing interior burrow on the first tile you dig at embark. **Armed by
`magnus-scripts`** (it only acts when the fort has no burrows yet).

### **`fort/caravan-unstick`**
A weekly watchdog that frees caravans stuck leaving — which otherwise quietly blocks future
caravans *and* migrants. **Enabled by `magnus-scripts`.** v3 (2026-09-04) hands stuck entries to DF's own cleanup instead of erasing
them — erasing killed the civ's schedule permanently. v4 makes that a **checked invariant**: the entry
list is captured around every pass and any entry that disappears inside one is reported by name as a
bug, and `caravan-unstick` now prints the year each civ's last caravan got home, so a stopped schedule
shows as a date. v5 also takes the fort **out of a civil war** on the same weekly pass, once
that war is **18 months** old (its age read from DF's own history collection, so a long-running one is acted
on at once) — long enough that the fort actually feels the homeland's trouble: a civ at war with itself sends no caravans home and no migrants — the same silence from a different
cause — and it is the one field DFHack's `fix/civil-war` clears. The wait is there because a civil war can end on its own,
and so the silence reads as the homeland's trouble reaching you; the war itself and its history are left
alone. **Live finding 2026-09-05:** the
homeland drought on this fort was a civil war running since year 102 (*The Eviscerated Conflict*, its
assaults on the capital led by dwarves held prisoner by the dark dwarves), not the erase bug; the two human
civs' silence since 105 is still unexplained.

### **`fort/combat-log`**
Newest-first ordering in the combat log works, and so does the `.` key: it advances the world by
exactly one tick from a screen that otherwise stops time altogether (the panel is closed for one
frame and put straight back). **What does not work is the point of it** — the log does not gain
the tick's new lines. DF rebuilds a unit's report log only inside its own open-the-log handler,
which no field assignment triggers, so the entries stay as of the last time you opened the log.
Feeding DF the click on the unit's row in the report picker DOES trigger the rebuild, and a
version of this did exactly that, but landing that click needs the row to be drawn where the
scrape looks: it retried up to twenty times a step, made the screen laggy, and a second `.`
arriving mid-flight left an empty panel. That machinery is gone; the step is now the plain,
stable version and the list is a tick stale until you reopen it. The likely fix is to drive DF's
own picker selection instead of hunting for the row on screen. **Enabled by `magnus-scripts`**,
which also binds `.` on that screen.

**Difficulty: Hard.** The plan is known — drive DF's own picker selection rather than scraping for
the row — but it depends on the report picker exposing a selection index that a write actually
acts on, and the screen-scraping version of this is already on record as laggy and fragile. If the
index turns out to be read-only in practice, there is no second idea.

### **`fort/mandate-notification`**
Shows noble mandates the moment they appear. **Run by `magnus-scripts` every session.** Unused
in practice and likely to be **removed** rather than repaired.

# TODO

Work with a plan attached. Mostly tools that are broken and switched off — but also repairs
queued against tools that ship and work today, which say so in their entry.

### **`fort/adamantine-hospital` — the `retarget` mode (REMOVED, worth retrying)**
The tool itself works; this was a third mode, now deleted from the script. Instead of forbidding
the adamantine a medical job had claimed and cancelling the treatment, it **swapped the claim**:
find an ordinary cloth/thread satisfying the same job filter (validated against DF's own
`isSuitableItem` / `isSuitableMaterial`), `disconnectJobItem` the adamantine, erase its
`job_item_ref` from `job.items`, and `attachJobItem` the replacement. Nicer outcome — the patient
keeps the treatment, no job churn, and the adamantine never has to be forbidden, so the smelter
can still reach it.

**It crashed DF.** Rewriting a live job's item list from inside DFHack's update tick produced a
`SIGSEGV` in `bit_container_identity::lua_item_read` — a Lua callback later reading `.flags` off
a pointer the edit had invalidated. Four crashes in ~40 minutes under an orc siege plus a strange
mood (heavy job and item churn); switching the mode off ran 34+ minutes clean with everything
else unchanged, which is what pinned it.

It was guarded against the obvious hazard — it refused to swap once a dwarf was already carrying
the item — so the damage is from the in-place `job.items` surgery itself, not from stealing a
carried item. A retry needs a mechanism that never edits a live job's item vector: cancel and
re-post the treatment with a pre-attached replacement, or find a DF-side call that reassigns a
claim atomically.

**Difficulty: Hard.** Not because the swap is complicated — the old code worked — but because the
only known-safe shape is "never touch a live job's item vector", and the obvious substitute has a
crash of its own: cancelling a job a dwarf is *currently doing* segfaults, so a retry may only act
on treatments no unit has picked up yet, which is a narrower window than the bug needs. Budget a
spike that proves the cancel-and-re-post path survives a siege before any of it is written.

### **`fort/quick-order` — fix up**
The order box works and is used constantly. What needs repair is **parsing and item matching**:
some inputs resolve to the wrong item, or a legal item is not found at all. The matcher is doing
a lot at once — every split point between material and item name is scored, each side fuzzily
(prefix, substring, edit distance, plural-folded), against a vocabulary that includes every
weapon/armour/tool itemdef, every fort-permitted reaction and the fixed-job furniture — so a
wrong answer is usually a scoring accident rather than a missing entry, and the fix is a matter
of tightening the scoring, not of adding vocabulary.

Still open alongside it, and recorded in the tool's own header: **suggested conditions**. An
`r`/`rN` repeating order gets its frequency but none of the `item_conditions` DF would attach
through its own "add suggested conditions" step, so a repeat ships ungated unless the parser
added a stock condition itself.

**Difficulty: Moderate for both, and they are independent.** The matching repair needs a bench of
failing inputs more than it needs new mechanism: collect the phrases that mismatch, make them a
table of expectations, then tune. The scoring already has the pieces a fix would use (an ambiguity
check that fails rather than guesses when the top two candidates disagree). For conditions, both
routes are open — drive DF's own add-order flow, or build `item_conditions` directly — and the
second is much cheaper than when it was written down, because `planner-orders` now hand-builds
conditioned repeating orders across two dozen asks, including the flag-based ones (`empty`,
`sand_bearing`) that used to be the unknown.

### **`fort/channel-safely` — fix up**
The scheduler is sound in principle — suspend on sight, release a few non-adjacent tiles at a
time, prove each release against a pretend map — and it is **enabled every session by
`magnus-scripts`**, so whatever it gets wrong it gets wrong on a live fort. Three things, in the
order they matter:

1. **A rare case still looks like it can cave in**, and it is not understood. That is the serious
   one: the tool's whole claim is that a release is *provable*, so an unexplained collapse means
   the proof has a hole in it rather than a tuning problem. Wanted first is a repro — the
   designation shape and the tile that went — because `channel-safely why <x> <y> <z>` will
   explain any tile's verdict and that is where the faulty step will show.
2. **The pathability check is not perfect.** The release test asks that every still-designated
   tile keeps somewhere to stand that connects out of the excavation; when that answer is wrong,
   tiles are either stranded or let out when they should not be.
3. **Big designations over open space should be dug, not channelled, first.** Where the tile
   below is already open, channelling opens a hole under the miner instead of a step down. The
   fix is an ordering rule: mine those tiles as a plain dig where that is legal, then channel
   **back to front** — each channel taken from the tile nearest the untouched rock, so the miner
   always has solid ground behind them and retreats out of the hole instead of into it.

**Difficulty: Hard for (1), Moderate for (2), Moderate for (3).** (1) is hard because it is a
correctness proof, not a behaviour: without a repro there is nothing to test against, and the bar
for "fixed" is higher than for anything else in this file. (3) is the most self-contained of the
three and could ship on its own — it is a new phase in an ordering the tool already owns, and the
back-to-front rule is the same connectivity search run with the order reversed. Mind the standing
constraint throughout: the safety scan stays inside ONE z-level per pass, because the wider
version froze the game.

### **`fort/planner-orders` — material types**
Three reported faults in the material picker and the orders it writes:

1. **Stone types that are available are not offered.** The picker's "any other metal/stone you
   have" pass is built from `fort_materials()`, so a stone the fort holds but that pass does not
   see never appears.
2. **There is no magma-safe rock choice.** The generic `Rock (any stone)` entry is *dropped
   outright* when the building requires magma safety, on the grounds that "rock" cannot be
   promised safe — which is true of the generic but leaves the player with no stone option at all
   for a magma building. The right shape is `quick-order`'s: resolve the class to a concrete
   magma-safe stone the fort actually has (most-numerous wins) and pin that.
3. **It writes orders DF renders as an unknown material.** Strong suspect, and it lines up with
   (2): the `Rock (any stone)` choice becomes `mat_type = 0, mat_index = -1` on the manager
   order, and there is **no "any inorganic" pin** — DF's material categories have no `stone`,
   `metal` or `glass` flag at all, so an order pinned that way names a material that does not
   exist. Metals are offered as concrete indices and should be fine unless `inorg()` failed to
   find one, which is worth checking at the same time.

**Difficulty: Moderate**, and mostly already solved next door. `quick-order` implements exactly
the model this needs — the fourteen real `job_material_category` flags for the category case, and
concrete-class resolution (stone/metal/glass → a specific material, filtered by magma-safety and
picked by stock) for everything else — so this is largely making `planner-orders` agree with it,
plus a sweep of the existing asks for material pins of the same broken shape. Verify against the
Work Orders screen, not just the struct: "unknown material" is a rendering of the pin, so the
screen is where the fix is confirmed.

### **`fort/mood-burrow`**
Confines a moody dwarf to a chosen burrow until it grabs its first material. Not referenced by
`magnus-scripts`.

**Difficulty: Moderate**, and mostly a testing problem. The burrow API is simple and proven
(`isAssignedTile` / `setAssignedUnit`), but the two hazards around it are known and sharp: a
burrow that does not contain both the dwarf's workshop and its materials strands the dwarf
instead of steering it, and a strange mood is the one job in the fort that must never be
cancelled or rewritten. Testing needs a live mood, which arrives when it arrives.

### **`fort/no-pausing`**
Stops the game from ever pausing. Deliberately **not** enabled by `magnus-scripts` — it
suppresses *all* pausing, so it is left as a manual toggle.

**Difficulty: Easy**, but there is nothing to implement — it does what it says. What is open is a
decision, not work: whether a selective version (suppress the nuisance pauses, keep the ones that
mean something) is worth building, which is a list of announcement types and a filter.

# Planned

Not built yet. Each of these has been asked for; each entry says what it would do and what
stands between here and there.

### **`fort/masterwork-engrave-walls`**
Like `dig-replace-walls`, but for engravings: paint an area and it drives the walls all the way
to a **masterwork** engraving, retrying until every tile is one. Smooth, engrave, read the
quality of what was carved, and where it came out below masterful, re-smooth that tile (which
destroys the engraving) and engrave it again.

**Difficulty: Moderate.** Every piece exists: `planned-smoothing` already lays designations down
as tiles become legal, `better-engraving` already chooses what is carved, and the job types are
pinned (`SmoothWall`/`SmoothFloor` are smoothing, `DetailWall`/`DetailFloor` are engraving, and
`designation.smooth` clears the moment the job posts). The two open questions are where the
finished engraving's quality is read back from (`world.engravings`, per tile) and what stops the
loop: a fort whose best engraver is not legendary will never produce a masterwork, so a retry
budget, or a "wait for a better engraver" state, is part of the design rather than a nicety.

### **`fort/move-items`**
In the `dig-building` left-hand picker, click a spot to move things TO, then pick what goes there
from a proper list — by type, material, quality, where it is now — and the tool moves it with a
**garbage dump zone it creates and manages itself**: place the zone on the target, mark the chosen
items `flags.dump`, and clear the whole arrangement away once the haul is done.

**Difficulty: Moderate**, with one nasty detail. The zone side is proven in this repo
(`internal/planeswalkers/buildings.lua` builds `building_civzonest` records) and the picker is the
same shape as the trade and planner dialogs. The detail: dumping is fort-wide, not per-zone —
dwarves carry a dumped item to whichever *active* dump zone suits them, so the tool has to
deactivate the fort's other dump zones for the duration and put them back exactly as they were,
which is the same "restore what you took" discipline `fort/holiday` already needs. Also needs
verifying live whether items land forbidden (DF's dump-forbid standing order) and un-forbidding
them if so.

### **`fort/auto-scaffold`**
Automatically build the stairs needed to reach a build job nothing can path to, then take them
down again once the building is up.

**Difficulty: Hard**, and the hardest thing on this list along with the pathing half of
suspendmanager-supreme. Reachability itself is cheap (`dfhack.maps.canWalkBetween` answers it from
DF's own walkability groups), but *routing* a scaffold is a 3D search through open air and solid
rock that nothing here has ever attempted, and it has to be built bottom-up in dependency order —
each stair is only placeable from the one below it. Removal is worse than construction: the last
tile has to be taken out from a place that still exists after it is gone, which is the classic way
a dwarf is left standing on nothing. Worth a spike that only answers "can we route and stage a
three-tile scaffold and get it back down cleanly", before anything else is written.

### **`fort/suspendmanager-supreme`**
Make suspendmanager succeed in more cases: compute the pathing it gives up on, and/or — when it
does suspend a job — **haul the planned building's materials to the site anyway**, so the builder
starts the moment the job unsuspends instead of starting with a walk.

**Difficulty: Hard for the pathing half, Moderate for the hauling half** — and they are separable,
which is the useful finding. Suspendmanager is a **C++ plugin** (`suspendmanager.plug.so`), so its
analysis cannot be edited in Lua; but it exposes `isKeptSuspended`, `suspensionDescription` and
`foreach_construction_job` through `require('plugins.suspendmanager')`, so a companion tool can
read *why* each job is suspended and act on that without touching the plugin. The hauling half
then rides on `move-items` above: DF has no "carry this stone to that tile" order, and a managed
dump zone is the only native way to make a dwarf put an item on a chosen square. Build `move-items`
first and this gets much cheaper.

### **`fort/manage-encrusting`**
A GUI with real control over encrusting: pick the items to decorate, pick what to decorate them
with (gems, glass, shell), and queue the jobs — instead of a manager order that decorates whatever
it feels like with whatever is nearest.

**Difficulty: Moderate.** The job types are confirmed live (`EncrustWithGems` = 86,
`EncrustWithGlass` = 87), and the posting mechanism is now well understood from the silk-web work:
a job can be given the exact item it is for by inserting a `general_ref_item` before it reaches its
workshop. What still needs a live pass is the encrust job's own shape — which reagent is a
`job_item` and which is a ref, and how DF picks the target item when both are left open — plus the
picker UI, which is ordinary work.

### **`fort/good-soup`**
Manage kitchen jobs so every cooking job produces the highest-value stack it can, rather than
whatever DF felt like combining.

**Difficulty: Moderate**, and the shape of it is unusual: you cannot tell a `PrepareMeal` job what
to cook. The levers are indirect — the fort's kitchen restrictions (`plotinfo.kitchen`, which
ingredients may be cooked at all) and what is in stock and unforbidden when the job runs — so the
tool is really "curate the pantry, then queue the meal", toggling the cook flags of the cheap
ingredients off while a lavish batch runs and putting them back after. All of that data is
readable and writable today; the work is the value model (what a stack is actually worth, and what
else wants those ingredients — syrup is also the brewer's) and not starving the rest of the fort
to feed one job. `planner-orders`' Good meals ask already owns the order side.

### **`fort/animal-tribute`**
Let messengers bring back local fauna from your outlying holdings — a mountain home that sends you
its wildlife, caged, as tribute.

**Difficulty: Moderate to Hard, and it is a design problem rather than a blocked one.** DF has no
such mechanic, so all of it is fabricated: which holding was visited, what lives in its region
(readable — each world region carries its populations), and then producing the animals. Producing
them is the part this repo has already solved (`create` + position seed + active-insert + teleport,
with the emigration trap noted), and caging plus taming on top of that is known work. The honest
risk is fidelity: a tribute that spawns creatures out of nothing will look like what it is unless
the messenger round trip, the timing and the announcement are built to carry it.

### **`fort/trade-agreements`**
Default each year's import requests to what you asked for last year — or to a list you keep — so
the liaison meeting stops being a fresh fifteen minutes of clicking every year.

**Difficulty: Moderate, but on a once-a-year clock.** The screen is reachable
(`main_interface.diplomacy`, with `taking_requests`, `taking_requests_tablist` and the scroll
state alongside it) and remembering last year's picks is trivial persisted site data. What makes
it slow is that the request UI only exists while a liaison is actually meeting you: every
structure question — where a request is stored, whether it can be written directly or has to be
clicked — can only be answered during that visit, so the build is gated on the calendar rather
than on effort.

### **`fort/auto-needs` — three more needs**
Extend the existing tool past the two needs it answers (WANDER → fishing, abstract thinking /
self-examination → a scholar's post at the public library): **eat the highest-value food**,
**pray when the stress is coming from prayer**, and **acquire something** when that is the need
doing the damage.

**Difficulty: Moderate for prayer, Moderate for food, uncertain for acquire** — one research
question each, because needs are *derived* and cannot be written directly (editing `pers.needs` is
cosmetic; the fix has to be the real-world act that drains them). Prayer has an obvious lever (a
temple location the dwarf is steered toward) and an obvious hazard (a burrow that strands them —
see `mood-burrow`). Food overlaps `good-soup`: you cannot pick what a dwarf eats, only what is
available and unforbidden when they go looking. "Acquire an object" is the one with no known
lever at all — whether ownership assignment satisfies it needs proving before it is promised.

### **`fort/quickfort` — complex multi-z-level blueprints**
Take the replacement quickfort front end past flat, single-level blueprints to the ones people
actually publish: a whole fort in one file, `#>` / `#<` stepping down and up through z-levels,
`#meta` sections stitching several blueprints together, and stairs that have to exist before the
level below them can be reached at all.

**Difficulty: Hard, and step zero is not the multi-z part.** The tool has still never applied
anything to a map — no designation, no building, no zone — so the per-tile readiness machinery it
already has is entirely unexercised; that has to be true before layering z on top. What multi-z
then adds is a real ordering problem rather than more of the same one: the existing dependency
chain is per tile (dig → smooth → engrave → build), while levels depend on *each other* — a level
is unreachable until the stairway above it is dug and built, constructions need something to stand
on, and channelling from above changes the level below. That is the same access question
`auto-scaffold` faces, arriving from the other direction, and the two should be designed together.
The parsing half is comparatively cheap: the library blueprints are already read correctly,
including the `hidden()` sections behind `#meta` that the offline verification turned up.

### **`fort/military-reequip` — its own squad gear manager**
Split the re-equip logic out of `military-uniforms` into a tool of its own, with a squad gear
manager: per squad and per soldier, what each slot wants, what is filling it, and what to do about
the ones that are empty.

**Difficulty: Moderate to Hard, and the hard part is the diagnosis, not the UI.** This is the
`dwarf-reequip` problem in `DEVNOTES.md` given a proper home, and it has resisted twice. A lot is
already known — assignment lists are indexed by item type and sorted by id, an *owned* item is
invisible to the equipment manager, `spec.assigned` is what actually drives a pickup while
`spec.item` alone never fetches anything, amputee demand is `min(2, limbs)`, and size comes from
the manager order's `specdata.race` — so the work is turning that pile into a reliable
slot → root cause → action mapping, with the screen as the easy half on top.

# Broken

No fix planned, or not yet decided whether they are worth keeping.

### **`fort/stockpile-place`**
Drag to create a stockpile, expand a selected one, or erase tiles from any pile — a
dig-shapes-style drag replacing DF's native click handling on the stockpile placement view.
**Switched off**: `default_enabled` is now false and `magnus-scripts` no longer carries a row
for it, so nothing turns it on for you. The script is still in the tree and
`overlay enable fort/stockpile-place.watcher` still brings it back.

**The failure mode is not recorded here** — it was switched off on request without one being
given, so this entry says what it did rather than what it does wrong. Worth knowing when
someone comes back to it: it does not go through `df.global.selection_rect` (only the Dig tool
does), it polls `enabler.mouse_lbut_down` / `mouse_rbut_down` every frame in `overlay_onupdate`
and swallows the press in `onInput` so DF's native handling never fires, then re-dispatches a
plain click to DF. Taking mouse presses away from DF on a screen DF is also driving is the part
most likely to be at fault.

![fort/stockpile-place demo](demos/stockpile-place.gif)

### **`fort/attack-invaders`**
Meant to order every squad to kill all invaders on the map. **Superseded and non-functional:**
it inserts `squad_order_kill_listst` orders directly, and as `DEVNOTES.md` records, "the orders
landed on squads but dwarves never engaged." The working paths are shift-clicking the
`enemies-inside-notification` / `agitated-animals-notification` panels, and driving DF's native
targeting through `fort/dwarf-rts` / `fort/squad-buttons`. Not auto-run — but note
`magnus-scripts` still advertises it in its closing "One-shot commands:" line.

### **`fort/embark-nobles`**
Meant to fill vacant key fort positions by skill (chief medical dwarf, militia commander,
broker, manager, bookkeeper, expedition leader). **Unfinished** — it appears to interfere with
position assignments and needs rework. Explicitly **not** run by `magnus-scripts`;
`embark-nobles dry` previews without applying.

### **`fort/wildlife-spawn`**
A from-scratch animal-spawn attempt, kept for reference. Not referenced by `magnus-scripts`.
⚠️ The docs disagree about this one: the README has long called it non-working, while
`migration-plan.md` records it as a **done, working spawn primitive**. Needs a live retest to
settle which is true.

### **`adv/fight`**
Designate creatures on the local map as kill targets and have your adventurer hunt them down
turn by turn, travelling to each and attacking until every target is dead. Never enabled by
`magnus-scripts` — it is a manual command.

### **`fix/dead-armies`**
Purges figures recorded dead from the world's armies, deletes the armies left with nobody
aboard, and clears figures pointing at armies that no longer exist. **Run once on a live world
(337 members purged, 155 armies deleted); no fix planned and no demonstrated value.** Two
problems, either of which sinks it:

- **`hf.died_year >= 0` is not "should not be in an army".** An intelligent undead — a raised
  thrall, a ghoul, anything a necromancer animated — keeps the death year of the body it was
  made from while walking, fighting and *travelling in armies*. Marching undead are exactly
  what a necromancer's army is made of, so the main rule plausibly disbands real forces and
  reads as having "cleaned up" hundreds of members that were doing their job. Nothing in the
  run distinguished them, and the counts were never broken down by undead status.
- **It never fixed the case it was written for.** The prompting bug was a jade brute whose
  death never reached its historical figure: the figure still said alive, so the script leaves
  it alone. It only catches figures history *already* knows are dead — which is the state that
  bothers nobody, since DF re-mints armies constantly and nothing reads a dead member except
  location tools.

What it got right is worth keeping if this is ever retried: "empty" must mean no members **and**
`sum(army.squads.count) == 0`, because `army.squads` holds `army_popst` — anonymous troops with
no unit and no figure, which is how most of the world's forces are stored. Every memberless army
in the test world still had troops aboard; without that guard the run would have disbanded 204
real armies, one of them 70 strong.

A retry would need a positive test for "this member is a corpse, not an animated corpse", and a
concrete symptom it repairs.

### **`fort/quickfort` — UNTESTED in a fort**
A replacement quickfort front end that lists each blueprint **once** (stock lists one row per
section) and then applies its sections itself, per tile, in dependency order: dig → smooth →
engrave/carve → build, with stockpiles and zones placed once every tile they cover is ready.
Each tile advances independently, so furniture lands on its own square as soon as that square is
floor. Zones are never placed over existing zones (one announcement, then skipped). There is no
give-up timer — on a real fort that fires mostly on jobs that were about to continue, when the
beds simply are not built yet — so running jobs are listed in the window with their progress and
can be cancelled there. Progress is read back off the map rather than stored, so a save/load or
script reload re-derives it exactly.

Verified offline against the real blueprint library: `housing.csv` decomposes to 651 tiles with
363 dig + 651 smooth + 318 engrave steps, 207 buildings and a 30-cell zone; `Noble Suite.csv` to
81 tiles, 29 buildings (23 single-tile, 2 two-tile, 4 three-tile) and a zone. Two bugs were found
and fixed that way — hidden sections had to be included (library blueprints keep their real
content in `hidden()` sections behind a `#meta`) and contiguous same-code build cells had to be
grouped, or a 3x3 workshop would have been requested as nine 1x1 workshops.

Not verified: the GUI has never been opened, and **nothing has ever been applied to a map** — no
designation, no building, no zone. The overlap refusal, the job list and the per-tile readiness
checks are all unexercised.

### **`fort/initial-standing-orders` — UNTESTED, never run in a fort**
Sets the two standing orders a new fort should have started with: children stop hauling refuse
and corpses (`labor_info.chores[HAUL_REFUSE]` / `[HAUL_BODY]` — DF has no separate burial chore,
hauling a corpse to its coffin *is* the burial job), and obsidian is released from the fort's
stone-use restrictions (`plotinfo.economic_stone`). Idempotent, touches nothing else on the
Standing Orders screen, and `fort/initial-standing-orders status` reports without changing.

The field reads were verified against the running game — `status` prints correct values live —
but no fort was loaded, so the two **writes** have never executed and nothing has been confirmed
in the Standing Orders UI. One claim in the header is also unverified: whether DF starts a fort
with obsidian restricted at all. The world checked had it already free, which would make that
half of the tool a no-op.

### **`fort/noble-warriors`**
Assigns each fort noble's symbols of office as specific items in their squad uniform, so
nobles wear their regalia into battle. Implemented and verified live, but **parked pending a
decision on whether it is actually wanted**. Never runs automatically — one-shot only, and
`noble-warriors dry` previews.
