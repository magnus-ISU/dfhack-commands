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

- **`binnable-stockpile`** — Stockpiles can be toggled on/off with one click, set to all
  meltables, binnables, food, or drink, and easily set allowed quality.
- **`stockpile-place`** — Drag to create a stockpile, expand a selected one, or erase tiles
  from any pile.

![stockpile-place demo](demos/stockpile-place.gif)

### 🔔 Notifications & alerts

- **`needs-tomb-notification`** — Alerts when a dwarf dies with no tomb; click for a death
  browser with cause, kills and a clickable family tree, and queue memorial slabs in bulk.
- **`mandate-notification`** — Shows noble mandates the moment they appear.
- **`raid-notification`** — Tracks squads out raiding with a rough ETA, and unsticks them weekly.
- **`civ-alert-notification`** — During a civilian alert, warns who's still outside the safe
  burrow; click to find them.
- **`enemies-inside-notification`** — Warns of enemies inside the alert burrow; shift-click sends
  selected squads to attack.
- **`agitated-animals-notification`** — Names the agitated animals by species instead of a bare
  count; shift-click attacks them all.
- **`trader-notification`** — Counts down how many days the trader is ready; click to jump to the
  depot.
- **`empty-labor-notification`** — Warns when a restricted work detail has nobody who can actually
  do it.
- **`planner-orders`** — Warns of planned buildings nothing produces and offers the orders to make
  them.

### ⚔️ Military & squads

- **`dwarf-rts`** — Command squads like an RTS: pick with number keys, click to move or attack,
  drag a box to order a group.
- **`squad-buttons`** — A Squads-screen button that selects or deselects all squads.
- **`military-uniforms`** — Sets up steel uniforms and auto-forges each soldier's exact gear —
  sized per wearer, with iron/copper backups and masterwork upgrades — and tracks what they're
  actually wearing.
- **`military-labor`** — Keeps the "Military" work detail matched to your standing squads.
- **`civilian-militia`** — Packs office-holder civilian squads into ready and reserve squads on
  command.
- **`noble-warriors`** — Puts each noble's symbols of office into their uniform so they wear their
  regalia into battle.
- **`training-barracks`** — Marks one barracks as the fort's training barracks and assigns every
  squad to train there.
- **`squad-equipment-search`** — Adds a search box to the squad-equipment item picker.
- **`attack-invaders`** — Orders every squad to kill all invaders on the map.

### 🛠️ Map, designation & building tools

- **`dig-shapes`** — Right-click to dig; drag shapes that automatically become staircases,
  constructions, mining, chopping or removal.
- **`dig-building`** — A searchable building picker while digging that drops you straight into
  DF's placement flow.
- **`right-click-cancel`** — Drag to designate, right-drag to erase, right-click to cancel — for
  every designation and build tool.
- **`plan-tile`** — Drag to place a whole grid of a building at once while planning.
- **`cheatmine`** — Instantly finishes all designated digging and any planned staircases (cheat).

### 🐄 Animals

- **`auto-pasture`** — Auto-pens new tame animals, warns when a pasture is overcrowded, and adds
  graze/butcher buttons to caged animals.
- **`butcher-shop`** — Bulk-marks animals for slaughter, grouped by species and sex, with
  last-breeder warnings.
- **`animal-training`** — Assigns a trainer to many caged animals at once.
- **`wild-animal-train`** — Marks a wild animal for taming, so it's trained the moment it's caught.
- **`auto-tomb`** — Drops the right zone onto furniture: a tomb on every coffin, a pasture on
  every nest box.

### 🤖 Automation & services

- **`magnus-scripts`** — Turns on all the always-on helpers at once (and, with `lovely`, a batch
  of stock DFHack tools).
- **`auto-mandate`** — Fills Make mandates with cheap materials (even minting coins) and
  prioritizes the work.
- **`auto-name`** — Names each migrant wave to share a starting letter (wave 1→A, 2→B, …),
  gender-correct.
