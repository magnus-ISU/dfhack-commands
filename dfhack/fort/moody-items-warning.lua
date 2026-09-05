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

Only items you could actually spend count: dumped, rotting, burning, hostile-owned and trade
goods are skipped, as is anything already an artifact. Forbidden ones are skipped too UNLESS
one of this repo's own tools forbade them -- what fort/help-mood is holding for a mood in
progress is still stock you have, while a forbidden cave swallow's remains lying in a cavern
is not.

Run once per DFHack session to register (or add `fort/moody-items-warning` to
dfhack-config/init/dfhack.init).
]]

local NAME = 'moody_items'
local dlg = require('gui.dialogs')

-- the notify panel asks often; a fort's item vectors are cheap but not free
local CACHE_MS = 10000
local MOOD_WANTS = 3      -- the most of one thing a mood asks for; below this is a near miss
local cache, cache_at = nil, 0

-- ---- item tests --------------------------------------------------------------

-- flags differ a little between versions; never let a missing one error the panel
local function flag(item, name)
    local ok, v = pcall(function() return item.flags[name] end)
    return ok and v or false
end

-- FORBIDDEN IS NOT MISSING. A forbidden shell is one you have; you would unforbid it, not go
-- hunting for another. Counting it as absent also set this tool against the rest of the repo,
-- since fort/help-mood forbids every candidate it reserves for a mood in progress -- the
-- better that did its job, the louder this insisted the fort was empty.
--
-- The rest of the list stays: dumped, rotting, on fire, somebody else's, a trader's or
-- already an artifact are all things you genuinely cannot spend.
local function usable(item)
    return not (flag(item, 'dump') or flag(item, 'garbage_collect')
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

-- ---- who could actually ask for a shell? -------------------------------------
--
-- Shells are the one mood material gated on a PREFERENCE rather than on stock. DFHack's
-- strangemood plugin (which reimplements DF's own selection) picks the bone carver's base
-- material as bones, and shells only for a dwarf who likes a type of shell -- the wiki says
-- the same: "Bone carvers will demand shells if they like a type of shell; if not, they will
-- demand bones." Unlike raw glass (`have_glass[]`) and metal bars (`getCreatedMetalBars()`),
-- there is NO "has the fort ever had one" check, so a shell-lover can demand a shell this
-- fort has never owned -- and a fort with nobody who likes one can never be asked at all.
--
-- So the shells line only appears when somebody here likes a shell. Shells are not in the
-- decoration list either (logs, bars, cut gems, blocks, rough gems, boulders, bones, leather,
-- cloth, raw glass), so a bone-carving mood is the only way one is ever demanded.
local LIKE_MATERIAL = df.unitpref_type.LikeMaterial

local function likes_a_shell(u)
    local soul = u.status.current_soul
    if not soul then return false end
    for _, p in ipairs(soul.preferences) do
        if p.type == LIKE_MATERIAL and p.matindex >= 0 then
            local mi = dfhack.matinfo.decode(p.mattype, p.matindex)
            if mi and mi.material and mi.material.flags.SHELL then return true end
        end
    end
    return false
end

local function anyone_likes_a_shell()
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and likes_a_shell(u) then return true end
    end
    return false
end

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
    {label = 'shells',          vec = 'CORPSEPIECE', test = shell, gate = anyone_likes_a_shell},
}

-- glass is asked for only in types this fort has produced (created_item_type history)
-- "raw", the way DF names the item. "crystal glass" on its own reads like a window or a
-- block; what a mood wants and what you have to go and make is RAW glass.
local GLASS = {
    {label = 'raw green glass',   mat = df.builtin_mats.GLASS_GREEN},
    {label = 'raw clear glass',   mat = df.builtin_mats.GLASS_CLEAR},
    {label = 'raw crystal glass', mat = df.builtin_mats.GLASS_CRYSTAL},
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

    local have, missing, low = {}, {}, {}
    -- A mood asks for up to three of a thing. Having ONE bar of the metal it settles on is
    -- the same dead end as having none, found a day later, so the warning starts at the
    -- number a mood can actually demand rather than at zero.
    local function note(label, n)
        have[#have + 1] = {label = label, n = n}
        if n == 0 then missing[#missing + 1] = label
        elseif n < MOOD_WANTS then low[#low + 1] = {label = label, n = n} end
    end
    for _, c in ipairs(CATEGORIES) do
        -- a gated category is only surveyed when this fort could be asked for it at all
        if not c.gate or c.gate() then
            note(c.label, count(c.vec, c.test))
        end
    end

    local made = produced_glass()
    for _, g in ipairs(GLASS) do
        local n = count('ROUGH', glass_of(g.mat))
        if n > 0 then remember_glass(g.mat) end     -- seen it: expect it from now on
        if made[g.mat] or n > 0 then note(g.label, n) end
    end

    -- the fell/macabre section, only while somebody is miserable enough to have one
    local stressed = stressed_citizens()
    local grim, grim_missing, grim_low = {}, {}, {}
    if #stressed > 0 then
        for label, n in pairs{remains = count('REMAINS'), bones = count('CORPSEPIECE', bone)} do
            grim[#grim + 1] = {label = label, n = n}
            if n == 0 then grim_missing[#grim_missing + 1] = label
            elseif n < MOOD_WANTS then grim_low[#grim_low + 1] = {label = label, n = n} end
        end
        table.sort(grim, function(a, b) return a.label < b.label end)
        table.sort(grim_missing)
    end

    cache = {have = have, missing = missing, low = low, stressed = #stressed,
             grim = grim, grim_missing = grim_missing, grim_low = grim_low}
    cache_at = now
    return cache
end

-- ---- the notification --------------------------------------------------------

function message()   -- module-level: the notification resolves it live, see register()
    if not dfhack.world.isFortressMode() then return end
    local ok, s = pcall(survey)
    if not ok or not s then return end

    -- one list, one sentence: the remains/bones gap reads as just another thing a mood could
    -- ask for and we haven't got.
    --
    -- ALWAYS NAMED, however many there are. A long list used to collapse to "5 mood materials
    -- missing!" on the grounds that naming them stopped being readable -- and a fort nearly
    -- lost a mood to that, because the one that mattered was raw crystal glass and the line
    -- did not say so. A count tells you nothing you can act on; the names are the whole
    -- point, and this is the only thing in the fort that says them out loud.
    local gone = {}
    for _, m in ipairs(s.missing) do gone[#gone + 1] = m end
    for _, m in ipairs(s.grim_missing) do gone[#gone + 1] = m end

    -- "one shell" is not a supply, it is a near miss, and it reads as a different kind of
    -- problem: nothing to go and find, just not enough of it yet. So the two are separate
    -- clauses rather than one list, and the count is named -- "2 bones" tells you how far off
    -- you are in a way "low on bones" never does.
    local short = {}
    for _, m in ipairs(s.low or {}) do
        short[#short + 1] = ('%d %s'):format(m.n, m.label)
    end
    for _, m in ipairs(s.grim_low or {}) do
        short[#short + 1] = ('%d %s'):format(m.n, m.label)
    end

    if #gone == 0 and #short == 0 then return end
    local parts = {}
    if #gone > 0 then parts[#parts + 1] = ('No %s'):format(table.concat(gone, ', ')) end
    if #short > 0 then parts[#parts + 1] = ('only %s'):format(table.concat(short, ', ')) end
    return ('%s for a mood'):format(table.concat(parts, '; '))
end

function show_dialog()   -- module-level: the notification resolves it live, see register()
    local s = survey()
    -- the count alone does not say whether it is enough, so the row says which it is
    local function row(h)
        local mark = ''
        if h.n == 0 then mark = 'NONE'
        elseif h.n < MOOD_WANTS then mark = ('%d  -- short, a mood can ask for %d')
            :format(h.n, MOOD_WANTS)
        else mark = ('%d'):format(h.n) end
        return ('  %-16s %s'):format(h.label, mark)
    end
    local lines = {('What a strange mood can demand, and what you have. A mood asks for up to')
        :format(), ('%d of a thing, so anything under that is counted short:'):format(MOOD_WANTS), ''}
    for _, h in ipairs(s.have) do lines[#lines + 1] = row(h) end
    if #s.grim > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('%d stressed %s -- a macabre mood is possible:'):format(
            s.stressed, s.stressed == 1 and 'dwarf' or 'dwarves')
        for _, h in ipairs(s.grim) do lines[#lines + 1] = row(h) end
    end
    if #s.missing == 0 and #s.grim_missing == 0 and #(s.low or {}) == 0
        and #(s.grim_low or {}) == 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Nothing short: any mood can be supplied.'
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
    -- Resolved live rather than pinned: a stored function value keeps the notification running
    -- the copy of this file that was loaded when it registered, so an edited script reports the
    -- old answer from the panel while the command line reports the new one.
    local function live()
        local ok, m = pcall(reqscript, 'fort/moody-items-warning')
        return (ok and m) or nil
    end
    entry.dwarf_fn = function()
        local m = live()
        return (m and m.message or message)()
    end
    entry.on_click = function()
        local m = live()
        return (m and m.show_dialog or show_dialog)()
    end
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
            print(('  %d stressed dwarf(s); macabre stock missing: %s'):format(
                s.stressed, #s.grim_missing > 0 and table.concat(s.grim_missing, ', ') or 'nothing'))
        end
    end
    print('  Click the notification for the full list.')
end
