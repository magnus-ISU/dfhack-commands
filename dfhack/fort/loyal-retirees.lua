-- Bring every citizen back when you unretire a fortress.
--@module = true
--[[
loyal-retirees

Retiring a fortress scatters its citizens. Some come back when you unretire, many do not --
they end up settled at other sites, and DF offers no way to recall them.

This records who lived here the moment you RETIRE, and summons every one of them back the
next time you unretire. Anyone still alive is brought home; the dead are reported and
skipped. No other filtering -- if they were a citizen when you retired, they return.
Livestock is excluded (`getCitizens` counts tame animals, and a fort's yaks carry historical
figures of their own); only castes with CAN_LEARN are recorded.

Progress is reported through DF's own announcement log, not the DFHack console, so it reads
alongside the rest of your fortress news.

How it works
============

**At retire.** An overlay on the Esc menu watches `main_interface.options.fort_retirement_confirm`.
The moment DF puts up "Really retire?", the citizen roster is written to this site's
persistent data (`dfhack.persistent.saveSiteData`). The snapshot is taken when the dialog
OPENS, not when you click Retire, so it is captured whether you confirm or cancel -- a
cancelled retirement just leaves a harmless roster behind that the next one overwrites.

Each roster member also gets `histfig.flags.never_cull` and `nemesis.flags.DO_NOT_CULL`.
This matters more than it looks: DF culls historical figures it considers unimportant, and
a citizen whose NEMESIS RECORD is culled becomes unrecoverable by any means, because the
recall rides on nemesis ids. Ordinary migrants are exactly what culling targets.

**At unretire.** On map load, the roster is compared against the current citizens. Everyone
missing and still alive is brought home in one trip, by the mechanism below.

Summoning people home
=====================

DF only materialises an off-map histfig as a real unit when an ARMY carrying them arrives at
your site -- and that path restores the ORIGINAL unit, with its skills, wounds, clothing and
inventory intact. Rebuilding units from scratch instead would produce blank strangers wearing
the right names.

Armies cannot be fabricated: DF allocates them from an internal pool, and one built from Lua
(`pool_id = -1`) is silently culled within ~50 ticks. Army CONTROLLERS -- the mission orders,
a separate object -- survive fabrication just fine. So this does not build an army. It builds
a fake mission and lets DF build the army:

  1. fabricate an `army_controller` (a DIPLOMACY task) for the site government;
  2. bind it to an ACTIVE noble position assignment, both ways --
     `assignment.assigned_army_controller_id` and `controller.assigned_epp_*`;
  3. put that noble on a map-edge tile and hold them there.

DF resolves a departing unit's mission through unit -> histfig -> position assignment ->
controller, mints a real pool-registered army, and off they go. The returnees are inserted
into `army.members` (sorted by `nemesis_id`) the frame it appears. When the army gets home
they arrive as visitors and are naturalised with `makeown`.

Gotchas this encodes, each of which cost a debugging session:

  * The courier must stand on a tile of the MAP PERIMETER -- any of the four edges, direction
    irrelevant. Non-perimeter tiles never work however walkable. And DF's departure check is
    PERIODIC, so a courier who wanders off before it fires simply never leaves; they are
    pinned to the tile until the mission starts.
  * The position must be `active` (enabled in this fort). `active` is set on EMPTY assignments
    too, so it means "this office exists here", not "on a mission".
  * Never store scratch state on a df struct (`hf.done = true` throws and silently kills the
    frame callback it was running in). Progress lives in plain Lua tables.

Usage::

    loyal-retirees                 -- status: roster on file, who is missing
    loyal-retirees snapshot        -- record the current citizens now
    loyal-retirees recover         -- summon missing roster members immediately
    loyal-retirees migrate <id>... -- summon any historical figures by id, from anywhere
    loyal-retirees forget          -- discard the stored roster

`migrate` uses the same machinery as `recover` but takes historical figure ids directly, so
it can recruit anyone alive in the world -- handy for testing the recall path without waiting
on a retirement, and for deliberately headhunting a particular legend::

    loyal-retirees migrate 163 204 197

Enable the retire hook (recommended) with::

    overlay enable fort/loyal-retirees.hook
]]

