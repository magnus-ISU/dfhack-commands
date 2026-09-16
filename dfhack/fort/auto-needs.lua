-- Lend a dwarf whose need is eating them a labor that satisfies it, and take it back after.
--@module = true
--@enable = true
--[[
fort/auto-needs

A dwarf with an unmet need does not tell you which one; the thought log says "has been
unable to leave the fortress lately" and the stress climbs and that is all the warning
there is. Some of those needs have a LABOR that answers them, and this hands that labor
out to the dwarves who need it -- then takes it back once they have had their fill, so
the fort's job assignments are not quietly rewritten forever by a mood that has passed.

TODAY IT KNOWS ONE LABOR AND ONE POST:

  WANDER -> FISHING. "Wander" is satisfied by being outside the fortress, and fishing is
  the reliable way a dwarf takes themselves out there and stays a while. Given the labor,
  a wandering-starved dwarf walks to the water, and the need drains on its own.

  The dwarf must be BOTH short on the need and carrying stress -- the need alone is
  ordinary (half a fort is a little short of wandering at any time) and the stress alone
  says nothing about which need is doing it.

  THINK ABSTRACTLY / SELF-EXAMINATION -> A SCHOLAR'S POST AT THE PUBLIC LIBRARY. Both of
  those needs are drained by the same act -- reading or writing something -- and the
  scholar occupation at a library is how a dwarf gets sent to do it. Mark one library
  [Public Library] and the neediest dwarves are posted there, and taken off again once
  they have read their fill. This half is described under THE PUBLIC LIBRARY below.

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

THE PUBLIC LIBRARY

  Open a zone belonging to a library and a [Public Library] button sits on its panel, the
  same place `training-barracks` puts [Basic training] on a barracks. Pressing it marks
  THAT LIBRARY -- the location, not the zone, so any of the zones that make it up will do
  -- as the one this tool staffs, and starts the background pass. Pressing it again stops
  staffing it; everyone this tool posted there is taken off on the way out.

  Each pass, EVERY citizen short past the bar is given a SCHOLAR post at that library.
  There is no limit and no queue: they read, the need drains, and a pass or two later the
  post is handed back, so the library staffs itself up and down with the fort's mood the
  way `autotraining` and `idle-crafting` do. The post is a loan, not a career.

  NOBODY IS PASSED OVER FOR BEING BUSY -- a soldier, a tavern keeper, a doctor all get one
  the moment they are short, because it costs them a few hours of reading. Two things still
  rule a dwarf out and neither is a policy: no historical figure (an occupation record is
  keyed by `histfig_id`, so there is nothing to write) and already being a scholar here.
  Children never come up; DF has no child occupations. A post this tool did NOT make is
  filled and then emptied, never deleted, so a library set up by hand keeps its shape.

  HOW A POST IS ACTUALLY GIVEN. An occupation has three owners and DF reads all three: the
  location's `occupations` list, the unit's, and `world.occupations.all`. Posting a dwarf
  writes `unit_id` and `histfig_id` on the record and adds it to the unit; taking them off
  clears both and removes it again. Scholar SLOTS beyond the ones the fort already has are
  created (and removed again when empty), which is a resize of the location's vector --
  never done while the location details panel is open on that library, because that panel
  holds raw pointers into it and resizing under it crashes DF.

THE THRESHOLD

  ONE BAR, SHARED BY EVERY RULE HERE AND EVERY RULE ADDED LATER: -750. A need's
  `focus_level` goes negative as it goes unmet, and -750 is far enough down to catch a dwarf
  before the need starts distracting them or handing them bad thoughts, without tripping on
  the ordinary shortfall half the fort carries at any moment. The loan is handed back at
  zero, so there is a gap between the two bars and nobody flickers in and out on a point of
  focus.

  Stress is not part of the test. An earlier version demanded it as well, which meant
  waiting for the damage to show before answering the need that was causing it.
]]

local GLOBAL_KEY = 'auto-needs'

