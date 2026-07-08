-- Notify-panel warning for civilians still outside the emergency (civilian-alert) burrow.
--@module = false
--[[
When the CIVILIAN ALERT is enabled (you've toggled the "civilian alert" on, so
civilians should be sheltering in its burrow), this raises a notify-panel entry:

    N citizens outside the fortress

counting fort civilians (non-soldiers) whose tile is NOT inside any of the
alert's burrow(s) -- i.e. dwarves who haven't reached safety yet. It shows only
while the alert is on and at least one civilian is still out; it clears when
everyone's inside or the alert is switched off.

Clicking it zooms to each straggler in turn (and selects them), so you can find
who's lagging.

DF data (verified): df.global.plotinfo.alerts.civ_alert_idx indexes the active
alert in .list; the default "No alert" has no burrows, so an active alert WITH
burrows means the civilian alert is on. Each alert's .burrows holds burrow ids;
a unit is "inside" if dfhack.burrows.isAssignedTile(burrow, unit.pos) is true.

Run `civ-alert-notification` to register (idempotent). magnus-scripts loads it.
]]

local NAME = 'civ_alert_outside'

-- the active civilian alert (an alert_statest with >=1 burrow), or nil if the civilian
-- alert is off. When off, civ_alert_idx points at the burrow-less "No alert" entry.
local function active_civ_alert()
    local al = df.global.plotinfo.alerts
    local idx = al.civ_alert_idx
    if idx < 0 or idx >= #al.list then return nil end
    local a = al.list[idx]
    if #a.burrows == 0 then return nil end
    return a
end

-- burrow objects of the active civ alert
local function alert_burrows(a)
    local out = {}
    for _, bid in ipairs(a.burrows) do
        local b = df.burrow.find(bid)
        if b then out[#out + 1] = b end
    end
    return out
end

-- unit ids in the "Military" work detail (the fort's real standing military, per military-labor).
-- ONLY these count as soldiers exempt from sheltering. A civilian-militia dwarf or an autotraining
-- trainee is in a squad (squad_id >= 0) but is NOT in this detail, so they still shelter like any
-- civilian -- which is why we key off the labor, not merely squad membership.
local function military_labor_set()
    local wd = df.global.plotinfo.labor_info.work_details
    for i = 0, #wd - 1 do
        if wd[i].name == 'Military' then
            local set = {}
            for _, id in ipairs(wd[i].assigned_units) do set[id] = true end
            return set
        end
    end
    return {}
end

-- a fort civilian who should be sheltering: a living, on-map citizen who is not a serving soldier
-- (i.e. not in the "Military" work detail; being in a squad is not enough -- civilian militia counts)
local function is_shelterable(u, mil)
    return dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) and not dfhack.units.isDead(u)
        and dfhack.units.isActive(u) and not mil[u.id] and u.pos.x >= 0
end

-- fort civilians whose tile is NOT inside any alert burrow
local function citizens_outside()
    local a = active_civ_alert()
    if not a then return {} end
    local burrows = alert_burrows(a)
    if #burrows == 0 then return {} end
    local mil = military_labor_set()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if is_shelterable(u, mil) then
            local inside = false
            for _, b in ipairs(burrows) do
                if dfhack.burrows.isAssignedTile(b, u.pos) then inside = true; break end
            end
            if not inside then out[#out + 1] = u end
        end
    end
    return out
end

-- notification line (only while the alert is on and someone is still out)
local function message()
    if not dfhack.world.isFortressMode() then return end
    if not active_civ_alert() then return end
    local n = #citizens_outside()
    if n == 0 then return end
    local text = ('%d citizen%s outside the fortress'):format(n, n == 1 and '' or 's')
    return {{text = text, pen = COLOR_LIGHTRED}}
end

-- click: cycle-zoom through each straggler (zoom + select), one per click
local cycle = 0
local function on_click()
    local list = citizens_outside()
    if #list == 0 then return end
    cycle = (cycle % #list) + 1
    local u = list[cycle]
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(u.pos.x, u.pos.y, u.pos.z), true, true)
    df.global.plotinfo.follow_unit = u.id
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
    entry.desc = 'Warns when the civilian alert is on but citizens are still outside its burrow.'
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

print('civ-alert-notification: "' .. NAME .. '" registered.')
print('Shows "N citizens outside the fortress" while the civilian alert is on and')
print('someone is still out; click it to zoom to each straggler.')
