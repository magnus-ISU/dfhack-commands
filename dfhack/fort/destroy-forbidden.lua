-- Destroys forbidden items lying on the ground.
--[[
fort/destroy-forbidden

Removes every FORBIDDEN item loose on the ground. Items in someone's inventory or built into
a building are never touched -- the forbid flag on those means something else, and taking a
workshop apart is not what anybody asked for.

    fort/destroy-forbidden                 the whole map
    fort/destroy-forbidden onscreen        only what is drawn right now (see below)
    fort/destroy-forbidden artifacts       artifacts too
    fort/destroy-forbidden onscreen artifacts

ONSCREEN is the way to use this as a pointing device: forbid what you want gone, look at it,
and run it. The box is the map viewport exactly as rendered -- `gui.dwarfmode.Viewport.get()`
-- so it is one z-level, the one you are looking at, and only the tiles between its corners.
Nothing above, below or off the edge is at risk, which makes a mistake cost you what you can
see rather than the fort.

ARTIFACTS are excluded by default and that default is deliberate: an artifact is unrecoverable
and usually forbidden precisely to keep it safe. Ask for them by name and they go too.
]]

local args = {...}
local flags = {}
for _, a in ipairs(args) do flags[a:lower()] = true end

for a in pairs(flags) do
    if a ~= 'onscreen' and a ~= 'artifacts' then
        qerror(('destroy-forbidden: unknown argument "%s" (want: onscreen, artifacts)'):format(a))
    end
end

-- the rendered box, or nil for the whole map
local box
if flags.onscreen then
    if not dfhack.world.isFortressMode() or not dfhack.isMapLoaded() then
        qerror('destroy-forbidden: onscreen needs a fort on screen')
    end
    local ok, vp = pcall(function() return require('gui.dwarfmode').Viewport.get() end)
    if not ok or not vp then qerror('destroy-forbidden: could not read the map viewport') end
    box = {x1 = vp.x1, y1 = vp.y1, x2 = vp.x2, y2 = vp.y2, z = vp.z}
end

local function in_box(item)
    if not box then return true end
    local p = item.pos
    -- one z-level: the one being rendered. An item a level down is not "on screen"
    -- however visible its tile is through a hole in the floor.
    return p.z == box.z and p.x >= box.x1 and p.x <= box.x2
        and p.y >= box.y1 and p.y <= box.y2
end

local count, artifacts = 0, 0
for i = #df.global.world.items.all - 1, 0, -1 do
    local item = df.global.world.items.all[i]
    if item
        and item.flags.forbid
        and not item.flags.in_inventory
        and not item.flags.in_building
        and (flags.artifacts or not item.flags.artifact)
        and in_box(item)
    then
        if item.flags.artifact then artifacts = artifacts + 1 end
        dfhack.items.remove(item)
        count = count + 1
    end
end

print(('Destroyed %d forbidden item%s%s%s.'):format(
    count, count == 1 and '' or 's',
    box and (' on screen (z%d, %d,%d-%d,%d)'):format(box.z, box.x1, box.y1, box.x2, box.y2) or '',
    artifacts > 0 and (', %d of them artifact%s'):format(artifacts, artifacts == 1 and '' or 's') or ''))
