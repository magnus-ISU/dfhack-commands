# dfhack-commands

A personal pack of **DFHack scripts** for the latest Dwarf Fortress (0.53.x / Steam),
plus the **Dwarf Fortress: High Adventure** content-mod suite.

- Scripts live in [`dfhack/`](dfhack/) (with a couple in [`adv/`](adv/) and
  [`fix/`](fix/)). Copy them into `dfhack-config/scripts/` and they become commands.
- Content mods live in [`content-mods/high-adventure/`](content-mods/high-adventure/).
- **Full command reference, implementation notes, known bugs and TODOs:
  [`DEVNOTES.md`](DEVNOTES.md).** Repo/workflow quickstart: [`instructions.md`](instructions.md).

Run `magnus-scripts` (or add it to `dfhack-config/init/dfhack.init`) to enable the
always-on helpers each session; `magnus-scripts lovely` also flips on a batch of
stock DFHack tools and a few extras.

---

## DFHack scripts

### 🗄️ Stockpiles

<video src="https://github.com/magnus-ISU/dfhack-commands/raw/master/demos/Stockpiles.mp4" controls width="100%"></video>

<sub>▶ If the video doesn't play inline (e.g. in a plain Markdown viewer), [watch it here](demos/Stockpiles.mp4).</sub>

