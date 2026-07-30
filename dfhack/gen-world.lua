-- One command to go from the title screen to a paused fort in a fresh modded world.
--@module = true
--[[
gen-world
=========

Tags: worldgen | tools

Builds a test world and drops you into it, so a raws change can be checked without the
long click-through. Written after doing it by hand: the mod list and the world sliders
are set by writing `viewscreen_new_regionst`'s own fields, and only the buttons that have
no data equivalent are pressed, with a fed `_MOUSE_L` on the label found on the text grid.

Usage::

    gen-world civilizations=max sites=max mods=ha fortress dwarves
    gen-world                                  -- same defaults as above
    gen-world civilizations=max sites=max mods=all everything=max fortress
    gen-world status                           -- where are we in the flow
    gen-world embark dwarves                   -- title -> paused fort in the newest world
    gen-world embark dwarves Lulespandire      -- ...in a named world
    gen-world pause                            -- pause once the fort loads

Options (all optional, any order):

:civilizations=: ``max`` | ``min`` | 0-4     how many civs the world gets
:sites=:         ``max`` | ``min`` | 0-4     the site cap
:history=:       ``max`` | ``min`` | 0-4     min is 5 years -- handy for asking "did this
                                             civ ever get placed?" without waiting for
                                             history to kill it off
:worldsize=: :beasts=: :savagery=: :minerals=:   the remaining sliders
:everything=:    ``max`` | ``min``           every slider not named explicitly
:mods=:          ``ha`` | ``all`` | ``none`` ``ha`` selects every installed mod except
                                             upstream fork sources, ``all`` includes them
:fortress: / :adventure:                     which mode to start (default fortress)
:dwarves: / :humans: / ...                   which civilization to play

Known gotcha, and it cost an hour the first time: DF's first-run **"Welcome to Dwarf
Fortress" panel is modal and swallows every input**, fed ones included. Nothing dismisses
it programmatically -- there is no flag for it on the viewscreen and no tutorial field on
`init`/`d_init`/`game`/`plotinfo`/`gview`/`enabler` -- and xdotool cannot help either,
since on Wayland it moves DF's pointer (DF polls the cursor position) but no button or key
event ever reaches the process. So this command detects the panel and asks you to click
its Okay once. Every OTHER popup in the flow (the tutorial offer, "On your own!", the
aquifer warning) does take a fed click and is handled automatically.

Also do not use the post-worldgen "Play now" shortcut: on a 232-civilization world it
crashed DF outright. `embark` deliberately keeps the world, returns to the title screen and
loads it, which is the path that works.
]]

local gui = require('gui')

local SLIDER_MAX, SLIDER_MIN = 4, 0
local SLIDERS = {
    civilizations = 'simple_civ_num',
    sites         = 'simple_site_cap',
    history       = 'simple_history',     -- min = 5 years, max = 500
    worldsize     = 'simple_world_size',
    beasts        = 'simple_beast',
    savagery      = 'simple_savagery',
    minerals      = 'simple_minerals',
}
local OTHER_SLIDERS = {
    'simple_world_size', 'simple_history', 'simple_beast',
    'simple_savagery', 'simple_minerals',
}
local MOD_FIELDS = {
    'id', 'name', 'numeric_version', 'displayed_version',
    'earliest_compat_numeric_version', 'src_dir', 'mod_header',
}
-- upstream mods kept only as fork sources; loading one beside its fork duplicates content
local FORK_SOURCES = {nauts_procedural_dragons_dragonfire_only = true}

local RACE_ALIASES = {
    dwarves = 'DWARF', dwarf = 'DWARF', humans = 'HUMAN', human = 'HUMAN',
    elves = 'ELF', elf = 'ELF', goblins = 'GOBLIN', goblin = 'GOBLIN',
    kobolds = 'HA_KOBOLD', ['high-elves'] = 'HA_HIGH_ELF', highelves = 'HA_HIGH_ELF',
    orcs = 'HA_ORC', drow = 'HA_DROW', illithids = 'HA_ILLITHID',
    succubi = 'HA_SUCCUBUS', ['dark-dwarves'] = 'HA_DARK_DWARF',
}

local function str(v)
    if type(v) == 'string' then return v end
    local ok, r = pcall(function() return v.value end)
    return ok and r or tostring(v)
end

local function focus() return dfhack.gui.getCurFocus(true)[1] or '?' end

local function region_screen()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs do
        if df.viewscreen_new_regionst:is_instance(vs) then return vs end
        vs = vs.parent
    end
end

-- ------------------------------------------------------------ screen text ----

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

