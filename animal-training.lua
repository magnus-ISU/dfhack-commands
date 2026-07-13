-- Bulk "configure training" UI for the animal-training zone: assign many caged animals to a
-- chosen trainer at once (so one trainer can level up on a whole flock of ravens).
--@module = true
--[[
animal-training

Vanilla lets you mark one animal at a time for training. This adds a **[configure training]**
button (Ctrl-T) to the Animal-Training zone panel (`dwarfmode/Zone/Some/AnimalTraining`). It
opens a two-pane picker:

    * LEFT  -- your dwarves with the Animal Training labor. Pick ONE (only one trainer active at
      a time); animals you click get assigned to that trainer.
    * RIGHT -- the caged, tamable animals, grouped by the top toggle:
        [types]        one row per species (e.g. "raven x7")
        [genders]      split male / female
        [individuals]  one row per animal
      Invader-owned animals are always split into their own rows ("... (invader)"). Ctrl-V (or
      click the toggle) cycles the three views.

Click an animal row to assign the whole group to the selected trainer; click again to unassign
(toggle). [X] = all assigned to the selected trainer, [~] = some, [ ] = none. "(n w/ other)"
means n of them are currently assigned to a different trainer.

Assignments are the game's own basic-training records (`plotinfo.training.training_assignments`
with a specific `trainer_id`), so a dwarf with the labor picks them up and skills up on them.

Overlay is auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local ANIMALTRAIN = df.unit_labor.ANIMALTRAIN
local VIEW = {TYPES = 1, GENDERS = 2, INDIVIDUALS = 3}

-- ---------------------------------------------------------------------------
-- data model: the game's basic-training assignments
-- ---------------------------------------------------------------------------

local function training_vec() return df.global.plotinfo.training.training_assignments end

local function find_assignment(animal_id)
    local tr = training_vec()
    for i = 0, #tr - 1 do
        if tr[i].animal_id == animal_id then return tr[i], i end
    end
end

-- basic training (not war/hunt) records a specific trainer_id; return it, or nil if the animal
-- isn't set for basic training.
local function basic_trainer_of(animal_id)
    local ta = find_assignment(animal_id)
    if ta and not ta.flags.train_war and not ta.flags.train_hunt then return ta.trainer_id end
end

-- keep the vector sorted by animal_id (matches how the game stores it)
local function sorted_insert(ta)
    local vec = training_vec()
    local i = 0
    while i < #vec and vec[i].animal_id < ta.animal_id do i = i + 1 end
    vec:insert(i, ta)
end

local function assign_to(animal_id, trainer_id)
    local ta = find_assignment(animal_id)
    if ta then
        ta.trainer_id = trainer_id
        ta.flags.train_war = false
        ta.flags.train_hunt = false
        ta.flags.any_trainer = false
        ta.flags.any_unassigned_trainer = false
    else
        ta = df.training_assignment:new()
        ta.animal_id = animal_id
        ta.trainer_id = trainer_id
        sorted_insert(ta)
    end
end

local function unassign(animal_id)
    local ta, idx = find_assignment(animal_id)
    if ta and idx then
        training_vec():erase(idx)
        ta:delete()
    end
end

local function trainer_assigned_count(trainer_id)
    local tr, n = training_vec(), 0
    for i = 0, #tr - 1 do
        if tr[i].trainer_id == trainer_id and not tr[i].flags.train_war and not tr[i].flags.train_hunt then
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- pools: trainers and the caged/trainable animals
-- ---------------------------------------------------------------------------

local function animaltrain_skill(u)
    local lvl = 0
    pcall(function()
        local s = u.status.current_soul
        if s then for _, sk in ipairs(s.skills) do
            if df.job_skill[sk.id] == 'ANIMALTRAIN' then lvl = sk.rating end
        end end
    end)
    return lvl
end

local function list_trainers()
    -- anyone the fort controls (citizen OR resident -- e.g. a joined mercenary/trader) with the
    -- Animal Training labor on. The labor bit is only ever set on fort workers, so this is exactly
    -- "people with the animal trainer labor". (Residents fail isCitizen but still do the work.)
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isFortControlled(u) and not dfhack.units.isDead(u)
            and u.status.labors[ANIMALTRAIN] then
            out[#out + 1] = u
        end
    end
    table.sort(out, function(a, b) return dfhack.units.getReadableName(a) < dfhack.units.getReadableName(b) end)
    return out
end

-- caged tamable animals, plus any animal already set for basic training (so you can unassign it)
local function list_animals()
    local seen, out = {}, {}
    local function add(u)
        if u and not dfhack.units.isDead(u) and not seen[u.id] then seen[u.id] = true; out[#out + 1] = u end
    end
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags1.caged and dfhack.units.isTamable(u) then add(u) end
    end
    local tr = training_vec()
    for i = 0, #tr - 1 do
        if not tr[i].flags.train_war and not tr[i].flags.train_hunt then add(df.unit.find(tr[i].animal_id)) end
    end
    return out
end

local function species_name(u, plural)
    local cr = df.global.world.raws.creatures.all[u.race]
    local n = cr and cr.name[plural and 1 or 0]
    if not n or n == '' then return plural and 'animals' or 'animal' end
    return n
end

-- physical body size (giant elephants biggest); largest individual represents its group
local function unit_size(u)
    local s = 0
    pcall(function() s = u.body.size_info.size_cur end)
    return s or 0
end

-- group the animals per the view mode; invaders always split into their own groups
local function group_animals(animals, mode)
    local by_key, order = {}, {}
    for _, u in ipairs(animals) do
        local inv = dfhack.units.isInvader(u)
        local key
        if mode == VIEW.INDIVIDUALS then key = 'u' .. u.id
        elseif mode == VIEW.GENDERS then key = u.race .. ':' .. tostring(u.sex) .. ':' .. tostring(inv)
        else key = u.race .. ':' .. tostring(inv) end
        local g = by_key[key]
        if not g then
            g = {key = key, units = {}, invader = inv, sex = u.sex, rep = u, size = 0}
            by_key[key] = g; order[#order + 1] = g
        end
        g.units[#g.units + 1] = u
        local sz = unit_size(u)
        if sz > g.size then g.size = sz end
    end
    for _, g in ipairs(order) do
        local n = #g.units
        local tag = g.invader and ' (invader)' or ''
        if mode == VIEW.INDIVIDUALS then
            g.label = dfhack.units.getReadableName(g.rep) .. tag
        elseif mode == VIEW.GENDERS then
            local gen = g.sex == 1 and 'male' or (g.sex == 0 and 'female' or 'unknown-sex')
            g.label = ('%s %s%s x%d'):format(species_name(g.rep, false), gen, tag, n)
        else
            g.label = ('%s%s x%d'):format(species_name(g.rep, n > 1), tag, n)
        end
        -- grazers need a grass pasture once tamed (wild/caged ones don't eat), so flag them:
        -- a species-level trait, so the group's representative answers for the whole group
        local grazer = false
        pcall(function() grazer = dfhack.units.isGrazer(g.rep) end)
        if grazer then g.label = g.label .. ' (grazer)' end
    end
    table.sort(order, function(a, b)
        if a.size ~= b.size then return a.size > b.size end       -- largest first (by body size)
        if a.invader ~= b.invader then return not a.invader end   -- your animals before invaders
        return a.label < b.label
    end)
    return order
end

-- ---------------------------------------------------------------------------
-- the picker window
-- ---------------------------------------------------------------------------

ConfigureTraining = defclass(ConfigureTraining, widgets.Window)
ConfigureTraining.ATTRS{
    frame_title = 'Configure animal training',
    frame = {w = 90, h = 40},
    resizable = true,
}

function ConfigureTraining:init()
    self.view_mode = VIEW.TYPES
    self:addviews{
        widgets.CycleHotkeyLabel{
            view_id = 'toggle',
            frame = {t = 0, l = 0},
            key = 'CUSTOM_CTRL_V',
            label = 'View:',
            options = {
                {label = 'types', value = VIEW.TYPES},
                {label = 'genders', value = VIEW.GENDERS},
                {label = 'individuals', value = VIEW.INDIVIDUALS},
            },
            initial_option = VIEW.TYPES,
            on_change = function(v) self.view_mode = v; self:refresh_animals() end,
        },
        widgets.Label{frame = {t = 2, l = 0}, text = 'Trainers (pick one):'},
        widgets.List{
            view_id = 'trainers',
            frame = {t = 3, l = 0, w = 40, b = 2},
            on_select = function() self:refresh_animals() end,
        },
        widgets.Label{
            frame = {t = 2, l = 42},
            text = {{text = function() return 'Animals \26 ' .. self:trainer_name() end, pen = COLOR_LIGHTGREEN}},
        },
        widgets.List{
            view_id = 'animals',
            frame = {t = 3, l = 42, b = 2},
            on_submit = function(_, choice) self:toggle_group(choice) end,
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = 'Ctrl-V: cycle view.  Click a trainer, then click animals to (un)assign.  "(grazer)" = needs a grass pasture once tamed.',
            text_pen = COLOR_GREY,
        },
    }
    self:refresh_trainers()
end

function ConfigureTraining:selected_trainer()
    local _, ch = self.subviews.trainers:getSelected()
    return ch and ch.unit
end

function ConfigureTraining:trainer_name()
    local u = self:selected_trainer()
    return u and dfhack.units.getReadableName(u) or '(select a trainer)'
end

function ConfigureTraining:refresh_trainers()
    -- remember the current pick so a rebuild (after assigning) doesn't jump selection
    local prev = self:selected_trainer()
    local prev_id = prev and prev.id
    local units = list_trainers()
    local choices, keep = {}, 1
    for _, u in ipairs(units) do
        choices[#choices + 1] = {
            text = ('%s  (skill %d, %d assigned)'):format(
                dfhack.units.getReadableName(u), animaltrain_skill(u), trainer_assigned_count(u.id)),
            unit = u,
        }
        if prev_id and u.id == prev_id then keep = #choices end
    end
    if #choices == 0 then choices = {{text = 'No dwarf has the Animal Training labor.', unit = nil}} end
    self.subviews.trainers:setChoices(choices, keep)
    self:refresh_animals()
end

function ConfigureTraining:refresh_animals()
    local groups = group_animals(list_animals(), self.view_mode)
    local sel = self:selected_trainer()
    local selid = sel and sel.id
    local choices = {}
    for _, g in ipairs(groups) do
        local to_sel, to_other = 0, 0
        for _, u in ipairs(g.units) do
            local t = basic_trainer_of(u.id)
            if t ~= nil then
                if selid and t == selid then to_sel = to_sel + 1 else to_other = to_other + 1 end
            end
        end
        local mark = to_sel == #g.units and '[X]' or (to_sel > 0 and '[~]' or '[ ]')
        local suffix = to_other > 0 and (' (%d w/ other)'):format(to_other) or ''
        choices[#choices + 1] = {text = ('%s %s%s'):format(mark, g.label, suffix), group = g}
    end
    if #choices == 0 then choices = {{text = '(no caged, tamable animals)', group = nil}} end
    self.subviews.animals:setChoices(choices)
end

function ConfigureTraining:toggle_group(choice)
    local sel = self:selected_trainer()
    if not sel or not choice.group then return end
    local g = choice.group
    -- if the whole group is already assigned to this trainer, unassign; otherwise assign all to it
    local all = true
    for _, u in ipairs(g.units) do if basic_trainer_of(u.id) ~= sel.id then all = false; break end end
    for _, u in ipairs(g.units) do
        if all then unassign(u.id) else assign_to(u.id, sel.id) end
    end
    self:refresh_trainers()   -- refreshes counts + the animal list
end

-- ---------------------------------------------------------------------------
-- the modal screen wrapping the window
-- ---------------------------------------------------------------------------

view = view or nil

ConfigureTrainingScreen = defclass(ConfigureTrainingScreen, gui.ZScreen)
ConfigureTrainingScreen.ATTRS{ focus_path = 'animal-training/configure' }
function ConfigureTrainingScreen:init() self:addviews{ ConfigureTraining{} } end
function ConfigureTrainingScreen:onDismiss() view = nil end

-- ---------------------------------------------------------------------------
-- overlay: the [configure training] button on the animal-training zone panel
-- ---------------------------------------------------------------------------

local function cur_training_zone()
    local mi = df.global.game.main_interface
    if mi.bottom_mode_selected == df.main_bottom_mode_type.ZONE
        and mi.civzone.cur_bld and mi.civzone.cur_bld.type == df.civzone_type.AnimalTraining then
        return mi.civzone.cur_bld
    end
end

TrainingConfigOverlay = defclass(TrainingConfigOverlay, overlay.OverlayWidget)
TrainingConfigOverlay.ATTRS{
    desc = 'Adds a [configure training] button to the animal-training zone panel for bulk trainer assignment.',
    default_pos = {x = 7, y = 13},
    default_enabled = true,
    viewscreens = 'dwarfmode/Zone/Some/AnimalTraining',
    frame = {w = 12, h = 1},
    version = 2,
}

function TrainingConfigOverlay:open()
    if cur_training_zone() and not view then view = ConfigureTrainingScreen{}:show() end
end

function TrainingConfigOverlay:init()
    -- keyless HotkeyLabel renders just its label (a plain clickable button); Ctrl-T is handled
    -- in onInput so the label stays a clean "[training]" instead of "Ctrl+T: [configure training]"
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 10},
            label = '[training]',
            on_activate = function() self:open() end,
        },
    }
end

function TrainingConfigOverlay:onInput(keys)
    if keys.CUSTOM_CTRL_T then self:open(); return true end
    return TrainingConfigOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {config = TrainingConfigOverlay}

if dfhack_flags and dfhack_flags.module then return end

-- run standalone: open the picker directly if a training zone is selected, else explain.
if cur_training_zone() then
    view = view or ConfigureTrainingScreen{}:show()
else
    print('animal-training: overlay registered. Open an Animal-Training zone and press Ctrl-T')
    print('(or click "[configure training]") to bulk-assign caged animals to a trainer.')
end
