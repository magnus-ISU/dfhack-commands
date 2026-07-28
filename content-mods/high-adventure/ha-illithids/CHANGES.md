# ha-illithids — build notes (v0.1)

## v0.45 — cage rites teleport their reagent too + resonate/reclaim skill tuning
- The cage rites (implant a tadpole / devour a caged prisoner) now also move their reagent to the
  bath: while the bath is staffed, a prisoner-bearing CAGE is teleported into the ring of 8 tiles
  around the bath centre, same as the corpse rites. find_prisoner now takes the worker's position
  and returns the CLOSEST valid caged prisoner, so the rite consumes the cage that was teleported
  beside the bath rather than one across the map (and the ring cage doesn't pile up unused).
- **Resonate** now trains, per non-thrall illithid, ONE random mental skill (+10 xp) and logician
  (+10 xp) each time -- instead of the old repeated random-scholar bursts that cumulatively raised
  the whole scholarly array. (Still calms the colony's stress.)
- **Reclaim lost memories** now trains a RANDOM mental skill for each of the 10 least-developed
  minds, rather than each recipient's highest skill.

## v0.44 — one worker per bath (fixes resonate) + teleport reagents (drops dump-zone hauling)
- **Resonate no longer churns an illithid.** A bath holds a SINGLE worker profile, but a bath with
  many queued rites needs different castes (resonate = Elder Brain only; devour/etc. = non-thrall).
  The old per-job pin let the last job win, pinning an illithid who then grabbed the resonate job
  and was endlessly unclaimed. Now the whole workshop is staffed by ONE worker legal for the most
  restrictive rite present -- the legal-caste sets are nested (resonate ⊂ non-thrall ⊂ anyone), so
  an Elder Brain staffs any bath containing a resonate job and can perform every other rite too.
  (Put resonate in its own bath if you want illithids working the other rites in parallel.)
- **Replaced the dump-zone corpse hauling with a teleport.** DF hauling to a script-made dump zone
  was unreliable. Now, while a bath is staffed, each corpse-rite (devour/reclaim/extract) keeps one
  matching corpse teleported into the ring of 8 tiles around the bath's centre (the middle 3x3
  minus the centre) -- the reagent appears beside the assigned worker; take_corpse consumes the
  nearest and the next pass teleports a replacement. Removed ensure_haul_target / request_haul /
  reclaim_hauled / haul_corpses_to_bath (and the `#nil` crash they carried is gone with them).

## v0.43 — proactive bath staffing + newborns are 0-year-old adults + staffing crash fixes
- **CRITICAL: staffing no longer dies mid-game.** `ensure_haul_target` did `#findCivzonesAt(...)`,
  but that DFHack call returns NIL (not an empty list) when no zone is on the tile, so `#nil` threw
  on every staffing tick that had a bath job. repeat-util re-schedules a tick only if its callback
  RETURNS, so the error silently killed staffing until a reload -- workers stopped being assigned
  and the (useless) "brine stirs" message appeared. Coalesced to `or {}`. Also hardened
  `caste_name` (a unit mid dummy-transform during a caste change can momentarily have an out-of-
  range caste index) so ascensions/promotions can't crash the tick either.
- **The staffing ticks are now wrapped in pcall** and log-and-continue, so no future error can kill
  the service; and a job completion calls `ensure_ticks()`, which restarts staffing if it ever
  stopped -- at most one rite is lost, then proper assignment resumes.
- Replaced the unhelpful "brine stirs / tender slipped away" message with a quiet skip (it only
  fired when staffing had stalled, which now self-heals).
- **Tadpole-born illithids are now age 0 and adult.** Illithid castes carry no CHILD/BABY token
  (no child phase), but `set_age_fresh_adult` was aging new units up by ~18 years. Newborns from
  an implanted prisoner now read as 0 years old and fully grown.
- **Bath jobs are staffed PROACTIVELY -- never by waiting for a job to finish.** Every fast tick,
  for each queued bath job the mod chooses ONE specific valid worker (preference-ranked,
  idle-preferred) and pins the workshop profile to exactly that unit, so only an eligible caste
  can claim it (every illithid and thrall carries the strand labor, so without this a thrall could
  grab "devour a dead sentient's brain," or a non-Elder "resonate"). Conditions are checked at
  assignment time, not at completion.
- **A job whose conditions fail is cancelled at staffing time, with a clear, specific reason** --
  no material/target on hand, no eligible caste in the colony, or an ineligible worker having
  grabbed it (in which case a valid worker is re-pinned). Example message: "Neural Bath: cancelling
  the job to devour a dead sentient's brain -- no fresh sentient-outsider corpse is on hand."
  Resonate cancels/reassigns whenever its worker is not a living Elder Brain.
- Reactions take far longer to perform than the 20-tick staffing cadence, so an
  ineligible/infeasible job is always cancelled before it can complete; the completion handler just
  applies the effect (handlers keep a defensive per-caste no-op as a last resort).
- **The assigned worker is handed back after EACH completion, including repeat jobs** -- the
  workshop is re-pinned to a fresh valid worker (idle-preferred) for the next cycle rather than left
  empty. Leaving it empty let an ineligible caste grab the repeat job in the window before the next
  staffing pass -- most visibly an illithid snatching a **resonate** job that only the slow Elder
  Brain may do, which then had to be unclaimed, looking like "assigns an illithid, then cancels."
  Re-pinning a valid worker keeps the rotation with no such window (for resonate the Elder Brain is
  the only valid pick, so it simply stays pinned). A worker the player pinned before the task began
  is left untouched. (Script-only change; hot-reloads into the running fort.)

## v0.42 — worldgen fix (no illithids) + crash-free caste changes
- **CRITICAL worldgen fix:** worlds generated no illithids at all. An orphaned, malformed
  "nullification" syndrome block left over from the pre-rename base mod (no `[SYNDROME]`
  opener, bare `ILLITHID:MALE/FEMALE/ULITHARID` creature tokens) produced *"Error(s)
  finalizing the creature HA_ILLITHID"*, which excluded the illithid civ from worldgen.
  Removed the dead block and fixed the two `SYN_IMMUNE_CREATURE:ILLITHID:ALL` toxin lines
  to `HA_ILLITHID:ALL`. Illithids spawn again. (Raws -> regenerate the world.)
- **Crash fix (converted ulitharids):** clicking the description of an illithid promoted to
  ulitharid crashed the game, and its art was wrong. Cause: `set_caste` set `u.caste`
  directly *and* applied a permanent `CE_BODY_TRANSFORMATION`. ULITHARID has EXTRA_FACE_TENTACLES
  (extra body parts -> extra appearance modifiers), so with `u.caste` pointing at ULITHARID but
  the appearance vectors still sized for the regular illithid caste, the description viewscreen
  read past the end of those vectors and crashed; the leftover permanent curse gave wrong art.
- Rewrote the caste change to the succubus-proven pattern: write the target caste into the
  identity *caches* only (enemy/soul/histfig race+caste), then apply a one-tick dummy transform
  (`HA_ILLITHID_TF` -> new `HA_ILLITHID_DUMMY`, `START:0:END:1`). When it reverts, DF rebuilds
  the body, appearance vectors and graphics from the caches, landing cleanly on the target caste
  -- no crash, correct art. Replaces the old permanent `become ulitharid` / `become elder brain`
  syndromes. Elder-brain ascension no longer needs a manual resize (the revert rebuilds it at the
  caste's BODY_SIZE 10000000). (Raws -> takes effect in a newly generated world.)

## v0.41 — illithids forge armor but never wear it
- Entity now permits forging protective armor (breastplate, mail shirt, leather, metal helm,
  gauntlets, greaves, high boots) -- so thralls can be armored and armor can be traded.
- New script step strip_illithid_armor() (slow tick): removes actual armor pieces
  (armorlevel > 0) from any illithid squad member's OWN uniform -- body/head/pants/gloves/shoes
  -- while keeping weapons, shields, clothing (armorlevel 0), and leaving thralls fully armored.
  So an illithid soldier fights robed and armed but never armored, no matter what uniform you
  assign. (Entity change is raws -> new world; the strip script re-registers on fort load.)

## v0.40 — ulitharids and elder brains no longer fly
- Removed [FLIER] from ULITHARID and ELDER_BRAIN. Flight forced expensive 3D pathfinding
  (a real FPS drain, especially for the huge elder brain) and made their pathing erratic.
  Both keep their walk gaits (elder brain: Ponderous Drift; ulitharid: humanoid body plan),
  so they still move -- just grounded. Regular illithids never had FLIER. Raws, so it takes
  effect in a newly generated world.

## v0.39 — corpse hauling to the bath (dump-zone pipeline)
- Reagent-less bath jobs (devour/reclaim/extract) consumed the nearest corpse without anyone
  hauling it. Now, for a bath's queued corpse jobs, the mod keeps a small supply of matching
  corpses hauled to the workshop: it creates a 1x1 garbage-dump Civzone beside the bath (once,
  cached per bath), flags matching corpses for dumping so haulers carry them there, and
  un-forbids the delivered (dumped) corpses so the reaction can consume them. Over-haul is
  capped (stops once ~3 corpses wait at the bath; flags at most 3/tick).
- MECHANISM IS ISOLATED for easy refactor: ensure_haul_target / request_haul / reclaim_hauled
  are the only haul-mechanism functions; the pipeline (which corpse, when) is separate. If DF
  won't haul to a script-made dump zone, swap those three (e.g. a posted DumpItem/BringItemToShop
  job) without touching the pipeline.
- CAVEAT: UNVERIFIED. DF suppresses ALL civilian hauling during a siege/alert, so this only
  works on a calm fort -- confirm there that dump-flagged corpses actually get carried to the
  bath's dump zone. Zone creation itself is confirmed working (Civzone subtype Dump registers
  in ZONE_DUMP). Takes effect on the next fort/save load (tick re-registration).

