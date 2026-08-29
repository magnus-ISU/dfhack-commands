# HA — Ancient Golems

Ancient iron constructs holding a handful of forest retreats. They start where
elves start and compete for the same groves, but each civ founds exactly **one**
site and never founds another.

## Fighting one

- **The head is a decoy.** No brain, no skull, no organs. Severing the neck or
  crushing the head accomplishes nothing.
- **The golden heart is the kill.** A `THOUGHT` part in the upper body, `INTERNAL`
  — you have to break the iron torso open before you can reach it, and destroying
  it drops the golem instantly.
- **The glass hand is the opening.** The left hand carries a fragile glass
  flamethrower. Shatter it and the flame is gone for the rest of the fight.
- Legendary+5 in every combat skill **except dodging**, which sits at
  Professional. Footwork is how you beat one.

Iron body, no blood, no pain, no fear, no fatigue. They do not eat, drink or
sleep, and being `FIREIMMUNE_SUPER` they are untouched by their own fire.

## Why they stay put

Placement is the `ha-high-elves` layout: `EXCLUSIVE_START_BIOME` with **no**
`SETTLEMENT_BIOME` and **no** `START_BIOME`. Those two tokens, not
`BIOME_SUPPORT`, are what grant a civ the right to build more sites.
`BIOME_SUPPORT` stays only because worldgen rejects a world with none.

Since one civ equals one grove, **`MAX_STARTING_CIV_NUMBER` is the "how many
groves exist" dial** (currently 6).

## Why they stay quiet

`WANDERER`, `BEAST_HUNTER`, `SCOUT` and `MERCENARY` are the four tokens that send
members out as roaming historical figures — all absent, which is how vanilla
kobolds stay out of everyone's history. `NO_ARTIFACT_CLAIMS` keeps them out of
artifact quests, and they carry none of `SIEGER`, `AMBUSHER`, `BABYSNATCHER`,
`ITEM_THIEF` or `LOCAL_BANDITRY`.

Two things no token can prevent: they will still hold professions, and they can
still be dragged into wars.

## Playing them

`ALL_MAIN_POPS_CONTROLLABLE` + `SITE_CONTROLLABLE` on the entity,
`OUTSIDER_CONTROLLABLE` on the creature. They wear no armour and no clothing —
their bodies are their armour — but the entity keeps weapons and tools so a fort
can dig, fell and fight. No `ACTIVE_SEASON`, so they send no caravans.

See `CHANGES.md` for the list of what is still unverified.
