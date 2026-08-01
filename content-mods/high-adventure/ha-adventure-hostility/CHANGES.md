# High Adventure - Adventure Hostility -- change log

A DFHack behavior component for the High Adventure suite. No raws (no creatures,
items, or entity) -- it ships a single overlay script,
`scripts_modactive/high-adventure/adventure-hostility.lua`, auto-discovered on
world load.

## v0.18 -- town ethics decide who fights; illithid thralls get a kit

- **Doctrine is territorial now, not racial.** Standing in a settlement, a creature follows
  the ethics of the TOWN rather than of its own race. A kobold farmer or an elf living
  among orcs comes at you alongside them; an orc in a human town is used to being around
  people and leaves you be. This replaces the old "guest" exemption, which asked whether
  your *citizenship* matched the site and so exempted permanent residents whose birth civ
  differs -- the kobold that prompted this lives in the orc town it was being spared in
  (`HOME_SITE_REALIZATION_BUILDING` -> the same site as the orcs beside it).
- Wilderness, ground nobody owns (ruins, lairs, bandit camps) and towns whose owning race
  has no rule of its own all read the same way: no local law, everyone falls back on their
  racial rule. An unruled town is just wilderness with buildings.
- **Temperament stays racial.** NOFEAR and the Pacify threshold are still keyed to what a
  creature actually is -- a kobold conscripted into orc doctrine is still a kobold. NOFEAR
  could not be territorial in any case: it is a caste-level raw flag written per race for
  the whole world at once.
- Conquered sites resolve to the CURRENT holder, not the founding civ -- 27 of 251 owned
  sites in the test world have a current owner of a different race from their founder.
- Invading armies keep their own doctrine anywhere, and members of the adventurer's own
  civilization are still never made hostile.
- **Added a sapience gate.** The race lists used to double as an "is this a person" filter,
  since a rule only ever matched its own races. Reading doctrine off the ground removes
  that, and the site government owns the livestock -- without the gate every horse and pack
  animal in a hostile town would have been conscripted into its war.
- **war-gear: illithid THRALLS are now equipped** (20% bronze weapon and no armor, 30%
  copper armor and weapon, 20% copper armor with a bronze weapon, 20% bronze armor and
  weapon, 10% steel). The mind flayer castes are listed but skipped -- they forge armor for
  their thralls and for trade but never wear it, and the ha-illithids stripping pass
  already exempts thralls.

## v0.17 -- kobolds are brave only under a dragon

- **Kobolds now get NOFEAR, but only while one of their ancient-dragon overlords is on
  screen.** `[CREATURE:HA_KOBOLD]` is `[BENIGN]` in the raws (inherited from Cute Kobold
  Caverns; vanilla kobolds are not), which per the token means it "will run away from any
  creature that is not friendly to it, and will only defend itself if it becomes enraged".
  Every other BENIGN race in the suite -- drow, dark dwarves, high elves -- was handed a
  flat NOFEAR that cancels the fleeing half, so kobolds were the one faction the mod made
  hostile and then left unable to fight back. They now hold the line under an overlord's
  eye and break without one, which is the intended flavour rather than a flat fix.
- The dragon's presence was already the signal that raises their Pacify bar from 1 to 12,
  so the two behaviours are one rule now: dragon on screen means fearless and hard to talk
  down; no dragon means cowardly and trivially pacified.
- **Fixed: no dragon had counted as a dragon since ha-kobolds 0.17.** `is_dragon_caste`
  tested for a caste literally named `ANCIENT_DRAGON`, but that caste was split into six
  (`DRAGON_H1_SPIKE` ... `DRAGON_H3_CLUB`), so it matched nothing and every dragon-gated
  rule -- the Pacify escalation and the kobold half of the dragon challenge -- was dead.
  Detection now matches `CREATURE_CLASS:HA_DRAGON_RULER`, the same token the raws use to
  gate the Dread Wyrm throne, so it survives further caste renames; the old caste name is
  still accepted for worlds baked before the split.
- `set_nofear` can now withdraw the flag as well as set it, and restores what the RAWS said
  instead of writing false -- the kobolds' own dragon castes carry `[NOFEAR]`, and clearing
  it blindly would have left the dragons themselves breakable for the rest of the session.
