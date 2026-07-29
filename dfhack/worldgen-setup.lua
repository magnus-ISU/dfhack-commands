-- Drive DF's world-creation screens: enable every mod, max the civ/site sliders, generate.
--@module = true
--[[
worldgen-setup
==============

Tags: worldgen | tools

Automates the "make a fresh test world with the whole mod suite loaded" chore, which is
otherwise a long click-through every time a raw changes.

Two mechanisms, chosen per step:

* **Data, where DF exposes it.** `viewscreen_new_regionst` keeps the available mods and
  the selected load order as parallel vectors, and the Basic screen's sliders as plain
  ints, so "select everything" is a copy and "max the sliders" is an assignment. No
  clicking, nothing to mis-target.
* **Synthetic clicks, where that works.** The title menu responds to a fed `_MOUSE_L`
  once `gps.mouse_x/y` is parked on the label, so `open` is automatic.

Known boundary: the world-creation screen itself ignores synthetic input entirely. Its
buttons and sliders are widgets driven by real SDL mouse events, not by fed keys -- a fed
click on "Low" does not even move a slider, and neither holding `enabler.mouse_lbut` nor
any interface key reaches the Create-world button (there are no worldgen interface keys at
all). So the last step is yours: press **Create world**. Everything before it, including
the mod list and the sliders that button acts on, is set from data.

Usage::

    worldgen-setup status            what screen are we on, what is selected
    worldgen-setup open              from the title screen, open world creation
    worldgen-setup mods              select every available mod (skips fork sources)
    worldgen-setup mods all          ...including upstream fork sources
    worldgen-setup unselect <id>     drop one mod from the load order
    worldgen-setup params            civilizations and sites to max
    worldgen-setup params all        every slider to max (slow: Large world, 500 years)
    worldgen-setup generate          try the button, and report if it needs a human
    worldgen-setup all               open + mods + params, then hand over
    worldgen-setup verify            after generation, list the mods the world loaded

Each step re-checks the screen and is safe to re-run, so a partial run can be resumed.
]]

local gui = require('gui')

-- Every slider on the Basic screen offers five choices; 0 is the leftmost.
local SLIDER_MAX = 4
local SLIDERS = {
    'simple_world_size', 'simple_history', 'simple_civ_num', 'simple_site_cap',
    'simple_beast', 'simple_savagery', 'simple_minerals',
}
-- What `params` touches by default: only what was asked for. Maxing world size and
-- history as well makes generation take many minutes, so that needs `params all`.
local DEFAULT_SLIDERS = {'simple_civ_num', 'simple_site_cap'}

-- the parallel vectors making up one entry of either mod list
local MOD_FIELDS = {
    'id', 'name', 'numeric_version', 'displayed_version',
    'earliest_compat_numeric_version', 'src_dir', 'mod_header',
}

-- vector<string> elements come back as string objects here, not Lua strings
local function str(v)
    if type(v) == 'string' then return v end
    local ok, r = pcall(function() return v.value end)
    return ok and r or tostring(v)
end

local function focus()
    return dfhack.gui.getCurFocus(true)[1] or '?'
end

local function region_screen()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs do
        if df.viewscreen_new_regionst:is_instance(vs) then return vs end
        vs = vs.parent
    end
end

-- ------------------------------------------------------------ text/clicks ----

