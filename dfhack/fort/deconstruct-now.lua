-- Instantly complete construction-removal designations, the way dig-now completes digs.
--[[
fort/deconstruct-now

Every constructed wall, floor, stair, ramp or fortification that is marked for removal comes
out this instant: the tile goes back to what it was before the construction went in, the
material it was built from is dropped where it stood (or the first solid tile below, when
that was mid-air), and the designation is cleared. `dig-now`'s bounds rules apply, and the
same `-z`:

    fort/deconstruct-now                 the whole map
    fort/deconstruct-now -z              only the z-level you are looking at
    fort/deconstruct-now here            only the tile under the cursor
    fort/deconstruct-now 10,20,150 30,40,150     a box (either order of corners)
    fort/deconstruct-now -c              remove, but drop no materials
    fort/deconstruct-now -d here         drop all the materials under the cursor instead

What counts as "marked for removal": DF's own Remove Construction designation on the tile,
or a Remove Construction job already posted for it -- DF clears the designation the moment
it posts the job, so a tile a dwarf is already walking towards is still on the list. One
exception: a job a dwarf is already HOLDING is left to that dwarf. Pulling a job out from
under its worker frees a struct DF is still pointing at, and that is a crash this fort has
already seen; it is counted and reported instead.

The floor a constructed wall put on top of itself STAYS when the wall comes out, as it does
when a dwarf pulls the wall: that is DF's rule (it is how floating floors get made), and the
first cut of this got it backwards and took the floors too. Nothing above or beside the
removed tile is touched, so a wall that was holding something up leaves it hanging until
DF's next collapse check -- again, the same as a dwarf pulling it.

Planned-but-unbuilt constructions are buildings, not constructions, and DF's own cancel
already removes those instantly; they are not touched here. Neither are built buildings
queued for deconstruction (a workshop marked with `x`): only constructions.

No dwarf gets experience, and no dwarf walks anywhere. That is the point.
]]

local argparse = require('argparse')
local utils = require('utils')

local DV = df.tile_dig_designation
local BASIC = df.tiletype_shape_basic
local SHAPE = df.tiletype_shape

-- ---- bounds --------------------------------------------------------------------

local function map_bounds()
    local x, y, z = dfhack.maps.getTileSize()
    return {x1 = 0, y1 = 0, z1 = 0, x2 = x - 1, y2 = y - 1, z2 = z - 1}
end

local function box_of(a, b)
    return {x1 = math.min(a.x, b.x), y1 = math.min(a.y, b.y), z1 = math.min(a.z, b.z),
            x2 = math.max(a.x, b.x), y2 = math.max(a.y, b.y), z2 = math.max(a.z, b.z)}
end

local function inside(box, p)
    return p.x >= box.x1 and p.x <= box.x2 and p.y >= box.y1 and p.y <= box.y2
        and p.z >= box.z1 and p.z <= box.z2
end

-- ---- what to take down ---------------------------------------------------------

local function designation_at(p)
    local blk = dfhack.maps.getTileBlock(p)
    return blk and blk.designation[p.x % 16][p.y % 16]
end

-- Remove Construction jobs, keyed by tile: the designation is gone once the job exists
local function removal_jobs()
    local set = {}
    for _, j in utils.listpairs(df.global.world.jobs.list) do
        if j.job_type == df.job_type.RemoveConstruction then
            set[('%d,%d,%d'):format(j.pos.x, j.pos.y, j.pos.z)] = j
        end
    end
    return set
end

local function key(p) return ('%d,%d,%d'):format(p.x, p.y, p.z) end

-- ---- taking one down -----------------------------------------------------------

-- the tile the dropped material lands on: the tile itself, or the first non-air tile below
local function landing(p)
    local z = p.z
    while z > 0 do
        local tt = dfhack.maps.getTileType(p.x, p.y, z)
        if not tt then break end
        local basic = SHAPE.attrs[df.tiletype.attrs[tt].shape].basic_shape
        if basic ~= BASIC.Open then break end
        z = z - 1
    end
    return xyz2pos(p.x, p.y, z)
