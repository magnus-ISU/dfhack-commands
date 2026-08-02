--@module = true
--@enable = true
--[====[
high-adventure/war-gear
=======================

Tags: fort | adventure | gameplay

One re-gear engine for the whole suite. Worldgen spreads a civ's equipment across
every metal it knows, so most members of any civ spawn in copper, silver or tin no
matter how martial the civ is meant to be. This upgrades them.

Lives here, in the hostility mod, because it is the same job for every race and was
previously duplicated in ha-high-elves and ha-drow. Those scripts keep their own
unique work (the shaping tree; the goblin war-slave kit) and no longer carry gear
code. It is a SEPARATE script from adventure-hostility.lua on purpose: that one is
an adventure-only overlay, and this has to run in fortress mode too.

Who gets what -- OUTFITS below is a weighted roll, made ONCE per unit and remembered:

    DWARF / HA_DARK_DWARF   40% copper pick|axe|spear, no armor
                            30% copper armor + weapon
                            15% bronze armor + weapon
                            15% iron armor + weapon
    HA_ORC                  30% copper weapon (civ list), no armor
                            30% leather armor + copper weapon
                            20% copper armor + weapon
                            20% iron armor + weapon
    GOBLIN                  40% copper weapon (civ list), no armor
                            15% leather armor + copper weapon
                            15% copper armor + weapon
                            15% bronze armor + weapon
                            15% iron armor + weapon
    HUMAN                   50% untouched
                            35% copper pick|axe|spear, no armor
                            15% iron armor + weapon
    HA_DROW  MALE           80% iron, 20% steel -- armor + weapon
             DRIDER         always steel
             FEMALE         giant cave spider silk clothing, no armor, no weapon
    HA_HIGH_ELF     1/6     full twinkling armor + twinkling weapon
                    1/6     full steel armor + twinkling weapon
                    1/6     grown WOODEN armor + steel weapon
                    1/6     cloak or robe, twinkling fabric clothes, twinkling weapon
                    1/6     twinkling fabric clothes, no cloak, UNARMED
                    1/6     giant cave spider silk clothes, no cloak, UNARMED
              women always wear a skirt or dress, men never do (`gendered`)
              FORTRESS MODE: a besieging elf army ignores the table above and is always
              armored, an even split of steel and twinkling (`siege`). Visitors and
              residents still take the ordinary roll, so a diplomat arrives robed.
    HA_ILLITHID  THRALL_M   20% bronze weapon, no armor
                 THRALL_F   30% copper armor + copper weapon
                            20% copper armor + bronze weapon
                            20% bronze armor + bronze weapon
                            10% steel armor + weapon
             every other caste (illithid, ulitharid, elder brain) left alone

UNTOUCHED, deliberately absent from the table: succubi, kobolds, vanilla elves. A race
not listed is never processed. Mind flayers themselves are listed but skipped: only
their THRALLS carry gear -- illithids forge armor for them and for trade but never wear
it, and ha-illithids strips any that reaches one (that pass already exempts thralls).

WEAPONS come from the unit's OWN CIV list unless the outfit names one. That list has
REPEATS and the repeats are the civ's preference ratio -- the drow entity lists
SCIMITAR ten times against one each of bow, pike, whip and the rest, so scimitars
dominate for drow without being forced and the other choices still come up. Training
weapons are filtered out of civ lists.

HOW MANY, and whether a shield comes too, depends on whether the unit's civ fields
shields at all:
  * civ WITH shields -- 50% one weapon, 25% two weapons, 25% one weapon and a shield.
    The shield subtype is one the civ actually lists (shield or buckler); it is wooden
    90% of the time and metal otherwise. Elves carry their own grown wood; every other
    race uses whatever wood the world has.
  * civ WITHOUT shields (the drow field none) -- the older rule stands: a roll that
    lands on a scimitar mints a PAIR, anything else mints one.
No unit is ever left holding more than MAX_WEAPONS (2), whatever the roll says.

ADDED PIECES -- the swap pass only ever replaces something already worn, but two cases
deliberately mint into an EMPTY slot:
  * a `leather` outfit issues a leather CLOAK (if the unit had no cloak or cape to
    re-make in leather);
  * a unit with NOTHING on its head -- no helm, cap, hood or veil -- gets a helm. An
    outfit that ARMORS issues one 80% of the time in its armor material; an outfit that
    carries only a WEAPON issues one 40% of the time in the weapon's own metal. A FABRIC
    outfit issues none (a cloth helm is not a legal item), and children get neither,
    since run() strips armor and weapon off them first.
  * a minted RANGED weapon comes with a leather quiver holding 10 rounds of whatever it
    actually fires -- arrows for a bow, bolts for a crossbow, darts for a blowgun, and
    bullets for the kobold sling. The pairing is read from the raws (weapon `ranged_ammo`
    vs ammo `ammo_class`), so a modded ranged weapon needs no entry here. The subtype
    prefers the unit's OWN civ ammo list, so an elf gets elven arrows; heads are the
    outfit's weapon metal. Only when this script mints the weapon -- a unit that already
    had one is left alone, along with whatever it was carrying.
  * `outer` on an outfit forces the cloak question: true mints a cloak or robe if the unit
    has none, false strips any cloak, cape or robe it has. Absent = leave it alone.

OUTERWEAR: cloaks and capes share item_type.ARMOR with tunics and shirts, so they are
never promoted -- otherwise someone in a tunic AND a cloak ends up in two breastplates
with the cloak gone. They are re-made in the outfit's material instead. For the same
reason only ONE piece per slot is ever promoted.

CLOTHING -> ARMOR: an outfit with `armor` promotes cloth to the armor piece for that
slot (tunic -> breastplate, skirt -> greaves, hood -> helm, gloves -> gauntlets,
socks -> boots). A `leather` outfit armors only the TORSO, in ITEM_ARMOR_LEATHER --
there is no leather greave or gauntlet, so the other slots stay clothing rather than
becoming impossible items. High elves and drow females instead keep clothing as
clothing, re-made in their `fabric`.

RULES THAT APPLY TO EVERY RACE
------------------------------

- **Upgrades only.** A piece is replaced only if its current material ranks BELOW
  the metal rolled for that unit. Steel is therefore never touched by an iron-or-
  bronze policy, and a drow male who rolls iron keeps steel he already had.
  Ranking is the material's SHEAR yield, read from the raws rather than hardcoded,
  so modded metals slot in by their own numbers:
      copper 70000 < silver 100000 < iron 155000 < bronze 172000 < steel 430000
      < twinkling 1000000 < adamantine 5000000
  Note bronze out-ranks iron on this measure, which is why "iron and bronze" works
  as a single tier: bronze gear already counts as good enough and is left alone.
- **Never a masterwork.** Masterwork and artifact pieces (quality >= Masterful) are
  left untouched whatever their material.
- **Never edits an item's material in place.** That can produce impossible
  item/material combinations. It generates a fresh item of the same type and
  subtype in the target metal, copies the old quality across, swaps it in, and
  removes the original.
- **Children are never armored or armed**, in any civ. They still get material
  upgrades, so an elf child is rewoven in twinkling fabric instead of being left in
  rags -- but a cloth item stays a cloth item and no weapon is minted.
- **Masterwork gates the minting.** A unit with ANY masterwork or artifact piece
  equipped is never handed fresh weapons -- they are left to what they have. Per
  item, a masterwork is never replaced either, whatever its material.
- **Empty ARMOR slots are never filled** -- this does not conjure a breastplate onto
  someone wearing nothing. Weapons are the deliberate exception: an unarmed unit of a
  race with an `arms` list gets one (or two).
- **Historical figures ARE affected** -- named townsfolk, soldiers and children
  included. Requiring `hist_figure_id < 0` was the old high-elf behaviour and it
  silently excluded nearly everyone worth seeing.
- **Never the adventurer, never your fortress citizens.** In fort mode that leaves
  invaders and visitors; in adventure mode, everyone but the player.

Usage
-----

	enable high-adventure/war-gear
	disable high-adventure/war-gear
]====]

