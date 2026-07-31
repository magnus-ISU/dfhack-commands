# Dwarf Fortress: High Adventure

A family of new-content mods adding several playable civilizations, designed to work
**together or individually**. Source lives in
[`content-mods/high-adventure/`](content-mods/high-adventure/) — one folder per mod, each with
its own `CHANGES.md`. Design rules and fork provenance are in
[`content-mods/README.md`](content-mods/README.md).

> **Raw changes (`objects/`) only take effect in a newly generated world.** A mod's
> `scripts_modactive/` scripts reload for an existing save, and graphics come from that world's
> baked snapshot. See [`instructions.md`](instructions.md) for deploy steps.

## Playable Civs

The four vanilla civilizations — dwarves, humans, elves and goblins — made playable in fortress
mode. A fork of *All Races Playable Redo*.

### Fortress mode
Dwarves are untouched; they already play the way the game intends. Humans and elves become
playable by gaining the full slate of fort noble positions they were missing, so a human or elf
fort can appoint a mayor, manager, bookkeeper and the rest exactly as a dwarven one does.
Elves get the Shaping Tree as well, since a civilization that refuses to fell a tree still
needs wood: they grow it from seeds rather than cutting it. Goblins are rebuilt more heavily —
they learn bronze-working, so a goblin fort can arm itself, and they receive a single caravan
each autumn instead of going entirely unsupplied.

### Adventure mode
Nothing here changes how these civilizations generate; they are the vanilla four, placed by the
vanilla rules. Vanilla kobolds are deliberately left out, because they embark broken — the
`ha-kobolds` mod supplies a playable kobold civilization instead.

### Scripts
The script paces the elven Shaping Tree: growing wood takes one month per tree, a freshly built
tree starts on a full month's cooldown, and a job finished too early withers with an
announcement. A skilled strand extractor grows more from the same tree — one bonus log per
skill level on top of the native log, up to twenty-one in total. It also enforces that a
Shaping Tree is built under open sky and wrapped around a living tree trunk.

Two smaller fixes cover engine gaps that make the new civilizations unplayable otherwise.
Elves have no picks, so Remove-Construction orders can never complete in an elf fort; the
script finishes them itself, reverting each designated tile so walls and floors can actually be
torn down. Goblins do not memorialize their dead, so their ghosts would accumulate forever;
goblin ghosts are dispelled automatically.

## High Elves

A good race composed of tall, reclusive elves who cares little for mortals and asks questions of the stars.

### Fortress mode
High elves play like dwarves, but they cannot chop trees. Instead, they can turn trees into Shaping Trees with a seed, growing wood at them. Skilled shapers can extract strands of twinkling starlight to create divine metals stronger than steel.

### Adventure mode
High elves live in forests in cities, but each civilization is reclusive and never expands. They are hostile to any evil adventurers, and provide an end-game challenge for them using divine weapons, clothing, and armor.

### Scripts
The high elf script enforces that the shaping tree workshop is built under open sky directly below a real tree. It also enforces that shaping trees can only be used once per month. It handles producing varying amounts of wood from the shaping tree based on the worker's skill at strand extraction, and offers a 5% chance to create twinkling strands per level of the worker.

With Adventure Hostility, high elves found in adventure mode automatically have all clothing, armor, and weapons changed to twinkling metal or fabric, and are hostile to evil adventurers who don't have a Pacifier skill of 6 or lower.

## Drow

A slender and beautiful humanoid, dark of skin and heart.

### Fortress mode
Drow are evil matriarchal elves who forge freely — any metal, up to and including steel — but
never carry a shield. They fight with scimitars and bows, and keep tame giant cave spiders as
escorts. Goblin slaves are kept as war-fodder rather than citizens.

### Adventure mode
Drow settle mountains and forests only, in insular fortresses that almost nothing ever reaches.
One in twenty-five drow is born a drider — a drow torso on a giant-spider body, armed with
paralytic venom and webs.

### Scripts
The drow script issues the war kit to goblin slaves who have been trained for war: an obsidian
short sword, and wooden breastplate and helm. The drow's own war gear used to live here and is
now handled by the shared war-gear engine described under Adventure Hostility.

## Illithids

A dread psionic with four tentacles, it hungers for mind and memory.

### Fortress mode
Illithids are ageless brain-eaters who play as a colony rather than a fortress. They come in
four castes — illithid, ulitharid, elder brain and thrall — and are robed but never armoured.
Everything revolves around the Neural Bath, where they devour brains, reclaim the memories of
their dead, extract ulitharid brains, implant tadpoles into prisoners, and finally coalesce an
elder brain.

### Adventure mode
They build isolated mountain dark fortresses and trade with nobody. Their ten psionic
interactions scale with scholarship, so an illithid adventurer grows in power by studying.

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
Orcs are warlike and work pure metals only — no alloys, no steel, and iron above all. They are
ruled by a warband hierarchy and breed their own numbers at the Breeding Pit rather than
waiting on migrants.

### Adventure mode
Orcs settle savanna and scrubland hamlets and are hostile to everyone, the evil bloc included.
One in five is a skull-cruncher champion: pain-immune and frequently raging.

