-- Adventure travel map: middle-drag panning and a search bar for everything you know.
--@module = true
--[[
adv/world-map-features
======================

Tags: adventure | interface

Two things the travel map has always wanted:

**Middle-drag to pan.**  Hold the MIDDLE mouse button on the travel map and
drag: the world scrolls under you.  DF has no camera field for this map -- it
rebuilds the port centred on the traveller every frame -- so the pan works by
moving what DF thinks the centre is (`adventure.travel_origin`), which is the
same value DF draws you at before a journey starts.  That makes DF render its
own map, at full fidelity, anywhere in the world.  Your true position keeps a
marker of its own (`@`) while the view is panned -- that marker is the only
indication, deliberately: no offset readout cluttering a map you are reading.

Because that field is also where a journey would BEGIN, the pan is unwound
whenever it could matter: MOVING drops it (the view belongs on you again), as
does Esc, a left-click on the lesser map (that click means "travel there", and
DF works the destination out from the true centre), leaving the travel screen,
the journey starting, or the script being disabled. Ordinary keys leave it
alone.
Panning is refused outright once you are actually travelling (the map then
follows your army, and the army's position is a real thing to move, not a
drawing hint).  `world-map-features recenter` snaps back by hand.

The pan STOPS at the edges of the world.  A centre outside the world map is not
merely wrong, it crashes DF outright (SIGSEGV in the render thread), so the
offset is clamped to real world tiles on every frame.

**A search bar for everything you have discovered.**  Alt-F focuses it; type
and results appear underneath, drawn from your adventurer's own knowledge --
not from the world at large:

    sites     every site you have heard of (`heard_of_stid`), by name and kind
    people    everyone you have met or heard of, with their last known spot
    beasts    your bestiary, with the region or site the sighting came from
    regions   the regions your sites, sightings and travels have touched
    groups    the civilizations and gangs behind those sites and people
    events    the rumours you are carrying, located where they happened

Sites and groups always carry a bearing -- a civilization is placed by its
capital (or the centre of its sites) even when you know none of its towns -- and
typing the exact name of a site you have NEVER discovered will still point at
it, on the grounds that knowing the name is itself the knowledge. Such a site is
marked `unmapped`.

Every row carries a category tag, a distance in world tiles and a compass
bearing.  Clicking a row (or Enter on it) TYPES that row's name into the bar,
and that is the whole mechanism: whenever the text exactly names one of the
things you know, the results list folds away and the map draws a LINE from you
to it. A site names itself there with the very card adv/read-the-map pops when
you hover it, distance and bearing appended; anything else gets a plain label.  The line is nothing but a reading of the
search bar -- it appears the instant the text matches, and goes when it stops
matching -- so it survives travelling, and Esc (which empties the bar) is what
takes it away.

Two things sharing a name resolve to the nearer one, and a namesake with no
known location never takes the line from one that has a place on the map.

The search text matches the name, the category and the KIND of thing, so typing
a type finds everything of that type you know: `vault` brings up the vaults,
`rabbit devil` the rabbit devils (the beast and anyone of that species you have
heard of), `high elf` both the high elves and any high elf sites -- sites carry
the race of the civ that owns them as well as their own kind, and vaults, tombs
and mythical lairs are resolved out of DF's catch-all `Monument` type. The
leading word `site:`, `person:`, `beast:`, `region:`, `group:` or `event:`
restricts the search to one category.

On the WORLD map, clicking a site you know types its name into the bar -- so a
click is just another way to name your destination. Clicks on open country fall
through to the game untouched, and the lesser map is left alone entirely, since
that is where adv/map-travel's click-to-walk lives.

    adv/world-map-features             status
    adv/world-map-features recenter    undo any pan
    adv/world-map-features clear       empty the search bar (and its line)
    adv/world-map-features help        this text

Only what your adventurer knows is listed, so an unexplored world gives a
short list -- that is the point.  People and rumours keep their last known
location, which may be stale; the bar marks those `(last seen)`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- ---- geometry ---------------------------------------------------------------
-- Everything on this screen is measured in ARMY UNITS: 48 per world tile, 3 per
-- mid tile. One map CELL is 48 army units on the greater (world) map, 3 on the
-- lesser one, and 1 when the lesser map rescales next to a site.
local ARMY_PER_WORLD = 48
local LOCAL_PER_WORLD = 768        -- histfig abs_x/abs_y are in local tiles

local function adv() return df.global.adventure end
local function port() return df.global.gps.main_map_port end

local function is_greater() return adv().travel_right_map ~= 0 end

local function units_per_cell()
    if is_greater() then return ARMY_PER_WORLD end
    return adv().site_level_zoom ~= 0 and 1 or 3
end

-- Has the journey begun? Until it has, DF has no player army and draws the
-- traveller at travel_origin (see adv/read-the-map for the full story).
local function still_local() return adv().travel_not_moved ~= 0 end

-- where the map is CENTRED right now, in army units (panned value included)
local function center_pos()
    if still_local() then return adv().travel_origin_x, adv().travel_origin_y end
    local army = df.army.find(adv().player_army_id)
    if army then return army.pos.x, army.pos.y end
end

-- ---- the pan ----------------------------------------------------------------
-- travel_origin is not ours to hold. It is where a journey would BEGIN, so a
-- panned value left lying around would launch the traveller from the wrong
-- place. The pan therefore exists only across the narrow window between the
-- frame's update and the end of its render: overlay_onupdate writes the offset
-- origin, DF draws the map from it, our own painting reads it, and
-- onRenderFrame puts the true value back before the game loop can take another
-- input. Everything outside that window -- every keypress, every click, every
-- frame we do not run -- sees the origin DF wrote.
--
-- The failure direction matters and is deliberate: a frame that updates but
-- never renders leaves the view snapping back to centre, which is a cosmetic
-- glitch. The opposite arrangement would leave a live coordinate wrong.
pan = pan or nil                   -- {home_x=, home_y=, ox=, oy=} in army units
local drag = nil                   -- {px=, py=} last mouse pixel during a drag
-- exactly what we last wrote into travel_origin, or nil if we have taken it
-- back. This is how "did the player move?" is answered: see the check in
-- overlay_onupdate.
local wrote_x, wrote_y = nil, nil

-- A centre outside the world CRASHES DF (measured in play, not theory): the map
-- renderer reads the world grid at the centre without checking it. So the pan is
-- clamped to real world tiles -- the last legal tile in each direction is the
-- furthest the view can go, and the drag simply stops there.
function clamp_origin(ax, ay)
    local wd = df.global.world.world_data
    local maxx = wd.world_width * ARMY_PER_WORLD - 1
    local maxy = wd.world_height * ARMY_PER_WORLD - 1
    return math.max(0, math.min(ax, maxx)), math.max(0, math.min(ay, maxy))
end

-- clamp the OFFSET so ox/oy can never drift past the edge and then need
-- unwinding before the view moves again
local function clamp_pan()
    if not pan then return end
    local x, y = clamp_origin(pan.home_x + pan.ox, pan.home_y + pan.oy)
    pan.ox, pan.oy = x - pan.home_x, y - pan.home_y
end

local function apply_pan()
    if not pan then return end
    clamp_pan()
    local x, y = clamp_origin(pan.home_x + pan.ox, pan.home_y + pan.oy)
    adv().travel_origin_x, adv().travel_origin_y = x, y
    wrote_x, wrote_y = x, y
end

-- Put DF's own value back, keeping the pan so the next frame can re-apply it.
-- Writes UNCONDITIONALLY whenever a pan exists. An earlier version skipped the
-- write when its own "currently applied" flag was false -- but that flag was a
-- file-local, so a hot reload in mid-pan cleared it while the module-global pan
-- lived on, and the next restore silently did nothing and stranded the
-- traveller's origin at the panned value. Rewriting a value that is already
-- correct costs nothing.
-- Drop the pan. `restore` writes DF's own centre back; without it the value
-- currently in travel_origin is left exactly as found.
local function release_pan(restore)
    if restore and pan then
        adv().travel_origin_x, adv().travel_origin_y = pan.home_x, pan.home_y
    end
    pan, drag, wrote_x, wrote_y = nil, nil, nil, nil
end

-- Hand DF's own value back at the end of the frame -- but only if the value in
-- travel_origin is still the one WE wrote. This is a compare-and-swap, and the
-- comparison is the whole point: travel_origin tracks where you are while you
-- are still local, so the game rewrites it when you move. A blind restore would
-- then overwrite a real movement with the stale centre we captured when the
-- drag began -- silently dragging your travel origin backwards. If the value is
-- not ours, the game changed it: that is the truth now, and the pan simply ends.
local function unapply_pan()
    if not pan then return end
    local a = adv()
    if wrote_x and (a.travel_origin_x ~= wrote_x or a.travel_origin_y ~= wrote_y) then
        release_pan(false)
        return
    end
    a.travel_origin_x, a.travel_origin_y = pan.home_x, pan.home_y
    wrote_x, wrote_y = nil, nil
end

-- Drop the pan and restore the view. Safe to call at any time; it will not
-- clobber a centre the game has moved out from under us.
function recenter()
    if not pan then return false end
    local a = adv()
    local ours = wrote_x and a.travel_origin_x == wrote_x and a.travel_origin_y == wrote_y
    release_pan(ours or wrote_x == nil)
    return true
end

-- the traveller's REAL position in army units, panned or not
local function player_pos()
    if pan then return pan.home_x, pan.home_y end
    return center_pos()
end

local function player_world()
    local ax, ay = player_pos()
    if not ax then return end
    return ax // ARMY_PER_WORLD, ay // ARMY_PER_WORLD
end

-- ---- the index --------------------------------------------------------------
-- Rebuilt when the travel screen opens (cheap: a few hundred entries, all from
-- the adventurer's own knowledge vectors -- no world-wide scans).
local index = nil
local index_built_for = nil

-- The knowledge all hangs off the adventurer's historical figure -- and
-- `getAdventurer()` returns NIL the moment a journey starts, because DF
-- offloads the unit into the player army. Every list would then come back
-- empty exactly when you most want to look something up, so fall back to the
-- nemesis record, which keeps pointing at the histfig the whole way.
local function adventurer_hf()
    local u = dfhack.world.getAdventurer()
    if u then
        local hf = df.historical_figure.find(u.hist_figure_id)
        if hf then return hf, u end
    end
    local nem = df.nemesis_record.find(adv().player_id)
    if nem and nem.figure then return nem.figure, u end
end

local function name_of(obj, english)
    local ok, s = pcall(dfhack.translation.translateName, obj, english ~= false)
    return ok and s ~= '' and s or nil
end

local function site_name(s)
    return name_of(s.name) or ('site ' .. s.id)
end

-- the species word. Castes carry their own noun ("wealthy Soldier", "tiercel
-- peregrine"), which is what the bestiary wants but not what a person's card
-- wants -- so callers choose.
local function race_name(race, caste)
    local cr = df.creature_raw.find(race)
    if not cr then return '?' end
    local c = caste and cr.caste[caste]
    return (c and c.caste_name[0] ~= '' and c.caste_name[0]) or cr.name[0] or cr.creature_id
end

local function species_name(race)
    local cr = df.creature_raw.find(race)
    return cr and (cr.name[0] ~= '' and cr.name[0] or cr.creature_id) or '?'
end

local function entry(cat, name, detail, wx, wy, stale)
    return {cat = cat, name = name, detail = detail, wx = wx, wy = wy, stale = stale,
            key = (name .. ' ' .. (detail or '') .. ' ' .. cat):lower()}
end

-- world region id under a world tile (region_map rows are pointers: _displace)
local function region_id_at(wx, wy)
    local wd = df.global.world.world_data
    if wx < 0 or wy < 0 or wx >= wd.world_width or wy >= wd.world_height then return end
    local ok, id = pcall(function() return wd.region_map[wx]:_displace(wy).region_id end)
    return ok and id or nil
end

-- What KIND of site this is, in the words a player would type. The raw enum is
-- not those words: vaults are `ImportantLocation`, and every tomb, vault and
-- mythical lair is a `Monument` whose real nature lives in subtype_info (the
-- same resolution adv/read-the-map does, kept in step with it).
local SITE_TYPE_NAMES = {
    PlayerFortress = 'Fortress', DarkFortress = 'Dark Fortress', Cave = 'Cave',
    MountainHalls = 'Mountain Halls', ForestRetreat = 'Forest Retreat', Town = 'Town',
    ImportantLocation = 'Vault', LairShrine = 'Lair', Fortress = 'Fortress', Camp = 'Camp',
}

local function site_kind(s)
    local raw = df.world_site_type[s.type] or tostring(s.type)
    if raw == 'Monument' then
        local mt
        pcall(function() mt = df.monument_type[s.subtype_info.monument_type] end)
        if mt == 'MYTHICAL' then
            return s.size >= 100 and 'Mysterious Palace'
                or s.size >= 15 and 'Mysterious Dungeon' or 'Mysterious Lair'
        end
        if mt == 'TOMB' then return 'Tomb' end
        if mt == 'VAULT' then return 'Vault' end
        return 'Monument'
    end
    return SITE_TYPE_NAMES[raw] or raw:gsub('(%l)(%u)', '%1 %2')
end

local function build_sites(out, hf, known_regions)
    local ki = hf.info.known_info
    for _, id in ipairs(ki.heard_of_stid) do
        local s = df.world_site.find(id)
        if s then
            local kind = site_kind(s)
            local owner = s.cur_owner_id >= 0 and df.historical_entity.find(s.cur_owner_id)
            local civ = s.civ_id >= 0 and df.historical_entity.find(s.civ_id)
            local detail = kind
            if owner then detail = detail .. ' of ' .. (name_of(owner.name) or '?') end
            local e = entry('site', site_name(s), detail, s.pos.x, s.pos.y)
            e.site = s              -- kept for footprint hit-testing on map clicks
            -- searchable by WHOSE it is as well as what it is, so "high elf"
            -- finds high elf towns and not just high elves
            for _, ent in ipairs{owner, civ} do
                if ent and ent.race >= 0 then e.key = e.key .. ' ' .. species_name(ent.race):lower() end
            end
            out[#out + 1] = e
            local rid = region_id_at(s.pos.x, s.pos.y)
            if rid then known_regions[rid] = true end
        end
    end
end

local function build_people(out, hf)
    for _, r in ipairs(hf.info.relationships.hf_visual) do
        local h = df.historical_figure.find(r.histfig_id)
        if h then
            local wx, wy, stale
            if r.abs_x > -100000 then
                wx, wy, stale = r.abs_x // LOCAL_PER_WORLD, r.abs_y // LOCAL_PER_WORLD, true
            end
            local species = species_name(h.race)
            local detail = species
            if r.meet_count > 0 then
                detail = ('%s, met %d%s'):format(detail, r.meet_count,
                    r.last_meet_year > 0 and (' (year %d)'):format(r.last_meet_year) or '')
            else
                detail = detail .. ', heard of'
            end
            -- worldgen leaves plenty of figures nameless; the species reads better
            -- in the list than "figure 14024"
            out[#out + 1] = entry('person', name_of(h.name) or ('unnamed ' .. species),
                                  detail, wx, wy, stale)
        end
    end
end

-- The bestiary. A creature_knowledgest keys a race+caste through the flattened
-- caste list (list_creature/list_caste are parallel to combined_caste_id) and
-- remembers WHERE the sighting came from -- a site, a region, or a cavern layer
-- (which has no surface location, so those rows are listed without one).
local function build_beasts(out, hf, known_regions)
    local raws = df.global.world.raws.creatures
    local wd = df.global.world.world_data
    -- one knowledge record per CASTE, so a plain two-caste animal would list
    -- twice ("cave dragon", "cave dragon"); collapse by what the row would say
    local seen = {}
    for _, ck in ipairs(hf.info.known_info.creature_knowledge) do
        local id = ck.combined_caste_id
        if id >= 0 and id < #raws.list_creature then
            local cr = raws.all[raws.list_creature[id]]
            local caste = cr and cr.caste[raws.list_caste[id]]
            if cr and caste then
                local wx, wy, where
                if #ck.site > 0 then
                    local s = df.world_site.find(ck.site[0])
                    if s then wx, wy, where = s.pos.x, s.pos.y, site_name(s) end
                end
                if not wx and #ck.region > 0 then
                    local reg = wd.regions[ck.region[0]]
                    if reg then
                        wx, wy = reg.mid_x, reg.mid_y
                        where = name_of(reg.name) or df.world_region_type[reg.type]
                        known_regions[reg.index] = true
                    end
                end
                if not wx and #ck.layer > 0 then where = 'the caverns' end
                local how = ck.flags.recent_encounter and 'seen'
                    or ck.flags.old_local and 'once local' or 'heard of'
                local nm = caste.caste_name[0]
                if nm == '' then nm = species_name(raws.list_creature[id]) end
                local detail = where and ('%s in %s'):format(how, where) or how
                local dedup = nm .. '|' .. detail
                if not seen[dedup] then
                    seen[dedup] = true
                    local e = entry('beast', nm, detail, wx, wy)
                    -- the row is named for the CASTE ("tiercel peregrine",
                    -- "queen high elf"), so the species word goes in the key or
                    -- typing the creature's own name would miss half its castes
                    local sp = species_name(raws.list_creature[id]):lower()
                    if not e.key:find(sp, 1, true) then e.key = e.key .. ' ' .. sp end
                    out[#out + 1] = e
                end
            end
        end
    end
end

local function build_regions(out, known_regions)
    local wd = df.global.world.world_data
    for id in pairs(known_regions) do
        local reg = wd.regions[id]
        if reg then
            out[#out + 1] = entry('region', name_of(reg.name) or ('region ' .. id),
                (df.world_region_type[reg.type] or '?'):gsub('(%l)(%u)', '%1 %2'),
                reg.mid_x, reg.mid_y)
        end
    end
end

-- Groups: the entities standing behind what you know -- whoever owns or founded
-- a site you have heard of, and whatever civilization the people you have met
-- belong to. Located at the average of their sites you know about.
local function build_groups(out, hf)
    local ki = hf.info.known_info
    local want, spots = {}, {}
    local function note(eid, wx, wy)
        if not eid or eid < 0 then return end
        want[eid] = true
        if wx then
            local s = spots[eid] or {n = 0, x = 0, y = 0}
            s.n, s.x, s.y = s.n + 1, s.x + wx, s.y + wy
            spots[eid] = s
        end
    end
    for _, id in ipairs(ki.heard_of_stid) do
        local s = df.world_site.find(id)
        if s then
            note(s.cur_owner_id, s.pos.x, s.pos.y)
            note(s.civ_id, s.pos.x, s.pos.y)
        end
    end
    for _, r in ipairs(hf.info.relationships.hf_visual) do
        local h = df.historical_figure.find(r.histfig_id)
        if h then note(h.civ_id) end
    end
    note(hf.civ_id)
    -- Every group gets a direction. Where none of its sites are known to you,
    -- fall back to the entity's own site links -- a civilization is a thing on
    -- the map whether or not you have heard of its towns, and "somewhere over
    -- there" is the answer the question wants.
    local function entity_seat(e)
        local n, sx, sy = 0, 0, 0
        for _, link in ipairs(e.site_links) do
            local s = df.world_site.find(link.target)
            if s then
                if link.flags.capital then return s.pos.x, s.pos.y end
                n, sx, sy = n + 1, sx + s.pos.x, sy + s.pos.y
            end
        end
        if n > 0 then return sx // n, sy // n end
    end
    for eid in pairs(want) do
        local e = df.historical_entity.find(eid)
        if e then
            local s = spots[eid]
            local wx, wy
            if s then wx, wy = s.x // s.n, s.y // s.n end
            if not wx then wx, wy = entity_seat(e) end
            local kind = (df.historical_entity_type[e.type] or 'group'):gsub('(%l)(%u)', '%1 %2')
            local race = e.race >= 0 and race_name(e.race) or nil
            out[#out + 1] = entry('group', name_of(e.name) or ('group ' .. eid),
                race and (race .. ' ' .. kind:lower()) or kind, wx, wy)
        end
    end
end

-- Rumours you are carrying. entity_event is a tagged union; the ONE live member
-- is the only key pairs() yields. The members are flat records of ids --
-- `site_id`, `region_id`, `histfig_id` -- so the location comes from whichever
-- of those the rumour happens to carry, in that order of precision.
local function build_events(out, hf)
    local wd = df.global.world.world_data
    local function field(p, name)
        local ok, v = pcall(function() return p[name] end)
        if ok and type(v) == 'number' and v >= 0 then return v end
    end
    for _, e in ipairs(hf.info.known_info.rumor_info.events) do
        local kind = (df.entity_event_type[e.type] or ('event ' .. e.type)):gsub('_', ' ')
        local wx, wy, where
        local payload
        for _, v in pairs(e.data) do payload = v break end
        if payload then
            local sid = field(payload, 'site_id')
            local s = sid and df.world_site.find(sid)
            if s then wx, wy, where = s.pos.x, s.pos.y, site_name(s) end
            if not wx then
                local rid = field(payload, 'region_id')
                local reg = rid and wd.regions[rid]
                if reg then wx, wy, where = reg.mid_x, reg.mid_y, name_of(reg.name) end
            end
            local hfid = field(payload, 'histfig_id')
            local who = hfid and df.historical_figure.find(hfid)
            if who then kind = ('%s: %s'):format(kind, name_of(who.name) or species_name(who.race)) end
        end
        local detail = ('year %d'):format(e.year)
        if where then detail = detail .. ' at ' .. where end
        out[#out + 1] = entry('event', kind, detail, wx, wy, true)
    end
end

function build_index(force)
    local hf, u = adventurer_hf()
    if not hf then return {} end
    -- keyed on the histfig, not the unit: mid-travel there is no unit
    local stamp = ('%d:%d:%d'):format(hf.id, #hf.info.known_info.heard_of_stid,
                                      #hf.info.relationships.hf_visual)
    if index and index_built_for == stamp and not force then return index end
    local out, known_regions = {}, {}
    local wx, wy = player_world()
    if wx then
        local rid = region_id_at(wx, wy)
        if rid then known_regions[rid] = true end
    end
    pcall(build_sites, out, hf, known_regions)
    pcall(build_people, out, hf)
    pcall(build_beasts, out, hf, known_regions)
    pcall(build_groups, out, hf)
    pcall(build_events, out, hf)
    pcall(build_regions, out, known_regions)   -- last: the others feed it
    index, index_built_for = out, stamp
    return index
end

-- ---- search -----------------------------------------------------------------
local CATS = {site = 'site', sites = 'site', person = 'person', people = 'person',
              beast = 'beast', beasts = 'beast', region = 'region', regions = 'region',
              group = 'group', groups = 'group', event = 'event', events = 'event'}

local function bearing(dx, dy)
    if dx == 0 and dy == 0 then return 'here' end
    local dirs = {'E', 'SE', 'S', 'SW', 'W', 'NW', 'N', 'NE'}
    local a = math.atan(dy, dx) * 4 / math.pi        -- eighths of a turn, y grows south
    return dirs[(math.floor(a + 0.5) % 8) + 1]
end

local function decorate(e)
    local wx, wy = player_world()
    if not wx or not e.wx then
        e.dist, e.dir = nil, nil
        return e
    end
    local dx, dy = e.wx - wx, e.wy - wy
    e.dist = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    e.dir = bearing(dx, dy)
    return e
end

-- split "beast: cave dragon" into the category filter and what is left to match
function parse_query(text)
    text = (text or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    local head, tail = text:match('^(%a+):%s*(.*)$')
    if head and CATS[head] then return CATS[head], tail end
    return nil, text
end

function search(text)
    local hits = {}
    local only
    only, text = parse_query(text)
    if text == '' and not only then return hits end
    for _, e in ipairs(build_index()) do
        if (not only or e.cat == only) and (text == '' or e.key:find(text, 1, true)) then
            hits[#hits + 1] = decorate(e)
        end
    end
    table.sort(hits, function(a, b)
        if (a.dist == nil) ~= (b.dist == nil) then return b.dist == nil end
        if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)
    return hits
end

-- The line is a pure function of what is in the search bar: it appears exactly
-- when the text NAMES one thing, and the results list gets out of the way at
-- the same moment. `hits` is already sorted nearest-first, so two things with
-- the same name resolve to the closer one, and a namesake with no known
-- location never steals the line from one that has a location.
-- Every site in the world, by lowercased name. Built once (a few hundred names)
-- and only ever consulted for an EXACT name: browsing stays limited to what you
-- know, but a name you have from outside the game -- a friend, the legends
-- screen, a previous adventurer -- still gets you a bearing. Knowing the name
-- IS the knowledge here; the map does not otherwise mention the place.
local all_sites_by_name = nil

local function unknown_site(want)
    if not all_sites_by_name then
        all_sites_by_name = {}
        for _, s in ipairs(df.global.world.world_data.sites) do
            local n = name_of(s.name)
            if n then all_sites_by_name[n:lower()] = s end
        end
    end
    local s = all_sites_by_name[want]
    if not s then return end
    local e = entry('site', name_of(s.name), site_kind(s) .. ', unmapped', s.pos.x, s.pos.y)
    e.site = s
    return e
end

function exact_match(text, hits)
    local only, want = parse_query(text)
    if want == '' then return nil end
    for _, e in ipairs(hits) do
        if e.wx and e.name:lower() == want then return e end
    end
    if only and only ~= 'site' then return nil end
    return unknown_site(want)
end

-- ---- painting ---------------------------------------------------------------
-- The map port draws square cells of `cellpx` pixels; the TEXT grid uses
-- tile_pixel_x/y, which are not square (10x16 here). Converting a map cell to a
-- text cell therefore scales x and y separately.
local PEN_LINE = dfhack.pen.parse{ch = 250, fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}
local PEN_MARK = dfhack.pen.parse{ch = string.byte('X'), fg = COLOR_LIGHTRED, bg = COLOR_BLACK}
local PEN_HOME = dfhack.pen.parse{ch = string.byte('@'), fg = COLOR_YELLOW, bg = COLOR_BLACK}
local PEN_LABEL = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}

local function cellpx()
    local g = df.global.gps
    return math.max(1, (g.dimx * g.tile_pixel_x) // port().dim_x)
end

-- army-unit position -> map cell, using the CURRENT centre
local function army_to_cell(ax, ay)
    local cx, cy = center_pos()
    if not cx then return end
    local s = units_per_cell()
    local mp = port()
    return mp.dim_x // 2 + (ax - cx) // s, mp.dim_y // 2 + (ay - cy) // s
end

-- For things known only by world tile (sites, regions, rumours), aim at the
-- middle of that tile. NOTE this is a QUANTISED position: a world tile is 48
-- army units, so the middle can be 24 units from the truth. That is under half
-- a cell on the greater map and invisible, but the lesser map draws 3 army
-- units per cell -- and 1 next to a site -- where the same rounding is 8 cells
-- out, or 24 when zoomed in. Anything whose exact position IS known (the
-- traveller) must go through army_to_cell directly.
local function world_to_cell(wx, wy)
    -- On the GREATER map one cell is exactly one world tile, and the centre cell
    -- is the tile you stand in -- so the cell is counted in TILES from there.
    -- Going through the tile's centre army-coordinate instead lands a cell short
    -- whenever you are deep inside your own tile (measured: standing at 2289,
    -- i.e. 33/48 through tile 47, put a site at tile 52 on cell 64 where DF
    -- draws it on 65). On the lesser map a world tile spans many cells, so there
    -- the tile centre is exactly what you want.
    local cx, cy = center_pos()
    if not cx then return end
    if is_greater() then
        local mp = port()
        return mp.dim_x // 2 + (wx - cx // ARMY_PER_WORLD),
               mp.dim_y // 2 + (wy - cy // ARMY_PER_WORLD)
    end
    return army_to_cell(wx * ARMY_PER_WORLD + ARMY_PER_WORLD // 2,
                        wy * ARMY_PER_WORLD + ARMY_PER_WORLD // 2)
end

local function cell_to_text(cx, cy)
    local g = df.global.gps
    local px = cellpx()
    return (cx * px + px // 2) // g.tile_pixel_x, (cy * px + px // 2) // g.tile_pixel_y
end

local function on_screen(tx, ty)
    local g = df.global.gps
    return tx >= 0 and ty >= 0 and tx < g.dimx and ty < g.dimy
end

local function paint_cell(pen, cx, cy)
    local mp = port()
    if cx < 0 or cy < 0 or cx >= mp.dim_x or cy >= mp.dim_y then return end
    local tx, ty = cell_to_text(cx, cy)
    if on_screen(tx, ty) then dfhack.screen.paintTile(pen, tx, ty) end
end

-- The last cell of (x0,y0)->(x1,y1) that is still on the map: the target itself
-- when it is on screen, otherwise where the line crosses the edge. Walks the
-- same Bresenham path the line is drawn with, so the marker always sits ON the
-- line rather than beside it.
local function clip_to_port(x0, y0, x1, y1)
    local mp = port()
    -- row 0 is excluded: that is where this overlay's own search bar sits, and a
    -- marker there is painted and then buried under it (measured -- the line
    -- appeared to run off the map with no label at all)
    local function inside(x, y) return x >= 0 and y >= 1 and x < mp.dim_x and y < mp.dim_y end
    if inside(x1, y1) then return x1, y1 end
    local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local lx, ly = x0, y0
    local guard = 0
    while guard < 4096 do
        guard = guard + 1
        if inside(x0, y0) then lx, ly = x0, y0 end
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
    return lx, ly
end

-- The trail is DOTTED: one dot every DOT_EVERY cells of the path, so it reads
-- as a direction rather than a wall of characters across the map you are trying
-- to look at. However sparse the sampling gets, the first, middle and last dots
-- are always drawn -- a bearing needs a near end, a far end and something in
-- between to be legible -- and a path with fewer cells than that simply draws
-- every cell it has.
local DOT_EVERY = 5

-- Bresenham in map cells, endpoints left to the callers' markers
local function line_cells(x0, y0, x1, y1)
    local cells = {}
    local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local guard = 0
    while guard < 4096 do
        guard = guard + 1
        if not (x0 == x1 and y0 == y1) and guard > 1 then
            cells[#cells + 1] = {x0, y0}
        end
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
    return cells
end

local function paint_line(x0, y0, x1, y1)
    -- sample only what would actually be drawn: cells off the map are not part
    -- of the trail, so clipping first keeps the spacing even across the visible
    -- stretch instead of leaving gaps where the path ran off screen
    local visible = {}
    local mp = port()
    for _, c in ipairs(line_cells(x0, y0, x1, y1)) do
        if c[1] >= 0 and c[2] >= 0 and c[1] < mp.dim_x and c[2] < mp.dim_y then
            visible[#visible + 1] = c
        end
    end
    local n = #visible
    if n == 0 then return end
    local want = {[1] = true, [n] = true, [(n + 1) // 2] = true}
    for i = 1, n, DOT_EVERY do want[i] = true end
    for i in pairs(want) do paint_cell(PEN_LINE, visible[i][1], visible[i][2]) end
end

-- A searched SITE shows the same card adv/read-the-map pops when you hover it --
-- one description of a place, however you arrived at it -- with the distance and
-- bearing appended, since that is what a destination is for. The card lines are
-- cached per site: building one walks the site's nobles and residents, which is
-- far too much to redo sixty times a second.
local card_cache = {}

local function read_the_map()
    return reqscript('adv/read-the-map')
end

local function site_card(t, dist, dir)
    if t.cat ~= 'site' or not t.site then return nil end
    local id = t.site.id
    if not card_cache[id] then
        local ok, lines = pcall(function() return read_the_map().lines_for_site(id) end)
        if not ok or not lines or #lines == 0 then return nil end
        card_cache[id] = lines
    end
    local out = {}
    for _, l in ipairs(card_cache[id]) do out[#out + 1] = l end
    out[#out + 1] = ('%d tiles %s'):format(dist, dir)
    if t.detail and t.detail:find('unmapped', 1, true) then
        out[#out + 1] = '(not on your map)'
    end
    return out
end

-- ---- the overlay ------------------------------------------------------------
if running == nil then running = true end
-- The line's target. NOT independent state: do_search sets it from the search
-- text on every keystroke, so it is only ever what the bar currently names.
-- `target` is a CACHE of "what the bar currently names", never state in its own
-- right. `target_text` is the text it was derived from, and the painter refuses
-- to draw a line whose text no longer matches the live field: the overlay
-- rebuilds its widgets whenever the travel screen is re-entered, which resets
-- the EditField to empty while these module globals survive -- and a line with
-- nothing naming it is exactly the state this pairing forbids.
target = target or nil
target_text = target_text or nil
active_widget = active_widget or nil

WorldMapFeatures = defclass(WorldMapFeatures, overlay.OverlayWidget)
WorldMapFeatures.ATTRS{
    desc = 'Travel map: middle-drag panning and a search bar for everything you know.',
    default_enabled = true,
    default_pos = {x = 1, y = 1},   -- overridden every frame by :recentre_frame()
    viewscreens = 'dungeonmode/Travel',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 64, h = 14},
}

-- The bar lives centred on the top row, so it reads as part of the map rather
-- than something bolted to a corner. Frame coordinates are relative to the
-- interface rect, so the centring is done against that rect's width, and it is
-- redone whenever the window size changes.
-- Where the top-left readout (adv/travelling-hunger's Food/Drink/Sleep line, or
-- whatever else sits up there) stops. Read from the live overlay rather than
-- assumed, since its width moves with the numbers in it.
local LEFT_FALLBACK = 34
local function on_this_screen(w)
    local vs = w.viewscreens
    if type(vs) == 'string' then vs = {vs} end
    if type(vs) ~= 'table' then return false end
    for _, s in ipairs(vs) do
        if tostring(s):find('dungeonmode', 1, true) then return true end
    end
    return false
end

local function left_obstacle(width)
    local ok, db = pcall(function() return overlay.get_state().db end)
    if not ok or not db then return LEFT_FALLBACK end
    local edge = 0
    for name, entry in pairs(db) do
        local w = entry.widget
        local fr = w and w.frame_rect
        -- A READOUT on the top row: small, shallow, ours excepted, and actually
        -- belonging to this screen. Without those tests the scan also finds the
        -- screen-covering overlays (gui/design, spectate, confirm), whose rects
        -- span the whole grid at y1=0 and would squeeze the bar to nothing.
        if fr and fr.y1 == 0 and fr.y2 <= 2
                and (fr.x2 - fr.x1 + 1) <= width // 3
                and not name:find('world%-map%-features')
                and on_this_screen(w) then
            edge = math.max(edge, fr.x2 + 1)
        end
    end
    return edge > 0 and edge or LEFT_FALLBACK
end

-- The bar is as wide as the screen allows while staying CENTRED and keeping two
-- clear columns from that readout -- which, being centred, means the same two
-- columns of margin on the right. Recomputed every frame, so a window resize (or
-- a longer Sleep count) just re-sizes it.
function WorldMapFeatures:recentre_frame()
    local ir = gui.get_interface_rect()
    local margin = left_obstacle(ir.width) + 2
    local w = math.max(40, ir.width - 2 * margin)
    local l = math.max(0, (ir.width - w) // 2)
    if self.frame.l == l and self.frame.w == w and self.frame.t == 0 then return end
    self.frame = {w = w, h = self.frame.h, l = l, t = 0}
    self:updateLayout(gui.ViewRect{rect = ir})
end

function WorldMapFeatures:init()
    self.hits = {}
    target, target_text = nil, nil  -- a fresh bar names nothing
    active_widget = self            -- so the `clear` command can empty the bar
    self:addviews{
        -- the banner paints only its brackets, so the panel under it supplies an
        -- opaque background -- otherwise the travel screen's own readouts (Speed,
        -- Sleep) show through the search bar
        widgets.Panel{
            frame = {l = 0, t = 0, r = 0, h = 1},
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.BannerPanel{
                    frame = {l = 0, t = 0, r = 0, h = 1},
                    subviews = {
                        widgets.EditField{
                            view_id = 'search',
                            frame = {l = 1, t = 0, r = 1},
                            key = 'CUSTOM_ALT_F',
                            on_change = function(text) self:do_search(text) end,
                            on_submit = function() self:pick(self.subviews.results:getSelected()) end,
                        },
                        -- what the bar is for, drawn over the empty field and gone
                        -- the moment there is text or focus (as adv/inventory-search does)
                        widgets.Label{
                            frame = {l = 9, t = 0, r = 1},
                            text = 'find a site, person, beast, region, group, event',
                            text_pen = COLOR_DARKGREY,
                            visible = function()
                                local s = self.subviews.search
                                return s.text == '' and not s.focus
                            end,
                        },
                    },
                },
            },
        },
        widgets.Panel{
            frame = {l = 0, t = 1, r = 0, b = 0},
            frame_style = gui.FRAME_THIN,
            frame_background = gui.CLEAR_PEN,
            visible = function() return #self.hits > 0 end,
            subviews = {
                widgets.List{
                    view_id = 'results',
                    frame = {l = 0, t = 0, r = 0, b = 0},
                    on_submit = function(idx) self:pick(idx) end,
                },
            },
        },
    }
end

local CAT_PEN = {
    site = COLOR_LIGHTGREEN, person = COLOR_LIGHTCYAN, beast = COLOR_LIGHTRED,
    region = COLOR_GREEN, group = COLOR_YELLOW, event = COLOR_LIGHTMAGENTA,
}

-- One text field drives both halves: the results list is what you get while the
-- text is still ambiguous, the line is what you get once it names something.
-- They are never both on screen.
function WorldMapFeatures:do_search(text)
    self.hits = search(text)
    target, target_text = exact_match(text, self.hits), text
    if target then
        self.hits = {}
        self.subviews.results:setChoices({}, 1)
        return
    end
    local choices = {}
    for i, e in ipairs(self.hits) do
        if i > 60 then break end
        local dist = e.dist and ('%d %s'):format(e.dist, e.dir) or '?'
        choices[#choices + 1] = {
            text = {
                {text = ('%-6s'):format(e.cat), pen = CAT_PEN[e.cat] or COLOR_GREY},
                {text = (' %-28s'):format(e.name:sub(1, 28))},
                {text = ('%8s '):format(dist), pen = COLOR_GREY},
                {text = (e.detail or ''):sub(1, 18), pen = COLOR_DARKGREY},
            },
            entry = e,
        }
    end
    self.subviews.results:setChoices(choices, 1)
end

-- Picking a row does not draw the line itself -- it TYPES the row's name into
-- the bar, and the exact match that follows draws the line and folds the list
-- away. One rule ("the line is what the text names"), reachable by mouse.
-- Clicking ALWAYS types the name, including for the many things you know of but
-- cannot place -- someone you have only heard of, a beast with no sighting
-- recorded. Refusing those clicks (an earlier version did) made rows that
-- simply ignored the mouse; typing the name instead leaves the row on screen
-- with no line, which says "known, location unknown" without a message.
function WorldMapFeatures:pick(idx)
    local c = self.subviews.results:getChoices()[idx]
    if not c then return end
    self.subviews.search:setText(c.entry.name)
end

-- ---- input ------------------------------------------------------------------
-- Anything that is not our own drag gets the TRUE origin back before the game
-- sees it: a click on the map starts a journey from wherever DF thinks we are.
-- Esc unwinds one layer at a time -- pan, then the search text (which takes the
-- line with it), then DF's own "leave the travel screen".
--
-- Ordinary keys are left alone: moving recentres the view by itself (the pan is
-- dropped in overlay_onupdate the moment your position changes), so cancelling
-- on every keystroke only made the map twitch. The one click still guarded is a
-- LEFT click on the lesser map, which means "travel there": DF works that
-- destination out from the true centre, so it must not be taken against a
-- panned view.
function WorldMapFeatures:onInput(keys)
    if not running then return false end
    if pan and keys.LEAVESCREEN then
        recenter()
        return true
    end
    if pan and keys._MOUSE_L and not is_greater() then recenter() end
    if keys.LEAVESCREEN and self.subviews.search.text ~= ''
            and not self.subviews.search.focus then
        self.subviews.search:setText('')
        return true
    end
    if keys._MOUSE_L and self:click_site() then return true end
    return WorldMapFeatures.super.onInput(self, keys)
end

-- Clicking a site on the WORLD map makes it the destination -- which, in this
-- script's one mechanism, means typing its name into the bar and letting the
-- exact match draw the line. Only the greater map: the lesser one is where
-- adv/map-travel's click-to-walk lives, and stealing its clicks would take the
-- walking with it. A click on open country is left to fall through untouched.
function WorldMapFeatures:click_site()
    if not is_greater() then return false end
    local g = df.global.gps
    local mp = port()
    local px = cellpx()
    local cx = (g.precise_mouse_x) // px
    local cy = (g.precise_mouse_y) // px
    if cx < 0 or cy < 0 or cx >= mp.dim_x or cy >= mp.dim_y then return false end
    local ax, ay = center_pos()
    if not ax then return false end
    local s = units_per_cell()
    -- the hovered world tile, and the mid tile inside it that site footprints
    -- are measured in (16 mid tiles to a world tile)
    local wx = (ax + (cx - mp.dim_x // 2) * s) // ARMY_PER_WORLD
    local wy = (ay + (cy - mp.dim_y // 2) * s) // ARMY_PER_WORLD
    local best
    for _, e in ipairs(build_index()) do
        if e.cat == 'site' and e.wx == wx and e.wy == wy then best = e break end
    end
    if not best then
        -- fall back to footprints: a town covers many world tiles, and its
        -- `pos` is only the one cell DF calls its centre
        for _, e in ipairs(build_index()) do
            if e.cat == 'site' and e.site
                    and wx * 16 + 8 >= e.site.global_min_x and wx * 16 + 8 <= e.site.global_max_x
                    and wy * 16 + 8 >= e.site.global_min_y and wy * 16 + 8 <= e.site.global_max_y then
                best = e
                break
            end
        end
    end
    if not best then return false end
    self.subviews.search:setText(best.name)
    return true
end

-- The drag itself is polled, not keyed: DF exposes the live button state, which
-- survives frames where no input event reaches the overlay.
function WorldMapFeatures:update_drag()
    local e = df.global.enabler
    local g = df.global.gps
    local held = e.mouse_mbut ~= 0 or e.mouse_mbut_down ~= 0
    if not held then drag = nil return end
    if not still_local() then return end            -- mid-journey: the army owns the centre
    if not drag then
        drag = {px = g.precise_mouse_x, py = g.precise_mouse_y}
        if not pan then
            pan = {home_x = adv().travel_origin_x, home_y = adv().travel_origin_y, ox = 0, oy = 0}
        end
        return
    end
    local px = cellpx()
    local dxc = (g.precise_mouse_x - drag.px) // px
    local dyc = (g.precise_mouse_y - drag.py) // px
    if dxc == 0 and dyc == 0 then return end
    drag.px = drag.px + dxc * px
    drag.py = drag.py + dyc * px
    -- a frame that rendered without updating could still be holding the old
    -- offset; take it back before changing it so the next apply writes fresh
    unapply_pan()
    local s = units_per_cell()
    pan.ox = pan.ox - dxc * s                       -- drag right = look further west
    pan.oy = pan.oy - dyc * s
end

function WorldMapFeatures:overlay_onupdate()
    if not running then return end
    if not dfhack.gui.matchFocusString('dungeonmode/Travel') then recenter() return end
    if pan and not still_local() then recenter() end
    -- The pan survives keystrokes but not MOVEMENT. Deciding which is which
    -- cannot be done by comparing the origin with `home`: our OWN offset makes
    -- it differ too, and the render that takes it back runs on a separate
    -- thread, so by update time it may or may not have happened. (Testing
    -- `~= home` did exactly this: every drag step wrote an offset, the next
    -- update read it back as "the player moved", and the pan died on the frame
    -- it was born -- panning stopped working altogether.) So compare against
    -- BOTH known-innocent values: the offset we last wrote, and home. Anything
    -- else was written by the game, which means you moved.
    if pan then
        local cx, cy = center_pos()
        local ours = wrote_x and cx == wrote_x and cy == wrote_y
        local home = cx == pan.home_x and cy == pan.home_y
        -- neither ours nor the value we captured: the game moved you. Let go
        -- WITHOUT restoring, or we would undo the move.
        if cx and not ours and not home then release_pan(false) end
    end
    pcall(function() self:recentre_frame() end)
    pcall(function() self:update_drag() end)
    apply_pan()                     -- hand DF the offset centre for this frame only
end

function WorldMapFeatures:onRenderFrame(dc, rect)
    WorldMapFeatures.super.onRenderFrame(self, dc, rect)
    if not running then return end
    -- paint FIRST (our own geometry reads the offset centre DF just drew from),
    -- then give the real origin back for the rest of the game loop
    -- a painting error must never take the frame down, but silently swallowing
    -- it once cost an evening: keep the last one where `lua` can read it
    local ok, err = pcall(function() self:paint_map() end)
    if not ok then last_error = tostring(err) end
    unapply_pan()
end

function WorldMapFeatures:paint_map()
    local mp = port()
    if mp.dim_x <= 0 then return end
    local pwx, pwy = player_world()
    if not pwx then return end
    -- the traveller's own cell comes from the EXACT army position, never from
    -- the world tile: rounding to the tile centre puts the marker up to 8 cells
    -- off on the lesser map and 24 when zoomed in next to a site
    local hx, hy = army_to_cell(player_pos())
    if not hx then return end
    if target and active_widget and active_widget.subviews.search.text ~= target_text then
        target, target_text = nil, nil          -- the bar moved on without us
    end
    if target then
        local tx, ty = world_to_cell(target.wx, target.wy)
        if tx and hx then
            paint_line(hx, hy, tx, ty)
            -- The marker goes on the target -- or, when the target lies beyond
            -- the map's edge (which on the lesser map is most of the world: it
            -- shows about 7 world tiles across), on the point where the line
            -- leaves the map, so the name and distance are always readable
            -- instead of a bare line running off the screen.
            local mx, my = clip_to_port(hx, hy, tx, ty)
            paint_cell(PEN_MARK, mx, my)
            local sx, sy = cell_to_text(mx, my)
            local dx, dy = target.wx - pwx, target.wy - pwy
            local dist = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
            local card = site_card(target, dist, bearing(dx, dy))
            if card then
                read_the_map().paint_card(card, sx, sy)
            else
                local label = ('%s (%d %s)'):format(target.name, dist, bearing(dx, dy))
                if target.stale then label = label .. ' (last seen)' end
                -- keep the whole string on the grid: flip to the other side of
                -- the marker when it would overrun the right edge, then trim
                -- what is left rather than painting past the end
                local dimx = df.global.gps.dimx
                local lx = sx + 2
                if lx + #label >= dimx then lx = sx - #label - 2 end
                if lx < 0 then lx = 0 end
                if on_screen(lx, sy) then
                    dfhack.screen.paintString(PEN_LABEL, lx, sy, label:sub(1, dimx - lx))
                end
            end
        end
    end
    -- while panned, DF's own marker sits at the panned centre, not on us. The
    -- marker is the whole indication: no offset readout, which was clutter in
    -- the corner of a map you are looking AT.
    if pan then paint_cell(PEN_HOME, hx, hy) end
end

OVERLAY_WIDGETS = {features = WorldMapFeatures}

-- the index and the pin belong to the world they were built in; the pan must
-- never outlive the screen
dfhack.onStateChange[_ENV] = function(sc)
    if sc == SC_WORLD_UNLOADED then
        recenter()
        index, index_built_for, target, target_text = nil, nil, nil, nil
        card_cache, all_sites_by_name = {}, nil
    end
end

function stop()
    recenter()
    running = false
end

if dfhack_flags and dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'recenter' then
    print(recenter() and 'adv/world-map-features: view recentred.' or 'adv/world-map-features: not panned.')
elseif arg == 'clear' then
    if active_widget then active_widget.subviews.search:setText('') end
    target, target_text = nil, nil
    print('adv/world-map-features: search cleared.')
elseif arg == 'stop' then
    stop()
    print('adv/world-map-features: paused for this session.')
elseif arg == 'help' then
    print('adv/world-map-features: middle-drag pans the travel map; Alt-F searches')
    print('everything your adventurer knows (sites, people, beasts, regions, groups, events).')
else
    running = true
    overlay.rescan()
    local n = #build_index(true)
    local by = {}
    for _, e in ipairs(index or {}) do by[e.cat] = (by[e.cat] or 0) + 1 end
    local parts = {}
    for _, c in ipairs{'site', 'person', 'beast', 'region', 'group', 'event'} do
        parts[#parts + 1] = ('%s %d'):format(c, by[c] or 0)
    end
    print(('adv/world-map-features: %s | %d known things (%s) | %s | %s')
        :format(running and 'ACTIVE' or 'stopped', n, table.concat(parts, ', '),
            pan and 'PANNED' or 'centred',
            target and ('line to: ' .. target.name) or 'no line'))
end
