-- Drag designate / drag remove for designation & build tools, plus right-click-to-cancel.
--@module = true
--[[
right-click-cancel

Mouse helpers for DF's designation and construction tools (overlay "right-click-cancel.cancel"):

  * LEFT-DRAG a box (in "box select" / rectangle mode) APPLIES the designation across the box
    in one gesture: the game places the first corner on mouse-down (so its selection box
    renders as you drag) and we auto-place the second corner on release. Works for dig and
    its sub-types (channel / ramps / up,down,up-down stairs), woodcutting (chop), plant
    gathering -- whatever designation tool is active. The game does the actual designating,
    so validity, marker mode, priority, etc. all match exactly.
  * LEFT single-click is left entirely to the game (placed on mouse-down), so the normal
    click-click designation and its live selection box are unchanged.
  * AUTO-REMOVE: a plain DIG box (left-drag with the Dig tool) drawn ENTIRELY over tiles that
    can't be dug but can be removed is redesignated as a removal -- all constructions -> Remove
    Construction; all natural ramps -> Remove Up Stairs/Ramps. Done by swapping the designation
    tool for that one box so DF applies the real removal, then restoring Dig. If any tile in the
    box is diggable rock (a real wall), it stays a normal dig -- so this only ever triggers when
    the whole selection is removable-only.

  * ALL gestures route through map_pos_if_clear(): the strict dfhack.gui.getMousePos() is nil
    over any UI (toolbar/panel/menu/notification), so a click on ANY UI element does the normal
    thing instead of designating -- plus we stand off DF hover elements and other DFHack overlays.
  * RIGHT-DRAG a box REMOVES everything designated in it (dig/chop/gather designations,
    smoothing/engraving/fortification designations + their queued jobs, and in-progress
    buildings). While dragging, a red-X preview marks the tiles that will be erased. A
    LEFT-press during a right-drag CANCELS the erase (and does not designate).
  * RIGHT single-click cancels whatever is designated under the cursor (a dig designation, a
    tree/plant marked for chop/gather, or an in-progress construction/building); a right
    click on an empty tile passes through (the game's normal "leave the tool").
    Two exceptions where the right-click is FORWARDED instead of cancelling:
      - if you just (< 2s) finished adding a dig/build job on that exact tile, so a reflexive
        right-click doesn't nuke what you just placed; and
      - if a box-select corner is placed but not yet completed, so the right-click backs out
        just that pending placement rather than cancelling designations under the cursor.

Toggle or move it with gui/overlay; magnus-scripts enables it each session.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')
local guidm = require('gui.dwarfmode')
local utils = require('utils')

local MD = df.main_designation_type
local DV = df.tile_dig_designation

-- ---- general map-click UI guard (mirrors dwarf-rts.map_pos_if_clear) --------
-- Every mouse gesture here must be ignored when the cursor is over ANY UI element, so a
-- click on a menu/panel/toolbar/notification does the normal thing instead of designating.
-- widget belongs to the screen we're on right now?
local function widget_on_screen(w, vs)
    local vss = w.viewscreens
    if type(vss) == 'string' then vss = {vss} end
    if type(vss) ~= 'table' then return false end
    for _, fs in ipairs(vss) do
        if type(fs) == 'string' then
            local ok, m = pcall(dfhack.gui.matchFocusString, fs, vs)
            if ok and m then return true end
        end
    end
    return false
end

-- cursor over some OTHER visible overlay panel (notifications, etc.) that draws over the map?
local function over_other_overlay(mx, my)
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'right-click-cancel.cancel' then
            local w = e.widget
            local r = w.frame_rect
            if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh)
                and widget_on_screen(w, vs)
            then
                local ok, vis = pcall(function() return utils.getval(w.visible) end)
                if ok and vis then return true end
            end
        end
    end
    return false
end

-- the map pos if the click is on the EXPOSED map, or nil if it's on any UI. The strict
-- dfhack.gui.getMousePos() is nil over panels/toolbar/menus; we additionally stand off DF
-- hover elements and other DFHack overlays (which draw over the map without blocking the
-- viewport). Use this instead of getMousePos() for every press/gesture start.
local function map_pos_if_clear()
    local pos = dfhack.gui.getMousePos()
    if not pos then return nil end
    local m = df.global.game.main_interface
    if m.current_hover ~= -1 then return nil end
    if m.current_hover_alert then return nil end       -- over a native DF notification/alert
    -- DF sets current_hover_left_x to the left edge of whatever UI element the cursor is
    -- over (the alert reads 4); it stays 0 over the open map. Non-zero => over UI.
    if m.current_hover_left_x ~= 0 then return nil end
    local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
    -- the protected notification area (same zone as dig-shapes/dwarf-rts): the left 2
    -- columns + the top-left 4x4 corner, so notifications and alerts stay usable while a
    -- designation tool is active
    if mx < 2 or (mx < 4 and my < 4) then return nil end
    if over_other_overlay(mx, my) then return nil end
    return pos
end

-- Marker painted over each tile a right-drag will erase. Must be drawn on the MAP
-- grid (graphical map tiles are a different size than the text grid, so a text-grid
-- paint comes out mis-scaled). So we carry a real graphics tile -- CURSORS(3,0), the
-- red "destroy/remove" art DFHack's mass-remove uses -- and paint with map=true.
-- keep_lower leaves the map tile visible under the eraser mark; ch/fg is the
-- ASCII-mode fallback.
local ERASE_PEN = dfhack.pen.parse{ch = 'X', fg = COLOR_LIGHTRED, keep_lower = true,
    tile = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)}

-- ============================================================================
-- CANCEL side (right-click / right-drag)
-- ============================================================================

-- designation tools in which right-click should cancel
local ACTIVE_DESIG = {}
for _, name in ipairs({
    'DIG_DIG', 'DIG_REMOVE_STAIRS_RAMPS', 'DIG_STAIR_UP', 'DIG_STAIR_UPDOWN', 'DIG_STAIR_DOWN',
    'DIG_RAMP', 'DIG_CHANNEL', 'DIG_FROM_MARKER', 'DIG_TO_MARKER',
    'CHOP', 'CHOP_FROM_MARKER', 'CHOP_TO_MARKER',
    'GATHER', 'GATHER_FROM_MARKER', 'GATHER_TO_MARKER',
    'SMOOTH', 'ENGRAVE', 'TRACK', 'FORTIFY', 'TOGGLE_ENGRAVING', 'SMOOTH_FROM_MARKER', 'SMOOTH_TO_MARKER',
    'ERASE',
}) do ACTIVE_DESIG[MD[name]] = true end

local DIG_JOB = {}
for _, name in ipairs({'Dig', 'CarveUpwardStaircase', 'CarveDownwardStaircase',
    'CarveUpDownStaircase', 'CarveRamp', 'DigChannel'}) do DIG_JOB[df.job_type[name]] = true end
local CHOP_JOB = {[df.job_type.FellTree] = true}
local GATHER_JOB = {[df.job_type.GatherPlants] = true}
-- smoothing, engraving and fortification-carving jobs (all driven by the same
-- designation.smooth flag: smooth on rough stone, engrave/fortify on smooth stone)
local SMOOTH_JOB = {}
for _, name in ipairs({'DetailWall', 'DetailFloor', 'CarveFortification'}) do
    SMOOTH_JOB[df.job_type[name]] = true
end

local function remove_jobs_at(pos, typeset)
    local removed = false
    local link = df.global.world.jobs.list.next
    while link do
        local job, nxt = link.item, link.next
        if job and typeset[job.job_type]
            and job.pos.x == pos.x and job.pos.y == pos.y and job.pos.z == pos.z then
            dfhack.job.removeJob(job)
            removed = true
        end
        link = nxt
    end
    return removed
end

local function cancel_dig(pos)
    local blk = dfhack.maps.getTileBlock(pos)
    if not blk then return false end
    local lx, ly = pos.x % 16, pos.y % 16
    local des = blk.designation[lx][ly]
    local had = des.dig ~= DV.No
    if had then
        des.dig = DV.No
        blk.occupancy[lx][ly].dig_marked = false
        blk.flags.designated = true
    end
    if remove_jobs_at(pos, DIG_JOB) then had = true end
    return had
end

-- un-designate smoothing / engraving / fortification-carving on the tile (all three
-- live in designation.smooth), and remove any already-queued detailing job there
local function cancel_smooth(pos)
    local blk = dfhack.maps.getTileBlock(pos)
    if not blk then return false end
    local des = blk.designation[pos.x % 16][pos.y % 16]
    local had = des.smooth ~= 0
    if had then
        des.smooth = 0
        blk.flags.designated = true
    end
    if remove_jobs_at(pos, SMOOTH_JOB) then had = true end
    return had
end

-- un-mark a tree/plant designated for chop/gather
local function cancel_plant(pos)
    local plant = dfhack.maps.getPlantAtTile(pos)
    if plant and dfhack.designations.isPlantMarked(plant) and dfhack.designations.canUnmarkPlant(plant) then
        dfhack.designations.unmarkPlant(plant)
        return true
    end
    return false
end

local function under_construction(bld)
    if bld:getBuildStage() < bld:getMaxBuildStage() then return true end
    for _, j in ipairs(bld.jobs) do
        if j.job_type == df.job_type.ConstructBuilding then return true end
    end
    return false
end

local function cancel_building(pos)
    local bld = dfhack.buildings.findAtTile(pos)
    if bld and under_construction(bld) then
        dfhack.buildings.deconstruct(bld)
        return true
    end
    return false
end

local function cancel_at(pos)
    local did = cancel_dig(pos)
    if cancel_smooth(pos) then did = true end
    if remove_jobs_at(pos, CHOP_JOB) then did = true end
    if remove_jobs_at(pos, GATHER_JOB) then did = true end
    if cancel_plant(pos) then did = true end
    if cancel_building(pos) then did = true end
    return did
end

local function in_cancel_mode()
    local mi = df.global.game.main_interface
    if ACTIVE_DESIG[mi.main_designation_selected] then return true end
    if mi.bottom_mode_selected == df.main_bottom_mode_type.BUILDING_PLACEMENT then return true end
    return false
end

local function for_box(a, b, cb)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    for x = x1, x2 do for y = y1, y2 do cb(x, y, a.z) end end
end

-- AUTO-REMOVE: a plain Dig box drawn entirely over things that can't be dug but CAN be
-- removed (constructions, or natural ramps) is redesignated as a removal instead. If EVERY
-- tile in the box is a construction -> Remove Construction; if every tile is a natural ramp
-- -> Remove Up Stairs/Ramps; anything diggable (a real wall) in the box -> leave it a normal
-- dig. Returns the main_designation_type to use for a native re-designation, or nil for dig.
local function removal_tool_for_box(a, b)
    local all_con, all_ramp, any = true, true, false
    for_box(a, b, function(x, y, z)
        any = true
        local pos = {x = x, y = y, z = z}
        local con = dfhack.constructions.findAtTile(pos) ~= nil
        local tt = dfhack.maps.getTileType(pos)
        local at = tt and df.tiletype.attrs[tt]
        local ramp = at and not con
            and (at.shape == df.tiletype_shape.RAMP or at.shape == df.tiletype_shape.RAMP_TOP)
        if not con then all_con = false end
        if not ramp then all_ramp = false end
    end)
    if not any then return nil end
    if all_con then return MD.REMOVE_CONSTRUCTION end
    if all_ramp then return MD.DIG_REMOVE_STAIRS_RAMPS end
    return nil   -- mixed, or contains diggable rock -> normal dig
end

local function cancel_box(a, b)
    for_box(a, b, function(x, y, z) cancel_at({x = x, y = y, z = z}) end)
end

-- current dig-designation value at pos (No if the block isn't loaded)
local function dig_val(pos)
    local blk = dfhack.maps.getTileBlock(pos)
    if not blk then return DV.No end
    return blk.designation[pos.x % 16][pos.y % 16].dig
end

-- did a dig designation or an under-construction building just get placed at pos?
local function just_added_at(pos)
    if dig_val(pos) ~= DV.No then return true end
    local bld = dfhack.buildings.findAtTile(pos)
    return bld ~= nil and under_construction(bld)
end

-- ============================================================================
-- DESIGNATE side (left-drag): let the GAME designate -- it places the first corner on
-- mouse-down (drawing its selection box); we just auto-place the second corner on release.
-- ============================================================================

-- left-drag completion is active only in "box select" (rectangle) mode while a designation
-- tool is up. (In paint mode the game already drags; single clicks need no help.)
local function left_drag_active()
    local mi = df.global.game.main_interface
    return mi.main_designation_doing_rectangles and mi.main_designation_selected ~= MD.NONE
end

-- ============================================================================
-- overlay: watch both mouse buttons
-- ============================================================================

RightClickCancel = defclass(RightClickCancel, overlay.OverlayWidget)
RightClickCancel.ATTRS{
    desc = 'Left-drag to box-designate, right-drag to box-remove, right-click to cancel.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},   -- invisible; onInput/onupdate still see map-wide mouse input
    overlay_onupdate_max_freq_seconds = 0,
}

function RightClickCancel:passthrough(key)
    self.pass = true
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), key)
    self.pass = false
