<!-- GENERATED FILE — do not edit README.md directly.
     Composed by `make readme` from README-HEADER.md, FORTRESS_MODE_FEATURES.md,
     ADVENTURE_MODE_FEATURES.md and HIGH_ADVENTURE_FEATURES.md.
     Edit those instead; anything written here is overwritten on the next build. -->

A personal pack of **DFHack scripts** for the latest Dwarf Fortress (0.53.x / Steam),
plus the **Dwarf Fortress: High Adventure** content-mod suite.

## Install

```sh
git clone https://github.com/magnus-ISU/dfhack-commands
cd dfhack-commands
make install     # scripts + content mods + plugins
```

Then restart Dwarf Fortress, and in the DFHack console run:

```sh
fort/magnus-scripts
```

That opens the switchboard — a checkbox per helper in this pack. Click rows to turn things
on or off; your choice is saved and re-applied on every map load, so it is a one-time setup.
Press `r` if you just want everything on.

Non-standard install path, installing individual scripts by hand, or the rest of the
arguments: [`SETUP_INSTRUCTIONS.md`](SETUP_INSTRUCTIONS.md).

## Where things are

- Scripts: [`dfhack/`](dfhack/) — `fort/`, `adv/`, `embark/`, `fix/`. The feature lists
  below cover what each one does.
- Content mods: [`content-mods/high-adventure/`](content-mods/high-adventure/).
- Things that don't work yet: [`BROKEN_FEATURES.md`](BROKEN_FEATURES.md).
- Full command reference, implementation notes and TODOs: [`DEVNOTES.md`](DEVNOTES.md).
  Repo/workflow quickstart: [`instructions.md`](instructions.md).

---

<details>
<summary><h1>Fortress mode</h1></summary>


## Mining, Building, and Zones

### **`fort/channel-safely`**
Channel a big hole without caving your fort in. Every channel designation is suspended the
instant it appears, then fed back to the miners a few tiles at a time in an order the tool can
prove is safe: at most eight tiles out of the blueprint at once, never two of them touching, and
each one picked with the previous ones imagined as already channelled out. A tile is only let
out if digging it leaves nothing without support — support runs along the four sides and up from
the rock below, never through a corner — and if every other designated tile still has somewhere
to stand that connects out of the excavation. Tiles that are out get restricted traffic so
nobody wanders onto them, and their old traffic setting is restored afterwards. A shape with no
safe order, like a ring drawn around floor that is not itself designated, simply stays planned.
Priority 1 designations are never touched, and `fort/channel-safely why <x> <y> <z>` explains
any tile's verdict. Enabled by `magnus-scripts`.

![fort/channel-safely demo](demos/fort-channel-safely.gif)

### **`fort/builder-burrow`**
Turn a burrow into a district. Pick a burrow, a preset (hovels, 2x2 or 3x3 housing, luxury
housing, varied housing, noble quarters, tombs, temples, guildhalls) and when to build, and the
burrow is planned on the level you are looking at: roads grow from wherever the burrow touches
your dug floor, one segment at a time, each segment dressed with statue rows and plazas and lined
with districts as it is laid; a road with nothing along it is refused; a second pass fills the
leftover frontage; noble suites and guild complexes are placed as suites with one door on the
road. Then every room, road and hallway piece is started as a `fort/quickfort` job, so digging,
digging,
smoothing, engraving and furniture sequence themselves per tile, and the three blueprints that
want a given square wait for each other on it — a mine designation and a smooth designation never
share a tile, because DF works the smoothing, the mining never happens, and the wall just stays. Each stamp declares the activity zone its
room carries (`zone = 'b'`/`'o'`/`'h'`/`'T'` in the preset), and the blueprint gets a `#zone`
section next to its dig, smooth, engrave and build sections — bedrooms, offices, dining rooms and
single-coffin tombs. A catacomb or family tomb declares none and is left to `fort/auto-tomb`,
which zones each coffin separately; auto-tomb stands off any tile a running plan is about to zone,
so the two never race. New stamps added in the preset editor start with the zone their furniture
implies. The burrow's outer ring is never
dug and nothing outside it is touched. Confirming closes the picker immediately and plans in
the background, a slice of a frame at a time, so the game keeps running while the rooms appear;
progress goes to the console and the summary is announced in game. Only "apply now" exists so far. "New preset" and "Edit
preset" open a three-column editor: actions and the settings of the selection, the passes with
their districts and blueprints, and the blueprint library filtered by what is being edited; Enter
on a library entry adds it. Presets save to `dfhack-config/scripts/data/builder-burrow/presets.json`
and copy and paste as JSON through the system clipboard, the same JSON the browser prototype in
`prototypes/burrow-stamper` produces. `fort/builder-burrow status` lists the plans made for this
fort.

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
drink, and easily set allowed quality. The meltables pile only accepts the metals your civ
works, so adamantine, divine metals and mod metals never reach the smelter.

### **`fort/stable-stockpile-bins`**
Keeps the max bins/barrels/wheelbarrows you set on a stockpile from silently resetting the
next time anything touches its filter. Caps DF can no longer honour — the container stopped
applying, or your number no longer fits on the pile's tiles — go back to being DF's, as does
a pile you give no type (the "None" icon, or clearing it out in Custom settings).

### **`fort/auto-tomb`**
Drops the right zone onto furniture: a tomb on every coffin, a pasture on every nest box.

## Fortress Management

