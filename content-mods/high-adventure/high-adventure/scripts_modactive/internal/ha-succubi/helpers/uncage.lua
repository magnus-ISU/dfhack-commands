--@module = true

local utils = require("utils")
local isDebug = false

-- Take the creature out of its cage
function ReleaseFromCage(unit)
	local cage = dfhack.units.getContainer(unit)
	
	if cage and cage ~= -1 then
		local pos = xyz2pos(dfhack.units.getPosition(unit))
		local i, ref
		--dfhack.units.teleport(unit, pos) --broken atm

		unit.pos.x = pos.x
		unit.pos.y = pos.y
		unit.pos.z = pos.z

		for i, ref in ipairs(cage.general_refs) do
			if df.general_ref_contains_unitst:is_instance(ref) and ref.unit_id == unit.id then
				cage.general_refs[i]:delete()
            end
		end

		local building = dfhack.items.getHolderBuilding(cage)

		if building then
			RemoveAssignation(building, unit)
		end

		for i, ref in ipairs(unit.general_refs) do
			if df.general_ref_contained_in_itemst:is_instance(ref) and ref.item_id == cage.id then
				unit.general_refs[i]:delete()
            end
		end
	end

	unit.flags1.caged = false
end

function RemoveAssignation(building, unit)
	if not df.building_cagest:is_instance(building) then
		if isDebug then print ('Not a cage') end
		return
	end

	for i, unitId in ipairs(building.assigned_units) do
		if isDebug then print ('Assigned ' .. unitId .. " unit " .. unit.id) end
		if unitId == unit.id then
			building.assigned_units[i] = -1
		end
	end
end
