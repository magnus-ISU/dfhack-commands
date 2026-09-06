-- Promote the fort's masterwork adamantine doors, hatch covers and floodgates to artifacts, so
-- no building destroyer can break them. Never changes what anything is made of.
--@module = true
--@enable = true
--[[
inviolable-masterworks

A building destroyer -- a troll in a siege, a forgotten beast, a demon -- walks through a door as
if it were not there, and the material makes no difference: an adamantine door dies exactly like
a wooden one. The one thing DF will not break is an ARTIFACT. Artifact furniture can never be
damaged or destroyed, which is why a fort lucky enough to get an artifact door saves it for the
one passage that has to hold.

This gives you those doors out of work you have already done. Once a season it looks over the
fort and promotes every CONSTRUCTED door, hatch cover and floodgate that is a MASTERWORK made of
ADAMANTINE -- the wafer metal or the raw stone -- minting a real artifact for each one.

What it will not do:

  * It never changes a material. A granite door stays granite and is left alone; nothing in the
    fort turns into something you did not build.
  * It never touches ordinary work. An adamantine door of merely good quality stays a door. A
    masterwork is already the best your fort can produce, and Masterful is the quality every real
    artifact carries, so promoting one is a short step rather than an invention.
  * It only looks at buildings standing in the world. A masterwork adamantine door lying in a
    stockpile is a door, not a fortification, and is left for you to place.

An artifact here is what a mood artifact is: a real `artifact_record` in the world, a name from
DF's own generator using the Artifact word tables, an `is_artifact` reference on the item, and the
item's artifact flag.

`artifact_mood` stays off by default. That flag multiplies an artifact's value tenfold and lists
it on the Objects -> Artifacts screen; fort wealth is what sizes your sieges, so it is not
something to switch on by accident. Pass `mood` if you want it.

    inviolable-masterworks            promote everything eligible right now
    inviolable-masterworks dry        list what WOULD be promoted; writes nothing
    inviolable-masterworks status     what has been promoted, and when the next sweep is due
    inviolable-masterworks undo       take back every artifact this tool minted
    enable inviolable-masterworks     seasonal sweeps (this is the default)
    disable inviolable-masterworks    stop

It is ON by default and runs from `magnus-scripts`, which arms it on every map load. The sweep is
seasonal because that is the pace the work arrives at: a mason finishes a masterwork now and then,
not every tick, and a once-a-season pass costs nothing between times.

Words you can add to a manual run: `mood` (also set artifact_mood), `limit=N` (at most N
buildings, so a first run is a handful you can go and look at), `only=door` / `only=hatch` /
`only=floodgate`, and `any` (drop the adamantine and masterwork requirements and promote every
constructed door, hatch cover and floodgate whatever it is made of).

Every promotion is recorded per fort, so `undo` deletes exactly the artifact records this tool
minted and puts each item's quality back. An item that was ALREADY an artifact is never touched.
]]

local GLOBAL_KEY = 'inviolable-masterworks'
local SCAN_FRAMES = 500     -- heartbeat: a date compare, and a sweep only when the season turns

-- Doors, hatch covers and floodgates: the buildings that seal a passage, that a destroyer can
-- take, and that are built from a single item -- an artifact is one item, which is why a bridge
-- (a heap of blocks) could never be one. Bridges lose nothing by it: DF already spares bridges,
-- roads, wells, traps, levers, chains, cages and stockpiles from building destroyers.
local TARGETS = {
    [df.building_type.Door]      = true,
    [df.building_type.Hatch]     = true,
    [df.building_type.Floodgate] = true,
}

-- ---- eligibility --------------------------------------------------------------

-- a linked mechanism is stored in the building the same way its material is, and is no part of
-- what the building is made of
local MECHANISM = df.item_trappartsst

-- The item a building is MADE of, or nil when it is not made of exactly one.
local function material_item(b)
    if not df.building_actual:is_instance(b) then return nil end
    local found
    for _, ci in ipairs(b.contained_items) do
        local item = ci.item
        if item and ci.use_mode == 2 and not MECHANISM:is_instance(item) then
            if found then return nil end
            found = item
        end
    end
    return found
end

-- constructed and standing: not a plan, not a half-built site, not an item in a pile
local function is_built(b)
    return b.flags.exists and df.building_actual:is_instance(b)
        and #b.contained_items > 0 and b:getBuildStage() >= b:getMaxBuildStage()
end

-- the two adamantines: the wafer metal and the raw stone it is smelted from
local function adamantine_set()
    local set = {}
    for _, id in ipairs{'ADAMANTINE', 'RAW_ADAMANTINE'} do
        local mi = dfhack.matinfo.find(id)
        if mi then set[mi.type .. '/' .. mi.index] = true end
    end
    if not next(set) then qerror('this world has no adamantine inorganic') end
    return set
