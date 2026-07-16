-- Show the selected creature's description in a scrollable panel, bottom-left.
--@module = true
--[[
When a creature is selected (its unit sheet is open), this shows the creature's
description -- `caste.description` -- in a wrapping, scrollable block in the
bottom-left. Most useful for forgotten beasts / titans / generated creatures,
whose description is their full generated flavor (body, materials, special
attacks). For ordinary creatures it's the species blurb.

Registered automatically as overlay `creature-description.desc`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- ---- kill summary -----------------------------------------------------------
-- Expands "Kills: N" into notable categories, in this fixed order:
--   demons, angels, megabeasts, beasts (semi-megabeasts), goblins, dwarves,
--   humans, elves, kobolds, <the largest animal species killed>, other
-- e.g. "66 kills: 1 demon, 2 angels, 3 megabeasts, 4 beasts, 5 goblins,
--       6 dwarves, 7 humans, 8 elves, 9 kobolds, 10 giant elephants, 11 other"

-- category key for a race, or nil for the animal/other pool
local function classify_race(rid)
    local cr = df.global.world.raws.creatures.all[rid]
    if not cr then return nil end
    local id = tostring(cr.creature_id)
    if id == 'GOBLIN' then return 'goblin' end
    if id == 'DWARF' then return 'dwarf' end
    if id == 'HUMAN' then return 'human' end
    if id == 'ELF' then return 'elf' end
    if id == 'KOBOLD' then return 'kobold' end
    -- angels have no caste flag of their own; their generated tokens carry DIVINE/ANGEL
    -- (e.g. "HF133 DIVINE_1", "SHARK_ANGEL"). Check before demons.
    if id:find('DIVINE') or id:find('ANGEL') then return 'angel' end
    local f = cr.caste[0] and cr.caste[0].flags
    if f then
        if f.DEMON or f.UNIQUE_DEMON then return 'demon' end
        if f.MEGABEAST or f.TITAN or f.FEATURE_BEAST then return 'megabeast' end
        if f.SEMIMEGABEAST then return 'beast' end
    end
    return nil
end

-- is this race a (non-speaking, non-learning) animal, and its adult body size
local function animal_info(rid)
    local cr = df.global.world.raws.creatures.all[rid]
    local c = cr and cr.caste[0]
    if not c then return false, 0 end
    if c.flags.CAN_LEARN or c.flags.CAN_SPEAK then return false, 0 end
    return true, c.misc.adult_size or 0
end

local CAT_ORDER = {'demon', 'angel', 'megabeast', 'beast', 'undead', 'goblin', 'dwarf', 'human', 'elf', 'kobold'}
local CAT_PLURAL = {demon = 'demons', angel = 'angels', megabeast = 'megabeasts', beast = 'beasts',
    undead = 'undead', goblin = 'goblins', dwarf = 'dwarves', human = 'humans', elf = 'elves', kobold = 'kobolds'}

-- any set bit in a kill group's undead_flags (zombie, ghostly, or the unnamed variants)
-- means the whole group was undead
local function is_undead_group(uf)
    if not uf then return false end
    for _, v in pairs(uf) do
        if v == true then return true end
    end
    return false
end

-- "310 kills: 139 goblins, 46 elves, ... 12 other" (or "Kills: 0").
-- Module-public so other scripts (and tests) can reuse it.
function kill_summary(u)
    local hf = u.hist_figure_id and u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
    if not (hf and hf.info and hf.info.kills) then return 'Kills: 0' end
    local k = hf.info.kills
    local cats, animals, other, total = {}, {}, 0, 0
    local function add(rid, n, undead)
        total = total + n
        -- undead trump every other category: a skeletal elf counts as undead, not elf
        if undead then
            cats.undead = (cats.undead or 0) + n
            return
        end
        local cat = classify_race(rid)
        if cat then
            cats[cat] = (cats[cat] or 0) + n
            return
        end
        local is_animal, size = animal_info(rid)
        if is_animal then
            local a = animals[rid] or {n = 0, size = size}
            a.n = a.n + n
            animals[rid] = a
        else
            other = other + n
        end
    end
    -- named victims: one event per kill; classify by the victim's race
    for i = 0, #k.events - 1 do
        local ev = df.history_event.find(k.events[i])
        if ev and df.history_event_hist_figure_diedst:is_instance(ev) then
            local v = df.historical_figure.find(ev.victim_hf)
            if v then add(v.race, 1) else total = total + 1; other = other + 1 end
        else
            total = total + 1
            other = other + 1
        end
    end
    -- anonymous kill groups (killed_count already includes undead-group kills;
    -- killed_undead is a parallel per-group FLAG marking undead groups, not a count)
    for i = 0, #k.killed_race - 1 do
        add(k.killed_race[i], k.killed_count[i], is_undead_group(k.killed_undead[i]))
    end
    if total == 0 then return 'Kills: 0' end
    -- the LARGEST animal species gets its own entry; all other animals fold into "other"
    local big_rid, big
    for rid, a in pairs(animals) do
        if not big or a.size > big.size or (a.size == big.size and a.n > big.n) then
            big_rid, big = rid, a
        end
    end
    for rid, a in pairs(animals) do
        if rid ~= big_rid then other = other + a.n end
    end
    local parts = {}
    for _, cat in ipairs(CAT_ORDER) do
        local n = cats[cat]
        if n and n > 0 then
            parts[#parts + 1] = ('%d %s'):format(n, n == 1 and cat or CAT_PLURAL[cat])
        end
    end
    if big then
        local cr = df.global.world.raws.creatures.all[big_rid]
        local nm = big.n == 1 and tostring(cr.name[0]) or tostring(cr.name[1])
        parts[#parts + 1] = ('%d %s'):format(big.n, nm)
    end
    if other > 0 then parts[#parts + 1] = ('%d other'):format(other) end
    return ('%d kill%s: %s'):format(total, total == 1 and '' or 's', table.concat(parts, ', '))
end

-- description + kills line for the selected creature, or nil
local function unit_info()
    local u = dfhack.gui.getSelectedUnit(true)
    if not u then return end
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if not (caste and caste.description and #caste.description > 0) then return end
    local ok, kills = pcall(kill_summary, u)
    return ('%s\n%s'):format(caste.description, ok and kills or 'Kills: ?')
end

-- how many display rows the text needs after word-wrapping to `width`
local function wrapped_lines(text, width)
    local n = 0
    for para in (text .. '\n'):gmatch('(.-)\n') do
        local len
        for word in para:gmatch('%S+') do
            local wl = #word
            if not len then len = wl
            elseif len + 1 + wl <= width then len = len + 1 + wl
            else n = n + 1; len = wl end
        end
        n = n + 1
    end
    return n
end

CreatureDescOverlay = defclass(CreatureDescOverlay, overlay.OverlayWidget)
CreatureDescOverlay.ATTRS{
    desc = "Shows the selected creature's description in the bottom-left.",
    default_pos = {x = 3, y = -4},   -- bottom-left
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT',
    frame = {w = 90, h = 12},
    version = 1,
    overlay_onupdate_max_freq_seconds = 0,
}

function CreatureDescOverlay:init()
    self:addviews{
        widgets.Panel{
            frame_style = gui.FRAME_THIN,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'desc',
                    frame = {t = 0, l = 0, r = 0, b = 0},
                    text_to_wrap = '',
                    text_pen = COLOR_YELLOW,
                },
            },
        },
    }
end

function CreatureDescOverlay:overlay_onupdate()
    local text = unit_info()
    self.visible = text ~= nil
    if not text then return end
    local changed = false
    if text ~= self.subviews.desc.text_to_wrap then
        self.subviews.desc.text_to_wrap = text
        changed = true
    end
    -- grow the box to fit the wrapped text (incl. the Kills line), so nothing is
    -- cut off; cap so it stays on screen
    local _, sh = dfhack.screen.getWindowSize()
    local h = math.max(4, math.min(wrapped_lines(text, self.frame.w - 2) + 2, sh - 6))
    if self.frame.h ~= h then self.frame.h = h; changed = true end
    if changed then self:updateLayout() end
end

OVERLAY_WIDGETS = {desc = CreatureDescOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('creature-description: registered overlay creature-description.desc')