## v0.38 — elder brain grayscale-flash fixed at the source
- The real cause: the creature-level `[CREATURE_GRAPHICS:HA_ILLITHID]` `SHADOW` layer was the
  ONE unconditioned layer, so it leaked onto the ELDER_BRAIN caste; on the animated frame the
  elder fell back to that creature-level art (grayscale, since the brain-body can't render the
  illithid body page). The drow scopes its shadow with CONDITION_CASTE (so driders never flash)
  -- the illithid didn't. Fixed by scoping the illithid SHADOW layer to FEMALE/MALE/AGENDER, so
  no creature-level layer applies to the elder and its caste graphics render steadily. (All the
  earlier DEFAULT-vs-ANIMATED toggling in the caste block was treating a symptom.) Graphics
  re-index at launch, so this needs a DF restart, not just a reload.

## v0.37 — staffing tick fix, unassign, thrall ghosts
- **The periodic tick was never being (re)scheduled** after hot-reloads -- the fast tick that
  runs staff_baths wasn't registered, so nothing assigned/cancelled bath jobs. Fixes:
  self-enable always runs on load; do_enable cancels before scheduling (scheduleEvery does not
  replace a key); staff_baths runs on the fast (20-tick) tick for prompt assign/cancel. NOTE:
  DFHack script reload does NOT re-run do_enable -- these take effect on the next fort/save
  load, not a live hot-reload.
