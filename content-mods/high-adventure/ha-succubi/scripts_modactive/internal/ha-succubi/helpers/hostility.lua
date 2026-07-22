--@module = true

-- Remove the enemy status cache and conflict activities involving this unit
function ClearEnemyCache(unit)
	if unit.enemy.enemy_status_slot ~= -1 then
		local status_slot = unit.enemy.enemy_status_slot
		local status_cache = df.global.world.enemy_status_cache

		unit.enemy.enemy_status_slot = -1
		status_cache.slot_used[status_slot] = false

		for index, _ in pairs(status_cache.rel_map[status_slot]) do
			status_cache.rel_map[status_slot][index] = -1
		end

		if status_cache.next_slot > status_slot then
            status_cache.next_slot = status_slot
        end
	end
end