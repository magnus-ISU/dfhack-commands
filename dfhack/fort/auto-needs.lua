-- Lend a dwarf whose need is eating them a labor that satisfies it, and take it back after.
--@module = true
--[[
fort/auto-needs

A dwarf with an unmet need does not tell you which one; the thought log says "has been
unable to leave the fortress lately" and the stress climbs and that is all the warning
there is. Some of those needs have a LABOR that answers them, and this hands that labor
out to the dwarves who need it -- then takes it back once they have had their fill, so
the fort's job assignments are not quietly rewritten forever by a mood that has passed.

TODAY IT KNOWS ONE NEED:

  WANDER -> FISHING. "Wander" is satisfied by being outside the fortress, and fishing is
  the reliable way a dwarf takes themselves out there and stays a while. Given the labor,
  a wandering-starved dwarf walks to the water, and the need drains on its own.

  The dwarf must be BOTH short on the need and carrying stress -- the need alone is
  ordinary (half a fort is a little short of wandering at any time) and the stress alone
  says nothing about which need is doing it.

HOW A LABOR IS ACTUALLY GIVEN

  Not by writing `unit.status.labors`. In this version of DF the WORK DETAILS own that flag:
  they are recomputed from the detail list, and a labor set by hand is wiped the next time
  anything recomputes -- measured here, twice, before the cause was found. So the dwarf is
  added to the work detail that carries the labor, the detail is put in "only the selected
  do this" mode if it was sitting at "nobody does this" (which is where a fort that has
  never fished leaves it), and `setAutomaticProfessions` is called on the dwarf, because DF
  only applies a detail when somebody clicks on its screen.

  The mode is put BACK the way it was found once the tool has nobody assigned there and the
  detail is empty again -- a fort that had fishing switched off does not silently end up with
  it switched on for good.

WHAT IT GIVES BACK

  A labor this tool turned ON is remembered, and turned OFF again once the dwarf no longer
  qualifies -- their need filled, or their stress gone. A labor the dwarf ALREADY HAD is
  never recorded and never removed: a fisherdwarf who was fishing before stays a
  fisherdwarf afterwards, and this tool will not be the reason the fort lost its fishing.
  The record lives with the site, so a save and reload does not strand a lent labor.

    fort/auto-needs             what it would do, and what it is holding
    fort/auto-needs once        run one pass now
    enable fort/auto-needs      run a pass a few times a day
    fort/auto-needs -n          a pass that changes nothing (with `once`)

THE THRESHOLDS

  A need's `focus_level` goes NEGATIVE as it goes unmet -- badly unmet reads in the
  thousands below zero -- and `personality.stress` is DF's own running total, where higher
  is worse and a negative total is a dwarf in credit. The bars here are deliberately LOW:
  the point is to catch a dwarf on the way down rather than after the tantrum, and the
  worst that a false positive costs is a dwarf who goes fishing for a while.
]]

local GLOBAL_KEY = 'auto-needs'

-- How far a need has to have slipped, and how much stress has to be riding on it. BOTH BARS
-- ARE AS LOW AS THEY GO: any shortfall at all on the need, any stress at all on the dwarf.
-- Waiting for a badly unmet need (the focus levels run into the thousands below zero) means
-- waiting for a dwarf who is already in trouble -- measured here, the fort had nine stressed
-- citizens and eleven who want to wander, and not one of them was past -1000 yet. The one this
-- catches, a chief medical dwarf at 16,224 stress and -594 focus, is exactly the case: short of
-- wandering, plainly suffering, and a long way from the tantrum that would make it obvious.
local FOCUS_UNMET = -1        -- focus_level below zero at all = the need is going short
local STRESS_MIN = 1          -- any stress at all; a dwarf in credit is left alone
local SCAN_FRAMES = 1200      -- a pass every game day or so

-- need -> the labor that answers it. One entry today; the shape is the point.
local RULES = {
    {need = df.need_type.Wander, labor = df.unit_labor.FISH,
     why = 'wander', gives = 'fishing'},
}

-- ---- state: the labors WE lent, per site ------------------------------------

local state = nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
        state.lent = state.lent or {}      -- ["unit_id/labor"] = true
        state.lent = type(state.lent) == 'table' and state.lent or {}
    end
    return state
end
local function save_state() pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

local function lent_key(unit, labor) return ('%d/%d'):format(unit.id, labor) end

-- ---- the work detail that carries a labor ------------------------------------

local function detail_for(labor)
    local details = df.global.plotinfo.labor_info.work_details
    for i = 0, #details - 1 do
        if details[i].allowed_labors[labor] then return details[i] end
    end
end

local function detail_has(detail, unit)
    for _, id in ipairs(detail.assigned_units) do
        if id == unit.id then return true end
    end
    return false
end

-- put the detail to work if the fort had it switched off, remembering what it was
local function ensure_mode(detail, s)
    local mode = detail.flags.mode
    if mode == df.work_detail_mode.OnlySelectedDoesThis then return end
    s.modes = s.modes or {}
    if s.modes[detail.name] == nil then s.modes[detail.name] = mode end
    detail.flags.mode = df.work_detail_mode.OnlySelectedDoesThis
end