### **`fort/planeswalkers`**
Carry a whole fort between worlds. `fort/planeswalkers save` snapshots the current fort —
terrain (with veins, sand/soil, the grass cover — surface grasses and the
cavern mosses, fungi and lichens alike — and, on a same-size embark, the whole column down
through the magma sea and hell; the destination keeps its own demons), adamantine spires
carried as real spires with their contents — the demon wave waiting in each hollow, the
divine treasures, the encased horrors and magma/water pockets, each with its trigger tiles
and whether it already went off — while the destination's own spire contents under the fort
are removed before the terrain lands, so the load itself can never set them off —
constructions, buildings, stockpiles with their
settings, zones, items (with containment, quality, decorations, and maker), artifacts (named,
with their descriptions and full artifact status — value, quality and the Objects screen —
even on pedestals, with their engraved images redrawn from what they depict), room and
office assignments and the guildhalls/temples/libraries/taverns behind meeting areas,
squads (members, uniforms, ammunition, barracks) and their commander and captains, work details
and labour assignments, burrows, trees and shrubs (re-planted and regrown where they stood), the
manager's work-order queue, locked doors and hatches, retired adventurers
(unretirable on arrival), and every unit with skills, personality, appearance, family ties,
kill tallies by species, clothing ownership, and the surrounding historical-figure web — into
`dfhack-config/scripts/data/planeswalkers/<name>/`. On a fresh embark in ANY other world
(same or larger embark size), `fort/planeswalkers load <name>` wipes the footprint
(including the embark's own buildings — the wagon is dismantled, its supplies dropped)
and rebuilds the fort there, dwarves and all. Everything is stored as raw tokens, so worlds
with the same mod set restore near-losslessly; content the destination world lacks (modded
materials, procedurally generated races and their materials, a deity's divine gear, necromantic
secrets) is substituted with the closest equivalent or skipped with a report. Carried spires are laid
down as plain raw-adamantine veins, which survive retire and reclaim; their contents are carried
as DF's own hidden-fun-stuff records. Make a manual DF save before loading — there is no
rollback. An in-game announcement tells you when the save is written and when the fort has
been restored. Run it with no arguments for a walkthrough, or `help fort/planeswalkers` for
the full description. A fort restored into a larger embark than it came from is saved again
at its original size and area, so it keeps travelling to embarks of its own size. `list`,
`delete <name> --yes` (deletes only the snapshot folder), `spires` (re-arm the carried spires
on a fort restored before that pass existed), `status`, and `cancel` round out the set.

### **`fort/workshop-tools`**
Puts a `+` on every queued workshop task that queues another one just like it, and sorts
a shop's "Add new task" list so the jobs you can actually do come before the ones you can't.

### **`fort/quick-order`**
Type plain text on the Work Orders screen to create a legal manager order, with "keep N in
stock" repeats. Only offers subtypes your civilization actually knows how to make.

![fort/quick-order demo](demos/fort-quick-order.gif)

### **`fort/planner-orders`**
Warns of planned buildings nothing produces and offers the orders to make them. With a hospital
up it also stocks the supplies one needs, traction benches included — the bench and its table,
mechanism and chain each get their own ask.

![fort/planner-orders demo](demos/fort-planner-orders.gif)

### **`fort/labor-groups`**
Tidies the Labor screen and creates any missing crafting work details.

### **`fort/choose-labor-icon`**
Pick a work detail's icon from a grid of the actual icons instead of cycling DF's little
selector one at a time.

![fort/choose-labor-icon demo](demos/fort-choose-labor-icon.png)

### **`fort/auto-name`**
Names each migrant wave to share a starting letter (wave 1→A, 2→B, …), gender-correct. A name
it hands out is never one already in use by anybody in the fort — if the pool ever runs dry it
numbers them instead (Aulus II, Aulus III, …).

## Military & Squads

### **`fort/dwarf-rts`**
Command squads like an RTS: pick with number keys, click to move or attack, drag a box to
order a group.

### **`fort/military-labor`**
Keeps the "Military" work detail matched to your standing squads.

### **`fort/training-barracks`**
Marks one barracks as the fort's training barracks and assigns every squad to train there.

### **`fort/squad-buttons`**
A Squads-screen button that selects or deselects all squads.

## Animals

### **`fort/auto-pasture`**
Auto-pens new tame animals, warns when a pasture is overcrowded, and adds graze/butcher
buttons to caged animals.

### **`fort/autobutcher`**
Replaces the stock `autobutcher` plugin and its GUI. One number per species -- how many
ADULTS you want -- instead of four (female kids, male kids, female adults, male adults),
and nothing is butchered until the herd grows past it: then males first, down to a floor
of four, then females. Click the number to type one, the arrows to nudge it, `[edit]` for
the per-species rules the plugin hardcodes -- keep the N oldest (so a herd can age while
every new adult goes to the butcher), infertile first, oldest or youngest first, war
animals last, a juvenile limit, a custom adult age. War-trained, chained and zoo-caged
animals are excluded from the reckoning entirely by default. Small numbers behave
differently on purpose: 2-4 keeps one male and the rest females and never butchers the
last breeding pair, 1 turns the left buttons into `[m] [f]` for which sex survives, and 0
turns them into a `[kids:cull|grow]` toggle. Marks it made it takes back off if you raise
a limit; marks you made by hand it never touches.

### **`fort/butcher-shop`**
Bulk-marks animals for slaughter, grouped by species and sex, with last-breeder warnings. Young
get their own rows and stay hidden until you ask for them (Ctrl-Y).

### **`fort/animal-training`**
Assigns a trainer to many caged animals at once.

### **`fort/wild-animal-train`**
Marks a wild animal for taming, so it's trained the moment it's caught.

## Automation

### **`fort/idle-smiths`**
Lets idle dwarves work the forge to satisfy their craft need, picking legal metals per item.
Soldiers whose squad is under orders are left to those orders.

### **`fort/auto-mandate`**
Fills Make mandates with cheap materials (even minting coins) and prioritizes the work.
Each order it queues is announced — who mandated it, and what was ordered.

### **`fort/auto-elf-chop`**
Keeps tree-cutting under the elves' yearly limit by designating the nearest trees itself.

### **`fort/harvest-plants`**
Posts a gathering job on every shrub standing in a Gather Fruit zone once a month, instead of
waiting for the zone to trickle a few tiles out at a time — vegetables and fruitless plants
included, not just what DF picks on its own. Tiles DF has already posted a job on are skipped,
so nothing is ever doubled up. A `[Harvest]` button on the zone panel, below the three gather settings,
turns a zone's auto-posting off and on and acts immediately: on posts that zone's jobs there
and then, off pulls its outstanding gathering jobs back out of the queue (anything a dwarf
already picked up is left to finish). It is on by default, and a zone with "Pick shrubs"
switched off is skipped. A tile whose job dies with the shrub still standing is retired for
the session, so an unreachable plant can't spam cancellations.

### **`fort/adamantine-hospital`**
Stops the hospital spending adamantine on bruises. DF gives a hospital no material filter, so
dressings and sutures happily consume adamantine cloth and strands. This watches the job list
and, the moment a treatment job has claimed adamantine cloth or thread, forbids that item and
cancels the job — the hospital re-issues the treatment and reaches for ordinary cloth, and
nothing is consumed. `adamantine-hospital release` hands the thread back to your smelter.

### **`fort/loyal-retirees`**
Brings a retired fortress's citizens home when you reclaim it. The roster is kept current as
dwarves join and leave, so whatever the fort looked like when you retired is what gets
summoned back — everyone still alive, however far they wandered.

DF only turns an off-map historical figure back into a real unit when an army carrying them
arrives, and armies can't be fabricated. So this fakes a diplomatic mission for one of your
nobles, lets DF mint the army for it, and puts the returnees aboard: they come back as their
original selves, with their skills, wounds, clothing and inventory intact. Progress is
reported in DF's own announcement log.

`loyal-retirees migrate <hf_id>...` uses the same machinery to summon anyone alive in the
world by historical figure id, whether or not they ever lived here.

![fort/loyal-retirees demo](demos/fort-loyal-retirees.webp)

### **`fort/broker-ready`**
Frees a soldier broker to trade, then puts their squad back on duty afterward.

### **`fort/rusty-legends`**
Keeps skill rust off a retired adventurer's every skill — matched on the nemesis
`ADVENTURER` flag, never a name or a skill count — and off any citizen's legendary
skills. Everything else rusts as normal. Swept once a game season. There is no stock
DFHack tool for this.

## Information

### **`fort/creature-description`**
Shows a creature's full description (great for forgotten beasts) with a categorized kill
list — each megabeast type by name, the cursed called out ahead of everything sentient
("1 goblin vampire, 2 kobold necromancers, 1 weremoose"), and sentient kills split by caste
("27 orcs, 9 orc champions, 5 illithids, 2 ulitharids"), with male/female castes grouped
together.

![fort/creature-description demo](demos/fort-creature-description.png)

### **`fort/item-description`**
Shows an item's full description instead of DF's truncated box.

![fort/item-description demo](demos/fort-item-description.png)

### **`fort/statue-redirect`**
Opens a statue's full item description, and adds a Remove button to built items.

![fort/statue-redirect demo](demos/fort-statue-redirect.gif)

### **`fort/clickable-noble-names`**
Makes the dead space on the Nobles screen live: click a noble's row to open their sheet
and follow them, or click one of the office/bedroom/dining/tomb icons to jump to that
room. DF's own assign and symbol buttons still work — the row is measured from the
render, so those blocks are handed straight back to DF.

### **`fort/clickable-squad-members`**
On a squad's details screen, clicking anywhere on a member's row — portrait or name — opens
that dwarf's sheet and follows them instead of offering to replace them. Clicking again,
while their sheet is the one on screen, falls through to DF's position-assignment list: see
who this is, then replace them. Empty positions and the row's own checkbox are untouched.

## Searchable Lists

### **`fort/noble-symbol-search`**
Adds search to the noble symbol-assignment list of tens of thousands of items.

### **`fort/squad-equipment-search`**
Adds a search box to the squad-equipment item picker.

### **`fort/announcement-search`**
Adds search to the huge Announcements settings list.

## Notifications

### **`fort/agitated-animals-notification`**
Names the agitated animals by species instead of a bare count; shift-click attacks them all.

### **`fort/enemies-inside-notification`**
Warns of enemies inside the alert burrow; shift-click sends selected squads to attack.

### **`fort/trader-notification`**
Counts down how many days the trader is ready; click to jump to the depot.

### **`fort/moody-items-warning`**
Warns when the fort has none of a material a strange mood might demand — stone, logs, leather,
plant/silk/yarn cloth, metal bars, rough or cut gems, blocks, bones, shells, and raw glass in
any type you have produced. A mood asks the moment it starts, so a gap found afterwards is a
berserk dwarf. With stressed dwarves in the fort it also checks remains and bones, which a
macabre mood wants. The list is taken from DFHack's `strangemood` plugin and cross-checked
against the wiki, not from memory.

### **`fort/empty-labor-notification`**
Warns when a restricted work detail has nobody who can actually do it. Stays quiet while
`autolabor` or `labormanager` is enabled, since those assign labors themselves.

### **`fort/needs-tomb-notification`**
Alerts when a dwarf dies with no tomb, or when anything is haunting the fort — a ghost counts
whether or not it was ever a citizen. Click for a death browser with cause, kills and a
clickable family tree, and queue memorial slabs in bulk.

### **`fort/civ-alert-notification`**
During a civilian alert, warns who's still outside the safe burrow; click to find them.

### **`fort/raid-notification`**
Tracks squads out raiding with a rough ETA, and unsticks them weekly.

## Embark

### **`fort/embark-prep`**
Prepare-carefully buttons that give a dwarf the office skills, plus a preferences view.

### **`embark/fast-dwarves`**
Opens a new fortress for you: skips the tutorial prompt, commits a dwarven origin civ, centres
the map on a scored spot near its halls, and clicks Embark. You place the fortress.

### **`embark/extra-info`**
Panel under DF's own, on the final placement step only: the adamantine spire count (or
`NO ADAMANTIUM` when there is none), salt or fresh water, the seven commonest stones (flux, coal and plaster called out) plus a count of
the rest, commonest wood, the wildlife, and **every** civ that can reach you — not vanilla's four.

