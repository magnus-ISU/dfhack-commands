-- Revive dead megabeasts (winter-solstice roll) so DF's OWN attack scheduler re-sends them.
--@module = true
--@enable = true
--[[
tarrasque

Forgotten beasts are a FINITE pool: worldgen makes exactly one per underground region, and once
your fort kills the ones its caverns can reach, the attacks stop forever. Titans and bronze
colossi are finite the same way. tarrasque brings them back: dead beasts roll a 1-in-100 chance
each year on the WINTER SOLSTICE (1st of Obsidian); winners are revived "outside the fortress" --
alive in the world again but NOT in play -- restored to the exact world-model of a natural
waiting beast, so that **DF's own attack machinery selects and delivers them again** with fully
native placement, announcement, and AI. tarrasque does NOT spawn or place anything itself.

Covered: forgotten beasts (FORGOTTEN_BEAST_<n>), titans (TITAN_<n>), bronze colossi
(COLOSSUS_BRONZE). NOT covered: dragons, rocs, hydras -- they breed, their pools refill naturally.

HOW NATIVE DELIVERY WORKS (cracked on a virgin test world, all verified live):
  * A waiting forgotten beast = a HIDDEN ONE-MEMBER ARMY (`army.flags.hidden`, controller -1,
    member = its nemesis) whose `hidden_fl_ind` is the cavern layer it lurks in, plus
    `whereabouts.state=3, army_id=<army>` on the histfig. Death (and delivery) DESTROY the army.
  * FB attacks are `Megabeast` timed events with `layer_id` = a genuinely-DISCOVERED cavern layer
    (flag-editing the feature is not enough -- the cavern must really be breached by digging).
    DF queues them itself at season boundaries, gated on irritation/wealth; `force-more
    forgotten-beast [layer]` queues one on demand. (FeatureAttack never spawns FBs -- dead end;
    stock `force Megabeast` never sets layer_id, so it only rolls surface beasts.)
  * Titans/colossi are surface dwellers (lair-site whereabouts, no army) picked by the same event
    with no layer.

WHAT REVIVAL DOES:
  * Histfig: died_year/died_seconds back to -1, ghost off, a "revived" history event added. The
    DEATH event (killer, year) is retained -- legends keep the whole story.
  * Nemesis record: created if missing, with the natural megabeast flags (BRAG_ON_KILL,
    KILL_QUEST, CHAT_WORTHY, FLASHES, DO_NOT_CULL) -- death leaves an existing record intact.
  * Beast with a LOADED dead unit (it died here): only once it has been dead over a year (a
    pacing cooldown -- freshly slain beasts don't return the same season); the unit is
    resurrected via `full-heal -r` and instantly OFFLOADED (flags1.inactive) -- alive but not
    in play, exactly like a caravan member who left the map. Its remains in the fort are LEFT
    ALONE: trophies of the first kill stay even as the beast walks again.
  * Forgotten beasts get their hidden army back via the LEAVE-DANCE: the revived unit is staged
    (invisible) at a map edge with the emigration leave flags; within a few ticks DF MINTS THE
    ARMY ITSELF (hand-built army objects are never selected by the native event, even when
    field-identical -- eligibility lives in registration only DF's army creation performs; DF
    even destroys any duplicate army we made). The service then converts DF's army into a hidden
    lurker in a random discovered local cavern layer and shelves the unit out of play again.
    Titans/colossi keep their lair-site whereabouts (death leaves it intact) -- no army needed.
  * Beast with NO unit anywhere (died off-map in worldgen, unit culled): revived abstractly --
    alive in legends and eligible for world-level events, but with nothing for a local Megabeast
    event to materialize it cannot re-attack this fort (no working unit-creation primitive).
  * Beast whose unit belongs to a different, unloaded site: skipped until that site is loaded.

State (enabled, last roll year, log) persists at WORLD level, so it follows the world across
forts and into adventure mode. Reviving works anywhere; the army rebuild needs a loaded fort map
(a beast revived in adventure mode is alive but army-less until revived-with-map -- rare edge).

Usage:
    enable tarrasque          run the solstice service (world must be loaded)
    disable tarrasque         stop it
    tarrasque                 status: counts per class, revived-awaiting-return, log tail
    tarrasque roll            run this year's solstice roll right now
    tarrasque revive [N]      revive up to N random dead beasts now (default 1)

To hurry a re-attack after a revival: `force-more forgotten-beast` (native event, DF picks the
beast). Enabled by `magnus-scripts lovely` or standalone.
]]

local utils = require('utils')

local GLOBAL_KEY = 'tarrasque'
local REVIVE_CHANCE = 100          -- 1-in-N per dead beast per year
local SOLSTICE_TICK = (12 - 1) * 28 * 1200   -- 1st of Obsidian = tick 369600
local MIN_DEAD_YEARS = 1           -- fort-killed beasts must be dead over a year (pacing cooldown)

-- ---- beast identification ---------------------------------------------------
-- race index -> 'fb' (cavern forgotten beast) or 'mega' (surface titan/colossus).
-- Dragons/rocs/hydras breed; they are deliberately NOT included.
local class_cache
local function race_classes()
    if not class_cache then
        class_cache = {}
        local cr = df.global.world.raws.creatures.all
        for i = 0, #cr - 1 do
            local id = tostring(cr[i].creature_id)
            if id:match('^FORGOTTEN_BEAST_%d+$') then class_cache[i] = 'fb'
            elseif id:match('^TITAN_%d+$') or id == 'COLOSSUS_BRONZE' then class_cache[i] = 'mega'
            end
        end
    end
    return class_cache
end

-- ---- persisted state (WORLD level -- follows the world, not the site) -------
state = state or nil

local function default_state()
    return {enabled = false, last_roll_year = -1, log = {}, staging = {}}
end

local function load_state()
    if not state then
        state = dfhack.persistent.getWorldData(GLOBAL_KEY, default_state())
    end
    -- upgrade stale/partial state EVERY load: the module env (and its `state`) survives a
    -- reqscript reload, so an old-format table (or a persistence round-trip that dropped
    -- empty tables) would otherwise linger without the newer fields
    for k, v in pairs(default_state()) do
        if state[k] == nil then state[k] = v end
    end
    return state
end
local function save_state() dfhack.persistent.saveWorldData(GLOBAL_KEY, state) end

-- ---- survey -----------------------------------------------------------------

-- one pass over world histfigs, per class:
--   alive / waiting (alive with a hidden army or lair, not in play) / dead breakdowns
local function survey()
    local cls = race_classes()
    local out = {fb = {alive = 0, awaiting = 0, dead = 0, dead_loaded = {}, dead_nounit = {}, dead_elsewhere = 0},
                 mega = {alive = 0, awaiting = 0, dead = 0, dead_loaded = {}, dead_nounit = {}, dead_elsewhere = 0}}
    for _, hf in ipairs(df.global.world.history.figures) do
        local c = cls[hf.race]
        if c then
            local s = out[c]
            if (hf.died_year or -1) >= 0 then
                s.dead = s.dead + 1
                if hf.unit_id >= 0 then
                    local u = df.unit.find(hf.unit_id)
                    if u and u.flags2.killed and not u.flags3.scuttle then
                        s.dead_loaded[#s.dead_loaded + 1] = hf.id
                    else
                        s.dead_elsewhere = s.dead_elsewhere + 1
                    end
                else
                    s.dead_nounit[#s.dead_nounit + 1] = hf.id
                end
            else
                s.alive = s.alive + 1
                local u = hf.unit_id >= 0 and df.unit.find(hf.unit_id)
                if not u or u.flags1.inactive then s.awaiting = s.awaiting + 1 end
            end
        end
    end
    return out
end

-- ---- revival pieces ----------------------------------------------------------

local function hf_name(hf)
    local nm = dfhack.translation.translateName(hf.name)
    if not nm or nm == '' then nm = 'a nameless beast' end
    return nm
end

-- most recent death event for this histfig: returns slayer hfid (or -1), scanning backwards
local function find_killer(hfid)
    local evs = df.global.world.history.events
    for i = #evs - 1, 0, -1 do
        local ev = evs[i]
        if df.history_event_hist_figure_diedst:is_instance(ev) and ev.victim_hf == hfid then
            return ev.slayer_hf or -1
        end
    end
    return -1
end

local function add_revival_event(hfid)
    local ev = df.history_event_hist_figure_revivedst:new()
    ev.histfig = hfid
    ev.year = df.global.cur_year
    ev.seconds = df.global.cur_year_tick
    ev.id = df.global.hist_event_next_id
    df.global.world.history.events:insert('#', ev)
    df.global.hist_event_next_id = df.global.hist_event_next_id + 1
end

-- the flags every natural megabeast nemesis carries (they survive death on existing records;
-- a freshly created record needs them or the beast is CULLABLE and not treated as a megabeast)
local function set_beast_flags(hf, nem)
    for _, f in ipairs({'BRAG_ON_KILL', 'KILL_QUEST', 'CHAT_WORTHY', 'FLASHES', 'DO_NOT_CULL'}) do
        pcall(function() nem.flags[f] = true end)
    end
    hf.flags.brag_on_kill = true
    hf.flags.kill_quest = true
    hf.flags.chatworthy = true
    hf.flags.flashes = true
    hf.flags.never_cull = true
end

-- worldgen-style nemesis record; id == index invariant
local function ensure_nemesis(hf)
    local nem = hf.nemesis_id >= 0 and df.nemesis_record.find(hf.nemesis_id)
    if not nem then
        local nems = df.global.world.nemesis.all
        nem = df.nemesis_record:new()
        nem.id = #nems
        nem.unit_id = hf.unit_id >= 0 and hf.unit_id or -1
        nem.save_file_id = -1
        nem.member_idx = 0
        nem.figure = hf
        nem.unit = hf.unit_id >= 0 and df.unit.find(hf.unit_id) or nil
        nem.group_leader_id = -1
        nem.activeplotindex = -1
        nem.travel_link_nemid = -1
        nem.ideal_item_container_id = -1
        nem.next_plot_year = -1
        nem.next_plot_season_count = -1
        nem.pool_id = nem.id
        nems:insert('#', nem)
        hf.nemesis_id = nem.id
    end
    set_beast_flags(hf, nem)
    return nem
end

-- the local map's cavern layer ids, discovered ones first
local function local_cavern_layers()
    local discovered, hidden = {}, {}
    if not dfhack.isMapLoaded() then return {} end
    local mf = df.global.world.features.map_features
    for i = 0, #mf - 1 do
        local f = mf[i]
        if df.feature_init_subterranean_from_layerst:is_instance(f) then
            table.insert(f.flags.Discovered and discovered or hidden, f.layer)
        end
    end
    if #discovered > 0 then return discovered end
    return hidden
end

-- ---- the leave-dance: get DF to create the beast's world army itself --------
-- Hand-built army objects are NEVER selected by the native Megabeast(layer) event, even when
-- field-identical to a natural one (tested to ~1.4% residual chance) -- eligibility lives in
-- some registration only DF's own army creation performs. But DF creates a proper army the
-- moment a unit tries to LEAVE the map (the emigration flag recipe) -- and it even destroys
-- any duplicate army we made for the same nemesis. Both beasts whose armies were minted this
-- way were selected by the very next native event. So revival stages the resurrected unit at
-- a map edge with leave flags, waits for DF to mint the army (a few ticks), then converts it
-- to a hidden cavern lurker and shelves the unit back out of play.

-- walkable map-edge tile near z (widening the z window); nil if none found
local function find_edge_tile(z_center, z_span)
    local W = df.global.world.map.x_count
    local H = df.global.world.map.y_count
    local Z = df.global.world.map.z_count
    local function try(x, y, z)
        local b = dfhack.maps.getTileBlock(x, y, z)
        if b and b.walkable[x % 16][y % 16] > 0 then return xyz2pos(x, y, z) end
    end
    for dz = 0, z_span do
        for _, z in ipairs(dz == 0 and {z_center} or {z_center - dz, z_center + dz}) do
            if z >= 1 and z < Z then
                for i = 1, W - 2, 3 do
                    local p = try(i, 1, z) or try(i, H - 2, z)
                    if p then return p end
                end
                for j = 1, H - 2, 3 do
                    local p = try(1, j, z) or try(W - 2, j, z)
                    if p then return p end
                end
            end
        end
    end
end

-- stage 1: put the revived unit at a map edge, invisible, asking to leave. DF notices within
-- a few ticks and mints a real army for its nemesis (taking over hf whereabouts).
local function stage_departure(hf, u)
    local pos = find_edge_tile(u.pos.z, 12) or find_edge_tile(u.pos.z, 60)
    if not pos then return false end
    dfhack.units.teleport(u, pos)
    u.flags1.move_state = true
    u.flags1.inactive = false
    u.flags1.incoming = false
    u.flags1.can_swap = true
    u.flags1.hidden_in_ambush = true          -- slip away unseen
    if not utils.linear_index(df.global.world.units.active, u.id, 'id') then
        df.global.world.units.active:insert('#', u)
    end
    u.following = nil
    u.flags1.forest = true                    -- the emigration "leave the map" recipe
    u.flags2.visitor = true
    u.animal.leave_countdown = 2
    return true
end

-- stage 2 (once DF has minted the army): convert it into the hidden cavern lurker the
-- Megabeast(layer) event selects from, and shelve the unit back out of play.
local function finish_departure(hf, u, layer)
    local a = hf.info.whereabouts.army_id >= 0 and df.army.find(hf.info.whereabouts.army_id)
    if not a then return false end
    a.flags.hidden = true
    a.controller_id = -1
    a.hidden_sr_ind = -1
    a.hidden_fl_ind = layer or -1             -- the cavern layer it lurks in
    u.flags1.inactive = true                  -- offloaded: alive but NOT in play
    u.flags1.hidden_in_ambush = false
    u.flags1.forest = false
    u.flags2.visitor = false
    u.animal.leave_countdown = 0
    hf.info.whereabouts.state = 3
    return true
end

-- staging queue (persisted in state.staging): beasts waiting for DF to mint their army.
-- Entries {hf=, army_before=, layer=, deadline=} -- checked every heartbeat frame while
-- non-empty (the mint takes only a few ticks); re-staged if DF hasn't reacted in a week.
local function pick_local_layer()
    local layers = local_cavern_layers()
    if #layers == 0 then return nil end
    return layers[math.random(#layers)]
end

local function process_staging()
    local staging = state.staging
    local dirty = false
    for i = #staging, 1, -1 do
        local st = staging[i]
        local hf = df.historical_figure.find(st.hf)
        local u = hf and hf.unit_id >= 0 and df.unit.find(hf.unit_id)
        if not hf or not u or hf.died_year >= 0 then
            table.remove(staging, i)                        -- died mid-staging / gone: drop
            dirty = true
        elseif hf.info.whereabouts.army_id >= 0
            and hf.info.whereabouts.army_id ~= st.army_before
            and df.army.find(hf.info.whereabouts.army_id) then
            if finish_departure(hf, u, st.layer) then       -- DF minted the army: convert it
                print(('tarrasque: %s now lurks in the deep, awaiting its return'):format(hf_name(hf)))
                table.remove(staging, i)
                dirty = true
            end
        elseif df.global.cur_year * 403200 + df.global.cur_year_tick > st.deadline then
            stage_departure(hf, u)                          -- DF didn't react: re-stage
            st.deadline = df.global.cur_year * 403200 + df.global.cur_year_tick + 7 * 1200
            dirty = true
        end
    end
    if dirty then save_state() end
end

local function queue_staging(hf, u, layer)
    table.insert(state.staging, {hf = hf.id, army_before = hf.info.whereabouts.army_id,
        layer = layer, deadline = df.global.cur_year * 403200 + df.global.cur_year_tick + 7 * 1200})
    save_state()
    return stage_departure(hf, u)
end

-- revive one dead beast. Returns true + a log line, or false + a skip reason.
local function revive_beast(hfid)
    local hf = df.historical_figure.find(hfid)
    if not hf or hf.died_year < 0 then return false, 'not dead' end
    local cls = race_classes()[hf.race]
    if not cls then return false, 'not an eligible beast' end
    local name = hf_name(hf)
    local u = hf.unit_id >= 0 and df.unit.find(hf.unit_id) or nil

    if hf.unit_id >= 0 and not u then
        return false, name .. ': its remains lie at an unloaded site'
    end
    if u and (df.global.cur_year - hf.died_year) < MIN_DEAD_YEARS then
        return false, name .. ': dead less than a year -- too soon to stir'
    end

    local killer = find_killer(hfid)
    local entry = {hf = hfid, name = name, class = cls, died = hf.died_year,
                   killer = killer, revived = df.global.cur_year}

    if u then
        -- fort-killed: resurrect the real unit and shelve it out of play. full-heal -r flips
        -- died_year/ghost, heals the body and logs the revival event itself. Any remains in
        -- the fort are deliberately LEFT ALONE -- trophies of the first kill stay in history
        -- even as the beast walks again.
        dfhack.run_command('full-heal', '-r', '--unit', tostring(u.id))
        if u.flags2.killed or hf.died_year >= 0 then
            return false, name .. ': resurrection failed'
        end
        u.flags1.inactive = true                    -- offloaded: alive but NOT in play
        ensure_nemesis(hf)
        if cls == 'fb' then
            -- stage the leave-dance: DF mints the beast's world army itself (hand-built ones
            -- are never selected); the heartbeat finishes the conversion within a few ticks
            local layer = pick_local_layer()
            if layer and queue_staging(hf, u, layer) then
                entry.army = layer
            else
                entry.note = 'no cavern layer / edge tile here -- alive but not re-attackable yet'
            end
        else
            -- titans/colossi keep their lair-site whereabouts (death leaves it intact);
            -- surface Megabeast events pick them from there
            hf.info.whereabouts.body_state = 0
            hf.info.whereabouts.body_state_id = -1
        end
        entry.awaiting = true
    else
        -- no unit anywhere: abstract revival (alive in legends; nothing for a local event
        -- to materialize, so it cannot re-attack this fort)
        hf.died_year = -1
        hf.died_seconds = -1
        hf.flags.ghost = false
        ensure_nemesis(hf)
        add_revival_event(hfid)
        hf.info.whereabouts.body_state = 0
        hf.info.whereabouts.body_state_id = -1
        entry.awaiting = false
    end
    table.insert(state.log, entry)
    save_state()
    return true, ('%s (died %d%s) walks the world again%s'):format(name, entry.died,
        killer >= 0 and (', slain by hf ' .. killer) or '',
        entry.awaiting and ' -- it will return...' or ' (abstract: no body to send back)')
end

-- ---- the winter-solstice roll -------------------------------------------------

local function solstice_roll(verbose)
    load_state()
    local s = survey()
    local candidates = {}
    for _, c in ipairs({'fb', 'mega'}) do
        for _, hfid in ipairs(s[c].dead_loaded) do candidates[#candidates + 1] = hfid end
        for _, hfid in ipairs(s[c].dead_nounit) do candidates[#candidates + 1] = hfid end
    end
    local revived = 0
    for _, hfid in ipairs(candidates) do
        if math.random(REVIVE_CHANCE) == 1 then
            local ok, msg = revive_beast(hfid)
            if ok then
                revived = revived + 1
                print('tarrasque: ' .. msg)
            elseif verbose then
                print('tarrasque: skipped -- ' .. msg)
            end
        end
    end
    state.last_roll_year = df.global.cur_year
    save_state()
    if verbose or revived > 0 then
        print(('tarrasque: solstice of %d -- %d dead beast%s rolled, %d revived'):format(
            df.global.cur_year, #candidates, #candidates == 1 and '' or 's', revived))
    end
    return revived
end

-- ---- background service ----------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

local function service_tick()
    load_state()
    if df.global.cur_year > state.last_roll_year and df.global.cur_year_tick >= SOLSTICE_TICK then
        pcall(solstice_roll, false)
    end
end

local hb_gen = 0
local last_run = nil
local DAY_TICKS = 1200

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        -- abs(): the calendar is NOT monotonic on this setup (timestream recalibrates)
        if not last_run or math.abs(now - last_run) >= DAY_TICKS then
            last_run = now
            service_tick()
        end
        -- staging is time-critical (DF mints the army within a few ticks of the leave
        -- flags): check every frame while anything is staged
        if state and state.staging and #state.staging > 0 then
            local ok, err = pcall(process_staging)
            if not ok then dfhack.printerr('tarrasque: staging pass failed: ' .. tostring(err)) end
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
    if sc == SC_WORLD_LOADED then
        state, class_cache = nil, nil
        load_state()
        if state.enabled then start() end
    elseif sc == SC_WORLD_UNLOADED then
        stop()
        state, class_cache = nil, nil
    end
end

-- exported for reqscript-driven toggling (the `enable` command path can serve a stale copy)
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

-- ---- command line ---------------------------------------------------------

if not dfhack.isWorldLoaded() then qerror('tarrasque needs a loaded world') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('tarrasque: ' .. (enabled
        and 'enabled -- dead megabeasts roll 1/100 to revive each winter solstice'
        or 'disabled'))
    return
end

local args = {...}
local cmd = args[1]

if cmd == 'roll' then
    solstice_roll(true)
elseif cmd == 'revive' then
    local n = tonumber(args[2]) or 1
    local s = survey()
    local candidates = {}
    for _, c in ipairs({'fb', 'mega'}) do
        for _, hfid in ipairs(s[c].dead_loaded) do candidates[#candidates + 1] = hfid end
        for _, hfid in ipairs(s[c].dead_nounit) do candidates[#candidates + 1] = hfid end
    end
    local done = 0
    while done < n and #candidates > 0 do
        local i = math.random(#candidates)
        local hfid = table.remove(candidates, i)
        local ok, msg = revive_beast(hfid)
        print('tarrasque: ' .. msg)
        if ok then done = done + 1 end
    end
    if done == 0 then print('tarrasque: nothing revivable right now.') end
else
    -- status
    local s = survey()
    print(('tarrasque: %s'):format(enabled and 'ENABLED (1/100 revival roll each 1 Obsidian)' or 'disabled'))
    for _, c in ipairs({{'fb', 'forgotten beasts'}, {'mega', 'titans/colossi'}}) do
        local t = s[c[1]]
        print(('  %-17s %d alive (%d awaiting return), %d dead (%d revivable here, %d unreachable in history, %d at other sites)')
            :format(c[2] .. ':', t.alive, t.awaiting, t.dead, #t.dead_loaded, #t.dead_nounit, t.dead_elsewhere))
    end
    print(('  last solstice roll: %s'):format(state.last_roll_year >= 0 and ('year ' .. state.last_roll_year) or 'never'))
    local shown = 0
    for i = #state.log, 1, -1 do
        local e = state.log[i]
        if shown == 0 then print('  recent revivals:') end
        print(('    %s (died %d, revived %d%s)'):format(e.name, e.died, e.revived,
            e.awaiting and ', awaiting return' or ', abstract'))
        shown = shown + 1
        if shown >= 5 then break end
    end
    if not enabled then print('  `enable tarrasque` to start; `tarrasque revive` to force a revival.') end
    print('  to hurry a re-attack: `force-more forgotten-beast` (native event, DF picks the beast)')
end