- **`auto-elf-chop`** — Keeps tree-cutting under the elves' yearly limit by designating the
  nearest trees itself.
- **`caravan-unstick`** — Frees caravans stuck leaving — which quietly blocks future caravans and
  migrants.
- **`caravan-teleport`** — Teleports a stranded merchant caravan back onto the depot.
- **`broker-ready`** — Frees a soldier broker to trade, then puts their squad back on duty
  afterward.
- **`idle-smiths`** — Lets idle dwarves work the forge to satisfy their craft need, picking legal
  metals per item.
- **`inside-burrow`** — Seeds a self-growing interior burrow on the first tile you dig at embark.
- **`mood-burrow`** — Confines a moody dwarf to a chosen burrow until it grabs its first material.
- **`quick-order`** — Type plain text on the Work Orders screen to create a legal manager order,
  with "keep N in stock" repeats.
- **`labor-groups`** — Tidies the Labor screen and creates any missing crafting work details.
- **`no-pausing`** — Stops the game from ever pausing.
- **`worldgen-setup`** — Sets up a fresh test world: selects every installed mod and maxes
  the civilization/site sliders from data, so only the Create-world click is left to you.

### 🔎 Info & description overlays

- **`creature-description`** — Shows a creature's full description (great for forgotten beasts)
  with a categorized kill list.
- **`item-description`** — Shows an item's full description instead of DF's truncated box.
- **`statue-redirect`** — Opens a statue's full item description, and adds a Remove button to
  built items.
- **`announcement-search`** — Adds search to the huge Announcements settings list.
- **`noble-symbol-search`** — Adds search to the noble symbol-assignment list of tens of thousands
  of items.
- **`dfhack-stocks`** — A searchable stocks menu for quickly marking gear to melt, forbid or dump.

### 🐉 World & megabeasts

- **`tarrasque`** — Keeps the world's megabeasts from going extinct — each winter a dead one may
  return and attack again.
- **`force-more`** — Forces attack events the stock `force` can't, like real forgotten-beast
  cavern attacks.

### 🧹 Cleanup & fixes

- **`destroy-forbidden`** — Destroys loose forbidden items lying on the ground.
- **`clear-flows`** — Clears miasma and other flow clouds — a quick FPS fix.
- **`fix/raiders`** — Rescues squads and soldiers stuck on off-site raids.
- **`raid-status`** — Reports raiding parties and a rough travel estimate, and retrieves stuck
  units.

### 🗺️ Adventure mode

- **`adv/fight`** — Auto-fights: marks matching creatures and hunts them down, even while paused.
- **`adv/im-sure`** — Instantly dismisses the "can't act for a while" interrupt when webbed or
  stunned.
- **`adv/keep-talking`** — After you pick a conversation topic, auto-reopens the conversation (via
  the `k`/`A_TALK` action → "Continue conversation") so it flows without re-initiating for every
  line. Closing with **Escape** does not reopen — that's how you leave. Toggle with
  `enable`/`disable adv/keep-talking` or **Ctrl+K** in-game. Default off. (Enabled automatically in
  adventure mode by `magnus-scripts`.)

### 🚧 Embark & experimental

- **`embark-prep`** — Prepare-carefully buttons that give a dwarf the office skills, plus a
  preferences view.
- **`embark-nobles`** — 🔴 *Unfinished* — meant to fill vacant fort positions by skill; needs
  rework.
- **`wildlife-spawn`** — ⚠️ *Doesn't work* — a from-scratch animal-spawn attempt kept for reference.

---

## Content mods — Dwarf Fortress: High Adventure

A family of new-content mods that add several playable civilizations, designed to work
**together or individually**. Source lives in
[`content-mods/high-adventure/`](content-mods/high-adventure/) (one folder per mod, each with
its own `CHANGES.md`); design rules and fork provenance are in
[`content-mods/README.md`](content-mods/README.md). The other folders under `content-mods/` are
Steam-Workshop reference/fork sources, not part of the suite.

