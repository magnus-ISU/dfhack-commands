-- Trees, saplings and shrubs for fort/planeswalkers. A plant is a world-local
-- object (a full tree carries a generated trunk/branch layout), so each is
-- saved as what it is and where, and rebuilt through the plant plugin: a
-- shrub or sapling is created in place, a tree is created as a sapling and
-- grown on the spot.
--@module = true

local common = reqscript('internal/planeswalkers/common')

local FILE = '/plants.json'

function save_phases(ctx)
    return {{
        name = 'plants',
        step = function(job)
            local o = ctx.origin
            local out = {v = 1, list = {}}
            local trees = 0
            for _, p in ipairs(df.global.world.plants.all) do
                if common.in_footprint(ctx, p.pos.x, p.pos.y) then
                    local ok, err = pcall(function()
                        local raw = df.plant_raw.find(p.material)
                        if raw then
                            local tree = p.tree_info ~= nil
                            if tree then trees = trees + 1 end
                            table.insert(out.list, {
                                x = p.pos.x - o.x, y = p.pos.y - o.y, z = p.pos.z,
                                id = raw.id, tree = tree or nil,
                                grow = p.grow_counter, hp = p.hitpoints,
                                dead = p.damage_flags.dead or nil,
                            })
                        end
                    end)
                    if not ok then common.add_skip(ctx, 'plant-save-error', tostring(err)) end
                end
            end
            common.write_json(ctx.dir .. FILE, out)
            ctx.manifest.counts.plants = #out.list
            print(('planeswalkers: %d plant(s) saved (%d trees)'):format(#out.list, trees))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function run_quiet(...)
    local args = {...}
    local ok, res = pcall(function() return dfhack.run_command_silent(table.unpack(args)) end)
    return ok and res or ''
end

function load_phases(ctx)
    return {{
        name = 'plants',
        init = function(job)
            job.data = common.read_json(ctx.dir .. FILE) or {list = {}}
            job.cursor = 1
            job.made, job.grown = 0, 0
            job.to_grow = {}
        end,
        total = function(job) return #job.data.list + 1 end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            local map = df.global.world.map
            while job.cursor <= #job.data.list do
                local rec = job.data.list[job.cursor]
                job.cursor = job.cursor + 1
                local x, y, z = rec.x + a.off_x, rec.y + a.off_y, rec.z + a.off_z
                if z >= 1 and z < map.z_count - 1 and not rec.dead then
                    local before = #df.global.world.plants.all
                    local pos = ('%d,%d,%d'):format(x, y, z)
                    local out = run_quiet('plant', 'create', rec.id, pos, '-c')
                    if #df.global.world.plants.all > before then
                        job.made = job.made + 1
                        local p = df.global.world.plants.all[#df.global.world.plants.all - 1]
                        pcall(function()
                            if rec.hp then p.hitpoints = rec.hp end
                            if rec.grow and not rec.tree then p.grow_counter = rec.grow end
                        end)
                        if rec.tree then table.insert(job.to_grow, pos) end
                    else
                        common.add_skip(ctx, 'plant-not-placed', rec.id .. ' ' .. (out:match('[^\n]+') or ''))
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            -- grow the saplings that were trees, one command each (the plugin
            -- takes a position), against the deadline
            while #job.to_grow > 0 do
                local pos = table.remove(job.to_grow)
                run_quiet('plant', 'grow', pos)
                job.grown = job.grown + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.plants_report = ('%d plant(s) placed, %d grown into trees'):format(job.made, job.grown)
            print('planeswalkers: ' .. ctx.plants_report)
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
