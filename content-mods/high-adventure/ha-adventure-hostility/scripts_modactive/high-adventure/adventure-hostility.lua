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

GOOD races split into two: the weaker "good civs" (HUMAN, ELF) attack any EVIL
adventurer but can surrender/flee, while "militant good" (HA_HIGH_ELF, DWARF) attack
the same EVIL set yet NEVER break (NOFEAR) and NEVER yield (NO_YIELD threshold). The
EVIL target set is orc, kobold, goblin, succubus, dark dwarf, drow and mind flayer.

KOBOLDS are a special case (see pacify_threshold): the kobold civ AND its dragon
overlords (the HA_KOBOLD ANCIENT_DRAGON caste, the same creature) are hostile to any
non-kobold. A plain kobold's surrender sticks at Pacify 1, but rises to 12 while one
of their ancient-dragon overlords is on screen; a dragon overlord itself always needs
Pacify 12. The standalone HA_ANCIENT_DRAGON MEGABEAST is a different creature and is
untouched by this.

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
-- races treated as "evil" -- the target set for the good-civ and militant-good rules
local EVIL = {HA_ORC=true, HA_ILLITHID=true, HA_DROW=true, HA_DARK_DWARF=true,
              HA_SUCCUBUS=true, GOBLIN=true, HA_KOBOLD=true}

-- Pacify skill a yielded unit's slayer needs for the surrender to STICK, per race. Unreachable
-- values (NO_YIELD) mark races that fight to the death and never surrender.
local NO_YIELD = 999
local PACIFY_THRESHOLD = {
    GOBLIN        = 1,
    HA_ORC        = 3,
    HA_DROW       = 6,
    HA_SUCCUBUS   = 6,
    HA_DARK_DWARF = 6,   -- not user-specified; matches the other CAVE_DETAILED evil civs
    HA_ILLITHID   = 12,
    -- militant good (high elves + dwarves) never yield, unlike the weaker HUMAN/ELF good civs
    HA_HIGH_ELF   = NO_YIELD,
    DWARF         = NO_YIELD,
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
    {name = 'good_civs', races = {'HUMAN', 'ELF'}, nofear = false,
     friendly = function(adv) return not EVIL[adv] end},
    -- militant good (high elves + dwarves): same target set as the good civs -- hostile to any EVIL
    -- adventurer -- but they NEVER break (NOFEAR) and NEVER yield (NO_YIELD threshold), unlike the
    -- weaker HUMAN/ELF good civs who can surrender.
    {name = 'militant_good', races = {'HA_HIGH_ELF', 'DWARF'}, nofear = true,
     friendly = function(adv) return not EVIL[adv] end},
    -- kobold civ: hostile to any adventurer who is NOT a kobold. Their dragon overlords are the
    -- HA_KOBOLD ANCIENT_DRAGON caste -- the SAME creature -- so this one rule covers kobolds AND
    -- their dragons. The standalone HA_ANCIENT_DRAGON MEGABEAST is a different creature and is left
    -- out entirely. Pacify thresholds are special-cased (see pacify_threshold): a plain kobold yields
    -- at Pacify 1, but 12 while a dragon overlord is on screen; a dragon overlord always needs 12.
    {name = 'kobolds', races = {'HA_KOBOLD'}, nofear = false,
     friendly = function(adv) return adv == 'HA_KOBOLD' end},
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

-- a kobold-civ dragon OVERLORD: the HA_KOBOLD ANCIENT_DRAGON caste (NOT the HA_ANCIENT_DRAGON
-- MEGABEAST, which is a separate creature). Only ever called on HA_KOBOLD units.
local function is_dragon_caste(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    return caste ~= nil and tostring(caste.caste_id) == 'ANCIENT_DRAGON'
end

-- is a unit inside the current on-screen viewport? (same map-tile-size math the click tools use:
-- S = viewport_zoom_factor/4 px per tile; visible tiles = screen pixels / S)
local function on_screen(u)
    if u.pos.z ~= df.global.window_z then return false end
    local gps = df.global.gps
    local S = math.max(1, gps.viewport_zoom_factor // 4)
    local vw = math.max(4, (gps.dimx * gps.tile_pixel_x) // S)
    local vh = math.max(4, (gps.dimy * gps.tile_pixel_y) // S)
    return u.pos.x >= df.global.window_x and u.pos.x < df.global.window_x + vw
        and u.pos.y >= df.global.window_y and u.pos.y < df.global.window_y + vh
end

-- Pacify skill a yielded unit's slayer needs for the surrender to STICK. Kobolds are special-cased:
-- a dragon overlord always needs 12; a plain kobold needs 1, but 12 while a dragon overlord is on
-- screen (emboldened by their overlord). Every other race uses the flat PACIFY_THRESHOLD table.
local function pacify_threshold(u, cid, dragon_on_screen)
    if cid == 'HA_KOBOLD' then
        if is_dragon_caste(u) then return 12 end
        return dragon_on_screen and 12 or 1
    end
    return PACIFY_THRESHOLD[cid] or DEFAULT_PACIFY
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
    local kobolds_active = false
    for _, rule in ipairs(RULES) do
        if not rule.friendly(adv_race) then
            local rs = race_set(rule.races)
            active[#active + 1] = rs
            if rs['HA_KOBOLD'] then kobolds_active = true end
            if rule.nofear then set_nofear(rs) end
        end
    end
    if #active == 0 then return end

    -- kobolds are harder to pacify while one of their ANCIENT_DRAGON overlords is on screen: note it
    -- up front (a pre-pass, since a plain kobold may be visited before the dragon in the sweep below).
    local dragon_on_screen = false
    if kobolds_active then
        for _, u in ipairs(df.global.world.units.active) do
            if u.id ~= adv.id and dfhack.units.isAlive(u)
                and creature_id(u.race) == 'HA_KOBOLD' and is_dragon_caste(u) and on_screen(u) then
                dragon_on_screen = true
                break
            end
        end
    end

    for _, u in ipairs(df.global.world.units.active) do
        if u.id ~= adv.id and dfhack.units.isAlive(u) and dist(u, adv) <= RANGE then
            local cid = creature_id(u.race)
            local targeted = false
            for _, races in ipairs(active) do if races[cid] then targeted = true break end end
            if targeted then
                -- guard per-unit so one odd unit can't abort the whole sweep
                pcall(function()
                    make_hostile(u, adv)
                    if u.flags3.adv_yield then
                        local threshold = pacify_threshold(u, cid, dragon_on_screen)
                        -- a skilled enough Pacifier gets to keep them surrendered
                        if pacify < threshold then u.flags3.adv_yield = false end
                    end
                end)
            end
        end
    end
end

-- ===========================================================================
-- overlay (drives process() every adventure turn)
-- ===========================================================================
-- overlay_onupdate keeps firing while the game is paused and self-heals after a
-- map reload / fast travel, so it is the right driver for adventure mode. We run
-- process() on a short real-time throttle -- NOT gated on the adventurer moving
-- -- so that standing still in a fight, or arriving from fast travel, keeps
-- nearby enemies re-engaged instead of letting them de-escalate into idle. The
-- whole body is wrapped in pcall: a single bad frame (transient nil during a
-- map reload, an odd unit, etc.) can never bubble an error up to the overlay
-- manager, which is exactly what would leave the widget dead until a restart.

HostilityOverlay = defclass(HostilityOverlay, overlay.OverlayWidget)
HostilityOverlay.ATTRS{
    desc = 'Forces designated High Adventure civilizations hostile to the adventurer.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 5,
    frame = {w = 1, h = 1},
}

function HostilityOverlay:overlay_onupdate()
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
