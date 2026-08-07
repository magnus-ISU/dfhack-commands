-- Adventure mode: sort "heat ice" / "heat snow" options to the top of the interact menu.
--@module = true
--[[
adv/heat-ice

Melting drinking water at a campfire means hunting for the "Heat the ice with the fire" rows in
the right-click / interact menu, which DF buries under a screenful of other options. Whenever an
option list holds heat-from-tile rows (df class adventure_item_interact_heat_from_tilest), this
overlay reorders the list in place: heat rows whose item is ice or snow first, any other heat
rows next, everything else after, each group keeping its original relative order. Checked by row
TYPE, not by screen text, and in every option_list context -- the rows are recognized wherever
they appear.

The reorder is a pointer shuffle inside the live option vector (no resize, no new rows), redone
only when the row set changes (open / rebuild), so it doesn't fight the menu while you scroll.
Row hotkeys are positional in DF, so the promoted rows also get the first letters -- that is the
point.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local overlay = require('plugins.overlay')

local function ol() return df.global.game.main_interface.adventure.option_list end

local function is_heat(opt)
    return df.adventure_item_interact_heat_from_tilest:is_instance(opt)
end

-- word-boundary match so "ice" can't hit "rice"/"slice"/"dice" in an item description
local function is_ice_or_snow(opt)
    local ok, it = pcall(function() return opt.item end)
    if not ok or not it then return false end
    local ok2, d = pcall(dfhack.items.getReadableDescription, it)
    if not ok2 or not d then return false end
    d = d:lower()
    return d:find('%f[%a]ice%f[%A]') ~= nil or d:find('%f[%a]snow%f[%A]') ~= nil
end

-- stable three-way partition: ice/snow heat rows, other heat rows, the rest
local function partition(vec)
    local first, second, rest = {}, {}, {}
    for i = 0, #vec - 1 do
        local opt = vec[i]
        if is_heat(opt) then
            if is_ice_or_snow(opt) then first[#first + 1] = opt
            else second[#second + 1] = opt end
        else
            rest[#rest + 1] = opt
        end
    end
    if #first + #second == 0 then return nil end   -- nothing to promote
    for _, opt in ipairs(second) do first[#first + 1] = opt end
    for _, opt in ipairs(rest) do first[#first + 1] = opt end
    return first
end

local function already_ordered(vec, want)
    for i = 1, #want do
        if vec[i - 1] ~= want[i] then return false end
    end
    return true
end

HeatIce = defclass(HeatIce, overlay.OverlayWidget)
HeatIce.ATTRS{
    desc = 'Adventure mode: sort heat-ice/heat-snow options first in interact menus.',
    default_pos = {x = 1, y = 3},
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function HeatIce:overlay_onupdate()
    local o = ol()
    if not o.open then self.last_n = -1; return end
    -- re-partition only when the row set changes (open or DF rebuild), not every frame
    if #o.option == self.last_n then return end
    self.last_n = #o.option
    local want = partition(o.option)
    if want and not already_ordered(o.option, want) then
        o.option:assign(want)
    end
end

OVERLAY_WIDGETS = {sorter = HeatIce}

if dfhack_flags and dfhack_flags.module then return end

print('adv/heat-ice: overlay registered.')
print('Heat-ice/heat-snow options now sort to the top of adventure interact menus.')
