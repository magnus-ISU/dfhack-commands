-- Track stop panel: which cart is on this route, where it is, and two buttons that finish the job.
--@module = true
--[[
fort/better-track-stops

A track stop's own sheet tells you its friction and its dump direction and nothing about the
thing that makes it work: the minecart. Whether one is assigned, where it has got to, whether
a dwarf is carrying it across the fort right now -- all of that lives on the Hauling screen, two
menus away, and a stop with no cart looks exactly like a stop with one.

This puts it on the stop, next to a pair of buttons for the two jobs you were about to go and
do by hand:

  * THE CART, AND WHERE IT IS. The route this stop belongs to, the cart assigned to it, what is
    in it (833 lava is not the same cart as an empty one), and its whereabouts: at the stop, on
    the rails N tiles away, or being carried by a named dwarf -- a cart in somebody's arms
    reports where THEY are, which is the honest answer to "where is my minecart". Click the
    line and the map goes there.

  * ASSIGN: [Lava] [Water] [Empty]. One button per KIND of cart, and each is shown only while
    the fort actually has one that can reach this stop -- a button for a cart that does not
    exist is a button that can only disappoint. Reachability is DF's own walkability groups,
    the same test the vehicle picker's "Inaccessible from first stop" comes from, so a cart in
    a sealed magma pit is never offered.

  * MAKE A QUANTUM STOCKPILE. With exactly one stockpile touching the stop, this finishes the
    classic quantum stockpile in one press: it links that pile to the route stop as its source,
    places a 1x1 catch-all stockpile on the tile the stop dumps into, and assigns an empty cart.
    It refuses when the adjacency is ambiguous (no pile, or more than one) rather than guessing
    which pile you meant, and it will not overwrite a building already standing on the dump
    tile.

WHAT IT DOES NOT DO is invent a route. A stop that DF has not put on a route yet has nothing to
assign a cart to, and saying so is more use than quietly creating one behind your back; the
quantum button does create the route it needs, because that is the point of pressing it.

Registered automatically as overlay `fort/better-track-stops.panel`.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')
local widgets = require('gui.widgets')

-- ---- the stop, its route, its cart -------------------------------------------

local function sheet_building()
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.BUILDING then return nil end
    local b = df.building.find(vs.viewing_bldid)
    if b and b:getType() == df.building_type.Trap and b.trap_type == df.trap_type.TrackStop then
        return b
    end
end

-- the hauling route stop standing on this building, if DF has one
local function stop_of(bld)
    for _, r in ipairs(df.global.plotinfo.hauling.routes) do
        for _, st in ipairs(r.stops) do
            if st.pos.x == bld.centerx and st.pos.y == bld.centery and st.pos.z == bld.z then
                return r, st
            end
        end
    end
end

local function vehicle_by_id(id)
    for _, v in ipairs(df.global.world.vehicles.all) do
        if v.id == id then return v end
    end
end

local function distance(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) + math.abs(a.z - b.z)
end

-- what is in a cart, as `833 lava`, or nil for an empty one
local LIQUID_WORD = {magma = 'lava'}

local function cart_liquid(item)
    local ok, contents = pcall(dfhack.items.getContainedItems, item)
    if not ok or not contents then return nil end
    for _, c in ipairs(contents) do
        if c:getType() == df.item_type.LIQUID_MISC then
            local name
            pcall(function()
                local mi = dfhack.matinfo.decode(c)
                name = mi and mi.material.state_name.Liquid
            end)
            if name and name ~= '' then
                return ('%d %s'):format(c.stack_size or 0, LIQUID_WORD[name] or name)
            end
        end
    end
end

-- Where the cart actually is, and who has it. A hauled cart lives in a dwarf's inventory and
-- its own `pos` goes stale there -- `getPosition` follows the holder, which is the only answer
-- worth printing.
local function cart_whereabouts(item, stop_pos)
    local x, y, z = dfhack.items.getPosition(item)
    if not x or x < 0 then return nil, nil, 'nowhere the fort can see' end
    local pos = xyz2pos(x, y, z)
    local holder = dfhack.items.getGeneralRef(item, df.general_ref_type.UNIT_HOLDER)
    local unit = holder and df.unit.find(holder.unit_id) or nil
    local d = distance(pos, stop_pos)
    if unit then
        -- the NAME, not the readable name: "Bim Azuzmeng" fits the window, whereas
        -- `Bim Azuzmeng "Somberlashes", Farmer` runs off the end of it mid-word
        local who = dfhack.translation.translateName(dfhack.units.getVisibleName(unit))
        if who == '' then who = dfhack.units.getReadableName(unit) end
        return pos, unit, ('carried by %s, %d tile%s away'):format(who, d, d == 1 and '' or 's')
    end
    if d == 0 then return pos, nil, 'at the stop' end
    return pos, nil, ('%d tile%s away'):format(d, d == 1 and '' or 's')
end

-- ---- picking a cart ----------------------------------------------------------

local function walk_group(pos)
    if not pos then return nil end
    local g = dfhack.maps.getWalkableGroup(pos)
    if not g or g == 0 then return nil end
    return g
end

local function liquid_rank(word)
    if not word then return 0 end
    if word:find('lava') then return 3 end
    if word:find('water') then return 2 end
    return 1
end

-- Every cart the fort could hitch to this stop: free (or on this very route), and standing
-- where a dwarf can walk to the stop from. Best first -- lava, then water, then empty.
function candidates(bld, route)
    local sg = walk_group(xyz2pos(bld.centerx, bld.centery, bld.z))
    local out = {}
    for _, v in ipairs(df.global.world.vehicles.all) do
        if v.route_id < 0 or (route and v.route_id == route.id) then
            local item = df.item.find(v.item_id)
            if item then
                local x, y, z = dfhack.items.getPosition(item)
                local g = (x and x >= 0) and walk_group(xyz2pos(x, y, z)) or nil
                if not sg or g == sg then
                    local liquid = cart_liquid(item)
                    out[#out + 1] = {vehicle = v, item = item, liquid = liquid,
                                     rank = liquid_rank(liquid)}
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.vehicle.id < b.vehicle.id
    end)
    return out
end

-- Hitch a cart to a route, the way DFHack's own assign-minecarts does it: the route's old carts
-- are released first, since a route holds one cart and a cart belongs to one route.
local function assign_cart(route, vehicle)
    for _, id in ipairs(route.vehicle_ids) do
        local old = vehicle_by_id(id)
        if old then old.route_id = -1 end
    end
    route.vehicle_ids:resize(0)
    route.vehicle_stops:resize(0)
    route.vehicle_ids:insert('#', vehicle.id)
    route.vehicle_stops:insert('#', 0)
    vehicle.route_id = route.id
end

-- ---- the quantum half --------------------------------------------------------

-- the stockpiles touching this stop, orthogonally, on its own level
local function adjacent_stockpiles(bld)
    local seen, out = {}, {}
    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
        local p = xyz2pos(bld.centerx + d[1], bld.centery + d[2], bld.z)
        local at = dfhack.buildings.findAtTile(p)
        if at and at:getType() == df.building_type.Stockpile and not seen[at.id] then
            seen[at.id] = true
            out[#out + 1] = at
        end
    end
    return out
end

-- the tile this stop throws its load onto
local function dump_pos(bld)
    local info = bld.track_stop_info
    return xyz2pos(bld.centerx + info.dump_x_shift, bld.centery + info.dump_y_shift, bld.z)
end

local function make_route_for(bld)
    local hauling = df.global.plotinfo.hauling
    hauling.routes:insert('#', {new = df.hauling_route, id = hauling.next_id,
                                name = ('Quantum %d'):format(hauling.next_id)})
    hauling.next_id = hauling.next_id + 1
    local route = hauling.routes[#hauling.routes - 1]
    route.stops:insert('#', {new = df.hauling_stop, id = 1,
                             pos = xyz2pos(bld.centerx, bld.centery, bld.z)})
    local stop = route.stops[0]
    -- the stop takes everything, which is what a quantum dumper is for
    pcall(function()
        require('plugins.stockpiles').import_settings('library/everything',
            {route_id = route.id, stop_id = stop.id, mode = 'set'})
    end)
    return route, stop
end

local function link_feeder(stop, pile)
    for _, l in ipairs(stop.stockpiles) do
        if l.building_id == pile.id then return false end     -- already linked
    end
    stop.stockpiles:insert('#', {new = df.route_stockpile_link,
                                 building_id = pile.id, mode = {take = true}})
    pile.linked_stops:insert('#', stop)
    return true
end

-- The catch-all pile the cart dumps into. Placed through quickfort's own `place` blueprint --
-- `quantum=true` is what turns off bins, barrels and wheelbarrows on it, and getting that
-- wrong by hand means a quantum pile that quietly hoards containers.
local function quantum_data(name)
    return ('ry{name="%s" quantum=true}:+all'):format(name)
end

-- CAN a stockpile stand on the dump tile? Asked with quickfort's own dry run, because the
-- answer is not obvious from the map: the first stop tried had a RAMP TOP under its dump
-- shift, which is walkable, looks clear, and cannot hold a pile. Asked BEFORE anything is
-- linked or created, so a refusal leaves the fort exactly as it was.
local function dump_tile_ok(pos, name)
    local quickfort = reqscript('quickfort')
    local ok, stats = pcall(quickfort.apply_blueprint,
                            {mode = 'place', pos = pos, data = quantum_data(name), dry_run = true})
    if not ok then return false, tostring(stats) end
    local n = stats and stats.place_designated and stats.place_designated.value or 0
    if n > 0 then return true end
    local tt = dfhack.maps.getTileType(pos)
    return false, ('no stockpile can stand on the dump tile (%s)')
        :format(tt and tostring(df.tiletype[tt]) or 'unknown tile')
end

local function place_quantum_pile(pos, name)
    local quickfort = reqscript('quickfort')
    local ok, stats = pcall(quickfort.apply_blueprint,
                            {mode = 'place', pos = pos, data = quantum_data(name)})
    if not ok then return false, tostring(stats) end
    local n = stats and stats.place_designated and stats.place_designated.value or 0
    if n == 0 then return false, 'nothing could be placed on the dump tile' end
    return true
end

-- ---- the panel ---------------------------------------------------------------

TrackStopPanel = defclass(TrackStopPanel, overlay.OverlayWidget)
TrackStopPanel.ATTRS{
    desc = 'Track stop: shows its minecart and where it is, assigns one, or makes it quantum.',
    -- MEASURED OFF THE SCREEN, not guessed. DF's track stop window runs x 94..154 and
    -- DFHack's own trackstop overlay (Ctrl+x dump, Ctrl+f friction) sits at rows 31..34 under
    -- it. This sits INSIDE those edges -- one column in on each side, 59 wide -- so its frame
    -- never draws over the window's own border, and its bottom edge is row 29, clear of
    -- DFHack's buttons below.
    default_pos = {x = 96, y = 22},
    default_enabled = true,
    -- broad, like the repo's other selector-screen tools: a narrow sub-focus match does not
    -- instantiate reliably here, and every pass is gated on a track stop's sheet being open
    viewscreens = 'dwarfmode',
    frame = {w = 59, h = 9},
    frame_style = gui.FRAME_MEDIUM,
    frame_title = 'Track stop',
    frame_background = dfhack.pen.parse{ch = ' ', fg = COLOR_BLACK, bg = COLOR_BLACK},
    overlay_onupdate_max_freq_seconds = 0.2,
    visible = function() return sheet_building() ~= nil end,
    version = 1,
}

function TrackStopPanel:init()
    self:addviews{
        -- EXPLICIT HEIGHT, AND auto_height OFF. A Label sizes itself to its content when it
        -- is laid out, and this one is laid out empty -- so it takes zero rows and keeps them
        -- however much text is set on it afterwards. The panel drew its buttons and nothing
        -- else until both of these were set.
        widgets.Label{view_id = 'cart', frame = {t = 0, l = 0, h = 3}, text = '',
                      auto_height = false,
                      on_click = function() self:goto_cart() end},
        -- One button per KIND of cart, and only for the kinds the fort actually has standing
        -- somewhere a dwarf could fetch them from. A button for a cart that does not exist is
        -- a button that can only disappoint.
        widgets.Label{frame = {t = 3, l = 0, h = 1}, text = 'Assign:', auto_height = false},
        -- PLAIN LABELS, not TextButtons: a TextButton draws a three-row bordered box, and two
        -- of them on neighbouring rows leave their borders lying across each other. A bracketed
        -- label clicks the same and is one row tall, which is what the row has room for.
        widgets.Label{view_id = 'lava', frame = {t = 3, l = 8, h = 1}, auto_height = false,
                      text = {{text = '[Lava]', pen = COLOR_RED}},
                      visible = function() return self:have('lava') end,
                      on_click = function() self:assign_kind('lava') end},
        widgets.Label{view_id = 'water', frame = {t = 3, l = 16, h = 1}, auto_height = false,
                      text = {{text = '[Water]', pen = COLOR_LIGHTBLUE}},
                      visible = function() return self:have('water') end,
                      on_click = function() self:assign_kind('water') end},
        widgets.Label{view_id = 'empty', frame = {t = 3, l = 25, h = 1}, auto_height = false,
                      text = {{text = '[Empty]', pen = COLOR_WHITE}},
                      visible = function() return self:have('empty') end,
                      on_click = function() self:assign_kind('empty') end},
        widgets.Label{view_id = 'nocarts', frame = {t = 3, l = 8, h = 1}, text = '',
                      auto_height = false, text_pen = COLOR_GREY},
        widgets.Label{frame = {t = 4, l = 0, h = 1}, auto_height = false,
                      text = {{text = '[Make a quantum stockpile]', pen = COLOR_LIGHTGREEN}},
                      on_click = function() self:quantum() end},
        widgets.Label{view_id = 'status', frame = {t = 6, l = 0, h = 1}, text = '',
                      auto_height = false, text_pen = COLOR_GREY},
    }
end

-- is there a cart of this kind within reach? Recomputed on the update pass, because the
-- buttons are drawn from it every frame and candidates() walks every vehicle in the fort.
function TrackStopPanel:have(kind)
    return self.available and self.available[kind] ~= nil
end

function TrackStopPanel:say(text, pen)
    self.subviews.status:setText(text or '')
    self.subviews.status.text_pen = pen or COLOR_GREY
end

function TrackStopPanel:overlay_onupdate()
    local bld = sheet_building()
    if not bld then return end
    local route, stop = stop_of(bld)
    self.bld, self.route, self.stop, self.cart_pos = bld, route, stop, nil
    -- the best cart of each kind within reach, for the Assign buttons
    local avail = {}
    for _, c in ipairs(candidates(bld, route)) do
        local kind = (c.liquid and c.liquid:find('lava')) and 'lava'
            or (c.liquid and c.liquid:find('water')) and 'water'
            or (not c.liquid) and 'empty' or nil
        if kind and not avail[kind] then avail[kind] = c end
    end
    self.available = avail
    local none = not (avail.lava or avail.water or avail.empty)
    self.subviews.nocarts:setText(none and 'no cart can reach this stop' or '')
    if not route then
        self.subviews.cart:setText{{text = 'No hauling route on this stop.', pen = COLOR_YELLOW}}
        return
    end
    local vid = #route.vehicle_ids > 0 and route.vehicle_ids[0] or nil
    local veh = vid and vehicle_by_id(vid) or nil
    local item = veh and df.item.find(veh.item_id) or nil
    if not item then
        self.subviews.cart:setText{
            {text = ('Route %d (%s)'):format(route.id, route.name ~= '' and route.name or 'unnamed')},
            NEWLINE,
            {text = 'no minecart assigned', pen = COLOR_LIGHTRED}}
        return
    end
    local pos, _, where = cart_whereabouts(item, xyz2pos(bld.centerx, bld.centery, bld.z))
    self.cart_pos = pos
    local liquid = cart_liquid(item)
    self.subviews.cart:setText{
        {text = ('Route %d (%s)'):format(route.id, route.name ~= '' and route.name or 'unnamed')},
        NEWLINE,
        {text = dfhack.items.getDescription(item, 0)},
        {text = liquid and (' (' .. liquid .. ')') or '',
         pen = liquid and (liquid:find('lava') and COLOR_RED or COLOR_LIGHTBLUE) or COLOR_GREY},
        NEWLINE,
        {text = where, pen = COLOR_GREY},
    }
end

function TrackStopPanel:goto_cart()
    if not self.cart_pos then return end
    df.global.game.main_interface.view_sheets.open = false
    dfhack.gui.revealInDwarfmodeMap(self.cart_pos, true, true)
end

-- NOT `assign`: that is a reserved method name in DFHack's class system, and defining it
-- aborts the whole script load -- silently, since the previously cached module env is what
-- reqscript hands back. The overlay simply never registers and nothing says why.
function TrackStopPanel:assign_kind(kind)
    local route = self.route
    if not route then
        self:say('This stop is not on a hauling route yet.', COLOR_YELLOW)
        return
    end
    local pick = self.available and self.available[kind]
    if not pick then
        self:say(('No %s cart can reach this stop.'):format(kind), COLOR_LIGHTRED)
        return
    end
    assign_cart(route, pick.vehicle)
    self:say(('Assigned %s%s.'):format(dfhack.items.getDescription(pick.item, 0),
                                       pick.liquid and (' (' .. pick.liquid .. ')') or ''),
             COLOR_GREEN)
end

function TrackStopPanel:quantum()
    local bld = self.bld or sheet_building()
    if not bld then return end
    local piles = adjacent_stockpiles(bld)
    if #piles == 0 then
        self:say('No stockpile touches this stop -- nothing to feed it.', COLOR_LIGHTRED)
        return
    end
    if #piles > 1 then
        self:say(('%d stockpiles touch this stop; link one by hand.'):format(#piles),
                 COLOR_YELLOW)
        return
    end
    local feeder = piles[1]
    local dpos = dump_pos(bld)
    if dfhack.buildings.findAtTile(dpos) then
        self:say('Something is already standing on the dump tile.', COLOR_LIGHTRED)
        return
    end
    local name = feeder.name ~= '' and feeder.name or ('Stop %d'):format(bld.id)
    -- checked first, changed second: a refusal must not leave a linked feeder behind
    local can, why = dump_tile_ok(dpos, name .. ' quantum')
    if not can then
        self:say('Quantum: ' .. tostring(why), COLOR_LIGHTRED)
        return
    end
    local route, stop = self.route, self.stop
    if not route then route, stop = make_route_for(bld) end
    link_feeder(stop, feeder)
    local ok, err = place_quantum_pile(dpos, name .. ' quantum')
    if not ok then
        self:say('Quantum pile: ' .. tostring(err), COLOR_LIGHTRED)
        return
    end
    -- an EMPTY cart for a quantum dumper: a cart full of magma dumps magma
    local best = self.available and self.available.empty
    if not best then
        for _, c in ipairs(candidates(bld, route)) do
            if not c.liquid then best = c; break end
        end
    end
    if best then assign_cart(route, best.vehicle) end
    self:say(('Quantum: %s feeds it, dumping to %d,%d%s.'):format(
        feeder.name ~= '' and feeder.name or ('stockpile ' .. feeder.id),
        dpos.x, dpos.y, best and ', cart assigned' or ' -- no free cart to assign'), COLOR_GREEN)
end

OVERLAY_WIDGETS = {panel = TrackStopPanel}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('better-track-stops: registered overlay fort/better-track-stops.panel')
print('  open a track stop to see its cart and where it is; `a` assigns the best reachable')
print('  cart, `q` turns a single adjacent stockpile into a quantum stockpile.')
