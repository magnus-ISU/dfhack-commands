-- Open a linked building on its LINKS, and let a flooded pressure plate be fired by hand.
--@module = true
--[[
fort/better-bridges

Two fixes to the building sheet, both about the same blind spot: DF knows perfectly well
that this bridge is wired to that lever, and shows you a list of mechanisms instead.

1. LINKED BUILDINGS IS THE DEFAULT PANEL when there are any. A building sheet has two
   panels at its foot -- `Show linked buildings` and `Show items` -- and DF always opens on
   Show items. For a bridge, a door, a hatch, a floodgate, a lever or a pressure plate,
   items means "the two mechanisms inside it", which is a fact about the masonry; the
   question you opened the sheet to ask is WHAT IS THIS WIRED TO. So when the building has
   a link, the sheet opens on the links. When it has none the panel is left alone, because
   then items is the only thing there is to show.

   Only the FIRST look at a building is redirected. Click `Show items` afterwards and it
   stays on items for as long as that sheet is open -- the default is a default, not a
   preference being enforced over the top of you.

   A LINK IS FOUND FROM BOTH ENDS. A lever or a plate keeps the far end's mechanism in its
   own `linked_mechanisms`; the bridge at the other end keeps nothing at all -- it just has
   a mechanism sitting in its `contained_items` whose refs point back. So both are read,
   and a bridge driven by two controls lists both of them.

2. [Open /] / [Close /] ON A PRESSURE PLATE, in that same list. DFHack's own `buildingplan`
   overlay already draws a `[Pull    /]` on the LEVER rows of the linked-buildings list -- open the bridge, see its lever, pull it
   from there without going to find it. A pressure plate gets no such button, because a
   plate is fired by the world rather than by a dwarf. But when the world has already put
   something on it, there IS something to fire -- so the button goes in the same column as
   `[Pull    /]`, on the plate's row, and flips whether that thing counts:

   IT SAYS WHAT THE CLICK WILL DO. Looking at a BRIDGE, the button reads `[Open    /]` or
   `[Close    /]` rather than `[Trigger /]`, because from there the answer is knowable: a
   raised drawbridge is a wall and a lowered one is a floor, so raised is closed. Either way
   the click toggles the bridge -- turning the plate's sense on fires it, turning the sense
   off lets it reset, and DF moves the bridge on both edges -- so the word is simply the
   opposite of where the bridge is now, and a bridge caught mid-movement is judged on where
   it is heading. Anything else at the other end still reads `[Trigger /]`, since "open" is
   not a thing this can promise about a lever or a hatch it has not been taught.

   All three words are built to DF's own stencil, eleven columns with the `/` pushed to the
   end, so the button never changes width as the bridge moves:

     * WATER or MAGMA standing on the plate's tile, or a MINECART parked on it. Nothing on
       the plate, no button: there would be nothing for it to do.
     * Clicking flips the plate's sense flag for that condition. Turn it on with water
       already sitting there and the plate fires and the bridge moves; turn it off and the
       plate stops sensing and the bridge goes back. That is the whole trick -- DF's own
       Water/Magma/Track tabs hold an On/Off for exactly this, three clicks away.
     * A plate can have more than one of them on it at once. The button aims at the FIRST
       of water, magma, minecart that is actually there -- a liquid beats a cart -- so it
       is one button with one meaning rather than a row of them.

   WHERE THE ROW IS -- AND THE `[Pull    /]` ITSELF -- is not DF's. That list is DFHack's
   stock `buildingplan.mechanism_unlink` overlay, which paints its own list over DF's, one
   `[Unlink]` button per row and a `[Pull    /]` on the lever rows. The overlay plugin draws
   its widgets in hash order, so nothing says which of the two paints first; the first cut of
   this read the `[Unlink]` text back off the screen and worked exactly until a restart put
   this widget before that one, when it read blank cells and drew nothing. So the button is
   painted from INSIDE the stock widget's render -- its `render` is wrapped, once, and ours
   runs the moment it returns -- and the rows come from its own `unlink_n` button subviews,
   each of which knows its row and which mechanism it stands for. Without that overlay there
   is no list of this shape at all, and nothing is drawn.

   THE CLICK IS THE WHOLE OF IT. The flag is written there and then -- nothing in this is
   throttled or queued -- and the button repaints on the same frame, because DF only redraws
   when it believes something changed and a flag written from outside its input handling is
   not something it knows about. What is NOT instant is DF acting on it: the plate has to be
   evaluated and the bridge has to move, and neither of those happens while the game is
   PAUSED. Pressing the button on a paused fort sets the flag and nothing visibly follows
   until time runs again.

   IT DOES NOT TOUCH THE PLATE'S RANGES. A plate configured to fire between 1 and 3 units
   of water will not fire under 7/7 however the flag is set, and rewriting the range to
   make the button "work" would be quietly redesigning the trap. `fort/better-bridges` on the
   command line prints the depth and the range, so a plate that will not move says why.

Both are overlays, registered automatically; nothing to enable.

    fort/better-bridges          what this building is linked to, and what is on the plate
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- ---- links, from both ends ---------------------------------------------------

-- Not every building type HAS a `linked_mechanisms` field, and reading a field that is not
-- there throws rather than returning nil -- a bridge is the case that matters here.
local function safe_field(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
end

-- Every building wired to this one. A mechanism carries two refs, the holder and the
-- trigger; whichever of them is not us is the other end of the wire.
function linked_buildings(bld)
    local out, seen = {}, {}
    local function note(mech)
        if not mech then return end
        for _, r in ipairs(mech.general_refs) do
            local t = r:getType()
            if t == df.general_ref_type.BUILDING_HOLDER
                    or t == df.general_ref_type.BUILDING_TRIGGER then
                local id = r.building_id
                if id ~= bld.id and not seen[id] then
                    local other = df.building.find(id)
                    if other then seen[id] = true; out[#out + 1] = other end
                end
            end
        end
    end
    -- the far end, for anything that drives something else (levers, plates, other triggers)
    for _, m in ipairs(safe_field(bld, 'linked_mechanisms') or {}) do note(m) end
    -- and the near end: the mechanism somebody else installed IN this building
    for _, e in ipairs(safe_field(bld, 'contained_items') or {}) do
        local it = e.item
        if it and it:getType() == df.item_type.TRAPPARTS then note(it) end
    end
    return out
end

-- ---- what is standing on a pressure plate ------------------------------------

-- The plate's sense flag, and the range it is configured to fire within, per condition.
local CONDITIONS = {
    {key = 'water',    flag = 'water', min = 'water_min', max = 'water_max', unit = '/7'},
    {key = 'magma',    flag = 'magma', min = 'magma_min', max = 'magma_max', unit = '/7'},
    {key = 'minecart', flag = 'track', min = 'track_min', max = 'track_max', unit = ''},
}
local BY_KEY = {}
for _, c in ipairs(CONDITIONS) do BY_KEY[c.key] = c end

local function plate_of_sheet(bld)
    if not bld or bld:getType() ~= df.building_type.Trap then return nil end
    if bld.trap_type ~= df.trap_type.PressurePlate then return nil end
    return bld
end

-- a minecart parked on this tile, or nil. The vehicle list is a couple of dozen entries, so
-- this is a scan over carts rather than over items.
local function cart_on(x, y, z)
    for _, v in ipairs(df.global.world.vehicles.active) do
        local it = df.item.find(v.item_id)
        if it then
            local ix, iy, iz = dfhack.items.getPosition(it)
            if ix == x and iy == y and iz == z then return it end
        end
    end
end

-- What the button is aimed at: the first of water, magma, minecart actually on the plate.
-- Returns the condition and the level to compare against the plate's range (nil for a cart,
-- whose range is a weight this cannot read).
function plate_condition(bld)
    local des = dfhack.maps.getTileFlags(xyz2pos(bld.x1, bld.y1, bld.z))
    if des and des.flow_size > 0 then
        local magma = des.liquid_type == df.tile_liquid.Magma
        return BY_KEY[magma and 'magma' or 'water'], des.flow_size
    end
    if cart_on(bld.x1, bld.y1, bld.z) then return BY_KEY.minecart, nil end
    return nil
end

-- Flip whether that condition fires the plate, and say what it means. Returns the new state.
-- NO ANNOUNCEMENT. The button is its own feedback -- it goes green the frame the flag goes on
-- -- and a line in the announcement log for a button you just pressed is noise you have to
-- scroll past later. The one thing an announcement was worth saying (the plate's range not
-- covering what is on it) is on the plate's own tab and in `fort/better-bridges` on the
-- command line.
function flip_trigger(bld)
    local cond = plate_condition(bld)
    if not cond then return nil end
    local info = bld.plate_info
    local now = not info.flags[cond.flag]
    info.flags[cond.flag] = now
    -- REDRAW THIS FRAME. DF only repaints when it thinks something changed, and a flag written
    -- from outside its own input handling is not something it knows about -- so the button
    -- could sit on its old colour until the next thing that happened to force a repaint, which
    -- reads exactly like a button that did not work.
    df.global.gps.force_full_display_count = 1
    return now
end

-- ---- the sheet ----------------------------------------------------------------

local function sheet_building()
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.BUILDING then return nil end
    return df.building.find(vs.viewing_bldid)
end

-- 1. open a linked building on its links ---------------------------------------
--
-- Done from `render` rather than `overlay_onupdate`: the update is throttled to seconds and
-- the panel has to be right on the frame the sheet appears, or the player watches it change
-- under them. The work is one integer compare until the building actually changes.

LinkPanelOverlay = defclass(LinkPanelOverlay, overlay.OverlayWidget)
LinkPanelOverlay.ATTRS{
    desc = 'Opens a building sheet on its linked buildings when it has any.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},          -- draws nothing; it only sets the default panel
    -- NO `overlay_onupdate_max_freq_seconds = 0` HERE, and it cost an evening to learn why.
    -- A widget that defines no `overlay_onupdate` is parked by the framework at
    -- `next_update_ms = math.huge` so it is never called -- but `do_update` skips that guard
    -- entirely when the frequency is 0, calls the method that is not there, and throws every
    -- frame. The throw escapes `update_viewscreen_widgets`, so the whole per-frame widget
    -- pass dies with it and EVERY OTHER OVERLAY stops updating: notifications stop rebuilding
    -- their rows and panels that size themselves in `overlay_onupdate` draw at their default
    -- size instead. This widget works in `render` and wants no update callback at all.
    version = 2,
}

function LinkPanelOverlay:render(dc)
    local vs = df.global.game.main_interface.view_sheets
    local id = (vs.open and vs.active_sheet == df.view_sheet_type.BUILDING)
        and vs.viewing_bldid or -1
    if id ~= self.last_bldid then
        self.last_bldid = id
        local bld = id >= 0 and df.building.find(id)
        if bld and #linked_buildings(bld) > 0 then
            vs.show_linked_buildings = true
        end
    end
    LinkPanelOverlay.super.render(self, dc)
end

-- 2. [Trigger /] ----------------------------------------------------------------
--
-- Drawn into the linked-buildings list, in the column DF uses for a lever's `[Pull    /]`.

local STOCK = 'buildingplan.mechanism_unlink'   -- the widget that paints the list
local PULL_DX = 12                 -- its `[Pull    /]` column, left of its `[Unlink]`

-- The stock widget's `[Pull    /]` on a lever row is eleven columns, the word left-aligned in
-- eight and the `/` pushed to the end -- so ours is built to the same stencil whatever word it
-- is carrying. A button that changed width as the bridge moved would jitter under the pointer.
local BUTTON_W = 11
local function button_text(word) return ('[%-8s/]'):format(word) end

-- SAY WHAT THE CLICK WILL DO, when the thing at the other end is a bridge and the answer is
-- therefore knowable. A raised drawbridge is a wall and a lowered one is a floor, so raised is
-- CLOSED and lowered is OPEN.
--
-- Either way the click TOGGLES the bridge: turning the plate's sense on fires it, turning the
-- sense off lets it reset, and DF moves the bridge on both edges. So what the click will do is
-- simply the opposite of where the bridge is now -- no need to reason about which way the flag
-- is going. A bridge caught mid-movement is judged on where it is heading, not where it is.
local function bridge_verb(bld)
    if not bld or bld:getType() ~= df.building_type.Bridge then return nil end
    local g = bld.gate_flags
    local going_up = g.raising or (g.raised and not g.lowering)
    return going_up and 'Open' or 'Close'
end

-- the building at the far end of a mechanism sitting in this one
local function mech_target(item)
    for _, ref in ipairs(item.general_refs) do
        if df.general_ref_building_triggerst:is_instance(ref)
                or df.general_ref_building_triggertargetst:is_instance(ref) then
            return df.building.find(ref.building_id)
        end
    end
end

TriggerOverlay = defclass(TriggerOverlay, overlay.OverlayWidget)
TriggerOverlay.ATTRS{
    desc = 'Adds a Trigger button to pressure plates listed under a building\'s linked buildings.',
    default_pos = {x = -56, y = 46},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = BUTTON_W, h = 21},
    version = 2,
}

-- the stock list widget, when it is loaded and switched on
local function stock_widget()
    local st = overlay.get_state()
    local entry = st.db[STOCK]
    if not entry or not entry.widget then return nil end
    local cfg = st.config[STOCK]
    if cfg and cfg.enabled == false then return nil end
    return entry.widget
end

-- The rows this widget should put a button on: `{x, y, bld}` in SCREEN cells for every row of
-- the stock list that holds a pressure plate with something on it. Each of its visible
-- `unlink_n` buttons is one row; the mechanism behind it is looked up the way it does, and
-- that mechanism's far end is the building on the row.
function TriggerOverlay:button_rows(stock)
    local out = {}
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.BUILDING then return out end
    if not vs.show_linked_buildings then return out end
    local bld = df.building.find(vs.viewing_bldid)
    if not bld or stock.building ~= bld then return out end
    -- a subview's frame_rect is relative to its parent's; the parent's is on the screen
    local base = stock.frame_rect
    if not base then return out end
    for n = 1, stock.num_buttons or 0 do
        local btn = stock.subviews['unlink_' .. n]
        if btn and btn.visible and btn.frame_rect then
            local idx = stock:idx_from_offset(btn.frame.t)
            local slot = idx > 0 and bld.contained_items[idx]
            local target = slot and mech_target(slot.item)
            local plate = plate_of_sheet(target)
            if plate and plate_condition(plate) then
                out[#out + 1] = {x = base.x1 + btn.frame_rect.x1 - PULL_DX,
                                 y = base.y1 + btn.frame_rect.y1, bld = plate}
            end
        end
    end
    return out
end

-- Painted straight after the stock widget has painted its list, whatever order the overlay
-- plugin happens to call the two of us in. Absolute screen cells: the rows came in those.
function TriggerOverlay:paint_after(stock)
    local word = bridge_verb(sheet_building()) or 'Trigger'
    -- kept for the click: the rows a button was actually PAINTED on are exactly the rows that
    -- should answer to one
    self.drawn_rows = self:button_rows(stock)
    for _, row in ipairs(self.drawn_rows) do
        local cond = plate_condition(row.bld)
        local on = cond and row.bld.plate_info.flags[cond.flag]
        dfhack.screen.paintString({fg = on and COLOR_GREEN or COLOR_WHITE}, row.x, row.y, button_text(word))
    end
end

-- Hook the stock widget's render, once per instance of it (a rescan makes a new one, which
-- arrives unhooked). Our own render then has nothing to paint: it only keeps the hook in place
-- and clears the rows when the list is not showing, so a stale click has nothing to land on.
function TriggerOverlay:onRenderBody(dc)
    local stock = stock_widget()
    if not stock then self.drawn_rows = nil return end
    if stock._better_bridges ~= self then
        local orig = stock._better_bridges_render or stock.render
        stock._better_bridges_render = orig
        stock._better_bridges = self
        local me = self
        stock.render = function(w, ...)
            orig(w, ...)
            local ok, err = pcall(me.paint_after, me, w)
            if not ok then dfhack.printerr('better-bridges: ' .. tostring(err)) end
        end
    end
    if not df.global.game.main_interface.view_sheets.show_linked_buildings then self.drawn_rows = nil end
end

function TriggerOverlay:onInput(keys)
    if not keys._MOUSE_L or not self.drawn_rows then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x then return false end
    for _, row in ipairs(self.drawn_rows) do
        if y == row.y and x >= row.x and x < row.x + BUTTON_W then
            flip_trigger(row.bld)
            return true
        end
    end
    return false
end

OVERLAY_WIDGETS = {panel = LinkPanelOverlay, trigger = TriggerOverlay}

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('better-bridges only works in fortress mode') end

local bld = sheet_building()
if not bld then
    print('better-bridges: no building sheet open. Click a bridge, lever or pressure plate.')
    return
end
print(('better-bridges: %s (#%d)'):format(dfhack.buildings.getName(bld), bld.id))
local links = linked_buildings(bld)
if #links == 0 then
    print('  not linked to anything -- the sheet is left on Show items.')
else
    print(('  linked to %d building(s); the sheet opens on Show linked buildings:'):format(#links))
    for _, b in ipairs(links) do
        print(('    %s (#%d, %s)'):format(dfhack.buildings.getName(b), b.id,
            df.building_type[b:getType()]))
    end
end
local plate = plate_of_sheet(bld)
if plate then
    local cond, level = plate_condition(plate)
    if not cond then
        print('  nothing on the plate -- no [Trigger /] button until there is.')
        print('  (the button appears on the plate\'s row in a LINKED building\'s sheet.)')
    else
        print(('  %s%s on it; the plate is %s sensing %s (fires between %d and %d).')
            :format(cond.key, level and (' ' .. level .. cond.unit) or '',
                plate.plate_info.flags[cond.flag] and 'ALREADY' or 'NOT',
                cond.key, plate.plate_info[cond.min], plate.plate_info[cond.max]))
    end
end