local repeatUtil = require('repeat-util')

local GLOBAL_KEY = 'haWarGear'

local COPPER = 'INORGANIC:COPPER'
local BRONZE = 'INORGANIC:BRONZE'
local IRON   = 'INORGANIC:IRON'
local STEEL  = 'INORGANIC:STEEL'
local LEATHER  = 'CREATURE_MAT:COW:LEATHER'
local GCS_SILK = 'CREATURE_MAT:SPIDER_CAVE_GIANT:SILK'
local TWINKLING        = 'INORGANIC:HA_TWINKLING_METAL'
local TWINKLING_FABRIC = 'INORGANIC:HA_TWINKLING_FABRIC'
-- the high elves' own grown wood: their armour and their shields
local GROWN_WOOD       = 'PLANT_MAT:HA_HE_GROWN:WOOD'

-- the "miner's kit" weapon set, for outfits that name it explicitly
local PICK_AXE_SPEAR = {'ITEM_WEAPON_PICK', 'ITEM_WEAPON_AXE_BATTLE', 'ITEM_WEAPON_SPEAR'}
-- fallback when a unit has no civ to read a weapon list from
local DWARF_ARMS = {'ITEM_WEAPON_AXE_BATTLE', 'ITEM_WEAPON_SWORD_SHORT',
                    'ITEM_WEAPON_HAMMER_WAR', 'ITEM_WEAPON_MACE', 'ITEM_WEAPON_SPEAR'}

-- Which armor piece a CLOTH item in each slot becomes, for outfits with `armor`.
local ARMOR_FOR_SLOT = {
    [df.item_type.ARMOR]  = 'ITEM_ARMOR_BREASTPLATE',
    [df.item_type.PANTS]  = 'ITEM_PANTS_GREAVES',
    [df.item_type.HELM]   = 'ITEM_HELM_HELM',
    [df.item_type.GLOVES] = 'ITEM_GLOVES_GAUNTLETS',
    [df.item_type.SHOES]  = 'ITEM_SHOES_BOOTS',
}
-- LEATHER armor only exists for the body: ITEM_ARMOR_LEATHER is [LEATHER] with no
-- [METAL], and there is no leather greave/gauntlet. A leather outfit therefore
-- armors the torso and leaves the rest as clothing, rather than minting impossible
-- items for the other slots.
local LEATHER_FOR_SLOT = {[df.item_type.ARMOR] = 'ITEM_ARMOR_LEATHER'}

-- Outerwear: cloaks and capes live in item_type.ARMOR alongside tunics and shirts, so
-- they must NOT be promoted -- otherwise a unit wearing tunic AND cloak gets two
-- breastplates and loses the cloak. They stay outerwear and are only re-made in the
-- outfit's material.
local OUTERWEAR = {ITEM_ARMOR_CLOAK=true, ITEM_ARMOR_CAPE=true}
-- Slots worn as a PAIR. The one-promotion-per-slot guard must not apply to these, or
-- a unit ends up with one gauntlet and one glove still on the other hand.
local PAIRED_SLOT = {[df.item_type.GLOVES]=true, [df.item_type.SHOES]=true}
-- Underlayers: worn UNDER the real footwear/handwear on the same body part. Socks and
-- shoes both live in item_type.SHOES, so a unit in socks+shoes on both feet offers FOUR
-- promotion candidates -- promote them all and you get four boots. Only one piece per
-- body part is promoted, and an underlayer is only chosen if nothing else covers that
-- part, so the sock stays a sock under the new boot.
local UNDERLAYER = {ITEM_SHOES_SOCKS=true, ITEM_SHOES_CHAUSSE=true,
                    ITEM_GLOVES_MITTENS=true}
local MAX_PER_PAIRED_SLOT = 2   -- two feet, two hands: a hard backstop
-- a leather outfit also issues a cloak; chance of issuing a helm to a bare head.
-- An armouring outfit is generous about it; an outfit that carries only a weapon still
-- offers one, at a lower rate, in the weapon's own metal.
local HELM_CHANCE = 0.80
local WEAPON_ONLY_HELM_CHANCE = 0.40

