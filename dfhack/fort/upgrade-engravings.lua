-- Re-cut engravings that came out less than masterful, until they come out masterful.
--@module = true
--@enable = true
--[[
fort/upgrade-engravings

An engraving's quality is set once, by whichever engraver happened to take the job, and there
is no way in the game to ask for another go. A wall that came out *Ordinary* stays Ordinary for
the life of the fortress, sitting in the middle of a corridor of Masterful ones.

This takes the wall down and starts again. Each tile goes round a loop:

  1. REMOVE     the wall is taken down -- a constructed wall by removal, a natural one by
                mining -- which destroys the engraving with it.
  2. REBUILD    once the tile is clear it is handed to `buildingplan` as a planned wall, using
                buildingplan's OWN stored Construction/Wall filter, exactly as
                `fort/dig-replace-walls` does. No material state is kept here.
  3. ENGRAVE    the finished wall is designated for engraving (`designation.smooth = 2`).
  4. JUDGE      when an engraving appears on the tile, its quality is read. Masterful, and the
                tile is done. Anything less, and it goes back to step 1.

SO THE COST IS UNBOUNDED, AND THAT IS THE POINT TO UNDERSTAND BEFORE RUNNING IT. Every lap
spends a block (or whatever your wall filter buys), a mining or removal job, a construction job
and an engraving job, and it buys a dice roll. Quality comes from the engraver DF picks, not
from anything here, so a fortress whose best engraver is Competent can loop forever and never
produce a Masterful anything. Hence `tries`: a tile that has failed that many times is given up
on and reported, rather than eating your stone forever. The default is 5.

WALLS ONLY. Of this fort's 1168 non-masterwork engraved walls, 1098 are constructed and 70 are
natural, and both are handled. Engraved FLOORS are skipped: a natural floor cannot be taken
down and rebuilt without channelling the level above, and that is a different (and much more
destructive) operation than this one.

MASTERFUL ENGRAVINGS ARE NEVER TOUCHED, which is the whole point -- and a tile is re-judged
from the engraving record itself, so a lucky lap is kept even if it lands while the manager is
not looking.

    upgrade-engravings                  open the painter (also in the dig-building picker)
    upgrade-engravings status           what is queued, and what is left to upgrade
    upgrade-engravings all [n]          queue up to n non-masterwork engraved walls (default 50)
    upgrade-engravings here             queue the wall under the cursor
    upgrade-engravings stop             stop the manager, leaving designations alone
    upgrade-engravings clear            forget every tile (designations are left as they are)
    enable upgrade-engravings           resume the manager on load
]]

local buildingplan = require('plugins.buildingplan')
local replace = reqscript('fort/dig-replace-walls')

local GLOBAL_KEY = 'upgrade-engravings'
local DV = df.tile_dig_designation
local SH = df.tiletype_shape
local TM = df.tiletype_material

-- FRAMES, not ticks: designating is mostly done paused, and a tick timer does not fire while
-- the game is paused -- the same reason `fort/dig-replace-walls` counts frames.
local CYCLE_FRAMES = 100
local MAX_WORK = 25             -- tiles advanced per cycle, so a big queue cannot stall a frame
local MAX_TRIES = 10   -- not configurable: see the header
local DEFAULT_BATCH = 50
local MASTERFUL = df.item_quality.Masterful

-- ---- tiles ------------------------------------------------------------------

local function pos(x, y, z) return {x = x, y = y, z = z} end
local function key(p) return ('%d,%d,%d'):format(p.x, p.y, p.z) end

local function attrs(p)
    local tt = dfhack.maps.getTileType(p)
    return tt and df.tiletype.attrs[tt] or nil
end

local function is_wall(p)
    local a = attrs(p)
    return a ~= nil and a.shape == SH.WALL and a.material ~= TM.TREE
end

local function is_clear(p)
    local a = attrs(p)
    if not a then return false end
    return a.shape == SH.FLOOR or a.shape == SH.PEBBLES or a.shape == SH.BOULDER
        or a.shape == SH.EMPTY
end

local function set_dig(p, val)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return false end
    blk.designation[p.x % 16][p.y % 16].dig = val
    blk.flags.designated = true
    return true
end

local function dig_val(p)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return DV.No end
    return blk.designation[p.x % 16][p.y % 16].dig
