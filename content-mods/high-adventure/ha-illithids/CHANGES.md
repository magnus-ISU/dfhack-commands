# ha-illithids — build notes (v0.1)

## v0.24 — ur head remap on the correct page
- v0.23 remapped BODY_SPECIAL faces, but those are undead-state layers; LIVING
  illithid faces (FACE_F1-M4) live on the main BODY page. Now remapping FACE layers
  on BOTH pages to the ur head columns (4 & 6), targeting only FACE-named layers so
  shoulders/arms/body stay intact.

## v0.23 — ur uses the real mb art with special heads
- Removed the hand-composited static ur sprite. Ur now uses a full caste-graphics
  copy of the varied mb illithid art (all body colours/variation intact), with the
  BODY_SPECIAL face columns remapped to the ur head columns (4 & 6, the six-tentacle
  faces the user identified) for every head index - so ur is a proper varied
  illithid that always wears the master head. Regular illithids (creature-level
  art) untouched.

## v0.21
- **Ur visual distinction**: the original mb graphics have zero caste conditions -
  every illithid caste shares one look, so ulitharid was never visually distinct
  (its extra tentacles are mechanical, invisible at 32px). Added a caste-graphics
  override giving ULITHARID a distinct sprite: the illithid body recoloured deep
  indigo-black with a bright extra pair of face-tentacles. (Errorlog confirmed
  clean for v0.20 - the lingering entries were stale, pre-snapshot-wipe.)

## v0.20
- **Stale snapshots were the culprit** for persistent errorlog entries - the world
  was gen'd on an old installed_mods copy. All snapshots wiped (standing rule).
- **Ur body fixed**: [BODY:EXTRA_FACE_TENTACLES] standalone gave ulitharid only two
  tentacles and no torso (Unrecognized/fallback). Now a full humanoid body line
  ending in 4_FACE_TENTACLES:EXTRA_FACE_TENTACLES - proper six-tentacle master.
- **Elder twinkle fixed**: DEFAULT and ANIMATED both pointed at the same LARGE_IMAGE
  region, and DF's frame-alternation flickered it to grayscale. Dropped ANIMATED;
  DEFAULT-only renders steady.
- Removed the mucus body-transformation (referenced the old creature name) and the
  invalid ROOM_REQUIREMENTS_MODIFIER entity token.

