-- Squad details screen: click a member's portrait to open their sheet instead of the
-- assignment list.
--@module = true
--[[
clickable-squad-members

On the squad details screen (Squads > a squad), every member row carries a portrait to the
side of the name. Clicking it does the same thing as clicking the name: it opens the
position-assignment list, offering to replace the dwarf standing there. That is a reasonable
default for an EMPTY position and a poor one for a filled one -- the portrait is the most
face-like thing on the screen and the last thing that should mean "swap this soldier out".

So a click on the portrait of a FILLED position now opens that dwarf's own detail sheet and
follows them on the map, the same pair of actions `fort/clickable-noble-names` gives a noble
row. Everything else is left exactly as DF has it:

  * the NAME still opens the assignment list -- that is how you replace a soldier, and it
    stays one click away;
  * an EMPTY position has no portrait to click, so "Assign position 4" is untouched;
  * every other click on the screen -- the squad name, Back to squads, the order buttons --
    never reaches this.

MEMBERS ARE MATCHED BY NAME PREFIX, because this screen truncates. The panel is narrow and
DF renders "Ineth Deler..." rather than the whole name, so the row is identified by testing
the visible text as a prefix of each squad member's name, dots stripped. That reads the row
actually under the cursor, which is what makes it survive a scrolled list -- and if nothing
matches, the click goes to DF untouched and you get the old behaviour rather than a wrong
dwarf.

The portrait is found the same way `clickable-noble-names` finds DF's blocks: it is drawn
from four consecutive texture-atlas tiles, so it is located on the spot instead of at a
hardcoded column, at whatever width DF has squeezed the panel to.

Registered automatically as overlay `fort/clickable-squad-members.click`.
]]

local overlay = require('plugins.overlay')

local function squads_panel()
    return df.global.game.main_interface.squads
end

-- the squad whose details are on screen
local function viewing_squad()
    local sq = squads_panel()
    local idx = sq.viewing_squad_index
    if idx < 0 or idx >= #sq.squad_id then return nil end
    return df.squad.find(sq.squad_id[idx])
end

local function position_unit(pos)
    if not pos or pos.occupant < 0 then return nil end
    local hf = df.historical_figure.find(pos.occupant)
    return hf and df.unit.find(hf.unit_id) or nil
end

-- ---- reading the rendered row ------------------------------------------------

local function line_text(y)
    local w = dfhack.screen.getWindowSize()
    local out = {}
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return table.concat(out)
end

-- every 4-wide block of consecutive atlas tiles on this line: the member portraits
local function tile_blocks(y)
    local w = dfhack.screen.getWindowSize()
    local blocks, run_start, prev = {}, nil, nil
    local function close(at)
        if run_start and at - run_start == 4 then
            blocks[#blocks + 1] = {x1 = run_start, x2 = at - 1}
        end
    end
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        local t = p and p.tile
        if t and prev and t == prev + 1 then
            -- still inside a run
        else
            close(x)
            run_start = t and x or nil
        end
        prev = t
    end
    close(w)
    return blocks
end

-- the squad member whose name DF drew on this line, or nil. The name is truncated to fit
-- ("Ineth Deler..."), so the drawn text is tested as a PREFIX of each member's real name.
local function member_on_line(y)
    local squad = viewing_squad()
    if not squad then return nil end
    local text = line_text(y):gsub('%s+$', ''):gsub('^%s+', '')
    local prefix = text:gsub('%.+$', '')
    if #prefix < 3 then return nil end             -- too little to identify anyone by
    for _, pos in ipairs(squad.positions) do
        local unit = position_unit(pos)
        if unit then
            local name = dfhack.translation.translateName(dfhack.units.getVisibleName(unit))
            if #name > 0 and name:sub(1, #prefix) == prefix then return unit end
        end
    end
end

-- a member row is three lines tall with the name in the middle, and the portrait is drawn
-- down all three -- the same shape the Nobles screen uses
local function row_at(y)
    for _, name_y in ipairs({y, y - 1, y + 1}) do
        local unit = member_on_line(name_y)
        if unit then return unit, name_y end
    end
end

-- is the click on the portrait? The name line carries exactly one 4-wide tile block, the
-- portrait itself; the name is plain text and the rest of the row is flat background.
local function on_portrait(x, name_y)
    for _, b in ipairs(tile_blocks(name_y)) do
        if x >= b.x1 and x <= b.x2 then return true end
    end
    return false
end

-- ---- the action --------------------------------------------------------------

-- Opened on a later frame, for the reason `clickable-noble-names` documents: the reveal
-- tears a unit sheet down, and it runs after this handler. Overlay updates keep ticking
-- with a panel up, where frame timers do not.
pending_sheet_id = pending_sheet_id or nil

local function goto_member(unit)
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if pos and pos.x >= 0 then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
        df.global.plotinfo.follow_item = -1
        df.global.plotinfo.follow_unit = unit.id
    end
    pending_sheet_id = unit.id                     -- off-map (raiding, say): sheet only
end

-- ---- overlays ----------------------------------------------------------------

SquadMemberClickOverlay = defclass(SquadMemberClickOverlay, overlay.OverlayWidget)
SquadMemberClickOverlay.ATTRS{
    desc = 'Squad details: click a member\'s portrait to open their sheet instead of the assignment list.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},          -- draws nothing; onInput sees the whole screen anyway
    version = 1,
}

function SquadMemberClickOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end

    local unit, name_y = row_at(y)
    if not unit or not on_portrait(x, name_y) then return false end

    goto_member(unit)
    return true
end

-- the deferred half, on plain `dwarfmode` so it still runs once the click is over
PendingSheetOverlay = defclass(PendingSheetOverlay, overlay.OverlayWidget)
PendingSheetOverlay.ATTRS{
    desc = 'Opens the unit sheet a click on a squad member\'s portrait asked for.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function PendingSheetOverlay:overlay_onupdate()
    local id = pending_sheet_id
    if not id then return end
    pending_sheet_id = nil
    local unit = df.unit.find(id)
    if not unit then return end
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    vs.open = true
end

OVERLAY_WIDGETS = {click = SquadMemberClickOverlay, sheet = PendingSheetOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('clickable-squad-members: registered overlay fort/clickable-squad-members.click')
print('  on a squad\'s details screen, click a member\'s portrait to open their sheet;')
print('  the name still opens DF\'s position-assignment list.')
