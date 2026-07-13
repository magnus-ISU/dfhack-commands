-- Notify-panel warning for enemies that have gotten INSIDE the emergency (civilian-alert) burrow.
--@module = false
--[[
The companion to civ-alert-notification. When the CIVILIAN ALERT is on (its burrow is the
"fortress" safe area civilians shelter in), this raises a notify-panel entry:

    N enemies inside the fortress

counting hostiles -- invaders, other dangerous creatures, and agitated animals (one line for all
three) -- whose tile is INSIDE any of the alert's burrow(s), i.e. threats that have breached the
safe zone. Shows only while the alert is on and at least one enemy is inside; clears when the
burrow is clear or the alert is switched off. Clicking it zooms to each enemy in turn; SHIFT-
clicking it (with squads selected via the dwarf-rts overlay) orders those squads to attack the
enemies that got inside -- same as shift-clicking "N invaders" / "N hostiles".

Enemy test: dfhack.units.isDanger (invaders / hostiles / crazed / undead / megabeasts) OR
isAgitated (agitated wildlife), and NOT isHidden and NOT caged -- an undetected ambusher/sneaker
you haven't spotted, or an enemy already captured in a cage, is not counted. "Inside" uses
dfhack.burrows.isAssignedTile, same as the
civilian-outside check. Run `enemies-inside-notification` to register (idempotent);
magnus-scripts loads it.
]]

local NAME = 'enemies_inside'

-- the active civilian alert (an alert_statest with >=1 burrow), or nil if the alert is off
local function active_civ_alert()
    local al = df.global.plotinfo.alerts
    local idx = al.civ_alert_idx
    if idx < 0 or idx >= #al.list then return nil end
    local a = al.list[idx]
    if #a.burrows == 0 then return nil end
    return a
end

local function alert_burrows(a)
    local out = {}
    for _, bid in ipairs(a.burrows) do
        local b = df.burrow.find(bid)
        if b then out[#out + 1] = b end
    end
    return out
end

-- an on-map living threat: an invader / dangerous creature / agitated animal (not fort-controlled).
-- HIDDEN units (undetected ambushers / sneakers you haven't spotted) are excluded -- the warning
-- reflects only threats you can actually see inside the burrow, not ones the game hasn't revealed.
local function is_enemy(u)
    if not dfhack.units.isActive(u) or dfhack.units.isDead(u) or u.pos.x < 0 then return false end
    if dfhack.units.isFortControlled(u) or dfhack.units.isHidden(u) then return false end
    if u.flags1.caged then return false end   -- a captured enemy in a cage isn't a live threat
    return dfhack.units.isDanger(u) or dfhack.units.isAgitated(u)
end

-- enemies whose tile is inside any alert burrow
local function enemies_inside()
    local a = active_civ_alert()
    if not a then return {} end
    local burrows = alert_burrows(a)
    if #burrows == 0 then return {} end
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if is_enemy(u) then
            for _, b in ipairs(burrows) do
                if dfhack.burrows.isAssignedTile(b, u.pos) then out[#out + 1] = u; break end
            end
        end
    end
    return out
end

-- notification line (only while the alert is on and an enemy is inside)
local function message()
    if not dfhack.world.isFortressMode() then return end
    if not active_civ_alert() then return end
    local n = #enemies_inside()
    if n == 0 then return end
    local text = ('%d enem%s inside the fortress'):format(n, n == 1 and 'y' or 'ies')
    return {{text = text, pen = COLOR_RED}}
end

-- click: cycle-zoom through each enemy (zoom + follow), one per click.
-- SHIFT-click (with squads selected via the dwarf-rts overlay): order every selected squad to
-- kill exactly the enemies inside the fortress -- same idea as shift-clicking "N invaders" /
-- "N hostiles" / "N agitated animals", but surgically targeting only the ones who breached the
-- safe zone. Falls through to the zoom if the overlay isn't loaded or no squads are selected.
local cycle = 0
local function on_click(state, shift)
    local list = enemies_inside()
    if #list == 0 then return state end
    if shift then
        local gk = dfhack.internal.dwarf_rts_group_kill
        if gk then
            local ids = {}
            for _, u in ipairs(list) do ids[#ids + 1] = u.id end
            if gk(ids) then return state end   -- squads were selected -> commanded them
        end
    end
    cycle = (cycle % #list) + 1
    local u = list[cycle]
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(u.pos.x, u.pos.y, u.pos.z), true, true)
    df.global.plotinfo.follow_unit = u.id
    return state
end

-- ---- registration (mirrors the pack's other notify scripts) -----------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Warns when enemies have gotten inside the civilian-alert burrow (the fortress safe area).'
    entry.dwarf_fn = message
    entry.on_click = on_click
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register() end
end

print('enemies-inside-notification: "' .. NAME .. '" registered.')
print('Shows "N enemies inside the fortress" while the civilian alert is on and a hostile')
print('(invader / dangerous creature / agitated animal) is inside its burrow; click to zoom.')
