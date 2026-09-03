-- The preset editor for fort/builder-burrow: three columns, as in the design.
--   1. actions and the settings of the selection
--   2. the passes: first pass districts and their blueprints, the second pass
--      (fill list) and the hallway blueprints when enabled
--   3. the blueprint library, filtered by what is being edited
-- User presets are saved to dfhack-config/scripts/data/builder-burrow/presets.json
-- and override shipped ones of the same name. Presets travel as JSON in the
-- same shape the browser sandbox copies out, so a preset built there pastes
-- straight in.
--@module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local json = require('json')

local presets = reqscript('internal/builder-burrow/presets')

USER_FILE = dfhack.getDFPath() .. '/dfhack-config/scripts/data/builder-burrow/presets.json'

-- ---------------------------------------------------------------------------
-- user presets on disk
-- ---------------------------------------------------------------------------

function load_user()
    local ok, data = pcall(json.decode_file, USER_FILE)
    if ok and type(data) == 'table' then return data end
    return {}
end

function save_user(tbl)
    local dir = USER_FILE:match('^(.*)/[^/]+$')
    dfhack.filesystem.mkdir_recursive(dir)
    json.encode_file(tbl, USER_FILE)
end

-- every preset by name, shipped first in their order, then the user's, sorted
function all_presets()
    local user = load_user()
    local out, order = {}, {}
    for _, name in ipairs(presets.PRESET_ORDER) do
        out[name] = presets.PRESETS[name]
        order[#order + 1] = name
    end
    local extra = {}
    for name, p in pairs(user) do
        if not out[name] then extra[#extra + 1] = name end
        out[name] = p
    end
    table.sort(extra)
    for _, name in ipairs(extra) do order[#order + 1] = name end
    return out, order
end

-- ---------------------------------------------------------------------------
-- blueprint library and room typing
-- ---------------------------------------------------------------------------

local function count(txt, ch)
    local n = 0
    for _ in txt:gmatch(ch:gsub('%p', '%%%0')) do n = n + 1 end
    return n
end

-- room type from the furniture a stamp would place; where it works from its walls
function typeOf(grid)
    local floors = grid.floors or {grid}
    local g = floors[1]
    local txt = ''
    for _, f in ipairs(floors) do txt = txt .. table.concat(f) end
    local types = {}
    if count(txt, 'b') > 0 then types[#types + 1] = 'bedroom' end
    if count(txt, 'x') > 0 then types[#types + 1] = 'tomb' end
    local tables, chairs = count(txt, 't'), count(txt, 'c')
    if chairs > 0 and tables <= 2 then types[#types + 1] = 'office' end
    if tables >= 3 then types[#types + 1] = 'dining room' end
    if count(txt, 'A') > 0 then types[#types + 1] = 'temple'
    elseif count(txt, 'P') > 0 or (#types == 0 and count(txt, 's') > 0) then types[#types + 1] = 'meeting area' end
    local constructed = count(txt, '#') > 0
    local where = constructed and 'surface' or (count(txt, 'd') > 0 and 'underground' or 'either')
    local t = #types == 0 and 'other' or (#types == 1 and types[1] or 'multi')
    return t, constructed, where
end

local TYPE_ORDER = {['bedroom'] = 0, ['office'] = 1, ['dining room'] = 2, ['tomb'] = 3, ['temple'] = 4,
                    ['meeting area'] = 5, ['multi'] = 6, ['other'] = 7, ['hallway'] = 8}

-- every stamp the shipped districts and presets know, plus any in user presets
function library()
    local seen, lib = {}, {}
    local function add(name, grid, kind)
        if not name or not grid or seen[name] then return end
        seen[name] = true
        local t, constructed, where = 'hallway', false, 'either'
        if kind == 'room' then t, constructed, where = typeOf(grid) end
        lib[#lib + 1] = {name = name, grid = grid, kind = kind, type = t, constructed = constructed, where = where}
    end
    local function addDistrict(d)
        for _, list in ipairs({d.stamps or {}, d.optional or {}}) do
            for _, sl in ipairs(list) do
                if sl.alts then for _, a in ipairs(sl.alts) do add(a.name or sl.name, a.grid, 'room') end
                else add(sl.name, sl.grid, 'room') end
            end
        end
    end
    for _, d in pairs(presets.DISTRICTS) do addDistrict(d) end
    for _, p in pairs(presets.PRESETS) do for _, r in ipairs(p.road or {}) do add(r.name, r.grid, 'road') end end
    for _, p in pairs(load_user()) do
        for _, list in ipairs({p.districts or {}, p.second or {}}) do
            for _, d in ipairs(list) do if d.stamps then addDistrict(d) end end
        end
        for _, r in ipairs(p.road or {}) do add(r.name, r.grid, 'road') end
    end
    table.sort(lib, function(p, q)
        if p.constructed ~= q.constructed then return not p.constructed end
        local tp, tq = TYPE_ORDER[p.type] or 9, TYPE_ORDER[q.type] or 9
        if tp ~= tq then return tp < tq end
        return p.name < q.name
    end)
    return lib
end

-- ---------------------------------------------------------------------------
-- the editable model: districts inline, every stamp a slot with alternatives
-- ---------------------------------------------------------------------------

local function clone(t) return json.decode(json.encode(t)) end

function toEditable(p, name)
    local function norm(d)
        local base = d.stamps and d or (presets.DISTRICTS[d.name] or {stamps = {}})
        local function sl(s)
            local alts = {}
            for _, a in ipairs(s.alts or {{grid = s.grid, name = s.name, weight = s.weight, setback = s.setback}}) do
                alts[#alts + 1] = {name = a.name or s.name, grid = a.grid, weight = a.weight or 1, setback = a.setback or 0}
            end
            return {name = s.name, weight = s.weight or 1, max = s.max, alts = alts}
        end
        local out = {name = d.name, weight = d.weight or 1,
                     margin = d.margin ~= nil and d.margin or (base.margin or 0),
                     set = base.set and true or false, shared = base.shared and true or false,
                     maxLen = base.maxLen or 14, depth = base.depth or 12, stamps = {}, optional = {}}
        for _, s in ipairs(base.stamps or {}) do out.stamps[#out.stamps + 1] = sl(s) end
        for _, s in ipairs(base.optional or {}) do out.optional[#out.optional + 1] = sl(s) end
        return out
    end
    local ed = {name = name or p.name or 'my preset', main = p.main or 3, side = p.side or 1,
                surface = p.surface and true or false, districts = {}, second = nil, road = nil}
    for _, d in ipairs(p.districts or {}) do ed.districts[#ed.districts + 1] = norm(d) end
    if p.second then
        ed.second = {}
        for _, d in ipairs(p.second) do ed.second[#ed.second + 1] = norm(d) end
    end
    if p.road then
        ed.road = {}
        for _, r in ipairs(p.road) do ed.road[#ed.road + 1] = {name = r.name, grid = r.grid, weight = r.weight or 1} end
    end
    return ed
end

function fromEditable(ed)
    local function out(d)
        local o = {name = d.name, weight = d.weight, margin = d.margin, set = d.set or nil, shared = d.shared or nil,
                   maxLen = d.maxLen, depth = d.depth, stamps = {}, optional = {}}
        for _, s in ipairs(d.stamps) do
            local alts = {}
            for _, a in ipairs(s.alts) do
                alts[#alts + 1] = {name = a.name, grid = a.grid, weight = a.weight, setback = a.setback,
                                   max = (not d.set) and s.max or nil}
            end
            o.stamps[#o.stamps + 1] = {name = s.name, weight = s.weight, max = (not d.set) and s.max or nil, alts = alts}
        end
        for _, s in ipairs(d.optional) do
            local alts = {}
            for _, a in ipairs(s.alts) do alts[#alts + 1] = {name = a.name, grid = a.grid, weight = a.weight, setback = a.setback} end
            o.optional[#o.optional + 1] = {name = s.name, max = s.max or 1, alts = alts}
        end
        return o
    end
    local p = {main = ed.main, side = ed.side, surface = ed.surface or nil, districts = {}}
    for _, d in ipairs(ed.districts) do p.districts[#p.districts + 1] = out(d) end
    if ed.second then
        p.second = {}
        for _, d in ipairs(ed.second) do p.second[#p.second + 1] = out(d) end
    end
    if ed.road and #ed.road > 0 then p.road = clone(ed.road) end
    return p
end

-- ---------------------------------------------------------------------------
-- the editor screen
-- ---------------------------------------------------------------------------

EditorWindow = defclass(EditorWindow, widgets.Window)
EditorWindow.ATTRS{
    frame_title = 'Preset editor',
    frame = {w = 118, h = 42},
    resizable = true,
    ed = DEFAULT_NIL,
    on_save = DEFAULT_NIL,
}

function EditorWindow:init()
    self.sel = {kind = 'pass', pass = 'districts'}
    self.lib = library()
    local L, M, R = 0, 32, 84
    self:addviews{
        -- column 1
        widgets.EditField{view_id = 'name', frame = {t = 0, l = L, w = 30}, key = 'CUSTOM_N', label_text = 'Name: ',
            text = self.ed.name, on_change = function(t) self.ed.name = t end},
        widgets.HotkeyLabel{frame = {t = 1, l = L}, key = 'CUSTOM_M', label = 'Main road width',
            on_activate = self:callback('prompt_number', 'main road width', function() return self.ed.main end, function(v) self.ed.main = math.max(1, math.min(5, v)) end)},
        widgets.HotkeyLabel{frame = {t = 2, l = L}, key = 'CUSTOM_I', label = 'Side road width',
            on_activate = self:callback('prompt_number', 'side road width', function() return self.ed.side end, function(v) self.ed.side = math.max(1, math.min(5, v)) end)},
        widgets.ToggleHotkeyLabel{view_id = 'surface', frame = {t = 3, l = L}, key = 'CUSTOM_U', label = 'Surface',
            initial_option = self.ed.surface, on_change = function(v) self.ed.surface = v; self:refresh() end},
        widgets.Label{view_id = 'widths', frame = {t = 4, l = L}, text = ''},
        widgets.HotkeyLabel{frame = {t = 6, l = L}, key = 'CUSTOM_P', label = 'Paste JSON', on_activate = self:callback('paste')},
        widgets.HotkeyLabel{frame = {t = 7, l = L}, key = 'CUSTOM_C', label = 'Copy JSON', on_activate = self:callback('copy')},
        widgets.HotkeyLabel{frame = {t = 9, l = L}, key = 'CUSTOM_D', label = 'Create district', on_activate = self:callback('add_district')},
        widgets.HotkeyLabel{view_id = 'addbp', frame = {t = 10, l = L}, key = 'CUSTOM_A', label = 'Add blueprint', on_activate = self:callback('add_blueprint')},
        widgets.HotkeyLabel{frame = {t = 11, l = L}, key = 'CUSTOM_X', label = 'Remove selected', on_activate = self:callback('remove')},
        widgets.HotkeyLabel{view_id = 'second', frame = {t = 13, l = L}, key = 'CUSTOM_S', label = 'Different second pass', on_activate = self:callback('toggle_second')},
        widgets.HotkeyLabel{view_id = 'road', frame = {t = 14, l = L}, key = 'CUSTOM_H', label = 'Add hallway blueprints', on_activate = self:callback('toggle_road')},
        widgets.Label{frame = {t = 16, l = L}, text = {{text = 'Settings of the selection', pen = COLOR_GREY}}},
        widgets.List{view_id = 'settings', frame = {t = 17, l = L, w = 30, h = 14}, on_submit = self:callback('edit_setting')},
        widgets.HotkeyLabel{frame = {t = 32, l = L}, key = 'CUSTOM_SHIFT_S', label = 'Save preset', on_activate = self:callback('save')},
        widgets.HotkeyLabel{frame = {t = 33, l = L}, key = 'LEAVESCREEN', label = 'Cancel', on_activate = function() self.parent_view:dismiss() end},
        widgets.Label{view_id = 'msg', frame = {t = 35, l = L, w = 116}, text = ''},
        -- column 2
        widgets.Label{frame = {t = 0, l = M}, text = {{text = 'Passes', pen = COLOR_GREY}}},
        widgets.List{view_id = 'rows', frame = {t = 1, l = M, w = 50, h = 33}, on_select = self:callback('select_row'), on_submit = self:callback('select_row')},
        -- column 3
        widgets.Label{view_id = 'libtitle', frame = {t = 0, l = R}, text = {{text = 'Blueprint library', pen = COLOR_GREY}}},
        widgets.List{view_id = 'lib', frame = {t = 1, l = R, w = 32, h = 33}, on_submit = self:callback('lib_submit')},
    }
    self:refresh()
end

function EditorWindow:say(text) self.subviews.msg:setText(text) end

function EditorWindow:prompt_number(title, get, set)
    dialogs.showInputPrompt(title, 'New value:', COLOR_WHITE, tostring(get()), function(t)
        local v = tonumber(t)
        if v then set(math.floor(v)); self:refresh() end
    end)
end

-- ---- selection and rows ---------------------------------------------------

local function passTitle(key)
    return key == 'districts' and 'First pass' or key == 'second' and 'Second pass (fill)' or 'Hallway blueprints'
end

function EditorWindow:build_rows()
    local rows = {}
    local ed = self.ed
    local function push(text, sel, pen) rows[#rows + 1] = {text = {{text = text, pen = pen}}, sel = sel} end
    local function pass(key)
        push('-- ' .. passTitle(key) .. ' --', {kind = 'pass', pass = key}, COLOR_YELLOW)
        if key == 'road' then
            if #(ed.road or {}) == 0 then push('    (none: select this line, pick a piece in the library)', {kind = 'pass', pass = key}, COLOR_GREY) end
            for i, r in ipairs(ed.road or {}) do push(('  %s  x%d'):format(r.name, r.weight), {kind = 'road', i = i}) end
            return
        end
        local list = ed[key]
        if #list == 0 then push('    (empty: pick a blueprint in the library, it gets its own district)', {kind = 'pass', pass = key}, COLOR_GREY) end
        for di, d in ipairs(list) do
            push(('  %s%s%s  weight %d  margin %d'):format(d.name, d.set and ' (suite)' or '', d.shared and ' (shared walls)' or '', d.weight, d.margin),
                 {kind = 'district', pass = key, di = di}, COLOR_WHITE)
            local function chip(s, si, optional, ai)
                local a = s.alts[ai]
                local tag = ''
                if ai == 1 then
                    if optional then tag = (' (0-%d)'):format(s.max or 1)
                    elseif not d.set and s.max then tag = (' (max %d)'):format(s.max) end
                end
                local sb = (a.setback or 0) > 0 and (' set back %d'):format(a.setback) or ''
                push(('    %s%s%s%s  x%d'):format(ai > 1 and '  alt: ' or (optional and '? ' or ''), a.name, tag, sb, a.weight),
                     {kind = 'slot', pass = key, di = di, si = si, optional = optional, ai = ai}, optional and COLOR_LIGHTCYAN or nil)
            end
            for si, s in ipairs(d.stamps) do for ai = 1, #s.alts do chip(s, si, false, ai) end end
            for si, s in ipairs(d.optional) do for ai = 1, #s.alts do chip(s, si, true, ai) end end
        end
    end
    pass('districts')
    if ed.second then pass('second') end
    if ed.road then pass('road') end
    return rows
end

local function selEq(a, b)
    if not a or not b or a.kind ~= b.kind then return false end
    for _, k in ipairs({'pass', 'di', 'si', 'ai', 'optional', 'i'}) do if a[k] ~= b[k] then return false end end
    return true
end

function EditorWindow:refresh()
    local rows = self:build_rows()
    local idx = 1
    for i, r in ipairs(rows) do if selEq(r.sel, self.sel) then idx = i break end end
    self.subviews.rows:setChoices(rows, idx)
    self.subviews.widths:setText(('main %d, side %d'):format(self.ed.main, self.ed.side))
    self.subviews.second:setLabel(self.ed.second and 'Same second pass' or 'Different second pass')
    self.subviews.road:setLabel(self.ed.road and 'Remove hallway blueprints' or 'Add hallway blueprints')
    local k = self.sel.kind
    self.subviews.addbp:setLabel(self:in_road() and 'Add hallway piece' or (k == 'pass' and 'Add blueprint (new district)')
        or (k == 'slot' and 'Add blueprint as alt' or 'Add blueprint to district'))
    self:refresh_lib()
    self:refresh_settings()
end

function EditorWindow:select_row(_, choice)
    if not choice then return end
    if not selEq(choice.sel, self.sel) then
        self.sel = choice.sel
        self:refresh()
    end
end

function EditorWindow:in_road()
    return self.sel.kind == 'road' or (self.sel.kind == 'pass' and self.sel.pass == 'road')
end

-- ---- library ---------------------------------------------------------------

function EditorWindow:refresh_lib()
    local road = self:in_road()
    local here = self.ed.surface and 'surface' or 'underground'
    local choices, lastGroup, divider = {}, nil, false
    local items, rest = {}, {}
    for _, it in ipairs(self.lib) do
        if (it.kind == 'road') == road then
            if road or it.where == 'either' or it.where == here then items[#items + 1] = it else rest[#rest + 1] = it end
        end
    end
    for _, it in ipairs(rest) do items[#items + 1] = it end
    for i, it in ipairs(items) do
        local fits = road or it.where == 'either' or it.where == here
        if not fits and not divider then
            divider = true
            choices[#choices + 1] = {text = {{text = self.ed.surface and '-- built for underground --' or '-- built for the surface --', pen = COLOR_RED}}, item = nil}
        end
        local group = (it.constructed and 'surface ' or '') .. it.type
        if group ~= lastGroup then
            lastGroup = group
            choices[#choices + 1] = {text = {{text = group, pen = COLOR_GREY}}, item = nil}
        end
        local g = it.grid.floors and it.grid.floors[1] or it.grid
        choices[#choices + 1] = {text = ('  %s %dx%d%s'):format(it.name, #g[1], #g, it.grid.floors and (' x' .. #it.grid.floors .. 'z') or ''), item = it}
    end
    self.subviews.lib:setChoices(choices)
    self.subviews.libtitle:setText({{text = road and 'Hallway pieces (Enter adds)' or 'Blueprint library (Enter adds)', pen = COLOR_GREY}})
end

function EditorWindow:lib_submit(_, choice)
    if choice and choice.item then self:add_blueprint(choice.item) end
end

-- ---- settings ----------------------------------------------------------------

function EditorWindow:district()
    local s = self.sel
    if s.kind == 'district' or s.kind == 'slot' then return self.ed[s.pass][s.di] end
end

function EditorWindow:refresh_settings()
    local s, rows = self.sel, {}
    local function row(label, value, apply, hint)
        rows[#rows + 1] = {text = ('%s: %s'):format(label, tostring(value)), apply = apply, label = label, value = value, hint = hint}
    end
    if s.kind == 'pass' then
        rows[#rows + 1] = {text = passTitle(s.pass) .. ' selected'}
        rows[#rows + 1] = {text = '"Create district" adds here;'}
        rows[#rows + 1] = {text = 'a library pick adds in a new district'}
    elseif s.kind == 'road' then
        local r = self.ed.road[s.i]
        rows[#rows + 1] = {text = r.name}
        row('weight', r.weight, function(v) r.weight = v end)
        rows[#rows + 1] = {text = 'remove this piece', apply = function() table.remove(self.ed.road, s.i); self.sel = {kind = 'pass', pass = 'road'} end}
    elseif s.kind == 'district' then
        local d = self:district()
        rows[#rows + 1] = {text = 'district', apply = function()
            dialogs.showInputPrompt('district name', 'Name:', COLOR_WHITE, d.name, function(t) d.name = t; self:refresh() end) end, value = d.name}
        row('weight', d.weight, function(v) d.weight = v end)
        row('margin', d.margin, function(v) d.margin = v end, 'extra rock between neighbours; 0 = one shared wall')
        row('max length', d.maxLen, function(v) d.maxLen = v end)
        row('depth', d.depth, function(v) d.depth = v end)
        row('suite', d.set, function() d.set = not d.set end, 'first blueprint is the hub with the road door')
        if self.ed.surface then row('shared walls', d.shared, function() d.shared = not d.shared end, 'built walls overlap the neighbour') end
        rows[#rows + 1] = {text = 'remove this district', apply = function() table.remove(self.ed[s.pass], s.di); self.sel = {kind = 'pass', pass = s.pass} end}
    elseif s.kind == 'slot' then
        local d = self:district()
        local list = s.optional and d.optional or d.stamps
        local sl = list[s.si]
        local a = sl.alts[s.ai]
        rows[#rows + 1] = {text = a.name .. (s.optional and ' (optional)' or (d.set and (s.si == 1 and ' (hub)' or ' (required)') or ''))}
        row('weight', a.weight, function(v) a.weight = v end)
        if self.ed.surface then row('setback', a.setback, function(v) a.setback = v end) end
        if not d.set then row('max per district', sl.max or 0, function(v) sl.max = v > 0 and v or nil end, '0 = unlimited') end
        if d.set and (s.si > 1 or s.optional) then
            if not s.optional then
                rows[#rows + 1] = {text = 'optional: no', apply = function()
                    local moved = table.remove(d.stamps, s.si); moved.max = moved.max or 1
                    d.optional[#d.optional + 1] = moved
                    self.sel = {kind = 'slot', pass = s.pass, di = s.di, si = #d.optional, optional = true, ai = 1} end}
            else
                row('optional max', sl.max or 1, function(v)
                    if v <= 0 then
                        local moved = table.remove(d.optional, s.si)
                        d.stamps[#d.stamps + 1] = moved
                        self.sel = {kind = 'slot', pass = s.pass, di = s.di, si = #d.stamps, optional = false, ai = 1}
                    else sl.max = v end
                end, '0 makes it required again')
            end
        end
        rows[#rows + 1] = {text = #sl.alts > 1 and 'remove this alternative' or 'remove this blueprint', apply = function()
            if #sl.alts > 1 then table.remove(sl.alts, s.ai) else table.remove(list, s.si) end
            self.sel = {kind = 'district', pass = s.pass, di = s.di} end}
    end
    self.subviews.settings:setChoices(rows)
end

function EditorWindow:edit_setting(_, choice)
    if not choice or not choice.apply then return end
    if type(choice.value) == 'number' then
        dialogs.showInputPrompt(choice.label, (choice.hint or '') .. '\nNew value:', COLOR_WHITE, tostring(choice.value), function(t)
            local v = tonumber(t)
            if v then choice.apply(math.floor(v)); self:refresh() end
        end)
    else
        choice.apply()
        self:refresh()
    end
end

-- ---- actions -----------------------------------------------------------------

function EditorWindow:new_district(pass)
    local list = self.ed[pass]
    list[#list + 1] = {name = 'district ' .. (#list + 1), weight = 1, margin = 0, set = false, shared = false,
                       maxLen = 14, depth = 12, stamps = {}, optional = {}}
    return #list
end

function EditorWindow:add_district()
    local pass = (self.sel.pass == 'second') and 'second' or 'districts'
    local di = self:new_district(pass)
    self.sel = {kind = 'district', pass = pass, di = di}
    self:refresh()
end

function EditorWindow:add_blueprint(item)
    if not item then
        local _, choice = self.subviews.lib:getSelected()
        item = choice and choice.item
    end
    if not item then self:say('pick a blueprint in the library first') return end
    local entry = {name = item.name, grid = item.grid, weight = 1, setback = 0}
    local s = self.sel
    if self:in_road() then
        if item.kind ~= 'road' then self:say('that is a room; the hallway list takes hallway pieces') return end
        self.ed.road = self.ed.road or {}
        local dup = false
        for _, r in ipairs(self.ed.road) do if r.name == item.name then dup = true end end
        if not dup then self.ed.road[#self.ed.road + 1] = {name = item.name, grid = item.grid, weight = 1} end
        self.sel = {kind = 'pass', pass = 'road'}
    elseif item.kind == 'road' then
        self:say('that is a hallway piece; select the hallway section to add it')
        return
    elseif s.kind == 'pass' then
        local pass = s.pass == 'second' and 'second' or 'districts'
        local di = self:new_district(pass)
        local d = self.ed[pass][di]
        d.name = item.name
        d.stamps[1] = {name = item.name, weight = 1, alts = {entry}}
        self.sel = {kind = 'district', pass = pass, di = di}
    elseif s.kind == 'district' then
        local d = self:district()
        d.stamps[#d.stamps + 1] = {name = item.name, weight = 1, alts = {entry}}
    elseif s.kind == 'slot' then
        local d = self:district()
        local sl = (s.optional and d.optional or d.stamps)[s.si]
        sl.alts[#sl.alts + 1] = entry
    end
    self:refresh()
end

function EditorWindow:remove()
    local s = self.sel
    if s.kind == 'pass' then return end
    if s.kind == 'road' then table.remove(self.ed.road, s.i); self.sel = {kind = 'pass', pass = 'road'}
    elseif s.kind == 'district' then table.remove(self.ed[s.pass], s.di); self.sel = {kind = 'pass', pass = s.pass}
    else
        local d = self:district()
        local list = s.optional and d.optional or d.stamps
        local sl = list[s.si]
        if #sl.alts > 1 then table.remove(sl.alts, s.ai) else table.remove(list, s.si) end
        self.sel = {kind = 'district', pass = s.pass, di = s.di}
    end
    self:refresh()
end

function EditorWindow:toggle_second()
    if self.ed.second then self.ed.second = nil; self.sel = {kind = 'pass', pass = 'districts'}
    else self.ed.second = clone(self.ed.districts); self.sel = {kind = 'pass', pass = 'second'} end
    self:refresh()
end

function EditorWindow:toggle_road()
    if self.ed.road then self.ed.road = nil; self.sel = {kind = 'pass', pass = 'districts'}
    else self.ed.road = {}; self.sel = {kind = 'pass', pass = 'road'} end
    self:refresh()
end

function EditorWindow:paste()
    local ok, text = pcall(dfhack.internal.getClipboardTextCp437)
    if not ok or not text or text == '' then self:say('the clipboard is empty') return end
    local ok2, p = pcall(json.decode, dfhack.df2utf(text))
    if not ok2 or type(p) ~= 'table' or not p.districts then self:say('the clipboard does not hold preset JSON') return end
    local name = self.ed.name
    self.ed = toEditable(p, p.name or name)
    self.subviews.name:setText(self.ed.name)
    self.subviews.surface:setOption(self.ed.surface)
    self.lib = library()
    self.sel = {kind = 'pass', pass = 'districts'}
    self:refresh()
    self:say('preset pasted')
end

function EditorWindow:copy()
    local p = fromEditable(self.ed)
    p.name = self.ed.name
    local text = json.encode(p)
    local ok = pcall(dfhack.internal.setClipboardTextCp437, dfhack.utf2df(text))
    self:say(ok and 'preset JSON copied to the clipboard' or 'the clipboard is not available here')
end

function EditorWindow:save()
    local name = self.subviews.name.text
    if not name or name == '' then self:say('give the preset a name') return end
    self.ed.name = name
    if #self.ed.districts == 0 then self:say('a preset needs at least one district') return end
    local user = load_user()
    user[name] = fromEditable(self.ed)
    save_user(user)
    if self.on_save then self.on_save(name) end
    self.parent_view:dismiss()
end

EditorScreen = defclass(EditorScreen, gui.ZScreen)
EditorScreen.ATTRS{focus_path = 'builder-burrow/editor', ed = DEFAULT_NIL, on_save = DEFAULT_NIL}
function EditorScreen:init() self:addviews{EditorWindow{ed = self.ed, on_save = self.on_save}} end

-- open the editor on a copy of `preset` (or a new one)
function open(preset, name, on_save)
    local ed = preset and toEditable(preset, name) or {name = 'my preset', main = 3, side = 1, surface = false, districts = {}, second = nil, road = nil}
    return EditorScreen{ed = ed, on_save = on_save}:show()
end

return {open = open, all_presets = all_presets, library = library, typeOf = typeOf,
        toEditable = toEditable, fromEditable = fromEditable, load_user = load_user, save_user = save_user}
