-- Force designated High Adventure civilizations hostile to the adventurer.
--@module = true
--[[
A config-driven adventure-mode overlay: each turn it makes nearby members of a
"hostile faction" attack the adventurer -- ONLY the adventurer, not their own
people -- unless the adventurer belongs to that faction (or, for good civs, unless
the adventurer isn't evil). It works by putting the unit into a Conflict activity
opposing the adventurer (creating one if needed) -- the same state the game builds
when you attack someone -- so it targets the player specifically rather than using
a blunt [CRAZED] that would also make them gut their own immigrants.

It also stops them yielding (clears flags3.adv_yield each turn) UNLESS the
adventurer is a skilled enough Pacifier (Pacify skill >= the target race's
threshold), in which case a surrender is respected. Optionally sets [NOFEAR] on a
faction's castes (session-only) so they never break.

Ships in the HA_adventure_hostility mod; auto-discovered as an overlay on world
load. Add a faction by editing RULES / PACIFY_THRESHOLD -- the engine is identical
for all of them, and races absent from the loaded world are ignored.
]]

local overlay = require('plugins.overlay')
local utils = require('utils')

-- ===========================================================================
-- CONFIG
-- ===========================================================================

-- the evil bloc trades/allies with each other (README trade table)
local BLOC = {HA_DROW=true, HA_DARK_DWARF=true, HA_SUCCUBUS=true, GOBLIN=true}
-- races treated as "evil" for the good-civ rule
local EVIL = {HA_ORC=true, HA_ILLITHID=true, HA_DROW=true, HA_DARK_DWARF=true,
              HA_SUCCUBUS=true, GOBLIN=true}

-- Pacify skill a yielded unit's slayer needs for the surrender to STICK, per race.
local PACIFY_THRESHOLD = {
    GOBLIN        = 1,
    HA_ORC        = 3,
    HA_DROW       = 6,
    HA_SUCCUBUS   = 6,
    HA_DARK_DWARF = 6,   -- not user-specified; matches the other CAVE_DETAILED evil civs
    HA_ILLITHID   = 12,
}
local DEFAULT_PACIFY = 3

-- one entry per hostile faction. friendly(adv_race_id) => true when the
-- adventurer is NOT a target of this faction.
local RULES = {
    -- loners: hostile to everyone but their own kind
    {name = 'orcs',      races = {'HA_ORC'},      nofear = true,
     friendly = function(adv) return adv == 'HA_ORC' end},
    {name = 'illithids', races = {'HA_ILLITHID'}, nofear = true,
     friendly = function(adv) return adv == 'HA_ILLITHID' end},
    -- evil bloc: hostile to any adventurer NOT in the bloc
    {name = 'evil_bloc', races = {'HA_DROW', 'HA_DARK_DWARF', 'HA_SUCCUBUS', 'GOBLIN'}, nofear = true,
     friendly = function(adv) return BLOC[adv] == true end},
    -- good civilizations: hostile to EVIL adventurers only (and they CAN yield/flee)
    {name = 'good_civs', races = {'DWARF', 'HUMAN', 'ELF'}, nofear = false,
     friendly = function(adv) return not EVIL[adv] end},
}

local RANGE = 20   -- manhattan distance (z weighted x4) at which a unit is engaged

-- ===========================================================================
-- helpers
-- ===========================================================================

local function creature_id(race)
    local r = df.global.world.raws.creatures.all[race]
    return r and tostring(r.creature_id) or nil
end

local function race_set(races)
    local s = {}
    for _, id in ipairs(races) do s[id] = true end
    return s
end

local function dist(u, adv)
    return math.abs(u.pos.x - adv.pos.x) + math.abs(u.pos.y - adv.pos.y)
        + math.abs(u.pos.z - adv.pos.z) * 4
end

local function adv_conflict(adv)
    for _, aid in ipairs(adv.activities) do
        local act = df.activity_entry.find(aid)
        if act and act.type == df.activity_entry_type.Conflict and #act.events > 0 then
            local ev = act.events[0]
            for si = 0, #ev.sides - 1 do
                for _, uid in ipairs(ev.sides[si].unit_ids) do
                    if uid == adv.id then return act, ev, si end
                end
            end
        end
    end
end

local function in_event(ev, uid)
    for si = 0, #ev.sides - 1 do
        for _, id in ipairs(ev.sides[si].unit_ids) do if id == uid then return true end end
    end
    return false
end

-- create a fresh Conflict activity: adv on side 0, u on side 1 (validated live)
local function create_conflict(adv, u)
    local acts = df.global.world.activities.all
    local newid = 1
    for _, a in ipairs(acts) do if a.id >= newid then newid = a.id + 1 end end
    local act = df.activity_entry:new()
    act.id = newid
    act.type = df.activity_entry_type.Conflict
    act.next_event_id = 1
    act.army_controller = -1
    local ev = df.activity_event_conflictst:new()
    ev.event_id = 0
    ev.activity_id = newid
    ev.parent_event_id = -1
    ev.next_side_local_id = 2
    ev.eventcol = -1
    ev.sides:insert('#', df.conflict_sidest:new())
    ev.sides:insert('#', df.conflict_sidest:new())
    local function fill(side, sid, unit, enemy_sid)
        side.id = sid
        utils.insert_sorted(side.unit_ids, unit.id)
        if unit.hist_figure_id >= 0 then utils.insert_sorted(side.histfig_ids, unit.hist_figure_id) end
        side.enemies:insert('#', df.conflict_statest:new())
        side.enemies[0].id = enemy_sid
        side.enemies[0].conflict_level = 5   -- 5 = fighting
        side.peak_strength = 100
        side.current_strength = 100
    end
    fill(ev.sides[0], 0, adv, 1)
    fill(ev.sides[1], 1, u, 0)
    act.events:insert('#', ev)
    acts:insert('#', act)
    adv.activities:insert('#', newid)
    u.activities:insert('#', newid)
end

local function make_hostile(u, adv)
    local act, ev, advside = adv_conflict(adv)
    if ev then
        if in_event(ev, u.id) then return end
        local uside = (advside == 0) and 1 or 0
        utils.insert_sorted(ev.sides[uside].unit_ids, u.id)
        if u.hist_figure_id >= 0 then utils.insert_sorted(ev.sides[uside].histfig_ids, u.hist_figure_id) end
        u.activities:insert('#', act.id)
    else
        create_conflict(adv, u)
    end
end

local nofear_done = {}
local function set_nofear(race_id_set)
    for _, cr in ipairs(df.global.world.raws.creatures.all) do
        local cid = tostring(cr.creature_id)
        if race_id_set[cid] and not nofear_done[cid] then
            for c = 0, #cr.caste - 1 do cr.caste[c].flags.NOFEAR = true end
            nofear_done[cid] = true
        end
    end
end

-- ===========================================================================
-- per-turn engine
-- ===========================================================================

local function process()
    if not dfhack.world.isAdventureMode() then return end
    local adv = dfhack.world.getAdventurer()
    if not adv then return end
    local adv_race = creature_id(adv.race)
    local pacify = dfhack.units.getNominalSkill(adv, df.job_skill.PACIFY, true) or 0

    local active = {}
    for _, rule in ipairs(RULES) do
        if not rule.friendly(adv_race) then
            active[#active + 1] = race_set(rule.races)
            if rule.nofear then set_nofear(race_set(rule.races)) end
        end
    end
    if #active == 0 then return end

    for _, u in ipairs(df.global.world.units.active) do
        if u.id ~= adv.id and dfhack.units.isAlive(u) and dist(u, adv) <= RANGE then
            local cid = creature_id(u.race)
            local targeted = false
            for _, races in ipairs(active) do if races[cid] then targeted = true break end end
            if targeted then
                make_hostile(u, adv)
                if u.flags3.adv_yield then
                    local threshold = PACIFY_THRESHOLD[cid] or DEFAULT_PACIFY
                    -- a skilled enough Pacifier gets to keep them surrendered
                    if pacify < threshold then u.flags3.adv_yield = false end
                end
            end
        end
    end
end

-- ===========================================================================
-- overlay (drives process() each adventure turn; edge-triggered on movement)
-- ===========================================================================

local last_key = nil

HostilityOverlay = defclass(HostilityOverlay, overlay.OverlayWidget)
HostilityOverlay.ATTRS{
    desc = 'Forces designated High Adventure civilizations hostile to the adventurer.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function HostilityOverlay:overlay_onupdate()
    local ok, adv = pcall(dfhack.world.getAdventurer)
    if not (ok and adv) then return end
    local key = ('%d,%d,%d'):format(adv.pos.x, adv.pos.y, adv.pos.z)
    if key == last_key then return end
    last_key = key
    pcall(process)
end

OVERLAY_WIDGETS = {hostility = HostilityOverlay}

if dfhack_flags.module then
    return
end

-- manual run: register + apply once
require('plugins.overlay').rescan()
pcall(process)
print('adventure-hostility: active (overlay HA_adventure_hostility... / adventure-hostility.hostility).')
