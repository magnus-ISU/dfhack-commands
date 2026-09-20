-- Pick a spot, pick items, and the fort carries them there -- via a dump zone it runs itself.
--@module = true
--[[
fort/move-items

DF has no "carry this to there". It has DUMPING: mark items, and haulers take them to a
garbage dump zone. That is a real move order with the controls filed off -- you cannot say
which zone, only that the fort has one, and what comes back is forbidden where it lands.

This puts the controls back. Reached from the `dig-building` picker ("Move items", in the
custom-tool band beside Replace wall), it runs the whole errand:

  1. YOU CLICK THE SPOT the things should end up on. DF's Dig tool is disarmed while you do
     -- this is normally opened from the dig-building picker, with mining mode live, and a
     click meant for us would otherwise paint a dig designation too -- and put back after.
  2. It makes a garbage dump zone there and DELETES EVERY OTHER DUMP ZONE in the fort, so
     there is exactly one place a dumped item can go and it is the one you picked. Those
     other zones do not come back -- deleting them is what makes the destination certain.
  3. A PICKER opens: every kind of item that can reach your spot, one row per kind, with the
     same search / sort / value / quality / wear filters DFHack's "move goods to depot"
     screen uses. Say how many of each you want and it marks the CLOSEST ones.
  4. It marks them for dumping, sets the three standing orders the haulers need, and gets
     out of the way -- and reports "Moving N items" in DFHack's notification panel for as
     long as the haul takes. Clicking that line walks the items still on their way, one per
     click, so you can see where each has got to. Hover it and it says
     "Moving N items (Shift+click to cancel)"; SHIFT+CLICK calls the whole delivery off --
     the marks come off what has not moved, the zone goes, and whatever already landed is
     unforbidden. The picker's own row says `Cancel move` instead of `Move items` while a
     delivery is running, and does that.

     Anything you mark for dumping yourself while it runs JOINS the delivery: with one dump
     zone in the fort it was going to that spot anyway, and joining is what gets it counted,
     waited for, and unforbidden as it lands like the rest.
     Anything ALREADY marked for dumping when the picker opens is PRE-SELECTED in it: mark
     a pile with `d`-`b`-`d` on the map, open Move items, click the spot, click Move, and
     that pile is what goes. Deselect what you did not mean; whatever is left unselected
     is unmarked when the delivery starts, and any delivery already in flight is cancelled:
     there is one dump zone and one set of marks, so two deliveries at once would land in
     each other's pile.
  5. EACH ITEM IS UNFORBIDDEN AS IT LANDS. Dumped items are put down forbidden (DF's own
     rule), and a pile of forbidden goods is not a delivery -- so the watcher hands each one
     back to the fort on the first tick after it arrives, rather than the whole pile at the
     end. A delivery of two hundred stones is usable while the rest of it is still walking.
     When the last one is in, the zone goes. That last announcement carries the destination,
     so clicking it recentres the map on the pile.

Nothing is done at all unless you pick both a place and at least one item.

WHAT IS OFFERED, and what is not. Anything the fort can actually dump: loose items,
stockpiled items, and the contents of bins and barrels. Only items that can REACH the spot
-- item and destination in the same walkability group, which is DF's own answer to "can a
dwarf get from here to there" -- and nothing already standing on it.

Rows are one kind of thing, not one item: every gabbro figurine is a row, whatever its
quality or what it is encrusted with, because that is how you think about them.

TWO KINDS OF THING ARE ROWED BY WHAT THEY MEAN INSTEAD. Corpses split into butcherable
bodies / refuse / your own dead, and CAGES split by what is inside them -- important cages
(a megabeast, titan, forgotten beast, demon or night creature), prisoner cages (anybody
else who can think), animal cages, empty cages, and other cages for a cage being used as a
plain container. "Wooden cage" is a useless row when one of them holds a forgotten beast
and forty hold seeds. THE FILTERS
CUT INSIDE A ROW: set a minimum quality and a row of five earrings becomes a row of the
three that pass -- that is the count it shows, those are the items `[specific]` lists, and
those are what a click on it takes. A row none of whose items pass is not shown. Narrowing
the sliders pulls a selection down with them (the closest N of what still passes; a hand-
picked set drops what is hidden), and widening them again does not put it back. Each row
opens with the distance to its closest passing item. `Melt targets` (Shift-T) keeps only
metal items and caps the quality sliders at exceptional -- everything below masterwork, since
the masterworks and artifacts are the ones you keep -- as a starting point; move them
afterwards if you like. Turning it off puts quality back to "any". `Marked to melt` (Shift-L)
keeps only items already designated for melting AND selects every row of them as it is switched
on, so carrying the whole melt pile to the smelter is one click; deselect what you would rather
leave, and off widens the list again without touching what is picked. `Noble symbols` (Shift-N)
opens a list of the fort's nobles and keeps only the SYMBOLS OF OFFICE given to the one you
click, selecting all of them -- a noble moving house takes their regalia in one click; the list's
first row puts it back to any item. Symbols are the one artifact-flagged thing the picker will
move: DF marks a named object with the artifact flag, and haulers dump them like anything else.
Real artifacts stay out. `This z only` (Shift-Z)
keeps only items on the destination's own z-level, and `Burrow` (Shift-B) cycles through the
fort's burrows to keep only items standing inside the one named -- the two ways a fort already
names a pile ("this floor", "the hospital's stock") that are not a kind of item. CLICKING A ROW
takes all of that kind, and clicking it again clears it; SHIFT-CLICK marks every row from the
last one clicked to this one. The bands along the right edge -- `[-1]`, the count, `[+1]`,
`[+10]`, `[all]` -- are there when you want an exact number instead. `[specific]` opens the
individual items behind a row, listed by distance, if you want to choose among them
(shift-click selects a range there too).

THE THREE STANDING ORDERS. Refuse hauling is what actually moves a corpse or a bone to a
dump zone, and a fort that has turned any of the three off silently never finishes the job.
So it sets `gather refuse`, `gather refuse outdoors` and `gather outdoor vermin remains`,
every time, and says so.

    fort/move-items            open the picker (or the status of a move in progress)
    fort/move-items status     what is still being moved
    fort/move-items cancel     stop: unmark what has not moved yet, clean up, unforbid
                               (the same thing as shift-clicking the notification line)

The job survives a save and reload: what was marked, where it is going and what to put back
afterwards is persisted with the fort.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local STATE_KEY = 'move-items/state'

-- ---- saying things ----------------------------------------------------------
--
-- TWO KINDS OF MESSAGE, AND ONLY ONE OF THEM IS A NOTIFICATION.
--
-- `log` is the delivery talking about itself -- "3 newly dumped item(s) joined the delivery",
-- "delivery finished". Those used to go into DF's announcement log and alert strip, where the
-- game puts sieges, artifacts and dead dwarves, and items joining a run mid-way raised that
-- line again and again. They go to the DFHack console now and nowhere else.
--
-- `say` is a REFUSAL or an ERROR -- the click could not do what you asked. That belongs on
-- screen where you are looking, so it stays a DF announcement. Everything else about a
-- delivery that went well, including the count of what a click marked, is the delivery
-- describing itself and goes to `log`. Two messages went entirely: the prompt to click a spot
-- (the picker overlay already says it in its own panel) and "nothing selected" (the window
-- closing is the whole answer).
local function log(text)
    print(text)
end

local function say(text, color)
    print(text)
    pcall(dfhack.gui.showAnnouncement, text, color or COLOR_WHITE, false)
end

-- ---- persisted state ---------------------------------------------------------
--
-- A move outlives the screen that started it and has to outlive the SESSION too: the items
-- are already marked, the zone is already there, and a reload must not leave either
-- orphaned. So the whole job -- target, zone, and the ids of everything marked -- is
-- persisted with the site the moment it starts.

local function load_state()
    local d = dfhack.persistent.getSiteData(STATE_KEY, nil)
    if type(d) ~= 'table' or not d.zone_id then return nil end
    return d
end

local function save_state(s)
    pcall(dfhack.persistent.saveSiteData, STATE_KEY, s or {})
end

local function clear_state()
    pcall(dfhack.persistent.saveSiteData, STATE_KEY, {})
end

-- ---- the map ------------------------------------------------------------------

-- Can a dwarf walk from here to there? DF keeps a walkability GROUP per tile -- tiles in the
-- same group are mutually reachable on foot -- so the question is one field compare, not a
-- path search. Group 0 means "not walkable at all".
local function walk_group(pos)
    if not pos or pos.x < 0 then return nil end
    local g = dfhack.maps.getWalkableGroup(pos)
    if not g or g == 0 then return nil end
    return g
end

local function same_pos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- the distance the trade screen shows, computed its way
local function distance(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) + math.abs(a.z - b.z)
end

-- ---- what can be dumped -------------------------------------------------------

-- Items DF will never haul, whatever you mark. Forbidden is NOT in this list: a forbidden
-- item is one you set aside, and moving it is a fine thing to ask for -- the picker offers
-- the trade screen's "hide forbidden" filter instead of deciding for you.
local function dumpable(it, symbols)
    local f = it.flags
    if f.garbage_collect or f.removed or f.encased or f.construction or f.in_building
        or f.spider_web or f.hostile or f.trader or f.on_fire then return false end
    -- an artifact is not cargo -- except a SYMBOL OF OFFICE, which wears the artifact flag
    -- (that is what makes it a "named object") and is exactly the thing a noble moving house
    -- wants carried after them. Haulers dump them like anything else (tested: a symbol boot
    -- marked by hand was picked up and carried)
    if f.artifact and not (symbols and symbols[it.id]) then return false end
    -- carried or worn: the holder is using it
    if dfhack.items.getGeneralRef(it, df.general_ref_type.UNIT_HOLDER) then return false end
    return true
end

-- ---- corpses ------------------------------------------------------------------
--
-- (Butchery PRODUCTS are excluded -- bones, skulls, teeth, horns, shells, wool. DF files them
-- as corpse pieces because they come off an animal, but they are craft stock, not remains, and
-- they get ordinary item rows instead. See is_usable_remains.)
--
-- Three rows, because a pile of corpses is three different chores wearing one word. What
-- DF calls them all is "refuse".

local CORPSE_BUTCHER   = 'corpses:butcher'
local CORPSE_REFUSE    = 'corpses:refuse'
local CORPSE_OWN       = 'corpses:own'

local CORPSE_LABEL = {
    [CORPSE_BUTCHER] = 'Butcherable corpses',
    [CORPSE_REFUSE]  = 'Refuse corpses and body parts',
    [CORPSE_OWN]     = 'Fallen allies and residents',
}

local function creature_caste(race, caste)
    local raw = df.creature_raw.find(race)
    if not raw then return nil, nil end
    local c = (caste >= 0 and caste < #raw.caste) and raw.caste[caste] or nil
    return raw, c
end

-- a corpse of OURS: a citizen, a resident, or somebody who was here as a friend (a merchant,
-- a visiting bard). Read from the dead figure rather than the corpse: the corpse remembers
-- who it was, and who they were is what says whether this is a body to bury or refuse to
-- clear away.
local function is_own_dead(it)
    local hfid = it.hist_figure_id
    if hfid and hfid >= 0 then
        local hf = df.historical_figure.find(hfid)
        if hf then
            local civ = df.global.plotinfo.civ_id
            local group = df.global.plotinfo.group_id
            if hf.civ_id == civ then return true end
            for _, link in ipairs(hf.entity_links) do
                if link.entity_id == group or link.entity_id == civ then return true end
            end
        end
    end
    local uid = it.unit_id
    if uid and uid >= 0 then
        local u = df.unit.find(uid)
        if u and (dfhack.units.isCitizen(u, true) or dfhack.units.isResident(u)
                  or dfhack.units.isVisiting(u)) then return true end
    end
    return false
end

-- DF's own bits for "this piece IS a material", one per refuse-stockpile category: a refuse
-- pile sorts bones / skulls / shells / teeth / horns / hair separately from corpses and body
-- parts precisely because those are STOCK and the rest is rot.
local CORPSE_MATERIAL_FLAGS = {
    'bone', 'skull', 'shell', 'tooth', 'horn', 'hair_wool',
    'leather', 'pearl', 'silk', 'yarn', 'soap', 'wood', 'plant',
}

-- Is this corpse piece a usable craft material rather than remains?
--
-- The test is one of those flags AND NOT `unbutchered`, and both halves are load-bearing --
-- measured on a live fort, neither alone is enough:
--
--   * A SEVERED LIMB CARRIES THE MATERIAL BIT TOO. "troglodyte right lower arm" is
--     `bone + unbutchered`, because there are two bones inside it waiting to be cut out
--     (`material_amount[Bone] == 2`). It is a body part, not a bone. `unbutchered` is what
--     tells the two apart: the finished item -- "right lower leg bone" -- carries `bone`
--     alone. A severed head is `unbutchered` with no material bit at all.
--   * THE MATERIAL IS NOT A TEST EITHER. `dfhack.matinfo.decode` on that same severed arm
--     returns "troglodyte bone" with ITEMS_HARD set, because the item's dominant tissue is
--     bone -- so anything keyed off the material flags files severed limbs as craft stock.
--
-- MANGLED IS NOT UNUSABLE, which was worth checking because it looks like it should be: a
-- "crundle mangled skull" carries the same `skull` bit, the same "crundle bone" material and
-- the same ITEMS_HARD as a clean one, and the wiki is explicit that being mangled does not
-- stop a corpse being butchered. So mangled bones and skulls count as stock like any other.
-- The word only describes the state of the thing it came off.
--
-- SCALES AND CHITIN ARE NOT STOCK, which is the other way round from what you would guess.
-- "crundle scale" and "antman chitin" carry NO corpse flag and NO material amount, and their
-- material has no ITEMS_* flag of any kind -- nothing in the game can be made out of them --
-- so they stay filed with the refuse, which is where DF puts them.
local function is_usable_remains(it)
    local ok, flags = pcall(function() return it.corpse_flags end)
    if not ok or not flags then return false end
    if flags.unbutchered then return false end
    for _, bit in ipairs(CORPSE_MATERIAL_FLAGS) do
        local got, on = pcall(function() return flags[bit] end)
        if got and on then return true end
    end
    return false
end

-- which of the three rows this corpse or body part belongs to, or nil if it is not one
local function corpse_category(it)
    local t = it:getType()
    if t ~= df.item_type.CORPSE and t ~= df.item_type.CORPSEPIECE then return nil end
    -- BUTCHERY PRODUCTS ARE NOT REMAINS. A bone, a skull, a tooth, an antler, a bin of shorn
    -- alpaca wool -- DF files them all as CORPSEPIECE because they came off an animal, so they
    -- share an item type with a severed arm, but they are craft stock waiting on a workshop.
    -- Rowing them with the butchery leftovers is how they end up buried in a refuse pile.
    -- They fall through to ordinary item rows instead, grouped by what they are.
    if t == df.item_type.CORPSEPIECE and is_usable_remains(it) then return nil end
    if is_own_dead(it) then return CORPSE_OWN end
    -- a whole, unrotten body of an animal is meat on legs; anything else is refuse. A
    -- severed hand is a body PART however fresh it is, and a sentient corpse is never
    -- butchered by a fort that would rather not be that fort.
    if t == df.item_type.CORPSE and not it.flags.rotten then
        local _, caste = creature_caste(it.race, it.caste)
        if caste and not (caste.flags.CAN_LEARN or caste.flags.CAN_SPEAK) then
            return CORPSE_BUTCHER
        end
    end
    return CORPSE_REFUSE
end

-- ---- cages -------------------------------------------------------------------
--
-- A pile of cages is not one chore either. "cage" is a container, and what is inside decides
-- entirely what moving it means: a caged forgotten beast, a captured goblin, a stack of war
-- dogs and an empty cage waiting to be re-used have nothing to do with each other, and they
-- all read as "wooden cage" in a list sorted by what things are made of. So cages get rows by
-- OCCUPANT, the way corpses get rows by chore.
--
-- Unlike the corpse rows these are NOT exempt from the quality and value sliders: a cage is a
-- crafted object with both, and a masterwork glass cage is a real thing to filter on.

local CAGE_IMPORTANT = 'cages:important'
local CAGE_PRISONER  = 'cages:prisoner'
local CAGE_ANIMAL    = 'cages:animal'
local CAGE_EMPTY     = 'cages:empty'
local CAGE_OTHER     = 'cages:other'

local CAGE_LABEL = {
    [CAGE_IMPORTANT] = 'Important cages (beasts)',
    [CAGE_PRISONER]  = 'Prisoner cages',
    [CAGE_ANIMAL]    = 'Animal cages',
    [CAGE_EMPTY]     = 'Empty cages',
    [CAGE_OTHER]     = 'Other cages',
}

-- WHAT COUNTS AS "IMPORTANT" IS WIDER THAN MEGABEAST, deliberately. Sorting strictly on
-- MEGABEAST/SEMIMEGABEAST would file a caged forgotten beast, titan or werebeast under ANIMAL
-- CAGES, because none of them is sapient -- which is the one place this could be actively
-- misleading, since those are exactly the cages you never want to move by accident. So the
-- test is "is this thing a named horror", and the flag list says which: 7 castes in these raws
-- carry MEGABEAST and 8 carry SEMIMEGABEAST, but 45 carry TITAN, 459 FEATURE_BEAST (forgotten
-- beasts), 20 UNIQUE_DEMON and 192 NIGHT_CREATURE. Trim the list if you want it narrower.
local IMPORTANT_CASTE_FLAGS = {
    'MEGABEAST', 'SEMIMEGABEAST', 'TITAN', 'FEATURE_BEAST',
    'UNIQUE_DEMON', 'DEMON', 'NIGHT_CREATURE',
}

-- the units a cage holds. DF hangs them off the CAGE as CONTAINS_UNIT refs (the unit carries
-- the matching CONTAINED_IN_ITEM), which is not the same list as its contained ITEMS.
local function caged_units(it)
    local out = {}
    for _, r in ipairs(it.general_refs) do
        if r:getType() == df.general_ref_type.CONTAINS_UNIT then
            local u = df.unit.find(r.unit_id)
            if u then out[#out + 1] = u end
        end
    end
    return out
end

-- 3 = a beast you would rather not lose track of, 2 = somebody who can think, 1 = livestock
local function occupant_rank(u)
    local _, caste = creature_caste(u.race, u.caste)
    if not caste then return 1 end
    for _, f in ipairs(IMPORTANT_CASTE_FLAGS) do
        local ok, on = pcall(function() return caste.flags[f] end)
        if ok and on then return 3 end
    end
    if caste.flags.CAN_LEARN or caste.flags.CAN_SPEAK then return 2 end
    return 1
end

-- which cage row this belongs to, or nil if it is not a cage
local function cage_category(it)
    if it:getType() ~= df.item_type.CAGE then return nil end
    local units = caged_units(it)
    if #units > 0 then
        -- a cage holding several takes the rank of its most important occupant: one goblin
        -- among the war dogs makes it a prisoner cage, not a kennel
        local rank = 0
        for _, u in ipairs(units) do
            local r = occupant_rank(u)
            if r > rank then rank = r end
        end
        if rank >= 3 then return CAGE_IMPORTANT end
        if rank == 2 then return CAGE_PRISONER end
        return CAGE_ANIMAL
    end
    -- NOT EMPTY JUST BECAUSE NOBODY IS IN IT. Forts use cages as ordinary containers -- 45 of
    -- the 126 cages in the fort this was written against hold seeds and no creature at all --
    -- and calling those "empty" would have somebody move a cage expecting it to be spare.
    local ok, contents = pcall(dfhack.items.getContainedItems, it)
    if ok and contents and #contents > 0 then return CAGE_OTHER end
    return CAGE_EMPTY
end

-- ---- what row does this item belong to? --------------------------------------
--
-- Corpses and cages are grouped by what they MEAN -- whose body, what is inside -- rather than
-- by what they are made of, which is how everything else is grouped. Returns the row key, its
-- label, and whether it is a corpse row (those alone are exempt from the quality/value
-- sliders, having neither).
local function special_row(it)
    local cat = corpse_category(it)
    if cat then return cat, CORPSE_LABEL[cat], true end
    cat = cage_category(it)
    if cat then return cat, CAGE_LABEL[cat], false end
    return nil
end

-- WHICH BURROW IS IT STANDING IN? A burrow is how a fort says "this pile is the hospital's"
-- or "that is the magma forge's stock", and two identical bins read identically in the list
-- until you know which room each is in -- at which point the choice of what to move is
-- obvious. So the item window names it.
--
-- `isAssignedTile` is about 50us a call, so this asks once per TILE and remembers the answer:
-- the scan walks stockpiles, where a hundred items share a handful of tiles.
local burrow_cache
local function burrow_at(pos)
    if not pos then return nil end
    local key = ('%d,%d,%d'):format(pos.x, pos.y, pos.z)
    burrow_cache = burrow_cache or {}
    local hit = burrow_cache[key]
    if hit ~= nil then return hit.names or nil, hit.ids end
    local names, ids = {}, {}
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
        local ok, inside = pcall(dfhack.burrows.isAssignedTile, b, pos)
        if ok and inside then
            local name = b.name
            names[#names + 1] = (name ~= '' and name) or ('burrow ' .. b.id)
            ids[b.id] = true
        end
    end
    local out = {names = #names > 0 and table.concat(names, ', ') or false, ids = ids}
    burrow_cache[key] = out
    return out.names or nil, ids
end

-- the fort's burrows as picker options: "any" first, then one per burrow, in list order
local function burrow_options()
    local opts = {{label = 'any', value = -1}}
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
        local name = b.name
        opts[#opts + 1] = {label = (name ~= '' and name) or ('burrow ' .. b.id), value = b.id}
    end
    return opts
end

-- ---- symbols of office ------------------------------------------------------------
--
-- A symbol is an ARTIFACT CLAIM on the fort's own entity: `claim_type` Symbol, and
-- `symbol_claim_id` names the position ASSIGNMENT (position + holder) it was given to. So the
-- unit of "whose symbols" is the assignment, and a dwarf holding two positions has two sets --
-- the noble list below folds those into one entry per holder.

-- item id -> assignment id, for every symbol the fort has handed out
local function symbol_lookup()
    local site = df.historical_entity.find(df.global.plotinfo.group_id)
    local out = {}
    if not site then return out end
    for _, c in ipairs(site.artifact_claims) do
        if c.claim_type == df.artifact_claim_type.Symbol and c.symbol_claim_id ~= -1 then
            local ar = df.artifact_record.find(c.artifact_id)
            if ar and ar.item then out[ar.item.id] = c.symbol_claim_id end
        end
    end
    return out
end

-- Every noble holding a position, one entry each: {name, hf, positions, assignments = {id = true},
-- count = symbols handed out}. Sorted most symbols first, then by name.
function noble_list()
    local site = df.historical_entity.find(df.global.plotinfo.group_id)
    if not site then return {} end
    local per_assignment = {}
    for _, aid in pairs(symbol_lookup()) do
        per_assignment[aid] = (per_assignment[aid] or 0) + 1
    end
    local titles = {}
    for _, p in ipairs(site.positions.own) do titles[p.id] = p.name[0] end
    local by_hf, out = {}, {}
    for _, a in ipairs(site.positions.assignments) do
        if a.histfig ~= -1 then
            local n = by_hf[a.histfig]
            if not n then
                local hf = df.historical_figure.find(a.histfig)
                n = {hf = a.histfig, positions = {}, assignments = {}, count = 0,
                     name = hf and dfhack.translation.translateName(hf.name) or '?'}
                by_hf[a.histfig] = n
                out[#out + 1] = n
            end
            n.positions[#n.positions + 1] = titles[a.position_id] or '?'
            n.assignments[a.id] = true
            n.count = n.count + (per_assignment[a.id] or 0)
        end
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return out
end

-- ---- the candidate scan --------------------------------------------------------
--
-- ONE PASS over every item in play, and it is not cheap (a fort with 27k items takes about a
-- second). It runs when the picker opens and not again -- the alternative, asking the
-- question per row or per keystroke, is the same work many times over. The tile -> walkability
-- lookup is cached because items pile up: 14k items sat on 2.1k distinct tiles here.

-- Made of a metal, whatever the item: the thing a smelter can take back. Metals are
-- inorganic (material type 0), so the raw is read straight rather than through matinfo,
-- which costs 0.5ms an item and this runs on every item in the fort.
local function is_metal(it)
    local idx = it:getMaterialIndex()
    if it:getMaterial() ~= 0 or idx < 0 then return false end
    local raw = df.global.world.raws.inorganics.all[idx]
    return raw and raw.material.flags.IS_METAL or false
end

function scan_items(target)
    burrow_cache = nil                     -- fresh burrow answers per scan
    local tgroup = walk_group(target)
    if not tgroup then return nil, 'that tile is not somewhere a dwarf can stand' end

    local groups, order = {}, {}
    local tile_group = {}
    local total = 0
    local symbols = symbol_lookup()

    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if dumpable(it, symbols) then
            local x, y, z = dfhack.items.getPosition(it)
            if x and x >= 0 then
                local pos = xyz2pos(x, y, z)
                if not same_pos(pos, target) then
                    local key = ('%d,%d,%d'):format(x, y, z)
                    local g = tile_group[key]
                    if g == nil then g = walk_group(pos) or false; tile_group[key] = g end
                    if g == tgroup then
                        local gkey, label, is_corpse = special_row(it)
                        if not gkey then
                            -- DF appends a stack marker (" <#8>") to a stacked item's
                            -- description; the row is the KIND, so the one item's count has
                            -- no business in its name
                            label = dfhack.items.getDescription(it, 0, false)
                                        :gsub('%s*<#%d+>%s*$', '')
                            gkey = ('%d:%d:%d:%d'):format(it:getType(), it:getSubtype(),
                                                          it:getMaterial(), it:getMaterialIndex())
                            -- A BODY PART REPORTS NO MATERIAL: camel hair, yak hair and alpaca
                            -- wool all key as 46:-1:-1:-1, so they collapsed into one row named
                            -- after whichever arrived first. The description is the only thing
                            -- that tells them apart, so it joins the key for those.
                            if it:getMaterial() < 0 then gkey = gkey .. ':' .. label end
                        end
                        local grp = groups[gkey]
                        if not grp then
                            grp = {key = gkey, label = label, corpse = is_corpse or false,
                                   items = {}, sel = 0, specific = nil}
                            groups[gkey] = grp
                            order[#order + 1] = grp
                        end
                        local bnames, bids = burrow_at(pos)
                        grp.items[#grp.items + 1] = {
                            id = it.id, dist = distance(pos, target), z = z,
                            desc = dfhack.items.getDescription(it, 0, true),
                            value = dfhack.items.getValue(it),
                            quality = it:getQuality(), wear = it.wear,
                            forbidden = it.flags.forbid, dump = it.flags.dump,
                            metal = is_metal(it), to_melt = it.flags.melt,
                            symbol = symbols[it.id],     -- assignment id, if a symbol of office
                            burrow = bnames, burrow_ids = bids,
                        }
                        total = total + 1
                    end
                end
            end
        end
    end

    for _, grp in ipairs(order) do
        table.sort(grp.items, function(a, b)
            if a.dist ~= b.dist then return a.dist < b.dist end
            return a.id < b.id
        end)
        -- a row's own numbers, so filters and sorting have something to sort on
        local v, q, w = 0, 0, 0
        for _, e in ipairs(grp.items) do
            v = math.max(v, e.value); q = math.max(q, e.quality); w = math.max(w, e.wear)
        end
        grp.value, grp.quality, grp.wear = v, q, w
        grp.eligible = grp.items      -- narrowed per filter by the picker
        grp.total = #grp.items
        -- ALREADY MARKED FOR DUMPING = ALREADY CHOSEN. Marking with `d`-`b`-`d` is how the map
        -- lets you point at things -- "these, this pile, that corpse" -- and a picker that then
        -- opened with them unselected threw the pointing away. So they open selected, as a
        -- hand-picked set, and the rest of the picker works as before: deselect what you do
        -- not mean, add what you do. Whatever is left unselected when you click Move is unmarked.
        local pre, n = {}, 0
        for _, e in ipairs(grp.items) do
            if e.dump then pre[e.id] = true; n = n + 1 end
        end
        if n > 0 then grp.specific = pre; grp.sel = n end
    end
    return order, nil, total
end

-- ---- doing it ------------------------------------------------------------------

local function dump_zones()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Civzone and b.type == df.civzone_type.Dump then
            out[#out + 1] = b
        end
    end
    return out
end

-- Every other dump zone goes. This is the whole reason the destination is knowable: DF sends
-- a dumped item to whichever dump zone suits the hauler, so a second zone is a second answer.
local function clear_dump_zones(keep_id)
    local n = 0
    for _, b in ipairs(dump_zones()) do
        if b.id ~= keep_id then
            if pcall(dfhack.buildings.deconstruct, b) then n = n + 1 end
        end
    end
    return n
end

local function make_dump_zone(pos)
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', 1))
    extents[0] = 1
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.Civzone, subtype = df.civzone_type.Dump, abstract = true,
        pos = pos, width = 1, height = 1,
        fields = {room = {x = pos.x, y = pos.y, width = 1, height = 1, extents = extents},
                  assigned_unit_id = -1},
    })
    if not ok or not bld then return nil end
    -- ACTIVE, or the zone is drawn greyed out and does nothing: a civzone created through
    -- constructBuilding comes up switched off, and the flag that turns it on is
    -- `spec_sub_flag.active` (quickfort sets it on every zone it makes, for the same reason).
    -- Nothing in the zone's own UI calls this "suspended", but that is what it looks like.
    pcall(function() bld.spec_sub_flag.active = true end)
    pcall(function() dfhack.buildings.notifyCivzoneModified(bld) end)
    return bld
end

-- The haulers' own switches. A fort with refuse gathering off never finishes a dump and
-- never says why -- the jobs simply are not posted.
local ORDERS = {
    {field = 'standing_orders_gather_refuse',         name = 'gather refuse'},
    {field = 'standing_orders_gather_refuse_outside', name = 'gather refuse outdoors'},
    {field = 'standing_orders_gather_vermin_remains', name = 'gather outdoor vermin remains'},
}

local function ensure_standing_orders()
    local changed = {}
    for _, o in ipairs(ORDERS) do
        if df.global[o.field] ~= 1 then
            df.global[o.field] = 1
            changed[#changed + 1] = o.name
        end
    end
    return changed
end

-- mark the chosen items and remember them; returns how many were marked
local function mark_items(ids)
    local marked = {}
    local symbols = symbol_lookup()
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and dumpable(it, symbols) then
            it.flags.dump = true
            -- an item nobody may touch is never hauled, so a forbidden item being MOVED is
            -- unforbidden now rather than at the end
            it.flags.forbid = false
            marked[#marked + 1] = id
        end
    end
    return marked
end

-- Split the job into what is still walking and what has landed. DF clears `dump` when the
-- item is put down in the zone, so a cleared flag IS the arrival -- which is what lets the
-- watcher hand each item back to the fort as it comes in.
local function partition_pending(ids)
    local pending, arrived = {}, {}
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it then
            if it.flags.dump then pending[#pending + 1] = id
            else arrived[#arrived + 1] = id end
        end
    end
    return pending, arrived
end

-- the ids still waiting
local function still_pending(ids)
    return (partition_pending(ids))
end

-- what a finished move leaves behind: forbidden goods in a heap. Dumped items are forbidden
-- where they land (DF's own rule), which makes a delivery look like a pile of rubbish and
-- keeps every one of them out of the fort's reach.
local function unforbid(ids)
    local n = 0
    for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and it.flags.forbid then it.flags.forbid = false; n = n + 1 end
    end
    return n
end

local function remove_zone(zone_id)
    local b = df.building.find(zone_id)
    if b then pcall(dfhack.buildings.deconstruct, b) end
end

-- Finish: the zone goes, everything moved is handed back to the fort, and the job is
-- forgotten. Safe to call twice.
function finish(quiet)
    local s = load_state()
    if not s then return false end
    remove_zone(s.zone_id)
    -- The watcher unforbids each item as it lands, so this is only the last few -- the ones
    -- that arrived between its final tick and now. Kept because finish() is also reached by
    -- paths the watcher never ran for (a cancel, a delivery replaced by a new one).
    unforbid(s.items or {})
    local n = #(s.items or {})
    local target = s.target
    clear_state()
    if not quiet then
        local text = ('move-items: delivery finished -- %d item(s) delivered, dump zone removed.')
            :format(n)
        -- A ZOOM announcement, so the line recentres the map on the pile when you click it (or
        -- press the recentre key). "It arrived" is not much use without "and it is over there":
        -- the whole point of the delivery was a place, and this is the one message that names it.
        if target then
            text = ('%s (at %d,%d,%d)'):format(text, target.x, target.y, target.z)
        end
        log(text)
    end
    return true
end

-- Cancel: whatever has not moved yet stops being marked; whatever has, still gets unforbidden.
function cancel()
    local s = load_state()
    if not s then return false end
    for _, id in ipairs(s.items or {}) do
        local it = df.item.find(id)
        if it and it.flags.dump then it.flags.dump = false end
    end
    remove_zone(s.zone_id)
    unforbid(s.items or {})
    clear_state()
    return true
end

-- Cancel AND say what happened, which is the form every button wants. Kept beside `cancel`
-- rather than inside it so the internal callers (a new delivery replacing an old one) stay
-- silent: that one already has its own sentence to say.
function cancel_delivery()
    local st = status()
    if not st then return false end
    cancel()
    moving_count = 0
    local landed = st.total - st.pending
    say(('move-items: delivery cancelled -- %d item(s) unmarked before they moved, %d '
         .. 'already delivered and unforbidden, dump zone removed.'):format(st.pending, landed),
        COLOR_YELLOW)
    return true
end

-- Is a delivery in flight? The CHEAP question, for callers that ask every frame -- the
-- dig-building row renames itself from this. `status()` answers the same thing but walks every
-- item in the delivery to count what is still moving, which is right once and wrong sixty
-- times a second.
function in_flight()
    return load_state() ~= nil
end

function status()
    local s = load_state()
    if not s then return nil end
    local pending = still_pending(s.items or {})
    return {target = s.target, zone_id = s.zone_id, total = #(s.items or {}), pending = #pending}
end

-- start the job: zone, marks, standing orders, persisted state
-- Everything the fort currently has marked for dumping, unmarked.
--
-- A new delivery starts from a clean slate for the same reason it deletes the other dump
-- zones: a dumped item goes to whatever dump zone is going, so anything ALREADY marked --
-- the last delivery's leftovers, a stray `d`-`b`-`d` from months ago, another tool's work --
-- would be carried to the spot you just picked, mixed in with what you asked for. This is
-- deliberately fort-wide and deliberately blunt; the alternative is a delivery that quietly
-- brings things nobody asked for.
local function clear_all_dumps(keep)
    local n = 0
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it.flags.dump then
            it.flags.dump = false
            -- an item the picker opened with pre-selected and is about to re-mark was not
            -- "stale": it is the delivery, so it does not count as unmarked
            if not (keep and keep[it.id]) then n = n + 1 end
        end
    end
    return n
end

local function begin_move(target, ids)
    if not target or #ids == 0 then return nil, 'nothing to do' end
    -- A NEW JOB REPLACES THE OLD ONE. Two deliveries at once cannot both be true: there is one
    -- dump zone and one set of marks, so the second would silently steal the first's haulers
    -- and land its items in the wrong place. The old one is cancelled properly -- its marks
    -- dropped, its zone removed, whatever already arrived unforbidden -- rather than forgotten.
    local replaced = cancel() and true or false
    local chosen = {}
    for _, id in ipairs(ids) do chosen[id] = true end
    local stale = clear_all_dumps(chosen)
    local zone = make_dump_zone(target)
    if not zone then return nil, 'could not place a dump zone there' end
    local removed = clear_dump_zones(zone.id)
    local marked = mark_items(ids)
    if #marked == 0 then
        remove_zone(zone.id)
        return nil, 'none of those items can be dumped any more'
    end
    local orders = ensure_standing_orders()
    save_state{target = {x = target.x, y = target.y, z = target.z},
               zone_id = zone.id, items = marked}
    return {marked = #marked, removed_zones = removed, orders = orders,
            replaced = replaced, stale_dumps = stale}
end

-- ---- the watcher, and the progress line ------------------------------------------
--
-- The watcher runs while a move is in progress and does nothing whatsoever otherwise: one
-- persisted-state read, throttled to a few seconds, since a haul takes minutes.
--
-- It reports through DFHack's OWN notification panel rather than a window of its own. A
-- delivery is minutes of nothing visibly happening, so "is it still going?" deserves an
-- answer on screen -- but it deserves one line among the fort's other standing notices, not
-- a floating box the player has to place and then look past.

moving_count = moving_count or 0      -- how many items are still on their way; 0 = idle

WatchOverlay = defclass(WatchOverlay, overlay.OverlayWidget)
WatchOverlay.ATTRS{
    desc = 'Finishes a move-items delivery: removes the dump zone and unforbids what arrived.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},          -- draws nothing: the progress line is a notification
    overlay_onupdate_max_freq_seconds = 5,
    version = 3,
}

-- ANYTHING ELSE YOU MARK FOR DUMPING JOINS THE DELIVERY.
--
-- While a delivery is running there is exactly one dump zone in the fort -- this tool deleted
-- the others -- so an item marked by hand IS going to the same spot whether we adopt it or
-- not. Adopting it is what makes the rest true: it is counted in "Moving N items", the
-- delivery is not declared finished while it is still walking, and it is unforbidden when it
-- lands like everything else. Left unadopted it would arrive forbidden, on a pile the tool
-- had already cleaned up and forgotten.
local function adopt_new_dumps(s)
    local known = {}
    for _, id in ipairs(s.items or {}) do known[id] = true end
    local added = 0
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it.flags.dump and not known[it.id] then
            s.items[#s.items + 1] = it.id
            known[it.id] = true
            added = added + 1
        end
    end
    if added > 0 then
        save_state(s)
        log(('move-items: %d newly dumped item(s) joined the delivery.'):format(added))
    end
    return added
end

function WatchOverlay:overlay_onupdate()
    local s = load_state()
    if not s then moving_count = 0; return end
    adopt_new_dumps(s)
    local pending, arrived = partition_pending(s.items or {})
    -- HANDED BACK AS THEY LAND, not in one go at the end. An item is unforbidden on the first
    -- tick after it is put down, so a long delivery is usable while the rest of it is still
    -- walking -- what has arrived is yours, instead of the whole pile staying out of the
    -- fort's reach until the last hauler gets there. Costs nothing: these are the same ids
    -- the pending count already walked, and unforbid only writes to items still forbidden.
    unforbid(arrived)
    if #pending == 0 then
        moving_count = 0
        finish()
        return
    end
    moving_count = #pending
end

-- the notification line: "Moving 7 items", and clicking it shows you where they are going
local NOTIFY_NAME = 'move_items_progress'

-- The panel this line lives in is DFHack's own `gui/notify` overlay. We need a handle on it
-- for two things below -- reading which row the mouse is over, and telling it to re-measure
-- when our row's text changes length -- and the overlay registry is where live widget
-- instances can be found by name.
local function notify_panel()
    local ok, st = pcall(overlay.get_state)
    if not ok or type(st) ~= 'table' or type(st.db) ~= 'table' then return nil end
    local entry = st.db['gui/notify.panel']
    local w = entry and entry.widget
    if w and w.visible and w.subviews and w.subviews.list then return w end
    return nil
end

-- Is the mouse over OUR row, as opposed to one of the fort's other notices? The list knows
-- which row is under the cursor; the row knows which notification drew it.
local function notify_hovered()
    local w = notify_panel()
    if not w then return false end
    local ok, idx = pcall(w.subviews.list.getIdxUnderMouse, w.subviews.list)
    if not ok or not idx then return false end
    local choice = w.subviews.list.choices and w.subviews.list.choices[idx]
    return choice ~= nil and choice.data ~= nil and choice.data.name == NOTIFY_NAME
end

local CANCEL_HINT = ' (Shift+click to cancel)'

-- The text is a FUNCTION, not a string, because the panel only rebuilds its rows every five
-- seconds and hover has to answer now: a token's text is re-read on every render, so the hint
-- appears the frame the mouse arrives. What it can't do from here is widen the panel -- that
-- is measured at rebuild time -- so `WatchOverlay:render` re-measures on the way in and out.
local function notify_message()
    if not dfhack.world.isFortressMode() then return end
    local s = load_state()
    if not s then return end
    local left = #still_pending(s.items or {})
    if left == 0 then return end
    moving_count = left
    return {{
        text = function()
            local n = moving_count
            return ('Moving %d item%s%s'):format(n, n == 1 and '' or 's',
                notify_hovered() and CANCEL_HINT or '')
        end,
        pen = COLOR_WHITE,
    }}
end

-- Clicking the line walks the items that have not arrived yet, one per click -- the same
-- cycle-zoom the fort's other notifications use. "Moving 7 items" answers how many; WHICH
-- seven, and where they have got to, is the question you click for. An item being carried
-- reports the hauler's position, since that is where it is.
local notify_cycle = 0

-- SHIFT+CLICK CALLS THE WHOLE THING OFF. The notification panel hands the click's secondary
-- flag straight through (its list fires `on_submit2` when shift is down), so the one line
-- that reports the delivery is also the one that stops it -- no command to remember and no
-- screen to reopen. A plain click still walks the items.
local function notify_click(_, shift)
    if shift then
        cancel_delivery()
        return
    end
    local s = load_state()
    if not s then return end
    local pending = still_pending(s.items or {})
    if #pending == 0 then
        if s.target then
            dfhack.gui.revealInDwarfmodeMap(xyz2pos(s.target.x, s.target.y, s.target.z), true, true)
        end
        return
    end
    -- skip over anything that has stopped having a position (eaten, melted, hauled into a
    -- container that is itself in flight) rather than sitting on a dead item forever
    for _ = 1, #pending do
        notify_cycle = (notify_cycle % #pending) + 1
        local it = df.item.find(pending[notify_cycle])
        local x, y, z = nil, nil, nil
        if it then x, y, z = dfhack.items.getPosition(it) end
        if x and x >= 0 then
            df.global.plotinfo.follow_unit = -1
            df.global.plotinfo.follow_item = -1
            dfhack.gui.revealInDwarfmodeMap(xyz2pos(x, y, z), true, true)
            return
        end
    end
end

-- Our row grows by the width of the hint when the mouse lands on it, and the notification
-- panel sizes itself from its widest row only when it rebuilds -- every five seconds. So the
-- transition is caught here, on the frame it happens, and the panel is asked to lay out again:
-- without this the hint is drawn into a frame too narrow for it and comes out clipped.
function WatchOverlay:render(dc)
    if moving_count > 0 then
        local hovered = notify_hovered()
        if hovered ~= self.was_hovered then
            self.was_hovered = hovered
            local w = notify_panel()
            if w then pcall(w.updateLayout, w) end
        end
    elseif self.was_hovered then
        self.was_hovered = false
    end
    WatchOverlay.super.render(self, dc)
end

local function register_notification()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok then return end
    local entry = n.NOTIFICATIONS_BY_NAME[NOTIFY_NAME]
    if not entry then
        entry = {name = NOTIFY_NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NOTIFY_NAME] = entry
    end
    entry.desc = 'Shows how many items a fort/move-items delivery still has on the way.'
    entry.dwarf_fn = notify_message
    entry.on_click = notify_click
    if n.config and n.config.data and not n.config.data[NOTIFY_NAME] then
        n.config.data[NOTIFY_NAME] = {enabled = true, version = 1}
    end
end

-- ---- the individual-item window -------------------------------------------------

SpecificScreen = defclass(SpecificScreen, gui.ZScreenModal)
SpecificScreen.ATTRS{focus_path = 'move-items/specific'}

function SpecificScreen:init(info)
    self.group = info.group
    self.on_close = info.on_close
    -- only what the picker's sliders let through: the row IS those items, here as elsewhere
    self.items = self.group.eligible or self.group.items
    -- the explicit set starts as whatever the row's number already means: the closest N
    self.chosen = {}
    if self.group.specific then
        for id in pairs(self.group.specific) do self.chosen[id] = true end
    else
        for i = 1, math.min(self.group.sel, #self.items) do self.chosen[self.items[i].id] = true end
    end
    self.last_idx = nil
    SPEC_ACTIVE = self    -- module-level handle, the picker's twin

    self:addviews{
        widgets.Window{
            frame = {w = 74, h = 30},
            frame_title = self.group.label,
            resizable = true,
            subviews = {
                widgets.Label{frame = {t = 0, l = 0},
                    text = 'Click to pick one, shift-click to pick a range.'},
                widgets.Label{frame = {t = 1, l = 0}, text = {{text = 'dist', pen = COLOR_GRAY},
                    {gap = 3, text = 'item', pen = COLOR_GRAY}}},
                widgets.List{
                    view_id = 'list',
                    frame = {t = 3, l = 0, r = 0, b = 2},
                    choices = self:choices(),
                    on_submit = function(idx) self:toggle(idx, false) end,
                },
                widgets.HotkeyLabel{frame = {b = 0, l = 0}, key = 'LEAVESCREEN',
                    label = 'Done', on_activate = function() self:dismiss() end},
            },
        },
    }
end

function SpecificScreen:choices()
    local out = {}
    for i, e in ipairs(self.items) do
        local mark = self.chosen[e.id] and string.char(251) or ' '   -- a checkmark if we have one
        local row = {{text = ('%-8d [%s] %s'):format(e.dist, mark, e.desc)}}
        if e.burrow then
            row[#row + 1] = {gap = 1, text = ('(%s)'):format(e.burrow), pen = COLOR_GRAY}
        end
        out[#out + 1] = {text = row, idx = i}
    end
    return out
end

-- A CLICK MUST NOT SCROLL THE LIST BACK TO THE TOP.
--
-- `widgets.List` moves the view to wherever `selected` is every time `setChoices` runs (it
-- calls setSelected -> moveCursor, which drags page_top to bring the selection into view).
-- Both screens here take `_MOUSE_L` in their own `onInput` -- they have to, because WHICH BAND
-- of a row was clicked is what decides between [specific], [-], [+], [+10] and "all of this
-- kind" -- and returning true means the List's own mouse handler, the one that would have
-- called `setSelected(idx)`, never runs. So `selected` sat at row 1 while the player clicked
-- row 40, and the refresh afterwards snapped the view back to the top.
--
-- Two halves: move the selection to the row actually clicked, and put `page_top` back after
-- rebuilding, so that a row appearing or disappearing under a filter cannot scroll the view
-- either. The scrollbar is told separately because `setChoices` updated it from the old top.
local function set_choices_keeping_view(list, choices, selected)
    local top = list.page_top
    list:setChoices(choices, selected)
    local max_top = math.max(1, #list.choices - list.page_size + 1)
    list.page_top = math.max(1, math.min(top, max_top))
    list.scrollbar:update(list.page_top, list.page_size, #list.choices)
end

function SpecificScreen:refresh()
    local list = self.subviews.list
    set_choices_keeping_view(list, self:choices(), list:getSelected())
end

-- shift-click extends from the last one clicked, which is what every list in the world does
function SpecificScreen:toggle(idx, shift)
    local items = self.items
    if shift and self.last_idx then
        local a, b = math.min(self.last_idx, idx), math.max(self.last_idx, idx)
        local on = not self.chosen[items[idx].id]
        for i = a, b do self.chosen[items[i].id] = on or nil end
    else
        local id = items[idx].id
        self.chosen[id] = (not self.chosen[id]) or nil
    end
    self.last_idx = idx
    self:refresh()
end

function SpecificScreen:onInput(keys)
    if keys._MOUSE_L then
        local list = self.subviews.list
        local idx = list:getIdxUnderMouse()
        if idx then
            list:setSelected(idx)      -- we swallow the click, so do the List's own bookkeeping
            self:toggle(idx, dfhack.internal.getModifiers().shift)
            return true
        end
    end
    return SpecificScreen.super.onInput(self, keys)
end

function SpecificScreen:onDismiss()
    if SPEC_ACTIVE == self then SPEC_ACTIVE = nil end
    local set, n = {}, 0
    for id in pairs(self.chosen) do set[id] = true; n = n + 1 end
    self.group.specific = (n > 0) and set or nil
    self.group.sel = n
    if self.on_close then self.on_close() end
end

-- ---- which noble's symbols --------------------------------------------------------
--
-- A modal list of the fort's nobles, most symbols first, with the positions each holds and
-- how many symbols they have been given. Picking one hands the picker that noble; the first
-- row clears it.

NobleScreen = defclass(NobleScreen, gui.ZScreenModal)
NobleScreen.ATTRS{focus_path = 'move-items/noble'}

function NobleScreen:init(info)
    self.on_pick = info.on_pick
    local choices = {{text = {{text = '(any item -- no noble)', pen = COLOR_GRAY}}, noble = false}}
    for _, n in ipairs(noble_list()) do
        local pen = n.count > 0 and COLOR_WHITE or COLOR_GRAY
        choices[#choices + 1] = {
            text = {{text = ('%-32s'):format(n.name:sub(1, 32)), pen = pen},
                    {text = ('%-28s'):format(table.concat(n.positions, ', '):sub(1, 28)), pen = COLOR_GRAY},
                    {text = ('%3d symbol(s)'):format(n.count), pen = pen}},
            noble = n,
        }
    end
    self:addviews{
        widgets.Window{
            frame = {w = 84, h = 24},
            frame_title = 'Whose symbols of office?',
            resizable = true,
            subviews = {
                widgets.Label{frame = {t = 0, l = 0},
                    text = 'Click a noble to keep only the symbols of office given to them.'},
                widgets.Label{frame = {t = 1, l = 0}, text = {{text = ('%-32s'):format('noble'), pen = COLOR_GRAY},
                    {text = ('%-28s'):format('positions'), pen = COLOR_GRAY}, {text = 'symbols', pen = COLOR_GRAY}}},
                widgets.List{
                    view_id = 'list',
                    frame = {t = 3, l = 0, r = 0, b = 2},
                    choices = choices,
                    on_submit = function(_, choice)
                        self:dismiss()
                        if self.on_pick then self.on_pick(choice.noble) end
                    end,
                },
                widgets.HotkeyLabel{frame = {b = 0, l = 0}, key = 'LEAVESCREEN',
                    label = 'Back', on_activate = function() self:dismiss() end},
            },
        },
    }
end

-- ---- the picker -----------------------------------------------------------------

local COL_SPECIFIC = 12      -- width of the [specific] button
local BTN = {                -- the buttons at the right of a row, in order
    {label = '[-1]',   delta = -1},
    {label = '[+1]',   delta = 1},
    {label = '[+10]',  delta = 10},
    {label = '[all]',  delta = 'all'},
}

PickerScreen = defclass(PickerScreen, gui.ZScreen)
PickerScreen.ATTRS{focus_path = 'move-items/picker'}

function PickerScreen:init(info)
    self.target = info.target
    self.groups = info.groups
    self.caravan = nil
    local ok, common = pcall(reqscript, 'internal/caravan/common')
    if ok then self.caravan = common end

    local sliders = {}
    if self.caravan and self.caravan.get_slider_widgets then
        local sok, w = pcall(self.caravan.get_slider_widgets, self)
        if sok then sliders = w end
    end

    self:addviews{
        widgets.Window{
            view_id = 'win',
            frame = {w = 100, h = 46},
            frame_title = 'Move items',
            resizable = true,
            subviews = {
                widgets.EditField{
                    view_id = 'search',
                    frame = {t = 0, l = 0, r = 1},
                    label_text = 'Search: ',
                    on_change = function() self:refresh() end,
                },
                widgets.CycleHotkeyLabel{
                    view_id = 'sort',
                    frame = {t = 1, l = 0, w = 24},
                    label = 'Sort by:',
                    key = 'CUSTOM_SHIFT_S',
                    options = {
                        {label = 'distance', value = 'dist'},
                        {label = 'name', value = 'name'},
                        {label = 'quantity', value = 'qty'},
                        {label = 'value', value = 'value'},
                    },
                    on_change = function() self:refresh() end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'hide_forbidden',
                    frame = {t = 1, l = 26, w = 28},
                    label = 'Hide forbidden:',
                    key = 'CUSTOM_SHIFT_F',
                    options = {{label = 'Yes', value = true, pen = COLOR_GREEN},
                               {label = 'No', value = false}},
                    initial_option = false,
                    on_change = function() self:refresh() end,
                },
                -- MELT TARGETS: metal only, and the quality sliders jump to ordinary..exceptional
                -- -- everything BELOW masterwork, because the masterworks and artifacts are the
                -- ones you keep -- as a starting point; they stay yours to move afterwards. Off
                -- puts quality back to "any", since the jump was this button's doing.
                widgets.ToggleHotkeyLabel{
                    view_id = 'melt_targets',
                    frame = {t = 1, l = 56, w = 26},
                    label = 'Melt targets:',
                    key = 'CUSTOM_SHIFT_T',
                    options = {{label = 'Yes', value = true, pen = COLOR_GREEN},
                               {label = 'No', value = false}},
                    initial_option = false,
                    on_change = function(on)
                        local sv = self.subviews
                        if sv.min_quality and sv.max_quality then
                            sv.min_quality:setOption(0)
                            sv.max_quality:setOption(on and 4 or 6)
                        end
                        self:refresh()
                    end,
                },
                -- WHERE THE ITEMS ARE: only this z-level (the destination's), and/or only one
                -- burrow. "Everything on this floor" and "the hospital's stock" are the two
                -- ways a fort already names a pile, and neither is a kind of item.
                widgets.ToggleHotkeyLabel{
                    view_id = 'this_z',
                    frame = {t = 2, l = 0, w = 24},
                    label = 'This z only:',
                    key = 'CUSTOM_SHIFT_Z',
                    options = {{label = 'Yes', value = true, pen = COLOR_GREEN},
                               {label = 'No', value = false}},
                    initial_option = false,
                    on_change = function() self:refresh() end,
                },
                -- MARKED TO MELT: only items already designated for melting, and every row of
                -- them selected the moment it is switched on -- "take the melt pile to the
                -- smelter" is one click, not a row-by-row hunt. It is a filter like the others
                -- afterwards: deselect what you would rather leave, and off widens the list
                -- again without touching what is picked.
                widgets.ToggleHotkeyLabel{
                    view_id = 'to_melt',
                    frame = {t = 2, l = 26, w = 24},
                    label = 'Marked to melt:',
                    key = 'CUSTOM_SHIFT_L',
                    options = {{label = 'Yes', value = true, pen = COLOR_GREEN},
                               {label = 'No', value = false}},
                    initial_option = false,
                    on_change = function(on)
                        self:refresh()
                        if on then
                            for _, g in ipairs(self.groups) do
                                if g.total > 0 then g.sel, g.specific = g.total, nil end
                            end
                            self:refresh()
                        end
                    end,
                },
                widgets.CycleHotkeyLabel{
                    view_id = 'burrow',
                    frame = {t = 2, l = 52, r = 0},
                    label = 'Burrow:',
                    key = 'CUSTOM_SHIFT_B',
                    options = burrow_options(),
                    initial_option = -1,
                    on_change = function() self:refresh() end,
                },
                -- NOBLE SYMBOLS: only the symbols of office given to one noble, and every row
                -- of them selected as the noble is chosen -- a noble moving house takes their
                -- regalia in one click. Opens a modal to say which noble; the modal's first row
                -- clears it. The symbols are named objects, so they wear the artifact flag; this
                -- is the one case the picker lets an artifact-flagged item through.
                widgets.HotkeyLabel{
                    view_id = 'noble',
                    frame = {t = 3, l = 0, r = 0},
                    label = 'Noble symbols: none',
                    key = 'CUSTOM_SHIFT_N',
                    on_activate = function()
                        NobleScreen{on_pick = function(noble) self:set_noble(noble) end}:show()
                    end,
                },
                -- the trade screen's own filter sliders, and they are laid out for a 38-wide
                -- column: given the whole width they draw on top of each other
                widgets.Panel{
                    frame = {t = 4, l = 0, r = 0, h = 18},
                    frame_style = gui.FRAME_INTERIOR,
                    subviews = {widgets.Panel{frame = {t = 0, l = 0, w = 38}, subviews = sliders}},
                },
                widgets.List{
                    view_id = 'list',
                    frame = {t = 23, l = 0, r = 0, b = 3},
                    choices = {},
                },
                widgets.Label{
                    frame = {b = 3, l = 0},
                    text = {{text = 'Click a row for all of that kind; shift-click a run of rows.',
                             pen = COLOR_GRAY}},
                },
                widgets.Label{
                    view_id = 'summary',
                    frame = {b = 2, l = 0},
                    text = '',
                },
                widgets.HotkeyLabel{
                    frame = {b = 0, l = 0}, key = 'CUSTOM_SHIFT_M',
                    label = 'Move the selected items',
                    on_activate = function() self:apply() end,
                },
                widgets.HotkeyLabel{
                    frame = {b = 0, l = 34}, key = 'LEAVESCREEN',
                    label = 'Cancel', on_activate = function() self:dismiss() end,
                },
            },
        },
    }
    self:refresh()
    ACTIVE = self       -- module-level handle, so the running game can be asked what it shows
end

function PickerScreen:onDismiss()
    if ACTIVE == self then ACTIVE = nil end
    -- the errand is over, however it ended (moved, cancelled, Esc): give the mining menu back
    -- exactly as it was. Defined further down; a global, so it resolves when this actually runs.
    reopen_mining_menu()
end

-- Chosen from the noble modal: nil/false clears. Choosing a noble also selects every row that
-- survives, the way "Marked to melt" does -- the point of asking is to carry the lot.
function PickerScreen:set_noble(noble)
    self.noble = noble or nil
    local btn = self.subviews.noble
    if self.noble then
        btn:setLabel(('Noble symbols: %s (%s)'):format(self.noble.name,
                                                       table.concat(self.noble.positions, ', ')))
    else
        btn:setLabel('Noble symbols: none')
    end
    self:refresh()
    if self.noble then
        for _, g in ipairs(self.groups) do
            if g.total > 0 then g.sel, g.specific = g.total, nil end
        end
        self:refresh()
    end
end

-- the sliders call this by name (they are the trade screen's own widgets)
function PickerScreen:refresh_list()
    self:refresh()
end

-- the slider settings, read the way DFHack's own move-goods screen reads them
function PickerScreen:filters()
    local f = {min_quality = 0, max_quality = 6, min_value = 0, max_value = math.huge,
               min_condition = 3, max_condition = 0,
               hide_forbidden = self.subviews.hide_forbidden:getOptionValue(),
               melt = self.subviews.melt_targets:getOptionValue(),
               to_melt = self.subviews.to_melt:getOptionValue(),
               noble = self.noble and self.noble.assignments or nil,
               only_z = self.subviews.this_z:getOptionValue() and self.target.z or nil,
               burrow = self.subviews.burrow:getOptionValue()}
    if f.burrow == -1 then f.burrow = nil end
    local sv = self.subviews
    local function num(v) return (type(v) == 'table') and v.value or v end
    if sv.min_quality then f.min_quality = sv.min_quality:getOptionValue() end
    if sv.max_quality then f.max_quality = sv.max_quality:getOptionValue() end
    if sv.min_value then f.min_value = num(sv.min_value:getOptionValue()) end
    if sv.max_value then f.max_value = num(sv.max_value:getOptionValue()) end
    if sv.min_condition then f.min_condition = sv.min_condition:getOptionValue() end
    if sv.max_condition then f.max_condition = sv.max_condition:getOptionValue() end
    return f
end

-- THE FILTERS ARE PER ITEM, NOT PER ROW. A row is a kind -- "gabbro earring" -- and two
-- earrings of that kind can sit either side of a quality slider; the row stays, with the
-- earrings that pass and no others. What the row shows, counts, offers in [specific] and
-- sends when clicked is exactly `eligible`, the items behind it that pass the sliders now.
-- Corpses are exempt from quality and value (they have neither) but not from forbidden or
-- wear, the same as DFHack's screen treats them.
local function item_passes(e, g, f)
    if f.hide_forbidden and e.forbidden then return false end
    if f.melt and not e.metal then return false end
    if f.to_melt and not e.to_melt then return false end
    if f.noble and not (e.symbol and f.noble[e.symbol]) then return false end
    if f.only_z and e.z ~= f.only_z then return false end
    if f.burrow and not (e.burrow_ids and e.burrow_ids[f.burrow]) then return false end
    if f.min_condition < e.wear or f.max_condition > e.wear then return false end
    if not g.corpse then
        if e.quality < f.min_quality or e.quality > f.max_quality then return false end
        if e.value < f.min_value or e.value > f.max_value then return false end
    end
    return true
end

-- Recompute every row's eligible items and pull its selection down to what still passes:
-- a count of "the closest N" becomes the closest N of those, and a hand-picked set drops
-- the items the sliders have hidden, since sending something you can no longer see would be
-- a surprise on the day the haulers arrive.
function PickerScreen:apply_filters()
    local f = self:filters()
    for _, g in ipairs(self.groups) do
        local eligible = {}
        for _, e in ipairs(g.items) do
            if item_passes(e, g, f) then eligible[#eligible + 1] = e end
        end
        g.eligible = eligible
        g.total = #eligible
        g.value = 0
        for _, e in ipairs(eligible) do g.value = math.max(g.value, e.value) end
        if g.specific then
            local kept, n = {}, 0
            for _, e in ipairs(eligible) do
                if g.specific[e.id] then kept[e.id] = true; n = n + 1 end
            end
            g.specific = (n > 0) and kept or nil
            g.sel = n
        else
            g.sel = math.min(g.sel, g.total)
        end
    end
end

function PickerScreen:visible_groups()
    local search = (self.subviews.search.text or ''):lower()
    local out = {}
    for _, g in ipairs(self.groups) do
        local ok = g.total > 0
        if ok and #search > 0 and not g.label:lower():find(search, 1, true) then ok = false end
        if ok then out[#out + 1] = g end
    end
    local sort = self.subviews.sort:getOptionValue()
    table.sort(out, function(a, b)
        if sort == 'name' then return a.label < b.label end
        if sort == 'qty' then
            if a.total ~= b.total then return a.total > b.total end
        elseif sort == 'value' then
            if a.value ~= b.value then return a.value > b.value end
        else
            local ad, bd = a.eligible[1].dist, b.eligible[1].dist
            if ad ~= bd then return ad < bd end
        end
        return a.label < b.label
    end)
    return out
end

function PickerScreen:refresh()
    self:apply_filters()
    self.shown = self:visible_groups()
    local choices = {}
    for _, g in ipairs(self.shown) do
        choices[#choices + 1] = {text = self:row_text(g), group = g}
    end
    local list = self.subviews.list
    set_choices_keeping_view(list, choices, list:getSelected())
    local chosen, kinds = 0, 0
    for _, g in ipairs(self.groups) do
        if g.sel > 0 then chosen = chosen + g.sel; kinds = kinds + 1 end
    end
    self.subviews.summary:setText(
        ('%d item(s) of %d kind(s) selected -- destination %d, %d, %d')
        :format(chosen, kinds, self.target.x, self.target.y, self.target.z))
end

-- One row, laid out in fixed columns so a click can be read back to the thing it landed on.
-- It opens with the distance to the closest item that passes the filters, the number the
-- "closest N" promise is made in.
function PickerScreen:row_text(g)
    local nearest = g.eligible[1] and g.eligible[1].dist or 0
    return ('%5d %-12s %-44s %s %4d/%-5d %s %s %s'):format(nearest,
        '[specific]', g.label:sub(1, 44), '[-1]', g.sel, g.total, '[+1]', '[+10]', '[all]')
end

-- The column bands of a row, ZERO-BASED, counted straight off the format string above:
-- dist 0-4, [specific] 6-17, label 19-62, [-1] 64-67, count 68-78, [+1] 80-83, [+10] 85-89,
-- [all] 91-95. The COUNT band deliberately runs from just after [-1] to the end of the total,
-- so clicking the number -- or the space either side of the slash -- is what asks for an
-- exact amount.
local BANDS = {
    {name = 'specific', x1 = 6,  x2 = 17},
    {name = 'minus',    x1 = 64, x2 = 67},
    {name = 'count',    x1 = 68, x2 = 78},
    {name = 'plus',     x1 = 80, x2 = 83},
    {name = 'plus10',   x1 = 85, x2 = 89},
    {name = 'all',      x1 = 91, x2 = 95},
}

local function band_at(x)
    for _, b in ipairs(BANDS) do
        if x >= b.x1 and x <= b.x2 then return b.name end
    end
end

-- CLICKING THE ROW ITSELF TAKES THE WHOLE KIND. The bands along the right edge are for
-- exact amounts; the row is the common case -- "all of those" -- so a click anywhere else on
-- it marks every item of that kind, and clicking a marked row clears it again. SHIFT-CLICK
-- carries that across a run of rows from the last one clicked, the same range gesture the
-- individual-item window uses.
function PickerScreen:mark_row(idx, shift)
    local g = self.shown[idx]
    if not g then return end
    if shift and self.last_row and self.shown[self.last_row] then
        local a, b = math.min(self.last_row, idx), math.max(self.last_row, idx)
        for i = a, b do
            local row = self.shown[i]
            if row then row.sel, row.specific = row.total, nil end
        end
        self.last_row = idx
        self:refresh()
        return
    end
    self.last_row = idx
    self:set_sel(g, g.sel >= g.total and 0 or g.total)
end

function PickerScreen:set_sel(g, n)
    g.sel = math.max(0, math.min(n, g.total))
    g.specific = nil           -- a number means "the closest N", not the set you had picked
    self:refresh()
end

function PickerScreen:onInput(keys)
    if keys._MOUSE_L then
        local list = self.subviews.list
        local idx = list:getIdxUnderMouse()
        if idx and self.shown[idx] then
            list:setSelected(idx)      -- we swallow the click, so do the List's own bookkeeping
            local g = self.shown[idx]
            local x = self:getMouseXInList()
            local band = x and band_at(x)
            if band == 'specific' then
                SpecificScreen{group = g, on_close = function() self:refresh() end}:show()
                return true
            elseif band == 'minus' then self:set_sel(g, g.sel - 1); return true
            elseif band == 'plus' then self:set_sel(g, g.sel + 1); return true
            elseif band == 'plus10' then self:set_sel(g, g.sel + 10); return true
            elseif band == 'all' then self:set_sel(g, g.total); return true
            elseif band == 'count' then self:ask_count(g); return true
            else
                -- anywhere else on the row (the label, the gaps): the whole kind
                self:mark_row(idx, dfhack.internal.getModifiers().shift)
                return true
            end
        end
    end
    return PickerScreen.super.onInput(self, keys)
end

-- the mouse's x inside the list's own body, so the bands above line up with what was drawn
function PickerScreen:getMouseXInList()
    local list = self.subviews.list
    local rect = list.frame_body
    if not rect then return nil end
    local x = dfhack.screen.getMousePos()
    if not x then return nil end
    return x - rect.x1
end

function PickerScreen:ask_count(g)
    local dlg = require('gui.dialogs')
    dlg.showInputPrompt(g.label, 'How many? (the closest ones are taken)', COLOR_WHITE,
        tostring(g.sel),
        function(text)
            local n = tonumber(text)
            if n then self:set_sel(g, math.floor(n)) end
        end)
end

function PickerScreen:apply()
    local ids = {}
    for _, g in ipairs(self.groups) do
        local items = g.eligible or g.items
        if g.specific then
            for _, e in ipairs(items) do
                if g.specific[e.id] then ids[#ids + 1] = e.id end
            end
        else
            for i = 1, math.min(g.sel, #items) do ids[#ids + 1] = items[i].id end
        end
    end
    -- Nothing selected: the window closes and that is the whole answer. A dwarf-sized
    -- announcement for "you picked nothing" is noise about a non-event.
    if #ids == 0 then
        self:dismiss()
        return
    end
    local res, err = begin_move(self.target, ids)
    self:dismiss()
    if not res then
        say('move-items: ' .. tostring(err), COLOR_RED)
        return
    end
    local msg = ('move-items: %d item(s) marked, %d other dump zone(s) removed.')
        :format(res.marked, res.removed_zones)
    if res.replaced then msg = msg .. ' The delivery already running was cancelled.' end
    if res.stale_dumps > 0 then
        msg = msg .. (' %d item(s) already marked for dumping were unmarked.'):format(res.stale_dumps)
    end
    if #res.orders > 0 then
        msg = msg .. ' Standing orders turned on: ' .. table.concat(res.orders, ', ') .. '.'
    end
    -- what was marked is the delivery describing itself, not a refusal: console only
    log(msg)
end

-- ---- picking the spot -------------------------------------------------------------
--
-- An OVERLAY, not a dialog, and it polls the mouse buttons rather than waiting for input to be
-- handed to it. Both parts are the lesson `dig-replace-walls` already learned on this screen:
--
--   * The Dig tool is still armed. This is normally opened from the `dig-building` picker,
--     which runs while NORMAL MINING MODE is selected, so a click meant for us also paints a
--     dig designation on the tile. So the designation tool is disarmed while we are up and put
--     back exactly as it was afterwards -- and with no tool selected there is nothing for DF or
--     for the repo's other map tools to act on either.
--   * A map click does not reliably arrive as `onInput` on a lua screen. The map belongs to DF;
--     what works is reading `enabler.mouse_lbut_down` on the overlay pump and resolving the
--     tile with `dfhack.gui.getMousePos()`, which is how every map tool here takes its clicks.
--
-- The click is taken on RELEASE, and the button state at the moment we open is remembered, so
-- the click that opened this panel is not read as the click that picks the spot.

targeting = targeting or false
local saved_tool = nil
-- THE CLICK THAT OPENED US IS STILL HELD. This is normally started by clicking "Move items" in
-- the dig-building picker, and that button is released a moment later -- straight into an
-- overlay watching for exactly that release, which read the map tile under the picker panel as
-- the destination, announced "that tile is not somewhere a dwarf can stand" and gave up. From
-- the outside: a menu entry that does nothing.
--
-- Adopting the button state once is not enough, because the release still arrives afterwards.
-- So we ARM instead: the opening click's release is what arms us, and only a press-and-release
-- made after that counts as picking a spot.
local armed = false

-- THE MINING MENU STAYS SHUT FOR THE WHOLE ERRAND, not just while the spot is being picked.
-- `main_designation_selected` is what holds the designation panel open (with a tool chosen the
-- focus reads dwarfmode/Designate/DIG_DIG; set it to NONE and the panel is gone), so putting it
-- back is what REOPENS the mining interface -- and the old code put it back the instant the
-- spot was chosen, a beat before the picker appeared. Mining was therefore live underneath the
-- picker for the whole time it was up, and every click that missed the panel painted a dig
-- designation on the map behind it. So the two halves are separate now: `stop_targeting` only
-- ends the spot-picking overlay, and the tool goes back when the ERRAND ends -- the picker
-- dismissed, cancelled, or never opened at all.
local function close_mining_menu()
    local mi = df.global.game.main_interface
    if saved_tool == nil then saved_tool = mi.main_designation_selected end
    mi.main_designation_selected = df.main_designation_type.NONE
end

-- Reopen it exactly as it was. Safe to call twice, and safe when we never closed anything.
function reopen_mining_menu()
    if saved_tool == nil then return end
    df.global.game.main_interface.main_designation_selected = saved_tool
    saved_tool = nil
end

local function start_targeting()
    close_mining_menu()
    armed = false
    targeting = true
end

-- ends the spot-picking overlay ONLY -- the designation tool deliberately stays put away
local function stop_targeting()
    targeting = false
end

-- Give up on the whole errand: stop asking for a spot AND hand the mining menu back. This is
-- the one call every way out of spot-picking goes through.
--
-- WHY THIS EXISTS: `targeting` gates `active()`, and `active()` is what tells the
-- dig-building picker to get out of the way -- so a `targeting` left stuck on does not just
-- leave a panel up, it makes the DIG-BUILDING PICKER VANISH COMPLETELY, with no way back
-- short of reloading the save. It happened. Previously the only way out was a right-click
-- read off `enabler`: press Esc instead, or click somewhere the release did not register,
-- and the flag stayed on forever.
function abort_targeting()
    if not targeting then return false end
    stop_targeting()
    reopen_mining_menu()
    return true
end

TargetOverlay = defclass(TargetOverlay, overlay.OverlayWidget)
TargetOverlay.ATTRS{
    desc = 'move-items: click the spot to move things to.',
    -- LEFT of the map, not the right-hand strip: a panel over there is laid out correctly
    -- and then painted over by DF every frame -- it has a frame_rect and draws nothing
    default_pos = {x = 2, y = 6},
    default_enabled = true,
    -- plain `dwarfmode`, not /Default: with a designation tool selected the focus is
    -- dwarfmode/Designate/DIG_DIG, and this is opened from the Dig tool
    viewscreens = 'dwarfmode',
    frame = {w = 34, h = 5},
    frame_style = gui.FRAME_MEDIUM,
    frame_title = 'Move items',
    frame_background = dfhack.pen.parse{ch = ' ', fg = COLOR_BLACK, bg = COLOR_BLACK},
    overlay_onupdate_max_freq_seconds = 0,
    -- the supported way to hide an overlay: a `visible` predicate. Overriding `render` to
    -- return early instead leaves the framework's frame state unset under a widget the C++
    -- overlay plugin is about to draw, and DF segfaulted in `render_things` doing it.
    visible = function() return targeting end,
    version = 1,
}

-- Esc is the key every other way out of a DF panel uses, and somebody backing out of this
-- one will reach for it before they think to right-click.
function TargetOverlay:onInput(keys)
    if targeting and keys.LEAVESCREEN then
        abort_targeting()
        return true
    end
    return TargetOverlay.super.onInput(self, keys)
end

function TargetOverlay:init()
    self.lbut, self.rbut = 0, 0
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = {
            'Click the spot to move', NEWLINE, 'things to.', NEWLINE,
            {text = 'Right-click or Esc cancels.', pen = COLOR_GRAY},
        }},
    }
end

-- The button states are INTS, not booleans, and that matters in Lua: `not 0` is false, so a
-- released button read as a boolean is indistinguishable from a held one. Compare against 1,
-- the way every other map tool here does.
function TargetOverlay:overlay_onupdate()
    if not targeting then return end
    -- A spot can only be picked on a fort map. If we are anywhere else the flag is stale, and
    -- a stale flag costs the player the dig-building picker -- so drop it rather than wait for
    -- a right-click that is never coming.
    if not dfhack.world.isFortressMode() or not dfhack.isMapLoaded() then
        stop_targeting()
        return
    end
    local e = df.global.enabler
    local l, r = e.mouse_lbut_down, e.mouse_rbut_down
    if not armed then                          -- waiting for the opening click to be let go
        if l ~= 1 and r ~= 1 then armed = true end
        self.lbut, self.rbut = l, r
        return
    end
    local l_rel, r_rel = (l ~= 1 and self.lbut == 1), (r ~= 1 and self.rbut == 1)
    self.lbut, self.rbut = l, r
    if r_rel then
        abort_targeting()             -- cancelled outright: the errand is over
        return
    end
    if not l_rel then return end
    local pos = dfhack.gui.getMousePos()
    if not pos then return end                 -- released off the map: not a choice
    -- A tile nobody can stand on is a MISS, not an answer: stay up and let them click again,
    -- rather than closing with a one-line complaint.
    if not walk_group(pos) then
        say('move-items: nothing could stand there -- pick a floor tile.', COLOR_YELLOW)
        return
    end
    stop_targeting()
    open_picker(pos)
end

-- ---- entry points --------------------------------------------------------------

function open_picker(target)
    local groups, err = scan_items(target)
    if not groups then
        say('move-items: ' .. tostring(err), COLOR_YELLOW)
        reopen_mining_menu()          -- no picker is coming; give the menu back
        return
    end
    if #groups == 0 then
        say('move-items: nothing that can reach that spot is anywhere else.', COLOR_YELLOW)
        reopen_mining_menu()
        return
    end
    PickerScreen{target = target, groups = groups}:show()
end

-- true while any part of this tool has the screen, so the dig-building picker gets out of the
-- way: the spot-picking overlay draws no focus of its own, so asking the focus string alone
-- would leave the picker sitting on top of it
function active()
    if targeting then return true end
    local f = dfhack.gui.getCurFocus(true)
    for _, s in ipairs(f or {}) do
        if s:find('move%-items') then return true end
    end
    return false
end

function show()
    local st = status()
    if st then
        -- not a refusal: picking a new destination is how you change your mind. The running
        -- delivery is cancelled when the new one is applied, not now -- back out of the picker
        -- and the one in flight carries on.
        log(('move-items: %d of %d item(s) are still on their way; starting a new '
            .. 'delivery will call that off.'):format(st.pending, st.total))
    end
    start_targeting()
end

OVERLAY_WIDGETS = {watch = WatchOverlay, target = TargetOverlay}

register_notification()
dfhack.onStateChange[NOTIFY_NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register_notification() end
    -- never strand the designation tool put away across a reload: the fort would come back
    -- with the mining menu mysteriously refusing to stay open
    if ev == SC_MAP_UNLOADED then targeting = false; saved_tool = nil end
end

if dfhack_flags.module then
    return
end

local args = {...}
local cmd = args[1]
if cmd == 'status' then
    local st = status()
    if not st then
        print('move-items: nothing being moved.')
    else
        print(('move-items: %d of %d item(s) still on the way to %d, %d, %d (zone %d).')
            :format(st.pending, st.total, st.target.x, st.target.y, st.target.z, st.zone_id))
    end
elseif cmd == 'cancel' then
    -- clears BOTH a delivery in flight and a stuck spot-picking flag, so there is always a
    -- console way back if the picker ever disappears again
    local stopped = abort_targeting()
    local cancelled = cancel()
    if cancelled then print('move-items: cancelled.')
    elseif stopped then print('move-items: stopped asking for a spot.')
    else print('move-items: nothing to cancel.') end
elseif cmd == 'finish' then
    print(finish() and 'move-items: finished.' or 'move-items: nothing in progress.')
else
    show()
end
