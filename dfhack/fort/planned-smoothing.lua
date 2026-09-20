-- Smooth, engrave and fortification designations DF refused, applied once they are legal.
--@module = true
--[[
fort/planned-smoothing

Draw a smooth designation over a room you have not finished digging yet. DF
throws away the part of the box that lands on undug rock -- the tiles are
hidden, so smoothing them is not legal and the designation simply never
appears. This remembers them and lays the designation down the moment each tile
is revealed and legal, so you can plan the finished room once instead of coming
back after every wall.

The same for ENGRAVING and CARVING FORTIFICATIONS on rough stone. DF only takes
either on a wall that has already been smoothed, so an engrave box dragged over
a freshly dug room designates nothing at all. Dragged here, the rough tiles are
remembered, designated for SMOOTHING first, and the moment the smoothing is done
the engrave (or fortification) designation is laid on the finished surface --
one gesture for what the game makes two, with a wait in between. Undug rock
under an engrave box is planned the same way: smooth when it is dug, engrave
when it is smooth. A fortification wants a wall; an engraving takes a wall or a
floor.

    fort/planned-smoothing            status
    fort/planned-smoothing clear      forget every planned tile
    fort/planned-smoothing now        run a designation pass immediately
    fort/planned-smoothing art on|off replace DF's designation art, or leave it

WHAT IT REMEMBERS, AND FOR HOW LONG

  Only tiles DF refused: the hidden ones inside a smooth box; the hidden and the
  rough ones inside an engrave or fortification box. Everything legal is
  designated by DF itself in the same gesture and is never touched.

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
      stone or ice), not already smoothed -- designate it, and forget it. An
      ENGRAVE or FORTIFY tile is designated for smoothing instead and KEPT: it
      waits through the smoothing designation and the smoothing job (a tile
      with a smoothing job on it is never designated again, so no second job is
      ever queued behind the first), and once the surface reads smooth it is
      designated for the finish and forgotten. A fortification on a tile that
      turns out to be a floor is dropped: there is nothing to carve.
    * anything that can never be smoothed -- forget it. Soil, constructions and
      grass never become smoothable however long you wait, and neither does a
      tile whose outstanding job is a staircase, a ramp or a channel: none of
      those leave anything to smooth, so the plan lets go rather than waiting on
      work that cannot satisfy it.

  DF's own rules, from quickfort's dig blueprint code, decide what is smoothable.
  Marking the tile is not enough on its own: `block_flags.designated` has to be
  raised too or DF never schedules the work.

WHAT IT LOOKS LIKE

  Exactly what DF draws, and nothing else. A real smooth designation gets DF's own
  designation art; a PLANNED tile is not designated yet, so DF draws nothing for it
  and neither do we -- `fort/planned-smoothing` on the command line says how many are
  waiting and on which z-levels.

  This tool used to paint a gray corner triangle over every smooth designation in
  view and blank DF's wash underneath it. That meant walking the viewport's map
  blocks on every rendered frame, which measured at 6.7% of frame time on a live
  fort -- the second most expensive overlay in the pack -- so the drawing is gone
  and the designation art is DF's alone. (`fort/planned-smoothing art` went with it.)

Loaded as two overlays: `planned-smoothing.capture` (the designation screens) and
`planned-smoothing.paint` (the pass driver -- it draws nothing; the key is kept so an
existing setting still finds it). Auto-enabled on `overlay rescan`.
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
--   plan[bkey] = {[idx] = kind, ...}   bkey = "bx,by,z", idx = (x%16)*16 + y%16
--   kind = 'smooth' | 'engrave' | 'fortify' -- what the tile is to end up as
plan = plan or {}
plan_tiles = plan_tiles or 0

local function bkey(pos) return (pos.x // 16) .. ',' .. (pos.y // 16) .. ',' .. pos.z end
local function tidx(pos) return (pos.x % 16) * 16 + (pos.y % 16) end

local function plan_add(pos, kind)
    local k, i = bkey(pos), tidx(pos)
    local b = plan[k]
    if not b then b = {}; plan[k] = b end
    if not b[i] then plan_tiles = plan_tiles + 1 end
    b[i] = kind or 'smooth'         -- a later box over the same tile says what it is now for
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
-- ENGRAVE AND FORTIFY TILES GO ROUND TWICE. The first time the tile is rough: it
-- is designated for smoothing and kept ('smooth'). Then it waits -- through the
-- smoothing designation (d.smooth ~= 0), and through the smoothing JOB, which is
-- invisible on the tile because DF clears the designation the moment it posts
-- the work; `work_marks` is what says a job is there, and without it the tile
-- would be designated a second time and a second job queued behind the first.
-- When the surface finally reads SMOOTH the finish is laid down ('go').
--   'smooth' -- rough: designate smoothing now, keep the tile
local function verdict(block, bx, by, k, i, kind)
    local d = block.designation[bx][by]
    if d.hidden then return 'wait' end
    if d.smooth ~= 0 then                          -- something is designated here already
        if kind == 'smooth' then return 'drop' end -- by hand: DF has it from here
        return 'wait'                              -- our smoothing, or the player's: wait it out
    end

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
    if kind ~= 'smooth' then
        local w = work_marks[k]
        if w and w[i] then return 'wait' end       -- a smoothing/engraving job is on the tile
        if kind == 'fortify' and attrs.shape ~= df.tiletype_shape.WALL then return 'drop' end
        if attrs.shape == df.tiletype_shape.FORTIFICATION then return 'drop' end
        if attrs.special == df.tiletype_special.SMOOTH then
            if attrs.shape ~= df.tiletype_shape.FLOOR
                and attrs.shape ~= df.tiletype_shape.WALL then return 'drop' end
            return 'go'
        end
        if attrs.shape ~= df.tiletype_shape.FLOOR
            and attrs.shape ~= df.tiletype_shape.WALL then return 'drop' end
        return 'smooth'
    end
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

-- SMOOTHING GOES TO THE BACK OF THE QUEUE, at priority 7.
--
-- A smoothing designation and a mining designation are the same queue to a dwarf: drop a
-- room's worth of smoothing on a half-dug fort and the miners stop digging to go and polish
-- walls. Priority is what DF has for saying "eventually": 1 is drop-everything, 4 is the
-- default, 7 is last.
--
-- It lives in a BLOCK SQUARE EVENT rather than the tile -- `block_square_event_designation_
-- priorityst`, one per block, holding a 16x16 grid of priority * 1000 -- so a block that has
-- never had a priority set has no event at all and one has to be made. This is the same path
-- quickfort's dig mode takes.
local SMOOTH_PRIORITY = 7

local function set_tile_priority(block, bx, by, priority)
    local pbse
    for _, ev in ipairs(block.block_events) do
        if ev:getType() == df.block_square_event_type.designation_priority then
            pbse = ev
            break
        end
    end
    if not pbse then
        block.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        pbse = block.block_events[#block.block_events - 1]
    end
    pbse.priority[bx][by] = priority * 1000
end

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
            for i, kind in pairs(tiles) do
                local bx, by = i // 16, i % 16
                local v = verdict(block, bx, by, k, i, kind)
                if v == 'go' then
                    -- an engraving is smooth=2; a fortification is smooth=1 on a wall
                    -- that is already smooth, which DF reads as "carve" (quickfort's
                    -- do_fortification writes the same)
                    block.designation[bx][by].smooth = kind == 'engrave' and 2 or 1
                    set_tile_priority(block, bx, by, SMOOTH_PRIORITY)
                    touched = true
                    plan_drop(k, i)
                    done = done + 1
                elseif v == 'smooth' then
                    block.designation[bx][by].smooth = 1
                    set_tile_priority(block, bx, by, SMOOTH_PRIORITY)
                    touched = true
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

-- Every job that finishes a surface, worker or not: a planned engraving waits on these.
local WORK_JOB = {
    [df.job_type.SmoothWall] = true,
    [df.job_type.SmoothFloor] = true,
    [df.job_type.DetailWall] = true,
    [df.job_type.DetailFloor] = true,
    [df.job_type.CarveFortification] = true,
}

job_marks = job_marks or {}      -- same shape as `plan`: [bkey] = {[idx] = true}
dig_marks = dig_marks or {}      -- [bkey] = {[idx] = 'wait'|'drop'}
work_marks = work_marks or {}    -- [bkey] = {[idx] = true}: a WORK_JOB is on the tile

local function refresh_marks()
    local marks, digs, work = {}, {}, {}
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
            if WORK_JOB[job.job_type] then
                local b = work[k]
                if not b then b = {}; work[k] = b end
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
    job_marks, dig_marks, work_marks = marks, digs, work
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

-- Did DF refuse this tile, and is it one this tool can ever satisfy? A smooth
-- box: only the hidden. An engrave or fortification box: the hidden, and the
-- ROUGH -- natural hard stone not yet smoothed, in a shape the finish can go on.
-- DF has already taken everything it would by the time this is asked (see the
-- one-frame delay in Capture), so a tile still reading smooth == 0 is refused.
local function refused(block, x, y, mode)
    local des = block.designation[x % 16][y % 16]
    if des.smooth ~= 0 then return false end
    if des.hidden then return true end
    if mode == 'smooth' then return false end
    local attrs = df.tiletype.attrs[block.tiletype[x % 16][y % 16]]
    if not HARD_MATERIALS[attrs.material] then return false end
    if attrs.special == df.tiletype_special.SMOOTH then return false end
    if mode == 'fortify' then return attrs.shape == df.tiletype_shape.WALL end
    return attrs.shape == df.tiletype_shape.WALL or attrs.shape == df.tiletype_shape.FLOOR
end

-- Record the refused tiles of a box, or drop them for the eraser. Walked block
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
                                -- Only what DF turned down. A tile it accepted
                                -- is a real designation now and is none of our
                                -- business.
                                if refused(block, x, y, mode) then plan_add(pos, mode) end
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
function plan_box(x1, y1, z1, x2, y2, z2, mode)
    register_box({x1 = math.min(x1, x2), x2 = math.max(x1, x2),
                  y1 = math.min(y1, y2), y2 = math.max(y1, y2),
                  z1 = math.min(z1, z2), z2 = math.max(z1, z2)}, mode or 'smooth')
    return plan_tiles
end

local function register_tile(pos, mode)
    if mode == 'erase' then
        plan_remove(pos)
        return
    end
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return end
    if refused(block, pos.x, pos.y, mode) then plan_add(pos, mode) end
end

local MODE_OF = {
    ['dwarfmode/Designate/SMOOTH'] = 'smooth',
    ['dwarfmode/Designate/ENGRAVE'] = 'engrave',
    ['dwarfmode/Designate/FORTIFY'] = 'fortify',
    ['dwarfmode/Designate/ERASE'] = 'erase',
}

local function current_mode()
    return MODE_OF[dfhack.gui.getCurFocus(true)[1] or '']
end

Capture = defclass(Capture, overlay.OverlayWidget)
Capture.ATTRS{
    desc = 'Remembers smooth/engrave/fortify designations DF refused (fort/planned-smoothing).',
    default_enabled = true,
    viewscreens = {'dwarfmode/Designate/SMOOTH', 'dwarfmode/Designate/ENGRAVE',
                   'dwarfmode/Designate/FORTIFY', 'dwarfmode/Designate/ERASE'},
    version = 2,
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
-- the pass driver
-- ---------------------------------------------------------------------------
--
-- This widget draws NOTHING. It once painted a corner triangle over every
-- smooth designation in the viewport and blanked DF's own art underneath, which
-- meant walking the viewport's blocks on every rendered frame -- measured at
-- 6.7% of frame time on a live fort, the second most expensive overlay in the
-- pack. Designations are DF's to draw; this only runs the pass. The widget keeps
-- its `paint` key so an existing enabled/disabled setting (and fort/magnus-scripts'
-- switch) still finds it.

Paint = defclass(Paint, overlay.OverlayWidget)
Paint.ATTRS{
    desc = 'Applies planned smoothing as the rock is dug (fort/planned-smoothing).',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 0, h = 0},
}

-- The pass runs from the overlay pump rather than a frame timeout, so it keeps
-- working while the game is paused -- which is exactly when a player draws a
-- plan and then wonders why nothing happened.
function Paint:overlay_onupdate()
    -- Nothing planned means there is no work here AT ALL, and this is the usual state of
    -- a fort. refresh_marks walks the whole job list and builds two keys per job; it
    -- exists to feed the pass, and with no plan there is no pass -- so doing it anyway
    -- was pure overhead. Measured with an empty plan it was 8.9% of frame time, the most
    -- expensive overlay in the pack, all of it spent answering a question nobody asked.
    if plan_tiles == 0 then return end
    local now = dfhack.getTickCount()
    if now < last_pass_at + PASS_INTERVAL_MS then return end
    last_pass_at = now
    -- Walked once per pass, not once per frame: the job list is as long as the
    -- fort is busy, and the answer only changes when a job is posted, picked up
    -- or finished.
    refresh_marks()
    pass(false)
end

OVERLAY_WIDGETS = {capture = Capture, paint = Paint}

-- A plan is a set of coordinates on THIS map. Carrying it into the next one
-- would designate whatever happened to be at those coordinates there.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        plan_clear()
        job_marks, dig_marks, work_marks = {}, {}, {}
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
            if not by_z[z] then zs[#zs + 1] = z; by_z[z] = {smooth = 0, engrave = 0, fortify = 0} end
            for _, kind in pairs(tiles) do by_z[z][kind] = (by_z[z][kind] or 0) + 1 end
        end
        table.sort(zs, function(a, b) return a > b end)
        for _, z in ipairs(zs) do
            local c = by_z[z]
            local parts = {}
            if c.smooth > 0 then parts[#parts + 1] = c.smooth .. ' smooth' end
            if c.engrave > 0 then parts[#parts + 1] = c.engrave .. ' engrave' end
            if c.fortify > 0 then parts[#parts + 1] = c.fortify .. ' fortify' end
            print(('  z=%d: %s'):format(z, table.concat(parts, ', ')))
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
elseif arg == 'now' then
    local n = pass(true)
    print(('fort/planned-smoothing: designated %d tile%s, %d still planned')
        :format(n, n == 1 and '' or 's', plan_tiles))
else
    status()
end
