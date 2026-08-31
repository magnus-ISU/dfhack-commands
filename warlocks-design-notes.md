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
Costs (decided):

| Gargoyle | Cost |
|---|---|
| Melee (golem) | 15 boulders |
| Fire | 15 boulders + 15 souls |
| Ice | 15 boulders + 15 souls + 1 cut gem |

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

Nothing in that chain is bought — it is all butchery plus grinding.

### Our currency: souls, gems, gold

We drop the whole dust/alchemy tier. Three costs carry everything:

- **Souls** — the bulk cost. Butchery. Everything routine is priced in souls.
- **Gems** — the scarce cost. One cut gem gates a single expensive thing.
- **Gold** — the *large* cost, in bars. Reserved for the shrines and for resurrection.

**Does the clear-glass plan work? Yes, with one hard constraint, verified live against this
build:**

```
GLASS_CLEAR    IS_GEM=false  IS_GLASS=true
GLASS_GREEN    IS_GEM=false  IS_GLASS=true
GLASS_CRYSTAL  IS_GEM=false  IS_GLASS=true
DIAMOND_CLEAR  IS_GEM=true
```

- Raw glass **can** be cut at a jeweler's into a cut gem — that half of the plan is fine, and
  clear glass is genuinely expensive (sand **+ pearlash** + fuel; crystal glass is rock crystal
  + pearlash + fuel; only green glass is cheap).
- But glass is **not** `IS_GEM`, so `[ANY_GEM_MATERIAL]` silently excludes every glass gem.
  Write the reagent as a bare cut gem instead — which is what `ha-succubi` already does:
  `[REAGENT:gem:1:SMALLGEM:NONE:NONE:NONE]`.
- That bare form also lets **green** glass through, and green glass is cheap. If we care, the
  only raw-level fix is parallel reactions (`ANY_GEM_MATERIAL` / `SMALLGEM:NONE:GLASS_CLEAR:NONE`
  / `SMALLGEM:NONE:GLASS_CRYSTAL:NONE`), which triples the menu entry for every gem recipe.
  Recommendation: accept the bare `SMALLGEM` and let green glass count — it still costs a
  glassmaker, sand and fuel.
- **Masterwork cannot be required.** There is no quality token for reaction reagents at all.
  Enforcing it would need a script check, and reagents are consumed when the job starts, so the
  check comes too late to refuse cleanly. Drop the masterwork condition.

### What costs gems, and what costs gold

Rule of thumb: **gems buy permanence** (a thing that stays on the map), **gold buys authority**
(a building or a person coming back). Nothing pays both except resurrection.

**The locked price list.** Every gem line ships as **two reactions** — one taking a gemstone
(`[ANY_GEM_MATERIAL]`), one taking cut clear glass — since glass is not `IS_GEM`.

| Thing | Cost |
|---|---|
| Melee gargoyle | **15 boulders**, nothing else |
| Skeleton (weak citizen, can do labour) | souls |
| Fire gargoyle | souls |
| Elemental, any type (strong warrior, no labour, **max 5 per shrine**) | souls |
| Ice gargoyle | souls + **1 gem** |
| Power up a warlock | souls + **1 gem** |
| **Bone golem** (powerful large citizen, can do labour) | souls + **10 gold bars** + **1 gem** |
| **Resurrect a warlock citizen** | **10 gold bars + 1 diamond** (any diamond) |
| Building a shrine | **gold + a book** |
| Building a necromantic shrine | **14 gems** |

Gold as `[REAGENT:gold:N:BAR:NONE:INORGANIC:GOLD]`; for a *building* cost,
`[BUILD_ITEM:10:BAR:NO_SUBTYPE:METAL:GOLD]` — `ha-succubi` already proves the specific-material
form with `[BUILD_ITEM:1:BAR:NO_SUBTYPE:METAL:TIN]`.

### Undead tiers

The original's ghoul/skeleton split is too flat. Three rungs:

1. **Skeletons** — souls only. Weak citizens that *can* do labour. The workforce floor.
2. **Elementals** — souls only, but capped at 5 per shrine. Strong warriors, no labour.
3. **Bone golems** — souls + 10 gold + a gem. Powerful *large* citizens that can do labour;
   the top of both lines and the reason a fort keeps mining after its ice gargoyle.

**Imps: cut them, or give them the one job nothing else has.** As written they are redundant
three times over — elementals already are "stronger warrior, no labour", and mephits already
are "small flying elemental pet". If they stay, the only non-overlapping niche is *cheap and
temporary*: a swarm summon that expires after a season, for scouting or throwing at a siege,
never a citizen. Otherwise drop them.

