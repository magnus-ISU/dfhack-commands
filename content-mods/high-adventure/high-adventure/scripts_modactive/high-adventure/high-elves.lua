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
  cooldown that growing wood uses. Its twinkling strand is minted here rather than as a
  native reaction PRODUCT because a native product always fires: the per-level chance is
  the whole point, and only a script can gate it.
- **Shaping Trees need open sky**: a tree placed without an "outside" (open to
  sky) work tile is cancelled while still under construction -- they catch
  starlight, so they cannot be built under a roof or underground.
- **Shaping Trees wrap a living tree**: the tile directly above the workshop must be a
  tree trunk, or the tree is cancelled while still under construction. DF gives a 5x5
  workshop a 5 x 6 art grid whose row 0 is that tile, and the art leaves row 0 blank,
  so the living tree stands in the mouth of the fern ring.
- **Twinkling gear** has MOVED: re-gearing high elves into twinkling metal and
  twinkling fabric is now part of the shared high-adventure/war-gear engine in the
  HA_adventure_hostility mod, which does the same job for drow, dark dwarves and
  vanilla dwarves. Nothing about the behaviour changed except that it now upgrades
  only -- a piece already at or above twinkling is left alone.

Usage: enable high-adventure/high-elves
]====]

local repeatUtil = require('repeat-util')
local eventful = require('plugins.eventful')

local GLOBAL_KEY = 'haHighElves'
local RACE_ID    = 'HA_HIGH_ELF'
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
-- the twinkling materials. Only the FABRIC one is used here now (catch-starlight
-- mints a twinkling thread); re-gearing elves into twinkling metal moved to the
-- shared high-adventure/war-gear engine in the HA_adventure_hostility mod.
local MAT_ID     = 'INORGANIC:HA_TWINKLING_METAL'
local FABRIC_ID  = 'INORGANIC:HA_TWINKLING_FABRIC'

local function target_mat()
    local mi = dfhack.matinfo.find(MAT_ID)
    if mi then return mi.type, mi.index end
end

-- Worlds generated before the fabric material existed do not have it (raws are
-- baked in at gen time), so fall back to the metal rather than minting nothing.
local function fabric_mat()
    local mi = dfhack.matinfo.find(FABRIC_ID)
    if mi then return mi.type, mi.index end
    return target_mat()
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

-- catch starlight: the reaction has NO native product, because a native [PRODUCT] always
-- fires and this one must not -- the whole point is the per-skill-level chance below, which
-- only a script can gate. (An earlier comment here blamed DF's metal-item fuel requirement
-- for the design; that was a raws bug, not an engine rule. The chance is the real reason.)
-- So we mint the dimension-15000 twinkling THREAD here after the reagents are consumed.
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
    -- the strand is FABRIC: weave it for cloth, or smelt it with silver for metal
    local ftype, findex = fabric_mat()
    if not ftype then return end
    local created = dfhack.items.createItem(unit, df.item_type.THREAD, -1, ftype, findex)
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
