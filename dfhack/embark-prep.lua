-- Embark "Prepare carefully" helpers: office-loadout button + preferences window.
--@module = true
--[[
Two overlays on the embark preparation screen, Dwarves tab
(focus setupdwarfgame/Dwarves):

* embark-prep.loadout -- three buttons that give the SELECTED dwarf the
  skills for an office, 1 point in each skill that affects the role
  (per the wiki):
    Manager    -> Organizer                                  (1 pick)
    Bookkeeper -> Record Keeper                              (1 pick)
    Broker     -> Appraiser, Comedian, Flatterer, Intimidator,
                  Judge of Intent, Liar, Negotiator, Persuader (8 picks)
  Skills already at 1+ are left alone and not paid for again. If the
  dwarf doesn't have enough picks left the skills are still set, but the
  shortfall is reported (DF doesn't block embark on it).

* embark-prep.prefs -- a window (lower-left) showing the selected dwarf's
  likes: materials, creatures, foods, items, plants, colors, shapes, art
  forms. Updates as you move the selection.

Reposition either with gui/overlay.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- ---------------------------------------------------------------- loadout --

-- 1 point in each skill that affects the office (per the DF wiki)
OFFICES = {
    {
        label = 'Manager (Organizer)',
        key = 'CUSTOM_CTRL_M',
        skills = {df.job_skill.ORGANIZATION},
    },
    {
        label = 'Bookkeeper (Record Keeper)',
        key = 'CUSTOM_CTRL_K',
        skills = {df.job_skill.RECORD_KEEPING},
    },
    {
        label = 'Broker (Appraiser + social)',
        key = 'CUSTOM_CTRL_B',
        skills = {
            df.job_skill.APPRAISAL,
            df.job_skill.COMEDY,
            df.job_skill.FLATTERY,
            df.job_skill.INTIMIDATION,
            df.job_skill.JUDGING_INTENT,
            df.job_skill.LYING,
            df.job_skill.NEGOTIATION,
            df.job_skill.PERSUASION,
        },
    },
}

local function get_screen()
    return dfhack.gui.getViewscreenByType(df.viewscreen_setupdwarfgamest, 0)
end

function apply_office(office)
    local vs = get_screen()
    if not vs then return 'no embark screen?' end
    local di = vs.dwarf_info[vs.selected_u]
    if not di then return 'no dwarf selected' end
    local raised = 0
    for _, sk in ipairs(office.skills) do
        if di.skilllevel[sk] < 1 then
            di.skilllevel[sk] = 1
            raised = raised + 1
        end
    end
    local short = raised - di.skill_picks_left
    di.skill_picks_left = math.max(0, di.skill_picks_left - raised)
    local unit = vs.s_unit[vs.selected_u]
    local name = unit and dfhack.df2utf(dfhack.units.getReadableName(unit))
                       or 'dwarf ' .. vs.selected_u
    name = name:match('^[^,]+') or name
    local role = office.label:match('^%S+')
    if raised == 0 then
        return ('%s already has the %s skills'):format(name, role)
    elseif short > 0 then
        return ('%s: +%d %s skills (%d over budget)'):format(name, raised,
                                                             role, short)
    end
    return ('%s: +%d %s skills, %d picks left'):format(name, raised, role,
                                                       di.skill_picks_left)
end

LoadoutButtons = defclass(LoadoutButtons, overlay.OverlayWidget)
LoadoutButtons.ATTRS{
    desc = 'Embark screen buttons: give the selected dwarf manager/bookkeeper/broker skills.',
    default_pos = {x = 21, y = -31},  -- just above the preferences window
    default_enabled = true,
    viewscreens = 'setupdwarfgame/Dwarves',
    frame = {w = 44, h = 4},
    version = 2,
}

function LoadoutButtons:init()
    local views = {}
    for i, office in ipairs(OFFICES) do
        table.insert(views, widgets.TextButton{
            frame = {t = i - 1, l = 0, w = 34, h = 1},
            label = office.label,
            key = office.key,
            on_activate = function()
                self.subviews.result:setText(apply_office(office))
            end,
        })
    end
    table.insert(views, widgets.Label{
        view_id = 'result',
        frame = {t = #OFFICES, l = 0},
        text = '',
        text_pen = COLOR_YELLOW,
    })
    self:addviews(views)
end

-- ------------------------------------------------------------ preferences --

local function mat_name(p)
    local ok, mi = pcall(dfhack.matinfo.decode, p.mattype, p.matindex)
    return ok and mi and mi:toString() or '?material'
end

local function creature_name(id)
    local cr = df.global.world.raws.creatures.all[id]
    return cr and cr.name[1] or '?creature'
end

local function plant_name(id)
    local pl = df.global.world.raws.plants.all[id]
    return pl and pl.name_plural or '?plant'
end

-- matinfo can yield e.g. "long yam plant plant" when the plant's own name
-- already ends in "plant"
local function dedupe(s)
    return (s:gsub('(%S+) (%S+)$', function(a, b)
        return a == b and a or a .. ' ' .. b
    end))
end

local function item_name(p)
    if p.item_subtype >= 0 then
        local ok, def = pcall(dfhack.items.getSubtypeDef, p.item_type,
                              p.item_subtype)
        if ok and def then return def.name_plural end
    end
    local attrs = df.item_type.attrs[p.item_type]
    local name = attrs and attrs.caption or '?item'
    return name:sub(-1) == 's' and name or name .. 's'
end

local function form_name(finder, id, what)
    local ok, form = pcall(finder, id)
    if ok and form then
        return dfhack.df2utf(dfhack.translation.translateName(form.name, true))
    end
    return 'a certain ' .. what
end

local RENDER = {
    [df.unitpref_type.LikeMaterial] = function(p) return 'Likes ' .. mat_name(p) end,
    [df.unitpref_type.LikeCreature] = function(p)
        return 'Likes ' .. creature_name(p.creature_id) end,
    [df.unitpref_type.HateCreature] = function(p)
        return 'Detests ' .. creature_name(p.creature_id) end,
    [df.unitpref_type.LikeFood] = function(p)
        local what
        if p.mattype >= 0 and p.matindex < 0 then
            -- fish/egg prefs put the creature race id in mattype
            what = creature_name(p.mattype)
        elseif p.mattype >= 0 then
            what = mat_name(p)
        else
            what = item_name(p)
        end
        return 'Likes eating ' .. dedupe(what) end,
    [df.unitpref_type.LikeItem] = function(p) return 'Likes ' .. item_name(p) end,
    [df.unitpref_type.LikePlant] = function(p)
        return 'Likes ' .. plant_name(p.plant_id) end,
    [df.unitpref_type.LikeTree] = function(p)
        return 'Likes ' .. plant_name(p.plant_id) .. ' (trees)' end,
    [df.unitpref_type.LikeColor] = function(p)
        local c = df.global.world.raws.descriptors.colors[p.color_id]
        return 'Likes the color ' .. (c and c.name or '?') end,
    [df.unitpref_type.LikeShape] = function(p)
        local s = df.global.world.raws.descriptors.shapes[p.shape_id]
        return 'Likes ' .. (s and s.name_plural or '?shapes') end,
    [df.unitpref_type.LikePoeticForm] = function(p)
        return 'Likes the poem ' .. form_name(df.poetic_form.find,
                                              p.poetic_form_id, 'poem') end,
    [df.unitpref_type.LikeMusicalForm] = function(p)
        return 'Likes the music ' .. form_name(df.musical_form.find,
                                               p.musical_form_id, 'song') end,
    [df.unitpref_type.LikeDanceForm] = function(p)
        return 'Likes the dance ' .. form_name(df.dance_form.find,
                                               p.dance_form_id, 'dance') end,
}

function preference_lines(unit)
    local lines = {}
    if not unit or not unit.status.current_soul then return lines end
    for _, p in ipairs(unit.status.current_soul.preferences) do
        local fn = RENDER[p.type]
        local ok, line = pcall(fn or function() return nil end, p)
        table.insert(lines, ok and line or ('?' .. tostring(df.unitpref_type[p.type])))
    end
    return lines
end

PrefsWindow = defclass(PrefsWindow, overlay.OverlayWidget)
PrefsWindow.ATTRS{
    desc = 'Embark screen window: show the selected dwarf\'s preferences.',
    default_pos = {x = 21, y = -9},  -- lower-left corner
    default_enabled = true,
    viewscreens = 'setupdwarfgame/Dwarves',
    frame = {w = 44, h = 20},
    version = 2,
}

function PrefsWindow:init()
    self.cur_sel = -1
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},
            frame_style = gui.FRAME_MEDIUM,
            frame_title = 'Preferences',
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.Label{
                    view_id = 'name',
                    frame = {t = 0, l = 0},
                    text = '',
                    text_pen = COLOR_LIGHTCYAN,
                },
                widgets.Label{
                    view_id = 'prefs',
                    frame = {t = 1, l = 0, r = 0, b = 0},
                    text = '',
                },
            },
        },
    }
end

function PrefsWindow:refresh(vs)
    local unit = vs.selected_u >= 0 and vs.selected_u < #vs.s_unit
        and vs.s_unit[vs.selected_u] or nil
    self.cur_sel = vs.selected_u
    if not unit then
        self.subviews.name:setText('')
        self.subviews.prefs:setText('(nobody selected)')
        return
    end
    self.subviews.name:setText(dfhack.df2utf(dfhack.units.getReadableName(unit)))
    local lines = preference_lines(unit)
    self.subviews.prefs:setText(table.concat(lines, NEWLINE))
end

function PrefsWindow:render(dc)
    local vs = get_screen()
    if vs and vs.selected_u ~= self.cur_sel then
        self:refresh(vs)
    end
    PrefsWindow.super.render(self, dc)
end

OVERLAY_WIDGETS = {
    loadout = LoadoutButtons,
    prefs = PrefsWindow,
}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('embark-prep: registered overlays embark-prep.loadout + embark-prep.prefs')