- The embolden signal is read for every rule, not just rules hostile to this adventurer, so
  it still applies during a dragon challenge -- where the kobold rule is skipped as friendly
  (a dragon adventurer is one of their own) yet the rival dragon's retinue still fights.

## v0.16 -- sheathe your weapon and talk your way past

- **A skilled Pacifier who has not drawn a weapon is no longer attacked at all.** Previously
  the only use for Pacify was keeping an enemy yielded *after* you had beaten them down; now
  meeting a race's threshold with no weapon in hand means they never turn on you in the first
  place. Drawing steel lapses the exemption on that same turn.
- "Weapon drawn" is a real weapon in the Weapon inventory role. A weapon stowed in a pack does
  not count, and a shield rides in the same role without being a weapon, so the item type is
  checked too.
- **Militant good (high elves, dwarves) no longer fight to the death regardless.** Their
  threshold was NO_YIELD (999), i.e. unreachable; it is now 6, like the other hardened civs.
  They still carry NOFEAR, so they never break -- they simply are not hostile to a sheathed
  Pacify-6 adventurer.
- A dragon challenge is never called off below Pacify 12, whatever the challenger's own race
  would otherwise ask for.

## v0.15 -- no duplicate boots/gauntlets from stacked footwear
- 0.14 let PAIRED slots promote every piece, which is right for two gloves but wrong
  for socks+shoes: both live in item_type.SHOES, so a unit wearing socks and shoes on
  both feet offered FOUR candidates and would have come out in four boots.
- Paired slots now promote at most one piece PER BODY PART, with MAX_PER_PAIRED_SLOT
  (2) as a backstop in case body_part_id is not usable. Candidates are sorted so an
  UNDERLAYER (socks, chausses, mittens) is only promoted when nothing else covers that
  part -- the sock stays a sock underneath the new boot.

## v0.14 -- paired slots promote both pieces; handedness self-repairs
- The one-promotion-per-slot guard added in 0.12 was wrong for PAIRED slots: a unit
  came out wearing one gauntlet and one ordinary glove. Gloves and shoes now promote
  every piece; the guard still applies to body slots so a shirt+tunic does not become
  two breastplates.
- Added a handedness repair pass. Minted gauntlets default to RIGHT, so a pair could
  end up both right-handed -- which is also the legacy damage left by every version
  before 0.13, where handedness was never carried at all. If a unit's two hand pieces
  agree, the second is flipped.

## v0.13 -- gauntlet handedness actually works; quiver crash fixed
- HANDEDNESS was never being carried across. `handedness` is a BitArray FIELD, so
  `newit.handedness = old.handedness` copied a reference and did nothing -- and it sat
  inside a pcall, so the failure was silent. That is the real cause of the 'two right
  gauntlets' the old high-elf code complained about. Now uses the accessors,
  getGloveHandedness/setGloveHandedness (1 = right, 2 = left).
- CRASH: `it.subtype` is not present on every item class -- item_quiverst has no such
  field -- so reading it unguarded threw as soon as a unit carried a quiver. The read
  is now guarded. It had been masked by a pcall around the whole pass until the plan
  step moved outside it.

## v0.12 -- leather cloaks, helms for bare heads, and a double-promotion fix
- A leather outfit now also issues a leather CLOAK.
- A unit with nothing at all on its head gets a helm 40% of the time. Restricted to
  outfits that armor: a "weapon only" outfit means only a weapon. ITEM_HELM_HELM
  carries both [LEATHER] and [METAL] so it is legal in either material.
- BUG FOUND while adding the cloak: cloaks and capes share item_type.ARMOR with
  tunics and shirts, so a unit wearing both a tunic and a cloak was getting TWO
  breastplates and losing the cloak. Outerwear is now never promoted, only re-made in
  the outfit's material, and at most ONE piece per slot is ever promoted.

## v0.11 -- war-gear becomes a weighted OUTFIT roll per race
- Replaces the single-metal-per-race model. Each race has a weighted list of outfits
  (metal, whether clothing is promoted to armor, which weapon), rolled once per unit.
  Dwarves/dark dwarves 40/30/15/15 copper-weapon-only / copper / bronze / iron;
  orcs 30/30/20/20; goblins 40/15/15/15/15; humans 50% UNTOUCHED / 35 / 15.