| Mod | Fortress mode | Adventure mode & world |
|---|---|---|
| **`ha-playable-civs`** | Play dwarves, humans, elves, goblins or kobolds in fortress mode, with goblins gaining bronze-working and a single autumn caravan (fork of *All Races Playable Redo*). | Any of them can be rolled as an adventure-mode outsider, and the shared Shaping Tree lets tree-respecting civs grow wood instead of felling it. |
| **`ha-high-elves`** | Elf-stock artisans who mine and forge like dwarves but never cut a tree or take a fey mood, growing their wood at the **Shaping Tree** and coaxing **twinkling metal** out of the night sky by catching starlight. | Founded in forests only, pinned to one town per civ, so they stay a rare, reclusive people rather than covering the map. |
| **`ha-drow`** | Evil matriarchal elves in insular mountain fortresses — scimitars and bows, no shields, any metal forged, escorted by domesticated giant cave spiders. | 4% are born **driders**, a drow torso on a chitin giant-spider body with paralytic venom and webs; they settle mountains and forests only and are attacked less than anyone in the world. |
| **`ha-illithids`** | Ageless psionic brain-eaters with **illithid / ulitharid / Elder Brain / human-thrall** castes and a **Neural Bath** for devouring brains, implanting tadpoles, ascension and coalescing a new Elder Brain. | Ten psionic interactions scaling with scholarship, in isolated dark fortresses in the mountains that trade with nobody and are hostile to all. |
| **`ha-orcs`** | Warlike orcs bigger than humans working only pure metals — no alloys, no steel, iron above all — ruled by a warband hierarchy and breeding in the **Breeding Pit**. | One in five is a pain-immune, frequently-raging **skull-cruncher champion**; they hold savanna and scrubland hamlets and are hostile to every civilization, the evil bloc included. |
| **`ha-dark-dwarves`** | Carnivorous cannibal dwarves with ironclad in-group loyalty — they never tantrum and never have bad thoughts — trading only with the evil bloc, in winter. | Child-snatchers who sap fortress walls with great picks, holding deep mountain halls and never hillocks. |
| **`ha-succubi`** | Demonic realm-builders with corruption, summoning, bone-working and magma-well workshops, keeping the full demonic wardrobe while fighting with vanilla pikes, halberds, scourges and whips (fork of *Succubus Dungeon*). | Desert city-builders with summer-only evil-bloc caravans, land-holding Demon princes and outdoor fortifications. |
| **`ha-kobolds`** | A self-contained fork of *Cute Kobold Caverns* with *Skulking Filth*'s item-thief hard mode baked in, occasionally ruled by an **Ancient Dragon** whose eldest becomes the civ's Dread Wyrm king. | Ancient Dragons also lair the world as fearsome megabeasts, in one-, two- and three-headed castes with spiked or clubbed tails. |
| **`ha-second-humans`** | A second, independent human civilization identical to the vanilla one, so humans get two placement draws to an orc civ's one. | Adds no creature and modifies no vanilla raws — its entity block is regenerated from vanilla by `sync_from_vanilla.py`. The two human realms can war each other. |
| **`ha-beasts`** | — | New wild monsters to make evil regions genuinely dangerous. First beast: the **Gibberling**, a small blue feral goblinoid roaming in swarms of one to twenty that attacks every living thing on sight (`OPPOSED_TO_LIFE` + `CRAZED`). Standalone. |
| **`ha-adventure-hostility`** | — | Guarantees on-sight hostility between the suite's civilizations in adventure mode, including ancient dragons and their kobolds turning on a rival dragon adventurer unless yielded to. |

> **Note:** raw changes (`objects/`) only take effect in a **newly generated world**; a mod's
> `scripts_modactive/` scripts reload for an existing save. See
> [`instructions.md`](instructions.md) for deploy steps.
