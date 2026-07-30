--@module = true
--@enable = true
--[====[
high-adventure/drow
===================

Tags: fort | gameplay

Drow support script: goblin slaves trained for war are issued their fighting kit --
an obsidian short sword and wooden armor (breastplate and helm).

Drow war gear (iron/steel by caste) used to live here; it is now part of the shared
high-adventure/war-gear engine in the HA_adventure_hostility mod, alongside the same
job for high elves, dark dwarves and vanilla dwarves.

Usage
-----

	enable high-adventure/drow
	disable high-adventure/drow
]====]

local repeatUtil = require("repeat-util")

local GLOBAL_KEY = "haDrow"
local ROLE = df.inv_item_role_type or (df.unit_inventory_item and df.unit_inventory_item.T_mode)

enabled = enabled or false

function isEnabled()
    return enabled
end

local function race_id(cid)
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == cid then return i end
    end
    return nil
end

local function itemdef_index(vec, id)
    for i, d in ipairs(vec) do
        if d.id == id then return i end
    end
    return nil
end

local function has_weapon(unit)
    for _, inv in ipairs(unit.inventory) do
        if inv.item and df.item_weaponst:is_instance(inv.item) then return true end
    end
    return false
end

local function make_and_equip(unit, itype, subtype, mat, mode)
    local matinfo = dfhack.matinfo.find(mat)
    if not matinfo then return false end
    local items = dfhack.items.createItem(unit, itype, subtype, matinfo.type, matinfo.index)
    local item = items
    if type(items) == "table" then item = items[1] end
    if not item then return false end
    return dfhack.items.moveToInventory(item, unit, mode, -1)
end

-- ------------------------------------------------------- war-slave kit ----

local function equip_slaves()
    local race = race_id("HA_GOBLIN_SLAVE")
    if not race then return end
    local raws = df.global.world.raws.itemdefs
    local sword = itemdef_index(raws.weapons, "ITEM_WEAPON_SWORD_SHORT")
    local breastplate = itemdef_index(raws.armor, "ITEM_ARMOR_BREASTPLATE")
    local helm = itemdef_index(raws.helms, "ITEM_HELM_HELM")
    local shield = itemdef_index(raws.shields, "ITEM_SHIELD_SHIELD")
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and u.profession == df.profession.TRAINED_WAR
            and not u.flags1.inactive and not u.flags2.killed
            and dfhack.units.isOwnCiv(u) and not has_weapon(u) then
            local ok = false
            if sword then
                ok = make_and_equip(u, df.item_type.WEAPON, sword,
                    "INORGANIC:OBSIDIAN", ROLE.Weapon) or ok
            end
            if breastplate then
                make_and_equip(u, df.item_type.ARMOR, breastplate,
                    "PLANT:TOWER_CAP:WOOD", ROLE.Worn)
            end
            if helm then
                make_and_equip(u, df.item_type.HELM, helm,
                    "PLANT:TOWER_CAP:WOOD", ROLE.Worn)
            end
            if shield then
                make_and_equip(u, df.item_type.SHIELD, shield,
                    "PLANT:TOWER_CAP:WOOD", ROLE.Weapon)
            end
            if ok then
                dfhack.gui.showAnnouncement(
                    ("A goblin slave is armed for war: %s takes up sword, board, and wooden mail.")
                        :format(dfhack.units.getReadableName(u)),
                    COLOR_MAGENTA, true)
            end
        end
    end
end

-- ------------------------------------------------------------ engine ----

local function do_enable()
    enabled = true
    repeatUtil.scheduleEvery(GLOBAL_KEY, 200, "ticks", equip_slaves)
end

local function do_disable()
    enabled = false
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() and race_id("HA_GOBLIN_SLAVE") then
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
