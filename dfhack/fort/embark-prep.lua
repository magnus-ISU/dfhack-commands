-- Embark "Prepare carefully" helpers: office-loadout button + preferences window.
--@module = true
--[[
Two overlays on the embark preparation screen, Dwarves tab
(focus setupdwarfgame/Dwarves):

* embark-prep.loadout -- three buttons that give the SELECTED dwarf the
  skills for an office (per the wiki):
    Manager    -> Organizer 5                                 (5 picks)
    Bookkeeper -> Record Keeper 5                             (5 picks)
    Doctor     -> Diagnostician, Surgeon, Bone Doctor
                  at 3 each                                   (9 picks)
    Broker     -> Appraiser, Comedian, Flatterer, Intimidator,
                  Judge of Intent, Liar, Negotiator, Persuader
                  at 1 each                                   (8 picks)
  Skills already at the target are left alone and not paid for again. If
  the dwarf doesn't have enough picks left the skills are still set, but
  the shortfall is reported (DF doesn't block embark on it).

* embark-prep.prefs -- a window showing what matters about the selected
  dwarf's likes at embark: metals and weapon/armor items, inline
  ("Prefers bismuth bronze and battle axes"), plus whether they like or
  dislike combat (the MARTIAL_PROWESS personal value). Updates as you
  move the selection.

Reposition either with gui/overlay.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- ---------------------------------------------------------------- loadout --

-- raise each listed skill to `level` (per the DF wiki; embark caps at 5)
OFFICES = {
    {
        label = 'Manager (Organizer 5)',
        key = 'CUSTOM_CTRL_M',
        level = 5,
        skills = {df.job_skill.ORGANIZATION},
    },
    {
        label = 'Bookkeeper (Record Keeper 5)',
        key = 'CUSTOM_CTRL_K',
        level = 5,
        skills = {df.job_skill.RECORD_KEEPING},
    },
    {
        label = 'Doctor (Diag/Surgeon/Bones 3)',
        key = 'CUSTOM_CTRL_D',
        level = 3,
        skills = {
            df.job_skill.DIAGNOSE,
            df.job_skill.SURGERY,
            df.job_skill.SET_BONE,
        },
    },
    {
        label = 'Broker (Appraiser + social)',
        key = 'CUSTOM_CTRL_B',
        level = 1,
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
    -- raise (never lower) each skill to the office's target level, paying
    -- one pick per level actually added
    local raised = 0
    for _, sk in ipairs(office.skills) do
        if di.skilllevel[sk] < office.level then
            raised = raised + office.level - di.skilllevel[sk]
            di.skilllevel[sk] = office.level
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
        return ('%s: +%d %s skill levels (%d over budget)'):format(
            name, raised, role, short)
    end
    return ('%s: +%d %s skill levels, %d picks left'):format(
        name, raised, role, di.skill_picks_left)
end

LoadoutButtons = defclass(LoadoutButtons, overlay.OverlayWidget)
LoadoutButtons.ATTRS{
    desc = 'Embark screen buttons: give the selected dwarf manager/bookkeeper/broker skills.',
    default_pos = {x = 21, y = -31},  -- just above the preferences window
    default_enabled = true,
    viewscreens = 'setupdwarfgame/Dwarves',
    frame = {w = 44, h = 5},   -- 4 office buttons + the result line
    version = 2,
}

function LoadoutButtons:init()
    self.cur_sel = -1
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
    -- auto_height=false matters: Labels default to auto_height, which sizes the
    -- label from its text at layout time and OVERRIDES an explicit frame.h -- a
    -- label built with EMPTY text gets height 0, and setText() later never
    -- re-layouts, so the text exists but has no body to render into
    table.insert(views, widgets.Label{
        view_id = 'result',
        frame = {t = #OFFICES, l = 0, h = 1},
        auto_height = false,
        text = '',
        text_pen = COLOR_YELLOW,
    })
    self:addviews(views)
end

-- the result line talks about a specific dwarf; clear it when the selection
-- moves on so it can't read as information about the newly selected dwarf
function LoadoutButtons:render(dc)
    local vs = get_screen()
    if vs and vs.selected_u ~= self.cur_sel then
        self.cur_sel = vs.selected_u
        self.subviews.result:setText('')
    end
    LoadoutButtons.super.render(self, dc)
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

-- ---- the filtered view the window actually shows ----------------------------
-- At embark the likes that matter are the ones moods and masterworks feed on:
-- metals and weapon/armor gear. Everything else (foods, colors, poems...) is noise.

local GEAR_ITEM_TYPES = {
    [df.item_type.WEAPON] = true,
    [df.item_type.SHIELD] = true,
    [df.item_type.ARMOR] = true,
    [df.item_type.HELM] = true,
    [df.item_type.GLOVES] = true,
    [df.item_type.SHOES] = true,
    [df.item_type.PANTS] = true,
    [df.item_type.AMMO] = true,
}

local function is_metal_pref(p)
    local ok, mi = pcall(dfhack.matinfo.decode, p.mattype, p.matindex)
    return ok and mi and mi.material and mi.material.flags.IS_METAL or false
end

-- names of the unit's liked metals and weapon/armor items, in preference order
function gear_likes(unit)
    local likes = {}
    if not unit or not unit.status.current_soul then return likes end
    for _, p in ipairs(unit.status.current_soul.preferences) do
        if p.type == df.unitpref_type.LikeMaterial and is_metal_pref(p) then
            table.insert(likes, mat_name(p))
        elseif p.type == df.unitpref_type.LikeItem
            and GEAR_ITEM_TYPES[p.item_type] then
            table.insert(likes, item_name(p))
        end
    end
    return likes
end

-- "a", "a and b", "a, b and c"
local function oxford(list)
    if #list <= 1 then return list[1] end
    return table.concat(list, ', ', 1, #list - 1) .. ' and ' .. list[#list]
end

-- the MARTIAL_PROWESS personal value: how this dwarf feels about combat.
-- No entry in personality.values means the civ default, i.e. unremarkable.
function combat_stance(unit)
    local strength = 0
    local soul = unit and unit.status.current_soul
    if soul then
        for _, v in ipairs(soul.personality.values) do
            if v.type == df.value_type.MARTIAL_PROWESS then
                strength = v.strength
                break
            end
        end
    end
    local word = strength >= 41 and 'Loves' or strength >= 15 and 'Likes'
        or strength <= -41 and 'Hates' or strength <= -15 and 'Dislikes'
        or 'Indifferent to'
    return ('%s combat (%+d)'):format(word, strength)
end

-- greedy word-wrap; the gui Label draws exactly the lines it's given
local function wrap(s, width)
    local lines, line = {}, ''
    for word in s:gmatch('%S+') do
        if #line > 0 and #line + #word + 1 > width then
            table.insert(lines, line)
            line = word
        else
            line = #line > 0 and (line .. ' ' .. word) or word
        end
    end
    if #line > 0 then table.insert(lines, line) end
    return lines
end

PrefsWindow = defclass(PrefsWindow, overlay.OverlayWidget)
PrefsWindow.ATTRS{
    desc = 'Embark screen window: selected dwarf\'s metal/gear likes + combat stance.',
    -- bottom-anchored (negative y = frame.b offset), so it rides the screen
    -- bottom instead of drifting when the grid gets taller
    default_pos = {x = 21, y = -17},
    default_enabled = true,
    viewscreens = 'setupdwarfgame/Dwarves',
    frame = {w = 44, h = 9},
    version = 6,
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
                -- both labels start EMPTY, and auto_height (the Label default)
                -- freezes an empty label at height 0 on first layout, overriding
                -- even an explicit frame.h -- setText() alone never revives it.
                -- Verified live: text set, frame_body y2 < y1, nothing rendered.
                widgets.Label{
                    view_id = 'name',
                    frame = {t = 0, l = 0, h = 1},
                    auto_height = false,
                    text = '',
                    text_pen = COLOR_LIGHTCYAN,
                },
                widgets.Label{
                    view_id = 'prefs',
                    frame = {t = 1, l = 0, r = 0, b = 0},
                    auto_height = false,
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
    -- NO df2utf here: screen text is cp437, and utf-8 multibyte chars (the
    -- nickname guillemets, say) come out as garbage tiles
    self.subviews.name:setText(dfhack.units.getReadableName(unit))
    local gear = gear_likes(unit)
    local lines = gear[1] and wrap('Prefers ' .. oxford(gear), 42)
                          or {'No metal or weapon/armor likes'}
    table.insert(lines, combat_stance(unit))
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
