<!-- GENERATED FILE — do not edit README.md directly.
     Composed by `make readme` from README-HEADER.md, FORTRESS_MODE_FEATURES.md,
     ADVENTURE_MODE_FEATURES.md and HIGH_ADVENTURE_FEATURES.md.
     Edit those instead; anything written here is overwritten on the next build. -->

# dfhack-commands

A personal pack of **DFHack scripts** for the latest Dwarf Fortress (0.53.x / Steam),
plus the **Dwarf Fortress: High Adventure** content-mod suite.

- Scripts live in [`dfhack/`](dfhack/), in folders that mirror the deployed tree —
  `fort/`, `adv/`, `embark/`, `fix/`. The folder is the command prefix: `fort/auto-name`,
  `adv/reveal`. Copy them into `dfhack-config/scripts/` and they become commands.
- Content mods live in [`content-mods/high-adventure/`](content-mods/high-adventure/).
- Things that don't work yet are kept out of this list — see
  [`BROKEN_FEATURES.md`](BROKEN_FEATURES.md).
- **Full command reference, implementation notes and TODOs:**
  [`DEVNOTES.md`](DEVNOTES.md). Repo/workflow quickstart: [`instructions.md`](instructions.md).

## Turning it all on — `magnus-scripts`

`magnus-scripts` is the switch for the whole pack. Run it once per session — or add it to
`dfhack-config/init/dfhack.init` and forget about it — and every always-on helper below is
enabled at once: the notification overlays, the watchdog services, the map and stockpile
tools. Anything destructive or situational is deliberately left out and stays a command you
run by hand.

```sh
magnus-scripts          # enable the always-on helpers for this session
magnus-scripts lovely   # ...plus a batch of stock DFHack tools and a few extras
```

It is safe to re-run at any time: each helper it starts is idempotent, and it disables and
re-enables its own services rather than stacking them.

---

# Mining, Building, and Zones

### **`fort/dig-shapes`**
Right-click to dig; drag shapes that automatically become staircases, constructions, mining,
chopping or removal.

### **`fort/dig-building`**
A searchable building picker while digging that drops you straight into DF's placement flow.

### **`fort/right-click-cancel`**
Drag to designate, right-drag to erase, right-click to cancel — for every designation and
build tool.

### **`fort/plan-tile`**
Drag to place a whole grid of a building at once while planning, tiled by its footprint so
copies sit edge-to-edge.

### **`fort/stockpile-place`**
Drag to create a stockpile, expand a selected one, or erase tiles from any pile.

![fort/stockpile-place demo](demos/stockpile-place.gif)

### **`fort/binnable-stockpile`**
Stockpiles can be toggled on/off with one click, set to all meltables, binnables, food, or
drink, and easily set allowed quality.

### **`fort/auto-tomb`**
Drops the right zone onto furniture: a tomb on every coffin, a pasture on every nest box.

# Fortress Management

### **`fort/quick-order`**
Type plain text on the Work Orders screen to create a legal manager order, with "keep N in
stock" repeats.

### **`fort/planner-orders`**
Warns of planned buildings nothing produces and offers the orders to make them.

### **`fort/labor-groups`**
Tidies the Labor screen and creates any missing crafting work details.

### **`fort/auto-name`**
Names each migrant wave to share a starting letter (wave 1→A, 2→B, …), gender-correct.

# Military & Squads

### **`fort/dwarf-rts`**
Command squads like an RTS: pick with number keys, click to move or attack, drag a box to
order a group.

### **`fort/military-labor`**
Keeps the "Military" work detail matched to your standing squads.

### **`fort/civilian-militia`**
Packs office-holder civilian squads into ready and reserve squads on command.

### **`fort/training-barracks`**
Marks one barracks as the fort's training barracks and assigns every squad to train there.

### **`fort/squad-buttons`**
A Squads-screen button that selects or deselects all squads.

# Animals

