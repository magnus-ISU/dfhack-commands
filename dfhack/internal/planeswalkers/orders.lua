-- Manager (work) orders for fort/planeswalkers: every order in the queue,
-- with its item, material, conditions and repeat schedule, in tokens.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local match = reqscript('internal/planeswalkers/match')

local FILE = '/orders.json'

-- jobs whose spec race sets the size of what is made
local SIZED_JOBS = {
    MakeArmor = true, MakeHelm = true, MakeGloves = true, MakeShoes = true,
    MakePants = true, MakeShield = true, MakeBackpack = true, MakeQuiver = true,
}

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

local function condition_out(c)
    local rec = {
        cmp = df.logic_condition_type[c.compare_type], val = c.compare_val,
        t = c.item_type >= 0 and df.item_type[c.item_type] or nil,
        st = subtype_token(c.item_type, c.item_subtype),
        mat = mat_token(c.mat_type, c.mat_index),
        f1 = c.flags1.whole, f2 = c.flags2.whole, f3 = c.flags3.whole,
        f4 = c.flags4, f5 = c.flags5,
        rclass = #c.reaction_class > 0 and c.reaction_class or nil,
        rprod = #c.has_material_reaction_product > 0 and c.has_material_reaction_product or nil,
        min_dim = c.min_dimension,
        tool_use = c.has_tool_use >= 0 and df.tool_uses[c.has_tool_use] or nil,
    }
    if c.metal_ore >= 0 then
        local raw = df.global.world.raws.inorganics.all[c.metal_ore]
        rec.ore = raw and raw.id or nil
    end
    if c.reaction_id >= 0 then
        local r = df.global.world.raws.reactions.reactions[c.reaction_id]
        rec.reaction = r and r.code or nil
        rec.contains = {}
        for _, i in ipairs(c.contains) do table.insert(rec.contains, i) end
    end
    if c.dye_color >= 0 then
        local col = df.global.world.raws.descriptors.colors[c.dye_color]
        rec.dye = col and col.id or nil
    end
    return rec
end

local function order_out(ctx, o)
    local rec = {
        id = o.id,
        job = df.job_type[o.job_type],
        t = o.item_type >= 0 and df.item_type[o.item_type] or nil,
        st = subtype_token(o.item_type, o.item_subtype),
        reaction = #o.reaction_name > 0 and o.reaction_name or nil,
        mat = mat_token(o.mat_type, o.mat_index),
        matcat = o.material_category.whole,
        left = o.amount_left, total = o.amount_total,
        freq = df.workquota_frequency_type[o.frequency],
        fy = o.finished_year, fyt = o.finished_year_tick,
        workshop = o.workshop_id >= 0 and o.workshop_id or nil,
        max_ws = o.max_workshops,
        art = o.art_spec.type >= 0 and df.job_art_specifier_type[o.art_spec.type] or nil,
        iconds = {}, oconds = {},
    }
    if SIZED_JOBS[rec.job] and o.specdata.race >= 0
        and o.specdata.race < #df.global.world.raws.creatures.all then
        rec.race = df.global.world.raws.creatures.all[o.specdata.race].creature_id
    end
    for _, c in ipairs(o.item_conditions) do table.insert(rec.iconds, condition_out(c)) end
    for _, c in ipairs(o.order_conditions) do
        table.insert(rec.oconds, {order = c.order_id,
                                  cond = df.workquota_order_condition_type[c.condition],
                                  flags = c.flags.whole})
    end
    return rec
end