end

local creator
local function drop_material(c, at)
    if c.flags.no_build_item then return false end
    if not creator then
        creator = dfhack.units.getCitizens(true)[1]
        if not creator then return false end
    end
    -- not `no_floor`: an item minted in limbo can never be moved anywhere afterwards
    local ok, items = pcall(dfhack.items.createItem, creator, c.item_type, c.item_subtype,
                            c.mat_type, c.mat_index, false)
    local item = ok and items and items[1]
    if type(item) == 'table' then item = item[1] end
    if not item then return false end
    return dfhack.items.moveToGround(item, at)
end

-- put the tile back to what it was, clear the mark, and let DF know the map changed
local function restore_tile(c)
    local p = c.pos
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return end
    local orig = c.original_tile
    if not orig or orig <= 0 then orig = df.tiletype.OpenSpace end
    blk.tiletype[p.x % 16][p.y % 16] = orig
    blk.designation[p.x % 16][p.y % 16].dig = DV.No
    dfhack.maps.enableBlockUpdates(blk, true, true)
end

-- erase the record from the world's construction list (sorted; found by position)
local function erase_record(c)
    local vec = df.global.world.event.constructions
    for i = #vec - 1, 0, -1 do
        if vec[i] == c then
            vec:erase(i)
            c:delete()
            return true
        end
    end
    return false
end

-- ---- the pass ------------------------------------------------------------------

local function run(box, opts)
    local jobs = removal_jobs()
    local targets, held = {}, 0
    for _, c in ipairs(df.global.world.event.constructions) do
        if inside(box, c.pos) then
            local des = designation_at(c.pos)
            local job = jobs[key(c.pos)]
            if job and dfhack.job.getWorker(job) then
                held = held + 1
            elseif job or (des and des.dig == DV.Default) then
                targets[#targets + 1] = {c = c, job = job}
            end
        end
    end

    local removed, dropped = 0, 0
    for _, t in ipairs(targets) do
        local c = t.c
        if t.job then pcall(dfhack.job.removeJob, t.job) end
        local at = opts.dump or landing(c.pos)
        if not opts.clean and drop_material(c, at) then dropped = dropped + 1 end
        restore_tile(c)
        if erase_record(c) then removed = removed + 1 end
    end
    if removed > 0 then df.global.world.reindex_pathfinding = true end
    return removed, dropped, held
end

-- ---- command -------------------------------------------------------------------

if not dfhack.isMapLoaded() then qerror('deconstruct-now needs a loaded fortress map') end

local opts = {clean = false, dump = nil, cur_z = false}
local positionals = argparse.processArgsGetopt({...}, {
    {'c', 'clean', handler = function() opts.clean = true end},
    {'d', 'dump', hasArg = true, handler = function(arg) opts.dump = argparse.coords(arg, 'dump') end},
    {'z', 'cur-zlevel', handler = function() opts.cur_z = true end},
    {'h', 'help', handler = function() print(dfhack.script_help()) os.exit() end},
})

local box
if #positionals >= 2 then
    box = box_of(argparse.coords(positionals[1], 'pos'), argparse.coords(positionals[2], 'pos'))
elseif #positionals == 1 then
    local p = argparse.coords(positionals[1], 'pos')
    box = box_of(p, p)
else
    box = map_bounds()
end
if opts.cur_z then box.z1, box.z2 = df.global.window_z, df.global.window_z end

local removed, dropped, held = run(box, opts)
print(('deconstruct-now: removed %d construction%s, dropped %d item%s.')
    :format(removed, removed == 1 and '' or 's', dropped, dropped == 1 and '' or 's'))
if held > 0 then
    print(('  %d left alone: a dwarf already holds the removal job.'):format(held))
end
