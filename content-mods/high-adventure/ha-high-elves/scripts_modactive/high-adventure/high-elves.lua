--@module = true
--@enable = true
--[====[
high-adventure/high-elves
=========================

Tags: fort | adventure | gameplay

Support script for the self-contained high-elf civilization. Three jobs:

- **Shaping Tree pacing**: growing wood at HA_HE_SHAPING_TREE takes one month per
  tree (halved by a legendary strand extractor); wood grown before the tree
  regrows withers, with an announcement. (Catch-starlight is NOT paced -- it is
  gated by its plant/silk thread cost.)
- **Shaping Trees need open sky**: a tree placed without an "outside" (open to
  sky) work tile is cancelled while still under construction -- they catch
  starlight, so they cannot be built under a roof or underground.
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
local GROW_REACTIONS = { HA_HE_GROW_WOOD = true, HA_HE_GROW_FEATHER = true }

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
        if df.general_ref_building_holderst:is_instance(ref) then return ref.building_id end
    end
    return nil
end

-- pace grow-wood: one month per tree, wither if worked too soon
local function on_grow(reaction, rp, unit, ii, ir, oi, call_native)
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
    next_ok[bid] = t + (worker_is_legendary(unit) and (MONTH // 2) or MONTH)
end

-- shaping trees must be built under open sky; cancel a roofed/underground one
-- while it is still under construction
local function enforce_sky_access(btype)
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

-- ------------------------------------------------------------- engine ----

local function tick()
    if dfhack.world.isFortressMode() then
        pcall(enforce_sky_access, shaping_tree_type())
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
    repeatUtil.scheduleEvery(GLOBAL_KEY, 100, 'ticks', tick)
end

local function do_disable()
    enabled = false
    eventful.registerReaction("HA_HE_GROW_WOOD", nil)
    eventful.registerReaction("HA_HE_GROW_FEATHER", nil)
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