## v0.19 — errorlog-driven fixes
- **Thrall bodies (real fix)**: the skin-colour SELECT_CASTE:THRALL block was placed
  before the thrall castes are declared, so it silently failed ("Caste Selection
  Fails" / "Null color selection") - thralls had NO skin colour and body layers
  can't pick a palette without one. Moved to the end of the creature, after the
  castes exist. Illithid purple stays scoped to illithid castes.
- **Ur distinct again**: added the EXTRA_FACE_TENTACLES body (was undefined, so ur
  fell back to the base 4-tentacle body and looked like a regular illithid).
- Fixed stale ILLITHID:AGENDER creature-name refs (mucus syndrome) -> HA_ILLITHID.

## v0.18
- **Thrall bodies render**: illithid purple skin was applied to ALL castes, so the
  human body art (needing human skin colors) couldn't match. Purple now scoped to
  illithid castes; thralls get vanilla human skin colors.
- **Psychic shields named + exclusive**: barrier (lvl1) / shield (lvl3) / aegis
  (lvl5) / prismatic aegis (lvl8). Shields moved out of innate/bundled grants into
  4 dedicated syndromes; the watcher grants only the highest tier and strips the
  rest, so an aegis-caster never casts a barrier.
- Descriptions: ur trimmed to one sentence; elder = "A vast naked brain upon a
  mass of writhing tentacles; a hatchling god with an unstoppable force of will."

## v0.17
- **Ur renders again**: the iron-hide change replaced the skin tissue, breaking the
  mb graphics skin-color conditions (bodies vanished, clothes stayed). Reverted to
  skin + high toughness/strength attributes for the iron-hard-skin effect.
- **Thralls: full vanilla human layered art** (gender-split caste files, orc-style
  CREATURE_CASTE_GRAPHICS), replacing the v0.16 static sprite that was cropped from
  a baby frame. Thralls inherit the forked creature's appearance infrastructure,
  so adult human bodies render with variation.
- Caste descriptions restored (illithid "dread psionic...", ur "towering
  master...", elder + thrall unchanged).

## v0.16 — CREATURE REBUILT BY FORKING THE ORIGINAL MOD
- Root lesson: layered body art needs the source creature's tissue/appearance
  infrastructure AND caste names it conditions on. Building from scratch severed
  both. drow worked because it is a full elf fork; illithids now work the same way.
- **Creature forked from the original Illithids mod** (Myphicbowser): keeps its
  complete infrastructure (color-varying skin, appearance modifiers, scholar
  skill-rates, max mental attributes, blue blood, tentacle bite) and its caste
  names FEMALE/MALE/AGENDER/ULITHARID - so the original mod's graphics render
  VERBATIM with full variation.
- Our features re-applied as a diff: ageless (MAXAGE stripped), childless
  illithids (thralls keep childhoods), EVIL + OUTSIDER_CONTROLLABLE, NO_SLEEP,
  blood-sense, discipline 50 + combat skills, brain-burn venom bite, our 10-level
  psionics (base CDIs by caste + ascension syndromes), no armor (entity),
  TRUE_ILLITHID gating. ULITHARID displays as "ur-illithid" with our buffs
  (flight, no-eat, iron hide, bigger, UR_BRAIN, level-4 psionics). ELDER_BRAIN
  and THRALL castes added. Ratios: illithid 40 / ur 9 / elder 1 / thralls 50.
- Graphics: original mb art verbatim (PENUMBRA layers dropped); elder LARGE_IMAGE;
  thralls a static human sprite this pass (layered human variation is a later
  polish - deferred to de-risk this rebuild). Script caste refs remapped.

## v0.15 — the caste-ID revelation
- **Root cause of clothes-only bodies everywhere**: CONDITION_CASTE matches caste
  ID strings. Vanilla human body layers demand FEMALE/MALE castes (drow worked
  effortlessly because their castes ARE named FEMALE/MALE); mb layers demanded
  FEMALE/MALE/AGENDER/ULITHARID. Our renamed castes matched nothing.
- Thralls: gender conditions remapped to THRALL_F/THRALL_M - full vanilla human
  rendering.
- **mb variety restored**: the full layered set caste-wrapped one-block-per-file;
  old caste conditions stripped (color/body variety flows from
  CONDITION_RANDOM_PART_INDEX, which is unit-random and needs no genes);
  ULITHARID-only layers live in the ur file; PENUMBRA layers dropped; mb tile
  pages restored.

## v0.14
- **Thralls carry vanilla human appearance genes** (both pre-caste and post-caste
  regions ported and rescoped): hair/eyebrow tissues, body-part appearance, hair
  styles, colors - so the verbatim human layered art's conditions can finally
  match. Bonus: thralls gain human punch/kick/bite (they previously had no
  attacks at all).
- Illithid/ur art moved from single-tile rows (suspected flash source - the only
  unproven form) to **orc-exact palette-free layered caste files**; ur sprite
  re-tinted deep blue, unmistakable.
- **Overlord** gated to HA_TRUE_ILLITHID like the voice of the colony.

## v0.13 — graphics architecture, the suite-proven shape
- **One CREATURE_CASTE_GRAPHICS block per file** (every working case - elder,
  drider, all 14 orc files - follows this; my multi-block files bled across
  castes, hence gray/blue flashing and ur heads on thralls).
- **Real full-body sprites**: mb stores bodies as part-layers; the illithid
  sprite is now a composite of all VIOLET parts, the ur of all MIDNIGHT_BLUE
  parts (naturally darker/larger presence). No more floating heads.
- **Thralls wear vanilla human art verbatim**: the base-game human layered set
  re-keyed to HA_ILLITHID at creature level (palettes shipped, dark-dwarf
  technique), every layer conditioned to the thrall castes - full bodies,
  clothing, hair, professions, exactly as humans render.
- Voice of the Colony gated to a new HA_TRUE_ILLITHID class (illithid, ur,
  elder) - no thrall may speak for the colony.

## v0.12 — three errorlog-guided fixes
- **Graphics rows need the color argument**: working files (elder, drider) end
  every row with AS_IS; the illithid/ur/thrall rows lacked it and were silently
  dropped (gorlak fallback / no art). All rows now carry AS_IS plus LIST_ICON and
  CORPSE entries, matching the proven form exactly.
- Invalid color token PALE_PURPLE (my invention) replaced with LAVENDER/PURPLE -
  was erroring every illithid caste's skin at world gen.
- Psychic shield syndromes used a malformed CE_MATERIAL_FORCE_MULTIPLIER; now
  copied from mb's literal working grammar (MAT_MULT:NONE:NONE:pct:100:PROB:100).

## v0.11
- **Penumbra excised entirely** (design reversal from v0.9): the inert inorganic
  is gone and every graphics layer or condition referencing the metal is removed
  block-aware. Zero references remain anywhere in the mod.

## v0.10
- Illithid/ur art converted to **static caste rows** (proven form): the mb layered
  body gates on appearance genes our rebuilt creature lacks - conditions never
  match, bodies never render (clothes-only symptom). Until mb appearance
  modifiers are ported, everyone gets a solid static sprite (ur tinted dark).

## v0.9 — graphics parser fix
- **Body layers invisible / thrall gorlak fallback root cause**: mb armor layers
  condition on the PENUMBRA metal, undefined in our fork - every reference
  desynced the graphics parser (errorlog: "Unrecognized Inorganic Token"),
  swallowing the body layers behind it. PENUMBRA is now defined as an inert,
  ungenerated metal (no reactions produce it), satisfying the parser.
- Thrall sprite rebuilt: densest mb body frame, flesh-tinted (the old crop was a
  near-blank 90px sliver of a palette template).

## v0.8
- **Illithids are never children**: BABY/CHILD stages moved off the illithid castes
  (thralls keep human childhoods) - illithid, ur, and elder are born whole. Tadpole
  newborns now report birth **today, age 0, accurately**.
- **Ascended elders keep their lives**: the revived-ur path (the usual case)
  preserves the original unit's age and history untouched; the rare minted-fallback
  elder no longer gets artificial aging either.

## v0.6 — variation restored
- The mb layered art is palette-free, so it qualifies for the orc-proven topology:
  the full 1096-layer set (worn items, professions, dyes, 88 random body variants)
  is now caste-wrapped for ILLITHID and UR_ILLITHID, replacing v0.5's static rows.
  Old-mod caste conditions stripped; original tile pages restored alongside the
  32px icons. Thrall and elder-brain rows unchanged.

## v0.5 — playtest fixes (corpse reagents are broken in raws; all validation moved to script)
- All four corpse reactions accepted any unrotten item (raws CORPSE filters silently
  fail) and GET_MATERIAL products yielded nothing. Now every job is script-validated
  and cancels with a clear message on bad input: devour requires a sentient outsider
  corpse (yields 5 meat + 2 fat via script, +1000 scholar xp, 20% ur-ascension for
  base illithids - the "transformed into an illithid" message was DF's own wording
  for this promotion, race name not caste; junk can no longer trigger it), reclaim
  requires an illithid corpse (not thrall), extract requires an ur-illithid corpse
  (brain item created by script), implant cancels without a caged brain-bearing
  sentient.
- **Resonate**: elder-brain-only (cancels with instructions otherwise); the boiling
  mist boulder is gone - its below-ambient melting point is the prime suspect in the
  bath's destruction - replaced by script-side stress washing + scholar xp trickle.
- Neural Bath costs 1 empty barrel + 3 building materials.
- Descriptions per spec; **art rebuilt in the drow-proven form**: static caste rows
  for illithid and ur-illithid (base frame cropped from mb sheet; ur tinted dark),
  thrall and elder rows unchanged; the mb layered file (clothing-only rendering) is
  retired.

## v0.4
- Court renamed: monarch = **elder brain** (gated to the Elder Brain caste via
  ALLOWED_CLASS - vacant until one exists), war-mind = **overlord**, lesser
  war-mind = **captain**, calculating mind = **calculator**.

## v0.3
- **Critical fix**: the playability/hostility/permit block silently failed to apply
  in v0.1-0.2 (anchored on a token PLAINS lacks) - the civ had no SITE_CONTROLLABLE,
  no ITEM_THIEF, and no Neural Bath permits. All inserted properly: playable,
  hostile to all (ITEM_THIEF + AMBUSHER + ABUSE_BODIES), bath and all six
  reactions permitted.

## v0.2
- Caste ratios rebalanced: **thralls 50%** (25 M + 25 F), illithids 40%,
  ur-illithids 9%, elder brains 1% - the colony is now visibly a slave-city with
  an illithid ruling class.
- Thralls never complain and are never upset: anger, stress vulnerability,
  depression, anxiety, discord, and emotional obsession all zeroed. They work,
  they breed, they endure. (Their base discipline 8 stays.)

Sources: face-tentacle body + mind-blast/shield concepts + language forked from
**Illithids** (Steam 3027569318, Myphicbowser; language by DPh Kraken); entity forked
from vanilla PLAINS; spawn/promotion/emission techniques from the suite's proven stock
(orc pit, drow slaves, succubus corruption). All IDs `HA_*`.

## Creature — HA_ILLITHID (all ageless; sexless except thralls)
- **ILLITHID** (72): psionic level 1, carnivore brain-eater, no sleep, blood-sense,
  legendary brain-burn bite (paralysis + necrosis), anger-prone.
- **UR_ILLITHID** (17): level 4, 120k size, iron-grade hide (skin plated), FLIER,
  no food/drink, NOPAIN.
- **ELDER_BRAIN** (1): level 6, 10M size, ten grasping tentacles, eyeless
  (EXTRAVISION), fragile (toughness floor), cannot drown, flies, drifts at
  battering-ram speed, maxed mental attributes.
- **THRALL_M/F** (5+5): mortal gendered humans; children roll ALL castes (thralls
  are the colony's brood-stock — worldgen populations grow).
- Discipline 50 (Legendary+35), combat skills 5, no skill rust, bite 15.

## Entity — HA_ILLITHID_CIV
- DARK_FORTRESS, tolerates nothing (razes conquests), no caravans, ITEM_THIEF +
  AMBUSHER (hostile to all), eats sapients, **no armor of any kind** — clothing
  and robes only (entity-level, airtight); swords/bows weighted, all human weapons
  permitted; full human industry; psionic court (overmind, voice of the colony,
  war-minds, calculating mind).

## Neural Bath (5×5, strand extraction; built from 1 buildmat + 2 buckets)
- **Devour the brain of a sentient creature**: consumes an unrotten sentient corpse,
  yields meat+fat (butchery), +1000 xp to worker's best scholar skill (random tie),
  20% ur-ascension for base illithids. Thralls are refused.
- **Reclaim a dead illithid's memories**: unrotten illithid corpse → +1000 scholar
  xp to every citizen, ghost quieted.
- **Extract the precious brain of an ur-illithid**: caste-validated; yields the
  UR_BRAIN item (caste-specific material — regular brains can't fake it).
- **Implant tadpole into prisoner**: caged sentient with a brain is freed, stunned,
  and its head bursts (gore, head destroyed, exsanguination); a newborn illithid
  citizen crawls free.
- **Ascend a dead ur-illithid**: ur-brain + adamantine thread; revives the dead ur
  as an ELDER BRAIN (full-heal + caste ascension) or coalesces a new one.
- **Resonate with the colony**: elder's job (repeat-designatable); trains logic
  natively, exhales joy-mist (illithid-only euphoria), script trickles random
  scholar xp colony-wide.

## Psionics — 10 levels (base: illithid 1 / ur 4 / elder 6; +1 at scholar skill 3/6/12/24)
1 mind blast + psychic shield I · 2 +disarm (hands spasm open) · 3 3-target +shield II
· 4 +unconsciousness · 5 telekinetic shove + shield III · 6 enthrall (CRAZED)
· 7 psionic lance (range 30, 5 targets) · 8 absolute aegis · 9 psionic storm
(15 targets, terror) · 10 annihilation (catastrophic necrosis+hemorrhage).
Upgrades are permanent syndromes applied by the watcher (fort + adventure).

## Graphics
- mb layered art re-keyed, every layer conditioned to ILLITHID/UR (1096 layers);
  elder brain = 96×64 3×2 LARGE_IMAGE caste rows (drider-proven); thralls = vanilla
  human base tile; Neural Bath = 4-stage purple brine pool with floating brains.

## Known gaps / verify
- Elder-brain-death-kills-all: deliberately omitted pending decision (ascension
  makes replacement possible; say the word to add the death-link).
- Devour-corpse butchery products use GET_MATERIAL_FROM_REAGENT (muscle/fat) —
  verify yields in play. Implant head-burst degrades gracefully to messy death.
- mb portrait/statue art not carried (referenced dead castes); polish pass later.
