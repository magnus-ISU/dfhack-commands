-- Keep the hospital's hands off your adamantine: forbid the cloth/thread a medical job claims.
--@module = true
--@enable = true
--[[
adamantine-hospital

DF gives a hospital NO material filter. It requests cloth and thread, and a dwarf fetches
whatever cloth and thread the fort has -- adamantine included. Wound dressings and sutures
consume it, so a single adamantine cloth ends up spent in fractions ("adamantine cloth (40%)")
on a bruise, and any standing order that keeps adamantine cloth in stock will quietly weave
another one to replace it, draining strands that should have become wafers.

This watches the job list and acts at the only moment that matters: when a medical job has
actually CLAIMED an adamantine cloth or thread. Two ways to handle that, chosen with
`adamantine-hospital mode <name>`:

  * `forbid` (default) -- the item is FORBIDDEN (so DF stops offering it) and the job
    cancelled, which makes the hospital re-issue the treatment and pick an ordinary cloth.
    Nothing is consumed -- a claimed item is only used up when the job completes, and the job
    never gets there.
  * `guard` -- prevention rather than cure: keep every adamantine cloth/thread forbidden all
    the time, so no medical job can ever claim one. The surest option and the only one with no
    job to unpick, but a forbidden item is invisible to YOUR jobs too -- the smelter and loom
    cannot touch the thread until you `release` it. Off by default for that reason.

A third mode, `retarget`, has been REMOVED -- see BROKEN_FEATURES.md. It swapped the claimed
adamantine for an ordinary cloth so the treatment could go ahead untouched, which is the nicer
outcome, but rewriting a live job's item list from inside DFHack's update tick crashed DF
(SIGSEGV in `bit_container_identity::lua_item_read`, several times an hour under load). Worth
retrying, but only with a safer mechanism than editing `job.items` in place.

Watched jobs: DressWound, Suture, Surgery, ApplyCast, ImmobilizeBreak, SetBone, PlaceInTraction.
Hauling adamantine INTO the hospital is deliberately NOT intercepted: storing it consumes
nothing, and the treatment job that would consume it is caught here.

NOTE: a forbidden item is invisible to ALL jobs, including your own -- forbidden adamantine
thread will not be smelted into wafers or woven at the loom either. Run `adamantine-hospital
release` when you want the smelter to have it back (the watcher re-forbids only if the
hospital reaches for it again).

Usage:
    enable adamantine-hospital     watch medical jobs (checks every 10 frames)
    disable adamantine-hospital    stop watching
    adamantine-hospital            status: adamantine cloth/thread on hand, how much is
                                   forbidden, how many hospital attempts have been blocked
    adamantine-hospital mode       show the mode; `mode forbid|guard` sets it
    adamantine-hospital release    unforbid every adamantine cloth/thread in the fort
]]

local GLOBAL_KEY = 'adamantine-hospital'
local CHECK_FRAMES = 10          -- job-list scan cadence; a treatment job takes far longer

-- the jobs that CONSUME cloth/thread on a patient. Hauling jobs are not here on purpose:
-- moving an item costs nothing, and whatever gets stored is caught when treatment claims it.
local MEDICAL = {}
for _, n in ipairs({'DressWound', 'Suture', 'Surgery', 'ApplyCast', 'ImmobilizeBreak',
                    'SetBone', 'PlaceInTraction'}) do
    if df.job_type[n] then MEDICAL[df.job_type[n]] = true end
end

-- the fibre item types worth protecting (an adamantine BAR/WAFER is never hospital fodder)
local FIBRE = {[df.item_type.CLOTH] = true, [df.item_type.THREAD] = true}

-- ---- persisted state (per site) ---------------------------------------------
state = state or nil

local function default_state()
    return {enabled = false, blocked = 0, mode = 'forbid'}
end

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, default_state())
    end
    for k, v in pairs(default_state()) do
        if state[k] == nil then state[k] = v end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

-- ---- adamantine ---------------------------------------------------------------

-- ADAMANTINE's inorganic index is per-world, so resolve it on each map load, not at load time.
local adam_idx = nil
local function adamantine_index()
    if adam_idx == nil then
        local mi = dfhack.matinfo.find('INORGANIC:ADAMANTINE')
        adam_idx = mi and mi.index or false
    end
    return adam_idx
end

-- adamantine cloth or thread? (RAW_ADAMANTINE is the mined boulder -- a different inorganic,
-- and never an item type we watch, so the index check alone is enough)
local function is_adamantine_fibre(item)
    local idx = adamantine_index()
    if not idx then return false end
    return FIBRE[item:getType()] and item:getMaterial() == 0 and item:getMaterialIndex() == idx
end

