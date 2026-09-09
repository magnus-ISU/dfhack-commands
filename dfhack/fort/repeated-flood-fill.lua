-- Paint the same zone, stockpile or burrow twice in the same place and it floods the room.
--@module = true
--[[
repeated-flood-fill

Zones, stockpiles and burrows are almost always drawn to the walls of a room, and dragging a
rectangle to those walls is fiddly work that the room's own shape already knows. This makes
REPEATING A PLACEMENT mean "and the rest of it":

    a 1x1 placement            does what DF does -- one tile
    a 1x1 placement ON THE     floods the room in 2D: every tile you could walk to from there
      SAME TILE, again         without leaving the z-level, out to the walls
    a 3x3 placement            does what DF does -- nine tiles
    a 3x3 placement ON THE     floods in 3D -- BURROWS ONLY, since a zone and a stockpile each
      SAME NINE TILES, again     live on one z-level

Nothing else changes: any other size, or a placement anywhere else, is DF's own. The trigger is
the REPEAT, not the tile -- clicking once inside a zone you already have does nothing unusual,
which is what makes this safe to leave on.

WHAT COUNTS AS THE ROOM. The fill runs from the repeated tile across floors, boulders, ramps,
stairs and brook tops -- anything you can stand on -- and stops at walls, fortifications, open
air and DOORS, the way DF's own rooms do. Doors matter more than they sound: without them a
bedroom joins the corridor, the corridor joins the fort, and "the room" is the whole level.

THE SHELL COMES WITH IT. What is filled is the floor you could walk plus THE WALLS AND DOORS
AROUND IT, corners included -- a room is its shell as much as its floor, a bedroom that stops one
tile short of the wall is not the room you drew, and a burrow that stops there leaves the miner
outside the rock he was sent to dig. Doors are inside the fill already, since you can stand on
one; the walls are added around the edge once the inside is known.

Hidden tiles are never filled -- a fill may not tell you what is behind an undug wall -- and
stockpiles also leave out tiles another building owns, doors included, since a stockpile cannot
share a tile with one. A fill that would exceed the tile cap is refused outright rather than
half-drawn, which is what happens when you repeat a placement out in the open.

The 3D fill climbs the way a dwarf does: a staircase reaches the staircase above or below it, a
ramp reaches the tile over its head, and each level filled brings its own walls. Burrows are
painted tile by tile, so the ERASE tool floods in reverse there, taking the room back out of the
burrow. Zones and stockpiles grow the object you repeated on -- its settings, its name, its
assignments all survive, because it is the same object with more tiles.

    repeated-flood-fill          what it does and whether the overlays are on

The overlay `fort/repeated-flood-fill.watcher` is what actually watches for the repeat;
`magnus-scripts` turns it on. If you also have DFHack's own burrow "Flood fill on double click"
set to 2D or 3D, turn one of the two off -- they answer the same gesture, and DFHack's fills the
walkable space without the walls.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

local SH = df.tiletype_shape

-- Tiles the fill may cross: the ones a dwarf can stand on. Walls, fortifications, open air and
-- tree innards stop it, which is what makes the fill mean "this room".
local STANDABLE = {
    [SH.FLOOR] = true, [SH.BOULDER] = true, [SH.PEBBLES] = true,
    [SH.STAIR_UP] = true, [SH.STAIR_DOWN] = true, [SH.STAIR_UPDOWN] = true,
    [SH.RAMP] = true, [SH.RAMP_TOP] = true,
    [SH.BROOK_TOP] = true, [SH.TWIG] = true, [SH.SAPLING] = true, [SH.SHRUB] = true,
}

-- A refused fill is better than a half-drawn one, and out in the open "the room" is the whole
-- map: the cap is what stops a stray double-click turning into a fort-wide stockpile. The 3D cap
-- is looser because a 3D room legitimately spans levels -- but it is still a cap, since a
-- staircase reaches every floor in the fort (measured: a four-tile shaft blows past 2000).
local MAX_TILES = 2000
local MAX_TILES_3D = 6000

-- DOORS END A ROOM. Without this the fill is useless indoors: a bedroom's doorway joins it to
-- the corridor, the corridor to the rest of the fort, and a flood from a bed reaches every floor
-- tile on the level (measured: over 2000 from a bedroom, refused by the cap). It is also how DF
-- itself decides what a room is. The door's own tile is filled -- it belongs to the room you
-- painted -- but nothing expands through it.
local BOUNDARY_BUILDING = {
    [df.building_type.Door] = true,
    [df.building_type.Floodgate] = true,
    [df.building_type.Hatch] = true,
    [df.building_type.GrateWall] = true,
    [df.building_type.GrateFloor] = true,
    [df.building_type.BarsVertical] = true,
    [df.building_type.BarsFloor] = true,
}

-- ---- the three tools ---------------------------------------------------------

local mi = df.global.game.main_interface

local KINDS = {
    zone = {
        focus = 'dwarfmode/Zone/Paint',
        label = 'zone',
        iface = function() return mi.civzone end,
    },
    stockpile = {
        focus = 'dwarfmode/Stockpile/Paint',
        label = 'stockpile',
        iface = function() return mi.stockpile end,
    },
    burrow = {
        focus = 'dwarfmode/Burrow/Paint',
        label = 'burrow',
        iface = function() return mi.burrow end,
        allow_3d = true,
    },
}

-- ---- the fill ----------------------------------------------------------------

-- one number per tile, so the sets can be plain lua tables. Fort maps top out well under 4096
-- tiles on a side, so three 12-bit fields fit inside a double with room to spare.
local function key(x, y, z) return (z * 4096 + y) * 4096 + x end
local function unkey(k)
    local x = k % 4096
    local r = (k - x) / 4096
    local y = r % 4096
    return x, y, (r - y) / 4096
end

local function tile_shape(pos)
    local tt = dfhack.maps.getTileType(pos)
    return tt and df.tiletype.attrs[tt].shape or nil
end

local function is_hidden(pos)
    local flags = dfhack.maps.getTileFlags(pos)
    return flags and flags.hidden
end

-- Is this tile a door or one of its relatives? The occupancy check comes first because it is a
-- byte read: only the handful of tiles that hold a building at all are worth a lookup.
local function is_boundary(pos)
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return false end
    if block.occupancy[pos.x % 16][pos.y % 16].building == df.tile_building_occ.None then
        return false
    end
    local bld = dfhack.buildings.findAtTile(pos)
    return bld ~= nil and BOUNDARY_BUILDING[bld:getType()] or false
end

-- Where a tile leads. Horizontally: the four sides. Vertically (3D fills only): a stair reaches
-- the stair above or below it, and a ramp reaches the tile over its head -- which is how a dwarf
-- gets between z-levels, so it is how the fill does too.
local function neighbours(x, y, z, three_d)
    local out = {
        {x + 1, y, z}, {x - 1, y, z}, {x, y + 1, z}, {x, y - 1, z},
    }
    if not three_d then return out end
    local sh = tile_shape(xyz2pos(x, y, z))
    if sh == SH.STAIR_UP or sh == SH.STAIR_UPDOWN or sh == SH.RAMP then
        out[#out + 1] = {x, y, z + 1}
    end
    if sh == SH.STAIR_DOWN or sh == SH.STAIR_UPDOWN then
        out[#out + 1] = {x, y, z - 1}
    end
    return out
end

-- The eight tiles around one, on its own level: the ring is drawn with corners, or a room's
-- corner walls would be the one thing left out of it.
local RING = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}

-- The room around `pos`: standable tiles out to the walls, plus THE WALLS AND DOORS THEMSELVES.
-- A room is its shell as much as its floor -- a bedroom that stops one tile short of the wall is
-- not the room you drew -- so once the inside is known, every wall and fortification touching it
-- is added, corners included. Doors are already in: they are standable, and the fill stops at
-- them rather than passing through.
--
-- `opts.blocked(pos)` refuses a tile outright (a stockpile cannot take a tile another building
-- owns); `opts.three_d` lets it climb stairs and ramps. Returns the tile set, or nil and why.
function flood_room(pos, opts)
    opts = opts or {}
    if not dfhack.maps.isValidTilePos(pos) then return nil, 'that is not a map tile' end
    local shape = tile_shape(pos)
    if not shape or not STANDABLE[shape] then
        return nil, 'there is no floor there to fill from'
    end
    local cap = opts.three_d and MAX_TILES_3D or MAX_TILES
    local inside = {[key(pos.x, pos.y, pos.z)] = true}
    local queue, head, count = {{pos.x, pos.y, pos.z}}, 1, 1
    while head <= #queue do
        local t = queue[head]
        head = head + 1
        for _, n in ipairs(neighbours(t[1], t[2], t[3], opts.three_d)) do
            local k = key(n[1], n[2], n[3])
            if not inside[k] then
                local np = xyz2pos(n[1], n[2], n[3])
                if dfhack.maps.isValidTilePos(np) then
                    local sh = tile_shape(np)
                    if sh and STANDABLE[sh] and not is_hidden(np)
                        and not (opts.blocked and opts.blocked(np)) then
                        inside[k] = true
                        count = count + 1
                        if count > cap then
                            return nil, ('more than %d tiles -- that is not a room, it is the '
                                .. 'whole fort'):format(cap)
                        end
                        -- the door is part of the room; what is beyond it is not
                        if not is_boundary(np) then queue[#queue + 1] = n end
                    end
                end
            end
        end
    end
    -- the shell: every wall and fortification touching the inside
    local tiles = {}
    for k in pairs(inside) do tiles[k] = true end
    for k in pairs(inside) do
        local x, y, z = unkey(k)
        for _, d in ipairs(RING) do
            local nk = key(x + d[1], y + d[2], z)
            if not tiles[nk] then
                local np = xyz2pos(x + d[1], y + d[2], z)
                if dfhack.maps.isValidTilePos(np) then
                    local sh = tile_shape(np)
                    if (sh == SH.WALL or sh == SH.FORTIFICATION) and not is_hidden(np)
                        and not (opts.blocked and opts.blocked(np)) then
                        tiles[nk] = true
                    end
                end
            end
        end
    end
    return tiles
end

-- ---- growing a zone or a stockpile -------------------------------------------

-- the tiles a room-holding building already covers
local function building_tiles(bld)
    local out, room = {}, bld.room
    if room and room.extents then
        for dy = 0, room.height - 1 do
            for dx = 0, room.width - 1 do
                if room.extents[dy * room.width + dx] ~= 0 then
                    out[key(room.x + dx, room.y + dy, bld.z)] = true
                end
            end
        end
    else
        for x = bld.x1, bld.x2 do
            for y = bld.y1, bld.y2 do out[key(x, y, bld.z)] = true end
        end
    end
    return out
end

-- Write a tile set back onto a zone or stockpile as its extents.
--
-- The extents array is a plain w*h byte grid hanging off `room`, so a bigger room needs a bigger
-- buffer: allocate a new one, write the building's bounding box to match, and leave the old one
-- alone (it is DF's, freed with the building; a room's worth of bytes is not worth the risk of
-- freeing memory the game still thinks it owns).
local function write_extents(bld, tiles)
    local x1, y1, x2, y2
    for k in pairs(tiles) do
        local x, y = unkey(k)
        x1 = math.min(x1 or x, x); x2 = math.max(x2 or x, x)
        y1 = math.min(y1 or y, y); y2 = math.max(y2 or y, y)
    end
    if not x1 then return false end
    local w, h = x2 - x1 + 1, y2 - y1 + 1
    local buf = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', w * h))
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            buf[dy * w + dx] = tiles[key(x1 + dx, y1 + dy, bld.z)] and 1 or 0
        end
    end
    bld.x1, bld.y1, bld.x2, bld.y2 = x1, y1, x2, y2
    bld.room.x, bld.room.y = x1, y1
    bld.room.width, bld.room.height = w, h
    bld.room.extents = buf
    return true
end

-- A stockpile's tiles are marked on the map as passable-building occupancy; a zone's are not
-- (zones are abstract and leave the map alone). Tiles added to a stockpile need that mark or
-- DF does not treat them as stockpile floor.
local function mark_stockpile_tiles(bld, tiles)
    for k in pairs(tiles) do
        local x, y = unkey(k)
        local block = dfhack.maps.getTileBlock(xyz2pos(x, y, bld.z))
        if block then
            local occ = block.occupancy[x % 16][y % 16]
            if occ.building == df.tile_building_occ.None then
                occ.building = df.tile_building_occ.Passable
            end
        end
    end
end

-- ---- what is at a tile -------------------------------------------------------

local function zones_at(pos)
    local out = {}
    for _, z in ipairs(dfhack.buildings.findCivzonesAt(pos) or {}) do out[#out + 1] = z end
    return out
end

local function stockpile_at(pos)
    local b = dfhack.buildings.findAtTile(pos)
    if b and b:getType() == df.building_type.Stockpile then return b end
    return nil
end

-- a tile a stockpile may not take: another building already has it
local function tile_taken_by_building(pos, self_bld)
    local b = dfhack.buildings.findAtTile(pos)
    return b ~= nil and b ~= self_bld
end

-- ---- the fills, per tool -----------------------------------------------------

local function announce(msg, color)
    dfhack.gui.showAnnouncement(msg, color or COLOR_WHITE)
end

local function grow_building(bld, pos, what, blocked)
    local tiles, err = flood_room(pos, {blocked = blocked})
    if not tiles then
        announce(('repeated-flood-fill: %s'):format(err), COLOR_LIGHTRED)
        return false
    end
    local before = building_tiles(bld)
    local added = 0
    for k in pairs(before) do tiles[k] = true end
    for k in pairs(tiles) do if not before[k] then added = added + 1 end end
    if added == 0 then
        announce(('repeated-flood-fill: that %s already covers the room.'):format(what))
        return false
    end
    if not write_extents(bld, tiles) then return false end
    return true, added
end

function fill_zone(gesture, pos)
    -- The repeat click made a SECOND one-tile zone on the same spot -- zones may overlap -- so
    -- the duplicate goes, and the zone the first click made is the one that grows: it is the one
    -- that may already have a name or an assignment on it.
    local zones = zones_at(pos)
    local target, dupes = nil, {}
    for _, z in ipairs(zones) do
        if gesture.obj_id and z.id == gesture.obj_id then target = z
        else dupes[#dupes + 1] = z end
    end
    if not target then
        -- no record of which one was ours: take the oldest single-tile zone here
        for _, z in ipairs(zones) do
            if dfhack.buildings.countExtentTiles(z.room, 1) == 1 and
                (not target or z.id < target.id) then target = z end
        end
        dupes = {}
        for _, z in ipairs(zones) do if z ~= target then dupes[#dupes + 1] = z end end
    end
    if not target then return end
    for _, z in ipairs(dupes) do
        -- only ever clean up a one-tile duplicate of the same type: never touch a real zone
        -- that happens to overlap this tile
        if z.type == target.type and dfhack.buildings.countExtentTiles(z.room, 1) == 1 then
            dfhack.buildings.deconstruct(z)
        end
    end
    local ok, added = grow_building(target, pos, 'zone')
    if ok then
        dfhack.buildings.notifyCivzoneModified(target)
        announce(('repeated-flood-fill: filled the room -- %d tiles added to the zone.')
            :format(added), COLOR_LIGHTGREEN)
    end
end

function fill_stockpile(_, pos)
    local sp = stockpile_at(pos)
    if not sp then return end
    local ok, added = grow_building(sp, pos, 'stockpile', function(p)
        return tile_taken_by_building(p, sp)
    end)
    if ok then
        mark_stockpile_tiles(sp, building_tiles(sp))
        announce(('repeated-flood-fill: filled the room -- %d tiles added to the stockpile.')
            :format(added), COLOR_LIGHTGREEN)
    end
end

function fill_burrow(_, pos, do_3d)
    local burrow = mi.burrow.painting_burrow
    if not burrow then return end
    -- Our own flood rather than DFHack's `burrow_tiles_flood_add`: theirs fills the walkable
    -- space and nothing else, and a burrow that stops at the walls leaves the miner outside the
    -- rock he was sent to dig. Ours brings the shell, and climbs stairs and ramps for the 3D one.
    local tiles, err = flood_room(pos, {three_d = do_3d})
    if not tiles then
        announce(('repeated-flood-fill: %s'):format(err), COLOR_LIGHTRED)
        return
    end
    local erasing = mi.burrow.erasing
    local n = 0
    for k in pairs(tiles) do
        local x, y, z = unkey(k)
        dfhack.burrows.setAssignedTile(burrow, xyz2pos(x, y, z), not erasing)
        n = n + 1
    end
    announce(('repeated-flood-fill: %s %d tiles %s the burrow.')
        :format(erasing and 'took' or 'put', n, erasing and 'out of' or 'into'),
        COLOR_LIGHTGREEN)
end

local FILL = {zone = fill_zone, stockpile = fill_stockpile, burrow = fill_burrow}

-- ---- watching for the repeat -------------------------------------------------

-- What the tool has at this tile right now, so a repeat can tell "the one I just made" from
-- "one that was already here".
local function object_id_at(kind, pos)
    if kind == 'stockpile' then
        local sp = stockpile_at(pos)
        return sp and sp.id or nil
    elseif kind == 'zone' then
        local best
        for _, z in ipairs(zones_at(pos)) do
            if not best or z.id > best.id then best = z end
        end
        return best and best.id or nil
    end
    return nil
end

-- One widget watches all three tools. It is registered for `dwarfmode` at large rather than for
-- the three paint focus strings, and that is not laziness: DF SWITCHES SCREENS ON THE RELEASE.
-- The moment a zone or stockpile is painted the game opens that object's own panel, so a widget
-- bound to `.../Paint` stops being updated exactly one frame before the object it needs to grow
-- comes into existence. The tool is read off the focus string instead, per click.
RepeatFillOverlay = defclass(RepeatFillOverlay, overlay.OverlayWidget)
RepeatFillOverlay.ATTRS{
    desc = 'Repeat a zone, stockpile or burrow placement in place to flood fill the room.',
    default_pos = {x = 1, y = -1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},          -- draws nothing; it is here to watch the mouse
    frame_background = gui.CLEAR_PEN,
    overlay_onupdate_max_freq_seconds = 0,
}

-- which of the three paint tools is on screen, if any
local function current_kind()
    for name, k in pairs(KINDS) do
        if dfhack.gui.matchFocusString(k.focus) then return name end
    end
    return nil
end

-- The press starts a gesture; the gesture is whatever rectangle the mouse covered by the time
-- the button came back up. Reading the button state rather than DF's own `doing_rectangle` keeps
-- a single click -- which can begin and end inside one frame as far as that flag goes -- a
-- gesture like any other.
function RepeatFillOverlay:onInput(keys)
    if keys._MOUSE_L then
        local kind = current_kind()
        local pos = kind and dfhack.gui.getMousePos(true)
        if pos then
            self.press = pos
            self.drag_end = pos
            self.press_kind = kind
        end
    end
    return false        -- never consume: DF's own painting has to happen first
end

local function bounds_of(a, b)
    return {x1 = math.min(a.x, b.x), x2 = math.max(a.x, b.x),
            y1 = math.min(a.y, b.y), y2 = math.max(a.y, b.y), z = a.z}
end

local function same_bounds(a, b)
    return a and b and a.x1 == b.x1 and a.x2 == b.x2 and a.y1 == b.y1 and a.y2 == b.y2
        and a.z == b.z
end

function RepeatFillOverlay:overlay_onupdate()
    -- The action waits a frame: DF creates the zone or stockpile on the button release, and on
    -- the frame of the release it does not exist yet.
    local pending = self.pending
    self.pending = nil
    if pending then self:act(pending.kind, pending.bounds) end

    if not self.press then return end
    local pos = dfhack.gui.getMousePos(true)
    if pos and pos.z == self.press.z then self.drag_end = pos end
    if df.global.enabler.mouse_lbut_down ~= 0 then return end
    self.pending = {kind = self.press_kind, bounds = bounds_of(self.press, self.drag_end)}
    self.press, self.press_kind = nil, nil
end

function RepeatFillOverlay:act(kind, b)
    local tool = KINDS[kind]
    if not tool then return end
    self.last = self.last or {}
    local w, h = b.x2 - b.x1 + 1, b.y2 - b.y1 + 1
    local last = self.last[kind]
    local pos = xyz2pos(b.x1 + math.floor(w / 2), b.y1 + math.floor(h / 2), b.z)
    if same_bounds(last and last.bounds, b) then
        self.last[kind] = nil                    -- a third repeat starts over, never re-fills
        if w == 1 and h == 1 then
            FILL[kind](last, pos, false)
            return
        elseif w == 3 and h == 3 and tool.allow_3d then
            FILL[kind](last, pos, true)
            return
        end
    end
    -- not a trigger: remember it, along with what the tool left at that tile, so the NEXT
    -- identical gesture knows which object was already there
    self.last[kind] = {bounds = b, obj_id = object_id_at(kind, pos)}
end

OVERLAY_WIDGETS = {watcher = RepeatFillOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('repeated-flood-fill: repeat a placement in the same spot to fill the room.')
print('  1x1 twice on the same tile   -> 2D fill (zones, stockpiles, burrows)')
print('  3x3 twice on the same tiles  -> 3D fill (burrows only)')
local full = 'fort/repeated-flood-fill.watcher'
print(('  %s: %s'):format(full, require('plugins.overlay').isOverlayEnabled(full) and 'on' or 'off'))
