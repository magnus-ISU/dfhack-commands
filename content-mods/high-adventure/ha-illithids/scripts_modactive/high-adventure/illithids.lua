--@module = true
--@enable = true
--[====[
high-adventure/illithids
========================

Tags: fort | gameplay

Illithid colony support:
- Psionic ascension: base level by caste (illithid 1, ur 4, elder 6); +1 level at
  scholarly skill 3, 6, 12, and 24 (highest scholarly skill counts). Levels are
  granted as permanent syndromes carrying new abilities.
- No armour: illithids are robed but never armoured. Armour is stripped out of squad
  uniforms and taken off any illithid already wearing it; anything with armorlevel 0
  (robes, cloaks, caps) is left alone, and thralls are exempt as human stock.
- Labor policy: thralls may never extract strands; ulitharids and elder brains
  have it (and for elders, all labor) switched off on ascension/arrival - the
  player may re-enable ulitharids deliberately.
- Neural Bath jobs: devour brains (xp + 20% ur promotion), reclaim memories
  (colony-wide xp, memorialize), extract ulitharid brains (caste-validated), implant
  tadpoles (prisoner dies messily, newborn illithid joins), ascend (revive or
  mint an elder brain), resonate (slow random scholar xp for the colony).

Auto-enables when a fort loads with this mod active.
]====]

local repeatUtil = require("repeat-util")
local eventful = require("plugins.eventful")
local syndromeUtil = require("syndrome-util")

local GLOBAL_KEY = "haIllithids"

local SCHOLAR_SKILLS = {
    "MATHEMATICS","LOGIC","CRITICAL_THINKING","ASTRONOMY","CHEMISTRY",
    "GEOGRAPHY","OPTICS_ENGINEER","FLUID_ENGINEER","TRACKING","RECORD_KEEPING",
}
local COMBAT_SKILLS = {"MELEE_COMBAT","DODGING","SHIELD","SWORD","RANGED_COMBAT","BOW"}
local ASCEND_SYNDROMES = {
    [2]="psionic awakening ii",[3]="psionic awakening iii",[4]="psionic awakening iv",
    [5]="psionic awakening v",[6]="psionic awakening vi",[7]="psionic awakening vii",
    [8]="psionic awakening viii",[9]="psionic awakening ix",[10]="psionic awakening x",
}
local BASE_LEVEL = { FEMALE=1, MALE=1, AGENDER=1, ULITHARID=4, ELDER_BRAIN=6 }
local MAX_LEVEL = { FEMALE=5, MALE=5, AGENDER=5, ULITHARID=8, ELDER_BRAIN=10 }

enabled = enabled or false
pending_workers = pending_workers or {}   -- bath job id -> worker unit id
managed = managed or {}   -- unit id -> true once labor policy applied
psi_applied = psi_applied or {}   -- unit id -> psi level last applied (announce only genuine gains)

function isEnabled() return enabled end

local function race_id()
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == "HA_ILLITHID" then return i end
    end
end

local function caste_name(u)
    -- Guard cr.caste[u.caste]: during the 1-tick dummy transform of a caste change (ascension /
    -- promotion) a unit's race is briefly the dummy creature (one caste) while u.caste may still
    -- hold a higher index, so the lookup can be nil. Never index a nil (it would crash the tick).
    local cr = df.creature_raw.find(u.race)
    local c = cr and cr.caste[u.caste]
    return c and c.caste_id or ""
end

local REGULAR = { FEMALE=true, MALE=true, AGENDER=true }

