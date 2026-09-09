-- Adds a "trader is ready to trade" countdown to DFHack's gui/notify panel, and puts the same
-- line on the trade depot's own panel.
--@module = true
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

CLICKING TAKES THE NEXT STEP OF THE TRADE, whatever that is:

  merchants still walking in   zoom to one who has NOT arrived yet -- the goods are
                               only as close as the slowest of them -- and a further
                               click steps to the next, so the caravan can be walked
  trading, goods at the depot  open the depot's own panel, the one clicking the depot
                               opens, where the trade and goods buttons are
  trading, nothing to sell     open DFHack's "move trade goods" window, so the next
                               thing you do is choose what goes down there

Either way the broker is asked for -- the depot's "bring the broker" flag -- unless
he is already standing on the depot. Sending him is what makes the panel you just
opened worth anything, and it is the step that gets forgotten.

THE SAME LINE GOES ON THE DEPOT'S OWN PANEL, under the "Trade Depot" title -- the screen you
are on when you are deciding what to send down there is the screen that should be telling you
how long you have. It is the notification's own text, so the two never disagree.

Run once per DFHack session to register. To make it permanent, add the line
    trader-notification
to your dfhack-config/init/dfhack.init (magnus-scripts does this for you).
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

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
-- click: take the next step of the trade
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

-- The fort's own goods sitting on the depot, waiting to be traded. TEMP is the role a hauled-in
-- trade good has; the depot's construction materials are in the same list under other roles, and
-- `flags.trader` marks what the merchants brought -- neither is something you can sell.
local function fort_goods_at_depot(depot)
    if not depot then return 0 end
    local n = 0
    for _, ci in ipairs(depot.contained_items) do
        if ci.use_mode == df.building_item_role_type.TEMP and ci.item
            and not ci.item.flags.trader then
            n = n + 1
        end
    end
    return n
end

-- the unit in the fort position that carries the TRADE responsibility, whatever that civ calls it
local function broker_unit()
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then ent = e break end
    end
    if not ent then return nil end
    local posbyid = {}
    for _, p in ipairs(ent.positions.own) do posbyid[p.id] = p end
    for _, a in ipairs(ent.positions.assignments) do
        local p = posbyid[a.position_id]
        if p and p.responsibilities.TRADE and a.histfig >= 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u then return u end
        end
    end
    return nil
end

-- Ask for the broker, which is the step that gets forgotten: a depot full of goods trades
-- nothing while he is off hauling. Skipped when he is already standing on the depot -- there is
-- nothing to send him to -- and when the flag is already set, so an existing request is left
-- exactly as it is. Returns true if this click was what sent him.
local function request_broker(depot)
    if not depot or depot.trade_flags.trader_requested then return false end
    local u = broker_unit()
    if u and at_depot(u, depot) then return false end
    depot.trade_flags.trader_requested = true
    return true
end

-- The depot's own panel: what clicking the depot opens, and where DFHack hangs its trade
-- buttons.
--
-- `viewing_bldid` IS NOT OPTIONAL, even though the sheet draws perfectly well without it. It is
-- what DF's focus string is built from: with it unset the screen reports itself as
-- `dwarfmode/ViewSheets/BUILDING` and stops there, and every overlay registered for
-- `.../BUILDING/TradeDepot` -- DFHack's own "DFHack move trade goods" button among them -- is
-- skipped, so opening the panel this way silently took features off it. With it set the focus
-- reads `.../BUILDING/TradeDepot/Items` and they come back.
local function open_depot_panel(depot)
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.BUILDING
    vs.active_id = depot.id
    vs.viewing_bldid = depot.id
    vs.open = true          -- opened LAST, once the sheet it should show is set
end

-- DFHack's "move trade goods" window. It is a modal of its own and does not need DF's own
-- (empty, and only fillable by DF) trade-goods screen underneath it.
local function open_move_goods(depot)
    local ok, mg = pcall(reqscript, 'internal/caravan/movegoods')
    if not ok or not mg or not mg.MoveGoodsModal then return false end
    mg.MoveGoodsModal{depot = depot}:show()
    return true
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

-- The click does whatever the trade needs next: find the stragglers while there are stragglers,
-- and once somebody is at the depot, open the screen the next move is made on -- the goods
-- window when there is nothing down there to sell, the depot's own panel when there is.
local function on_click()
    if #ready_caravans() == 0 then return zoom_to_arrival() end
    local depot = find_depot()
    if not depot then return end
    request_broker(depot)
    zoom_to_depot()
    if fort_goods_at_depot(depot) == 0 and open_move_goods(depot) then return end
    open_depot_panel(depot)
end

-- ---------------------------------------------------------------------------
-- the same line, on the depot's own panel
-- ---------------------------------------------------------------------------

-- The depot panel is right-anchored and fixed-width, like every other building sheet, so the
-- position is an offset from the right edge rather than something scraped, the way DFHack's own
-- caravan overlays anchor to this panel. A negative x is the widget's RIGHT edge measured from
-- the right of the screen (overlay's own make_frame: r = |x| - 1), so -43 with a width of 52
-- puts the left edge in the panel's own text column, where "Move goods to/from depot" starts.
-- Row 9 leaves a blank line between it and the "Trade Depot" title.
DepotCountdownOverlay = defclass(DepotCountdownOverlay, overlay.OverlayWidget)
DepotCountdownOverlay.ATTRS{
    desc = 'Shows the trade countdown on the trade depot panel.',
    default_pos = {x = -43, y = 9},
    default_enabled = true,
    -- the sheet's focus string is not reliably granular: opened by a click it reads
    -- .../BUILDING/TradeDepot/Items, opened from the notification only .../BUILDING. So the
    -- widget is registered for the building sheet at large and asks the sheet itself what it
    -- is showing (see showing_depot below).
    viewscreens = 'dwarfmode/ViewSheets/BUILDING',
    frame = {w = 52, h = 1},
    overlay_onupdate_max_freq_seconds = 1,
    version = 1,
}

function DepotCountdownOverlay:init()
    -- h = 1 and a re-layout when the text changes: a Label built with no text lays out zero
    -- rows high and clips whatever it is given afterwards
    self:addviews{
        widgets.Label{view_id = 'text', frame = {t = 0, l = 0, h = 1},
                      text = '', text_pen = COLOR_LIGHTCYAN},
    }
end

-- is the building sheet showing a trade depot right now?
local function showing_depot()
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.BUILDING then return false end
    return df.building_tradedepotst:is_instance(df.building.find(vs.active_id))
end

function DepotCountdownOverlay:overlay_onupdate()
    if not showing_depot() then self.visible = false return end
    local msg = trader_message()
    self.visible = msg ~= nil
    if not msg or msg == self.shown then return end
    self.shown = msg
    self.subviews.text:setText(msg)
    if self.frame_parent_rect then self:updateLayout() end
end

OVERLAY_WIDGETS = {depot_countdown = DepotCountdownOverlay}

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
    entry.on_click = on_click
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

if dfhack_flags and dfhack_flags.module then return end

print('trader-notification: "trader_ready" registered.')
print('Shows "Merchants are coming to the depot" while a caravan is walking in (click steps')
print('through the ones not there yet), then "Trader is ready to trade for N days" -- where a')
print('click asks for the broker and opens the depot panel, or the move-goods window if the')
print('depot is empty. The same line shows on the depot panel, under the title.')
print('Add `trader-notification` to dfhack.init to load it every session.')
