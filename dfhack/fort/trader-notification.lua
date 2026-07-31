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

Clicking the notification zooms the map to your trade depot.

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

-- caravans currently AT the depot and ready to trade (not approaching / leaving / stuck)
local function ready_caravans()
    local out = {}
    local cs = df.global.plotinfo.caravans
    for i = 0, #cs - 1 do
        local c = cs[i]
        if c.trade_state == df.caravan_state.T_trade_state.AtDepot then
            out[#out + 1] = c
        end
    end
    return out
end

local function trader_message()
    if not dfhack.world.isFortressMode() then return end
    local ready = ready_caravans()
    if #ready == 0 then return end
    -- countdown: time_remaining ticks down while each caravan is at the depot. With several
    -- caravans present, list EVERY group's remaining days, soonest first -- e.g.
    -- "Traders are ready to trade for 9, 12, and 18 days" -- so you can see both the
    -- pressing deadline and how long the others will linger.
    local days = {}
    for _, c in ipairs(ready) do
        days[#days + 1] = math.max(1, math.ceil(c.time_remaining / TICKS_PER_DAY))
    end
    table.sort(days)
    if #ready == 1 then
        return ('Trader is ready to trade for %d day%s'):format(days[1], days[1] == 1 and '' or 's')
    end
    local list
    if #days == 2 then
        list = ('%d and %d'):format(days[1], days[2])
    else
        list = table.concat(days, ', ', 1, #days - 1) .. ', and ' .. days[#days]
    end
    return ('Traders are ready to trade for %s days'):format(list)
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
    entry.desc = 'Counts down the days a merchant caravan is at your depot, ready to trade.'
    entry.dwarf_fn = trader_message
    entry.on_click = zoom_to_depot
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
print('Shows "Trader is ready to trade for N days" while a caravan is at the depot.')
print('Add `trader-notification` to dfhack.init to load it every session.')
