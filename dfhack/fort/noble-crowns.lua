-- Keep crowns on noble heads: forbid any crown a commoner wears, claims or reaches for.
--@module = true
--@enable = true
--[[
noble-crowns

A crown is finery, and DF hands finery out by ownership: any dwarf who takes a liking to one
CLAIMS it and then wears it, crown or not. Nothing in the game reserves a crown for the noble
it was made for, so the mayor's regalia ends up on a peasant and stays there.

This watches every crown in the fort and FORBIDS the ones a commoner has got hold of. Three
ways a crown reaches a commoner, all watched:

  * WORN -- the crown is in someone's inventory with role `Worn`.
  * OWNED -- the crown is claimed (`flags.owned`) by a unit who is not a noble. This is the
    one that matters: ownership is what makes a dwarf put it on and keep putting it on.
  * A PICKUP-EQUIPMENT JOB holds a reference to the crown. That is the "tries to" case, caught
    before the crown is ever put on.

A NOBLE is anyone holding ANY position, of any rank, in any entity -- the monarch and the mayor,
and just as much the bookkeeper, broker, manager and expedition leader. Administrators are
nobles for this purpose: the fort gave them the office, so the fort may dress them for it.
Anything such a dwarf wears, owns or fetches is left strictly alone, and a crown lying in a
stockpile with nobody attached to it is not touched either.

The test is `dfhack.units.getNoblePositions`, read off the dwarf's own historical figure, so it
sees the assignment wherever it is recorded. Scanning `positions.assignments` on the site
government and the civ instead -- what this did before -- missed holders those two vectors do
not list, and quietly confiscated the broker's and the bookkeeper's crowns.

HAULING IS ALWAYS ALLOWED, and this is the important exclusion. A crown in a dwarf's inventory
in any role but `Worn` is being carried somewhere, and the destination that matters is the
TRADE DEPOT: forbid a crown mid-carry and the hauler drops it where it stands, so a crown you
meant to sell never reaches the caravan. Carrying is therefore ignored outright, and the job
test is an allowlist of one (`PickupEquipment`) rather than "any job holding a crown" -- which
would have caught `BringItemToDepot`, `TradeAtDepot`, `StoreItemInStockpile` and every other
piece of ordinary handling.

ONLY CITIZENS are policed. A merchant's stock walks in on the merchant's own back, and a
visiting lord holds his position in HIS civilization rather than yours, so both read as
commoners here -- forbidding either would be confiscating property that is not the fort's.

Forbidding is the whole action. It is what stops the crown being fetched, hauled and re-claimed,
and it leaves the item exactly where it is -- nothing is teleported, no job is cancelled, no
dwarf is stripped. Two consequences worth knowing:

  * A crown ALREADY BEING WORN is not taken off by forbidding it. DF has no "undress" order,
    and pulling an item out of a unit's inventory from a script is how you corrupt one. The
    forbid stops the crown being re-claimed after it comes off on its own; to get it off now,
    use the Nobles screen or dump it by hand.
  * Ownership is NOT cleared. `flags.owned` with a forbidden item is a stalemate DF resolves
    on its own eventually, and clearing an owner mid-job is exactly the kind of live-structure
    edit that crashed `adamantine-hospital`'s retarget mode (BROKEN_FEATURES.md).

The forbid is a SYNC, not a ratchet: each pass releases any crown no commoner has hold of any
more. A peasant's crown that gets forbidden and is then dropped, or worn by a dwarf who has
since been appointed bookkeeper, is unforbidden again on the next check -- otherwise it stayed
locked out of everyone's hands, nobles included, until released by hand.

`noble-crowns release` unforbids every crown in the fort immediately, without waiting for a
pass; with the watcher enabled it will re-forbid any a commoner still has hold of.

Usage:
    enable noble-crowns      watch crowns (checks every 100 frames)
    disable noble-crowns     stop watching
    noble-crowns             status: every crown in the fort, who has it, what is forbidden
    noble-crowns release     unforbid every crown in the fort
]]

local GLOBAL_KEY = 'noble-crowns'
local CHECK_FRAMES = 100     -- crowns change hands over days, not frames; no need to be eager

-- ---- persisted state (per site) ---------------------------------------------

state = state or nil

local function default_state()
    return {enabled = false, forbidden = 0}
