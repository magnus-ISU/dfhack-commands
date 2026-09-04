-- Pick the items a strange mood will use, and make sure the dwarf gets exactly those.
--@module = true
--[[
fort/help-mood

Run by hand while a dwarf is in a strange mood -- this is not a background overlay.

    fort/help-mood        open the planner
    fort/help-mood stop   let the chosen items go again and empty the burrow

WHAT IT TELLS YOU

If the fort cannot satisfy the mood, the panel says one thing and no more: **"The gods are
testing you"**. Not which requirement is short, not what the others are -- knowing what a mood
wants IS the blessing, and a fort that cannot answer it does not get to read the list and go
shopping. Otherwise it opens with **"The gods have blessed <dwarf> "** and, where
the dwarf's own preferences and moodable skill settle the question, what is coming:
*"<dwarf> announces they will create a hammer!"* A weaponsmith who likes war hammers makes a
war hammer; a dwarf whose preferences say nothing the skill can make gets no prediction rather
than a guess.

WHAT IT SHOWS

One row per thing the mood wants, read from the mood job's own filters (the same list
`showmood` prints). Note that DF states the first requirement in raw units -- 150 for a bar --
where only ONE item is ever needed, so that row is counted as one.

Each row proposes the HIGHEST-VALUE item in the fort that satisfies it, because a mood is the
one job where spending the good material is the point. Worn goods are never offered, nor
part-used ones -- a bolt of cloth the hospital has been taking bandages from measures 14985
instead of 15000 and is indistinguishable in a list, so anything short of the fullest of its
own kind in the fort is left out. Click a row to pick something else from
every item that fits, then **[build selected artifact]** to hold the fort to that choice.
**[close]** just closes the panel and leaves a build running; **[cancel helping]** is the one
that lets go -- it unforbids everything and empties the burrow, and works on forbids left
behind by an earlier session too. A build left alone ends by itself when the dwarf has
everything. (`fort/help-mood stop` is the same thing from the command line.)

A requirement the dwarf has ALREADY hauled in is shown as claimed and cannot be changed --
that decision is behind you, and DF will not let go of it.

When the fort CANNOT meet the mood this says so and no more. It does not name the missing
requirement, deliberately: by the time a mood has struck the demand is already rolled, so an
answer here arrives on the one day it cannot be used. `fort/moody-items-warning` is what
answers that question, all the time, while there is still a season to act on it.

WHAT IT DOES

Reserving the items is the point. While the dwarf is fetching a chosen one, every OTHER item
in the fort that could satisfy that requirement is forbidden, so DF has one legal choice and
takes it -- left alone it takes the NEAREST one, which is how a mood ends up spending gneiss
while the adamantine sits in the next room. THE REST OF THE PLAN IS FORBIDDEN TOO, and opened
one slot at a time as the mood becomes ready for it: a chosen item left loose while the dwarf
walks off for something else is a chosen item any other job can take, and moods are slow. (With
a valve: if nothing is hauled for a while, another slot opens, so a mood that wants its
requirements out of order is slowed down rather than stopped.) The dwarf is also
confined to a burrow holding the item's tile AND the whole of the workshop they have claimed
-- the item alone would be a dwarf with nowhere to carry it back to -- which stops them
wandering off to a nearer candidate that appears mid-walk. The moment they actually pick it
up, the forbids come off and the burrow moves on to the next requirement.

DELAYING. A mood does not wait for you. It claims a workshop, gathers what it can reach, and
starts building with that -- so when the panel says the gods are testing you, the useful move
is usually not a better forbid but more time. `delay work` (Ctrl-D) gives the dwarf a burrow
of nothing but their own workshop: they can stand in it and do nothing else, no item is inside
it, and the mood holds exactly where it is until you lift the delay -- by which time the
smelter has run and the bar you needed exists. It uses the same burrow rather than a second
one, because a dwarf assigned to two burrows may walk anywhere either covers, which would
delay nothing at all.

Everything it touches is put back: forbids are restored to what they were, and the temporary
burrow (named `help-mood`) is emptied rather than deleted, so the same one is reused next time
instead of littering the burrow list. A delay comes off with it -- a dwarf left in a
one-workshop burrow after the artifact is done would never leave it again.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local BURROW_NAME = 'help-mood'

-- ---------------------------------------------------------------------------
-- finding the mood
-- ---------------------------------------------------------------------------

-- The mood job exists from the moment the mood strikes -- before a workshop is claimed --
-- and is the one job in the list flagged `special` whose type is a StrangeMood* one. The
-- dwarf comes off the job's own worker reference, NOT from scanning units for a mood flag:
-- `unit.mood` is back to None the instant the artifact is finished, while the job is what
-- this tool actually works from.
function find_mood()
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.flags.special and (df.job_type[job.job_type] or ''):find('^StrangeMood') then
            local unit
            for _, ref in ipairs(job.general_refs) do
                if df.general_ref_unit_workerst:is_instance(ref) then
                    unit = df.unit.find(ref.unit_id)
                end
            end
            return unit, job
        end
        link = link.next
    end
end

-- ---------------------------------------------------------------------------
-- what the mood wants
-- ---------------------------------------------------------------------------

-- An item nobody else has a claim on. Checked once per item rather than once per
-- requirement: a fort of twenty-odd thousand items and eight requirements is eight sweeps
-- otherwise, and this runs on DF's own thread.
-- FORBIDDEN IS NOT EXCLUDED. A forbid is a decision, not a fact about the item, and a mood
-- is exactly the moment to reconsider one -- the good stone is often forbidden precisely so
-- the everyday jobs leave it alone. Forbidden candidates are listed, marked, and freed if
-- you pick one. (It also keeps this tool from hiding its OWN forbids from itself on a
-- second look.) The rest of these flags are facts: an item in a job, in a wall, or somebody
-- else's is not available whatever anyone decides.
-- ONE test, used for both questions this tool asks: "may I offer you this item" and "must I
-- forbid this item". They were separate, and every exclusion added to the first punched a
-- hole in the second -- worn goods, part-used bolts, foreign logs stopped being offered and
-- so stopped being forbidden, which left them as the only legal items in a locked-down fort
-- and handed the mood exactly the junk it should never have had. Whatever DF could reach for,
-- this offers AND forbids.
--
-- What remains here is only what makes an item unreachable to any job at all: destroyed,
-- built into something, encased in ice, an artifact, somebody else's. Wear and part-use are
-- NOT in that list -- DF will happily spend a frayed bolt on an artifact, so they have to be
-- forbidden, and being able to see one is the point of showing them.
local function usable(item)
    local f = item.flags
    return not (f.dump or f.hostile or f.artifact or f.owned or f.garbage_collect
        or f.removed or f.in_building or f.encased or f.trader or f.foreign)
end

local function is_forbidden(item)
    local v = false
    pcall(function() v = item.flags.forbid end)
    return v
end

-- A mood requirement is not always an item type. Half of them are a CATEGORY carried in the
-- filter's flag bits: `bone` + `body_part` with no item type at all is "any bones", `cloth`
-- with `silk` is silk cloth specifically. Reading only item_type/material called all three of
-- those "any item" and matched the entire fort against them -- which is how a sock came to be
-- offered for a bone.
--
-- `dfhack.job.isSuitableItem` / `isSuitableMaterial` look like the answer and are NOT: they do
-- not understand these bits. Asked whether a cave spider silk cloth satisfies a cloth+silk
-- requirement -- material flag SILK set, item type matching exactly -- both return false, and
-- a fort with 68 bolts of silk reads as having none. So the categories are tested here, from
-- the item's own material flags, and a bit this does not know about is left as no constraint
-- rather than used to hide things.
-- Each category lists every material flag that satisfies it, because one word can be more
-- than one material flag. "Plant" is the example that cost a run: a plant is
-- STRUCTURAL_PLANT_MAT as a log or a stem, but rope reed CLOTH is THREAD_PLANT, so a fort
-- with 105 bolts of plant fibre read as having none.
local CATEGORY_FLAG = {
    silk = {'SILK'},
    yarn = {'YARN'},
    hair_wool = {'YARN'},
    leather = {'LEATHER'},
    bone = {'BONE'},
    shell = {'SHELL'},
    horn = {'HORN'},
    ivory_tooth = {'TOOTH'},
    pearl = {'PEARL'},
    plant = {'THREAD_PLANT', 'STRUCTURAL_PLANT_MAT'},
}

-- `body_part` is not a material, it is a KIND of item, and the difference is the whole of
-- "any bone" versus "anything made out of bone". A fort's bone-material items are mostly
-- rings, earrings, crowns and whole corpses; the bones a mood wants are butchery output,
-- which DF stores as CORPSEPIECE. Testing the material alone offered a bone crown for a
-- bone.
local ITEM_CATEGORY = {
    body_part = df.item_type.CORPSEPIECE,
}

-- A CORPSEPIECE answers the category question itself, and its answer is the one that counts.
-- `corpse_flags` uses the same vocabulary as the requirement's own bits -- bone, skull, horn,
-- tooth, shell, leather, hair_wool -- so the two are compared name for name. The material
-- route is wrong here and wrong in a way that reads plausible: a giant rat's toe and a cavy
-- boar's skull are both made of bone material and neither is a bone. A butchered bone says
-- `corpse_flags.bone`; a skull says `skull`; a severed toe says neither.
local CORPSE_FLAG = {
    bone = 'bone', shell = 'shell', horn = 'horn', ivory_tooth = 'tooth', pearl = 'pearl',
    leather = 'leather', silk = 'silk', yarn = 'yarn', hair_wool = 'hair_wool',
    plant = 'plant',
}

local function material_of(item)
    local mi
    pcall(function() mi = dfhack.matinfo.decode(item) end)
    return mi and mi.material or nil
end

local function filter_matches(ji, item)
    if ji.item_type >= 0 and item:getType() ~= ji.item_type then return false end
    if ji.item_subtype >= 0 and item:getSubtype() ~= ji.item_subtype then return false end
    if ji.mat_type >= 0 and item:getMaterial() ~= ji.mat_type then return false end
    if ji.mat_index >= 0 and item:getMaterialIndex() ~= ji.mat_index then return false end

    for bit, itype in pairs(ITEM_CATEGORY) do
        local wanted = false
        pcall(function() wanted = ji.flags2[bit] end)
        if wanted and item:getType() ~= itype then return false end
    end

    local corpse = item:getType() == df.item_type.CORPSEPIECE
    -- An UNBUTCHERED body part is not material. A severed foot, an upper arm, a reindeer
    -- bull's head all carry `corpse_flags.bone` -- they contain bone, and testing that flag
    -- alone offers them for "any bone" -- but the thing a mood wants is butchery output, a
    -- stack named "horse bone [14]", and the one bit that separates the two is this.
    if corpse then
        local raw = false
        pcall(function() raw = item.corpse_flags.unbutchered end)
        if raw then return false end
    end

    local mat
    for bit, matflags in pairs(CATEGORY_FLAG) do
        local wanted = false
        pcall(function() wanted = ji.flags2[bit] end)
        if wanted then
            local has = false
            if corpse then
                local name = CORPSE_FLAG[bit]
                if name then
                    pcall(function() has = item.corpse_flags[name] end)
                else
                    has = true          -- a category corpse pieces do not record: not ours to judge
                end
            else
                mat = mat or material_of(item)
                if mat then
                    for _, flag in ipairs(matflags) do
                        local on = false
                        pcall(function() on = mat.flags[flag] end)
                        if on then has = true; break end
                    end
                end
            end
            if not has then return false end
        end
    end

    -- a bar or a bolt of cloth has to be big enough on its own; DF states the requirement
    -- in raw units (150 to a bar) and a part-used one will not do
    if ji.min_dimension > 0 then
        local dim = 0
        pcall(function() dim = item.dimension end)
        if dim > 0 and dim < ji.min_dimension then return false end
    end
    return true
end

local function item_matches(ji, item)
    return usable(item) and filter_matches(ji, item)
end

local function item_value(item)
    local v = 0
    pcall(function() v = dfhack.items.getValue(item) end)
    return v
end

-- Every requirement's candidates, best first, in ONE pass over the item list -- as
-- SNAPSHOTS, not as item pointers.
--
-- That distinction cost a crash. A candidate list is held while the player reads it, and an
-- item can be gone by the time they click: melted, merged into a stack, taken into a job.
-- The pointer is then dangling, and handing it to a DFHack binding is a segfault, not an
-- error -- `Items::getDescription` went straight through pcall and took DF with it. So each
-- candidate is reduced, while it is certainly alive, to what the panel actually needs: its
-- id, its value, its name. Nothing here touches an item again except through
-- `df.item.find(id)`, which returns nil for one that has gone.
--
-- Two things fall out of that besides safety. The value and the description are read once
-- each instead of once per redraw, and the sort is over plain numbers.
-- What a candidate is reduced to. Deliberately NO description: `getReadableDescription` is
-- the call that crashed, it is not cheap, and running it over twenty thousand items to build
-- a grouping key would be both slow and the widest possible exposure to whatever item state
-- it cannot handle. The key below is made of plain numbers off the item, which groups
-- identical things just as well, and a name is fetched only for the few hundred rows that
-- actually get drawn -- through `df.item.find`, so a dead id yields nil instead of a
-- dangling pointer.
local function snapshot(item)
    local q, dq, dim, wear, injob = 0, 0, 0, 0, false
    pcall(function() q = item:getQuality() end)
    pcall(function() dq = item:getSubtype() end)
    pcall(function() dim = item.dimension end)
    pcall(function() wear = item.wear end)
    pcall(function() injob = item.flags.in_job end)
    return {
        id = item.id,
        value = item_value(item),
        forbidden = is_forbidden(item),
        worn = wear > 0,
        busy = injob,
        dim = dim,
        key = ('%d/%d/%d/%d/%d'):format(item:getType(), dq, item:getMaterial(),
            item:getMaterialIndex(), q),
    }
end

-- Part-used goods are marked, not removed. DF does not flag them -- it just counts
-- `dimension` down, so a bolt the hospital has been taking bandages from measures 14985 of
-- 15000 and looks identical in a list. Knowing which is which matters (the default never
-- lands on one) but hiding them was what stopped them being forbidden.
local function mark_part_used(list)
    local best = {}
    for _, snap in ipairs(list) do
        if snap.dim > (best[snap.key] or 0) then best[snap.key] = snap.dim end
    end
    for _, snap in ipairs(list) do
        snap.part_used = snap.dim > 0 and snap.dim < best[snap.key]
    end
    return list
end

-- The dwarf's walkable group: DF numbers connected regions of the map, and an item in a
-- different one cannot be fetched at all. Offering such an item is offering a stall -- the
-- mood waits forever for a boulder across a chasm -- so candidates are restricted to the
-- dwarf's own group. Items in containers and stockpiles report the tile they sit on, which
-- is the right answer for this.
local function walk_group(pos)
    local g
    pcall(function() g = dfhack.maps.getWalkableGroup(pos) end)
    return g
end

local function unit_group(unit)
    if not unit then return nil end
    return walk_group(xyz2pos(dfhack.units.getPosition(unit)))
end

local function reachable(item, group)
    if not group then return true end          -- unknown: do not hide things over a guess
    local g
    pcall(function() g = item.walkable_id end)
    if g == nil or g == 0 then
        g = walk_group(xyz2pos(dfhack.items.getPosition(item)))
    end
    return g == nil or g == 0 or g == group
end

local function all_candidates(job, unit)
    local group = unit_group(unit)
    local lists = {}
    local filters = job.job_items.elements
    for idx in ipairs(filters) do lists[idx] = {} end
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if usable(item) and reachable(item, group) then
            local snap
            for idx, ji in ipairs(filters) do
                if filter_matches(ji, item) then
                    snap = snap or snapshot(item)
                    local l = lists[idx]
                    l[#l + 1] = snap
                end
            end
        end
    end
    for idx, list in pairs(lists) do
        lists[idx] = mark_part_used(list)
        list = lists[idx]
        table.sort(list, function(a, b)
            if a.value ~= b.value then return a.value > b.value end
            return a.id < b.id
        end)
    end
    return lists
end

-- one requirement's candidates, unsorted -- what `steer` needs, which is "everything else"
local function candidates(ji)
    local out = {}
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if item_matches(ji, item) then out[#out + 1] = item end
    end
    return out
end

-- How many ITEMS a requirement wants, which is not always what `quantity` says.
--
-- A requirement measured in a DIMENSION -- bars, cloth, thread -- states its quantity in raw
-- units: 150 to a bar, 10000 to a bolt. One item covers it. Everything else states a count of
-- items and means it: a mason's mood asking for 3 boulders takes three, and a tool that pins
-- only one leaves DF to grab the other two from whatever is nearest. That is how a mood ends
-- up part adamantine and part slate and cobaltite.
local function needed(ji)
    if ji.min_dimension > 0 then return 1 end
    return math.max(1, ji.quantity)
end

-- what the dwarf has already hauled in for requirement `idx`
local function claimed_items(job, idx)
    local out = {}
    for _, ref in ipairs(job.items) do
        if ref.job_item_idx == idx and ref.item then out[#out + 1] = ref.item end
    end
    return out
end

-- the row is done when it has as many as it wants
local function claimed_for(job, idx)
    local got = claimed_items(job, idx)
    if #got >= needed(job.job_items.elements[idx]) then return got[1] end
end

-- One row per requirement: its filter, whether it is already met, and what is available.
-- DF states the FIRST requirement in raw units (150 for a bar) but only ever needs one
-- item, so every row here counts items rather than units.
-- One row per ITEM the mood wants, not per requirement: a mason's mood asking for three
-- boulders is three rows, each with its own choice, because "three boulders" is three
-- decisions and DF will happily spend the second and third on slate.
--
-- Rows for a requirement that is partly filled show the hauled items first, in the order
-- they came in, and those are settled -- the open slots follow.
function requirements(job, unit)
    local lists = all_candidates(job, unit)
    local rows = {}
    for fidx, ji in ipairs(job.job_items.elements) do
        local got = claimed_items(job, fidx)
        local want = needed(ji)
        for slot = 1, want do
            rows[#rows + 1] = {
                fidx = fidx,
                slot = slot,
                filter = ji,
                of = want,
                claimed = got[slot],
                options = got[slot] and {} or (lists[fidx] or {}),
            }
        end
    end
    return rows
end

-- The category words in a requirement's flag bits -- "bone", "silk", "leather" -- which are
-- most of what a mood actually asks for.
local function filter_tags(ji)
    local tags = {}
    for _, fs in ipairs{'flags1', 'flags2', 'flags3'} do
        pcall(function()
            for k, on in pairs(ji[fs]) do
                if on == true then tags[#tags + 1] = tostring(k) end
            end
        end)
    end
    -- `bone` always arrives with `body_part`; saying both adds nothing
    if #tags > 1 then
        local out = {}
        for _, t in ipairs(tags) do
            if not (t == 'body_part' and #tags > 1) then out[#out + 1] = t end
        end
        tags = out
    end
    return tags
end

-- a readable name for a requirement, since DF's filter is only numbers and bits
function requirement_name(ji)   -- module-level so it can be checked from the command line
    local parts = {}
    if ji.mat_type >= 0 then
        local ok, info = pcall(dfhack.matinfo.decode, ji.mat_type, ji.mat_index)
        if ok and info then parts[#parts + 1] = info:toString() end
    end
    for _, tag in ipairs(filter_tags(ji)) do
        parts[#parts + 1] = tag:gsub('_', ' ')
    end
    if ji.item_type < 0 or ji.item_type == df.item_type.NONE then
        -- no item type at all: the category IS the requirement ("any bones")
        if #parts == 0 then return 'any item' end
        return 'any ' .. table.concat(parts, ' ')
    end
    -- DF does not call these "rough": raw glass is RAW, and the word matters when the whole
    -- point of the line is you reading it and going to make some. A rough gem stays rough.
    if ji.item_type == df.item_type.ROUGH then
        local glass = false
        if ji.mat_type >= 0 then
            local ok, info = pcall(dfhack.matinfo.decode, ji.mat_type, ji.mat_index)
            if ok and info then pcall(function() glass = info.material.flags.IS_GLASS end) end
        end
        -- a tag the material name already says ("glass" beside "crystal glass") is noise
        local mat = parts[1] or ''
        local kept = {}
        for i, part in ipairs(parts) do
            if i == 1 or not mat:find(part, 1, true) then kept[#kept + 1] = part end
        end
        table.insert(kept, 1, glass and 'raw' or 'rough')
        return table.concat(kept, ' ')
    end
    local t = df.item_type[ji.item_type]
    parts[#parts + 1] = t and t:lower():gsub('_', ' ') or 'item'
    if ji.item_subtype >= 0 then parts[#parts + 1] = ('subtype %d'):format(ji.item_subtype) end
    return table.concat(parts, ' ')
end

local function base_name(item)
    local n = '?'
    pcall(function() n = dfhack.items.getReadableDescription(item) end)
    if n == '?' then pcall(function() n = dfhack.items.getDescription(item, 0, false) end) end
    return n
end

local function item_name(item, snap)
    local n = base_name(item)
    local tags = {}
    if is_forbidden(item) then tags[#tags + 1] = 'forbidden' end
    local wear = 0
    pcall(function() wear = item.wear end)
    if wear > 0 then tags[#tags + 1] = 'worn' end
    if snap and snap.part_used then tags[#tags + 1] = 'part-used' end
    if snap and snap.busy then tags[#tags + 1] = 'in another job' end
    if #tags > 0 then n = ('%s (%s)'):format(n, table.concat(tags, ', ')) end
    return n
end

-- a live item's display name, or a placeholder if it has gone since
local function live_name(id, snap)
    local item = df.item.find(id or -1)
    if not item then return '(gone)' end
    return item_name(item, snap)
end

-- ---------------------------------------------------------------------------
-- what the artifact will be
-- ---------------------------------------------------------------------------

-- The moodable skill fixes the class of thing; the dwarf's own item preference, when the
-- skill can actually make it, fixes the thing. Anything less certain than that is not
-- reported at all -- a guess about an artifact is worse than silence.
-- Keyed by job_skill. Built through a helper because indexing this table with a name the
-- build does not have (CARPENTER, which is CARPENTRY here) puts a nil key in the constructor
-- and the whole file fails to load with "table index is nil" -- a long way from the typo.
local SKILL_ITEMS = {}

local function skill_makes(skill_name, ...)
    local skill = df.job_skill[skill_name]
    if skill == nil then
        dfhack.printerr(('help-mood: no job_skill %s on this build'):format(skill_name))
        return
    end
    SKILL_ITEMS[skill] = {...}
end

skill_makes('FORGE_WEAPON', df.item_type.WEAPON, df.item_type.TRAPCOMP)
skill_makes('FORGE_ARMOR', df.item_type.ARMOR, df.item_type.HELM, df.item_type.SHOES, df.item_type.GLOVES, df.item_type.PANTS, df.item_type.SHIELD)
skill_makes('FORGE_FURNITURE', df.item_type.CHAIR, df.item_type.TABLE, df.item_type.DOOR, df.item_type.CABINET, df.item_type.BOX, df.item_type.STATUE)
skill_makes('CARPENTRY', df.item_type.CHAIR, df.item_type.TABLE, df.item_type.DOOR, df.item_type.BED, df.item_type.CABINET, df.item_type.BOX)
skill_makes('MASONRY', df.item_type.CHAIR, df.item_type.TABLE, df.item_type.DOOR, df.item_type.CABINET, df.item_type.COFFIN, df.item_type.STATUE)
skill_makes('BOWYER', df.item_type.WEAPON)
skill_makes('LEATHERWORK', df.item_type.ARMOR, df.item_type.SHOES, df.item_type.BACKPACK)
skill_makes('CLOTHESMAKING', df.item_type.ARMOR, df.item_type.SHOES, df.item_type.PANTS)
skill_makes('BONECARVE', df.item_type.CRAFTS, df.item_type.ARMOR)

local PREF_LIKE_ITEM = 4     -- unit_preference type 4 is "likes <item>"

local function subtype_name(item_type, subtype)
    local defs = {
        [df.item_type.WEAPON] = df.global.world.raws.itemdefs.weapons,
        [df.item_type.TRAPCOMP] = df.global.world.raws.itemdefs.trapcomps,
        [df.item_type.AMMO] = df.global.world.raws.itemdefs.ammo,
        [df.item_type.ARMOR] = df.global.world.raws.itemdefs.armor,
        [df.item_type.HELM] = df.global.world.raws.itemdefs.helms,
        [df.item_type.SHOES] = df.global.world.raws.itemdefs.shoes,
        [df.item_type.GLOVES] = df.global.world.raws.itemdefs.gloves,
        [df.item_type.PANTS] = df.global.world.raws.itemdefs.pants,
        [df.item_type.SHIELD] = df.global.world.raws.itemdefs.shields,
        [df.item_type.TOOL] = df.global.world.raws.itemdefs.tools,
    }
    local vec = defs[item_type]
    if not vec or subtype < 0 or subtype >= #vec then return nil end
    local d = vec[subtype]
    return d and d.name or nil
end

-- Item types are not enough: the SUBTYPE has to be something your civilisation knows how to
-- make. A dwarf here prefers blowdarts, a weaponsmith mood can plausibly make ammo, and the
-- panel duly promised a blowdart -- but the civ's entire ammo list is one entry, bolts. It has
-- never heard of a blowdart and no mood of theirs will produce one.
--
-- So a preference with a subtype is checked against the civ's own list for that item class
-- (`entity.resources.*_type`, the same vectors that decide what a caravan can bring). Classes
-- with no such list -- furniture, crafts -- carry no subtype and are left alone.
-- Built through a helper: `df.item_type.DIGGER` does not exist on this build, and a nil key
-- in a table constructor fails the whole file with "table index is nil" -- the same trap the
-- job_skill list hit earlier.
local CIV_LIST = {}

local function civ_list(type_name, field)
    local t = df.item_type[type_name]
    if t ~= nil then CIV_LIST[t] = field end
end

civ_list('WEAPON', 'weapon_type')
civ_list('ARMOR', 'armor_type')
civ_list('HELM', 'helm_type')
civ_list('GLOVES', 'gloves_type')
civ_list('SHOES', 'shoes_type')
civ_list('PANTS', 'pants_type')
civ_list('SHIELD', 'shield_type')
civ_list('AMMO', 'ammo_type')
civ_list('TRAPCOMP', 'trapcomp_type')
civ_list('TOOL', 'tool_type')
civ_list('TOY', 'toy_type')
civ_list('INSTRUMENT', 'instrument_type')
civ_list('DIGGER', 'digger_type')
civ_list('SIEGEAMMO', 'siegeammo_type')
civ_list('DIGGER', 'digger_type')   -- absent on some builds; skipped when so

local function civ_can_make(item_type, subtype)
    local list = CIV_LIST[item_type]
    if not list or subtype < 0 then return true end   -- no subtype list: nothing to check
    local ok = false
    pcall(function()
        local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
        for _, idx in ipairs(civ.resources[list]) do
            if idx == subtype then ok = true; return end
        end
    end)
    return ok
end

function prediction(unit)
    if not unit or not df.unit:is_instance(unit) then return nil end
    local skill = unit.job.mood_skill
    local allowed = SKILL_ITEMS[skill]
    if not allowed then return nil end
    local ok_set = {}
    for _, t in ipairs(allowed) do ok_set[t] = true end
    local soul = unit.status.current_soul
    if not soul then return nil end
    for _, p in ipairs(soul.preferences) do
        if p.type == PREF_LIKE_ITEM and ok_set[p.item_type]
            and civ_can_make(p.item_type, p.item_subtype) then
            local name = subtype_name(p.item_type, p.item_subtype)
            if not name then
                local t = df.item_type[p.item_type]
                name = t and t:lower():gsub('_', ' ') or nil
            end
            if name then return name end
        end
    end
    return nil          -- falling off the end returns NOTHING, not nil, and callers that
end                     -- pass the result straight to tostring() then error

-- ---------------------------------------------------------------------------
-- the helper: forbids and a one-tile burrow
-- ---------------------------------------------------------------------------

-- {unit_id, job_id, step, picks = {idx -> item_id},
--  forbidden = {item_id -> true},   -- forbids this tool SET, to lift again
--  freed     = {item_id -> true}}   -- forbids this tool LIFTED, to set again
--
-- Persisted with the fort, because the forbids are a debt: a fort can hold a thousand
-- boulders and every one of them is forbidden while the mason fetches his. If DF is closed
-- or reloaded mid-mood the in-memory list would be gone and those forbids would be
-- permanent, so the list is written down and `fort/help-mood stop` can pay it back later.
local GLOBAL_KEY = 'help-mood'

state = state or nil

local function save_state()
    local out = nil
    if state then
        local ids = {}
        for id in pairs(state.forbidden) do ids[#ids + 1] = id end
        out = {unit_id = state.unit_id, job_id = state.job_id, forbidden = ids}
    end
    dfhack.persistent.saveSiteData(GLOBAL_KEY, out or {})
end

local function find_burrow()
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
        if b.name == BURROW_NAME then return b end
    end
end

-- reused rather than recreated: an emptied burrow costs nothing and deleting one that DF's
-- own UI may be pointing at is not worth the risk
local function get_burrow()
    local b = find_burrow()
    if b then return b end
    local id = 0
    for _, x in ipairs(df.global.plotinfo.burrows.list) do
        if x.id >= id then id = x.id + 1 end
    end
    b = df.burrow:new()
    b.id = id
    b.name = BURROW_NAME
    df.global.plotinfo.burrows.list:insert('#', b)
    return b
end

local function clear_burrow()
    local b = find_burrow()
    if not b then return end
    pcall(function()
        dfhack.burrows.clearUnits(b)
        dfhack.burrows.clearTiles(b)
    end)
end

-- Every tile of the workshop the mood has claimed. Before a workshop is claimed the job
-- still carries a position, and that one tile stands in for it.
function workshop_tiles(job)
    local tiles = {}
    local bld
    for _, ref in ipairs(job.general_refs) do
        if df.general_ref_building_holderst:is_instance(ref) then
            bld = df.building.find(ref.building_id)
        end
    end
    if bld then
        for x = bld.x1, bld.x2 do
            for y = bld.y1, bld.y2 do
                tiles[#tiles + 1] = xyz2pos(x, y, bld.z)
            end
        end
    elseif job.pos and job.pos.x >= 0 then
        tiles[#tiles + 1] = xyz2pos(job.pos.x, job.pos.y, job.pos.z)
    end
    return tiles
end

-- ---------------------------------------------------------------------------
-- delaying the work
-- ---------------------------------------------------------------------------
--
-- A mood claims its workshop long before it has everything it wants, and once it has what it
-- wants it starts building -- with whatever it managed to find. If the good bar is three
-- levels down and the mood is about to settle for a copper one, the useful thing is not a
-- better forbid, it is TIME.
--
-- So: a burrow holding the workshop and nothing else, with the moody dwarf assigned to it.
-- They can stand in their shop and they can do nothing else. No item is inside the burrow, so
-- no item can be fetched, and the mood waits where it is until the burrow comes off -- by
-- which time the smelter has run and the bar exists.
--
-- It shares the one burrow with the helping side of this tool rather than adding a second:
-- a dwarf assigned to two burrows may walk anywhere either of them covers, so a delay burrow
-- next to a fetching burrow would delay nothing at all.

delaying = delaying or false

local function apply_delay(unit, job)
    local shop = workshop_tiles(job)
    if #shop == 0 then return false end
    local b = get_burrow()
    local ok = pcall(function()
        dfhack.burrows.clearTiles(b)
        for _, tile in ipairs(shop) do
            dfhack.burrows.setAssignedTile(b, tile, true)
        end
        dfhack.burrows.clearUnits(b)
        dfhack.burrows.setAssignedUnit(b, unit, true)
    end)
    return ok
end

local delay_tick

-- Returns ok, why-not. Works with or without a helping session running: delaying is a thing
-- you may want before you have decided anything at all.
function set_delay(on)
    if not on then
        delaying = false
        clear_burrow()          -- the helper puts its own back on the next tick if it is running
        return true
    end
    local unit, job = find_mood()
    if not unit or not job then return false, 'nobody is in a mood' end
    -- Before a workshop is claimed the job has no position DF will admit to, and a burrow
    -- built around that would pen the dwarf on a tile in the middle of nowhere.
    if #workshop_tiles(job) == 0 then
        return false, 'no workshop claimed yet -- wait for them to pick one'
    end
    if not apply_delay(unit, job) then return false, 'could not set the burrow' end
    delaying = true
    delay_tick()
    return true
end

-- The workshop can change under a delay (a dwarf whose claim is cancelled claims another),
-- and the mood can simply end, which must take the burrow off with it -- a dwarf left
-- assigned to a one-workshop burrow after the artifact is done never leaves it again.
delay_tick = function()
    if not delaying then return end
    local unit, job = find_mood()
    if not unit or not job then set_delay(false); return end
    if not state then apply_delay(unit, job) end   -- while helping, steer() does this
    dfhack.timeout(50, 'frames', delay_tick)
end

local function set_forbidden(item, val)
    pcall(function() item.flags.forbid = val end)
end

-- put every forbid this tool set back the way it was
local function release_forbids()
    if not state then return end
    for id in pairs(state.forbidden or {}) do
        local item = df.item.find(id)
        if item then set_forbidden(item, false) end
    end
    -- and put back the forbids this tool lifted, so a chosen-but-unused item goes back to
    -- being set aside rather than quietly rejoining the stockpiles
    for id in pairs(state.freed or {}) do
        local item = df.item.find(id)
        if item then set_forbidden(item, true) end
    end
    state.forbidden, state.freed = {}, {}
end

-- forbids left behind by a session that ended without standing down
local function release_persisted()
    local saved = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    local n = 0
    for _, id in ipairs(saved.forbidden or {}) do
        local item = df.item.find(id)
        if item and item.flags.forbid then
            set_forbidden(item, false)
            n = n + 1
        end
    end
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {})
    return n
end

function stop()
    local n = 0
    if state and state.forbidden then
        for _ in pairs(state.forbidden) do n = n + 1 end
    end
    release_forbids()
    delaying = false
    clear_burrow()
    state = nil
    if hb_gen then hb_gen = hb_gen + 1 end
    return n + release_persisted()
end

-- The requirement the dwarf is working on now: the first one nothing has been hauled for.
local function current_step(job, picks)
    for idx, ji in ipairs(job.job_items.elements) do
        local got = #claimed_items(job, idx)
        if needed(ji) > got then
            -- the slot the dwarf is about to fill: the first one nothing has arrived for
            local slots = picks[idx] or {}
            local item = df.item.find(slots[got + 1] or -1)
            return idx, ji, item
        end
    end
end

-- Items made AFTER the sweep. A mood is not instant: stone gets mined, bones get butchered,
-- cloth comes off the loom while the dwarf is still walking, and every one of those arrives
-- unforbidden and is fair game for the job. So each tick looks for items the sweep has not
-- seen and forbids the ones that could satisfy a row still open.
--
-- "Not seen" is decided by id, because DF hands them out in order: anything above the
-- highest id the last pass looked at is new. That makes the check a single integer compare
-- per item, which is what lets it run several times a second over a fort's whole item list.
-- How long the mood may go without picking anything up before another slot of the plan is
-- opened. A safety valve, not a schedule: see the note in steer().
local STALL_SECONDS = 30

local FULL_SWEEP_SECONDS = 5

local function sweep_new(job, unit)
    local high = state.max_id or 0
    local seen = high
    local open_filters, keep = {}, {}
    for i, filter in ipairs(job.job_items.elements) do
        if needed(filter) > #claimed_items(job, i) then
            open_filters[#open_filters + 1] = filter
            for _, id in pairs(state.picks[i] or {}) do keep[id] = true end
        end
    end
    if #open_filters == 0 then return end
    local group = unit_group(unit)
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        local id = item.id
        if id > high then
            if id > seen then seen = id end
            if not keep[id] and usable(item) and reachable(item, group)
                and not is_forbidden(item) then
                for _, filter in ipairs(open_filters) do
                    if filter_matches(filter, item) then
                        set_forbidden(item, true)
                        state.forbidden[id] = true
                        break
                    end
                end
            end
        end
    end
    state.max_id = seen
end

-- Forbid every other candidate for EVERY requirement still outstanding, and pen the dwarf on
-- the tile of the one they are fetching now.
--
-- Every requirement, not just the current one, and that is the whole lesson here. Steering
-- only the step in hand leaves DF free to reserve items for the steps AFTER it -- which it
-- does, well before the dwarf walks over -- and by the time this got round to that step the
-- wrong gem was already spoken for, flagged in_job, and beyond reach. That is what "I chose
-- star rubies and they used some random jasper" looks like from the inside.
--
-- One pass over the item list for the lot, because there is no cheap way to do it per row.
local function steer(unit, job)
    local idx, ji, item = current_step(job, state.picks)
    if not idx then return false end                 -- everything hauled: done
    if not item then return true end                 -- nothing chosen for this one; leave it be

    -- redone when the step moves on, which is exactly when the dwarf has picked one up and
    -- the alternatives for that row should be let go
    -- The full sweep also repeats on a timer, not only when the step moves. The cheap
    -- id-based pass below catches anything newly MADE, whatever made it -- mined, butchered,
    -- woven, forged, unloaded off a caravan -- but an item that merely became AVAILABLE keeps
    -- its old id: a boulder released when some other job was cancelled, a forbid the player
    -- lifted, something taken out of a container. Only looking at everything again finds those.
    local now = os.clock()
    local stale = not state.last_full or (now - state.last_full) > FULL_SWEEP_SECONDS
    if state.step ~= idx or state.step_item ~= item.id or stale then
        state.last_full = now
        -- only when the step actually moved: a timed re-sweep must not let go of what it
        -- already holds, or every five seconds the fort briefly opens up again
        if state.step ~= idx or state.step_item ~= item.id then
            release_forbids()
            state.step, state.step_item = idx, item.id
        end

        -- What is still wanted, and what may be taken for it.
        --
        -- ONE ITEM IS LEGAL AT A TIME. Everything else in the plan is forbidden along with
        -- everything else in the fort -- because a chosen item that sits unforbidden while
        -- the dwarf walks off to fetch something else is a chosen item any other job can
        -- take, and moods are slow. The plan is opened one slot at a time, in the order the
        -- job asks for them, and each slot only when the dwarf is actually ready for it.
        --
        -- With a stall valve. If DF ever wants a later requirement first, holding the
        -- earlier one open and nothing else would leave the mood standing still forever, so
        -- an extra slot is opened for every STALL_SECONDS that pass without anything being
        -- hauled. Slower than a free-for-all, never stuck.
        local lists = all_candidates(job, unit)
        local open_rows, keep = {}, {}
        local plan = {}
        for i, filter in ipairs(job.job_items.elements) do
            local got = #claimed_items(job, i)
            local want = needed(filter)
            if want > got then
                open_rows[#open_rows + 1] = {filter = filter}
                local slots = state.picks[i] or {}
                for slot = got + 1, want do
                    plan[#plan + 1] = {row = i, want = want - got,
                                       item = df.item.find(slots[slot] or -1)}
                end
            end
        end

        local hauled = #job.items
        if state.hauled ~= hauled then
            state.hauled, state.hauled_at = hauled, now
        end
        local waited = now - (state.hauled_at or now)
        local expose = 1 + math.floor(waited / STALL_SECONDS)

        for k, entry in ipairs(plan) do
            if k > expose then break end
            local chosen = entry.item
            if chosen and not keep[chosen.id] then
                keep[chosen.id] = true
                if is_forbidden(chosen) then
                    set_forbidden(chosen, false)
                    state.freed[chosen.id] = true
                end
            elseif not chosen then
                -- a slot nobody chose for falls back to the best still going, so what DF
                -- helps itself to is the best in the fort rather than the nearest
                for _, alt in ipairs(lists[entry.row] or {}) do
                    if not keep[alt.id] and df.item.find(alt.id) then
                        keep[alt.id] = true
                        break
                    end
                end
            end
        end

        local group = unit_group(unit)
        local high = 0
        for _, item_ in ipairs(df.global.world.items.other.IN_PLAY) do
            if item_.id > high then high = item_.id end
            if not keep[item_.id] and usable(item_) and reachable(item_, group)
                and not is_forbidden(item_) then
                for _, row in ipairs(open_rows) do
                    if filter_matches(row.filter, item_) then
                        set_forbidden(item_, true)
                        state.forbidden[item_.id] = true
                        break
                    end
                end
            end
        end

        state.max_id = high
        save_state()
    end

    -- and anything that has come into being since
    sweep_new(job, unit)

    local pos = xyz2pos(dfhack.items.getPosition(item))
    local shop = workshop_tiles(job)
    if delaying then
        -- the forbids above still stand; the burrow is the workshop alone
        apply_delay(unit, job)
        return true
    end
    if pos and pos.x >= 0 then
        local b = get_burrow()
        pcall(function()
            dfhack.burrows.clearTiles(b)
            dfhack.burrows.setAssignedTile(b, pos, true)
            -- and the workshop, always: a burrow holding only the item is a dwarf with
            -- nowhere to carry it back to, and the mood stalls on the doorstep
            for _, tile in ipairs(shop) do
                dfhack.burrows.setAssignedTile(b, tile, true)
            end
            dfhack.burrows.clearUnits(b)
            -- and NOT before there is a workshop to include. Until the dwarf claims one the
            -- job has no position at all (DF parks it at -30000), so restricting them now
            -- would pen them on the item with nowhere legal to go. The forbids alone are
            -- enough at that stage: there is only one item they can take anyway.
            if #shop > 0 then dfhack.burrows.setAssignedUnit(b, unit, true) end
        end)
    end
    return true
end

hb_gen = hb_gen or 0

local function heartbeat()
    local my_gen = hb_gen
    local function tick()
        if not state or my_gen ~= hb_gen then return end
        -- THE MOOD JOB IS NOT ONE JOB. DF replaces it as the mood progresses -- the id this
        -- started with stops existing, most visibly around the workshop being claimed -- and
        -- looking it up by id then found nothing, concluded the mood was over, and STOPPED:
        -- every forbid released, the fort thrown open, and DF free to take whatever was
        -- nearest for the rest of the mood. That is the failure behind every "it used some
        -- random jasper" in this fort. The mood is followed by its DWARF instead, which is
        -- the thing that actually persists.
        local unit = df.unit.find(state.unit_id)
        local live_unit, job = find_mood()
        if not unit or not job or not live_unit or live_unit.id ~= state.unit_id then
            stop()                                   -- mood over, one way or another
            return
        end
        state.job_id = job.id
        if not steer(unit, job) then stop() return end
        dfhack.timeout(10, 'frames', tick)
    end
    tick()
end

function start(unit, job, picks)
    stop()
    hb_gen = hb_gen + 1
    state = {unit_id = unit.id, job_id = job.id, picks = picks, forbidden = {}, freed = {},
             max_id = 0}
    heartbeat()
    save_state()
end

-- ---------------------------------------------------------------------------
-- the item picker
-- ---------------------------------------------------------------------------

Picker = defclass(Picker, widgets.Window)
Picker.ATTRS{
    frame_title = 'Pick an item',
    frame = {w = 70, h = 24},
    resizable = true,
    options = DEFAULT_NIL,
    on_pick = DEFAULT_NIL,
}

-- A mood's "any item" slot matches most of the fort, and a list widget with seventeen
-- thousand rows in it is not a chooser, it is a hang. Rows are one per kind (below), which
-- takes most of the sting out of that, and the list is best-first, so any tail past this
-- cap is the part nobody scrolls to.
local PICKER_MAX = 200

function Picker:init()
    -- One row per KIND of thing, not per item: a fort holds forty identical raw adamantine
    -- boulders and scrolling past thirty-nine of them is not a choice. The list arrives
    -- best-first, so the one kept is the best of its kind, and the rest are counted beside
    -- it. Forbidden and free items of the same name stay separate rows -- which of the two
    -- you take is a real decision, and one this tool will not make quietly.
    local seen, order = {}, {}
    for _, snap in ipairs(self.options or {}) do
        local key = ('%s%s%s%s'):format(snap.key, snap.forbidden and '!' or '',
            snap.worn and 'w' or '', snap.part_used and 'p' or '')
        local row = seen[key]
        if row then
            row.count = row.count + 1
        else
            row = {snap = snap, count = 1}
            seen[key] = row
            order[#order + 1] = row
        end
    end

    local choices = {}
    for _, row in ipairs(order) do
        if #choices >= PICKER_MAX then break end
        local snap = row.snap
        -- the name is read here, for this row only, off a freshly resolved item
        choices[#choices + 1] = {
            text = ('%7d  %s%s'):format(snap.value, live_name(snap.id, snap),
                row.count > 1 and (' x%d'):format(row.count) or ''),
            snap = snap,
        }
    end
    local hidden = math.max(0, #order - #choices)
    if hidden > 0 then
        choices[#choices + 1] = {text = {{
            text = ('...and %d more kinds, none worth more than these'):format(hidden),
            pen = COLOR_GREY}}}
    end
    if #choices == 0 then choices = {{text = '(nothing in the fort fits this)'}} end
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = 'value    item', text_pen = COLOR_GREY},
        widgets.List{
            frame = {t = 2, l = 0, r = 0, b = 0},
            choices = choices,
            on_submit = function(_, ch)
                if ch.snap then self.on_pick(ch.snap) end
                self.parent_view:dismiss()
            end,
        },
    }
end

PickerScreen = defclass(PickerScreen, gui.ZScreenModal)
PickerScreen.ATTRS{
    focus_path = 'help-mood/pick',
    options = DEFAULT_NIL,
    on_pick = DEFAULT_NIL,
}
function PickerScreen:init()
    self:addviews{Picker{options = self.options, on_pick = self.on_pick}}
end

-- ---------------------------------------------------------------------------
-- the planner
-- ---------------------------------------------------------------------------

Planner = defclass(Planner, widgets.Window)
Planner.ATTRS{
    frame_title = 'Strange mood',
    frame = {w = 78, h = 24},
    resizable = true,
    unit = DEFAULT_NIL,
    job = DEFAULT_NIL,
}

function Planner:init()
    self.picks = {}
    self.hauled = #self.job.items
    self.rows = requirements(self.job, self.unit)
    -- Defaults, slot by slot: the best items by value, one per open slot and never the same
    -- item twice -- two slots pointing at one boulder is a mood that stalls on the second.
    -- A forbidden item is skipped unless there is nothing else, since a forbid is a decision
    -- the fort made on purpose.
    local taken = {}
    for _, r in ipairs(self.rows) do
        if r.claimed then
            taken[r.claimed.id] = true
        else
            self.picks[r.fidx] = self.picks[r.fidx] or {}
            local pick
            -- the best CLEAN one: not forbidden, not worn, not part-used, not spoken for
            for _, snap in ipairs(r.options) do
                if not taken[snap.id] and not snap.forbidden and not snap.worn
                    and not snap.part_used and not snap.busy then
                    pick = snap
                    break
                end
            end
            for _, snap in ipairs(r.options) do
                if pick then break end
                if not taken[snap.id] then pick = snap end
            end
            if pick then
                taken[pick.id] = true
                self.picks[r.fidx][r.slot] = pick.id
            end
        end
    end
    self:addviews{
        widgets.Label{view_id = 'headline', frame = {t = 0, l = 0}, text = ''},
        -- wrapped: "<dwarf> announces they will create a <thing>!" with a long dwarf name
        -- runs off the default screen otherwise
        widgets.WrappedLabel{view_id = 'omen', frame = {t = 1, l = 0, r = 0, h = 2},
                             text_to_wrap = ''},
        widgets.List{
            view_id = 'list',
            frame = {t = 4, l = 0, r = 0, b = 3},
            on_submit = function(_, ch) self:pick(ch) end,
        },
        -- h = 1 on both: a TextButton is a BannerPanel, and a frame without a height
        -- stretches it down the whole window as a column of empty brackets
        widgets.TextButton{
            view_id = 'help',
            frame = {b = 1, l = 0, w = 33, h = 1},
            label = 'build selected artifact',
            key = 'CUSTOM_CTRL_B',
            on_activate = function() self:apply() end,
        },
        -- shown whether or not a build is running: it also clears forbids left behind by a
        -- session that ended without one, which is the only way back from those
        widgets.TextButton{
            frame = {b = 1, l = 35, w = 24, h = 1},
            label = 'cancel helping',
            key = 'CUSTOM_CTRL_X',
            on_activate = function()
                local n = stop()
                self:refresh()
                self.subviews.status:setText(
                    ('Let go: %d item%s unforbidden, burrow emptied.'):format(n, n == 1 and '' or 's'))
            end,
        },
        widgets.TextButton{
            frame = {b = 1, l = 61, w = 7, h = 1},
            label = 'close',
            on_activate = function() self.parent_view:dismiss() end,
        },
        -- its own row above the others: a delay is not part of the pick-and-build sequence,
        -- it is the thing you reach for when that sequence needs longer than the mood allows
        widgets.TextButton{
            view_id = 'delay',
            frame = {b = 2, l = 0, w = 22, h = 1},
            label = 'delay work',
            key = 'CUSTOM_CTRL_D',
            on_activate = function() self:toggle_delay() end,
        },
        widgets.Label{
            view_id = 'status', frame = {b = 0, l = 0}, text = '', text_pen = COLOR_GREY,
        },
    }
    self:refresh()
end

-- Hold the mood where it is: the dwarf gets a burrow of nothing but their own workshop, so
-- there is no item they can reach and nothing they can start.
function Planner:toggle_delay()
    if delaying then
        set_delay(false)
        self.subviews.status:setText('Delay lifted: they may fetch again.')
    else
        local ok, why = set_delay(true)
        if not ok then
            self.subviews.status:setText('Cannot delay: ' .. (why or 'unknown'))
        else
            self.subviews.status:setText(
                'Delayed: burrowed into their workshop, they can fetch nothing.')
        end
    end
    self:relabel_delay()
end

function Planner:relabel_delay()
    local b = self.subviews.delay
    b.label.text_pen = delaying and COLOR_LIGHTGREEN or COLOR_GREY
    b:setLabel(delaying and 'let them work' or 'delay work')
end

function Planner:satisfied()
    for _, r in ipairs(self.rows) do
        if not r.claimed and #r.options == 0 then return false end
    end
    return true
end

-- Drop any pick whose item is gone -- consumed by this very mood, most often -- and put the
-- best of what is left in its place. Without this a row reads "(gone)", which is true and
-- useless: the choice still has to be made, and the panel knows what the alternatives are.
function Planner:reconcile()
    -- the mood taking something is the one event that changes every row's meaning, so the
    -- requirements are re-read when that count moves rather than on every redraw
    local hauled = #self.job.items
    if hauled ~= self.hauled then
        self.hauled = hauled
        self.rows = requirements(self.job, self.unit)
    end
    local taken = {}
    for _, r in ipairs(self.rows) do
        if r.claimed then taken[r.claimed.id] = true end
    end
    for _, r in ipairs(self.rows) do
        local slots = self.picks[r.fidx]
        local id = slots and slots[r.slot]
        if id and not df.item.find(id) then id = nil end
        if id then
            taken[id] = true
        elseif not r.claimed then
            local pick
            for _, snap in ipairs(r.options) do
                if not taken[snap.id] and not snap.forbidden and not snap.worn
                    and not snap.part_used and df.item.find(snap.id) then
                    pick = snap
                    break
                end
            end
            self.picks[r.fidx] = self.picks[r.fidx] or {}
            self.picks[r.fidx][r.slot] = pick and pick.id or nil
            if pick then taken[pick.id] = true end
        end
    end
end

function Planner:refresh()
    self:reconcile()
    self:relabel_delay()
    local name = dfhack.units.getReadableName(self.unit)
    if self:satisfied() then
        self.subviews.headline:setText({{
            text = ('The gods have blessed %s'):format(name), pen = COLOR_LIGHTGREEN}})
        local what = prediction(self.unit)
        self.subviews.omen:setText(what
            and ('%s announces they will create a %s!'):format(name, what)
            or 'What they will make is anyone\'s guess.')
        self.subviews.omen.text_pen = what and COLOR_YELLOW or COLOR_GREY
    else
        -- and NOTHING else. No row, no requirement name, no hint at which one is short:
        -- the whole value of this panel is knowing what the mood wants, and a fort that
        -- cannot meet it has not earned that. The dwarf goes mad or does not on their own.
        --
        -- THIS IS NOT THE PLACE TO LEARN WHAT YOU ARE SHORT OF. By the time a mood has
        -- struck it is already too late -- the demand was rolled when it started. Naming the
        -- gap here was tried and taken straight back out: it reads as help and it is not,
        -- because the answer arrives on the one day it cannot be used.
        -- `fort/moody-items-warning` is the tool for that question. It runs all the time,
        -- names every mood material the fort has none of ("No raw crystal glass for a
        -- mood"), and says it while there is still a season to do something about it.
        self.subviews.headline:setText({{text = 'The gods are testing you', pen = COLOR_LIGHTRED}})
        self.subviews.omen:setText('')
        self.subviews.list:setChoices({})
        -- The one thing this panel CAN offer when the fort is short: hold the dwarf still
        -- while somebody goes and makes the missing thing.
        self.subviews.status:setText(delaying
            and 'Delayed: burrowed into their workshop, they can fetch nothing.'
            or 'They want something you have not got. Ctrl-D holds them until you have.')
        self.subviews.help.visible = false
        return
    end

    self.subviews.help.visible = true
    local choices = {}
    for n, r in ipairs(self.rows) do
        -- "rock boulder 2/3" where a requirement wants several, plain otherwise
        local want = requirement_name(r.filter)
        if r.of > 1 then want = ('%s %d/%d'):format(want, r.slot, r.of) end
        local line, pen
        if r.claimed then
            line = ('%d. %-26s claimed: %s'):format(n, want, item_name(r.claimed))
            pen = COLOR_GREY
        elseif #r.options == 0 then
            line = ('%d. %-26s NOTHING IN THE FORT FITS'):format(n, want)
            pen = COLOR_LIGHTRED
        else
            local id = (self.picks[r.fidx] or {})[r.slot]
            local snap
            for _, o in ipairs(r.options) do if o.id == id then snap = o; break end end
            line = ('%d. %-26s %s'):format(n, want, id and live_name(id, snap) or '(none picked)')
        end
        choices[#choices + 1] = {text = pen and {{text = line, pen = pen}} or line, row = r}
    end
    self.subviews.list:setChoices(choices, self.subviews.list:getSelected())
    self.subviews.status:setText(state
        and 'Building: every other candidate is forbidden until the dwarf has these.'
        or 'Click a row to choose a different item, then build.')
end

function Planner:pick(choice)
    local r = choice and choice.row
    if not r then return end
    if r.claimed then
        self.subviews.status:setText('Already hauled in -- too late to change that one.')
        return
    end
    PickerScreen{
        options = r.options,
        on_pick = function(snap) self:choose(r, snap) end,
    }:show()
end

-- Put `item` in this row's slot. Two slots of one requirement must never name the same
-- item -- DF can only bring it once and the second slot would wait forever -- so a pick that
-- is already spoken for takes another of the same kind where the fort has one, and trades
-- places with the slot that had it where it does not.
function Planner:choose(r, snap)
    local slots = self.picks[r.fidx] or {}
    self.picks[r.fidx] = slots

    -- across EVERY row, not just this requirement's: two requirements are two items even
    -- when the same one would satisfy both, and DF can only carry it to one of them
    local holder, holder_fidx
    for fidx, other in pairs(self.picks) do
        for slot, id in pairs(other) do
            if id == snap.id and not (fidx == r.fidx and slot == r.slot) then
                holder, holder_fidx = slot, fidx
            end
        end
    end
    if holder then
        local used = {}
        for _, other in pairs(self.picks) do
            for _, id in pairs(other) do used[id] = true end
        end
        local swap
        for _, alt in ipairs(r.options) do
            if not used[alt.id] and alt.key == snap.key then swap = alt; break end
        end
        if swap then
            slots[r.slot] = swap.id          -- another of the same kind
        else
            -- nothing else like it: trade places with whoever had it
            self.picks[holder_fidx][holder] = slots[r.slot]
            slots[r.slot] = snap.id
        end
    else
        slots[r.slot] = snap.id
    end
    self:refresh()
end

function Planner:apply()
    if not self:satisfied() then
        self.subviews.status:setText('Nothing to build: the mood cannot be satisfied.')
        return
    end
    start(self.unit, self.job, self.picks)
    self:refresh()
end

PlannerScreen = defclass(PlannerScreen, gui.ZScreen)
PlannerScreen.ATTRS{
    focus_path = 'help-mood',
    unit = DEFAULT_NIL,
    job = DEFAULT_NIL,
}
function PlannerScreen:init() self:addviews{Planner{unit = self.unit, job = self.job}} end
function PlannerScreen:onDismiss() view = nil end

view = view or nil

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('fort/help-mood only works in fortress mode') end

local arg = ({...})[1]
if arg == 'stop' then
    local n = stop()
    print(('fort/help-mood: released; burrow emptied, %d leftover forbid%s cleared.')
        :format(n, n == 1 and '' or 's'))
    return
end

local unit, job = find_mood()
if not job then
    qerror('no strange mood is active')
end
if not unit then
    qerror('found a mood job but not the dwarf it belongs to')
end
view = view or PlannerScreen{unit = unit, job = job}:show()
