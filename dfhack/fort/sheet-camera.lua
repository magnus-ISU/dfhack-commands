-- Press DF's own "follow this creature" button on an open unit sheet.
--@module = true
--[[
fort/sheet-camera

A unit sheet covers the right half of the map. DFHack's revealInDwarfmodeMap centres a
tile on the WHOLE viewport, which puts the unit under the sheet's edge; DF's own camera
button on the sheet (hover FOLLOW_UNIT, "Set the camera to follow this creature") centres
it in the part of the map the sheet leaves visible, and follows it. Rather than copy DF's
layout arithmetic -- which changes with window size and interface scale -- this presses
that button, so the camera lands exactly where DF would put it on any screen.

The button is graphics-only (no text to search for), drawn on the right-anchored sheet at
a fixed offset from the screen's right edge: measured at interface cell (dimx - 41, 6).
Feeding the click takes two frames after the sheet opens: one for DF to lay the sheet out
and read the parked cursor, one to confirm through DF's own hover target (current_hover ==
FOLLOW_UNIT) that the cell really is that button before pressing -- so a layout where it is
not gets no click at all. Whether it worked is read back from plotinfo.follow_unit -- the
button sets it, nothing else here does. If the press did not land, the fallback is a plain
follow, which at least keeps the unit tracked.

    local cam = reqscript('fort/sheet-camera')
    cam.request(unit)      -- right after vs.open = true
    ...
    cam.tick()             -- from an overlay_onupdate; a no-op when nothing is pending
]]

local gui = require('gui')

local BUTTON_FROM_RIGHT, BUTTON_Y = 41, 6

-- one request at a time: {id = unit id, stage = frames since the request}
local pending = nil

function request(unit)
    pending = {id = unit.id, stage = 0}
end

local function sheet_shows(id)
    local vs = df.global.game.main_interface.view_sheets
    return vs.open and vs.active_sheet == df.view_sheet_type.UNIT and vs.active_id == id
end

function tick()
    if not pending then return end
    local p = pending
    p.stage = p.stage + 1
    if not sheet_shows(p.id) then pending = nil; return end     -- closed under us
    local gps, mi = df.global.gps, df.global.game.main_interface
    if p.stage == 1 then
        -- the sheet was opened last frame and is laid out now: park DF's cursor on the button.
        -- DF keeps a written cursor cell until the real mouse moves, and reads its hover
        -- target from it on the next frame -- which is the check before pressing.
        gps.mouse_x, gps.mouse_y = gps.dimx - BUTTON_FROM_RIGHT, BUTTON_Y
    elseif p.stage == 2 then
        -- press ONLY if DF itself says that cell is the follow button. On a layout where it
        -- is something else (the header also holds "expel this creature") no click is fed.
        if mi.current_hover == df.main_hover_instruction.FOLLOW_UNIT then
            gui.simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
        end
    elseif p.stage >= 3 then
        if df.global.plotinfo.follow_unit ~= p.id then
            -- the press did not land (or was not attempted): follow anyway, so the unit is
            -- at least tracked
            df.global.plotinfo.follow_item = -1
            df.global.plotinfo.follow_unit = p.id
        end
        pending = nil
    end
end
