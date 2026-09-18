-- [Train] toggle on a WILD animal's unit sheet, like the butcher/graze options tame
-- animals get.
--@module = true
--[[
wild-animal-train

When the unit sheet of a WILD tamable animal is open (dwarfmode/ViewSheets/UNIT), this
shows a [Train] button. Clicking it queues the game's OWN basic-training assignment for
that animal with "any trainer" (the same record the Animal-Training zone picker writes),
and turns green; clicking again removes it. Once the animal is captured (or if it is
already caged), any dwarf with the Animal Training labor picks the job up -- so you can
mark interesting wildlife for taming the moment you spot it, without hunting for it
later in the zone picker.

Only shown for living, tamable, NOT-yet-tame animals -- tame/trained animals have their
own native options (butcher, geld, ...) on the sheet.

Registered automatically as overlay `wild-animal-train.train`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- ---- the game's basic-training records (same as animal-training.lua) --------

local function training_vec() return df.global.plotinfo.training.training_assignments end

local function find_assignment(animal_id)
    local tr = training_vec()
    for i = 0, #tr - 1 do
        if tr[i].animal_id == animal_id then return tr[i], i end
    end
end

-- basic-training assignment (war/hunt training records are not ours to touch)
local function is_queued(animal_id)
    local ta = find_assignment(animal_id)
    return ta ~= nil and not ta.flags.train_war and not ta.flags.train_hunt
end

-- keep the vector sorted by animal_id (matches how the game stores it)
local function sorted_insert(ta)
    local vec = training_vec()
    local i = 0
    while i < #vec and vec[i].animal_id < ta.animal_id do i = i + 1 end
    vec:insert(i, ta)
end

local function queue_training(animal_id)
    if find_assignment(animal_id) then return end
    local ta = df.training_assignment:new()
    ta.animal_id = animal_id
    ta.trainer_id = -1
    ta.flags.any_trainer = true
    sorted_insert(ta)
end

local function unqueue_training(animal_id)
    local ta, idx = find_assignment(animal_id)
    if ta and idx and not ta.flags.train_war and not ta.flags.train_hunt then
        training_vec():erase(idx)
        ta:delete()
    end
end

-- ---- the selected unit -------------------------------------------------------

local function cur_unit()
    local id = df.global.game.main_interface.view_sheets.active_id
    if not id or id < 0 then return nil end
    return df.unit.find(id)
end

-- a living, tamable animal that is NOT yet tame: exactly the ones whose sheet has no
-- native livestock options. (Tame/trained animals get butcher/geld etc. natively.)
local function is_wild_tamable(u)
    return u ~= nil
        and dfhack.units.isAlive(u)
        and dfhack.units.isAnimal(u)
        and dfhack.units.isTamable(u)
        and not dfhack.units.isTame(u)
end

-- ---- overlay -----------------------------------------------------------------

WildTrainOverlay = defclass(WildTrainOverlay, overlay.OverlayWidget)
WildTrainOverlay.ATTRS{
    desc = 'Adds a [Train] toggle to a wild tamable animal\'s unit sheet.',
    default_pos = {x = 3, y = -16},   -- above the creature-description block, bottom-left
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT',
    frame = {w = 7, h = 1},
    version = 1,
}

function WildTrainOverlay:init()
    self.visible = function() return is_wild_tamable(cur_unit()) end
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 7},    -- '[Train]'
            label = '[Train]',
            text_pen = function()
                local u = cur_unit()
                return (u and is_queued(u.id)) and COLOR_GREEN or COLOR_WHITE
            end,
            on_activate = function()
                local u = cur_unit()
                if not u then return end
                if is_queued(u.id) then unqueue_training(u.id) else queue_training(u.id) end
            end,
        },
    }
end

-- ---- the same button, on a CAGE --------------------------------------------
--
-- Clicking a caged animal on the map does NOT open the unit's sheet -- it opens the CAGE's
-- item sheet, because what you clicked is an item that happens to contain somebody. So the
-- unit-sheet button above never appears for exactly the animals you are most likely to want
-- trained: the ones already sitting in a cage waiting for it.
--
-- A cage holds its occupants as `general_ref_contains_unitst`; there is normally one, but a
-- trap can hold several, so this trains all of the tamable ones together.

local function caged_animals(item)
    local out = {}
    if not item then return out end
    for _, g in ipairs(item.general_refs) do
        if df.general_ref_contains_unitst:is_instance(g) then
            local u = df.unit.find(g.unit_id)
            if is_wild_tamable(u) then out[#out + 1] = u end
        end
    end
    return out
end

local function cur_cage_animals()
    return caged_animals(dfhack.gui.getSelectedItem(true))
end

CagedTrainOverlay = defclass(CagedTrainOverlay, overlay.OverlayWidget)
CagedTrainOverlay.ATTRS{
    desc = 'Adds a [Train] toggle to the item sheet of a cage holding a wild tamable animal.',
    -- THE SAME SPOT `fort/auto-pasture` PUTS [Graze]/[Scavenge]. That overlay
    -- (`auto-pasture.cagegraze`) owns this row of the cage sheet for a caged animal that is
    -- already tame or trained; this one owns it for a caged animal that is not. The two can
    -- never be visible at once -- one wants `isTame`, the other `not isTame` -- so sharing the
    -- position is deliberate, and it means the button is always in the place your eye already
    -- goes for "what do I do with this animal". Anchored from the RIGHT because the item sheet
    -- is a right-hand panel and moves with the screen edge, not the left one.
    default_pos = {x = -56, y = 9},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/ITEM',
    frame = {w = 7, h = 1},
    -- 2: moved onto DF's own button row. A version bump RESETS the saved config, which is what
    -- makes the new default_pos take, but the widget comes back DISABLED -- re-enable after.
    version = 2,
}

function CagedTrainOverlay:init()
    self.visible = function() return #cur_cage_animals() > 0 end
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 7},
            label = '[Train]',
            -- green once every occupant is queued, so a trap holding three reads as done
            -- only when all three are
            text_pen = function()
                local animals = cur_cage_animals()
                if #animals == 0 then return COLOR_WHITE end
                for _, u in ipairs(animals) do
                    if not is_queued(u.id) then return COLOR_WHITE end
                end
                return COLOR_GREEN
            end,
            on_activate = function()
                local animals = cur_cage_animals()
                if #animals == 0 then return end
                -- if any is unqueued the click queues them all; only an all-queued cage
                -- un-queues, so a half-done cage never toggles the wrong way
                local all_queued = true
                for _, u in ipairs(animals) do
                    if not is_queued(u.id) then all_queued = false break end
                end
                for _, u in ipairs(animals) do
                    if all_queued then unqueue_training(u.id) else queue_training(u.id) end
                end
            end,
        },
    }
end

OVERLAY_WIDGETS = {train = WildTrainOverlay, caged = CagedTrainOverlay}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('wild-animal-train: [Train] toggle on wild tamable animals\' unit sheets.')
