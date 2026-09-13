-- Pick a spot, pick items, and the fort carries them there -- via a dump zone it runs itself.
--@module = true
--[[
fort/move-items

DF has no "carry this to there". It has DUMPING: mark items, and haulers take them to a
garbage dump zone. That is a real move order with the controls filed off -- you cannot say
which zone, only that the fort has one, and what comes back is forbidden where it lands.

This puts the controls back. Reached from the `dig-building` picker ("Move items", in the
custom-tool band beside Replace wall), it runs the whole errand:

  1. YOU CLICK THE SPOT the things should end up on. DF's Dig tool is disarmed while you do
     -- this is normally opened from the dig-building picker, with mining mode live, and a
     click meant for us would otherwise paint a dig designation too -- and put back after.
  2. It makes a garbage dump zone there and DELETES EVERY OTHER DUMP ZONE in the fort, so
     there is exactly one place a dumped item can go and it is the one you picked. Those
     other zones do not come back -- deleting them is what makes the destination certain.
  3. A PICKER opens: every kind of item that can reach your spot, one row per kind, with the
     same search / sort / value / quality / wear filters DFHack's "move goods to depot"
     screen uses. Say how many of each you want and it marks the CLOSEST ones.
  4. It marks them for dumping, sets the three standing orders the haulers need, and gets
     out of the way.
  5. When the last one has arrived it deletes the zone and UNFORBIDS everything it moved --
     dumped items land forbidden, and a pile of forbidden goods is not a delivery.

Nothing is done at all unless you pick both a place and at least one item.

WHAT IS OFFERED, and what is not. Anything the fort can actually dump: loose items,
stockpiled items, and the contents of bins and barrels. Only items that can REACH the spot
-- item and destination in the same walkability group, which is DF's own answer to "can a
dwarf get from here to there" -- and nothing already standing on it.

Rows are one kind of thing, not one item: every gabbro figurine is a row, whatever its
quality or what it is encrusted with, because that is how you think about them. `[specific]`
opens the individual items behind a row, listed by distance, if you want to choose among
them (shift-click selects a range).

THE THREE STANDING ORDERS. Refuse hauling is what actually moves a corpse or a bone to a
dump zone, and a fort that has turned any of the three off silently never finishes the job.
So it sets `gather refuse`, `gather refuse outdoors` and `gather outdoor vermin remains`,
every time, and says so.

    fort/move-items            open the picker (or the status of a move in progress)
    fort/move-items status     what is still being moved
    fort/move-items cancel     stop: unmark what has not moved yet, clean up, unforbid

The job survives a save and reload: what was marked, where it is going and what to put back
afterwards is persisted with the fort.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local STATE_KEY = 'move-items/state'

-- ---- persisted state ---------------------------------------------------------
--
-- A move outlives the screen that started it and has to outlive the SESSION too: the items
-- are already marked, the zone is already there, and a reload must not leave either
-- orphaned. So the whole job -- target, zone, and the ids of everything marked -- is
-- persisted with the site the moment it starts.

local function load_state()
    local d = dfhack.persistent.getSiteData(STATE_KEY, nil)
    if type(d) ~= 'table' or not d.zone_id then return nil end
    return d
end

local function save_state(s)
    pcall(dfhack.persistent.saveSiteData, STATE_KEY, s or {})
end

local function clear_state()
    pcall(dfhack.persistent.saveSiteData, STATE_KEY, {})
end

-- ---- the map ------------------------------------------------------------------

-- Can a dwarf walk from here to there? DF keeps a walkability GROUP per tile -- tiles in the
-- same group are mutually reachable on foot -- so the question is one field compare, not a
-- path search. Group 0 means "not walkable at all".
local function walk_group(pos)
    if not pos or pos.x < 0 then return nil end
    local g = dfhack.maps.getWalkableGroup(pos)
    if not g or g == 0 then return nil end
    return g
end

local function same_pos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- the distance the trade screen shows, computed its way
local function distance(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) + math.abs(a.z - b.z)
end

-- ---- what can be dumped -------------------------------------------------------

-- Items DF will never haul, whatever you mark. Forbidden is NOT in this list: a forbidden
-- item is one you set aside, and moving it is a fine thing to ask for -- the picker offers
-- the trade screen's "hide forbidden" filter instead of deciding for you.
local function dumpable(it)
    local f = it.flags
    if f.garbage_collect or f.removed or f.encased or f.construction or f.in_building
        or f.spider_web or f.hostile or f.trader or f.on_fire then return false end
    if f.artifact then return false end                 -- an artifact is not cargo
    -- carried or worn: the holder is using it
    if dfhack.items.getGeneralRef(it, df.general_ref_type.UNIT_HOLDER) then return false end
    return true
end

-- ---- corpses ------------------------------------------------------------------
--
-- Three rows, because a pile of corpses is three different chores wearing one word. What
-- DF calls them all is "refuse".

local CORPSE_BUTCHER   = 'corpses:butcher'
local CORPSE_REFUSE    = 'corpses:refuse'
local CORPSE_OWN       = 'corpses:own'

local CORPSE_LABEL = {
    [CORPSE_BUTCHER] = 'Butcherable corpses',
    [CORPSE_REFUSE]  = 'Refuse corpses and body parts',
    [CORPSE_OWN]     = 'Fallen allies and residents',
}

local function creature_caste(race, caste)
    local raw = df.creature_raw.find(race)
    if not raw then return nil, nil end
    local c = (caste >= 0 and caste < #raw.caste) and raw.caste[caste] or nil
    return raw, c
end

-- a corpse of OURS: a citizen, a resident, or somebody who was here as a friend (a merchant,
-- a visiting bard). Read from the dead figure rather than the corpse: the corpse remembers
-- who it was, and who they were is what says whether this is a body to bury or refuse to
-- clear away.
local function is_own_dead(it)
    local hfid = it.hist_figure_id
    if hfid and hfid >= 0 then
        local hf = df.historical_figure.find(hfid)
        if hf then
            local civ = df.global.plotinfo.civ_id
            local group = df.global.plotinfo.group_id
            if hf.civ_id == civ then return true end
            for _, link in ipairs(hf.entity_links) do
                if link.entity_id == group or link.entity_id == civ then return true end
            end
        end
    end
    local uid = it.unit_id
    if uid and uid >= 0 then
        local u = df.unit.find(uid)
        if u and (dfhack.units.isCitizen(u, true) or dfhack.units.isResident(u)
                  or dfhack.units.isVisiting(u)) then return true end
    end
    return false
end

-- which of the three rows this corpse or body part belongs to, or nil if it is not one
local function corpse_category(it)
    local t = it:getType()
    if t ~= df.item_type.CORPSE and t ~= df.item_type.CORPSEPIECE then return nil end
    if is_own_dead(it) then return CORPSE_OWN end
    -- a whole, unrotten body of an animal is meat on legs; anything else is refuse. A
    -- severed hand is a body PART however fresh it is, and a sentient corpse is never
    -- butchered by a fort that would rather not be that fort.
    if t == df.item_type.CORPSE and not it.flags.rotten then
        local _, caste = creature_caste(it.race, it.caste)
        if caste and not (caste.flags.CAN_LEARN or caste.flags.CAN_SPEAK) then
            return CORPSE_BUTCHER
        end
    end
    return CORPSE_REFUSE
end

-- ---- the candidate scan --------------------------------------------------------
--
-- ONE PASS over every item in play, and it is not cheap (a fort with 27k items takes about a
-- second). It runs when the picker opens and not again -- the alternative, asking the
-- question per row or per keystroke, is the same work many times over. The tile -> walkability
-- lookup is cached because items pile up: 14k items sat on 2.1k distinct tiles here.

function scan_items(target)
    local tgroup = walk_group(target)
    if not tgroup then return nil, 'that tile is not somewhere a dwarf can stand' end

    local groups, order = {}, {}
    local tile_group = {}
    local total = 0

    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if dumpable(it) then
            local x, y, z = dfhack.items.getPosition(it)
            if x and x >= 0 then
                local pos = xyz2pos(x, y, z)
                if not same_pos(pos, target) then
                    local key = ('%d,%d,%d'):format(x, y, z)
                    local g = tile_group[key]
                    if g == nil then g = walk_group(pos) or false; tile_group[key] = g end
                    if g == tgroup then
                        local cat = corpse_category(it)
                        local gkey, label
                        if cat then
                            gkey, label = cat, CORPSE_LABEL[cat]
                        else
                            gkey = ('%d:%d:%d:%d'):format(it:getType(), it:getSubtype(),
                                                          it:getMaterial(), it:getMaterialIndex())
                            -- DF appends a stack marker (" <#8>") to a stacked item's
                            -- description; the row is the KIND, so the one item's count has
                            -- no business in its name
                            label = dfhack.items.getDescription(it, 0, false)
                                        :gsub('%s*<#%d+>%s*$', '')
                        end
                        local grp = groups[gkey]
                        if not grp then
                            grp = {key = gkey, label = label, corpse = cat and true or false,
                                   items = {}, sel = 0, specific = nil}
                            groups[gkey] = grp
                            order[#order + 1] = grp
                        end
                        grp.items[#grp.items + 1] = {
                            id = it.id, dist = distance(pos, target),
                            desc = dfhack.items.getDescription(it, 0, true),
                            value = dfhack.items.getValue(it),
                            quality = it:getQuality(), wear = it.wear,
                            forbidden = it.flags.forbid,
                        }
                        total = total + 1
                    end
                end
            end
        end
    end

    for _, grp in ipairs(order) do
        table.sort(grp.items, function(a, b)
            if a.dist ~= b.dist then return a.dist < b.dist end
            return a.id < b.id
        end)
        -- a row's own numbers, so filters and sorting have something to sort on
        local v, q, w = 0, 0, 0
        for _, e in ipairs(grp.items) do
            v = math.max(v, e.value); q = math.max(q, e.quality); w = math.max(w, e.wear)
        end
        grp.value, grp.quality, grp.wear = v, q, w
        grp.total = #grp.items
    end
    return order, nil, total
end

-- ---- doing it ------------------------------------------------------------------

local function dump_zones()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Civzone and b.type == df.civzone_type.Dump then
            out[#out + 1] = b
        end
    end
    return out
end

-- Every other dump zone goes. This is the whole reason the destination is knowable: DF sends
-- a dumped item to whichever dump zone suits the hauler, so a second zone is a second answer.
local function clear_dump_zones(keep_id)
    local n = 0
    for _, b in ipairs(dump_zones()) do
        if b.id ~= keep_id then
            if pcall(dfhack.buildings.deconstruct, b) then n = n + 1 end
        end
    end
    return n
end

local function make_dump_zone(pos)
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', 1))
    extents[0] = 1
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.Civzone, subtype = df.civzone_type.Dump, abstract = true,
        pos = pos, width = 1, height = 1,
        fields = {room = {x = pos.x, y = pos.y, width = 1, height = 1, extents = extents},
                  assigned_unit_id = -1},
    })
    if not ok or not bld then return nil end
    pcall(function() dfhack.buildings.notifyCivzoneModified(bld) end)
    return bld
end

-- The haulers' own switches. A fort with refuse gathering off never finishes a dump and
-- never says why -- the jobs simply are not posted.
local ORDERS = {
    {field = 'standing_orders_gather_refuse',         name = 'gather refuse'},
    {field = 'standing_orders_gather_refuse_outside', name = 'gather refuse outdoors'},
    {field = 'standing_orders_gather_vermin_remains', name = 'gather outdoor vermin remains'},
}

local function ensure_standing_orders()
    local changed = {}
    for _, o in ipairs(ORDERS) do
        if df.global[o.field] ~= 1 then
            df.global[o.field] = 1
            changed[#changed + 1] = o.name
        end
    end
    return changed
end

-- mark the chosen items and remember them; returns how many were marked
local function mark_items(ids)
    local marked = {}
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and dumpable(it) then
            it.flags.dump = true
            -- an item nobody may touch is never hauled, so a forbidden item being MOVED is
            -- unforbidden now rather than at the end
            it.flags.forbid = false
            marked[#marked + 1] = id
        end
    end
    return marked
end

-- the ids still waiting: DF clears `dump` when the item is put down in the zone
local function still_pending(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and it.flags.dump then out[#out + 1] = id end
    end
    return out
end

-- what a finished move leaves behind: forbidden goods in a heap. Dumped items are forbidden
-- where they land (DF's own rule), which makes a delivery look like a pile of rubbish and
-- keeps every one of them out of the fort's reach.
local function unforbid(ids)
    local n = 0
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and it.flags.forbid then it.flags.forbid = false; n = n + 1 end
    end
    return n
end

local function remove_zone(zone_id)
    local b = df.building.find(zone_id)
    if b then pcall(dfhack.buildings.deconstruct, b) end
end

-- Finish: the zone goes, everything moved is handed back to the fort, and the job is
-- forgotten. Safe to call twice.
function finish(quiet)
    local s = load_state()
    if not s then return false end
    remove_zone(s.zone_id)
    local n = unforbid(s.items or {})
    clear_state()
    if not quiet then
        dfhack.gui.showAnnouncement(
            ('move-items: delivery finished -- %d item(s) unforbidden, dump zone removed.')
            :format(n), COLOR_GREEN, true)
    end
    return true
end

-- Cancel: whatever has not moved yet stops being marked; whatever has, still gets unforbidden.
function cancel()
    local s = load_state()
    if not s then return false end
    for _, id in ipairs(s.items or {}) do
        local it = df.item.find(id)
        if it and it.flags.dump then it.flags.dump = false end
    end
    remove_zone(s.zone_id)
    unforbid(s.items or {})
    clear_state()
    return true
end

function status()
    local s = load_state()
    if not s then return nil end
    local pending = still_pending(s.items or {})
    return {target = s.target, zone_id = s.zone_id, total = #(s.items or {}), pending = #pending}
end

-- start the job: zone, marks, standing orders, persisted state
local function begin_move(target, ids)
    if not target or #ids == 0 then return nil, 'nothing to do' end
    local zone = make_dump_zone(target)
    if not zone then return nil, 'could not place a dump zone there' end
    local removed = clear_dump_zones(zone.id)
    local marked = mark_items(ids)
    if #marked == 0 then
        remove_zone(zone.id)
        return nil, 'none of those items can be dumped any more'
    end
    local orders = ensure_standing_orders()
    save_state{target = {x = target.x, y = target.y, z = target.z},
               zone_id = zone.id, items = marked}
    return {marked = #marked, removed_zones = removed, orders = orders}
end

-- ---- the watcher ---------------------------------------------------------------
--
-- Runs while a move is in progress and does nothing whatsoever otherwise: one persisted-state
-- read, throttled to a few seconds, since a haul takes minutes.

WatchOverlay = defclass(WatchOverlay, overlay.OverlayWidget)
WatchOverlay.ATTRS{
    desc = 'Finishes a move-items delivery: removes the dump zone and unforbids what arrived.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 5,
    version = 1,
}

function WatchOverlay:overlay_onupdate()
    local s = load_state()
    if not s then return end
    if #still_pending(s.items or {}) == 0 then finish() end
end

-- ---- the individual-item window -------------------------------------------------

SpecificScreen = defclass(SpecificScreen, gui.ZScreenModal)
SpecificScreen.ATTRS{focus_path = 'move-items/specific'}

function SpecificScreen:init(info)
    self.group = info.group
    self.on_close = info.on_close
    -- the explicit set starts as whatever the row's number already means: the closest N
    self.chosen = {}
    if self.group.specific then
        for id in pairs(self.group.specific) do self.chosen[id] = true end
    else
        for i = 1, self.group.sel do self.chosen[self.group.items[i].id] = true end
    end
    self.last_idx = nil
    SPEC_ACTIVE = self    -- module-level handle, the picker's twin

    self:addviews{
        widgets.Window{
            frame = {w = 74, h = 30},
            frame_title = self.group.label,
            resizable = true,
            subviews = {
                widgets.Label{frame = {t = 0, l = 0},
                    text = 'Click to pick one, shift-click to pick a range.'},
                widgets.Label{frame = {t = 1, l = 0}, text = {{text = 'dist', pen = COLOR_GRAY},
                    {gap = 3, text = 'item', pen = COLOR_GRAY}}},
                widgets.List{
                    view_id = 'list',
                    frame = {t = 3, l = 0, r = 0, b = 2},
                    choices = self:choices(),
                    on_submit = function(idx) self:toggle(idx, false) end,
                },
                widgets.HotkeyLabel{frame = {b = 0, l = 0}, key = 'LEAVESCREEN',
                    label = 'Done', on_activate = function() self:dismiss() end},
            },
        },
    }
end

function SpecificScreen:choices()
    local out = {}
    for i, e in ipairs(self.group.items) do
        local mark = self.chosen[e.id] and string.char(251) or ' '   -- a checkmark if we have one
        out[#out + 1] = {
            text = ('%-8d [%s] %s'):format(e.dist, mark, e.desc),
            idx = i,
        }
    end
    return out
end

function SpecificScreen:refresh()
    local list = self.subviews.list
    local sel = list:getSelected()
    list:setChoices(self:choices(), sel)
end

-- shift-click extends from the last one clicked, which is what every list in the world does
function SpecificScreen:toggle(idx, shift)
    local items = self.group.items
    if shift and self.last_idx then
        local a, b = math.min(self.last_idx, idx), math.max(self.last_idx, idx)
        local on = not self.chosen[items[idx].id]
        for i = a, b do self.chosen[items[i].id] = on or nil end
    else
        local id = items[idx].id
        self.chosen[id] = (not self.chosen[id]) or nil
    end
    self.last_idx = idx
    self:refresh()
end

function SpecificScreen:onInput(keys)
    if keys._MOUSE_L then
        local idx = self.subviews.list:getIdxUnderMouse()
        if idx then
            self:toggle(idx, dfhack.internal.getModifiers().shift)
            return true
        end
    end
    return SpecificScreen.super.onInput(self, keys)
end

function SpecificScreen:onDismiss()
    if SPEC_ACTIVE == self then SPEC_ACTIVE = nil end
    local set, n = {}, 0
    for id in pairs(self.chosen) do set[id] = true; n = n + 1 end
    self.group.specific = (n > 0) and set or nil
    self.group.sel = n
    if self.on_close then self.on_close() end
end

-- ---- the picker -----------------------------------------------------------------

local COL_SPECIFIC = 12      -- width of the [specific] button
local BTN = {                -- the buttons at the right of a row, in order
    {label = '[-1]',   delta = -1},
    {label = '[+1]',   delta = 1},
    {label = '[+10]',  delta = 10},
    {label = '[all]',  delta = 'all'},
}

PickerScreen = defclass(PickerScreen, gui.ZScreen)
PickerScreen.ATTRS{focus_path = 'move-items/picker'}

function PickerScreen:init(info)
    self.target = info.target
    self.groups = info.groups
    self.caravan = nil
    local ok, common = pcall(reqscript, 'internal/caravan/common')
    if ok then self.caravan = common end

    local sliders = {}
    if self.caravan and self.caravan.get_slider_widgets then
        local sok, w = pcall(self.caravan.get_slider_widgets, self)
        if sok then sliders = w end
    end

    self:addviews{
        widgets.Window{
            view_id = 'win',
            frame = {w = 100, h = 46},
            frame_title = 'Move items',
            resizable = true,
            subviews = {
                widgets.EditField{
                    view_id = 'search',
                    frame = {t = 0, l = 0, r = 1},
                    label_text = 'Search: ',
                    on_change = function() self:refresh() end,
                },
                widgets.CycleHotkeyLabel{
                    view_id = 'sort',
                    frame = {t = 1, l = 0, w = 24},
                    label = 'Sort by:',
                    key = 'CUSTOM_SHIFT_S',
                    options = {
                        {label = 'distance', value = 'dist'},
                        {label = 'name', value = 'name'},
                        {label = 'quantity', value = 'qty'},
                        {label = 'value', value = 'value'},
                    },
                    on_change = function() self:refresh() end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'hide_forbidden',
                    frame = {t = 1, l = 26, w = 28},
                    label = 'Hide forbidden:',
                    key = 'CUSTOM_SHIFT_F',
                    options = {{label = 'Yes', value = true, pen = COLOR_GREEN},
                               {label = 'No', value = false}},
                    initial_option = false,
                    on_change = function() self:refresh() end,
                },
                -- the trade screen's own filter sliders, and they are laid out for a 38-wide
                -- column: given the whole width they draw on top of each other
                widgets.Panel{
                    frame = {t = 3, l = 0, r = 0, h = 18},
                    frame_style = gui.FRAME_INTERIOR,
                    subviews = {widgets.Panel{frame = {t = 0, l = 0, w = 38}, subviews = sliders}},
                },
                widgets.List{
                    view_id = 'list',
                    frame = {t = 22, l = 0, r = 0, b = 3},
                    choices = {},
                },
                widgets.Label{
                    view_id = 'summary',
                    frame = {b = 2, l = 0},
                    text = '',
                },
                widgets.HotkeyLabel{
                    frame = {b = 0, l = 0}, key = 'CUSTOM_SHIFT_M',
                    label = 'Move the selected items',
                    on_activate = function() self:apply() end,
                },
                widgets.HotkeyLabel{
                    frame = {b = 0, l = 34}, key = 'LEAVESCREEN',
                    label = 'Cancel', on_activate = function() self:dismiss() end,
                },
            },
        },
    }
    self:refresh()
    ACTIVE = self       -- module-level handle, so the running game can be asked what it shows
end

function PickerScreen:onDismiss()
    if ACTIVE == self then ACTIVE = nil end
end

-- the sliders call this by name (they are the trade screen's own widgets)
function PickerScreen:refresh_list()
    self:refresh()
end

function PickerScreen:filters()
    local f = {min_quality = 0, max_quality = 5, min_value = 0, min_condition = 3}
    local sv = self.subviews
    if sv.min_quality then f.min_quality = sv.min_quality:getOptionValue() end
    if sv.max_quality then f.max_quality = sv.max_quality:getOptionValue() end
    if sv.min_value then
        local v = sv.min_value:getOptionValue()
        f.min_value = (type(v) == 'table') and v.value or v
    end
    if sv.min_condition then f.min_condition = sv.min_condition:getOptionValue() end
    return f
end

function PickerScreen:visible_groups()
    local search = (self.subviews.search.text or ''):lower()
    local hide_forbidden = self.subviews.hide_forbidden:getOptionValue()
    local f = self:filters()
    local out = {}
    for _, g in ipairs(self.groups) do
        local ok = true
        if #search > 0 and not g.label:lower():find(search, 1, true) then ok = false end
        if ok and hide_forbidden then
            local any = false
            for _, e in ipairs(g.items) do if not e.forbidden then any = true; break end end
            ok = any
        end
        if ok and not g.corpse then
            if g.quality < f.min_quality or g.quality > f.max_quality then ok = false end
            if ok and g.value < f.min_value then ok = false end
        end
        if ok then out[#out + 1] = g end
    end
    local sort = self.subviews.sort:getOptionValue()
    table.sort(out, function(a, b)
        if sort == 'name' then return a.label < b.label end
        if sort == 'qty' then
            if a.total ~= b.total then return a.total > b.total end
        elseif sort == 'value' then
            if a.value ~= b.value then return a.value > b.value end
        else
            local ad, bd = a.items[1].dist, b.items[1].dist
            if ad ~= bd then return ad < bd end
        end
        return a.label < b.label
    end)
    return out
end

function PickerScreen:refresh()
    self.shown = self:visible_groups()
    local choices = {}
    for _, g in ipairs(self.shown) do
        choices[#choices + 1] = {text = self:row_text(g), group = g}
    end
    local list = self.subviews.list
    list:setChoices(choices, list:getSelected())
    local chosen, kinds = 0, 0
    for _, g in ipairs(self.groups) do
        if g.sel > 0 then chosen = chosen + g.sel; kinds = kinds + 1 end
    end
    self.subviews.summary:setText(
        ('%d item(s) of %d kind(s) selected -- destination %d, %d, %d')
        :format(chosen, kinds, self.target.x, self.target.y, self.target.z))
end

-- One row, laid out in fixed columns so a click can be read back to the thing it landed on.
function PickerScreen:row_text(g)
    return ('%-12s %-44s %s %4d/%-5d %s %s %s'):format(
        '[specific]', g.label:sub(1, 44), '[-1]', g.sel, g.total, '[+1]', '[+10]', '[all]')
end

-- The column bands of a row, ZERO-BASED, counted straight off the format string above:
-- [specific] 0-11, label 13-56, [-1] 58-61, count 62-72, [+1] 74-77, [+10] 79-83, [all] 85-89.
-- The COUNT band deliberately runs from just after [-1] to the end of the total, so clicking
-- the number -- or the space either side of the slash -- is what asks for an exact amount.
local BANDS = {
    {name = 'specific', x1 = 0,  x2 = 11},
    {name = 'minus',    x1 = 58, x2 = 61},
    {name = 'count',    x1 = 62, x2 = 72},
    {name = 'plus',     x1 = 74, x2 = 77},
    {name = 'plus10',   x1 = 79, x2 = 83},
    {name = 'all',      x1 = 85, x2 = 89},
}

local function band_at(x)
    for _, b in ipairs(BANDS) do
        if x >= b.x1 and x <= b.x2 then return b.name end
    end
end

function PickerScreen:set_sel(g, n)
    g.sel = math.max(0, math.min(n, g.total))
    g.specific = nil           -- a number means "the closest N", not the set you had picked
    self:refresh()
end

function PickerScreen:onInput(keys)
    if keys._MOUSE_L then
        local list = self.subviews.list
        local idx = list:getIdxUnderMouse()
        if idx and self.shown[idx] then
            local g = self.shown[idx]
            local x = self:getMouseXInList()
            local band = x and band_at(x)
            if band == 'specific' then
                SpecificScreen{group = g, on_close = function() self:refresh() end}:show()
                return true
            elseif band == 'minus' then self:set_sel(g, g.sel - 1); return true
            elseif band == 'plus' then self:set_sel(g, g.sel + 1); return true
            elseif band == 'plus10' then self:set_sel(g, g.sel + 10); return true
            elseif band == 'all' then self:set_sel(g, g.total); return true
            elseif band == 'count' then self:ask_count(g); return true
            end
        end
    end
    return PickerScreen.super.onInput(self, keys)
end

-- the mouse's x inside the list's own body, so the bands above line up with what was drawn
function PickerScreen:getMouseXInList()
    local list = self.subviews.list
    local rect = list.frame_body
    if not rect then return nil end
    local x = dfhack.screen.getMousePos()
    if not x then return nil end
    return x - rect.x1
end

function PickerScreen:ask_count(g)
    local dlg = require('gui.dialogs')
    dlg.showInputPrompt(g.label, 'How many? (the closest ones are taken)', COLOR_WHITE,
        tostring(g.sel),
        function(text)
            local n = tonumber(text)
            if n then self:set_sel(g, math.floor(n)) end
        end)
end

function PickerScreen:apply()
    local ids = {}
    for _, g in ipairs(self.groups) do
        if g.specific then
            for _, e in ipairs(g.items) do
                if g.specific[e.id] then ids[#ids + 1] = e.id end
            end
        else
            for i = 1, g.sel do ids[#ids + 1] = g.items[i].id end
        end
    end
    if #ids == 0 then
        dfhack.gui.showAnnouncement('move-items: nothing selected -- nothing done.',
            COLOR_YELLOW, false)
        self:dismiss()
        return
    end
    local res, err = begin_move(self.target, ids)
    self:dismiss()
    if not res then
        dfhack.gui.showAnnouncement('move-items: ' .. tostring(err), COLOR_RED, true)
        return
    end
    local msg = ('move-items: %d item(s) marked, %d other dump zone(s) removed.')
        :format(res.marked, res.removed_zones)
    if #res.orders > 0 then
        msg = msg .. ' Standing orders turned on: ' .. table.concat(res.orders, ', ') .. '.'
    end
    dfhack.gui.showAnnouncement(msg, COLOR_GREEN, true)
end

-- ---- picking the spot -------------------------------------------------------------
--
-- An OVERLAY, not a dialog, and it polls the mouse buttons rather than waiting for input to be
-- handed to it. Both parts are the lesson `dig-replace-walls` already learned on this screen:
--
--   * The Dig tool is still armed. This is normally opened from the `dig-building` picker,
--     which runs while NORMAL MINING MODE is selected, so a click meant for us also paints a
--     dig designation on the tile. So the designation tool is disarmed while we are up and put
--     back exactly as it was afterwards -- and with no tool selected there is nothing for DF or
--     for the repo's other map tools to act on either.
--   * A map click does not reliably arrive as `onInput` on a lua screen. The map belongs to DF;
--     what works is reading `enabler.mouse_lbut_down` on the overlay pump and resolving the
--     tile with `dfhack.gui.getMousePos()`, which is how every map tool here takes its clicks.
--
-- The click is taken on RELEASE, and the button state at the moment we open is remembered, so
-- the click that opened this panel is not read as the click that picks the spot.

targeting = targeting or false
local saved_tool = nil

local function start_targeting()
    local mi = df.global.game.main_interface
    saved_tool = mi.main_designation_selected
    mi.main_designation_selected = df.main_designation_type.NONE
    targeting = true
end

local function stop_targeting()
    targeting = false
    if saved_tool then
        df.global.game.main_interface.main_designation_selected = saved_tool
        saved_tool = nil
    end
end

TargetOverlay = defclass(TargetOverlay, overlay.OverlayWidget)
TargetOverlay.ATTRS{
    desc = 'move-items: click the spot to move things to.',
    default_pos = {x = -33, y = 6},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 32, h = 4},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function TargetOverlay:init()
    self.lbut, self.rbut = 0, 0
    self:addviews{
        widgets.Panel{
            frame_style = gui.FRAME_MEDIUM,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.Label{frame = {t = 0, l = 0}, text = {
                    'Click the spot to move things to.', NEWLINE,
                    {text = 'Right-click cancels.', pen = COLOR_GRAY},
                }},
            },
        },
    }
end

function TargetOverlay:render(dc)
    if not targeting then return end
    TargetOverlay.super.render(self, dc)
end

-- The button states are INTS, not booleans, and that matters in Lua: `not 0` is false, so a
-- released button read as a boolean is indistinguishable from a held one. Compare against 1,
-- the way every other map tool here does.
function TargetOverlay:overlay_onupdate()
    if not targeting then return end
    local e = df.global.enabler
    local l, r = e.mouse_lbut_down, e.mouse_rbut_down
    local l_rel, r_rel = (l ~= 1 and self.lbut == 1), (r ~= 1 and self.rbut == 1)
    self.lbut, self.rbut = l, r
    if r_rel then
        stop_targeting()
        return
    end
    if not l_rel then return end
    local pos = dfhack.gui.getMousePos()
    if not pos then return end                 -- released off the map: not a choice
    stop_targeting()
    open_picker(pos)
end

-- ---- entry points --------------------------------------------------------------

function open_picker(target)
    local groups, err = scan_items(target)
    if not groups then
        dfhack.gui.showAnnouncement('move-items: ' .. tostring(err), COLOR_YELLOW, true)
        return
    end
    if #groups == 0 then
        dfhack.gui.showAnnouncement(
            'move-items: nothing that can reach that spot is anywhere else.', COLOR_YELLOW, true)
        return
    end
    PickerScreen{target = target, groups = groups}:show()
end

-- true while any part of this tool has the screen, so the dig-building picker gets out of the
-- way: the spot-picking overlay draws no focus of its own, so asking the focus string alone
-- would leave the picker sitting on top of it
function active()
    if targeting then return true end
    local f = dfhack.gui.getCurFocus(true)
    for _, s in ipairs(f or {}) do
        if s:find('move%-items') then return true end
    end
    return false
end

function show()
    local st = status()
    if st then
        dfhack.gui.showAnnouncement(
            ('move-items: a delivery is already running -- %d of %d item(s) still on the way. '
             .. '`move-items cancel` calls it off.'):format(st.pending, st.total),
            COLOR_YELLOW, true)
        return
    end
    start_targeting()
end

OVERLAY_WIDGETS = {watch = WatchOverlay, target = TargetOverlay}

if dfhack_flags.module then
    return
end

local args = {...}
local cmd = args[1]
if cmd == 'status' then
    local st = status()
    if not st then
        print('move-items: nothing being moved.')
    else
        print(('move-items: %d of %d item(s) still on the way to %d, %d, %d (zone %d).')
            :format(st.pending, st.total, st.target.x, st.target.y, st.target.z, st.zone_id))
    end
elseif cmd == 'cancel' then
    print(cancel() and 'move-items: cancelled.' or 'move-items: nothing to cancel.')
elseif cmd == 'finish' then
    print(finish() and 'move-items: finished.' or 'move-items: nothing in progress.')
else
    show()
end