-- `from_bottom` matters: several screens repeat a button's word in their help text (the
-- embark screen says 'Click "Embark" to place your fortress'), and the button is lower.
local function find_label(label, from_bottom)
    local rows = grid_rows()
    local _, h = dfhack.screen.getWindowSize()
    local order = {}
    for y = 0, h - 1 do order[#order + 1] = from_bottom and (h - 1 - y) or y end
    for _, y in ipairs(order) do
        local row = rows[y]
        -- NB: `row and row:find(...)` would truncate to a single return value and leave
        -- the end index nil, so the nil check has to come first
        if row then
            local a, b = row:find(label, 1, true)
            if a then return math.floor((a - 1 + b - 1) / 2), y end
        end
    end
end

-- Click a label by parking DF's own cursor on it and feeding a mouse event. Works on
-- every screen tested EXCEPT while the modal welcome panel is up.
local function click(label, from_bottom)
    local cx, cy = find_label(label, from_bottom)
    if not cx then return false end
    df.global.gps.mouse_x, df.global.gps.mouse_y = cx, cy
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
    return true
end

local function modal_blocked()
    for _, row in pairs(grid_rows()) do
        if row:find('Welcome to Dwarf Fortress', 1, true) then return true end
    end
    return false
end

-- Click a raw screen cell (used for the two map clicks, which have no label).
local function click_cell(cx, cy)
    df.global.gps.mouse_x, df.global.gps.mouse_y = cx, cy
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
end

-- DF throws several one-button popups through the embark flow (the tutorial offer, the
-- "On your own!" notice, the aquifer warning). All of them take a fed click, unlike the
-- first-run welcome panel.
local function dismiss_popups()
    for _ = 1, 6 do
        local hit = false
        for _, label in ipairs({'Skip tutorial', 'Confirm', 'Okay'}) do
            if find_label(label) and click(label) then hit = true break end
        end
        if not hit then return end
    end
end

-- ------------------------------------------------------------------ steps ----

function status()
    print('focus: ' .. focus())
    if modal_blocked() then
        print('BLOCKED: the modal welcome panel is up -- click its Okay button once')
    end
    local vs = region_screen()
    if not vs then return false end
    local sel = {}
    for i = 0, #vs.object_load_order_id - 1 do
        local id = str(vs.object_load_order_id[i])
        if not id:find('^vanilla') then sel[#sel + 1] = id end
    end
    print(('load order: %d entries, non-vanilla: %s')
        :format(#vs.object_load_order_id, #sel > 0 and table.concat(sel, ', ') or '(none)'))
    print(('civilizations=%d sites=%d world_size=%d history=%d')
        :format(vs.simple_civ_num, vs.simple_site_cap, vs.simple_world_size, vs.simple_history))
    return true
end

local function open_creation()
    if region_screen() then return true end
    if not df.viewscreen_titlest:is_instance(dfhack.gui.getCurViewscreen(true)) then
        qerror('expected the title screen or world creation, but focus is ' .. focus())
    end
    click('Create new world')
    return region_screen() ~= nil
end

-- Copy a value out of the available-mod list rather than aliasing it.
--
-- This matters a great deal. The string vectors hold POINTERS, so inserting `src[i]`
-- straight into the load order puts the *same* std::string into two vectors. DF then
-- shows the mod as both available and selected, and on teardown frees it twice -- which
-- is the `free(): invalid pointer` abort that killed several sessions at export_region.
-- Allocate a fresh string and give DF sole ownership of it.
local function copy_entry(v)
    if type(v) ~= 'userdata' then return v end            -- numbers and Lua strings
    local ok, dup = pcall(function()
        local probe = v.value                              -- only std::string has .value
        local x = df.new('string')
        x.value = probe
        return x
    end)
    if ok and dup then return dup end
    return v            -- mod_header is a struct, not a string: share the pointer
end

local function apply_mods(mode)
    if mode == 'none' then print('mods: leaving the load order alone'); return end
    local vs = region_screen()
    local have = {}
    for i = 0, #vs.object_load_order_id - 1 do have[str(vs.object_load_order_id[i])] = true end
    local added, skipped = {}, {}
    -- DF lists a mod once per copy it can see: the live one under mods/ and any
    -- older snapshot left in data/installed_mods. Same id, different version. Take
    -- the newest, or worldgen silently runs on stale raws.
    local best = {}
    for i = 0, #vs.available_id - 1 do
        local id = str(vs.available_id[i])
        local ver = tonumber(vs.available_numeric_version[i]) or 0
        if not best[id] or ver > best[id].ver then best[id] = {idx = i, ver = ver} end
    end
    for id, pick in pairs(best) do
        if FORK_SOURCES[id] and mode ~= 'all' then
            skipped[#skipped + 1] = id
        elseif not have[id] then
            for _, f in ipairs(MOD_FIELDS) do
                local s, d = vs['available_' .. f], vs['object_load_order_' .. f]
                if s and d then d:insert('#', copy_entry(s[pick.idx])) end
            end
            have[id] = true
            added[#added + 1] = ('%s v%d'):format(id, pick.ver)
        end
    end
    table.sort(added)
    print(('mods: added %d (%s)'):format(#added, table.concat(added, ', ')))
    if #skipped > 0 then
        print(('mods: skipped fork source(s) %s -- use mods=all to include')
            :format(table.concat(skipped, ', ')))
    end
end

local function slider_value(word)
    if word == 'max' then return SLIDER_MAX end
    if word == 'min' then return SLIDER_MIN end
    local n = tonumber(word)
    if n and n >= 0 and n <= SLIDER_MAX then return math.floor(n) end
    qerror('slider value must be max, min or 0-' .. SLIDER_MAX .. ', got: ' .. tostring(word))
end

local function apply_params(opts)
    local vs = region_screen()
    local out = {}
    for name, field in pairs(SLIDERS) do
        if opts[name] then
            vs[field] = slider_value(opts[name])
            out[#out + 1] = ('%s=%d'):format(name, vs[field])
        end
    end
    if opts.everything then
        local v = slider_value(opts.everything)
        for _, f in ipairs(OTHER_SLIDERS) do vs[f] = v end
        out[#out + 1] = ('everything=%d'):format(v)
    end
    print('params: ' .. (#out > 0 and table.concat(out, ' ') or '(defaults kept)'))
end

-- ------------------------------------------------------------------- main ----

local function parse(args)
    local opts, flags = {}, {}
    for _, a in ipairs(args) do
        local k, v = a:match('^([%w_]+)=(.+)$')
        if k then opts[k:lower()] = v:lower() else flags[a:lower()] = true end
    end
    return opts, flags
end

function run(...)
    local args = {...}
    if args[1] == 'status' then return status() end
    local opts, flags = parse(args)
    opts.civilizations = opts.civilizations or 'max'
    opts.sites = opts.sites or 'max'
    opts.mods = opts.mods or 'ha'

    if modal_blocked() then
        print('DF\'s modal "Welcome to Dwarf Fortress" panel is up. It swallows every input,')
        print('including fed clicks, and nothing dismisses it programmatically. Click its')
        print('Okay button once, then re-run this command.')
        return false
    end
    if not open_creation() then
        qerror('could not open the world-creation screen (focus: ' .. focus() .. ')')
    end
    apply_mods(opts.mods)
    apply_params(opts)

    local race = nil
    for word in pairs(flags) do
        if RACE_ALIASES[word] then race = RACE_ALIASES[word] end
    end
    print(('mode: %s%s'):format(flags.adventure and 'adventure' or 'fortress',
        race and (' as ' .. race) or ''))

    if not click('Create world') then qerror('no "Create world" button on screen') end
    print('generating -- this blocks DF for a while; poll `gen-world status`')
    print('when it finishes, embark with: gen-world embark ' .. (race or 'dwarves'))
    return true
end

-- ----------------------------------------------------------------- embark ----

-- The whole title-to-fort walk, in the order it actually works. Each step is a label
-- click; the two bare map clicks pick a region tile and then the embark rectangle.
-- NOTE: do not use the post-worldgen "Play now" shortcut -- it crashed DF outright on a
-- 232-civ world. Keep the world, then load it from the title screen as below.
function embark(race_word, world_name)
    local race = RACE_ALIASES[(race_word or 'dwarves'):lower()] or 'DWARF'
    local function step(desc, fn)
        print('  ' .. desc)
        fn()
        dfhack.timeout(1, 'frames', function() end)
    end
    if df.viewscreen_titlest:is_instance(dfhack.gui.getCurViewscreen(true)) then
        step('load the world', function()
            click('Start new game in existing world')
            if world_name then
                if not click(world_name) then
                    qerror('no world named "' .. world_name .. '" in the load list')
                end
            else
                -- no name given: take the last world in the list, which is the newest
                local rows, pick = grid_rows(), nil
                for y, row in pairs(rows) do
                    if row:find('World:', 1, true) then pick = y end
                end
                if not pick then qerror('could not find a world in the load list') end
                local a = rows[pick]:find('World:', 1, true)
                click_cell(a + 20, pick)
            end
        end)
    end
    step('fortress mode', function() click('Fortress') end)
    step('dismiss popups', dismiss_popups)
    step('choose civilization', function()
        click('Choose origin civilization', true)
        dismiss_popups()
        for word, id in pairs(RACE_ALIASES) do
            if id == race then
                local label = word:gsub('^%l', string.upper)
                if find_label(label) then click(label) break end
            end
        end
    end)
    step('zoom the map', function() click_cell(40, 30) end)
    step('press Embark', function() click('Embark', true) end)
    step('place the fort', function() click_cell(40, 30) end)
    step('confirm warnings', dismiss_popups)
    step('start with defaults', function() click('Play now!') end)
    print('watch for dwarfmode; then `gen-world pause`')
    return true
end

function pause()
    df.global.pause_state = true
    print('paused: ' .. tostring(df.global.pause_state)
        .. '  fort mode: ' .. tostring(dfhack.world.isFortressMode()))
end

if dfhack_flags and dfhack_flags.module then return end
local a = {...}
if a[1] == 'embark' then embark(a[2])
elseif a[1] == 'pause' then pause()
else run(...) end
