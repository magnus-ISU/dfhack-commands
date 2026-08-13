-- Warns when the fort is missing a material a strange mood could demand.
--@module = true
--[[
moody-items-warning

Registers a "moody_items" notification: it lists the mood materials your fort has NONE of.
A strange mood that asks for something you cannot supply ends with a dwarf going berserk or
melancholy, and the demand is rolled the moment the mood starts -- by then it is too late to
buy shells from the elves.

WHERE THE LIST COMES FROM. Not from memory: it is taken from DFHack's own `strangemood`
plugin (plugins/strangemood.cpp, which reimplements DF's selection) and cross-checked against
the Strange mood wiki page. The two agree.

BASE MATERIAL, chosen by the skill the moody dwarf claims:

    mining, stone engraving, masonry, stonecrafting,     rough stone boulders (hard stone --
      mechanics, stone cutting/carving                     clay and soil do not count)
    carpentry, woodcrafting, bowyery, papermaking,       logs
      bookbinding
    tanning, leatherworking                              tanned hides
    weaving, clothesmaking                               cloth -- plant, silk or yarn
    weaponsmithing, armorsmithing, metalsmithing,        metal bars
      metalcrafting
    gem cutting, gem setting                             rough gems
    glassmaking                                          raw glass
    bone carving                                         bones, or shells if they prefer one

DECORATION MATERIALS, up to seven more, each an even roll over: logs, metal bars, cut gems,
blocks, rough gems, boulders, bones, leather, cloth (plant/silk/yarn) and raw glass. A
decoration is never the same item type as the base material.

RAW GLASS IS ONLY DEMANDED IF YOU HAVE MADE IT. The game checks the fort's production history
(created_item_type) for green, clear and crystal glass, and a type you have never produced is
never asked for. So a fort with no glass industry is never nagged about glass -- but once
yours has made some, running out of it becomes a real gap and is reported like any other.

That is tracked from the production history AND from glass actually seen in your stockpiles,
remembered per site. Either alone has a hole: the history is one global read away from
silently disabling the whole check, and stock cannot be observed at the exact moment it
matters, which is when it has hit zero.

FELL AND MACABRE MOODS need corpses instead, and those are gated on MISERY: they happen to
stressed dwarves. So the remains/bones section only appears when at least one citizen is
actually stressed, and it is a warning about your ability to feed such a mood, not a
suggestion to stock up on friends.

    * a MACABRE mood wants remains, bones or skulls, and swaps roughly half its decorations
      for more of the same;
    * a FELL mood wants a fresh corpse and gets it by murdering someone. Nothing you can
      stockpile, so nothing is claimed here about it.

Only loose, usable items count: forbidden, dumped, rotting, hostile-owned and trade goods are
all skipped, as is anything already an artifact.

Run once per DFHack session to register (or add `fort/moody-items-warning` to
dfhack-config/init/dfhack.init).
]]

local NAME = 'moody_items'
local dlg = require('gui.dialogs')

-- the notify panel asks often; a fort's item vectors are cheap but not free
local CACHE_MS = 10000
local cache, cache_at = nil, 0

-- ---- item tests --------------------------------------------------------------

-- flags differ a little between versions; never let a missing one error the panel
local function flag(item, name)
    local ok, v = pcall(function() return item.flags[name] end)
    return ok and v or false
end

local function usable(item)
    return not (flag(item, 'forbid') or flag(item, 'dump') or flag(item, 'garbage_collect')
        or flag(item, 'hostile') or flag(item, 'trader') or flag(item, 'rotten')
        or flag(item, 'artifact') or flag(item, 'owned') or flag(item, 'on_fire'))
end

local function matflag(item, name)
    local ok, mi = pcall(dfhack.matinfo.decode, item)
    if not ok or not mi or not mi.material then return false end
    local ok2, v = pcall(function() return mi.material.flags[name] end)
    return ok2 and v or false
end

-- hard stone: an inorganic that is not soil. Mood stone filters on flags3.hard, which clay
-- and sand boulders fail -- a fort with nothing but soil boulders has no mood stone.
local function hard_stone(item)
    local ok, mi = pcall(dfhack.matinfo.decode, item)
    if not ok or not mi or not mi.inorganic then return false end
    local ok2, soil = pcall(function() return mi.inorganic.flags.SOIL end)
    return not (ok2 and soil)
end

local function metal_bar(item)
    -- mat_type 0 is INORGANIC (metal); a full bar is dimension 150, and the mood asks for
    -- whole bars, so a part-used one does not qualify
    local ok, dim = pcall(function() return item.dimension end)
    return item.mat_type == 0 and (not ok or dim >= 150)
end

local function rough_gem(item)
    return item.mat_type == 0            -- inorganic rough = a gem; glass is its own mat_type
end

local function glass_of(mat_type)
    return function(item) return item.mat_type == mat_type end
end

local function cloth_of(flagname)
    return function(item)
        local ok, dim = pcall(function() return item.dimension end)
        if ok and dim < 10000 then return false end   -- the mood wants whole cloth
        return matflag(item, flagname)
    end
end

local function bone(item) return matflag(item, 'BONE') end
local function shell(item) return matflag(item, 'SHELL') end

-- ---- the categories ----------------------------------------------------------

local function vec(name)
    local ok, v = pcall(function() return df.global.world.items.other[name] end)
    return ok and v or nil
end

local function count(vec_name, test)
    local items = vec(vec_name)
    if not items then return 0 end
    local n = 0
    for _, item in ipairs(items) do
        if usable(item) and (not test or test(item)) then n = n + 1 end
    end
    return n
end

-- everything a mood can ask for that you can actually keep in a stockpile
local CATEGORIES = {
    {label = 'stone boulders',  vec = 'BOULDER',     test = hard_stone},
    {label = 'logs',            vec = 'WOOD'},
    {label = 'tanned leather',  vec = 'SKIN_TANNED'},
    {label = 'metal bars',      vec = 'BAR',         test = metal_bar},
    {label = 'rough gems',      vec = 'ROUGH',       test = rough_gem},
    {label = 'cut gems',        vec = 'SMALLGEM'},
    {label = 'blocks',          vec = 'BLOCKS'},
    {label = 'plant cloth',     vec = 'CLOTH',       test = cloth_of('THREAD_PLANT')},
    {label = 'silk cloth',      vec = 'CLOTH',       test = cloth_of('SILK')},
    {label = 'yarn cloth',      vec = 'CLOTH',       test = cloth_of('YARN')},
    {label = 'bones',           vec = 'CORPSEPIECE', test = bone},
    {label = 'shells',          vec = 'CORPSEPIECE', test = shell},
}

-- glass is asked for only in types this fort has produced (created_item_type history)
local GLASS = {
    {label = 'green glass',   mat = df.builtin_mats.GLASS_GREEN},
    {label = 'clear glass',   mat = df.builtin_mats.GLASS_CLEAR},
    {label = 'crystal glass', mat = df.builtin_mats.GLASS_CRYSTAL},
}

-- Which glass types this fort is expected to keep in stock. Two sources, OR-ed, because
-- either one alone has a hole:
--
--   * the production history (created_item_type), which is what DF itself consults -- but it
--     is a single global read, and if it is ever unreadable this feature silently never
--     warns about anything, which is the worst failure mode available;
--   * glass we have SEEN in the stockpiles, remembered per site. Once a fort has had raw
--     glass of a type, running out of it is exactly the thing worth saying.
--
-- Seen-once is sticky on purpose: the whole point is to warn AFTER it runs out, and a
-- count of zero is precisely when the stock-based half stops being able to see it.
local SITE_KEY = 'moody-items-warning'

local function remembered_glass()
    local ok, data = pcall(dfhack.persistent.getSiteData, SITE_KEY, {glass = {}})
    if not ok or type(data) ~= 'table' or type(data.glass) ~= 'table' then return {} end
    return data.glass
end

local function remember_glass(mat)
    local ok, data = pcall(dfhack.persistent.getSiteData, SITE_KEY, {glass = {}})
    if not ok or type(data) ~= 'table' then return end
    data.glass = type(data.glass) == 'table' and data.glass or {}
    if data.glass[tostring(mat)] then return end
    data.glass[tostring(mat)] = true
    pcall(dfhack.persistent.saveSiteData, SITE_KEY, data)
end

local function produced_glass()
    local made = {}
    pcall(function()
        local types, mats = df.global.created_item_type, df.global.created_item_mattype
        for i = 0, #types - 1 do
            if types[i] == df.item_type.ROUGH then made[mats[i]] = true end
        end
    end)
    local seen = remembered_glass()
    for mat in pairs(seen) do made[tonumber(mat) or -1] = true end
    return made
end

-- ---- stress ------------------------------------------------------------------

-- Fell and macabre moods go to unhappy dwarves, so the corpse section is only relevant
-- once somebody is miserable. getStressCategory runs 0 (ecstatic) .. 6 (miserable).
local STRESSED_AT = 4

local function stressed_citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) and not dfhack.units.isBaby(u) then
            local ok, cat = pcall(dfhack.units.getStressCategory, u)
            if ok and cat and cat >= STRESSED_AT then out[#out + 1] = u end
        end
    end
    return out
end

-- ---- the check ---------------------------------------------------------------

local function survey()
    local now = dfhack.getTickCount()
    if cache and now - cache_at < CACHE_MS then return cache end

    local have, missing = {}, {}
    for _, c in ipairs(CATEGORIES) do
        local n = count(c.vec, c.test)
        have[#have + 1] = {label = c.label, n = n}
        if n == 0 then missing[#missing + 1] = c.label end
    end

    local made = produced_glass()
    for _, g in ipairs(GLASS) do
        local n = count('ROUGH', glass_of(g.mat))
        if n > 0 then remember_glass(g.mat) end     -- seen it: expect it from now on
        if made[g.mat] or n > 0 then
            have[#have + 1] = {label = g.label, n = n}
            if n == 0 then missing[#missing + 1] = g.label end
        end
    end

    -- the fell/macabre section, only while somebody is miserable enough to have one
    local stressed = stressed_citizens()
    local grim, grim_missing = {}, {}
    if #stressed > 0 then
        local remains = count('REMAINS')
        local bones = count('CORPSEPIECE', bone)
        grim[#grim + 1] = {label = 'remains', n = remains}
        grim[#grim + 1] = {label = 'bones', n = bones}
        if remains == 0 then grim_missing[#grim_missing + 1] = 'remains' end
        if bones == 0 then grim_missing[#grim_missing + 1] = 'bones' end
    end

    cache = {have = have, missing = missing, stressed = #stressed,
             grim = grim, grim_missing = grim_missing}
    cache_at = now
    return cache
end

-- ---- the notification --------------------------------------------------------

local function message()
    if not dfhack.world.isFortressMode() then return end
    local ok, s = pcall(survey)
    if not ok or not s then return end

    local n = #s.missing
    local g = #s.grim_missing
    if n == 0 and g == 0 then return end

    local parts = {}
    if n > 0 then
        parts[#parts + 1] = (n == 1)
            and ('No ' .. s.missing[1] .. ' for a strange mood!')
            or (('%d mood materials missing!'):format(n))
    end
    if g > 0 then
        parts[#parts + 1] = (('%d stressed dwarf%s and no %s!'):format(
            s.stressed, s.stressed == 1 and '' or 'ves', table.concat(s.grim_missing, ' or ')))
    end
    return table.concat(parts, '  ')
end

local function show_dialog()
    local s = survey()
    local lines = {'What a strange mood can demand, and what you have:', ''}
    for _, h in ipairs(s.have) do
        lines[#lines + 1] = ('  %-16s %s'):format(h.label, h.n > 0 and ('%d'):format(h.n) or 'NONE')
    end
    if #s.grim > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('%d stressed dwarf%s -- a fell or macabre mood is possible:'):format(
            s.stressed, s.stressed == 1 and '' or 'ves')
        for _, h in ipairs(s.grim) do
            lines[#lines + 1] = ('  %-16s %s'):format(h.label, h.n > 0 and ('%d'):format(h.n) or 'NONE')
        end
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'A fell mood takes a corpse by murder -- nothing to stock for that.'
    end
    if #s.missing == 0 and #s.grim_missing == 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Nothing missing: any mood can be supplied.'
    end
    dlg.showMessage('Mood materials', table.concat(lines, NEWLINE), COLOR_WHITE)
end

-- ---- registration ------------------------------------------------------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Notifies when the fort has none of a material a strange mood could demand.'
    entry.dwarf_fn = message
    entry.on_click = show_dialog
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        cache = nil
        register()
    end
end

if not dfhack_flags.module then
    register()
    print('moody-items-warning: "moody_items" registered.')
    local ok, s = pcall(survey)
    if ok and s then
        print(('  missing now: %s'):format(#s.missing > 0 and table.concat(s.missing, ', ') or 'nothing'))
        if s.stressed > 0 then
            print(('  %d stressed dwarf(s); fell/macabre stock missing: %s'):format(
                s.stressed, #s.grim_missing > 0 and table.concat(s.grim_missing, ', ') or 'nothing'))
        end
    end
    print('  Click the notification for the full list.')
end