local utils = require('utils')
local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'loyal-retirees'
local MAX_PIN_FRAMES = 20000     -- frames to hold the courier on the edge before giving up
local MAX_WAIT_FRAMES = 60000     -- frames to wait for the army to come home

local function translate(name)
    local ok, s = pcall(dfhack.translation.translateName, name, true)
    return ok and s or '?'
end

-- Report through DF's own announcement log rather than the DFHack console, so the player
-- sees what happened in the place they already read fortress news. `true` recentres/pauses
-- on the announcement the same way DF's own notices do.
local function announce(text, color)
    pcall(dfhack.gui.showAnnouncement, text, color or COLOR_WHITE, true)
end

-- ---------------------------------------------------------------------------
-- roster storage
-- ---------------------------------------------------------------------------

local function load_roster()
    return dfhack.persistent.getSiteData(GLOBAL_KEY, {members = {}, year = -1})
end

local function save_roster(r)
    dfhack.persistent.saveSiteData(GLOBAL_KEY, r)
end

-- Citizens worth recording: people, backed by a historical figure AND a nemesis record.
--   * CAN_LEARN excludes livestock. `getCitizens` counts tame animals as citizens, and a
--     fort's yaks and war dogs can carry historical figures and nemesis records of their own
--     -- they would otherwise be recalled by diplomatic mission alongside the dwarves.
--   * the histfig + nemesis record are what the recall rides on; without both there is no
--     way to bring someone home by any route.
local function is_person(u)
    return dfhack.units.casteFlagSet(u.race, u.caste, df.caste_raw_flags.CAN_LEARN)
end