-- ONE BAR FOR EVERY RULE IN THIS FILE, and every rule added later. A need's `focus_level`
-- goes negative as it goes unmet, and -750 is where it stops being background noise and
-- starts costing the dwarf: far enough down to be worth acting on, not so shallow that half
-- the fort trips it every pass. Measured here, 85 of 95 citizens carry an unmet thinking or
-- introspection need at any moment and most sit a couple of hundred below zero -- ordinary
-- life, and not something to reassign anybody over.
--
-- The bar is the WHOLE test. An earlier version also demanded stress before lending anything,
-- which meant waiting for the damage to show before answering the need that was doing it;
-- -750 catches the dwarf on the way down instead, which is the point of the tool.
local FOCUS_UNMET = -750      -- how far a need has to have slipped before this tool acts
local FOCUS_MET = 0           -- and where it is back above water, so the loan can end
local SCAN_FRAMES = 1200      -- a pass every game day or so

-- need -> the labor that answers it. One entry today; the shape is the point.
local RULES = {
    {need = df.need_type.Wander, labor = df.unit_labor.FISH,
     why = 'wander', gives = 'fishing'},
}

-- The two needs a scholar's post answers. DF drains both of them with the same act --
-- reading or writing written content -- which is exactly what a library scholar does.
local SCHOLAR_NEEDS = {df.need_type.ThinkAbstractly, df.need_type.SelfExamination}


-- ---- state: the labors WE lent, per site ------------------------------------

local state = nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
        state.lent = state.lent or {}      -- ["unit_id/labor"] = true
        state.lent = type(state.lent) == 'table' and state.lent or {}
        -- the public library: the LOCATION we staff, who we posted there, and which of
        -- those posts we had to create (so only those are ever deleted again)
        if state.library_id == nil then state.library_id = -1 end
        state.posted = type(state.posted) == 'table' and state.posted or {}   -- ["unit_id"] = occupation id
        state.our_slots = type(state.our_slots) == 'table' and state.our_slots or {}  -- ["occupation id"] = true
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

-- STRESS OPENS THE BAR EARLY. -750 is where an unmet need stops being background noise for
-- an ordinary dwarf, but a dwarf who is already breaking does not have the slack to wait for
-- it: the fort's angriest citizen sat at 70,754 stress with abstract thinking at -614 -- a
-- need she genuinely was not getting, just not far enough down to be noticed -- and was
-- passed over pass after pass while calmer dwarves were posted.
--
-- So anything unmet at all counts once DF's own stress categories call the dwarf stressed.
--
-- THE CATEGORY SCALE RUNS DOWNWARDS: 0 is Miserable and 6 is Ecstatic, the opposite of what
-- the name suggests. Measured here -- the dwarf at 70,714 stress reports category 0, the ones
-- at -100,000 report 6 -- so "stressed" is `<=`, and a `>=` test silently selects the
-- HAPPIEST dwarves in the fort. Category 2 is about 10,000 stress and up.
local STRESSED_AT = 2

local function badly_stressed(unit)
    local ok, cat = pcall(dfhack.units.getStressCategory, unit)
    return ok and cat and cat <= STRESSED_AT or false
end

-- is this dwarf short enough on `focus` for the tool to act?
local function past_the_bar(unit, focus)
    if not focus then return false end
    if focus <= FOCUS_UNMET then return true end
    return focus < 0 and badly_stressed(unit)
end

-- does this dwarf want the labor right now? The shared bar is the whole test; the loan is
-- given back at FOCUS_MET, so there is a gap between the two and nobody flickers in and out
-- of a labor on a single point of focus.
local function qualifies(unit, rule)
    return past_the_bar(unit, need_focus(unit, rule.need))
end

-- and is the loan finished? (kept apart from `qualifies` so the two bars can differ)
local function finished(unit, rule)
    local focus = need_focus(unit, rule.need)
    return focus == nil or focus >= FOCUS_MET
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
                elseif ours and not finished(unit, rule) then
                    -- climbing back but not there yet: leave the loan where it is
                    kept = kept + 1
                elseif ours then
                    -- had their fill: give the labor back
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