end

-- 0 none, 1 smooth, 2 engrave. DF CLEARS THIS THE MOMENT IT POSTS THE JOB, so a tile reading 0
-- has either never been designated or is already being worked -- it is not proof of either.
local function set_smooth(p, val)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return false end
    blk.designation[p.x % 16][p.y % 16].smooth = val
    blk.flags.designated = true
    return true
end

local function smooth_val(p)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return 0 end
    return blk.designation[p.x % 16][p.y % 16].smooth
end

-- ---- engravings -------------------------------------------------------------

-- The engraving record on a tile, or nil. Linear over the fort's engravings (1666 here), so it
-- is gated on the cheap tiletype test wherever it is called in a loop.
local function engraving_at(p)
    for _, e in ipairs(df.global.world.event.engravings) do
        if e.pos.x == p.x and e.pos.y == p.y and e.pos.z == p.z then return e end
    end
end

local function is_engraved_wall(p)
    local a = attrs(p)
    if not a or a.shape ~= SH.WALL or a.special ~= df.tiletype_special.SMOOTH then return false end
    return engraving_at(p) ~= nil
end

-- every wall in the fort carrying an engraving worse than Masterful
function candidates()
    local out = {}
    for _, e in ipairs(df.global.world.event.engravings) do
        if e.quality < MASTERFUL and not e.flags.hidden then
            local p = pos(e.pos.x, e.pos.y, e.pos.z)
            local a = attrs(p)
            if a and a.shape == SH.WALL then
                out[#out + 1] = {x = p.x, y = p.y, z = p.z, quality = e.quality}
            end
        end
    end
    table.sort(out, function(a, b) return a.quality < b.quality end)   -- worst first
    return out
end

-- ---- state ------------------------------------------------------------------
--
-- One record per tile: {x, y, z, phase, tries, from}. `from` is the quality it started at,
-- kept only so the report can say what was gained.

local function load_state()
    if not dfhack.isSiteLoaded() then return {tiles = {}} end
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, nil)
    if type(d) ~= 'table' or type(d.tiles) ~= 'table' then
        return {tiles = {}}
    end
    return d
end

local function save_state(st)
    if not dfhack.isSiteLoaded() then return end
    dfhack.persistent.saveSiteData(GLOBAL_KEY, st)
end

enabled = enabled or false
function isEnabled() return enabled end

-- ---- the loop ---------------------------------------------------------------

local function take_down(p)
    -- A completed construction is not a building -- DF drops the building once it is built --
    -- and `designateRemove` on one just sets `designation.dig`, the same flag a natural wall
    -- uses. So both kinds come down the same way, and both are cancelled the same way.
    if dfhack.constructions.findAtTile(p) then
        local ok = pcall(dfhack.constructions.designateRemove, p)
        if ok then return true end
    end
    return set_dig(p, DV.Default)
end

-- Plan a wall pinned to one exact item form and material, rather than to buildingplan's
-- current filter. `getFiltersByType` hands back SPARSE tables, so every field that matters is
-- written explicitly instead of trusting what is already there.
function plan_wall_as(p, was)
    local filters = dfhack.buildings.getFiltersByType({}, df.building_type.Construction,
                                                      df.construction_type.Wall, -1)
    if not filters or not filters[1] then return nil, 'no wall construction filters' end
    local f = filters[1]
    f.item_type, f.item_subtype = was.it, was.isub or -1
    f.mat_type, f.mat_index = was.mt, was.mi
    local ok, bld = pcall(dfhack.buildings.constructBuilding,
        {pos = pos(p.x, p.y, p.z), type = df.building_type.Construction,
         subtype = df.construction_type.Wall, custom = -1, filters = filters})
    if not ok or not bld then return nil, 'constructBuilding failed: ' .. tostring(bld) end
    local got, res = pcall(buildingplan.addPlannedBuilding, bld)
    if not got or res == false then return nil, 'buildingplan did not take the wall' end
    pcall(buildingplan.scheduleCycle)
    return bld
end