### Gating magic work to warlocks

Not expressible in raws — reactions cannot be caste-restricted. Use the illithid mechanism,
which is proven in-repo (`ha-illithids/scripts_modactive/high-adventure/illithids.lua`,
`job_legal_caste` + `set_profile`): the script sets each magic workshop's
`building.profile.permitted_workers` to a single legal unit for the pending reaction, so only
a warlock can ever staff it. The Obsidian Factory is exempt and keeps an open profile.

### Building rules: shrines, books, and the Shaping Tree pattern

Two different mechanisms, and the split matters:

- **Requiring a unique book (and gold) to build is fully native.** `[BUILD_ITEM]` takes a
  specific tool subtype — `ha-succubi` already does `[BUILD_ITEM:1:TOOL:ITEM_TOOL_CAULDRON:NONE:NONE]`.
  So a shrine is `[BUILD_ITEM:1:TOOL:ITEM_TOOL_BOOK_<X>:NONE:NONE]` + `[BUILD_ITEM:10:BAR:NO_SUBTYPE:METAL:GOLD]`.
  No script. The book is consumed by construction, so "one book, one shrine" is automatic.
- **The Shaping Tree script is for what `BUILD_ITEM` cannot say** — *placement* and *state*.
  `playable-civs.lua` watches buildings under construction and cancels them with a message when
  the site is wrong ("must be built under the open sky", "must be built around a living tree"),
  and seeds per-building cooldowns on completion.

### The elemental cap is a POPULATION cap, not a per-building counter

Because `BUILD_ITEM`s are refunded on deconstruction, a per-building counter is trivially
defeated: summon 5, tear the shrine down, rebuild it (or rebuild it as another type, whose
counter is at 0), summon 5 more, for the price of re-hauling the same book and gold. Any
per-building state is the wrong thing to track.

**Track the living population instead.** At job-assignment time, count elementals belonging to
the fort; if the count is at the cap, cancel the job with a message. No persistence, nothing to
migrate across saves, and rebuilding a shrine buys nothing.

**Both caps scale with the shrines that are standing right now:**

```
type_cap(T)  = 5 x (completed shrines of type T)
global_cap   = 5 x (completed shrines, all types)

summon of type T allowed  <=>  living(T) < type_cap(T)  AND  living(all) < global_cap
```

The global is not redundant, and the deconstruct case is exactly why. Build a fire shrine,
summon 5 fire elementals, tear it down, build an ice shrine: `ice_cap` is 5 and no ice
elemental exists, so the type test passes — but `global_cap` is still 5 (one shrine) against 5
living elementals, so the summon is refused. The 5 fire elementals are *stranded* above a type
cap that is now 0, and the global is what keeps them counted. Build a second shrine and the
global rises to 10, which is the intended growth curve.

Details that matter:

- Count **completed** shrines only (`construction_stage >= bld:getMaxBuildStage()`), or a
  half-built shrine inflates the cap.
- Being over cap is a stable, harmless state — a torn-down shrine does not kill anything, it
  just stops new summons until something dies or a shrine goes up.
- **Living**, not lifetime: an elemental that dies frees its slot. A lifetime budget would need
  persistent state and would make losing one in battle permanent.
- Shrine type comes straight off `bld.custom_type` (one custom building per element), and the
  elemental's type off its creature/caste — no bookkeeping either side.

Enforce it the way `ha-illithids` enforces its bath rules — **at assignment time, never at
completion**, so the souls are not spent before the refusal:

```lua
-- illithids.lua, staff_baths(): conditions checked NOW, not at JOB_COMPLETED
if not job_feasible(rn) then cancel_bath_job(job, msg_infeasible(rn)) end
-- cancel_bath_job: removeWorker FIRST, then removeJob, then announce
```

Removing the worker before the job matters — cancelling a unit's `current_job` directly is a
known segfault.

**The book is a VANILLA book, checked by script.** No new item type — per the project's
vanilla-first rule, a bespoke `ITEM_TOOL_BOOK_*` is the wrong answer. The raw filter stays
loose and lua enforces the real condition, exactly like the elves' shaping-tree placement
checks:

```
[BUILD_ITEM:1:TOOL:NONE:NONE:NONE][HAS_TOOL_USE:CONTAIN_WRITING][CAN_USE_ARTIFACT]
[BUILD_ITEM:10:BAR:NO_SUBTYPE:METAL:GOLD]
```

