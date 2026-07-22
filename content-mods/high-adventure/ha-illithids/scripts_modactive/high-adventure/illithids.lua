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
- Labor policy: thralls may never extract strands; ur-illithids and elder brains
  have it (and for elders, all labor) switched off on ascension/arrival - the
  player may re-enable ur-illithids deliberately.
- Neural Bath jobs: devour brains (xp + 20% ur promotion), reclaim memories
  (colony-wide xp, memorialize), extract ur-brains (caste-validated), implant
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

local function add_xp(u, sk, amount)
    local soul = u.status.current_soul
    if not soul then return end
    for _, s in ipairs(soul.skills) do
        if s.id == sk then
            s.experience = s.experience + amount
            while s.experience >= 500 + s.rating * 100 do
                s.experience = s.experience - (500 + s.rating * 100)
                s.rating = s.rating + 1
            end
            return
        end
    end
    local entry = df.unit_skill:new()
    entry.id = sk; entry.rating = 0; entry.experience = amount
    soul.skills:insert("#", entry)
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
    for _, syn in ipairs(df.global.world.raws.syndromes.all) do
        if syn.syn_name == name then return syn end
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

local function apply_shield(u, lvl)
    if lvl < 1 then return end
    local want
    for _, tier in ipairs(SHIELD_TIERS) do
        if lvl >= tier.min then want = tier.name break end
    end
    for _, tier in ipairs(SHIELD_TIERS) do
        if tier.name == want then
            if not has_syndrome(u, tier.name) then
                local syn = find_syndrome(tier.name)
                if syn then syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing) end
            end
        else
            -- remove any lower/other shield the unit carries so aegis-casters never cast barrier
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

local function apply_levels(u)
    local lvl = psi_level(u)
    apply_shield(u, lvl)
    for n = 2, lvl do
        local name = ASCEND_SYNDROMES[n]
        if name and not has_syndrome(u, name) then
            local syn = find_syndrome(name)
            if syn then
                syndromeUtil.infectWithSyndrome(u, syn, syndromeUtil.ResetPolicy.DoNothing)
                dfhack.gui.showAnnouncement(
                    ("%s ascends: %s."):format(dfhack.units.getReadableName(u), name),
                    COLOR_MAGENTA, true)
            end
        end
    end
end

local function labor_policy(u)
    local cn = caste_name(u)
    if cn == "THRALL_M" or cn == "THRALL_F" then
        u.status.labors.EXTRACT_STRAND = false
    elseif not managed[u.id] then
        if cn == "ULITHARID" then
            u.status.labors.EXTRACT_STRAND = false
            managed[u.id] = true
        elseif cn == "ELDER_BRAIN" then
            for i = 0, df.unit_labor._last_item do
                pcall(function() u.status.labors[i] = false end)
            end
            managed[u.id] = true
        end
    end
end

local function tick()
    local race = race_id()
    if not race then return end
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and not u.flags1.inactive and not u.flags2.killed then
            if dfhack.units.isCitizen(u) or dfhack.world.isAdventureMode() then
                apply_levels(u)
                if dfhack.units.isCitizen(u) then labor_policy(u) end
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

local function set_caste(u, ci)
    u.caste = ci
    u.enemy.normal_caste = ci
    local cr = df.creature_raw.find(u.race)
    pcall(function() u.enemy.caste_flags:assign(cr.caste[ci].flags) end)
    if u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then hf.caste = ci end
    end
end

local function promote_to_ur(u)
    local ci = caste_index("ULITHARID")
    if not ci then return end
    set_caste(u, ci)
    local si = u.body.size_info
    si.size_cur = 120000; si.size_base = 120000
    u.status.labors.EXTRACT_STRAND = false
    managed[u.id] = true
    dfhack.gui.showAnnouncement(
        ("%s has devoured a worthy mind and swelled into an UR-ILLITHID!")
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
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and dfhack.units.isCitizen(u) then
            local _, sk = best_scholar(u)
            if sk then add_xp(u, sk, 1000) end
        end
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
    if not dead then
        return warn("Only the unrotten corpse of an ur-illithid yields a brain precious enough to keep; none lies near.")
    end
    local made = make_items(unit, df.item_type.MEAT, -1, "CREATURE_MAT:HA_ILLITHID:UR_BRAIN", 1)
    if made > 0 then
        dfhack.gui.showAnnouncement(
            "A precious ur-illithid brain is drawn glistening from the bath.", COLOR_MAGENTA, true)
    end
end

local function find_prisoner()
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags1.caged and not u.flags1.inactive and not u.flags2.killed
            and u.race ~= race_id() then
            local cr = df.creature_raw.find(u.race)
            if cr and cr.caste[u.caste].flags.CAN_LEARN then
                local bi = cr.caste[u.caste].body_info
                for _, bp in ipairs(bi.body_parts) do
                    if bp.flags.THOUGHT then return u end
                end
            end
        end
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
    local race = race_id()
    local ur = caste_index("ULITHARID")
    local dead_ur = nil
    for _, u in ipairs(df.global.world.units.all) do
        if u.race == race and u.caste == ur and u.flags2.killed then
            dead_ur = u
            break
        end
    end
    if dead_ur then
        local uid = dead_ur.id
        pcall(dfhack.run_script, "full-heal", "-r", "--unit", tostring(uid))
        local u = df.unit.find(uid)
        if u and not u.flags2.killed then
            set_caste(u, caste_index("ELDER_BRAIN"))
            local si = u.body.size_info
            si.size_cur = 10000000; si.size_base = 10000000
            dfhack.units.teleport(u, xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z))
            dfhack.units.makeown(u)
            managed[u.id] = nil
            dfhack.gui.showAnnouncement(
                ("The dead rise swollen with thought: %s has ascended into an ELDER BRAIN!")
                    :format(dfhack.units.getReadableName(u)), COLOR_MAGENTA, true)
            return
        end
    end
    local u = dfhack.units.create(race, caste_index("ELDER_BRAIN"))
    if u then
        local pos = xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z)
        u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
        u.flags1.inactive = false
        df.global.world.units.active:insert("#", u)
        dfhack.units.teleport(u, pos)
        dfhack.units.makeown(u)
        name_illithid(u)
        dfhack.gui.showAnnouncement(
            "From adamantine and stolen thought, a new ELDER BRAIN coalesces in the bath!",
            COLOR_MAGENTA, true)
    end
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
            if math.random() < 0.35 then
                local name = SCHOLAR_SKILLS[math.random(#SCHOLAR_SKILLS)]
                local sk = skill_id(name)
                if sk then add_xp(u, sk, 150) end
            end
        end
    end
    dfhack.gui.showAnnouncement(
        "The Elder Brain resonates; the colony's minds sing as one.", COLOR_MAGENTA, true)
end

local HANDLERS = {
    HA_DEVOUR_BRAIN = on_devour,
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
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    eventful.onJobCompleted[GLOBAL_KEY] = on_bath_job
    repeatUtil.scheduleEvery(GLOBAL_KEY, 20, "ticks", function()
        track_bath_workers()
    end)
    repeatUtil.scheduleEvery(GLOBAL_KEY.."Slow", 200, "ticks", tick)
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
    -- self-enable at module load: survives any load-order race with SC_MAP_LOADED
    if not enabled and dfhack.isMapLoaded() and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
