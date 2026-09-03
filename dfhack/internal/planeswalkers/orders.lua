-- Manager (work) orders for fort/planeswalkers, through DFHack's own `orders`
-- plugin: `orders export` writes the queue in its JSON format and `orders
-- import` rebuilds it, validating every field the way DF expects (a
-- hand-built order once SEGFAULTed the manager screen). The import refuses
-- the whole file at the first entry it cannot resolve, so the file is
-- filtered first: materials and subtypes this world lacks are swapped for
-- their closest local equivalent, and what cannot be swapped is dropped.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local match = reqscript('internal/planeswalkers/match')
local json = require('json')

local FILE = '/orders.json'
local TMP = 'planeswalkers_tmp'
local ORDERS_DIR = dfhack.getDFPath() .. '/dfhack-config/orders'

local function tmp_path() return ORDERS_DIR .. '/' .. TMP .. '.json' end

function save_phases(ctx)
    return {{
        name = 'manager orders',
        step = function(job)
            local n = 0
            local ok, err = pcall(function()
                dfhack.run_command_silent('orders', 'export', TMP)
                local data = json.decode_file(tmp_path())
                os.remove(tmp_path())
                common.write_json(ctx.dir .. FILE, data)
                n = #data
            end)
            if not ok then
                common.add_skip(ctx, 'orders-export-failed', tostring(err))
                common.write_json(ctx.dir .. FILE, {})
            end
            ctx.manifest.counts.orders = n
            ctx.manifest.complete.orders = true
            print(('planeswalkers: %d manager order(s) saved'):format(n))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function category_names(whole)
    local names = {}
    local bf = df.job_material_category:new()
    bf.whole = whole or 0
    for k, v in pairs(bf) do if v == true then table.insert(names, k) end end
    bf:delete()  -- our own scratch object, never DF's
    return names
end

-- a snapshot written by the earlier hand-rolled format -> plugin format
local function convert_legacy(data)
    local out = {}
    for _, r in ipairs(data.list or {}) do
        local o = {id = r.id, job = r.job, amount_left = r.left or 1, amount_total = r.total or 1,
                   frequency = r.freq or 'OneTime', is_validated = false, is_active = false}
        if r.t then o.item_type = r.t end
        if r.st then o.item_subtype = r.st end
        if r.mat then o.material = r.mat end
        if r.reaction then o.reaction = r.reaction end
        if r.matcat and r.matcat ~= 0 then o.material_category = category_names(r.matcat) end
        if r.workshop then o.workshop_id = r.workshop end
        if r.max_ws and r.max_ws > 0 then o.max_workshops = r.max_ws end
        if r.iconds and #r.iconds > 0 then
            o.item_conditions = {}
            for _, c in ipairs(r.iconds) do
                local cc = {condition = c.cmp or 'AtLeast', value = c.val or 0}
                if c.t then cc.item_type = c.t end
                if c.st then cc.item_subtype = c.st end
                if c.mat then cc.material = c.mat end
                table.insert(o.item_conditions, cc)
            end
        end
        if r.oconds and #r.oconds > 0 then
            o.order_conditions = {}
            for _, c in ipairs(r.oconds) do
                table.insert(o.order_conditions, {order = c.order, condition = c.cond or 'Completed'})
            end
        end
        table.insert(out, o)
    end
    return out
end

local function reaction_exists(code)
    for _, r in ipairs(df.global.world.raws.reactions.reactions) do
        if r.code == code then return true end
    end
    return false
end

-- make every entry acceptable to `orders import` in THIS world, or drop it
local function filter(ctx, list)
    local out, workshops = {}, {}
    for _, o in ipairs(list) do
        local keep = true
        local why
        local function fix_mat(tbl, key)
            if tbl[key] then
                local mi = match.resolve_mat_token(ctx, tbl[key])
                if mi then tbl[key] = mi:getToken() else keep = false why = 'material ' .. tbl[key] end
            end
        end
        local function fix_subtype(tbl)
            if tbl.item_subtype then
                local itype = tbl.item_type
                if not itype and df.job_type[o.job] then
                    local ok, it = pcall(function() return df.job_type.attrs[df.job_type[o.job]].item end)
                    itype = ok and it and it >= 0 and df.item_type[it] or nil
                end
                if itype then
                    local st = match.resolve_subtype(ctx, itype, tbl.item_subtype)
                    if st >= 0 then
                        local ok, def = pcall(dfhack.items.getSubtypeDef, df.item_type[itype], st)
                        if ok and def then tbl.item_subtype = def.id else keep = false why = 'subtype' end
                    else keep = false why = 'subtype ' .. tbl.item_subtype end
                end
            end
        end
        if not df.job_type[o.job] then keep, why = false, 'job ' .. tostring(o.job) end
        if keep and o.reaction and not reaction_exists(o.reaction) then keep, why = false, 'reaction ' .. o.reaction end
        if keep then fix_mat(o, 'material') end
        if keep then fix_subtype(o) end
        if keep then
            for _, c in ipairs(o.item_conditions or {}) do
                if keep then fix_mat(c, 'material') end
                if keep then fix_subtype(c) end
            end
        end
        if keep then
            o.hist_figure = nil                 -- a figure of the old world
            o.is_validated, o.is_active = false, false  -- DF re-checks
            if o.workshop_id then
                workshops[#out + 1] = o.workshop_id  -- 1-based index in the file -> old id
                o.workshop_id = nil
            end
            table.insert(out, o)
        else
            common.add_skip(ctx, 'order-dropped', (o.job or '?') .. ': ' .. tostring(why))
        end
    end
    return out, workshops
end

function load_phases(ctx)
    return {{
        name = 'manager orders',
        step = function(job)
            local data = common.read_json(ctx.dir .. FILE)
            if not data then return true end
            if data.list then data = convert_legacy(data) end
            local list, workshops = filter(ctx, data)
            if #list == 0 then
                print('planeswalkers: no manager order could be carried')
                return true
            end
            local all = df.global.world.manager_orders.all
            local before = #all
            dfhack.filesystem.mkdir_recursive(ORDERS_DIR)
            json.encode_file(list, tmp_path(), {pretty = false})
            local out = dfhack.run_command_silent('orders', 'import', TMP)
            os.remove(tmp_path())
            local made = #all - before
            if made < #list then
                common.add_skip(ctx, 'orders-import-refused', (out:match('[^\n]+') or ''):sub(1, 100))
            end
            -- workshop restrictions point at the restored workshops
            local relinked = 0
            for i = 1, made do
                local old = workshops[i]
                if old then
                    local bld = ctx.bld_map and ctx.bld_map[old]
                    local o = all[before + i - 1]
                    if bld and o then o.workshop_id = bld.id relinked = relinked + 1 end
                end
            end
            ctx.orders_restored = made
            print(('planeswalkers: %d of %d manager order(s) restored through the orders plugin, %d workshop restriction(s) relinked')
                :format(made, #list, relinked))
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
