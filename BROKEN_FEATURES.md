# Broken features

Everything here still ships and still runs exactly as it always did — nothing has been
changed, disabled or removed. These are grouped out of the feature lists so the main README
only advertises things that work.

Three groups, most urgent first:

- **Fixer Uppers** — broken *and still switched on*, so they are acting on your fort right now.
- **TODO** — broken, not switched on, and there is a plan to fix them.
- **Broken** — everything else: no plan, or not yet decided whether it is worth keeping.

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
that war is a year old (its age read from DF's own history collection, so a long-running one is acted on at
once): a civ at war with itself sends no caravans home and no migrants — the same silence from a different
cause — and it is the one field DFHack's `fix/civil-war` clears. The year of patience is there because a
civil war can end on its own; the war itself and its history are left alone. **Live finding 2026-09-05:** the
homeland drought on this fort was a civil war running since year 102 (*The Eviscerated Conflict*, its
assaults on the capital led by dwarves held prisoner by the dark dwarves), not the erase bug; the two human
civs' silence since 105 is still unexplained.

### **`fort/mandate-notification`**
Shows noble mandates the moment they appear. **Run by `magnus-scripts` every session.** Unused
in practice and likely to be **removed** rather than repaired.

# TODO

Broken and switched off, with a plan to fix them.

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

### **`fort/mood-burrow`**
Confines a moody dwarf to a chosen burrow until it grabs its first material. Not referenced by
`magnus-scripts`.

### **`fort/no-pausing`**
Stops the game from ever pausing. Deliberately **not** enabled by `magnus-scripts` — it
suppresses *all* pausing, so it is left as a manual toggle.

# Broken

No fix planned, or not yet decided whether they are worth keeping.

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

### **`fort/choose-labor-icon` — UNTESTED, never opened in a fort**
A picker for a work detail's icon: your details on the left, all nineteen icons on the right,
drawn as DF draws them (each is a 4x3 tile rectangle on the `INTERFACE_BITS_LABOR` page, at
coordinates read out of vanilla's `graphics_interface.txt`). Click a detail, click an icon, and
`work_detail.icon` is written. `OVERRIDE_PAGES` lists tile pages consulted before vanilla's for
the `CUSTOM_1..8` slots, so a mod that rebinds those identifiers — the Steam Workshop *Work
Detail Icons* mod is the one it ships knowing about — shows its art in the picker too.

**Two reasons it is here.** No fort was loaded while it was written, so the window has never
been opened: the list, the click targets and the write are unverified. Worse, on the machine it
was written on `dfhack.screen.findGraphicsTile` returned nil for *every* page tried, including
`CURSORS`, which stock scripts use successfully — so the sprite path may never run and the
picker may always fall back to its name-only list. That fallback is functional (same clicks,
same result) but it is not what the tool is for. Confirm in a fort, in graphics mode, before
promoting this.

### **`fort/noble-warriors`**
Assigns each fort noble's symbols of office as specific items in their squad uniform, so
nobles wear their regalia into battle. Implemented and verified live, but **parked pending a
decision on whether it is actually wanted**. Never runs automatically — one-shot only, and
`noble-warriors dry` previews.