-- Outerwear, for an outfit that declares `outer`. Wider than OUTERWEAR above: that set
-- exists to stop capes being PROMOTED into breastplates, whereas this one is "the garment
-- you wear over everything", which for an elf includes the robe.
local OUTER_GARMENT = {ITEM_ARMOR_CLOAK=true, ITEM_ARMOR_CAPE=true, ITEM_ARMOR_ROBE=true}
local OUTER_MINT = {'ITEM_ARMOR_CLOAK', 'ITEM_ARMOR_ROBE'}

-- Lower-body garments the `gendered` rule sorts on. A dress lives in item_type.ARMOR and
-- the skirts in item_type.PANTS, so both types have to be considered together.
local SKIRTLIKE = {ITEM_PANTS_SKIRT=true, ITEM_PANTS_SKIRT_SHORT=true,
                   ITEM_PANTS_SKIRT_LONG=true, ITEM_ARMOR_DRESS=true}
local WOMENS_MINT = {{df.item_type.PANTS, 'ITEM_PANTS_SKIRT'},
                     {df.item_type.ARMOR, 'ITEM_ARMOR_DRESS'}}
-- what a man gets instead, if stripping a skirt would have left him bare-legged
local MENS_PANTS = 'ITEM_PANTS_PANTS'

-- ammo issued alongside a minted bow
local ARROWS_PER_QUIVER = 10

-- How a race that carries shields arms itself. Rolled once per unit, in this order:
-- one weapon / two weapons / a weapon and a shield. A race whose entity lists NO shield
-- (the drow field none) skips this entirely and keeps the older rule, where a scimitar
-- comes as a pair and everything else is single.
local ARMING = {{w=50, weapons=1}, {w=25, weapons=2}, {w=25, weapons=1, shield=true}}
local MAX_WEAPONS = 2               -- hard ceiling, whatever the roll says
local SHIELD_WOOD_CHANCE = 0.90     -- otherwise metal

-- OUTFITS: a weighted roll per unit, made once and then remembered.
--   w       relative weight
--   weapon  metal for a minted weapon (nil = mint nothing)
--   armor   metal for armor; clothing in an armored slot is PROMOTED to armor.
--           nil = leave worn items alone entirely
--   leather true = armor the torso in ITEM_ARMOR_LEATHER instead of metal
--   arms    explicit weapon list; nil = draw from the unit's OWN CIV list, which
--           reproduces that civ's preferences by repetition (the drow entity lists
--           SCIMITAR ten times against one each of the rest, so scimitars dominate
--           without being forced -- and the other choices still come up)
--   pair    mint two (only used when the roll lands on a scimitar; see mint_arms)
--   fabric  re-make CLOTHING in this material and do NOT promote it to armor
--   skip    true = this unit is left completely alone
-- A race absent from this table is untouched: succubi, kobolds and vanilla elves are
-- deliberately not listed.

-- The illithids' human-bodied THRALL castes are the civ's soldiery and the only members
-- of that civ who carry gear -- their masters forge armor but never wear it. Shared by
-- both thrall castes; the mind flayer castes fall through to the skip entry below.
local THRALL_KIT = {
    {w=20, weapon=BRONZE},                        -- weapon only, no armor
    {w=30, weapon=COPPER, armor=COPPER},
    {w=20, weapon=BRONZE, armor=COPPER},
    {w=20, weapon=BRONZE, armor=BRONZE},
    {w=10, weapon=STEEL,  armor=STEEL},
}

local OUTFITS = {
    DWARF = {
        {w=40, weapon=COPPER, arms=PICK_AXE_SPEAR},   -- weapon only, no armor
        {w=30, weapon=COPPER, armor=COPPER},
        {w=15, weapon=BRONZE, armor=BRONZE},
        {w=15, weapon=IRON,   armor=IRON},
    },
    HA_ORC = {
        {w=30, weapon=COPPER},                        -- civ weapon, no armor
        {w=30, weapon=COPPER, armor=LEATHER, leather=true},
        {w=20, weapon=COPPER, armor=COPPER},
        {w=20, weapon=IRON,   armor=IRON},
    },
    GOBLIN = {
        {w=40, weapon=COPPER},
        {w=15, weapon=COPPER, armor=LEATHER, leather=true},
        {w=15, weapon=COPPER, armor=COPPER},
        {w=15, weapon=BRONZE, armor=BRONZE},
        {w=15, weapon=IRON,   armor=IRON},
    },
    HUMAN = {
        {w=50, skip=true},                            -- half of humanity is left alone
        {w=35, weapon=COPPER, arms=PICK_AXE_SPEAR},
        {w=15, weapon=IRON,   armor=IRON},
    },
    HA_HIGH_ELF = {
        -- A third of elves are soldiery, a sixth are armed travellers in cloaks, and half
        -- are unarmed civilians. `gendered` enforces "women in skirts or dresses, men
        -- never"; `outer` decides whether they wear a cloak or robe over it.
        -- ARMED: the two armoured outfits, plus the cloaked one -- a cloak or robe comes
        -- with a twinkling weapon. Plain-clothed and silk-clad elves carry nothing.
        {w=1, weapon=TWINKLING, armor=TWINKLING,  fabric=TWINKLING_FABRIC, wood=GROWN_WOOD, gendered=true},
        {w=1, weapon=TWINKLING, armor=STEEL,      fabric=TWINKLING_FABRIC, wood=GROWN_WOOD, gendered=true},
        {w=1, weapon=STEEL,     armor=GROWN_WOOD, fabric=TWINKLING_FABRIC, wood=GROWN_WOOD, gendered=true},
        {w=1, weapon=TWINKLING, fabric=TWINKLING_FABRIC, wood=GROWN_WOOD, outer=true,  gendered=true},
        {w=1, fabric=TWINKLING_FABRIC, outer=false, gendered=true},
        {w=1, fabric=GCS_SILK,         outer=false, gendered=true},
        -- FORTRESS MODE ONLY, and only for an invading army: a siege is always armoured,
        -- an even split of steel and twinkling. Visitors and residents fall through to the
        -- roll above, so a diplomat still turns up in robes rather than plate.
        siege = {
            {w=1, weapon=TWINKLING, armor=TWINKLING, fabric=TWINKLING_FABRIC, gendered=true},
            {w=1, weapon=TWINKLING, armor=STEEL,     fabric=TWINKLING_FABRIC, gendered=true},
        },
    },
    HA_DROW = {
        by_caste = {
            FEMALE = {{w=100, fabric=GCS_SILK}},      -- not soldiers: silk, no arms
            DRIDER = {{w=100, weapon=STEEL, armor=STEEL}},
        },
        {w=80, weapon=IRON,  armor=IRON},             -- MALE
        {w=20, weapon=STEEL, armor=STEEL},
    },
    HA_ILLITHID = {
        by_caste = {THRALL_M = THRALL_KIT, THRALL_F = THRALL_KIT},
        -- illithid, ulitharid and elder brain castes fall through to this and are
        -- left exactly as they are
        {w=100, skip=true},
    },
}
OUTFITS.HA_DARK_DWARF = OUTFITS.DWARF                 -- same treatment as vanilla dwarves

