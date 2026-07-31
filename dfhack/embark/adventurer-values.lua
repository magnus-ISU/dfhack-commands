-- Adventurer creation: click a need on the Personality page to change its severity.
--@module = true
--[[
embark/adventurer-values
========================

Tags: adventure | embark | interface

The Personality page of adventurer creation lists your needs ("Drink alcohol
Moderate Need", "Be with family  Moderate Need", ...) but gives you no way to
edit them short of rerolling the personality or hand-tuning values in Full
customization.  Some are effectively un-satisfiable in play -- a wanderer never
sees their family, so "Be with family" is a permanent focus drain.

With this overlay loaded, the needs list is editable in place, on BOTH the
Personality page and the Full customization page:

- **Left-click** a need: raise its severity one step (Slight -> Moderate ->
  Strong -> Intense).
- **Right-click** a need: lower it one step; right-clicking a Slight need
  REMOVES it.  The right-click is consumed, so it does not ALSO navigate back.

Needs are DERIVED data: DF rebuilds `pers.needs` from personality values and
facets (each value-column click in Full customization triggers the rebuild), so
editing the needs vector alone only changes the display until the next rebuild.
This overlay therefore edits the SOURCE -- the personal value (which overrides
the cultural default) or the facet -- and then resyncs the needs entries it
affects.  Open Full customization after clicking and you can watch the value /
facet selections move.

The need -> source map and the severity bands were derived empirically on this
build (write source, trigger DF's own rebuild, read the result):

  values   (<15 none, 15-25 Slight, 26-40 Moderate, 41+ Strong; no Intense):
    BeWithFamily<-FAMILY  BeWithFriends<-FRIENDSHIP  HearEloquence<-ELOQUENCE
    UpholdTradition<-TRADITION  SelfExamination<-INTROSPECTION
    MakeMerry<-MERRIMENT  CraftObject<-CRAFTSMANSHIP
    MartialTraining<-MARTIAL_PROWESS  PracticeSkill<-SKILL
    TakeItEasy<-LEISURE_TIME  MakeRomance<-ROMANCE  AdmireArt<-ARTWORK
    SeeAnimal & SeeGreatBeast <- NATURE (one value, two needs)
  facets   (<40 none, 40-60 Slight, 61-75 Moderate, 76-90 Strong, 91+ Intense):
    Socialize<-GREGARIOUSNESS  Excitement<-EXCITEMENT_SEEKING
    AcquireObject<-GREED  Fight<-VIOLENT  CauseTrouble<-DISCORD
    BeExtravagant<-IMMODESTY  HelpSomebody<-ALTRUISM
    ThinkAbstractly<-ABSTRACT_INCLINED  BeCreative<-ART_INCLINED
    Wander<-ACTIVITY_LEVEL
    EatGoodMeal & DrinkAlcohol <- IMMODERATION (one facet, two needs --
      DrinkAlcohol is NOT racial on this build)
  inverse facet (40-60 Slight, 25-39 Moderate, 10-24 Strong, <=9 Intense,
    61+ none):
    Argue <- FRIENDLINESS (quarrelsome = unfriendly; found by binary search)
  dual source (need level = max of the two):
    LearnSomething <- KNOWLEDGE value | CURIOUS facet
    StayOccupied   <- HARD_WORK value | ACTIVITY_LEVEL facet
  unsupported:
    PrayOrMedidate is worship-driven; clicks on "Pray to X" rows are consumed
    but do nothing.

Coupled sources are inherent: lowering "Eat good meal" also lowers "Drink
alcohol" (both are IMMODERATION), NATURE moves both animal needs, and
ACTIVITY_LEVEL links Wander with StayOccupied.  All affected needs are resynced
on every click.  Editing a source also shifts the matching personality-text
line -- that is the point: the change is real, not cosmetic.

Clicks are resolved by reading the clicked ROW's rendered text and matching the
need name against the enum -- no hardcoded row geometry, so scrolling and
layout shifts don't break it.

    embark/adventurer-values          status (the overlay is on by default)
]]

local overlay = require('plugins.overlay')

-- need_level values DF renders as Slight / Moderate / Strong / Intense
local LEVELS = {1, 2, 5, 10}
local SEV_WORDS = {Slight = true, Moderate = true, Strong = true, Intense = true}

adjusted = adjusted or 0   -- clicks that changed a source (persists across reloads)

-- ---- need -> source mapping (empirical, see header) -------------------------

local function V(name) return {kind = 'value', id = df.value_type[name]} end
local function F(name, inverse)
    return {kind = 'facet', id = df.personality_facet_type[name], inverse = inverse}
end

local SOURCES = {
    Socialize       = {F('GREGARIOUSNESS')},
    DrinkAlcohol    = {F('IMMODERATION')},
    StayOccupied    = {V('HARD_WORK'), F('ACTIVITY_LEVEL')},
    BeCreative      = {F('ART_INCLINED')},
    Excitement      = {F('EXCITEMENT_SEEKING')},
    LearnSomething  = {V('KNOWLEDGE'), F('CURIOUS')},
    BeWithFamily    = {V('FAMILY')},
    BeWithFriends   = {V('FRIENDSHIP')},
    HearEloquence   = {V('ELOQUENCE')},
    UpholdTradition = {V('TRADITION')},
    SelfExamination = {V('INTROSPECTION')},
    MakeMerry       = {V('MERRIMENT')},
    CraftObject     = {V('CRAFTSMANSHIP')},
    MartialTraining = {V('MARTIAL_PROWESS')},
    PracticeSkill   = {V('SKILL')},
    TakeItEasy      = {V('LEISURE_TIME')},
    MakeRomance     = {V('ROMANCE')},
    SeeAnimal       = {V('NATURE')},
    SeeGreatBeast   = {V('NATURE')},
    AcquireObject   = {F('GREED')},
    EatGoodMeal     = {F('IMMODERATION')},
    Fight           = {F('VIOLENT')},
    CauseTrouble    = {F('DISCORD')},
    Argue           = {F('FRIENDLINESS', true)},
    BeExtravagant   = {F('IMMODESTY')},
    Wander          = {F('ACTIVITY_LEVEL')},
    HelpSomebody    = {F('ALTRUISM')},
    ThinkAbstractly = {F('ABSTRACT_INCLINED')},
    AdmireArt       = {V('ARTWORK')},
}

-- band 0 = no need, 1..4 = Slight/Moderate/Strong/Intense.
-- Representative strengths land mid-band, matching what DF's own column
-- clicks write for values (+++ writes 50, ++ writes 33).
local VALUE_REP = {[0] = 0, 20, 33, 50, 50}       -- values cap at Strong
local FACET_REP = {[0] = 30, 50, 68, 83, 95}
local INV_REP   = {[0] = 70, 50, 32, 17, 5}

local function value_band(s)
    if s >= 41 then return 3 elseif s >= 26 then return 2
    elseif s >= 15 then return 1 else return 0 end
end

local function facet_band(v, inverse)
    if inverse then
        if v >= 61 then return 0 elseif v >= 40 then return 1
        elseif v >= 25 then return 2 elseif v >= 10 then return 3
        else return 4 end
    end
    if v >= 91 then return 4 elseif v >= 76 then return 3
    elseif v >= 61 then return 2 elseif v >= 40 then return 1
    else return 0 end
end

local function level_band(lv)
    for i, l in ipairs(LEVELS) do if lv <= l then return i end end
    return #LEVELS
end

-- ---- character sheet access -------------------------------------------------

local function sheet()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs and not df.viewscreen_setupadventurest:is_instance(vs) do vs = vs.parent end
    if not vs or vs.mode ~= 5 then return end                 -- 5 = character sheet
    local idx = vs.active_sheet_index
    if idx < 0 or idx >= #vs.csheet then idx = 0 end
    local cs = vs.csheet[idx]
    -- 8 = the Personality page; the needs list renders the same on the main
    -- page and inside Full customization, and this works on both
    if not cs or cs.sub_mode ~= 8 then return end
    return cs
end

local function personal_value(cs, vtype)
    for i = 0, #cs.pers.values - 1 do
        if cs.pers.values[i].type == vtype then return cs.pers.values[i] end
    end
end

-- band a single source contributes right now; nil for a civ-default value we
-- cannot read (no personal entry overriding it)
local function source_band(cs, src)
    if src.kind == 'facet' then
        return facet_band(cs.pers.traits[src.id], src.inverse)
    end
    local pv = personal_value(cs, src.id)
    if pv then return value_band(pv.strength) end
    return nil
end

local function write_source(cs, src, band)
    if src.kind == 'facet' then
        cs.pers.traits[src.id] = (src.inverse and INV_REP or FACET_REP)[band]
    else
        local pv = personal_value(cs, src.id)
        if pv then pv.strength = VALUE_REP[band]
        else
            cs.pers.values:insert('#',
                {new = true, type = src.id, strength = VALUE_REP[band]})
        end
    end
end

-- ---- needs display sync -----------------------------------------------------

local function need_entry(cs, id)
    for i = 0, #cs.pers.needs - 1 do
        if cs.pers.needs[i].id == id then return i, cs.pers.needs[i] end
    end
end

-- recompute one need's level from its sources and make pers.needs match.
-- A civ-default value source (band nil) is invisible to us, but every write
-- creates a personal override, so by the time it matters it is readable.
local function sync_need(cs, name)
    local id = df.need_type[name]
    local band = 0
    for _, src in ipairs(SOURCES[name]) do
        local b = source_band(cs, src)
        if b and b > band then band = b end
    end
    local idx, entry = need_entry(cs, id)
    if band == 0 then
        if idx then cs.pers.needs:erase(idx) end
    elseif entry then
        entry.need_level = LEVELS[band]
    else
        cs.pers.needs:insert('#', {new = true, id = id, deity_id = -1,
            focus_level = 0, need_level = LEVELS[band]})
    end
end

-- every need that shares a source with `name`, itself included
local function affected_needs(name)
    local touched = {}
    for _, src in ipairs(SOURCES[name]) do touched[src.kind .. src.id] = true end
    local out = {}
    for other, srcs in pairs(SOURCES) do
        for _, src in ipairs(srcs) do
            if touched[src.kind .. src.id] then out[#out + 1] = other break end
        end
    end
    return out
end

local function adjust(cs, name, entry, delta)
    local target = level_band(entry.need_level) + delta
    if target > #LEVELS or target < 0 then return false end
    local srcs = SOURCES[name]
    -- values cannot produce Intense; don't no-op writes into the same band
    if target == 4 and srcs[1].kind == 'value' and #srcs == 1 then return false end
    if delta > 0 then
        -- raise: push the primary source into the target band (facet sources
        -- can't be above it -- the max would already show a higher severity)
        write_source(cs, srcs[1], target)
    else
        -- lower: every source now contributing more than the target must drop.
        -- An unreadable civ default (band nil) gets a personal override at the
        -- target band, which is exactly how the game's own UI overrides it.
        for _, src in ipairs(srcs) do
            local b = source_band(cs, src)
            if b == nil or b > target then write_source(cs, src, target) end
        end
    end
    for _, other in ipairs(affected_needs(name)) do sync_need(cs, other) end
    adjusted = adjusted + 1
    return true
end

-- ---- click resolution -------------------------------------------------------

local function norm(s) return s:lower():gsub('[^%a]', '') end

-- need_type enum name -> normalized display name ("BeWithFamily" -> "bewithfamily")
local NEED_BY_NORM = {}
for i = df.need_type._first_item, df.need_type._last_item do
    local name = df.need_type[i]
    if name then NEED_BY_NORM[norm(name)] = name end
end

local function read_row(y)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    for x = 0, gps.dimx - 1 do
        local t = dfhack.screen.readTile(x, y)
        local ch = t and t.ch or 0
        row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- Parse one rendered row as "<anything>  <need name>  <Sev> Need".  The left
-- half of the screen holds the personality paragraph, so the need name is the
-- LAST 2+-space-separated chunk before the severity.  Returns the name and its
-- cell span, or nil when the row isn't a need row.
local function parse_row(row)
    local sev = row:match('(%a+) Need%s*$')
    if not sev or not SEV_WORDS[sev] then return end
    -- greedy .* leaves the 2+-space gap's tail on `before`; strip to the last
    -- non-space or the name-start arithmetic lands cells to the right of the name
    local before = row:match('^(.*%S)%s+%a+ Need%s*$')
    if not before then return end
    local name
    for chunk in (before .. '  '):gmatch('(.-)%s%s+') do
        if chunk:match('%S') then name = chunk:match('^%s*(.-)%s*$') end
    end
    if not name or name == '' then return end
    local x1 = #before - #name              -- 0-based cell of the name's first char
    local x2 = #row:match('^(.*%a+ Need)%s*$') - 1
    return name, x1, x2
end

-- the clicked need: its enum name and its entry in cs.pers.needs
local function need_at(cs, mx, my)
    local disp, x1, x2 = parse_row(read_row(my))
    if not disp or mx < x1 or mx > x2 then return end
    local key = norm(disp)
    local name = NEED_BY_NORM[key]
    if not name and key:match('^prayto') then name = 'PrayOrMedidate' end
    if not name then return end
    local _, entry = need_entry(cs, df.need_type[name])
    return name, entry
end

-- ---- overlay ----------------------------------------------------------------

AdventurerValues = defclass(AdventurerValues, overlay.OverlayWidget)
AdventurerValues.ATTRS{
    desc = 'Left/right-click needs on the adventurer Personality page to raise/lower them.',
    default_enabled = true,
    viewscreens = 'setupadventure',
    frame = {w = 1, h = 1},
}

-- usage hint painted 4 rows above the top of the needs list
local HINT = {'Left click to intensify a need', 'Right click to weaken it'}
local PEN_HINT = dfhack.pen.parse{fg = COLOR_YELLOW, bg = COLOR_BLACK}
local hint_pos, hint_at = nil, 0
local HINT_TTL_MS = 500

-- topmost need row on screen (cheap: stops at the first match)
local function find_top_need()
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local name, x1 = parse_row(read_row(y))
        if name then return {x = x1, y = y} end
    end
end

function AdventurerValues:onRenderFrame(dc, rect)
    pcall(function()
        if not sheet() then return end
        local now = dfhack.getTickCount()
        if now - hint_at > HINT_TTL_MS then
            hint_at = now
            hint_pos = find_top_need()
        end
        if not hint_pos then return end
        for i, line in ipairs(HINT) do
            local y = hint_pos.y - 4 + (i - 1)
            if y >= 0 then dfhack.screen.paintString(PEN_HINT, hint_pos.x, y, line) end
        end
    end)
end

function AdventurerValues:onInput(keys)
    if not keys._MOUSE_L and not keys._MOUSE_R then return false end
    local ok, handled = pcall(function()
        local cs = sheet()
        if not cs then return false end
        local gps = df.global.gps
        local name, entry = need_at(cs, gps.mouse_x, gps.mouse_y)
        if not name then return false end
        -- consume the click even when it changes nothing (Pray rows, caps):
        -- a fallen-through _MOUSE_R would navigate back out of the page
        if entry and SOURCES[name] then
            adjust(cs, name, entry, keys._MOUSE_L and 1 or -1)
        end
        return true
    end)
    return ok and handled
end

OVERLAY_WIDGETS = {values = AdventurerValues}

if dfhack_flags.module then return end

print(('embark/adventurer-values: %d source adjustment%s this session')
    :format(adjusted, adjusted == 1 and '' or 's'))
print('On the Personality page (or Full customization) of adventurer creation:')
print('left-click a need to raise it, right-click to lower; lowering Slight removes it.')
print('Edits change the underlying value/facet, so they survive DF\'s needs rebuilds.')