### Scripts
The orc script runs the Breeding Pit. Each "breed orcs from meat" job tries to birth an orcling
on the spot, failing 75% of the time at first and falling linearly to never failing for a
legendary strand extractor; the worker earns 70 strand-extraction experience per attempt.
Orclings arrive as full citizens, are always common orcs rather than champions, and are named
Peon with an orcish surname. Orcs also send out fodder and do not memorialize their dead, so
orc ghosts are dispelled automatically.

## Dark Dwarves

A short, sturdy creature fond of drink and villainy.

### Fortress mode
Dark dwarves are carnivorous cannibals with ironclad in-group loyalty — they never tantrum, no
matter what happens to the fort. They trade with the evil bloc in winter.

### Adventure mode
They live in deep mountain halls and never hillocks. They are child-snatchers, and they sap
fortress walls with great picks rather than going around them.

### Scripts
No script of its own. Their war gear is handled by the shared war-gear engine described under
Adventure Hostility.

## Succubi

Demonic realm-builders who keep the full demonic wardrobe but fight with vanilla arms. A fork
of *Succubus Dungeon*.

### Fortress mode
Succubi build around corruption, summoning, bone-working and magma-well workshops.

### Adventure mode
They are desert city-builders with land-holding Demon princes and outdoor fortifications, and
send caravans to the evil bloc in summer only.

### Scripts
The succubus script enables the three submodules the workshops depend on — the magma well,
powers, and corruption — so those reactions actually function.

## Kobolds

The playable kobold civilization: a fork of *Cute Kobold Caverns* with *Skulking Filth*'s
item-thief hard mode.

### Fortress mode
Kobolds play as thieves. A kobold civilization is sometimes ruled by an Ancient Dragon, and
when it is, the eldest becomes the Dread Wyrm king.

### Adventure mode
Ancient Dragons also lair the world as megabeasts in their own right — a huge winged creature
full of dread majesty, soaring on iron-hard scales immune to any fire. They come in one-, two-
and three-headed castes, with spiked or clubbed tails.

### Scripts
No script of its own. Kobold and dragon hostility is handled by Adventure Hostility, which
treats a kobold civ and its dragon overlords as one faction.

## Second Humans

A second, independent human civilization identical to the vanilla one.

### Fortress mode
No change — they play exactly as vanilla humans do.

### Adventure mode
The point of the mod is worldgen placement: two human civilizations mean humans get two
placement draws against an orc civilization's one, and the two human realms can war each other.
It adds no creature and touches no vanilla raws, and is regenerated from vanilla by
`sync_from_vanilla.py`.

### Scripts
None.

## Beasts

Wild monsters to make evil regions genuinely dangerous. Standalone — it adds no civilization.

### Fortress mode
No change beyond what wanders in.

### Adventure mode
The first entry is the Gibberling: a small, gibbering predator plated in blue chitin, which
swarms the living and devours the dead.

### Scripts
None.

## Adventure Hostility

Makes the suite's civilizations behave like enemies in adventure mode, and upgrades the gear
everyone in the world is carrying.

### Fortress mode
The war-gear half runs in fortress mode too, so invaders and visitors arrive in the metal their
civilization is supposed to wear.

### Adventure mode
Each turn, nearby members of a hostile faction are put into a conflict with the adventurer
specifically — never with their own people — by placing them in the same Conflict activity the
game builds when you attack someone. Hostility is site-scoped: inside a settlement only that
settlement's own people turn on you, so a drow merchant visiting a high elf town stays a guest.
Units of the adventurer's own civilization are always left alone whatever their race.

The factions are: orcs and illithids, each hostile to everyone but their own kind; the evil
bloc (drow, dark dwarves, succubi, goblins), hostile to any adventurer outside it; the good
civilizations (humans, vanilla elves), hostile only to evil adventurers and able to surrender or
flee; the militant good (high elves, dwarves), hostile to the same evil adventurers but never
breaking and never yielding; and kobolds, hostile to any non-kobold. Two ancient dragons
meeting is read as a challenge, so every other ancient dragon turns on a dragon adventurer.

Surrender is respected only if the adventurer's Pacify skill meets that race's threshold —
goblin 1, orc 3, drow, succubus and dark dwarf 6, illithid 12, while high elves and dwarves
never yield at all.

### Scripts
Two scripts ship here. `adventure-hostility.lua` is the adventure-mode overlay described above;
it also clears the yield flag each turn unless the Pacify threshold is met, and can set NOFEAR
on a faction so it never breaks.

`war-gear.lua` is a separate script because it has to run in fortress mode as well. Worldgen
spreads a civilization's equipment across every metal it knows, so most members of any civ spawn
in copper, silver or tin however martial they are meant to be. This re-gears them from a
weighted outfit roll made once per unit and remembered — high elves get twinkling metal armour
with their clothing rewoven in twinkling fabric, drow males roll 80% iron and 20% steel while
driders are always steel and females wear giant cave spider silk, and dwarves, dark dwarves,
orcs, goblins and humans each get their own mix. It only ever **upgrades**: a piece is replaced
only if its material ranks below the metal rolled, ranked by the material's shear yield read
from the raws, so steel is never downgraded and twinkling gear is left alone. Masterworks and
artifacts are never touched, children are never armed or armoured though their clothing is
still rewoven, and it never edits an item's material in place — it mints a fresh item of the
same type and subtype, copies the quality across and swaps it in.

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
