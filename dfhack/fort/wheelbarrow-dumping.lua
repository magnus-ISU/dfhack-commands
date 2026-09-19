-- Heavy items hauled by hand go at wheelbarrow speed when a wheelbarrow is handy.
--@module = true
--@enable = true
--[[
fort/wheelbarrow-dumping

Vanilla uses a wheelbarrow for one thing: hauling to a stockpile that has one assigned.
Everything else heavy is carried by hand -- a boulder being dumped, a boulder fetched to
the smelter as flux, a block walked to a construction site, a stone bound for a pile with
no barrows -- and a 240-weight stone slows an ordinary dwarf to a quarter of walking pace,
so a designation of forty boulders becomes forty dwarves crawling across the fort for a
season. Wheelbarrows exist to fix exactly this ("dwarves carrying items in wheelbarrows
ignore the weight of the contents"), and DF only reaches for them on that one job.

This makes every hand-haul use them, by pretending. Whenever a fort worker picks up an
item for a job that weighs more than 75 (the same line vanilla draws for when a stockpile
haul gets a wheelbarrow) and a free wheelbarrow is handy, the item weighs nothing for the
rest of the trip: the dwarf walks at full speed, exactly as they would pushing it in a
barrow. It applies to whatever the job is -- dumping, a workshop reagent, a building
material, a stockpile haul from a pile without barrows of its own. The wheelbarrow is
spoken for until the item is put down -- so, as with stockpiles, the number of barrows you
have is the number of heavy hauls that go fast at once, and one idle barrow is never
lent to two people -- and the item gets its real weight back the moment it leaves the
carrier's hands.

    enable fort/wheelbarrow-dumping    turn it on for this fort (saved with the fort)
    disable fort/wheelbarrow-dumping   stop; anything mid-haul gets its weight back now
    fort/wheelbarrow-dumping           status: what is being barrowed right now

**"Handy"** means a wheelbarrow anywhere on the map that is not in use: no job on it,
not being pushed, not forbidden. Wheelbarrows assigned to a stockpile count while they
are idle, just as vanilla lets any pile borrow them between hauls. Distance is not a
factor -- barrows live at a stone pile or a tool stockpile, rarely near what is dumped.
Nothing is written to the wheelbarrow -- it is not moved, flagged or attached to the job,
because DF's dump-job code has no vehicle step at all (a barrow attached as
`PushHaulVehicle` is silently dropped at pickup, tested). The reservation is this tool's
own bookkeeping.

**This is a house rule.** Barrowing a dump run or a smelter's flux is not something vanilla
does slowly; it is something vanilla does not do. Lives in the *house rules* column of
`fort/magnus-scripts`: off until you turn it on, untouched by the `[r]` / `[m]` master
switches. No options: the 75 line is vanilla's own number.

**How the pretending works.** DF caches an item's weight on the item (`item.weight`) and
weighs it lazily: a boulder nobody has touched sits at 0 until the first pickup, and
after that DF reads the cache -- it does not re-weigh mid-carry, and the carried weight
is what sets the dwarf's pace (measured: 37 ticks/tile at 240, 8-11 ticks/tile at 1, on
the same dwarf, mid-haul). So this sets the cached weight to 1 at pickup and writes the
real number back when the item leaves the inventory -- job done, job cancelled, dwarf
distracted, whatever the reason. A haul is spotted from the carrier's side: every fort
worker with a job, every item in their hands (inventory mode Hauled) that belongs to that
job and weighs over the line. A boulder riding in a real wheelbarrow is inside the barrow,
not in the hands, so those hauls are never touched. Items are tracked in the fort's saved
data, so a save made mid-haul is repaired on load; anything that fell through (a crash)
is reset to 0, the untouched state DF re-weighs from on its own.
]]

local GLOBAL_KEY = 'wheelbarrow-dumping'

-- vanilla's wheelbarrow line: a stockpile haul gets a barrow when the item is heavier
-- than 75. Same rule here.
local HEAVY = 75
-- the weight a barrowed item shows while carried. Not 0: 0 is DF's "not weighed yet"
-- value and would invite a re-weigh at the next pickup-like moment.
local LIGHT = 1

-- rendered frames between sweeps. A pickup is only missed for as long as one gap, and a
-- dwarf covers a tile or two in that time; per sweep this walks units.active once.
local BEAT_FRAMES = 10

-- unit_inventory_item.mode: 0 = Hauled (in the hands for a job), 2 = Worn. The enum is
-- not exposed to Lua on this build, so the number is spelled out.
local MODE_HAULED = 0

enabled = enabled or false

-- item id -> {whole, fraction, wb = wheelbarrow id}. Everything currently lightened.
-- Mirrored into the fort's site data on every change so a mid-haul save can be undone.
tracked = tracked or {}

local function persist()
    local rows = {}
    for id, t in pairs(tracked) do
        rows[#rows + 1] = {id = id, whole = t.whole, fraction = t.fraction, wb = t.wb}
    end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = enabled, tracked = rows})
end

local function is_heavy(item)
    local w = item.weight
    return w.whole > HEAVY or (w.whole == HEAVY and w.fraction > 0)
end

-- a wheelbarrow nobody is using: no job on it, not carried, not forbidden, not
-- already spoken for by one of our own hauls
local function wheelbarrow_free(wb, reserved)
    local f = wb.flags
    return not f.in_job and not f.in_inventory and not f.forbid and not f.garbage_collect
        and not reserved[wb.id]
end

