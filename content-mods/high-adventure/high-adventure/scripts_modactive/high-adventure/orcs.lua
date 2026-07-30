--@module = true
--@enable = true
--[====[
high-adventure/orcs
===================

Tags: fort | gameplay

Breeding Pit support and orcish afterlife customs:

- Each "breed orcs from meat" job attempts to birth an orcling on the spot.
  Base failure chance is 75%, falling linearly to 0% for a legendary strand
  extractor. The worker gains 70 strand-extraction experience per attempt (the reaction skill itself grants ~30 more).
- Orclings are always common orcs (never champions), arrive as full citizens,
  and are named Peon with an orcish surname.
- Orcs send out fodder and do not memorialize their dead: orc ghosts are
  dispelled automatically.

Auto-enables when a fort loads with this mod active.

Usage
-----

	enable high-adventure/orcs
	disable high-adventure/orcs
]====]

local repeatUtil = require("repeat-util")
local eventful = require("plugins.eventful")

local GLOBAL_KEY = "haOrcs"
local BREED_REACTION = "HA_BREED_ORC"

enabled = enabled or false
pending_workers = pending_workers or {}   -- breed job id -> worker unit id
pending_meat = pending_meat or {}         -- breed job id -> {stack, mat_type, mat_index}

function isEnabled()
    return enabled
end

local function orc_race_id()
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == "HA_ORC" then return i end
    end
    return nil
end

local function snaga_caste(race)
    local cr = df.creature_raw.find(race)
    local snaga = 0
    for j = 0, #cr.caste - 1 do
        if cr.caste[j].caste_id == "PEON" then return j end
        if cr.caste[j].caste_id == "SNAGA" then snaga = j end
    end
    return snaga
end

local function skill_entry(unit, skill)
    local soul = unit.status.current_soul
    if not soul then return nil end
    for _, s in ipairs(soul.skills) do
        if s.id == skill then return s end
    end
    local entry = df.unit_skill:new()
    entry.id = skill
    entry.rating = 0
    entry.experience = 0
    soul.skills:insert("#", entry)
    return soul.skills[#soul.skills - 1]
end

local function grant_strand_xp(unit, amount)
    local s = skill_entry(unit, df.job_skill.EXTRACT_STRAND)
    if not s then return 0 end
    local before = s.rating
    s.experience = s.experience + amount
    while s.experience >= 500 + s.rating * 100 do
        s.experience = s.experience - (500 + s.rating * 100)
        s.rating = s.rating + 1
    end
    return before
end

local function write_name(name)
    -- nameless hordelings: just "Peon", no surname
    name.first_name = "Peon"
    name.words[0] = -1
    name.words[1] = -1
    name.has_name = true
end

local function name_orcling(u)
    write_name(u.name)
    if u.hist_figure_id >= 0 then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then write_name(hf.name) end
    end
end


local function set_age_fresh_adult(u)
    -- newly spawned units get an arbitrary old birth year; make them just-matured
    local cr = df.creature_raw.find(u.race)
    local grow = cr.caste[u.caste].misc.child_age
    if not grow or grow < 0 then grow = 0 end
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

local function spawn_orcling(near_unit)
    local race = orc_race_id()
    if not race then return nil end
    local u = dfhack.units.create(race, snaga_caste(race))
    if not u then return nil end
    local tgt = xyz2pos(near_unit.pos.x, near_unit.pos.y, near_unit.pos.z)
    u.pos.x, u.pos.y, u.pos.z = tgt.x, tgt.y, tgt.z
    u.flags1.inactive = false
    df.global.world.units.active:insert("#", u)
    dfhack.units.teleport(u, tgt)
    dfhack.units.makeown(u)
    name_orcling(u)
    set_age_fresh_adult(u)
    return u
end

local function on_breed_job(job)
    if job.reaction_name ~= BREED_REACTION then return end
    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
    local wid = wref and wref.unit_id or pending_workers[job.id]
    pending_workers[job.id] = nil
    local unit = wid and df.unit.find(wid)
    if not unit then
        dfhack.gui.showAnnouncement("The breeding pit bubbles, but its tender slipped away unseen.", COLOR_YELLOW, true)
        return
    end
    local meat = pending_meat[job.id]
    pending_meat[job.id] = nil
    if meat and meat.stack > 1 then
        -- the pit only digests one unit of the hauled stack; return the rest
        local r = dfhack.items.createItem(unit, df.item_type.MEAT, -1, meat.mat_type, meat.mat_index)
        local item = (type(r) == "table") and r[1] or r
        if item then item.stack_size = meat.stack - 1 end
    end
    local rating = grant_strand_xp(unit, 70)
    local fail_chance = 0.75 * (1 - math.min(rating, 15) / 15)
    if math.random() < fail_chance then
        dfhack.gui.showAnnouncement(
            "The breeding pit heaves and gurgles, but nothing crawls out.",
            COLOR_YELLOW, true)
        return
    end
    local u = spawn_orcling(unit)
    if u then
        dfhack.gui.showAnnouncement(
            ("An orcling crawls out of the breeding pit: %s joins the horde!")
                :format(dfhack.units.getReadableName(u)),
            COLOR_LIGHTRED, true)
    end
end

local function track_breed_workers()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) then
            for _, job in ipairs(bld.jobs) do
                if job.job_type == df.job_type.CustomReaction
                    and job.reaction_name == BREED_REACTION then
                    local wref = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT_WORKER)
                    if wref then pending_workers[job.id] = wref.unit_id end
                    for _, ji in ipairs(job.items) do
                        local it = ji.item
                        if it and df.item_meatst:is_instance(it) then
                            pending_meat[job.id] = {
                                stack = it.stack_size or 1,
                                mat_type = it.mat_type,
                                mat_index = it.mat_index,
                            }
                        end
                    end
                end
            end
        end
    end