function save_phases(ctx)
    return {{
        name = 'manager orders',
        step = function(job)
            local out = {v = 1, list = {}}
            for _, o in ipairs(df.global.world.manager_orders.all) do
                local ok, rec = pcall(order_out, ctx, o)
                if ok then table.insert(out.list, rec)
                else common.add_skip(ctx, 'order-save-error', tostring(rec)) end
            end
            common.write_json(ctx.dir .. FILE, out)
            ctx.manifest.counts.orders = #out.list
            ctx.manifest.complete.orders = true
            print(('planeswalkers: %d manager order(s) saved'):format(#out.list))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function reaction_index(code)
    if not code then return -1 end
    for i, r in ipairs(df.global.world.raws.reactions.reactions) do
        if r.code == code then return i end
    end
    return -1
end

local function condition_in(ctx, rec)
    local c = df.manager_order_condition_item:new()
    c.compare_type = df.logic_condition_type[rec.cmp or 'AtLeast'] or 0
    c.compare_val = rec.val or 0
    c.item_type = rec.t and df.item_type[rec.t] or -1
    c.item_subtype = rec.t and rec.st and match.resolve_subtype(ctx, rec.t, rec.st) or -1
    local mi = rec.mat and match.resolve_mat_token(ctx, rec.mat)
    c.mat_type = mi and mi.type or -1
    c.mat_index = mi and mi.index or -1
    c.flags1.whole = rec.f1 or 0
    c.flags2.whole = rec.f2 or 0
    c.flags3.whole = rec.f3 or 0
    c.flags4 = rec.f4 or 0
    c.flags5 = rec.f5 or 0
    c.reaction_class = rec.rclass or ''
    c.has_material_reaction_product = rec.rprod or ''
    c.metal_ore = -1
    if rec.ore then
        local omi = dfhack.matinfo.find('INORGANIC:' .. rec.ore)
        if omi then c.metal_ore = omi.index end
    end
    c.min_dimension = rec.min_dim or -1
    c.reaction_id = reaction_index(rec.reaction)
    if c.reaction_id >= 0 then
        for _, i in ipairs(rec.contains or {}) do c.contains:insert('#', i) end
    end
    c.has_tool_use = rec.tool_use and df.tool_uses[rec.tool_use] or -1
    c.dye_color = -1
    if rec.dye then
        for i, col in ipairs(df.global.world.raws.descriptors.colors) do
            if col.id == rec.dye then c.dye_color = i break end
        end
    end
    return c
end

function load_phases(ctx)
    return {{
        name = 'manager orders',
        step = function(job)
            local data = common.read_json(ctx.dir .. FILE)
            if not data then return true end
            local handler = df.global.world.manager_orders
            local id_map, made = {}, {}
            for _, rec in ipairs(data.list or {}) do
                local jt = df.job_type[rec.job]
                if not jt then
                    common.add_skip(ctx, 'order-job-unknown', rec.job)
                else
                    local ok, err = pcall(function()
                        local o = df.manager_order:new()
                        o.id = handler.manager_order_next_id
                        handler.manager_order_next_id = o.id + 1
                        o.job_type = jt
                        o.item_type = rec.t and df.item_type[rec.t] or -1
                        o.item_subtype = rec.t and rec.st and match.resolve_subtype(ctx, rec.t, rec.st) or -1
                        o.reaction_name = rec.reaction or ''
                        local mi = rec.mat and match.resolve_mat_token(ctx, rec.mat)
                        o.mat_type = mi and mi.type or -1
                        o.mat_index = mi and mi.index or -1
                        o.material_category.whole = rec.matcat or 0
                        if rec.race then
                            local r = reqscript('internal/planeswalkers/units').resolve_race(ctx, rec.race)
                            if r then o.specdata.race = r end
                        end
                        o.art_spec.type = rec.art and df.job_art_specifier_type[rec.art] or -1
                        o.art_spec.id, o.art_spec.subid = -1, -1
                        o.amount_left = rec.left or 1
                        o.amount_total = rec.total or 1
                        o.status.whole = 0  -- DF re-validates on its next pass
                        o.frequency = df.workquota_frequency_type[rec.freq or 'OneTime'] or 0
                        o.finished_year = rec.fy or -1
                        o.finished_year_tick = rec.fyt or -1
                        o.workshop_id = -1
                        if rec.workshop then
                            local bld = ctx.bld_map and ctx.bld_map[rec.workshop]
                            if bld then o.workshop_id = bld.id
                            else common.add_skip(ctx, 'order-workshop-not-restored', rec.job) end
                        end
                        o.max_workshops = rec.max_ws or 0
                        for _, cr in ipairs(rec.iconds or {}) do
                            o.item_conditions:insert('#', condition_in(ctx, cr))
                        end
                        handler.all:insert('#', o)
                        id_map[rec.id] = o.id
                        table.insert(made, {o = o, rec = rec})
                    end)
                    if not ok then common.add_skip(ctx, 'order-restore-failed', tostring(err)) end
                end
            end
            -- order-on-order conditions refer to the new ids
            for _, m in ipairs(made) do
                for _, cr in ipairs(m.rec.oconds or {}) do
                    local target = id_map[cr.order]
                    if target then
                        local c = df.manager_order_condition_order:new()
                        c.order_id = target
                        c.condition = df.workquota_order_condition_type[cr.cond or 'Completed'] or 1
                        c.flags.whole = cr.flags or 0
                        m.o.order_conditions:insert('#', c)
                    else
                        common.add_skip(ctx, 'order-condition-target-missing', m.rec.job)
                    end
                end
            end
            ctx.orders_restored = #made
            print(('planeswalkers: %d manager order(s) restored'):format(#made))
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
