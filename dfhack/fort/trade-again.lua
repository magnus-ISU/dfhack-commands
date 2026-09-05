-- Pre-select your own nearby goods when DFHack's trade-goods screen opens.
--@module = true
--@enable = true
--[[
fort/trade-again

DFHack's "Move goods to/from depot" screen (`dfhack/lua/caravan/movegoods`) opens with nothing
selected, so every caravan starts with the same hunt through thousands of rows for the things
you were always going to sell. This selects them for you as the screen opens: everything your
own fort made that is sitting AT the depot already.

WHAT IT PICKS, and why each condition is there:

  * NOT FOREIGN -- an item with `flags.foreign` was bought from a caravan, and selling last
    year's purchases back to this year's merchants is almost never what you meant.
  * DISTANCE 0 from the depot -- the distance the screen's own `dist` column shows, computed
    the same way (`max(|dx|,|dy|) + |dz|` from the depot centre). Zero means no dwarf has to
    walk anywhere. `fort/trade-again radius N` widens that if you want the surrounding tiles
    too; the setting persists with the fort.
  * NOT forbidden, NOT an artifact, and NOT ethically banned -- the three kinds of item that
    being selected by accident actually costs you something. (The screen marks banned goods
    itself; this reads the same flags via the caravan module's own scan.)

Items already at the depot (`in_building`) need no help: DFHack counts those as selected the
moment the screen opens. This is for the ones lying beside it that it does not.

Selection uses DFHack's own primitive -- `dfhack.items.markForTrade` -- so the screen picks
them up exactly as if you had clicked each row, and deselecting one on the screen removes the
job again the normal way.

    enable trade-again      pre-select as the screen opens (persists with the fort)
    disable trade-again     stop
    trade-again             select them right now, without opening the screen
    trade-again radius N    how far from the depot counts (default 0)
    trade-again status      what is set, and what would be selected
]]

local GLOBAL_KEY = 'trade-again'

-- ---- state -----------------------------------------------------------------

state = state or nil

local function default_state()
    return {enabled = false, radius = 0}
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

local function save_state()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, state)
end

-- ---- what counts -----------------------------------------------------------

-- the depot the screen is about: the selected building when one is up, else the fort's only
-- (or first) finished depot, so the command works from anywhere
local function find_depot()
    local bld = dfhack.gui.getSelectedBuilding(true)
    if bld and df.building_tradedepotst:is_instance(bld) then return bld end
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
        if b:getBuildStage() >= b:getMaxBuildStage() then return b end
    end
end

-- the screen's own distance measure, kept identical on purpose: whatever the `dist` column
-- says is what this matches on
local function depot_distance(depot, pos)
    return math.max(math.abs(depot.centerx - pos.x), math.abs(depot.centery - pos.y))
        + math.abs(depot.z - pos.z)
end

-- the caravan module's banned/risky scan, if it will load -- the ethics rules are its own and
-- reimplementing them here would drift
local function banned_scan()
    local ok, common = pcall(reqscript, 'internal/caravan/common')
    if not ok or not common or not common.scan_banned then return nil end
    local risky = {}
    return function(item)
        local okc, banned = pcall(common.scan_banned, item, risky)
        return okc and banned or false
    end
end

local function eligible(item, depot, radius, is_banned)
    local f = item.flags
    if f.foreign or f.forbid or f.artifact or f.garbage_collect or f.removed
        or f.hostile or f.owned or f.trader or f.in_job then
        return false
    end
    if f.in_building then return false end        -- already at the depot: already selected
    if item.flags.dump then return false end
    if is_banned and is_banned(item) then return false end
    local ok, pos = pcall(function() return xyz2pos(dfhack.items.getPosition(item)) end)
    if not ok or not pos then return false end
    return depot_distance(depot, pos) <= radius
end

-- everything that would be selected right now
function candidates()
    local depot = find_depot()
    if not depot then return {}, nil end
    local radius = load_state().radius or 0
    local is_banned = banned_scan()
    local out = {}
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if eligible(item, depot, radius, is_banned) then out[#out + 1] = item end
    end
    return out, depot
end

-- Mark them the way the screen itself would. markForTrade posts the BringItemToDepot job that
-- `get_pending_trade_item_ids` reads, so the rows come up already ticked.
function select_now()
    local items, depot = candidates()
    if not depot then return 0 end
    local n = 0
    for _, item in ipairs(items) do
        local ok = pcall(dfhack.items.markForTrade, item, depot)
        if ok then n = n + 1 end
    end
    return n, depot
end

-- ---- the hook --------------------------------------------------------------
-- The screen reads its pending set once, in MoveGoodsModal:init. So the selection is made
-- just BEFORE that runs and the screen builds itself already knowing about it -- no reaching
-- into its cached choices afterwards, which is the part that would break on any DFHack
-- change. Same shape as plan-tile's hook on buildingplan's planner.

hooked = hooked or false

function install_hook()
    if hooked then return true end
    local ok, mg = pcall(reqscript, 'internal/caravan/movegoods')
    if not ok or type(mg) ~= 'table' or not mg.MoveGoodsModal then return false end
    local cls = mg.MoveGoodsModal
    local orig = cls.init
    if not orig then return false end
    cls.init = function(self, ...)
        if load_state().enabled then pcall(select_now) end
        return orig(self, ...)
    end
    hooked = true
    return true
end

-- ---- enable/disable --------------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

function set_enabled(on)
    load_state()
    enabled = on and true or false
    state.enabled = enabled
    save_state()
    if enabled then install_hook() end
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        enabled = state.enabled and true or false
        if enabled then install_hook() end
    elseif sc == SC_MAP_UNLOADED then
        state = nil
    end
end

if dfhack_flags.module then
    return
end

-- ---- command line ----------------------------------------------------------

if not dfhack.world.isFortressMode() then qerror('trade-again needs a loaded fort') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    if enabled and not hooked then
        dfhack.printerr('trade-again: could not hook the trade screen (is the caravan plugin loaded?)')
    end
    print('trade-again: ' .. (enabled and 'enabled -- the trade screen opens with your own depot goods selected'
                                      or 'disabled'))
    return
end

local args = {...}
local cmd = args[1]

if cmd == 'radius' then
    local n = tonumber(args[2])
    if not n or n < 0 then qerror('radius: give a number of tiles, 0 or more') end
    state.radius = math.floor(n)
    save_state()
    print(('trade-again: radius %d -- items up to %d tile%s from the depot centre')
        :format(state.radius, state.radius, state.radius == 1 and '' or 's'))
elseif cmd == 'status' then
    local items, depot = candidates()
    print(('trade-again: %s, radius %d'):format(enabled and 'ENABLED' or 'disabled', state.radius or 0))
    if not depot then
        print('  no finished trade depot in this fort')
    else
        print(('  depot at %d,%d,%d'):format(depot.centerx, depot.centery, depot.z))
        print(('  %d item%s would be selected'):format(#items, #items == 1 and '' or 's'))
        for i = 1, math.min(5, #items) do
            print('    ' .. dfhack.items.getReadableDescription(items[i]))
        end
        if #items > 5 then print(('    ...and %d more'):format(#items - 5)) end
    end
else
    local n, depot = select_now()
    if not depot then qerror('trade-again: no finished trade depot in this fort') end
    print(('trade-again: selected %d item%s for trade'):format(n, n == 1 and '' or 's'))
end
