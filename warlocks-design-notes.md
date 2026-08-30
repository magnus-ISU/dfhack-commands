# ha-warlocks — research notes

Findings from studying Meph's ☼Warlocks☼ (bay12 thread 175304) against what High Adventure
already ships. The reference material lives in `content-mods/warlocks/` (gitignored; see its
`README.md` for provenance — **the 1.0 release itself is gone from the internet**, we have the
Masterwork-era ancestor raws, the manual pages, and the thread's full art set including the
1920×1080 cheat sheet).

Nothing here is built yet. This is the answer sheet for the questions raised while scoping it.

## Creatures we do and don't need to add

| Wanted | Vanilla already has | Verdict |
|---|---|---|
| Giant scorpions | `BARK_SCORPION`, `GIANT_BARK_SCORPION` (+ `BARK_SCORPION_MAN`) — that is the *only* scorpion line in v50 | Reuse the giant bark scorpion, or add one desert/cave giant scorpion if one species feels thin |
| Snakes for warlocks | `KINGSNAKE`, `COPPERHEAD_SNAKE`, `RATTLESNAKE`, `HELMET_SNAKE`, `SNAKE_FIRE` + giant versions | **Add nothing.** HA already tames one (`HA_HELMET_SNAKE_TAME`); same pattern for the rest |
| Ravens / crows | `BIRD_RAVEN`, `BIRD_CROW`, `GIANT_RAVEN`, `GIANT_CROW` (+ `RAVEN_MAN`, `CROW_MAN`) | **Add nothing** — exactly the "eyes in the sky" the mod wanted |
| Prisoners | nothing | Add. Precedent in-repo: `HA_GOBLIN_SLAVE` (ha-drow, an `ANIMAL_TOKEN` embark pet) |
| Mephits | nothing | Add. Meph's is one creature, four castes (Acid / Air / Ice / Fire), dog-sized, `PET_EXOTIC`, flying |
| Gargoyles | **nothing in vanilla, nothing in any HA mod** | Add 1–2. The mod shipped ~9 (earth, poison, web, ice, fire, light, necromantic, armed, golem) — the cheat sheet crop is `content-mods/warlocks/art/crop_gargoyle.png` |
| Elemental men | nothing usable | Needed for the altars; Meph's were a full cavern civ, we only need a pet creature |

Souls are not a creature problem but worth recording: Meph implements a soul as a **plant
material** (`PLANT_MAT:SOUL`) with `[REACTION_CLASS:SOUL]`, dropped by butchery through an extra
butcher object on the brain — `[EXTRA_BUTCHER_OBJECT:BY_TYPE:THOUGHT][EBO_ITEM:PLANT:NONE:PLANT_MAT:SOUL:STRUCTURAL]`.
In v50 that can be applied to existing creatures with `[SELECT_CREATURE:X]`, the same mechanism
`ha-succubi/objects/creature_edits.txt` already uses.

## Gargoyles — scope locked

Three only: **ice**, **fire**, **melee**.

- **Melee** — the bulky red-eyed stone golem. Costs **15 boulders, any stone, nothing else.**
- **Ice** — the teal-crystal one.
- **Fire** — the flame one.
- Ice and fire each cost **15 boulders + one extra reagent** (see below).

One thing to confirm when we cut the art: by my reading of the cheat-sheet row (left group of
six read in rows, then the middle pair, then the armed pair, then the golem) the golem is 10th,
but ice lands at 4 and fire at 6/8 rather than 3 and 8. The sprites themselves aren't ambiguous
— teal crystal, flame, golem — so this only matters when someone is counting tiles in
`content-mods/warlocks/art/crop_garg3.png`.

All three are `[IMMOBILE]` pasturable pets; ice and fire get their breath weapon from a
`[CAN_DO_INTERACTION]` + `CDI` block, the golem just gets natural attacks.

## Magic reagents