end

local function is_adamantine(item, set)
    return set[item.mat_type .. '/' .. item.mat_index] or false
end

local function is_masterwork(item)
    return item.getQuality and item:getQuality() == df.item_quality.Masterful
end

-- ---- artifact minting --------------------------------------------------------
-- the same recipe fort/planeswalkers uses to restore a carried artifact: a record in
-- world.artifacts.all, an is_artifact general_ref on the item, and the item's own flag.

local function mint_artifact(item, mood)
    local ar = df.artifact_record:new()
    ar.id = df.global.artifact_next_id
    df.global.artifact_next_id = ar.id + 1
    ar.item = item
    -- DF's own generator with the Artifact word tables, so the name reads like any other
    local wt = df.global.world.raws.language.word_table
    dfhack.translation.generateName(ar.name, 0, df.language_name_type.Artifact,
        wt[0][df.language_name_category.Artifact], wt[1][df.language_name_category.Artifact])
    ar.name.has_name = true
    -- whereabouts: new() zero-inits these, which would claim site 0 / hf 0. Mark them unknown
    -- and put the artifact at THIS site, so legends and the Objects screen read correctly.
    ar.site = df.global.plotinfo.site_id
    ar.structure_local, ar.subregion, ar.feature_layer = -1, -1, -1
    ar.last_local_bld_id, ar.site_building_profile = -1, -1
    ar.storage_site, ar.storage_structure_local = -1, -1
    ar.loss_region, ar.last_layer, ar.holder_hf = -1, -1, -1
    ar.owner_hf, ar.year, ar.season_tick = -1, -1, -1
    ar.abs_tile_x, ar.abs_tile_y, ar.abs_tile_z = -1000000, -1000000, -1000000
    df.global.world.artifacts.all:insert('#', ar)
    local ref = df.general_ref_is_artifactst:new()
    ref.artifact_id = ar.id
    item.general_refs:insert('#', ref)
    item.flags.artifact = true
    -- MASTERFUL, not the enum's own `Artifact` level (6). Every artifact a world holds that has a
    -- quality at all carries 5, the mood-made and the worldgen-named alike; nothing in the game
    -- writes 6. The FLAG marks an artifact -- quality only has to match the rest. A masterwork is
    -- already 5, so this matters only under `any`.
    if item.isCrafted and item:isCrafted() then item:setQuality(df.item_quality.Masterful) end
    if mood then item.flags.artifact_mood = true end
    return ar.id, dfhack.translation.translateName(ar.name, true)
end

local function unmint_artifact(item, artifact_id, old_quality)
    if item then
        for i = #item.general_refs - 1, 0, -1 do
            local r = item.general_refs[i]
            if df.general_ref_is_artifactst:is_instance(r) and r.artifact_id == artifact_id then
                item.general_refs:erase(i)
                r:delete()
            end
        end
        item.flags.artifact = false
        item.flags.artifact_mood = false
        if old_quality and item.isCrafted and item:isCrafted() then item:setQuality(old_quality) end
    end
    local all = df.global.world.artifacts.all
    for i = #all - 1, 0, -1 do
        if all[i].id == artifact_id then
            local ar = all[i]
            all:erase(i)
            ar:delete()
            break
        end
    end
end

-- ---- state (persisted per fort) ---------------------------------------------

state = state or nil
local function load_state()
    if not state then state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {} end
    -- fill the fields on EVERY call, not just the first: a script's environment survives a hot
    -- reload, so `state` can arrive from a copy of this file that predates a field, and a
    -- one-shot initializer would leave it missing for the rest of the session.
    -- ON BY DEFAULT -- a fort that has never been told either way is watched.
    if state.enabled == nil then state.enabled = true end
    state.done = state.done or {}      -- item id (string) -> {a = artifact id, q = old quality}
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- the sweep ---------------------------------------------------------------