function snapshot()
    local members, skipped = {}, 0
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
        if hf and hf.nemesis_id >= 0 and is_person(u) then
            -- ids only. Names are NOT stored: persistent data is JSON, and DF names carry
            -- CP437 bytes that are not valid UTF-8, which makes the whole roster unreadable
            -- on the way back in. The historical figure is the source of truth for the name.
            members[#members + 1] = {hf = hf.id, nem = hf.nemesis_id}
            -- protect them from being culled while the fort is retired
            pcall(function() hf.flags.never_cull = true end)
            local nem = df.nemesis_record.find(hf.nemesis_id)
            if nem then pcall(function() nem.flags.DO_NOT_CULL = true end) end
        else
            skipped = skipped + 1
        end
    end
    local roster = {members = members, year = df.global.cur_year, site = df.global.plotinfo.site_id}
    save_roster(roster)
    return #members, skipped
end

-- ---------------------------------------------------------------------------
-- courier + departure point
-- ---------------------------------------------------------------------------

-- A courier is the holder of a position that is ACTIVE (this office exists in this fort),
-- currently filled, on the map, and not already away on a mission.
local function find_courier()
    local fe = df.historical_entity.find(df.global.plotinfo.group_id)
    if not fe then return end
    for _, a in ipairs(fe.positions.assignments) do
        local ok, active = pcall(function()
            return a.flags[df.entity_position_profile_flags.active]
        end)
        if ok and active and a.histfig >= 0 and a.assigned_army_controller_id < 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u and not u.flags1.inactive and dfhack.units.isCitizen(u) then
                return a, hf, u
            end
        end
    end
end

-- Departure only happens from the MAP PERIMETER. Pick the nearest perimeter tile whose
-- surface is walkable and in the courier's own walkability group.
local function edge_tile(unit)
    local W = df.global.world.map
    local ok, mygroup = pcall(dfhack.maps.getWalkableGroup, unit.pos)
    if not ok then mygroup = nil end
    local xmax, ymax = W.x_count - 1, W.y_count - 1
    local cands = {}
    for y = 1, ymax - 1 do
        cands[#cands + 1] = {0, y}
        cands[#cands + 1] = {xmax, y}
    end
    for x = 1, xmax - 1 do
        cands[#cands + 1] = {x, 0}
        cands[#cands + 1] = {x, ymax}
    end
    local best, bestd
    for _, xy in ipairs(cands) do
        for z = W.z_count - 1, 1, -1 do
            local pos = xyz2pos(xy[1], xy[2], z)
            local tt = dfhack.maps.getTileType(pos)
            if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR then
                local fl, occ = dfhack.maps.getTileFlags(pos)
                if fl and fl.outside and not fl.hidden
                    and occ and occ.building == df.tile_building_occ.None then
                    local ok2, wg = pcall(dfhack.maps.getWalkableGroup, pos)
                    if ok2 and wg ~= 0 and (not mygroup or wg == mygroup) then
                        local d = math.abs(xy[1] - unit.pos.x) + math.abs(xy[2] - unit.pos.y)
                        if not bestd or d < bestd then best, bestd = pos, d end
                    end
                end
                break                      -- topmost floor in the column is the surface
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- the fake mission
-- ---------------------------------------------------------------------------

local function next_id(vec)
    local m = -1
    for _, o in ipairs(vec) do if o.id > m then m = o.id end end
    return m + 1
end

local function make_mission(courier_hf, assignment, dest_site)
    local world = df.global.world
    local govt = df.global.plotinfo.group_id
    local site = df.world_site.find(df.global.plotinfo.site_id)
    local hx, hy = site.global_min_x * 3, site.global_min_y * 3

    local c = df.army_controller:new()
    c.id = next_id(world.army_controllers.all)
    c.entity_id, c.site_id, c.subregion_id = govt, dest_site, -1
    c.pos_x, c.pos_y = hx, hy
    c.year, c.year_tick = df.global.cur_year, df.global.cur_year_tick
    c.parent_id, c.master_id = -1, c.id
    c.master_hf, c.commander_hf = courier_hf.id, -1
    c.origin_task_holder_nemesis_id, c.origin_task_id = -1, -1
    c.origin_plot_holder_nemesis_id, c.origin_plot_id = -1, -1
    c.goal = df.army_controller_goal_type.DIPLOMACY
    local gd = df.ac_goal_diplomacyst:new()
    gd.topic:insert('#', df.meeting_topic.OpenTrade)
    gd.topic_id1:insert('#', -1)
    gd.topic_id2:insert('#', -1)
    gd.source_abs_smm_x, gd.source_abs_smm_y = hx, hy
    c.data.goal_diplomacy = gd
    c.flag.civ_rep = true
    c.assigned_epp_entity_id:insert('#', govt)
    c.assigned_epp_epp_id:insert('#', assignment.id)
    world.army_controllers.all:insert('#', c)
    assignment.assigned_army_controller_id = c.id
    return c
end

local function army_of(ctrl_id)
    for _, a in ipairs(df.global.world.armies.all) do
        local ac = a.controller
        if a.controller_id == ctrl_id or (ac and ac.master_id == ctrl_id) then return a end
    end
end

-- Insert a rider into a live army. Members are kept sorted by nemesis_id.
local function board_one(army, hf)
    for _, m in ipairs(army.members) do
        if m.nemesis_id == hf.nemesis_id then return false end
    end
    local ref = army.members[0]
    local m = df.army_nemesisst:new()
    m.nemesis_id = hf.nemesis_id
    m.stored_fat = ref and ref.stored_fat or 413500
    m.tracking_rating = ref and ref.tracking_rating or 15
    m.sneak_rating = ref and ref.sneak_rating or 31
    m.smell_trigger, m.odor_level = 50, 50
    m.travel_rate = ref and ref.travel_rate or 10
    m.abs_x, m.abs_y, m.abs_z = -1000000, -1000000, -1000000
    m.mount_nemid, m.section_master_acid, m.section_index = -1, -1, -1
    utils.insert_sorted(army.members, m, 'nemesis_id')

    local w = hf.info.whereabouts
    local old_site = w.site_id
    w.army_id, w.state, w.site_id = army.id, df.whereabouts_type.army_died, -1
    -- DF does not clear the old residency itself; leaving it makes the histfig a resident of
    -- two places, and the copy at the old site can later die in a worldgen event while a unit
    -- here still points at them.
    if old_site >= 0 then
        local st = df.world_site.find(old_site)
        if st then
            for k = #st.populace.nemesis - 1, 0, -1 do
                if st.populace.nemesis[k] == hf.nemesis_id then st.populace.nemesis:erase(k) end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- recovery
-- ---------------------------------------------------------------------------

-- who from the roster is not currently a citizen here?
local function missing_from(roster)
    local here = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        if u.hist_figure_id >= 0 then here[u.hist_figure_id] = true end
    end
    local away, dead = {}, {}
    for _, m in ipairs(roster.members or {}) do
        if not here[m.hf] then
            local hf = df.historical_figure.find(m.hf)
            if not hf then
                dead[#dead + 1] = m
            elseif hf.died_year ~= -1 then
                dead[#dead + 1] = m
            elseif hf.nemesis_id < 0 then
                dead[#dead + 1] = m       -- nemesis culled: unrecoverable
            else
                away[#away + 1] = hf
            end
        end
    end
    return away, dead
end

-- Send one mission that fetches everyone in `people` (a list of historical_figure). Shared by
-- `recover` (roster members who went missing) and `migrate` (anybody you name).
-- `what` names the group for the announcements; `dead` is reported but not fetched.
local function summon(people, what, dead)
    dead = dead or 0
    local assignment, chf, cu = find_courier()
    if not assignment then
        announce('No noble is free to carry word abroad. Appoint one, then try again.', COLOR_YELLOW)
        dfhack.printerr('loyal-retirees: no active, filled, free noble position to carry the mission.')
        dfhack.printerr('  Appoint a noble to any active office and run the command again.')
        return false
    end
    local edge = edge_tile(cu)
    if not edge then
        dfhack.printerr('loyal-retirees: no reachable map-edge tile found')
        return false
    end

    local ctrl = make_mission(chf, assignment, people[1].info.whereabouts.site_id)
    dfhack.units.teleport(cu, edge)
    dfhack.units.setPathGoal(cu, edge, df.unit_path_goal.SeekStation)

    announce(('%s departs to summon %d %s%s.'):format(
        translate(chf.name), #people, what, dead > 0 and (' -- %d cannot be reached'):format(dead) or ''),
        COLOR_LIGHTCYAN)
    print(('loyal-retirees: summoning %d (%d unreachable)'):format(#people, dead))
    print(('  courier %s -> edge (%d,%d,%d), mission %d'):format(
        translate(chf.name), edge.x, edge.y, edge.z, ctrl.id))

    -- Hold the courier on the edge: DF's departure check is periodic, and a courier who
    -- steps off before it fires never leaves at all.
    local pins = 0
    local function pin()
        pins = pins + 1
        if not df.army_controller.find(ctrl.id) then return end
        local u = df.unit.find(cu.id)
        if u and not u.flags1.inactive
            and (u.pos.x ~= edge.x or u.pos.y ~= edge.y or u.pos.z ~= edge.z) then
            pcall(dfhack.units.teleport, u, edge)
        end
        if pins < MAX_PIN_FRAMES then dfhack.timeout(1, 'frames', pin) end
    end
    dfhack.timeout(1, 'frames', pin)

    -- Board everyone the frame DF mints the army.
    local tries, boarded = 0, false
    local function board()
        tries = tries + 1
        local army = army_of(ctrl.id)
        if army then
            local n = 0
            for _, hf in ipairs(people) do
                if board_one(army, hf) then n = n + 1 end
            end
            boarded = true
            print(('loyal-retirees: %d boarded army %d'):format(n, army.id))
            return
        end
        if not df.army_controller.find(ctrl.id) then
            announce('The journey was abandoned before it began. Run the command again to retry.',
                COLOR_YELLOW)
            dfhack.printerr('loyal-retirees: mission ended before an army appeared -- run it again')
            return
        end
        if tries < MAX_PIN_FRAMES then dfhack.timeout(1, 'frames', board) end
    end
    dfhack.timeout(1, 'frames', board)

    -- Naturalise each arrival as their unit materialises. Do NOT stop early just because
    -- nobody is in an army any more: there is a window where the army has dissolved and the
    -- unit has not loaded yet, and giving up there strands them as permanent visitors.
    local waited, settled = 0, {}
    local function settle()
        waited = waited + 1
        if boarded then
            local remaining = 0
            for _, hf in ipairs(people) do
                if not settled[hf.id] then
                    local u = df.unit.find(hf.unit_id)
                    if u and not u.flags1.inactive and hf.info.whereabouts.army_id < 0 then
                        u.flags2.visitor = false
                        pcall(dfhack.units.makeown, u)
                        if dfhack.units.isCitizen(u) then
                            settled[hf.id] = true
                            announce(('%s has joined the fortress.')
                                :format(dfhack.units.getReadableName(u)), COLOR_LIGHTGREEN)
                        end
                    end
                    if not settled[hf.id] then remaining = remaining + 1 end
                end
            end
            if remaining == 0 then
                announce(('All %d have arrived.'):format(#people), COLOR_LIGHTGREEN)
                return
            end
        end
        if waited < MAX_WAIT_FRAMES then dfhack.timeout(1, 'frames', settle) end
    end
    dfhack.timeout(1, 'frames', settle)
    return true
end

-- Summon roster members who are no longer here.
function recover()
    local roster = load_roster()
    if #(roster.members or {}) == 0 then
        dfhack.printerr('loyal-retirees: no roster on file for this site')
        return
    end
    local away, dead = missing_from(roster)
    if #away == 0 then
        print(('loyal-retirees: nobody to summon (%d dead/unrecoverable)'):format(#dead))
        return
    end
    summon(away, ('former citizen%s home'):format(#away == 1 and '' or 's'), #dead)
end

-- Summon anybody in the world by historical figure id, whether or not they ever lived here.
-- Useful for testing the recall machinery, and for recruiting a specific person on purpose.
function migrate(ids)
    local people, skipped = {}, {}
    local here = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        if u.hist_figure_id >= 0 then here[u.hist_figure_id] = true end
    end
    for _, id in ipairs(ids) do
        local hf = df.historical_figure.find(id)
        if not hf then skipped[#skipped + 1] = ('%d: no such historical figure'):format(id)
        elseif hf.died_year ~= -1 then skipped[#skipped + 1] = ('%d: dead'):format(id)
        elseif hf.nemesis_id < 0 then skipped[#skipped + 1] = ('%d: no nemesis record, cannot travel'):format(id)
        elseif here[id] then skipped[#skipped + 1] = ('%d: already here'):format(id)
        elseif hf.info and hf.info.whereabouts and hf.info.whereabouts.army_id >= 0 then
            skipped[#skipped + 1] = ('%d: already travelling with an army'):format(id)
        else
            people[#people + 1] = hf
        end
    end
    for _, why in ipairs(skipped) do dfhack.printerr('  skipped hf ' .. why) end
    if #people == 0 then
        dfhack.printerr('loyal-retirees: nobody to migrate')
        return
    end
    for _, hf in ipairs(people) do
        print(('  %s (hf %d)'):format(translate(hf.name), hf.id))
    end
    summon(people, ('new arrival%s'):format(#people == 1 and '' or 's'), #skipped)
end

-- ---------------------------------------------------------------------------
-- the retire hook
-- ---------------------------------------------------------------------------

RetireHook = defclass(RetireHook, overlay.OverlayWidget)
RetireHook.ATTRS{
    desc = 'Records the citizen roster when you retire, so loyal-retirees can summon them back.',
    default_pos = {x = -1, y = -1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Options',
    frame = {w = 1, h = 1},           -- invisible; we only need the update tick
    overlay_onupdate_max_freq_seconds = 0,
}

function RetireHook:init()
    self.armed = false
end

function RetireHook:overlay_onupdate()
    local opts = df.global.game.main_interface.options
    local confirming = opts.open and opts.fort_retirement_confirm
    if confirming and not self.armed then
        self.armed = true             -- rising edge: snapshot once per time the dialog opens
        local n = snapshot()
        announce(('%d citizens have been recorded. Should this fortress be reclaimed, they will be sent for.')
            :format(n), COLOR_LIGHTCYAN)
    elseif not confirming then
        self.armed = false
    end
end

OVERLAY_WIDGETS = {hook = RetireHook}

-- ---------------------------------------------------------------------------
-- unretire: summon on map load
-- ---------------------------------------------------------------------------

dfhack.onStateChange[GLOBAL_KEY] = function(ev)
    if ev ~= SC_MAP_LOADED then return end
    if not dfhack.world.isFortressMode() then return end
    local roster = load_roster()
    if #(roster.members or {}) == 0 then return end
    local away, dead = missing_from(roster)
    if #away == 0 then return end
    announce(('%d former citizen%s of this fortress %s living elsewhere%s. Run loyal-retirees recover to send for them.')
        :format(#away, #away == 1 and '' or 's', #away == 1 and 'is' or 'are',
                #dead > 0 and (' (%d have died)'):format(#dead) or ''), COLOR_LIGHTCYAN)
end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

local function status()
    local roster = load_roster()
    local n = #(roster.members or {})
    if n == 0 then
        print('loyal-retirees: no roster recorded for this site yet.')
        print('  It is written automatically when you open the Retire confirmation,')
        print('  or right now with: loyal-retirees snapshot')
        return
    end
    print(('loyal-retirees: %d citizens recorded in year %s'):format(n, tostring(roster.year)))
    local away, dead = missing_from(roster)
    print(('  home: %d   away: %d   dead/unrecoverable: %d'):format(n - #away - #dead, #away, #dead))
    for i, hf in ipairs(away) do
        if i > 10 then print(('  ... and %d more'):format(#away - 10)) break end
        local w = hf.info.whereabouts
        local st = w.site_id >= 0 and df.world_site.find(w.site_id)
        print(('    %-28s at %s'):format(translate(hf.name), st and translate(st.name) or 'unknown'))
    end
end

if dfhack_flags and dfhack_flags.module then return end

local cmd = ({...})[1]
if cmd == 'snapshot' then
    local n, skipped = snapshot()
    print(('loyal-retirees: recorded %d citizens%s'):format(
        n, skipped > 0 and (' (%d skipped: livestock or no historical figure)'):format(skipped) or ''))
elseif cmd == 'recover' then
    recover()
elseif cmd == 'migrate' then
    local args = {...}
    local ids = {}
    for i = 2, #args do
        local n = tonumber(args[i])
        if n then ids[#ids + 1] = n
        else dfhack.printerr(('not a historical figure id: %s'):format(tostring(args[i]))) end
    end
    if #ids == 0 then
        qerror('usage: loyal-retirees migrate <hf_id> [<hf_id> ...]')
    end
    migrate(ids)
elseif cmd == 'forget' then
    dfhack.persistent.deleteSiteData(GLOBAL_KEY)
    print('loyal-retirees: roster discarded')
else
    status()
end
