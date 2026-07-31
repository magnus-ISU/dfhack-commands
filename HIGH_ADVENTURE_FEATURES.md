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