local function grid_rows()
    local w, h = dfhack.screen.getWindowSize()
    local rows = {}
    for y = 0, h - 1 do
        local out = {}
        for x = 0, w - 1 do
            local p = dfhack.screen.readTile(x, y)
            local c = p and p.ch or 0
            out[#out + 1] = (c >= 32 and c < 127) and string.char(c) or ' '
        end
        rows[y] = table.concat(out)
    end
    return rows
end

-- Find `label` on the text grid and left-click its centre. DF's newer widget menus do
-- not respond to simulated key events, but they do respond to this.
local function click_text(label)
    for y, row in pairs(grid_rows()) do
        local a, b = row:find(label, 1, true)
        if a then
            local gps = df.global.gps
            gps.mouse_x = math.floor((a - 1 + b - 1) / 2)
            gps.mouse_y = y
            gui.simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
            return true, gps.mouse_x, y
        end
    end
    return false
end

-- ---------------------------------------------------------------- status ----

function status()
    print(('focus: %s'):format(focus()))
    local vs = region_screen()
    if not vs then
        print('not on the world-creation screen')
        return false
    end
    print(('available mods: %d   load order: %d')
        :format(#vs.available_id, #vs.object_load_order_id))
    local sel, have = {}, {}
    for i = 0, #vs.object_load_order_id - 1 do
        local id = str(vs.object_load_order_id[i])
        have[id] = true
        if not id:find('^vanilla') then sel[#sel + 1] = id end
    end
    print('non-vanilla in load order: ' .. (#sel > 0 and table.concat(sel, ', ') or '(none)'))
    local missing = {}
    for i = 0, #vs.available_id - 1 do
        local id = str(vs.available_id[i])
        if not have[id] then missing[#missing + 1] = id end
    end
    print('available but not selected: ' .. (#missing > 0 and table.concat(missing, ', ') or '(none)'))
    local parts = {}
    for _, f in ipairs(SLIDERS) do parts[#parts + 1] = ('%s=%d'):format(f, vs[f]) end
    print('sliders: ' .. table.concat(parts, ' '))
    return true
end

-- ------------------------------------------------------------------ open ----

function open()
    if region_screen() then
        print('world-creation screen already open')
        return true
    end
    if not df.viewscreen_titlest:is_instance(dfhack.gui.getCurViewscreen(true)) then
        qerror('not on the title screen (focus: ' .. focus() .. ')')
    end
    if not click_text('Create new world') then
        qerror('could not find "Create new world" on screen')
    end
    if region_screen() then
        print('opened world creation')
        return true
    end
    print('click did not open world creation; still on ' .. focus())
    return false
end

-- ------------------------------------------------------------------ mods ----

-- Upstream mods kept in installed_mods purely as fork sources. Loading one alongside the
-- fork that derives from it duplicates its creatures, so they are skipped unless asked
-- for explicitly with `mods all`.
local FORK_SOURCES = {
    nauts_procedural_dragons_dragonfire_only = true,
}

-- Drop a mod from the load order by id (all its parallel vector entries).
function unselect(id)
    local vs = region_screen()
    if not vs then qerror('not on the world-creation screen') end
    for i = #vs.object_load_order_id - 1, 0, -1 do
        if str(vs.object_load_order_id[i]) == id then
            for _, f in ipairs(MOD_FIELDS) do
                local v = vs['object_load_order_' .. f]
                if v then v:erase(i) end
            end
            print(('removed %s from the load order'):format(id))
            return true
        end
    end
    print(('%s was not in the load order'):format(id))
    return false
end

function mods(mode)
    local vs = region_screen()
    if not vs then qerror('not on the world-creation screen (focus: ' .. focus() .. ')') end
    local have = {}
    for i = 0, #vs.object_load_order_id - 1 do
        have[str(vs.object_load_order_id[i])] = true
    end
    local added, skipped = {}, {}
    for i = 0, #vs.available_id - 1 do
        local id = str(vs.available_id[i])
        if FORK_SOURCES[id] and mode ~= 'all' then
            skipped[#skipped + 1] = id
        elseif not have[id] then
            for _, f in ipairs(MOD_FIELDS) do
                local src, dst = vs['available_' .. f], vs['object_load_order_' .. f]
                if src and dst then dst:insert('#', src[i]) end
            end
            have[id] = true
            added[#added + 1] = id
        end
    end
    print(('added %d mod(s): %s'):format(#added, table.concat(added, ', ')))
    if #skipped > 0 then
        print(('skipped %d fork source(s): %s  (use `mods all` to include)')
            :format(#skipped, table.concat(skipped, ', ')))
    end
    print(('load order is now %d entries'):format(#vs.object_load_order_id))
    return true
end

-- ---------------------------------------------------------------- params ----

function params(mode)
    local vs = region_screen()
    if not vs then qerror('not on the world-creation screen (focus: ' .. focus() .. ')') end
    local list = (mode == 'all') and SLIDERS or DEFAULT_SLIDERS
    local out = {}
    for _, f in ipairs(list) do
        vs[f] = SLIDER_MAX
        out[#out + 1] = ('%s=%d'):format(f, vs[f])
    end
    print('set to max: ' .. table.concat(out, ' '))
    if mode ~= 'all' then
        print('(world size, history, beasts, savagery and minerals left alone; '
           .. 'use `params all` to max those too)')
    end
    return true
end

-- -------------------------------------------------------------- generate ----

-- The Create-world button is a widget fed by real SDL mouse events, so this can only
-- try; it reports honestly rather than claiming a generation that never started.
function generate()
    local vs = region_screen()
    if not vs then qerror('not on the world-creation screen (focus: ' .. focus() .. ')') end
    if not click_text('Create world') then
        qerror('could not find the "Create world" button on screen')
    end
    if not region_screen() then
        print('generation started')
        return true
    end
    print('the Create world button did not respond to a synthetic click -- it never does;')
    print('everything else is set, so click "Create world" yourself (bottom right),')
    print('then run `worldgen-setup verify` to confirm the mods loaded.')
    return false
end

-- ---------------------------------------------------------------- verify ----

-- After generation, report which mods the world actually loaded. This is the only check
-- that proves the load-order edit took effect rather than being rebuilt by DF.
function verify()
    local ol = df.global.world.object_loader
    local mods = {}
    for _, d in ipairs(ol.object_load_order_src_dir) do
        local s = str(d)
        if s:find('installed_mods') then
            mods[#mods + 1] = s:match('installed_mods/([^/]+)') or s
        end
    end
    print(('world loaded %d non-vanilla mod(s):'):format(#mods))
    for _, m in ipairs(mods) do print('   ' .. m) end
    return #mods > 0
end

-- ------------------------------------------------------------------ main ----

function all(mode)
    if not region_screen() and not open() then return false end
    mods(mode)
    params(mode)
    status()
    print('')
    print('ready -- click "Create world" (bottom right) to generate,')
    print('then run `worldgen-setup verify`.')
    return true
end

local ACTIONS = {status = status, open = open, mods = mods, params = params,
                 generate = generate, verify = verify, all = all, unselect = unselect}

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local action = args[1] or 'status'
local fn = ACTIONS[action]
if not fn then
    qerror('unknown action: ' .. action
        .. ' (status/open/mods/params/generate/verify/all)')
end
fn(table.unpack(args, 2))