- **Unassign after work**: a bath with no jobs clears its worker profile; a cancelled job
  also releases its worker (removeWorker) and drops the pinned profile.
- **Feasibility checked FIRST** (before worker/legality), so an infeasible job is cancelled
  even after a worker already claimed it.
- **Thralls never linger as ghosts**: the tick clears flags3.ghostly from thrall castes.
  Illithids still ghost normally unless devoured/reclaimed at the pool or memorialized.

## v0.36 — bath staffing: unassign when idle, cancel infeasible jobs, quiet resonate
- **Unassign after the job**: once a bath has no HA_ jobs left, staff_baths clears the
  worker profile it set (only ever a mod-set one, never the player's), so the workshop
  isn't left restricted to one dwarf while idle.
- **Cancel infeasible jobs**: a queued job whose material isn't on hand is cancelled --
  devour (no sentient corpse), reclaim (no illithid corpse), extract (no ulitharid corpse),
  implant/devour-prisoner (no caged prisoner), ascend (no preserved brain tool + 15000
  adamantine thread). Resonate needs no material. Feasibility is checked BEFORE the
  worker/legality logic, so an infeasible job is cancelled even after a worker has already
  claimed it (everyone now has the strand labor, so jobs get grabbed within a tick or two).
- **Resonate no longer announces** (it's a frequent repeat job; the message spammed the
  log). Its effects are unchanged.
- Verified live: a queued resonate job correctly staffed the elder brain (its only legal
  caste); fort stable.

## v0.35 — bath staffing by workshop profile (labor left alone)
- The script no longer manages anyone's strand-extraction labor beyond keeping it ON for
  every illithid citizen (keep_strand_enabled) so all castes can physically staff the bath.
  No more stripping, no more temporary grant/revoke.
- **staff_baths()** steers each queued bath job to a legal, preference-ranked worker via the
  workshop's permitted-workers profile:
  - Legality: resonate = elder brains only; implant = anyone (incl. thralls); devour /
    reclaim / extract / ascend = any non-thrall.
  - Preference: illithid > ulitharid > elder brain > thrall (idle candidates win ties).
  - If the player pre-assigned the workshop, it's left alone.
  - A job an illegal worker grabbed is cancelled after reassigning the shop; a job with no
    legal candidate (e.g. resonate with no elder, or an all-thrall fort) is cancelled.
- NOTE: shipped but NOT yet verified live — the test world crashed (see below) before a
  reload could exercise it.

## v0.34 — graceful neural-bath staffing (no more labor stripping)
- **Stopped auto-removing the strand-extraction labor from ulitharids** (and from
  ulitharid-caste founders, which read as "illithids in the starting 7"). The old
  labor_policy stripped EXTRACT_STRAND from ulitharids and promote_to_ur did the same on
  promotion -- both removed.
- **Graceful bath staffing (manage_bath_labor)**: when a neural bath has a queued job and
  no eligible illithid has the strand labor, the mod enables EXTRACT_STRAND on ONE random
  appropriate worker (non-thrall, non-elder citizen), and hands the labor back once no bath
  job remains (only from workers it assigned -- never the player's own labor choices). So
  bath jobs always get staffed without the player micromanaging labors, and elites aren't
  permanently doing menial work. Elder brains remain out of the labor pool; resonate is
  unchanged.

## v0.33 — reclaim cap, awakening display, innate shields, crash revert
- **Reclaim rewards only the 10 lowest-level illithids** (sorted by psi level, then scholar
  skill), instead of the whole colony.
- **Psionic-awakening announcement**: shows only the HIGHEST level newly reached (a IV->VI
  jump prints just "VI", not V and VI), with capital roman numerals.
- **Innate base shields for worldgen/adventure**: each caste's base-level best shield is now
  innate in the raws -- illithid = psychic barrier (I), ulitharid = psychic shield (II),
  elder brain = psychic aegis (III) -- so they defend even when the fort script isn't
  running. The script (apply_shield) now only grants/manages shields STRICTLY ABOVE that
  innate base, so it never duplicates the base tier and still keeps a single best higher
  shield. (Attacks were already innate per caste.)
- **Brain tool uses the vanilla body-part brain sprite** (graphics_ha_brain.txt ->
  TOOL_GRAPHICS on the global BODYPARTS page, 0:13; no art shipped).
- **CRASH FIX / revert**: the v0.32 cage-emptying (uncage_unit erasing cage<->unit
  general_refs on devour/implant) crashed DF's UI renderer a few ticks later -- manual cage
  ref surgery is unsafe on this build (DFHack releases caged units via pit jobs, never ref
  edits). Reverted: devoured/implanted prisoners no longer scrub the cage, so the emptied
  cage keeps its former-occupant name (cosmetic) but the game stays stable.

## v0.31 — ascends-spam fix, workshop order, brain name prefix
- **No more "ascends: psionic awakening" spam on load**: apply_levels tracks a per-unit
  applied level (psi_applied) and stays silent on first sight (fort load, migrant
  arrival, fresh spawn) — natural ulitharids (base 4) and elder brains (base 6) no
  longer announce their base levels. Only genuine in-session gains (skill growth, pit
  ascension) announce.
- **Workshop task order forced via "a."–"g." name prefixes**: DF sorts a custom
  workshop's task list ALPHABETICALLY by display name (not raw/entity order), so the
  reactions are prefixed a.–g. to land in the intended order (implant, devour-prisoner,
  devour-sentient, reclaim, extract, ascend, resonate).
- **Brain reads "preserved ulitharid brain"** (no "illithid"/"iron" prefix): added
  [PREFIX:NONE] to the UR_BRAIN material so the creature-name prefix is suppressed.

## v0.30 — ulitharid rename, bath polish, prisoner/ascend/syndrome fixes
- **find_syndrome fixed for this DFHack build**: world.raws.syndromes doesn't exist
  here, so the old lookup errored on every call — silently breaking ALL syndrome
  application (psi ascension AND caste transforms). Now iterates df.syndrome.find(id).
- **"ur-illithid" renamed to "ulitharid" everywhere it shows** (caste name, reaction
  names, item, announcements, description). Internal IDs (ULITHARID, UR_BRAIN,
  promote_to_ur) unchanged. Transform syndrome "become ur-illithid" -> "become ulitharid".
- **Workshop task order sorted**: implant, devour-prisoner, devour-sentient, reclaim,
  extract, ascend, resonate (reordered PERMITTED_REACTION in the entity, which drives
  the in-workshop menu order). All reaction NAMEs recapitalized/clarified.
- **Brain item reads "preserved ulitharid brain"** (no "iron" prefix): repurposed the
  orphaned UR_BRAIN material (STONE_TEMPLATE, adj "preserved ulitharid") as the tool's
  material and set the tool NAME to "brain". Extract now mints it from that material.
- **Ascend consumes the brain item as its reagent**: the reaction reagent (preserved
  ulitharid brain tool + adamantine thread) is hauled and consumed natively. on_ascend
  still prefers to REVIVE an actual dead ulitharid and transform it into an Elder Brain
  (preserving that specific creature + histfig); it only mints a fresh Elder Brain when
  no dead ulitharid exists.
- **Caged-prisoner detection fixed**: caged units are often dropped from units.active,
  so find_prisoner now scans CAGE items for their contained unit (with an active-list
  fallback). This is why implant / devour-prisoner couldn't find caged sentients.

## v0.28 — Neural Bath fixes (reclaim XP / ascend art / brain item)
- **add_xp leveling fixed**: the new-skill branch no longer skips the level-up loop,
  and every XP grant now re-runs apply_levels(u). Reclaiming a lost illithid (+1000 xp)
  now actually raises the skill rating and can trigger a psi level-up, matching how
  naturally-earned XP behaves.
- **Ascend/promotion now changes body & art, not just descriptions**: set_caste applies
  a permanent CE_BODY_TRANSFORMATION (new HA_TF_CARRIER syndromes "become ur-illithid" /
  "become elder brain") *before* rewriting u.caste, so DF registers a real caste
  transition and rebuilds the body/graphics instead of skipping it as a no-op. Identity
  caches (u.caste, enemy.normal_race/caste, were_race/caste, soul.race/caste, histfig
  race/caste) are then set so the change sticks (no revert) and the nobles/labor screens
  update. This mirrors the succubus-corruption transform pattern.
- **Ur-illithid brain is now a real, non-rotting, inedible item**: extract produces
  ITEM_TOOL_HA_UR_BRAIN (a tool — tools never rot and can't be eaten) instead of a MEAT
  brain. Removed [EDIBLE_RAW] from the UR_BRAIN creature material for good measure.
- **Ascend now costs an ur-illithid brain, not illithid meat**: HA_ASCEND reagent changed
  to TOOL:ITEM_TOOL_HA_UR_BRAIN (+ adamantine thread). The brain is a genuine reaction
  reagent, so DF hauls it into the workshop and consumes it natively — no script-side
  item deletion for the ascend step.

## v0.26b
- Elder brain grayscale flash fixed properly: added ANIMATED (same LARGE_IMAGE as
  DEFAULT). With DEFAULT only, DF alternates to the creature-level mb art for the
  animated frame, which the brain-body cannot render -> placeholder flicker. The
  v0.20 removal of ANIMATED was the wrong fix; both frames now hold the elder.

## v0.26
- **New job: devour a sentient prisoner** - devours a caged brain-bearing sentient
  directly (kill + gore, meat/fat, +1000 scholar xp, 20% ur-ascension), thralls barred.
- **Thralls excluded from reclaim & resonate XP** (they still get resonate happiness).
- Confirmed (post-snapshot-fix): devour rejects non-sentient corpses (CAN_LEARN
  check), thralls cannot devour, resonate is elder-only. The earlier no-XP symptom
  was the whole script not loading - installed_mods snapshot had been wiped; the
  script/dispatcher (onJobCompleted + worker tracking) is the orc-proven path.

## v0.25
- Restored the Neural Bath graphics wiring (graphics_ha_illithid_buildings.txt +
  tile_page) - the .txt files were collateral of an earlier graphics-folder wipe
  while the neural_bath.png image survived, so the bath had lost its custom art.
  Rebuilt in the proven orc-pit format (4-stage, 1-based rows).

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

## v0.29
- Banditry 10 -> 40, added `[LOCAL_BANDITRY]` (single-token change atop the v0.28 caste/art work; nothing else altered).

## v0.46
- Graphics: removed the `ANIMATED` frame from the elder-brain large sprite (it pointed at the same single frame, causing the grayscale flicker); static `DEFAULT` LARGE_IMAGE only, matching vanilla single-frame large creatures.
