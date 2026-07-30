--@module = true

local eventful = require("plugins.eventful")
local source = reqscript("internal/ha-succubi/helpers/source")
local utils = require("utils")

local debug = false

function Debug()
	source.list_liquid_sources()
end

function onLoad()
	RegisterMagmaWell("N")
	RegisterMagmaWell("S")
	RegisterMagmaWell("E")
	RegisterMagmaWell("W")

	if debug then print("Register reaction STOP_SPAWN") end
	eventful.registerReaction("HA_SUCCUBUS_STOP_SPAWN", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		source.clear_liquid_sources()
		call_native = false
	end)

	source.onLoad()
	print("Magmawell activated")
end

function onUnload()
	source.onUnload()
	print("Magmawell deactivated")
end

-- Add the reactions to eventful, one for each liquid level for the given direction (N, S, E or W)
function RegisterMagmaWell(direction)
	if debug then print("Register reaction " .. direction) end

	for i = 7, 1, -1 do
		RegisterReaction(direction, i)
	end 

	local stopReactionName = "HA_SUCCUBUS_MAGMAWELL_" .. direction .. "_STOP"

	eventful.registerReaction(stopReactionName, function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		local pos = copyall(unit.pos)
		RemoveSource(pos, direction)
		call_native = false
	end)
end

-- Register one reaction for one direction (N, S, E or W) and depth (1 to 7)
function RegisterReaction(direction, depth)
	local reactionName = "HA_SUCCUBUS_MAGMAWELL_" .. direction .. "_" .. depth

	eventful.registerReaction(reactionName, function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		local pos = copyall(unit.pos)
		AddSource(pos, direction, depth)
		call_native = false
	end)
end

-- Add a liquid source according to the direction (N, S, E or W) and depth (1 to 7)
function AddSource(pos, direction, depth)
	local sourcePos = GetAdjustedPosition(pos, direction)
	source.add_liquid_source(sourcePos, 'magma', depth)
end

-- Remove a liquid source according to the direction
function RemoveSource(pos, direction)
	local sourcePos = GetAdjustedPosition(pos, direction)
	source.delete_liquid_source(sourcePos)
end

-- Get a square next to the workshop in a cardinal direction (N, S, E or W) and one z-level below
function GetAdjustedPosition(pos, direction)
	pos.z = pos.z - 1

	if direction == "N" then
		pos.y = pos.y - 2
	end

	if direction == "S" then
		pos.y = pos.y + 2
	end

	if direction == "E" then
		pos.x = pos.x + 2
	end

	if direction == "W" then
		pos.x = pos.x - 2
	end

	return pos
end
