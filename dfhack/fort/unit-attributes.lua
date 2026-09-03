-- Unit sheet: an [Attributes] button on the Other Skills tab, and the panel it opens.
--@module = true
--[[
fort/unit-attributes

DF's unit sheet lists every skill and never once tells you the attributes underneath
them -- whether this legendary weaponsmith is also strong, whether the marksdwarf can
see straight. This adds an **[Attributes]** button to the unit sheet's *Other Skills*
tab, sitting directly above the Progress Bar / Experience toggles, and it opens all
nineteen attributes in one modal panel.

Each row reads:

    Strength                 2937 / 3100   +4  exceptional

    * the CURRENT value and, after the slash, the highest this dwarf can ever reach --
      the cap is the interesting half of a young dwarf's numbers;
    * the TIER, which is how far the value sits from the median for this creature's
      own caste, in DF's own steps of 250 points: +1 is one step above a typical
      dwarf, -2 two steps below. Dwarves are not humans and a "good" number depends
      on the species, so the comparison is always against the caste's own raws
      (`phys_att_range` / `ment_att_range`, whose fourth entry is the median).

The word beside the tier is this tool's own plain ladder, not DF's prose: DF has a
different set of adjectives for every attribute ("mighty", "clumsy", "a questionable
spatial sense") and those strings are not in the raws or exposed anywhere DFHack can
read them, so inventing them from memory would mean quietly making some of them up.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- DF's own step: assign-attributes documents tiers as 250 points apart, measured from
-- the caste median, and clamped to four steps either way.
local TIER_STEP = 250
local TIER_MAX = 4

-- Plainly this tool's words, not DF's. Indexed by tier.
local TIER_WORD = {
    [4] = 'exceptional', [3] = 'superior',  [2] = 'strong',   [1] = 'above average',
    [0] = 'average',
    [-1] = 'below average', [-2] = 'weak', [-3] = 'poor', [-4] = 'dismal',
}

local function title_case(token)
    return (token:lower():gsub('_', ' '):gsub('^%l', string.upper))
end

-- ---------------------------------------------------------------------------
-- the numbers
-- ---------------------------------------------------------------------------

local function caste_of(unit)
    local cr = df.creature_raw.find(unit.race)
    return cr and cr.caste[unit.caste] or nil
end

-- The median for this creature's caste: the fourth of the seven numbers in the raws'
-- PHYS_ATT_RANGE / MENT_ATT_RANGE token. A creature with no token of its own uses the
-- standard 1000, which is what DF assumes too.
local DEFAULT_MEDIAN = 1000

local function median_of(unit, kind, token)
    local median = DEFAULT_MEDIAN
    pcall(function()
        local attrs = caste_of(unit).attributes
        local range = (kind == 'physical') and attrs.phys_att_range or attrs.ment_att_range
        median = range[token][3]
    end)
    return median
end

local function tier_of(value, median)
    local tier = math.floor((value - median) / TIER_STEP + 0.5)
    return math.max(-TIER_MAX, math.min(TIER_MAX, tier))
end

-- one row per attribute: name, current value, personal cap, tier
-- `pcall` IS NOT A GUARD HERE. dfhack.units.getPhysicalAttrValue takes a df::unit* straight
-- through to C++, which dereferences it without checking: called with nil it segfaults, and
-- a segfault is not an error pcall can catch -- DF is simply gone. So the unit is checked
-- once, here, before any of it runs.
local function read_attrs(unit, kind)
    if not unit or not df.unit:is_instance(unit) then return {} end
    local enum = (kind == 'physical') and df.physical_attribute_type or df.mental_attribute_type
    local get = (kind == 'physical') and dfhack.units.getPhysicalAttrValue
                                      or dfhack.units.getMentalAttrValue
    local rows = {}
    for idx, token in ipairs(enum) do
        local raw, cap
        pcall(function()
            local store = (kind == 'physical') and unit.body.physical_attrs
                                                or unit.status.current_soul.mental_attrs
            raw = store[token].value
            cap = store[token].max_value
        end)
        -- the EFFECTIVE value, which is what the dwarf actually works with: syndromes
        -- and the like move it away from the stored number
        local value = raw
        pcall(function() value = get(unit, idx) end)
        if value then
            local median = median_of(unit, kind, token)
            rows[#rows + 1] = {
                name = title_case(token),
                value = value,
                cap = cap,
                tier = tier_of(value, median),
                median = median,
            }
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- the panel
-- ---------------------------------------------------------------------------

local NAME_W = 22

local function tier_pen(tier)
    if tier > 1 then return COLOR_LIGHTGREEN end
    if tier > 0 then return COLOR_GREEN end
    if tier < -1 then return COLOR_LIGHTRED end
    if tier < 0 then return COLOR_RED end
    return COLOR_GREY
end

Attributes = defclass(Attributes, widgets.Window)
Attributes.ATTRS{
    frame_title = 'Attributes',
    -- tall enough for the lot without scrolling: 6 physical + 13 mental, their two headings
    -- and the blank between them, plus the two header lines, the footer and the frame; and
    -- wide enough for the longest row -- "Disease Resistance" is 18 characters before the
    -- value/cap pair and the tier word, and a dwarf's readable name is longer than any of it
    frame = {w = 74, h = 30},
    resizable = true,
    unit = DEFAULT_NIL,
}

function Attributes:init()
    local choices = {}
    if not self.unit or not df.unit:is_instance(self.unit) then
        self:addviews{widgets.Label{frame = {t = 0, l = 0}, text = 'No unit.'}}
        return
    end
    local function heading(text)
        choices[#choices + 1] = {text = {{text = text, pen = COLOR_LIGHTCYAN}}}
    end
    local function rows(kind)
        for _, r in ipairs(read_attrs(self.unit, kind)) do
            local cap = r.cap and ('%5d / %-5d'):format(r.value, r.cap) or ('%5d'):format(r.value)
            choices[#choices + 1] = {text = {
                {text = ('  %s %s  '):format(r.name .. (' '):rep(math.max(0, NAME_W - #r.name)), cap)},
                {text = ('%+d %s'):format(r.tier, TIER_WORD[r.tier] or ''), pen = tier_pen(r.tier)},
            }}
        end
    end
    heading('Physical')
    rows('physical')
    choices[#choices + 1] = {text = ''}
    heading('Mental')
    rows('mental')

    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = dfhack.units.getReadableName(self.unit),
        },
        widgets.Label{
            frame = {t = 1, l = 0},
            text = ('%s%s'):format((' '):rep(NAME_W + 2), 'value / cap   vs. caste median'),
            text_pen = COLOR_GREY,
        },
        widgets.List{frame = {t = 3, l = 0, r = 0, b = 2}, choices = choices},
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {
                'The tier is distance from this caste\'s median attribute, in DF\'s',
                NEWLINE,
                'own steps of 250. Esc closes.',
            },
            text_pen = COLOR_GREY,
        },
    }
end

AttributesScreen = defclass(AttributesScreen, gui.ZScreenModal)
-- `unit` MUST be declared here. An attribute the class does not declare is not carried
-- through the constructor, so it arrives nil in init -- and a nil unit handed to
-- Units::getPhysicalAttrValue below dereferences null in C++ and takes DF down with it.
AttributesScreen.ATTRS{
    focus_path = 'unit-attributes',
    unit = DEFAULT_NIL,
}
function AttributesScreen:init() self:addviews{Attributes{unit = self.unit}} end
function AttributesScreen:onDismiss() view = nil end

view = view or nil

-- ---------------------------------------------------------------------------
-- the button
-- ---------------------------------------------------------------------------

-- the unit whose sheet is on screen
local function sheet_unit()
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.UNIT then return nil end
    local unit = df.unit.find(vs.active_id)
    if not unit or not df.unit:is_instance(unit) then return nil end
    return unit
end

AttributesOverlay = defclass(AttributesOverlay, overlay.OverlayWidget)
AttributesOverlay.ATTRS{
    desc = 'Adds an [Attributes] button to the unit sheet\'s Other Skills tab.',
    -- one row above the stock Progress Bar / Experience banner, which sits at the
    -- bottom of internal/unit-info-viewer/skills-progress's own frame
    default_pos = {x = -43, y = -6},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT/Skills/Other',
    frame = {w = 54, h = 1},
}

function AttributesOverlay:init()
    self:addviews{
        widgets.TextButton{
            frame = {t = 0, l = 1, w = 20},
            label = 'Attributes',
            key = 'CUSTOM_CTRL_A',
            on_activate = function() self:open() end,
        },
    }
end

function AttributesOverlay:open()
    local unit = sheet_unit()
    if not unit then return end
    if view then view:dismiss() end
    view = AttributesScreen{unit = unit}:show()
end

OVERLAY_WIDGETS = {button = AttributesOverlay}

if dfhack_flags and dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('unit-attributes: registered overlay fort/unit-attributes.button')
print('  open a unit sheet, Skills > Other skills, and click [Attributes] (Ctrl-A).')
