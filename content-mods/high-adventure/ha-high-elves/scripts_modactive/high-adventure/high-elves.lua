--@module = true
--@enable = true
--[====[
high-adventure/high-elves
=========================

Tags: fort | adventure | gameplay

Support script for the self-contained high-elf civilization. Three jobs:

- **Shaping Tree pacing**: growing wood at HA_HE_SHAPING_TREE takes one month per
  tree; a freshly built tree starts on a full month cooldown; wood grown before the
  tree regrows withers, with an announcement. A skilled strand extractor grows MORE
  wood -- the one native log plus one bonus log per skill level, up to 21 total
  (legendary+5). Catch-starlight is chancy: 5% success per point of the worker's strand
  extractor rating, so an unskilled elf always fails and a legendary+5 one always
  succeeds. A failure still spends both threads but does NOT rest the tree -- it can be
  tried again immediately; only a caught strand puts the tree on the same one-month
  cooldown that growing wood uses. Its twinkling strand is minted here, not as a native
  reaction PRODUCT, so the fuel-less Shaping Tree escapes DF's hardcoded metal-item fuel
  requirement.
- **Shaping Trees need open sky**: a tree placed without an "outside" (open to
  sky) work tile is cancelled while still under construction -- they catch
  starlight, so they cannot be built under a roof or underground.
- **Shaping Trees wrap a living tree**: the tile directly above the workshop must be a
  tree trunk, or the tree is cancelled while still under construction. DF gives a 5x5
  workshop a 5 x 6 art grid whose row 0 is that tile, and the art leaves row 0 blank,
  so the living tree stands in the mouth of the fern ring.
- **Twinkling gear**: worldgen cannot equip a divine metal (metals come from
  geology), so high elves never spawn in twinkling metal. This re-gears them.
  It does NOT alter item materials (that can make impossible item/material combos);
  instead, for each item a target already has EQUIPPED whose type+subtype is on the
  ALLOWLIST, it GENERATES a fresh twinkling item of that type/subtype at the old
  item's quality (lower qualities preserved), swaps it in, and removes the old one.
  MASTERWORK and ARTIFACT items are left untouched; empty slots are never filled.
  Targets fort-mode invaders/visitors (never citizens) and adventure-mode NPCs
  (never historical figures -- so not the adventurer, retired citizens, or named
  high elves).

UNTESTED until a high-elf world exists.

Usage: enable high-adventure/high-elves
]====]

local repeatUtil = require('repeat-util')
local eventful = require('plugins.eventful')

local GLOBAL_KEY = 'haHighElves'
local RACE_ID    = 'HA_HIGH_ELF'
local MAT_ID     = 'INORGANIC:HA_TWINKLING_METAL'
local MONTH      = 33600
-- catch starlight is a gamble: this much success chance per point of the worker's
-- strand extractor rating (so rating 20, legendary+5, is a sure thing)
local STARLIGHT_CHANCE_PER_LEVEL = 0.05
local GROW_REACTIONS = { HA_HE_GROW_WOOD = true, HA_HE_GROW_FEATHER = true }
-- material each grow reaction yields, so we can mint skill-scaled bonus logs
local GROW_MAT = {
    HA_HE_GROW_WOOD    = 'PLANT_MAT:HA_HE_GROWN:WOOD',
    HA_HE_GROW_FEATHER = 'PLANT_MAT:HA_HE_FEATHER:WOOD',
}

-- Only these item types/subtypes are ever generated (prevents impossible items).
-- Edit freely -- this is the whole point of the allowlist.
local ALLOW = {
    [df.item_type.WEAPON] = {
        ITEM_WEAPON_SWORD_SHORT=true, ITEM_WEAPON_SWORD_LONG=true,
        ITEM_WEAPON_SPEAR=true, ITEM_WEAPON_MACE=true,
        ITEM_WEAPON_HAMMER_WAR=true, ITEM_WEAPON_PICK=true,
    },
    [df.item_type.ARMOR]  = {ITEM_ARMOR_BREASTPLATE=true, ITEM_ARMOR_MAIL_SHIRT=true, ITEM_ARMOR_CLOAK=true},
    [df.item_type.HELM]   = {ITEM_HELM_HELM=true, ITEM_HELM_CAP=true},
    [df.item_type.GLOVES] = {ITEM_GLOVES_GAUNTLETS=true},
    [df.item_type.SHOES]  = {ITEM_SHOES_BOOTS=true, ITEM_SHOES_BOOTS_LOW=true},
    [df.item_type.PANTS]  = {ITEM_PANTS_GREAVES=true, ITEM_PANTS_LEGGINGS=true},
    [df.item_type.SHIELD] = {ITEM_SHIELD_SHIELD=true, ITEM_SHIELD_BUCKLER=true},
}

local EQUIPPED = {[df.inv_item_role_type.Weapon]=true, [df.inv_item_role_type.Worn]=true}

enabled = enabled or false
done = done or {}
next_ok = next_ok or {}       -- shaping-tree building id -> earliest tick for next harvest
cooldown_init = cooldown_init or {}  -- shaping-tree building id -> already given its build-time cooldown