-- 'wait' | 'done' | 'give-up' (with a reason)
local function advance(rec, st)
    local p = pos(rec.x, rec.y, rec.z)

    if rec.phase == 'remove' then
        if is_clear(p) then rec.phase = 'build' return 'wait' end
        if not is_wall(p) then return 'give-up', 'the tile stopped being a wall' end
        -- re-designate only if the player has not taken it off; a cleared designation with no
        -- job posted is the player saying no, and it is not re-applied behind them
        if dig_val(p) == DV.No and not dfhack.constructions.findAtTile(p) then
            if rec.designated then return 'give-up', 'the dig was cancelled' end
            take_down(p)
            rec.designated = true
        elseif not rec.designated then
            take_down(p)
            rec.designated = true
        end
        return 'wait'

    elseif rec.phase == 'build' then
        local b = dfhack.buildings.findAtTile(p)
        if b and b:getType() == df.building_type.Construction then
            -- still going up; buildingplan owns it until it is finished
            return 'wait'
        end
        if is_wall(p) then rec.phase = 'engrave' return 'wait' end
        if not is_clear(p) then return 'give-up', 'the tile is neither clear nor a wall' end
        -- A WALL YOU BUILT COMES BACK AS THE WALL YOU BUILT. Re-cutting an engraving is not a
        -- request to change the fortress's masonry, so a microcline block wall is rebuilt in
        -- microcline blocks whatever the filter currently says. The filter governs the other
        -- case only: a SMOOTHED ROCK wall, which has no construction to copy, has to be
        -- rebuilt as something and that something is the player's choice.
        local bld, err
        if rec.was then
            bld, err = plan_wall_as(p, rec.was)
        else
            bld, err = replace.plan_wall(p)
        end
        if not bld then return 'wait', err end
        return 'wait'

    elseif rec.phase == 'engrave' then
        if not is_wall(p) then return 'give-up', 'the new wall is gone' end
        local e = engraving_at(p)
        if e then
            -- THE ONLY PLACE QUALITY IS JUDGED, and it is judged from the record rather than
            -- from anything this script remembers, so a lap that finished while the manager was
            -- not looking still counts.
            if e.quality >= MASTERFUL then return 'done' end
            rec.tries = (rec.tries or 0) + 1
            if rec.tries >= (MAX_TRIES) then
                return 'give-up', ('still %s after %d tries'):format(
                    df.item_quality[e.quality], rec.tries)
            end
            rec.phase = 'remove'
            rec.designated, rec.asked_smooth, rec.asked_engrave = false, false, false
            return 'wait'
        end

        -- NOTHING IS TORN DOWN UNTIL IT HAS BEEN JUDGED. A wall with no engraving yet has
        -- nothing wrong with it -- there is no masterpiece to beat and no evidence the
        -- engravers will do badly here -- so it gets its engraving first and is only
        -- replaced if that one comes out short. Painting a bare corridor therefore costs an
        -- engraving job and no stone at all, which is the cheapest thing it could do.
        local a = attrs(p)
        if a and a.special ~= df.tiletype_special.SMOOTH then
            -- rough rock cannot be engraved: it is smoothed first, which is a separate job
            if not rec.asked_smooth then set_smooth(p, 1); rec.asked_smooth = true end
            return 'wait'
        end
        -- Designated ONCE. DF clears `designation.smooth` the moment it posts the job, so
        -- re-asserting on every cycle would queue a second engraving behind the first.
        if not rec.asked_engrave then set_smooth(p, 2); rec.asked_engrave = true end
        return 'wait'
    end
    return 'give-up', 'unknown phase ' .. tostring(rec.phase)
end

running = running or false
generation = generation or 0

