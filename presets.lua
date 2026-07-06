-- Save/load named presets of military uniform templates and stockpile settings.
--@module = false
--[[
presets
=======

Save and reload your setups as named presets:

  * MILITARY UNIFORMS -- all of the fort's uniform templates (the "Steel - axe",
    "Melee", etc. entries on the military Uniforms screen), stored as an editable
    JSON file under dfhack-config/uniform-presets/. Item subtypes are stored by
    NAME and materials by TOKEN, so a preset re-resolves correctly even in a
    different fort/world (falling back to raw indices if a name/token is gone).

  * STOCKPILE SETTINGS -- delegates to DFHack's own `stockpiles` plugin (saved
    under dfhack-config/stockpiles/), so these presets interop with gui/stockpiles
    and the stockpile screen's import/export buttons.

Usage:

    presets save uniforms <name>        save all fort uniform templates
    presets load uniforms <name>        add them to this fort (skips ones whose
                                        name already exists unless --overwrite)
    presets load uniforms <name> --overwrite   replace same-named uniforms
    presets list uniforms               list saved uniform presets

    presets save stockpile <name>       save the SELECTED stockpile's settings
    presets load stockpile <name>       load settings into the SELECTED stockpile
    presets list stockpile              list saved stockpile presets

Notes:
  * "save stockpile"/"load stockpile" need a stockpile selected on the map.
  * Loading uniforms never deletes; it only adds (or, with --overwrite, replaces a
    same-named template). Delete unwanted templates on the Uniforms screen.
]]

local json = require('json')
local stockpiles = require('plugins.stockpiles')

if not dfhack.world.isFortressMode() then
    qerror('presets: load a fort first (fortress mode only)')
end

local UNIFORM_DIR = dfhack.getDFPath() .. '/dfhack-config/uniform-presets'
local IT = df.item_type

-- uniform item_type -> the itemdefs vector that names its subtypes
local ITEMDEF_VEC = {
    [IT.WEAPON] = 'weapons', [IT.ARMOR] = 'armor', [IT.HELM] = 'helms',
    [IT.PANTS] = 'pants', [IT.GLOVES] = 'gloves', [IT.SHOES] = 'shoes',
    [IT.SHIELD] = 'shields', [IT.AMMO] = 'ammo', [IT.TRAPCOMP] = 'trapcomps',
    [IT.TOOL] = 'tools', [IT.INSTRUMENT] = 'instruments',
    [IT.SIEGEAMMO] = 'siege_ammo', [IT.TOY] = 'toys',
}

local function fort_entity()
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then return e end
    end
end

-- ---- name/token <-> index helpers (portable across worlds) ------------------

local function subtype_name(item_type, idx)
    if not idx or idx < 0 then return nil end   -- -1 = unspecified subtype
    local vec = ITEMDEF_VEC[item_type]
    if not vec then return nil end
    local dv = df.global.world.raws.itemdefs[vec]
    if idx >= #dv then return nil end
    local d = dv[idx]
    return d and d.name or nil
end

local function subtype_idx(item_type, name, fallback)
    local vec = ITEMDEF_VEC[item_type]
    if vec and name then
        local v = df.global.world.raws.itemdefs[vec]
        for i = 0, #v - 1 do if v[i].name == name then return i end end
    end
    return fallback   -- name gone (or unknown type): use the stored raw index
end

-- ---- (de)serialize one uniform ----------------------------------------------

local function serialize_uniform(u)
    local slots = {}
    for slot = 0, 6 do
        local types = u.uniform_item_types[slot]
        local subs = u.uniform_item_subtypes[slot]
        local infos = u.uniform_item_info[slot]
        local items = {}
        for i = 0, #types - 1 do
            local it = types[i]
            local info = infos[i]
            local mi = dfhack.matinfo.decode(info.mattype, info.matindex)
            items[#items + 1] = {
                item_type = df.item_type[it] or it,
                subtype_idx = subs[i],
                subtype_name = subtype_name(it, subs[i]),
                mat_token = mi and mi:getToken() or nil,
                mattype = info.mattype, matindex = info.matindex,
                armorlevel = info.armorlevel, item_color = info.item_color,
            }
        end
        if #items > 0 then slots[tostring(slot)] = items end
    end
    return {name = u.name, type = u.type, flags_whole = u.flags.whole, slots = slots}
end

local function make_info(mattype, matindex, armorlevel, item_color)
    local info = df.entity_uniform_item:new()
    info.mattype, info.matindex, info.material_class = mattype, matindex, -1
    info.item_color = item_color or -1
    info.armorlevel = armorlevel or -1
    info.maker_race = -1
    info.art_image_id, info.art_image_subid = -1, -1
    info.image_thread_color, info.image_material_class = -1, -1
    info.random_dye = 0
    return info
end

local function resolve_entry(entry)
    local it = entry.item_type
    if type(it) == 'string' then it = df.item_type[it] end
    local sub = subtype_idx(it, entry.subtype_name, entry.subtype_idx)
    local mattype, matindex = entry.mattype, entry.matindex
    if entry.mat_token then
        local mi = dfhack.matinfo.find(entry.mat_token)
        if mi then mattype, matindex = mi.type, mi.index end
    end
    return it, sub, mattype, matindex
end

