-- Keep a "Military" work detail's members in sync with the fort's military, daily.
--@module = true
--@enable = true
--[[
military-labor

Once per game-day, assigns every dwarf currently in the military (any fort citizen in a
squad) to the work detail named "Military" -- if that detail exists. Dwarves who leave a
squad are dropped; new soldiers are added. Two kinds of squad member are excluded so the
detail tracks your actual standing military:
    * members of a DFHack autotraining squad, UNLESS they are the squad leader (the rest
      are only rostered to train, not real soldiers);
    * everyone in a squad on the default Off-Duty routine (not actually serving). The "Military" detail is created/ordered (last
on the Labor list, siege-operators icon) by `labor-groups`; this script only manages its
membership, so whatever labor(s) you put on that detail follow your squads automatically.

    enable military-labor    start the daily sync (persists with the fort)
    disable military-labor   stop it
    military-labor           sync once now (also prints status)

Add `enable military-labor` to magnus-scripts / dfhack.init to run it every session.
]]

local GLOBAL_KEY = 'military-labor'
local DAY_TICKS = 1200
local DETAIL_NAME = 'Military'

-- ---- the work + detail ------------------------------------------------------

local function find_detail()
    local wd = df.global.plotinfo.labor_info.work_details
    for i = 0, #wd - 1 do
        if wd[i].name == DETAIL_NAME then return wd[i] end
    end
end

-- the squads DFHack's autotraining tool is currently driving (active only). Read from
-- its persisted site data; keys are stored as strings, so coerce back to numbers.
local function autotraining_squads()
    local set = {}
    local d = dfhack.persistent.getSiteData('autotraining')
    if d and d.training_squads then
        for k, active in pairs(d.training_squads) do
            if active then set[tonumber(k)] = true end
        end
    end
    return set
end

-- a squad on the default Off-Duty routine (the built-in routine, always index 0 of the
-- fort's schedule list). Such squads aren't actually serving, so their members are skipped.
local function is_off_duty(sid)
    local sq = df.squad.find(sid)
    return sq and sq.cur_routine_idx == 0
end

-- every fort citizen currently in a squad (the militia + standing army), minus:
--   * members of an autotraining squad, UNLESS they are the squad leader (position 0)
--     -- the rest are only rostered to train; and
--   * everyone in a squad on the default Off-Duty routine (not actually serving).
local function military_unit_ids()
    local training = autotraining_squads()
    local ids = {}
    for _, u in ipairs(df.global.world.units.active) do
        local sid = u.military.squad_id
        if sid >= 0 and dfhack.units.isCitizen(u)
            and dfhack.units.isActive(u) and not dfhack.units.isDead(u)
            and not (training[sid] and u.military.squad_position ~= 0)   -- skip non-leader trainees
            and not is_off_duty(sid)                                     -- skip off-duty squads
        then ids[#ids + 1] = u.id end
    end
    return ids
end

-- sync the detail's assigned units to the current military set. Returns the count, or
-- nil if there is no "Military" detail (the "if it exists" guard).
local function sync()
    local d = find_detail()
    if not d then return nil end
    local ids = military_unit_ids()
    d.assigned_units:resize(0)
    for _, id in ipairs(ids) do d.assigned_units:insert('#', id) end
    return #ids
end

-- ---- enable state (persisted per fort) --------------------------------------

state = state or nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- daily heartbeat (calendar-gated; survives reloads via dfhack.internal) --
-- mirrors military-uniforms: the generation counter lives on dfhack.internal so a
-- reload/re-enable bumps it and any older closed-over heartbeat exits instead of leaking.
local last_run
local function hb_gen(set)
    if set ~= nil then dfhack.internal.military_labor_hb_gen = set end
    return dfhack.internal.military_labor_hb_gen or 0
end
local function start_heartbeat()
    last_run = nil
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then last_run = now; sync() end
        dfhack.timeout(1, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

local function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if v then start_heartbeat(); sync() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- entry point ------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('military-labor only works in fortress mode') end
    set_enabled(dfhack_flags.enable_state)
    print('military-labor: daily sync ' .. (isEnabled() and 'ENABLED' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('military-labor only works in fortress mode') end
local n = sync()
if n == nil then
    print(('military-labor: no "%s" work detail found -- run labor-groups to create it.'):format(DETAIL_NAME))
else
    print(('military-labor: assigned %d military dwarf/dwarves to "%s".'):format(n, DETAIL_NAME))
end
