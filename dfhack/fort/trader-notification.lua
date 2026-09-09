-- Adds a "trader is ready to trade" countdown to DFHack's gui/notify panel.
--@ module = false
--[[
trader-notification

Registers a custom notification (name: "trader_ready") into the same notification
list used by "moody dwarf is gathering items" and "needs a tomb" (DFHack's
gui/notify overlay).

While a merchant caravan is at your trade depot and ready to trade, it shows:
    "Trader is ready to trade for N days"
where N counts down as the caravan's remaining time at the depot ticks away. With
more than one caravan present it reads "Traders are ready to trade for N days"
(N = the SOONEST to leave, so you know your real deadline to trade with everyone).

BEFORE THEY GET THERE it shows the approach instead:
    "Merchants are coming to the depot"
A caravan that has walked onto the map but not reached the depot is the window in
which things go wrong -- a wagon with no route, a pack animal left at the edge --
and the notice is what tells you to go and look. With a caravan already trading
and another still walking in, the countdown gets "(more coming)" on the end.

Clicking zooms the map. While merchants are on their way it zooms to one who has
NOT arrived yet -- the trade goods are only as close as the slowest of them -- and
each further click steps to the next one, so you can walk the whole caravan. Once
they are all in, and while trade is on, it zooms to the depot as before.

Run once per DFHack session to register. To make it permanent, add the line
    trader-notification
to your dfhack-config/init/dfhack.init (magnus-scripts does this for you).
]]

local NAME = 'trader_ready'
local STOCK = 'traders_ready'   -- DFHack's built-in trader notification (we supersede it)
-- caravan.time_remaining is NOT in cur_year_tick units -- it decrements ~1 per 10 game ticks
-- (measured: 47 units over 472 ticks). So one day (1200 game ticks) is 120 of these units.
local TICKS_PER_DAY = 120

-- ---------------------------------------------------------------------------
-- detection
-- ---------------------------------------------------------------------------

local T = df.caravan_state.T_trade_state

local function caravans_in_state(state)
    local out = {}
    local cs = df.global.plotinfo.caravans
    for i = 0, #cs - 1 do
        if cs[i].trade_state == state then out[#out + 1] = cs[i] end
    end
    return out
end

-- caravans currently AT the depot and ready to trade (not approaching / leaving / stuck)
local function ready_caravans() return caravans_in_state(T.AtDepot) end

-- caravans that are on the map and still walking to the depot
local function approaching_caravans() return caravans_in_state(T.Approaching) end

local function trader_message()
    if not dfhack.world.isFortressMode() then return end
    local ready = ready_caravans()
    if #ready == 0 then
        -- nobody trading yet: say so while they are still walking in, which is when a caravan
        -- that will never make it still looks like one that will
        local coming = approaching_caravans()
        if #coming == 0 then return end
        return #coming == 1 and 'Merchants are coming to the depot'
            or ('Merchants from %d caravans are coming to the depot'):format(#coming)
    end
    -- countdown: time_remaining ticks down while each caravan is at the depot. With several
    -- caravans present, list EVERY group's remaining days, soonest first -- e.g.
    -- "Traders are ready to trade for 9, 12, and 18 days" -- so you can see both the
    -- pressing deadline and how long the others will linger.
    local days = {}
    for _, c in ipairs(ready) do
        days[#days + 1] = math.max(1, math.ceil(c.time_remaining / TICKS_PER_DAY))
    end
    table.sort(days)
    -- one more caravan still on the road is worth knowing about while you plan a trade
    local more = #approaching_caravans() > 0 and ' (more coming)' or ''
    if #ready == 1 then
        return ('Trader is ready to trade for %d day%s%s')
            :format(days[1], days[1] == 1 and '' or 's', more)
    end
    local list
    if #days == 2 then
        list = ('%d and %d'):format(days[1], days[2])
    else
        list = table.concat(days, ', ', 1, #days - 1) .. ', and ' .. days[#days]
    end
    return ('Traders are ready to trade for %s days%s'):format(list, more)
end

-- ---------------------------------------------------------------------------
-- click: zoom to the trade depot
-- ---------------------------------------------------------------------------

local function find_depot()
    local bs = df.global.world.buildings.all
    for i = 0, #bs - 1 do
        if bs[i]:getType() == df.building_type.TradeDepot then return bs[i] end
    end
end

local function zoom_to_depot()
    local d = find_depot()
    if d then
        dfhack.gui.revealInDwarfmodeMap(xyz2pos(d.centerx, d.centery, d.z), true, true)
    end
end

-- is this unit standing on the depot?
local function at_depot(u, depot)
    if not depot then return false end
    local p = u.pos
    return p.z == depot.z and p.x >= depot.x1 and p.x <= depot.x2
        and p.y >= depot.y1 and p.y <= depot.y2
end

-- The merchants of the approaching caravans who have not reached the depot yet, in a stable
-- order (by unit id) so that clicking again steps to the next one rather than shuffling.
-- Pack animals are left out: a click should land on somebody you can read a name off, and the
-- animals follow their driver anyway.
local function merchants_en_route()
    local coming = approaching_caravans()
    if #coming == 0 then return {} end
    local civs = {}
    for _, c in ipairs(coming) do civs[c.entity] = true end
    local depot = find_depot()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if civs[u.civ_id] and dfhack.units.isMerchant(u) and not dfhack.units.isAnimal(u)
            and not u.flags1.inactive and not u.flags2.killed and not at_depot(u, depot) then
            out[#out + 1] = u
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- which one of them the last click showed, so the next click shows the next
local next_en_route = 1

-- Merchants still walking in are what you want to see while they are walking in: the click
-- steps through them one per click and falls back to the depot once they are all there.
local function zoom_to_arrival()
    local en_route = merchants_en_route()
    if #en_route == 0 then return zoom_to_depot() end
    if next_en_route > #en_route then next_en_route = 1 end
    local u = en_route[next_en_route]
    next_en_route = next_en_route + 1
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(u.pos.x, u.pos.y, u.pos.z), true, true)
end

-- ---------------------------------------------------------------------------
-- registration (idempotent; survives notify-module reloads via onStateChange)
-- ---------------------------------------------------------------------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    -- (re)assign callbacks every time so re-running the script picks up edits
    entry.desc = 'Counts down the days a merchant caravan is at your depot, and says when one '
        .. 'is still on its way.'
    entry.dwarf_fn = trader_message
    entry.on_click = zoom_to_arrival
    -- the overlay gates on config.data[name].enabled; make sure it exists so it
    -- doesn't nil-index (and so the notification is on by default)
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
    -- our countdown supersedes DFHack's stock "traders_ready" alert -- turn that one off so
    -- they don't both show. (magnus-scripts disable restores it.)
    if n.config and n.config.data then
        local stock = n.NOTIFICATIONS_BY_NAME[STOCK]
        n.config.data[STOCK] = n.config.data[STOCK] or {version = stock and stock.version or 1}
        if n.config.data[STOCK].enabled ~= false then
            n.config.data[STOCK].enabled = false
            if n.config.write then n.config:write() end
        end
    end
end

register()

-- re-apply if the notify module is reloaded on a new world/map load
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

print('trader-notification: "trader_ready" registered.')
print('Shows "Merchants are coming to the depot" while a caravan is walking in (click steps')
print('through the ones not there yet), then "Trader is ready to trade for N days".')
print('Add `trader-notification` to dfhack.init to load it every session.')
