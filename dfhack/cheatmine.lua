-- Instantly mine all designated tiles, including stairway designations.
--[[
cheatmine

One-shot cheat: everything currently DESIGNATED for digging -- mining, channels, ramps,
and carved up/down/up-down STAIRS -- completes instantly (via the dig-now plugin). Then
any planned CONSTRUCTED STAIRCASE (the hanging up/down staircases dig-shapes places in
air gaps of a staircase column) is instantly built too (via build-now, materials
summoned), so a dragged staircase through open space finishes end to end.

Other planned buildings (workshops, furniture, walls...) are deliberately NOT touched --
only stair constructions are completed. Use `build-now` yourself for the rest.

Usage:
    cheatmine
]]

if not dfhack.isMapLoaded() then qerror('cheatmine needs a loaded map') end

-- 1) all dig designations (mining, stairs, ramps, channels) complete instantly
local ok, err = pcall(dfhack.run_command, 'dig-now')
if not ok then qerror('cheatmine: dig-now failed: ' .. tostring(err)) end

-- 2) instantly build planned STAIR constructions (dig-shapes' air-gap staircases)
local CT = df.construction_type
local stair_sub = {
    [CT.UpStair] = true,
    [CT.DownStair] = true,
    [CT.UpDownStair] = true,
}
local built = 0
local bs = df.global.world.buildings.all
-- collect first: build-now mutates the buildings vector as it completes them
local targets = {}
for i = 0, #bs - 1 do
    local b = bs[i]
    if b:getType() == df.building_type.Construction
        and stair_sub[b.type]
        and b:getBuildStage() < b:getMaxBuildStage() then
        targets[#targets + 1] = {x = b.centerx, y = b.centery, z = b.z}
    end
end
for _, p in ipairs(targets) do
    local ok2 = pcall(dfhack.run_command, 'build-now',
        tostring(p.x), tostring(p.y), tostring(p.z))
    if ok2 then built = built + 1 end
end

print(('cheatmine: dig designations completed instantly%s.'):format(
    built > 0 and ('; %d stair construction%s built'):format(built, built == 1 and '' or 's') or ''))
