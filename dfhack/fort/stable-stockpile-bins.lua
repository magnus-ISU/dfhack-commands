-- Keep a stockpile's max bins/barrels/wheelbarrows at the number YOU set.
--@module = true
--@enable = true
--[[
DF recomputes a stockpile's container caps from scratch whenever anything touches
its filter -- one checkbox in the customize screen is enough -- so the "0 barrels"
you set quietly becomes "30 barrels" again later. This watches the three caps and
puts your number back.

    enable fort/stable-stockpile-bins    start watching (persists with the fort)
    disable fort/stable-stockpile-bins   stop
    fort/stable-stockpile-bins           toggle

The whole problem is telling apart the reasons a cap can change, and the one that
matters has an exact signal -- no game code is emulated:

  1. YOU changed it. Every cap edit goes through the "Storage and tools" side
     panel, which DF exposes as `main_interface.stockpile_tools` (its `bld_id` is
     the pile being edited). A change seen while that panel is open on the pile is
     yours: it becomes the new pinned number.

  2. Otherwise DF recomputed it off the back of a filter touch, and your number
     goes back. Deliberately NO assumption is made about the value DF writes: a
     single-category pile gets its tile count, but on a pile where bins AND
     barrels both apply DF may give each a share, so "it equals the tile count"
     is not a safe test for "DF just recomputed this". Only the panel decides.

  3. Except the cap genuinely stopped applying -- you asked for 5 bins and then
     made it a wood pile. DF writes 0 for that, the one value its recompute is
     pinned down to. That cap is RELEASED rather than pinned at 0, which would
     fight you the day you add a binnable category back.

  4. And except that the pin no longer fits. Containers sit on tiles, so the three
     caps together cannot exceed the tile count -- 6 pinned bins on a 10-tile pile
     DF has also given 5 barrels wants 11. There is no sensible number to write,
     so the pin is released and the pile goes back to being DF's.

The cost of (2) making no assumption is that a cap written by `quickfort` or
`stockpiles import` on an already-pinned pile is treated as a reset and put back;
`repin` adopts it if that is what you wanted.

A pile is only ever managed once you have set one of its caps by hand in the
Storage and tools panel. Until then DF owns the number and this does nothing at
all -- so placing a pile, or adding a category that newly wants bins, behaves
exactly as it does in vanilla.

Giving a pile NO TYPE hands it straight back to DF -- every pin is dropped and
its caps are DF's again, as if you had never set them. That is the in-game way to
undo a pin, and it is the state DF's own panel warns about ("Warning: stockpile
has no type"). It is watched as STATE, not as a click, so both routes to it work:
the "None" type icon, and clearing a pile out from the Custom settings screen.
Those two need slightly different tests, because DF's Custom-settings "None"
button empties a category but can leave its group flag set -- so a pile is also
treated as untyped when every flagged category is empty. Nothing is released
while that screen is open, since a pile can be momentarily empty mid-edit.

It is the type that counts, not the cap values: a Food pile holding nothing
barrelable also sits at 0 barrels, and it keeps its pin.

    fort/stable-stockpile-bins status         what is pinned, and what has drifted
    fort/stable-stockpile-bins repin [N|all]  pin a pile's caps as they are now
    fort/stable-stockpile-bins forget [N|all] drop the pin; DF owns the caps again
                                              (same as setting the type to None)
    fort/stable-stockpile-bins log on|off     print every restore (off by default)

N is the stockpile number DF shows on the pile's panel. With no N these act on the
selected stockpile, or on every pile if none is selected.
]]

local GLOBAL_KEY = 'stable-stockpile-bins'

