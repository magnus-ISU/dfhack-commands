-- Removes airborne flow clouds (miasma, smoke, mist, steam, dust, ...) from the map.
--@ module = false
--[[
Residual flow clouds keep being simulated every tick and can wreck FPS long
after whatever produced them is gone -- classically, tens of thousands of
miasma clouds left over from a cavern/battlefield full of rotting corpses.
This wipes them in a single pass.

Usage:
    clear-flows                clear ALL flow clouds
    clear-flows Miasma Smoke   clear only the listed flow type(s)

Flow type names come from df.flow_type, e.g.:
    Miasma  Steam  Mist  MaterialDust  MagmaMist  Smoke  Dragonfire  Fire
    Web  MaterialGas  MaterialVapor  OceanWave  SeaFoam  ItemCloud

NOTE: this removes the clouds, not their source. If something is still
generating them (rotting items, an active fire, magma meeting water), clear the
source too -- otherwise the clouds simply come back. The usual companion fix is
to dump/destroy the rotting corpses or items feeding the miasma.
]]

local args = {...}

-- optional flow-type filter
local filter
if #args > 0 then
    filter = {}
    for _, name in ipairs(args) do
        local id = df.flow_type[name]
        if id == nil then
            qerror(('unknown flow type: %q (see df.flow_type)'):format(name))
        end
        filter[id] = true
    end
end

local function type_name(t)
    return df.flow_type[t] or tostring(t)
end

local w = df.global.world
local cleared, blocks = 0, 0
local bytype = {}

for _, b in pairs(w.map.map_blocks) do
    local n = #b.flows
    if n > 0 then
        if not filter then
            -- fast path: drop every flow in the block at once
            for i = 0, n - 1 do
                local tn = type_name(b.flows[i].type)
                bytype[tn] = (bytype[tn] or 0) + 1
            end
            cleared = cleared + n
            blocks = blocks + 1
            b.flows:resize(0)
        else
            -- selective: erase matching flows from the back so indices stay valid
            local removed = 0
            for i = n - 1, 0, -1 do
                local t = b.flows[i].type
                if filter[t] then
                    local tn = type_name(t)
                    bytype[tn] = (bytype[tn] or 0) + 1
                    b.flows:erase(i)
                    removed = removed + 1
                end
            end
            if removed > 0 then
                cleared = cleared + removed
                blocks = blocks + 1
            end
        end
    end
end

print(('Cleared %d flow object%s from %d map block%s.'):format(
    cleared, cleared == 1 and '' or 's', blocks, blocks == 1 and '' or 's'))
if cleared > 0 then
    local parts = {}
    for t, c in pairs(bytype) do parts[#parts + 1] = ('  %-14s %d'):format(t, c) end
    table.sort(parts)
    print(table.concat(parts, '\n'))
else
    print('No matching flows found.')
end
