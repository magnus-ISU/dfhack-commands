-- Auto-assign the important fort nobles to your best-suited dwarves.
--@module = true
--[[
embark-nobles
=============
Assigns the key fort positions in one go -- handy right after embark:

  * chief medical dwarf  -- best at the medical skills (Diagnosis, Surgery, ...)
  * militia commander    -- best at weapon / military-leadership skills
  * broker               -- best at Appraisal / negotiation skills
  * manager              -- best at Organization / Record Keeping
  * bookkeeper           -- best at Record Keeping / Organization
  * expedition leader    -- a *different* dwarf from the five above

The five skill roles are filled greedily by skill, each to a distinct dwarf, then
the expedition leader is chosen from whoever is left (preferring social skill), so
all six end up on six different dwarves. (DF has no dedicated bookkeeping/manager
skill, so those use Record Keeping / Organization as the closest proxy.)

    embark-nobles            assign the six positions
    embark-nobles dry        preview the picks without changing anything

Positions live on the fortress group entity (plotinfo.group_id); each already has
an assignment slot, so we reuse it (set histfig + fix the position entity-link),
mirroring make-monarch.
]]

local S = df.job_skill

-- role -> the skills that make a dwarf good at it (summed into a score)
local ROLES = {  -- order = greedy assignment priority (most specialised first)
    {code = 'CHIEF_MEDICAL_DWARF', label = 'chief medical dwarf',
     skills = {S.DIAGNOSE, S.SURGERY, S.SET_BONE, S.SUTURE, S.DRESS_WOUNDS, S.CRUTCH_WALK}},
    {code = 'MILITIA_COMMANDER', label = 'militia commander',
     skills = {S.AXE, S.SWORD, S.MACE, S.HAMMER, S.SPEAR, S.CROSSBOW, S.PIKE, S.WHIP,
               S.BOW, S.BLOWGUN, S.MELEE_COMBAT, S.DISCIPLINE, S.LEADERSHIP, S.TEACHING}},
    {code = 'BROKER', label = 'broker',
     skills = {S.APPRAISAL, S.NEGOTIATION, S.JUDGING_INTENT, S.CONSOLE, S.PACIFY, S.INTIMIDATION, S.LYING}},
    {code = 'MANAGER', label = 'manager',
     skills = {S.ORGANIZATION, S.RECORD_KEEPING, S.APPRAISAL, S.NEGOTIATION}},
    {code = 'BOOKKEEPER', label = 'bookkeeper',
     skills = {S.RECORD_KEEPING, S.ORGANIZATION, S.APPRAISAL}},
}
-- expedition leader: kept distinct from the five; chosen by social/leadership skill
local EXPEDITION = {code = 'EXPEDITION_LEADER', label = 'expedition leader',
    skills = {S.LEADERSHIP, S.NEGOTIATION, S.ORGANIZATION, S.CONSOLE, S.PACIFY, S.JUDGING_INTENT}}

local function fort_entity()
    return df.historical_entity.find(df.global.plotinfo.group_id)
end

-- ---- scoring --------------------------------------------------------------

local function skill_rating(unit, skill_id)
    local soul = unit.status.current_soul
    if not soul then return 0 end
    for _, sk in ipairs(soul.skills) do
        if sk.id == skill_id then return sk.rating end
    end
    return 0
end

local function role_score(unit, role)
    local s = 0
    for _, sk in ipairs(role.skills) do s = s + skill_rating(unit, sk) end
    return s
end