-- ---- the public library ------------------------------------------------------

-- The abstract building (the LOCATION) behind an id, if this fort owns it and it is a
-- library. Zones come and go; the location is the thing worth remembering.
local function find_library(id)
    if not id or id < 0 then return nil end
    local site = df.world_site.find(df.global.plotinfo.site_id)
    if not site then return nil end
    for _, b in ipairs(site.buildings) do
        if b.id == id and b:getType() == df.abstract_building_type.LIBRARY then return b end
    end
end

-- the library a zone belongs to, or nil. A library is made of MeetingHall civzones that
-- carry its `location_id`, and there can be several of them; any one identifies it.
local function library_of_zone(zone)
    if not zone or not df.building_civzonest:is_instance(zone) then return nil end
    return find_library(zone.location_id)
end

-- Is DF's location details panel sitting open on this library? Its `loc_occupation` vector
-- holds RAW POINTERS into the location's occupation list, so growing or shrinking that list
-- underneath it is a crash. Reading and writing the records in place is fine.
local function details_open_on(lib)
    local ld = df.global.game.main_interface.location_details
    return ld and ld.open and ld.selected_ab == lib
end

-- how short this dwarf is on the scholar needs: the deepest shortfall of the ones they have,
-- or nil when they have neither. Used both to rank candidates and to decide who is finished.
local function scholar_shortfall(unit)
    local worst
    for _, need in ipairs(SCHOLAR_NEEDS) do
        local focus = need_focus(unit, need)
        if focus and (not worst or focus < worst) then worst = focus end
    end
    return worst
end

