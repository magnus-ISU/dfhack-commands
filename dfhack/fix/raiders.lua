-- Fix squads and soldiers stuck on off-site raids.
--[[
fix/raiders

Raids in v50 can wedge in several distinct ways, all of which leave squads unusable or
soldiers lost "offscreen" forever. This walks every one of them and repairs what it finds:

  1. SOLDIERS STUCK OFF-MAP: a fort member's unit sits `flags1.inactive` (out of play)
     from a raid whose army no longer exists / no longer contains them. The unit is still
     in memory, so it is brought HOME: reactivated at a walkable map edge (it walks back
     in), whereabouts reset to this site, dead army references cleared. If the beast's
     army still exists but is a leaderless husk (controller gone), the member is extracted
     and the army deleted once empty.
     Raiders the world-sim KILLED (a raid army wiped en route -- e.g. by a wild cave
     dragon pack; the members are recorded DEAD in history while their unloaded units
     still stand invisible at the map edge with killed=false) STAY DEAD: those lingering
     units are marked killed so they stop haunting the map edge / unit lists. World
     deaths are real deaths -- the abstract army combat ignores gear and skill, so send
     bigger raiding parties instead.
  2. SQUADS BOUND TO DEAD MISSIONS: `squad.assigned_army_controller_id` pointing at a
     controller that no longer exists, or one with no army and no assigned squads (a husk
     that will never conclude). The binding is cleared so the squad can be ordered again.
  3. DANGLING SQUAD ACTIVITY: `squad.activity` referencing an activity entry that no
     longer exists -- the squad reads as eternally busy. Cleared.
  4. HUSK MISSION CONTROLLERS: army controllers belonging to YOUR fort government with no
     army and no assigned squads, older than a month -- missions that already fell apart
     but sit in the missions tab as "ongoing" forever. Removed.

Everything repaired is printed. Run with `-n` / `--dry-run` to only report.

Usage:
    fix/raiders           report and FIX everything found
    fix/raiders -n        report only (dry run)
]]

local args = {...}
local dry = args[1] == '-n' or args[1] == '--dry-run'
local function act(fmt, ...)
    print((dry and '[dry] ' or '') .. fmt:format(...))
end

if not dfhack.isMapLoaded() then qerror('fix/raiders needs a loaded fort') end

local gid = df.global.plotinfo.group_id
local site_id = df.global.plotinfo.site_id
local MONTH = 33600
local found = 0

-- ---- shared helpers ---------------------------------------------------------

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

local function is_fort_member(hf)
    for _, l in ipairs(hf.entity_links) do
        if l.entity_id == gid and df.histfig_entity_link_memberst:is_instance(l) then
            return true
        end
    end
    return false
end

-- remove a nemesis from an army's member list; delete the army if it empties
local function extract_from_army(army, nemesis_id)
    for i = #army.members - 1, 0, -1 do
        if army.members[i].nemesis_id == nemesis_id then
            army.members:erase(i)
        end
    end
    if #army.members == 0 then
        local armies = df.global.world.armies.all
        for i = #armies - 1, 0, -1 do
            if armies[i].id == army.id then
                armies:erase(i)
                pcall(function() army:delete() end)
                break
            end
        end
    end
end

-- ---- 1) soldiers stuck off-map ----------------------------------------------