- **`binnable-stockpile`** — Overlay on the stockpile customize screen. One-click group
  toggles that compose: **all meltables** (`Ctrl-M`, metal items only — no adamantine,
  below-masterwork, ammo excluded — and flips on DFHack's native automelt), **all binnables**
  (`Ctrl-B`), **all food** (`Ctrl-F`), **all drink** (`Ctrl-D`), and a **quality** tri-state
  (`Ctrl-Q`). Also: click an already-selected category (or sub-category) again to toggle it
  all on/off.
- **`stockpile-place`** — Stockpile *placement* view: left-drag to create a new pile,
  right-drag to erase tiles from any pile under the box, and drag on a selected pile to
  expand it (dig-shapes-style gestures).

### 🔔 Notifications & alerts

- **`needs-tomb-notification`** — Alerts for dead dwarves with no tomb; click opens a "dead
  browser" with cause of death, skills, kills and a clickable family tree, plus bulk memorial-slab
  queuing.
- **`mandate-notification`** — Shows noble mandates the moment they exist (replaces the
  built-in `mandates_expiring`).
- **`raid-notification`** — Notify-panel entry for squads out raiding (rough ETA) + weekly
  auto-unstuck.
- **`civ-alert-notification`** — While the civilian alert is on, warns how many citizens /
  military are still outside the alert burrow; click to cycle/zoom to each.
- **`enemies-inside-notification`** — Warns of enemies *inside* the alert burrow; shift-click
  (with squads selected) orders them attacked.
- **`agitated-animals-notification`** — Replaces the stock "N agitated animals" line with a
  typed one (species/largest); shift-click attacks them all.
- **`trader-notification`** — Countdown "trader ready for N days" while a caravan is at the
  depot; click zooms to it.
- **`empty-labor-notification`** — Warns when an "only selected" work detail has no usable
  worker (accounts for soldiers' schedules).
- **`planner-orders`** — Warns of `buildingplan` items nothing produces and offers material
  choices + standing-order checks (incl. an adamantine processing chain).
- **`mandate-notification`** / **`auto-mandate`** — see below.

### ⚔️ Military & squads

- **`dwarf-rts`** — RTS squad control on the Squads screen: number-key select, left-click to
  move/attack/select, left-drag box to command, right-click to back out.
- **`squad-buttons`** — Squads-screen button that names its own action ("Select all squads" /
  "Select no squads").
- **`military-uniforms`** — Steel uniform templates + an Equip-screen auto-gear service that
  forges each soldier's exact pieces (sized per wearer, iron/copper backups, masterwork
  upgrades, tool/war-dog options) and tracks gear soldiers actually wear.
- **`military-labor`** — Keeps the "Military" work detail in sync with your standing squads.
- **`civilian-militia`** — Manually packs office-holder civilian squads into Ready/No-Orders
  squads (pulled out of the auto cycle).
- **`noble-warriors`** — Assigns each noble's symbols of office as specific uniform items so
  they wear their regalia into battle.
- **`training-barracks`** — Barracks-screen toggle marking one barracks as the fort's training
  barracks; all squads get assigned to train there.
- **`squad-equipment-search`** — Adds a search field (`Alt-S`) to the squad-equipment specific-item
  picker.
- **`attack-invaders`** — One-shot: order every squad to kill all uncaged invaders on the map.

### 🛠️ Map, designation & building tools

- **`dig-shapes`** — RTS map interactions: right-click to enter Dig mode; shaped dig boxes are
  reclassified on completion (staircases, real constructions, remove, chop, mine).
- **`dig-building`** — Companion building picker docked while the Dig tool is active; ranked
  type-to-filter search drives DF's native placement flow (with buildingplan on).
- **`right-click-cancel`** — Mouse helpers for designation/build tools: left-drag to apply,
  right-drag to erase, right-click to cancel under the cursor.
- **`plan-tile`** — During buildingplan placement, left-drag to lay a whole grid of a
  fixed-footprint building at once.
- **`cheatmine`** — Armok: instantly mines everything designated and builds planned constructed
  staircases end-to-end.

### 🐄 Animals

- **`auto-pasture`** — Pen-screen graze/scavenge toggles + a service that pens new tame animals,
  an overcrowding warning, and graze/butcher buttons on caged animals.
- **`butcher-shop`** — `[Butcher]` panel (`Ctrl-B`) for bulk slaughter marking, grouped by
  species/sex with last-breeder warnings.
- **`animal-training`** — `[configure training]` panel (`Ctrl-T`) for bulk trainer assignment to
  caged tamable animals.
- **`wild-animal-train`** — `[Train]` toggle on a wild tamable animal's sheet, so it's trained the
  moment it's captured.
- **`auto-tomb`** — Drops the needed zone onto furniture: a Tomb zone on every coffin, a
  Pen/Pasture on every nest box.

### 🤖 Automation & services

- **`magnus-scripts`** — One-shot that enables all the always-on helpers (and, with `lovely`, a
  batch of stock DFHack tools + extras).
- **`auto-mandate`** — Queues cheap-material manager orders to satisfy Make mandates (incl.
  minting coins) and prioritizes their jobs.
- **`auto-name`** — Renames each migrant wave to share a starting letter (wave 1→A, 2→B, …),
  gender-correct, from an editable name list.
- **`auto-elf-chop`** — Keeps tree-cutting under the elves' negotiated yearly lumber cap,
  designating the closest trees itself instead of letting `autochop` overshoot.
- **`caravan-unstick`** — Conservative watchdog for caravans stuck "Leaving" (which silently
  blocks future caravans *and* migrant waves).
- **`caravan-teleport`** — One-shot rescue: teleports an AtDepot caravan stranded away from the
  depot onto it.
- **`broker-ready`** — Frees a soldier broker to trade by switching their squad onto "Ready"
  while requested at the depot, then restoring it.
- **`idle-smiths`** — Lets idle dwarves satisfy their craft need at the forge (armor/weapons/cages/
  furniture), with a stateless armorsmith/weaponsmith split and per-category metal legality.
- **`inside-burrow`** — At embark, seeds a self-growing `inside+` burrow on the first tile a miner
  digs, then disables itself.
- **`mood-burrow`** — Confines a moody dwarf to a chosen burrow until it claims its first artifact
  material, then releases it.
- **`quick-order`** — "New order" text box on the Work Orders screen: freeform text → a legal
  manager order, with `r`/`rN` "keep N in stock" repeats.
- **`labor-groups`** — Orders the Labor screen and creates any missing crafting work details
  (non-destructive).
- **`no-pausing`** — Forces the game to never pause (manual toggle).

### 🔎 Info & description overlays

- **`creature-description`** — Shows the selected creature's description (great for forgotten
  beasts), with a categorized kills line.
- **`item-description`** — Redraws truncated item descriptions using up to half the screen.
- **`statue-redirect`** — Redirects a selected statue to the item's full description sheet; adds a
  Remove button to built items.
- **`announcement-search`** — `[dfhack search]` window for the ~356-entry Announcements settings
  list, toggling the real flag bits.
- **`noble-symbol-search`** — Search field (`Alt-S`) for the noble symbol-assignment list (10,000s
  of items).
- **`dfhack-stocks`** — Searchable/filterable stocks menu for quickly marking gear to melt/forbid/
  dump (replaces the vanilla Stocks screen).

### 🐉 World & megabeasts

