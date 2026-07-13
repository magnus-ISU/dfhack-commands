-- Free the broker to trade: while the broker is requested at the depot, put their squad on "Ready".
--@ module = false
--[[
broker-ready

When the broker has been requested at the trade depot (the depot's `trader_requested` flag, set by
"bring the broker to trade"), this temporarily switches the squad the broker belongs to onto the
**"Ready"** military routine -- equipped but not training -- so the broker is free to walk to the
depot and trade instead of being stuck training. Once the request clears (trade finished / caravan
gone), the squad's **previous routine is restored**.

Only the broker's own squad is touched, and only if the broker is actually in a fort squad and not
already on Ready. State is held in memory only (on `dfhack.internal`, so it survives a script
reload): if the game is SAVED AND RELOADED mid-trade the squad is left on Ready and won't be
auto-restored -- re-request/finish the trade, or set its schedule back by hand.

Run once per session (magnus-scripts does this); it installs a lightweight heartbeat and re-arms on
map load. Re-running is safe (idempotent).
]]

local GLOBAL_KEY = 'broker-ready'
local CHECK_FRAMES = 50   -- ~1s at 50 fps; react promptly without scanning every frame

-- in-memory state, kept on dfhack.internal so it survives a `reqscript`/reload of this script:
--   active     = we have already handled the current request (don't re-process each tick)
--   saved      = { [squad_id] = previous cur_routine_idx } for squads WE switched
local function st()
    dfhack.internal.broker_ready_state = dfhack.internal.broker_ready_state or {active = false, saved = {}}
    return dfhack.internal.broker_ready_state
end

-- ---------------------------------------------------------------------------
-- detection
-- ---------------------------------------------------------------------------

-- The broker is "wanted at the depot" only while a caravan is present AND some depot has its
-- trader_requested flag set. (Requiring a caravan guards against a stuck flag with no traders.)
local function broker_wanted()
    if #df.global.plotinfo.caravans == 0 then return false end
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_tradedepotst:is_instance(b) and b.trade_flags.trader_requested then return true end
    end
    return false
end

-- index of the fort's "Ready" military routine (looked up by name -- routines can be reordered)
local function ready_routine_idx()
    local routines = df.global.plotinfo.alerts.routines
    for i = 0, #routines - 1 do if routines[i].name == 'Ready' then return i end end
    return nil
end

-- the unit assigned to a fort noble position carrying the TRADE responsibility (the broker)
local function broker_unit()
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then ent = e break end
    end
    if not ent then return nil end
    local posbyid = {}
    for _, p in ipairs(ent.positions.own) do posbyid[p.id] = p end
    for _, a in ipairs(ent.positions.assignments) do
        local p = posbyid[a.position_id]
        if p and p.responsibilities.TRADE and a.histfig >= 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u then return u end
        end
    end
    return nil
end

local function fort_squad(squad_id)
    if not squad_id or squad_id < 0 then return nil end
    local sq = df.squad.find(squad_id)
    if sq and sq.entity_id == df.global.plotinfo.group_id then return sq end
    return nil
end

-- ---------------------------------------------------------------------------
-- act
-- ---------------------------------------------------------------------------

-- On the rising edge of a request: switch the broker's squad to Ready, remembering its old routine.
local function engage()
    local s = st()
    s.active = true                    -- mark handled even if there's nothing to switch (broker not
                                       -- in a squad) so we don't rescan the entity list every tick
    local ridx = ready_routine_idx()
    if not ridx then return end
    local u = broker_unit()
    if not u or not u.military then return end
    local sq = fort_squad(u.military.squad_id)
    if not sq then return end
    if sq.cur_routine_idx == ridx then return end   -- already Ready -- nothing to save or change
    s.saved[sq.id] = sq.cur_routine_idx
    sq.cur_routine_idx = ridx
end

-- On the falling edge: restore every squad we switched back to its previous routine.
local function release()
    local s = st()
    for sqid, prev in pairs(s.saved) do
        local sq = fort_squad(sqid)
        if sq then sq.cur_routine_idx = prev end
    end
    s.saved = {}
    s.active = false
end

local function tick()
    if not dfhack.world.isFortressMode() then return end
    if broker_wanted() then
        if not st().active then engage() end
    else
        if st().active then release() end
    end
end

-- ---------------------------------------------------------------------------
-- heartbeat (generation-guarded so a reload/re-run never leaks a second loop)
-- ---------------------------------------------------------------------------

local function hb_gen(set)
    if set ~= nil then dfhack.internal.broker_ready_hb_gen = set end
    return dfhack.internal.broker_ready_hb_gen or 0
end

local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if my ~= hb_gen() then return end        -- a newer heartbeat superseded us -> exit
        pcall(tick)
        dfhack.timeout(CHECK_FRAMES, 'frames', hb)
    end
    hb()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        dfhack.internal.broker_ready_state = {active = false, saved = {}}   -- fresh fort, no memory
        if dfhack.world.isFortressMode() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        hb_gen(hb_gen() + 1)                                                -- stop the heartbeat
    end
end

if dfhack_flags and dfhack_flags.module then return end

if dfhack.world.isFortressMode() then start_heartbeat() end
print('broker-ready: watching the depot -- the broker\'s squad goes Ready while the broker is '
    .. 'requested, then restores its routine.')
