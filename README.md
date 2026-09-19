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

Two columns stay out of `r`'s way and start empty: **house rules**, for tools that change what
the game *means* rather than doing the clicking for you, and **joke/**. Turn those on a row at
a time, or with their own `h` / `j` header keys.

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
nobody wanders onto them, and their old traffic setting is restored afterwards. Smoothing beside
a channel goes first: a tile waits while any of the eight around it is still designated for
smoothing or engraving, or has a detailing job outstanding, since cutting the floor away first
only sends the detailer to a hole and gets the job cancelled. Detailing on the excavation itself
does not count — a tile designated for both channelling and smoothing loses that smoothing to the
dig whatever the order, so waiting on it would only deadlock. A shape with no
safe order, like a ring drawn around floor that is not itself designated, simply stays planned.
Only tiles a miner can actually get to are let out — revealed, and with somewhere to stand:
its own tile if that is reachable (a staircase is its own way in), a neighbour at its own level,
or a hole with one of the fort's ramps under it, which is how a miner walks back up into a level
that has already been channelled out — which keeps a designation drawn across undug rock from filling the working set
with tiles nobody can reach; when none of it can be reached yet, `status` says so rather than
blaming the shape. Priority 1 designations are never touched, and
`fort/channel-safely why <x> <y> <z>` explains any tile's verdict. Enabled by `magnus-scripts`.

Finding the designations costs almost nothing when there are none. The sweep walks every map
block in the fort, so it runs once a second only while there is a reason to look — a designation
tool is up, tiles are being held, or the last sweep found channel work — and once every ten
seconds otherwise. Nothing is missed: a designation DF has turned into a job, the case that
actually races a miner, is caught the instant it happens by the job hook rather than by the
sweep. That took it from 8.2% of frame time to 1.3%.

![fort/channel-safely demo](demos/fort-channel-safely.gif)

When a pass can prove **nothing** safe to dig, that now raises a line in DFHack's notification
panel — *"23 channels blocked: smoothing beside them first"* — with the reason in the line and a
click that steps through the refused tiles. Held designations look exactly like working ones, so
without it a fort can wait a season on a blueprint nobody was ever going to dig.

### **`fort/planned-smoothing`**
Smooth a room before you have finished digging it. A smooth designation only sticks to tiles
that are revealed, so the part of your box that lands on undug rock is silently thrown away —
this remembers those tiles and lays the designation down once each one is a revealed floor of
natural hard stone with nothing already smoothed and nothing built on it, using DF's own rules.
Mining comes first: rock beside a fresh excavation is revealed as a wall long before anybody
digs it out, and smoothing that face is work a miner cuts away an hour later, so the tile waits
until mining has actually happened in it. Tiles that can never be smoothed — soil, constructions,
or a tile whose outstanding job is a staircase, a ramp or a channel — are forgotten rather than
held forever. The eraser takes plans back the same
way it takes designations back. Plans live in memory only and do not survive a reload, by
design: a box you dragged a minute ago is not a standing preference.

`fort/planned-smoothing` reports what is planned, `clear` forgets it, `now` runs a pass
immediately. Enabled by `magnus-scripts`.

It draws nothing: designation art is DF's own, and a planned tile — not designated yet — shows
what it always showed, which is the rock. It used to paint a gray corner triangle over every
smooth designation in view, which meant walking the viewport's map blocks on every rendered
frame; it also now goes idle completely when nothing is planned, instead of re-reading the
fort's job list four times a second. Together that was 6.7% of frame time on a live fort, now
effectively nothing.

Every tile it designates goes in at **priority 7**, the back of the queue: a smoothing
designation and a mining designation are the same queue to a dwarf, so a room's worth of
smoothing dropped on a half-dug fort stops the miners to go and polish walls. (`fort/dig-shapes`
instead gives everything it lays — digging, stairs and smoothing alike — the priority the Dig
tool is set to.)

### **`fort/builder-burrow`**
Turn a burrow into a district. Pick a burrow (only those on a single z-level are listed, under
the name DF shows them by; the burrow is deleted once its blueprints start), a preset (hovels, 2x2 or 3x3 housing, luxury
housing, varied housing, noble quarters, tombs, temples, guildhalls) and when to build, and the
burrow is planned on the level you are looking at: roads grow from wherever the burrow touches
your dug floor, one segment at a time, each segment dressed with statue rows and plazas and lined
with districts as it is laid; a road with nothing along it is refused; a second pass fills the
leftover frontage; noble suites and guild complexes are placed as suites with one door on the
road. Then every room, road and hallway piece is started as a `fort/quickfort` job, so digging,
digging,
smoothing, engraving and furniture sequence themselves per tile, and the three blueprints that
want a given square wait for each other on it — a mine designation and a smooth designation never
share a tile, because DF works the smoothing, the mining never happens, and the wall just stays. Every wall around the plan is smoothed, and a room's walls are engraved as well — hallway
walls are left plain, so the carvings belong to the rooms. A noble suite goes further: the floor
under every piece of its furniture is engraved too, carved before the furniture arrives, since
nothing can be carved under a bed. Each stamp declares the activity zone its
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

A box that holds constructions **and** open tiles which would become walls is a **build**, not a
removal: drawing from a wall you already have up into the air above it is how you add another
course, so the walls in the box are left standing and the air is built. Air with nothing under it
— the sky caught alongside a bridge you are dismantling — would only ever become floor, and stays
incidental to the removal.

Where a staircase column tops out on an existing up stair, a **constructed** one gets an up/down
staircase built over it (a construction cannot be carved into) while a **naturally dug** one is
simply designated for a down stair — it is rock, and a miner cuts the down side into it for free
rather than spending a block and a mason on it.

Everything it lays — the digging, the stairs, the channels and the smoothing beside them — goes
in at the priority the Dig tool is set to, the same as a tile you paint by hand.

![fort/dig-shapes demo](demos/fort-dig-shapes.gif)

### **`fort/dig-building`**
A searchable building picker while digging that drops you straight into DF's placement flow.

### **`fort/dig-replace-walls`**
Paint walls that should become constructed walls of your choosing. Reached from the
`fort/dig-building` picker as **Replace wall**, in the custom-tool band at the bottom.
A natural wall is designated for mining, a constructed wall for removal, and once the tile
is actually clear it is handed to `buildingplan` as a planned wall. Doors, hatches, furniture
and workshops are never taken down, and neither is a constructed wall carrying a masterwork
engraving — **nor one that already satisfies the filter**: taking down a conglomerate block wall
to build a conglomerate block wall costs a mining job, a hauling trip and a hole in the meantime
and gains nothing, so painting over one does nothing and says so. That judgement is made against
`buildingplan`'s own filter — the item form against its Blocks/Logs/Boulders/Bars toggles, the
material against the category mask and the named materials — so "turn these boulder walls into
block walls" still works with no material chosen at all. A filter carrying a heat-safety
requirement or a special is not judged, and those walls are replaced as before.

Materials are `buildingplan`'s, not the tool's. The panel shows the wall filter as it stands, in
`buildingplan`'s own words ("Any building material of microcline"), and its two controls — `f`
for the filter dialog and `b`/`l`/`o`/`r` for Blocks/Logs/Boulders/Bars — are `buildingplan`'s
own, editing `buildingplan`'s own stored wall settings. So a wall painted here is built out of
exactly what placing a wall by hand would build it out of, and a change made here applies to
walls generally.

The painter is an overlay rather than a dialog, so opening and closing it neither pauses the game
nor makes DF blank and redraw the screen; while it is up DF's designation tool is disarmed, so no
other map tool acts on the clicks it is taking.

A plan lasts only as long as the work does: cancel the dig on a painted tile by any means and the
replacement is cancelled with it — nothing is ever re-designated behind you — and the plan drops
itself as soon as the replacement wall is handed to `buildingplan`.

A rewrite of Little Fern Studio's [replace-wall](https://github.com/LittleFernStudio/replace-wall)
(MIT); see `LICENSE.md`.

### **`fort/move-items`**
Moves things to a spot you pick. DF has no "carry this to there" — it has *dumping*, which is
the same order with the controls filed off: you mark items, and haulers take them to whichever
garbage dump zone suits them, where they land forbidden. This puts the controls back. Reached
from the `fort/dig-building` picker as **Move items**, beside Replace wall.

**Corpses and cages are rowed by what they mean, not what they are made of.** Corpses split
into butcherable bodies, refuse, and your own dead. Cages split by occupant:

| Row | What lands there |
|---|---|
| **Important cages** | a megabeast, semimegabeast, titan, forgotten beast, unique demon or night creature |
| **Prisoner cages** | anybody else who can think — `CAN_LEARN` or `CAN_SPEAK` |
| **Animal cages** | everything else alive |
| **Empty cages** | nothing inside at all |
| **Other cages** | a cage being used as a plain container |

"Wooden cage" is a useless row when one of them holds a forgotten beast and forty hold seeds.
A cage holding several takes the rank of its most important occupant, so one goblin among the
war dogs makes it a prisoner cage rather than a kennel. "Important" is deliberately wider than
megabeasts: sorting strictly on `MEGABEAST`/`SEMIMEGABEAST` would file a caged forgotten beast
under *animal cages*, since none of those creatures is sapient — and those are exactly the
cages you never want to move by accident. Unlike the corpse rows, cages are **not** exempt from
the quality and value sliders; a masterwork glass cage is a real thing to filter on.

Click the destination and it makes a dump zone there and **deletes every other dump zone in the
fort**, so there is exactly one place a dumped item can go and it is the one you picked. Then a
picker opens: every kind of item that can actually reach that spot — same walkability group,
which is DF's own answer to "can a dwarf get from here to there" — one row per kind, with the
same search, sort, value, quality and wear filters as DFHack's *move goods to depot* screen.
The filters cut *inside* a row: a minimum quality turns five earrings into the three that pass
— that is the count shown, those are what `[specific]` lists, and those are what a click takes;
a row with nothing left is not shown, and narrowing pulls a selection down with it. Each row
opens with the distance to its closest passing item, and **Melt targets** (Shift-T) keeps only
metal and caps quality below masterwork — the masterworks and artifacts are the ones you keep —
as a starting point you can move; off puts quality back to any. **This z only** (Shift-Z)
keeps only items on the destination's z-level, and **Burrow** (Shift-B) cycles through the
fort's burrows to keep only what stands inside the one named.
Say how many of each and it marks the **closest** ones; `[specific]` opens the individual items
behind a row, by distance, if you want to choose among them.

Corpses come as three rows rather than five hundred, because a heap of bodies is three different
chores wearing one word: **butcherable corpses** (a whole, unrotten animal), **refuse corpses and
body parts** (an elephant trunk, a goblin, anything left over), and **fallen allies and
residents** — your own dead, and the merchants and visitors who died here.

It also turns on the three standing orders the haulers need (*gather refuse*, *gather refuse
outdoors*, *gather outdoor vermin remains*) and says which it changed: a fort with any of them
off never finishes the job and never says why. While the haul runs, DFHack's notification panel
carries a **"Moving N items"** line, and clicking it walks the items still on their way — one
per click, so you can see where each has got to (an item being carried shows you the hauler).
The announcement when the delivery lands is a zoom announcement, so clicking *that* recentres
the map on the finished pile.

**Calling it off.** Hover that line and it reads **"Moving N items (Shift+click to cancel)"**;
shift-clicking it does exactly that — the dump marks come off everything that has not moved, the
zone goes, and whatever already landed is unforbidden where it lies. The `fort/dig-building` row
renames itself to **Cancel move** while a delivery is in flight and does the same thing, so the
place you started it from is the place you stop it. `fort/move-items cancel` is the same call
from the console.

The hover text is a token *function* rather than a string, because the notification panel only
rebuilds its rows every five seconds and hover has to answer now — a token's text is re-read on
every render. What that cannot do is widen the panel, which is measured at rebuild time, so the
watcher overlay catches the hover transition on the frame it happens and asks the panel to lay
out again; without that the hint is drawn into a frame too narrow for it and comes out clipped.

**Anything already marked for dumping opens pre-selected in the picker**: mark a pile with
`d`-`b`-`d` on the map, open Move items, click the spot, click Move, and that pile is what goes
— deselect what you did not mean. Starting a delivery then **unmarks whatever was left
unselected** and **cancels any delivery already in flight** (it says how many of each). Both for
the same reason it deletes the other dump zones: a dumped item goes to whatever dump zone is
going, so old marks would arrive mixed in with what you asked for. On one live fort that first sweep cleared 361 stray dump
designations. **Each item is unforbidden as it lands**, not all at once at the end — dumped goods
are put down forbidden, and a pile of forbidden goods is not a delivery, so a long haul is usable
while the rest of it is still walking. The zone goes when the last one is in. The job survives a
save and reload.


**The delivery does not narrate itself.** *"3 newly dumped item(s) joined the delivery"* and
*"delivery finished"* used to go into DF's announcement log and alert strip, where the game puts
sieges, artifacts and dead dwarves — and items joining a run mid-way raise that line again and
again. Those go to the DFHack console now, and the finished line names the destination's
coordinates in its text rather than being a clickable zoom announcement. **Refusals and errors stay on
screen**: *"nothing could stand there — pick a floor tile"*, *"nothing that can reach that spot
is anywhere else"*, and anything that went wrong marking items. Everything about a delivery that
went well — including the count of what a click marked — is the delivery describing itself and
goes to the console. The prompt to click a spot is gone because the picker's own panel already
says it, and "nothing selected" is gone because the window closing is the whole answer.


**The item window names the burrow** each piece is standing in, when it is in one. A burrow is
how a fort says *"this pile is the hospital's"* or *"that is the forge's stock"*, and two
identical bins read identically in the list until you know which room each is in — at which
point the choice is obvious. `isAssignedTile` costs ~50µs, so the answer is cached per tile: a
16,845-item scan with 16,155 of them inside a burrow takes 211 ms.

**Wool and hair are not remains.** DF files shorn wool as a CORPSEPIECE — it comes off an
animal, so it shares an item type with a severed arm — but a bin of alpaca wool is thread
waiting for a loom, not a corpse, and burying it in the *"Refuse corpses and body parts"* row is
how it ends up in a refuse pile. Those rows are ordinary item rows now, one per kind: a body
part reports no material at all (camel hair, yak hair and alpaca wool all key as `46:-1:-1:-1`),
so the description joins the group key to keep them apart.


**Clicking a row takes all of that kind**, and clicking it again clears it; **shift-click**
marks every row from the last one clicked to this one. The bands along the right edge — `[-1]`,
the count, `[+1]`, `[+10]`, `[all]` — are still there for an exact number, and `[specific]` still
opens the items behind a row. Before this, a click that landed on the label did nothing at all.

### **`fort/rewall`**
Redraws every planned construction, to shake loose the ones deadlocked on a reserved item.

A wall that never gets built is usually waiting on itself. A hauler drops the block for one wall
onto the tile of the next one; that tile now holds an item another job has claimed, so DF suspends
the job rather than build over it — and the claim never lapses, because the job holding it is
suspended too, waiting on a tile of its own. Nothing in the fort resolves that: the walls sit
*planned* with their material lying right there. This removes each designation and puts back
exactly what it took away — same construction type, same tile, **same material** — and the fresh,
unsuspended job goes looking for it. Measured on a fort with 63 suspended walls: none left
suspended afterwards.

The material is the subtle part. Choosing a stone for a construction does not narrow the job's
filter; DF leaves that generic and *attaches the item you picked*. So the material is read off
the item already hauled to the site, not off the filter, or a wall with conglomerate waiting on
it comes back sandstone. `--any-material` gives that up deliberately, for when breaking the
tangle matters more than the stone.

`fort/rewall register` loads its warning without redrawing anything: a line in DFHack's
notification panel — *"7 constructions deadlocked — run fort/rewall"*. It counts **one shape**: a
suspended construction with an item on its tile that *another construction job has claimed*. That
tile cannot be built while the item sits on it, the item cannot be hauled while a job holds it,
and nothing in the fort ever undoes that. A wall suspended because another wall goes first is not
counted — that is `suspendmanager` sequencing, the fort working correctly, and a warning that
fires every season is one you stop reading. Clicking it walks you through the tiles. A deadlocked
wall is otherwise invisible: it looks exactly like a wall waiting its turn.

**It also picks materials that will not get stuck again.** A construction cannot be built while
loose items sit on its tile, and an item only leaves a tile if a hauler has somewhere to take it —
so in a fort with no stockpile accepting stone, blocks or bars, the blocks dropped along a wall
line sit exactly where the wall goes, forever, and a plain redraw hands the job back the same
blocked tile. So: if a loose item on the tile is what the job wants, **that** item becomes the
job's material, attached at creation — the job starts unsuspended with nothing to fetch and the
tile loses a blocker instead of gaining one — and whatever is left on the tile is moved to the
nearest reachable tile that is not a building site (`--no-clear` leaves it). Measured on this
fort: 16 sites blocked by unmovable items, 16 built from a block already lying on them, 48 items
moved aside, and *"Blocked by an unmovable item"* gone from the fort entirely.

Sites **nobody can reach** are named rather than redrawn — a pocket sealed by walls already
built, or a floor designated out over open air with nothing to build it from. No material and no
ordering fixes those.

`--material INORGANIC:CONGLOMERATE` (with `--item BLOCKS` for the form) overrides both the pin and
the old filter, for when the material a wall is carrying is itself the mistake.

It leaves alone anything a dwarf is actually building (taking a job out from under its worker is
how this repo has crashed DF), anything already part-built, and anything **`buildingplan` is
holding** — that filter lives in the plugin rather than in the building, so a redraw would throw
the plan away and leave a plain construction that takes the nearest rock. `-n` reports without changing
anything, `--suspended` limits it to the deadlocked ones, `-v` names each. The one cost is real:
a material already hauled to the site is released, so a hauler may carry that block elsewhere
before the new job claims it — the wall is not lost, only the trip.

### **`fort/repeated-flood-fill`**
Place a zone, stockpile or burrow **twice in the same spot** and the second one means *"and the
rest of the room"*. A 1×1 placement is DF's own; a 1×1 placement on the same tile again floods
the room in 2D. For burrows a 3×3 placed twice over the same nine tiles floods in **3D** — zones
and stockpiles each live on one z-level, so they have nothing to fill upward into.

The trigger is the *repeat*, never the tile, so clicking once inside a zone you already have does
nothing unusual — and the repeat has to **stand alone**: a 1×1 with a zone, stockpile or burrow
tile of its own kind in any of the eight tiles around it is left to DF, because clicking the same
tile twice is also what painting one tile at a time looks like when a click does not register.
It says nothing when it works, either; the room filling in front of you is the report, and only a
**refused** fill announces itself (too big to be a room, no floor to fill from, nothing to add). The fill stops at walls, open air and **doors**, the way DF's own rooms do —
without that a bedroom joins the corridor, the corridor joins the fort, and "the room" would be
the whole level. For a **zone or a burrow** what it fills is the floor **plus the walls and doors
around it**, corners included: a room is its shell as much as its floor, a bedroom that stops one
tile short of the wall is not the room you drew, and a burrow that stops there leaves the miner
outside the rock he was sent to dig. A **stockpile gets the floor only** — nothing is ever stored
in a wall, so a stockpile drawn over one counts tiles it can never use and holds them away from a
stockpile that could.

The 3D fill climbs the way a dwarf does — a staircase reaches the staircase above or below it, a
ramp the tile over its head — and brings each level's walls with it. Hidden tiles are never
filled, stockpiles also leave out tiles another building owns (doors included, since they cannot
share one), and too big a region is refused outright rather than half-drawn: a fort staircase
reaches every floor you have. The object you repeated on is the one that grows, so its name, settings and
assignments all survive.

![fort/repeated-flood-fill demo](demos/fort-repeated-flood-fill.gif)

### **`fort/right-click-cancel`**
Drag to designate, right-drag to erase, right-click to cancel — for every designation and
build tool.

### **`fort/plan-tile`**
Drag to place a whole grid of a building at once while planning, tiled by its footprint so
copies sit edge-to-edge.

A building DF places over a hole rather than on a floor — a well, which goes on open space or a ramp top — is placed by the same drag: the tile the mouse goes down on is one DF has already accepted, so its shape is what the rest of the grid is measured against.

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

### **`fort/auto-mayor-quarters`**
Name a bedroom, dining hall, tomb and office with "Mayor" in the zone name and they follow
the office: when DF announces an election or a succession, every one of them the new mayor
does not already own is reassigned to them, so the quarters stop staying with the last
mayor while the new one sulks over unmet demands. One zone per kind — two bedrooms named
for the mayor and it leaves bedrooms alone and says so. Run bare to hand over now and see
who owns what.

## Fortress Management

### **`fort/planeswalkers`**
Carry a whole fort between worlds. `fort/planeswalkers save` snapshots the current fort —
terrain (with veins, sand/soil, the grass cover — surface grasses and the
cavern mosses, fungi and lichens alike — and, on a same-size embark, the whole column down
through the magma sea and hell, re-registered on the destination's magma layer with the
layer's z band widened to the arriving sea and any magma pipe above it, so DF keeps rather
than drains it; the destination keeps its own demons), adamantine spires
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
and labour assignments, burrows, trees and shrubs (shrubs and saplings re-planted where they stood; every tree rebuilt with
its own trunk, branch and root layout and the exact tiles it stood on), the
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
on a fort restored before that pass existed), `repair` (re-registers and refills a magma
sea that drained after the restore — the one recovery still worth a command), `status`, and
`cancel` round out the set.


**Taking a party instead of a fort.** `fort/planeswalkers gui` asks the question first: the whole fort, or
these travellers? A party snapshot is a handful of chosen dwarves and what they carry — skills, attributes,
personality, **preferences**, **body size**, appearance, labors, relationships and every worn, wielded or carried item,
containers with their contents. Nothing about the destination map is touched: the travellers arrive in the
fort you are already playing, beside a citizen picked at random (a different one each load), and everything
else there survives. Extra loose items can be named on top of their gear — the anvil in the stockpile, the
artifact on its pedestal — while gear itself is never a question, since it always comes. Preferences are
written as raw tokens (`INORGANIC:STEEL`, `PLANT:PINEAPPLE:DRINK`) and looked up again on arrival, so a
material the next world has never heard of is dropped rather than pointed at whatever now sits at that
index; poetry, music and dance forms are skipped entirely, being works this world composed. `fort/planeswalkers
party [name] <unit id...>` does the same from the keyboard, defaulting to the selected dwarf.

**A round trip through a world that has never heard of your mods.** `killed_race` is an index into the
*current* world's creature list, so a dwarf who walks into a vanilla world loses every drow, orc and succubus
kill the moment she arrives — and the next save would read her kill list back out of the game and write down
only what was left. Anything a destination cannot represent is now **carried** instead: kept beside the fort
against the historical figure who earned it, and folded back into her record the next time she is saved, so
she comes home with her career intact. Preferences that name a material the world lacks are carried the same
way, against the unit. Verified on a 136-row kill list: 52 modded rows (415 kills) survive the round trip and
merge back without duplicating the 84 the game still holds.

### **`fort/forge-bars`**
The forge's "Add new task" list names every metal it could work as "iron (opens menu)",
whether you own a bar of it or not. This overlay paints the count over that tail on every row —
"iron (40 bars)", "steel (no bars)", "bronze (319 bars, 2 in use)" — read from the bars on the map
(forbidden bars are not counted; bars a job has already claimed are counted and noted), and the metals
you have none of are moved to the bottom of the list, in DF's order. Metalsmith's
forge and magma forge only. Auto-discovered by `overlay rescan`; `forge-bars` on the console prints
the same counts for the open menu.

### **`fort/workshop-tools`**
Puts a `+` on every queued workshop task that queues another one just like it — material,
repeat, suspend and "do this now" priority included; shift-click fills the shop to DF's ten
with copies of it — and sorts a shop's "Add new task" list so the jobs you can actually do come before the ones you can't.

### **`fort/better-world-map`**
The World screen's **`Center on fort`** button scrolls the map so your fort sits in the middle,
and that is all it does — on a big world the middle is a crowd of sites, roads and rumour icons
in which the fort is one tile among hundreds.

This flashes a `!` for five seconds over every site worth finding, in three colours:

| | |
|---|---|
| **blue** | your own fortress |
| **yellow** | a site **under your control** — your holding as a land holder, the one whose panel offers *Request workers* and reads "economically linked to you" |
| **white** | a site that merely **belongs to your civilization** — your civ, somebody else's holding. You cannot attack it and cannot negotiate with it, and that is all it means |

**The glyph says library, the colour says whose.** A site that keeps books draws an **∞** (CP437
236, the nearest thing the map font has to a scroll) instead of a `!`, in whatever colour its
standing calls for — so Furnacehailed, which is your civilization's, now shows a white scroll
where it used to show a plain white bang and hide its library entirely.

**Your own fortress is the exception** and keeps its blue `!`: you do not need telling that your
own library is there, and the bang is what you clicked the button to find.

Foreign libraries have no standing to colour them by, so they are coloured by how dangerous
fetching from one would be:

| | |
|---|---|
| **red ∞** | held by a government you are **at war** with |
| **white ∞** | allied, or never met |

Books are worth going out of your way for *because* they are rare — **7 libraries across 3664
sites** — so a foreign one is marked whoever owns it. Getting in is your problem; knowing it is
there is the point.

**Shift+click pins it.** Five seconds is right for "where am I" and wrong for reading the map with
your holdings in front of you, so shift+click keeps the markers flashing with no time limit until
the next click on `Center on fort` clears them. They still blink — the blink is what makes a
marker findable against a crowded map. `fort/better-world-map pin` and `... clear` do the same
from the console.

**The middle tier is the point.** Flattening "under your control" into "belongs to your
civilization" made fifteen sites look like yours when only one was.

**Which sites count is not decided here.** `fort/economic-expeditions` already has to answer
this to know where an expedition may go, and two scripts disagreeing about what belongs to you
would be worse than a dependency — so this asks that one, through its exported `site_standing`. If it is not
installed the flash falls back to marking the fort alone rather than failing. The list is built
once when the flash starts, not per frame: it is a 3664-site scan taking ~60 ms, nothing once
but a stutter sixty times a second.

The markers are placed from the map's centre and each site's world position every frame, so
scrolling mid-flash carries them along. `fort/better-world-map flash` triggers it from the
console without the button.

### **`fort/economic-expeditions`**
On the fort-mode world map, clicking a site tells you its name, its population and nothing at
all about the land. This adds a survey panel under DF's **`Diplomacy`** button:

- **Stone** — the layer stones (always there) and the vein materials, grouped by how hard they
  are to find: *veins*, *clusters*, *small clusters*, *single gems*. **Soils are left out** —
  clay, silt and their kin are layers like any other but digging them yields no boulder, so
  listing them as something to fetch would be a lie. Adamantine is never listed.
- **Trees**, **Plants** and **Game** — the surface roster of the tiles the site stands on.
  **Animal people are not game** — they can talk, and they turn up as visitors and residents.
  A **savage** tile legitimately carries far more, because the giant variants live there.
- **Library** — the named books it holds, by title. The line is absent on a site with no
  library rather than saying so on every one of them.

Nothing here writes to the game; this is the read-only half of a larger house rule, and sending
expeditions comes later.

**None of it is a scan.** Stone is the world tile's *geology* — `region_map_entry.geo_index`
picks a `world_geo_biome` whose layers carry the layer stone and the vein materials, each tagged
with an `inclusion_type` that *is* the rarity signal. A handful of vector reads, not a prospect
sweep, so it is cheap enough to compute behind a panel. It models what the rock would hold
rather than counting what is there.

**The exact answer is only available near home.** `world.populations.all` is generated for the
loaded embark's neighbourhood and nowhere else — measured here, 9146 entries covering **49 world
tiles out of 33153**. So there are two answers, and the panel says which one you are getting:

- **exact** — the site's tiles have local populations: the 13–15 surface animals DF actually
  spawns there, per tile.
- **estimated** — the fallback, marked *"living things estimated from the region"*: the roster of
  the region the site sits in, intersected with the biome of the site's own tile. Broader than
  the truth — what could be there rather than what is.

Without the fallback, Shinmystery — a forest retreat with vegetation 90, 116 tiles east —
reported **"Trees: none here"**. Stone is unaffected: geology is world-wide and always exact.

Trees, plants and game come from **`world.populations.all`** where it exists — DF's per-world-tile
local populations, the roster it actually spawns from. Two filters make that correct, and without
either one the list is confidently wrong:

- **Per world tile, not per region.** `world_region.population` is the union over every tile a
  region covers — "The Prairie of Zeniths" spans **415** of them — so it credits a site with
  things growing four hundred tiles away. A single tile carries **13–15 surface animals**, which
  is the number you see wandering into a fort.
- **Surface only** — `layer_depth`, `cave_id` and `feature_idx` must all be `-1`. Unfiltered, a
  tile returns **74–126** entries, because the same structure holds the cavern layers (crundle,
  troll, gorlak), the magma sea (fire imp, magma man), the HFS (demons) and the water (carp,
  pike, sturgeon).

**A site is not one tile**, so the survey unions across the tiles it covers. **1441 of this
world's 3664 sites** span more than one, the largest four. Burnedroofs covers x 70–71, y 78–79:
three of those tiles hold the same 15 grassland animals, and the fourth holds a 10-strong desert
roster with camels, jaguar and leopard. Reading `pos` alone would have dropped the camels.

Vermin and insect colonies are dropped throughout, and animal people are dropped as people.

**The titles come from artifacts, not from the library.** An off-map library instantiates no
ordinary book items — `library.item_id` is empty on all 7 of this world's libraries — and
`written_content` records an author and references but never a location. **Artifact** books are
a different thing: `world.artifacts.all` holds 1710 records, each with a real `item` and a
`site`, which is what DF itself lists under Artifacts on the site panel. Filtering those to
books gives the titles — *The Journey into Trickery*, *Musings on Surveying* and fifteen more at
Silkendied.

These are the **named** books, not every volume on the shelves; ordinary copies still do not
exist off-map. That is the difference between "there is a library here" and "here is what is
worth sending somebody for".

**The panel is placed by reading the screen.** DF's site panel is a v50 `widget_container`
behind an opaque `shared_ptr`, so nothing can be inserted into it — the `Diplomacy` label is
located in a bounded band and the survey drawn beneath it, the same trick `fort/butcher-shop`
uses. It draws full width and is allowed to sit over DF's own right-edge buttons, behind a filled
background box so the text never interleaves with what was underneath; the buttons return the
moment the panel stops drawing. If the label is not found it draws nothing rather than guessing.

**Every name is shown** — there is no "and N more". A list you cannot read to the end is no use
for deciding where to send an expedition, so vertical space is spent instead: no counts, no
heading over the stone tiers, a blue label and its names sharing one line, and a blank row
between groups. Burnedroofs fills about forty of the fifty-odd rows under the button.

**Where an expedition can go**, and how a site stands to you generally — three answers, because
DF draws a real distinction the first version of this flattened:

- **`own`** — your fortress.
- **`controlled`** — *your* holding, what DF calls "economically linked to you" and the only
  sites whose panel offers *Request workers*.
- **`civ`** — merely your civilization's. Another noble's holding.

**The discriminator is `position_profile_id`, not the link flags.** All sixteen of this world's
`land_for_holding` links point at the same civ entity, so testing the flag alone calls all
sixteen yours when fifteen belong to other nobles. Each link records the position profile it was
granted to, and yours is the one on your own fort's link — profile 11 here, which is also the
`land_holder_residence`. That sorts them 1 own / 1 controlled / 14 civ.

An expedition may go to a **`controlled`** site, or to **another player fortress** (a fort you
played and retired is yours whatever the diplomacy graph says). Belonging to your civilization is
**not** enough — another noble's hillocks are not yours to strip.

**Red means the fort has no source of it**, in both the survey and the picker — the point of an
expedition is to fetch what you cannot get at home, and a list that does not say which is which
makes you check four screens before deciding. "Already have it" means something different for
each:

| | counts as *have* when |
|---|---|
| **stone** | it is in your own geology, so you could mine it out of a wall |
| **trees** | it grows on your own tiles |
| **plants** | you hold **seeds** of it — a plant you cannot plant is one you have to go and pick |
| **animals** | you have a **breeding pair**: a live tame male who would breed with a female and a female who would breed with a male |

DF tracks orientation on animals too (`soul.orientation_flags`), and a pair that will not breed
is not a herd — which is exactly when you would send a hunting party for another. The stone check
reads the fort's geo layers rather than sweeping the map for wall types, which would lock the
game up.

On this desert fort that lights up every temperate tree at Burnedroofs in red — alder, birch,
cherry, chestnut, oak, pear, willow — which is a good reason to send a logging party.

**Grass is not a crop.** `plant_raw.flags.GRASS` marks the ground cover — meadow-grass, grama,
blue sedge, ryegrass — which no herbalist can gather and which has no seed to plant. They were
listed because the region records them as growing there, which is true and useless. Dropping them
took Burnedroofs from 37 plants to 26.

**The round trip is real, and it is not a DF mission.** A mission hands the squad to an
`army_controller` and hopes DF gives them back; this walks them out and counts the days itself,
which has far fewer moving parts and cannot be lost to DF deciding the army should do something
else. Four phases:

1. **Marching.** The squad gets a genuine patrol order to the nearest map-edge tile it can
   *actually reach* — ranked by distance, then confirmed with `canWalkBetween`, which is a real
   DF pathfind rather than a straight line. **Always on the surface**: the tile must be `outside`
   and unhidden, so nobody is ever sent out through a cavern. The edge is re-picked on every
   check, because a dwarf who starts deep in the fort may surface nearer a different side than
   the one that was closest from the stairwell; a new edge has to beat the current one by eight
   tiles before the order is rewritten, or they dither between two forever.
2. **Departing.** At the edge they come **off the map**, the way DF parks a unit that has left:
   `flags1.inactive` set, dropped from `world.units.active`, and the tile's `occupancy.unit`
   cleared. All three matter — leave them in the active list and the engine keeps ticking a unit
   that is nowhere; leave the occupancy set and an invisible body blocks the square they walked
   off. Any job they were on is released with `removeWorker` first, never `removeJob`, which
   segfaults on a unit's `current_job`.
3. **Away**, for a week plus travel each way. The days are counted **here**, by accumulating the
   driver's own interval — `cur_year_tick` is not monotonic once timestream is in play and it
   wraps at the year end, so an expedition begun in Timber would come home instantly or never.
4. **Home.** They are put back on the tile they left from and the haul is created at their feet:
   boulders for stone, logs and plants through their `PLANT_MAT`, corpses stamped with their race
   so they do not render as a *nil corpse*. Anything that could not be made is reported rather
   than quietly lost — **live cages are not built yet**, since a caged beast is a unit as well as
   an item.

**Cancelling the order is how you cancel the expedition** — take the patrol off the squad by any
means and the march calls itself off. Once they are off the map there is no order left to carry
and no recalling them. `fort/dwarf-rts`, which stands every squad down when the squads screen
closes, asks a generic guard table before clearing orders so it cannot cancel a march by
accident.

**A trade needs its tool in the fortress**: a pick for mining, an axe for logging. Nobody carries
one out and none comes back worn — it is proof the fortress is equipped for the work, the same
way you cannot put a dwarf on Mining with no pick in the stockpile. What counts as a pick is the
civ's own `digger_type`; what counts as an axe is an `AXE` weapon small enough that your race
wields it in one hand, measured against that same pick — which keeps great axes and halberds,
same skill and twice the size, out of the count.

**Mining and logging never come home empty.** A squad with no Miner between them still spends a
week at a quarry and can carry one rock out of it. The floor is one item per **mission**, not per
pick, so choosing a small cluster alongside a layer stone does not turn a 1-in-500 vein into a
guaranteed one — the guaranteed item lands on the quarry stone. Botany and hunting keep no floor:
a week's foraging really can find nothing.

A **`[Send Expedition]`** button sits at the foot of the stone, trees, plants and game sections,
on sites **under your control** only. It opens a two-panel picker: the **squad** on the left with
the skill that matters to this trade beside each one, and the **targets** on the right, one name
per line under their group headings — a list you are picking from wants to be a list, even though
the same names read better wrapped when you are only looking. Mining carries two ticks, one in
the layer stones and one below; it defaults to the first layer stone and the first vein. The
window opens as tall as the screen allows so a forty-name list rarely needs scrolling.

The survey panel itself scrolls too — the wheel moves it while the pointer is over it — and
always leaves five rows free at the bottom of the screen.

Every dwarf gets **one attempt per level** of the relevant skill, and expeditions grant **no
experience** — they spend skill rather than build it.

| trade | skill | a level buys |
|---|---|---|
| **mining** | Miner | ⅕ of a layer stone **and** a share of the vein or cluster it was digging for |
| **logging** | Woodcutter | ⅕ of a log |
| **botany** | Herbalist | a 10% chance at the chosen plant |
| **hunting** | Ambusher | a 10% chance at a corpse, 1% at a live one in a cage |

Mining and logging additionally guarantee a single item per mission, however unskilled the squad
(see above); an unskilled party comes home with one rock or one log, not nothing.

**Scholarly expeditions** send scribes to copy books, and are the one trade that may leave your
own holdings: copying takes nothing away, so any library you are on speaking terms with will do.

| | |
|---|---|
| **contacted** | `Library: N books   [Send Expedition]`, then every title, one per line |
| **never met** | the label and *"Contact the site to learn about their books and send scribes to copy them."* — **no titles**, because you do not know what they have |
| **at war** | the titles, and *"Make peace in order to send scribes to copy these books."* — no button |

Titles are a **list**, not the wrapped prose the other groups use: a library runs to dozens of
books — Furnacehailed holds 96 — and the button sits on the **header** row so you never scroll
past sixty titles to reach it. Titles the fort already holds are plain; ones it lacks are red,
the same convention as everything else.

Each scribe has a flat **1/10** of bringing a book home, plus **1/10 per level of Reading** —
summed and converted once, so **ten unskilled scribes always come home with at least one book**
(verified: ten yields exactly one, nine yields nothing). **No duplicates in one trip** while the
library still holds anything the fort lacks; once you own every title it has, a second copy is
the only thing left to bring, so the rule relaxes rather than returning nothing. Verified at a
hundred scribes: ten books, ten distinct, zero duplicates.

Separately, **1/100 per level of Reading** that somebody turns up a book the fortress has never
held **from anywhere in the world** — the 1117 distinct artifact-book titles that exist. If you
already own a copy of everything, this finds nothing.

**A book is three parts, and a copy has to build all three**: the bound `item_bookst`, its
`title`, and an `itemimprovement_pagesst` carrying the page material, the page count and the
`written_content` ids. Sharing the content id with the original is not a shortcut — that is
precisely what a scribe's copy *is*, and DF expects many items to point at one written work.
Ordinary copies do not exist off-map, so the source to copy from is the **artifact** record, the
same one the site panel lists under Artifacts; all 96 of Furnacehailed's titles resolve to one.

**Contact is a third state, not a flag.** `site_hostile` collapses "at war" and "never heard of
them" into "not hostile", which is right for colouring a map marker and wrong here — both block
scribes, for different reasons with different fixes. `site_contact` returns `war` / `contact` /
`nil`, and your own holdings short-circuit to `contact` since DF records no diplomacy state
between you and yourself. In this world only **Furnacehailed** (96 books) and your own
**Scrapedwind** (20) are contacted; Bannertongue, Silkendied, Scarsabre, Brasschained and
Stalkerhex are all unmet, and nothing is at war — so the war branch is written but unexercised.

Any fractional rate reads as "this many for certain, and a roll for the remainder" — 120% is one
guaranteed and a one-in-five chance of a second.

**A mining expedition picks two things**: a layer stone to quarry, and a vein or cluster to dig
for. There is no failure roll — the layer stone is the quarry work that always pays, and the
target is what they were actually after. The share depends on how the geology buried it:

| target | per level | at 150 squad levels |
|---|---|---|
| layer stone | ⅕ | 30 |
| vein | ⅒ | 15 |
| cluster | 1/20 | 7–8 |
| small cluster | 1/100 | 1–2 |
| single gem | 1/500 | rarely one at all |

Single gems are an **extrapolation** and not part of the agreed rates — the ramp had to continue
somewhere, and leaving a whole tier unfetchable seemed worse than guessing. Adamantine is never
offered. A full squad of legendary woodcutters brings home **40 logs**, which you would not
usually have.

**Hunting has three tiers and they do not stack**: ordinary game 10%/1% per level, ordinary game
in a **savage** place 5%/0.5%, and a **giant** 2%/0.2% wherever it stands.

`fort/economic-expeditions plan <kind> <site id> <squad #> <what>` prints what a squad would
bring back, changing nothing — mining takes its two picks as `"<layer stone> + <vein or cluster>"`.

`fort/economic-expeditions` prints the survey for the selected site, or pass a site id.

### **`fort/research-breakthrough`**
When a scholar in your library finally cracks a topic — the vanilla **research breakthrough**
announcement — this hands you **one recipe unlock**. A picker opens listing every item your
civilization does not know how to make yet, and the one you pick is yours for good: high boots,
cloaks, masks, bowls, great picks. Items native to a dwarf civ are marked `*` and sorted first;
the rest is other civs' gear, yours to take anyway. Procedural artifact junk types and training
weapons are filtered out.

This is a **house rule, not a hidden vanilla link** — in DF the 312 research topics unlock only
literary forms and have nothing to do with crafting. The breakthrough is just the trigger; the
topic discovered does not constrain the choice. Breakthroughs are rare (a scholar needs ~120+
ponder cycles for their first), so expect a few a year at most in a fort with a real library.

It lives in the **house rules** column of `magnus-scripts` — the column for tools that change what
the game *means* rather than doing the clicking for you. Like `joke/`, that column starts empty and
is untouched by the `[r]` and `[m]` master switches: a switch meant "arm the useful pack" should not
quietly change the rules of your fort. Turn it on with its own `[h]` header or by clicking the row.

Detection is the announcement, not a scan — a watermark on the announcement id, walking only what
arrived since the last look. The unlock writes the same civ field the stock `add-recipe` writes,
with diggers routed to `digger_type` so picks land in the right menu. Unspent unlocks are banked
per fort and shown as the `research_unlock` notification; Esc banks rather than wastes, and the
`Cancel` button at the top of the picker forfeits the banked unlocks outright.
`research-breakthrough list` prints what is still unlockable.

### **`fort/rusty-legends`**
Keeps skill rust off a retired adventurer's every skill — matched on the nemesis
`ADVENTURER` flag, never a name or a skill count — and off any citizen's legendary
skills. Everything else rusts as normal. Swept once a game season. There is no stock
DFHack tool for this.

This is a **house rule**: in vanilla every unused skill rusts, legendary ones included,
and a retired adventurer's lifetime of skills rots in the dining room like anyone else's —
the game has no "no rust" switch for anyone. Exempting a class of skills from rust is a rule
DF does not have, so it lives in the **house rules** column of `magnus-scripts`, off until
you turn it on and untouched by the `[r]` / `[m]` master switches.

### **`fort/quick-order`**
Type plain text on the Work Orders screen to create a legal manager order, with "keep N in
stock" repeats. Only offers subtypes your civilization actually knows how to make.

![fort/quick-order demo](demos/fort-quick-order.gif)

### **`fort/planner-orders`**
Warns of planned buildings nothing produces and offers the orders to make them, along with the
standing orders a fort keeps forgetting — brewing, fuel, milling, containers, and one smelting
ask per ore as you find it. **Bronze comes straight from the ore**: hold a tin ore and a copper
ore and it offers the Smelter's "make bronze bars (use ore)" as a single job, skipping the two
separate smelts — gated on *an ore of* tin and *an ore of* copper rather than on named stones, so
changing which copper ore you are mining does not strand the order. With a hospital
up it also stocks the supplies one needs, traction benches included — the bench and its table,
mechanism and chain each get their own ask — and the chain ask, the one kept stocked rather than
made once, is held at *N chains of the metal it forges*, so the iron ones you already have never
hold a copper order shut. Some asks are standing preferences rather than
one-off gaps: say yes to cutting the rough-gem surplus once and it is handled from then on, one
Cut Gem job at a time, posted again whenever that one is finished and the pile is still over ten
— no second ask, and `planner-orders disable` hands it back. **Glass is two standing asks**:
*Clear glass* keeps raw clear glass in stock and cuts it to gems (offered once there is pearlash
or an order making some, since clear glass is sand *plus* pearlash), and *Green glass* offers to
keep five raw green glass on hand the moment the fort holds any at all and nothing is making
more — green glass costs only sand and fuel, so a fort down to its last piece is a fort that
simply forgot to ask. Both are repeating orders offered whenever they are missing, rather than
the one-time batch that used to ride along with the pearlash chain and could never be asked for
again. Adamantine is the same, and has to
be: its ladder — keep 3 raw boulders always, then 3 wafers, 3 thread, 3 cloth, 9 wafers for a
true throne, and the rest stays raw — counts the adamantine you have set *aside*, and a manager
order gated on a condition cannot see a forbidden wafer, so it would extract more to replace
what was merely reserved. One rung at a time, and only what that rung asks for. **Silk webs**
are the third: it gathers three cobwebs at a time, but only ones hanging inside your emergency
(civilian alert) burrow, and only while you hold under thirty silk thread — *your* thread, not the
webs, which DF files as silk thread too and so reads as stock you already have. Each job names
the web it is for, because a plain collect-webs order is gated on that same lying count and
sends the weaver to whichever web is nearest, cavern included.

![fort/planner-orders demo](demos/fort-planner-orders.gif)

### **`fort/labor-groups`**
Tidies the Labor screen and creates any missing crafting work details. The list ends with
*Animal Trainer*, then *Military*, then **Strand extraction** — the adamantine labor you go
hunting for the moment a vein turns up and never think about again, parked at a fixed place
at the very bottom with the custom-**I** icon, which nothing else here uses.

### **`fort/sort-locations`**
When you assign a new temple or guildhall, the deities and professions that have actually
*petitioned* for one are moved to the top of the list, in DF's order otherwise — instead of
sitting somewhere among sixty-odd entries that look exactly the same. Petitions are read from
the agreements themselves and filtered to your own site, so another settlement's guild never
pulls a profession up your list. *(No particular deity)* keeps its place at the head, and a
list already in the right order is left alone so nothing shifts while you read it.

### **`fort/holiday`**
Stops the fort working, and starts it again with everything exactly where it was. A **[Holiday]**
button sits on the work detail screen beside [Change Icon]; `fort/holiday on` / `off` does the
same from the console.

A fort that has to *be* somewhere — everyone into the burrow before the siege lands, everyone off
the surface before the clouds arrive — spends the crucial minute being dragged back to workshops
by jobs already queued. Turning the labors off turns the queue off with it.

Nobody's work detail membership is touched. Every detail's **mode** is set to *nobody does this*
and the mode it had is written down; every labor still standing after that is cleared on the dwarf
and **written down per dwarf**, so the fort resumes exactly as it was rather than as DF would
guess. Measured on a 92-dwarf fort: 6,069 labors enabled before, **0** during, 6,069 after with
all 92 dwarves identical to their snapshot and every detail mode back.

The order is the fiddly part and the comments say so: `setAutomaticProfessions` rebuilds the
uncovered labors from DF's defaults, so it runs *before* the direct clears going in and *before*
the direct restores coming out. A running holiday also re-asserts itself a few times a second,
since DF rebuilds a dwarf's labors whenever it recomputes one — opening the labor screen is
enough — and a holiday that ends the moment you look at it is no holiday. It survives a save and
reload, and ends correctly from the other side.

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
order a group, shift-click to grow a patrol route out of where a squad is standing. A
patrol walks its route once and holds at the far end, unless you close the route back on
its own start, which keeps it cycling. The dotted trail DF paints between route waypoints
is kept off the map -- the waypoint banners stay, and the trail comes back while you have
the patrol-route screen open. Clicks on any UI -- or in the three-tile band
around the screen border -- are always left to the game. While a squad is under any order it
sleeps **in barracks at need** and carries **no food or water** -- the schedule and supplies
settings you would flip by hand before an order -- and gets its own values back when the last
order goes, even across a save. A new order also **drops the march the old one started**:
vanilla lets a soldier finish walking to wherever the last order sent him before it reads the
new one; here the path goal is cleared with the orders, so the next step obeys the new click.
And **no standing over the corpse**: vanilla leaves a soldier fixed on a dead target for
several hundred ticks -- about a day -- before he returns to his order, and does the same
standing "search" for one that got away; a member under orders whose target is dead, gone or
out of reach is released at once.

### **`fort/military-labor`**
Keeps the "Military" work detail matched to your standing squads.

### **`fort/better-hives`**
A beehive does nothing until you tick **Install a colony**, and DF never ticks it for you. One
fort built fourteen hives — finished, each holding its glass hive, ten wild honey-bee colonies on
the surface, eighty-eight beekeepers — and not one had a colony, because that flag was off on all
of them. This switches it on **once, the first time a hive is seen finished**, so bees move in on
their own. Once is the whole point: a hive you turn back off by hand, or want kept empty (an empty
hive is how you stop a split), is never touched again; each hive's one nudge is remembered with
the fort. Only a *built* hive counts, so a stack of planned ones is left alone until each goes up.
It fires **on the build itself**: the job that raises a hive is a `ConstructBuilding` job
carrying a reference to the building, and DFHack's `JOB_COMPLETED` event hands that job over
the moment the builder finishes — so the flag goes on in the same tick the hive becomes a hive,
with nothing scanned in between. Hives already finished when it is switched on are caught once,
on enable. Enabled by `magnus-scripts`.

### **`fort/training-barracks`**
Marks one barracks as the fort's training barracks and assigns the squads with nowhere to
drill to train there.

A squad that **already trains at another barracks is passed over**, and one that picks up a
barracks of its own later is **released from this one** on the next pass. That squad has been
given a training ground deliberately, a second training room would only split its drill
between the two, and an assignment that outlives its reason is one you untick in the zone UI
and watch come straight back. Only the *train* use counts: a squad that merely sleeps or
keeps its equipment in another barracks has no training ground, so it still gets the basic
one — and releasing a squad clears only *train*, leaving those other uses alone.

### **`fix/assigned-equipment`**
Frees gear the squad equipment lists refuse to offer.

Two things hide a perfectly good item from the uniform pickers. One is a *phantom assignment*: an id
left in `plotinfo.equipment.items_assigned` after the squad, uniform or soldier that claimed it is
gone, so the item belongs to a soldier who does not exist and nothing ever releases it — those ids
are moved back to the unassigned lists (ids whose item is gone are dropped). The other is *personal
property*: an item a citizen has claimed is skipped by the equipment manager outright while it sits
in the unassigned list looking available, so it never appears in the picker however hard you look —
which is how adventurer gear carried into a fort usually ends up unusable. Every piece of military
gear a citizen has claimed is reported, and `--unclaim` drops the claim so DF offers it on its next
equipment update. "Military gear" is the item types the equipment screen deals in — weapons, shields,
ammo, quivers, flasks, packs, and for the armour slots only real armour (`armorlevel > 0`) or an
artifact — so the clothes dwarves own are left to `cleanowned`, and a visitor's own sword is never
confiscated. Anything a squad, hunter, work detail or soldier still references is left alone. `-n`
reports only, `-v` names every item, and `--all-squads` widens the reference scan from your fort's
squads to every squad in the world.

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

### **`fort/help-mood`**
Run by hand during a strange mood (`fort/help-mood`). If the fort cannot satisfy the mood it
says one thing and no more -- *"The gods are testing you"* -- because knowing what a mood wants
IS the blessing, and because by then the demand is already rolled: what you were short of is
`fort/moody-items-warning`'s question, and it answers it all the time. Otherwise it lists
one row per ITEM the mood needs, read from the job's own
filters, proposes the highest-value candidate for each, and lets you click any row to choose
from everything that fits. Where the dwarf's preferences and moodable skill settle it, it says
what is coming: *"...announces they will create a table!"* Then `[build selected artifact]`
forbids every other candidate in the fort -- including ones mined, butchered or woven while the
dwarf walks -- so DF has one legal choice per row and takes it, instead of the nearest boulder.
It never changes what the mood *asks for* — the requirement is the mood's own, and the panel
only helps you satisfy it. Requirements already hauled in are shown as claimed; candidates are
limited to what the dwarf can actually walk to and to what the fort can actually give — an item that belongs
to a building is never offered, since `flags.in_building` is clear on workshop contents and unforbidding one
does nothing (the forbid was never what stopped it); worn, part-used and forbidden items are shown,
labelled, and never chosen by default, and a block that was built into a wall or pillar says `BUILT INTO A
WALL` rather than a bare "unreachable" — it is still an item at that tile and still in your stocks, which
makes it look eminently walkable. And when the fort is short of what the mood wants,
`[delay work]` (Ctrl-D) buys the time to make it: the dwarf gets a burrow of nothing but their
own workshop, so there is no item they can reach and the mood holds where it is until you lift
it. Everything it touches is put back.

The mood line names the craft the mood claimed — "Gautier, Clothier, is taken by a fey mood!" —
since that is what decides the base material and whether the fort can supply it at all; DF fixes it on
`unit.job.mood_skill` when the mood begins, so it is known before a workshop is claimed.

The status line quotes the dwarf the way DF does — a fey or fell dwarf *screams, "I must have rock
blocks!"*, a possessed one names the artifact and trails off the way DF does, *mutters, "The Flighty Shrine
requires bars... metal..."*, a macabre one *broods, "Yes. I need …"*. A dwarf never says the specific
material: where the mood wants iron bars he asks for *bars... metal…*, and only a requirement that is
already generic ("rock blocks") is spoken as it reads.

**A secretive dwarf draws it instead**, and DF gives the drawing its own vocabulary — so that is the
vocabulary used: bone is sketched as *skeletons*, stone as *a quarry*, wood as *a forest*, metal bars as
*shining bars of metal*, blocks as *square blocks*, leather and cloth as *stacked* leather and cloth, a
skull as *death*, and clear glass as *glass and burning wood*. Not the requirement's own name in DF's
sentence — the line DF actually prints.

Items the dwarf cannot walk to are listed last and marked `UNREACHABLE`, and the picker refuses to take
one — hiding them made the panel claim the fort had nothing when it held twenty-five blocks across a
chasm. Where an item was made is ignored: a foreign block builds like any other.

### **`fort/butcher-shop`**
Bulk-marks animals for slaughter, grouped by species and sex, with last-breeder warnings. Young
get their own rows and stay hidden until you ask for them (Ctrl-Y).

Beneath its `[Butcher]` button sits a **`[training]`** one, opening `fort/animal-training`'s
trainer picker. The butcher's shop is where you stand while deciding an animal's fate, and
"train it instead" is the other half of that decision — but reaching it otherwise means going
and finding an animal-training zone first. The button lives in *this* overlay rather than in
`animal-training` because this one already snaps itself to the right row by scraping for
"Add new task"; a second widget guessing at the same anchor would drift out of line with it.

### **`fort/filter-other-units`**
Category filter buttons on the Units screen's **Other** tab, where the Dead/Missing tab
keeps its `[Show death cause]`: `[Friendly] [Wildlife] [Hostile]` are independent toggles
(none lit = unfiltered, so clicking one filters to just that and clicking a second adds
it), and `[Caged?]` cycles separately through *cages don't matter* → `[No Cage]` →
`[Caged!]`, so Hostile + `[Caged!]` is your prisoner list. The categories are DF's own,
read out of the `Cat` column it already draws rather than guessed again from unit flags.

**What goes where.** `Friendly` and `Hostile` are not the only friends and enemies on that
tab, and taking them for the whole answer is what made the buttons look broken: a fort with a
caravan in and a tavern full of visitors had **not one row** saying either word — the list was
guests, a merchant's camel, ravens and a bronze colossus — so every row fell through to
"unknown" and no filter moved anything.

| Button | DF's words |
|---|---|
| Friendly | `Friendly`, `Merchant`, `Guest` (drawn as `Guest / Listen to Story`), `Caged Guest` |
| Hostile | `Hostile`, `Uninvited Guest`, `Caged Prisoner` |
| Wildlife | `Wild Animal`, including `Wild Animal (Caged)` |

Merchants and guests are people you let in; an *uninvited* guest is DF's word for the thing
that walked in without being asked — the bronze colossus, on the fort this was measured on —
and it belongs with the enemies. A cage says where somebody is, not whose side they are on.

**`[Caged?]` is on all three tabs** — Residents and Pets/Livestock as well as Other — and shows
**only where the list you are looking at actually has something caged in it**, the same rule on
every tab. A tab with nothing caged is never offered a filter whose only possible effect is to
empty it. The cage state is kept when you step onto a tab that has none, so stepping back finds
it as you left it. The category buttons stay on Other, the only tab with a `Cat` column.

Three things that tab has to teach you. **Residents' focus string has no tail** — Pets is
`…/CREATURES/PET` and Other is `…/CREATURES/OTHER`, but Residents is just
`dwarfmode/Info/CREATURES`, so registering for `…/CITIZEN` (what the mode enum calls it) matches
nothing and the buttons never appear there. **The tabs are not shaped alike**: Dead/Missing *is*
the unit list and Other is a stack holding one, but Residents and Pets wrap theirs in a
`widget_container` one level further down — a one-level scan finds nothing, with no error, and
the sweep just quietly does nothing on those two tabs. And **`[Caged?]` is pushed out to column
88**, well right of the other three, to clear DFHack's own `logistics.autoretrain` panel at
columns 50–85 over rows 59–63, which is exactly the row this uses; Dead/Missing is left out
altogether because `sort.deathcause_button` and `fort/needs-tomb-notification` already have that
row.

### **`fort/animal-training`**
Assigns a trainer to many caged animals at once.

### **`fort/wild-animal-train`**
Marks a wild animal for taming, so it's trained the moment it's caught. The `[Train]` toggle sits
on the animal's unit sheet, and **also on the item sheet of a cage holding one** — because
clicking a caged animal on the map opens the *cage's* sheet, not the unit's, so the unit-sheet
button never appeared for exactly the animals most likely to want training: the ones already in
a cage waiting for it. A cage holding several (a trap's catch) trains them together; the button
only reads green once every occupant is queued, and only an all-queued cage un-queues, so a
half-done cage never toggles the wrong way.

It sits in **the same spot `fort/auto-pasture` puts `[Graze]`/`[Scavenge]`**. That overlay owns
that row of the cage sheet for an animal already tame or trained; this one owns it for one that
is not. They can never be visible at once — one wants `isTame`, the other `not isTame` — so
sharing the position is deliberate, and it keeps the button where your eye already goes for
"what do I do with this animal".

Either way it writes the game's own basic-training assignment with `any_trainer` — every animal
trainer in the fort is eligible, rather than one being singled out.

## Automation

### **`fort/auto-needs`**
Lends a dwarf whose unmet need is wearing them down a labor that answers it, and takes it back
after.

The first need it knows is **wander → fishing**. "Wander" is satisfied by being outside the
fortress, and fishing is the reliable way a dwarf takes themselves out there and stays a while.

**One bar, shared by every rule here and every rule added later: −750.** A need's `focus_level`
goes negative as it goes unmet, and −750 is far enough down to catch a dwarf before the need
starts distracting them or handing them bad thoughts, without tripping on the ordinary shortfall
half the fort carries at any moment. The loan is handed back at **zero**, so there is a gap
between the two bars and nobody flickers in and out on a point of focus. Stress is not part of
the test: an earlier version demanded it as well, which meant waiting for the damage to show
before answering the need that was causing it.

A labor it turned on is remembered and turned off again once the dwarf no longer qualifies. A
labor the dwarf **already had** is never recorded and never removed, so a fisherdwarf who was
fishing before stays one. The record lives with the site, so a reload does not strand a lent
labor.

It gives the labor the way DF actually accepts it: by adding the dwarf to the **work detail**
that carries it, putting that detail into *only the selected do this* if the fort had it at
*nobody does this*, and calling `setAutomaticProfessions` — writing `unit.status.labors` directly
does nothing that lasts, since the details are recomputed over the top of it. The detail's mode is
put back the way it was found once the tool has nobody assigned there.

**The public library.** The second need it answers is *thinking abstractly* / *self-examination*
— two needs DF drains with the same act, reading or writing written content — and the lever is a
**scholar's post at a library**. Open a zone belonging to a library and a **`[Public Library]`**
button sits on its panel, the same place `training-barracks` puts `[Basic training]` on a
barracks. Pressing it marks that **location** (not the zone, so any of the zones making it up will
do) as the library this tool staffs.

Each pass, **every** citizen past the bar is given a scholar post there — no limit, no queue.
They read, the need drains, and a pass or two later the post is handed back, so the library staffs
itself up and down with the fort's mood the way `autotraining` and `idle-crafting` do. On a
95-dwarf fort that came to 26 scholars at once, and the same 26 the count said were past the bar.

**Nobody is passed over for being busy** — a soldier, a tavern keeper, a doctor all get one the
moment they are short, because it costs them a few hours of reading. Two things still rule a dwarf
out and neither is a policy: no historical figure (an occupation record is keyed by `histfig_id`,
so there is nothing to write) and already being a scholar here. Children never come up; DF has no
child occupations. A post the tool did **not** create is filled and emptied but never deleted, so
a library set up by hand keeps its shape; posts it created are closed again once nobody is
standing in them. Un-marking the library takes everyone off on the way out.

Stacking a second occupation on a dwarf who already holds one is off DF's own beaten path — 286
filled posts in this world and not one figure holds two — so it was tried before it was shipped: a
tavern keeper given a scholar's post kept both records and kept working, and the game ran on.

Measured on a live fort: 26 posted, DF answered with its own `PonderTopic` and `Research`
activities, and within half a game day two of them had climbed from −3130 and −777 to **+374** and
**+384** and been handed their posts back. The rest were still on their way. A library with
nothing in it to read is the one thing that stalls this — the need is drained by reading or
writing written content, so keep books, scrolls and blank quires in there.

It gives a post the way DF reads one: an occupation has three owners — the location's list, the
unit's, and `world.occupations.all` — so posting writes `unit_id` and `histfig_id` on the record
and adds it to the unit, and taking someone off clears both and removes it again. Extra scholar
slots are created and destroyed as needed, which resizes the location's occupation vector — never
done while DF's location details panel is open on that library, because that panel holds raw
pointers into it.

The two halves run independently: `enable fort/auto-needs` lends labors, `[Public Library]` staffs
the library, and neither switches the other on behind your back.

`fort/auto-needs` previews without changing anything, `fort/auto-needs once` runs a pass, and
`enable fort/auto-needs` runs one about once a game day. `magnus-scripts` has a row for it.


**Nothing creative → something to make.** A dwarf short on being creative is handed a statue or
a figurine, assigned to them by name the way `idle-smiths` hands out forge work. The options, in
preference order — cheapest to the fort first:

1. an **obsidian statue**, then an **obsidian figurine** — obsidian is worth nothing to anything
   else and looks the part;
2. a **green glass statue**, but only with a **magma** glass furnace and sand to hand. A magma
   furnace burns no fuel, so the statue costs one bag of sand and nothing else — which is why it
   comes *before* spending a real boulder. A wood- or coal-fired glass furnace is deliberately
   skipped: that statue would cost fuel, which is worse than the stone it saves;
3. a **plain stone statue**, then a **plain stone figurine** — a stone with **no economic use**
   (no ore, no thread metal, nothing on its `economic_uses` list) so making art never eats the
   flux, the gypsum or the ores.

Each dwarf gets the first option that is safe for them *and* has a free building, so a dwarf
blocked on masonry can still be served a figurine or a glass statue.

It is offered **only when the work cannot change what a strange mood would claim**. Masonry
(statue), stonecrafting (figurine) and glassmaking (glass statue) are all moodable, and a mood
takes the dwarf's highest, so an armorer given a statue can quietly turn their next artifact from
a suit of armour into a piece of furniture. Safe means the job's skill is already their highest
moodable skill *alone*, or sits **two full levels** below it — a tie at the top counts as unsafe.
The margin is two, not one: one level of room is not enough, because this job is not the only
thing that will ever train that skill and a dwarf sitting exactly one level down gets carried over
the top by ordinary work. On a 113-dwarf fort that difference blocks 27 dwarf/skill pairs the
one-level rule would have allowed, nearly all of them the same shape — top moodable skill at 1,
the craft skill at 0.

**The bar is flat: −500, the same for every dwarf, for every need tracked.** It sat at −750,
which is where an unmet need stops being background noise for a dwarf with slack to spare — and
that let this fort's angriest citizen be passed over pass after pass with abstract thinking at
−614, a need she genuinely was not getting and just not deep enough to notice. Stress is not the
answer to that: a dwarf who is already breaking is the last one a cheap loan reaches in time, so
the bar moved down rather than growing a second, stress-shaped test.

### **`fort/idle-smiths`**
Lets idle dwarves work the forge to satisfy their craft need, picking legal metals per item.
Soldiers whose squad is under orders are left to those orders.

**What it makes is melted again.** A dwarf forging to settle a craving turns a bar into a helm
nobody asked for, so each piece is designated for melting as it comes off the forge and the bar
comes back. Two things are kept: a **masterwork** (melting a dwarf's best work is the one sure
way to make them miserable) and a **silver war hammer** (silver is useless as armour but its
weight makes the best blunt weapon in the game). Only jobs *this tool* queued are followed — a
piece from an order you placed at the same forge is left alone.


**Angriest first, and a pass a day.** A need bucket used to be a hash set, so whichever dwarf
the iteration reached first was served and the same few kept winning — with 28 dwarves in the
top bucket and three forges, a given dwarf could wait months. The queue is now ordered by
stress, deepest need breaking ties. And the rescan runs **once a game day** rather than
upstream's 8419 ticks (seven days): since a forge is marked failing for the rest of a cycle the
moment it takes a job, that cadence capped the whole fort at one job per forge per week.


**The practice pieces are melted again.** A dwarf forging to settle a craving turns a bar into
a helm nobody asked for; left alone they pile up and the metal is gone. Each piece these jobs
produce is designated for melting as it comes off the forge — except a **masterwork** (the
dwarf's best work, and melting it is the one certain way to make them miserable) and a **silver
war hammer** (silver is worthless as armour and makes the best blunt weapon in the game). Only
this tool's own jobs are followed, by item-id watermark, so a piece from an order you queued at
the same forge is never touched.

### **`fort/auto-mandate`**
Fills Make mandates with cheap materials (even minting coins) and prioritizes the work.
Each order it queues is announced — who mandated it, and what was ordered.

**Siege equipment** is queued too: catapult parts, ballista parts, a ballista arrow head and a
ballista arrow (DF's `SIEGEAMMO`). Parts and arrows are left **unconstrained** rather than given
the wood policy — that one falls back to metal when the fort is short of logs, which here would
queue a forge order no forge can take, and the siege workshop already restricts the material to
what it will accept. The arrow *head* is the one thing that is genuinely forged, from a bar, so it
takes the cheap-metal policy. These also get DF's own words: the item tokens lower-case to
"catapultparts" and "siegeammo", which is not what the announcement should say.

**Garments are never metal.** One `item_type` covers both the armoury and the wardrobe — `PANTS`
is greaves *and* trousers, `SHOES` is high boots *and* socks, `ARMOR` is a mail shirt *and* a
robe — and only the **subtype** says which. Pinning the copper policy by item type queued
"3 copper trousers", and the trap is that DF *takes* that order: the forge makes them and hands
the noble a metal garment. This fort had **six copper trousers** in it, quality 4 and 5, made by
three of its own dwarves, with bars spent on clothing a clothier would have woven for free.

So the subtype decides. The raws say it outright — a metal-capable piece carries the `METAL`
flag (greaves: `HARD, METAL, BARRED, SHAPED`) and a garment does not (trousers: `SOFT, LEATHER,
WOVEN_THREAD`). Metal-capable pieces keep the copper policy; garments are pinned to a material
**category** instead, chosen from what their own raws allow — `SOFT` means it can be woven,
`LEATHER` means it can be cut from a hide, so trousers may be either and a sock only woven — and
within that, the category the fort has the deepest usable pile of. Leaving the material merely
*unpinned* is not enough: a forge will take an unpinned `MakePants` and make it out of copper
again. One category is set, never a combination, because every order blueprint DFHack ships sets
exactly one and a combination is unproven.

**Jewelry is metal, not wood**: a wooden earring is legal and worthless, so amulets, rings,
bracelets, earrings, crowns and scepters follow the cage rule — copper if there is any, then
any metal, then wood, so a fort with no bars can still comply. And every choice asks whether
there is **enough for the whole mandate**, not whether there is one: a mandate for ten earrings
backed by one copper bar stalls after the first, and a stalled mandate is a punished mandate, so
it moves to the next material the fort actually has. Metals are ranked cheapest first (ties to
whichever there is more of) and filtered to things that can actually be forged into items —
`items.other.BAR` also holds coal and pearlash, and bismuth is an alloy ingredient, none of which
make an earring. **Stone goods** take obsidian (worthless and renewable), and
failing that **whichever stone the fort has most boulders of** — the one it can least miss, which
on a fort cut out of gabbro is gabbro and on one cut out of sandstone is sandstone, without having
to name either. Stones the fort's own stone-use settings hold back as economic are skipped, since
an order pinned to a stone the masons will not touch is worse than an open one.

### **`fort/auto-elf-chop`**
Keeps tree-cutting under the elves' yearly limit by designating the nearest trees itself.
A `fort/dig-shapes` chop box that would go past the allowance is cut back to what is left, and
at the limit refused outright, with a notice either way — on purpose or by accident, the
agreement is not broken from there; DF's own Chop tool is the way past it.

### **`fort/harvest-plants`**
Designates every ripe shrub standing in a Gather Fruit zone for gathering once a month, instead
of waiting for the zone to trickle a few tiles out at a time — vegetables and fruitless plants
included, not just what DF picks on its own. It uses DF's own mechanism: the same tile
designation the Designate › Gather tool paints, so DF posts and runs the jobs exactly as if you
had dragged the tool over the zone. Tiles already designated or with a gathering job are skipped,
so nothing is ever doubled up, and withered shrubs (`ShrubDead`, or a plant flagged dead) are never
touched. A `[Harvest]` button on the zone panel, below the three gather settings, turns a zone's
auto-designating off and on and acts immediately: on designates that zone's ripe shrubs there and
then, off clears the designations it painted (jobs DF already posted are left to run — pulling a
job DF owns has crashed this fort). It is on by default, and a zone with "Pick shrubs" switched off
is skipped. Only shrubs with something on them are designated — a plant with growths has produce
only while one is in *season*, and leaves and flowers are not produce — and its own designations
are re-checked daily and cleared when their season ends, so a summer berry patch is not still
designated in late autumn on bare twigs. Hand-painted designations are never cleared.

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

## Information

### **`fort/better-world-map`**
On the World screen, `Center on fort` also flashes a bright `!` over the fort for five seconds,
because on a big world the centre of the map is a crowd of sites and the fort is one tile among
them. The marker follows the fort if you scroll during the flash.

### **`fort/find-hidden-artifacts`**
Run by hand; prints who has your artifacts and where the missing ones went. The fort's
artifacts are read from the world's history — made here, ever stored here, claimed by the
fort — not from the artifact's current site, because DF blanks the site the moment a thief
picks one up, which is exactly when you want it listed. **On somebody who is not yours** names
every non-citizen on the map with one of them: how it is held, where they stand, and who they
really are — a visitor with a "name" in quotes is wearing a false identity, and the line gives
the real name, race, profession, civilization and every religion, troupe or company they
belong to, since villains are entities too. It catches the one DF hides: a thief at the map
edge is already dropped from the active unit list while still standing on it with the
artifact in hand, so the pass is over the whole unit list, once, flagged *HEADING FOR THE MAP
EDGE*. If they laid claim to it themselves it says when. **Gone from the map** gives each
missing artifact the world's best answer — destroyed, away with your own squad, held by a
named figure and where they are, at another site, lost in the wilds — or, when DF has not
caught up with a thief on the road, says so, names the pedestal it was last on and whether
anyone saw it go. Both sections count the foreign claimants and list the newest few living
ones, because claims are how the world decides who comes for an artifact next. Citizens and
visitors' own artifacts are not listed.

### **`fort/unit-attributes`**
An `[Attributes]` button on a unit sheet's *Other Skills* tab, above the Progress Bar toggles,
opening all nineteen attributes at once: current value, the highest that dwarf can ever reach,
and how far the value sits from the median for that creature's own caste in DF's steps of 250.
The window measures itself against what it is showing, so nothing is cut off at either edge,
and it does not pause the fort. Click any attribute for the list of jobs and skills that
exercise it — transcribed from the DF wiki, since the game does not expose that mapping at all,
and the panel says so.

### **`fort/thought-police`**
Counts the fort's recent bad thoughts and prints the worst, most common first.

The stress screen names the miserable dwarf; it never names the cause, and a hundred unit sheets is
not a diagnosis. This walks every citizen's emotions, keeps the ones from the last month (`days=N`),
and groups them by what happened rather than by which feeling it produced — "sad about X" and "angry
about X" are one problem to fix. `NeedsUnfulfilled` is broken out by the need that went unmet, since
that is the entire content of the row. Each row shows how often it happened, how many citizens had
it, how many have not got over it yet, and the harshest emotion DF attached to it with how hard that
bites on a scale of 1 to 8 — Annoyance (1), Sadness (2), Grief (4), Horror (8). The number is DF's
own: it divides a thought's severity by the emotion's divider to reach stress, and every negative
emotion in the game uses 1, 2, 4 or 8, so the same thought recorded as horror really does cost eight
times what it costs as annoyance. Fifty dwarves wanting a cup is a smaller problem than three
reliving a death. `-v` names the three dwarves who had it most, with the running
stress total each is carrying; `top=N` changes how many rows print.

What counts as bad is DF's own arithmetic, not a hand-written list of unpleasant-sounding emotions:
each emotion carries a `divider` DF uses to turn severity into stress, so a positive divider is a
thought that hurt. There is deliberately no "stress caused" column — DF does not record one, and the
`severity` field that looks like it sits at 0 on most unpleasant thoughts, witnessing a death
included, so anything computed from it reports a contented paradise.

### **`fort/creature-description`**
Shows a creature's full description (great for forgotten beasts) with a categorized kill
list — each megabeast type by name, the cursed called out ahead of everything sentient
("1 goblin vampire, 2 kobold necromancers, 1 weremoose"), and sentient kills split by caste
("27 orcs, 9 orc champions, 5 illithids, 2 ulitharids"), with male/female castes grouped
together.

![fort/creature-description demo](demos/fort-creature-description.png)

### **`fort/item-description`**
Shows an item's full description instead of DF's truncated box. For an artifact it adds, two
rows below the description, who made it — *"Created by Blanchefleur Dodókumril, dwarf child in
129."* — read from the world's history, which is the only place DF keeps it.

![fort/item-description demo](demos/fort-item-description.png)

### **`fort/statue-redirect`**
Opens a statue's full item description, and adds a Remove button to built items.

![fort/statue-redirect demo](demos/fort-statue-redirect.gif)

### **`fort/clickable-noble-names`**
Makes the dead space on the Nobles screen live: click a noble's row to open their sheet
and follow them, or click one of the office/bedroom/dining/tomb icons to jump to that
room. DF's own assign and symbol buttons still work — the row is measured from the
render, so those blocks are handed straight back to DF.

### **`fort/better-bridges`**
Two fixes to the building sheet, both about the same blind spot: DF knows perfectly well that
this bridge is wired to that lever, and shows you a list of mechanisms instead.

**Linked buildings is the default panel when there are any.** A building sheet has two panels at
its foot — *Show linked buildings* and *Show items* — and DF always opens on Show items. For a
bridge, a door, a hatch, a floodgate, a lever or a pressure plate, "items" means *the two
mechanisms inside it*, which is a fact about the masonry; the question you opened the sheet to ask
is **what is this wired to**. So when the building has a link, the sheet opens on the links; when
it has none the panel is left alone, because then items is all there is. Only the *first* look at
a building is redirected — click *Show items* afterwards and it stays there for as long as that
sheet is open.

A link is found from **both ends**. A lever or a plate keeps the far end's mechanism in its own
`linked_mechanisms`; the bridge at the other end keeps nothing at all — it just has a mechanism
sitting in its `contained_items` whose refs point back. Reading only one end gets you a lever that
knows its bridge and a bridge that knows nothing. Read both and a bridge driven by two controls
lists both of them, which is exactly what the test fort had: one bridge, a lever and a plate.

**`[Open /]` / `[Close /]` on a pressure plate**, in that same list. DF already draws a `[Pull    /]` on the
**lever** rows of the linked-buildings list — open the bridge, see its lever, pull it from there
without going to find it. A plate gets no such button, because a plate is fired by the world
rather than by a dwarf. But when the world has already put something on it, there *is* something
to fire, so `[Trigger /]` goes in the same column on the plate's row:

* It appears only when **water, magma or a minecart** is actually on the plate's tile. Nothing on
  the plate, no button — there would be nothing for it to do.
* Clicking flips the plate's sense flag for that condition, and the button is **green** while the
  plate is already sensing it. Turn it on with water sitting there and the plate fires and the
  bridge moves; turn it off and the plate stops sensing and the bridge goes back. DF keeps that
  same On/Off on its Water / Magma / Track tabs, three clicks away.
* A plate can have more than one of them on it at once. The button aims at the **first** of water,
  magma, minecart that is there — a liquid beats a cart — so it is one button with one meaning
  rather than a row of them.

**It says what the click will do.** Looking at a **bridge**, the button reads `[Open    /]` or
`[Close    /]` rather than `[Trigger /]`, because from there the answer is knowable: a raised
drawbridge is a wall and a lowered one is a floor, so raised is *closed*. Either way the click
toggles the bridge — turning the plate's sense on fires it, turning the sense off lets it reset,
and DF moves the bridge on both edges — so the word is simply the opposite of where the bridge is
now, and a bridge caught mid-movement is judged on where it is heading. Anything else at the
other end still reads `[Trigger /]`; "open" is not something this can promise about a lever or a
hatch it has not been taught. All three are built to DF's own stencil — eleven columns with the
`/` pushed to the end, exactly like `[Pull    /]` — so the button never changes width as the
bridge moves.

It does **not** touch the plate's ranges. A plate set to fire between 1 and 3 units of water will
not fire under 7/7 however the flag is set, and rewriting the range to make the button "work"
would be quietly redesigning the trap. `fort/better-bridges` on the command line prints the depth
and the range instead, so a plate that will not move says why.

**Clicking it is not announced**, and nothing about the click is throttled or queued: the flag is
written there and then — measured at 0 ms — and the button repaints on the same frame, because DF
only redraws when it believes something changed and a flag written from outside its own input
handling is not something it knows about. What is *not* instant is DF acting on it. The plate has
to be evaluated and the bridge has to move, and neither happens while the game is **paused** — on
a paused fort the flag is set and nothing visibly follows until time runs again. The click also
hit-tests against the rows a button was actually painted on rather than re-deriving them from the
screen, since DF suppresses that panel under some of its own tooltips and a click landing in that
gap used to be dropped.

Where the row is comes from DF's own drawing. There is no vector behind that list — DF builds it
from the building's mechanisms as it paints — so the rows are found by reading back the
`[Unlink]` that DF puts at the end of every one of them, within the band the button occupies and
nowhere else. The button draws twelve columns to the **left** of that anchor, so it never covers
the text it navigates by.

### **`fort/better-track-stops`**
A track stop's sheet tells you its friction and its dump direction and nothing about the thing
that makes it work. This adds a panel with the cart on it: the route, the cart assigned to it,
what is in it, and where it has got to — *at the stop*, *18 tiles away*, or *carried by Bim
Azuzmeng, 25 tiles away*, since a cart in a dwarf's arms reports **their** position, which is the
honest answer to "where is my minecart". Click the line and the map goes there.

The panel sits directly above DFHack's own `Ctrl+x` / `Ctrl+f` track stop buttons and is the same
width as DF's window, both measured off the screen rather than guessed.

**`Assign: [Lava] [Water] [Empty]`** — one button per kind of cart, each shown only while the fort
has one that can actually reach this stop, using DF's own walkability groups, so a cart in a sealed
magma pit is never offered. A cart is assigned to a hauling **route**, not to a stop, so if this
stop is on no route the button **makes one** with this stop as its first stop and puts the cart on
that — it used to say "this stop is not on a hauling route yet" and leave you to go and build one
by hand, which is the work the button exists to save. What the stop *carries* is left alone and
named in the status line: that is the one part of a route only you can decide.

**The panel stays hidden on a track stop that is not built yet.** While it is a construction site
DF will still show its sheet, but there is no route to hang a stop on and no cart to assign. **`[Make a quantum stockpile]`** turns the stop into one in a single
click when exactly one stockpile touches it: it links that pile to the route
stop as its source, places a 1×1 catch-all pile on the tile the stop dumps into, and assigns an
empty cart. It refuses when the adjacency is ambiguous rather than guessing which pile you meant,
and it checks the dump tile can hold a stockpile *before* changing anything — the first stop tried
had a ramp top under its dump shift, which is walkable, looks clear, and cannot hold a pile.

**Removing the stop removes its route.** DF leaves the hauling route behind when a track stop is
deconstructed: a stop pointing at an empty tile, a cart still being sent to it, and a Hauling
screen filling with dead entries that look exactly like live ones. So a removal ordered on a stop
this tool can see is remembered, and when the building actually goes the stop goes with it — and
the whole route too, if that was its last stop. A route with **other** stops keeps them: a
two-stop route minus one stop still works, and deleting it would throw away work nobody asked to
lose.

It waits for the building rather than acting on the click, because clicking *Remove* only queues a
deconstruct job and a change of mind cancels it. The route stays until the stop really is gone,
and a cancelled removal drops the note with it. The note is kept with the site, since that walk
can outlast a save and reload.

Tearing a route down means freeing what it owns — the stop's departure conditions and stockpile
links, the stops, the route — and cutting its cart loose (`vehicle.route_id`), or DF keeps routing
a minecart to a route that is not there. DF's Hauling screen also caches **raw pointers** to
routes and stops in `view_routes` / `view_stops`, built when the screen draws and never
invalidated — this fort held ten of them against five live routes — so those are emptied first and
DF rebuilds them when the screen next opens.

### **`fort/improve-minecart-selector`**
*Choose a vehicle for Route 9* lists every minecart in the fort as `gabbro minecart`, over and
over, with nothing to tell them apart but a footnote about which route already has one. This
writes **what each cart is carrying** after its name — `+gabbro minecart+ (833 lava)`, in the
liquid's own colour — and **sorts the list** in the order that decides whether a cart is
any use to you: *None*, then unassigned carts (lava, water, empty), then carts already hitched
to another route (lava, water, empty), then the unreachable ones (same again). A cart you cannot
reach is no use whatever it holds; one already on a route costs that route its vehicle; and after
that, what is in it decides.

Reachability is DF's own walkability groups — the cart's tile and the route's first stop in the
same group is exactly "can a dwarf get from one to the other", answered from a field rather than
a path search; checked row for row against DF's own *Inaccessible from first stop* on a 26-cart
list. The sort reorders DF's display list itself, so clicking a row still picks the cart that row
shows.

### **`fort/interrogate-all`**
Three bulk actions on the justice screen's interrogation tab, lined up with DFHack's filter
panel and sitting above it — plain text, no border: **`[cancel interviews]`**,
**`[interrogate all]`** and **`[interrogate all visitors]`**. Cancel is the same walk with the
target inverted: Enter is pressed only on rows that are *on*, each verified off by identity, so
a row already off is never touched and nothing can be switched on by mistake. It reaches the
whole list whatever `Show` is set to — *cancel the interviews* means all of them, and a filter
that hid some would leave the captain of the guard still working through them.

**And it empties the committed queue, not just the ticks.** What the tab shows is a pending edit
(the list's `selected` set); DF commits it into each *crime's* own interrogation queue
(`crime.reports`, `interrogation_queue_ihf` in DF's terms) when you leave the tab, and that
per-crime queue — across every open and cold case — is what the captain actually works through.
One fort's queue stood at 164 with nothing ticked on screen. Cancel un-ticks the tab and then
drops every queued entry on every crime, clearing the screen's own *scheduled* marks to match; a
subject the captain is interviewing right now is left in place. The tab schedules one unit per click, and the question you
are actually asking ("has anything walked in here that shouldn't have?") is asked of everybody
at once.

**It presses the keys you would press.** The two pieces of state DF changes on a click — the
bit in `justice.crimeflag` and the entry in the list's `selected` set — are both unwritable
from Lua (the map is exposed as a sequence with no unit keys, the set refuses `insert`), and
DF's widget lists ignore synthetic mouse clicks. What works is DF's own keyboard path: put the
list cursor on a row and feed Enter. Three things had to be right for that: `cursor_idx` is a
**display** index (the order the rows are drawn in, *not* the order of `entry_list`, which
names a different unit at every position); the cursor has to be set from inside the frame; and
one key lands per frame on a row that is on screen. A row already scheduled is **never
pressed** — Enter is a toggle, so pressing one would switch it off — and each press is checked
back by identity, not by watching the selection count. A full pass is a frame per unit taken:
111 units scheduled out of 273 rows in 280 frames, with nothing switched off. A pass can only
be started from the tab itself, and **closing the tab abandons it** — it does not sit waiting and
carry on from the same row when the tab is next opened.

`[interrogate all]` means what **`F: Show`** means — set it to *Risky visitors* and the button
takes the risky visitors. DFHack's own filter function is called rather than reimplemented, so
the two cannot drift. With no filter set (*Show: All*) it still leaves out what you cannot
question: the deceased and missing, animals and wildlife, and megabeasts, semi-megabeasts,
titans, forgotten beasts and demons — tested per creature, because `Others` holds a human
axeman next to a forgotten beast. `[interrogate all visitors]` ignores the `Show` filter and
takes every visitor, under the same rules. Both respect **`Interviewed: Exclude`**, and both
line themselves up with DFHack's panel wherever it is dragged to.

### **`fort/clickable-job-worker`**
A building's Tasks list tells you somebody is on a job — the row carries the green check DF
draws for a claimed task — and then refuses to say who. Click the job's **name** or its **green check** and the
worker's sheet opens with the camera following them — those two spans and nothing else, since
DF's own row buttons sit between them and `fort/workshop-tools` puts its `+` near the panel's
right edge. Only
rows that actually have a worker are taken; a job nobody has picked up is left to DF entirely,
which is every row on a quiet workshop. Rows are identified by reading the line — `job.getName`
usually returns exactly the string DF drew — so a scrolled list still hands back the right dwarf, and
two rows with the same name are matched to those jobs in order.

Where the two disagree the row is matched by the longest run of **whole words** the line shares
with a job's name. A butcher's shop draws *"Slaughter Stray Yak Bull (Tame)"* for a job named
*"Slaughter animal"* — DF names the beast, the job name does not — and matching on the name
alone left every row on a butcher's shop unclickable. A short run is not agreement (*"Make"*
opens every other row on a craftsdwarf's shop), so it takes at least six characters, and ties
fall to the same in-order rule as rows that read identically.


**The "Add new task" menu is left alone.** It draws over the same rows with job *names*, so a
click on *"Make pair of silk gloves"* there looked exactly like a click on a queued job sharing
those words, and the worker's sheet opened instead of the task being added. While that menu is up
(`main_interface.building.button` is non-empty — DF empties it the instant the menu closes)
nothing here takes a click.


**The Trade Depot is left to `clickable-broker`.** A depot has jobs — *"Trade at depot"* held by
the broker, *"Bring item to depot"* by whoever is hauling — but no Tasks list: nobody queued them
and no worker check is drawn. What the depot sheet does draw is the broker's name with her current
job under it, and when that job is *"Trade at depot"* it reads exactly like a Tasks row whose
worker is the broker, so a click there — or on DF's own *Trade* button, which shares the word —
opened her sheet and closed the depot with the trade never started. `fort/clickable-job-worker
log` prints the last eight hits, for the next time something looks wrong.

### **`fort/clickable-broker`**
The Trade Depot's sheet names your broker, says what they are doing and whether they can even
reach the depot — and then does nothing with any of it. This makes that block live: click the
icon, the name, the job line or the access line and the broker's sheet opens with the camera
following them. The block is found by reading the screen for the broker's own name, so it does
not care where the merchant notice or the tab strip have pushed it, and DF's three
"requested at depot" buttons just above are named explicitly and never swallowed.


**It reads the sheet's panel only, never the whole row.** Reading a full screen row let a name
drawn on the left half — a notification line, an announcement — make that *row* look like the
broker's, and a click on whatever DF had drawn at the right end of the same row (the *Trade*
button, say) opened the broker's sheet instead. Every hit now records the geometry it was decided
on; `fort/clickable-broker log` prints the last eight, so a mis-click that happens once a week
can be explained after the fact.

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

**Giant cave spiders get a segment of their own**, first on the line and in their own colour,
and are counted whether or not they are agitated or classed as a danger. A GCS carries **none**
of the megabeast flags — to DF it is ordinary cave wildlife — so otherwise it is either pooled
into "N hostiles" and named only when it happens to be the most numerous kind there, or *not
counted at all*, because one that is neither agitated nor a "danger" matches no list this line
draws from. For the thing that webs a squad in place and kills it one at a time, "sometimes
mentioned" is not good enough. Caged, chained, tame and dead ones do not count, and a hidden one
is not announced — the stock lines do not reveal what you have not found either. Clicking the
segment cycle-zooms the spiders and shift-clicking sets selected squads on them, like every other
segment. Race indexes are per world, so the creature is looked up by its raw id and the cached
index is re-checked against that id before it is trusted.


**A creature you have titled is not counted.** A custom profession — *"the Skinless"*, *"the
Bronze Colossus"* — is the player's own label, never DF's, and it means that one is known and
dealt with: caged, tamed, walled off, or simply old news. The line reports what has turned up
that you have **not** handled, so titled creatures are left out of every segment. One fort's
*"3 megabeasts including a bronze colossus"* became *"1 forgotten beast"* — the only one still
wandering about untitled.

### **`fort/enemies-inside-notification`**
Warns of enemies inside the alert burrow; shift-click sends selected squads to attack.


**Wildlife counts as an intruder.** A crundle that wanders into the safe burrow is neither
`isDanger` nor agitated — to DF it is ordinary cave wildlife — but it is loose in the room the
civilians were told to shelter in, which is the whole thing this line watches; seventeen of them
were wandering one fort while this reported the burrow clear. Anything the fort owns is already
excluded, and tame animals and pets are not wildlife, so nothing of yours trips it.

### **`fort/trade-again`**
DFHack's "Move goods to/from depot" screen opens with nothing selected, so every caravan starts with the
same hunt through thousands of rows. This pre-selects the obvious ones as the screen opens: everything
**your own fort made** (not `foreign` — selling last year's purchases back is rarely the intent), plus
**loot**: foreign gear whose maker's race you are presently at war with and which has not traded here in ten
years is siege plunder, not a purchase (`trade-again loot off` to stop that; DF records no "I looted this"
bit, so this matches on `maker_race` against your civ's live war list, and your own civ's race never counts).
Selected items must be sitting at
**distance 0** from the depot, measured exactly the way the screen's own `dist` column measures it. Forbidden
items, artifacts and ethically banned goods are left alone, and items already *in* the depot need no help
since DFHack counts those as selected already. Selection goes through `dfhack.items.markForTrade`, so rows
come up ticked exactly as if you had clicked them and deselecting one removes the job normally.
`trade-again radius N` widens the catchment (persists with the fort); `trade-again` selects them now
without opening the screen; `trade-again status` says what would be picked. Hooks
`MoveGoodsModal:init` so the selection is made just before the screen reads its pending set.

It also **opens the window at the full height of the interface** instead of DFHack's fixed 46 rows — on a
tall screen that is a lot of list you were paging through for nothing — and at **whatever width you last
resized it to**, which the window records for itself. Both are class hooks, so a window already open picks
them up on its next render.

### **`fort/trader-notification`**
Counts down how many days the trader is ready. It also speaks up *before* they get there —
*"Merchants are coming to the depot"* — which is the window in which a caravan quietly fails to
arrive. With one caravan trading and another still walking in, the countdown reads *"…for 9 days
(more coming)"*.

Clicking takes the **next step of the trade**, whatever that is. While merchants are still on
their way it zooms to one who has not arrived, one per click, so you can walk the stragglers.
Once somebody is at the depot it opens the screen you would go to next: the depot's own panel —
the one clicking the depot opens — or, if you have nothing down there to sell, DFHack's *move
trade goods* window. Either way it asks for the **broker**, unless he is already standing on the
depot: sending him is what makes the panel worth opening, and it is the step that gets
forgotten.

The same line also sits on the **depot's own panel**, under the *Trade Depot* title: the screen
you are on while deciding what to send down there is the one that should be telling you how long
you have. It is the notification's own text, so the two can never disagree.

### **`fort/better-dfhack-trade`**
DFHack's trade UI is one small window with a tab bar — *Caravan goods* on one tab, *Fort goods*
on the other — and a trade is a comparison, which a tab switch is not. This opens it as **two
windows side by side**: what they are selling on the left, what you are offering on the right,
each a whole DFHack trade window with its own search, sort, filters and selections.

They open against the edges of the screen — four rows of margin at the top, three columns at the
left, three rows at the bottom — and stop short of the **minimap**, so the thing that tells you
where your depot is stays visible while you trade. The minimap's width is measured rather than
assumed (DF draws it itself, so those cells come back empty from the tile grid), and a fort with
the minimap turned off gets the full width. After that they are ordinary DFHack windows: drag
and resize them as you like.

It works by swapping the class DFHack's own *DFHack trade UI* button builds, so every way in —
the banner button, the keybinding — opens this instead, and turning it off in `magnus-scripts`
puts DFHack's own window straight back.


**Each window's title carries its side's marked total** — *"Fort goods — 1,240 marked"* against
*"Caravan goods — 980 marked"*. DFHack prices every row and never sums them, so the one number a
trade turns on was yours to add up by eye across two lists. The sum is of what DF has marked,
priced the way the rows are (the caravan's view, container plus contents, counted once per
marked bin) and shown through the same broker-skill obfuscation, so the total is exactly as sure
as the numbers beside it. It follows each click.

### **`fort/help-mood` notices**
Replaces DFHack's *"moody dwarf is claiming a workshop / can't find needed item"* with the
game's own words: **"Thåkut withdraws from society..."**, *"...works furiously!"*,
*"...keeps muttering..."* — the right line for the mood type, and the dwarf's first name
rather than "moody dwarf". **If the fort has no workshop of their craft it says so** — *"Dunstan,
Bowyer, has been possessed! They need a Bowyer's Workshop!"*, in red — because a moody dwarf who
cannot find their workshop wanders until the mood runs out and then goes insane, and DF never
mentions it: its announcement names the mood and stops. Magma forges and magma glass furnaces
count, and a craft with no rule for it says nothing rather than guessing. While they are fetching it keeps the mood's own line and counts what has arrived —
*"Thåkut withdraws from society... Claimed 3 items."* When they are stuck it names what they
are short of the way DF would, and a secretive dwarf *sketches* it rather than demanding it; past a week it counts the
days: *"Thåkut has sketched rock blocks for 7 days"*. A possessed dwarf's line is DF's own,
whole — the artifact names itself, in dwarven: *"Libadlitast Mostod Akam needs bones... yes..."*.

**The requirement it names is the one nothing can fill**, not the first one still open. DF does
not work through its own list in order — it takes whatever it finds that fits an open slot — so
naming the first unfilled requirement sends you to a stockpile that is not the problem. One fort's
possessed weaponsmith, one of his two bars in and no bone in reach, was reported as wanting metal
bars with fifty-five of them in the stockpile while DF's own line said bones. Unreachable stock does
not count as stock: a bone at the bottom of a cavern stalls a mood exactly as an absent one does. Clicking follows them with the camera,
clicking again opens the planner. Turning it off in `magnus-scripts`
puts DFHack's own line back rather than leaving a gap.

### **`fort/mood-watch`**
The mood you have *not* had yet. *"A strange mood could strike"* — from DF's own
`mood_cooldown`, population and excavated-tile counters rather than a guess about three
months. Clicking opens a dialog in the fort's own voice — *"Our fortress has grown to attract the
attention of the gods..."* — with three answers: **Reserve a metal**, **Not this time** (back
for the next mood) and **Don't ever show this again**. Reserving one metal means — forbidding every other metal
bar in the fort, and *continuing* to forbid them, so bars smelted or traded for afterwards are
caught too (*"Ensuring slade is used for next mood"*). Only the bars it forbade are ever
released again, so your own forbids are safe. `magnus-scripts` turns the notice back on, and `fort/mood-watch gui` reopens the dialog once the
notice has been clicked away.

A reserve is **spent by the first mood**, whatever that mood turns out to want: once one begins its
materials are already rolled, so the reserve lifts itself and every bar it forbade is put back — leaving
it up would mean the *next* mood finds only that one metal legal. It also lifts for a mood that came and
went unwatched, spotted by `mood_cooldown` having risen since the reserve was made, and the check runs
from the notification itself rather than the sweep heartbeat, which a script reload or save/load can
leave stopped.

The sweep that keeps other metals forbidden runs from the notification as well as its heartbeat — a
reserve only steers anything while every rival bar stays forbidden, and bars keep arriving; with the
heartbeat stopped, 24 of one fort's 45 iron bars sat free under a slade reserve and the next mood duly
asked for iron.

### **`fort/moody-items-warning`**
Warns when the fort has none of a material a strange mood might demand — stone, logs, leather,
plant/silk/yarn cloth, metal bars, rough or cut gems, blocks, bones, shells, and raw glass in
any type you have produced. A mood asks the moment it starts, so a gap found afterwards is a
berserk dwarf. With stressed dwarves in the fort it also checks remains and bones, which a
macabre mood wants. The list is taken from DFHack's `strangemood` plugin and cross-checked
against the wiki, not from memory. Forbidden stock counts — a forbidden shell is one you have — but **unbutchered pieces and
unreachable stock do not**. A corpse nobody has butchered is a pile of body parts, every one of
them carrying the `bone` bit because there is bone inside it, and what a mood wants is butchery
output; a bone at the bottom of a cavern or sealed in a tomb is not stock either. One fort read as
having bones on the strength of 66 unbutchered pieces and five bones it could not reach, and said
nothing while a possessed weaponsmith waited thirty days for one. It
warns at **fewer than three** rather than at none, since three is the most of one thing a mood
asks for and one bar of the metal it settles on is the same dead end as none, found a day
later: *"No shells; 2 leather"*.

The shells line only appears when somebody in the fort actually prefers a shell material: shells are
the one mood material chosen by preference rather than stock (a bone carver demands shells only if they
like a type of shell, bones otherwise), so a fort with no shell-lover can never be asked for one.

### **`fort/empty-labor-notification`**
Warns when a restricted work detail has nobody who can actually do it, and says which problem it
is — *"No workers for Masonry"* (nobody selected) or *"Workers for Masonry are in a squad
training"* (selected, but all soldiers their schedule keeps on duty) — since one wants a dwarf
assigned and the other a schedule looked at. Stays quiet while `autolabor` or `labormanager` is
enabled, since those assign labors themselves.

### **`fort/needs-tomb-notification`**
Alerts when a dwarf dies with no tomb, or when anything is haunting the fort — a ghost counts
whether or not it was ever a citizen. Click for a death browser with cause, kills and a
clickable family tree, and queue memorial slabs in bulk.

### **`fort/no-sparring-spam`**
Removes the sparring alert from the notification strip. Squads drilling refill that button
constantly, so it sits there permanently and pushes the alerts you want to read — a failed
job, a guest, a real fight — out of the way. It waits for the bout to end first: the button
goes only after three seconds with no new sparring report, so a squad still trading blows is
never interrupted and DF is not left rebuilding a button that keeps vanishing. Only the button
goes: every sparring blow is still filed in the units' combat logs and reads back in full.

### **`fort/guild-agreement-dates`**
Puts the deadline on the map view's agreement notice. DF shows the job, the petitioner and a
date, but that date is when the agreement was **made**, and the year you have to build the
temple or guildhall is never spelled out. This rewrites DF's own first line to carry the count —
*"Temple Complex, 321 days"* — in the pen read off that line, so it reads as part of the notice.
The word *Build* goes with it: it is the same on every notice, and the band is only 26 columns
wide, so *"Build temple complex, 321 days"* ran off the end and took the count with it. Past the
deadline the line reads *"Temple Complex, 12 over"*, which is what fits.
It goes there rather than on a line of its own because DF **stacks** the notices when more than
one agreement is outstanding, three rows each, and a number on its own line lands in the gap
between two notices and belongs visibly to neither; on the job line it can only be the deadline
for the thing named beside it. Every notice on screen gets its own count. The notices are found
by reading the screen, so the counts follow them wherever DF puts them, and there is nothing to
draw while the squads panel is up, since DF hides the notice there. The search is confined to the
right-edge band DF hangs the notice off, and only to lines that read as *"Build …"*, so a window
that happens to show a date elsewhere on screen can never be mistaken for the notice.
Turning this on in `magnus-scripts` turns DFHack's own
*"N petitions outstanding"* line off, since this says the same thing and more;
turning it off puts that line back.

### **`fort/missing-noble-warning`**
Warns when nobody holds a post the fort actually suffers without: *"Assign a manager, broker,
bookkeeper."* One or two are named, three are listed, and past that it gives the count instead,
*"Assign 4 noble positions."* Clicking opens Nobles and administrators, where you assign them. It
looks for the **job, not the title** — each post is found by the responsibility the entity raws
give it, so a modded civilisation run by a quartermaster and a war-leader is covered exactly as
well as a dwarven one, and the warning uses whatever that civilisation calls the post. A role
counts as covered when any position carrying its responsibility is held, which is what stops a
fort with a mayor being nagged about its expedition leader. Posts nothing depends on — hammerer,
dungeon master, champion — are never mentioned.

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
`NO ADAMANTIUM` when there is none), salt or fresh water, **magma and how far up it comes**
(`volcano`, `magma in first cavern` … `third`, or `no magma` — the first cavern is the one you
can reach without digging to the bottom of the world), read per embark tile rather than off the
world tile's candidate list, which claims magma nearly everywhere, the **four commonest stones** — the
thickest layers first, which is what the fort gets cut out of — plus a count of the rest, and the
flux, coal and plaster stones, tagged in place when they are already among the four and named
after them when they are not. Then commonest wood, the wildlife, and **every** civ that can reach
you — not vanilla's four. Naming only the single commonest stone said almost nothing: it is
gabbro over and over.

### **`embark/assistant`**
Site finder, replacing the retired `embark-assistant` plugin. Bare `embark/assistant` opens a
window: type filters, press Enter, then press Enter on a result to **place the embark rectangle
on that exact world tile** — the local embark screen opens with the rectangle on the tile that
matched and the site chosen, and *nothing confirmed*: whether you actually embark there stays
your call, and DF's own Confirm button is how you make it. Getting it to stay there is the
awkward part and is why this is more than one write: in placement mode DF re-derives the
rectangle from wherever your pointer is, every frame, so the tool moves the **camera** by the
error it measures — a nudge per frame, since the hover it measures only updates once a frame —
until the tile under your pointer is the one you asked for, then commits with the click you
would have made. Filters cover
flux, coal, plaster, named metals and minerals, sand, clay, soil, rivers, aquifers, volcanoes,
biome, tree density, freezing, evil weather, savagery, evil, and neighbouring civs and towers by
name or count. `s` runs a survey that adds **magma pools by cavern level**, which is not world-wide data and
cannot be faked: a world tile's feature list carries *candidate* pools that are not placed
anywhere (242 of 256 tiles in one world), so magma is resolved per embark tile through
`region_details` — the survey walks the camera to make those resident. It also records *which*
of the tile's 256 embark tiles the magma is under, and `goto` puts the rectangle over that
spot, which is the difference between "this world tile has magma" and "your fort has magma". Also works from the console — `embark/assistant help`.

## One-time-commands

### **`fort/civilian-militia`**
Packs office-holder civilian squads into ready and reserve squads on command.

### **`fort/no-monster-slayers`**
Two buttons under the work-detail list, touching at their brackets: **[Auto][Remove Monster
Slayers]**, with Auto on the left and green while it is on. A monster slayer turns up because
you have a tavern, takes a slayer's post at one of your locations and settles in; the button
takes that post away, deleting the location from it and then removing the post from the unit and
from the world. Clearing the location alone is not enough, since the post is listed on the unit
as well, and a slayer keeps it until both let go. With **[Auto]** off the button asks first: a window
lists every monster slayer with their two best fighting skills, and clicking a name takes that
one post and leaves the rest. With it on the button takes them all, since you have already said
so. **[Auto]** is on by default, because a slayer can simply be offered another post. The pair sits at the foot of the work-detail panel, its
right-hand bracket in the same column as "Add new work detail", so it follows the panel wherever
the interface puts it.

### **`fort/inviolable-masterworks`**
Turns the masterwork adamantine doors, hatch covers and floodgates you have already built into
real artifacts, which no building destroyer can break. A troll walks through an adamantine door
exactly as it walks through a wooden one, since material never enters into it, but artifact
furniture can never be damaged or destroyed. A sweep runs once a season, on by default. It never
changes what anything is made of and never touches ordinary work: a granite door stays granite,
an adamantine door of merely good quality stays a door, and a masterwork lying in a stockpile is
left for you to place. Each promotion mints a real artifact record with a name from DF's own
generator, and `undo` takes every one of them back.

### **`fort/force-more`**
Forces attack events the stock `force` can't, like real forgotten-beast cavern attacks.

### **`fort/destroy-forbidden`**
Destroys loose forbidden items lying on the ground.

`onscreen` narrows it to the map viewport exactly as rendered — one z-level, the one you are looking
at, between its corners — which makes it a pointing device: forbid what you want gone, look at it, run it.
`artifacts` includes artifacts, which are excluded by default because they are unrecoverable and usually
forbidden precisely to keep them safe.

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
  creatures and the player in adventure mode. This is notliad's plugin, tracked at upstream v0.5,
  with every flag on: creatures and vehicles glide between tiles, sprites face the way they walk,
  hauled boulders, bars and wood show an icon while they are carried, movement uses the linear
  tween, and the work-in-progress free camera is opted in. (A C++ plugin rather than a script —
  install it with `make install`.)

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