function isEnabled() return enabled end

-- ---------------------------------------------------------------- gear ----

local function target_mat()
    local mi = dfhack.matinfo.find(MAT_ID)
    if mi then return mi.type, mi.index end
end

local function target_race()
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == RACE_ID then return i end
    end
end

local function should_regear(u, race)
    if u.race ~= race or not dfhack.units.isActive(u) then return false end
    if dfhack.world.isAdventureMode() then
        return u.hist_figure_id < 0            -- non-historical figures only
    end
    return not dfhack.units.isCitizen(u)        -- fort: invaders/visitors, never our citizens
end

local function equipped_targets(u)
    local out = {}
    for _, inv in ipairs(u.inventory) do
        local it = inv.item
        if it and EQUIPPED[inv.mode] then
            local itype = it:getType()
            local allow = ALLOW[itype]
            local sub = it.subtype and it.subtype.id
            if allow and sub and allow[sub] then
                local q = it:getQuality()
                if q < df.item_quality.Masterful then    -- leave masterworks AND artifacts untouched
                    out[#out+1] = {old=it, itype=itype, isub=it:getSubtype(),
                                   mode=inv.mode, bp=inv.body_part_id, quality=q}
                end
            end
        end
    end
    return out
end

local function regear(u, mtype, mindex)
    for _, t in ipairs(equipped_targets(u)) do
        local created = dfhack.items.createItem(u, t.itype, t.isub, mtype, mindex)
        local newit = created and created[1]
        if newit then
            newit:setQuality(t.quality)
            dfhack.items.remove(t.old)
            dfhack.items.moveToInventory(newit, u, t.mode, t.bp)
        end
    end
end

-- ------------------------------------------------------- shaping tree ----

local function now()
    return dfhack.world.ReadCurrentTick() + dfhack.world.ReadCurrentYear() * 403200
end

local function shaping_tree_type()
    for i, b in ipairs(df.global.world.raws.buildings.all) do
        if b.code == "HA_HE_SHAPING_TREE" then return b.id end
    end
end

-- EXTRACT_STRAND skill rating (0 if unskilled/no soul); drives bonus-log yield
local function extract_strand_rating(unit)
    local soul = unit.status.current_soul
    if not soul then return 0 end
    for _, s in ipairs(soul.skills) do
        if s.id == df.job_skill.EXTRACT_STRAND then return s.rating end
    end
    return 0
end

local function job_building(unit)
    local job = unit.job.current_job
    if not job then return nil end
    for _, ref in ipairs(job.general_refs) do
        if df.general_ref_building_holderst:is_instance(ref) then return ref.building_id end
    end
    return nil
end

-- drop `count` extra logs of `matspec` (e.g. PLANT_MAT:HA_HE_GROWN:WOOD) at the
-- worker's feet -- used to pay out the skill-scaled bonus above the one native log
local function mint_logs(unit, matspec, count)
    if count <= 0 then return end
    local mi = dfhack.matinfo.find(matspec)
    if not mi then return end
    local pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}
    for _ = 1, count do
        local created = dfhack.items.createItem(unit, df.item_type.WOOD, -1, mi.type, mi.index)
        local it = created and created[1]
        if it then dfhack.items.moveToGround(it, pos) end
    end
end

-- pace grow-wood: one month per tree, wither if worked too soon. A skilled strand
-- extractor grows MORE wood: the one native log plus one bonus log per skill level,
-- capped at 21 total (legendary+5 == rating 20 -> 1 + 20).
local function on_grow(reaction, rp, unit, ii, ir, oi, call_native)
    if not reaction or not GROW_REACTIONS[reaction.code] or not unit then return end
    local bid = job_building(unit) or -1
    local t = now()
    if next_ok[bid] and t < next_ok[bid] then
        if call_native then call_native.value = false end
        dfhack.gui.showAnnouncement(
            "The shaping tree is not ready to grow into new forms; it only can once a month.",
            COLOR_YELLOW, true)
        return
    end
    next_ok[bid] = t + MONTH
    mint_logs(unit, GROW_MAT[reaction.code], math.min(extract_strand_rating(unit), 20))
end

