-- Vehicle picker: say what is IN each minecart, and put the usable ones at the top.
--@module = true
--[[
fort/improve-minecart-selector

"Choose a vehicle for Route 9." lists every minecart in the fort as `gabbro minecart`, over
and over, and the only thing that tells them apart is a line underneath saying which route
already has it or that it cannot be reached. Two things are missing from that, and both of
them are the whole reason you are on this screen:

  * WHAT IS IN IT. A cart holding magma is not interchangeable with an empty one -- it is
    either exactly what you want or the last thing you want to hitch to a route. The contents
    are written after the name: `+gabbro minecart+ (833 lava)`.

  * WHICH ONES YOU CAN ACTUALLY USE. DF sorts by nothing in particular and leaves
    "Inaccessible from first stop" as a footnote on rows you cannot pick. The list is sorted
    instead, in the order that decides whether a cart is any use to you:

        None
        unassigned: lava, then water, then empty
        assigned to another route: lava, then water, then empty
        unreachable: lava, then water, then empty

    A cart you cannot reach is no use whatever it holds; a cart already hitched somewhere costs
    that route its vehicle; and after that, what is in it decides.

HOW ACCESSIBILITY IS DECIDED. By DF's own walkability groups -- the cart's tile and the
route's first stop being in the same group is exactly the question "can a dwarf get from one
to the other", answered from a field rather than a path search. Checked against DF's own
verdict on every row of a 26-cart list: the same answer every time.

THE SORT IS THE DISPLAY LIST ITSELF (`assign_vehicle.i_vehicle`), reordered in place, so
clicking a row picks the cart that row shows -- there is no mapping to get out of step. The
"None" entry is left where DF puts it, at the top.

Registered automatically as overlay `fort/improve-minecart-selector.rows`.
]]

local overlay = require('plugins.overlay')

-- The list's geometry, read off the render: the "None" row sits on the first line and every
-- vehicle row is three lines tall, so row i draws its name on ROW0 + 3*(i - scroll).
local ROW0 = 9
local PITCH = 3

-- DF's own word for the liquid is "magma"; the label here says LAVA, which is what this
-- fort's owner calls it and what the screen is being read for.
local LIQUID_WORD = {magma = 'lava'}
local LIQUID_PEN = {lava = COLOR_RED, water = COLOR_LIGHTBLUE}

-- what a cart is carrying: amount and liquid name, or nil for an empty one
local function cart_liquid(item)
    if not item then return nil end
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
                return c.stack_size or 0, LIQUID_WORD[name] or name
            end
        end
    end
end

-- lava beats water beats nothing: the rank a cart sorts by
local function liquid_rank(word)
    if word == 'lava' then return 2 end
    if word == 'water' then return 1 end
    return 0
end

local function route_of(id)
    for _, r in ipairs(df.global.plotinfo.hauling.routes) do
        if r.id == id then return r end
    end
end

-- Can a dwarf get a cart from where it lies to the route's first stop? DF keeps a walkability
-- GROUP per tile -- same group means mutually reachable on foot -- so this is a field compare
-- rather than a path search, and it is the same answer DF prints as "Inaccessible from first
-- stop" (verified row for row on a 26-cart list).
local function stop_group(av)
    local route = route_of(av.route_id)
    local stop = route and #route.stops > 0 and route.stops[0] or nil
    if not stop then return nil end
    return dfhack.maps.getWalkableGroup(stop.pos)
end

local function cart_group(item)
    if not item then return nil end
    local x, y, z = dfhack.items.getPosition(item)
    if not x or x < 0 then return nil end
    return dfhack.maps.getWalkableGroup(xyz2pos(x, y, z))
end

-- everything the rows need, computed once per pass: one entry per vehicle index.
--
-- CACHED for a fraction of a second, because both halves of this want it and both run every
-- frame: a pass is ~0.5ms on a 26-cart fort, which is nothing once and 25% of a frame at fifty
-- frames a second, twice. Carts do not fill or move that fast; the cache is dropped as soon as
-- the list changes length, which is what happens when one is made, melted or hitched.
local cache = {t = nil, n = nil, route = nil, info = nil}
local SURVEY_TTL_MS = 500

function survey(av)
    local now = dfhack.getTickCount()
    if cache.info and cache.t and now - cache.t < SURVEY_TTL_MS
        and cache.n == #av.i_vehicle and cache.route == av.route_id then
        return cache.info
    end
    local info = survey_now(av)
    cache.t, cache.n, cache.route, cache.info = now, #av.i_vehicle, av.route_id, info
    return info
