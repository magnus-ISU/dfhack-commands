-- Warn when a Work Detail is "Only Selected Does This" but has no usable worker.
--@ module = false
--[[
empty-labor-notification

Registers a notification (name: "empty_labor") into DFHack's gui/notify panel, alongside
"needs a tomb" and the planned-building order warnings. It alerts when any Work Detail is set
to "Only Selected Does This" but has no living, civilian worker to actually do it -- because:
    * nothing is selected, or
    * the selected dwarves have all died / left, or
    * the only selected dwarves are soldiers whose military SCHEDULE keeps them on active duty --
      with no Ready (off-duty) month this month or next -- so the labor doesn't get done. A soldier
      who cycles back to Ready within the next month (e.g. any squad on the even/odd-month routines)
      still does the work in a Ready month, so those details are NOT flagged.
Messages:
    * exactly one   -> 'Work detail "Masonry" has no available workers!'
    * more than one -> '3 work details have no available workers!'

Clicking the notification lists the offending details and the labors they cover. (A detail
you genuinely want nobody to do should be set to "Nobody Does This", which does NOT warn.)
The pack's "Military" detail is exempt -- it is meant to hold only soldiers.

The whole warning goes quiet while `autolabor` or `labormanager` is enabled: those plugins
hand out labors themselves and ignore work details, so an unstaffed detail says nothing
about whether the work gets done.

Run once per DFHack session to register; magnus-scripts loads it. To make it permanent on
its own, add `empty-labor-notification` to dfhack-config/init/dfhack.init.
]]

local NAME = 'empty_labor'
-- the pack's "Military" work detail is *meant* to hold only soldiers (labor-groups creates it,
-- military-labor syncs squad members into it), so never flag it for being soldier-only.
local MILITARY_DETAIL = 'Military'

-- A labor plugin assigns labors itself and pays no attention to work details, so while one
-- is running an unstaffed "Only Selected" detail means nothing and the warning stays hidden.
local LABOR_PLUGINS = {'autolabor', 'labormanager'}
-- Re-ask on a REAL-TIME clock, not frame_counter: the plugin is usually toggled from a
-- paused game, and frame_counter does not advance while paused -- a frame-based cache
-- would hold the pre-toggle answer until the player unpaused.
local PLUGIN_RECHECK_MS = 1000

local dlg = require('gui.dialogs')

-- ---------------------------------------------------------------------------
-- autolabor / labormanager detection
-- ---------------------------------------------------------------------------

-- is the plugin present at all? (labormanager is absent from some builds; asking `plug`
-- about it every second would be a wasted command)
local function plugin_loaded(name)
    local ok, list = pcall(dfhack.internal.listPlugins)
    if not ok or type(list) ~= 'table' then return true end   -- can't tell -> assume it is
    for _, p in ipairs(list) do
        if p == name then return true end
    end
    return false
end

local function plugin_enabled(name)
    if not plugin_loaded(name) then return false end
    -- a plugin that ships a lua wrapper (autolabor) answers directly
    local ok, mod = pcall(require, 'plugins.' .. name)
    if ok and type(mod) == 'table' and mod.isEnabled then
        local ok_call, on = pcall(mod.isEnabled)
        if ok_call then return on end
    end
    -- no wrapper (labormanager has none): ask `plug`, which prints one row per plugin
    -- PRESENT IN THIS BUILD -- "<name> loaded <n> enabled" -- and nothing at all when the
    -- plugin does not exist. The frontier pattern is what keeps "disabled" from matching.
    local ok_cmd, out = pcall(dfhack.run_command_silent, 'plug', name)
    if not ok_cmd or type(out) ~= 'string' then return false end
    for line in out:gmatch('[^\r\n]+') do
        if line:match('^' .. name .. '%s') and line:match('%f[%a]enabled%s*$') then
            return true
        end
    end
    return false
end

local plugin_cache = {ms = nil, name = nil}
local function labor_plugin_running()
    local now = dfhack.getTickCount()
    if plugin_cache.ms and now >= plugin_cache.ms and now - plugin_cache.ms < PLUGIN_RECHECK_MS then
        return plugin_cache.name
    end
    local found
    for _, p in ipairs(LABOR_PLUGINS) do
        if plugin_enabled(p) then
            found = p
            break
        end
    end
    plugin_cache.ms, plugin_cache.name = now, found
    return found
end

-- ---------------------------------------------------------------------------
-- detection: details set to OnlySelectedDoesThis with no usable worker
-- ---------------------------------------------------------------------------