local function build_uniform(ent, su)
    local u = df.entity_uniform:new()
    u.id = ent.next_uniform_id
    u.name = su.name
    u.type = su.type or 0
    u.flags.whole = su.flags_whole or 0
    for slotstr, items in pairs(su.slots or {}) do
        local slot = tonumber(slotstr)
        for _, entry in ipairs(items) do
            local it, sub, mattype, matindex = resolve_entry(entry)
            if it and sub then
                u.uniform_item_types[slot]:insert('#', it)
                u.uniform_item_subtypes[slot]:insert('#', sub)
                u.uniform_item_info[slot]:insert('#', make_info(mattype, matindex, entry.armorlevel, entry.item_color))
            end
        end
    end
    ent.uniforms:insert('#', u)
    ent.next_uniform_id = ent.next_uniform_id + 1
end

-- ---- file helpers -----------------------------------------------------------

local function uniform_path(name) return UNIFORM_DIR .. '/' .. name .. '.json' end

local function assert_name(name)
    if not name or #name == 0 then qerror('please give a preset name') end
    if name:find('[^%w._-]') then qerror('name may only contain letters, numbers, . _ -') end
end

-- ---- uniform commands -------------------------------------------------------

local function save_uniforms(name)
    assert_name(name)
    local ent = fort_entity()
    if not ent then qerror('could not find the fort entity') end
    local out = {version = 1, uniforms = {}}
    for i = 0, #ent.uniforms - 1 do
        out.uniforms[#out.uniforms + 1] = serialize_uniform(ent.uniforms[i])
    end
    dfhack.filesystem.mkdir_recursive(UNIFORM_DIR)
    local path = uniform_path(name)
    local f = io.open(path, 'w')
    if not f then qerror('cannot write ' .. path) end
    f:write(json.encode(out))
    f:close()
    print(('presets: saved %d uniform template(s) to %s'):format(#out.uniforms, path))
end

local function load_uniforms(name, overwrite)
    assert_name(name)
    local ent = fort_entity()
    if not ent then qerror('could not find the fort entity') end
    local path = uniform_path(name)
    local f = io.open(path, 'r')
    if not f then qerror('no such uniform preset: ' .. path) end
    local data = json.decode(f:read('*a'))
    f:close()

    -- index existing uniforms by name (for skip / overwrite)
    local existing = {}
    for i = 0, #ent.uniforms - 1 do existing[ent.uniforms[i].name] = i end

    -- overwrite = delete same-named first (iterate high->low so indices stay valid)
    if overwrite then
        for i = #ent.uniforms - 1, 0, -1 do
            for _, su in ipairs(data.uniforms or {}) do
                if ent.uniforms[i].name == su.name then
                    ent.uniforms:erase(i)
                    break
                end
            end
        end
        existing = {}
        for i = 0, #ent.uniforms - 1 do existing[ent.uniforms[i].name] = i end
    end

    local added, skipped = 0, 0
    for _, su in ipairs(data.uniforms or {}) do
        if existing[su.name] then
            print('  skip (already exists): ' .. su.name)
            skipped = skipped + 1
        else
            build_uniform(ent, su)
            added = added + 1
        end
    end
    print(('presets: loaded %d uniform(s)%s from %s'):format(
        added, skipped > 0 and (' (' .. skipped .. ' skipped)') or '', path))
end

local function list_uniforms()
    local files = dfhack.filesystem.listdir(UNIFORM_DIR) or {}
    local names = {}
    for _, fn in ipairs(files) do
        local base = fn:match('^(.+)%.json$')
        if base then names[#names + 1] = base end
    end
    table.sort(names)
    if #names == 0 then
        print('presets: no uniform presets saved yet (' .. UNIFORM_DIR .. ')')
    else
        print('Saved uniform presets:')
        for _, n in ipairs(names) do print('  ' .. n) end
    end
end

-- ---- stockpile commands (delegate to the stockpiles plugin) -----------------

local function save_stockpile(name)
    assert_name(name)
    local sp = dfhack.gui.getSelectedStockpile(true)
    if not sp then qerror('select a stockpile on the map first') end
    stockpiles.export_settings(name, {id = sp.id})
    print('presets: saved selected stockpile settings as "' .. name .. '"')
end

local function load_stockpile(name)
    assert_name(name)
    local sp = dfhack.gui.getSelectedStockpile(true)
    if not sp then qerror('select a stockpile on the map first') end
    stockpiles.import_settings(name, {id = sp.id})
    print('presets: loaded stockpile settings "' .. name .. '" into the selected stockpile')
end

local function list_stockpile()
    dfhack.run_command('stockpiles', 'list')
end

-- ---- dispatch ---------------------------------------------------------------

local args = {...}
local verb, kind = args[1], args[2]
local rest = {}
for i = 3, #args do rest[#rest + 1] = args[i] end
local overwrite = false
local name
for _, a in ipairs(rest) do
    if a == '--overwrite' then overwrite = true else name = name or a end
end

local DISPATCH = {
    ['save uniforms'] = function() save_uniforms(name) end,
    ['load uniforms'] = function() load_uniforms(name, overwrite) end,
    ['list uniforms'] = list_uniforms,
    ['save stockpile'] = function() save_stockpile(name) end,
    ['load stockpile'] = function() load_stockpile(name) end,
    ['list stockpile'] = list_stockpile,
    ['list stockpiles'] = list_stockpile,
}

local fn = DISPATCH[(verb or '') .. ' ' .. (kind or '')]
if not fn then
    print('Usage:')
    print('  presets save|load|list uniforms  [<name>] [--overwrite]')
    print('  presets save|load|list stockpile [<name>]')
    return
end
fn()
