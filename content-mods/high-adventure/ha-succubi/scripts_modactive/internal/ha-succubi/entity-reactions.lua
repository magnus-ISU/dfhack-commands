--@module = true
--This module insert workshops and reactions to the player's entity, if they are playing a specific entity.
--It is designed to avoid displaying dfhack workshops and reactions to players who did not install the tool.

local utils = require("utils")
local data = reqscript("internal/ha-succubi/data/reactions")

-- Return the player entity if it match the mod
function GetPlayerCiv()
	local entity = utils.binsearch(df.global.world.entities.all, df.global.plotinfo.civ_id, "id")

	if entity and entity.entity_raw.code == data.civCode then
		return entity
	else
		return nil
	end
end

function onLoad()
	local entity = GetPlayerCiv()
	if not entity then return end

	for i = 1, #data.workshops do
		AddWorkshop(entity, data.workshops[i])
	end

	for i = 1, #data.reactions do
		AddReaction(entity, data.reactions[i])
	end

	print("Added workshops and reaction to the entity.")
end

-- Add a reaction to the entity
function AddReaction(entity, code)
	local reactionRaw = FindReactionRaw(code)

	if not reactionRaw then
		qerror("Reaction "..code.." not found!")
	end

	local permitted = entity.entity_raw.workshops.permitted_reaction_id
	utils.insert_sorted(permitted, reactionRaw.index)
end

-- Add a workshop to the entity
function AddWorkshop(entity, code)
	if not GetPlayerCiv() then return end

	local workshopRaw = FindWorkshopRaw(code)

	if not workshopRaw then
		qerror("Workshop "..code.." not found!")
	end

	local permitted = entity.entity_raw.workshops.permitted_building_id
	utils.insert_sorted(permitted, workshopRaw.id)
end

-- Find a reaction's raw by its code
function FindReactionRaw(code)
	for _, reaction in ipairs(df.global.world.raws.reactions.reactions) do
		if reaction.code == code then
			return reaction
		end
	end
end

-- Find a workshop's raw by its code
function FindWorkshopRaw(code)
	for _, workshop in ipairs(df.global.world.raws.buildings.workshops) do
		if workshop.code == code then
			return workshop
		end
	end
end