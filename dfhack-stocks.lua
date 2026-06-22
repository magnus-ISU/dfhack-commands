-- Searchable/filterable stocks menu for designating items (replaces vanilla Stocks).
--@module = true
--[[
A searchable list of fort items for quickly marking gear to melt (or forbid /
dump), with origin / exotic / rarity filters so foreign loot and high-quality
pieces are easy to find.

    dfhack-stocks            open the menu

Or just click the vanilla Stocks button on the bottom toolbar -- this script
replaces that screen with the menu (press Esc to dismiss it back to play).

Menu:
  * Search field is focused on open; the most recent artifact is selected.
  * Action (top, next to Search): view / melt / forbid / dump. Defaults to view
    (view opens the item's sheet); melt only lists metal meltable items, so the
    non-meltable most-recent artifact can lead only under a non-melt action.
  * Filters: origin (all/foreign/local), exotic (all/only/not), and a rarity
    range slider (Ordinary .. Artifact).
  * Rows show melt/forbid/dump flags, quality, value and the detailed
    description, sorted by origin, then quality, then item type.
  * Click a row once to select it (full description at the bottom); click it
    again, double-click, or shift-click to apply the current action. Shift-click
    applies to a range; "Apply to all visible" applies to everything shown.
  * The panel on the right counts the items currently marked for melting, by
    type. The bottom shows the selected item's full description + value.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

-- ---- item model -----------------------------------------------------------

-- what the fort civ can produce: per-item-type subtype sets + its metals
local function civ_production()
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then ent = e; break end
    end
    local p = {subtypes = {}, metals = {}}
    if not ent then return p end
    local r = ent.resources
    local function setof(vec) local s = {}; for _, v in ipairs(vec) do s[v] = true end; return s end
    -- weapons the civ can forge include its diggers (picks)
    local wset = setof(r.weapon_type)
    for _, v in ipairs(r.digger_type) do wset[v] = true end
    p.subtypes = {
        [df.item_type.WEAPON]   = wset,
        [df.item_type.ARMOR]    = setof(r.armor_type),
        [df.item_type.HELM]     = setof(r.helm_type),
        [df.item_type.SHIELD]   = setof(r.shield_type),
        [df.item_type.PANTS]    = setof(r.pants_type),
        [df.item_type.GLOVES]   = setof(r.gloves_type),
        [df.item_type.SHOES]    = setof(r.shoes_type),
        [df.item_type.AMMO]     = setof(r.ammo_type),
        [df.item_type.TOOL]     = setof(r.tool_type),
        [df.item_type.TRAPCOMP] = setof(r.trapcomp_type),
    }
    for _, mi in ipairs(r.metals) do p.metals[mi] = true end
    return p
end

-- can a metal of this item's material be forged into this item class? (e.g. a
-- platinum war hammer can't be: platinum lacks ITEMS_WEAPON). Only gates the
-- classes with a clear single material flag; others pass.
local function material_can_make(item)
    if item.mat_type ~= 0 then return true end          -- non-metal: not gated here
    local ir = df.inorganic_raw.find(item.mat_index)
    if not ir then return true end
    local f = ir.material.flags
    local t = item:getType()
    if t == df.item_type.WEAPON then
        return f.ITEMS_WEAPON or f.ITEMS_WEAPON_RANGED or f.ITEMS_DIGGER
    elseif t == df.item_type.AMMO then
        return f.ITEMS_AMMO
    elseif t == df.item_type.ARMOR or t == df.item_type.HELM or t == df.item_type.PANTS
        or t == df.item_type.GLOVES or t == df.item_type.SHOES then
        return f.ITEMS_ARMOR
    end
    return true
end

-- exotic = the fort's civilization cannot produce this item (so only an enemy
-- or an artifact could have made it): a subtype it doesn't forge (flail, great
-- pick), a material it can't forge into that item (platinum hammer), or a metal
-- the civ doesn't even use.
local function is_exotic(item, prod)
    if item.mat_type == 0 and not prod.metals[item.mat_index] then return true end
    local set = prod.subtypes[item:getType()]
    if set and not set[item:getSubtype()] then return true end
    if not material_can_make(item) then return true end
    return false
end

-- ---- quality / type helpers -----------------------------------------------

-- short tag + pen + full name, indexed by quality rank 0..6 (6 = artifact)
local QUALITY = {
    [0] = {tag = 'ord',  name = 'Ordinary',     pen = COLOR_GRAY},
    [1] = {tag = 'well', name = 'Well-crafted',  pen = COLOR_WHITE},
    [2] = {tag = 'fine', name = 'Finely-crafted',pen = COLOR_CYAN},
    [3] = {tag = 'sup',  name = 'Superior',      pen = COLOR_LIGHTBLUE},
    [4] = {tag = 'exc',  name = 'Exceptional',   pen = COLOR_GREEN},
    [5] = {tag = 'mast', name = 'Masterful',     pen = COLOR_YELLOW},
    [6] = {tag = 'ART',  name = 'Artifact',      pen = COLOR_LIGHTMAGENTA},
}

-- the set of item ids that are artifacts, plus the most-recent artifact's item
-- id, read from the authoritative artifact list (newest = last entry). Some
-- artifacts (slabs, engravings) have no movable item, so skip those.
local function artifact_info()
    local ids, recent = {}, nil
    for _, a in ipairs(df.global.world.artifacts.all) do
        if a.item and a.item.id >= 0 then
            ids[a.item.id] = true
            recent = a.item.id
        end
    end
    return ids, recent
end

local function quality_rank(item, art_ids)
    if art_ids[item.id] then return 6 end       -- artifacts outrank Masterful
    return item:getQuality()
end

-- readable item-type name for grouping/sorting, e.g. "battle axe", "mail shirt"
local function type_name(item)
    local ok, def = pcall(dfhack.items.getSubtypeDef, item:getType(), item:getSubtype())
    if ok and def and def.name and def.name ~= '' then return def.name end
    local tn = df.item_type[item:getType()]
    return tn and tn:lower():gsub('_', ' ') or 'item'
end

-- one-letter status flags for the row, e.g. "M.D" (melt, dump)
local function flag_tag(item)
    local f = item.flags
    return ('%s%s%s'):format(f.melt and 'M' or '.', f.forbid and 'F' or '.', f.dump and 'D' or '.')
end

local function comma(n)
    local out = tostring(math.floor(n or 0)):reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- focus the game's item sheet on this item (mirrors statue-redirect). The
-- viewing_itid vector must be cleared first, or a stale id keeps the old sheet.
local function focus_item(item)
    local vs = df.global.game.main_interface.view_sheets
    vs.viewing_itid:resize(0)
    vs.viewing_itid:insert('#', item.id)
    vs.active_sheet = df.view_sheet_type.ITEM
    vs.active_id = item.id
    vs.open = true
    -- center the map on the item too, so the focus is unmistakable
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if ok and x then pcall(dfhack.gui.revealInDwarfmodeMap, xyz2pos(x, y, z), true, true) end
end

-- ---- window ---------------------------------------------------------------

StocksWindow = defclass(StocksWindow, widgets.Window)
StocksWindow.ATTRS{
    frame_title = 'DFHack stocks',
    frame = {w = 114, h = 48},
    resizable = true,
    resize_min = {w = 86, h = 32},
}

function StocksWindow:init()
    -- size to (nearly) fill the screen, capped, so it's as large as it can be
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame = {w = math.max(90, math.min(160, sw - 30)),  -- leave room for the minimap
                  h = math.max(34, math.min(70, sh - 4))}

    self.prod = civ_production()
    self.armed_id = nil     -- row whose next click will apply the action
    self.anchor_id = nil    -- range anchor for shift-click

    local rarity_opts = {}
    for i = 0, 6 do rarity_opts[i + 1] = {label = QUALITY[i].name, value = i} end

    self:addviews{
        widgets.EditField{
            view_id = 'search',
            frame = {t = 0, l = 0, w = 46},
            label_text = 'Search: ',
        },
        widgets.CycleHotkeyLabel{
            view_id = 'action',
            frame = {t = 0, l = 48, w = 22},
            label = 'Action:',
            -- default to view so the (non-meltable) most-recent artifact is in
            -- the list on open; melt restricts to metal items, so it can't lead
            initial_option = 'view',
            options = {
                {label = 'view', value = 'view', pen = COLOR_LIGHTCYAN},
                {label = 'melt', value = 'melt', pen = COLOR_LIGHTRED},
                {label = 'forbid', value = 'forbid', pen = COLOR_YELLOW},
                {label = 'dump', value = 'dump', pen = COLOR_LIGHTMAGENTA},
            },
            on_change = function() self:refresh() end,
        },
        widgets.Label{
            view_id = 'totals',
            frame = {t = 0, l = 72, r = 0},
        },
        widgets.Label{
            frame = {t = 2, l = 0},
            text = {{text = 'Filters:', pen = COLOR_LIGHTCYAN}},
        },
        widgets.TextButton{
            view_id = 'apply_all',
            frame = {t = 2, r = 0, w = 24, h = 1},
            label = 'Apply to all visible',
            on_activate = self:callback('apply_all_visible'),
        },
        widgets.CycleHotkeyLabel{
            view_id = 'origin',
            frame = {t = 3, l = 2, w = 20},
            label = 'Origin:',
            options = {
                {label = 'all', value = 'all', pen = COLOR_GRAY},
                {label = 'foreign', value = 'foreign', pen = COLOR_YELLOW},
                {label = 'local', value = 'local', pen = COLOR_GREEN},
            },
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'exotic',
            frame = {t = 3, l = 24, w = 20},
            label = 'Exotic:',
            options = {
                {label = 'all', value = 'all', pen = COLOR_GRAY},
                {label = 'only', value = 'only', pen = COLOR_YELLOW},
                {label = 'not', value = 'not', pen = COLOR_GREEN},
            },
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'min_quality',
            frame = {t = 3, l = 46, w = 30},
            label = 'Min rarity:',
            options = rarity_opts,
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'max_quality',
            frame = {t = 3, r = 0, w = 30},
            label = 'Max rarity:',
            initial_option = 6,
            options = rarity_opts,
            on_change = function() self:refresh() end,
        },
        widgets.RangeSlider{
            frame = {t = 4, l = 46, r = 1},
            num_stops = 7,
            get_left_idx_fn = function()
                return self.subviews.min_quality:getOptionValue() + 1
            end,
            get_right_idx_fn = function()
                return self.subviews.max_quality:getOptionValue() + 1
            end,
            on_left_change = function(idx) self:set_min_rarity(idx - 1) end,
            on_right_change = function(idx) self:set_max_rarity(idx - 1) end,
        },
        widgets.Label{
            frame = {t = 5, l = 0, r = 0},
            text = {{text = 'Click a row to select; click again / double / shift-click applies the action.',
                     pen = COLOR_GRAY}},
        },
        -- three-line column header lining up with the M/F/D flag columns
        widgets.Label{
            frame = {t = 6, l = 0},
            text = 'Melt\n Forbid\n  Dump',
            text_pen = COLOR_LIGHTRED,
        },
        widgets.FilteredList{
            view_id = 'list',
            frame = {t = 9, l = 0, r = 29, b = 8},
            on_select = self:callback('on_select'),
            on_submit = self:callback('on_submit'),
            on_submit2 = self:callback('on_submit2'),
            on_double_click = self:callback('on_double_click'),
            on_double_click2 = self:callback('on_submit2'),
        },
        widgets.Panel{
            frame = {t = 9, r = 0, w = 28, b = 8},
            frame_style = gui.FRAME_THIN,
            frame_title = 'Marked for melt',
            subviews = {
                widgets.Label{
                    view_id = 'melt_total',
                    frame = {t = 0, l = 0, r = 0},
                },
                widgets.List{
                    view_id = 'melt_list',
                    frame = {t = 2, l = 0, r = 0, b = 0},
                },
            },
        },
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 7},
            frame_style = gui.FRAME_THIN,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'desc',
                    frame = {t = 0, l = 0, r = 0, b = 0},
                    text_to_wrap = 'Select an item to see its description.',
                },
            },
        },
    }

    -- drive the list's text filter from our external search field, and pull the
    -- list rows up flush (we don't use the FilteredList's own edit field)
    local fl = self.subviews.list
    fl.edit.visible = false
    fl.list.frame = {t = 0}
    fl.not_found.frame = {l = 0, t = 0}
    fl.edit = self.subviews.search
    self.subviews.search.on_change = function(text) fl:onFilterChange(text) end

    self:build_choices()
    self:refresh()
    self:select_default()

    -- the FilteredList's hidden edit grabbed keyboard focus during addviews;
    -- hand it back to our visible search field
    self.subviews.search:setFocus(true)
