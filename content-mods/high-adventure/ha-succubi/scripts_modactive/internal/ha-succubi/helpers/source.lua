--@ module = true

-- This is a copy of the source script but designed as a modtool.
local repeatUtil = require('repeat-util')

local GLOBAL_KEY = 'ha-succubi-source' -- used for state change hooks and persistence
local debug = false

g_sources_list = g_sources_list or {}

local function persist_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, g_sources_list)
    if debug then print("source: saved g_sources_list") end
end

local function formatPos(pos)
    return ('[%d, %d, %d]'):format(pos.x, pos.y, pos.z)
end

local function is_flow_passable(pos)
    local tiletype = dfhack.maps.getTileType(pos)
    local titletypeAttrs = df.tiletype.attrs[tiletype]
    local shape = titletypeAttrs.shape
    local tiletypeShapeAttrs = df.tiletype_shape.attrs[shape]
    return tiletypeShapeAttrs.passable_flow
end

local function load_liquid_source()
    if debug then print("source: registering action") end

    repeatUtil.scheduleEvery(GLOBAL_KEY, 12, 'ticks', function()
        if not next(g_sources_list) then
            if debug then print("source: no sources, unregistering action") end
            repeatUtil.cancel(GLOBAL_KEY)
        else
            for _, v in ipairs(g_sources_list) do
                local block = dfhack.maps.getTileBlock(v.pos)
                if block and is_flow_passable(v.pos) then
                    local isMagma = v.liquid == 'magma'

                    local flags = dfhack.maps.getTileFlags(v.pos)
                    local flow = flags.flow_size

                    if flow ~= v.amount then
                        local target = flow + 1
                        if flow > v.amount then
                            target = flow - 1
                        end

                        flags.liquid_type = isMagma
                        flags.flow_size = target
                        flags.flow_forbid = (isMagma or target >= 4)

                        dfhack.maps.enableBlockUpdates(block, true)
                    end
                end
            end
        end
    end)
end

local function delete_source_at(key)
    local v = g_sources_list[key]

    if v then
        local block = dfhack.maps.getTileBlock(v.pos)
        if block and is_flow_passable(v.pos) then
            local flags = dfhack.maps.getTileFlags(v.pos)
            flags.flow_size = 0
            dfhack.maps.enableBlockUpdates(block, true)
        end
        g_sources_list[key] = nil
    end
end

local function wipe_sources()
    for k, v in ipairs(g_sources_list) do
        delete_source_at(k)
    end
    if debug then print("source: wiped") end
end

function add_liquid_source(pos, liquid, amount)
    local new_source = {liquid = liquid, amount = amount, pos = copyall(pos)}
    print(("Adding %d %s to %s"):format(amount, liquid, formatPos(pos)))
    for k, v in ipairs(g_sources_list) do
        if same_xyz(pos, v.pos) then
            delete_source_at(k)
        end
    end

    table.insert(g_sources_list, new_source)

    persist_state()
    load_liquid_source()
end

function delete_liquid_source(pos)
    print(("Deleting Source at %s"):format(formatPos(pos)))
    for k, v in ipairs(g_sources_list) do
        if same_xyz(pos, v.pos) then
            print("Source Found")
            delete_source_at(k)
        end
    end

    persist_state()
end

function clear_liquid_sources()
    wipe_sources()
    persist_state()
end

function list_liquid_sources()
    print('Current Liquid Sources:')
    for _,v in ipairs(g_sources_list) do
        print(('%s %s %d'):format(formatPos(v.pos), v.liquid, v.amount))
    end
end

function onLoad()
    g_sources_list = dfhack.persistent.getSiteData(GLOBAL_KEY, {})

    if debug then list_liquid_sources() end

    load_liquid_source()
end

function onUnload()
    wipe_sources()
end