### **`embark/assistant`**
Site finder, replacing the retired `embark-assistant` plugin. Bare `embark/assistant` opens a
window: type filters, press Enter, press Enter on a result to jump the map there. Filters cover
flux, coal, plaster, named metals and minerals, sand, clay, soil, rivers, aquifers, volcanoes,
biome, tree density, freezing, evil weather, savagery, evil, and neighbouring civs and towers by
name or count. `s` runs an ~11 s survey that adds **magma pools by cavern level**, which is not
world-wide data. Also works from the console — `embark/assistant help`.

## One-time-commands

### **`fort/civilian-militia`**
Packs office-holder civilian squads into ready and reserve squads on command.

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

## Miscellaneous

### **`fort/gen-world`**
Drives world creation from the title screen, writing the mod list and all five sliders as
data and clicking only the buttons that have no data equivalent.

### **`fort/ha-census`**
Reports a freshly generated world's population at years 1/25/50/75/100, civ counts, sites and
castles, and the terrain each civ settled. Run it straight after generation, before saving.

### **`fix/old-saves`**
Marks old-game-version saves on the title screen's Continue Game lists — DF itself only tells
you after you load. Every save last written by an *older* game version than the one running
gets its "Files" button repainted: a red **CRASH** when loading would cross a known
backwards-incompatible build (3600, 3602 — hover the stamp for the workaround: procedurally
generated syndromes may crash, exterminate/full-heal the carriers), or a yellow **!OLD!**
when it's merely older and expected to load fine. The version is read from each save's
`world.sav` header (DF's title-screen data doesn't carry it), and rows are identified by the
save's folder name so same-named copies of a world can't be confused. Run the command bare at
the title screen to print every save and its version.

