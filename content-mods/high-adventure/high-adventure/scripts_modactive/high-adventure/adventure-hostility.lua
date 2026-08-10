-- Force designated High Adventure civilizations hostile to the adventurer.
--@module = true
--[[
A config-driven adventure-mode overlay: each turn it makes nearby members of a
"hostile faction" attack the adventurer -- ONLY the adventurer, not their own
people -- unless the adventurer belongs to that faction (or, for good civs, unless
the adventurer isn't evil). Units of the adventurer's OWN civilization are always
left alone regardless of race: a dwarf snatched and raised in a drow civ is one of
theirs (only the dragon challenge ignores this -- rival dragons duel even in-civ).

DOCTRINE IS TERRITORIAL, TEMPERAMENT IS RACIAL. Standing inside a settlement, a unit
follows the ETHICS OF THE TOWN rather than of its own race: everyone in an orc town
behaves like an orc, so a kobold farmer or an elf living among orcs comes at you with
them, while an orc in a human town is used to being around people and leaves you be.
Out in the wilderness -- and in a site nobody owns, like a ruin or a lair -- there is
no local law and every unit falls back on its own race's rule, so travel stays
dangerous. Same fallback if the owning race has no rule of its own: an unruled town is
just wilderness with buildings.

What the town does NOT decide is what a creature IS. Whether it breaks (NOFEAR) and how
hard it is to talk down (Pacify) stay keyed to its actual race -- a kobold conscripted
into orc doctrine is still a kobold. NOFEAR could not be territorial even if we wanted
it to be: it is a caste-level RAW flag, written per race for the whole world at once.

Two things override the local doctrine. INVADERS keep their own -- a besieging army
inside someone's walls is not adopting the ethics of the people it came to kill -- and
members of the ADVENTURER'S OWN CIVILIZATION are never made hostile at all, so your own
kin do not turn on you in their own streets. Only PEOPLE are subject to any of this:
the doctrine is looked up from the ground, not from the unit, so livestock and pets
would otherwise be swept in with their owners. It works by putting the unit into a Conflict activity
opposing the adventurer (creating one if needed) -- the same state the game builds
when you attack someone -- so it targets the player specifically rather than using
a blunt [CRAZED] that would also make them gut their own immigrants.

PRISONERS ARE EXEMPT, OUTRIGHT. A CHAINED or CAGED unit is never touched by any rule in
this file, in any role -- not targeted, not counted as a dragon overlord or challenger.
Local doctrine reads off the ground, so without this a rescue target of a friendly race
held captive at a hostile site would inherit its captor's doctrine and get thrown into a
Conflict against the very adventurer come to free them.

PACIFY WORKS TWO WAYS, and the first one matters most: an adventurer whose Pacify
skill meets the target race's threshold AND who has NOT DRAWN A WEAPON is never made
hostile at all. You do not have to fight anyone first -- walk in sheathed and a good
enough talker simply is not attacked. Draw steel and the exemption lapses on that same
turn. Second, for anyone who HAS yielded, the same threshold decides whether the
surrender sticks: below it, flags3.adv_yield is cleared each turn and the fight goes
on. Optionally sets [NOFEAR] on a faction's castes (session-only) so they never break;
a faction may instead take NOFEAR conditionally (see the kobolds below), in which case
the flag is written and withdrawn again as the condition changes.

GOOD races split into two: the weaker "good civs" (HUMAN, ELF) attack any EVIL
adventurer but can surrender/flee, while "militant good" (HA_HIGH_ELF, DWARF) attack
the same EVIL set and NEVER break (NOFEAR) -- but, like everyone else, they leave a
sheathed Pacify-6 adventurer alone. The EVIL target set is orc, kobold, goblin,
succubus, dark dwarf, drow and mind flayer.

KOBOLDS are a special case, and everything about them keys off ONE signal: whether one
of their ancient-dragon overlords (a HA_KOBOLD caste carrying CREATURE_CLASS
HA_DRAGON_RULER -- the same creature) is on screen. The kobold civ and its dragons are
hostile to any non-kobold, but a kobold alone is a coward: the race is [BENIGN] in the
raws, so it flees anything unfriendly and only fights when cornered. With an overlord
watching it is emboldened -- NOFEAR goes on for the whole race while a dragon is on
screen and comes back off the moment none is, so kobolds stand and fight under their
dragon and break without one. The Pacify bar moves with the same signal: a plain
kobold's surrender sticks at Pacify 1, rising to 12 while an overlord is on screen; a
dragon overlord itself always needs Pacify 12.

DRAGON CHALLENGE: two ancient dragons meeting is read as a challenge. When the
ADVENTURER is an ancient dragon -- either a HA_KOBOLD dragon caste or the standalone
HA_ANCIENT_DRAGON megabeast -- every other ancient dragon turns on them,
and so do the kobolds standing with that rival dragon, even though the kobold civ
would otherwise greet a dragon as an overlord. Kobolds nowhere near a rival dragon
still treat a dragon adventurer as one of their own. A challenger that has already
yielded is left alone if the adventurer's Pacify is 12 or better: that surrender
stands and the challenge is not reopened.

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

-- Pacify skill that calls a race off, per race. It does two jobs: an adventurer who meets it
-- and has NOT drawn a weapon is never attacked in the first place (see weapon_drawn), and a
-- unit that HAS yielded stays yielded rather than being forced back into the fight.
local PACIFY_THRESHOLD = {
    GOBLIN        = 1,
    HA_ORC        = 3,
    HA_DROW       = 6,
    HA_SUCCUBUS   = 6,
    HA_DARK_DWARF = 6,   -- not user-specified; matches the other CAVE_DETAILED evil civs
    HA_ILLITHID   = 12,
    -- militant good (high elves + dwarves) still never BREAK (nofear), but a sheathed
    -- Pacifier at 6 can walk among them unmolested like any other faction
    HA_HIGH_ELF   = 6,
    DWARF         = 6,
}
local DEFAULT_PACIFY = 3

-- `nofear` on a rule takes three values: true (always -- the faction never breaks),
-- false (never -- they flee like anyone else), or NOFEAR_WITH_DRAGON, which applies it
-- only while one of the kobolds' ancient-dragon overlords is on screen and withdraws it
-- again as soon as none is.
local NOFEAR_WITH_DRAGON = 'dragon'

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
    -- adventurer -- and they NEVER break (NOFEAR), unlike the weaker HUMAN/ELF good civs who
    -- can flee. A sheathed Pacify-6 adventurer is still left alone, same as any other faction.
    {name = 'militant_good', races = {'HA_HIGH_ELF', 'DWARF'}, nofear = true,
     friendly = function(adv) return not EVIL[adv] end},
    -- kobold civ: hostile to any adventurer who is NOT a kobold. Their dragon overlords are
    -- HA_KOBOLD castes -- the SAME creature -- so this one rule covers kobolds AND their dragons.
    -- The standalone HA_ANCIENT_DRAGON MEGABEAST is a different creature and is left out entirely.
    -- NOFEAR is conditional: kobolds are [BENIGN] cowards on their own and only hold the line while
    -- an overlord is on screen. Pacify thresholds move with the same signal (see pacify_threshold):
    -- a plain kobold yields at Pacify 1, but 12 with a dragon watching; a dragon always needs 12.
    {name = 'kobolds', races = {'HA_KOBOLD'}, nofear = NOFEAR_WITH_DRAGON,
     friendly = function(adv) return adv == 'HA_KOBOLD' end},
}

local RANGE = 20   -- manhattan distance (z weighted x4) at which a unit is engaged

-- Dragon challenge (see the header): how close a kobold has to stand to a rival ancient
-- dragon to take its side against a dragon adventurer, and the Pacify that calls the
-- whole challenge off once a challenger has yielded.
local DRAGON_CHALLENGE_RANGE = 20
local DRAGON_PACIFY = 12

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

-- ---- "whose law applies where I am standing?" ---------------------------------
-- Inside a settlement the LOCAL doctrine replaces each unit's racial one, so what we
-- need from the ground is a single race id to look rules up by.
-- Same world-tile arithmetic adv/fear-no-goblin uses to find the site underfoot.

local function player_world_tile(adv)
    if not dfhack.isMapLoaded() then return end
    local map = df.global.world.map
    return (map.region_x + adv.pos.x // 48) // 16,
           (map.region_y + adv.pos.y // 48) // 16
end

-- The race whose doctrine governs the ground the adventurer is standing on, or nil in
-- the wilderness / on ground nobody owns.
--
-- `cur_owner_id` (the site government) is asked FIRST and `civ_id` (the founding civ)
-- only as a fallback, because on a CONQUERED site the two disagree and it is the
-- current holder who writes the law -- 27 of the 251 owned sites in the test world have
-- a current owner of a different race from their founder, so this is not a corner case.
--
-- Returning nil means "no local law here": an unowned site (ruin, lair, bandit camp)
-- reads exactly like open wilderness, and every unit falls back on its racial rule.
local function site_doctrine_race(adv)
    local wx, wy = player_world_tile(adv)
    if not wx then return end
    for _, s in ipairs(df.global.world.world_data.sites) do
        local x0, y0 = s.global_min_x // 16, s.global_min_y // 16
        local x1, y1 = (s.global_max_x - 1) // 16, (s.global_max_y - 1) // 16
        if wx >= x0 and wx <= x1 and wy >= y0 and wy <= y1 then
            for _, civ_id in ipairs{s.cur_owner_id, s.civ_id} do
                local e = civ_id >= 0 and df.historical_entity.find(civ_id)
                if e and e.race >= 0 then return creature_id(e.race) end
            end
            return
        end
    end
end

-- A siege is not a social visit: an army that came to sack the place does not pick up
-- the ethics of the people inside it, so invaders keep their own racial doctrine.
local function is_invader(u)
    return u.flags1.active_invader or u.flags1.invader_origin or u.flags1.marauder
end

-- Local doctrine is read off the GROUND, not off the unit, so the race lists stop
-- doubling as a "is this even a person" filter the way they did when a rule only ever
-- matched its own races. Without this gate every horse, pet and pack animal belonging
-- to a hostile town would be conscripted into its war -- the site government owns the
-- livestock too (measured live: the horse beside the adventurer carried the site
-- government's own civ id).
local function is_person(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if not caste then return false end
    return caste.flags.CAN_SPEAK or caste.flags.CAN_LEARN
end

-- CHAINED/CAGED units are prisoners, not combatants -- the classic case being an
-- adventure-mode rescue target held at a hostile site. Local doctrine reads off the
-- GROUND (see site_doctrine_race above), so without this guard a captive of a friendly
-- race would inherit their captor's hostile doctrine and get dragged into a Conflict
-- against the very adventurer who came to free them. Exempted outright, everywhere in
-- this engine -- never targeted, never counted as a dragon overlord/challenger.
local function is_captive(u)
    return u.flags1.chained or u.flags1.caged
end

-- a kobold-civ dragon OVERLORD (NOT the HA_ANCIENT_DRAGON MEGABEAST, which is a separate
-- creature). Only ever called on HA_KOBOLD units.
--
-- Matched on CREATURE_CLASS:HA_DRAGON_RULER -- the very token the raws use to gate the civ's
-- Dread Wyrm throne -- rather than on a caste id, because the caste ids move: ha-kobolds 0.17
-- replaced the single ANCIENT_DRAGON caste with six (DRAGON_H1_SPIKE ... DRAGON_H3_CLUB) and
-- the old exact-name test silently stopped matching anything, which killed the dragon rules
-- outright. The legacy name is still accepted so a world baked before 0.17 keeps working.
local DRAGON_RULER_CLASS = 'HA_DRAGON_RULER'
local function is_dragon_caste(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if not caste then return false end
    for _, cc in ipairs(caste.creature_class) do
        if tostring(cc.value) == DRAGON_RULER_CLASS then return true end
    end
    return tostring(caste.caste_id) == 'ANCIENT_DRAGON'
end

-- an ancient dragon of EITHER kind: one of the kobold civ's dragon castes or the
-- standalone HA_ANCIENT_DRAGON megabeast. Used only by the dragon-challenge rule,
-- which does not care which of the two a dragon is.
local function is_ancient_dragon(u, cid)
    cid = cid or creature_id(u.race)
    if cid == 'HA_ANCIENT_DRAGON' then return true end
    return cid == 'HA_KOBOLD' and is_dragon_caste(u)
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

-- Is the adventurer holding a weapon READY? A weapon stowed in a pack is not drawn (it rides
-- as Hauled, or as contained cargo that never appears in `inventory` at all), and a shield
-- occupies the same Weapon role without being a weapon -- so the item type is checked too.
-- Walking in sheathed is what lets a skilled Pacifier pass unmolested.
local function weapon_drawn(u)
    for _, inv in ipairs(u.inventory) do
        if inv.mode == df.inv_item_role_type.Weapon and inv.item
            and inv.item:getType() == df.item_type.WEAPON then
            return true
        end
    end
    return false
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

-- Force two sides of an event to full combat. DF decays conflict_level over
-- time (a de-escalated conflict reads level 0 = no aggression), and units
-- added to an existing event inherit whatever stale level it has -- both left
-- everyone "in conflict" yet passive. Re-assert 5 (fighting) in BOTH
-- directions every sweep, creating the enemy entry if it is missing.
local function ensure_fighting(ev, ia, ib)
    local function bump(side, enemy_id)
        for _, e in ipairs(side.enemies) do
            if e.id == enemy_id then
                if e.conflict_level < 5 then e.conflict_level = 5 end
                return
            end
        end
        local st = df.conflict_statest:new()
        st.id = enemy_id
        st.conflict_level = 5
        side.enemies:insert('#', st)
    end
    bump(ev.sides[ia], ev.sides[ib].id)
    bump(ev.sides[ib], ev.sides[ia].id)
end

local function make_hostile(u, adv)
    local act, ev, advside = adv_conflict(adv)
    if ev then
        local uside = (advside == 0) and 1 or 0
        if not in_event(ev, u.id) then
            utils.insert_sorted(ev.sides[uside].unit_ids, u.id)
            if u.hist_figure_id >= 0 then utils.insert_sorted(ev.sides[uside].histfig_ids, u.hist_figure_id) end
            u.activities:insert('#', act.id)
        end
        ensure_fighting(ev, advside, uside)
    else
        create_conflict(adv, u)
    end
end

-- NOFEAR is a CASTE-LEVEL RAW flag, so it is written for a whole race at once and has to be
-- withdrawn the same way -- there is no per-unit version of it.
--
-- Turning it off restores what the RAWS said rather than writing false, which matters here:
-- HA_KOBOLD's ancient-dragon castes carry [NOFEAR] of their own, so clearing the flag blindly
-- when the dragons stop being visible would leave the dragons themselves permanently breakable
-- for the rest of the session. `nofear_base` snapshots each caste the first time we touch it.
--
-- `nofear_on` records the last state written per race so a sweep that changes nothing costs
-- nothing -- including for races absent from this world, which are marked resolved too so the
-- creature list is not walked again on their account.
local nofear_base = {}
local nofear_on = {}
local function set_nofear(race_id_set, on)
    local pending = false
    for cid in pairs(race_id_set) do
        if nofear_on[cid] ~= on then pending = true break end
    end
    if not pending then return end
    for _, cr in ipairs(df.global.world.raws.creatures.all) do
        local cid = tostring(cr.creature_id)
        if race_id_set[cid] and nofear_on[cid] ~= on then
            local base = nofear_base[cid]
            if not base then
                base = {}
                for c = 0, #cr.caste - 1 do base[c] = cr.caste[c].flags.NOFEAR end
                nofear_base[cid] = base
            end
            for c = 0, #cr.caste - 1 do
                cr.caste[c].flags.NOFEAR = on or base[c] or false
            end
        end
    end
    for cid in pairs(race_id_set) do nofear_on[cid] = on end
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
    local drawn = weapon_drawn(adv)

    local active = {}
    local kobolds_active = false
    -- Rules whose NOFEAR depends on a dragon being on screen. Gathered from EVERY rule, not just
    -- the ones hostile to this adventurer: "a dragon is watching, so the kobolds hold" is a fact
    -- about the kobolds, not about who they are angry at. It has to hold for the dragon challenge
    -- too, where the kobold rule itself is skipped as friendly (a dragon adventurer is one of
    -- their own) yet the rival dragon's retinue still ends up fighting. Applied after the
    -- pre-pass below, which is what actually looks for the dragon.
    local conditional_nofear = {}
    for _, rule in ipairs(RULES) do
        local rs = race_set(rule.races)
        if rule.nofear == NOFEAR_WITH_DRAGON then
            conditional_nofear[#conditional_nofear + 1] = rs
        end
        if not rule.friendly(adv_race) then
            active[#active + 1] = rs
            if rs['HA_KOBOLD'] then kobolds_active = true end
            if rule.nofear == true then set_nofear(rs, true) end
        end
    end
    -- A dragon adventurer is challenged by every other ancient dragon, so collect the rivals up
    -- front: their kobold retinue is decided by proximity to THEM, not to the adventurer, and a
    -- retainer may be swept before its dragon. This is the one rule that can fire with no faction
    -- rule active at all (the kobold civ greets a dragon as an overlord), so it is gathered before
    -- the early-out below.
    -- whose doctrine governs the ground we are standing on (nil in the wilderness and on
    -- unowned ground, where every unit falls back on its own race -- travel stays dangerous)
    local local_doctrine = site_doctrine_race(adv)

    local adv_is_dragon = is_ancient_dragon(adv, adv_race)
    local rival_dragons = {}
    if adv_is_dragon then
        for _, u in ipairs(df.global.world.units.active) do
            if u.id ~= adv.id and dfhack.units.isAlive(u) and not is_captive(u) and is_ancient_dragon(u) then
                rival_dragons[#rival_dragons + 1] = u
            end
        end
    end

    -- Is one of the kobolds' dragon overlords on screen? This single fact drives BOTH kobold
    -- rules -- whether they hold the line (NOFEAR, just below) and how hard they are to pacify
    -- -- so it is settled up front, as a pre-pass: a plain kobold may well be visited before its
    -- dragon in the main sweep. It runs ahead of the early-out below so that the conditional
    -- NOFEAR is reconciled -- switched OFF as well as ON -- on every single sweep.
    local dragon_on_screen = false
    if kobolds_active or adv_is_dragon or #conditional_nofear > 0 then
        for _, u in ipairs(df.global.world.units.active) do
            if u.id ~= adv.id and dfhack.units.isAlive(u) and not is_captive(u)
                and creature_id(u.race) == 'HA_KOBOLD' and is_dragon_caste(u) and on_screen(u) then
                dragon_on_screen = true
                break
            end
        end
    end

    -- Emboldened by their overlord, cowed without one. A [BENIGN] race flees anything unfriendly
    -- unless it is fearless, so this is what decides whether kobolds fight back at all.
    for _, rs in ipairs(conditional_nofear) do set_nofear(rs, dragon_on_screen) end

    if #active == 0 and #rival_dragons == 0 then return end

    for _, u in ipairs(df.global.world.units.active) do
        if u.id ~= adv.id and dfhack.units.isAlive(u) and not is_captive(u) and dist(u, adv) <= RANGE then
            local cid = creature_id(u.race)
            -- Members of the adventurer's OWN civilization never turn on them:
            -- civ membership beats race. A dwarf snatched and raised by the drow
            -- is one of theirs, so drow of that civ leave them alone (other drow
            -- civs still attack). The dragon challenge below is deliberately
            -- exempt -- rival ancient dragons duel even within one civ.
            local same_civ = adv.civ_id >= 0 and u.civ_id == adv.civ_id
            -- WHOSE ETHICS THIS UNIT IS ACTING ON. In a settlement it is the town's, so a
            -- kobold or an elf among orcs fights like an orc and an orc among humans keeps
            -- the peace like a human. Out in the open, and for an invading army anywhere,
            -- it is the unit's own race. This is the only lookup that moves -- pacify and
            -- NOFEAR below stay keyed to `cid`, what the creature actually is.
            local doctrine = cid
            if local_doctrine and not is_invader(u) then doctrine = local_doctrine end
            local targeted = false
            if not same_civ and is_person(u) then
                for _, races in ipairs(active) do if races[doctrine] then targeted = true break end end
            end

            -- dragon challenge: a rival ancient dragon, or a kobold standing with one
            local challenge = false
            if adv_is_dragon and not targeted then
                if is_ancient_dragon(u, cid) then
                    challenge = true
                elseif cid == 'HA_KOBOLD' then
                    for _, d in ipairs(rival_dragons) do
                        if d.id ~= u.id and dist(u, d) <= DRAGON_CHALLENGE_RANGE then
                            challenge = true
                            break
                        end
                    end
                end
            end

            if targeted or challenge then
                -- guard per-unit so one odd unit can't abort the whole sweep
                pcall(function()
                    local threshold = pacify_threshold(u, cid, dragon_on_screen)
                    -- a dragon challenge is never called off below the dragon bar, whatever the
                    -- challenger's own race would ask for
                    if challenge and threshold < DRAGON_PACIFY then threshold = DRAGON_PACIFY end
                    -- SHEATHED AND PERSUASIVE: a Pacifier who meets the bar and has NOT drawn a
                    -- weapon is not attacked at all. You no longer have to beat someone down and
                    -- then hold the surrender -- walking in unarmed is enough on its own. Draw
                    -- steel and the rule lapses immediately, on the same turn.
                    if not drawn and pacify >= threshold then return end
                    -- a challenger who has already yielded to a Pacify 12 adventurer is left in
                    -- peace: that surrender stands rather than reopening the challenge each turn
                    if challenge and u.flags3.adv_yield and pacify >= DRAGON_PACIFY then return end
                    make_hostile(u, adv)
                    -- a skilled enough Pacifier gets to keep them surrendered
                    if u.flags3.adv_yield and pacify < threshold then
                        u.flags3.adv_yield = false
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
