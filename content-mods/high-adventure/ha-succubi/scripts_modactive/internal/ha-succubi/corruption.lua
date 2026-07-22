--@module = true

local casteSet = reqscript("internal/ha-succubi/data/caste-set")
local eventful = require("plugins.eventful")
local fov = reqscript("internal/ha-succubi/helpers/fov")
local hostilityClear = reqscript("internal/ha-succubi/helpers/hostility")
local makeown = reqscript("makeown")
local syndromes = reqscript("internal/ha-succubi/helpers/syndromes")
local syndromeUtil = require("syndrome-util")
local uncage = reqscript("internal/ha-succubi/helpers/uncage")
local utils = require("utils")

-- The range of the check FOV
local range = 15

-- Creature to caste binding for the transformations
local defaultCaste = 'DEVIL'

-- Dummy transform to avoid some crashes
local transformSyndromeName = "HA_SUCCUBUS_TF"
local transformSyndrome = nil

-- Will print debug messages if set to true
local debug = false

function onLoad()
	eventful.registerReaction("HA_SUCCUBUS_CORRUPT_GUESTS", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		FOVCorruption(unit)
		call_native = false
	end)

	eventful.registerReaction("HA_SUCCUBUS_CORRUPT_INVADERS", function(reaction, reaction_product, unit, input_items, input_reagents, output_items, call_native)
		FOVZombify(unit)
		call_native = false
	end)

	print("Corruption activated")
end

--
-- Actions
--

-- Run corrupt on applicable targets in the position's FOV
function FOVCorruption(unitSource)
	local view = fov.get_fov(range, unitSource.pos)
	local unitList = df.global.world.units.active

	-- Check through the list for the right units
	for i = #unitList - 1, 0, -1 do
		unit = unitList[i]
		if IsCandidate(unit) and
			unit.flags1.invader_origin == false and
			IsInView(unit, view)
	 	then
			Corrupt(unitSource, unit)
		end
	end
end

-- Apply a syndrome on applicable targets in the position's FOV
function FOVZombify(unitSource)
	local view = fov.get_fov(range, unitSource.pos)
	local unitList = df.global.world.units.active
	local syndrome = syndromes.GetSyndrome("Succubus Zombify")

	if not syndrome then qerror("Zombify syndrome not found!") end

	-- Check through the list for the right units
	for i = #unitList - 1, 0, -1 do
		unit = unitList[i]
		if IsCandidate(unit) and
			unit.flags1.invader_origin == true and
			IsInView(unit, view)
	 	then
			syndromeUtil.infectWithSyndromeIfValidTarget(unit, syndrome, syndromeUtil.ResetPolicy.DoNothing)
		end
	end
end

--
-- Unit handling functions
--

-- Change the creature race, take down hostility and  merchant flags, free cages and trading
function Corrupt(unitSource, unitTarget)
	if debug then print("Corrupting unit #" .. unit.id) end

	local raceIndex = df.global.plotinfo.race_id
	local casteId = GetTargetCaste(unitTarget)

	makeown.make_own(unitTarget)

	if casteId ~= nil then
		--[[dfhack.run_script( -- marked unstable
			'modtools/transform-unit',
			'-unit', unit.id,
			'-race', raceId,
			'-caste', casteId,
			'-keepInventory'
		)]]
		local casteIndex = FindCasteIndex(casteId)
		transform(unitTarget, raceIndex, casteIndex, unitSource.population_id)
		syndromeUtil.infectWithSyndromeIfValidTarget(unit, GetDummySyndrome(), syndromeUtil.ResetPolicy.DoNothing)
	end

	hostilityClear.ClearEnemyCache(unitTarget)
	HandleUnitData(unitSource, unitTarget)
	HandleMerchant(unitTarget)
	uncage.ReleaseFromCage(unitTarget)
end

-- Takes down specifics that makeown didn't handle
function HandleUnitData(unitSource, unitTarget)
	unitTarget.population_id = unitSource.population_id

	unitTarget.flags1.coward = false

	unitTarget.invasion_id = -1
	unitTarget.relationship_ids.GroupLeader = -1
	unitTarget.relationship_ids.LastAttacker = -1
    unitTarget.enemy.army_controller_id = -1
end

-- Remove dragging and riding of mounts/wagons, draggees also join your civ
function HandleMerchant(unit)
	if unit.relationship_ids.Draggee ~= -1 then
		local dragee = utils.binsearch(df.global.world.units.active, unit.relationship_ids.Draggee, 'id')

		if dragee then
			mo.make_own(dragee)
			dragee.relationship_ids.Dragger = -1
			dragee.flags1.tame = true
			dragee.training_level = df.animal_training_level.Domesticated
		end
	end

	unit.relationship_ids.Draggee = -1
	unit.relationship_ids.RiderMount = -1
	unit.flags1.rider = false
end

-- Transform the unit, assign it the pop id
function transform(unit, raceIndex, casteIndex, pop_id)
	unit.enemy.normal_race = raceIndex
	unit.enemy.normal_caste = casteIndex
	unit.enemy.were_race = raceIndex
	unit.enemy.were_caste = casteIndex
	unit.status.current_soul.race = raceIndex
	unit.status.current_soul.caste = casteIndex

	local hf
	if unit.flags1.important_historical_figure or unit.flags2.important_historical_figure then
        hf = df.historical_figure.find(unit.hist_figure_id) 
    end

    if hf then
    	hf.race = raceIndex
    	hf.caste = casteIndex
    	hf.population_id = pop_id
    end
end

--
-- Helpers
--

-- Return true if the unit can be a target for corruption
function IsCandidate(unit)
	return casteSet.HasCreature(unit) and
		dfhack.units.isAlive(unit) and
		dfhack.units.isSane(unit) and
		not dfhack.units.isCitizen(unit) and
		not dfhack.units.isAnimal(unit)
end

-- Check boundaries and field of view, z level must be the same
function IsInView(unit, view)
	local pos = {dfhack.units.getPosition(unit)}

	if
		pos[1] < view.xmin or pos[1] > view.xmax or
		pos[2] < view.ymin or pos[2] > view.ymax or
		view.z ~= pos[3]
	then
		return false
	end

	return view[pos[2]][pos[1]] > 0
end

-- Returns the caste that will be used for transformation
function GetTargetCaste(unit)
	local originalRace = tostring(df.global.world.raws.creatures.all[unit.race].creature_id)
	local targetCaste = casteSet.bindings[originalRace]
	local suffix

	if debug then print("* Original race: " .. originalRace) end

	if targetCaste == false then
		if debug then print("* No transformation") end
		return nil
	end

	if targetCaste == nil then
		if debug then print("* Using default caste") end
		targetCaste = casteSet.default
	end

	if unit.sex == 1 then
		suffix = "_MALE"
	else
		suffix = "_FEMALE"
	end

	targetCaste = targetCaste .. suffix
	if debug then print('* Selected caste: ' .. targetCaste) end

	return targetCaste
end

-- Return the caste row
function FindCasteIndex(casteId)
	local targetRace = df.global.world.raws.creatures.all[df.global.plotinfo.race_id]

	for i, v in ipairs(targetRace.caste) do
		if v.caste_id == casteId then
			return i
		end
	end

	qerror("Invalid caste.")
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
