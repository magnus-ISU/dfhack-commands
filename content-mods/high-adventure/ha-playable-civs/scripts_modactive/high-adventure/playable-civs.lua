--@module = true
--@enable = true
--[====[
high-adventure/playable-civs
============================

Tags: fort | gameplay

Support script for the High Adventure playable-civilizations mod:

- **Shaping Tree pacing**: growing wood from seeds takes one month per tree, and a
  freshly built tree starts on a full month cooldown. A skilled strand extractor grows
  MORE wood -- the one native log plus one bonus log per skill level, up to 21 total
  (legendary+5). Jobs finished too soon wither (products consumed) with an announcement.
- **Shaping Trees need open sky**: a tree placed without an "outside" (open to
  sky) work tile is cancelled while still under construction.
- **Elves can remove their own walls**: elves have no picks, so Remove-Construction
  orders (mining designations) never complete; in an elf fort this finishes them,
  reverting each designated constructed tile so walls/floors can be torn down.
- **Goblins do not memorialize their dead**: goblin ghosts are dispelled.

Usage
-----

	enable high-adventure/playable-civs
	disable high-adventure/playable-civs
]====]

local repeatUtil = require("repeat-util")
local eventful = require("plugins.eventful")

local GLOBAL_KEY = "haPlayableCivs"
local GROW_REACTIONS = { GROW_WOOD_HA = true, GROW_FEATHER_HA = true }
-- material each grow reaction yields, so we can mint skill-scaled bonus logs
local GROW_MAT = {
    GROW_WOOD_HA    = 'PLANT_MAT:GROWN_HA:WOOD',
    GROW_FEATHER_HA = 'PLANT_MAT:FEATHER_HA:WOOD',
}
local MONTH = 33600

enabled = enabled or false
next_ok = next_ok or {}   -- building id -> earliest tick for next harvest
cooldown_init = cooldown_init or {}  -- building id -> already given its build-time cooldown

function isEnabled()
    return enabled
end

local function now()
    return dfhack.world.ReadCurrentTick() + dfhack.world.ReadCurrentYear() * 403200
end

local function goblin_race_id()
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == "GOBLIN" then return i end
    end
    return nil
end

local function shaping_tree_type()
    for i, b in ipairs(df.global.world.raws.buildings.all) do
        if b.code == "HA_SHAPING_TREE" then return b.id end
    end
    return nil
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

-- drop `count` extra logs of `matspec` at the worker's feet -- the skill-scaled
-- bonus above the one native log
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

local function job_building(unit)
    local job = unit.job.current_job
    if not job then return nil end
    for _, ref in ipairs(job.general_refs) do
        if df.general_ref_building_holderst:is_instance(ref) then
            return ref.building_id
        end
    end
    return nil
end

local function on_reaction(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
    if not reaction or not GROW_REACTIONS[reaction.code] or not unit then return end
    local bid = job_building(unit) or -1
    local t = now()
    if next_ok[bid] and t < next_ok[bid] then
        if call_native then call_native.value = false end
        dfhack.gui.showAnnouncement(
            "The shaping tree is not yet ready to grow into new forms; it only yields new logs once a moon.",
            COLOR_YELLOW, true)
        return
    end
    next_ok[bid] = t + MONTH
    -- one native log plus one bonus log per EXTRACT_STRAND level, capped at 21 total
    mint_logs(unit, GROW_MAT[reaction.code], math.min(extract_strand_rating(unit), 20))
end

local function elf_fort()
    local r = df.global.world.raws.creatures.all[df.global.plotinfo.race_id]
    return r and tostring(r.creature_id) == "ELF"
end

-- Elves have no picks, so a "Remove Construction" order (which is a mining
-- designation) can never be carried out -- it just sits forever. Finish those
-- ourselves: revert each designated constructed tile to what it was before and
-- drop the construction record, so an elf fort can tear down its own walls and
-- floors with the normal Remove-Construction order, no DFHack command needed.
local function complete_wall_removals()
    if not elf_fort() then return end
    -- The player's Remove-Construction order shows up as a RemoveConstruction
    -- job that no pick-less elf can ever work. Snapshot those jobs (removeJob
    -- mutates the list), then finish each: revert the tile and drop the record.
    local jobs = {}
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        if j and j.job_type == df.job_type.RemoveConstruction then jobs[#jobs + 1] = j end
        link = link.next
    end
    if #jobs == 0 then return end
    local cons = df.construction.get_vector()
    local removed = false
    for _, j in ipairs(jobs) do
        local p = j.pos
        for i = #cons - 1, 0, -1 do
            local c = cons[i]
            if c.pos.x == p.x and c.pos.y == p.y and c.pos.z == p.z then
                local b = dfhack.maps.getTileBlock(c.pos)
                if b then
                    local lx, ly = p.x % 16, p.y % 16
                    b.tiletype[lx][ly] = c.original_tile
                    b.designation[lx][ly].dig = df.tile_dig_designation.No
                    dfhack.maps.enableBlockUpdates(b, true, true)
                    removed = true
                end
                cons:erase(i)
                break
            end
        end
        dfhack.job.removeJob(j)
    end
    if removed then pcall(function() df.global.world.reindex_pathfinding = true end) end
end

-- shaping trees must be built under open sky (to catch starlight / grow wood);
-- cancel a roofed or underground one while it is still under construction
local function enforce_sky_access()
    local btype = shaping_tree_type()
    if not btype then return end
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld.custom_type == btype and df.building_workshopst:is_instance(bld)
           and bld.construction_stage < bld:getMaxBuildStage() then
            local b = dfhack.maps.getTileBlock(bld.centerx, bld.centery, bld.z)
            if b and not b.designation[bld.centerx % 16][bld.centery % 16].outside then
                dfhack.buildings.deconstruct(bld)
                dfhack.gui.showAnnouncement(
                    "A shaping tree must be built under open sky.", COLOR_YELLOW, true)
            end
        end
    end
end

-- a freshly built shaping tree starts on a full one-month cooldown, so it cannot
-- be harvested the instant it finishes construction
local function init_new_trees()
    local btype = shaping_tree_type()
    if not btype then return end
    local t = now()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld.custom_type == btype and df.building_workshopst:is_instance(bld)
           and not cooldown_init[bld.id]
           and bld.construction_stage >= bld:getMaxBuildStage() then
            cooldown_init[bld.id] = true
            next_ok[bld.id] = t + MONTH
        end
    end
end

local function tick()
    complete_wall_removals()
    pcall(enforce_sky_access)
    pcall(init_new_trees)
    -- dispel goblin ghosts
    local grace = goblin_race_id()
    if grace then
        for _, u in ipairs(df.global.world.units.active) do
            if u.race == grace and u.flags3.ghostly then
                u.flags3.ghostly = false
                u.flags1.inactive = true
                u.flags2.killed = true
            end
        end
    end
end

local function do_enable()
    enabled = true
    eventful.registerReaction("GROW_WOOD_HA", on_reaction)
    eventful.registerReaction("GROW_FEATHER_HA", on_reaction)
    repeatUtil.scheduleEvery(GLOBAL_KEY, 50, "ticks", tick)
end

local function do_disable()
    enabled = false
    eventful.registerReaction("GROW_WOOD_HA", nil)
    eventful.registerReaction("GROW_FEATHER_HA", nil)
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() then
        do_enable()
    end
end

if dfhack_flags.module then
    -- self-enable at module load: survives any load-order race with SC_MAP_LOADED
    if not enabled and dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
