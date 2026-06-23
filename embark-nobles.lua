-- Auto-assign the important fort nobles to your best-suited dwarves.
--@module = true
--[[
embark-nobles
=============
Fills any VACANT key fort positions (already-assigned ones are left untouched) --
handy right after embark, and safe to re-run:

  * chief medical dwarf  -- best at the medical skills (Diagnosis, Surgery, ...)
  * militia commander    -- best at weapon / military-leadership skills
  * broker               -- best at Appraisal / negotiation skills
  * manager              -- best at Organization / Record Keeping
  * bookkeeper           -- best at Record Keeping / Organization
  * expedition leader    -- a *different* dwarf from the five above

Only vacant positions are filled. The five skill roles each go to the best-skilled
dwarf (a dwarf MAY hold more than one of them). The expedition leader is forced to
be a *different* dwarf from whoever holds those five. (DF has no dedicated
bookkeeping/manager skill, so those use Record Keeping / Organization as the
closest proxy.)

    embark-nobles            fill the vacant positions
    embark-nobles dry        preview without changing anything

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
-- Only VACANT positions are filled; already-held ones are left alone. Returns an
-- ordered list of {role, unit, score, action} where action is 'kept' (already
-- held), 'fill' (vacant -> assign this unit), or 'none' (vacant, no candidate).
function plan()
    local cands = candidates()
    local picks = {}
    local five_ids = {}   -- unit ids holding the five skill roles (held or to-fill)
    local function best_for(role, exclude)
        local best, score
        for _, u in ipairs(cands) do
            if not (exclude and exclude[u.id]) then
                local sc = role_score(u, role)
                if not best or sc > score then best, score = u, sc end
            end
        end
        return best, score
    end
    for _, role in ipairs(ROLES) do
        local held = current_holder(role.code)
        if held then
            five_ids[held.id] = true
            picks[#picks + 1] = {role = role, unit = held, action = 'kept'}
        else
            -- best-skilled dwarf; a dwarf MAY hold several of the five
            local u, sc = best_for(role)
            if u then
                five_ids[u.id] = true
                picks[#picks + 1] = {role = role, unit = u, score = sc, action = 'fill'}
            else
                picks[#picks + 1] = {role = role, action = 'none'}
            end
        end
    end
    -- expedition leader: only if vacant, and a different dwarf from the five
    local held = current_holder(EXPEDITION.code)
    if held then
        picks[#picks + 1] = {role = EXPEDITION, unit = held, action = 'kept'}
    else
        local u, sc = best_for(EXPEDITION, five_ids)     -- distinct from the five
        if not u then u, sc = best_for(EXPEDITION) end   -- tiny-fort fallback
        if u then
            picks[#picks + 1] = {role = EXPEDITION, unit = u, score = sc, action = 'fill'}
        else
            picks[#picks + 1] = {role = EXPEDITION, action = 'none'}
        end
    end
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
print(dry and 'embark-nobles (dry run -- nothing changed):' or 'embark-nobles: filling vacant fort positions')
local filled = 0
for _, p in ipairs(picks) do
    if p.action == 'kept' then
        print(('  %-20s -- kept %s'):format(p.role.label, dfhack.units.getReadableName(p.unit)))
    elseif p.action == 'fill' then
        local ok, msg = true, nil
        if not dry then ok, msg = assign_position(p.role.code, p.unit) end
        if ok then filled = filled + 1 end
        print(('  %-20s -> %-28s (skill score %d)%s'):format(
            p.role.label, dfhack.units.getReadableName(p.unit), p.score or 0,
            ok and '' or ('  ! ' .. tostring(msg))))
    else
        print(('  %-20s -- vacant, no candidate'):format(p.role.label))
    end
end
if dry then print('  run `embark-nobles` (no args) to fill the vacant ones.')
elseif filled == 0 then print('  all positions already assigned -- nothing to do.') end