end

local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

function RightClickCancel:overlay_onupdate()
    -- the "a box corner is placed but not completed" tracker is only meaningful while a
    -- rectangle designation tool is up; any other context clears it.
    if not left_drag_active() then self.corner_pending = false end

    -- LEFT button. Normally NOT swallowed -- the game places corner 1 on mouse-down and
    -- renders its selection box; we re-dispatch a click on release to place corner 2.
    local ld = df.global.enabler.mouse_lbut_down
    if ld == 1 and self.lbut ~= 1 then
        -- #5b: a left-press while a right-drag erase is in progress ABORTS the erase and is
        -- consumed (swallowed in onInput) -- it does not also start a designation.
        if self.rpress then
            self.rpress = nil
            self.left_ate_erase = true
        else
            self.left_ate_erase = false
            self.lpress = left_drag_active() and map_pos_if_clear() or nil
        end
    elseif ld ~= 1 and self.lbut == 1 then
        if not self.left_ate_erase then
            local rel = dfhack.gui.getMousePos()
            local was_drag = self.lpress and rel and not same(self.lpress, rel) and left_drag_active()
            if was_drag then
                -- AUTO-REMOVE: if this is a plain Dig box lying entirely on removable-only tiles
                -- (all constructions, or all natural ramps), swap the tool to the matching
                -- removal type so DF applies a REMOVAL box; restore the Dig tool after. Any
                -- diggable tile in the box -> removal_tool_for_box returns nil -> normal dig.
                local mi = df.global.game.main_interface
                local tool = (mi.main_designation_selected == MD.DIG_DIG)
                    and removal_tool_for_box(self.lpress, rel) or nil
                if tool then
                    mi.main_designation_selected = tool
                    self:passthrough('_MOUSE_L')  -- DF applies the removal box (corner 2)
                    mi.main_designation_selected = MD.DIG_DIG
                else
                    self:passthrough('_MOUSE_L')  -- finish the normal dig box (place corner 2)
                end
            end
            -- #5a: track the click-click corner state. A drag completes the box; a plain
            -- click toggles corner1(pending) <-> corner2(complete).
            if left_drag_active() and rel then
                self.corner_pending = (not was_drag) and not self.corner_pending
            else
                self.corner_pending = false
            end
            -- #4: remember the tile where we just ended adding a dig/build job
            if rel and in_cancel_mode() and just_added_at(rel) then
                self.last_add = {pos = rel, ms = dfhack.getTickCount()}
            end
        end
        self.lpress = nil
        self.left_ate_erase = false
    end
    self.lbut = ld

    -- RIGHT button: swallowed in onInput; resolved here on release.
    local rd = df.global.enabler.mouse_rbut_down
    if rd == 1 and self.rbut ~= 1 then
        self.rpress = in_cancel_mode() and map_pos_if_clear() or nil
    elseif rd ~= 1 and self.rbut == 1 then
        if self.rpress then
            local rel = dfhack.gui.getMousePos()
            if rel then
                if same(self.rpress, rel) then
                    if self.corner_pending then
                        -- #5a: a box corner is placed but not completed -> back out just that
                        -- pending placement; do NOT cancel designations under the cursor
                        self.corner_pending = false
                        self:passthrough('_MOUSE_R')
                    elseif self.last_add and same(rel, self.last_add.pos)
                        and dfhack.getTickCount() - self.last_add.ms < 2000 then
                        -- #4: right-click on a just-added tile -> forward (exit the tool)
                        self.last_add = nil
                        self:passthrough('_MOUSE_R')
                    elseif not cancel_at(rel) then
                        self:passthrough('_MOUSE_R')
                    end
                else
                    cancel_box(self.rpress, rel)
                end
            end
        end
        self.rpress = nil
    end
    self.rbut = rd