**In the standalone (1.0), we don't know the gargoyle recipe** — no raws survive. What the
cheat sheet does state is the general currency: *"Most [workshops] requires totems, slabs and
souls to be build."* Plus the Gargoyle Mason's own line, "great to dump excess boulders", and
the player report of ~15 boulders per gargoyle. So the standalone's vocabulary of magic
ingredients is **souls, totems, slabs, bones, ash and blood** — all obtainable from corpses and
a craftsdwarf's workshop, with no separate reagent industry.

**In the MDF ancestor it was a full production chain**, and the raws for it survive
(`content-mods/warlocks/mdf-raws/reaction_warlock.txt`):

1. **Souls** — butcher anything. Stored by the Soul Syphon as a **phylactery** (soul + hourglass).
2. **Dusts** — the four *Shredders* (Wood / Ore / Plant / Gem) grind raw material into
   `POWDER_<x>` tagged with a reaction class: `TREE_DUST`, `METAL_DUST` / `METAL_DUST_GREATER`,
   `PLANT_DUST` / `PLANT_DUST_FOUL`, `GEM_DUST`. This is the "strip-mine the whole map" tier —
   every gem, ore, log and weed goes in.
3. **Ritual reagents** — the *Alchemist* mixes three bags of 150 dust into a tool item:
   bag of herbs, bag of foul herbs, incense, circle of protection, greater circle of protection,
   gem sigil, eerie flame, scrying mirror, philosopher's stone, eternal rose.
4. **Organics** — the *Herbalist* makes totems (from skull fronds), bonemeal, glue, netherleather,
   papyrus and three acids; the *Chemist* makes pearlash, brimstone, saltpeter, oils and acids.

