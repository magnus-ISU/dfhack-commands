-- Squads for fort/planeswalkers: every squad of the fort's site government
-- with its members, uniforms, ammunition, supplies and barracks, plus the
-- military positions (commander, captains) that come with them.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local match = reqscript('internal/planeswalkers/match')
local extras = reqscript('internal/planeswalkers/extras')

local FILE = '/squads.json'

local function fort_entity() return df.historical_entity.find(df.global.plotinfo.group_id) end

local function subtype_token(item_type, subtype)
    if item_type < 0 or subtype < 0 then return nil end
    local ok, def = pcall(dfhack.items.getSubtypeDef, item_type, subtype)
    return ok and def and def.id or nil
end

local function mat_token(mt, mx)
    if mt < 0 then return nil end
    local mi = dfhack.matinfo.decode(mt, mx)
    return mi and mi:getToken() or nil
end

local function spec_out(sp)
    return {
        t = sp.item_type >= 0 and df.item_type[sp.item_type] or nil,
        st = subtype_token(sp.item_type, sp.item_subtype),
        cls = sp.material_class >= 0 and df.entity_material_category[sp.material_class] or nil,
        mat = mat_token(sp.mattype, sp.matindex),
        color = sp.color,
        indiv = sp.indiv_choice.whole,
    }
end

local function squad_out(ctx, ent, sq)
    local rec = {
        name = extras.name_out(sq.name), alias = sq.alias,
        priority = sq.uniform_priority,
        supplies = {food = sq.supplies.carry_food, water = sq.supplies.carry_water},
        routine = sq.cur_routine_idx,
        positions = {}, ammo = {}, rooms = {},
    }
    for _, p in ipairs(ent.positions.own) do
        if p.id == sq.leader_position then rec.leader_code = p.code end
    end
    for i = 0, #sq.positions - 1 do
        local pos = sq.positions[i]
        local prec = {hf = pos.occupant >= 0 and pos.occupant or nil,
                      flags = pos.equipment.flags.whole, uniform = {}}
        for cat = 0, #pos.equipment.uniform - 1 do
            local list = {}
            for _, sp in ipairs(pos.equipment.uniform[cat]) do table.insert(list, spec_out(sp)) end
            if #list > 0 then prec.uniform[df.uniform_category[cat]] = list end
        end
        table.insert(rec.positions, prec)
    end
    for _, a in ipairs(sq.ammo.ammunition) do
        table.insert(rec.ammo, {
            t = a.item_type >= 0 and df.item_type[a.item_type] or nil,
            st = subtype_token(a.item_type, a.item_subtype),
            cls = a.material_class >= 0 and df.entity_material_category[a.material_class] or nil,
            mat = mat_token(a.mattype, a.matindex),
            amount = a.amount, flags = a.flags.whole,
        })
    end
    for _, r in ipairs(sq.rooms) do
        table.insert(rec.rooms, {bld = r.building_id, mode = r.mode.whole})
    end
    return rec
end