-- catch starlight: the reaction has NO native product (a metal [PRODUCT] would force
-- DF's hardcoded metal-item fuel requirement onto this fuel-less workshop). Instead we
-- mint the dimension-15000 twinkling THREAD here after the reagents are consumed.
-- Catching starlight is chancy: STARLIGHT_CHANCE_PER_LEVEL per point of the worker's
-- strand extractor rating. A failure still burns the two threads -- the reagents are
-- consumed by the job itself, and all we withhold is the strand -- but it does NOT put
-- the tree on cooldown, so a failed catch can be tried again at once. Only a caught
-- strand rests the tree, and it shares the one month cooldown with growing wood.
local function on_catch_starlight(reaction, rp, unit, ii, ir, oi, call_native)
    if not reaction or reaction.code ~= 'HA_CATCH_STARLIGHT' or not unit then return end
    local bid = job_building(unit) or -1
    local t = now()
    if next_ok[bid] and t < next_ok[bid] then
        if call_native then call_native.value = false end
        dfhack.gui.showAnnouncement(
            "The shaping tree has spent its light; its boughs will not catch more for a moon.",
            COLOR_YELLOW, true)
        return
    end
    local rating = extract_strand_rating(unit)
    if math.random() >= rating * STARLIGHT_CHANCE_PER_LEVEL then
        dfhack.gui.showAnnouncement(
            dfhack.units.getReadableName(unit) ..
            ' lacked the skill to extract the strands of starlight. They can try again with a ' ..
            math.floor(rating * STARLIGHT_CHANCE_PER_LEVEL * 100) .. '% chance.',
            COLOR_YELLOW, true)
        return
    end
    next_ok[bid] = t + MONTH
    local mi = dfhack.matinfo.find(MAT_ID)
    if not mi then return end
    local created = dfhack.items.createItem(unit, df.item_type.THREAD, -1, mi.type, mi.index)
    local it = created and created[1]
    if it then
        if it.dimension ~= nil then it.dimension = 15000 end
        dfhack.items.moveToGround(it, {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z})
    end
end

-- shaping trees must be built under open sky; cancel a roofed/underground one
-- while it is still under construction
local function enforce_sky_access(btype)
    if not btype then return end
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) and bld.custom_type == btype
           and bld.construction_stage < bld:getMaxBuildStage() then
            local b = dfhack.maps.getTileBlock(bld.centerx, bld.centery, bld.z)
            if b and not b.designation[bld.centerx % 16][bld.centery % 16].outside then
                dfhack.buildings.deconstruct(bld)
                dfhack.gui.showAnnouncement(
                    "A shaping tree must be built under the open sky.", COLOR_YELLOW, true)
            end
        end
    end
end

-- a freshly built shaping tree starts on a full one-month cooldown, so it cannot
-- be harvested the instant it finishes construction
local function init_new_trees(btype)
    if not btype then return end
    local t = now()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) and bld.custom_type == btype
           and not cooldown_init[bld.id]
           and bld.construction_stage >= bld:getMaxBuildStage() then
            cooldown_init[bld.id] = true
            next_ok[bld.id] = t + MONTH
        end
    end
end

-- --------------------------------------------------- shaping tree site ----
-- a shaping tree is grown AROUND a living tree: DF draws a 5x5 workshop's art on a
-- 5 x (5+1) grid whose row 0 is the tile directly above the footprint. The art
-- (graphics/images/shaping_tree.png) leaves that row transparent so the real tree
-- shows through it -- and that tile has to BE a real tree.

local function trunk_pos(bld) return {x = bld.centerx, y = bld.y1 - 1, z = bld.z} end

-- any part of a living tree counts: a trunk pillar is material TREE but shape
-- WALL, not TRUNK_BRANCH
local function is_trunk(pos)
    local tt = dfhack.maps.getTileType(pos.x, pos.y, pos.z)
    if not tt then return false end
    return df.tiletype.attrs[tt].material == df.tiletype_material.TREE
end

-- NOTE: custom_type only exists on workshops/furnaces, so the is_instance test
-- must come FIRST -- reading it off a farm plot is a hard error
local function each_shaping_tree(btype, fn)
    if not btype then return end
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) and bld.custom_type == btype then
            fn(bld)
        end
    end
end

local function enforce_trunk(btype)
    each_shaping_tree(btype, function(bld)
        if bld.construction_stage < bld:getMaxBuildStage()
           and not is_trunk(trunk_pos(bld)) then
            dfhack.buildings.deconstruct(bld)
            dfhack.gui.showAnnouncement(
                'A shaping tree must be built around a living tree: put the trunk ' ..
                'just above the workshop.', COLOR_YELLOW, true)
        end
    end)
end

-- ------------------------------------------------------------- engine ----

local function tick()
    if dfhack.world.isFortressMode() then
        local btype = shaping_tree_type()
        pcall(enforce_sky_access, btype)
        pcall(init_new_trees, btype)
        pcall(enforce_trunk, btype)
    end
    local race = target_race(); if not race then return end
    local mtype, mindex = target_mat(); if not mtype then return end
    for _, u in ipairs(df.global.world.units.active) do
        if not done[u.id] and should_regear(u, race) then
            pcall(regear, u, mtype, mindex)
            done[u.id] = true
        end
    end
end

local function do_enable()
    enabled = true
    eventful.registerReaction("HA_HE_GROW_WOOD", on_grow)
    eventful.registerReaction("HA_HE_GROW_FEATHER", on_grow)
    eventful.registerReaction("HA_CATCH_STARLIGHT", on_catch_starlight)
    repeatUtil.scheduleEvery(GLOBAL_KEY, 100, 'ticks', tick)
end

local function do_disable()
    enabled = false
    eventful.registerReaction("HA_HE_GROW_WOOD", nil)
    eventful.registerReaction("HA_HE_GROW_FEATHER", nil)
    eventful.registerReaction("HA_CATCH_STARLIGHT", nil)
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
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