-- and put it back once we have nobody there and neither has anyone else
local function restore_mode(detail, s)
    s.modes = s.modes or {}
    local was = s.modes[detail.name]
    if was == nil or #detail.assigned_units > 0 then return end
    detail.flags.mode = was
    s.modes[detail.name] = nil
end

-- ---- the rule ---------------------------------------------------------------

-- how short this dwarf is on `need`, or nil when they do not have it at all. A dwarf's
-- needs are DERIVED from their personality: not every dwarf wants to wander.
local function need_focus(unit, need)
    local soul = unit.status.current_soul
    if not soul then return nil end
    for _, n in ipairs(soul.personality.needs) do
        if n.id == need then return n.focus_level end
    end
end

local function stress_of(unit)
    local soul = unit.status.current_soul
    return soul and soul.personality.stress or 0
end

-- does this dwarf want the labor right now?
local function qualifies(unit, rule)
    local focus = need_focus(unit, rule.need)
    if not focus or focus > FOCUS_UNMET then return false end
    return stress_of(unit) >= STRESS_MIN
end

local function citizens()
    local out = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and not dfhack.units.isDead(unit)
                and dfhack.units.isAdult(unit) then
            out[#out + 1] = unit
        end
    end
    return out
end

-- One pass. Returns the lists, so `once` can report and `-n` can report without acting.
-- `missing` names any rule whose labor no work detail carries -- nothing can be lent then.
function scan(dry)
    local s = load_state()
    local given, taken, kept, missing = {}, {}, 0, {}
    local seen = {}

    for _, rule in ipairs(RULES) do
        local detail = detail_for(rule.labor)
        if not detail then
            missing[#missing + 1] = rule
        else
            for _, unit in ipairs(citizens()) do
                local key = lent_key(unit, rule.labor)
                seen[key] = true
                local ours = s.lent[key]
                local assigned = detail_has(detail, unit)
                if qualifies(unit, rule) then
                    if assigned or unit.status.labors[rule.labor] then
                        -- theirs already, or ours from an earlier pass
                        if ours then kept = kept + 1 end
                    elseif not dry then
                        ensure_mode(detail, s)
                        detail.assigned_units:insert('#', unit.id)
                        pcall(dfhack.units.setAutomaticProfessions, unit)
                        s.lent[key] = true
                        given[#given + 1] = {unit = unit, rule = rule}
                    else
                        given[#given + 1] = {unit = unit, rule = rule}
                    end
                elseif ours then
                    -- had their fill (or the stress went): give the labor back
                    if not dry then
                        for i = #detail.assigned_units - 1, 0, -1 do
                            if detail.assigned_units[i] == unit.id then
                                detail.assigned_units:erase(i)
                            end
                        end
                        s.lent[key] = nil
                        pcall(dfhack.units.setAutomaticProfessions, unit)
                        restore_mode(detail, s)
                    end
                    taken[#taken + 1] = {unit = unit, rule = rule}
                end
            end
        end
    end

    -- a dwarf who died, left, or stopped being a citizen is not ours to bookkeep
    if not dry then
        for key in pairs(s.lent) do
            if not seen[key] then s.lent[key] = nil end
        end
        save_state()
    end
    return given, taken, kept, missing
end

-- ---- heartbeat --------------------------------------------------------------

local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_needs_hb_gen = set end
    return dfhack.internal.auto_needs_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        pcall(scan)
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

local function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if v then start_heartbeat(); pcall(scan) else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- entry point ------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('auto-needs only works in fortress mode') end
    set_enabled(dfhack_flags.enable_state)
    print('auto-needs: ' .. (isEnabled() and 'ENABLED (a pass a day)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('auto-needs only works in fortress mode') end

local args = {...}
local dry = false
for _, a in ipairs(args) do
    if a == '-n' or a == '--dry-run' then dry = true end
end
local once = args[1] == 'once' or (args[1] == nil and false)

local given, taken, kept, missing = scan(dry or not once)
local function name(e) return dfhack.units.getReadableName(e.unit) end

if not once then
    print('auto-needs: ' .. (isEnabled() and 'enabled' or 'disabled')
        .. ' -- one need known: an unmet WANDER gets the FISHING labor.')
end
local tag = (dry or not once) and '[dry] ' or ''
if #given > 0 then
    print(('%s%d dwarf/dwarves given fishing for an unmet wander need:'):format(tag, #given))
    for _, e in ipairs(given) do
        print(('    %s (focus %d, stress %d)'):format(name(e),
            need_focus(e.unit, e.rule.need), stress_of(e.unit)))
    end
else
    print(tag .. 'nobody is short enough on a need this tool can answer.')
end
if #taken > 0 then
    print(('%s%d had their lent labor taken back:'):format(tag, #taken))
    for _, e in ipairs(taken) do print('    ' .. name(e)) end
end
if kept > 0 then print(('  %d still holding a labor lent earlier.'):format(kept)) end
for _, rule in ipairs(missing or {}) do
    print(('  NOTHING TO LEND: no work detail carries %s, so the %s need cannot be answered.')
        :format(rule.gives, rule.why))
    print('  Make a work detail with that labor (any name) and this will use it.')
end
