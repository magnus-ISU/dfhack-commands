-- Warn when a Work Detail is "Only Selected Does This" but has nobody assigned.
--@ module = false
--[[
empty-labor-notification

Registers a notification (name: "empty_labor") into DFHack's gui/notify panel, alongside
"needs a tomb" and the planned-building order warnings. It alerts when any Work Detail is
set to "Only Selected Does This" but has NO assigned workers -- so that labor silently never
gets done.
    * exactly one   -> 'Work detail "Masonry" has no workers!'
    * more than one -> '3 work details have no workers!'

Clicking the notification lists the offending details and the labors they cover. (A detail
you genuinely want nobody to do should be set to "Nobody Does This", which does NOT warn.)

Run once per DFHack session to register; magnus-scripts loads it. To make it permanent on
its own, add `empty-labor-notification` to dfhack-config/init/dfhack.init.
]]

local NAME = 'empty_labor'

local dlg = require('gui.dialogs')

-- ---------------------------------------------------------------------------
-- detection: details set to OnlySelectedDoesThis with no assigned units
-- ---------------------------------------------------------------------------

local function scan()
    local out = {}
    local wds = df.global.plotinfo.labor_info.work_details
    for i = 0, #wds - 1 do
        local w = wds[i]
        if w.flags.mode == df.work_detail_mode.OnlySelectedDoesThis
            and #w.assigned_units == 0 then
            out[#out + 1] = w
        end
    end
    return out
end

local function empty_labor_message()
    if not dfhack.world.isFortressMode() then return end
    local list = scan()
    local n = #list
    if n == 0 then return end
    if n == 1 then
        return ('Work detail "%s" has no workers!'):format(list[1].name)
    end
    return ('%d work details have no workers!'):format(n)
end

-- ---------------------------------------------------------------------------
-- click dialog: list the offending details + the labors they cover
-- ---------------------------------------------------------------------------

-- the labors a detail covers, as a readable list ("mason, stone detailing")
local function labor_names(w)
    local names = {}
    for lname, on in pairs(w.allowed_labors) do
        if on == true then
            names[#names + 1] = tostring(lname):lower():gsub('_', ' ')
        end
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ', ') or '(no labors)'
end

local function show_dialog()
    local list = scan()
    if #list == 0 then return end
    local lines = {
        'These Work Details are set to "Only Selected Does This" but have NO assigned',
        'workers, so their labors never get done. Assign someone, switch them to',
        '"Everybody Does This", or set "Nobody Does This" to silence this warning.',
        '',
    }
    for _, w in ipairs(list) do
        lines[#lines + 1] = ('  %s  --  %s'):format(w.name, labor_names(w))
    end
    dlg.showMessage('Work details with no workers', table.concat(lines, '\n'), COLOR_YELLOW)
end

-- ---------------------------------------------------------------------------
-- registration (idempotent; survives notify-module reloads via onStateChange)
-- ---------------------------------------------------------------------------

local function register()
    local nmod = reqscript('internal/notify/notifications')
    local entry = nmod.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(nmod.NOTIFICATIONS_BY_IDX, entry)
        nmod.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    -- (re)assign callbacks every time so re-running the script picks up edits
    entry.desc = 'Notifies when a work detail is "Only Selected Does This" but has no assigned workers.'
    entry.dwarf_fn = empty_labor_message
    entry.on_click = show_dialog
    -- the overlay gates on config.data[name].enabled; make sure it exists so it's on by default
    if nmod.config and nmod.config.data and not nmod.config.data[NAME] then
        nmod.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()

-- re-apply if the notify module is reloaded on a new world/map load
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

print('empty-labor-notification: "empty_labor" registered.')
print('Warns when a work detail is "Only Selected Does This" with no assigned workers.')
print('Click the notification for the list. Add to dfhack.init to load it every session.')