- **`tarrasque`** — Keeps the world's megabeasts (forgotten beasts, titans, bronze colossi) from
  going extinct: each winter solstice a dead beast may revive via DF's own native attack scheduler.
- **`force-more`** — Forces native attack events the stock `force` can't (real forgotten-beast
  cavern attacks, surface megabeasts).

### 🧹 Cleanup & fixes

- **`destroy-forbidden`** — Destroys loose forbidden ground items (skips inventory/buildings/
  artifacts).
- **`clear-flows`** — Wipes airborne flow clouds (miasma/smoke/…) — a miasma FPS fix.
- **`fix/raiders`** — Repairs squads/soldiers stuck on off-site raids across several failure modes.
- **`raid-status`** — Reports raiding parties + rough travel estimate; auto-retrieves stuck units
  (🟡 planning-screen overlay TODO).

### 🗺️ Adventure mode

- **`adv/fight`** — Auto-fight: designates matching creatures and hunts them down across z-levels
  (runs as an overlay so it works while paused).
- **`adv/im-sure`** — Instantly dismisses the "haven't been able to act for a while" interrupt
  (webbed/stunned/pinned).

### 🚧 Embark & experimental

- **`embark-prep`** — "Prepare carefully" buttons that give the selected dwarf the office skills
  (`Ctrl-M`/`Ctrl-K`/`Ctrl-B`), plus a preferences window.
- **`embark-nobles`** — 🔴 *Unfinished / not in the pack* — meant to fill vacant fort positions by
  skill; interferes with assignment and needs rework.
- **`wildlife-spawn`** — ⚠️ *Does not work / unsolved primitive* — a from-scratch wild-animal spawn
  attempt kept only for reference.

---

## Content mods — Dwarf Fortress: High Adventure

A family of new-content mods that add several playable civilizations, designed to work
**together or individually**. Source lives in
[`content-mods/high-adventure/`](content-mods/high-adventure/) (one folder per mod, each with
its own `CHANGES.md`); design rules and fork provenance are in
[`content-mods/README.md`](content-mods/README.md). The other folders under `content-mods/` are
Steam-Workshop reference/fork sources, not part of the suite.

| Mod | What it adds |
|---|---|
| **`ha-playable-civs`** | Play dwarves, humans, elves, goblins or kobolds in fortress mode, and any of them as adventure-mode outsiders (fork of *All Races Playable Redo*). Goblins gain bronze-working + a single autumn caravan. |
| **`ha-drow`** | Evil, matriarchal mountain-fortress elves (scimitars/bows, no shields, forge any metal) escorted by domesticated giant cave spiders. 4% are born **driders** — a drow torso on a chitin giant-spider body with paralytic venom and webs. Fort + adventure. |
| **`ha-illithids`** | Ageless psionic brain-eaters: **illithid / ulitharid / Elder Brain / human-thrall** castes and a **Neural Bath** workshop (devour brains, ascension, tadpole implants, coalesce a new Elder Brain), with 10 psionic levels scaling to scholarship. |
| **`ha-orcs`** | Warlike pure-metal orcs (no alloys, iron above all) hostile to everyone. One in five is a pain-immune, frequently-raging **skull-cruncher champion**; ruled by a warband hierarchy. Fort + adventure. |
| **`ha-dark-dwarves`** | Carnivorous cannibal evil dwarves with ironclad in-group loyalty (never tantrum), child-snatchers who sap fortress walls with great picks; winter evil-bloc trade. Fort + adventure. |
| **`ha-succubi`** | Fork of *Succubus Dungeon* using vanilla weapons but keeping the full demonic wardrobe, corruption, summoning and magma wells; summer evil-bloc caravans. |
| **`ha-beasts`** | New wild monsters to make evil regions genuinely dangerous. First beast: the **Gibberling**, a small blue feral goblinoid that roams in gibbering swarms (`OPPOSED_TO_LIFE` + `CRAZED`). Standalone. |
| **`ha-increased-banditry`** | Raises the vanilla human/elf bandit-group rates (30 / 20) via `SELECT_ENTITY`; worldgen-only and independently toggleable. |
| **`ha-summon-test`** | Throwaway test mod for summon permanence/citizenship. Not for real play. |

> **Note:** raw changes (`objects/`) only take effect in a **newly generated world**; a mod's
> `scripts_modactive/` scripts reload for an existing save. See
> [`instructions.md`](instructions.md) for deploy steps.