local function random_illithid_caste()
    local race = race_id()
    local cr = df.creature_raw.find(race)
    local opts = {}
    for j = 0, #cr.caste - 1 do
        if REGULAR[cr.caste[j].caste_id] then table.insert(opts, j) end
    end
    return opts[math.random(#opts)]
end

local function caste_index(name)
    local cr = df.creature_raw.find(race_id())
    for j = 0, #cr.caste - 1 do
        if cr.caste[j].caste_id == name then return j end
    end
end

local function skill_id(name) return df.job_skill[name] end
local function random_mental_skill() return skill_id(SCHOLAR_SKILLS[math.random(#SCHOLAR_SKILLS)]) end

local function get_skill(u, sk)
    local soul = u.status.current_soul
    if not soul then return 0 end
    for _, s in ipairs(soul.skills) do
        if s.id == sk then return s.rating end
    end
    return 0
end

local apply_levels  -- forward declaration; defined below, called by add_xp

local function add_xp(u, sk, amount)
    local soul = u.status.current_soul
    if not soul then return end
    local entry
    for _, s in ipairs(soul.skills) do
        if s.id == sk then entry = s break end
    end
    if not entry then
        local e = df.unit_skill:new()
        e.id = sk; e.rating = 0; e.experience = 0
        soul.skills:insert("#", e)
        entry = soul.skills[#soul.skills - 1]
    end
    entry.experience = entry.experience + amount
    while entry.experience >= 500 + entry.rating * 100 do
        entry.experience = entry.experience - (500 + entry.rating * 100)
        entry.rating = entry.rating + 1
    end
    apply_levels(u)
end

local function best_scholar(u)
    local best, best_sk = -1, nil
    local tied = {}
    for _, name in ipairs(SCHOLAR_SKILLS) do
        local sk = skill_id(name)
        if sk then
            local r = get_skill(u, sk)
            if r > best then best = r; tied = {sk} elseif r == best then table.insert(tied, sk) end
        end
    end
    best_sk = tied[math.random(#tied)]
    return best, best_sk
end

local function psi_level(u)
    local base = BASE_LEVEL[caste_name(u)] or 0
    if base == 0 then return 0 end
    local rating = select(1, best_scholar(u))
    local bonus = 0
    for _, th in ipairs({3, 6, 12, 24}) do
        if rating >= th then bonus = bonus + 1 end
    end
    return math.min(base + bonus, MAX_LEVEL[caste_name(u)] or base)
end

local function find_syndrome(name)
    -- This DFHack build has no world.raws.syndromes vector; iterate by id instead
    -- (df.syndrome.find indexes the global contiguous syndrome list).
    local id = 0
    while true do
        local syn = df.syndrome.find(id)
        if not syn then return nil end
        if syn.syn_name == name then return syn end
        id = id + 1
    end
end

local function has_syndrome(u, name)
    for _, act in ipairs(u.syndromes.active) do
        local syn = df.syndrome.find(act['type'])
        if syn and syn.syn_name == name then return true end
    end
    return false
end

local SHIELD_TIERS = {
    {min=8, name="grant prismatic aegis"},
    {min=5, name="grant psychic aegis"},
    {min=3, name="grant psychic shield"},
    {min=1, name="grant psychic barrier"},
}

-- Each caste's BASE-level best shield is innate in the raws (so it works in worldgen /
-- adventure, where this script never runs). These are the "min level" of that innate
-- shield; the script only ever grants shields STRICTLY ABOVE it, and never re-grants the
-- base tier as a syndrome.
local INNATE_SHIELD_MIN = { FEMALE=1, MALE=1, AGENDER=1, ULITHARID=3, ELDER_BRAIN=5 }

local function apply_shield(u, lvl)
    if lvl < 1 then return end
    local base_min = INNATE_SHIELD_MIN[caste_name(u)] or 0
    -- best shield tier available at this level
    local want
    for _, tier in ipairs(SHIELD_TIERS) do
        if lvl >= tier.min then want = tier break end
    end
    -- only manage a SYNDROME shield when the best tier is above the innate base tier
    local want_name = (want and want.min > base_min) and want.name or nil
    for _, tier in ipairs(SHIELD_TIERS) do
        if tier.name == want_name then
            if not has_syndrome(u, tier.name) then
                local syn = find_syndrome(tier.name)
                if syn then syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing) end
            end
        else
            -- strip any other syndrome shield so only the single best syndrome shield remains
            for i = #u.syndromes.active - 1, 0, -1 do
                local act = u.syndromes.active[i]
                local s = df.syndrome.find(act['type'])
                if s and s.syn_name == tier.name then
                    u.syndromes.active:erase(i)
                end
            end
        end
    end
end

local ROMAN = {[2]="II",[3]="III",[4]="IV",[5]="V",[6]="VI",[7]="VII",[8]="VIII",[9]="IX",[10]="X"}

function apply_levels(u)
    local lvl = psi_level(u)
    apply_shield(u, lvl)
    -- prev = level we last applied for this unit. nil on first sight (fort load, migrant
    -- arrival, fresh spawn) -> apply base/natural levels SILENTLY. Announce only ONCE per
    -- change, for the HIGHEST level newly reached during play (skill growth, ascension) --
    -- a jump from IV to VI shows only VI, not V and VI.
    local prev = psi_applied[u.id]
    local highest_new
    for n = 2, lvl do
        local name = ASCEND_SYNDROMES[n]
        if name and not has_syndrome(u, name) then
            local syn = find_syndrome(name)
            if syn then
                syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing)
                if prev and n > prev then highest_new = n end
            end
        end
    end
    if highest_new then
        dfhack.gui.showAnnouncement(
            ("%s ascends to psionic awakening %s."):format(
                dfhack.units.getReadableName(u), ROMAN[highest_new] or tostring(highest_new)),
            COLOR_MAGENTA, true)
    end
    if not prev or lvl > prev then psi_applied[u.id] = lvl end
end

-- The script never toggles anyone's strand-extraction labor off. It only keeps it ON for
-- every illithid citizen (all castes) so any of them can physically staff the bath; WHO
-- actually does each job is steered by the workshop worker profile in staff_baths().
local function keep_strand_enabled(u)
    if not u.status.labors.EXTRACT_STRAND then u.status.labors.EXTRACT_STRAND = true end
end

-- ----- Neural-bath staffing by workshop profile -----
local function bath_buildings()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(b) and b.custom_type >= 0 then
            local def = df.building_def.find(b.custom_type)
            if def and def.code == "HA_NEURAL_BATH" then out[#out + 1] = b end
        end
    end
    return out
end

-- Who may legally work each reaction.
local function job_legal_caste(reaction, cn)
    if reaction == "HA_RESONATE" then return cn == "ELDER_BRAIN" end   -- elder brains only
    if reaction == "HA_IMPLANT_TADPOLE" then return true end            -- anyone, incl. thralls
    return cn ~= "THRALL_M" and cn ~= "THRALL_F"                        -- devour/reclaim/extract/ascend
end

-- Preference rank (lower = preferred): illithid, then ulitharid, then elder brain, then thrall.
local CASTE_RANK = { FEMALE = 1, MALE = 1, AGENDER = 1, ULITHARID = 2, ELDER_BRAIN = 3, THRALL_M = 4, THRALL_F = 4 }

-- Best legal candidate for a reaction, by preference; idle candidates win ties.
local function pick_worker(reaction)
    local race = race_id()
    local best, best_rank, best_idle
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and dfhack.units.isCitizen(u) and not u.flags1.inactive and not u.flags2.killed then
            local cn = caste_name(u)
            if job_legal_caste(reaction, cn) then
                local rank = CASTE_RANK[cn] or 99
                local idle = (u.job.current_job == nil)
                if not best or rank < best_rank or (rank == best_rank and idle and not best_idle) then
                    best, best_rank, best_idle = u, rank, idle
                end
            end
        end
    end
    return best
end

local function job_worker(job)
    for _, u in ipairs(df.global.world.units.active) do
        if u.job.current_job and u.job.current_job.id == job.id then return u end
    end
end

bath_profile_mod = bath_profile_mod or {}   -- building id -> worker id WE set (vs player's)

local function set_profile(b, uid)
    local pw = b.profile.permitted_workers
    pw:resize(0)
    if uid then pw:insert("#", uid) end
    bath_profile_mod[b.id] = uid
end

local function mod_worker_valid(b, reaction)
    local uid = bath_profile_mod[b.id]
    if not uid then return false end
    local u = df.unit.find(uid)
    return u and dfhack.units.isCitizen(u) and not u.flags1.inactive and not u.flags2.killed
        and job_legal_caste(reaction, caste_name(u))
end

local find_prisoner   -- forward declaration (defined in the handlers section below)
local prisoner_ok     -- forward declaration (used by the cage-teleport helpers below)

-- Is there an unrotten, unforbidden corpse matching pred lying about?
local function corpse_exists(pred)
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and not it.flags.rotten
            and not it.flags.forbid and not it.flags.in_building then
            local uid = it.unit_id
            local u = uid and uid >= 0 and df.unit.find(uid)
            if u and pred(u) then return true end
        end
    end
    return false
end

-- Are the ascend reagents (a preserved brain tool + 15000 of adamantine thread) on hand?
local function ascend_feasible()
    local adam = dfhack.matinfo.find("INORGANIC:ADAMANTINE")
    local has_brain, thread = false, 0
    for _, it in ipairs(df.global.world.items.other.TOOL) do
        if it.subtype and it.subtype.id == "ITEM_TOOL_HA_UR_BRAIN" and not it.flags.forbid then
            has_brain = true
        end
    end
    if adam then
        for _, it in ipairs(df.global.world.items.other.THREAD) do
            if it.mat_type == adam.type and it.mat_index == adam.index and not it.flags.forbid then
                thread = thread + it.dimension
            end
        end
    end
    return has_brain and thread >= 15000
end

-- Can a job's reaction actually be fulfilled right now (required material present)?
local function job_feasible(reaction)
    local race = race_id()
    if reaction == "HA_RESONATE" then return true end
    if reaction == "HA_IMPLANT_TADPOLE" or reaction == "HA_DEVOUR_PRISONER" then
        return find_prisoner() ~= nil
    elseif reaction == "HA_DEVOUR_BRAIN" then
        return corpse_exists(function(v)
            local vcr = df.creature_raw.find(v.race)
            return v.race ~= race and vcr and vcr.caste[v.caste].flags.CAN_LEARN
        end)
    elseif reaction == "HA_RECLAIM_MEMORIES" then
        return corpse_exists(function(v)
            local cn = caste_name(v)
            return v.race == race and cn ~= "THRALL_M" and cn ~= "THRALL_F"
        end)
    elseif reaction == "HA_EXTRACT_UR_BRAIN" then
        return corpse_exists(function(v) return v.race == race and caste_name(v) == "ULITHARID" end)
    elseif reaction == "HA_ASCEND" then
        return ascend_feasible()
    end
    return true
end

-- ============================================================================================
-- Getting a reagent to the bath. Reagent-less bath reactions (devour/reclaim/extract) consume a
-- matching corpse, but nothing HAULS one to the workshop, and DF hauling to a script-made dump
-- zone proved unreliable. Instead we TELEPORT one matching corpse into the ring of 8 tiles around
-- the bath's centre (the middle 3x3 minus the centre) whenever the bath is staffed and none is
-- already there -- the reagent simply appears beside the assigned worker. take_corpse then consumes
-- the nearest, and the next staffing pass teleports a replacement.
local RING8 = {{-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1}}

local function ring_pos(b)
    local d = RING8[math.random(#RING8)]
    return {x = b.centerx + d[1], y = b.centery + d[2], z = b.z}
end

-- already an unrotten matching corpse within the bath's 3x3? (so we don't teleport another)
local function ring_has_corpse(b, pred)
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and not it.flags.rotten and not it.flags.in_building
            and it.pos.z == b.z and math.abs(it.pos.x - b.centerx) <= 1 and math.abs(it.pos.y - b.centery) <= 1 then
            local u = it.unit_id and it.unit_id >= 0 and df.unit.find(it.unit_id)
            if u and pred(u) then return true end
        end
    end
    return false
end

-- teleport ONE matching corpse (from anywhere) into a random ring tile beside the bath
local function teleport_corpse_to_ring(b, pred)
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and not it.flags.rotten and not it.flags.in_building
            and not it.flags.in_job then
            local u = it.unit_id and it.unit_id >= 0 and df.unit.find(it.unit_id)
            if u and pred(u) then
                it.flags.forbid = false
                pcall(dfhack.items.moveToGround, it, ring_pos(b))
                it.flags.in_building = false
                return true
            end
        end
    end
end

-- The cage rites (implant tadpole / devour a caged prisoner) need a caged, brain-bearing prisoner
-- beside the bath. Same idea as corpses, but the "item" is the CAGE holding a valid prisoner.
local function cage_prisoner(cage)   -- the valid prisoner inside `cage`, or nil
    for _, gref in ipairs(cage.general_refs) do
        if df.general_ref_contains_unitst:is_instance(gref) then
            local u = df.unit.find(gref.unit_id)
            if prisoner_ok(u) then return u end
        end
    end
end
local function ring_has_cage(b)      -- already a cage with a valid prisoner in the bath's 3x3?
    for _, cage in ipairs(df.global.world.items.other.CAGE) do
        if not cage.flags.in_building and cage.pos.z == b.z
            and math.abs(cage.pos.x - b.centerx) <= 1 and math.abs(cage.pos.y - b.centery) <= 1
            and cage_prisoner(cage) then
            return true
        end
    end
    return false
end
local function teleport_cage_to_ring(b)   -- move one prisoner-bearing cage into a random ring tile
    for _, cage in ipairs(df.global.world.items.other.CAGE) do
        if not cage.flags.in_building and not cage.flags.in_job and cage_prisoner(cage) then
            cage.flags.forbid = false
            pcall(dfhack.items.moveToGround, cage, ring_pos(b))
            cage.flags.in_building = false
            return true
        end
    end
end
-- --------------------------------------------------------------------------------------------

local function job_corpse_pred(reaction)   -- what corpse a job needs (nil = no corpse)
    local race = race_id()
    if reaction == "HA_DEVOUR_BRAIN" then
        return function(v) local vcr = df.creature_raw.find(v.race)
            return v.race ~= race and vcr and vcr.caste[v.caste].flags.CAN_LEARN end
    elseif reaction == "HA_RECLAIM_MEMORIES" then
        return function(v) local cn = caste_name(v)
            return v.race == race and cn ~= "THRALL_M" and cn ~= "THRALL_F" end
    elseif reaction == "HA_EXTRACT_UR_BRAIN" then
        return function(v) return v.race == race and caste_name(v) == "ULITHARID" end
    end
end

local CAGE_RITE = { HA_IMPLANT_TADPOLE = true, HA_DEVOUR_PRISONER = true }

-- For a bath's live rites, keep their reagents teleported into the ring, replacing whatever was
-- consumed: a matching corpse for devour/reclaim/extract, and a prisoner-bearing cage for the
-- cage rites. Only teleports when the reagent isn't already beside the bath.
local function maintain_ring_reagents(b, jobs)
    local done_corpse, need_cage = {}, false
    for _, job in ipairs(jobs) do
        local rn = job.reaction_name
        local pred = job_corpse_pred(rn)
        if pred then
            if not done_corpse[rn] then
                done_corpse[rn] = true
                if not ring_has_corpse(b, pred) then teleport_corpse_to_ring(b, pred) end
            end
        elseif CAGE_RITE[rn] then
            need_cage = true
        end
    end
    if need_cage and not ring_has_cage(b) then teleport_cage_to_ring(b) end
end

-- ---------- Bath job cancellation: clear, specific messages ----------
-- What each bath reaction DOES (for messages), what it NEEDS when infeasible, and who it needs.
local JOB_ACTION = {
    HA_IMPLANT_TADPOLE  = "implant a tadpole",
    HA_DEVOUR_PRISONER  = "devour a caged prisoner's brain",
    HA_DEVOUR_BRAIN     = "devour a dead sentient's brain",
    HA_RECLAIM_MEMORIES = "reclaim a dead illithid's memories",
    HA_EXTRACT_UR_BRAIN = "extract a ulitharid's brain",
    HA_ASCEND           = "ascend a ulitharid's brain",
    HA_RESONATE         = "resonate with the colony",
}
local JOB_NEED = {
    HA_IMPLANT_TADPOLE  = "no caged, brain-bearing prisoner is on hand",
    HA_DEVOUR_PRISONER  = "no caged, brain-bearing prisoner is on hand",
    HA_DEVOUR_BRAIN     = "no fresh sentient-outsider corpse is on hand",
    HA_RECLAIM_MEMORIES = "no fresh illithid corpse is on hand",
    HA_EXTRACT_UR_BRAIN = "no fresh ulitharid corpse is on hand",
    HA_ASCEND           = "the preserved ulitharid brain and adamantine thread are not both on hand",
    HA_RESONATE         = "no Elder Brain dwells in the colony",
}
local JOB_WHO = { HA_RESONATE = "Elder Brain" }   -- default below: "non-thrall illithid"

local function caste_word(cn)
    if cn == "THRALL_M" or cn == "THRALL_F" then return "thrall"
    elseif cn == "ULITHARID" then return "ulitharid"
    elseif cn == "ELDER_BRAIN" then return "Elder Brain"
    else return "illithid" end
end
local function announce(msg) if msg then dfhack.gui.showAnnouncement(msg, COLOR_YELLOW, true) end end
local function act(rn) return JOB_ACTION[rn] or "a bath rite" end
local function msg_infeasible(rn) return ("Neural Bath: cancelling the job to %s -- %s."):format(act(rn), JOB_NEED[rn] or "its requirement is missing") end
local function msg_illegal(rn, cn) return ("Neural Bath: cancelling the job to %s -- a %s may not perform it."):format(act(rn), caste_word(cn)) end
local function msg_nobody(rn) return ("Neural Bath: cancelling the job to %s -- no %s in the colony can perform it."):format(act(rn), JOB_WHO[rn] or "non-thrall illithid") end

-- The worker ASSIGNED to a job (via the job's worker ref -- set the moment a unit claims it,
-- before it starts walking), falling back to a unit actively running it.
local function assigned_worker(job)
    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
    if wref then local u = df.unit.find(wref.unit_id); if u then return u end end
    return job_worker(job)
end
local function cancel_bath_job(job, msg)
    pcall(dfhack.job.removeWorker, job, 0)
    pcall(dfhack.job.removeJob, job)
    announce(msg)
end

-- One worker staffs a whole workshop, so it must be legal for the MOST restrictive rite queued.
-- The legal-caste sets are nested -- resonate (Elder Brain) is a subset of the non-thrall rites,
-- which are a subset of implant (anyone) -- so a worker picked for the most restrictive rite can
-- perform every other rite in the same bath. (A bath containing a resonate job is therefore
-- staffed by an Elder Brain; put resonate in its own bath if you want parallel work.)
local RESTRICT = {
    HA_RESONATE = 3,
    HA_DEVOUR_BRAIN = 2, HA_DEVOUR_PRISONER = 2, HA_RECLAIM_MEMORIES = 2,
    HA_EXTRACT_UR_BRAIN = 2, HA_ASCEND = 2,
    HA_IMPLANT_TADPOLE = 1,
}
local function pick_bath_worker(jobs)
    local worst_rn, worst = nil, -1
    for _, job in ipairs(jobs) do
        local r = RESTRICT[job.reaction_name] or 0
        if r > worst then worst, worst_rn = r, job.reaction_name end
    end
    return worst_rn and pick_worker(worst_rn) or nil
end

-- Staff the bath PROACTIVELY, every fast tick -- never wait for a job to finish. For each queued
-- bath job we, at assignment time: (1) check its conditions -- if the material/target is missing
-- or no eligible caste exists, cancel it now with a clear reason; (2) otherwise choose ONE
-- specific valid worker (preference-ranked, idle-preferred) and pin the workshop's profile to
-- exactly that unit, so only an eligible worker can ever claim it. If an ineligible worker
-- somehow grabbed a job (every illithid and thrall carries the strand labor), cancel it and
-- re-pin a valid worker. When a bath has no jobs left, hand its worker back.
local function staff_baths()
    for _, b in ipairs(bath_buildings()) do
        local ha = {}
        for _, job in ipairs(b.jobs) do
            local rn = job.reaction_name
            if job.job_type == df.job_type.CustomReaction and rn and rn:sub(1, 3) == "HA_" then
                ha[#ha + 1] = job
            end
        end
        if #ha == 0 then
            if #b.profile.permitted_workers > 0 then set_profile(b, nil) end
        else
            -- (1) per-job conditions, checked NOW (not at completion): cancel with a clear reason
            -- if the reagent/target is missing or no eligible caste exists. Survivors -> `live`.
            local live = {}
            for _, job in ipairs(ha) do
                local rn = job.reaction_name
                if not job_feasible(rn) then
                    cancel_bath_job(job, msg_infeasible(rn))
                elseif not pick_worker(rn) then
                    cancel_bath_job(job, msg_nobody(rn))
                else
                    live[#live + 1] = job
                end
            end
            if #live == 0 then
                if #b.profile.permitted_workers > 0 then set_profile(b, nil) end
            else
                -- (2) ONE worker staffs the workshop: legal for the most restrictive live rite (an
                -- Elder Brain if a resonate job is present -- it can do every rite). Unclaim any
                -- ineligible worker that grabbed a job in the meantime, then pin the chosen worker.
                local cand = pick_bath_worker(live)
                if cand then
                    for _, job in ipairs(live) do
                        local w = assigned_worker(job)
                        if w and not job_legal_caste(job.reaction_name, caste_name(w)) then
                            pcall(dfhack.job.removeWorker, job, 0)
                        end
                    end
                    local pw = b.profile.permitted_workers
                    if #pw ~= 1 or pw[0] ~= cand.id then set_profile(b, cand.id) end
                    -- (3) teleport the needed reagents beside the assigned worker
                    maintain_ring_reagents(b, live)
                end
            end
        end
    end
end

-- Illithids may FORGE armor (for thralls / trade) but never WEAR it. This strips the actual
-- armor pieces (armorlevel > 0) out of any illithid squad member's OWN uniform -- categories
-- body/head/pants/gloves/shoes -- while leaving weapons, shields, clothing (armorlevel 0), and
-- thralls untouched. Runs on the slow tick; idempotent (nothing to strip once done).
local ARMOR_DEFS
local function spec_is_armor(sp)
    ARMOR_DEFS = ARMOR_DEFS or {
        [df.item_type.ARMOR] = df.global.world.raws.itemdefs.armor,
        [df.item_type.HELM] = df.global.world.raws.itemdefs.helms,
        [df.item_type.PANTS] = df.global.world.raws.itemdefs.pants,
        [df.item_type.GLOVES] = df.global.world.raws.itemdefs.gloves,
        [df.item_type.SHOES] = df.global.world.raws.itemdefs.shoes,
    }
    local lst = ARMOR_DEFS[sp.item_type]
    if lst and sp.item_subtype >= 0 and sp.item_subtype < #lst then
        local d = lst[sp.item_subtype]
        return d and d.armorlevel and d.armorlevel > 0
    end
    return false
end

-- Same armorlevel test, but against a real item rather than a uniform spec. Robes, cloaks
-- and caps are armorlevel 0 and stay on: illithids are robed, just never armoured. Shields
-- have no armorlevel at all and are rejected outright.
local function item_is_armor(item)
    if not item then return false end
    local ity = item:getType()
    if ity == df.item_type.SHIELD then return true end
    ARMOR_DEFS = ARMOR_DEFS or {
        [df.item_type.ARMOR] = df.global.world.raws.itemdefs.armor,
        [df.item_type.HELM] = df.global.world.raws.itemdefs.helms,
        [df.item_type.PANTS] = df.global.world.raws.itemdefs.pants,
        [df.item_type.GLOVES] = df.global.world.raws.itemdefs.gloves,
        [df.item_type.SHOES] = df.global.world.raws.itemdefs.shoes,
    }
    local lst = ARMOR_DEFS[ity]
    if not lst then return false end
    local sub = item:getSubtype()
    if sub < 0 or sub >= #lst then return false end
    local d = lst[sub]
    return d and d.armorlevel and d.armorlevel > 0
end

-- Clearing the uniform stops the military assigning armour, but it does nothing about a
-- piece already on the body -- looted in adventure mode, carried over from a transformed
-- unit, or assigned before this mod was enabled. Take those off too.
local function strip_worn_armor(u)
    local removed = 0
    for i = #u.inventory - 1, 0, -1 do
        local inv = u.inventory[i]
        if inv and item_is_armor(inv.item) then
            if dfhack.items.moveToGround(inv.item, xyz2pos(dfhack.units.getPosition(u))) then
                removed = removed + 1
            end
        end
    end
    return removed
end

local function strip_illithid_armor()
    local race = race_id()
    local ent = df.global.plotinfo.main.fortress_entity
    if not ent then return end
    for _, sid in ipairs(ent.squads) do
        local sq = df.squad.find(sid)
        if sq then
            for pi = 0, #sq.positions - 1 do
                local pos = sq.positions[pi]
                if pos.occupant and pos.occupant >= 0 then
                    local hf = df.historical_figure.find(pos.occupant)
                    local u = hf and df.unit.find(hf.unit_id)
                    if u and u.race == race then
                        local cn = caste_name(u)
                        if cn ~= "THRALL_M" and cn ~= "THRALL_F" then
                            for _, cat in ipairs({0, 1, 2, 3, 4}) do   -- body/head/pants/gloves/shoes
                                local specs = pos.equipment.uniform[cat]
                                for si = #specs - 1, 0, -1 do
                                    if spec_is_armor(specs[si]) then specs:erase(si) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function tick()
    local race = race_id()
    if not race then return end
    strip_illithid_armor()
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race then
            -- Illithids never wear armour. Thralls are human stock and may.
            if not u.flags1.inactive and not u.flags2.killed then
                local cn = caste_name(u)
                if cn ~= "THRALL_M" and cn ~= "THRALL_F" then strip_worn_armor(u) end
            end
            -- Thralls are mindless human stock; they never linger as ghosts. (Illithids may
            -- ghost normally unless devoured/reclaimed at the pool or memorialized.)
            if u.flags3.ghostly then
                local cn = caste_name(u)
                if cn == "THRALL_M" or cn == "THRALL_F" then
                    -- thralls are mindless stock: fully dispel, like goblin/orc dead
                    u.flags3.ghostly = false
                    u.flags1.inactive = true
                    u.flags2.killed = true
                end
            end
            if not u.flags1.inactive and not u.flags2.killed then
                if dfhack.units.isCitizen(u) or dfhack.world.isAdventureMode() then
                    apply_levels(u)
                    if dfhack.units.isCitizen(u) then keep_strand_enabled(u) end
                end
            end
        end
    end
end

-- ---------- Neural Bath handlers ----------

local function warn(msg)
    if msg then dfhack.gui.showAnnouncement(msg, COLOR_YELLOW, true) end
end

local function corpse_unit(item)
    local ok, uid = pcall(function() return item.unit_id end)
    if ok and uid and uid >= 0 then return df.unit.find(uid) end
end

-- find and CONSUME the nearest valid corpse within reach of the worker
local function take_corpse(worker, pred)
    local best, bestd
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and not it.flags.rotten
            and not it.flags.forbid and not it.flags.in_building then
            local u = corpse_unit(it)
            if u and pred(u) then
                local d = math.abs(it.pos.x - worker.pos.x)
                    + math.abs(it.pos.y - worker.pos.y)
                    + 8 * math.abs(it.pos.z - worker.pos.z)
                if not bestd or d < bestd then best, bestd = it, d end
            end
        end
    end
    if best then
        local u = corpse_unit(best)
        dfhack.items.remove(best)
        return u
    end
end

local function make_items(worker, itype, subtype, matstr, count)
    local mi = dfhack.matinfo.find(matstr)
    if not mi then return 0 end
    local made = 0
    for _ = 1, count do
        local r = dfhack.items.createItem(worker, itype, subtype, mi.type, mi.index)
        local item = (type(r) == "table") and r[1] or r
        if item then made = made + 1 end
    end
    return made
end

-- Brief dummy body-transformation (raws: HA_ILLITHID_TF -> HA_ILLITHID_DUMMY, END:1).
local TF_SYNDROME = "HA_ILLITHID_TF"

local function set_caste(u, ci)
    local race = u.race
    -- Succubus-proven caste change. Write the target caste into the identity CACHES only,
    -- then apply a one-tick dummy transformation. When it reverts next tick, DF rebuilds
    -- the unit's body, appearance vectors and graphics FROM these caches, landing cleanly
    -- on the target caste. We deliberately do NOT set u.caste/u.race here: doing so leaves
    -- the appearance vectors sized for the old caste, so opening the unit's description
    -- reads past their end and CRASHES the game (and the art comes out wrong). The dummy
    -- revert is what regenerates those vectors to match the new caste.
    u.enemy.normal_race = race
    u.enemy.normal_caste = ci
    u.enemy.were_race = race
    u.enemy.were_caste = ci
    if u.status.current_soul then
        u.status.current_soul.race = race
        u.status.current_soul.caste = ci
    end
    local cr = df.creature_raw.find(race)
    pcall(function() u.enemy.caste_flags:assign(cr.caste[ci].flags) end)
    if u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then hf.race = race; hf.caste = ci end
    end
    local syn = find_syndrome(TF_SYNDROME)
    if syn then
        syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing)
    else
        -- Fallback for worlds generated before the dummy syndrome existed: set the caste
        -- directly. May render the description imperfectly, but never leaves a stuck curse.
        u.caste = ci
    end
end

local function promote_to_ur(u)
    local ci = caste_index("ULITHARID")
    if not ci then return end
    set_caste(u, ci)
    dfhack.gui.showAnnouncement(
        ("%s has devoured a worthy mind and swelled into a ULITHARID!")
            :format(dfhack.units.getReadableName(u)), COLOR_MAGENTA, true)
end

local function on_devour(unit)
    local cn = caste_name(unit)
    if cn == "THRALL_M" or cn == "THRALL_F" then
        return warn("Thralls may not taste the feast of minds.")
    end
    local victim = take_corpse(unit, function(v)
        local vcr = df.creature_raw.find(v.race)
        return v.race ~= unit.race and vcr
            and vcr.caste[v.caste].flags.CAN_LEARN
    end)
    if not victim then return false end   -- no valid corpse -> cancel (message from on_bath_job)
    local vcr = df.creature_raw.find(victim.race)
    local vid = vcr.creature_id
    make_items(unit, df.item_type.MEAT, -1, "CREATURE_MAT:"..vid..":MUSCLE", 5)
    make_items(unit, df.item_type.GLOB, -1, "CREATURE_MAT:"..vid..":FAT", 2)
    local _, sk = best_scholar(unit)
    if sk then add_xp(unit, sk, 1000) end
    if REGULAR[cn] and math.random() < 0.20 then promote_to_ur(unit) end
end

local function on_reclaim(unit)
    local dead = take_corpse(unit, function(v)
        local dc = caste_name(v)
        return v.race == race_id() and dc ~= "THRALL_M" and dc ~= "THRALL_F"
    end)
    if not dead then return false end   -- no valid corpse -> cancel (message from on_bath_job)
    local race = race_id()
    -- The reclaimed memories flow to the colony's least-developed minds: only the 10
    -- lowest-level (then lowest-skilled) non-thrall illithids gain experience.
    local elig = {}
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and dfhack.units.isCitizen(u) then
            local cn = caste_name(u)
            if cn ~= "THRALL_M" and cn ~= "THRALL_F" then
                local rating, sk = best_scholar(u)
                if sk then table.insert(elig, {u = u, sk = sk, lvl = psi_level(u), rating = rating}) end
            end
        end
    end
    table.sort(elig, function(a, b)
        if a.lvl ~= b.lvl then return a.lvl < b.lvl end
        return a.rating < b.rating
    end)
    -- train a RANDOM mental skill (not each recipient's highest) for the 10 least-developed minds
    for i = 1, math.min(10, #elig) do
        local rnd = random_mental_skill()
        if rnd then add_xp(elig[i].u, rnd, 1000) end
    end
    if dead.flags3.ghostly then dead.flags3.ghostly = false end
    dfhack.gui.showAnnouncement(
        "The colony drinks the memories of its dead; nothing is lost, and no one is mourned.",
        COLOR_MAGENTA, true)
end

local function on_extract(unit)
    local dead = take_corpse(unit, function(v)
        return v.race == race_id() and caste_name(v) == "ULITHARID"
    end)
    if not dead then return false end   -- no valid corpse -> cancel (message from on_bath_job)
    -- brain tool is made of the ulitharid's own preserved-brain material (reads
    -- "preserved ulitharid brain", no metal prefix)
    local mi = dfhack.matinfo.find("CREATURE_MAT:HA_ILLITHID:UR_BRAIN")
        or dfhack.matinfo.find("INORGANIC:MICROCLINE")
    local raws = df.global.world.raws.itemdefs
    local sub
    for i, d in ipairs(raws.tools) do if d.id == "ITEM_TOOL_HA_UR_BRAIN" then sub = i break end end
    if sub and mi then
        local r = dfhack.items.createItem(unit, df.item_type.TOOL, sub, mi.type, mi.index)
        local item = (type(r) == "table") and r[1] or r
        if item then
            dfhack.gui.showAnnouncement(
                "A preserved ulitharid brain is drawn glistening from the bath.", COLOR_MAGENTA, true)
        end
    end
end

function prisoner_ok(u)
    if not u or u.flags1.inactive or u.flags2.killed or u.race == race_id() then return false end
    local cr = df.creature_raw.find(u.race)
    if not cr or not cr.caste[u.caste].flags.CAN_LEARN then return false end
    for _, bp in ipairs(cr.caste[u.caste].body_info.body_parts) do
        if bp.flags.THOUGHT then return true end
    end
    return false
end

-- Find a valid caged prisoner. With `near` (a worker pos) it returns the CLOSEST one -- so the
-- rite consumes the cage we teleported into the bath ring rather than one across the map. Without
-- `near` it returns the first valid (the cheap path used for feasibility checks).
function find_prisoner(near)
    local best, bestd
    local function consider(u, pos)
        if not prisoner_ok(u) then return end
        if not near then best = best or u; return end
        local d = math.abs(pos.x - near.x) + math.abs(pos.y - near.y) + 8 * math.abs(pos.z - near.z)
        if not bestd or d < bestd then best, bestd = u, d end
    end
    -- Caged units are often dropped from units.active (stored inside the cage item), so look
    -- through cage items first, then fall back to any still-active caged unit.
    for _, cage in ipairs(df.global.world.items.other.CAGE) do
        for _, gref in ipairs(cage.general_refs) do
            if df.general_ref_contains_unitst:is_instance(gref) then
                consider(df.unit.find(gref.unit_id), cage.pos)
                if best and not near then return best end
            end
        end
    end
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags1.caged then
            consider(u, u.pos)
            if best and not near then return best end
        end
    end
    return best
end

local function translation_index(name)
    for i, tr in ipairs(df.global.world.raws.language.translations) do
        if tr.name == name then return i end
    end
    return 0
end

local function name_illithid(u)
    local lang = translation_index("HA_ILLITHID")
    local tr = df.global.world.raws.language.translations[lang]
    local nwords = #df.global.world.raws.language.words
    local w0, w1 = math.random(0, nwords - 1), math.random(0, nwords - 1)
    local first = math.random(0, nwords - 1)
    local native = tr and tr.words[first].value or "Ilth"
    native = native:sub(1, 1):upper()..native:sub(2)
    local targets = { u.name }
    if u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then table.insert(targets, hf.name) end
    end
    for _, nm in ipairs(targets) do
        nm.first_name = native
        nm.words[0] = w0
        nm.words[1] = w1
        nm.parts_of_speech[0] = 0
        nm.parts_of_speech[1] = 0
        nm.language = lang
        nm.has_name = true
    end
end


local function set_age_fresh_adult(u)
    -- Illithid castes carry no CHILD/BABY token, so a unit born this instant is already an adult
    -- (no child phase). Newly created units get an arbitrary birth year; normalize to age 0 so a
    -- tadpole-born illithid reads as 0 years old and still fully grown.
    local new_birth = df.global.cur_year
    local delta = new_birth - u.birth_year
    u.birth_year = new_birth
    u.birth_time = df.global.cur_year_tick
    if u.old_year and u.old_year >= 0 then u.old_year = u.old_year + delta end
    if u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then
            hf.born_year = new_birth
            hf.born_seconds = df.global.cur_year_tick
            if hf.old_year and hf.old_year >= 0 then hf.old_year = hf.old_year + delta end
        end
    end
end

local function spawn_illithid(pos)
    local race = race_id()
    local u = dfhack.units.create(race, random_illithid_caste())
    if not u then return end
    u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
    u.flags1.inactive = false
    df.global.world.units.active:insert("#", u)
    dfhack.units.teleport(u, pos)
    dfhack.units.makeown(u)
    name_illithid(u)
    set_age_fresh_adult(u)
    return u
end

-- NOTE: manually erasing a cage's contains-unit / a unit's contained-in-item general_refs
-- mid-reaction leaves a dangling pointer that crashes DF's UI renderer a few ticks later
-- (confirmed 2026-07-22). DFHack never releases caged units by ref surgery -- it queues a
-- pit/release job instead. So we do NOT scrub cage refs here; the emptied cage keeps its
-- former-occupant name (cosmetic) but the game stays stable.

local function on_devour_prisoner(unit)
    local cn = caste_name(unit)
    if cn == "THRALL_M" or cn == "THRALL_F" then
        return warn("Thralls may not taste the feast of minds.")
    end
    local prisoner = find_prisoner(unit.pos)
    if not prisoner then return false end   -- no caged prisoner -> cancel (message from on_bath_job)
    local pos = xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z)
    prisoner.flags1.caged = false
    dfhack.units.teleport(prisoner, pos)
    local vcr = df.creature_raw.find(prisoner.race)
    local vid = vcr.creature_id
    dfhack.gui.showAnnouncement(
        ("%s's skull is cracked open and its mind devoured whole."):format(
            dfhack.units.getReadableName(prisoner)), COLOR_LIGHTRED, true)
    prisoner.body.blood_count = 0
    prisoner.flags1.inactive = true
    prisoner.flags2.killed = true
    make_items(unit, df.item_type.MEAT, -1, "CREATURE_MAT:"..vid..":MUSCLE", 5)
    make_items(unit, df.item_type.GLOB, -1, "CREATURE_MAT:"..vid..":FAT", 2)
    local _, sk = best_scholar(unit)
    if sk then add_xp(unit, sk, 1000) end
    if REGULAR[cn] and math.random() < 0.20 then promote_to_ur(unit) end
end

local function on_implant(unit)
    local prisoner = find_prisoner(unit.pos)
    if not prisoner then return false end   -- no caged prisoner -> cancel (message from on_bath_job)
    local pos = xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z)
    prisoner.flags1.caged = false
    dfhack.units.teleport(prisoner, pos)
    prisoner.counters.stunned = 200
    local pid = prisoner.id
    dfhack.timeout(120, "ticks", function()
        local pu = df.unit.find(pid)
        if not pu or pu.flags2.killed then return end
        dfhack.gui.showAnnouncement(
            ("%s's head bursts in a spray of gore - and something small and hungry crawls free!")
                :format(dfhack.units.getReadableName(pu)), COLOR_LIGHTRED, true)
        local cr = df.creature_raw.find(pu.race)
        local bi = cr.caste[pu.caste].body_info
        for i, bp in ipairs(bi.body_parts) do
            if bp.flags.HEAD then
                pcall(function() pu.body.components.body_part_status[i].missing = true end)
            end
        end
        pu.body.blood_count = 0
        local born = spawn_illithid(xyz2pos(pu.pos.x, pu.pos.y, pu.pos.z))
        if born then
            dfhack.gui.showAnnouncement(
                ("A newborn illithid joins the colony: %s.")
                    :format(dfhack.units.getReadableName(born)), COLOR_MAGENTA, true)
        end
    end)
end

local function on_ascend(unit)
    -- The reaction consumes the preserved ulitharid brain (tool) + adamantine thread
    -- natively. Preferred path: revive an actual dead ulitharid and transform it into
    -- an Elder Brain (preserves the specific creature and its histfig). Only if no dead
    -- ulitharid exists do we mint a fresh Elder Brain instead.
    local race = race_id()
    local ur = caste_index("ULITHARID")
    local pos = xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z)

    local dead_ur
    for _, u in ipairs(df.global.world.units.all) do
        if u.race == race and u.caste == ur and u.flags2.killed then dead_ur = u break end
    end
    if dead_ur then
        local uid = dead_ur.id
        pcall(dfhack.run_script, "full-heal", "-r", "--unit", tostring(uid))
        local u = df.unit.find(uid)
        if u and not u.flags2.killed then
            set_caste(u, caste_index("ELDER_BRAIN"))
            -- No manual resize: the dummy-revert rebuilds the body from the ELDER_BRAIN
            -- caste, which already defines BODY_SIZE 10000000 at adulthood.
            dfhack.units.teleport(u, pos)
            dfhack.units.makeown(u)
            managed[u.id] = nil
            dfhack.gui.showAnnouncement(
                ("The dead rise swollen with thought: %s has ascended into an ELDER BRAIN!")
                    :format(dfhack.units.getReadableName(u)), COLOR_MAGENTA, true)
            return
        end
    end

    -- Fallback: no dead ulitharid to raise; coalesce a fresh Elder Brain.
    local u = dfhack.units.create(race, caste_index("ELDER_BRAIN"))
    if not u then return false end   -- ascension failed to mint an Elder Brain -> cancel
    u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
    u.flags1.inactive = false
    df.global.world.units.active:insert("#", u)
    dfhack.units.teleport(u, pos)
    dfhack.units.makeown(u)
    name_illithid(u)
    set_age_fresh_adult(u)
    dfhack.gui.showAnnouncement(
        "From adamantine and a preserved ulitharid brain, an ELDER BRAIN coalesces in the bath!",
        COLOR_MAGENTA, true)
end

local function on_resonate(unit)
    if caste_name(unit) ~= "ELDER_BRAIN" then
        return warn("The bath hums emptily: only an Elder Brain may resonate. Assign it to this workshop and set the job on repeat.")
    end
    local race = race_id()
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and dfhack.units.isCitizen(u) then
            local soul = u.status.current_soul
            if soul then
                soul.personality.stress = math.min(soul.personality.stress, -50000)
            end
            local cn = caste_name(u)
            if cn ~= "THRALL_M" and cn ~= "THRALL_F" then
                -- each resonate trains ONE random mental skill (+10) and logician (+10), not the
                -- whole scholarly array
                local rnd = random_mental_skill()
                if rnd then add_xp(u, rnd, 10) end
                local logic = skill_id("LOGIC")
                if logic then add_xp(u, logic, 10) end
            end
        end
    end
    -- resonate is a frequent repeat job; no announcement (would spam the log)
end

local HANDLERS = {
    HA_DEVOUR_BRAIN = on_devour,
    HA_DEVOUR_PRISONER = on_devour_prisoner,
    HA_RECLAIM_MEMORIES = on_reclaim,
    HA_EXTRACT_UR_BRAIN = on_extract,
    HA_IMPLANT_TADPOLE = on_implant,
    HA_ASCEND = on_ascend,
    HA_RESONATE = on_resonate,
}

local function track_bath_workers()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) then
            for _, job in ipairs(bld.jobs) do
                if job.job_type == df.job_type.CustomReaction
                    and HANDLERS[job.reaction_name] then
                    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
                    if wref then pending_workers[job.id] = wref.unit_id end
                end
            end
        end
    end
end

local ensure_ticks   -- forward decl (defined with do_enable); revives staffing if it ever stopped

local function on_bath_job(job)
    if ensure_ticks then ensure_ticks() end   -- a completion restarts staffing if it had died
    local rn = job.reaction_name
    local h = HANDLERS[rn]
    if not h then return end
    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
    local wid = wref and wref.unit_id or pending_workers[job.id]
    pending_workers[job.id] = nil
    local unit = wid and df.unit.find(wid)
    if not unit then
        -- The rite finished but we cannot tell who performed it. This only happens when staffing
        -- had stalled (now revived by ensure_ticks above) so pending_workers was never recorded.
        -- Skip this one rite quietly -- the next staffing pass assigns proper workers again.
        return
    end
    -- Legality and feasibility are enforced PROACTIVELY by staff_baths (a bath reaction takes far
    -- longer to perform than the 20-tick staffing cadence, so an ineligible/infeasible job is
    -- cancelled before it can complete). Here we only apply the effect; the handlers keep a
    -- defensive no-op guard for their own caste as a last resort.
    h(unit)
    -- Hand the worker back after each completion -- including repeat jobs. A worker WE assigned
    -- (tracked in bath_profile_mod) is released and the workshop RE-PINNED to a fresh valid worker
    -- for the next cycle (idle-preferred). We must NOT leave the profile empty: a repeat job would
    -- then be grabbable by an ineligible caste in the window before the next staffing pass -- most
    -- visibly an illithid snatching a resonate job that only the (slow) Elder Brain may do, which
    -- then has to be unclaimed, looking like "assigns an illithid, then cancels." Re-pinning a
    -- valid worker keeps the rotation with no such window. If none is valid now, clear it and let
    -- staff_baths cancel the job with a reason. A worker the player pinned before the task began
    -- (bath_profile_mod unset) is left untouched.
    local b = dfhack.job.getHolder(job)
    if b and bath_profile_mod[b.id] then
        -- re-pin for the WHOLE bath (most restrictive rite), not just the completed job, so a
        -- resonate-containing bath stays pinned to the Elder Brain rather than flipping to an
        -- illithid after a devour/extract completes.
        local jobs = {}
        for _, j in ipairs(b.jobs) do
            local rn = j.reaction_name
            if j.job_type == df.job_type.CustomReaction and rn and rn:sub(1, 3) == "HA_" then
                jobs[#jobs + 1] = j
            end
        end
        local cand = pick_bath_worker(jobs)
        set_profile(b, cand and cand.id or nil)
    end
end

local function do_enable()
    enabled = true
    -- cancel first: scheduleEvery does NOT replace an existing key. (A hot-reload still won't
    -- swap these closures -- only a fresh do_enable at world/save load does -- but this keeps a
    -- re-enable from stacking duplicate ticks.)
    repeatUtil.cancel(GLOBAL_KEY)
    repeatUtil.cancel(GLOBAL_KEY.."Slow")
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    eventful.onJobCompleted[GLOBAL_KEY] = on_bath_job
    -- fast: staff the bath (assign a dedicated worker / cancel infeasible or illegal jobs).
    -- WRAPPED IN pcall: repeat-util re-schedules a tick only if its callback RETURNS, so any
    -- unhandled error (e.g. a transient during an ascension/caste change, or an odd map tile)
    -- would silently kill staffing until a reload. Catch and log instead -- a bad tick costs one
    -- cycle, not the whole service.
    repeatUtil.scheduleEvery(GLOBAL_KEY, 20, "ticks", function()
        local ok, err = pcall(function() track_bath_workers(); staff_baths() end)
        if not ok then dfhack.printerr("ha-illithids: staffing tick error (continuing): "..tostring(err)) end
    end)
    -- slow: psi levels + keep the strand labor on for everyone
    repeatUtil.scheduleEvery(GLOBAL_KEY.."Slow", 100, "ticks", function()
        local ok, err = pcall(tick)
        if not ok then dfhack.printerr("ha-illithids: slow tick error (continuing): "..tostring(err)) end
    end)
end

-- Self-heal: if staffing ever stopped (e.g. a pre-pcall error), a job completion brings it back.
function ensure_ticks()
    if dfhack.isMapLoaded() and race_id() and not repeatUtil.repeating[GLOBAL_KEY] then
        do_enable()
    end
end

local function do_disable()
    enabled = false
    eventful.onJobCompleted[GLOBAL_KEY] = nil
    repeatUtil.cancel(GLOBAL_KEY)
    repeatUtil.cancel(GLOBAL_KEY.."Slow")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        if race_id() then do_enable() end
    end
end

if dfhack_flags.module then
    -- self-enable at every module load/reload: scheduleEvery is idempotent (keyed), so this
    -- safely (re)registers the ticks -- a stale `enabled` must NOT gate it, or a hot-reload
    -- leaves the periodic ticks unscheduled and staffing/labor silently stop.
    if dfhack.isMapLoaded() and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode())
        and race_id() then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
