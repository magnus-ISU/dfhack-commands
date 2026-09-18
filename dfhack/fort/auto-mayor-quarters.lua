-- Hand the zones named "Mayor" to whoever is mayor now, every time the office changes hands.
--@module = true
--@enable = true
--[[
fort/auto-mayor-quarters

The mayor is elected, and re-elected, and replaced -- and every time the office changes hands
the quarters stay with the LAST mayor, because rooms are assigned to a dwarf, not to a
position. So the new mayor sulks over unmet room demands while the old one keeps the tower.

Name the rooms and this does the handover. Any bedroom, dining hall, tomb or office zone whose
name contains "Mayor" (any case: "Mayor's Tower Office", "mayor bedroom") is the mayor's
quarters of that kind. When DF announces an election or a succession -- "X has been elected
mayor." -- every such zone the new mayor does not already own is reassigned to them, and the
same is done once when the watcher starts, for an election it missed.

ONE ZONE PER KIND: if two bedrooms are named for the mayor
this does nothing with bedrooms at all and says so on the console, because guessing which
one you meant would be worse than leaving both. Kinds are independent -- a fort with a mayor
office and no mayor tomb hands over the office and ignores the tomb.

Nothing else is touched: zones without "Mayor" in the name, other nobles, the previous
mayor's other rooms. A fort with no mayor (the office is vacant, or the position does not
exist for this civilization) does nothing until there is one.

    enable auto-mayor-quarters     watch for the election announcement and hand over (persists)
    disable auto-mayor-quarters    stop watching
    auto-mayor-quarters            hand over once now, and report what is named and who owns it
]]

local GLOBAL_KEY = 'auto-mayor-quarters'
local CHECK_FRAMES = 100            -- ~2s between looks at the announcement log

-- the zone kinds that make up a set of quarters: vector name -> what to call it
local KINDS = {
    {vec = 'ZONE_BEDROOM',     label = 'bedroom'},
    {vec = 'ZONE_DINING_HALL', label = 'dining hall'},
    {vec = 'ZONE_TOMB',        label = 'tomb'},
    {vec = 'ZONE_OFFICE',      label = 'office'},
}

-- ---- state --------------------------------------------------------------------

state = state or nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- who is mayor -------------------------------------------------------------

-- the live unit holding the fort's MAYOR position, or nil
local function mayor()
    local ent = df.historical_entity.find(df.global.plotinfo.group_id)
    if not ent then return nil end
    local pos_id
    for _, p in ipairs(ent.positions.own) do
        if p.code == 'MAYOR' then pos_id = p.id; break end
    end
    if not pos_id then return nil end
    for _, a in ipairs(ent.positions.assignments) do
        if a.position_id == pos_id and a.histfig >= 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u and not dfhack.units.isDead(u) then return u end
        end
    end
    return nil
end

-- ---- the named zones ----------------------------------------------------------