![fix/old-saves demo](demos/fix-old-saves.png)
</details>

<details>
<summary><h1>Adventure mode</h1></summary>


## Adventure mode features

### **`adv/auto-save`** 
Save adventurer mode automatically. `adv/auto-save enable 20` to save every
  20 minutes, which is default. 1 hour must pass in-game between autosaves.

![adv/auto-save demo](demos/adv-auto-save.png)

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

### **`adv/appraiser`** 
Item values appear directly below each item's weight in the inventory and pick-up lists, at
  the precision a fortress broker gets: no Appraiser skill shows only `?`, ratings 1–5 show
  estimates rounded *up* the 1-2-5 ladder (140☼ → `~200`, 501☼ → `~1000`), 6–10 two
  significant figures (`~350`), 11–14 three
  (`~347`), and Legendary (15+) is exact. The skill
  trains as an adventurer plausibly would: +200 xp for a *completed purchase* with a partner
  you haven't traded with before (goods must actually reach your hands), +10 xp for handling
  a coin minting you haven't seen, checked once per in-game day — judged against rolling
  last-20 lists (persisted in the save) so the checks stay cheap.

### **`adv/inventory-display-weight`** 
Show every item's weight in the inventory list and the pick-up menu.

![adv/inventory-display-weight demo](demos/adv-inventory-display-weight.png)

### **`adv/inventory-search`** 
Search the inventory list (Alt-S) by item description, material or type.
  Magic words: `heavy` sorts by weight, `equip`/`equipped` shows equipped items
  (hands always first, then strapped weapons/tools, containers last), `food` shows food and drink (drinks, food,
  healing drinks, healing food, then ethics-refused sapient flesh; containers
  excluded), `healing` shows food/drink with beneficial syndromes. One-click presets on the
  bar type them for you: `[Food] [Heal] [Book] [Heavy]`. The unsearched list
  displays in the equip order by default. keep-inventory reopens keep the filter.

![adv/inventory-search demo](demos/adv-search-inventory.png)
![adv/inventory-search sort demo](demos/adv-sort-inventory.png)

### **`adv/travelling-hunger`** 
Show how many meals, drinks and 8-hour sleeps you need on the fast-travel screen's top row.

### **`adv/heat-ice`** 
Sort "heat ice" / "heat snow" options to the top of interact menus.

![adv/heat-ice demo](demos/adv-sort-ice.png)

