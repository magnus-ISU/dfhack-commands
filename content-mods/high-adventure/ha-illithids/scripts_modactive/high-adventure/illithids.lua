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
    local cr = df.creature_raw.find(u.race)
    return cr and cr.caste[u.caste].caste_id or ""
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
-- Corpse hauling to the bath. Reagent-less bath reactions (devour/reclaim/extract) consume the
-- nearest corpse; without this, nobody physically HAULS one to the workshop. The MECHANISM for
-- getting a corpse hauled to the bath is deliberately isolated in the three functions below so
-- it can be swapped wholesale if this approach doesn't pan out (DF suppresses civilian hauling
-- during sieges, so it is best observed on a calm fort). Current mechanism: a per-bath garbage
-- dump zone + flagging the corpse for dumping, so haulers carry it to the tile beside the bath.
-- If that proves unreliable, replace ONLY ensure_haul_target / request_haul / reclaim_hauled
-- (e.g. with a posted DumpItem/BringItemToShop job); the pipeline (which corpse, when) is separate.
bath_haul_target = bath_haul_target or {}   -- bath building id -> mechanism handle (dump zone id)

local function ensure_haul_target(b)
    local zid = bath_haul_target[b.id]
    if zid then
        local z = df.building.find(zid)
        if z and df.building_civzonest:is_instance(z) then return z end
    end
    for _, d in ipairs({{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,2},{-3,0},{3,0}}) do
        local x, y = b.centerx + d[1], b.centery + d[2]
        local tt = dfhack.maps.getTileType(x, y, b.z)
        if tt then
            local sh = df.tiletype.attrs[tt].shape
            if sh and df.tiletype_shape.attrs[sh].walkable
                and #dfhack.buildings.findCivzonesAt(xyz2pos(x, y, b.z)) == 0 then
                local ok, z = pcall(function()
                    return dfhack.buildings.constructBuilding{ type = df.building_type.Civzone,
                        subtype = df.civzone_type.Dump, abstract = true,
                        pos = {x = x, y = y, z = b.z}, width = 1, height = 1 }
                end)
                if ok and z then bath_haul_target[b.id] = z.id; return z end
            end
        end
    end
end

local function request_haul(item)       -- cause `item` to be hauled to the bath's haul target
    item.flags.dump = true
end

local function near_bath(it, b)
    return it.pos.z == b.z and math.abs(it.pos.x - b.centerx) <= 2 and math.abs(it.pos.y - b.centery) <= 2
end

local function reclaim_hauled(b)        -- free corpses that ARRIVED at the bath so the reaction can use them
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and it.flags.forbid and not it.flags.rotten and near_bath(it, b) then
            it.flags.forbid = false     -- dumped items arrive forbidden
            it.flags.dump = false
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