-- A soldier still counts as an available worker if the MILITARY SCHEDULE will make them Ready
-- (off-duty -- doing civilian jobs in their armour) this month or next. Any squad on the
-- even-month/odd-month routines is Ready every other month, so a Ready month is always at most one
-- month away and the labour still gets done; only a soldier who stays on active duty with no Ready
-- month this month or next (e.g. Constant training) is treated as unavailable. We read the squad's
-- own schedule, not the "Military" work-detail labor -- an active-duty soldier who cycles back to
-- Ready soon should NOT trigger the warning.
local MONTH_TICKS = 33600   -- 403200 game ticks/year / 12 months
local function ready_soon(u)
    local sqid = u.military and u.military.squad_id or -1
    if sqid < 0 then return true end                    -- not in a squad -> a plain civilian worker
    local sq = df.squad.find(sqid)
    if not sq then return true end
    -- Bounds-check BEFORE indexing: a df vector THROWS on an out-of-range index, it does not
    -- return nil, so the `if not routine` guard below can never fire on its own. A citizen can
    -- belong to a squad that is not the fortress's (a soldier who joined the fort keeps the
    -- squad_id of their old civ's squad), and those foreign/worldgen squads carry an EMPTY
    -- routine vector with cur_routine_idx 0 -- routine[0] then throws. That matters far beyond
    -- this warning: gui/notify calls every dwarf_fn UNPROTECTED, so one throwing callback
    -- aborts the overlay update and blanks the whole notification panel, DFHack's own
    -- notifications included.
    local routines = sq.schedule.routine
    local ridx = sq.cur_routine_idx
    if ridx < 0 or ridx >= #routines then return true end   -- no readable schedule -> don't warn
    local routine = routines[ridx]
    if not routine then return true end                 -- can't read a schedule -> don't warn
    local pos = u.military.squad_position
    local cur = math.floor((df.global.cur_year_tick or 0) / MONTH_TICKS) % 12
    for _, m in ipairs{cur, (cur + 1) % 12} do          -- Ready this month or next = "within the next month"
        local e = routine.month[m]
        if e then
            local oa = e.order_assignments
            -- a month is "Ready" for this soldier when their position has no assigned order (-1);
            -- fall back to "the month has no orders at all" if we can't index their position.
            local ready = (pos >= 0 and pos < #oa) and (oa[pos].assigned_order_idx == -1)
                or (not (pos >= 0 and pos < #oa) and #e.orders == 0)
            if ready then return true end
        end
    end
    return false
end

-- A detail's labor only gets done by a living worker the fort can actually put on it: a citizen or
-- resident (residents -- e.g. a joined "cursed hunter" -- aren't citizens but do the work) that is
-- either not a soldier or is a soldier whose schedule makes them Ready within the next month (see
-- ready_soon). Dead/expelled units linger in assigned_units but don't count. All such "unworkable"
-- details are flagged.
local function has_available_worker(w)
    for _, uid in ipairs(w.assigned_units) do
        local u = df.unit.find(uid)
        if u and not dfhack.units.isDead(u)
            and (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
            and ready_soon(u) then
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
            and w.name ~= MILITARY_DETAIL                 -- the grouping detail itself; soldier-only by design
            and not has_available_worker(w) then
            out[#out + 1] = w
        end
    end
    cache.frame, cache.list = f, out
    return out
end

local function empty_labor_message()
    if not dfhack.world.isFortressMode() then return end
    if labor_plugin_running() then return end   -- the plugin decides who works, not the details
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
    local plugin = labor_plugin_running()
    if plugin then
        dlg.showMessage('Work details with no available workers',
            ('%s is enabled, so it assigns labors itself and work details are ignored.\n' ..
             'This warning stays hidden until you `disable %s`.'):format(plugin, plugin),
            COLOR_YELLOW)
        return
    end
    local list = scan()
    if #list == 0 then return end
    local lines = {
        'These Work Details are set to "Only Selected Does This" but have no living worker to',
        'do them -- nothing selected, the selected dwarves have died/left, or the only ones',
        'selected are soldiers whose schedule keeps them on active duty (no Ready month this',
        'month or next). Assign a free dwarf, switch to "Everybody Does This", or set "Nobody',
        'Does This" to silence this warning.',
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
    entry.desc = 'Notifies when an "Only Selected Does This" work detail has no usable worker (none, all dead, or only soldiers who stay on active duty -- soldiers Ready within the next month still count). Silent while autolabor or labormanager is enabled.'
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
print('Stays hidden while autolabor or labormanager is enabled.')
print('Click the notification for the list. Add to dfhack.init to load it every session.')
