-- Smooth designations drawn over undug rock, applied as the rock is revealed.
--@module = true
--[[
fort/planned-smoothing

Draw a smooth designation over a room you have not finished digging yet. DF
throws away the part of the box that lands on undug rock -- the tiles are
hidden, so smoothing them is not legal and the designation simply never
appears. This remembers them and lays the designation down the moment each tile
is revealed and legal, so you can plan the finished room once instead of coming
back after every wall.

    fort/planned-smoothing            status
    fort/planned-smoothing clear      forget every planned tile
    fort/planned-smoothing now        run a designation pass immediately
    fort/planned-smoothing art on|off replace DF's designation art, or leave it

WHAT IT REMEMBERS, AND FOR HOW LONG

  Only tiles DF refused: the hidden ones inside the box you dragged. Everything
  legal is designated by DF itself in the same gesture and is never touched.

  The plan lives in memory ONLY -- it is not written to the save and does not
  survive a reload, by design. A remembered tile is a rectangle you dragged
  thirty seconds ago, not a standing preference, and a plan that outlived the
  session it was drawn in would re-designate rooms you had long since changed
  your mind about, with nothing on screen to explain why.

  Erasing works the way you would expect: the ERASE designation tool drops
  planned tiles under its box as well as the real designations, so a plan can be
  taken back with the same gesture that takes back a designation.

WHEN A PLANNED TILE IS DESIGNATED

  A pass runs a few times a second, over the plan's blocks in turn. For each
  planned tile:

    * still hidden, still a wall, waiting on a miner, or blocked by a building
      -- keep waiting. MINING COMES FIRST: rock beside a fresh excavation is
      revealed as a wall long before anybody digs it out, and designating that
      face is work thrown away -- a dwarf smooths it and a miner cuts it away an
      hour later. The tile waits until mining has actually happened in it.
    * a revealed floor of natural hard stone (stone, mineral, feature, lava
      stone or ice), not already smoothed -- designate it, and forget it.
    * anything that can never be smoothed -- forget it. Soil, constructions and
      grass never become smoothable however long you wait, and neither does a
      tile whose outstanding job is a staircase, a ramp or a channel: none of
      those leave anything to smooth, so the plan lets go rather than waiting on
      work that cannot satisfy it.

  DF's own rules, from quickfort's dig blueprint code, decide what is smoothable.
  Marking the tile is not enough on its own: `block_flags.designated` has to be
  raised too or DF never schedules the work.

WHAT IT LOOKS LIKE

  Both planned and real smooth designations are drawn as a small triangle in the
  bottom-left corner of the tile, in place of DF's full-tile designation wash --
  the same shape DFHack marks damp dig tiles with, in gray. A room designated
  for smoothing then reads as what is under it, with a marker, instead of a
  solid block of designation colour you cannot see the floor through.

  Bright gray is designated for real -- including once the designation has become
  a job, which DF stops drawing as a designation at all because it clears the
  tile's flag when it posts the work. Dark gray is planned and waiting on the
  rock. A job somebody has PICKED UP is left to DF, flashing: that is the one
  state worth keeping, since it says a dwarf is on the way. Engrave designations
  keep DF's own graphic too. Hidden tiles are never drawn on -- undiscovered
  blackness is supposed to tell you nothing, and a marker on one breaks that.

  The wash is taken away only when smoothing is the ONLY thing designated on the
  tile. A tile also marked for mining keeps DF's art untouched and just gets the
  triangle drawn over it -- hiding the miner's marking to say "this will also be
  smoothed" would bury the more urgent of the two.

  Drawing is `paintTile` on the map grid, so the triangle keeps its own colours.
  Writing the sprite into `screentexpos_designation` instead does draw, but that
  layer is SHADED with DF's designation colour, which turned a gray triangle
  ruddy brown. The triangle is generated in code rather than shipped as an image.

  `fort/planned-smoothing art off` puts DF's own art back and leaves it alone.
  Worth knowing about: taking the wash away means zeroing DF's render layers, so
  if the marker ever fails to draw over the hole it leaves, a designated tile
  looks like nothing was designated at all.

Loaded as two overlays: `planned-smoothing.capture` (the designation screens)
and `planned-smoothing.paint` (the map). Auto-enabled on `overlay rescan`.
]]