`HAS_TOOL_USE` is a documented `BUILD_ITEM` modifier, and `ha-illithids` already proves
modifiers work there (`[BUILD_ITEM:1:BARREL:NONE:NONE:NONE][EMPTY][CAN_USE_ARTIFACT]`).

**"Unique" has a free definition in DF: an original written work is an ARTIFACT; a scribe's
copy is not** (copies also get "(copy)" appended to the title, and never enter legends). So the
script's test is one flag:

- walk `world.buildings.all` for our shrine `custom_type` with
  `construction_stage < bld:getMaxBuildStage()`;
- find the book in `bld.contained_items`;
- if it is not `flags.artifact` — a copy, or a blank quire, which is never an artifact —
  `dfhack.buildings.deconstruct(bld)` + `showAnnouncement("A shrine must be raised over an
  original work, not a copy.")`. Deconstructing mid-build returns the book and the gold.

`[CAN_USE_ARTIFACT]` is **mandatory** here — without it DF refuses to haul an artifact to a
construction site and the recipe can never be satisfied.

The gate becomes "run a library and have your warlocks *write* something", which fits the theme
better than a bespoke recipe would.

**`BUILD_ITEM`s are not consumed — they are stored in the building and returned on
deconstruction.** Verified live: a workshop's build materials sit in `bld.contained_items` with
`use_mode = 2` for the life of the building. So the artifact book is *housed* in the shrine, not
destroyed, and deconstructing hands it back along with the gold.

That is the right flavour — the shrine is built around its founding text — but note what it
does to the economics: **every building cost here is a deposit, not a payment.** One artifact
book plus 10 gold bars can be recovered and spent on the next shrine, and the same is true of
the necromantic shrine's 14 gems. If a shrine is meant to *cost* something permanently, the
price has to move out of `BUILD_ITEM` and into a reaction that consumes reagents. Worth deciding
deliberately; the refundable version is defensible (relocating a shrine shouldn't cost a fresh
artifact) but it is not what "costs 14 gems" sounds like.

Side effect while a shrine stands: its book is in use by the building, so it cannot also be
shelved in a library or read.

### Population: no migrants, but children

`[CHILD:n]` and ordinary reproduction give children — a deliberate departure from the original,
where warlocks were sterile immortals.

**There is no raw token that disables migrants.** The workable approach is the inverse of the
caravan trick: our script scans `df.global.timed_events` and erases any `Migrants` event whose
entity is the player civ. Small vector, cheap to check, and it uses machinery we already
understand from `force.lua` / `dfhack/fort/force-more.lua`. Needs a live test.

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

## Nobles — DECIDED

Five noble positions, plus two military ones. The Horsemen are the **civil administration**,
replacing the whole vanilla slate (mayor, manager, bookkeeper, broker, chief medical,
sheriff/hammerer) — *and* each is stationable as a one-man squad.

| Position | Raw slot | Responsibilities | Squad |
|---|---|---|---|
| **Sorcerer Supreme** | `EXPEDITION_LEADER`, auto-assigned | meet workers, receive diplomats, military goals | — |
| **Death** | appointed | law enforcement, executions | `[SQUAD:1:death:deaths]` |
| **Hunger** | appointed | trade, accounting, stocks | `[SQUAD:1:hunger:hungers]` |
| **Pestilence** | appointed | health management | `[SQUAD:1:pestilence:pestilences]` |
| **War** | appointed | military strategy, manage production | `[SQUAD:1:war:wars]` |
| **Crypt Lord** | `AS_NEEDED`, warlock-only | squad leader for warlocks | normal squad |
| **Death Knight** | militia commander, non-warlock castes | squad leader for skeletons/golems | normal squad |

The Horsemen responsibility split above is a flavour call, confirmed as the starting point.

**Making the Sorcerer Supreme permanent.** Verified against `entity_default.txt`: vanilla's
`EXPEDITION_LEADER` carries `[REPLACED_BY:MAYOR]`, and `MAYOR` is `[ELECTED]` with
`[REQUIRES_POPULATION:50]`. So define the Sorcerer Supreme as `EXPEDITION_LEADER`, **omit
`[REPLACED_BY:...]`, and define no `MAYOR`** — nothing then displaces it, and the fort always
has an auto-filled noble able to appoint the other four.

Naming note: the original mod used "Sorcerer Supreme" for the off-site `MONARCH`. If we ever
want an off-map ruler too, it needs a different title.

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