-- For each kind: the one zone named for the mayor, or the list of several (an error), or
-- nothing. `zone` is set when exactly one; `many` lists them when more than one.
function named_zones()
    local out = {}
    for _, kind in ipairs(KINDS) do
        local found = {}
        for _, z in ipairs(df.global.world.buildings.other[kind.vec]) do
            if z.name:lower():find('mayor', 1, true) then found[#found + 1] = z end
        end
        out[#out + 1] = {kind = kind, zone = #found == 1 and found[1] or nil,
                         many = #found > 1 and found or nil}
    end
    return out
end

-- ---- the handover -------------------------------------------------------------

-- module-level so a repeated ambiguity is said once, not every six seconds
local warned = {}

-- reassign every unambiguous named zone the mayor does not already own; returns the number
-- changed. `quiet` suppresses the per-zone console line (the watcher still says what it did).
function handover(quiet)
    local m = mayor()
    if not m then return 0 end
    local changed = 0
    for _, e in ipairs(named_zones()) do
        if e.many then
            if not warned[e.kind.label] then
                warned[e.kind.label] = true
                local names = {}
                for _, z in ipairs(e.many) do names[#names + 1] = '"' .. dfhack.df2console(z.name) .. '"' end
                dfhack.printerr(('auto-mayor-quarters: %d %ss are named for the mayor (%s) -- name exactly one')
                    :format(#e.many, e.kind.label, table.concat(names, ', ')))
            end
        elseif e.zone then
            warned[e.kind.label] = nil
            if e.zone.assigned_unit_id ~= m.id then
                dfhack.buildings.setOwner(e.zone, m)
                changed = changed + 1
                if not quiet then
                    print(('auto-mayor-quarters: %s "%s" -> %s'):format(e.kind.label,
                        dfhack.df2console(e.zone.name), dfhack.df2console(dfhack.units.getReadableName(m))))
                end
            end
        end
    end
    return changed
end

-- ---- the watcher --------------------------------------------------------------
--
-- DF announces the election -- "X has been elected mayor." (ELECTION_RESULTS) -- and a
-- succession (FORT_POSITION_SUCCESSION), so that is what is watched: a watermark on the
-- report id, and only the announcements added since the last look are read. No walk of
-- the zone list until one of those lands, plus once when the watcher starts, for a mayor
-- elected while it was not running.
local ELECTION = {
    [df.announcement_type.ELECTION_RESULTS] = true,
    [df.announcement_type.FORT_POSITION_SUCCESSION] = true,
}
local last_report = nil

local function election_since_last_look()
    local reports = df.global.world.status.reports
    local top = df.global.world.status.next_report_id - 1
    if not last_report then last_report = top; return false end
    local hit = false
    for i = #reports - 1, 0, -1 do
        local r = reports[i]
        if r.id <= last_report then break end
        if ELECTION[r.type] then hit = true end
    end
    last_report = top
    return hit
end

-- generation lives in dfhack.internal so a hot reload's start retires the old closure
local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_mayor_quarters_hb_gen = set end
    return dfhack.internal.auto_mayor_quarters_hb_gen or 0
end

local function announce_handover(n)
    if n <= 0 then return end
    local m = mayor()
    print(('auto-mayor-quarters: handed %d zone%s to the mayor, %s'):format(
        n, n == 1 and '' or 's', dfhack.df2console(dfhack.units.getReadableName(m))))
end

local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    last_report = nil
    if dfhack.world.isFortressMode() then announce_handover(handover(true)) end
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        if dfhack.world.isFortressMode() and election_since_last_look() then
            announce_handover(handover(true))
        end
        dfhack.timeout(CHECK_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if v then start_heartbeat() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, warned = nil, {}
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- entry point --------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then
    -- a reload with a watcher already ticking: take the tick over from the old copy
    if hb_gen() > 0 and dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    return
end

if not dfhack.world.isFortressMode() then qerror('auto-mayor-quarters only works in fortress mode') end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('auto-mayor-quarters: ' .. (isEnabled() and 'ENABLED (watching the mayoralty)' or 'disabled'))
    return
end

local m = mayor()
local n = handover(false)
print(('auto-mayor-quarters: mayor is %s; %d zone%s reassigned.'):format(
    m and dfhack.df2console(dfhack.units.getReadableName(m)) or 'nobody', n, n == 1 and '' or 's'))
for _, e in ipairs(named_zones()) do
    if e.zone then
        local o = df.unit.find(e.zone.assigned_unit_id)
        print(('  %-12s "%s" -- %s'):format(e.kind.label, dfhack.df2console(e.zone.name),
            o and dfhack.df2console(dfhack.units.getReadableName(o)) or 'unassigned'))
    elseif e.many then
        print(('  %-12s %d zones named for the mayor -- name exactly one'):format(e.kind.label, #e.many))
    else
        print(('  %-12s no zone named "Mayor"'):format(e.kind.label))
    end
end
