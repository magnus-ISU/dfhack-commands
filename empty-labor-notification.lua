-- Warn when a Work Detail is "Only Selected Does This" but has no usable worker.
--@ module = false
--[[
empty-labor-notification

Registers a notification (name: "empty_labor") into DFHack's gui/notify panel, alongside
"needs a tomb" and the planned-building order warnings. It alerts when any Work Detail is set
to "Only Selected Does This" but has no living, civilian worker to actually do it -- because:
    * nothing is selected, or
    * the selected dwarves have all died / left, or
    * the only selected dwarves are MILITARY (in a squad) -- they're off training/fighting,
      so the labor still doesn't get done.
Messages:
    * exactly one   -> 'Work detail "Masonry" has no available workers!'
    * more than one -> '3 work details have no available workers!'

Clicking the notification lists the offending details and the labors they cover. (A detail
you genuinely want nobody to do should be set to "Nobody Does This", which does NOT warn.)
The pack's "Military" detail is exempt -- it is meant to hold only soldiers.

Run once per DFHack session to register; magnus-scripts loads it. To make it permanent on
its own, add `empty-labor-notification` to dfhack-config/init/dfhack.init.
]]

local NAME = 'empty_labor'
-- the pack's "Military" work detail is *meant* to hold only soldiers (labor-groups creates it,
-- military-labor syncs squad members into it), so never flag it for being soldier-only.
local MILITARY_DETAIL = 'Military'

local dlg = require('gui.dialogs')

-- ---------------------------------------------------------------------------
-- detection: details set to OnlySelectedDoesThis with no usable worker
-- ---------------------------------------------------------------------------

-- A detail's labor only gets done by a living worker the fort can actually put on it: a
-- citizen or resident (residents -- e.g. a joined "cursed hunter" -- aren't citizens but do
-- the work) who is NOT a soldier. Dead/expelled units linger in assigned_units but don't
-- count; and a military dwarf (in a squad) is off training/on duty, so a detail whose only
-- live assignees are soldiers effectively goes unworked too. All of these are flagged.
local function has_available_worker(w)
    for _, uid in ipairs(w.assigned_units) do
        local u = df.unit.find(uid)
        if u and not dfhack.units.isDead(u)
            and (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
            and u.military.squad_id < 0 then        -- skip soldiers (in a squad)
            return true
        end
    end
    return false
end

local cache = {frame = -1, list = nil}   -- recompute at most once per frame (cheap, but called often)
local function scan()
    local f = df.global.world.frame_counter or 0
    if f == cache.frame and cache.list then return cache.list end
    local out = {}
    local wds = df.global.plotinfo.labor_info.work_details
    for i = 0, #wds - 1 do
        local w = wds[i]
        if w.flags.mode == df.work_detail_mode.OnlySelectedDoesThis
            and w.name ~= MILITARY_DETAIL                 -- soldier-only by design
            and not has_available_worker(w) then
            out[#out + 1] = w
        end
    end
    cache.frame, cache.list = f, out
    return out
end

local function empty_labor_message()
    if not dfhack.world.isFortressMode() then return end
    local list = scan()
    local n = #list
    if n == 0 then return end
    if n == 1 then
        return ('Work detail "%s" has no available workers!'):format(list[1].name)
    end
    return ('%d work details have no available workers!'):format(n)
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
        'These Work Details are set to "Only Selected Does This" but have no living civilian',
        'worker to do them -- nothing selected, the selected dwarves have died/left, or the',
        'only ones selected are soldiers (who are off on military duty). Assign a civilian,',
        'switch to "Everybody Does This", or set "Nobody Does This" to silence this warning.',
        '',
    }
    for _, w in ipairs(list) do
        lines[#lines + 1] = ('  %s  --  %s'):format(w.name, labor_names(w))
    end
    dlg.showMessage('Work details with no available workers', table.concat(lines, '\n'), COLOR_YELLOW)
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
    entry.desc = 'Notifies when an "Only Selected Does This" work detail has no usable worker (none, all dead, or only soldiers).'
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
print('Warns when an "Only Selected" work detail has no available worker (none/dead/only soldiers).')
print('Click the notification for the list. Add to dfhack.init to load it every session.')