end

function RightClickCancel:onInput(keys)
    if self.pass then return false end   -- our own re-dispatched click
    -- #5b: while a right-drag erase is in progress, swallow the LEFT button so it cancels
    -- the erase (handled by the poller) instead of starting a designation.
    if keys._MOUSE_L and self.rpress then return true end
    -- only the RIGHT button is otherwise intercepted (resolved on release by the poller).
    -- The LEFT button is left to the game so its native selection box renders. Don't swallow
    -- panel clicks (getMousePos is nil off the map).
    if keys._MOUSE_R and in_cancel_mode() and map_pos_if_clear() then return true end
    return false
end

-- live preview of the box a right-drag will erase: a red X on every tile in the
-- current drag rectangle (only while the right button is held and dragging).
function RightClickCancel:onRenderFrame(dc, rect)
    if not self.rpress or df.global.enabler.mouse_rbut_down ~= 1 then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= self.rpress.z then return end
    local vp = guidm.Viewport.get()
    if vp.z ~= self.rpress.z then return end
    for_box(self.rpress, cur, function(x, y, z)
        local pos = {x = x, y = y, z = z}
        if vp:isVisible(pos) then
            local s = vp:tileToScreen(pos)
            -- map=true -> draw on the graphical map grid (correct scale/position)
            dfhack.screen.paintTile(ERASE_PEN, s.x, s.y, nil, nil, true)
        end
    end)
end

OVERLAY_WIDGETS = {cancel = RightClickCancel}

if not dfhack_flags.module then
    require('plugins.overlay').rescan()
    dfhack.run_command('overlay', 'enable', 'right-click-cancel.cancel')
    print('right-click-cancel: overlay enabled.')
    print('  left-drag = box designate (the game renders the box), left-click = normal click')
    print('  right-drag = box remove, right-click = cancel under cursor')
end