end

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, default_state())
    end
    for k, v in pairs(default_state()) do
        if state[k] == nil then state[k] = v end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

-- ---- nobles -----------------------------------------------------------------

-- ANY position counts, elected or appointed, grand or clerical: monarch, mayor, baron, and
-- equally the bookkeeper, broker, manager and expedition leader. "Administrator" is not a
-- lesser rank here -- if the fort gave a dwarf a hat, the dwarf may keep the crown.
--
-- The test that decides this is `dfhack.units.getNoblePositions`, which walks the dwarf's OWN
-- historical figure for position links and so finds an assignment in whatever entity holds it.
-- The earlier version instead scanned `positions.assignments` on the site government and the
-- civ and matched `assignment.histfig`, which reads as "no position at all" for any holder
-- those two vectors do not happen to list -- which is how the broker and the bookkeeper ended
-- up losing their crowns. The entity scan is KEPT as a second opinion, for the mirror-image
-- case (the assignment names the histfig but the histfig carries no link), and the two are
-- OR-ed: a hit from either one is a noble.
local function noble_hfs()
    local out = {}
    for _, ent_id in ipairs({df.global.plotinfo.group_id, df.global.plotinfo.civ_id}) do
        local ent = df.historical_entity.find(ent_id)
        if ent then
            for _, asn in ipairs(ent.positions.assignments) do
                if asn.histfig >= 0 then out[asn.histfig] = true end
            end
        end
    end
    return out
end

local function is_noble(unit, nobles)
    if not unit then return false end
    local ok, positions = pcall(dfhack.units.getNoblePositions, unit)
    if ok and positions and #positions > 0 then return true end
    return unit.hist_figure_id >= 0 and nobles[unit.hist_figure_id] or false
end

-- ---- crowns -----------------------------------------------------------------