function save_phases(ctx)
    return {{
        name = 'squads',
        step = function(job)
            local out = {v = 1, list = {}}
            local ent = fort_entity()
            if ent then
                for _, sid in ipairs(ent.squads) do
                    local sq = df.squad.find(sid)
                    if sq then
                        local ok, rec = pcall(squad_out, ctx, ent, sq)
                        if ok then table.insert(out.list, rec)
                        else common.add_skip(ctx, 'squad-save-error', tostring(rec)) end
                    end
                end
            end
            common.write_json(ctx.dir .. FILE, out)
            ctx.manifest.counts.squads = #out.list
            print(('planeswalkers: %d squad(s) saved'):format(#out.list))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function unit_of_hf(hf)
    if not hf then return nil end
    for _, u in ipairs(df.global.world.units.active) do
        if u.hist_figure_id == hf.id then return u end
    end
end

-- a free captain-type assignment for this squad: the leader's own position
-- code when a slot is free there, else any squad position with room, else a
-- new assignment on a position that allows any number of captains
local function captain_assignment(ent, leader_code)
    local function free_slot(p)
        for _, a in ipairs(ent.positions.assignments) do
            if a.position_id == p.id and a.squad_id < 0 and a.histfig < 0 then return a end
        end
    end
    local candidates = {}
    for _, p in ipairs(ent.positions.own) do
        if p.squad_size > 0 then
            if p.code == leader_code then table.insert(candidates, 1, p)
            else table.insert(candidates, p) end
        end
    end
    for _, p in ipairs(candidates) do
        local a = free_slot(p)
        if a then return a end
    end
    for _, p in ipairs(candidates) do
        if p.number < 0 then
            local aid = ent.positions.next_assignment_id
            ent.positions.next_assignment_id = aid + 1
            local pidx
            for j = 0, #ent.positions.own - 1 do
                if ent.positions.own[j].id == p.id then pidx = j end
            end
            ent.positions.assignments:insert('#', {new = df.entity_position_assignment,
                id = aid, position_id = p.id, position_vector_idx = pidx or -1,
                histfig = -1, histfig2 = -1, squad_id = -1, st_id = -1, ab_id = -1,
                vassal_of_entity_id = -1, vassal_of_position_profile_id = -1,
                assigned_army_controller_id = -1, temp = 0})
            return ent.positions.assignments[#ent.positions.assignments - 1]
        end
    end
end

local function appoint(ent, a, hf)
    a.histfig = hf.id
    local l = df.histfig_entity_link_positionst:new()
    l.entity_id = ent.id
    l.link_strength = 100
    l.assignment_id = a.id
    l.start_year = df.global.cur_year
    hf.entity_links:insert('#', l)
end

local function spec_in(ctx, sp, s)
    sp.item = -1
    sp.item_type = s.t and df.item_type[s.t] or -1
    sp.item_subtype = (s.t and s.st) and match.resolve_subtype(ctx, s.t, s.st) or -1
    sp.material_class = s.cls and df.entity_material_category[s.cls] or -1
    local mi = s.mat and match.resolve_mat_token(ctx, s.mat)
    sp.mattype = mi and mi.type or -1
    sp.matindex = mi and mi.index or -1
    sp.color = s.color or -1
    pcall(function() sp.indiv_choice.whole = s.indiv or 0 end)
end

local function restore_squad(ctx, ent, rec)
    local leader_rec = rec.positions[1]
    local leader_hf = leader_rec and leader_rec.hf and ctx.hf_map and ctx.hf_map[leader_rec.hf]
    local leader = unit_of_hf(leader_hf)
    if not leader then return nil, 'leader not restored' end
    local a = captain_assignment(ent, rec.leader_code)
    if not a then return nil, 'no military position free' end
    appoint(ent, a, leader_hf)
    local sq = dfhack.military.makeSquad(a.id)
    if not sq then return nil, 'makeSquad refused' end
    sq.alias = common.fromu(rec.alias or '')
    pcall(function() if rec.name then extras.name_in(sq.name, rec.name, ctx) end end)
    sq.uniform_priority = rec.priority or 0
    sq.supplies.carry_food = rec.supplies and rec.supplies.food or 0
    sq.supplies.carry_water = rec.supplies and rec.supplies.water or 0
    if rec.routine and rec.routine < #sq.schedule.routine then sq.cur_routine_idx = rec.routine end
    -- the leader sits in slot 0 by hand (the API cannot seat leaders)
    sq.positions[0].occupant = leader_hf.id
    leader.military.squad_id = sq.id
    leader.military.squad_position = 0
    local members = 1
    for i = 2, #rec.positions do
        local prec = rec.positions[i]
        local hf = prec.hf and ctx.hf_map and ctx.hf_map[prec.hf]
        local u = unit_of_hf(hf)
        if u and i - 1 < #sq.positions then
            if dfhack.military.addToSquad(u.id, sq.id, i - 1) then members = members + 1
            else common.add_skip(ctx, 'squad-member-not-added', rec.alias or '') end
        elseif prec.hf then
            common.add_skip(ctx, 'squad-member-not-restored', rec.alias or '')
        end
    end
    for i, prec in ipairs(rec.positions) do
        local pos = sq.positions[i - 1]
        if pos then
            local eq = pos.equipment
            pcall(function() eq.flags.whole = prec.flags or 0 end)
            for catname, list in pairs(prec.uniform or {}) do
                local cat = df.uniform_category[catname]
                if cat then
                    for _, s in ipairs(list) do
                        local sp = df.squad_uniform_spec:new()
                        spec_in(ctx, sp, s)
                        eq.uniform[cat]:insert('#', sp)
                    end
                end
            end
        end
    end
    for _, arec in ipairs(rec.ammo or {}) do
        local am = df.squad_ammo_spec:new()
        am.item_type = arec.t and df.item_type[arec.t] or -1
        am.item_subtype = (arec.t and arec.st) and match.resolve_subtype(ctx, arec.t, arec.st) or -1
        am.material_class = arec.cls and df.entity_material_category[arec.cls] or -1
        local mi = arec.mat and match.resolve_mat_token(ctx, arec.mat)
        am.mattype = mi and mi.type or -1
        am.matindex = mi and mi.index or -1
        am.amount = arec.amount or 0
        pcall(function() am.flags.whole = arec.flags or 0 end)
        sq.ammo.ammunition:insert('#', am)
    end
    for _, r in ipairs(rec.rooms or {}) do
        local bld = ctx.bld_map and ctx.bld_map[r.bld]
        if bld then
            local ok = pcall(dfhack.military.updateRoomAssignments, sq.id, bld.id, r.mode or 0)
            if not ok then common.add_skip(ctx, 'squad-barracks-not-assigned', rec.alias or '') end
        end
    end
    return sq, members
end

function load_phases(ctx)
    return {{
        name = 'squads',
        step = function(job)
            local data = common.read_json(ctx.dir .. FILE)
            if not data then return true end
            local ent = fort_entity()
            if not ent then return true end
            local n, members = 0, 0
            for _, rec in ipairs(data.list or {}) do
                local ok, sq, res = pcall(restore_squad, ctx, ent, rec)
                if ok and sq then
                    n = n + 1
                    members = members + (res or 0)
                else
                    common.add_skip(ctx, 'squad-not-restored',
                                    (rec.alias or '') .. ': ' .. tostring(ok and res or sq))
                end
            end
            ctx.squads_restored = n
            print(('planeswalkers: %d squad(s) restored with %d member(s); their captains hold the ' ..
                   'military positions'):format(n, members))
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
