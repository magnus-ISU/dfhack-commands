# High Adventure — open work

Testing debt and wanted features. Items marked **[user]** came from the running list;
the rest fell out of worldgen sessions and code reading and are proposals, not decisions.

## Untested — adventure mode

- [ ] **Aggro / yielding not fully tested.** `ha-adventure-hostility` makes civs attack on
      sight; the yield path (Pacify 12 to call them off, ancient dragons and nearby kobolds
      aggroing on a rival dragon adventurer) has never been exercised end to end. **[user]**
- [ ] **Replacing high elf gear as an adventurer is untested** — whether twinkling-metal
      kit can be swapped, dropped and re-equipped without breaking. **[user]**
- [ ] **Drow adventure mode untested** entirely. **[user]**
- [ ] **Illithid psionics in adventure mode.** Ten `HA_PSI_*` interactions exist; none have
      been fired from an adventurer. **[user]**
- [x] ~~Second-humans civ inherits hostility behaviour.~~ **Resolved by inspection:**
      `adventure-hostility.lua` matches on *creature race*, never on entity code, and
      `HA_PLAINS_ALT` uses the vanilla `HUMAN` creature — so it falls under the existing
      `good_civs` rule exactly as vanilla humans do. No change needed.

## Untested — sieges and war

- [ ] **Do high elves even siege?** Never observed. They launched 202 war actions in a
      100-year world but took only one site, so the siege path specifically is unverified.
      **[user]**
- [ ] **Drow sieges untested.** They also have `MAX_SITE_POP_NUMBER:500`, which historically
      is what made their sieges outsized — worth checking the size is still sane. **[user]**
- [ ] Orc siege behaviour after the biome changes (they no longer border everyone).

## Untested — fortress mode

- [ ] **Caravan trading.** Evil-bloc timing in particular: dark dwarves winter, succubi
      summer, goblins single autumn caravan. **[user]**
- [ ] **Drider armor** — a drow torso on a giant-spider body; check what actually equips.
      **[user]**
- [ ] **Illithid armor — the raws and the description disagree, pick one.** `info.txt` says
      illithids are *"unable to wear armor but robed and terrible"*, but
      `entity_ha_illithid.txt` grants `ITEM_ARMOR_BREASTPLATE`, `ITEM_ARMOR_MAIL_SHIRT`,
      `ITEM_ARMOR_LEATHER`, `ITEM_GLOVES_GAUNTLETS`, `ITEM_PANTS_GREAVES` and both shields,
      and the creature carries `[EQUIPS]`. Either the description is stale or the armour
      tokens were never removed. **[user]**
- [ ] **Kobold ancient-dragon armor — confirm they CANNOT wear it.** Sizes say it is safe:
      an adult kobold is `BODY_SIZE 20,000`, an adult dragon caste 5,000,000 at age 10 and
      25,000,000 at 1000 — 250x to 1250x, far outside any DF fit tolerance. Low risk, but
      still worth one in-game look. **[user]**
- [ ] High elf Shaping Tree end to end: `HA_CATCH_STARLIGHT` success/cooldown, twinkling bar
      forging, wood and feather growing.
- [ ] Illithid Neural Bath: devour brain, devour prisoner, ascension, tadpole implant,
      Elder Brain coalescence. Devouring/implanting *synthetic* caged units has crashed DF
      before — use siege-captured prisoners.
- [ ] Succubi magma well, summoning and corruption workshops.
- [ ] Orc breeding pit (`HA_BREED_ORC`).
- [ ] Kobold Dread Wyrm succession — does the eldest ancient dragon actually take the throne,
      and what happens when none exists.

## Wanted features

- [ ] **Let elves and high elves move trees around.** A relocate-tree tool, presumably a
      DFHack script living in the mod that owns it rather than a standalone command. **[user]**

## Worldgen balance — open questions

- [ ] **Castles never appear for high elves or succubi** despite both carrying
      `BUILDS_OUTDOOR_FORTIFICATIONS` and land-holding nobles. Humans built 78 per civ in the
      same world. Suspicion: castles grow from mead halls, and a civ pinned to one town per
      civ never gets one. Unproven.
- [ ] **Dwarves fell to a single civilization** once the second human entity was added — the
      total civ budget (`total_civ_number`, 80 at max) is fixed, so extra human civs come out
      of everyone else. Consider raising it in detailed worldgen.
- [ ] **Nothing in the suite uses the ocean**, which is ~48% of every map. Highfantasy fields
      three aquatic civs there. Largest unclaimed niche available.
- [ ] **Dark dwarves leak off the mountains — confirmed.** They still carry the wide list the
      drow had (mountain + forest + grassland + savanna + shrubland) and in the last world
      placed 33 sites on grassland against 13 in the mountains. The drow fix was
      `SETTLEMENT_BIOME`/`BIOME_SUPPORT` limited to mountain and forest; the same edit applies
      here if that behaviour is unwanted.
- [ ] **No working necromancy lever.** Deliberate raw changes moved counts far less than the
      seed did. `worldgen_parms.secret_number` (default 28) is the untried candidate.
- [ ] **Ancient dragons still end a century at 1–2 of 3–4.** Better than the total wipeout
      before the growth curve was fixed, but they are not a lasting world threat.
- [ ] **Elder brains decline even when illithids are healthy.** Cause unknown.
- [ ] Small worlds (33x33) spawn **no megabeasts at all** and nearly killed goblins and
      illithids. If small worlds are a supported way to play, they need their own tuning.

## Code / raws hygiene

- [ ] `Unrecognized tile: WORKSHOP_CUSTOM` fires on 40 of the 120 shaping-tree graphics
      lines in each buildings file, yet the art renders correctly. Harmless, but unexplained.
- [x] ~~Gibberling `CLAW` attack after the body fix.~~ **Resolved by inspection:** claws are
      attached with `[TISSUE_LAYER:BY_CATEGORY:TOE:CLAW:FRONT]`, and the replacement body
      supplies `5TOES`, so the TOE category still exists. A clean errorlog after the fix
      confirms it.
- [ ] `mythical_site_num` (mysterious lairs/dungeons/palaces, default 50) can only be changed
      through detailed worldgen — the basic screen rebuilds the params on Create world. If
      more of those sites are wanted, that is the route.
- [ ] Re-run `ha-second-humans/sync_from_vanilla.py` after any DF update so the duplicate
      human entity tracks changes to vanilla `PLAINS`.
