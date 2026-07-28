-- Make noble mandates show in the notify panel immediately, not only near their deadline.
--@ module = false
--[[
DFHack's built-in 'mandates_expiring' notification only fires for production
(Make) mandates that are within ~1 month of expiring -- so export bans never
show, and production mandates stay hidden until they are nearly due.

This overrides that notification so it appears the moment a production (Make) or
guild mandate is active, giving you time to react. Export bans are omitted from
the one-line summary -- they are passive, non-urgent "do not export X" demands --
but still appear when you click it to see the full list of every mandate, with
what is demanded, who demanded it, and how long is left.

If the built-in notification is missing (different DFHack version), this registers
a new 'mandates_active' notification instead.

Run once per DFHack session. To make it permanent, add the line
    mandate-notification
to your dfhack-config/init/dfhack.init (or onMapLoad.init).
]]

local dlg = require('gui.dialogs')

-- map item_type -> the itemdef vector that holds its subtype names
local SUBTYPE_VEC = {
    [df.item_type.WEAPON]     = 'weapons',
    [df.item_type.ARMOR]      = 'armor',
    [df.item_type.SHOES]      = 'shoes',
    [df.item_type.GLOVES]     = 'gloves',
    [df.item_type.HELM]       = 'helms',
    [df.item_type.PANTS]      = 'pants',
    [df.item_type.SHIELD]     = 'shields',
    [df.item_type.AMMO]       = 'ammo',
    [df.item_type.TRAPCOMP]   = 'trapcomps',
    [df.item_type.TOY]        = 'toys',
    [df.item_type.INSTRUMENT] = 'instruments',
    [df.item_type.TOOL]       = 'tools',
}

local function item_name(item_type, item_subtype)
    local vecname = SUBTYPE_VEC[item_type]
    if vecname and item_subtype and item_subtype >= 0 then
        local vec = df.global.world.raws.itemdefs[vecname]
        local def = vec and vec[item_subtype]
        if def then
            return (def.name_plural ~= '' and def.name_plural) or def.name
        end
    end
    local tok = df.item_type[item_type]
    return tok and tok:lower():gsub('_', ' ') or 'goods'
end

local NEAR_DEADLINE_TICKS = 2500   -- same threshold the built-in used for "urgent"

local function days_left(m)
    return math.floor((m.timeout_limit - m.timeout_counter) / 1200 + 0.5)
end

-- "do not export breastplates" / "produce 2 steel mail shirts" / "guild mandate: crafts"
local function mandate_demand(m)
    local item = item_name(m.item_type, m.item_subtype)
    if m.mode == df.mandate_type.Make then
        return ('produce %d %s'):format(m.amount_remaining, item)
    elseif m.mode == df.mandate_type.Export then
        return ('do not export %s'):format(item)
    else
        return ('guild mandate: %s'):format(item)
    end
end

local function cap(s)
    return (s:gsub('^%l', string.upper))
end

-- the mandates to surface in the one-line notification. Export bans are always
-- omitted -- they are passive, non-urgent demands -- but still show in the
-- click-through detail list (see show_mandates, which reads mandates.all directly).
local function visible_mandates()
    local all = df.global.world.mandates.all
    local list = {}
    for i = 0, #all - 1 do
        local m = all[i]
        if m.mode ~= df.mandate_type.Export then
            list[#list + 1] = m
        end
    end
    return list
end

-- notification line (runs frequently; mandates.all is tiny so no caching needed)
local function mandates_message()
    if not dfhack.world.isFortressMode() then return end
    local list = visible_mandates()
    local count = #list
    if count == 0 then return end
    local urgent = false
    for _, m in ipairs(list) do
        if (m.timeout_limit - m.timeout_counter) < NEAR_DEADLINE_TICKS then
            urgent = true
            break
        end
    end
    -- does a manager work order already exist for this Make mandate?
    local function handled(m)
        local ok, am = pcall(reqscript, 'auto-mandate')
        return ok and am and am.has_order_for and am.has_order_for(m) or false
    end

    local text
    if count == 1 then
        local m = list[1]
        if m.mode == df.mandate_type.Make then
            if handled(m) then
                local noble = m.unit
                    and dfhack.translation.translateName(dfhack.units.getVisibleName(m.unit))
                    or 'a noble'
                text = ('producing %d %s for %s'):format(
                    m.amount_remaining, item_name(m.item_type, m.item_subtype), noble)
            else
                local noble = m.unit
                    and dfhack.translation.translateName(dfhack.units.getVisibleName(m.unit))
                    or 'A noble'
                text = ('%s requests %d %s'):format(
                    noble, m.amount_remaining, item_name(m.item_type, m.item_subtype))
            end
        else
            text = 'Mandate: ' .. mandate_demand(m)
        end
    else
        local all_make, all_handled = true, true
        for _, m in ipairs(list) do
            if m.mode ~= df.mandate_type.Make then all_make = false end
            if m.mode == df.mandate_type.Make and not handled(m) then all_handled = false end
        end
        if all_make and all_handled then
            text = ('dealing with %d mandates'):format(count)
        elseif all_make then
            text = ('%d production mandates'):format(count)
        else
            text = ('%d active mandates'):format(count)
        end
    end
    return {{text = text, pen = urgent and COLOR_LIGHTRED or COLOR_YELLOW}}
end

-- click handler: detailed list of every active mandate
-- the click dialog always lists every mandate, including export bans that are
-- hidden from the one-line notification when a higher-priority demand exists
local function show_mandates()
    local all = df.global.world.mandates.all
    if #all == 0 then return end
    local lines = {'Active noble mandates:', ''}
    for i = 0, #all - 1 do
        local m = all[i]
        local dl = days_left(m)
        local when = dl <= 0 and 'expiring now'
            or ('%d day%s left'):format(dl, dl == 1 and '' or 's')
        table.insert(lines, ('  %s  (%s)'):format(cap(mandate_demand(m)), when))
        local noble = m.unit and dfhack.units.getReadableName(m.unit) or 'unknown'
        table.insert(lines, ('      demanded by %s'):format(noble))
    end
    table.insert(lines, '')
    table.insert(lines, 'Manage these on the Nobles screen.')
    dlg.showMessage('Mandates', table.concat(lines, '\n'), COLOR_WHITE)
end

-- override the built-in 'mandates_expiring' (or add 'mandates_active' if absent)
local function register()
    local n = reqscript('internal/notify/notifications')
    local name = 'mandates_expiring'
    local entry = n.NOTIFICATIONS_BY_NAME[name]
    if not entry then
        name = 'mandates_active'
        entry = n.NOTIFICATIONS_BY_NAME[name]
        if not entry then
            entry = {name = name, version = 1, default = true}
            table.insert(n.NOTIFICATIONS_BY_IDX, entry)
            n.NOTIFICATIONS_BY_NAME[name] = entry
        end
    end
    entry.desc = 'Notifies as soon as any noble mandate is active, not just near its deadline.'
    entry.dwarf_fn = mandates_message
    entry.on_click = show_mandates
    if n.config and n.config.data and not n.config.data[name] then
        n.config.data[name] = {enabled = true, version = 1}
    end
    return name
end

local applied = register()

-- re-apply if the notify module is reloaded on a new world/map load
dfhack.onStateChange['mandate-notification'] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

print(('mandate-notification: overriding "%s" to show mandates immediately.'):format(applied))
print('Click the notification for a full list of active mandates.')
print('Add `mandate-notification` to dfhack.init to load it every session.')