local function cycle(gen)
    if gen ~= generation or not dfhack.isMapLoaded() then running = false return end
    local st = load_state()
    local keep, worked = {}, 0
    for _, rec in ipairs(st.tiles) do
        local action, err = 'wait', nil
        if worked < MAX_WORK then
            worked = worked + 1
            action, err = advance(rec, st)
        end
        if action == 'done' then
            print(('upgrade-engravings (%d,%d,%d): masterful after %d %s'):format(
                rec.x, rec.y, rec.z, (rec.tries or 0) + 1,
                (rec.tries or 0) == 0 and 'try' or 'tries'))
        elseif action == 'give-up' then
            dfhack.printerr(('upgrade-engravings (%d,%d,%d): %s'):format(
                rec.x, rec.y, rec.z, err or 'given up'))
        else
            if err then
                dfhack.printerr(('upgrade-engravings (%d,%d,%d): %s'):format(
                    rec.x, rec.y, rec.z, err))
            end
            keep[#keep + 1] = rec
        end
    end
    st.tiles = keep
    save_state(st)
    if #keep == 0 then running = false return end
    dfhack.timeout(CYCLE_FRAMES, 'frames', function() cycle(gen) end)
end

-- Restarting is always safe: bumping the generation invalidates whatever chain was live, so
-- there is never more than one. `running` survives a script reload while the timeout chain
-- that set it does not, which is why it is never trusted as "already going".
function start()
    if not dfhack.isMapLoaded() then return end
    running = true
    generation = generation + 1
    local gen = generation
    dfhack.timeout(1, 'frames', function() cycle(gen) end)
end

function stop()
    running = false
    generation = generation + 1
end

-- ---- queueing ---------------------------------------------------------------

function queue(list)
    local st = load_state()
    local have = {}
    for _, r in ipairs(st.tiles) do have[key(r)] = true end
    local added = 0
    for _, c in ipairs(list) do
        if not have[key(c)] then
            -- 'engrave' is the entry phase for everything. A wall already carrying a bad
            -- engraving is judged on the first cycle and drops straight through to 'remove';
            -- a bare wall gets one cut first. One phase, both cases, no special casing.
            st.tiles[#st.tiles + 1] = {x = c.x, y = c.y, z = c.z,
                                       phase = 'engrave', tries = 0, from = c.quality,
                                       was = c.was}
            have[key(c)] = true
            added = added + 1
        end
    end
    save_state(st)
    if added > 0 then start() end
    return added
end

function clear()
    local st = load_state()
    local n = #st.tiles
    st.tiles = {}
    save_state(st)
    stop()
    return n
end

function set_enabled(on)
    enabled = on and true or false
    dfhack.persistent.saveSiteData(GLOBAL_KEY .. '/enabled', {on = enabled})
    if enabled then start() else stop() end
end

local function load_enabled()
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY .. '/enabled', nil)
    enabled = type(d) == 'table' and d.on == true
end

