-- Bulk "mark for slaughter" UI on the butcher's shop, à la the animal-training picker.
--@module = true
--[[
butcher-shop

Adds a **[Butcher]** button (Ctrl-B) to a butcher's-shop building panel
(dwarfmode/ViewSheets/BUILDING/Workshop/Butchers). It opens a two-panel picker of your non-pet
fort animals (loose livestock, plus caged NON-tame captives you're holding -- caged domesticated
livestock and genuinely wild caged captives are left out), grouped by species and (by default) sex:

    * LEFT panel  = animals NOT set for slaughter.
    * RIGHT panel = animals already set for slaughter.
    * NON-TAME animals (not fully domesticated -- e.g. a trained-but-wild raven, which can revert)
      sort to the TOP so you cull them first, and the group's LEAST-trained (wildest) level is shown
      next to the name ("(Trained)", "(Semi-Wild)", ...) -- one row per species/sex even if its
      members sit at different training levels.
    * Within that non-tame block (and among the domesticated livestock below it) rows are sorted by
      body size of the species' LARGER gender, largest first, and within a species MALE before FEMALE.
    * A group whose species/sex has only ONE adult is shown in PINK -- a warning that slaughtering
      it removes your last breeder of that species/sex.
    * YOUNG animals (babies and children) always get their own "(young)" row, never mixed into the
      adult count, and are HIDDEN from the left panel by default -- Ctrl-Y shows them. Young that
      are already marked always appear on the right, so a mark can always be undone.
    * Ctrl-G toggles "Split by gender" off, collapsing each species to a single row.

Click a LEFT row to mark that group's OLDEST not-yet-marked animal for slaughter -- click again to
mark the next-oldest, and so on. Click a RIGHT row to un-mark that group's youngest marked animal
(undo). Marking sets the unit's `flags2.slaughter`.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local PINK = COLOR_LIGHTMAGENTA

-- ---------------------------------------------------------------------------
-- data
-- ---------------------------------------------------------------------------

-- your butcherable livestock: alive, fort-owned animals that aren't pets or merchants.
-- CAGED animals: kept only when NON-tame (semi-wild/trained captives you're holding -- valid cull
-- targets). Caged fully-domesticated livestock stays out (it's deliberately stored). Genuinely wild
-- caged captives (wild-untamed, captured invader beasts) are excluded by the isFortControlled gate.
local function is_butcher_animal(u)
    if not (dfhack.units.isFortControlled(u) and dfhack.units.isAnimal(u) and dfhack.units.isAlive(u)
        and not dfhack.units.isMerchant(u) and not dfhack.units.isPet(u)) then
        return false
    end
    if u.flags1.caged then
        local dom = true; pcall(function() dom = dfhack.units.isDomesticated(u) end)
        if dom then return false end
    end
    return true
end

local function list_animals()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if is_butcher_animal(u) then out[#out + 1] = u end
    end
    return out
end

-- default TRUE: adulthood gates whether a row shows on the left, so an unreadable age must fail
-- towards "visible adult" rather than silently hiding the animal
local function is_adult(u)
    local a = true
    pcall(function() a = not dfhack.units.isBaby(u) and not dfhack.units.isChild(u) end)
    return a
end
local function unit_age(u) local a = 0; pcall(function() a = dfhack.units.getAge(u, true) end); return a end
local function unit_size(u) local s = 0; pcall(function() s = u.body.size_info.size_cur end); return s end
local function is_marked(u) local m = false; pcall(function() m = u.flags2.slaughter end); return m end
local function set_marked(u, v) pcall(function() u.flags2.slaughter = v end) end
-- "non-tame" = not fully domesticated (e.g. a trained-but-wild raven -- tame now, but a lower
-- training level that can still revert). These are prioritized: sorted above the domestic livestock
-- and tagged, so you cull them first.
local function is_nontame(u) local d = true; pcall(function() d = dfhack.units.isDomesticated(u) end); return not d end
local function training_level(u) local t = 99; pcall(function() t = u.training_level end); return t end
-- pretty enum name: SemiWild -> "Semi-Wild", WellTrained -> "Well-Trained", Trained -> "Trained"
local function level_name(tl)
    local n = df.animal_training_level[tl]
    return n and (n:gsub('(%l)(%u)', '%1-%2')) or '?'
end

local function species_name(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local n = cr and cr.name[0]
    return (n and n ~= '') and n or 'animal'
end

-- group by species (+ sex when by_gender), and ALWAYS split young (babies/children) off into their
-- own group so they never pad an adult row's count. Sort by the species' larger-gender size (desc),
-- keeping a species' rows adjacent, male before female and each adult row above its young row.
-- Also returns adult counts keyed by species/sex ("breed"), for the last-breeder warning.
local function group_animals(animals, by_gender)
    local species_size = {}
    for _, u in ipairs(animals) do
        local sz = unit_size(u)
        if (species_size[u.race] or -1) < sz then species_size[u.race] = sz end
    end
    local by_key, order, breed_adults = {}, {}, {}
    for _, u in ipairs(animals) do
        local breed = by_gender and (u.race .. ':' .. u.sex) or tostring(u.race)
        local adult = is_adult(u)
        if adult then breed_adults[breed] = (breed_adults[breed] or 0) + 1 end
        local key = breed .. (adult and ':a' or ':y')
        local g = by_key[key]
        if not g then
            g = {race = u.race, sex = by_gender and u.sex or nil, breed = breed, adult = adult,
                 units = {}, ssize = species_size[u.race],
                 nontame = is_nontame(u), tlevel = training_level(u)}
            by_key[key] = g; order[#order + 1] = g
        end
        g.units[#g.units + 1] = u
        local tl = training_level(u)
        if tl < g.tlevel then g.tlevel = tl end                    -- one row per group, showing the LEAST-trained level
    end
    table.sort(order, function(a, b)
        if a.nontame ~= b.nontame then return a.nontame end        -- non-tame prioritized to the top
        if a.ssize ~= b.ssize then return a.ssize > b.ssize end    -- then size: larger gender's, biggest first
        if a.race ~= b.race then return a.race < b.race end        -- keep a species' rows together
        local am = a.sex == 1 and 0 or 1                           -- male (sex 1) before female
        local bm = b.sex == 1 and 0 or 1
        if am ~= bm then return am < bm end
        return a.adult and not b.adult                             -- adults above their own young
    end)
    return order, breed_adults
end

-- oldest unit in `units` matching want_marked; nil if none
local function pick(units, want_marked, oldest)
    local target
    for _, u in ipairs(units) do
        if is_marked(u) == want_marked then
            if not target then target = u
            elseif oldest and unit_age(u) > unit_age(target) then target = u
            elseif not oldest and unit_age(u) < unit_age(target) then target = u end
        end
    end
    return target
end

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------

Butcher = defclass(Butcher, widgets.Window)
Butcher.ATTRS{
    frame_title = 'Mark for slaughter',
    frame = {w = 76, h = 40},
    resizable = true,
}

function Butcher:init()
    self:addviews{
        widgets.ToggleHotkeyLabel{
            view_id = 'by_gender',
            frame = {t = 0, l = 0},
            key = 'CUSTOM_CTRL_G',
            label = 'Split by gender:',
            initial_option = true,
            on_change = function() self:refresh() end,
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'show_young',
            frame = {t = 1, l = 0},
            key = 'CUSTOM_CTRL_Y',
            label = 'Show young:     ',
            initial_option = false,
            on_change = function() self:refresh() end,
        },
        widgets.Label{frame = {t = 3, l = 0}, text = 'Not for slaughter  (click \26 mark oldest)'},
        widgets.List{
            view_id = 'keep',
            frame = {t = 4, l = 0, w = 36, b = 3},
            on_submit = function(_, choice) self:mark(choice) end,
        },
        widgets.Label{frame = {t = 3, l = 38}, text = {{text = 'For slaughter  (click \26 un-mark)', pen = COLOR_LIGHTRED}}},
        widgets.List{
            view_id = 'slaughter',
            frame = {t = 4, l = 38, b = 3},
            on_submit = function(_, choice) self:unmark(choice) end,
        },
        widgets.Label{
            frame = {b = 0, l = 0, h = 2},
            text = {
                'Ctrl-G: split by gender.  Left marks the oldest (repeat for more); right un-marks.  Pink = only one adult left.',
                NEWLINE,
                'Ctrl-Y: show young (babies/children) on the left -- young are always their own row, and marked young always show on the right.',
            },
            text_pen = COLOR_GREY,
        },
    }
    self:refresh()
end

function Butcher:refresh()
    local show_young = self.subviews.show_young:getOptionValue()
    local groups, breed_adults = group_animals(list_animals(), self.subviews.by_gender:getOptionValue())
    local keep, slaughter, hidden_young = {}, {}, 0
    for _, g in ipairs(groups) do
        local nkeep, nmark = 0, 0
        for _, u in ipairs(g.units) do
            if is_marked(u) then nmark = nmark + 1 else nkeep = nkeep + 1 end
        end
        -- the warning is about losing your last breeder, so it counts adults of the whole
        -- species/sex (never the young row, which breeds nothing yet)
        local pink = g.adult and (breed_adults[g.breed] or 0) == 1
        local gender = g.sex == 1 and ' male' or (g.sex == 0 and ' female' or '')
        local tags = {}
        if not g.adult then tags[#tags + 1] = 'young' end
        if g.nontame then tags[#tags + 1] = level_name(g.tlevel) end               -- show level if not tame
        local base = ('%s%s'):format(species_name(g.units[1]), gender)
        if #tags > 0 then base = base .. ' (' .. table.concat(tags, ', ') .. ')' end
        if nkeep > 0 then
            if g.adult or show_young then
                local label = ('%s x%d'):format(base, nkeep)
                keep[#keep + 1] = {text = pink and {{text = label, pen = PINK}} or label, group = g}
            else
                hidden_young = hidden_young + nkeep
            end
        end
        if nmark > 0 then   -- marked young are always listed, else the mark could never be undone
            slaughter[#slaughter + 1] = {text = ('%s x%d'):format(base, nmark), group = g}
        end
    end
    if hidden_young > 0 then
        keep[#keep + 1] = {text = {{text = ('(%d young hidden -- Ctrl-Y)'):format(hidden_young), pen = COLOR_GREY}}}
    end
    if #keep == 0 then keep = {{text = '(no tame, non-pet livestock)'}} end
    if #slaughter == 0 then slaughter = {{text = '(none marked)'}} end
    self.subviews.keep:setChoices(keep, self.subviews.keep:getSelected())
    self.subviews.slaughter:setChoices(slaughter, self.subviews.slaughter:getSelected())
end

-- left click: mark this group's oldest not-yet-marked animal (repeatable)
function Butcher:mark(choice)
    if not choice.group then return end
    local target = pick(choice.group.units, false, true)   -- oldest unmarked
    if target then set_marked(target, true) end
    self:refresh()
end

-- right click: un-mark this group's youngest marked animal (undo the most recent mark)
function Butcher:unmark(choice)
    if not choice.group then return end
    local target = pick(choice.group.units, true, false)   -- youngest marked
    if target then set_marked(target, false) end
    self:refresh()
end

-- ---------------------------------------------------------------------------
-- screen + overlay
-- ---------------------------------------------------------------------------

view = view or nil

ButcherScreen = defclass(ButcherScreen, gui.ZScreen)
ButcherScreen.ATTRS{ focus_path = 'butcher-shop/mark' }
function ButcherScreen:init() self:addviews{ Butcher{} } end
function ButcherScreen:onDismiss() view = nil end

local function cur_butcher_shop()
    local b = dfhack.gui.getSelectedBuilding()
    if b and df.building_workshopst:is_instance(b) and b.type == df.workshop_type.Butchers then
        return b
    end
end

-- Find the (dynamic) "Add new task" button on the panel by reading the screen, and return the
-- SCREEN (col, row) where the [Butcher] button should sit: directly to its right with a 2-space
-- gap. Returns nil if the text isn't drawn yet (e.g. a different tab), so the caller can retry.
local ADD_TASK = 'Add new task'
local function add_task_button_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    for y = 0, sh - 1 do
        local chars = {}
        for x = 40, sw - 1 do        -- the task panel is well right of center; skip the left half
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local c = table.concat(chars):find(ADD_TASK, 1, true)
        if c then
            local col = 40 + c - 1                    -- 0-based screen col of "Add new task"
            return col + #ADD_TASK + 2, y             -- button col (2-space gap) and same row
        end
    end
end

ButcherOverlay = defclass(ButcherOverlay, overlay.OverlayWidget)
ButcherOverlay.ATTRS{
    desc = 'Adds a [Butcher] button to the butcher-shop panel for bulk slaughter marking.',
    default_pos = {x = 2, y = 6},                     -- fallback until it snaps next to "Add new task"
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/Workshop/Butchers',
    frame = {w = 9, h = 1},
    overlay_onupdate_max_freq_seconds = 0,            -- checked every frame, but only re-scrapes on change
    version = 2,
}

function ButcherOverlay:open()
    if cur_butcher_shop() and not view then view = ButcherScreen{}:show() end
end

function ButcherOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 9},
            label = '[Butcher]',
            on_activate = function() self:open() end,
        },
    }
end

-- snap the button next to "Add new task" (frame is relative to the interface rect, so convert the
-- screen coords by the interface origin). Returns false if the text isn't on screen yet.
function ButcherOverlay:reposition()
    local col, row = add_task_button_pos()
    if not col then return false end
    local ir = gui.get_interface_rect()
    self.frame = {w = self.frame.w, h = self.frame.h, l = col - ir.x1, t = row - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    return true
end

-- recompute only when the panel opens or its task count changes (the "Add new task" button slides
-- down as tasks are added) -- not every frame. The cheap signature check runs every frame; the
-- (heavier) screen scrape + reposition happens only when that signature changes.
function ButcherOverlay:overlay_onupdate()
    local bld = cur_butcher_shop()
    if not bld then self.sig = nil; return end
    local sig = ('%d:%d'):format(bld.id, #bld.jobs)
    if sig ~= self.sig then
        if self:reposition() then self.sig = sig end   -- commit only once the text is actually drawn
    end
end

function ButcherOverlay:onInput(keys)
    if keys.CUSTOM_CTRL_B then self:open(); return true end
    return ButcherOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {butcher = ButcherOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('butcher-shop: overlay registered.')
print('Open a butcher\'s shop and press Ctrl-B (or click [Butcher]) to bulk-mark animals for slaughter.')
