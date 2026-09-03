-- ha-warlocks: everything the raws cannot say.
--@module = true
--@enable = true
--[[
high-adventure/warlocks

Ships inside the ha-warlocks mod and only ever acts in a fort whose civ is HA_WARLOCK_CIV.

What lives here, and why it cannot live in raws:

  * SOULS.  The currency. Minted on a kill, and on butchering a prisoner or a large animal.
    Meph hung an EXTRA_BUTCHER_OBJECT off every creature's brain; copying that would mean
    SELECT_CREATURE edits to every butcherable creature in the game, which is the most
    invasive thing this project forbids. A lua hook costs nothing and covers creatures other
    mods add. Sapient corpses cannot be butchered in fortress mode at all, which is why kills
    mint souls directly -- otherwise a siege would be worthless.

  * WARLOCK-ONLY WORK.  Reactions cannot be caste-gated in raws. Same fix ha-illithids uses:
    pin each workshop's profile.permitted_workers to one legal warlock.

  * SHRINE BOOKS.  A shrine is raised over an ORIGINAL written work. DF gives us that test for
    free -- an original is an artifact, a scribe's copy is not -- so the check is one flag, and
    a shrine built on a copy is deconstructed while still under construction, exactly the way
    ha-playable-civs cancels a badly-sited shaping tree.

  * ELEMENTAL CAPS.  5 per shrine of that type, and 5 x every standing shrine globally. Counted
    off the LIVING population, never off per-building state: BUILD_ITEMs are refunded on
    deconstruction, so a building counter is defeated by tearing the shrine down and rebuilding.

  * GARGOYLES.  IMMOBILE creatures cannot walk to a pasture. This teleports each one into the
    pasture it is assigned to, after a delay, while it is off screen.

  * NO MIGRANTS.  No raw token disables them; we erase the Migrants timed events instead.

  * RAID PRISONERS, CARAVAN LURES, RIOTS, and the unit creation behind every summon.

Cancellation rule, inherited from ha-illithids and not to be relaxed: conditions are checked at
ASSIGNMENT time, never at completion, so a refusal never costs the player their souls. Always
removeWorker BEFORE removeJob -- cancelling a unit's current_job directly segfaults DF.
]]

local repeatUtil = require("repeat-util")
local eventful = require("plugins.eventful")
local createUnit = reqscript("modtools/create-unit")

local GLOBAL_KEY = "haWarlocks"
local CIV_CODE = "HA_WARLOCK_CIV"
local RACE_CODE = "HA_WARLOCK"

local DAY = 1200

-- A soul comes off anything sapient, or anything this big. A human is 70000, a dog 15000.
local SOUL_MIN_BODY_SIZE = 50000

local ELEMENTS = {
    AMETHYST = "ELEMENTMAN_AMETHYST",
    FIRE     = "ELEMENTMAN_FIRE",
    GABBRO   = "ELEMENTMAN_GABBRO",
    IRON     = "ELEMENTMAN_IRON",
    MAGMA    = "ELEMENTMAN_MAGMA",
    MUD      = "ELEMENTMAN_MUD",
}

local PER_SHRINE_CAP = 5

-- Every workshop this mod adds. All of them are magic; all of them are warlock-only.
local OUR_WORKSHOPS = {
    HA_GARGOYLE_FORGE = true, HA_OBSIDIAN_FACTORY = true, HA_LIAISONS_OFFICE = true,
    HA_NECRO_SHRINE = true,
}
for code in pairs(ELEMENTS) do OUR_WORKSHOPS["HA_SHRINE_" .. code] = true end

-- Persisted only in memory: everything else is recomputed from the world each tick.
pending_raids  = pending_raids or {}    -- {due_tick=, count=, race_code=}
last_reports   = last_reports or nil    -- #world.status.mission_reports at last check
gargoyle_due   = gargoyle_due or {}     -- unit id -> tick at which we may teleport it
ws_worker      = ws_worker or {}        -- building id -> unit id we pinned

-- ----------------------------------------------------------------- helpers --

local function now() return df.global.cur_year * 403200 + df.global.cur_year_tick end

local function announce(msg, colour)
    dfhack.gui.showAnnouncement(msg, colour or COLOR_LIGHTMAGENTA, true)
end

local function player_civ()
    local e = df.historical_entity.find(df.global.plotinfo.civ_id)
    if e and e.entity_raw and e.entity_raw.code == CIV_CODE then return e end
end

