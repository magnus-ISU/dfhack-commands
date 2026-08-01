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
    HA_HIGH_ELF             twinkling metal armor; clothing rewoven in twinkling fabric
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
dominate for drow without being forced and the other choices still come up. A roll
that lands on a scimitar mints a PAIR; anything else mints one. Training weapons are
filtered out of civ lists.

ADDED PIECES -- the swap pass only ever replaces something already worn, but two cases
deliberately mint into an EMPTY slot:
  * a `leather` outfit issues a leather CLOAK (if the unit had no cloak or cape to
    re-make in leather);
  * a unit with NOTHING on its head -- no helm, cap, hood or veil -- gets a helm 40% of
    the time. Only for outfits that armor: a "weapon only" outfit means only a weapon.

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
-- a leather outfit also issues a cloak; chance of issuing a helm to a bare head
local HELM_CHANCE = 0.40

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
        -- elves keep clothing as clothing; only real armor is upgraded
        {w=100, weapon=TWINKLING, armor=TWINKLING, fabric=TWINKLING_FABRIC},
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
}

local function subtype_index(itype, id)
    local get = DEF_VEC[itype]
    return get and itemdef_index(get(), id)
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

local function apply(u, swaps)
    for _, t in ipairs(swaps) do
        local created = dfhack.items.createItem(u, t.itype, t.isub, t.mt, t.mi)
        local newit = created and created[1]
        if newit then
            newit:setQuality(t.quality)
            if t.hand and t.hand ~= 0 then
                pcall(function() newit:setGloveHandedness(t.hand) end)
            end
            dfhack.items.remove(t.old)
            dfhack.items.moveToInventory(newit, u, t.mode, t.bp)
        end
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
    if not o.armor then return end
    if o.leather and not had_outer then
        local idx = subtype_index(df.item_type.ARMOR, 'ITEM_ARMOR_CLOAK')
        if idx then
            local created = dfhack.items.createItem(u, df.item_type.ARMOR, idx, mtype, mindex)
            local it = created and created[1]
            if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Worn, -1) end
        end
    end
    if bare_headed(u) and math.random() < HELM_CHANCE then
        -- ITEM_HELM_HELM carries both [LEATHER] and [METAL], so it is legal in a
        -- leather outfit's material as well as in a metal one
        local idx = subtype_index(df.item_type.HELM, 'ITEM_HELM_HELM')
        if idx then
            local created = dfhack.items.createItem(u, df.item_type.HELM, idx, mtype, mindex)
            local it = created and created[1]
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

-- Mint a weapon for the unarmed, in the outfit's weapon metal. A scimitar is minted
-- as a PAIR -- drow fight with twin blades -- anything else as a single weapon.
local function mint_arms(u, o)
    if not o.weapon then return end
    if armed(u) then return end
    local wtype, windex = mat(o.weapon)
    if not wtype then return end
    local list = o.arms or civ_arms(u)
    local pick = list[math.random(#list)]
    local isub = subtype_index(df.item_type.WEAPON, pick)
    if not isub then return end
    local n = pick == 'ITEM_WEAPON_SCIMITAR' and 2 or 1
    for _ = 1, n do
        local created = dfhack.items.createItem(u, df.item_type.WEAPON, isub, wtype, windex)
        local it = created and created[1]
        if it then dfhack.items.moveToInventory(it, u, df.inv_item_role_type.Weapon, -1) end
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
            local list = (entry.by_caste and entry.by_caste[caste]) or entry
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
