-- Put the deities and professions that have asked for a location at the top of the list.
--@module = true
--[[
sort-locations

Assigning a new temple or guildhall means picking from a list of every deity your
citizens worship, or every profession they practise -- sixty-four entries here, in
whatever order DF built them. The one that matters is almost always the one that
ASKED: a religion that has petitioned for a temple, a guild that has petitioned for
a guildhall. That entry is somewhere in the middle of the list looking exactly like
the sixty-three that did not.

So they are moved to the top, in the order they appear otherwise. "(No particular
deity)" keeps its place at the head of the list, since it is DF's own catch-all
rather than a choice about anybody.

WHERE "ASKED" COMES FROM. A petition is an `agreement` with a `Location` detail:
`type` is the abstract building wanted (TEMPLE / GUILDHALL), and it names either a
deity (`deity_data` + `deity_type`) or a `profession`. Those are exactly the keys
the location selector lists its rows by -- `valid_religious_practice` paired with
`valid_religious_practice_id` for temples, `valid_craft_guild_type` for guildhalls
-- so matching is direct. Both unapproved petitions (`plotinfo.petitions`) and
agreements already accepted but not yet built count: both are somebody waiting.

The lists are DF's own vectors and the screen draws them in order, so sorting is
done by reordering them in place. It is idempotent -- a list already in the right
order is left alone, so nothing shifts under the cursor while you read it.

Auto-discovered by `overlay rescan`; no enable needed.
]]

local overlay = require('plugins.overlay')

local function selector()
    return df.global.game.main_interface.location_selector
end

-- ---------------------------------------------------------------------------
-- who has asked for what
-- ---------------------------------------------------------------------------

-- Keyed the way the selector lists its rows, so a row can be looked up directly:
--   temples    'd<deity_type>/<deity_data>'
--   guildhalls 'g<profession>'
local function wanted_keys()
    local keys = {}
    local here = df.global.plotinfo.site_id
    local function note(loc)
        if not loc then return end
        -- OUR site only. A world has petitions in it for every settlement: this fort had four
        -- of its own and two belonging to a site two hundred miles away, and pulling a
        -- profession to the top because somebody else's guild wants a hall is worse than not
        -- sorting at all.
        if loc.site ~= here then return end
        if loc.type == df.abstract_building_type.TEMPLE then
            -- `deity_data` is a union (Deity / Religion / practice_id share the storage) and
            -- `deity_type` says which reading applies -- the same pair the selector lists its
            -- rows by. Reading the union as a number throws, which a pcall then swallows,
            -- leaving no keys and a sort that silently did nothing.
            keys[('d%d/%d'):format(loc.deity_type, loc.deity_data.practice_id)] = true
        elseif loc.type == df.abstract_building_type.GUILDHALL then
            keys[('g%d'):format(loc.profession)] = true
        end
    end
    for _, ag in ipairs(df.global.world.agreements.all) do
        for _, d in ipairs(ag.details) do
            if d.type == df.agreement_details_type.Location then
                note(d.data.Location)
            end
        end
    end
    return keys
end

-- ---------------------------------------------------------------------------
-- reordering
-- ---------------------------------------------------------------------------

-- Sort `n` rows by a key function, wanted first, otherwise stable. `swap(i, j)`
-- exchanges every parallel vector at once, so an id never parts company with the
-- practice type beside it.
local function bring_forward(n, is_wanted, is_pinned, swap)
    local order = {}
    for i = 0, n - 1 do order[#order + 1] = i end
    local rank = {}
    for _, i in ipairs(order) do
        rank[i] = is_pinned(i) and 0 or (is_wanted(i) and 1 or 2)
    end
    table.sort(order, function(a, b)
        if rank[a] ~= rank[b] then return rank[a] < rank[b] end
        return a < b                                   -- stable: keep DF's order
    end)
    -- already right? then touch nothing -- this runs every tick the window is up
    local moved = false
    for pos, src in ipairs(order) do
        if src ~= pos - 1 then moved = true break end
    end
    if not moved then return 0 end

    -- apply the permutation with swaps, tracking where each original row went
    local at, holds = {}, {}
    for i = 0, n - 1 do at[i], holds[i] = i, i end
    local n_swaps = 0
    for pos, src in ipairs(order) do
        local dest = pos - 1
        local cur = at[src]
        if cur ~= dest then
            swap(cur, dest)
            local other = holds[dest]
            at[src], holds[dest] = dest, src
            at[other], holds[cur] = cur, other
            n_swaps = n_swaps + 1
        end
    end
    return n_swaps
end

-- the deity/religion list
local function sort_temples(keys)
    local ls = selector()
    local prac, id = ls.valid_religious_practice, ls.valid_religious_practice_id
    local n = #prac
    if n == 0 or #id ~= n then return 0 end
    return bring_forward(n,
        function(i) return keys[('d%d/%d'):format(prac[i], id[i])] == true end,
        function(i) return id[i] < 0 end,          -- "(No particular deity)" stays put
        function(a, b)
            prac[a], prac[b] = prac[b], prac[a]
            id[a], id[b] = id[b], id[a]
        end)
end

-- the profession list
local function sort_guilds(keys)
    local ls = selector()
    local v = ls.valid_craft_guild_type
    local n = #v
    if n == 0 then return 0 end
    return bring_forward(n,
        function(i) return keys[('g%d'):format(v[i])] == true end,
        function() return false end,
        function(a, b) v[a], v[b] = v[b], v[a] end)
end

-- `force` sorts the vectors even with the window shut, which is only useful for checking the
-- ordering by hand: DF rebuilds these lists when the selector opens, so it changes nothing you
-- would see.
function sort_now(force)
    local ls = selector()
    if not (force or ls.open) then return 0 end
    local keys = wanted_keys()
    if not next(keys) then return 0 end            -- nobody has asked: leave DF's order alone
    return sort_temples(keys) + sort_guilds(keys)
end

-- ---------------------------------------------------------------------------
-- overlay
-- ---------------------------------------------------------------------------

SortLocations = defclass(SortLocations, overlay.OverlayWidget)
SortLocations.ATTRS{
    desc = 'Puts deities and guilds that petitioned for a location at the top of the list.',
    default_enabled = true,
    -- Broad, like the other tools here: a narrow sub-focus match does not instantiate
    -- reliably on these screens, and the work is gated on the selector being open anyway.
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0.2,
    default_pos = {x = -1, y = -1},     -- draws nothing; parked in the corner like a pump
    frame = {w = 1, h = 1},
    version = 1,
}

function SortLocations:overlay_onupdate()
    pcall(sort_now)
end

function SortLocations:render() end     -- nothing to draw; this only reorders

OVERLAY_WIDGETS = {sort = SortLocations}

if dfhack_flags and dfhack_flags.module then return end

local n = sort_now()
print(('sort-locations: %d row%s moved.'):format(n, n == 1 and '' or 's'))
print('Petitioned deities and guilds are listed first while a temple or guildhall is assigned.')