### **`adv/fort`** 
Do fort jobs in adventure mode — the self-contained, overlay-based successor to
  the retired `adv/advfort` (a community rework of DFHack's `gui/advfort`): jobs
  trigger on CAREFUL move or an adjacent click; Smooth/Engrave really smooth
  (designation + tiletype fallback); Fell Tree really fells trees (axe-skill-timed
  work, one log per trunk tile, Wood Cutter exp); recipes default to your civ plus
  the site owner's, with permitted custom workshops tagged by owning civ; the
  "you haven't acted in a while" prompt is auto-dismissed. The menu lives on the left border as
  a real overlay: nothing else is intercepted, so right-clicks and the native
  toolbar work directly and the window never blinks closed and reopens. At most
  ONE auxiliary panel opens to the menu's right at a time — the build picker
  (with its materials section built into its bottom), the workshop job menu, or
  a job's materials list — each searchable like fort/dig-building; picking a
  specific item for a slot opens a modal picker that takes complete focus until
  chosen or canceled (Esc/right-click). A job engine pumps work automatically
  (jobs can't start and silently stall), cancels the job if you leave its reach
  instead of orphaning it, auto-resumes interrupted-but-valid jobs, and sweeps
  stuck leftovers when the tool opens. Mouse job clicks are same-z only — the
  floor seen through a channel is walked to, not channeled (Ctrl+D/E for jobs
  below/above); standing inside a planned building's footprint is fine (the job
  anchors at your tile and you're stepped off a finished building that would
  seal you in); Use Workshop never captures a click or opens its menu unless
  you stand within 1 tile of the building's center, where jobs can actually
  run. On the map, Enter does the selected action at the look cursor, opening
  look mode first if it isn't up. Ctrl+Q quick mode, Shift+R/T cycle jobs.
  `adv/fort` shows, `adv/fort hide` hides, jobs keep running.

![adv/fort demo](demos/adv-fort.gif)

### **`adv/exhaustion-meter`** 
Combat-exertion bar with the native blood meter's manners and placement:
  invisible while you're fine, appearing in the blood meter's bottom-left
  corner once exertion matters, empty = you collapse. Tracks the counter built
  by attacking/sprinting/jumping that knocks you over mid-fight (DF shows no
  meter for it): yellow at Tired (2,000), red at Exhausted (4,000), empty at
  the ~6,000 falling-over point; decays when you stop exerting. Overlay
  `adv/exhaustion-meter.meter`, enabled by default (gui/overlay moves it).

### **`adv/posession`** 
[Regain your weapon] button on the "Who will you attack?" screen while you are
  struggling over possession of a weapon (grabbed from you, or stuck in someone
  pulling on it): one click selects whoever shares the weapon with you and
  initiates the native possession-struggle Wrestle attack. Dormant otherwise;
  overlay `adv/posession.regain`, enabled by default.

### **`adv/keep-talking`** 
Automatically reopen a conversation you are participating in.

![adv/keep-talking demo](demos/adv-keep-talking.gif)

### **`adv/read-the-map`** 
Allow hovering over sites to learn about them in fast travel.

![adv/read-the-map demo](demos/adv-read-the-map.png)

### **`adv/world-map-features`** 
Middle-drag the travel map to pan it, and search everything your adventurer
  knows from a bar centred on the top row (Alt-F): sites you have heard of, people (placed
  where the world says they are, since a name reaches you with its story), your bestiary,
  regions, groups, carried rumours and artifacts kept or held by what you know. Rows show a category, distance
  and bearing; clicking one types its name into the bar, and whenever the text exactly names
  something the list folds away and the map draws a dotted line to it (the line is purely a
  reading of the bar -- clear the text and it goes), ending in a bordered card describing the
  target: read-the-map's own hover card for a site or region, one of the same shape for
  anything else, drawn at the map's edge when the target is beyond it. Typing a TYPE finds everything of it you know -- `vault`, `rabbit devil`,
  `high elf` (which also finds high elf sites); sites and civilizations always carry a
  bearing, and the exact name of an undiscovered site, artifact or person points at it too.
  Names match in either rendering (translated or native), first-and-last-name is enough
  without the epithet, accented letters are typed as plain ascii, and true names learned
  from slabs are searchable -- a demon is findable by what its slab calls it. On the
  world map, clicking a site types its name in. `site:`/`person:`/`beast:`/
  `region:`/`group:`/`event:` narrows the search. DF has no camera for this map, so the pan
  moves what DF thinks the centre is (`travel_origin`) only between update and render, and
  moving (or Esc) drops it -- `world-map-features recenter` if one ever sticks. The pan
  stops at the world edges: a centre outside the world crashes DF.

### **`adv/right-click-move`** 
Right clicking (if it gives no other options) automatically
  initiates movement, dismissing when the game annoyingly asks for two confirmations. Saves 3
  mouse clicks / key presses for a basic action.

![adv/right-click-move demo](demos/adv-right-click-move.gif)

### **`adv/grab-stacks`** 
One click grabs a whole stack. Clicking a stack in the pickup menu
  ("Get copper coins [512]") normally opens a mouse-only "Pick up how many?" screen — an
  extra click for the answer that is almost always "all of them". With this running, clicking
  a stack anywhere *except* its [N] count skips that screen and takes the full stack; click
  the [N] itself to choose an amount as before. On the amount screen, Enter or any letter key
  now accepts the shown number too.

![adv/grab-stacks demo](demos/adv-grab-stacks.gif)

### **`adv/enemy-recenter`** 
While you're in combat (by the same judgement `adv/reveal` and
  `adv/always-be-satiated` use), a "Recenter on enemy" button appears directly above DF's own
  "Recenter on yourself" button, wearing the same graphic. Click it and the camera jumps to
  the foe that put you in combat, with a selection box (`fort/dwarf-rts`'s art) flashing on
  that unit; multiple foes cycle click by click. DF's own button right below takes you home,
  so the pair reads as one rocker: enemy above, yourself below.

### **`adv/watch-their-blade`** 
The attack screens show a combat summary under each name — every
  candidate on the "Who will you attack?" chooser, and your target on the attack
  screens after you pick: their wounds ("Faint, Heavy Bleeding"), worn armor
  ("iron greaves, iron breastplate") and what they are holding, by hand ("Left
  hand silver carving knife, right hand copper whip") — including sheathed
  weapons. Pick your target, and your fight, with open eyes.

![adv/watch-their-blade demo](demos/adv-watch-their-blade.png)

### **`smooth-movement`** 
Smooth camera panning in adventure mode, and smooth movement for
  creatures and the player in adventure mode. (A C++ plugin rather than a script — install it
  with `make install`.)

![smooth-movement demo](demos/adv-smooth-camera.gif)

### **`adv/fear-no-goblin`** 
Fast travel into, out of and past goblin dark pits. DF refuses travel while you stand in one
and bumps you off the world map when your route crosses one; this presents every pit within
one world tile (tracked even mid-travel via your army's position — pit clusters form walls,
so all of them must open at once) as a town for exactly as long as you are playing. The patch
lifts the moment you leave the play screen, restores on world unload, and the real site types
are recorded in dfhack persistence *inside the save itself* before anything is touched — a
save that catches the patch necessarily catches the recovery record, and the next load heals
the world automatically. Always-on via its overlay; `adv/fear-no-goblin stop` pauses it.

### **`adv/im-sure`** 
Automatically dismiss "you haven't acted in a while" for long-running move
  commands.

![adv/im-sure demo](demos/adv-im-sure.gif)

### **`adv/makeown`** 
Recruit the selected unit as a core party member, preserved after retiring. `-extra` makes them a follower you can't take control of.

## Adventure mode embark features

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

### **`embark/adventurer-map`**
Show information about sites on the world map during adventurer creation. Clicking on a
site changes your origin to there, if possible.

![embark/adventurer-map demo](demos/embark-adventurer-map.gif)
</details>

<details>
<summary><h1>Dwarf Fortress: High Adventure</h1></summary>


A family of new-content mods adding several playable civilizations, designed to work
**together or individually**. Source lives in
[`content-mods/high-adventure/`](content-mods/high-adventure/) — one folder per mod, each with
its own `CHANGES.md`. Design rules and fork provenance are in
[`content-mods/README.md`](content-mods/README.md).

> **Raw changes (`objects/`) only take effect in a newly generated world.** A mod's
> `scripts_modactive/` scripts reload for an existing save, and graphics come from that world's
> baked snapshot. See [`instructions.md`](instructions.md) for deploy steps.

## Playable Civs

The vanilla civilizations made playable. Humans, elves and goblins can be played in fortress
mode, and every one of them — plus kobolds — can be rolled as an adventure-mode outsider. A fork
of *All Races Playable Redo*.

### Fortress mode
Humans become playable by gaining the full slate of fort noble positions they were missing, so
a human fort can appoint a mayor, manager, bookkeeper and the rest exactly as any other does.
Otherwise they play as the game already imagines them.

Elves gain those positions too, and the Shaping Tree besides, because a civilization that
refuses to fell a tree still needs wood. A shaper plants a seed into a living tree and the
workshop grows around its trunk under the open sky; from then on it yields wood on its own,
and a skilled strand extractor coaxes far more out of the same tree than an unskilled one.
Elves also have no picks, which normally means a Remove-Construction order can never finish —
here those orders complete, so an elf fort can tear its own walls down.

Goblins are rebuilt most heavily. They learn bronze-working, so a goblin fort can arm itself
rather than scavenging, and they receive a single caravan each autumn instead of going entirely
unsupplied. Goblins also don't come back as ghosts, being militant and not caring about the
number of their dead.

### Adventure mode
None of this changes how these civilizations generate — they are placed by the vanilla rules.
What changes is who you can be: dwarves, elves, goblins and kobolds all become outsider-playable
alongside humans, so you can roll an adventurer of any of them.

With Adventure Hostility, each of these races takes its own side. Humans and vanilla elves are
the good civilizations: they turn on evil adventurers but can surrender or flee. Dwarves are
militant good, hostile to the same evil adventurers and never breaking. Goblins belong to the
evil bloc and attack any adventurer outside it. Kobolds are hostile to any non-kobold.

### Scripts
The script paces the Shaping Tree: growing wood takes one month per tree, a freshly built tree
starts on a full month's cooldown, and a job finished too early withers with an announcement. A
skilled strand extractor grows more from the same tree — one bonus log per skill level on top of
the native log, up to twenty-one in total. It also enforces that a Shaping Tree is built under
the open sky and wrapped around a living tree trunk.

Two smaller fixes cover engine gaps. The script completes the elves' Remove-Construction orders
itself, reverting each designated tile, and it dispels goblin ghosts.

## High Elves

A good race composed of tall, reclusive elves who cares little for mortals and asks questions of the stars.

### Fortress mode
High elves play like dwarves, but they cannot chop trees. Instead, they can turn trees into Shaping Trees with a seed, growing wood at them. Skilled shapers can extract strands of twinkling starlight to create divine metals stronger than steel.

### Adventure mode
High elves live in forests in cities, but each civilization is reclusive and never expands. They are hostile to any evil adventurers, and provide an end-game challenge for them using divine weapons, clothing, and armor.

### Scripts
The high elf script enforces that the shaping tree workshop is built under open sky directly below a real tree. It also enforces that shaping trees can only be used once per month. It handles producing varying amounts of wood from the shaping tree based on the worker's skill at strand extraction, and offers a 5% chance to create twinkling strands per level of the worker.

With Adventure Hostility, high elves found in adventure mode automatically have all clothing, armor, and weapons changed to twinkling metal or fabric, and are hostile to evil adventurers unless they have a Pacifier skill of 6 or higher and no weapon drawn.

## Drow

A slender and beautiful humanoid, dark of skin and heart.

### Fortress mode
Drow are evil matriarchal elves who forge freely — any metal, up to and including steel — but
never carry a shield. They fight with scimitars and bows, and keep tame giant spiders as well as
goblin slaves as livestock.

### Adventure mode
Drow settle mountains and forests only, in insular fortresses that almost nothing ever reaches.
One in twenty-five drow is born a drider — a drow torso on a giant-spider body, armed with
paralytic venom and webs.

### Scripts
The drow script issues the war kit to goblin slaves who have been trained for war: an obsidian
short sword, and a wooden breastplate and helm.

With Adventure Hostility, drow belong to the evil bloc alongside goblins, dark dwarves and
succubi, and attack any adventurer from outside it. Their gear is upgraded on sight: males roll
80% iron and 20% steel, driders are always steel, and females wear giant cave spider silk
clothing with no armour and no weapon. A sheathed adventurer with a Pacifier skill of 6 or
better is left alone.

## Illithids

A dread psionic with four tentacles, it hungers for mind and memory.

### Fortress mode
Illithids are ageless brain eaters with a unique life cycle. Illithids can devour the brains of living or dead creatures to gain knowledge and rarely evolve new psionic powers as Ulitharid. When a Ulitharid dies, its brain can be preserved, and eventually combined with adamantine strands to ascend into an Elder Brain. Illithid never wear armor, but have psionic powers granting a unique fighting style, and study of scholarly arts improves their psionic abilities. They prefer to absorb their dead back into the colonies memories rather than simply memorialize them. They are also served by expendable human thralls who can wear armor and do not ever rise as ghosts.

### Adventure mode
They build isolated mountain dark fortresses and trade with nobody. Their ten psionic
interactions scale with scholarship, so an illithid adventurer grows in power by studying.

With Adventure Hostility, illithids are loners: they attack every adventurer who is not himself
an illithid, and they never break. They are among the hardest of all to talk down — it takes a
Pacifier skill of 12, sheathed, to walk among them. Their gear is deliberately left alone, since
they are never armoured anyway.

### Scripts
The illithid script runs psionic ascension: each caste starts at a base level — illithid 1,
ulitharid 4, elder brain 6 — and gains a level at scholarly skill 3, 6, 12 and 24, counting the
highest scholarly skill. Levels are granted as permanent syndromes that carry new abilities.

It enforces the no-armour rule, stripping armour out of squad uniforms and taking it off any
illithid already wearing it, while leaving robes, cloaks and caps alone; thralls are exempt as
human stock. It also runs the labor policy — thralls may never extract strands, and ulitharids
and elder brains have labor switched off on ascension — and drives every Neural Bath job,
including the 20% chance that devouring a brain promotes an illithid to ulitharid.

## Orcs

A medium-sized creature, ready to give its life for the horde.

### Fortress mode
Orcs are warlike and only work pure metals -- they do not understand alloys. They are ruled by a strong champion caste, but are mostly composed of expendable peons who do not need to be memorialized. They do not even have to wait on migrants, and can easily produce more cannon fodder at Breeding Pits.

### Adventure mode
Orcs settle savanna and scrubland hamlets and are hostile to everyone.

With Adventure Hostility, orcs are loners like the illithids: everyone who is not an orc is an
enemy, and they never break. They are the easiest of the hostile races to talk down — a sheathed
adventurer with a Pacifier skill of 3 passes unmolested. Their gear is upgraded on sight into
copper, leather and iron by a weighted roll, so a war party is not all wearing tin.

### Scripts
The orc script runs the Breeding Pit. Each "breed orcs from meat" job tries to birth an orcling
on the spot, failing 75% of the time at first and falling linearly to never failing for a
legendary strand extractor; the worker earns 70 strand-extraction experience per attempt.
Orclings arrive as full citizens, are always common orcs rather than champions, and are named
Peon with an orcish surname. Orc ghosts are dispelled automatically.

## Dark Dwarves

A short, sturdy creature fond of drink and villainy.

### Fortress mode
Dark dwarves are carnivorous cannibals with ironclad in-group loyalty — they never tantrum, no
matter what happens to the fort. They trade with succubi, goblins, and drow in winter.

### Adventure mode
They live in deep mountain halls, but are otherwise very similar to vanilla dwarves except for
being hostile to good adventurers instead of evil ones.

### Scripts
With Adventure Hostility, dark dwarves belong to the evil bloc alongside drow, goblins and
succubi, and attack any adventurer from outside it. Their gear is upgraded on sight by the same
weighted roll the vanilla dwarves use — mostly copper, with bronze and iron coming up — so they
are not left in whatever metal worldgen happened to hand them. A sheathed adventurer with a
Pacifier skill of 6 or better is left alone.

## Succubi

A hedonistic female creature which plays with hearts and fire.

### Fortress mode
Succubi are demonic realm-builders who keep the full demonic wardrobe but fight with ordinary
arms. They build downward toward the magma they love: a magma well draws it up where there is
none, letting a young colony run magma industry from the surface. Beyond that they corrupt
creatures to their side, summon servants outright rather than waiting for migrants, and work
bone and glass into the trappings a demon court expects.

### Adventure mode
They are desert city-builders with land-holding Demon princes and outdoor fortifications, and
send caravans to the evil bloc in summer only.

With Adventure Hostility, succubi belong to the evil bloc alongside drow, goblins and dark
dwarves, and attack any adventurer from outside it. A sheathed adventurer with a Pacifier skill
of 6 or better is left alone. Their gear is deliberately left untouched — the demonic wardrobe
is the point, and re-forging it into iron would ruin them.

### Scripts
The succubus script switches on the three submodules its workshops depend on, without which
those reactions silently do nothing: the magma well that conjures magma where the map has none,
the powers that drive their summoning and demonic abilities, and the corruption that turns
other creatures to their side.

## Kobolds

The playable kobold civilization: a fork of *Cute Kobold Caverns* with *Skulking Filth*'s
item-thief hard mode.

### Fortress mode
Kobolds play as thieves. A kobold civilization is sometimes ruled by an Ancient Dragon, and
when it is, the eldest becomes the Dread Wyrm king — a civilization-level monarch rather than a
site one, who rules from wherever it lairs and carries out the civ's executions, a role the
kobolds otherwise have nobody to fill.

### Adventure mode
Ancient Dragons also lair the world as megabeasts in their own right — a huge winged creature
full of dread majesty, soaring on iron-hard scales immune to any fire. They come in one-, two-
and three-headed castes, with spiked or clubbed tails.

With Adventure Hostility, kobolds attack any adventurer who is not a kobold, and their dragon
overlords count as the same faction. A plain kobold gives up easily — a sheathed Pacifier skill
of 1 is enough — but they are emboldened while one of their dragons is on screen, and then it
takes 12, which is also what a dragon overlord always demands. Two ancient dragons meeting is
read as a challenge: every other ancient dragon turns on a dragon adventurer, and so do the
kobolds standing with that rival, even though the civ would otherwise greet a dragon as an
overlord. Kobold gear is left untouched.

### Scripts
The kobold script brings idle dragons down. A flier in Dwarf Fortress has no reason to land, so
a dragon that finishes a flight parks itself a dozen z-levels up — unreachable in adventure
mode, and in fortress mode a permanent "there is a dragon here" that nothing can resolve. Any
airborne ancient dragon, wild megabeast or Dread Wyrm alike, glides down a z-level at a time
until it is standing on the ground. It only does this while nothing is fighting the dragon: one
that is jumped halfway down stops descending and is handed back to the game's own AI, so an air
attack is never turned into a free kill. Magma, deep water, the adventurer, and caged, ridden,
stunned or unconscious dragons are all left alone.

## Second Humans

These exist to balance populations; humans expand across the whole map, while other
civilizations have restrictive placement, and this mod causes them to outnumber other races
rather than be about equal to orcs.

## Beasts

Adds gibberlings: small, gibbering predators with blue chitin, who swarm and devour the living.

## Adventure Hostility

Makes the suite's civilizations behave like enemies in adventure mode, and upgrades the gear
everyone in the world is carrying.

### Fortress mode
The war-gear half runs in fortress mode too, but only ever touches **invaders and visitors** —
never your own citizens, and never migrants joining the fort. So a siege or a caravan arrives in
the metal its civilization is supposed to wear, while your fort equips itself as normal.

### Adventure mode
Each turn, nearby members of a hostile faction are put into a conflict with the adventurer
specifically — never with their own people — by placing them in the same Conflict activity the
game builds when you attack someone. Hostility is site-scoped: inside a settlement only that
settlement's own people turn on you, so a drow merchant visiting a high elf town stays a guest.
Units of the adventurer's own civilization are always left alone whatever their race.

The factions are: orcs and illithids, each hostile to everyone but their own kind; the evil
bloc (drow, dark dwarves, succubi, goblins), hostile to any adventurer outside it; the good
civilizations (humans, vanilla elves), hostile only to evil adventurers and able to surrender or
flee; the militant good (high elves, dwarves), hostile to the same evil adventurers and never
breaking; and kobolds, hostile to any non-kobold.

**Sheathe your weapon and talk.** An adventurer whose Pacifier skill meets a race's threshold
and who has not drawn a weapon is never attacked at all — you do not have to fight anyone first
or hold them at a surrender. Draw steel and the exemption lapses that same turn. The thresholds
are goblin 1, orc 3, drow, succubus, dark dwarf, high elf and dwarf 6, illithid 12, and kobold
1 rising to 12 while a dragon overlord watches. The same number decides whether a surrender
already given is allowed to stand.

### Scripts
Two scripts ship here. `adventure-hostility.lua` is the adventure-mode overlay described above;
it also sets NOFEAR on a faction so it never breaks, and clears a yield each turn for anyone
below the threshold.

`war-gear.lua` is a separate script because it has to run in fortress mode as well. Worldgen
spreads a civilization's equipment across every metal it knows, so most members of any civ spawn
in copper, silver or tin however martial they are meant to be. This re-gears them from a
weighted outfit roll made once per unit and remembered — high elves get twinkling metal armour
with their clothing rewoven in twinkling fabric, drow males roll 80% iron and 20% steel while
driders are always steel and females wear giant cave spider silk, and dwarves, dark dwarves,
orcs, goblins and humans each get their own mix. Illithids, succubi, kobolds and vanilla elves
are deliberately left alone. It only ever **upgrades**: a piece is replaced only if its material
ranks below the metal rolled, ranked by the material's shear yield read from the raws, so steel
is never downgraded and twinkling gear is left as it is. Masterworks and artifacts are never
touched, children are never armed or armoured though their clothing is still rewoven, and it
never edits an item's material in place — it mints a fresh item of the same type and subtype,
copies the quality across and swaps it in.

## The all-in-one bundle

Every `ha-*` mod merged into a single mod, so one entry in the mod picker installs the whole
suite. It is **generated, never hand-edited**:

```sh
cd content-mods/high-adventure
python3 build-high-adventure.py
```

Re-run it after bumping any member mod, and bump the bundle's own version too — DF keys its
snapshot by `<MOD_ID> (numeric_version)`, so a rebuild that reuses the old number leaves DF
serving the previous snapshot with the contents silently changed.
</details>