Nothing in that chain is bought — it is all butchery plus grinding. For our version, which drops
plants, potions and the whole alchemy tier, the standalone's own shorter list is the right one:
**a soul** as the universal magic cost, plus **a totem** (a skull at the craftsdwarf's) or a
**slab** where a second ingredient makes the recipe read better. That keeps ice/fire gargoyles
gated behind killing something without introducing a reagent industry.

## Squad size

**Yes, it is moddable — it's a raw token, not an engine constant.** Squad size is the first
argument of the entity position token:

```
[POSITION:MILITIA_COMMANDER][SQUAD:100:minion:minions]      Meph's Overlord
[POSITION:MILITIA_CAPTAIN1] [SQUAD:1:death:deaths]          the four Horsemen
[POSITION:GHOUL_COMMANDER]  [SQUAD:25:ghoul:ghouls]
```

Caveat, stated plainly: vanilla v50 uses `[SQUAD:10:...]` *everywhere* — every entity file in
`data/vanilla`, and every HA entity we ship. Values other than 10 are proven for 0.44 (Meph
shipped 100 and 25) but **not verified on the Steam build**, and the military UI is the thing
that would break. Cheap test before designing around it: bump one HA entity to `[SQUAD:20:...]`,
gen a pocket world, and see whether the squad screen accepts an 11th member.

The 1-man squad trick (`[SQUAD:1:death:deaths]`) is the interesting half anyway, and that
direction is safe — it's how Death/Hunger/Pestilence/War each get their own stationable slot
without a UI that has to hold more than 10.

Proposed noble slate matches the mod's own shape closely enough to inherit its ergonomics:
Death / Hunger / Pestilence / War as four `MILITIA_CAPTAIN`s with `[SQUAD:1]`, Crypt Lords as
the `AS_NEEDED` warlock-only sergeants, and a Death Knight `MILITIA_COMMANDER` restricted with
`[ALLOWED_CLASS:...]` to the non-warlock castes.

## Workshop scope vs. what HA already ships

Keeping the planned set (Obsidian Factory, Liaison's Office, Gargoyle Mason, Magic Altars,
Necromantic Shrine) against the existing mods:

| Planned warlock shop | Collides with | Notes |
|---|---|---|
| Magic Altar → summon elemental men | `ha-succubi` **Summoning Circle** (15 summon reactions) | Same mechanic, different creatures. Reuse the succubi spawn plumbing rather than writing a second one |
| Magic Altar → start a strange mood | nothing | New; no precedent in repo |
| Necromantic Shrine → **summon imps** | `ha-succubi` `HA_SUCCUBUS_SUMMONING_IMP_FIRE` (summons vanilla `IMP_FIRE`) | Direct overlap. Either give warlocks a different minion or a distinct imp creature |
| Necromantic Shrine → power up a warlock | `ha-succubi` **Altar of Power** (citizen upgrade, `powers.lua`) | Same mechanic. Worth sharing the caste-set / syndrome helpers, not duplicating them |
| Necromantic Shrine → resurrect a dead starting warlock | nothing | New |
| Gargoyle Mason | nothing | New |
| Obsidian Factory (boulders only) | `ha-succubi` **Underworld drill** (slade) / **Magma Well** | Adjacent but distinct — and slade is explicitly out of scope for warlocks, so no clash |
| Liaison's Office | nothing | See below |

The bigger collision is **prisoners**. `ha-illithids` already builds its whole loop on caged
prisoners (`HA_IMPLANT_TADPOLE`, `HA_DEVOUR_PRISONER`) and that path has a known crash:
synthetic caged goblins segfault the UI render — the illithid mod had to use real siege
captives. Warlock prisoners-as-livestock is the *same* mechanic and will hit the same wall if
they're spawned rather than captured. The safe shape is what ha-drow already does with
`HA_GOBLIN_SLAVE`: a real, tame, butcherable `ANIMAL_TOKEN` creature bought at embark — not a
caged sentient.

Deliberate omissions (ethereal furniture, bonemold/bloodsteel/soulforged, bone/obsidian/slade
furniture, new plants, potions) also remove every material-side collision with ha-succubi's
bone and slade work. Nothing left to deconflict there.

## Summoning caravans — yes, and it generalises

This is the one trick worth stealing wholesale, and it's *easier* now than when Meph did it.

Meph's version was indirect: the reaction produced a boulder of a magic inorganic
(`FORCE_SIEGE_ORC`, `FORCE_MIGRANTS_W`, …) that an MDF DFHack item-trigger script watched for.
On this build the engine event is directly writable — that's all stock `force` does:

```lua
df.global.timed_events:insert('#', {
    new = true,
    type = df.timed_event_type.Caravan,      -- or Diplomat / Migrants / Megabeast
    season = df.global.cur_season,
    season_ticks = df.global.cur_season_tick,
    entity = <the historical_entity to summon>,
    feature_ind = -1,
})
```

(`$DFH/hack/scripts/force.lua`; `dfhack/fort/force-more.lua` in this repo already does the
Megabeast variant.)

So **yes** — high elves, orcs, kobolds and illithids can each get a workshop reaction that buys
a caravan from *their own* civilization only. Wire it as a `JOB_COMPLETED` hook per
`ha-reaction-scripting`, resolve the entity, insert the event. Caveats that matter:

- **One outstanding caravan per civ.** While a civ has a live caravan entry DF schedules no new
  Caravan event for it — the failure mode documented at length in
  `dfhack/fort/caravan-unstick.lua`. A summon reaction must no-op (and say so) when that civ
  already has one in flight, or players will quietly break their own trade *and*, for the home
  civ, their migrant waves.
- **Pick the right entity, don't take the first match.** `force.lua`'s `findCiv` returns the
  first entity whose `entity_raw.code` matches; a world can hold many civs sharing an HA raw
  code. Prefer one the fort has actually met and isn't at war with.
- **Untested: hostile civs.** Summoning merchants from a civ at war with you is exactly the
  goblin-caravan case Meph shipped, but it needs a live test on this build before we promise it.
- The summoned caravan brings whatever *that entity's* raws let it bring, which is the whole
  point: an orc caravan finally becomes a way to buy orc goods.

A generic `high-adventure/summon-caravan <civ>` helper shared by all four mods is the natural
shape, with each mod's workshop supplying flavour and the reagent cost.
