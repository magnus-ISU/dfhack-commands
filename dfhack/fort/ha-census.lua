-- Census of the world currently in memory: population over time, sites, terrain.
-- Run straight after worldgen finishes, before saving.
local W = df.global.world
local wd = W.world_data

local function nice(c)
    return (tostring(c or '?'):gsub('^HA_', ''):gsub('_CIV$', ''):gsub('_', ' '))
end

local idx = {}
for i, cr in ipairs(W.raws.creatures.all) do idx[tostring(cr.creature_id)] = i end

local RACES = {
    {'Humans', idx.HUMAN}, {'Orcs', idx.HA_ORC}, {'Elves', idx.ELF},
    {'High elves', idx.HA_HIGH_ELF}, {'Goblins', idx.GOBLIN}, {'Dwarves', idx.DWARF},
    {'Dark dwarves', idx.HA_DARK_DWARF}, {'Drow', idx.HA_DROW},
    {'Illithids', idx.HA_ILLITHID}, {'Succubi', idx.HA_SUCCUBUS_CIV},
    {'Kobolds', idx.HA_KOBOLD}, {'Ancient dragons', idx.HA_ANCIENT_DRAGON},
}
local YEARS = {1, 25, 50, 75, 100}

print(('=== WORLD: %s   size %dx%d   year %d   sites %d ==='):format(
    dfhack.translation.translateName(wd.name, true),
    wd.world_width, wd.world_height, df.global.cur_year, #wd.sites))
print('')

-- population over time, from birth/death years of historical figures
local rows = {}
for _, r in ipairs(RACES) do rows[#rows + 1] = {r[1], {0, 0, 0, 0, 0}, r[2]} end
local F = W.history.figures
for i = 0, #F - 1 do
    local h = F[i]
    local ok, skip = pcall(function() return h.flags.deity or h.flags.force end)
    if not (ok and skip) then
        for yi, y in ipairs(YEARS) do
            if h.born_year <= y and (h.died_year < 0 or h.died_year > y) then
                for _, r in ipairs(rows) do
                    if h.race == r[3] then r[2][yi] = r[2][yi] + 1 end
                end
            end
        end
    end
end

-- current head count, civ count and sites, off the entity records
local code, pop, civs, sites, castles = {}, {}, {}, {}, {}
for _, e in ipairs(W.entities.all) do
    local ok, c = pcall(function() return nice(tostring(e.entity_raw.code)) end)
    if ok then
        code[e.id] = c
        if e.type == df.historical_entity_type.Civilization then civs[c] = (civs[c] or 0) + 1 end
        local ok2, t = pcall(function() return e.total_pop end)
        if ok2 and t > 0 then pop[c] = (pop[c] or 0) + t end
    end
end

local function terrain_of(s)
    local ok, t = pcall(function()
        local rme = wd.region_map[s.pos.x]:_displace(s.pos.y)
        return tostring(df.world_region_type[wd.regions[rme.region_id].type])
    end)
    return ok and t or '?'
end

local terr = {}
for _, s in ipairs(wd.sites) do
    local c = s.civ_id >= 0 and code[s.civ_id] or nil
    if c then
        sites[c] = (sites[c] or 0) + 1
        if tostring(df.world_site_type[s.type]) == 'Fortress' then
            castles[c] = (castles[c] or 0) + 1
        end
        local b = terrain_of(s)
        terr[c] = terr[c] or {}
        terr[c][b] = (terr[c][b] or 0) + 1
    end
end

print('=== POPULATION (historical figures alive at year Y) ===')
local hdr = ('%-18s'):format('')
for _, y in ipairs(YEARS) do hdr = hdr .. ('%8s'):format('y' .. y) end
print(hdr)
for _, r in ipairs(rows) do
    local l = ('%-18s'):format(r[1])
    for j = 1, 5 do l = l .. ('%8d'):format(r[2][j]) end
    print(l)
end

print('')
print('=== FINAL STATE (year ' .. df.global.cur_year .. ') ===')
local l = {}
for c, n in pairs(pop) do l[#l + 1] = {c, n, civs[c] or 0, sites[c] or 0, castles[c] or 0} end
table.sort(l, function(a, b) return a[2] > b[2] end)
print(('%-18s %9s %6s %7s %8s'):format('civ', 'pop', 'civs', 'sites', 'castles'))
for _, x in ipairs(l) do
    print(('%-18s %9d %6d %7d %8d'):format(x[1], x[2], x[3], x[4], x[5]))
end

print('')
print('=== SITE TERRAIN BY CIV ===')
for _, x in ipairs(l) do
    local t = terr[x[1]]
    if t then
        local b = {}
        for k, v in pairs(t) do b[#b + 1] = {k, v} end
        table.sort(b, function(p, q) return p[2] > q[2] end)
        local parts = {}
        for i = 1, #b do parts[#parts + 1] = b[i][1]:lower() .. '=' .. b[i][2] end
        print(('  %-16s %s'):format(x[1], table.concat(parts, '  ')))
    end
end

print('')
print('=== TERRAIN AVAILABLE ON THE MAP ===')
local T, tot = {}, 0
for x = 0, wd.world_width - 1 do
    for y = 0, wd.world_height - 1 do
        local ok, t = pcall(function()
            local rme = wd.region_map[x]:_displace(y)
            return tostring(df.world_region_type[wd.regions[rme.region_id].type])
        end)
        if ok then T[t] = (T[t] or 0) + 1; tot = tot + 1 end
    end
end
local tl = {}
for t, n in pairs(T) do tl[#tl + 1] = {t, n} end
table.sort(tl, function(a, b) return a[2] > b[2] end)
for _, x in ipairs(tl) do
    print(('  %-12s %6d  %4.1f%%'):format(x[1], x[2], 100 * x[2] / tot))
end
