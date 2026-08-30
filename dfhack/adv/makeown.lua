-- Adventure mode: make the selected unit a member of your adventuring party.
--@module = true
--[[
adv/makeown

Recruits whoever you have selected -- the unit under the cursor, or `-unit <id>` --
into your adventure party, without a conversation and without their consent. The
tavern mercenary who will not take your money, the caged prisoner you freed, the
war dog belonging to somebody else, a goblin that just lost a fight: point at them
and they are yours.

WHAT "IN YOUR PARTY" MEANS HERE
  Modern adventure mode keeps the party in three histfig-id lists on
  `df.global.adventure.interactions`, and DF treats each one differently:

    party_core_members   full members -- selectable in tactical mode, controllable,
                         and kept when you retire/unretire. This is the default.
    party_extra_members  hangers-on: they follow and fight, but you cannot take
                         control of them. `-extra` puts them here (`advtools party`
                         promotes an extra member to core later).
    party_pets           animals. Auto-detected for anything that can neither speak
                         nor learn; force it with `-pet`.

  Those lists alone do not make anyone walk after you, so the older fields that
  actually drive following are set too: the recruit's nemesis lands in the
  adventurer's `nemesis.companions`, its `group_leader_id` points back at you, and
  `unit.relationship_ids.GroupLeader` is your unit id. Reciprocal
  `histfig_hf_link_companionst` links are added on both historical figures so
  Legends and the talk menu agree about who travels with whom.

HOSTILITY IS CLEARED, NOT IGNORED
  A unit recruited mid-fight otherwise keeps trying to kill you. Invader/ambusher/
  visitor flags are cleared, `invasion_id` and the army controller are dropped, the
  unit is pulled out of every Conflict activity and out of the enemy status cache
  (via stock `makeown`'s own helpers), and its civ becomes yours.

UNITS WITH NO HISTORICAL FIGURE
  Ordinary wildlife and generic townsfolk have no nemesis record, so there is
  nothing for the party lists to hold. One is created the same way DFHack's own
  `bodyswap` does it -- `unit:create_nemesis(1, 1)`, plus `never_cull` on the new
  figure -- and the recruit is removed from the populace list of any site its
  figure is linked to, which is what stops it appearing twice in `units.active`
  after you travel.

DISMISSING
  `adv/makeown -remove` reverses everything for the selected unit. `gui/companion-order`'s
  Leave order works too. The vanilla talk menu usually will not offer "part ways",
  because no join agreement was ever signed -- the recruit is in your party by
  data, not by diplomacy.

USAGE
    adv/makeown                 recruit the selected unit as a core party member
    adv/makeown -unit 1234      recruit by unit id
    adv/makeown -extra          recruit as a follower (not controllable)
    adv/makeown -pet            recruit as an animal companion
    adv/makeown -remove         remove them from the party again
]]

local utils = require('utils')
local makeown = reqscript('makeown')

local function party()
    return df.global.adventure.interactions
end

local function vec_has(vec, value)
    return utils.linear_index(vec, value) ~= nil
end

local function vec_add_unique(vec, value)
    if vec_has(vec, value) then return false end
    vec:insert('#', value)
    return true
end

local function vec_erase_value(vec, value)
    local idx = utils.linear_index(vec, value)
    if not idx then return false end
    vec:erase(idx)
    return true
end

local function get_adventurer()
    local unit = dfhack.world.getAdventurer()
    if unit then return unit end
    local nem = df.nemesis_record.find(df.global.adventure.player_id)
    return nem and nem.unit or nil
end

-- Only creatures that can neither talk nor learn become pets; everyone else is a
-- companion. Same test stock makeown uses to decide whether to name a unit.
local function is_animal(unit)
    local flags = unit.enemy.caste_flags
    return not (flags.CAN_SPEAK or flags.CAN_LEARN)
end

-- create_nemesis(important, inplay, just_born). The third argument is newer than
-- stock bodyswap.lua's two-argument call, and DFHack's lua binding rejects a wrong
-- argument count outright ("cannot invoke unit.create_nemesis(): invalid argument
-- count"), so try the current signature first and fall back to the old one rather
-- than pinning either.
local function create_nemesis(unit)
    local ok, nem = pcall(function() return unit:create_nemesis(1, 1, false) end)
    if ok then return nem end
    local ok2, nem2 = pcall(function() return unit:create_nemesis(1, 1) end)
    if ok2 then return nem2 end
    qerror('create_nemesis failed on this DFHack build: ' .. tostring(nem))
end

local function get_or_create_nemesis(unit)
    local nem = dfhack.units.getNemesis(unit)
    if nem then return nem end
    nem = create_nemesis(unit)
    if nem and nem.figure then
        nem.figure.flags.never_cull = true
    end
    return nem
end

-- A figure left in a site's populace list is loaded a second time when that site
-- reloads with the figure already present in your party, giving you a duplicate in
-- units.active. bodyswap.lua does exactly this for the same reason.
local function clear_nemesis_from_linked_sites(nem)
    if not nem.figure then return end
    for _, link in ipairs(nem.figure.site_links) do
        local site = df.world_site.find(link.site)
        if site then
            utils.erase_sorted(site.populace.nemesis, nem.id)
        end
    end
end

local function find_companion_link(hf, target_id)
    for i, link in ipairs(hf.histfig_links) do
        if df.histfig_hf_link_companionst:is_instance(link) and link.target_hf == target_id then
            return i
        end
    end
    return nil
end

local function add_companion_link(from_hf, to_hf, party_index)
    if find_companion_link(from_hf, to_hf.id) then return end
    from_hf.histfig_links:insert('#', {
        new = df.histfig_hf_link_companionst,
        target_hf = to_hf.id,
        link_strength = 100,
        agreement_id = -1,              -- no join agreement was signed
        agreement_party_id = party_index,
    })
end

local function remove_companion_link(from_hf, target_id)
    local idx = find_companion_link(from_hf, target_id)
    while idx do
        from_hf.histfig_links:erase(idx)
        idx = find_companion_link(from_hf, target_id)
    end
end

-- Strip the "I am here to fight you" state. Everything below is either a plain flag
-- or a stock makeown helper; nothing here touches the map.
local function pacify(unit, adventurer)
    unit.flags1.marauder = false
    unit.flags1.active_invader = false
    unit.flags1.hidden_in_ambush = false
    unit.flags1.invader_origin = false
    unit.flags1.hidden_ambusher = false
    unit.flags1.invades = false
    unit.flags2.underworld = false
    unit.flags2.resident = false
    unit.flags2.visitor_uninvited = false
    unit.flags2.visitor = false
    unit.flags3.guest = false
    unit.flags4.invader_waits_for_parley = false
    unit.flags4.agitated_wilderness_creature = false

    unit.invasion_id = -1
    unit.enemy.army_controller_id = -1
    unit.enemy.army_controller = nil

    makeown.clear_enemy_status(unit)
    makeown.remove_from_conflict(unit)

    -- unit.civ_id only: the soul's civ_id is the default-ethics entity, and
    -- rewriting that would quietly re-moralize the recruit.
    unit.civ_id = adventurer.civ_id
end

local function make_pet(unit, adventurer)
    unit.relationship_ids.PetOwner = adventurer.id
    unit.flags1.tame = true
    unit.training_level = df.animal_training_level.Domesticated
end

function makeCompanion(adventurer, unit, opts)
    opts = opts or {}

    local adv_nem = dfhack.units.getNemesis(adventurer)
    if not adv_nem or not adv_nem.figure then
        qerror('The adventurer has no nemesis record.')
    end

    local nem = get_or_create_nemesis(unit)
    if not nem or not nem.figure then
        qerror('Could not give ' .. dfhack.units.getReadableName(unit) ..
               ' a historical figure to join the party with.')
    end

    local as_pet = opts.pet or is_animal(unit)

    pacify(unit, adventurer)

    -- follow-me plumbing: nemesis companion list + group leader on both layers
    vec_add_unique(adv_nem.companions, nem.id)
    nem.group_leader_id = adv_nem.id
    unit.relationship_ids.GroupLeader = adventurer.id

    add_companion_link(nem.figure, adv_nem.figure, 0)
    add_companion_link(adv_nem.figure, nem.figure, 1)

    clear_nemesis_from_linked_sites(nem)

    local p = party()
    vec_erase_value(p.party_core_members, nem.figure.id)
    vec_erase_value(p.party_extra_members, nem.figure.id)
    vec_erase_value(p.party_pets, nem.figure.id)

    if as_pet then
        make_pet(unit, adventurer)
        vec_add_unique(p.party_pets, nem.figure.id)
        return 'pet'
    end

    -- A nameless companion shows up as "Human Swordsman" forever, and the unretire
    -- list needs the ADVENTURER flag to offer them.
    makeown.name_unit(unit)
    if not nem.figure.name.has_name then
        local old_name = nem.figure.name
        nem.figure.name = unit.name:new()
        old_name:delete()
    end

    if opts.extra then
        vec_add_unique(p.party_extra_members, nem.figure.id)
        return 'follower'
    end

    nem.flags.ADVENTURER = true
    vec_add_unique(p.party_core_members, nem.figure.id)
    return 'core party member'
end

function removeCompanion(adventurer, unit)
    local adv_nem = dfhack.units.getNemesis(adventurer)
    local nem = dfhack.units.getNemesis(unit)

    if adv_nem and nem then
        vec_erase_value(adv_nem.companions, nem.id)
        if nem.group_leader_id == adv_nem.id then
            nem.group_leader_id = -1
        end
        nem.flags.ADVENTURER = false
        if adv_nem.figure and nem.figure then
            remove_companion_link(adv_nem.figure, nem.figure.id)
            remove_companion_link(nem.figure, adv_nem.figure.id)
        end
    end

    if unit.relationship_ids.GroupLeader == adventurer.id then
        unit.relationship_ids.GroupLeader = -1
    end
    if unit.relationship_ids.PetOwner == adventurer.id then
        unit.relationship_ids.PetOwner = -1
    end

    local hf_id = nem and nem.figure and nem.figure.id or unit.hist_figure_id
    if hf_id and hf_id ~= -1 then
        local p = party()
        vec_erase_value(p.party_core_members, hf_id)
        vec_erase_value(p.party_extra_members, hf_id)
        vec_erase_value(p.party_pets, hf_id)
    end
end

-- Hand-rolled so `-remove` works: argparse's getopt would read that single dash as
-- a cluster of short flags. Leading dashes are optional on every keyword.
local FLAGS = utils.invert{'pet', 'extra', 'remove', 'help'}

local function parse_args(args)
    local opts = {}
    local i = 1
    while i <= #args do
        local word = args[i]:gsub('^%-%-?', '')
        if FLAGS[word] then
            opts[word] = true
        elseif word == 'unit' then
            i = i + 1
            opts.unit = args[i]
            if not opts.unit then qerror('-unit needs a unit id.') end
        else
            qerror('Unknown argument: ' .. args[i])
        end
        i = i + 1
    end
    return opts
end

local function main(args)
    local opts = parse_args(args)

    if opts.help then
        print(dfhack.script_help())
        return
    end

    if not dfhack.world.isAdventureMode() then
        qerror('adv/makeown only works in adventure mode.')
    end

    local adventurer = get_adventurer()
    if not adventurer then
        qerror('Could not find the current adventurer.')
    end

    local unit
    if opts.unit then
        local id = tonumber(opts.unit)
        unit = id and df.unit.find(id)
        if not unit then
            qerror('No unit with id ' .. tostring(opts.unit))
        end
    else
        unit = dfhack.gui.getSelectedUnit(true)
    end
    if not unit then
        qerror('Select a unit first (look at them, or open their sheet), or pass -unit <id>.')
    end
    if unit == adventurer then
        qerror('That is you.')
    end

    if opts.remove then
        removeCompanion(adventurer, unit)
        print(('adv/makeown: %s has left the party.')
            :format(dfhack.units.getReadableName(unit)))
        return
    end

    if unit.flags2.killed or unit.flags1.inactive then
        qerror(dfhack.units.getReadableName(unit) .. ' is dead.')
    end

    local role = makeCompanion(adventurer, unit, opts)
    print(('adv/makeown: %s is now a %s.')
        :format(dfhack.units.getReadableName(unit), role))
    if role == 'follower' then
        print('  Promote them to the core party later with `advtools party`.')
    end
    print('  Order them around or dismiss them with `gui/companion-order`,' ..
          ' or `adv/makeown -remove`.')
end

if not dfhack_flags.module then
    main({...})
end
