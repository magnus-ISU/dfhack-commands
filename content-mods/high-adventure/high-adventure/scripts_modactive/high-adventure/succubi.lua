--@module = true
--@enable = true
--[====[
high-adventure/succubi
======================

Tags: fort | gameplay

Enable the succubus dungeon submodules to get workshops and other scripts to work.

Modules:
- Magma well
- Powers
- Corruption

Usage
-----

	enable high-adventure/succubi
	disable high-adventure/succubi
]====]

local magmawellModule = reqscript("internal/ha-succubi/magmawell")
local powersModule = reqscript("internal/ha-succubi/powers")
local corruptionModule = reqscript("internal/ha-succubi/corruption")
--local entityReactionModule = reqscript("internal/ha-succubi/entity-reactions") -- disabled in favor of putting reactions directly in the entity
local GLOBAL_KEY = "succubusDungeon"

--print("*** SD RUN *** ")

local function get_default_state()
	return {
		enabled=false,
	}
end

state = state or get_default_state()

function isEnabled()
	return state.enabled
end

local function do_enable()
	magmawellModule.onLoad()
	powersModule.onLoad()
	corruptionModule.onLoad()
	--entityReactionModule.onLoad()

	state.enabled = true
	print("* Succubus Dungeon mod enabled")
end

local function do_disable()
	magmawellModule.onUnload()
	state.enabled = false
	print("* Succubus Dungeon mod disabled")
end

dfhack.onStateChange[GLOBAL_KEY] = function(state)
	--print("*** SD STATE CHANGE *** ".. state)
	if state == SC_MAP_UNLOADED then
		do_disable()
		dfhack.onStateChange[GLOBAL_KEY] = nil
		return
	end
	
    if state == SC_MAP_LOADED and dfhack.world.isFortressMode() then
		do_enable()
    end
end

if dfhack_flags.module then
	-- self-enable at module load: survives any load-order race with SC_MAP_LOADED
	if not state.enabled and dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
		do_enable()
	end
	return
end

if not dfhack_flags.enable then
	print(dfhack.script_help())
	print(string.format("Succubus Dungeon lua scripts are currently %q", state.enabled and "enabled" or "disabled"))
	return
end

if dfhack_flags.enable_state then
	do_enable()
else
	do_disable()
end