-- every adamantine cloth/thread in the fort
local function fibre_items()
    local out = {}
    for _, vec in ipairs({df.global.world.items.other.CLOTH, df.global.world.items.other.THREAD}) do
        for _, it in ipairs(vec) do
            if not it.flags.garbage_collect and is_adamantine_fibre(it) then out[#out + 1] = it end
        end
    end
    return out
end

-- ---- interception ---------------------------------------------------------------

local function intercept(job, item)
    local what = dfhack.items.getDescription(item, 0)
    item.flags.forbid = true
    -- cancelling frees the claim, so the hospital re-issues the treatment and -- with this
    -- item now forbidden -- reaches for ordinary cloth instead
    local removed = pcall(dfhack.job.removeJob, job)
    load_state()
    state.blocked = state.blocked + 1
    save_state()
    dfhack.gui.showAnnouncement(
        ('%s forbidden: the hospital tried to use it for %s.')
            :format(what, df.job_type[job.job_type]), COLOR_YELLOW, true)
    return removed
end

-- `guard` mode: forbid adamantine fibre BEFORE anything reaches for it, so the hospital never
-- gets to claim one. The surer of the two, and the only one with no medical job to unpick --
-- but a forbidden item is invisible to YOUR jobs too, so the smelter and loom cannot touch the
-- thread until `adamantine-hospital release`. Off by default for exactly that reason.
local function guard_all()
    local n = 0
    for _, it in ipairs(fibre_items()) do
        if not it.flags.forbid and not it.flags.in_job then
            it.flags.forbid = true
            n = n + 1
        end
    end
    return n
end

-- one pass over the active job list. Only the job_type is read for most jobs, so this stays
-- cheap enough to run every few frames on a fort with hundreds of jobs.
local function do_check()
    if not dfhack.world.isFortressMode() then return 0 end
    if load_state().mode == 'guard' then guard_all() end
    local hits = 0
    local link = df.global.world.jobs.list.next
    while link do
        -- removeJob frees the job AND its list link, so the successor must be read first
        local nxt = link.next
        local job = link.item
        if job and MEDICAL[job.job_type] then
            for _, ref in ipairs(job.items) do
                local it = ref.item
                if it and is_adamantine_fibre(it) then
                    intercept(job, it)
                    hits = hits + 1
                    break                  -- this job is gone; on to the next link
                end
            end
        end
        link = nxt
    end
    return hits
end

-- unforbid every adamantine cloth/thread (e.g. to let the smelter turn thread into wafers)
local function release()
    local n = 0
    for _, it in ipairs(fibre_items()) do
        if it.flags.forbid then it.flags.forbid = false; n = n + 1 end
    end
    return n
end

-- ---- service loop (frame-gap-safe bounce via set_enabled) --------------------

enabled = enabled or false
function isEnabled() return enabled end

local hb_gen = 0
local last_frame = nil

local function start()
    enabled = true
    last_frame = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local f = df.global.world.frame_counter
        if not last_frame or math.abs(f - last_frame) >= CHECK_FRAMES then
            last_frame = f
            pcall(do_check)
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, adam_idx = nil, nil        -- both are per-world
        load_state()
        if state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, adam_idx = nil, nil
    end
end

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

if dfhack_flags.module then
    return
end

-- ---- command line ------------------------------------------------------------

if not dfhack.isMapLoaded() then qerror('adamantine-hospital needs a loaded fort') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('adamantine-hospital: ' .. (enabled and 'enabled -- watching medical jobs' or 'disabled'))
    return
end

local cmd = ({...})[1]

local MODES = {forbid = true, guard = true}

if cmd == 'release' then
    local n = release()
    print(('adamantine-hospital: unforbade %d adamantine cloth/thread item%s')
        :format(n, n == 1 and '' or 's'))
    if state.mode == 'guard' then
        print('  NOTE: mode is `guard`, which re-forbids them on the next check.')
        print('  Switch with `adamantine-hospital mode forbid` to keep them available.')
    end
elseif cmd == 'mode' then
    local m = ({...})[2]
    if not m then
        print('adamantine-hospital: mode is ' .. state.mode)
        print('  forbid    forbid the claimed item and cancel the treatment')
        print('  guard     keep all adamantine fibre forbidden so nothing can ever claim it')
    elseif MODES[m] then
        state.mode = m
        save_state()
        print('adamantine-hospital: mode set to ' .. m)
        if m == 'guard' then
            print('  adamantine fibre will be kept forbidden -- your smelter/loom cannot use it')
            print('  either until `adamantine-hospital release` (and mode is changed).')
        end
    else
        qerror('unknown mode "' .. m .. '" (forbid, guard)')
    end
else
    print(('adamantine-hospital: %s'):format(enabled and 'ENABLED (checks every '
        .. CHECK_FRAMES .. ' frames)' or 'disabled'))
    local items = fibre_items()
    local free, held = 0, 0
    for _, it in ipairs(items) do
        if it.flags.forbid then held = held + 1 else free = free + 1 end
    end
    print(('  adamantine fibre on hand: %d (%d forbidden, %d available)'):format(#items, held, free))
    for _, it in ipairs(items) do
        print(('    %s%s'):format(dfhack.items.getDescription(it, 0),
            it.flags.forbid and '  [forbidden]' or ''))
    end
    print(('  mode: %s'):format(state.mode))
    print(('  hospital attempts blocked: %d'):format(state.blocked))
    if not enabled then print('  `enable adamantine-hospital` to watch.') end
end
