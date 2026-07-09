-- Left-hand building picker: while the Dig tool is active, click a building to place it.
--@module = true
--[[
Companion to dig-shapes. While NORMAL MINING MODE is active (the Dig tool selected,
main_designation_selected == DIG_DIG) on dwarfmode/Default, a picker window docks on the LEFT
listing every buildable thing -- workshops, furnaces, constructions, doors/hatches/grates/bars,
trade depot, well, farm plot, military buildings, traps, cages/chains, machines, siege engines,
and all furniture.

Clicking an entry drops the Dig tool and enters that building's PLACEMENT action (buildingplan
mode -- materials reserved per your buildingplan filters; click to place; build-more on). This is
driven by simulating the building's native interface key (HOTKEY_BUILDING_*), so it goes through
DF's own placement flow.

  * EXCEPTION -- SLAB: instead of buildingplan it should ask which specific slab item to use, with
    build-more always on. (The native slab flow already prompts for the slab; the buildingplan /
    build-more specifics are being verified live -- see TODO below.)

Layout: two columns, vertically SCROLLABLE when the list overflows. The window leaves 10 rows of
negative space at the TOP and 4 rows at the BOTTOM uncovered.

Registered automatically as overlay `dig-building.picker`. Reposition with `gui/overlay`.

TODO (needs live click-testing after the crash-restart):
  * confirm simulate-key placement path (whether A_BUILDING must be fed first).
  * slab: custom "which slab item" chooser + force build-more, no buildingplan.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local function mi() return df.global.game.main_interface end
local TOP_MARGIN, BOT_MARGIN = 10, 4      -- rows of negative space kept clear, top / bottom
local WIN_W = 34                          -- window width; two columns inside
local COL_W = 16                          -- each column's text width

-- Every buildable thing, in display order, as {label, key}. `key` is the DF interface key that
-- selects that building directly (verified present in df.interface_key on this build). `slab=true`
-- marks the special-cased slab entry.
local BUILDINGS = {
    -- workshops
    {'Carpenter',    'HOTKEY_BUILDING_WORKSHOP_CARPENTER'},
    {'Mason',        'HOTKEY_BUILDING_WORKSHOP_MASON'},
    {'Craftsdwarf',  'HOTKEY_BUILDING_WORKSHOP_CRAFTSMAN'},
    {'Jeweler',      'HOTKEY_BUILDING_WORKSHOP_JEWELER'},
    {'Metalsmith',   'HOTKEY_BUILDING_WORKSHOP_METALSMITH'},
    {'Mechanic',     'HOTKEY_BUILDING_WORKSHOP_MECHANIC'},
    {'Siege wksp',   'HOTKEY_BUILDING_WORKSHOP_SIEGE'},
    {'Bowyer',       'HOTKEY_BUILDING_WORKSHOP_BOWYER'},
    {'Butcher',      'HOTKEY_BUILDING_WORKSHOP_BUTCHER'},
    {'Tanner',       'HOTKEY_BUILDING_WORKSHOP_TANNER'},
    {'Leatherworks', 'HOTKEY_BUILDING_WORKSHOP_LEATHER'},
    {'Clothier',     'HOTKEY_BUILDING_WORKSHOP_CLOTHES'},
    {'Dyer',         'HOTKEY_BUILDING_WORKSHOP_DYER'},
    {'Fishery',      'HOTKEY_BUILDING_WORKSHOP_FISHERY'},
    {'Still',        'HOTKEY_BUILDING_WORKSHOP_STILL'},
    {'Kitchen',      'HOTKEY_BUILDING_WORKSHOP_KITCHEN'},
    {'Farmer',       'HOTKEY_BUILDING_WORKSHOP_FARMER'},
    {'Quern',        'HOTKEY_BUILDING_WORKSHOP_QUERN'},
    {'Millstone',    'HOTKEY_BUILDING_WORKSHOP_MILLSTONE'},
    {'Magma mill',   'HOTKEY_BUILDING_WORKSHOP_LAVAMILL'},
    {'Loom',         'HOTKEY_BUILDING_WORKSHOP_LOOM'},
    {'Ashery',       'HOTKEY_BUILDING_WORKSHOP_ASHERY'},
    {'Kennel',       'HOTKEY_BUILDING_KENNEL'},
    -- furnaces
    {'Wood furnace', 'HOTKEY_BUILDING_FURNACE_WOOD'},
    {'Smelter',      'HOTKEY_BUILDING_FURNACE_SMELTER'},
    {'Glass furnace','HOTKEY_BUILDING_FURNACE_GLASS'},
    {'Kiln',         'HOTKEY_BUILDING_FURNACE_KILN'},
    {'Magma smelter','HOTKEY_BUILDING_FURNACE_SMELTER_LAVA'},
    {'Magma glass',  'HOTKEY_BUILDING_FURNACE_GLASS_LAVA'},
    {'Magma kiln',   'HOTKEY_BUILDING_FURNACE_KILN_LAVA'},
    -- constructions
    {'Wall',         'HOTKEY_BUILDING_CONSTRUCTION_WALL'},
    {'Floor',        'HOTKEY_BUILDING_CONSTRUCTION_FLOOR'},
    {'Ramp',         'HOTKEY_BUILDING_CONSTRUCTION_RAMP'},
    {'Stairs',       'HOTKEY_BUILDING_CONSTRUCTION_STAIR_UPDOWN'},
    {'Fortificatn',  'HOTKEY_BUILDING_CONSTRUCTION_FORTIFICATION'},
    {'Track',        'HOTKEY_BUILDING_CONSTRUCTION_TRACK'},
    {'Track stop',   'HOTKEY_BUILDING_CONSTRUCTION_TRACK_STOP'},
    -- doors / portals / windows
    {'Door',         'HOTKEY_BUILDING_DOOR'},
    {'Floodgate',    'HOTKEY_BUILDING_FLOODGATE'},
    {'Hatch',        'HOTKEY_BUILDING_HATCH'},
    {'Wall grate',   'HOTKEY_BUILDING_GRATE_WALL'},
    {'Floor grate',  'HOTKEY_BUILDING_GRATE_FLOOR'},
    {'Vert bars',    'HOTKEY_BUILDING_BARS_VERTICAL'},
    {'Floor bars',   'HOTKEY_BUILDING_BARS_FLOOR'},
    {'Glass window', 'HOTKEY_BUILDING_WINDOW_GLASS'},
    {'Gem window',   'HOTKEY_BUILDING_WINDOW_GEM'},
    {'Bridge',       'HOTKEY_BUILDING_BRIDGE'},
    -- furniture
    {'Bed',          'HOTKEY_BUILDING_BED'},
    {'Chair',        'HOTKEY_BUILDING_CHAIR'},
    {'Table',        'HOTKEY_BUILDING_TABLE'},
    {'Coffin',       'HOTKEY_BUILDING_COFFIN'},
    {'Cabinet',      'HOTKEY_BUILDING_CABINET'},
    {'Chest',        'HOTKEY_BUILDING_BOX'},
    {'Statue',       'HOTKEY_BUILDING_STATUE'},
    {'Armor stand',  'HOTKEY_BUILDING_ARMORSTAND'},
    {'Weapon rack',  'HOTKEY_BUILDING_WEAPONRACK'},
    {'Slab',         'HOTKEY_BUILDING_SLAB', slab = true},
    {'Nest box',     'HOTKEY_BUILDING_NEST_BOX'},
    {'Bookcase',     'HOTKEY_BUILDING_BOOKCASE'},
    {'Hive',         'HOTKEY_BUILDING_HIVE'},
    {'Display case', 'HOTKEY_BUILDING_DISPLAY_FURNITURE'},
    {'Offering',     'HOTKEY_BUILDING_OFFERING_PLACE'},
    {'Traction bed', 'HOTKEY_BUILDING_TRACTION_BENCH'},
    -- structures / zones-of-work
    {'Well',         'HOTKEY_BUILDING_WELL'},
    {'Farm plot',    'HOTKEY_BUILDING_FARMPLOT'},
    {'Trade depot',  'HOTKEY_BUILDING_TRADEDEPOT'},
    {'Support',      'HOTKEY_BUILDING_SUPPORT'},
    {'Archery targ', 'HOTKEY_BUILDING_ARCHERYTARGET'},
    {'Dirt road',    'HOTKEY_BUILDING_ROAD_DIRT'},
    {'Paved road',   'HOTKEY_BUILDING_ROAD_PAVED'},
    -- cages / chains / animals
    {'Cage',         'HOTKEY_BUILDING_CAGE'},
    {'Restraint',    'HOTKEY_BUILDING_CHAIN'},
    {'Animal trap',  'HOTKEY_BUILDING_ANIMALTRAP'},
    -- machines
    {'Screw pump',   'HOTKEY_BUILDING_MACHINE_SCREW_PUMP'},
    {'Water wheel',  'HOTKEY_BUILDING_MACHINE_WATER_WHEEL'},
    {'Windmill',     'HOTKEY_BUILDING_MACHINE_WINDMILL'},
    {'Gear assembly','HOTKEY_BUILDING_MACHINE_GEAR_ASSEMBLY'},
    {'Vert axle',    'HOTKEY_BUILDING_MACHINE_AXLE_VERTICAL'},
    {'Horiz axle',   'HOTKEY_BUILDING_MACHINE_AXLE_HORIZONTAL'},
    {'Rollers',      'HOTKEY_BUILDING_MACHINE_ROLLERS'},
    -- siege engines
    {'Ballista',     'HOTKEY_BUILDING_SIEGEENGINE_BALLISTA'},
    {'Catapult',     'HOTKEY_BUILDING_SIEGEENGINE_CATAPULT'},
    -- traps
    {'Lever',        'HOTKEY_BUILDING_TRAP_LEVER'},
    {'Pressure plt', 'HOTKEY_BUILDING_TRAP_TRIGGER'},
    {'Cage trap',    'HOTKEY_BUILDING_TRAP_CAGE'},
    {'Stonefall',    'HOTKEY_BUILDING_TRAP_STONE'},
    {'Weapon trap',  'HOTKEY_BUILDING_TRAP_WEAPON'},
    {'Spike trap',   'HOTKEY_BUILDING_TRAP_SPIKE'},
    {'Instrument',   'HOTKEY_BUILDING_INSTRUMENT'},
}

-- keep only entries whose interface key actually exists on this build (defensive against
-- version drift -- a missing key would otherwise silently do nothing on click)
local ENTRIES = {}
for _, e in ipairs(BUILDINGS) do
    if df.interface_key[e[2]] ~= nil then
        ENTRIES[#ENTRIES + 1] = {label = e[1], key = e[2], slab = e.slab}
    end
end

-- ---- placement trigger -------------------------------------------------------

-- select a building for placement by feeding its native interface key. The key is fed from a
-- 1-frame timeout (NOT synchronously in onInput) so it lands inside DF's own frame loop -- the
-- proven pattern dwarf-rts uses to (re)open the squads panel; a synchronous/out-of-loop feed
-- doesn't drive the building interface.
local function start_placement(entry)
    -- drop the Dig tool so we're not mining and placing at once
    mi().main_designation_selected = df.main_designation_type.NONE
    dfhack.timeout(1, 'frames', function()
        local scr = dfhack.gui.getDFViewscreen(true)
        -- open the build interface, then jump to the specific building (its key enters placement)
        gui.simulateInput(scr, 'A_BUILDING')
        gui.simulateInput(scr, entry.key)
    end)
    -- NOTE (slab): the native slab flow prompts for the specific slab itself; forcing build-more
    -- and bypassing buildingplan for slabs is a live-test TODO.
end

-- ---- overlay -----------------------------------------------------------------

DigBuilding = defclass(DigBuilding, overlay.OverlayWidget)
DigBuilding.ATTRS{
    desc = 'While the Dig tool is active, a left-hand picker to place any building.',
    default_pos = {x = 1, y = TOP_MARGIN + 1},   -- left edge; 10 rows of clear space above
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = WIN_W, h = 10},                  -- h is recomputed each update (full height - margins)
    overlay_onupdate_max_freq_seconds = 0,
}

local function dig_active()
    return mi().main_designation_selected == df.main_designation_type.DIG_DIG
end

function DigBuilding:init()
    self.scroll = 0
end

-- rows available for the list = window height (no border; we draw our own title row)
function DigBuilding:list_rows()
    return math.max(1, self.frame.h - 1)   -- minus 1 for the title row
end

function DigBuilding:max_scroll()
    local lines = math.ceil(#ENTRIES / 2)
    return math.max(0, lines - self:list_rows())
end

function DigBuilding:overlay_onupdate()
    self.visible = dig_active()
    -- full height minus the top and bottom negative-space margins
    local h = df.global.gps.dimy - TOP_MARGIN - BOT_MARGIN
    if h ~= self.frame.h then self.frame.h = h end
    if self.scroll > self:max_scroll() then self.scroll = self:max_scroll() end
end

function DigBuilding:onRenderBody(dc)
    if not self.visible then return end
    local rows = self:list_rows()
    local ms = self:max_scroll()
    -- title row with scroll affordances
    dc:seek(0, 0):pen(COLOR_GREY):string('Build')
    if ms > 0 then
        dc:seek(WIN_W - 6, 0):pen(self.scroll > 0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(WIN_W - 1, 0):pen(self.scroll < ms and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('+')
    end
    -- two-column list
    for r = 0, rows - 1 do
        local line = self.scroll + r
        for c = 0, 1 do
            local idx = line * 2 + c + 1
            local e = ENTRIES[idx]
            if e then
                dc:seek(c * COL_W, r + 1):pen(e.slab and COLOR_YELLOW or COLOR_WHITE)
                    :string(e.label:sub(1, COL_W - 1))
            end
        end
    end
end

-- map a local (x,y) inside the body to an entry, or nil
function DigBuilding:entry_at(x, y)
    if y < 1 then return nil end                    -- title row
    local r = y - 1
    if r >= self:list_rows() then return nil end
    local c = (x >= COL_W) and 1 or 0
    local idx = (self.scroll + r) * 2 + c + 1
    return ENTRIES[idx]
end

function DigBuilding:onInput(keys)
    if not self.visible then return false end
    -- mouse wheel scrolls the list
    if keys.CONTEXT_SCROLL_UP then self.scroll = math.max(0, self.scroll - 1); return true end
    if keys.CONTEXT_SCROLL_DOWN then self.scroll = math.min(self:max_scroll(), self.scroll + 1); return true end

    if keys._MOUSE_L then
        local x, y = self:getMousePos()
        if not x then return false end              -- click outside the window: let it pass through
        -- title-row scroll buttons
        if y == 0 then
            if x >= WIN_W - 6 and x <= WIN_W - 2 then self.scroll = math.max(0, self.scroll - 1)
            elseif x >= WIN_W - 1 then self.scroll = math.min(self:max_scroll(), self.scroll + 1) end
            return true
        end
        local e = self:entry_at(x, y)
        if e then start_placement(e) end
        return true                                 -- consume any click within the window
    end
    return false
end

OVERLAY_WIDGETS = {picker = DigBuilding}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dig-building: left-hand building picker (active while the Dig tool is selected).')