- Weapons now come from the unit's OWN CIV weapon list, whose REPEATS encode the
  civ's preference ratio, instead of a hardcoded pick. Drow therefore still favour
  scimitars (their entity lists SCIMITAR x10) but bows, pikes and whips now appear.
  A scimitar roll mints a PAIR. Training weapons are filtered out.
- Leather outfits armor the TORSO only: ITEM_ARMOR_LEATHER is [LEATHER] with no
  [METAL] and there is no leather greave or gauntlet, so other slots stay clothing
  rather than becoming impossible items.
- Illithids, succubi, kobolds and vanilla elves are deliberately absent from the
  table and are never processed.

## v0.10 -- war-gear: children never armored or armed
- Across every civ, a unit that is not an adult keeps clothing as clothing and gets
  no minted weapon. Material upgrades still apply, so an elf child is rewoven in
  twinkling fabric rather than left in rags -- the exemption is from ARMOR and ARMS,
  not from the whole pass.

## v0.9 -- war-gear: clothing promoted to armor, weapons minted, drow females in GCS silk
- Dwarves, dark dwarves and drow now have their CLOTHING replaced by the ARMOR piece
  for that slot rather than by better cloth: tunic -> breastplate, skirt -> greaves,
  hood -> helm, gloves -> gauntlets, socks -> boots. High elves are exempt and keep
  clothing as clothing in twinkling fabric.
- Unarmed units get weapons minted from their own civ's entity raws. Drow get TWIN
  scimitars -- their entity lists SCIMITAR ten times against one each of everything
  else, so that is the civ's own preference. Dwarves and dark dwarves draw from the
  MOUNTAIN list (battle axe, short sword, war hammer, mace, spear).
- Minting is GATED ON MASTERWORK: a unit already carrying any masterwork or artifact
  piece is left to it. Per-item masterwork protection is unchanged.
- Drow FEMALE caste is no longer skipped -- it now has its own caste override: no
  armor, no weapons, clothing re-made in giant cave spider silk. Castes can override
  any field of their race's policy.

## v0.8 -- war-gear allowlist gaps: skirts, veils, capes, chausses
- A high-elf clothier kept a rope reed SKIRT while her tunic, gloves and socks all
  became twinkling fabric: ITEM_PANTS_SKIRT was simply missing from ALLOW_FABRIC.
  Checked the full itemdef list in a loaded world and added every other gap too --
  SKIRT / SKIRT_SHORT / SKIRT_LONG / THONG, ARMOR_CAPE, SHOES_CHAUSSE, and the head
  coverings TURBAN / MASK / VEIL_HEAD / VEIL_FACE / SCARF_HEAD.
- ITEM_PANTS_LEGGINGS moved to ALLOW_METAL: its itemdef carries [METAL] and it is
  armorlevel 1, so it is armor, not clothing.
- ITEM_ARMOR_LEATHER dropped from both lists: [LEATHER] with neither [SOFT] nor
  [METAL], so it can legally be made of neither fabric nor metal.

## v0.7 -- absorbs the shared war-gear engine
- New script `high-adventure/war-gear`: one re-gear engine for the whole suite,
  replacing the duplicated copies that lived in ha-high-elves and ha-drow.
  High elves -> twinkling metal + twinkling fabric; drow -> DRIDER always steel,
  MALE 20% steel / 80% iron, FEMALE untouched; dark dwarves and VANILLA DWARVES
  -> iron or bronze.
- UPGRADES ONLY: a piece is replaced only when its current material ranks below
  the metal rolled for that unit, so steel survives an iron-or-bronze policy and
  a drow male who rolls iron keeps steel he already had. Rank is the material's
  SHEAR yield read from the raws, not a hardcoded list, so modded metals slot in
  by their own numbers. Bronze (172000) out-ranks iron (155000), which is why
  'iron and bronze' behaves as one tier.
- Never touches a masterwork or artifact. Never edits an item's material in place
  (that can make impossible item/material combos) -- it mints a replacement at the
  same quality and swaps it in. Never fills an empty slot.
- Affects historical figures; never the adventurer, never fortress citizens.
- Deliberately a SEPARATE script from adventure-hostility.lua: that one is an
  adventure-only overlay, and this has to run in fortress mode too.