local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')

local GLOBAL_KEY = 'planned-smoothing'

local function mi() return df.global.game.main_interface end
local sr = df.global.selection_rect

-- A single drag can cover a lot of map. DF is happy to take a box the size of
-- the embark; walking one in lua is not free, so a gesture past this is read as
-- a mis-drag and ignored rather than freezing the game for a second.
local MAX_BOX_TILES = 120000

local PASS_INTERVAL_MS = 300   -- how often planned tiles are re-examined
local BLOCKS_PER_PASS = 96     -- plan blocks looked at in one pass

-- ---------------------------------------------------------------------------
-- the plan
-- ---------------------------------------------------------------------------
--
-- In memory, never persisted (see the header). Grouped BY BLOCK, because both
-- things that read it want it that way: a pass fetches one block and then reads
-- 16x16 tile records straight out of it, and the renderer only cares about the
-- handful of blocks the viewport covers. A flat list of positions would cost a
-- block lookup per tile in both.
--
--   plan[bkey] = {[idx] = true, ...}   bkey = "bx,by,z", idx = (x%16)*16 + y%16
plan = plan or {}
plan_tiles = plan_tiles or 0

local function bkey(pos) return (pos.x // 16) .. ',' .. (pos.y // 16) .. ',' .. pos.z end
local function tidx(pos) return (pos.x % 16) * 16 + (pos.y % 16) end

local function plan_add(pos)
    local k, i = bkey(pos), tidx(pos)
    local b = plan[k]
    if not b then b = {}; plan[k] = b end
    if not b[i] then b[i] = true; plan_tiles = plan_tiles + 1 end
end

local function plan_drop(k, i)
    local b = plan[k]
    if not (b and b[i]) then return end
    b[i] = nil
    plan_tiles = plan_tiles - 1
    if not next(b) then plan[k] = nil end
end

local function plan_remove(pos) plan_drop(bkey(pos), tidx(pos)) end

function plan_clear()
    local n = plan_tiles
    plan, plan_tiles = {}, 0
    return n
end

-- Forget every planned tile in a box. A plan is invisible to DF -- the tiles it
-- covers are hidden rock with nothing designated on them -- so nothing DF's own
-- eraser does can reach it. Anything that erases an area has to say so here, or
-- the plan quietly re-designates ground the player just cleared.
-- `fort/right-click-cancel` calls this after every erase it drives.
function forget_box(x1, y1, z1, x2, y2, z2)
    if plan_tiles == 0 then return 0 end
    local n = 0
    for z = math.min(z1, z2), math.max(z1, z2) do
        for x = math.min(x1, x2), math.max(x1, x2) do
            for y = math.min(y1, y2), math.max(y1, y2) do
                local k, i = (x // 16) .. ',' .. (y // 16) .. ',' .. z,
                             (x % 16) * 16 + (y % 16)
                if plan[k] and plan[k][i] then plan_drop(k, i); n = n + 1 end
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- what DF will accept
-- ---------------------------------------------------------------------------
--
-- Lifted from quickfort's dig blueprints (internal/quickfort/dig.lua, do_smooth)
-- so a planned tile is designated exactly when a hand-drawn one would have been.
local HARD_MATERIALS = {
    [df.tiletype_material.STONE] = true,
    [df.tiletype_material.FEATURE] = true,
    [df.tiletype_material.LAVA_STONE] = true,
    [df.tiletype_material.MINERAL] = true,
    [df.tiletype_material.FROZEN_LIQUID] = true,
}

-- Mining jobs, by whether the tile they finish on could ever be smoothed. A plain
-- Dig leaves a floor, which is the whole point of waiting for it. A staircase, a
-- ramp or a channel does not: nothing at that position will be smoothable when
-- the miner is done, so the plan lets the tile go rather than waiting forever.
local DIG_JOB = {
    [df.job_type.Dig] = 'wait',
    [df.job_type.CarveUpwardStaircase] = 'drop',
    [df.job_type.CarveDownwardStaircase] = 'drop',
    [df.job_type.CarveUpDownStaircase] = 'drop',
    [df.job_type.CarveRamp] = 'drop',
    [df.job_type.DigChannel] = 'drop',
}

-- The same question asked of a designation that has not become a job yet.
local DIG_DESIGNATION = {
    [df.tile_dig_designation.Default] = 'wait',
    [df.tile_dig_designation.UpStair] = 'drop',
    [df.tile_dig_designation.DownStair] = 'drop',
    [df.tile_dig_designation.UpDownStair] = 'drop',
    [df.tile_dig_designation.Ramp] = 'drop',
    [df.tile_dig_designation.Channel] = 'drop',
}

-- Three answers, not two. A tile that cannot be smoothed BECAUSE OF SOMETHING
-- THAT MIGHT CHANGE -- still buried, waiting on a miner, a building standing on
-- it -- has to stay in the plan, while one that can never be smoothed has to
-- leave it, or the plan grows without bound and every pass gets slower.
--   'go'   -- designate it now
--   'wait' -- not yet, keep it
--   'drop' -- never, forget it
--
-- MINING COMES FIRST. A planned tile is undug rock, and the rock next to a fresh
-- excavation is revealed as a WALL long before anybody digs it out. Designating
-- the wall face then is work thrown away: a dwarf walks over, smooths it, and a
-- miner cuts it away an hour later. So the tile waits until mining has actually
-- happened in it -- until it is a floor -- and waits again while any digging is
-- still outstanding there.
--
-- Except when what is outstanding is a staircase, a ramp or a channel. None of
-- those leave a smoothable tile behind, so the plan lets go rather than waiting
-- on work that can never satisfy it.
local function verdict(block, bx, by, k, i)
    local d = block.designation[bx][by]
    if d.hidden then return 'wait' end
    if d.smooth ~= 0 then return 'drop' end        -- already designated by hand

    -- outstanding mining, as a designation or as the job it has become
    local pending = DIG_DESIGNATION[d.dig]
    if not pending then
        local b = dig_marks[k]
        pending = b and b[i]
    end
    if pending then return pending end

    local occ = block.occupancy[bx][by]
    if occ.building > df.tile_building_occ.Passable
        and occ.building ~= df.tile_building_occ.Dynamic then return 'wait' end
    local attrs = df.tiletype.attrs[block.tiletype[bx][by]]
    if not HARD_MATERIALS[attrs.material] then return 'drop' end
    if attrs.special == df.tiletype_special.SMOOTH then return 'drop' end
    -- A revealed WALL is designated, not held. Waiting for it to become a floor
    -- sounds prudent and is wrong: a wall face is exactly what a room's walls
    -- ARE, and rock nobody has designated for digging is never going to become a
    -- floor, so the tile would sit in the plan for good. "Mining first" is about
    -- mining that is actually PENDING, and that is settled above.
    if attrs.shape ~= df.tiletype_shape.FLOOR
        and attrs.shape ~= df.tiletype_shape.WALL then return 'drop' end
    return 'go'
end

-- ---------------------------------------------------------------------------
-- the pass
-- ---------------------------------------------------------------------------

designated_total = designated_total or 0
last_pass_at = last_pass_at or 0
local pass_cursor = nil        -- block key the last pass stopped after

local function block_of(k)
    local bx, by, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
    if not bx then return end
    return dfhack.maps.getTileBlock(
        {x = tonumber(bx) * 16, y = tonumber(by) * 16, z = tonumber(z)})
end

-- Walks the plan a slice at a time, resuming where it left off, so a big plan
-- costs the same per frame as a small one -- it just takes more passes to come
-- round again. Returns how many tiles it designated.
local function pass(all)
    local keys = {}
    for k in pairs(plan) do keys[#keys + 1] = k end
    if #keys == 0 then return 0 end
    table.sort(keys)

    local start = 1
    if not all and pass_cursor then
        for i, k in ipairs(keys) do
            if k > pass_cursor then start = i; break end
            if i == #keys then start = 1 end
        end
    end

    local n = all and #keys or math.min(BLOCKS_PER_PASS, #keys)
    local done = 0
    for step = 0, n - 1 do
        local k = keys[(start - 1 + step) % #keys + 1]
        pass_cursor = k
        local tiles = plan[k]
        local block = tiles and block_of(k)
        if not block then
            -- the block is gone (map unloaded under us, or an unallocated one):
            -- nothing there to designate and nothing to wait for
            if tiles then for i in pairs(tiles) do plan_drop(k, i) end end
        else
            local touched = false
            for i in pairs(tiles) do
                local bx, by = i // 16, i % 16
                local v = verdict(block, bx, by, k, i)
                if v == 'go' then
                    block.designation[bx][by].smooth = 1
                    touched = true
                    plan_drop(k, i)
                    done = done + 1
                elseif v == 'drop' then
                    plan_drop(k, i)
                end
            end
            -- DF only schedules work from blocks flagged as having designations,
            -- and it clears that flag as it processes them -- so writing the
            -- tile record without re-raising it designates nothing at all.
            if touched then block.flags.designated = true end
        end
    end
    -- Raising the block flag is not the whole of it. DF decides when to look at
    -- designations again on its own schedule, and a designation written from
    -- outside the UI can sit there designated-but-jobless in the meantime --
    -- which is exactly "it does not make a normal smoothing job the way the
    -- player does". This is the nudge quickfort's dig blueprints end with, and
    -- it is the difference between a designation and a job.
    if done > 0 then pcall(dfhack.job.checkDesignationsNow) end
    designated_total = designated_total + done
    return done
end

function run_pass(all) return pass(all) end

-- ---------------------------------------------------------------------------
-- tiles whose designation has already become a job
-- ---------------------------------------------------------------------------
--
-- DF clears `designation.smooth` the moment it posts the job, so a tile the
-- player designated stops looking designated to us and DF's own art comes back
-- the instant a job appears -- which is the "the art changes once it is placed"
-- half of this. Those tiles are found from the job list instead, and marked the
-- same way, so a room designated for smoothing keeps one look from the drag to
-- the dwarf arriving.
--
-- A job somebody has PICKED UP is deliberately left alone: that is the flashing
-- DF draws for work in hand, and it is worth keeping -- it is the one state that
-- says a dwarf is on the way.
-- Tiles whose smooth designation has already become a job. DF clears
-- `designation.smooth` when it posts the work, so without this a tile stops
-- looking designated the moment a job appears and DF's own art comes back.
-- A job somebody has PICKED UP is deliberately not listed: that is the flashing
-- DF draws for work in hand, and it is the one state worth keeping.
local SMOOTH_JOB = {
    [df.job_type.SmoothWall] = true,
    [df.job_type.SmoothFloor] = true,
}

job_marks = job_marks or {}      -- same shape as `plan`: [bkey] = {[idx] = true}
dig_marks = dig_marks or {}      -- [bkey] = {[idx] = 'wait'|'drop'}

local function refresh_marks()
    local marks, digs = {}, {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job then
            local p = job.pos
            local k = (p.x // 16) .. ',' .. (p.y // 16) .. ',' .. p.z
            local i = (p.x % 16) * 16 + (p.y % 16)
            if SMOOTH_JOB[job.job_type] and not dfhack.job.getWorker(job) then
                local b = marks[k]
                if not b then b = {}; marks[k] = b end
                b[i] = true
            end
            local dig = DIG_JOB[job.job_type]
            if dig then
                local b = digs[k]
                if not b then b = {}; digs[k] = b end
                b[i] = dig
            end
        end
        link = link.next
    end
    job_marks, dig_marks = marks, digs
end

-- ---------------------------------------------------------------------------
-- capture: what the player just dragged
-- ---------------------------------------------------------------------------

local function map_bounds()
    local m = df.global.world.map
    return m.x_count, m.y_count, m.z_count
end

local function clamp_pos(p)
    local mx, my, mz = map_bounds()
    return {x = math.max(0, math.min(mx - 1, p.x)),
            y = math.max(0, math.min(my - 1, p.y)),
            z = math.max(0, math.min(mz - 1, p.z))}
end

-- The box being dragged: one corner is the mouse, the other is where the drag
-- started (DF keeps it in selection_rect for the designation tools). Same shape
-- as the dig plugin's own warm/damp box reader.
local function drag_bounds()
    local m = dfhack.gui.getMousePos(true)
    if not m then return end
    if sr.start_z < 0 then return end
    local a, b = clamp_pos(m), clamp_pos{x = sr.start_x, y = sr.start_y, z = sr.start_z}
    return {x1 = math.min(a.x, b.x), x2 = math.max(a.x, b.x),
            y1 = math.min(a.y, b.y), y2 = math.max(a.y, b.y),
            z1 = math.min(a.z, b.z), z2 = math.max(a.z, b.z)}
end

-- Record the hidden tiles of a box, or drop them for the eraser. Walked block
-- by block: one map lookup per 16x16 instead of one per tile.
local function register_box(bounds, mode)
    local w = bounds.x2 - bounds.x1 + 1
    local h = bounds.y2 - bounds.y1 + 1
    local d = bounds.z2 - bounds.z1 + 1
    if w * h * d > MAX_BOX_TILES then return end
    for z = bounds.z1, bounds.z2 do
        for bx = bounds.x1 // 16, bounds.x2 // 16 do
            for by = bounds.y1 // 16, bounds.y2 // 16 do
                local block = dfhack.maps.getTileBlock({x = bx * 16, y = by * 16, z = z})
                if block then
                    for x = math.max(bounds.x1, bx * 16), math.min(bounds.x2, bx * 16 + 15) do
                        for y = math.max(bounds.y1, by * 16), math.min(bounds.y2, by * 16 + 15) do
                            local pos = {x = x, y = y, z = z}
                            if mode == 'erase' then
                                plan_remove(pos)
                            else
                                local des = block.designation[x % 16][y % 16]
                                -- Only what DF turned down. A tile it accepted
                                -- is a real designation now and is none of our
                                -- business; a tile that is merely hidden is
                                -- exactly what this tool exists for.
                                if des.hidden and des.smooth == 0 then plan_add(pos) end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Register a box the way a player's own drag would. Needed because a drag
-- completed by `fort/right-click-cancel` finishes with a SYNTHETIC click, which
-- goes straight to the viewscreen and past this tool's input hook.
function plan_box(x1, y1, z1, x2, y2, z2)
    register_box({x1 = math.min(x1, x2), x2 = math.max(x1, x2),
                  y1 = math.min(y1, y2), y2 = math.max(y1, y2),
                  z1 = math.min(z1, z2), z2 = math.max(z1, z2)}, 'smooth')
    return plan_tiles
end

local function register_tile(pos, mode)
    if mode == 'erase' then
        plan_remove(pos)
        return
    end
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return end
    local des = block.designation[pos.x % 16][pos.y % 16]
    if des.hidden and des.smooth == 0 then plan_add(pos) end
end

local MODE_OF = {
    ['dwarfmode/Designate/SMOOTH'] = 'smooth',
    ['dwarfmode/Designate/ERASE'] = 'erase',
}

local function current_mode()
    return MODE_OF[dfhack.gui.getCurFocus(true)[1] or '']
end

Capture = defclass(Capture, overlay.OverlayWidget)
Capture.ATTRS{
    desc = 'Remembers smooth designations drawn over undug rock (fort/planned-smoothing).',
    default_enabled = true,
    viewscreens = {'dwarfmode/Designate/SMOOTH', 'dwarfmode/Designate/ERASE'},
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 0, h = 0},
}

-- The box is registered a frame LATE, deliberately. At the click DF has not
-- applied its own designation yet, and the whole judgement here is "what did DF
-- refuse?" -- asked too early, every tile looks refused and the plan fills up
-- with tiles that are about to be designated for real.
function Capture:onInput(keys)
    if Capture.super.onInput(self, keys) then return true end
    local mode = current_mode()
    if not mode then return end
    if mi().main_designation_doing_rectangles then
        if keys._MOUSE_L and sr.start_z >= 0 then
            local bounds = drag_bounds()
            if bounds then
                if self.pending then self.pending() end
                self.pending = function() register_box(bounds, mode) end
            end
        end
    elseif keys._MOUSE_L_DOWN then
        local pos = dfhack.gui.getMousePos()
        if pos then self.pending = function() register_tile(pos, mode) end end
    end
    -- never swallowed: DF still designates everything it can, as always
end

-- Freehand painting (rectangle mode off) has no click to hang off -- DF paints
-- whatever the held mouse crosses -- so the tile under the cursor is taken every
-- frame while the button is down, which is the same thing DF is doing.
function Capture:overlay_onupdate()
    local mode = current_mode()
    if not mode or mi().main_designation_doing_rectangles then return end
    if df.global.enabler.mouse_lbut_down ~= 1 then return end
    local pos = dfhack.gui.getMousePos()
    if pos then register_tile(pos, mode) end
end

function Capture:onRenderFrame(dc, rect)
    Capture.super.onRenderFrame(self, dc, rect)
    if self.pending then
        self.pending()
        self.pending = nil
    end
end

-- ---------------------------------------------------------------------------
-- the marker
-- ---------------------------------------------------------------------------
--
-- Drawn in code, not shipped as an image: it is nine rows of a right triangle in
-- three shades, and a generated texture keeps the colours in the file that
-- explains them. The shape mirrors DFHack's damp-dig marker -- bottom-left
-- corner, inset a pixel, lightest along the hypotenuse -- so it reads as the
-- same kind of annotation rather than as part of the map.

-- Whether DF's own designation art is taken away under our marker. Off leaves
-- every designation looking exactly as DF draws it, with the triangle painted on
-- top -- the safe setting if the marker ever fails to draw, since a suppressed
-- wash with no marker over it makes a designated tile look undesignated.
art_suppress = art_suppress
if art_suppress == nil then art_suppress = true end

local TILE_PX = 32

-- {hypotenuse, shade, fill}, packed 0xRRGGBBAA
local SHADES = {
    designated = {0xC4C4C4FF, 0x5F5F5FFF, 0x8A8A8AFF},
    planned    = {0x8A8A8AFF, 0x3C3C3CFF, 0x5A5A5AFF},
}

-- Row 22 down to row 30, starting one pixel in from the left edge. Read off
-- DFHack's own damp marker rather than derived, antialiasing and all: A is the
-- lit hypotenuse, B the shading behind it, C the body.
local PATTERN = {
    'A',
    'BA',
    'CBA',
    'CBBA',
    'CCBBA',
    'CCCCBA',
    'CCCCBBA',
    'CCCCCBBA',
    'CCCCCCCBA',
}
local SHADE_INDEX = {A = 1, B = 2, C = 3}

local function tile_pixels(shades, out)
    for row, line in ipairs(PATTERN) do
        local y = 21 + row
        for col = 1, #line do
            out[y * TILE_PX + col + 1] = shades[SHADE_INDEX[line:sub(col, col)]]
        end
    end
end

local function make_tileset()
    local px = {}
    for i = 1, TILE_PX * TILE_PX * 2 do px[i] = 0 end
    local top, bottom = {}, {}
    for i = 1, TILE_PX * TILE_PX do top[i] = 0; bottom[i] = 0 end
    tile_pixels(SHADES.designated, top)
    tile_pixels(SHADES.planned, bottom)
    for i = 1, TILE_PX * TILE_PX do
        px[i] = top[i]
        px[TILE_PX * TILE_PX + i] = bottom[i]
    end
    -- one column, two rows: sliced row-major, tile 1 is designated, 2 is planned
    return dfhack.textures.createTileset(px, TILE_PX, TILE_PX * 2, TILE_PX, TILE_PX, true)
end

textures = textures or make_tileset()

local function texpos(i)
    local h = textures and textures[i]
    if not h then return 0 end
    return dfhack.textures.getTexposByHandle(h) or 0
end

-- ---------------------------------------------------------------------------
-- paint: the map overlay
-- ---------------------------------------------------------------------------

Paint = defclass(Paint, overlay.OverlayWidget)
Paint.ATTRS{
    desc = 'Draws smooth designations as a corner triangle and applies planned ones (fort/planned-smoothing).',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 0, h = 0},
}

-- The pass runs from the overlay pump rather than a frame timeout, so it keeps
-- working while the game is paused -- which is exactly when a player draws a
-- plan and then wonders why nothing happened.
function Paint:overlay_onupdate()
    local now = dfhack.getTickCount()
    if now < last_pass_at + PASS_INTERVAL_MS then return end
    last_pass_at = now
    -- Walked once per pass, not once per frame: the job list is as long as the
    -- fort is busy, and the answer only changes when a job is posted, picked up
    -- or finished.
    refresh_marks()
    if plan_tiles > 0 then pass(false) end
end

-- carve_track_* read back as a boolean or as a 0/1 depending on how it was last
-- written, and 0 is TRUTHY in lua -- so neither `if v` nor `v ~= 0` is right on
-- its own
local function set(v) return v ~= nil and v ~= false and v ~= 0 end

-- Pens, not raw layer writes. Writing the sprite into `screentexpos_designation`
-- does draw it, but that layer is SHADED by the renderer with DF's designation
-- colour, so a gray triangle came out ruddy brown. Painting the map grid keeps
-- the sprite's own colours and draws OVER the tile rather than in place of it.
-- `keep_lower` leaves the map underneath alone; `tile_color` is deliberately
-- unset, since setting it would shade the sprite with the pen's fg.
local function marker_pen(i, ch, fg)
    return dfhack.pen.parse{ch = ch, fg = fg, keep_lower = true, tile = texpos(i)}
end

function Paint:onRenderFrame(dc, rect)
    Paint.super.onRenderFrame(self, dc, rect)
    if not dfhack.world.isFortressMode() then return end
    local vp = guidm.Viewport.get()
    if not vp then return end
    local gvp = df.global.gps.main_viewport
    local dimx, dimy = gvp.dim_x, gvp.dim_y
    if dimx <= 0 or dimy <= 0 then return end
    -- DF draws a designated tile in two layers: `screentexpos_background_two` is
    -- the full-tile wash (and the flashing), `screentexpos_designation` the
    -- marking over it.
    local layer, layer_old = gvp.screentexpos_designation, gvp.screentexpos_designation_old
    local wash, wash_old = gvp.screentexpos_background_two, gvp.screentexpos_background_two_old
    local t_des, t_plan = texpos(1), texpos(2)
    if t_des == 0 and t_plan == 0 then return end
    local pen_des = marker_pen(1, 250, COLOR_GREY)
    local pen_plan = marker_pen(2, 250, COLOR_DARKGREY)
    local z = vp.z

    local function suppress(x, y)
        local vx, vy = x - vp.x1, y - vp.y1
        if vx < 0 or vy < 0 or vx >= dimx or vy >= dimy then return end
        local at = vx * dimy + vy
        -- Only ever ZEROED, never given a texpos of ours, so a cell left behind
        -- when the view scrolls is simply "nothing here" -- which is what an
        -- undesignated cell should hold anyway. That is why this needs no
        -- bookkeeping to undo itself.
        layer[at], layer_old[at] = 0, 0
        wash[at], wash_old[at] = 0, 0
    end

    for bx = math.max(0, vp.x1 // 16), vp.x2 // 16 do
        for by = math.max(0, vp.y1 // 16), vp.y2 // 16 do
            local block = dfhack.maps.getTileBlock({x = bx * 16, y = by * 16, z = z})
            if block then
                local k = bx .. ',' .. by .. ',' .. z
                local planned, queued, digging = plan[k], job_marks[k], dig_marks[k]
                for x = math.max(vp.x1, bx * 16), math.min(vp.x2, bx * 16 + 15) do
                    for y = math.max(vp.y1, by * 16), math.min(vp.y2, by * 16 + 15) do
                        local lx, ly = x % 16, y % 16
                        local i = lx * 16 + ly
                        local des = block.designation[lx][ly]
                        local pen
                        -- Undiscovered tiles are left exactly as DF draws them.
                        -- A marker on one breaks what that blackness means -- it
                        -- is the one part of the map that is supposed to tell
                        -- you nothing -- and a plan is only ever waiting on rock
                        -- there anyway.
                        if des.hidden then pen = nil
                        elseif des.smooth == 1 or (queued and queued[i]) then
                            -- designated and queued look the same on purpose:
                            -- the tile is going to be smoothed either way
                            pen = pen_des
                        elseif planned and planned[i] then
                            pen = pen_plan
                        end
                        if pen then
                            local occ = block.occupancy[lx][ly]
                            -- A tile also marked for mining keeps DF's art: the
                            -- triangle goes over it rather than instead of it.
                            local other = des.dig ~= df.tile_dig_designation.No
                                or (digging ~= nil and digging[i] ~= nil)
                                or set(occ.carve_track_north) or set(occ.carve_track_east)
                                or set(occ.carve_track_south) or set(occ.carve_track_west)
                            if art_suppress and not other then suppress(x, y) end
                            local sp = vp:tileToScreen({x = x, y = y, z = z})
                            dfhack.screen.paintTile(pen, sp.x, sp.y, nil, nil, true)
                        end
                    end
                end
            end
        end
    end
end

OVERLAY_WIDGETS = {capture = Capture, paint = Paint}

-- A plan is a set of coordinates on THIS map. Carrying it into the next one
-- would designate whatever happened to be at those coordinates there.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        plan_clear()
        job_marks, dig_marks = {}, {}
        pass_cursor = nil
    end
end

function status()
    print(('fort/planned-smoothing: %d tile%s planned')
        :format(plan_tiles, plan_tiles == 1 and '' or 's'))
    if plan_tiles > 0 then
        local by_z, zs = {}, {}
        for k, tiles in pairs(plan) do
            local z = tonumber(k:match(',(-?%d+)$'))
            local n = 0
            for _ in pairs(tiles) do n = n + 1 end
            if not by_z[z] then zs[#zs + 1] = z; by_z[z] = 0 end
            by_z[z] = by_z[z] + n
        end
        table.sort(zs, function(a, b) return a > b end)
        for _, z in ipairs(zs) do
            print(('  z=%d: %d tile%s'):format(z, by_z[z], by_z[z] == 1 and '' or 's'))
        end
    end
    print(('  %d designated so far this session'):format(designated_total))
    print('  plans are in memory only -- they do not survive a reload')
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/planned-smoothing only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'clear' then
    local n = plan_clear()
    print(('fort/planned-smoothing: forgot %d planned tile%s'):format(n, n == 1 and '' or 's'))
elseif arg == 'art' then
    local on = ({...})[2]
    if on == 'on' or on == 'off' then art_suppress = (on == 'on') end
    print(('fort/planned-smoothing: replacing DF\'s designation art is %s')
        :format(art_suppress and 'ON' or 'OFF'))
elseif arg == 'now' then
    local n = pass(true)
    print(('fort/planned-smoothing: designated %d tile%s, %d still planned')
        :format(n, n == 1 and '' or 's', plan_tiles))
else
    status()
end
