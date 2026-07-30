--@module = true

local eventful = require("plugins.eventful")
local syndromeUtil = require("syndrome-util")
local syndromes = reqscript("internal/ha-succubi/helpers/syndromes")

-- Dummy transform to make sure DF updates the sprite
local transformSyndromeName = "HA_SUCCUBUS_TF"
local transformSyndrome = nil

function onLoad()
	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_FIRE_SECRET", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)
	
	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_LUST_SECRET", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_DEPRAVITY_SECRET", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_THRALLDOM_SECRET", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_PHASING", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_FACE_MELTER", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)
	
	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_SLAM", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_UPGRADE_FIREBALL", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_POWER_CLEAR", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		ClearPowers(unit)
		call_native = false
	end)

	print("Powers activated")
end

-- Main action
function RunPower(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
	local isMajor = IsMajorSyndrome(reaction.code)

	if not IsSuccubus(unit) then
		CancelReaction(reaction, unit, input_reagents, "not a succubus or corrupted caste")
	elseif HasSyndromeClass(unit, isMajor) then
		local reason

		if isMajor then
			reason = 'already have a major power'
		else
			reason = 'already have a minor power'
		end

		CancelReaction(reaction, unit, input_reagents, reason)
	else
		ActivatePower(unit, reaction.code)
	end
end

-- Adds the power on the unit
function ActivatePower(unit, reactionCode)
	local synName = GetSyndromeName(reactionCode)
	local syndrome = syndromes.GetSyndrome(synName)

	if syndrome == nil then
		qerror("Syndrome for reaction " .. reactionCode .. " not found!")
		return
	end

	syndromeUtil.infectWithSyndromeIfValidTarget(unit, syndrome, syndromeUtil.ResetPolicy.DoNothing)
	syndromeUtil.infectWithSyndromeIfValidTarget(unit, GetDummySyndrome(), syndromeUtil.ResetPolicy.DoNothing)

	local message = string.format("%s has learned %s.", dfhack.translation.translateName(dfhack.units.getVisibleName(unit)), synName)
	print("ha-succubi: " .. message)
	dfhack.gui.showAnnouncement(message, COLOR_WHITE)
end

-- Return the name of the syndrome matching the reaction
function GetSyndromeName(reactionCode)
	if reactionCode == 'HA_SUCCUBUS_UPGRADE_FIRE_SECRET' then
		return 'Pyromaniac'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_LUST_SECRET' then
		return 'Courtesan'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_DEPRAVITY_SECRET' then
		return 'Debauchee'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_THRALLDOM_SECRET' then
		return 'Archvile'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_PHASING' then
		return 'Dimensional Phasing'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_FACE_MELTER' then
		return 'Face Melter'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_SLAM' then
		return 'Abyssal Gravity'
	elseif reactionCode == 'HA_SUCCUBUS_UPGRADE_FIREBALL' then
		return 'Gehenna Fireball'
	else
		return nil
	end
end

-- Return true is the reaction results in a major power, false otherwise
function IsMajorSyndrome(reactionCode)
	return string.sub(reactionCode, -7) == '_SECRET'
end

-- Return true if the unit already learned a power of this class.
function HasSyndromeClass(unit, isMajor)
	local synClass

	if(isMajor) then
		synClass = 'MAJOR_POWER'
	else
		synClass = 'MINOR_POWER'
	end

	for i, unitSyndrome in ipairs(unit.syndromes.active) do
		local syndrome = df.syndrome.find(unitSyndrome.type)

		for _, class in ipairs(syndrome.syn_class) do
			if class.value == synClass then
				return true
			end
		end
	end

	return false
end

-- Return true if the unit is a succubus (no matter the caste)
function IsSuccubus(unit)
	return tostring(df.global.world.raws.creatures.all[unit.race].creature_id) == "HA_SUCCUBUS_CIV"
end

-- Simulate a canceled reaction message, save the reagents
function CancelReaction(reaction, unit, input_reagents, reason)
	local message = string.format(
		"%s, %s cancels %s: %s.",
		dfhack.translation.translateName(dfhack.units.getVisibleName(unit)),
		dfhack.units.getProfessionName(unit),
		reaction.name,
		reason 
	)

	--announcements are broken
	print("ha-succubi: " .. message)
	--dfhack.gui.autoDFAnnouncement(df.announcement_type.cancel_job, unit.pos, message, COLOR_YELLOW)
	dfhack.gui.showAnnouncement(message, COLOR_WHITE)

	for _, v in ipairs(input_reagents or {}) do
		v.flags.PRESERVE_REAGENT = true
	end
end

-- Remove both powers from the unit
function ClearPowers(unit)
	local isRemoved = syndromeUtil.eraseSyndromeClass(unit, "MAJOR_POWER")
	isRemoved = isRemoved + syndromeUtil.eraseSyndromeClass(unit, "MINOR_POWER")

	if isRemoved > 0 then
		local message = string.format("%s has lost their powers.", dfhack.translation.translateName(dfhack.units.getVisibleName(unit)))
		print("ha-succubi: " .. message)
		dfhack.gui.showAnnouncement(message, COLOR_WHITE)
	end
end

-- Get the dummy transform syndrome
function GetDummySyndrome()
	if transformSyndrome then
		return transformSyndrome
	end

	transformSyndrome = syndromes.GetSyndrome(transformSyndromeName)

	if transformSyndrome == nil then
		qerror("Dummy transform syndrome not found!")
		return
	end

	return transformSyndrome
end