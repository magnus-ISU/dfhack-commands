-- Force native attack events that the stock `force` script can't: cavern forgotten beasts.
--[[
force-more

The stock `force Megabeast` can only summon SURFACE megabeasts (titans, rocs, ...): it inserts a
Megabeast timed event with no layer_id, which makes DF roll a surface beast. Forgotten-beast
attacks in v50 are the SAME event type with `layer_id` set to a cavern layer -- there is no
working FeatureAttack path (that event type never spawns FBs; it's for cavern-civ invasions).
This was found by watching what DF itself queues at a season boundary after a real cavern breach.

force-more inserts the exact event DF uses, so selection, placement, announcement, and AI are all
native. DF picks WHICH beast itself: a living forgotten beast "waiting" in the world as a hidden
one-member army whose `hidden_fl_ind` matches the layer (see tarrasque, which rebuilds exactly
that state for revived beasts).

Usage:
    force-more list                       show the local cavern layers (id, discovered, irritation)
    force-more forgotten-beast [layer]    queue a forgotten-beast attack from that cavern layer:
                                          `layer` = a layer id from `list`, or a cavern ordinal
                                          (1..3); default = a random DISCOVERED cavern
    force-more megabeast                  queue a SURFACE megabeast (same as stock `force Megabeast`)

The event fires within a few ticks of the current calendar position. If DF finds no eligible
beast for the layer (none alive/waiting there, cavern never really discovered), the event is
consumed with no arrival -- nothing breaks.
]]

local function cavern_layers()
    local out = {}
    if not dfhack.isMapLoaded() then return out end
    local mf = df.global.world.features.map_features
    for i = 0, #mf - 1 do
        local f = mf[i]
        if df.feature_init_subterranean_from_layerst:is_instance(f) then
            out[#out + 1] = {layer = f.layer, discovered = f.flags.Discovered and true or false,
                             irritation = f.feature.irritation_level}
        end
    end
    return out
end

local function queue_megabeast(layer)
    df.global.timed_events:insert('#', {
        new = true,
        type = df.timed_event_type.Megabeast,
        season = df.global.cur_season,
        season_ticks = df.global.cur_season_tick,
        feature_ind = -1,
        layer_id = layer,
    })
end

if not dfhack.isWorldLoaded() then qerror('force-more needs a loaded world') end

local args = {...}
local cmd = args[1]

if cmd == 'forgotten-beast' or cmd == 'fb' then
    local caverns = cavern_layers()
    if #caverns == 0 then qerror('no cavern layers here (no map loaded?)') end
    local layer
    local want = tonumber(args[2])
    if want then
        for _, c in ipairs(caverns) do
            if c.layer == want then layer = c.layer end
        end
        if not layer and caverns[want] then layer = caverns[want].layer end   -- cavern ordinal 1..3
        if not layer then qerror(('no cavern layer %d -- see `force-more list`'):format(want)) end
    else
        local discovered = {}
        for _, c in ipairs(caverns) do
            if c.discovered then discovered[#discovered + 1] = c end
        end
        if #discovered == 0 then qerror('no cavern is discovered yet -- breach one first (or pass a layer id)') end
        layer = discovered[math.random(#discovered)].layer
    end
    for _, c in ipairs(caverns) do
        if c.layer == layer and not c.discovered then
            dfhack.printerr(('warning: cavern layer %d is not discovered -- the event will likely fizzle'):format(layer))
        end
    end
    queue_megabeast(layer)
    print(('force-more: forgotten-beast attack queued from cavern layer %d (fires within a few ticks)'):format(layer))
elseif cmd == 'megabeast' then
    queue_megabeast(-1)
    print('force-more: surface megabeast attack queued (fires within a few ticks)')
elseif cmd == 'list' or cmd == nil then
    local caverns = cavern_layers()
    if #caverns == 0 then print('force-more: no cavern layers (no map loaded?)') end
    for i, c in ipairs(caverns) do
        print(('cavern %d: layer id %d, %s, irritation %d'):format(
            i, c.layer, c.discovered and 'DISCOVERED' or 'not discovered', c.irritation))
    end
    if cmd == nil then print('usage: force-more forgotten-beast [layer] | megabeast | list') end
else
    qerror('unknown type: ' .. tostring(cmd) .. ' (forgotten-beast | megabeast | list)')
end
