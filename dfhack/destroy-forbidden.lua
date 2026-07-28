-- Destroys all forbidden items that are loose on the ground
-- (skips items in inventories, buildings, or that are artifacts)

local count = 0
for i = #df.global.world.items.all-1, 0, -1 do
    local item = df.global.world.items.all[i]
    if item
       and item.flags.forbid
       and not item.flags.in_inventory
       and not item.flags.in_building
       and not item.flags.artifact then
        dfhack.items.remove(item)
        count = count + 1
    end
end

print(("Destroyed %d forbidden items."):format(count))
