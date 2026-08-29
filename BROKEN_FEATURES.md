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
caravans *and* migrants. **Enabled by `magnus-scripts`.** Not yet confirmed to work reliably.

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

### **`fort/noble-warriors`**
Assigns each fort noble's symbols of office as specific items in their squad uniform, so
nobles wear their regalia into battle. Implemented and verified live, but **parked pending a
decision on whether it is actually wanted**. Never runs automatically — one-shot only, and
`noble-warriors dry` previews.

### **`embark/assistant`**
A site finder for the embark screen, reimplementing the old DFHack `embark-assistant` plugin
that no longer ships. Give it what you refuse to embark without — `flux coal river fresh`,
`biome=Forest soil3 calm near=DWARF`, `notower` — and it sweeps the whole world map, ranks what
matches and prints the best; `embark/assistant goto <n>` centres the map on one. With no filters
it still ranks the world on elbow room, rivers, soil, flux, coal, savagery and distance from the
nearest dwarven hall. Geology is classified once per `geo_index` rather than per tile, which is
what makes a full-world sweep affordable: 4,225 tiles in ~1.3 s on a 65×65 world.

**Written and exercised, but parked.** It runs, the numbers look right, and `goto` lands where
it says — but "looks right" is all it is: nothing has been checked against an actual embark, and
a site finder that quietly mis-ranks is worse than none.

Two real limits, both structural:

- **It cannot see aquifers or adamantine.** Both live in `region_details`, which DF loads only
  for the 16×16 world-tile shell the embark cursor is in; reading another shell is documented as
  crash-prone and did kill the game once during development. The sweep is therefore built purely
  from `region_map` and `world_data.geo_biomes`, which are complete world-wide. Move the cursor
  to a result and `embark/extra-info` answers the adamantine question for that tile.
- **~1.3 s is 1.3 s of frozen main thread.** Fine for a one-shot search, and it is bounded and
  measured rather than a blind map scan, but it is not something to run from an overlay.

`near=` matches on creature id (`near=DWARF`), which is the filter that matters — that civ is
your caravan.
