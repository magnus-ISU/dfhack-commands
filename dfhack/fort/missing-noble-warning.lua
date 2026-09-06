-- Warn when the fort has nobody doing a job a noble is supposed to do, and open the Nobles
-- screen when the warning is clicked.
--@ module = false
--[[
missing-noble-warning

Registers a notification (name: "missing_nobles") into DFHack's gui/notify panel, alongside
"needs a tomb" and the work-detail warnings. It watches the five posts a fort actually suffers
without and says which ones nobody holds:

    "Assign a manager."
    "Assign a chief medical dwarf and militia commander."
    "Assign a manager, broker, bookkeeper."
    "Assign 4 noble positions."

One or two are named, three are listed, and past that it just says how many -- by then the list
is longer than the notification line and the screen you are about to open says the rest.
Clicking opens Nobles and administrators, where you assign them.

WHAT IT LOOKS FOR IS THE JOB, NOT THE TITLE. Each post is found by the RESPONSIBILITY the
entity raws give it -- managing production, trade, accounting, health management, military
strategy -- so a modded civilisation whose fort is run by a quartermaster and a war-leader is
covered exactly as well as a dwarven one, and the warning uses whatever that civilisation calls
the post. A role counts as covered when ANY position carrying its responsibility has somebody in
it, which is also what keeps a fort with a mayor from being nagged about its expedition leader.

Posts with nobody in them that no fort depends on -- hammerer, dungeon master, champion -- are
not mentioned; the warning is about work that stops without them.

Run once per DFHack session to register; magnus-scripts loads it. To make it permanent on its
own, add `missing-noble-warning` to dfhack-config/init/dfhack.init.
]]

local NAME = 'missing_nobles'

-- The jobs a fort misses. Each is a responsibility flag from the entity raws, in the order the
-- warning lists them, with a fallback name for the odd civilisation that has the job but leaves
-- the position unnamed.
local ROLES = {
    {resp = 'MANAGE_PRODUCTION',  fallback = 'manager'},
    {resp = 'TRADE',              fallback = 'broker'},
    {resp = 'ACCOUNTING',         fallback = 'bookkeeper'},
    {resp = 'HEALTH_MANAGEMENT',  fallback = 'chief medical dwarf'},
    {resp = 'MILITARY_STRATEGY',  fallback = 'militia commander'},
}

-- ---------------------------------------------------------------------------
-- who is missing
-- ---------------------------------------------------------------------------

local function fort_entity()
    return df.global.plotinfo.main.fortress_entity
end

-- position id -> true when somebody actually holds it (an assignment with a real histfig;
-- DF keeps empty assignment rows around for every vacant slot)
local function held_positions(ent)
    local held = {}
    for _, a in ipairs(ent.positions.assignments) do
        if a.histfig ~= -1 then held[a.position_id] = true end
    end
    return held
end

-- The name this civilisation gives a position. `name[0]` is the singular ("manager",
-- "quartermaster"); some modded positions leave it empty, hence the fallback.
local function position_name(p, fallback)
    local n = p.name[0]
    if n and #n > 0 then return n end
    return fallback
end

-- Every role nobody is doing, named as this civilisation names it. A role is covered when ANY
-- position carrying its responsibility is held -- so a mayor covers what an expedition leader
-- would, and a modded civ that splits a job across two posts is covered by either.
local function missing_roles()
    local ent = fort_entity()
    if not ent then return {} end
    local held = held_positions(ent)
    local out = {}
    for _, role in ipairs(ROLES) do
        local exists, covered, name = false, false, nil
        for _, p in ipairs(ent.positions.own) do
            if p.responsibilities[role.resp] then
                exists = true
                if held[p.id] then covered = true break end
                name = name or position_name(p, role.fallback)
            end
        end
        -- a civilisation with no such post at all is not missing anything
        if exists and not covered then out[#out + 1] = name or role.fallback end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- the line
-- ---------------------------------------------------------------------------

local function missing_noble_message()
    if not dfhack.world.isFortressMode() then return end
    local missing = missing_roles()
    local n = #missing
    if n == 0 then return end
    if n >= 4 then
        return ('Assign %d noble positions.'):format(n)
    end
    if n == 1 then
        return ('Assign a %s.'):format(missing[1])
    end
    if n == 2 then
        return ('Assign a %s and %s.'):format(missing[1], missing[2])
    end
    return ('Assign a %s, %s, %s.'):format(missing[1], missing[2], missing[3])
end

-- ---------------------------------------------------------------------------
-- the click: open Nobles and administrators
-- ---------------------------------------------------------------------------

local function show_nobles()
    local info = df.global.game.main_interface.info
    info.open = true
    info.current_mode = df.info_interface_mode_type.ADMINISTRATORS
end

-- ---------------------------------------------------------------------------
-- registration (idempotent; survives notify-module reloads via onStateChange)
-- ---------------------------------------------------------------------------

local function register()
    local nmod = reqscript('internal/notify/notifications')
    local entry = nmod.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(nmod.NOTIFICATIONS_BY_IDX, entry)
        nmod.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    -- (re)assign callbacks every time so re-running the script picks up edits
    entry.desc = 'Notifies when no one holds a post the fort needs -- manager, broker, bookkeeper, chief medical dwarf, militia commander -- found by the job the entity raws give each position, so modded civs are covered. Click to open Nobles and administrators.'
    entry.dwarf_fn = missing_noble_message
    entry.on_click = show_nobles
    -- the overlay gates on config.data[name].enabled; make sure it exists so it's on by default
    if nmod.config and nmod.config.data and not nmod.config.data[NAME] then
        nmod.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()

dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

print('missing-noble-warning: "missing_nobles" registered.')
local msg = missing_noble_message()
print('  now: ' .. (msg or 'every post the fort needs is held.'))
print('  Click the notification to open Nobles and administrators.')
