-- Replace DFHack's stock "N agitated animals" notify line with a typed version.
--@module = false
--[[
agitated-animals-notification

DFHack's built-in notify panel shows a bland "N agitated animals". This hides that line
(stock notification `agitated_count`) and registers a replacement (`agitated_typed`) that
names what you're actually dealing with:

    * all one species   -> "N agitated ravens"           (singular if N == 1)
    * mixed species      -> "N agitated animals including a giant elephant"

where the "including ..." creature is the LARGEST agitated animal by body size (giant
elephants are the biggest in the game). Same detection as the stock line: living, on-map,
agitated wildlife that isn't caged or chained.

Clicking cycle-zooms through the agitated animals, one per click. SHIFT-clicking (with squads
selected via the dwarf-rts overlay) orders those squads to attack every agitated animal --
just like shift-clicking "N invaders" / "N hostiles". Falls through to the zoom if the overlay
isn't loaded or no squads are selected.

Run `agitated-animals-notification` to register (idempotent); magnus-scripts loads it.
]]

local NAME = 'agitated_typed'
local STOCK = 'agitated_count'   -- the built-in line we hide and replace

-- living, on-map, agitated wildlife that isn't caged/chained (mirrors the stock iterator)
local function is_target(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained and dfhack.units.isAgitated(u)
end

local function list_agitated()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if is_target(u) then out[#out + 1] = u end
    end
    return out
end

-- creature name: index 0 singular, 1 plural (df creature_raw.name = {sing, plural, adj})
local function creature_name(race, plural)
    local cr = df.global.world.raws.creatures.all[race]
    local n = cr and cr.name[plural and 1 or 0]
    if not n or n == '' then return plural and 'animals' or 'animal' end
    return n
end

local function a_an(word)
    local c = word:sub(1, 1):lower()
    return ((c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u') and 'an ' or 'a ') .. word
end

local function message()
    if not dfhack.world.isFortressMode() then return end
    local list = list_agitated()
    local n = #list
    if n == 0 then return end
    local first_race = list[1].race
    local same = true
    local big = list[1]                       -- largest individual so far
    for _, u in ipairs(list) do
        if u.race ~= first_race then same = false end
        if u.body.size_info.size_cur > big.body.size_info.size_cur then big = u end
    end
    local text
    if same then
        text = ('%d agitated %s'):format(n, creature_name(first_race, n > 1))
    else
        text = ('%d agitated animals including %s'):format(n, a_an(creature_name(big.race, false)))
    end
    return {{text = text, pen = COLOR_YELLOW}}
end

-- click: cycle-zoom; SHIFT-click with squads selected: order them to attack all agitated animals
local cycle = 0
local function on_click(state, shift)
    local list = list_agitated()
    if #list == 0 then return state end
    if shift then
        local gk = dfhack.internal.dwarf_rts_group_kill
        if gk then
            local ids = {}
            for _, u in ipairs(list) do ids[#ids + 1] = u.id end
            if gk(ids) then return state end   -- squads were selected -> commanded them
        end
    end
    cycle = (cycle % #list) + 1
    local u = list[cycle]
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(u.pos.x, u.pos.y, u.pos.z), true, true)
    df.global.plotinfo.follow_unit = u.id
    return state
end

-- ---- registration (mirrors the pack's other notify scripts) -----------------

local function register()
    local n = reqscript('internal/notify/notifications')
    -- hide the stock "N agitated animals" line (its overlay gates on config.data[name].enabled)
    if n.config and n.config.data then
        n.config.data[STOCK] = n.config.data[STOCK] or {version = 1}
        n.config.data[STOCK].enabled = false
    end
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Agitated wildlife on the map, named by species (or the largest species when mixed). Shift-click with squads selected to attack them all.'
    entry.dwarf_fn = message
    entry.on_click = on_click
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register() end
end

print('agitated-animals-notification: "' .. NAME .. '" registered; stock "' .. STOCK .. '" hidden.')
print('Shows "N agitated <species>" (or "... including a <largest>"); shift-click to attack.')