-- how often the caps are sampled. Cheap: 3 ints per pile, and the tile count is
-- only ever counted for a pile whose cap just moved.
local SAMPLE_FRAMES = 4
-- a cap can commit a frame or two after the Storage-and-tools panel closes, so a
-- change just after it was open still counts as yours -- but only if it is not
-- DF's reset value, or a filter click right after an edit would steal the pin.
local GRACE_SCANS = 10
-- runaway guard only: if a pile's cap somehow keeps bouncing back, stop fighting it
local RESTORE_LIMIT, RESTORE_WINDOW = 200, 250   -- restores per pile+cap per ~1000 frames
-- how often a pinned, all-zero pile is checked for having been emptied out via the
-- Custom settings screen. That check reads a category's contents rather than just its
-- group flag, so it runs on a slow cadence instead of every pass.
local DEEP_SCAN_SCANS = 25   -- ~2s

-- the three caps, as {state key, df field, label}. The state key is what gets
-- persisted, so keep it short and stable.
local CAPS = {
    {key = 'b', field = 'max_bins',         label = 'bins'},
    {key = 'r', field = 'max_barrels',      label = 'barrels'},
    {key = 'w', field = 'max_wheelbarrows', label = 'wheelbarrows'},
}

enabled = enabled or false
generation = generation or 0
-- persisted: {pins = {[id] = {b=,r=,w=}}, log = bool}. A cap key is absent when DF
-- owns that cap -- a pin only ever appears once you have set the number yourself.
state = state or {pins = {}, log = false, loaded = false}
-- per-session: the last values we saw, so a change can be spotted at all
observed = observed or {}
restores = restores or 0
scans = scans or 0
runaway = runaway or {}          -- [id..key] = {n, window_start}; runaway guard
gave_up = gave_up or {}          -- [id] = true; stop managing for this session
deep_scan = deep_scan or {}      -- [id] = scan of the last emptied-out check

function isEnabled()
    return enabled
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function stockpiles()
    return df.global.world.buildings.other.STOCKPILE
end

-- The pile's real tile count -- its extents, not its bounding box. This is the
-- number DF resets a bin/barrel cap to, so it is the fingerprint of a reset. Only
-- called for a pile whose cap just moved, never in the idle path.
local function count_tiles(sp)
    local r = sp.room
    local ok, n = pcall(function()
        local c, ext = 0, r.extents
        for i = 0, r.width * r.height - 1 do
            if ext[i] ~= 0 then c = c + 1 end
        end
        return c
    end)
    if ok and n and n > 0 then return n end
    return r.width * r.height
end

-- DF writes 0 to a bin/barrel cap when nothing in the pile's filter uses that container
-- any more. That is a real answer rather than the reset bug, and it is the ONE value
-- DF's recompute is pinned down to -- deliberately no assumption is made about what it
-- writes otherwise. A single-category pile gets its tile count, but a pile where bins
-- AND barrels both apply may well be given a share each, so "the value equals the tile
-- count" is NOT a safe test for "DF just recomputed this". Wheelbarrows are excluded:
-- 0 is their from-scratch value too, so for them the two cases cannot be told apart.
local function not_applicable(key, now)
    return key ~= 'w' and now == 0
end

-- Would honouring this pin need more container tiles than the pile has? Containers sit
-- on tiles, so the three caps together cannot exceed the tile count: 6 pinned bins on a
-- 10-tile pile that DF has also given 5 barrels wants 11. Measured against whatever DF
-- actually assigned the other two caps, so no formula is assumed here either.
local function over_committed(cap, want, cur, tiles)
    local total = want
    for _, other in ipairs(CAPS) do
        if other.key ~= cap.key then total = total + cur[other.key] end
    end
    return total > tiles
end

