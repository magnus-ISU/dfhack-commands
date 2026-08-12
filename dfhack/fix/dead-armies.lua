-- Purge dead figures from world armies and delete the armies left with nobody.
--[[
fix/dead-armies

An army is how the world-sim carries anyone who is not sitting at a site: a raiding party,
a migrating band, a lone wandering beast (a one-member army). When a member dies, DF is
supposed to drop it from the army -- but a death that never reaches the historical figure
leaves the figure "alive" in an army forever, and armies that lose everyone can be left
behind as husks. Tools that report where somebody is (`gui/adv-finder`, legends readers)
believe the army, so a corpse keeps a world position and keeps travelling.

This walks every army and repairs three things:

  1. DEAD MEMBERS: a member whose figure is recorded dead (`died_year >= 0`), or whose unit
     is loaded and flagged killed while history has not caught up, or whose nemesis record
     is gone entirely (an orphan id). The member is erased from the army and the figure's
     `whereabouts.army_id` is cleared so nothing keeps reading a position for it.
  2. EMPTY ARMIES: an army with no members left AND no anonymous troops. Deleted.
  3. DANGLING ARMY REFERENCES: any historical figure whose `whereabouts.army_id` points at
     an army that no longer exists -- the state that made a dead figure look like it was
     still on the move. Cleared. (Step 2 creates these too, so it always runs after.)

WHAT IT WILL NOT TOUCH:

  * The adventurer's own army. A dead companion in your party is DF's business; editing the
    party you are currently travelling with is not worth the risk.
  * Any army still carrying anonymous troops. `army.squads` holds `army_popst` blocks --
    abstract soldiers with no unit and no figure, which is how most of the world's forces
    are stored. In this world 204 of the 359 armies with no living NAMED member are exactly
    that: real forces whose named leader died. Deleting them would quietly disband real
    invasions, so "empty" means no members and no troops, and those armies are only counted.

Everything repaired is printed. Run with `-n` / `--dry-run` to only report.

Usage:
    fix/dead-armies           report and FIX everything found
    fix/dead-armies -n        report only (dry run)
    fix/dead-armies -v        also list every army touched, not just a summary
]]

local args = {...}
local dry, verbose = false, false
for _, a in ipairs(args) do
    if a == '-n' or a == '--dry-run' then dry = true
    elseif a == '-v' or a == '--verbose' then verbose = true
    else qerror('unknown argument: ' .. a) end
end

if not dfhack.isWorldLoaded() then qerror('fix/dead-armies needs a loaded world') end

local function act(fmt, ...)
    print((dry and '[dry] ' or '') .. fmt:format(...))
end

local world = df.global.world
local player_army = df.global.adventure and df.global.adventure.player_army_id or -1

-- ---- helpers ----------------------------------------------------------------

-- why this member is dead, or nil if it should stay. Anything we cannot prove dead stays:
-- a nemesis with no figure is not evidence of death, it is just an unnamed traveller.
-- The reason string is only built when it will be printed -- naming a figure is a lookup
-- per call, and most runs purge hundreds of members with nothing to say about them.
local function death_reason(nemesis_id)
    local nem = df.nemesis_record.find(nemesis_id)
    if not nem then return true, function() return 'orphan nemesis ' .. nemesis_id end end
    local hf = nem.figure
    if hf and hf.died_year >= 0 then
        return true, function()
            return ('%s died in year %d'):format(dfhack.units.getReadableName(hf), hf.died_year)
        end
    end
    -- the unit is only loaded on the current map; when it is, it outranks history, which is
    -- the whole point -- a fort kill that never registered on the figure lives here
    local unit = nem.unit_id >= 0 and df.unit.find(nem.unit_id) or nil
    if unit and unit.flags2.killed then
        return true, function()
            return ('%s killed (unit %d), unrecorded in history'):format(
                dfhack.units.getReadableName(unit), unit.id)
        end
    end
    return false
end

-- anonymous soldiers riding along with no unit and no figure
local function troop_count(army)
    local n = 0
    for _, sq in ipairs(army.squads) do n = n + sq.count end
    return n
end

local function clear_army_ref(hf, army_id)
    local wa = hf and hf.info and hf.info.whereabouts
    if wa and wa.army_id == army_id then
        if not dry then wa.army_id = -1 end
        return true
    end
end

-- ---- 1) dead members, 2) the armies they empty ------------------------------

local armies = world.armies.all
local purged, emptied, kept, refs = 0, 0, 0, 0

for i = #armies - 1, 0, -1 do
    local army = armies[i]
    if army.id ~= player_army then
        local removed = {}
        for j = #army.members - 1, 0, -1 do
            local nemesis_id = army.members[j].nemesis_id
            local dead, why = death_reason(nemesis_id)
            if dead then
                local nem = df.nemesis_record.find(nemesis_id)
                if clear_army_ref(nem and nem.figure, army.id) then refs = refs + 1 end
                table.insert(removed, verbose and why() or true)
                purged = purged + 1
                if not dry then army.members:erase(j) end
            end
        end
        if #removed > 0 and verbose then
            act('army %d at %d,%d: dropping %d dead member%s', army.id, army.pos.x, army.pos.y,
                #removed, #removed == 1 and '' or 's')
            for _, why in ipairs(removed) do print('    ' .. why) end
        end
        -- in a dry run the members are still in place, so count what WOULD be left
        local left = #army.members - (dry and #removed or 0)
        if left == 0 then
            local troops = troop_count(army)
            if troops > 0 then
                kept = kept + 1
                if verbose then
                    act('army %d at %d,%d: keeping -- no named member left but %d anonymous troop%s aboard',
                        army.id, army.pos.x, army.pos.y, troops, troops == 1 and '' or 's')
                end
            else
                emptied = emptied + 1
                if verbose then
                    act('army %d at %d,%d: deleting -- nobody left aboard',
                        army.id, army.pos.x, army.pos.y)
                end
                if not dry then
                    armies:erase(i)
                    pcall(function() army:delete() end)
                end
            end
        end
    end
end

-- ---- 3) figures still pointing at an army that is gone ----------------------
-- Deleting armies above makes new ones of these, so this runs last and sweeps both the
-- references we just orphaned and any the world-sim orphaned on its own.

local dangling = 0
for _, hf in ipairs(world.history.figures) do
    local wa = hf.info and hf.info.whereabouts
    if wa and wa.army_id >= 0 and not df.army.find(wa.army_id) then
        dangling = dangling + 1
        if verbose then
            act('%s: clearing reference to army %d, which no longer exists',
                dfhack.units.getReadableName(hf), wa.army_id)
        end
        if not dry then wa.army_id = -1 end
    end
end

-- ---- report -----------------------------------------------------------------

local total = purged + emptied + dangling
if total == 0 then
    print('fix/dead-armies: nothing to fix -- no dead figures in any army.')
else
    local verb = dry and 'found (dry run -- rerun without -n to fix)' or 'fixed'
    print(('fix/dead-armies: %d dead member%s purged, %d empty arm%s deleted, ' ..
        '%d dangling reference%s cleared -- %s.'):format(
        purged, purged == 1 and '' or 's',
        emptied, emptied == 1 and 'y' or 'ies',
        dangling, dangling == 1 and '' or 's', verb))
    if refs > 0 then
        print(('  (plus %d whereabouts reference%s cleared on the purged members themselves)'):format(
            refs, refs == 1 and '' or 's'))
    end
end
if kept > 0 then
    print(('  %d arm%s left alone: no living named member, but anonymous troops still aboard.'):format(
        kept, kept == 1 and 'y is' or 'ies are'))
end
