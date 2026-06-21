-- Auto-open a statue's item sheet (which shows DF's full description) + a Remove button.
--@module = true
--@enable = true
--[[
When you select a statue, this redirects you straight to the statue ITEM's sheet,
where DF natively shows the full prose description -- no custom UI popping in/out.
Press the native "View" button to go back to the statue building.

It also adds a "Remove" button on any built item's sheet (below "View") that
deconstructs the building the item belongs to.

    enable statue-redirect      turn the auto-redirect on (persists with the fort)
    disable statue-redirect     turn it off
    statue-redirect             toggle

The Remove-button overlay (statue-redirect.remove) is always available; reposition
it with gui/overlay.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'statue-redirect'

local function vsheets()
    return df.global.game.main_interface.view_sheets
end

-- ---------------------------------------------------------------------------
-- auto-redirect (frame loop, so it can see the BUILDING<->ITEM transitions)
-- ---------------------------------------------------------------------------

enabled = enabled or false
generation = generation or 0

function isEnabled()
    return enabled
end

local prev_sheet, prev_id

local function statue_item_of(bld_id)
    local b = df.building.find(bld_id)
    if not b or b:getType() ~= df.building_type.Statue then return end
    for i = 0, #b.contained_items - 1 do
        local it = b.contained_items[i].item
        if it:getType() == df.item_type.STATUE then return it end
    end
end

local function tick(gen)
    if not enabled or gen ~= generation then return end
    if dfhack.world.isFortressMode() then
        local vs = vsheets()
        local sheet = vs.open and vs.active_sheet or -1
        local id = vs.active_id
        if vs.open and sheet == df.view_sheet_type.BUILDING then
            local it = statue_item_of(id)
            if it then
                -- redirect on a FRESH statue selection, but not when the player
                -- just pressed "View" to come back here (prev sheet was ITEM),
                -- nor while they linger on the same statue
                local from_item = prev_sheet == df.view_sheet_type.ITEM
                local same = prev_sheet == df.view_sheet_type.BUILDING and prev_id == id
                if not from_item and not same then
                    vs.active_sheet = df.view_sheet_type.ITEM
                    vs.active_id = it.id
                    vs.viewing_itid:resize(0)
                    vs.viewing_itid:insert('#', it.id)
                end
            end
        end
        prev_sheet, prev_id = sheet, id   -- record what we OBSERVED (pre-redirect)
    else
        prev_sheet, prev_id = nil, nil
    end
    dfhack.timeout(1, 'frames', function() tick(gen) end)
end

local function start()
    if enabled then return end
    enabled = true
    generation = generation + 1
    prev_sheet, prev_id = nil, nil
    tick(generation)
end

local function stop()
    enabled = false
    generation = generation + 1
end

local function persist()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = enabled})
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

-- ---------------------------------------------------------------------------
-- Remove button on a built item's sheet
-- ---------------------------------------------------------------------------

-- the building that holds the currently-viewed item, if any
local function viewed_building()
    local vs = vsheets()
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.ITEM then return end
    local it = df.item.find(vs.active_id)
    if not it then return end
    for i = 0, #it.general_refs - 1 do
        local r = it.general_refs[i]
        if r:getType() == df.general_ref_type.BUILDING_HOLDER then
            return df.building.find(r.building_id)
        end
    end
end

RemoveOverlay = defclass(RemoveOverlay, overlay.OverlayWidget)
RemoveOverlay.ATTRS{
    desc = 'Adds a Remove (deconstruct) button on a built item sheet.',
    default_pos = {x = -48, y = 9},   -- top-right area
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/ITEM',
    frame = {w = 8, h = 1},
    version = 1,
    overlay_onupdate_max_freq_seconds = 0,
}

function RemoveOverlay:init()
    self:addviews{
        widgets.TextButton{
            view_id = 'btn',
            frame = {t = 0, l = 0, w = 8, h = 1},
            label = 'Remove',
            on_activate = self:callback('do_remove'),
        },
    }
end

function RemoveOverlay:do_remove()
    local b = viewed_building()
    if b then dfhack.buildings.deconstruct(b) end
end

function RemoveOverlay:overlay_onupdate()
    self.visible = viewed_building() ~= nil
end

OVERLAY_WIDGETS = {remove = RemoveOverlay}

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if dfhack_flags.enable_state then start() else stop() end
else
    if enabled then stop() else start() end
end
persist()
require('plugins.overlay').rescan()
print('statue-redirect: auto-redirect ' .. (enabled and 'ON' or 'OFF')
    .. '; Remove button overlay registered')