end

local CHAMP_CASTES = {"SKINNER","MUSH_FACE","SOMBOLG","JOBBER","GRISHNAHRK","GORE_BAG","SAW_GOD","SKULL_CRUNCHER"}

-- champion caste indices for a race; champions ARE memorialized, so their ghosts
-- are left alone -- only the rank-and-file get dispelled.
local function champion_caste_set(race)
    local cr = df.creature_raw.find(race)
    local names, set = {}, {}
    for _, n in ipairs(CHAMP_CASTES) do names[n] = true end
    if cr then for j = 0, #cr.caste - 1 do if names[cr.caste[j].caste_id] then set[j] = true end end end
    return set
end

local function tick()
    track_breed_workers()
    local race = orc_race_id()
    if not race then return end
    local champs = champion_caste_set(race)
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and u.flags3.ghostly and not champs[u.caste] then
            -- rank-and-file orcs are not memorialized; champions are left to haunt
            u.flags3.ghostly = false
            u.flags1.inactive = true
            u.flags2.killed = true
        end
    end
end

local function champion_indices(race)
    local cr = df.creature_raw.find(race)
    local set, idx = {}, {}
    for _, n in ipairs(CHAMP_CASTES) do set[n] = true end
    for j = 0, #cr.caste - 1 do
        if set[cr.caste[j].caste_id] then table.insert(idx, j) end
    end
    return idx
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

local function embark_champions()
    -- all seven founders are champions, once per site; orc forts only, silent
    local race = orc_race_id()
    if not race then return end
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not civ or civ.race ~= race then return end
    local state = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    if state.embark_done then return end
    local cits = dfhack.units.getCitizens(false)
    if #cits == 0 or #cits > 7 then
        state.embark_done = true
        dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
        return
    end
    local champs = champion_indices(race)
    if #champs == 0 then return end
    local cr = df.creature_raw.find(race)
    for _, u in ipairs(cits) do
        if u.race == race and not cr.caste[u.caste].flags.NOPAIN then
            local ci = champs[math.random(#champs)]
            set_caste(u, ci)
            local si = u.body.size_info
            si.size_cur = 130000; si.size_base = 130000
            si.area_cur = math.floor(si.area_cur * 4 / 3)
            si.area_base = si.area_cur
            si.length_cur = math.floor(si.length_cur * 7 / 6)
            si.length_base = si.length_cur
        end
    end
    state.embark_done = true
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

local function do_enable()
    enabled = true
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    eventful.onJobCompleted[GLOBAL_KEY] = on_breed_job
    repeatUtil.scheduleEvery(GLOBAL_KEY, 20, "ticks", tick)
    dfhack.timeout(10, "ticks", embark_champions)
end

local function do_disable()
    enabled = false
    eventful.onJobCompleted[GLOBAL_KEY] = nil
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() then
        do_enable()
    end
end

if dfhack_flags.module then
    -- self-enable at module load: survives any load-order race with SC_MAP_LOADED
    if not enabled and dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