-- every SCHOLAR post at this library, and how many of them are standing empty
local function scholar_posts(lib)
    local posts = {}
    for _, o in ipairs(lib.occupations) do
        if o.type == df.occupation_type.SCHOLAR then posts[#posts + 1] = o end
    end
    return posts
end

-- Open one more scholar's post. Three owners have to know about an occupation and two of
-- them are lists: the world's and the location's. Ids are unique across the world, so a new
-- one is the highest in use plus one.
local function open_post(lib, s)
    local all = df.global.world.occupations.all
    local max_id = -1
    for _, o in ipairs(all) do if o.id > max_id then max_id = o.id end end
    local o = df.occupation:new()
    o.id = max_id + 1
    o.type = df.occupation_type.SCHOLAR
    o.histfig_id, o.unit_id = -1, -1
    o.location_id = lib.id
    o.site_id = lib.site_id
    o.group_id = -1
    all:insert('#', o)
    lib.occupations:insert('#', o)
    s.our_slots[tostring(o.id)] = true
    return o
end

-- Close a post we opened, once it is empty again. A post the fort made by hand is never
-- closed -- filling and emptying it is a loan, deleting it would be redecorating.
local function close_post(lib, o, s)
    for i = #lib.occupations - 1, 0, -1 do
        if lib.occupations[i] == o then lib.occupations:erase(i) end
    end
    local all = df.global.world.occupations.all
    for i = #all - 1, 0, -1 do
        if all[i] == o then all:erase(i); break end
    end
    s.our_slots[tostring(o.id)] = nil
    o:delete()
end

local function post_dwarf(o, unit)
    o.unit_id = unit.id
    o.histfig_id = unit.hist_figure_id
    unit.occupations:insert('#', o)
end

local function unpost_dwarf(o)
    local u = o.unit_id >= 0 and df.unit.find(o.unit_id)
    if u then
        for i = #u.occupations - 1, 0, -1 do
            if u.occupations[i] == o then u.occupations:erase(i) end
        end
    end
    o.unit_id, o.histfig_id = -1, -1
end

-- Could this dwarf be posted at all? NOBODY is passed over for being busy: a soldier, a
-- tavern keeper, a doctor all get a post the moment they are short, because the post is a
-- few hours of reading and step 1 takes it back again. Two things still rule a dwarf out,
-- and neither is a policy:
--   * no historical figure -- an occupation record is keyed by `histfig_id` and DF's own
--     picker only ever offers figures, so there is nothing to write;
--   * already a scholar at this library -- one post each, not two.
-- (Children never reach here: `citizens()` is adults only, and DF has no child occupations.)
--
-- Holding a SECOND occupation alongside an existing one is off DF's own beaten path -- 286
-- filled posts in this world and not one figure holds two -- so it was tried before it was
-- shipped: a tavern keeper given a scholar's post kept both records and kept working, and
-- the game ran on. It is still the one thing here DF never does by itself.
local function can_be_posted(unit)
    if unit.hist_figure_id < 0 then return false end
    for _, o in ipairs(unit.occupations) do
        if o.type == df.occupation_type.SCHOLAR then return false end
    end
    return true
end

-- One library pass. Returns who was posted, who was released, and how many are still reading.
-- `dry` reports without touching anything.
function scan_library(dry)
    local s = load_state()
    local posted, released, holding = {}, {}, 0
    local lib = find_library(s.library_id)
    if not lib then
        -- the library was deleted: forget it, and forget the people we had there
        if s.library_id >= 0 and not dry then
            s.library_id, s.posted, s.our_slots = -1, {}, {}
            save_state()
        end
        return posted, released, holding, nil
    end

    local frozen = details_open_on(lib)     -- no resizing the occupation list under the panel
    local posts = scholar_posts(lib)
    local by_id = {}
    for _, o in ipairs(posts) do by_id[tostring(o.id)] = o end

    -- 1. who is finished? Every scholar we posted whose needs are back above water -- or who
    --    died, left, or had their post taken away by hand.
    for key, occ_id in pairs(s.posted) do
        local unit = df.unit.find(tonumber(key))
        local o = by_id[tostring(occ_id)]
        local done = true
        if unit and o and o.unit_id == unit.id and dfhack.units.isCitizen(unit)
                and not dfhack.units.isDead(unit) then
            local worst = scholar_shortfall(unit)
            done = not worst or worst >= FOCUS_MET
        end
        if done then
            -- only ever empty the post if it is still OUR dwarf standing in it: somebody
            -- re-assigned by hand in the meantime is not this tool's to move
            if not dry then
                if o and (o.unit_id < 0 or o.unit_id == tonumber(key)) then unpost_dwarf(o) end
                s.posted[key] = nil
            end
            released[#released + 1] = {unit = unit, id = tonumber(key)}
        else
            holding = holding + 1
        end
    end

    -- 2. who is short? EVERYBODY past the bar gets a post -- there is no limit and no
    --    queue. A scholar reads, the need drains, and step 1 hands the post back a pass or
    --    two later, so the library staffs itself up and down with the fort's mood instead of
    --    rationing a few seats to the worst-off. Neediest first only so that a pass cut
    --    short by the details panel does the most useful work it can.
    local want = {}
    for _, unit in ipairs(citizens()) do
        if not s.posted[tostring(unit.id)] and can_be_posted(unit) then
            local worst = scholar_shortfall(unit)
            if past_the_bar(unit, worst) then
                want[#want + 1] = {unit = unit, shortfall = worst}
            end
        end
    end
    table.sort(want, function(a, b)
        if a.shortfall ~= b.shortfall then return a.shortfall < b.shortfall end
        return a.unit.id < b.unit.id
    end)

    -- 3. fill the empty posts, opening as many more as it takes
    local empty = {}
    for _, o in ipairs(posts) do
        if o.unit_id < 0 and o.histfig_id < 0 then empty[#empty + 1] = o end
    end
    for _, cand in ipairs(want) do
        local o = table.remove(empty, 1)
        if not o and not frozen and not dry then o = open_post(lib, s) end
        if not o and dry then o = true end          -- the dry run only needs to say "this one"
        if not o then break end                     -- panel open and nothing free: wait a pass
        if not dry then
            post_dwarf(o, cand.unit)
            s.posted[tostring(cand.unit.id)] = o.id
        end
        posted[#posted + 1] = cand
        holding = holding + 1
    end

    -- 4. tidy: close the posts we opened that nobody is standing in any more, so a library
    --    this tool has finished with looks the way the fort left it
    if not dry and not frozen then
        for _, o in ipairs(scholar_posts(lib)) do
            if s.our_slots[tostring(o.id)] and o.unit_id < 0 and o.histfig_id < 0 then
                close_post(lib, o, s)
            end
        end
    end

    if not dry then save_state() end
    return posted, released, holding, lib
end

-- Take everybody off and close every post we opened. Used when the library is un-marked.
local function clear_library()
    local s = load_state()
    local lib = find_library(s.library_id)
    if lib and not details_open_on(lib) then
        for _, o in ipairs(scholar_posts(lib)) do
            local ours_post = false
            for key, occ_id in pairs(s.posted) do
                if occ_id == o.id then ours_post = true; s.posted[key] = nil end
            end
            if ours_post then unpost_dwarf(o) end
        end
        for _, o in ipairs(scholar_posts(lib)) do
            if s.our_slots[tostring(o.id)] and o.unit_id < 0 and o.histfig_id < 0 then
                close_post(lib, o, s)
            end
        end
    end
    s.posted, s.our_slots = {}, {}
end

-- ---- heartbeat --------------------------------------------------------------

local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_needs_hb_gen = set end
    return dfhack.internal.auto_needs_hb_gen or 0
end

-- The pass runs for either half on its own: `enable fort/auto-needs` lends labors, marking a
-- [Public Library] staffs it, and neither switches the other one on behind your back.
local function library_marked() return load_state().library_id >= 0 end
local function service_wanted() return isEnabled() or library_marked() end

-- ---- NOTHING CREATIVE -> A STATUE -------------------------------------------
--
-- "Has been unable to be creative lately" is answered by MAKING something, and a statue is
-- the cheapest thing in the fort that counts: one boulder, one mason's workshop, no chain of
-- industries behind it. The job is handed to the dwarf directly (a worker reference on the
-- job), the way `fort/idle-smiths` hands out forge work, so it does not wait on labors or on
-- whoever happens to be nearest.
--
-- THE STONE: OBSIDIAN FIRST, then any NON-ECONOMIC stone. Obsidian is worth nothing to
-- anything else and looks the part; after that, a stone with no economic use -- no ore, no
-- thread metal, nothing on its `economic_uses` list -- so making art never eats the flux,
-- the gypsum or the ores the fort is keeping for something.
--
-- AND ONLY IF IT DOES NOT CHANGE WHAT A MOOD WOULD CLAIM. A statue trains MASONRY, which is
-- a moodable skill, and a strange mood takes the dwarf's highest moodable skill -- so
-- handing an armorer a statue can quietly turn their next artifact from a suit of armour
-- into a piece of furniture. So it is offered only when masonry ALREADY is their highest
-- moodable skill (nothing can change), or sits at least a full level below it (one statue
-- cannot close a level). A tie at the top counts as unsafe.
local CREATIVE_NEED = df.need_type.BeCreative
local STATUE_SKILL = df.job_skill.MASONRY

-- the skills a strange mood can claim -- the same set `fort/help-mood` maps to workshops
local MOODABLE = {
    df.job_skill.MASONRY, df.job_skill.CARPENTRY, df.job_skill.WEAVING,
    df.job_skill.CLOTHESMAKING, df.job_skill.LEATHERWORK, df.job_skill.BOWYER,
    df.job_skill.MECHANICS, df.job_skill.SIEGECRAFT, df.job_skill.CUTGEM,
    df.job_skill.ENCRUSTGEM, df.job_skill.WOODCRAFT, df.job_skill.STONECRAFT,
    df.job_skill.BONECARVE, df.job_skill.EXTRACT_STRAND, df.job_skill.METALCRAFT,
    df.job_skill.FORGE_WEAPON, df.job_skill.FORGE_ARMOR, df.job_skill.FORGE_FURNITURE,
    df.job_skill.GLASSMAKER,
}

local function skill_level(unit, skill)
    local ok, v = pcall(dfhack.units.getNominalSkill, unit, skill, true)
    return (ok and v) or 0
end

-- would a statue change the skill a mood would claim from this dwarf?
local function statue_is_safe(unit)
    local mine = skill_level(unit, STATUE_SKILL)
    local best, best_count = -1, 0
    for _, skill in ipairs(MOODABLE) do
        local lvl = skill_level(unit, skill)
        if lvl > best then best, best_count = lvl, 1
        elseif lvl == best then best_count = best_count + 1 end
    end
    if mine == best and best_count == 1 then return true end   -- already theirs alone
    return mine < best                                          -- a level of room to spare
end

-- a stone that is nobody's raw material: no ore, no thread metal, no economic use
local function plain_stone(mat_index)
    local ir = df.global.world.raws.inorganics.all[mat_index]
    if not ir then return false end
    local ok, stone = pcall(function() return ir.material.flags.IS_STONE end)
    if not ok or not stone then return false end
    if ir.flags.SOIL then return false end
    return #ir.economic_uses == 0 and #ir.metal_ore.mat_index == 0
        and #ir.thread_metal.mat_index == 0
end

-- the stone to carve: obsidian if the fort has any, else the most plentiful plain stone
local function statue_stone()
    local counts, obsidian = {}, nil
    for _, it in ipairs(df.global.world.items.other.BOULDER) do
        if it.mat_type == 0 and not it.flags.forbid and not it.flags.artifact
            and not it.flags.dump and not it.flags.in_job and plain_stone(it.mat_index)
        then
            counts[it.mat_index] = (counts[it.mat_index] or 0) + 1
            local ir = df.global.world.raws.inorganics.all[it.mat_index]
            if ir and ir.id == 'OBSIDIAN' then obsidian = it.mat_index end
        end
    end
    if obsidian then return obsidian end
    local best, best_n = nil, 0
    for idx, n in pairs(counts) do
        if n > best_n then best, best_n = idx, n end
    end
    return best
end

-- a finished mason's workshop with nothing queued and no master assigned
local function free_masons_shop()
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Workshop
            and b:getSubtype() == df.workshop_type.Masons
            and b:getBuildStage() >= b:getMaxBuildStage()
            and #b.jobs == 0
            and (not b.profile or b.profile.max_general_orders > 0)
        then
            return b
        end
    end
end

local function statue_job(unit, shop, mat_index)
    local job = dfhack.job.createLinked()
    job.job_type = df.job_type.ConstructStatue
    job.mat_type = 0
    job.mat_index = mat_index

    local jitem = df.job_item:new()
    jitem.item_type = df.item_type.BOULDER
    jitem.mat_type = 0
    jitem.mat_index = mat_index
    jitem.quantity = 1
    jitem.vector_id = df.job_item_vector_id.BOULDER
    job.job_items.elements:insert('#', jitem)

    dfhack.job.assignToWorkshop(job, shop)
    return dfhack.job.addWorker(job, unit)
end

-- One creative pass: the neediest dwarf a statue is safe for, per free workshop.
function scan_creative(dry)
    local made, skipped = {}, 0
    local mat = statue_stone()
    if not mat then return made, skipped, 'no obsidian or non-economic stone' end

    local want = {}
    for _, unit in ipairs(citizens()) do
        local focus = need_focus(unit, CREATIVE_NEED)
        if past_the_bar(unit, focus) and dfhack.units.isJobAvailable(unit) then
            if statue_is_safe(unit) then
                want[#want + 1] = {unit = unit, focus = focus, stress = stress_of(unit)}
            else
                skipped = skipped + 1
            end
        end
    end
    -- angriest first, then the deepest need: the same order fort/idle-smiths serves
    table.sort(want, function(a, b)
        if a.stress ~= b.stress then return a.stress > b.stress end
        if a.focus ~= b.focus then return a.focus < b.focus end
        return a.unit.id < b.unit.id
    end)

    for _, cand in ipairs(want) do
        local shop = free_masons_shop()
        if not shop then break end
        if dry then
            made[#made + 1] = cand.unit
        elseif statue_job(cand.unit, shop, mat) then
            made[#made + 1] = cand.unit
        end
    end
    return made, skipped, nil
end

local function one_pass()
    if isEnabled() then pcall(scan) end
    if isEnabled() then pcall(scan_creative) end
    if library_marked() then pcall(scan_library) end
end

local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not service_wanted() or my ~= hb_gen() then return end
        one_pass()
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

local function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if service_wanted() then start_heartbeat() else stop_heartbeat() end
    if v then pcall(scan) end
end

-- mark (or un-mark) the library this tool staffs; the pass starts itself on the way in
function set_library(loc_id)
    local s = load_state()
    if s.library_id == loc_id then
        clear_library()
        s.library_id = -1
        save_state()
        if not service_wanted() then stop_heartbeat() end
    else
        if s.library_id >= 0 then clear_library() end
        s.library_id = loc_id
        save_state()
        start_heartbeat()
        pcall(scan_library)
    end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and service_wanted() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- the [Public Library] button ---------------------------------------------

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- the library behind the zone whose panel is open, or nil
local function cur_library()
    local civzone = df.global.game.main_interface.civzone
    return library_of_zone(civzone and civzone.cur_bld)
end

PublicLibraryOverlay = defclass(PublicLibraryOverlay, overlay.OverlayWidget)
PublicLibraryOverlay.ATTRS{
    desc = 'Adds a public-library toggle to the zone screen of a library.',
    default_pos = {x = 7, y = 14},
    default_enabled = true,
    viewscreens = 'dwarfmode/Zone/Some/MeetingHall',
    frame = {w = 16, h = 1},
    version = 1,
}

function PublicLibraryOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 16},    -- '[Public Library]'
            label = '[Public Library]',
            -- a meeting hall that is not a library gets no button at all
            visible = function() return cur_library() ~= nil end,
            text_pen = function()
                local lib = cur_library()
                return (lib and load_state().library_id == lib.id) and COLOR_GREEN or COLOR_WHITE
            end,
            on_activate = function()
                local lib = cur_library()
                if lib then set_library(lib.id) end
            end,
        },
    }
end

OVERLAY_WIDGETS = {library = PublicLibraryOverlay}

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
local posted, released, reading, lib = scan_library(dry or not once)
local function name(e)
    return e.unit and dfhack.units.getReadableName(e.unit) or ('unit #' .. tostring(e.id))
end

if not once then
    print('auto-needs: ' .. (isEnabled() and 'enabled' or 'disabled')
        .. ' -- an unmet WANDER gets the FISHING labor. Every bar here is '
        .. FOCUS_UNMET .. ', handed back at ' .. FOCUS_MET .. '.')
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

-- ---- the library half -------------------------------------------------------

print()
if not lib then
    print('No public library marked. Open a zone belonging to a library and press'
        .. ' [Public Library] on its panel.')
else
    print(('Public library: %s -- everybody past the bar gets a post.'):format(
        dfhack.translation.translateName(lib.name, true)))
    if #posted > 0 then
        print(('%s%d posted as scholar%s:'):format(tag, #posted, #posted == 1 and '' or 's'))
        for _, e in ipairs(posted) do
            print(('    %s (short %d on abstract thinking / self-examination)')
                :format(dfhack.units.getReadableName(e.unit), e.shortfall))
        end
    end
    if #released > 0 then
        print(('%s%d taken off again, having read their fill:'):format(tag, #released))
        for _, e in ipairs(released) do print('    ' .. name(e)) end
    end
    if reading > 0 then print(('  %d still reading there.'):format(reading)) end
    if #posted == 0 and #released == 0 and reading == 0 then
        print('  nobody is short enough on abstract thinking or self-examination to post.')
    end
end
