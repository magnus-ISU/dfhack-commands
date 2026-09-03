-- Burrows for fort/planeswalkers: each burrow's name, look, options, member
-- units and every tile it covers.
--@module = true

local common = reqscript('internal/planeswalkers/common')

local FILE = '/burrows.json'

-- tiles of a burrow as {bx, by, z, mask...} per block, mask = 16 words of
-- 16 bits (the block's tile_bitmask), block coords relative to the footprint
local function tiles_out(ctx, burrow)
    local o = ctx.origin
    local out = {}
    for _, block in ipairs(dfhack.burrows.listBlocks(burrow)) do
        local bx, by = block.map_pos.x // 16, block.map_pos.y // 16
        if bx >= o.bx and bx < o.bx + o.wb and by >= o.by and by < o.by + o.hb then
            local bb = block.block_burrows
            local node = bb.next
            while node do
                if node.item and node.item.id == burrow.id then
                    local words = {}
                    for i = 0, 15 do words[i + 1] = node.item.tile_bitmask.bits[i] end
                    table.insert(out, {bx - o.bx, by - o.by, block.map_pos.z, words})
                    break
                end
                node = node.next
            end
        end
    end
    return out
end

function save_phases(ctx)
    return {{
        name = 'burrows',
        step = function(job)
            local out = {v = 1, list = {}}
            for _, b in ipairs(df.global.plotinfo.burrows.list) do
                local ok, err = pcall(function()
                    local units = {}
                    for _, id in ipairs(b.units) do table.insert(units, id) end
                    table.insert(out.list, {
                        name = common.u(b.name), tile = b.tile, fg = b.fg_color, bg = b.bg_color,
                        symbol = b.symbol_index,
                        rgb = {b.texture_r, b.texture_g, b.texture_b},
                        flags = b.flags.whole, units = units, blocks = tiles_out(ctx, b),
                    })
                end)
                if not ok then common.add_skip(ctx, 'burrow-save-error', tostring(err)) end
            end
            common.write_json(ctx.dir .. FILE, out)
            ctx.manifest.counts.burrows = #out.list
            print(('planeswalkers: %d burrow(s) saved'):format(#out.list))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function next_burrow_id()
    local info = df.global.plotinfo.burrows
    local ok, v = pcall(function() return info.next_id end)
    if ok and v then return v end
    local m = -1
    for _, b in ipairs(info.list) do if b.id > m then m = b.id end end
    return m + 1
end

local function bump_next_id(id)
    pcall(function()
        local info = df.global.plotinfo.burrows
        if info.next_id <= id then info.next_id = id + 1 end
    end)
end

function load_phases(ctx)
    return {{
        name = 'burrows',
        init = function(job)
            job.data = common.read_json(ctx.dir .. FILE) or {list = {}}
            job.cursor, job.block_cursor = 1, 1
            job.made = 0
            job.tiles = 0
        end,
        total = function(job) return #job.data.list end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            while job.cursor <= #job.data.list do
                local rec = job.data.list[job.cursor]
                if not job.current then
                    local ok, err = pcall(function()
                        local b = df.burrow:new()
                        b.id = next_burrow_id()
                        bump_next_id(b.id)
                        b.name = common.fromu(rec.name or '')
                        b.tile, b.fg_color, b.bg_color = rec.tile or 43, rec.fg or 11, rec.bg or 3
                        b.symbol_index = rec.symbol or 0
                        if rec.rgb then b.texture_r, b.texture_g, b.texture_b = rec.rgb[1], rec.rgb[2], rec.rgb[3] end
                        pcall(function() b.flags.whole = rec.flags or 0 end)
                        df.global.plotinfo.burrows.list:insert('#', b)
                        for _, old in ipairs(rec.units or {}) do
                            local u = ctx.unit_map and ctx.unit_map[old]
                            if u then dfhack.burrows.setAssignedUnit(b, u, true) end
                        end
                        job.current = b
                        job.block_cursor = 1
                    end)
                    if not ok then
                        common.add_skip(ctx, 'burrow-restore-failed', tostring(err))
                        job.cursor = job.cursor + 1
                        goto continue
                    end
                end
                -- tiles, block by block, against the deadline
                while job.block_cursor <= #(rec.blocks or {}) do
                    local blk = rec.blocks[job.block_cursor]
                    job.block_cursor = job.block_cursor + 1
                    local z = blk[3] + a.off_z
                    local block = dfhack.maps.getBlock(blk[1] + a.off_bx, blk[2] + a.off_by, z)
                    if block and z >= 0 then
                        local words = blk[4]
                        for x = 0, 15 do
                            local w = words[x + 1] or 0
                            if w ~= 0 then
                                for y = 0, 15 do
                                    if w & (1 << y) ~= 0 then
                                        dfhack.burrows.setAssignedBlockTile(job.current, block, x, y, true)
                                        job.tiles = job.tiles + 1
                                    end
                                end
                            end
                        end
                    end
                    if dfhack.getTickCount() >= deadline then return false end
                end
                job.made = job.made + 1
                job.current = nil
                job.cursor = job.cursor + 1
                ::continue::
                if dfhack.getTickCount() >= deadline then return false end
            end
            print(('planeswalkers: %d burrow(s) restored covering %d tile(s)'):format(job.made, job.tiles))
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