end

function survey_now(av)
    local sg = stop_group(av)
    local out = {}
    for i = 0, #av.i_vehicle - 1 do
        local v = av.i_vehicle[i]
        local item = v and df.item.find(v.item_id) or nil
        local amount, word = cart_liquid(item)
        out[i] = {vehicle = v, item = item, amount = amount, word = word,
                  rank = liquid_rank(word),
                  -- a cart already hitched to a route is one you would be taking OFF that
                  -- route, so it sorts below the free ones however promising its contents
                  free = (v == nil) or (v.route_id < 0),
                  -- a cart with no position (held, hauled) is not judged inaccessible on a
                  -- guess: unknown sorts with the reachable ones rather than being buried
                  reachable = (not sg) or (cart_group(item) == sg) or (cart_group(item) == nil)}
    end
    return out
end

-- REORDER DF'S OWN LIST. The rows are drawn from this vector and clicks index straight back
-- into it, so sorting it is what makes the screen sorted -- nothing else has to agree.
-- Index 0 is DF's "None" entry and stays put.
local function sort_list(av, info)
    local order = {}
    for i = 1, #av.i_vehicle - 1 do order[#order + 1] = i end
    -- reachable first, then unhitched, then by what is in it -- in that order of importance:
    -- a cart you cannot reach is no use whatever it holds, and a cart already on a route costs
    -- another route its vehicle.
    table.sort(order, function(a, b)
        local ia, ib = info[a], info[b]
        if ia.reachable ~= ib.reachable then return ia.reachable end
        if ia.free ~= ib.free then return ia.free end
        if ia.rank ~= ib.rank then return ia.rank > ib.rank end
        return a < b                      -- otherwise DF's own order, unshuffled
    end)
    local changed = false
    for pos, idx in ipairs(order) do
        if idx ~= pos then changed = true; break end
    end
    if not changed then return false end
    local vehicles, moved = {}, {}
    for pos, idx in ipairs(order) do vehicles[pos] = info[idx].vehicle end
    for pos, v in ipairs(vehicles) do av.i_vehicle[pos] = v end
    return true
end

-- ---- overlay -----------------------------------------------------------------

MinecartSelectorOverlay = defclass(MinecartSelectorOverlay, overlay.OverlayWidget)
MinecartSelectorOverlay.ATTRS{
    desc = 'Vehicle picker: shows minecart contents and sorts reachable/lava carts first.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- BROAD, like fort/sort-locations: a narrow sub-focus match does not instantiate
    -- reliably on these selector screens, and every pass is gated on the picker being open
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},          -- draws nothing of its own; it paints onto DF's rows
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function MinecartSelectorOverlay:overlay_onupdate()
    local av = df.global.game.main_interface.assign_vehicle
    if not av.open or #av.i_vehicle == 0 then return end
    sort_list(av, survey(av))
end

-- the last column of the name DF drew on this line, or nil if the line is blank. The name is
-- the only thing on a row's first line, so its end is simply the last character on it.
local function name_end(y, x1, x2)
    local last
    for x = x1, x2 do
        local p = dfhack.screen.readTile(x, y)
        local ch = p and p.ch or 0
        if ch ~= 0 and ch ~= 32 then last = x end
    end
    return last
end

function MinecartSelectorOverlay:onRenderFrame(dc, rect)
    local av = df.global.game.main_interface.assign_vehicle
    if not av.open or #av.i_vehicle == 0 then return end
    local w, h = dfhack.screen.getWindowSize()
    local info = survey(av)
    local scroll = av.scroll_position or 0
    for i = math.max(1, scroll), #av.i_vehicle - 1 do
        local y = ROW0 + PITCH * (i - scroll)
        if y >= h - 1 then break end
        local e = info[i]
        if e and e.amount then
            local x = name_end(y, 0, w - 1)
            if x then
                local text = (' (%d %s)'):format(e.amount, e.word)
                local pen = dfhack.pen.parse{fg = LIQUID_PEN[e.word] or COLOR_GREY,
                                             bg = COLOR_BLACK}
                pcall(dfhack.screen.paintString, pen, x + 1, y, text)
            end
        end
    end
end

OVERLAY_WIDGETS = {rows = MinecartSelectorOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('improve-minecart-selector: registered overlay fort/improve-minecart-selector.rows')
print('  the vehicle picker now names what each cart is carrying and puts the reachable')
print('  ones -- lava first, then water -- at the top of the list.')