-- never leave a cap larger than the pile can hold (DF's own ceilings)
local function clamp(key, want, tiles)
    if key == 'w' then return math.max(0, math.min(want, tiles - 1)) end
    return math.max(0, math.min(want, tiles))
end

local function caps_of(sp)
    local s = sp.storage
    return {b = s.max_bins, r = s.max_barrels, w = s.max_wheelbarrows}
end

-- The 17 category flags of `settings.flags` (a stockpile_group_set -- the bits above
-- these are unnamed padding and cannot be read by name, so the list is spelled out).
-- All of them off is DF's "None" stockpile type, the state its own panel flags as
-- "Warning: stockpile has no type".
local TYPE_FLAGS = {'ammo', 'animals', 'armor', 'bars_blocks', 'cloth', 'coins', 'corpses',
    'finished_goods', 'food', 'furniture', 'gems', 'leather', 'refuse', 'sheet', 'stone',
    'weapons', 'wood'}

local function elem_on(e)
    local t = type(e)
    return (t == 'boolean' and e) or (t == 'number' and e ~= 0)
end

-- does this category hold ANY item type, material or quality? Short-circuits on the
-- first thing it finds, so a real category costs almost nothing; only a genuinely
-- empty one is scanned in full.
local function cat_any_on(s)
    if not s then return false end
    for _, v in pairs(s) do
        if elem_on(v) then return true end
        if type(v) == 'userdata' then
            local ok, len = pcall(function() return #v end)
            if ok then
                for i = 0, len - 1 do if elem_on(v[i]) then return true end end
            end
        end
    end
    return false
end

-- No stockpile type. The cheap test is the group flags, which is all the "None" type
-- icon needs -- it clears them. The Custom settings screen writes those SAME flags, but
-- its "None" button clears a category's CONTENTS while leaving the group flag set (the
-- phantom flag binnable-stockpile heals), so a pile emptied that way still claims a
-- type. `deep` confirms by checking whether the flagged categories actually hold
-- anything, which is what makes both routes work without depending on any other script.
local function has_no_type(sp, deep)
    local f, flagged = sp.settings.flags, nil
    for _, name in ipairs(TYPE_FLAGS) do
        if f[name] then
            if not deep then return false end
            flagged = flagged or {}
            flagged[#flagged + 1] = name
        end
    end
    if not flagged then return true end
    for _, name in ipairs(flagged) do
        if cat_any_on(sp.settings[name]) then return false end
    end
    return true   -- every flagged category is empty: the pile has been cleared out
end

local function pile_label(sp)
    local ok, name = pcall(dfhack.buildings.getName, sp)
    name = ok and name or nil
    if name and #name > 0 and name ~= 'Stockpile' then
        return ('#%d %s'):format(sp.stockpile_number, name)
    end
    return ('#%d'):format(sp.stockpile_number)
end

-- Pins are keyed by building id. Persistence round-trips through JSON, which has
-- no integer keys, so they are written (and read back) as strings explicitly
-- rather than left to whatever the encoder decides to do with a sparse table.
local function persist()
    local pins = {}
    for id, p in pairs(state.pins) do pins[tostring(id)] = p end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY,
        {enabled = enabled, log = state.log, pins = pins})
end

-- Load the fort's saved pins. onStateChange covers the normal path, but a script
-- run for the first time mid-fort never sees that event -- without this it would
-- start with no pins and the first persist() would wipe the saved ones.
local function load_state()
    if state.loaded then return {enabled = enabled, log = state.log, pins = state.pins} end
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, log = false, pins = {}})
    local pins = {}
    for k, p in pairs(d.pins or {}) do pins[tonumber(k) or k] = p end
    state = {pins = pins, log = d.log or false, loaded = true}
    return d
end

-- ---------------------------------------------------------------------------
-- the watcher
-- ---------------------------------------------------------------------------

-- the last pile the Storage-and-tools panel was seen open on, and when
local tools_bld, tools_scan = -1, -1000

-- Put `want` back; returns the value written. Returns nil once a pile trips the
-- runaway guard, which can only happen if something keeps overwriting the cap
-- every few frames.
local function restore_cap(sp, cap, want, tiles)
    local k = sp.id .. cap.key
    local r = runaway[k]
    if not r or scans - r.start > RESTORE_WINDOW then r = {n = 0, start = scans}; runaway[k] = r end
    r.n = r.n + 1
    if r.n > RESTORE_LIMIT then
        gave_up[sp.id] = true
        dfhack.printerr(('stable-stockpile-bins: stockpile %s keeps overwriting its %s cap'
            .. ' -- leaving it alone for this session'):format(pile_label(sp), cap.label))
        return nil
    end
    local v, reset_to = clamp(cap.key, want, tiles), sp.storage[cap.field]
    sp.storage[cap.field] = v
    restores = restores + 1
    if state.log then
        print(('stable-stockpile-bins: %s %s reset to %d -> put back to %d')
            :format(pile_label(sp), cap.label, reset_to, v))
    end
    return v