local function roll(list)
    local total = 0
    for _, o in ipairs(list) do total = total + o.w end
    if total <= 0 then return end
    local r = math.random() * total
    for _, o in ipairs(list) do
        r = r - o.w
        if r <= 0 then return o end
    end
    return list[#list]
end

-- Only these item types/subtypes are ever generated (prevents impossible items).
local ALLOW_METAL = {
    [df.item_type.WEAPON] = {
        ITEM_WEAPON_SWORD_SHORT=true, ITEM_WEAPON_SWORD_LONG=true,
        ITEM_WEAPON_SPEAR=true, ITEM_WEAPON_MACE=true, ITEM_WEAPON_HAMMER_WAR=true,
        ITEM_WEAPON_AXE_BATTLE=true, ITEM_WEAPON_CROSSBOW=true, ITEM_WEAPON_PICK=true,
    },
    -- every entry here carries [METAL] in its itemdef, so a metal copy is a legal item
    [df.item_type.ARMOR]  = {ITEM_ARMOR_BREASTPLATE=true, ITEM_ARMOR_MAIL_SHIRT=true},
    [df.item_type.HELM]   = {ITEM_HELM_HELM=true, ITEM_HELM_CAP=true},
    [df.item_type.GLOVES] = {ITEM_GLOVES_GAUNTLETS=true},
    [df.item_type.SHOES]  = {ITEM_SHOES_BOOTS=true, ITEM_SHOES_BOOTS_LOW=true},
    [df.item_type.PANTS]  = {ITEM_PANTS_GREAVES=true, ITEM_PANTS_LEGGINGS=true},
    [df.item_type.SHIELD] = {ITEM_SHIELD_SHIELD=true, ITEM_SHIELD_BUCKLER=true},
}
-- CLOTHING: only used by a policy that declares `fabric` (high elves). The rank
-- rule is NOT applied here -- comparing cloth by shear yield is meaningless, and
-- the point is that high elves should not stand around in jute and ramie rags.
-- Every entry here carries [SOFT] + woven-thread elasticity in its itemdef, so a fabric
-- copy is a legal item. ITEM_ARMOR_LEATHER is deliberately absent from BOTH lists: it is
-- [LEATHER] with neither [SOFT] nor [METAL], so it can be made of neither.
-- Checked against the full itemdef list in a loaded world -- the skirts, veils and
-- chausses below were the gap that left a high-elf clothier in a rope reed skirt.
local ALLOW_FABRIC = {
    [df.item_type.ARMOR]  = {
        ITEM_ARMOR_CLOAK=true, ITEM_ARMOR_COAT=true, ITEM_ARMOR_SHIRT=true,
        ITEM_ARMOR_TUNIC=true, ITEM_ARMOR_TOGA=true, ITEM_ARMOR_CAPE=true,
        ITEM_ARMOR_VEST=true, ITEM_ARMOR_DRESS=true, ITEM_ARMOR_ROBE=true,
    },
    [df.item_type.HELM]   = {ITEM_HELM_HOOD=true, ITEM_HELM_TURBAN=true, ITEM_HELM_MASK=true,
                             ITEM_HELM_VEIL_HEAD=true, ITEM_HELM_VEIL_FACE=true,
                             ITEM_HELM_SCARF_HEAD=true},
    [df.item_type.GLOVES] = {ITEM_GLOVES_GLOVES=true, ITEM_GLOVES_MITTENS=true},
    [df.item_type.SHOES]  = {ITEM_SHOES_SHOES=true, ITEM_SHOES_SANDAL=true,
                             ITEM_SHOES_SOCKS=true, ITEM_SHOES_CHAUSSE=true},
    [df.item_type.PANTS]  = {ITEM_PANTS_PANTS=true, ITEM_PANTS_LOINCLOTH=true,
                             ITEM_PANTS_BRAIES=true, ITEM_PANTS_THONG=true,
                             ITEM_PANTS_SKIRT=true, ITEM_PANTS_SKIRT_SHORT=true,
                             ITEM_PANTS_SKIRT_LONG=true},
}

local EQUIPPED = {[df.inv_item_role_type.Weapon]=true, [df.inv_item_role_type.Worn]=true}

enabled = enabled or false
done = done or {}          -- unit id -> already processed (also stops the metal re-rolling)

function isEnabled() return enabled end

-- ------------------------------------------------------------- helpers ----

local function mat(id)
    local mi = dfhack.matinfo.find(id)
    if mi then return mi.type, mi.index end
end

-- how good a material is, for "upgrade only". SHEAR yield straight from the raws,
-- so a modded metal ranks by its own numbers instead of needing a hardcoded table.
local function rank_of(mtype, mindex)
    local mi = dfhack.matinfo.decode(mtype, mindex)
    if not mi then return 0 end
    local ok, v = pcall(function() return mi.material.strength.yield[df.strain_type.SHEAR] end)
    return (ok and v) or 0
end

local function race_index(cid)
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == cid then return i end
    end
end

-- caste_id string, not unit.sex: HA_DROW's DRIDER caste carries
-- [CREATURE_CLASS:HA_DROW_FEMALE], so a sex test would exempt driders along with
-- females -- the exact opposite of "driders always get steel".
local function caste_of(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local c = cr and cr.caste[u.caste]
    return c and c.caste_id or ''
end

-- part of an attacking army, as opposed to a visitor or resident. Same three flags
-- adventure-hostility uses to tell a siege from a social call.
local function is_invader(u)
    return u.flags1.active_invader or u.flags1.invader_origin or u.flags1.marauder
end

local function is_target(u)
    if not dfhack.units.isActive(u) then return false end
    if dfhack.world.isAdventureMode() then
        local adv = dfhack.world.getAdventurer()
        return not adv or u.id ~= adv.id
    end
    return not dfhack.units.isCitizen(u)
end

-- ---------------------------------------------------------------- gear ----

local function itemdef_index(vec, id)
    for i, d in ipairs(vec) do
        if d.id == id then return i end
    end
end

local DEF_VEC = {
    [df.item_type.ARMOR]  = function() return df.global.world.raws.itemdefs.armor end,
    [df.item_type.PANTS]  = function() return df.global.world.raws.itemdefs.pants end,
    [df.item_type.HELM]   = function() return df.global.world.raws.itemdefs.helms end,
    [df.item_type.GLOVES] = function() return df.global.world.raws.itemdefs.gloves end,
    [df.item_type.SHOES]  = function() return df.global.world.raws.itemdefs.shoes end,
    [df.item_type.WEAPON] = function() return df.global.world.raws.itemdefs.weapons end,
    [df.item_type.SHIELD] = function() return df.global.world.raws.itemdefs.shields end,
}

local function subtype_index(itype, id)
    local get = DEF_VEC[itype]
    return get and itemdef_index(get(), id)
end

-- Create ONE item, destroying anything else the call minted. Needed because createItem
-- follows DF's forging rules and returns a PAIR for some gear (gauntlets), so the naive
-- `createItem(...)[1]` silently drops the other piece on the floor. Only apply() wants the
-- surplus (it dresses the second hand with it); every mint path below wants exactly one.
local function create_one(u, itype, isub, mt, mi)
    local created = dfhack.items.createItem(u, itype, isub, mt, mi)
    if not (created and created[1]) then return end
    for i = 2, #created do pcall(dfhack.items.remove, created[i]) end
    return created[1]
end

-- true if ANY equipped piece is a masterwork or artifact. Gates the MINTING of new
-- gear: someone already carrying a masterwork is left to what they have.
local function has_masterwork(u)
    for _, inv in ipairs(u.inventory) do
        if inv.item and EQUIPPED[inv.mode]
           and inv.item:getQuality() >= df.item_quality.Masterful then return true end
    end
    return false
end

local function armed(u)
    for _, inv in ipairs(u.inventory) do
        if inv.item and inv.mode == df.inv_item_role_type.Weapon
           and df.item_weaponst:is_instance(inv.item) then return true end
    end
    return false
end

-- The unit's OWN civ weapon list, as itemdef ids WITH REPEATS -- the repeats are the
-- civ's preference ratio (drow: SCIMITAR x10 vs one each of bow, pike, whip...), so a
-- uniform pick over this list reproduces that ratio. Falls back to a sane list when the
-- unit has no civ (wild/prisoner units carry civ_id -1).
local function civ_arms(u, fallback)
    local ent = u.civ_id and u.civ_id >= 0 and df.historical_entity.find(u.civ_id)
    local out = {}
    if ent then
        for _, wi in ipairs(ent.resources.weapon_type) do
            local d = df.global.world.raws.itemdefs.weapons[wi]
            -- skip training weapons: they are in the civ list but are not real arms
            if d and not d.id:find('TRAINING') then out[#out+1] = d.id end
        end
    end
    if #out == 0 then return fallback or DWARF_ARMS end
    return out
end

-- Decide what each equipped piece should BECOME under this outfit.
local function plan(u, o, mtype, mindex, want_rank, ftype, findex)
    local out = {}
    if not (o.armor or o.fabric) then return out, false end  -- weapon-only: touch nothing worn
    local slot_map = o.leather and LEATHER_FOR_SLOT or ARMOR_FOR_SLOT
    local promoted = {}      -- item_type -> already promoted a piece in this body slot
    local promoted_bp = {}   -- "itype:body_part" -> that part already has its armor
    local paired_n = {}      -- item_type -> promotions made in a paired slot
    local made_outer = false
    -- non-underlayers first, so a shoe wins its foot over the sock beneath it
    local ordered = {}
    for _, inv in ipairs(u.inventory) do ordered[#ordered+1] = inv end
    table.sort(ordered, function(a, b)
        local function under(inv)
            local it = inv.item
            if not it then return true end
            local ok, sub = pcall(function() return it.subtype and it.subtype.id end)
            return (ok and sub and UNDERLAYER[sub]) and true or false
        end
        local ua, ub = under(a), under(b)
        if ua ~= ub then return not ua end
        return false
    end)
    for _, inv in ipairs(ordered) do
        local it = inv.item
        if it and EQUIPPED[inv.mode] then
            -- NB not every item class HAS a subtype field (item_quiverst does not),
            -- so this must be a guarded read, not `it.subtype and it.subtype.id`
            local itype = it:getType()
            local oksub, sub = pcall(function() return it.subtype and it.subtype.id end)
            sub = oksub and sub or nil
            local q = it:getQuality()
            if sub and q < df.item_quality.Masterful then
                local isub, at, ai
                if (ALLOW_METAL[itype] or {})[sub] then
                    -- already armor: same piece, better metal, upgrade only
                    if o.armor and not o.leather
                       and rank_of(it:getActualMaterial(), it:getActualMaterialIndex()) < want_rank then
                        isub, at, ai = it:getSubtype(), mtype, mindex
                    end
                elseif (ALLOW_FABRIC[itype] or {})[sub] then
                    if OUTERWEAR[sub] then
                        -- never promoted; re-made in the outfit's own material so a
                        -- leather outfit ends up with a leather cloak
                        local ot, oi = mtype, mindex
                        if ftype then ot, oi = ftype, findex end
                        isub, at, ai = it:getSubtype(), ot, oi
                        made_outer = true
                    elseif o.armor and slot_map[itype] then
                        -- ONE promotion per body slot (shirt+tunic must not become two
                        -- breastplates). PAIRED slots get one per BODY PART instead, so
                        -- both hands/feet are covered but socks under shoes do not each
                        -- turn into a boot. MAX_PER_PAIRED_SLOT is a backstop in case
                        -- body_part_id is not usable.
                        local bpkey = itype .. ':' .. tostring(inv.body_part_id)
                        local allow
                        if PAIRED_SLOT[itype] then
                            allow = not promoted_bp[bpkey]
                                and (paired_n[itype] or 0) < MAX_PER_PAIRED_SLOT
                        else
                            allow = not promoted[itype]
                        end
                        local idx = allow and subtype_index(itype, slot_map[itype])
                        if idx then
                            isub, at, ai = idx, mtype, mindex
                            promoted[itype] = true
                            promoted_bp[bpkey] = true
                            paired_n[itype] = (paired_n[itype] or 0) + 1
                        end
                    elseif ftype then
                        isub, at, ai = it:getSubtype(), ftype, findex   -- stays clothing
                    end
                end
                if isub and at then
                    -- handedness is a BitArray field, so copying `it.handedness` across
                    -- silently did nothing and left units in two right gauntlets. The
                    -- accessors are the real API: 1 = right, 2 = left.
                    local hand
                    if itype == df.item_type.GLOVES then
                        local okh, h = pcall(function() return it:getGloveHandedness() end)
                        if okh then hand = h end
                    end
                    out[#out+1] = {old=it, itype=itype, isub=isub, mt=at, mi=ai,
                                   mode=inv.mode, bp=inv.body_part_id, quality=q, hand=hand}
                end
            end
        end
    end
    return out, made_outer
end

-- DF FORGES SOME GEAR IN PAIRS. createItem for gauntlets hands back TWO items -- a right
-- and a left, already handed 1 and 2 -- where boots, breastplates and helms give one.
-- Taking only created[1] therefore did two bad things at once: it abandoned the left
-- gauntlet of every pair on the floor (the litter), and it put a created[1] on BOTH hands,
-- which is the "two right gauntlets" fix_handedness was invented to paper over.
-- The surplus is now carried to the next swap in the same slot, so one call dresses both
-- hands; anything genuinely left over is destroyed rather than dropped.
local function apply(u, swaps)
    local spare = {}
    for _, t in ipairs(swaps) do
        local newit
        local pool = spare[t.itype]
        if pool then
            for i, cand in ipairs(pool) do
                if cand:getSubtype() == t.isub then
                    newit = cand
                    table.remove(pool, i)
                    break
                end
            end
        end
        if not newit then
            local created = dfhack.items.createItem(u, t.itype, t.isub, t.mt, t.mi)
            if created and created[1] then
                newit = created[1]
                if #created > 1 then
                    spare[t.itype] = spare[t.itype] or {}
                    for i = 2, #created do table.insert(spare[t.itype], created[i]) end
                end
            end
        end
        if newit then
            newit:setQuality(t.quality)
            if t.hand and t.hand ~= 0 then
                pcall(function() newit:setGloveHandedness(t.hand) end)
            end
            dfhack.items.remove(t.old)
            dfhack.items.moveToInventory(newit, u, t.mode, t.bp)
        end
    end
    -- never leave a surplus piece lying where it was minted
    for _, pool in pairs(spare) do
        for _, it in ipairs(pool) do pcall(dfhack.items.remove, it) end
    end
end

-- true if the unit has NOTHING on its head -- no helm, no cap, no hood, no veil
local function bare_headed(u)
    for _, inv in ipairs(u.inventory) do
        if inv.item and EQUIPPED[inv.mode]
           and inv.item:getType() == df.item_type.HELM then return false end
    end
    return true
end

-- Pieces an armored outfit ADDS rather than replaces:
--   * a leather outfit issues a leather cloak, if the unit had no outerwear to re-make
--   * a bare head gets a helm HELM_CHANCE of the time
-- Both mint into an empty slot, which the swap pass deliberately never does.
local function mint_extras(u, o, mtype, mindex, had_outer)
    -- the issued cloak belongs to the leather policy, so it stays armour-gated
    if o.armor and o.leather and not had_outer then
        local idx = subtype_index(df.item_type.ARMOR, 'ITEM_ARMOR_CLOAK')
        if idx then
            local it = create_one(u, df.item_type.ARMOR, idx, mtype, mindex)
            if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Worn, -1) end
        end
    end
    -- HELMETS. An outfit that ARMOURS issues one at HELM_CHANCE in its armour material.
    -- An outfit carrying only a WEAPON -- no armour, no fabric -- issues one at
    -- WEAPON_ONLY_HELM_CHANCE in the weapon's own metal, so a copper-armed orc still ends
    -- up in a copper helm instead of bare-headed. A FABRIC outfit gets none: the material
    -- there is cloth, and ITEM_HELM_HELM is [METAL]/[LEATHER], so it would be an
    -- impossible item. Children reach neither branch -- run() strips armor and weapon off
    -- them before this is called.
    local chance, ht, hi
    if o.armor then
        chance, ht, hi = HELM_CHANCE, mtype, mindex
    elseif o.weapon and not o.fabric then
        chance, ht, hi = WEAPON_ONLY_HELM_CHANCE, mat(o.weapon)
    end
    if chance and ht and bare_headed(u) and math.random() < chance then
        -- ITEM_HELM_HELM carries both [LEATHER] and [METAL], so it is legal in a
        -- leather outfit's material as well as in a metal one
        local idx = subtype_index(df.item_type.HELM, 'ITEM_HELM_HELM')
        if idx then
            local it = create_one(u, df.item_type.HELM, idx, ht, hi)
            if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Worn, -1) end
        end
    end
end

-- Repair handedness on paired hand gear. Gauntlets minted without an explicit hand all
-- come out RIGHT, so a unit can end up wearing two right gauntlets -- which is also the
-- legacy damage left by the earlier version that failed to carry handedness at all.
-- If both hand items agree, flip the second to the other hand (1 = right, 2 = left).
local function fix_handedness(u)
    local hands = {}
    for _, inv in ipairs(u.inventory) do
        local it = inv.item
        if it and EQUIPPED[inv.mode] and it:getType() == df.item_type.GLOVES then
            hands[#hands+1] = it
        end
    end
    if #hands ~= 2 then return end
    local ok1, h1 = pcall(function() return hands[1]:getGloveHandedness() end)
    local ok2, h2 = pcall(function() return hands[2]:getGloveHandedness() end)
    if ok1 and ok2 and h1 ~= 0 and h1 == h2 then
        pcall(function() hands[2]:setGloveHandedness(h1 == 1 and 2 or 1) end)
    end
end

-- every equipped piece whose subtype passes `pred`
local function worn_matching(u, pred)
    local out = {}
    for _, inv in ipairs(u.inventory) do
        local it = inv.item
        if it and EQUIPPED[inv.mode] then
            local ok, sub = pcall(function() return it.subtype and it.subtype.id end)
            if ok and sub and pred(sub) then out[#out+1] = it end
        end
    end
    return out
end

local function wear_new(u, itype, sub_id, mt, mi)
    local idx = subtype_index(itype, sub_id)
    if not idx then return end
    local it = create_one(u, itype, idx, mt, mi)
    if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Worn, -1) end
    return it
end

-- `outer` on an outfit: true = make sure there IS a cloak or robe, false = make sure there
-- is not, nil = leave whatever the unit came with (every race but the high elves).
local function apply_outer(u, o, mt, mi)
    if o.outer == nil then return end
    local have = worn_matching(u, function(sub) return OUTER_GARMENT[sub] end)
    if o.outer then
        if #have == 0 then
            wear_new(u, df.item_type.ARMOR, OUTER_MINT[math.random(#OUTER_MINT)], mt, mi)
        end
    else
        for _, it in ipairs(have) do dfhack.items.remove(it) end
    end
end

-- `gendered`: elf women always in a skirt or dress, elf men never. Runs AFTER the swap
-- pass, so it sorts out whatever the unit was left wearing rather than what it arrived in.
local function apply_gendered(u, o, mt, mi)
    if not o.gendered then return end
    local ok, female = pcall(function() return dfhack.units.isFemale(u) end)
    if not ok then female = (u.sex == 0) end        -- pronoun_type: 0 she, 1 he
    local skirts = worn_matching(u, function(sub) return SKIRTLIKE[sub] end)
    if female then
        if #skirts == 0 then
            local pick = WOMENS_MINT[math.random(#WOMENS_MINT)]
            wear_new(u, pick[1], pick[2], mt, mi)
        end
    else
        if #skirts == 0 then return end
        for _, it in ipairs(skirts) do dfhack.items.remove(it) end
        -- do not leave him bare-legged: if that took his only leg covering, issue trousers
        local legs = worn_matching(u, function(sub)
            return (ALLOW_FABRIC[df.item_type.PANTS] or {})[sub]
                or (ALLOW_METAL[df.item_type.PANTS] or {})[sub]
        end)
        if #legs == 0 then wear_new(u, df.item_type.PANTS, MENS_PANTS, mt, mi) end
    end
end

-- The ammo CLASS a weapon fires ('ARROW', 'BOLT', 'BLOWDART', 'BULLET' for the kobold
-- sling...), or nil for a melee weapon. This is the raws' own linkage -- weapon itemdefs
-- carry `ranged_ammo` and ammo itemdefs carry a matching `ammo_class` -- so a modded
-- ranged weapon is handled without naming it here.
local function ammo_class_of(weapon_sub)
    local W = df.global.world.raws.itemdefs.weapons
    for i = 0, #W - 1 do
        if tostring(W[i].id) == weapon_sub then
            local c = tostring(W[i].ranged_ammo)
            return c ~= '' and c or nil
        end
    end
end

-- The ammo itemdef INDEX for a class, preferring the unit's OWN civ list so an elf gets
-- elven arrows, and falling back to any ammo of that class in the world.
--
-- Indexed numerically because the INDEX itself is the value we need to return -- ipairs
-- over a df vector yields 0-based indices correctly, but writing the bound out makes it
-- obvious that `ai` is an itemdef index and not a position in a Lua list.
local function ammo_index_for(u, class)
    local A = df.global.world.raws.itemdefs.ammo
    local ent = u.civ_id and u.civ_id >= 0 and df.historical_entity.find(u.civ_id)
    if ent then
        local list = ent.resources.ammo_type
        for i = 0, #list - 1 do
            local ai = list[i]
            local d = A[ai]
            if d and tostring(d.ammo_class) == class then return ai end
        end
    end
    for i = 0, #A - 1 do
        if tostring(A[i].ammo_class) == class then return i end
    end
end

-- A minted RANGED weapon comes with a leather quiver holding ARROWS_PER_QUIVER rounds of
-- whatever it actually fires -- arrows for a bow, bolts for a crossbow, darts for a
-- blowgun. Heads are the outfit's weapon metal.
local function give_quiver(u, weapon_sub, wtype, windex)
    local class = ammo_class_of(weapon_sub)
    if not class then return end
    local aidx = ammo_index_for(u, class)
    if not aidx then return end
    local lt, li = mat(LEATHER)
    if not lt then return end
    local quiver = create_one(u, df.item_type.QUIVER, -1, lt, li)
    if not quiver then return end
    dfhack.items.moveToInventory(quiver, u, df.inv_item_role_type.Worn, -1)
    local rounds = create_one(u, df.item_type.AMMO, aidx, wtype, windex)
    if rounds then
        rounds:setStackSize(ARROWS_PER_QUIVER)
        dfhack.items.moveToContainer(rounds, quiver)
    end
end

-- how many real weapons the unit is already carrying
local function weapon_count(u)
    local n = 0
    for _, inv in ipairs(u.inventory) do
        if inv.item and inv.mode == df.inv_item_role_type.Weapon
           and df.item_weaponst:is_instance(inv.item) then n = n + 1 end
    end
    return n
end

local function has_shield(u)
    for _, inv in ipairs(u.inventory) do
        if inv.item and EQUIPPED[inv.mode]
           and inv.item:getType() == df.item_type.SHIELD then return true end
    end
    return false
end

-- The shield subtypes this unit's civ actually fields, as itemdef ids. Empty = a civ that
-- does not use shields at all (the drow), which is what switches the arming roll off.
local function civ_shields(u)
    local ent = u.civ_id and u.civ_id >= 0 and df.historical_entity.find(u.civ_id)
    local out = {}
    if ent then
        local list = ent.resources.shield_type
        for i = 0, #list - 1 do
            local d = df.global.world.raws.itemdefs.shields[list[i]]
            if d then out[#out+1] = tostring(d.id) end
        end
    end
    return out
end

-- Any wood in the world, for a shield whose outfit names none. Cached: the scan only ever
-- runs until the first plant that has a WOOD material.
local wood_cache
local function default_wood()
    if wood_cache ~= nil then return wood_cache end
    local P = df.global.world.raws.plants.all
    wood_cache = false
    for i = 0, #P - 1 do
        local tok = 'PLANT_MAT:' .. tostring(P[i].id) .. ':WOOD'
        if dfhack.matinfo.find(tok) then wood_cache = tok break end
    end
    return wood_cache
end

-- Shields are wooden SHIELD_WOOD_CHANCE of the time and metal otherwise. The wood is the
-- outfit's own if it names one (elves carry grown wood), else whatever the world has.
local function mint_shield(u, o, sub_id)
    local mt, mi
    if math.random() < SHIELD_WOOD_CHANCE then
        local w = o.wood or default_wood()
        if w then mt, mi = mat(w) end
    end
    if not mt then mt, mi = mat(o.armor or o.weapon or '') end
    if not mt then return end
    local idx = subtype_index(df.item_type.SHIELD, sub_id)
    if not idx then return end
    local it = create_one(u, df.item_type.SHIELD, idx, mt, mi)
    -- a shield rides in the Weapon role, same as a weapon, without being one
    if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Weapon, -1) end
end

-- Mint arms for the unarmed, in the outfit's weapon metal.
--   * a shield-bearing civ rolls ARMING: 50% one weapon, 25% two, 25% weapon + shield
--   * a civ with no shields keeps the old rule -- a scimitar comes as a PAIR (drow fight
--     with twin blades), anything else single
-- Never leaves a unit holding more than MAX_WEAPONS. A minted ranged weapon also gets a
-- quiver of matching ammo.
local function mint_arms(u, o)
    if not o.weapon then return end
    if armed(u) then return end
    local wtype, windex = mat(o.weapon)
    if not wtype then return end
    local list = o.arms or civ_arms(u)
    local pick = list[math.random(#list)]
    local isub = subtype_index(df.item_type.WEAPON, pick)
    if not isub then return end

    local shields = civ_shields(u)
    local n, want_shield = 1, false
    if #shields > 0 then
        local r = roll(ARMING)
        n, want_shield = r.weapons, r.shield or false
    elseif pick == 'ITEM_WEAPON_SCIMITAR' then
        n = 2
    end
    n = math.min(n, MAX_WEAPONS - weapon_count(u))

    for _ = 1, n do
        local it = create_one(u, df.item_type.WEAPON, isub, wtype, windex)
        if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Weapon, -1) end
    end
    -- any weapon the raws say fires something gets a quiver of the right ammo
    if n > 0 then pcall(give_quiver, u, pick, wtype, windex) end
    if want_shield and not has_shield(u) then
        pcall(mint_shield, u, o, shields[math.random(#shields)])
    end
end

-- Exported so it can be applied ON DEMAND. The scheduled pass runs on game TICKS, and in
-- adventure mode ticks only advance when the player acts -- standing still, a newly
-- enabled or newly edited policy appears to do nothing until you take a turn.
--   dfhack-run lua 'local e=reqscript("high-adventure/war-gear") e.done={} e.run()'
function run()
    local by_race = {}
    for cid, entry in pairs(OUTFITS) do
        local idx = race_index(cid)
        if idx then by_race[idx] = entry end
    end
    if not next(by_race) then return end

    for _, u in ipairs(df.global.world.units.active) do
        local entry = by_race[u.race]
        if entry and not done[u.id] and is_target(u) then
            local caste = caste_of(u)
            -- A besieging army in FORTRESS mode uses the siege list if the race has one:
            -- an assault turns up armoured. Visitors, residents and everyone in adventure
            -- mode fall through to the ordinary roll.
            local list
            if entry.siege and dfhack.world.isFortressMode() and is_invader(u) then
                list = entry.siege
            else
                list = (entry.by_caste and entry.by_caste[caste]) or entry
            end
            local o = roll(list)
            if o and not o.skip then
                -- CHILDREN in every civ: never armored, never armed. Material upgrades
                -- still apply, so an elf child is rewoven rather than left in rags.
                if not dfhack.units.isAdult(u) then
                    o = setmetatable({armor=nil, leather=nil, weapon=nil}, {__index=o})
                end
                local mtype, mindex = mat(o.armor or o.fabric or o.weapon or '')
                local ftype, findex
                if o.fabric then
                    ftype, findex = mat(o.fabric)
                    if not ftype then ftype, findex = mtype, mindex end
                end
                if mtype then
                    local swaps, had_outer = plan(u, o, mtype, mindex, rank_of(mtype, mindex), ftype, findex)
                    pcall(apply, u, swaps)
                    pcall(mint_extras, u, o, mtype, mindex, had_outer)
                    -- cloak policy and the gendered garment rule both operate on CLOTHING,
                    -- so they use the fabric material when the outfit has one, and run
                    -- after the swap pass has settled what the unit is actually wearing.
                    local ct, ci = ftype or mtype, findex or mindex
                    pcall(apply_outer, u, o, ct, ci)
                    pcall(apply_gendered, u, o, ct, ci)
                end
                if not has_masterwork(u) then pcall(mint_arms, u, o) end
                pcall(fix_handedness, u)
            end
            done[u.id] = true
        end
    end
end

-- ------------------------------------------------------------- engine ----

local function do_enable()
    enabled = true
    repeatUtil.scheduleEvery(GLOBAL_KEY, 200, 'ticks', run)
end

local function do_disable()
    enabled = false
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED
        and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        done = {}
        do_enable()
    end
end

if dfhack_flags.module then
    if not enabled and dfhack.isMapLoaded()
        and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