-- Pipeline: for a bath's queued corpse jobs, keep a small supply of matching corpses hauled to it.
local function haul_corpses_to_bath(b, ha)
    reclaim_hauled(b)
    local preds = {}
    for _, job in ipairs(ha) do
        local p = job_corpse_pred(job.reaction_name)
        if p then preds[#preds + 1] = p end
    end
    if #preds == 0 then return end
    -- don't over-haul: stop once a few corpses are already waiting at the bath
    local near = 0
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if df.item_corpsest:is_instance(it) and not it.flags.rotten and near_bath(it, b) then near = near + 1 end
    end
    if near >= 3 then return end
    if not ensure_haul_target(b) then return end
    local flagged = 0
    for _, it in ipairs(df.global.world.items.other.ANY_CORPSE or {}) do
        if flagged >= 3 then break end
        if df.item_corpsest:is_instance(it) and not it.flags.rotten and not it.flags.forbid
            and not it.flags.in_job and it.flags.on_ground and not it.flags.dump and not near_bath(it, b) then
            local u = it.unit_id and it.unit_id >= 0 and df.unit.find(it.unit_id)
            if u then
                for _, p in ipairs(preds) do
                    if p(u) then request_haul(it); flagged = flagged + 1; break end
                end
            end
        end
    end
end

-- For every queued bath job: cancel it if its material is missing; otherwise keep it staffed
-- by a legal, preference-ranked worker via the workshop profile. Respect a profile the player
-- set. Once a bath has no jobs left, hand back any worker WE assigned.
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
            -- no bath work left: unassign the workshop (clear any worker we pinned to it)
            if #b.profile.permitted_workers > 0 then set_profile(b, nil) end
        else
            haul_corpses_to_bath(b, ha)   -- physically haul needed corpses to the bath
            local to_remove = {}
            for _, job in ipairs(ha) do
                local rn = job.reaction_name
                if not job_feasible(rn) then
                    -- material missing: cancel even if a worker already grabbed it (everyone
                    -- has the strand labor, so jobs get claimed before a no-worker tick)
                    to_remove[#to_remove + 1] = job
                else
                    local worker = job_worker(job)
                    if worker then
                        if not job_legal_caste(rn, caste_name(worker)) then
                            local cand = pick_worker(rn)
                            set_profile(b, cand and cand.id or nil)
                            to_remove[#to_remove + 1] = job      -- illegal worker: reassign + cancel
                        end
                    else
                        local pw = b.profile.permitted_workers
                        if #pw > 0 and not bath_profile_mod[b.id] then
                            -- player pre-assigned the workshop: leave it
                        elseif not mod_worker_valid(b, rn) then
                            local cand = pick_worker(rn)
                            if cand then
                                set_profile(b, cand.id)
                            else
                                set_profile(b, nil)              -- no legal candidate...
                                to_remove[#to_remove + 1] = job  -- ...so cancel the job
                            end
                        end
                    end
                end
            end
            for _, job in ipairs(to_remove) do
                pcall(dfhack.job.removeWorker, job, 0)   -- release the worker from the cancelled job
                pcall(dfhack.job.removeJob, job)
            end
            -- if everything got cancelled, drop the pinned worker now instead of next tick
            if #to_remove == #ha and #b.profile.permitted_workers > 0 then set_profile(b, nil) end
        end
    end
end

local function tick()
    local race = race_id()
    if not race then return end
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race then
            -- Thralls are mindless human stock; they never linger as ghosts. (Illithids may
            -- ghost normally unless devoured/reclaimed at the pool or memorialized.)
            if u.flags3.ghostly then
                local cn = caste_name(u)
                if cn == "THRALL_M" or cn == "THRALL_F" then u.flags3.ghostly = false end
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

local function set_caste(u, ci, syn_name)
    local race = u.race
    -- Rebuild the body/graphics FIRST, while u.caste is still the old caste, so DF
    -- registers a real caste transition and doesn't skip the transform as a no-op.
    -- The permanent CE_BODY_TRANSFORMATION supplies the new body & art; the identity
    -- caches below make the change stick (no revert) and update nobles/labor screens.
    if syn_name then
        local syn = find_syndrome(syn_name)
        if syn then syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing) end
    end
    u.caste = ci
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
end

local function promote_to_ur(u)
    local ci = caste_index("ULITHARID")
    if not ci then return end
    set_caste(u, ci, "become ulitharid")
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
    if not victim then
        return warn("The bath demands the unrotten corpse of a sentient outsider; none lies near.")
    end
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
    if not dead then
        return warn("Only the unrotten corpse of an illithid holds memories worth drinking; none lies near.")
    end
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
    for i = 1, math.min(10, #elig) do add_xp(elig[i].u, elig[i].sk, 1000) end
    if dead.flags3.ghostly then dead.flags3.ghostly = false end
    dfhack.gui.showAnnouncement(
        "The colony drinks the memories of its dead; nothing is lost, and no one is mourned.",
        COLOR_MAGENTA, true)
end

local function on_extract(unit)
    local dead = take_corpse(unit, function(v)
        return v.race == race_id() and caste_name(v) == "ULITHARID"
    end)
    if not dead then
        return warn("Only the unrotten corpse of a ulitharid yields a brain precious enough to keep; none lies near.")
    end
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

local function prisoner_ok(u)
    if not u or u.flags1.inactive or u.flags2.killed or u.race == race_id() then return false end
    local cr = df.creature_raw.find(u.race)
    if not cr or not cr.caste[u.caste].flags.CAN_LEARN then return false end
    for _, bp in ipairs(cr.caste[u.caste].body_info.body_parts) do
        if bp.flags.THOUGHT then return true end
    end
    return false
end

function find_prisoner()
    -- Caged units are often dropped from units.active (stored inside the cage item),
    -- so look through cage items first, then fall back to any still-active caged unit.
    for _, cage in ipairs(df.global.world.items.other.CAGE) do
        for _, gref in ipairs(cage.general_refs) do
            if df.general_ref_contains_unitst:is_instance(gref) then
                local u = df.unit.find(gref.unit_id)
                if prisoner_ok(u) then return u end
            end
        end
    end
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags1.caged and prisoner_ok(u) then return u end
    end
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
    -- newly spawned units get an arbitrary old birth year; make them just-matured
    local cr = df.creature_raw.find(u.race)
    local grow = cr.caste[u.caste].misc.child_age
    if not grow or grow <= 0 then grow = 18 end
    local new_birth = df.global.cur_year - grow
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
    local prisoner = find_prisoner()
    if not prisoner then
        return warn("No caged, brain-bearing sentient awaits devouring; capture one first.")
    end
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
    local prisoner = find_prisoner()
    if not prisoner then
        return warn("No caged, brain-bearing sentient awaits the tadpole; capture one first.")
    end
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
            set_caste(u, caste_index("ELDER_BRAIN"), "become elder brain")
            local si = u.body.size_info
            si.size_cur = 10000000; si.size_base = 10000000
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
    if not u then
        return warn("The bath convulses, but no greater mind coalesces; the ascension fails.")
    end
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
            if cn ~= "THRALL_M" and cn ~= "THRALL_F" and math.random() < 0.35 then
                local name = SCHOLAR_SKILLS[math.random(#SCHOLAR_SKILLS)]
                local sk = skill_id(name)
                if sk then add_xp(u, sk, 150) end
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

local function on_bath_job(job)
    local h = HANDLERS[job.reaction_name]
    if not h then return end
    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
    local wid = wref and wref.unit_id or pending_workers[job.id]
    pending_workers[job.id] = nil
    local unit = wid and df.unit.find(wid)
    if not unit then
        return warn("The bath's brine stirs, but its tender slipped away unseen.")
    end
    h(unit)
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
    -- fast: staff the bath (assign a dedicated worker / cancel infeasible or illegal jobs)
    repeatUtil.scheduleEvery(GLOBAL_KEY, 20, "ticks", function()
        track_bath_workers()
        staff_baths()
    end)
    -- slow: psi levels + keep the strand labor on for everyone
    repeatUtil.scheduleEvery(GLOBAL_KEY.."Slow", 100, "ticks", tick)
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