end

-- pins change once per edit, but an edit is a held +/- button that moves the number
-- every frame -- so the save data is written on a timer, not on every step
local dirty, dirty_scan = false, 0
local PERSIST_SCANS = 12   -- ~1s at the sample rate

local function scan()
    scans = scans + 1
    local st = df.global.game.main_interface.stockpile_tools
    if st.open then tools_bld, tools_scan = st.bld_id, scans end
    -- No pile is released while the Custom settings screen is open: mid-edit a pile can
    -- momentarily hold nothing at all, and that transient must not read as "cleared out".
    -- The decision is simply deferred until the screen closes and the state is final.
    local customizing = df.global.game.main_interface.custom_stockpile.open

    local sps = stockpiles()
    local live = {}

    for i = 0, #sps - 1 do
        local sp = sps[i]
        local id = sp.id
        live[id] = true
        local cur = caps_of(sp)
        local was = observed[id]
        local pin = state.pins[id]

        -- Setting the pile's type to "None" hands it back to DF: drop the pin. This runs
        -- BEFORE the classification below, or a wheelbarrow pin would be restored on the
        -- way past (0 is DF's from-scratch wheelbarrow value, so it reads as a reset).
        -- The all-zero test is a cheap gate: a pile with no type always sits at 0/0/0, so
        -- the 17 flag reads only happen for a pinned pile already there. It is a gate and
        -- not the test itself -- a food pile with no barrelable goods is 0/0/0 too.
        if pin and not customizing and cur.b == 0 and cur.r == 0 and cur.w == 0 then
            local deep = scans - (deep_scan[id] or -10000) >= DEEP_SCAN_SCANS
            if deep then deep_scan[id] = scans end
            if has_no_type(sp, deep) then
                if state.log then
                    print(('stable-stockpile-bins: %s has no stockpile type -- unpinned, DF owns its caps')
                        :format(pile_label(sp)))
                end
                state.pins[id], pin, dirty = nil, nil, true
            end
        end

        if was and not gave_up[id] then
            -- Yours if the Storage-and-tools panel is open on this pile. Just after it
            -- closed, only if the value is not DF's reset value -- otherwise a filter
            -- click straight after an edit would be mistaken for the edit itself.
            local panel_open = st.open and st.bld_id == id
            local in_grace = tools_bld == id and (scans - tools_scan) <= GRACE_SCANS
            local tiles

            for _, cap in ipairs(CAPS) do
                local now, want = cur[cap.key], pin and pin[cap.key]
                if now ~= was[cap.key] then
                    if want == nil then
                        -- DF owns this cap until you set it yourself in the panel
                        if panel_open or in_grace then
                            pin = pin or {}
                            state.pins[id] = pin
                            pin[cap.key] = now
                            dirty = true
                        end
                    elseif want ~= now then
                        tiles = tiles or count_tiles(sp)
                        if panel_open or in_grace then
                            -- you set it: this is the new number
                            pin[cap.key] = now
                            dirty = true
                        elseif not_applicable(cap.key, now) then
                            -- The cap stopped applying: you asked for 5 bins and then made
                            -- it a wood pile, so DF zeroed it. Pinning that 0 would fight
                            -- you the day you add a binnable category back, so the cap is
                            -- RELEASED -- DF owns it again.
                            pin[cap.key], dirty = nil, true
                            if state.log then
                                print(('stable-stockpile-bins: %s %s no longer applies -- released to DF')
                                    :format(pile_label(sp), cap.label))
                            end
                        elseif over_committed(cap, want, cur, tiles) then
                            -- Honouring the pin would need more container tiles than the
                            -- pile has -- 6 pinned bins on a 10-tile pile DF has also given
                            -- 5 barrels. There is no sensible number to write, so the pin
                            -- is released rather than half-applied.
                            pin[cap.key], dirty = nil, true
                            if state.log then
                                print(('stable-stockpile-bins: %s %s %d no longer fits in %d tile(s) -- released to DF')
                                    :format(pile_label(sp), cap.label, want, tiles))
                            end
                        else
                            local v = restore_cap(sp, cap, want, tiles)
                            if not v then break end
                            cur[cap.key] = v
                        end
                    end
                end
            end
        end

        -- a pile whose every cap has been released is no longer managed at all
        if pin and next(pin) == nil then state.pins[id], dirty = nil, true end

        observed[id] = cur   -- restore_cap keeps `cur` in step with what it wrote
    end

    -- forget piles that no longer exist
    for id in pairs(state.pins) do
        if not live[id] then state.pins[id] = nil; dirty = true end
    end
    for id in pairs(observed) do
        if not live[id] then observed[id] = nil end
    end
    for id in pairs(deep_scan) do
        if not live[id] then deep_scan[id] = nil end
    end

    if dirty and scans - dirty_scan >= PERSIST_SCANS then
        persist()
        dirty, dirty_scan = false, scans
    end
end

local function tick(gen)
    if not enabled or gen ~= generation then return end
    if dfhack.world.isFortressMode() then
        local ok, err = pcall(scan)
        if not ok then dfhack.printerr('stable-stockpile-bins: ' .. tostring(err)) end
    end
    dfhack.timeout(SAMPLE_FRAMES, 'frames', function() tick(gen) end)
end

-- Re-assert every pin once, for resets that happened while this was off. Only touches
-- caps you pinned by hand, and applies the same releases the watcher would have: a cap
-- DF has zeroed no longer applies, and a pin that no longer fits is dropped.
local function reassert()
    if not dfhack.world.isFortressMode() then return 0 end
    local n = 0
    for _, sp in ipairs(stockpiles()) do
        local pin = state.pins[sp.id]
        -- a pile that lost its type while this was off is DF's again
        if pin and has_no_type(sp, true) then state.pins[sp.id], pin = nil, nil end
        if pin then
            local cur, tiles = caps_of(sp), nil
            for _, cap in ipairs(CAPS) do
                local want = pin[cap.key]
                if want ~= nil and cur[cap.key] ~= want then
                    tiles = tiles or count_tiles(sp)
                    if not_applicable(cap.key, cur[cap.key]) or over_committed(cap, want, cur, tiles) then
                        pin[cap.key] = nil
                    else
                        local v = clamp(cap.key, want, tiles)
                        sp.storage[cap.field] = v
                        cur[cap.key] = v
                        n = n + 1
                    end
                end
            end
            if next(pin) == nil then state.pins[sp.id] = nil end
        end
        observed[sp.id] = caps_of(sp)
    end
    return n
end

local function start()
    if enabled then return end
    enabled = true
    generation = generation + 1
    observed, gave_up, runaway, deep_scan = {}, {}, {}, {}
    tools_bld, tools_scan = -1, -1000
    local n = reassert()
    if n > 0 then print(('stable-stockpile-bins: put back %d cap(s) reset while it was off'):format(n)) end
    tick(generation)
end

local function stop()
    enabled = false
    generation = generation + 1
    -- flush anything the timer hasn't written -- but never on the way out of a map,
    -- where writing site data is no longer safe (the timer keeps this under a second
    -- behind anyway, and a lost pin is remade the next time you touch the panel)
    if dirty and dfhack.isMapLoaded() then persist() end
    dirty = false
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state.loaded = false          -- a different fort: reload its own pins
        enabled = false
        local d = load_state()
        if d.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        observed, gave_up, runaway, deep_scan = {}, {}, {}, {}
        state.loaded = false
    end
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

-- Which piles a subcommand acts on: an explicit stockpile number, `all`, or --
-- with neither -- the selected pile, falling back to all of them.
local function targets(arg)
    local sps = stockpiles()
    if arg == 'all' then
        local t = {}
        for _, sp in ipairs(sps) do t[#t + 1] = sp end
        return t, 'every stockpile'
    end
    local num = tonumber(arg)
    if num then
        for _, sp in ipairs(sps) do
            if sp.stockpile_number == num then return {sp}, pile_label(sp) end
        end
        qerror('no stockpile numbered ' .. num)
    end
    if arg then qerror('expected a stockpile number, `all`, or nothing: ' .. arg) end
    local sel = dfhack.gui.getSelectedStockpile(true)
    if sel then return {sel}, pile_label(sel) end
    local t = {}
    for _, sp in ipairs(sps) do t[#t + 1] = sp end
    return t, 'every stockpile'
end

local function cmd_status()
    print(('stable-stockpile-bins: %s%s'):format(enabled and 'ON' or 'off',
        state.log and ', logging restores' or ''))
    if not dfhack.world.isFortressMode() then print('  (no fortress loaded)'); return end
    print(('  %d cap(s) put back this session'):format(restores))
    local any = false
    for _, sp in ipairs(stockpiles()) do
        local pin = state.pins[sp.id]
        if pin then
            any = true
            local cur, bits = caps_of(sp), {}
            for _, cap in ipairs(CAPS) do
                if pin[cap.key] ~= nil then
                    bits[#bits + 1] = ('%s %d%s'):format(cap.label, pin[cap.key],
                        cur[cap.key] ~= pin[cap.key] and (' (now %d)'):format(cur[cap.key]) or '')
                end
            end
            print(('  %-24s pinned: %s%s'):format(pile_label(sp), table.concat(bits, ', '),
                gave_up[sp.id] and '   [given up on this session]' or ''))
        end
    end
    if not any then
        print('  nothing pinned yet -- set a cap in a stockpile\'s "Storage and tools"')
        print('  panel and it is pinned from then on (or use `repin`).')
    end
end

local function cmd_repin(arg)
    local t, label = targets(arg)
    local n, skipped = 0, 0
    for _, sp in ipairs(t) do
        -- pinning a type-None pile is pointless: the watcher unpins it on its next pass
        if has_no_type(sp) then
            skipped = skipped + 1
        else
            local cur = caps_of(sp)
            state.pins[sp.id] = {b = cur.b, r = cur.r, w = cur.w}
            observed[sp.id] = cur
            gave_up[sp.id] = nil
            n = n + 1
        end
    end
    persist()
    print(('stable-stockpile-bins: pinned the current caps of %s (%d pile(s))'):format(label, n))
    if skipped > 0 then
        print(('  skipped %d pile(s) with no stockpile type -- those stay DF-managed'):format(skipped))
    end
end

local function cmd_forget(arg)
    local t, label = targets(arg)
    for _, sp in ipairs(t) do state.pins[sp.id] = nil end
    persist()
    print(('stable-stockpile-bins: dropped the pin on %s -- DF owns those caps again'):format(label))
end

if dfhack_flags.module then
    return
end

local args = {...}
local sub = args[1]

if dfhack.isMapLoaded() then load_state() end

if sub == 'status' then
    cmd_status()
    return
elseif sub == 'repin' then
    if not dfhack.world.isFortressMode() then qerror('load a fortress first') end
    cmd_repin(args[2])
    return
elseif sub == 'forget' then
    if not dfhack.world.isFortressMode() then qerror('load a fortress first') end
    cmd_forget(args[2])
    return
elseif sub == 'log' then
    if args[2] ~= 'on' and args[2] ~= 'off' then qerror('usage: log on|off') end
    state.log = args[2] == 'on'
    persist()
    print('stable-stockpile-bins: restore logging ' .. args[2])
    return
elseif sub then
    qerror('unknown subcommand: ' .. sub)
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if dfhack_flags.enable_state then start() else stop() end
else
    if enabled then stop() else start() end
end
persist()
print('stable-stockpile-bins: ' .. (enabled and
    'watching -- caps you set in "Storage and tools" now survive filter edits'
    or 'off'))