end

function StocksWindow:build_choices()
    local art_ids, recent_art = artifact_info()
    self.recent_artifact_id = recent_art
    local choices = {}
    for _, item in ipairs(df.global.world.items.all) do
        if not item.flags.garbage_collect then
            -- guard against odd items (body parts, vermin, etc.) failing a call
            local ok, c = pcall(function()
                local desc = dfhack.items.getDescription(item, 0, true)
                local q = quality_rank(item, art_ids)
                return {
                    item = item,
                    desc = desc,
                    foreign = item.flags.foreign,
                    exotic = is_exotic(item, self.prod),
                    meltable = dfhack.items.canMelt(item),
                    value = dfhack.items.getValue(item),
                    qrank = q,
                    qtag = QUALITY[q].tag,
                    qpen = QUALITY[q].pen,
                    qname = QUALITY[q].name,
                    type_name = type_name(item),
                    search_key = dfhack.toSearchNormalized(desc),
                }
            end)
            if ok then choices[#choices + 1] = c end
        end
    end
    -- sort: origin (foreign first), then quality (high first), then item type,
    -- then value (high first), then newest first
    table.sort(choices, function(a, b)
        local ao, bo = a.foreign and 0 or 1, b.foreign and 0 or 1
        if ao ~= bo then return ao < bo end
        if a.qrank ~= b.qrank then return a.qrank > b.qrank end
        if a.type_name ~= b.type_name then return a.type_name < b.type_name end
        if a.value ~= b.value then return a.value > b.value end
        return a.item.id > b.item.id
    end)
    self.all_choices = choices
end

function StocksWindow:make_text(c)
    return {
        {text = flag_tag(c.item), pen = COLOR_LIGHTRED, width = 3},
        {gap = 1, text = c.qtag, pen = c.qpen, width = 4},
        {gap = 1, text = ('%7s'):format(comma(c.value)), pen = COLOR_GREEN},
        {gap = 1, text = c.foreign and 'F' or ' ', pen = COLOR_LIGHTBLUE, width = 1},
        {gap = 1, text = c.exotic and 'X' or ' ', pen = COLOR_YELLOW, width = 1},
        {gap = 1, text = c.desc},
    }
end

function StocksWindow:refresh()
    local act = self.subviews.action:getOptionValue()
    local ff = self.subviews.origin:getOptionValue()
    local xf = self.subviews.exotic:getOptionValue()
    local minq = self.subviews.min_quality:getOptionValue()
    local maxq = self.subviews.max_quality:getOptionValue()
    local list, total = {}, 0
    for _, c in ipairs(self.all_choices or {}) do
        if act == 'melt' and not c.meltable then goto cont end
        if ff == 'foreign' and not c.foreign then goto cont end
        if ff == 'local' and c.foreign then goto cont end
        if xf == 'only' and not c.exotic then goto cont end
        if xf == 'not' and c.exotic then goto cont end
        if c.qrank < minq or c.qrank > maxq then goto cont end
        list[#list + 1] = {text = self:make_text(c), search_key = c.search_key,
                           item = c.item, data = c}
        total = total + c.value
        ::cont::
    end
    local saved = self.subviews.list:getFilter()
    self.subviews.list:setFilter('')
    self.subviews.list:setChoices(list)
    self.subviews.list:setFilter(saved)
    self:update_totals(#list, total)
    self:update_melt_panel()
end

function StocksWindow:update_totals(n, total)
    self.subviews.totals:setText({
        {text = ('%d shown'):format(n), pen = COLOR_GRAY},
        {gap = 2, text = ('value %s'):format(comma(total)), pen = COLOR_GREEN},
    })
end

-- right panel: count of items currently marked for melting, grouped by type
function StocksWindow:update_melt_panel()
    local counts, order = {}, {}
    for _, c in ipairs(self.all_choices or {}) do
        if c.item.flags.melt then
            if not counts[c.type_name] then counts[c.type_name] = 0; order[#order + 1] = c.type_name end
            counts[c.type_name] = counts[c.type_name] + 1
        end
    end
    table.sort(order, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
    end)
    local rows, tot = {}, 0
    for _, tn in ipairs(order) do
        rows[#rows + 1] = {text = ('%3d  %s'):format(counts[tn], tn)}
        tot = tot + counts[tn]
    end
    self.subviews.melt_total:setText(tot > 0
        and {{text = ('%d items marked'):format(tot), pen = COLOR_YELLOW}}
        or {{text = 'nothing marked', pen = COLOR_GRAY}})
    self.subviews.melt_list:setChoices(rows)
end

-- ---- selection + actions --------------------------------------------------

function StocksWindow:show_desc(choice)
    if not choice then return end
    local c = choice.data or choice
    local item = c.item
    local ok, readable = pcall(dfhack.items.getReadableDescription, item)
    self.subviews.desc:setText(('%s\n%s  -  value %s%s%s'):format(
        ok and readable or c.desc,
        c.qname,
        comma(c.value),
        c.foreign and '  [foreign]' or '  [created]',
        c.exotic and '  [exotic]' or ''))
end

-- re-render one row's text in place (no action changes filter membership, so we
-- avoid a full rebuild of the whole list on every click)
function StocksWindow:update_row(id)
    for _, w in ipairs(self.subviews.list:getVisibleChoices()) do
        if w.item.id == id then w.text = self:make_text(w.data); return end
    end
end

-- select (and scroll to the top) the most recent artifact in the current view,
-- falling back to the newest item if no artifact is shown
function StocksWindow:select_default()
    local vis = self.subviews.list:getVisibleChoices()
    if #vis == 0 then return end
    local pos
    if self.recent_artifact_id then
        for i, c in ipairs(vis) do
            if c.item.id == self.recent_artifact_id then pos = i; break end
        end
    end
    if not pos then     -- newest item in view
        local best
        for i, c in ipairs(vis) do
            if not best or c.item.id > best then best, pos = c.item.id, i end
        end
    end
    if pos then
        local lst = self.subviews.list.list
        lst.page_top = pos          -- bring the chosen row to the top of the viewport
        lst:setSelected(pos)        -- (clamped on next layout if near the end)
        self:show_desc(vis[pos])
        -- arm it so a single click on the pre-selected artifact applies the
        -- current (view) action -- i.e. focuses its sheet right away
        self.armed_id = vis[pos].item.id
        self.anchor_id = vis[pos].item.id
    end
end

-- toggle the current action's designation on one item
function StocksWindow:toggle(item)
    local act = self.subviews.action:getOptionValue()
    if act == 'view' then
        focus_item(item)
        if view then view:dismiss() end
    elseif act == 'melt' then
        if item.flags.melt then dfhack.items.cancelMelting(item)
        elseif dfhack.items.canMelt(item) then dfhack.items.markForMelting(item) end
    elseif act == 'forbid' then
        item.flags.forbid = not item.flags.forbid
    elseif act == 'dump' then
        item.flags.dump = not item.flags.dump
    end
end

-- force the current action on (used by range / select-all so they don't toggle off)
function StocksWindow:set_on(item)
    local act = self.subviews.action:getOptionValue()
    if act == 'melt' then
        if not item.flags.melt and dfhack.items.canMelt(item) then dfhack.items.markForMelting(item) end
    elseif act == 'forbid' then
        item.flags.forbid = true
    elseif act == 'dump' then
        item.flags.dump = true
    end
end

function StocksWindow:apply(item)
    if self.subviews.action:getOptionValue() == 'view' then
        self:toggle(item)   -- opens the sheet + dismisses
        return
    end
    self:toggle(item)
    self:update_row(item.id)
    self:update_melt_panel()
    self.armed_id = item.id
    self.anchor_id = item.id
end

function StocksWindow:on_select(idx, choice)
    self:show_desc(choice)
end

-- first click on a row only selects it; clicking the armed row applies
function StocksWindow:on_submit(idx, choice)
    if not choice then return end
    local id = choice.item.id
    if self.armed_id ~= id then
        self.armed_id = id
        self.anchor_id = id
        self:show_desc(choice)
        return
    end
    self:apply(choice.item)
end

-- double-click applies immediately
function StocksWindow:on_double_click(idx, choice)
    if not choice then return end
    self.armed_id = choice.item.id
    self:apply(choice.item)
end

-- shift-click applies to the range from the anchor row to here
function StocksWindow:on_submit2(idx, choice)
    if not choice then return end
    if self.subviews.action:getOptionValue() == 'view' then
        self:apply(choice.item)
        return
    end
    local vis = self.subviews.list:getVisibleChoices()
    local a, b
    for i, c in ipairs(vis) do
        if self.anchor_id and c.item.id == self.anchor_id then a = i end
        if c.item.id == choice.item.id then b = i end
    end
    if not b then return end
    a = a or b
    for i = math.min(a, b), math.max(a, b) do
        if vis[i] then self:set_on(vis[i].item); vis[i].text = self:make_text(vis[i].data) end
    end
    self:update_melt_panel()
    self.armed_id = choice.item.id
    self.anchor_id = choice.item.id
end

function StocksWindow:apply_all_visible()
    if self.subviews.action:getOptionValue() == 'view' then return end
    for _, c in ipairs(self.subviews.list:getVisibleChoices()) do
        self:set_on(c.item); c.text = self:make_text(c.data)
    end
    self:update_melt_panel()
end

-- ---- rarity slider <-> min/max cycle labels -------------------------------

function StocksWindow:set_min_rarity(q)
    q = math.max(0, math.min(6, q))
    self.subviews.min_quality:setOption(q)
    if self.subviews.max_quality:getOptionValue() < q then
        self.subviews.max_quality:setOption(q)
    end
    self:refresh()
end

function StocksWindow:set_max_rarity(q)
    q = math.max(0, math.min(6, q))
    self.subviews.max_quality:setOption(q)
    if self.subviews.min_quality:getOptionValue() > q then
        self.subviews.min_quality:setOption(q)
    end
    self:refresh()
end

-- ---- screen ---------------------------------------------------------------

view = view or nil

StocksScreen = defclass(StocksScreen, gui.ZScreen)
StocksScreen.ATTRS{
    focus_path = 'dfhack-stocks',
}

function StocksScreen:init()
    self:addviews{StocksWindow{}}
end

function StocksScreen:onDismiss()
    view = nil
end

local function show()
    view = view and view:raise() or StocksScreen{}:show()
    return view
end

-- ---- redirect: replace the vanilla Stocks screen with our window ----------

-- An invisible overlay attached to the vanilla Stocks screen. The instant the
-- player opens it (bottom-toolbar Stocks button), we close it and pop our own
-- window instead -- which is freely dismissable with Esc, returning to play.
StocksRedirect = defclass(StocksRedirect, overlay.OverlayWidget)
StocksRedirect.ATTRS{
    desc = 'Opens the DFHack stocks designation window in place of the vanilla Stocks screen.',
    default_enabled = true,
    viewscreens = 'dwarfmode/Stocks',
    overlay_onupdate_max_freq_seconds = 0,   -- react on the very first frame
    frame = {w = 1, h = 1},
}

function StocksRedirect:overlay_onupdate()
    if view then return end                              -- our window is already up
    df.global.game.main_interface.stocks.open = false    -- dismiss the vanilla screen
    dfhack.timeout(1, 'frames', show)                    -- pop ours next frame
end

OVERLAY_WIDGETS = {redirect = StocksRedirect}

if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('dfhack-stocks only works in fortress mode')
end
show()
