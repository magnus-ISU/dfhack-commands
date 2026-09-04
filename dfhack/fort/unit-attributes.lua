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
                token = token,
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


-- ---------------------------------------------------------------------------
-- what trains an attribute
-- ---------------------------------------------------------------------------
--
-- NOT READABLE FROM THE GAME. `df.job_skill.attrs` carries a caption, a labor and a
-- profession and nothing else -- which skill exercises which attribute is hardcoded inside
-- DF and never exposed, so there is no honest way to compute this list. It is transcribed
-- from the Dwarf Fortress wiki's Attribute page instead, and it is worth knowing that is
-- where it comes from: it is documentation, not data, and it can be out of date in a way the
-- rest of this panel cannot.
--
-- Names are the wiki's, which are DF's own profession words rather than skill tokens -- what
-- you would look for in the labor list.
local TRAINS = {
    STRENGTH = {'Miner', 'Carpenter', 'Wood cutter', 'Mason', 'Bone doctor', 'Beekeeper',
        'Brewer', 'Cheese maker', 'Dyer', 'Grower', 'Lye maker', 'Milker', 'Miller',
        'Potash maker', 'Presser', 'Soaper', 'Spinner', 'Thresher', 'Wood burner',
        'Fisherdwarf', 'Armorsmith', 'Furnace operator', 'Metal crafter', 'Metalsmith',
        'Weaponsmith', 'Glassmaker', 'Leatherworker', 'Strand extractor', 'Mechanic',
        'Pump operator', 'Siege engineer', 'Siege operator', 'Papermaker', 'Swimmer',
        'All combat skills except Dodger'},
    AGILITY = {'Bowyer', 'Carpenter', 'Wood cutter', 'Engraver', 'Mason', 'Animal caretaker',
        'Animal trainer', 'Trapper', 'Bone doctor', 'Crutch-walker', 'Surgeon', 'Suturer',
        'Wound dresser', 'Beekeeper', 'Brewer', 'Butcher', 'Cheese maker', 'Cook', 'Dyer',
        'Grower', 'Herbalist', 'Milker', 'Miller', 'Presser', 'Spinner', 'Tanner', 'Thresher',
        'Fish cleaner', 'Fish dissector', 'Fisherdwarf', 'Armorsmith', 'Metal crafter',
        'Metalsmith', 'Weaponsmith', 'Gem cutter', 'Gem setter', 'Bone carver', 'Clothier',
        'Glassmaker', 'Glazer', 'Leatherworker', 'Potter', 'Stone crafter', 'Wood crafter',
        'Wax worker', 'Strand extractor', 'Mechanic', 'Siege engineer', 'Papermaker',
        'Bookbinder', 'Swimmer', 'Comedian', 'Intimidator', 'Student',
        'All combat skills except Biter and Armor user'},
    TOUGHNESS = {'Miner', 'Animal trainer', 'Lye maker', 'Potash maker', 'Soaper',
        'Wood burner', 'Furnace operator', 'Pump operator', 'Siege operator',
        'All close combat skills'},
    ENDURANCE = {'Miner', 'Wood cutter', 'Mason', 'Animal trainer', 'Crutch-walker',
        'Beekeeper', 'Butcher', 'Cheese maker', 'Dyer', 'Grower', 'Lye maker', 'Milker',
        'Miller', 'Potash maker', 'Presser', 'Soaper', 'Spinner', 'Thresher', 'Wood burner',
        'Fish cleaner', 'Armorsmith', 'Furnace operator', 'Metal crafter', 'Metalsmith',
        'Weaponsmith', 'Glassmaker', 'Leatherworker', 'Strand extractor', 'Mechanic',
        'Pump operator', 'Siege engineer', 'Siege operator', 'Swimmer', 'Armor user',
        'Biter', 'Dodger'},
    RECUPERATION = {},
    DISEASE_RESISTANCE = {},

    ANALYTICAL_ABILITY = {'Animal caretaker', 'Trapper', 'Beekeeper', 'Cheese maker', 'Cook',
        'Furnace operator', 'Strand extractor', 'Gem cutter', 'Siege engineer',
        'Siege operator', 'Mechanic', 'Architecture', 'Diagnostician', 'Appraiser',
        'Organizer', 'Record keeper', 'Student', 'Knapper'},
    FOCUS = {'Fisherdwarf', 'Archer', 'Siege operator', 'Ambusher', 'Surgeon', 'Bone doctor',
        'Suturer', 'Record keeper', 'Student', 'Concentration', 'Observer'},
    WILLPOWER = {'Miner', 'Wood cutter', 'Fighter', 'Crutch-walker', 'Pump operator',
        'Swimmer', 'Concentration', 'Resisting exertion and pain'},
    CREATIVITY = {'Bone carver', 'Clothier', 'Glassmaker', 'Glazer', 'Leatherworker', 'Potter',
        'Stone crafter', 'Weaver', 'Wood crafter', 'Wax worker', 'Trapper', 'Cheese maker',
        'Cook', 'Architecture', 'Organizer', 'Liar', 'Comedian'},
    INTUITION = {'Animal trainer', 'Judge of intent', 'Appraiser', 'Observer', 'Diagnostician'},
    PATIENCE = {'Animal trainer', 'Fisherdwarf', 'Concentration', 'Some non-skill tasks'},
    MEMORY = {'Animal caretaker', 'Herbalist', 'Diagnostician', 'Appraiser', 'Record keeper',
        'Student'},
    LINGUISTIC_ABILITY = {'Persuader', 'Negotiator', 'Liar', 'Intimidator', 'Conversationalist',
        'Comedian', 'Flatterer', 'Consoler', 'Pacifier', 'Leader', 'Teacher'},
    SPATIAL_SENSE = {'Miner', 'Wood cutter', 'Bone carver', 'Clothier', 'Glassmaker',
        'Leatherworker', 'Potter', 'Glazer', 'Wax worker', 'Stone crafter', 'Weaver',
        'Wood crafter', 'Trapper', 'Spinner', 'Siege operator', 'Ambusher', 'Architecture',
        'Wound dresser', 'Surgeon', 'Bone doctor', 'Suturer', 'Crutch-walker', 'Papermaker',
        'Bookbinder', 'Swimmer', 'Observer', 'Knapper', 'Combat skills'},
    MUSICALITY = {},
    KINESTHETIC_SENSE = {'Most skills involving movement of any kind, and unskilled work too'},
    EMPATHY = {'Animal trainer', 'Animal caretaker', 'Wound dresser', 'Persuader', 'Negotiator',
        'Judge of intent', 'Conversationalist', 'Flatterer', 'Consoler', 'Pacifier', 'Leader',
        'Teacher'},
    SOCIAL_AWARENESS = {'Persuader', 'Negotiator', 'Judge of intent', 'Organizer', 'Liar',
        'Conversationalist', 'Flatterer', 'Consoler', 'Pacifier', 'Leader', 'Teacher'},
}