function status()
    local st = load_state()
    local left = candidates()
    print(('upgrade-engravings: %s, %d tile%s queued, %d tries allowed each'):format(
        enabled and 'enabled' or 'disabled', #st.tiles, #st.tiles == 1 and '' or 's',
        MAX_TRIES))
    local phases = {}
    for _, r in ipairs(st.tiles) do phases[r.phase] = (phases[r.phase] or 0) + 1 end
    for _, ph in ipairs{'remove', 'build', 'engrave'} do
        if phases[ph] then print(('   %-8s %d'):format(ph, phases[ph])) end
    end
    local byq = {}
    for _, c in ipairs(left) do byq[c.quality] = (byq[c.quality] or 0) + 1 end
    print(('   %d engraved wall%s in the fortress are not masterful:'):format(
        #left, #left == 1 and '' or 's'))
    for q = 0, MASTERFUL - 1 do
        if byq[q] then print(('      %-14s %d'):format(df.item_quality[q], byq[q])) end
    end
end

-- ---- the painter ---------------------------------------------------------------
--
-- Reached from the `fort/dig-building` picker, beside `Replace wall`, and it hits exactly the
-- walls that one does: a NATURAL rock/soil wall or a CONSTRUCTED wall, and nothing else. A
-- door, a statue, a floor, a tile with a building on it -- none of them are walls, so none of
-- them are painted.
--
-- Same gesture scheme as the rest of the repo's map tools (`fort/right-click-cancel`):
--   LEFT-DRAG            paint every wall in the box
--   LEFT-CLICK in place  one corner; the next click completes the box
--   RIGHT-DRAG           unpaint the box
--   RIGHT-CLICK in place unpaint that tile; on a bare tile it closes
--   Esc                  close

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')
local buildingplan = require('plugins.buildingplan')
local SETTINGS = {{'blocks'}, {'logs'}, {'boulders'}, {'bars'}}
local guidm = require('gui.dwarfmode')

painting = painting or false

local PAINT_TILE = dfhack.screen.findGraphicsTile('CURSORS', 1, 2)
local ERASE_TILE = dfhack.screen.findGraphicsTile('CURSORS', 0, 2)

local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

local function for_box(a, b, cb)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    if (x2 - x1 + 1) * (y2 - y1 + 1) > 10000 then return false end
    for x = x1, x2 do for y = y1, y2 do cb(pos(x, y, a.z)) end end
    return true
end

-- the same acceptance test `fort/dig-replace-walls` paints by
local function paintable(p)
    if not is_wall(p) then return false end
    local ok, b = pcall(dfhack.buildings.findAtTile, p)
    if ok and b then return false end            -- a door, a hatch, anything built here
    return true
end

-- WHAT A CONSTRUCTED WALL WAS MADE OF, read BEFORE it is taken down -- once the construction
-- is gone the record goes with it, so this has to happen at paint time, not at rebuild time.
-- nil for a natural wall, which never had a construction to copy.
function built_as(p)
    local con = dfhack.constructions.findAtTile(p)
    if not con then return nil end
    return {it = con.item_type, isub = con.item_subtype,
            mt = con.mat_type, mi = con.mat_index}
end

function queued_keys()
    local set = {}
    for _, r in ipairs(load_state().tiles) do set[key(r)] = true end
    return set
end

function paint_box(a, b)
    local found = {}
    local ok = for_box(a, b, function(p)
        if paintable(p) then
            local e = engraving_at(p)
            -- a masterful engraving is already what you are asking for: never painted, never
            -- torn down. Everything else goes in, engraved or bare.
            if not e or e.quality < MASTERFUL then
                found[#found + 1] = {x = p.x, y = p.y, z = p.z, quality = e and e.quality or nil,
                                     was = built_as(p)}
            end
        end
    end)
    if not ok then return 0, 'that box is too big' end
    return queue(found)
end

function erase_box(a, b)
    local st = load_state()
    local drop, n = {}, 0
    for_box(a, b, function(p) drop[key(p)] = true end)
    local keep = {}
    for _, r in ipairs(st.tiles) do
        if drop[key(r)] then n = n + 1 else keep[#keep + 1] = r end
    end
    st.tiles = keep
    save_state(st)
    return n
end

-- NO WHOLE-FORTRESS SCAN. There was one, and it walked every tile of every map block
-- looking for unhidden walls. It FROZE THE GAME -- DFHack lua runs on DF's own main thread,
-- so a sweep of that size is not slow, it is a hang, and the fort stops until it finishes.
--
-- There is no cheap index of bare walls to replace it with: `world.event.engravings` knows
-- every engraved tile in the fortress (1666 of them here, read in milliseconds) but by
-- definition knows nothing about walls that have never been engraved. So the two ways in are
-- the painter, which is bounded by the box you drag, and "the worst N", which is bounded by
-- the engravings list. Both are cheap; neither pretends to cover walls nobody has touched.

UpgradePanel = defclass(UpgradePanel, overlay.OverlayWidget)
UpgradePanel.ATTRS{
    desc = 'Paint walls whose engravings should be re-cut until they come out masterful.',
    default_pos = {x = 2, y = 6},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 42, h = 15},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function UpgradePanel:init()
    self.visible = function() return painting end
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, w = 42, h = 15},
            frame_style = gui.FRAME_PANEL,
            frame_background = gui.CLEAR_PEN,
            frame_title = 'Upgrade engravings',
            subviews = {
                widgets.Label{view_id = 'count', frame = {t = 0, l = 0}, text = ''},
                widgets.Label{frame = {l = 0, t = 2}, text = 'Smoothed rock rebuilds as:'},
                widgets.WrappedLabel{
                    frame = {l = 0, t = 3, h = 2, r = 0},
                    text_pen = COLOR_LIGHTCYAN,
                    text_to_wrap = function() return self.summary or '' end,
                    auto_height = false,
                },
                widgets.HotkeyLabel{
                    frame = {l = 0, t = 5}, key = 'CUSTOM_F',
                    label = 'Set/Edit filter',
                    on_activate = function() self:edit_filter() end,
                },
                -- WORST FIRST is the useful default: an Ordinary engraving in a corridor of
                -- Masterful ones is the one that spoils the room, and re-cutting it costs the
                -- same as re-cutting an Exceptional one.
                widgets.ToggleHotkeyLabel{view_id = 'blocks', frame = {l = 0, t = 6},
                    key = 'CUSTOM_B', label = 'Blocks', label_width = 9,
                    on_change = function(v) self:set_setting('blocks', v) end},
                widgets.ToggleHotkeyLabel{view_id = 'logs', frame = {l = 0, t = 7},
                    key = 'CUSTOM_L', label = 'Logs', label_width = 9,
                    on_change = function(v) self:set_setting('logs', v) end},
                widgets.ToggleHotkeyLabel{view_id = 'boulders', frame = {l = 0, t = 8},
                    key = 'CUSTOM_O', label = 'Boulders', label_width = 9,
                    on_change = function(v) self:set_setting('boulders', v) end},
                widgets.ToggleHotkeyLabel{view_id = 'bars', frame = {l = 0, t = 9},
                    key = 'CUSTOM_R', label = 'Bars', label_width = 9,
                    on_change = function(v) self:set_setting('bars', v) end},
                -- WORST FIRST is the useful default: an Ordinary engraving in a corridor of
                -- Masterful ones is the one that spoils the room.
                widgets.HotkeyLabel{
                    frame = {t = 11, l = 0}, key = 'CUSTOM_Q',
                    label = 'The 50 worst engravings',
                    on_activate = function() self:worst(50) end,
                },
                widgets.HotkeyLabel{
                    frame = {t = 12, l = 0}, key = 'CUSTOM_C',
                    label = 'Forget the queue',
                    on_activate = function() clear(); self:refresh() end,
                },
            },
        },
    }