### **`fort/auto-pasture`**
Auto-pens new tame animals, warns when a pasture is overcrowded, and adds graze/butcher
buttons to caged animals.

### **`fort/butcher-shop`**
Bulk-marks animals for slaughter, grouped by species and sex, with last-breeder warnings.

### **`fort/animal-training`**
Assigns a trainer to many caged animals at once.

### **`fort/wild-animal-train`**
Marks a wild animal for taming, so it's trained the moment it's caught.

# Automation

### **`fort/idle-smiths`**
Lets idle dwarves work the forge to satisfy their craft need, picking legal metals per item.

### **`fort/auto-mandate`**
Fills Make mandates with cheap materials (even minting coins) and prioritizes the work.

### **`fort/auto-elf-chop`**
Keeps tree-cutting under the elves' yearly limit by designating the nearest trees itself.

### **`fort/broker-ready`**
Frees a soldier broker to trade, then puts their squad back on duty afterward.

# Information

### **`fort/creature-description`**
Shows a creature's full description (great for forgotten beasts) with a categorized kill list.

### **`fort/item-description`**
Shows an item's full description instead of DF's truncated box.

### **`fort/statue-redirect`**
Opens a statue's full item description, and adds a Remove button to built items.

# Searchable Lists

### **`fort/noble-symbol-search`**
Adds search to the noble symbol-assignment list of tens of thousands of items.

### **`fort/squad-equipment-search`**
Adds a search box to the squad-equipment item picker.

### **`fort/announcement-search`**
Adds search to the huge Announcements settings list.

# Notifications

### **`fort/agitated-animals-notification`**
Names the agitated animals by species instead of a bare count; shift-click attacks them all.

### **`fort/enemies-inside-notification`**
Warns of enemies inside the alert burrow; shift-click sends selected squads to attack.

### **`fort/trader-notification`**
Counts down how many days the trader is ready; click to jump to the depot.

### **`fort/empty-labor-notification`**
Warns when a restricted work detail has nobody who can actually do it.

### **`fort/needs-tomb-notification`**
Alerts when a dwarf dies with no tomb; click for a death browser with cause, kills and a
clickable family tree, and queue memorial slabs in bulk.

### **`fort/civ-alert-notification`**
During a civilian alert, warns who's still outside the safe burrow; click to find them.

### **`fort/raid-notification`**
Tracks squads out raiding with a rough ETA, and unsticks them weekly.

# Embark

### **`fort/embark-prep`**
Prepare-carefully buttons that give a dwarf the office skills, plus a preferences view.

# One-time-commands

### **`fort/cheatmine`**
Instantly finishes all designated digging and any planned staircases (cheat).

### **`fort/force-more`**
Forces attack events the stock `force` can't, like real forgotten-beast cavern attacks.

### **`fort/destroy-forbidden`**
Destroys loose forbidden items lying on the ground.

### **`fort/clear-flows`**
Clears miasma and other flow clouds — a quick FPS fix.

### **`fix/raiders`**
Rescues squads and soldiers stuck on off-site raids.

### **`fort/raid-status`**
Reports raiding parties and a rough travel estimate, and retrieves stuck units.

### **`fort/caravan-teleport`**
Teleports a stranded merchant caravan back onto the depot.

### **`fort/worldgen-setup`**
Sets up a fresh test world: selects every installed mod and maxes the civilization/site
sliders from data, so only the Create-world click is left to you.

# Miscellaneous

### **`fort/gen-world`**
Drives world creation from the title screen, writing the mod list and all five sliders as
data and clicking only the buttons that have no data equivalent.

### **`fort/ha-census`**
Reports a freshly generated world's population at years 1/25/50/75/100, civ counts, sites and
castles, and the terrain each civ settled. Run it straight after generation, before saving.

# Adventure mode features

### **`adv/map-travel`** 
Allow clicking to travel more than 1 tile in fast travel, like in
  non-fast-travel.

![adv/map-travel demo](demos/adv-map-travel.gif)

