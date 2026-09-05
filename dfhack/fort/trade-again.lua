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
    year's purchases back to this year's merchants is almost never what you meant. EXCEPT
    loot: foreign gear made by a race whose civs are all at war with you is siege plunder, not
    a purchase, and that is exactly what you want to sell. See `hostile_races` below for how
    close a guess that is.
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

THE WINDOW ITSELF opens at the FULL height of the interface rather than DFHack's fixed 46
rows -- on a tall screen that is a lot of list you were paging through for nothing -- and at
whatever width you last resized it to, which it records for you.

    enable trade-again      pre-select as the screen opens (persists with the fort)
    disable trade-again     stop
    trade-again             select them right now, without opening the screen
    trade-again radius N    how far from the depot counts (default 0)
    trade-again loot on|off include gear made by civs you are AT WAR with (default on)
    trade-again status      what is set, and what would be selected
]]

local gui = require('gui')

local GLOBAL_KEY = 'trade-again'

-- ---- state -----------------------------------------------------------------

state = state or nil

local function default_state()
    -- width: recorded by the window itself, see below
    return {enabled = false, radius = 0, loot = true}
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

-- ---- loot from the people you are actually fighting -------------------------
--
-- `flags.foreign` only says "another civ made this", which is one word for two very different
-- things: goods you bought, and gear you stripped off a siege. DF keeps no "I looted this"
-- bit, so the closest honest proxy is the MAKER'S RACE (`item.maker_race`, recorded on
-- foreign goods) matched against the civs you are at war with right now -- `relation == 1`
-- with a live `war_event_collection` in your civ's own diplomacy table.
--
-- TWO DELIBERATE NARROWINGS, both to stop bought goods being swept in:
--   * your own civ's race never counts. Your civ appears in its own war list here (this fort
--     has been in a CIVIL WAR since year 102), and dwarf-made foreign goods are mostly
--     migrants' gear.
--   * a race that has TRADED here within the last ten years never counts, war or no war. That
--     is the only thing that actually puts bought goods in your stock, and it is read from the
--     fort's own MERCHANT history rather than guessed. (Requiring instead that every civ of a
--     race be at war -- the first thing tried -- excluded everyone: with dozens of civs per
--     race there is always a peaceful one somewhere in the world.)
--
-- It is a race-level guess and it says so; there is no item-level truth to read.
local hostile_cache, hostile_cache_at = nil, 0

function hostile_races()
    local now = dfhack.getTickCount()
    if hostile_cache and now - hostile_cache_at < 10000 then return hostile_cache end
    local out = {}
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not civ then return out end
    local at_war = {}
    local ok = pcall(function()
        for _, s in ipairs(civ.relations.diplomacy.state) do
            local other = df.historical_entity.find(s.group_id)
            if other and other.race >= 0 and s.group_id ~= civ.id then
                if s.relation == 1 and s.war_event_collection >= 0 then
                    at_war[other.race] = true
                end
            end
        end
    end)
    if not ok then return out end
    -- races whose caravans have actually come here lately: their goods are purchases
    local traded, site = {}, df.global.plotinfo.site_id
    local ev = df.global.world.history.events
    local cutoff = df.global.cur_year - 10
    for i = #ev - 1, math.max(0, #ev - 20000), -1 do
        local e = ev[i]
        local okv = pcall(function()
            if df.history_event_type[e:getType()] == 'MERCHANT' and e.site == site and e.year >= cutoff then
                local src = df.historical_entity.find(e.source)
                if src and src.race >= 0 then traded[src.race] = true end
            end
        end)
    end
    for race in pairs(at_war) do
        if race ~= civ.race and not traded[race] then out[race] = true end
    end
    hostile_cache, hostile_cache_at = out, now
    return out
end

local function is_loot(item, hostile)
    local mr = -1
    pcall(function() mr = item.maker_race end)
    return mr >= 0 and hostile[mr] or false
end