## v0.6 -- hostility is site-scoped: guests in a town leave you alone
- While the adventurer stands inside a settlement, only that settlement's OWN
  people can be forced hostile. Anyone else there is a guest and is skipped --
  fixing a drow merchant who attacked on sight in a high elf town the moment the
  player joined it.
- Ownership is read from the site under the adventurer (same world-tile
  arithmetic `adv/fear-no-goblin` uses). BOTH of the site's ids count as "local":
  residents carry the site government id (`cur_owner_id`) while citizens and
  adventurers of the owning civ carry the parent `civ_id` -- measured live in a
  high elf town whose locals were civ 32 and whose adventurer was civ 31.
- Invaders are exempt: a siege is not a social visit, so `active_invader` /
  `invader_origin` / `marauder` units still attack inside anyone's walls. Visiting
  NPCs carry NO merchant/diplomat/visitor flag at all (the drow merchant had every
  one clear), which is why ownership rather than flags is the discriminator.
- Out in the wilderness nothing changes -- the faction rules apply in full, so
  travel stays as dangerous as before.

## v0.5 -- passive "in conflict" units actually fight now
- `make_hostile` re-asserts conflict_level 5 (fighting) in both directions on
  every sweep. Previously level 5 was only set when the script CREATED a
  conflict: units added to an existing event inherited its stale level, and DF
  decays levels over time -- either way targets ended up "in conflict" at
  level 0 and stood around peacefully (observed: six HA_KOBOLDs sharing the
  adventurer's conflict, all passive).

## v0.4 -- own-civ members never attack the adventurer
- Civ membership now beats race: units sharing the adventurer's `civ_id` are
  never force-hostiled. Previously the rules matched on creature race only, so
  e.g. a dwarf adventurer born/raised in a drow civilization was attacked on
  sight by their own people. Other civs of the same hostile race still attack.
- The dragon challenge is deliberately exempt: rival ancient dragons (and the
  kobolds standing with them) still turn on a dragon adventurer within one civ.

## v0.3 -- militant good (high elves + dwarves); kobolds are evil
- Kobolds (`HA_KOBOLD`) are now part of the EVIL set, so the good factions treat a
  kobold adventurer as an enemy. The evil set is now orc, kobold, goblin, succubus,
  dark dwarf, drow and mind flayer.
- New "militant good" faction: high elves (`HA_HIGH_ELF`) and dwarves (`DWARF`) are
  hostile to any EVIL adventurer -- same target set as the plain good civs -- but
  they NEVER break (NOFEAR) and NEVER yield (unreachable Pacify threshold), unlike
  the weaker good civs.
- `DWARF` moved from the yielding "good civs" group into "militant good"; the good
  civs are now just `HUMAN` and `ELF`.

## v0.2 -- kobold civ + dragon overlords
- The kobold civ is now a hostile faction: `HA_KOBOLD` (which includes its dragon
  overlords, the `ANCIENT_DRAGON` caste of the same creature) is hostile to any
  adventurer who is not a kobold.
- Special pacify thresholds for kobolds: a plain kobold's surrender sticks at Pacify
  1, but rises to 12 while one of their ancient-dragon overlords is on screen; a
  dragon overlord itself always needs Pacify 12.
- The standalone `HA_ANCIENT_DRAGON` MEGABEAST (a different creature) is deliberately
  left out -- only the civ kobolds and their overlords are affected.

## v0.1
- Adventure-mode overlay that forces designated civs hostile to the adventurer by
  injecting nearby members into a Conflict activity opposing the player (creating
  one on-sight if needed) -- targeted at the player only, so they never berserk
  their own immigrants (unlike a raw `[CRAZED]`).
- Per-turn de-yield (`flags3.adv_yield`) gated on the adventurer's Pacify skill vs
  a per-race threshold: Goblin 1, Orc 3, Drow/Succubus/Dark Dwarf 6, Mind Flayer 12.
- Sets `[NOFEAR]` (session-only) on the always-hostile evil civs; good civs keep
  fear (can flee/yield).
- Config: `RULES` (loners / evil_bloc / good_civs) + `PACIFY_THRESHOLD`. Races
  absent from the loaded world are ignored.