local function crown_items()
    local out = {}
    for _, it in ipairs(df.global.world.items.other.CROWN) do
        if not it.flags.garbage_collect then out[#out + 1] = it end
    end
    return out
end

-- Who is trying to KEEP this crown, and how -- or nil for every use that is none of our
-- business. Returns unit, reason.
--
-- HAULING IS NOT POSSESSION. A crown in a dwarf's inventory with any role but `Worn` is being
-- carried somewhere -- to a stockpile, into a bin, and above all TO THE TRADE DEPOT. Forbidding
-- it mid-carry makes the hauler drop it on the spot and puts the crown beyond the depot for
-- good, so carrying is ignored outright and only `Worn` counts here.
local function possessor(item)
    for _, inv_unit in ipairs(df.global.world.units.active) do
        for _, inv in ipairs(inv_unit.inventory) do
            if inv.item and inv.item.id == item.id then
                if inv.mode == df.inv_item_role_type.Worn then
                    return inv_unit, 'wearing it'
                end
                return nil                     -- hauling it somewhere; leave them to it
            end
        end
    end
    if item.flags.owned then
        local owner = dfhack.items.getOwner(item)
        if owner then return owner, 'has claimed it' end
    end
    return nil
end

-- jobs that mean "about to put it on". Everything else a job can do with a crown -- carry it
-- to the depot, trade it, stuff it in a bin, haul it to a stockpile -- is legitimate handling
-- by whoever happens to be free, so an allowlist is used rather than "any job at all".
local WEAR_JOBS = {}
for _, n in ipairs({'PickupEquipment'}) do
    if df.job_type[n] then WEAR_JOBS[df.job_type[n]] = true end
end

-- the unit whose JOB is about to put this crown on ("tries to"): the job's worker, or nil
local function job_claimant(item)
    if not item.flags.in_job then return nil end       -- cheap gate; most crowns fail it
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and WEAR_JOBS[job.job_type] then
            for _, ref in ipairs(job.items) do
                if ref.item and ref.item.id == item.id then
                    return dfhack.job.getWorker(job), df.job_type[job.job_type] or 'a job'
                end
            end
        end
        link = link.next
    end
    return nil
end

-- ---- the check --------------------------------------------------------------

local function forbid(item, unit, why)
    item.flags.forbid = true
    load_state()
    state.forbidden = state.forbidden + 1
    save_state()
    dfhack.gui.showAnnouncement(
        ('%s forbidden: %s is not a noble and is %s.'):format(
            dfhack.items.getDescription(item, 0, true),
            dfhack.units.getReadableName(unit), why),
        COLOR_YELLOW, true)
end

-- who, if anyone, is trying to keep this crown -- possession first, then the pickup job
local function holder(item)
    local unit, why = possessor(item)
    if not unit then
        local worker, jobname = job_claimant(item)
        if worker then unit, why = worker, 'fetching it for ' .. jobname end
    end
    return unit, why
end

-- one pass over the fort's crowns. Bounded by the crown count (single digits in most forts),
-- and the units.active walk inside possessor() only runs for crowns that are not already
-- forbidden, so a fort that has settled costs one vector read per crown per check.
--
-- The pass is a SYNC, not a one-way ratchet: a crown is forbidden exactly while a commoner
-- has hold of it, and released the moment that stops being true. Without the release half, a
-- crown forbidden off a peasant stayed forbidden after the peasant dropped it or was appointed
-- bookkeeper -- unclaimable by anyone, noble included, until `noble-crowns release` was run by
-- hand. Only crowns are touched, and only while the watcher is enabled.
local function do_check()
    if not dfhack.world.isFortressMode() then return 0 end
    local nobles = noble_hfs()
    local hits = 0
    for _, item in ipairs(crown_items()) do
        local unit, why = holder(item)
        -- CITIZENS ONLY. A merchant's stock walks into the fort on the merchant's own back,
        -- and a visiting lord's position is held in HIS civ, not ours, so he reads as a
        -- commoner here. Forbidding either would be confiscating someone else's property --
        -- and for the caravan, forbidding goods that came to be traded.
        local commoner = unit and dfhack.units.isCitizen(unit) and not is_noble(unit, nobles)
        if commoner and not item.flags.forbid then
            forbid(item, unit, why)
            hits = hits + 1
        elseif not commoner and item.flags.forbid then
            item.flags.forbid = false
        end
    end
    return hits
end

local function release()
    local n = 0
    for _, it in ipairs(crown_items()) do
        if it.flags.forbid then it.flags.forbid = false; n = n + 1 end
    end
    return n
end

-- ---- service loop (frame-gap-safe bounce via set_enabled) --------------------

enabled = enabled or false
function isEnabled() return enabled end

local hb_gen = 0
local last_frame = nil

local function start()
    enabled = true
    last_frame = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local f = df.global.world.frame_counter
        if not last_frame or math.abs(f - last_frame) >= CHECK_FRAMES then
            last_frame = f
            pcall(do_check)
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil                       -- per-world
        load_state()
        if state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state = nil
    end
end

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

if dfhack_flags.module then
    return
end

-- ---- command line ------------------------------------------------------------

if not dfhack.isMapLoaded() then qerror('noble-crowns needs a loaded fort') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('noble-crowns: ' .. (enabled and 'enabled -- watching crowns' or 'disabled'))
    return
end

local cmd = ({...})[1]

if cmd == 'release' then
    local n = release()
    print(('noble-crowns: unforbade %d crown%s'):format(n, n == 1 and '' or 's'))
    if enabled then
        print('  the watcher re-forbids any of them a commoner still has hold of.')
    end
else
    print(('noble-crowns: %s'):format(enabled and 'ENABLED (checks every '
        .. CHECK_FRAMES .. ' frames)' or 'disabled'))
    local nobles = noble_hfs()
    local items = crown_items()
    local held = 0
    for _, it in ipairs(items) do if it.flags.forbid then held = held + 1 end end
    print(('  crowns in the fort: %d (%d forbidden)'):format(#items, held))
    for _, it in ipairs(items) do
        local unit, why = holder(it)
        local who = 'unclaimed or in transit'
        if unit then
            local rank = is_noble(unit, nobles) and 'NOBLE'
                or (dfhack.units.isCitizen(unit) and 'commoner' or 'not a citizen')
            who = ('%s %s -- %s'):format(dfhack.units.getReadableName(unit), why, rank)
        end
        print(('    %s  [%s]%s'):format(dfhack.items.getDescription(it, 0, true), who,
            it.flags.forbid and '  [forbidden]' or ''))
    end
    print(('  crowns forbidden so far: %d'):format(state.forbidden))
    if not enabled then print('  `enable noble-crowns` to watch.') end
end