-- any free wheelbarrow on the map, or nil. Distance is deliberately not a factor: a
-- fort keeps its barrows at a stone pile or a tool stockpile, rarely near whatever is
-- being dumped, and vanilla lets a pile borrow a barrow from anywhere too.
-- items.other.TOOL is every tool on the map (dozens to a few hundred), a fine size for
-- a per-pickup scan.
local function free_wheelbarrow(reserved)
    for _, it in ipairs(df.global.world.items.other.TOOL) do
        if it:isWheelbarrow() and wheelbarrow_free(it, reserved) then return it end
    end
    return nil
end

-- Every heavy item currently in a fort worker's hands for their job: item id -> item.
-- units.active is the bounded list (hundreds); a worker's inventory is a dozen entries.
-- The job link is the item's in_job flag: a hauled item that is nobody's job is a
-- dwarf carrying their own property, not a haul.
local function carried_heavy()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if u.job.current_job and dfhack.units.isFortControlled(u)
                and dfhack.units.isAlive(u) then
            for _, e in ipairs(u.inventory) do
                local item = e.item
                if e.mode == MODE_HAULED and item.flags.in_job and not item:isWheelbarrow()
                        and (tracked[item.id] or is_heavy(item)) then
                    out[item.id] = item
                end
            end
        end
    end
    return out
end

local function lighten(item, wb)
    tracked[item.id] = {whole = item.weight.whole, fraction = item.weight.fraction, wb = wb.id}
    item.weight.whole, item.weight.fraction = LIGHT, 0
end

-- put the real weight back. A missing item (dumped into magma, atom-smashed) just
-- drops out of the table.
local function restore(id)
    local t = tracked[id]
    if not t then return end
    local item = df.item.find(id)
    if item then item.weight.whole, item.weight.fraction = t.whole, t.fraction end
    tracked[id] = nil
end

-- one sweep: release what is no longer carried, lighten what just got picked up
local function sweep()
    local changed = false
    -- release first, so a barrow freed this sweep is handy for a pickup this sweep
    local still = carried_heavy()
    for id in pairs(tracked) do
        if not still[id] then restore(id) changed = true end
    end
    local reserved = {}
    for _, t in pairs(tracked) do reserved[t.wb] = true end
    for id, item in pairs(still) do
        if not tracked[id] then
            local wb = free_wheelbarrow(reserved)
            if wb then
                lighten(item, wb)
                reserved[wb.id] = true
                changed = true
            end
        end
    end
    if changed then persist() end
end

local function restore_all()
    for id in pairs(tracked) do restore(id) end
    persist()
end

-- ---------------------------------------------------------------------------
-- the service
-- ---------------------------------------------------------------------------

-- generation guard: a reqscript reload builds fresh locals, so the running heartbeat
-- closure must be told to stop through something that survives the reload
local function hb_gen(set)
    if set ~= nil then dfhack.internal.wheelbarrow_dumping_hb_gen = set end
    return dfhack.internal.wheelbarrow_dumping_hb_gen or 0
end

function isEnabled() return enabled end

local function start()
    enabled = true
    local my_gen = hb_gen() + 1
    hb_gen(my_gen)
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen() then return end
        if dfhack.world.isFortressMode() then pcall(sweep) end
        dfhack.timeout(BEAT_FRAMES, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen(hb_gen() + 1)
    restore_all()
end

function set_enabled(on)
    if on then start() else stop() end
    persist()
    return enabled
end

-- Items lightened when the fort was last saved: put their weight back before anything
-- else happens. A row whose item is still being carried under a live dump job would be
-- re-lightened by the first sweep anyway; the rest are leftovers.
local function load_persisted()
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY)
    tracked = {}
    if not data then return false end
    for _, row in ipairs(data.tracked or {}) do
        tracked[row.id] = {whole = row.whole, fraction = row.fraction, wb = row.wb}
    end
    restore_all()
    return data.enabled == true
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode() and load_persisted() then start() end
    elseif sc == SC_MAP_UNLOADED then
        enabled = false
        hb_gen(hb_gen() + 1)
        tracked = {}
    end
end

if dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if not dfhack.world.isFortressMode() then
    qerror('wheelbarrow-dumping only works in fortress mode')
end

if dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('wheelbarrow-dumping: %s'):format(enabled and
        'ON -- heavy dumps go at wheelbarrow speed when a barrow is handy' or 'OFF'))
    return
end

-- status
local free, total = 0, 0
local reserved = {}
for _, t in pairs(tracked) do reserved[t.wb] = true end
for _, it in ipairs(df.global.world.items.other.TOOL) do
    if it:isWheelbarrow() then
        total = total + 1
        if wheelbarrow_free(it, reserved) then free = free + 1 end
    end
end
print(('wheelbarrow-dumping is %s; %d wheelbarrow%s on the map, %d free')
    :format(enabled and 'ON' or 'OFF', total, total == 1 and '' or 's', free))
local n = 0
for id, t in pairs(tracked) do
    n = n + 1
    local item = df.item.find(id)
    local wb = df.item.find(t.wb)
    -- the barrow's item id is printed because several barrows share a name; each haul
    -- here holds a different one
    print(('  %s (real weight %d) -- as if in %s [item %d]'):format(
        item and dfhack.items.getDescription(item, 0) or ('item #' .. id), t.whole,
        wb and dfhack.items.getDescription(wb, 0) or 'wheelbarrow', t.wb))
end
if n == 0 then print('  nothing heavy is being hauled by hand right now') end