local function race_id()
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == RACE_CODE then return i end
    end
end

local function creature_id(code)
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        if cr.creature_id == code then return i end
    end
end

local function caste_index(race, caste_code)
    local cr = df.global.world.raws.creatures.all[race]
    if not cr then return nil end
    for j = 0, #cr.caste - 1 do
        if cr.caste[j].caste_id == caste_code then return j end
    end
end

local function caste_of(u)
    local cr = df.creature_raw.find(u.race)
    local c = cr and cr.caste[u.caste]
    return c and c.caste_id or ""
end

local function is_warlock(u)
    local cn = caste_of(u)
    return u.race == race_id() and (cn == "WARLOCK_M" or cn == "WARLOCK_F")
end

local function fort_units(pred)
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if not u.flags1.inactive and not u.flags2.killed and pred(u) then out[#out + 1] = u end
    end
    return out
end

local function workshop_code(bld)
    if not df.building_workshopst:is_instance(bld) then return nil end
    if bld.custom_type < 0 then return nil end
    local def = df.building_def.find(bld.custom_type)
    return def and def.code or nil
end

local function each_workshop(fn)
    for _, b in ipairs(df.global.world.buildings.all) do
        local code = workshop_code(b)
        if code and OUR_WORKSHOPS[code] then fn(b, code) end
    end
end

local function is_complete(b) return b.construction_stage >= b:getMaxBuildStage() end

-- --------------------------------------------------------------- the souls --

local function soul_mat()
    local mi = dfhack.matinfo.find("INORGANIC:HA_SOUL")
    return mi and mi.type, mi and mi.index
end

-- Create souls at a position. The creator is only a handle DF needs; the item is then put on
-- the floor where the thing died or was butchered. Never pass no_floor -- an item created with
-- it is stuck in limbo forever and can never be hauled.
local function mint_souls(pos, count)
    local mt, mi = soul_mat()
    if not mt then return 0 end
    local creator = fort_units(function(u) return dfhack.units.isCitizen(u) end)[1]
    if not creator then return 0 end
    local made = 0
    for _ = 1, (count or 1) do
        local ok, items = pcall(dfhack.items.createItem, creator, df.item_type.BOULDER, -1, mt, mi)
        if ok and items and items[1] then
            pcall(dfhack.items.moveToGround, items[1], pos or creator.pos)
            made = made + 1
        end
    end
    return made
end

local function yields_soul(race, caste)
    local cr = df.creature_raw.find(race)
    if not cr then return false end
    local c = cr.caste[caste or 0]
    if not c then return false end
    if c.flags.CAN_LEARN or c.flags.CAN_SPEAK then return true end     -- anything sapient
    local sizes = c.body_size_2
    local biggest = 0
    for _, s in ipairs(sizes) do if s > biggest then biggest = s end end
    return biggest >= SOUL_MIN_BODY_SIZE
end

local function on_death(unit_id)
    if not player_civ() then return end
    local u = df.unit.find(unit_id)
    if not u then return end
    if dfhack.units.isCitizen(u) then return end             -- your own dead are not currency
    if yields_soul(u.race, u.caste) then
        mint_souls(u.pos, 1)
    end
end

-- Butchery: the corpse item carries the race it came from, so we can tell a prisoner or a big
-- beast from a turkey without touching a single creature raw.
local function on_butcher(job)
    if not player_civ() then return end
    local pris = creature_id("HA_PRISONER")
    for _, ir in ipairs(job.items) do
        local it = ir.item
        local ty = it and it:getType()
        if ty == df.item_type.CORPSE or ty == df.item_type.CORPSEPIECE then
            local r = it.race
            if r and (r == pris or yields_soul(r, it.caste)) then
                mint_souls(job.pos, 1)
                return
            end
        end
    end
end

-- ----------------------------------------------------- warlock-only labour --

local function pick_warlock()
    local best
    for _, u in ipairs(fort_units(function(u) return dfhack.units.isCitizen(u) and is_warlock(u) end)) do
        if not best or (u.job.current_job == nil) then best = u end
        if u.job.current_job == nil then break end
    end
    return best
end

local function set_profile(b, uid)
    local pw = b.profile.permitted_workers
    pw:resize(0)
    if uid then pw:insert("#", uid) end
    ws_worker[b.id] = uid
end

local function cancel_job(job, msg)
    pcall(dfhack.job.removeWorker, job, 0)
    pcall(dfhack.job.removeJob, job)
    if msg then announce(msg, COLOR_YELLOW) end
end

-- ------------------------------------------------------------- shrine caps --

local function shrine_counts()
    local per, total = {}, 0
    each_workshop(function(b, code)
        local el = code:match("^HA_SHRINE_(.+)$")
        if el and is_complete(b) then
            per[el] = (per[el] or 0) + 1
            total = total + 1
        end
    end)
    return per, total
end

local function elemental_counts()
    local per, total = {}, 0
    local by_race = {}
    for el, code in pairs(ELEMENTS) do
        local r = creature_id(code)
        if r then by_race[r] = el end
    end
    for _, u in ipairs(df.global.world.units.active) do
        if not u.flags1.inactive and not u.flags2.killed then
            local el = by_race[u.race]
            if el and dfhack.units.isOwnGroup(u) then
                per[el] = (per[el] or 0) + 1
                total = total + 1
            end
        end
    end
    return per, total
end

-- Both caps scale with the shrines standing right now. The global is NOT redundant: tear a
-- fire shrine down with five fire elementals alive and build an ice one, and the ice type cap
-- is clear while the global still counts those five.
local function may_summon(el)
    local sper, stotal = shrine_counts()
    local eper, etotal = elemental_counts()
    local type_cap = PER_SHRINE_CAP * (sper[el] or 0)
    local global_cap = PER_SHRINE_CAP * stotal
    if (eper[el] or 0) >= type_cap then
        return false, ("The %s shrines will hold no more than %d of their own."):format(el:lower(), type_cap)
    end
    if etotal >= global_cap then
        return false, ("Your shrines can bind only %d elementals in all; build another."):format(global_cap)
    end
    return true
end

-- ------------------------------------------------------------ unit spawning --

local function spawn(race_code, caste_code, pos, tame, quantity)
    local r = creature_id(race_code)
    if not r then return nil end
    local ok, err = pcall(createUnit.createUnit, race_code, caste_code, pos, nil, nil, nil,
                          tame and true or false,
                          tame and -1 or df.global.plotinfo.civ_id,
                          tame and -1 or df.global.plotinfo.group_id,
                          nil, nil, nil, quantity or 1)
    if not ok then dfhack.printerr("ha-warlocks: spawn failed: " .. tostring(err)) end
    return ok
end

-- Citizens (skeletons, bone golems) are members of the fort group; pets (elementals, mephits,
-- gargoyles, imps) are domesticated instead.
local function spawn_citizen(caste_code, pos)
    return spawn(RACE_CODE, caste_code, pos, false, 1)
end

local function spawn_pet(race_code, caste_code, pos)
    return spawn(race_code, caste_code, pos, true, 1)
end

-- ----------------------------------------------------------- job dispatch --

local MEPHIT_ROLL = { {"HA_MEPHIT", "AIR"}, {"HA_MEPHIT", "ACID"}, {"HA_MEPHIT", "ICE"},
                      {"IMP_FIRE", nil} }

local function shrine_element(job)
    local b = df.building.find(job.building_id or -1)
    local code = b and workshop_code(b)
    return code and code:match("^HA_SHRINE_(.+)$")
end

local HANDLERS = {}

HANDLERS.HA_GARGOYLE_MELEE = function(job) spawn_pet("HA_GARGOYLE", "MELEE", job.pos) end
HANDLERS.HA_GARGOYLE_FIRE  = function(job) spawn_pet("HA_GARGOYLE", "FIRE",  job.pos) end
HANDLERS.HA_GARGOYLE_ICE_GEM   = function(job) spawn_pet("HA_GARGOYLE", "ICE", job.pos) end
HANDLERS.HA_GARGOYLE_ICE_GLASS = HANDLERS.HA_GARGOYLE_ICE_GEM

local function bind_mephit(job)
    local pick = MEPHIT_ROLL[math.random(#MEPHIT_ROLL)]
    spawn_pet(pick[1], pick[2], job.pos)
    announce("Something small and pleased with itself uncoils out of the gem.")
end
HANDLERS.HA_BIND_MEPHIT_GEM = bind_mephit
HANDLERS.HA_BIND_MEPHIT_GLASS = bind_mephit

HANDLERS.HA_RAISE_SKELETON = function(job)
    spawn_citizen("SKELETON", job.pos)
    announce("A skeleton stands up and waits to be told what to do.")
end

local function raise_golem(job)
    spawn_citizen("BONE_GOLEM", job.pos)
    announce("The bone golem takes its first step. The floor complains.")
end
HANDLERS.HA_BONE_GOLEM_GEM = raise_golem
HANDLERS.HA_BONE_GOLEM_GLASS = raise_golem

-- Empowering a warlock: physical and mental attributes are pushed up a step. Deliberately
-- modest and repeatable rather than a one-shot jackpot.
local function empower(job)
    local w = pick_warlock()
    if not w then return end
    for _, att in ipairs({"STRENGTH", "TOUGHNESS", "ENDURANCE", "WILLPOWER", "FOCUS"}) do
        local a = w.body.physical_attrs[df.physical_attribute_type[att]]
        if a then a.value = math.min(5000, a.value + 250) end
    end
    for _, att in ipairs({"WILLPOWER", "FOCUS", "ANALYTICAL_ABILITY"}) do
        local a = w.status.current_soul and
                  w.status.current_soul.mental_attrs[df.mental_attribute_type[att]]
        if a then a.value = math.min(5000, a.value + 250) end
    end
    announce(("%s comes out of the shrine changed."):format(dfhack.units.getReadableName(w)))
end
HANDLERS.HA_POWER_WARLOCK_GEM = empower
HANDLERS.HA_POWER_WARLOCK_GLASS = empower

local function resurrect(job)
    -- Bring back a dead warlock of this fort: cheapest correct route is DFHack's own revival.
    for _, u in ipairs(df.global.world.units.all) do
        if u.race == race_id() and u.flags2.killed and is_warlock(u) then
            local ok = pcall(dfhack.run_command, "full-heal", "-r", "-unit", tostring(u.id))
            if ok then
                announce(("%s is called back out of the dark."):format(dfhack.units.getReadableName(u)))
                return
            end
        end
    end
    announce("Nothing answers: no warlock of this tower lies dead.", COLOR_YELLOW)
end
for mat in pairs({DIAMOND_CLEAR=1, DIAMOND_RED=1, DIAMOND_GREEN=1, DIAMOND_BLUE=1,
                  DIAMOND_YELLOW=1, DIAMOND_BLACK=1, DIAMOND_FY=1, DIAMOND_LY=1}) do
    HANDLERS["HA_RESURRECT_" .. mat] = resurrect
end

for el, code in pairs(ELEMENTS) do
    HANDLERS["HA_SUMMON_" .. el] = function(job)
        spawn_pet(code, nil, job.pos)
        announce(("A %s steps out of the shrine."):format(code:gsub("ELEMENTMAN_", ""):lower()))
    end
    HANDLERS["HA_MOOD_" .. el] = function(job)
        pcall(dfhack.run_command, "strangemood", "-force")
    end
end

-- Caravans. This is the same engine event stock `force` writes; the guard matters more than
-- the write does -- see dfhack/fort/caravan-unstick.lua for what an outstanding caravan does
-- to a civ's future visits.
local function civ_has_caravan(entity)
    for _, c in ipairs(df.global.plotinfo.caravans) do
        if c.entity == entity.id then return true end
    end
    return false
end

local function lure(entity, label)
    if not entity then
        announce("No such neighbour answers the letter.", COLOR_YELLOW); return
    end
    if civ_has_caravan(entity) then
        announce(("The %s already have a caravan on the road; the letter is wasted."):format(label),
                 COLOR_YELLOW)
        return
    end
    df.global.timed_events:insert("#", {
        new = true,
        type = df.timed_event_type.Caravan,
        season = df.global.cur_season,
        season_ticks = df.global.cur_season_tick,
        entity = entity,
        feature_ind = -1,
    })
    announce(("A %s caravan turns towards the tower."):format(label))
end

local function find_entity(pred)
    for _, e in ipairs(df.global.world.entities.all) do
        if e.type == df.historical_entity_type.Civilization and pred(e) then return e end
    end
end

HANDLERS.HA_LURE_CARAVAN_OWN = function()
    lure(player_civ(), "warlock")
end
HANDLERS.HA_LURE_CARAVAN_GOBLIN = function()
    lure(find_entity(function(e) return e.entity_raw.code == "EVIL" end), "goblin")
end
HANDLERS.HA_LURE_CARAVAN_ANY = function()
    local civ = player_civ()
    lure(find_entity(function(e) return e ~= civ end), "foreign")
end

local function on_job_completed(job)
    if not player_civ() then return end
    if job.job_type == df.job_type.ButcherAnimal then
        pcall(on_butcher, job)
        return
    end
    local rn = job.reaction_name
    if not rn or rn:sub(1, 3) ~= "HA_" then return end
    local h = HANDLERS[rn]
    if h then
        local ok, err = pcall(h, job)
        if not ok then dfhack.printerr("ha-warlocks: " .. rn .. ": " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------- shrine books --

-- An original written work is an artifact; a scribe's copy is not, and a blank quire never is.
-- So the whole "is this book unique" question is one flag.
local function book_is_original(b)
    for _, ci in ipairs(b.contained_items) do
        local it = ci.item
        if it and it:getType() == df.item_type.TOOL then
            if it.flags.artifact then return true end
            return false
        end
    end
    return nil     -- no book hauled yet: undecided, check again next tick
end

local function enforce_shrine_books()
    each_workshop(function(b, code)
        if not code:match("^HA_SHRINE_") then return end
        if is_complete(b) then return end
        local ok = book_is_original(b)
        if ok == false then
            dfhack.buildings.deconstruct(b)
            announce("A shrine must be raised over an original work. A copy is only paper.",
                     COLOR_YELLOW)
        end
    end)
end

-- ------------------------------------------------------------- gargoyles --

local function assigned_pasture(u)
    for _, ref in ipairs(u.general_refs) do
        if df.general_ref_building_civzone_assignedst:is_instance(ref) then
            return df.building.find(ref.building_id)
        end
    end
end

local function on_screen(pos)
    local g = df.global
    if pos.z ~= g.window_z then return false end
    return pos.x >= g.window_x and pos.x < g.window_x + g.gps.dimx
       and pos.y >= g.window_y and pos.y < g.window_y + g.gps.dimy
end

-- A gargoyle cannot walk anywhere. Assign it a pasture and, a little later and only when you
-- are looking somewhere else, it will simply be there.
local function move_gargoyles()
    local grace = creature_id("HA_GARGOYLE")
    if not grace then return end
    local t = now()
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == grace and not u.flags1.inactive and not u.flags2.killed then
            local z = assigned_pasture(u)
            if z then
                local inside = u.pos.z == z.z and u.pos.x >= z.x1 and u.pos.x <= z.x2
                               and u.pos.y >= z.y1 and u.pos.y <= z.y2
                if inside then
                    gargoyle_due[u.id] = nil
                else
                    local due = gargoyle_due[u.id]
                    if not due then
                        gargoyle_due[u.id] = t + DAY
                    elseif t >= due and not on_screen(u.pos) then
                        local x = math.random(z.x1, z.x2)
                        local y = math.random(z.y1, z.y2)
                        pcall(dfhack.units.teleport, u, xyz2pos(x, y, z.z))
                        gargoyle_due[u.id] = nil
                    end
                end
            end
        end
    end
end

-- --------------------------------------------------------- no migrants --

local function suppress_migrants()
    local civ = player_civ()
    if not civ then return end
    for i = #df.global.timed_events - 1, 0, -1 do
        local ev = df.global.timed_events[i]
        if ev.type == df.timed_event_type.Migrants then
            df.global.timed_events:erase(i)
        end
    end
end

-- ------------------------------------------------- raids bring prisoners --

local PRIS_CASTE_BY_RACE = {
    GOBLIN = "GOBLIN", DWARF = "DWARF", HUMAN = "HUMAN", ELF = "ELF", KOBOLD = "KOBOLD",
}

local function raid_prisoner_caste(report)
    for _, sid in ipairs(report.searched_site) do
        local site = df.world_site.find(sid)
        local ent = site and df.historical_entity.find(site.civ_id)
        local cr = ent and df.creature_raw.find(ent.race)
        local caste = cr and PRIS_CASTE_BY_RACE[cr.creature_id]
        if caste then return caste end
    end
end

local function watch_missions()
    local reports = df.global.world.status.mission_reports
    local n = #reports
    if last_reports == nil then last_reports = n; return end
    if n <= last_reports then last_reports = n; return end
    for i = last_reports, n - 1 do
        local r = reports[i]
        local caste = r and raid_prisoner_caste(r)
        local count = math.random(0, 3)
        if count > 0 then
            pending_raids[#pending_raids + 1] =
                { due = now() + 2 * DAY, count = count, caste = caste }
        end
    end
    last_reports = n
end

local function land_raid_prisoners()
    local t = now()
    for i = #pending_raids, 1, -1 do
        local p = pending_raids[i]
        if t >= p.due then
            local host = pick_warlock() or fort_units(dfhack.units.isCitizen)[1]
            if host then
                for _ = 1, p.count do
                    spawn_pet("HA_PRISONER", p.caste, host.pos)
                end
                announce(("Your raiders drag %d prisoner(s) into the tower."):format(p.count))
            end
            table.remove(pending_raids, i)
        end
    end
end

-- ---------------------------------------------------------------- riots --

-- Dwarven, human and elven prisoners still remember being people. Once in a long while one
-- stops being livestock: it is simply set wild, and a wild thing loose in a dungeon is a riot.
local RIOTOUS = { DWARF = true, HUMAN = true, ELF = true }

local function prisoner_riots()
    local pris = creature_id("HA_PRISONER")
    if not pris then return end
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == pris and u.flags1.tame and not u.flags1.inactive and not u.flags2.killed then
            if RIOTOUS[caste_of(u)] and math.random(1000) == 1 then
                pcall(createUnit.wildUnit, u)
                announce("A prisoner has stopped cooperating.", COLOR_RED)
            end
        end
    end
end

-- ------------------------------------------------------------ the ticks --

-- Fast: staff the workshops with a warlock, refuse jobs that cannot legally finish, and shuffle
-- gargoyles. Conditions are tested HERE, at assignment, not at completion.
local function fast_tick()
    if not player_civ() then return end
    each_workshop(function(b, code)
        local jobs = {}
        for _, job in ipairs(b.jobs) do
            if job.job_type == df.job_type.CustomReaction and job.reaction_name
               and job.reaction_name:sub(1, 3) == "HA_" then
                jobs[#jobs + 1] = job
            end
        end
        -- cap check, before any soul is spent
        for _, job in ipairs(jobs) do
            local el = job.reaction_name:match("^HA_SUMMON_(.+)$")
            if el then
                local ok, why = may_summon(el)
                if not ok then cancel_job(job, why) end
            end
        end
        if #b.jobs == 0 then
            if #b.profile.permitted_workers > 0 then set_profile(b, nil) end
            return
        end
        local pinned = ws_worker[b.id] and df.unit.find(ws_worker[b.id])
        if not (pinned and dfhack.units.isCitizen(pinned) and is_warlock(pinned)
                and not pinned.flags1.inactive and not pinned.flags2.killed) then
            local w = pick_warlock()
            if w then
                set_profile(b, w.id)
            else
                for _, job in ipairs(jobs) do
                    cancel_job(job, "No warlock is left to work the magic.")
                end
                set_profile(b, nil)
            end
        end
    end)
    pcall(enforce_shrine_books)
    pcall(move_gargoyles)
end

-- Slow: population bookkeeping.
local function slow_tick()
    if not player_civ() then return end
    pcall(suppress_migrants)
    pcall(watch_missions)
    pcall(land_raid_prisoners)
    pcall(prisoner_riots)
end

local function do_enable()
    repeatUtil.cancel(GLOBAL_KEY)
    repeatUtil.cancel(GLOBAL_KEY .. "Slow")
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    eventful.enableEvent(eventful.eventType.UNIT_DEATH, 5)
    eventful.onJobCompleted[GLOBAL_KEY] = on_job_completed
    eventful.onUnitDeath[GLOBAL_KEY] = on_death
    repeatUtil.scheduleEvery(GLOBAL_KEY, 25, "ticks", function()
        local ok, err = pcall(fast_tick)
        if not ok then dfhack.printerr("ha-warlocks: tick error (continuing): " .. tostring(err)) end
    end)
    repeatUtil.scheduleEvery(GLOBAL_KEY .. "Slow", 500, "ticks", function()
        local ok, err = pcall(slow_tick)
        if not ok then dfhack.printerr("ha-warlocks: slow tick error (continuing): " .. tostring(err)) end
    end)
end

local function do_disable()
    eventful.onJobCompleted[GLOBAL_KEY] = nil
    eventful.onUnitDeath[GLOBAL_KEY] = nil
    repeatUtil.cancel(GLOBAL_KEY)
    repeatUtil.cancel(GLOBAL_KEY .. "Slow")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() then
        if player_civ() then do_enable() end
    end
end

if dfhack_flags.module then
    -- Re-register on every module load: scheduleEvery is keyed and idempotent, and a stale
    -- `enabled` flag must never gate this or a hot reload silently stops the ticks.
    if dfhack.isMapLoaded() and dfhack.world.isFortressMode() and player_civ() then do_enable() end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
end
