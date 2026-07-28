--@module = true
--@enable = true
--[====[
high-adventure/high-elves
=========================

Tags: fort | adventure | gameplay

Worldgen cannot equip a civ in a divine metal (metals come from geology; twinkling
metal is reaction-made), so high elves never spawn wearing it. This re-gears them
after the fact.

HOW IT WORKS (redesigned): it does NOT alter the material of existing items (that
can make impossible item/material combos -- a cloth-only type turned metal, etc.).
Instead, for each item a target already has EQUIPPED (wielded or worn) whose
type+subtype is on the ALLOWLIST below, it GENERATES a fresh twinkling-metal item
of that same type/subtype AT THE OLD ITEM'S QUALITY (lower qualities preserved),
swaps it into the same slot, and removes the old one. MASTERWORK and ARTIFACT
items are left untouched -- never re-geared (so no masterwork is destroyed). Empty
slots are never filled; equipped items not on the allowlist are left alone.

WHO it targets:
  - fort mode: high-elf INVADERS/VISITORS (never your own citizens).
  - adventure mode: high-elf units that are NOT historical figures -- so it never
    touches the adventurer if they are a histfig, retired fortress citizens, or any
    named/legendary high elf; only anonymous NPCs.

The drow "always steel" script is the same module with RACE_ID='HA_DROW',
MAT_ID='INORGANIC:STEEL', and a steel allowlist -- factor to a shared helper when
that ships.

UNTESTED until a high-elf world exists; the createItem/moveToInventory path is the
load-bearing part to verify live.

Usage: enable high-adventure/high-elves
]====]

local repeatUtil = require('repeat-util')

local GLOBAL_KEY = 'haHighElves'
local RACE_ID    = 'HA_HIGH_ELF'
local MAT_ID     = 'INORGANIC:HA_TWINKLING_METAL'

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

function isEnabled() return enabled end

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

-- allowlisted, currently-equipped items -> {type, subtype, role, body_part}
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
            newit:setQuality(t.quality)         -- preserve masterwork / crafted quality
            dfhack.items.remove(t.old)
            dfhack.items.moveToInventory(newit, u, t.mode, t.bp)
        end
    end
end

local function tick()
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
    repeatUtil.scheduleEvery(GLOBAL_KEY, 100, 'ticks', tick)
end

local function do_disable()
    enabled = false
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