### **`adv/reveal`** 
Adventure mode reveal only when not in combat. You can easily navigate around
  a castle, dark goblin pit, dwarven fortress, or find a lair, and then not get an advantage in
  combat. It automatically re-enables when you leave fast traveling.

![adv/reveal demo](demos/adv-reveal.gif)

### **`adv/always-be-satiated`** 
Automatically eat and drink (non healing potions) when not in
  combat.

![adv/always-be-satiated demo](demos/adv-always-be-satiated.gif)

### **`adv/keep-inventory`** 
Automatically reopen the inventory and scroll to the last position
  when you use it.

![adv/keep-inventory demo](demos/adv-keep-inventory.gif)

### **`adv/keep-talking`** 
Automatically reopen a conversation you are participating in.

![adv/keep-talking demo](demos/adv-keep-talking.gif)

### **`adv/read-the-map`** 
Allow hovering over sites to learn about them in fast travel.

![adv/read-the-map demo](demos/adv-read-the-map.png)

### **`adv/right-click-move`** 
Right clicking (if it gives no other options) automatically
  initiates movement, dismissing when the game annoyingly asks for two confirmations. Saves 3
  mouse clicks / key presses for a basic action.

![adv/right-click-move demo](demos/adv-right-click-move.gif)

### **`smooth-movement`** 
Smooth camera panning in adventure mode, and smooth movement for
  creatures and the player in adventure mode. (A C++ plugin rather than a script — install it
  with `make install`.)

![smooth-movement demo](demos/adv-smooth-camera.gif)

### **`adv/im-sure`** 
Automatically dismiss "you haven't acted in a while" for long-running move
  commands.

![adv/im-sure demo](demos/adv-im-sure.gif)

# Adventure mode embark features

### **`embark/adventurer-values`** 
Modify adventurer needs easily when you create your adventurer
  — so you can make a barbarian who loves to fight or avoid the impossible-to-satisfy Intense Need
  For Family (without memorizing which values affect which needs, where they are in the list,
  etc).

![embark/adventurer-values demo](demos/embark-adventurer-values.png)

### **`embark/adventurer-default-items`** 
Automatically give you a decent starting gear loadout
  when creating an adventurer, and let you switch metals on your gear more easily.

![embark/adventurer-default-items demo](demos/embark-adventurer-default-items.png)

# Dwarf Fortress: High Adventure

A family of new-content mods adding several playable civilizations, designed to work
**together or individually**. Source lives in
[`content-mods/high-adventure/`](content-mods/high-adventure/) — one folder per mod, each with
its own `CHANGES.md`. Design rules and fork provenance are in
[`content-mods/README.md`](content-mods/README.md); the other folders under `content-mods/` are
Steam-Workshop reference and fork sources, not part of the suite.

> **Raw changes (`objects/`) only take effect in a newly generated world.** A mod's
> `scripts_modactive/` scripts reload for an existing save, and graphics come from that world's
> baked snapshot. See [`instructions.md`](instructions.md) for deploy steps.

# ha-playable-civs

Play as dwarves, humans, elves or goblins. A fork of *All Races Playable Redo*.

### Fortress mode
Goblins gain bronze-working and a single autumn caravan, so a goblin fort is supplied rather
than starved.

### Adventure mode & world
Vanilla kobolds are deliberately excluded — they embark broken. `ha-kobolds` supplies the
playable kobold civ instead.

### Scripts
`playable-civs.lua`

# ha-high-elves

Elf artisans who mine and forge like dwarves but never fell a tree.

### Fortress mode
They grow their wood at the **Shaping Tree** and catch starlight for **twinkling metal**, and
they never take a fey mood. Champions carry divine metal arms and armour.

### Adventure mode & world
Forest-founded and pinned to one town per civ, so they stay rare and reclusive.

### Scripts
`high-elves.lua` — raws cannot reference procedurally generated materials, so the script runs
at world load, finds the world's generated `[DIVINE]` inorganics, filters them by adjective and
adds them to the high-elf civs' entity resources. Gear minted during worldgen therefore won't
be divine; everything equipped after first load will be.

