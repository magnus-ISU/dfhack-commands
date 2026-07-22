--@module = true
--@enable = true
--[====[
high-adventure/playable-civs
============================

Tags: fort | gameplay

Support script for the High Adventure playable-civilizations mod:

- **Shaping Tree pacing**: growing wood from seeds takes one month per tree;
  a legendary strand extractor halves that. Jobs finished too soon wither
  (products are consumed) with an announcement.
- **Shaping Trees cannot be deconstructed**: removal jobs are cancelled.
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
local MONTH = 33600

enabled = enabled or false
next_ok = next_ok or {}   -- building id -> earliest tick for next harvest

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

local function worker_is_legendary(unit)
    local soul = unit.status.current_soul
    if not soul then return false end
    for _, s in ipairs(soul.skills) do
        if s.id == df.job_skill.EXTRACT_STRAND then return s.rating >= 15 end
    end
    return false
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
            "The shaping tree has not yet regrown; the young wood withers away.",
            COLOR_YELLOW, true)
        return
    end
    local period = worker_is_legendary(unit) and (MONTH // 2) or MONTH
    next_ok[bid] = t + period
end

local function tick()
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
    -- shaping trees cannot be unmade
    local btype = shaping_tree_type()
    if btype then
        for _, bld in ipairs(df.global.world.buildings.all) do
            if df.building_workshopst:is_instance(bld) and bld.custom_type == btype then
                for i = #bld.jobs - 1, 0, -1 do
                    local job = bld.jobs[i]
                    if job.job_type == df.job_type.DestroyBuilding then
                        dfhack.job.removeJob(job)
                        dfhack.gui.showAnnouncement(
                            "The shaping tree refuses to be unmade.", COLOR_GREEN, true)
                    end
                end
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