local function eligible(item, depot, radius, is_banned, hostile)
    local f = item.flags
    if f.forbid or f.artifact or f.garbage_collect or f.removed
        or f.hostile or f.owned or f.trader or f.in_job then
        return false
    end
    -- foreign goods are skipped unless they are loot off a civ you are at war with
    if f.foreign and not (hostile and is_loot(item, hostile)) then return false end
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
    local hostile = state.loot and hostile_races() or nil
    local out = {}
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if eligible(item, depot, radius, is_banned, hostile) then out[#out + 1] = item end
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

-- ---- the window's shape ----------------------------------------------------
--
-- The screen opens 46 rows tall whatever your screen is, so on a tall terminal you page
-- through a list that had room to show itself. So it opens at the FULL height of the
-- interface instead, and at whatever width you last left it: the window records its own width
-- as you resize it, so the shape you settle on is the shape it comes back at. Height is not
-- remembered on purpose -- full height is the point.
--
-- Both hooks are on the class, so an instance that is already open picks them up on its next
-- layout (methods resolve through the class table at call time).

local function full_height()
    local ok, ir = pcall(gui.get_interface_rect)
    if not ok or not ir then return nil end
    local h = (ir.height or (ir.y2 - ir.y1 + 1))
    if type(h) ~= 'number' or h < 20 then return nil end
    return h
end

-- Re-installable on purpose. The class object outlives a script reload, so a plain "already
-- hooked" flag freezes whatever version happened to land first -- which is how a width hook
-- kept running after it had been rewritten to do height. The originals are stashed on the
-- class and the wrappers rebuilt whenever this file's HOOK_VERSION moves.
local HOOK_VERSION = 2

function install_window_hook()
    local ok, mg = pcall(reqscript, 'internal/caravan/movegoods')
    if not ok or type(mg) ~= 'table' or not mg.MoveGoods then return false end
    local cls = mg.MoveGoods
    if cls.trade_again_hook_version == HOOK_VERSION then return true end

    -- first time through, keep the untouched methods; afterwards rewrap those, never a wrapper
    if not cls.trade_again_orig then
        cls.trade_again_orig = {init = cls.init, layout = cls.postUpdateLayout, render = cls.render}
    end
    local orig = cls.trade_again_orig

    -- ATTRS.frame is SHARED with every instance's self.frame -- writing a field on it edits
    -- the class default for the rest of the session (this is how DFHack's own 86 became 192).
    -- So the frame is copied before anything is set on it.
    cls.init = function(self, ...)
        local r = orig.init and orig.init(self, ...) or nil
        if load_state().enabled then
            local f = {}
            for k, v in pairs(self.frame or {}) do f[k] = v end
            f.h = full_height() or f.h
            if type(state.width) == 'number' and state.width > 40 then f.w = state.width end
            self.frame = f
        end
        return r
    end

    -- remember the width you resize it to. postUpdateLayout catches a resize; render catches
    -- the window that is ALREADY open when this hook goes in, which is the one whose width
    -- you actually want kept. Both are a number comparison and only write when it changes.
    local function remember(self)
        local w = self.frame and self.frame.w
        if type(w) == 'number' and w > 40 and load_state().width ~= w then
            state.width = w
            save_state()
        end
    end

    cls.postUpdateLayout = function(self, ...)
        remember(self)
        if orig.layout then return orig.layout(self, ...) end
    end

    if orig.render then
        cls.render = function(self, ...)
            remember(self)
            return orig.render(self, ...)
        end
    end

    cls.trade_again_hook_version = HOOK_VERSION
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
    if enabled then install_hook(); install_window_hook() end
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        enabled = state.enabled and true or false
        if enabled then install_hook(); install_window_hook() end
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
install_window_hook()

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
elseif cmd == 'loot' then
    local on = args[2]
    if on ~= 'on' and on ~= 'off' then qerror('loot: say `on` or `off`') end
    state.loot = (on == 'on')
    save_state()
    local hostile = state.loot and hostile_races() or {}
    local names = {}
    for race in pairs(hostile) do
        local r = df.creature_raw.find(race)
        names[#names + 1] = r and r.creature_id or ('race ' .. race)
    end
    table.sort(names)
    print(('trade-again: loot %s%s'):format(on,
        state.loot and (' -- gear made by ' .. (#names > 0 and table.concat(names, ', ') or 'nobody: you are at war with no one')) or ''))
elseif cmd == 'status' then
    local items, depot = candidates()
    print(('trade-again: %s, radius %d, loot %s, window %s wide x %s high'):format(
        enabled and 'ENABLED' or 'disabled', state.radius or 0, state.loot and 'on' or 'off',
        tostring(state.width or 'DFHack default'), tostring(full_height() or '?')))
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