# ha-drow

Evil matriarchal elves in insular mountain fortresses.

### Fortress mode
Scimitars and bows, no shields at all, any metal forged, escorted by tame giant cave spiders.

### Adventure mode & world
Mountains and forests only, and almost nothing ever reaches them.

### Castes
**4% are born driders** — a drow torso on a giant-spider body, with paralytic venom and webs.

### Scripts
`drow.lua`

# ha-illithids

Ageless psionic brain-eaters.

### Fortress mode
Robed but never armoured — a script enforces it.

### Adventure mode & world
Ten psionic interactions that scale with scholarship, from isolated mountain dark fortresses
that trade with nobody.

### Castes
**Illithid**, **ulitharid**, **Elder Brain** and **thrall**.

### Workshops & reactions
The **Neural Bath**: devouring brains, implanting tadpoles, ascension, and coalescing an Elder
Brain.

### Scripts
`illithids.lua`

# ha-orcs

Warlike orcs who work pure metals only — no alloys, no steel, iron above all.

### Fortress mode
Ruled by a warband hierarchy.

### Adventure mode & world
Savanna and scrubland hamlets, hostile to everyone — the evil bloc included.

### Castes
**One in five is a skull-cruncher champion**: pain-immune and frequently raging.

### Workshops & reactions
The **Breeding Pit**.

### Scripts
`orcs.lua`

# ha-dark-dwarves

Carnivorous cannibal dwarves with ironclad in-group loyalty.

### Fortress mode
They never tantrum, and trade with the evil bloc in winter.

### Adventure mode & world
Child-snatchers who sap fortress walls with great picks, living in deep mountain halls and
never hillocks.

# ha-succubi

Demonic realm-builders. A fork of *Succubus Dungeon*.

### Fortress mode
Corruption, summoning, bone-working and magma-well workshops. They keep the full demonic
wardrobe but fight with vanilla arms.

### Adventure mode & world
Desert city-builders with land-holding Demon princes, outdoor fortifications, and summer-only
evil-bloc caravans.

### Scripts
`succubi.lua` (plus an internal `magmawell-debug.lua`)

# ha-kobolds

The playable kobold civ: a fork of *Cute Kobold Caverns* with *Skulking Filth*'s item-thief
hard mode.

### Fortress mode
Sometimes ruled by an **Ancient Dragon**, whose eldest becomes the **Dread Wyrm** king.

### Adventure mode & world
Ancient Dragons also lair the world as megabeasts.

### Castes
Ancient Dragons come in one-, two- and three-headed castes, with spiked or clubbed tails.

# ha-second-humans

A second, independent human civilization identical to the vanilla one, giving humans two
placement draws to an orc civ's one. The two human realms can war each other.

Adds no creature and touches no vanilla raws — it is regenerated from vanilla by
`sync_from_vanilla.py`.

# ha-beasts

Wild monsters to make evil regions genuinely dangerous. Standalone — it adds no civilization.

First entry: the **Gibberling**, a feral blue goblinoid that roams in swarms and attacks
everything alive.

# ha-adventure-hostility

Guarantees on-sight hostility between the suite's civs, including a kobold civ's dragons
turning on a rival dragon adventurer unless yielded to.

### Scripts
`adventure-hostility.lua` and `war-gear.lua` — the shared outfit engine for the suite.

# high-adventure — the all-in-one bundle

Every `ha-*` mod merged into a single mod, so one entry in the mod picker installs the whole
suite. It is **generated, never hand-edited**:

```sh
cd content-mods/high-adventure
python3 build-high-adventure.py
```

Re-run it after bumping any member mod, and bump the bundle's own version too — DF keys its
snapshot by `<MOD_ID> (numeric_version)`, so a rebuild that reuses the old number leaves DF
serving the previous snapshot with the contents silently changed.