Attributes = defclass(Attributes, widgets.Window)
Attributes.ATTRS{
    frame_title = 'Attributes',
    -- a starting size only: init() measures the rows it actually built and resizes to fit
    -- them, since guessing once against one dwarf is what left the panel too small
    frame = {w = 74, h = 31},
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
    local widest = 0
    local function rows(kind)
        for _, r in ipairs(read_attrs(self.unit, kind)) do
            local cap = r.cap and ('%5d / %-5d'):format(r.value, r.cap) or ('%5d'):format(r.value)
            local left = ('  %s %s  '):format(r.name .. (' '):rep(math.max(0, NAME_W - #r.name)), cap)
            local right = ('%+d %s'):format(r.tier, TIER_WORD[r.tier] or '')
            widest = math.max(widest, #left + #right)
            choices[#choices + 1] = {
                token = r.token, name = r.name,
                text = {{text = left}, {text = right, pen = tier_pen(r.tier)}},
            }
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
        -- b = 3 clears the two-line footer; at b = 2 the last attribute sat under it
        widgets.List{
            frame = {t = 3, l = 0, r = 0, b = 3},
            choices = choices,
            on_submit = function(_, ch)
                if ch and ch.token then
                    TrainedByScreen{name = ch.name, token = ch.token}:show()
                end
            end,
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {
                'The tier is distance from this caste\'s median attribute, in DF\'s',
                NEWLINE,
                'own steps of 250. Click an attribute for what trains it. Esc closes.',
            },
            text_pen = COLOR_GREY,
        },
    }

    -- Sized from what is actually in it rather than from a pair of numbers worked out once
    -- against one dwarf. The height is every row plus the headers, the footer and the frame;
    -- the width is the longest row against the dwarf's name, which is easily the longest
    -- line here. Clamped to the screen, since a small window is better than one whose bottom
    -- rows are off the edge.
    -- EVERY line, not just the attribute rows: the footer is the longest line in this
    -- window and measuring only the rows cut it off mid-sentence.
    local FOOTER = 'own steps of 250. Click an attribute for what trains it. Esc closes.'
    widest = math.max(widest,
                      #FOOTER,
                      #'The tier is distance from this caste\'s median attribute, in DF\'s',
                      NAME_W + 2 + #'value / cap   vs. caste median',
                      #dfhack.units.getReadableName(self.unit))
    local sw, sh = dfhack.screen.getWindowSize()
    -- +10, measured rather than reasoned: the frame, the title, the two header lines, the
    -- gap and the two footer lines. At +8 the last two attributes were off the bottom.
    self.frame.w = math.max(48, math.min(sw - 4, widest + 4))
    self.frame.h = math.max(20, math.min(sh - 4, #choices + 10))
end

-- ---------------------------------------------------------------------------
-- "what trains this?"
-- ---------------------------------------------------------------------------

TrainedBy = defclass(TrainedBy, widgets.Window)
TrainedBy.ATTRS{
    frame_title = 'Trained by',
    -- a default frame is REQUIRED, not decoration: a Window whose ATTRS omit one has no
    -- self.frame at all, and init's resize then indexes nil
    frame = {w = 62, h = 20},
    resizable = true,
    name = DEFAULT_NIL,
    token = DEFAULT_NIL,
}

function TrainedBy:init()
    local list = TRAINS[self.token] or {}
    local choices, widest = {}, 0
    for _, job in ipairs(list) do
        widest = math.max(widest, #job)
        choices[#choices + 1] = {text = '  ' .. job}
    end
    if #choices == 0 then
        choices[1] = {text = {{text = '  Nothing known to train it.', pen = COLOR_GREY}}}
        widest = 30
    end
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0},
            text = {{text = self.name or '?', pen = COLOR_LIGHTCYAN},
                    {text = ' is exercised by:'}}},
        widgets.List{frame = {t = 2, l = 0, r = 0, b = 2}, choices = choices},
        widgets.Label{frame = {b = 0, l = 0}, text_pen = COLOR_GREY,
            text = 'From the DF wiki -- the game does not expose this. Esc closes.'},
    }
    local FOOTER = 'From the DF wiki -- the game does not expose this. Esc closes.'
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame.w = math.max(40, math.min(sw - 6, math.max(widest + 8, #FOOTER + 4)))
    self.frame.h = math.max(10, math.min(sh - 6, #choices + 9))
end

TrainedByScreen = defclass(TrainedByScreen, gui.ZScreenModal)
TrainedByScreen.ATTRS{
    focus_path = 'unit-attributes/trained-by',
    force_pause = false,
    name = DEFAULT_NIL,
    token = DEFAULT_NIL,
}
function TrainedByScreen:init()
    self:addviews{TrainedBy{name = self.name, token = self.token}}
end
function TrainedByScreen:onDismiss() end

AttributesScreen = defclass(AttributesScreen, gui.ZScreenModal)
-- `unit` MUST be declared here. An attribute the class does not declare is not carried
-- through the constructor, so it arrives nil in init -- and a nil unit handed to
-- Units::getPhysicalAttrValue below dereferences null in C++ and takes DF down with it.
AttributesScreen.ATTRS{
    focus_path = 'unit-attributes',
    -- reading a dwarf's numbers is not a reason to stop the fort
    force_pause = false,
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