-- One pass over the fort. Returns (buildings promoted, log lines).
function run_pass(opts)
    opts = opts or {}
    local adam = adamantine_set()
    local st = load_state()
    local log, n = {}, 0
    for _, b in ipairs(df.global.world.buildings.all) do
        if opts.limit and n >= opts.limit then break end
        local btype = b:getType()
        if TARGETS[btype] and (not opts.only or opts.only == btype) and is_built(b) then
            local item = material_item(b)
            if item and not item.flags.artifact
                and (opts.any or (is_adamantine(item, adam) and is_masterwork(item))) then
                local what = ('%s at (%d,%d,%d), %s'):format(df.building_type[btype],
                    b.centerx, b.centery, b.z,
                    dfhack.matinfo.decode(item.mat_type, item.mat_index):toString())
                if opts.dry then
                    log[#log + 1] = '  would promote ' .. what
                else
                    local q = item.getQuality and item:getQuality() or nil
                    local aid, name = mint_artifact(item, opts.mood)
                    st.done[tostring(item.id)] = {a = aid, q = q}
                    log[#log + 1] = ('  %s is now %s'):format(what, name)
                end
                n = n + 1
            end
        end
    end
    if not opts.dry and n > 0 then save_state() end
    return n, log
end

function undo_all()
    local st = load_state()
    local n = 0
    for key, rec in pairs(st.done) do
        unmint_artifact(df.item.find(tonumber(key)), rec.a, rec.q)
        st.done[key] = nil
        n = n + 1
    end
    save_state()
    return n
end

-- ---- the seasonal clock ------------------------------------------------------

-- Season, as a value that only ever changes when the season turns. cur_season_tick is not a safe
-- clock on its own (it is reset and, under a timestream mod, does not advance evenly), while the
-- year/season pair moves exactly once per turn of the season, which is the event we want.
local function season_stamp()
    return ('%d/%d'):format(df.global.cur_year, df.global.cur_season)
end

local function sweep_if_season_turned(force)
    local st = load_state()
    local now = season_stamp()
    if not force and st.season == now then return 0 end
    local ok, n = pcall(run_pass, {mood = st.mood})
    st.season = now
    save_state()
    return ok and n or 0
end

local function hb_gen(set)
    if set ~= nil then dfhack.internal.inviolable_masterworks_hb_gen = set end
    return dfhack.internal.inviolable_masterworks_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        -- the common tick is one string compare against the stored season stamp
        if dfhack.world.isFortressMode() then sweep_if_season_turned() end
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

function set_enabled(v, opts)
    load_state()
    state.enabled = v
    if opts and opts.mood ~= nil then state.mood = opts.mood end
    save_state()
    if v then start_heartbeat() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- start watching as soon as the file is loaded on a live fort: magnus-scripts loads this on every
-- map load, and the enable is the default, so no one has to remember to arm it
if not (dfhack_flags and dfhack_flags.module) and dfhack.world.isFortressMode() and isEnabled() then
    start_heartbeat()
end

-- ---- entry point -------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('inviolable-masterworks only works in fortress mode')
end

local args = {...}
local opts, verb = {}, nil
for _, a in ipairs(args) do
    if a == 'dry' then opts.dry = true
    elseif a == 'mood' then opts.mood = true
    elseif a == 'any' then opts.any = true
    elseif a == 'status' or a == 'undo' then verb = a
    elseif a:match('^limit=%d+$') then opts.limit = tonumber(a:match('%d+'))
    elseif a:match('^only=%a+$') then
        local want = a:match('=(%a+)'):lower()
        for t in pairs(TARGETS) do
            if df.building_type[t]:lower() == want then opts.only = t end
        end
        if not opts.only then qerror('only= must be door, hatch or floodgate') end
    else qerror('unknown argument: ' .. tostring(a)) end
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state, opts)
    if isEnabled() then sweep_if_season_turned(true) end
    print('inviolable-masterworks: ' ..
        (isEnabled() and 'ENABLED (a sweep each season)' or 'disabled'))
    return
end

if verb == 'status' then
    local st = load_state()
    local n = 0
    for _ in pairs(st.done) do n = n + 1 end
    print(('inviolable-masterworks: %d building%s promoted to artifacts by this tool.')
        :format(n, n == 1 and '' or 's'))
    print('  seasonal sweeps: ' .. (isEnabled() and 'on' or 'off') ..
        ('   last swept: %s   now: %s'):format(st.season or 'never', season_stamp()))
    return
end

if verb == 'undo' then
    local n = undo_all()
    print(('inviolable-masterworks: took back %d artifact%s (records deleted, quality restored).')
        :format(n, n == 1 and '' or 's'))
    return
end

local n, log = run_pass(opts)
for _, line in ipairs(log) do print(line) end
if opts.dry then
    print(('inviolable-masterworks: DRY RUN -- %d building%s would be promoted. Nothing was written.')
        :format(n, n == 1 and '' or 's'))
elseif n == 0 then
    print('inviolable-masterworks: nothing to promote -- every constructed masterwork adamantine door, hatch cover and floodgate is already an artifact.')
else
    print(('inviolable-masterworks: promoted %d building%s to artifacts.'):format(n, n == 1 and '' or 's'))
    print('  `inviolable-masterworks undo` takes every one of them back.')
end