local surface_z = df.global.window_z
for _, u in ipairs(df.global.world.units.all) do
    if u.flags1.inactive and not u.flags2.killed and u.civ_id == df.global.plotinfo.civ_id
        and u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf and is_fort_member(hf) then
            local wa = hf.info and hf.info.whereabouts
            local army = wa and wa.army_id >= 0 and df.army.find(wa.army_id) or nil
            -- stuck = off in an army that is gone, or a husk army with no controller.
            -- hf.died_year >= 0 with a live unit = the world-sim wiped the raid army and
            -- recorded the members dead while their real bodies still stand at the edge.
            local husk_army = army and army.controller_id >= 0
                and not df.army_controller.find(army.controller_id)
            if not army or husk_army or (wa and wa.army_id < 0) then
                found = found + 1
                if hf.died_year >= 0 then
                    -- world-sim wiped the raid: the death is REAL. Mark the lingering
                    -- unit killed so it stops haunting the map edge and unit lists.
                    act('laying to rest: %s (unit %d) -- died year %d on a raid; the body record is closed',
                        dfhack.units.getReadableName(u), u.id, hf.died_year)
                    if not dry then
                        if army and hf.nemesis_id >= 0 then
                            extract_from_army(army, hf.nemesis_id)
                        end
                        u.flags2.killed = true
                        if wa and wa.army_id >= 0 and not df.army.find(wa.army_id) then
                            wa.army_id = -1
                        end
                    end
                else
                    act('bringing home: %s (unit %d)%s',
                        dfhack.units.getReadableName(u), u.id,
                        army and ' -- extracting from husk army ' .. army.id or '')
                    if not dry then
                        if army and hf.nemesis_id >= 0 then
                            extract_from_army(army, hf.nemesis_id)
                        end
                        local pos = find_edge_tile(u.pos.z >= 0 and u.pos.z or surface_z, 12)
                            or find_edge_tile(surface_z, 60)
                        if pos then
                            if u.pos.x < 0 then u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z end
                            dfhack.units.teleport(u, pos)
                        end
                        u.flags1.inactive = false
                        u.flags1.incoming = true
                        u.flags1.move_state = false
                        local utils = require('utils')
                        if not utils.linear_index(df.global.world.units.active, u.id, 'id') then
                            df.global.world.units.active:insert('#', u)
                        end
                        if wa then
                            wa.state = 1
                            wa.site_id = site_id
                            wa.army_id = -1
                        end
                    end
                end
            end
        end
    end
end

-- ---- 2) + 3) squad bindings and activities ----------------------------------

for _, sq in ipairs(df.global.world.squads.all) do
    if sq.entity_id == gid then
        local name = dfhack.translation.translateName(sq.name, true)
        local acid = sq.assigned_army_controller_id
        if acid and acid >= 0 then
            local ac = df.army_controller.find(acid)
            local husk = ac and #ac.assigned_squads == 0
            if husk then
                -- does any army still serve this controller?
                for _, a in ipairs(df.global.world.armies.all) do
                    if a.controller_id == acid then husk = false break end
                end
            end
            if not ac or husk then
                found = found + 1
                act('squad %s: unbinding from %s mission controller %d', name,
                    ac and 'husk' or 'missing', acid)
                if not dry then sq.assigned_army_controller_id = -1 end
            end
        end
        if sq.activity and sq.activity >= 0 and not df.activity_entry.find(sq.activity) then
            found = found + 1
            act('squad %s: clearing dangling activity %d (read as eternally busy)', name, sq.activity)
            if not dry then sq.activity = -1 end
        end
    end
end

-- ---- 4) husk mission controllers of our government --------------------------

local now = df.global.cur_year * 403200 + df.global.cur_year_tick
local acs = df.global.world.army_controllers.all
for i = #acs - 1, 0, -1 do
    local ac = acs[i]
    if ac.entity_id == gid and #ac.assigned_squads == 0 then
        local has_army = false
        for _, a in ipairs(df.global.world.armies.all) do
            if a.controller_id == ac.id then has_army = true break end
        end
        local age = math.abs(now - (ac.year * 403200 + ac.year_tick))
        if not has_army and age > MONTH then
            found = found + 1
            local goal = df.army_controller_goal_type[ac.goal] or tostring(ac.goal)
            act('removing husk mission: controller %d (%s, year %d, site %d) -- no army, no squads',
                ac.id, goal, ac.year, ac.site_id)
            if not dry then
                acs:erase(i)
                pcall(function() ac:delete() end)
            end
        end
    end
end

if found == 0 then
    print('fix/raiders: nothing stuck -- all squads and soldiers accounted for.')
else
    print(('fix/raiders: %d issue%s %s.'):format(found, found == 1 and '' or 's',
        dry and 'found (dry run -- rerun without -n to fix)' or 'fixed'))
end