end

function UpgradePanel:worst(n)
    local list = candidates()
    local take = {}
    for i = 1, math.min(n, #list) do take[i] = list[i] end
    local added = queue(take)
    dfhack.gui.showAnnouncement(
        ('Upgrade engravings: %d queued, worst first (%d not masterful in all).'):format(
            added, #list), COLOR_LIGHTCYAN)
    self:refresh()
end

function UpgradePanel:refresh()
    local st = load_state()
    local bare, bad = 0, 0
    for _, r in ipairs(st.tiles) do
        if r.from == nil then bare = bare + 1 else bad = bad + 1 end
    end
    self.subviews.count:setText{
        {text = ('%d queued'):format(#st.tiles), pen = COLOR_WHITE}, NEWLINE,
        {text = ('%d to re-cut, %d never engraved'):format(bad, bare), pen = COLOR_GREY},
    }
end

function UpgradePanel:open()
    self.summary = replace.filter_summary()
    self:refresh_settings()
    self:cancel_drag()
    -- DISARM DF'S DESIGNATION TOOL while we are up, and put it back on the way out.
    --
    -- This painter is opened from `fort/dig-building` with the Dig tool still armed on the map
    -- underneath. Our clicks are swallowed here, but the repo's other map tools poll the mouse
    -- straight from the overlay pump and have no idea anything else has the map --
    -- `fort/right-click-cancel` completes a dig box on the release that ended a paint drag,
    -- leaving a mining designation behind on the last tile. With no tool selected there is
    -- nothing for DF or for them to act on. Straight from `fort/dig-replace-walls`.
    local mi = df.global.game.main_interface
    self.saved_tool = mi.main_designation_selected
    mi.main_designation_selected = df.main_designation_type.NONE
    -- THE CLICK THAT OPENED US IS STILL HELD. Without seeding the button state from it, the
    -- release of that very click reads as the end of a drag and paints whatever the cursor
    -- happened to be over -- "it does actions when you start your drag".
    self.lbut, self.rbut = df.global.enabler.mouse_lbut_down, df.global.enabler.mouse_rbut_down
    painting = true
    self:refresh()
end

function UpgradePanel:close()
    painting = false
    self:cancel_drag()
    if self.saved_tool then
        df.global.game.main_interface.main_designation_selected = self.saved_tool
        self.saved_tool = nil
    end
end

-- ---- what the rebuilt wall is made of ----------------------------------------
--
-- The same buildingplan filter `fort/dig-replace-walls` uses, edited through the same dialog:
-- a wall re-cut for its engraving is rebuilt exactly as a wall placed by hand would be. No
-- material state is kept here either -- change it in one place and you have changed both.

function UpgradePanel:refresh_settings()
    local ok, settings = pcall(buildingplan.getGlobalSettings)
    if not ok or not settings then return end
    for _, sname in ipairs(SETTINGS) do
        local w = self.subviews[sname[1]]
        if w and settings[sname[1]] ~= nil then w:setOption(settings[sname[1]]) end
    end
end

function UpgradePanel:set_setting(name, val)
    pcall(buildingplan.setSetting, name, val)
    self:refresh_settings()
end

function UpgradePanel:edit_filter()
    self:cancel_drag()
    replace.WallFilterScreen{on_close = function()
        self.summary = replace.filter_summary()
        self:refresh_settings()
    end}:show()
end

function UpgradePanel:cancel_drag()
    self.press, self.mode, self.corner = nil, nil, nil
end

function UpgradePanel:anchor() return self.corner or self.press end

function UpgradePanel:map_pos_if_clear()
    local p = dfhack.gui.getMousePos()
    if not p then return nil end
    if self:getMouseFramePos() then return nil end
    local m = df.global.game.main_interface
    if m.current_hover ~= -1 or m.current_hover_alert then return nil end
    return p
end

function UpgradePanel:apply(a, b, mode)
    if mode == 'erase' then
        erase_box(a, b)
    else
        local n, err = paint_box(a, b)
        if err then
            dfhack.gui.showAnnouncement('Upgrade engravings: ' .. err, COLOR_LIGHTRED)
        elseif n == 0 then
            dfhack.gui.showAnnouncement(
                'Upgrade engravings: no walls there that are not already masterful.',
                COLOR_YELLOW)
        end
    end
    self:refresh()
end

function UpgradePanel:on_release(rel, mode)
    local a = self:anchor()
    if not a or not rel or a.z ~= rel.z then self:cancel_drag() return end
    if not same(self.press or a, rel) then
        self:apply(a, rel, mode); self:cancel_drag()
    elseif self.corner then
        self:apply(self.corner, rel, mode); self:cancel_drag()
    else
        self.corner, self.mode = rel, mode
        self.press = nil
    end
end

function UpgradePanel:overlay_onupdate()
    if not painting then return end
    local foc = dfhack.gui.getCurFocus(true)[1] or ''
    local e = df.global.enabler
    local l, r = e.mouse_lbut_down, e.mouse_rbut_down
    if foc:sub(1, 9) ~= 'dwarfmode' then
        self.lbut, self.rbut = l, r
        self:cancel_drag()
        return
    end
    if l == 1 and self.lbut ~= 1 then
        if self.mode == 'erase' and self.press then self:cancel_drag(); self.ate = true
        else self.ate = false; self.press = self:map_pos_if_clear(); self.mode = 'paint' end
    elseif l ~= 1 and self.lbut == 1 then
        if not self.ate and self.press then self:on_release(dfhack.gui.getMousePos(), 'paint') end
        self.ate = false
    end
    self.lbut = l
    if r == 1 and self.rbut ~= 1 then
        if self:anchor() and self.mode ~= 'erase' then self:cancel_drag(); self.rate = true
        else self.rate = false; self.press = self:map_pos_if_clear(); self.mode = 'erase' end
    elseif r ~= 1 and self.rbut == 1 then
        if not self.rate and self.press then
            local rel = dfhack.gui.getMousePos()
            if rel and same(self.press, rel) and not self.corner then
                self:cancel_drag()
                if queued_keys()[key(rel)] then erase_box(rel, rel); self:refresh()
                else self:close() end
            else
                self:on_release(rel, 'erase')
            end
        end
        self.rate = false
    end
    self.rbut = r
end

function UpgradePanel:onInput(keys)
    if not painting then return false end
    if keys.LEAVESCREEN then
        if self:anchor() then self:cancel_drag() return true end
        self:close()
        return true
    end
    if (keys._MOUSE_L or keys._MOUSE_R) and self:getMouseFramePos() then
        return UpgradePanel.super.onInput(self, keys)
    end
    if keys._MOUSE_L or keys._MOUSE_R then
        return self:map_pos_if_clear() ~= nil
    end
    return UpgradePanel.super.onInput(self, keys)
end

-- the drag box and the queued tiles, drawn through DF's OWN map layer rather than stamped over
-- the finished frame, so they sit under menus instead of on top of them
function UpgradePanel:onRenderFrame(dc, rect)
    UpgradePanel.super.onRenderFrame(self, dc, rect)
    if not painting then return end
    local vp = guidm.Viewport.get()
    local gvp = df.global.gps.main_viewport
    if not vp or not gvp then return end
    local dimx, dimy = gvp.dim_x, gvp.dim_y
    if dimx <= 0 or dimy <= 0 then return end
    local arr, arr_old = gvp.screentexpos_interface, gvp.screentexpos_interface_old
    local function mark(p, tile)
        if not tile or p.z ~= vp.z then return end
        local vx, vy = p.x - vp.x1, p.y - vp.y1
        if vx >= 0 and vy >= 0 and vx < dimx and vy < dimy then
            local at = vx * dimy + vy
            arr[at], arr_old[at] = tile, tile
        end
    end
    for _, r in ipairs(load_state().tiles) do mark(r, PAINT_TILE) end
    local a = self:anchor()
    if not a then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= a.z then return end
    for_box(a, cur, function(p)
        mark(p, self.mode == 'erase' and ERASE_TILE or PAINT_TILE)
    end)
end

OVERLAY_WIDGETS = {panel = UpgradePanel}

local function panel_widget()
    local w = overlay.get_state().db['fort/upgrade-engravings.panel']
    return w and w.widget or nil
end

function show()
    if not dfhack.isMapLoaded() then qerror('a fortress map must be loaded') end
    local w = panel_widget()
    if not w then qerror('the fort/upgrade-engravings.panel overlay is not loaded') end
    w:open()
    return true
end

function hide()
    local w = panel_widget()
    if w then w:close() else painting = false end
end

function is_open() return painting end

-- ---- lifecycle ---------------------------------------------------------------

-- A QUEUE WITH NO MANAGER IS A QUEUE THAT NEVER MOVES, and it looks exactly like an endless
-- job: the tiles sit there with their engrave designations already placed, and nothing ever
-- judges the result or starts the next lap.
--
-- The driver is a `dfhack.timeout` chain, and a chain belongs to the copy of this script that
-- created it. A hot reload leaves the new copy with `running = false` and the old chain
-- orphaned, so the queue froze every time this file was redeployed -- which during development
-- was constantly. `enabled` must not gate this either: the QUEUE is the state that matters,
-- and having tiles in it is reason enough to be running.
local function resume_if_work()
    if not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then return end
    if #load_state().tiles > 0 then start() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        load_enabled()
        resume_if_work()
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

if dfhack_flags and dfhack_flags.module then
    resume_if_work()        -- take the queue over from the copy this reload replaced
    return
end

if not dfhack.world.isFortressMode() then
    qerror('upgrade-engravings only works in fortress mode')
end
load_enabled()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('upgrade-engravings: ' .. (enabled and 'ENABLED' or 'disabled'))
    return
end

local args = {...}
local cmd = args[1]

if cmd == 'all' then
    local n = tonumber(args[2]) or DEFAULT_BATCH
    local list = candidates()
    local take = {}
    for i = 1, math.min(n, #list) do take[i] = list[i] end
    local added = queue(take)
    print(('upgrade-engravings: queued %d of %d non-masterful engraved walls (worst first).')
        :format(added, #list))
    if #list > added then
        print(('   %d more remain; run again to take another batch.'):format(#list - added))
    end
elseif cmd == 'here' then
    local p = df.global.cursor
    if not p or p.x < 0 then qerror('put the cursor on an engraved wall first') end
    local t = pos(p.x, p.y, p.z)
    if not is_engraved_wall(t) then qerror('that tile is not an engraved wall') end
    local e = engraving_at(t)
    if e.quality >= MASTERFUL then qerror('that engraving is already masterful') end
    print(('upgrade-engravings: queued %d tile (was %s).'):format(
        queue{{x = t.x, y = t.y, z = t.z, quality = e.quality}}, df.item_quality[e.quality]))
elseif cmd == 'stop' then
    stop()
    print('upgrade-engravings: manager stopped; designations left alone.')
elseif cmd == 'clear' then
    print(('upgrade-engravings: forgot %d queued tile(s).'):format(clear()))
elseif cmd == 'status' then
    status()
else
    show()
    print('upgrade-engravings: painter open -- drag a box over the walls you want re-cut.')
end