-- adult, living, sane fort citizens that can hold a position
local function candidates()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) and dfhack.units.isAdult(u)
            and u.hist_figure_id >= 0 then
            out[#out + 1] = u
        end
    end
    return out
end

-- ---- position assignment (reuse existing slot; mirrors make-monarch) -------

local function get_position(ent, code)
    for _, p in ipairs(ent.positions.own) do
        if p.code == code then return p end
    end
end

local function get_assignment(ent, position_id)
    local av = ent.positions.assignments
    for i = 0, #av - 1 do
        if av[i].position_id == position_id then return av[i], i end
    end
end

-- drop the holder's POSITION entity-link for this assignment, if present
local function clear_holder_link(ent, assignment)
    if assignment.histfig == -1 then return end
    local oldfig = df.historical_figure.find(assignment.histfig)
    if not oldfig then return end
    for k, v in ipairs(oldfig.entity_links) do
        if df.histfig_entity_link_positionst:is_instance(v)
            and v.assignment_id == assignment.id and v.entity_id == ent.id then
            oldfig.entity_links:erase(k)
            break
        end
    end
end

-- assign `unit` to position `code`; returns ok, message
function assign_position(code, unit)
    local ent = fort_entity()
    local pos = get_position(ent, code)
    if not pos then return false, 'no such position: ' .. code end
    local a, idx = get_assignment(ent, pos.id)
    if not a then return false, 'no assignment slot for ' .. code end
    local figid = unit.hist_figure_id
    if a.histfig == figid then return true, 'already held' end
    clear_holder_link(ent, a)
    a.histfig = figid
    local nf = df.historical_figure.find(figid)
    nf.entity_links:insert('#', {new = df.histfig_entity_link_positionst, entity_id = ent.id,
        link_strength = 100, assignment_id = a.id, assignment_vector_idx = idx,
        start_year = df.global.cur_year})
    return true
end

-- vacate position `code`; returns ok
function unassign_position(code)
    local ent = fort_entity()
    local pos = get_position(ent, code)
    if not pos then return false, 'no such position: ' .. code end
    local a = get_assignment(ent, pos.id)
    if not a then return false, 'no assignment slot for ' .. code end
    clear_holder_link(ent, a)
    a.histfig = -1
    a.histfig2 = -1
    return true
end

-- who currently holds position `code` (unit, or nil)
function current_holder(code)
    local ent = fort_entity()
    local pos = get_position(ent, code)
    if not pos then return nil end
    local a = get_assignment(ent, pos.id)
    if not a or a.histfig == -1 then return nil end
    local fig = df.historical_figure.find(a.histfig)
    return fig and df.unit.find(fig.unit_id) or nil
end

-- ---- selection ------------------------------------------------------------

-- choose the six dwarves; returns an ordered list of {role, unit, score}
function plan()
    local cands = candidates()
    local used, picks = {}, {}
    local function best_for(role, allow_used)
        local best, score
        for _, u in ipairs(cands) do
            if allow_used or not used[u.id] then
                local sc = role_score(u, role)
                if not best or sc > score then best, score = u, sc end
            end
        end
        return best, score
    end
    for _, role in ipairs(ROLES) do
        local u, sc = best_for(role, false)
        if not u then u, sc = best_for(role, true) end   -- fewer dwarves than roles
        if u then
            used[u.id] = true
            picks[#picks + 1] = {role = role, unit = u, score = sc}
        end
    end
    -- expedition leader: a different dwarf (unused); fall back to anyone if tiny fort
    local u, sc = best_for(EXPEDITION, false)
    if not u then u, sc = best_for(EXPEDITION, true) end
    if u then picks[#picks + 1] = {role = EXPEDITION, unit = u, score = sc} end
    return picks
end

-- ---- command --------------------------------------------------------------

if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('embark-nobles only works in fortress mode')
end

local args = {...}
local dry = args[1] == 'dry' or args[1] == 'list' or args[1] == '-n'

local picks = plan()
if #picks == 0 then
    qerror('no adult citizens available to assign')
end

print(dry and 'embark-nobles (dry run -- nothing changed):' or 'embark-nobles: assigning fort positions')
for _, p in ipairs(picks) do
    local name = dfhack.units.getReadableName(p.unit)
    local ok, msg = true, nil
    if not dry then ok, msg = assign_position(p.role.code, p.unit) end
    print(('  %-20s -> %-28s (skill score %d)%s'):format(
        p.role.label, name, p.score or 0, ok and '' or ('  ! ' .. tostring(msg))))
end
if dry then print('  run `embark-nobles` (no args) to apply.') end
