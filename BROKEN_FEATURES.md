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

### **`fort/dfhack-stocks`**
A searchable stocks menu for quickly marking gear to melt, forbid or dump. **On hold**
mid-build (`DEVNOTES.md`). Not referenced by `magnus-scripts`.

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

### **`adv/fear-no-goblin`**
Fast travel into and out of the goblin dark pit you are standing at. Deliberately **not** armed
by `magnus-scripts`: it patches `world_site` types, so it stays a manual toggle.

### **`fort/noble-warriors`**
Assigns each fort noble's symbols of office as specific items in their squad uniform, so
nobles wear their regalia into battle. Implemented and verified live, but **parked pending a
decision on whether it is actually wanted**. Never runs automatically — one-shot only, and
`noble-warriors dry` previews.
