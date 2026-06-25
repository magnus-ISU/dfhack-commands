-- labor-groups: (re)build the crafting Work Details as one ordered, mood-complete set.
--[[
    labor-groups        swap the crafting Work Details for the standard ordered set,
                        preserving which dwarves do which labors.
    labor-groups dry    preview only -- change nothing.
    labor-groups once   run only if it has not yet been applied to this fort (used by
                        magnus-scripts, so re-running that won't clobber later manual
                        Labor-screen tweaks). A plain `labor-groups` always re-applies.

Replaces the fort's CRAFTING work details with a single curated set, placed at the TOP
of the Labor list in a fixed order. The first twelve are the priority crafts:

    Weaponsmithing, Armorsmithing, Metal crafting, Metalsmithing, Stone carving,
    Carpentry, Glassmaker, Mechanic, Wood crafter, Stone crafter, Furnace operator,
    Wood burner

Then a group is added for every remaining MOODABLE skill that isn't already covered, so
a strange mood can always claim the right workshop: Mason, Bone carver, Bowyer, Clothier,
Gem cutter, Gem setter, Leatherworker, Tanner, Weaver. (Miner, Stonecutter and Engraver
are moodable too but stay on their existing DF default details, which we leave alone.)

SWAP + MIGRATE: every existing work detail whose labors are ALL within this managed
crafting set is removed and rebuilt, but the assignments are carried over -- before
removing anything we snapshot, per labor, which units were assigned, and re-apply that to
the new groups. So the same dwarves keep doing the same labors (e.g. the old combined
"Furnace" SMELT+BURN_WOOD detail's dwarves end up on BOTH the new Furnace operator and
Wood burner groups). Non-crafting DF defaults (Miners, Woodcutters, Planters, Haulers,
medical, siege, and the kept Stonecutters/Engravers) are never touched.

Idempotent: re-running snapshots the current assignments, rebuilds the set in order, and
restores the assignments -- so it converges and never loses who-does-what.

Data: Work Details live in `df.global.plotinfo.labor_info.work_details`; each has `name`,
`allowed_labors` (a unit_labor bitfield), `flags.mode` (a `work_detail_mode`; we use
`OnlySelectedDoesThis`), `assigned_units` (unit ids), and `icon`.
]]

-- ordered crafting set: the twelve priority crafts first, then the missing moodables.
-- name = label shown on the Labor screen; labors = unit_labor enum keys it enables.
local GROUPS = {
    -- priority order (these must be the first details, in exactly this order)
    {name = 'Weaponsmithing',   labors = {'FORGE_WEAPON'}},
    {name = 'Armorsmithing',    labors = {'FORGE_ARMOR'}},
    {name = 'Metal crafting',   labors = {'METAL_CRAFT'}},
    {name = 'Metalsmithing',    labors = {'FORGE_FURNITURE'}},  -- aka Blacksmithing
    {name = 'Stone carving',    labors = {'STONE_CARVER'}},
    {name = 'Carpentry',        labors = {'CARPENTER'}},
    {name = 'Glassmaker',       labors = {'GLASSMAKER'}},
    {name = 'Mechanic',         labors = {'MECHANIC'}},
    {name = 'Wood crafter',     labors = {'WOOD_CRAFT'}},
    {name = 'Stone crafter',    labors = {'STONE_CRAFT'}},
    {name = 'Furnace operator', labors = {'SMELT'}},
    {name = 'Wood burner',      labors = {'BURN_WOOD'}},
    -- remaining moodable skills not covered above or by a kept DF default
    {name = 'Mason',            labors = {'MASON'}},
    {name = 'Bone carver',      labors = {'BONE_CARVE'}},
    {name = 'Bowyer',           labors = {'BOWYER'}},
    {name = 'Clothier',         labors = {'CLOTHESMAKER'}},
    {name = 'Gem cutter',       labors = {'CUT_GEM'}},
    {name = 'Gem setter',       labors = {'ENCRUST_GEM'}},
    {name = 'Leatherworker',    labors = {'LEATHER'}},
    {name = 'Tanner',           labors = {'TANNER'}},
    {name = 'Weaver',           labors = {'WEAVER'}},
}

-- every moodable skill -> its labor, for the coverage check (Miner/Stonecutter/Engraver
-- ride on kept DF defaults; <none> has no labor). Used only to report representation.
local MOODABLE = {
    {skill = 'Armorsmith',    labor = 'FORGE_ARMOR'},
    {skill = 'Bone carver',   labor = 'BONE_CARVE'},
    {skill = 'Bowyer',        labor = 'BOWYER'},
    {skill = 'Carpenter',     labor = 'CARPENTER'},
    {skill = 'Clothier',      labor = 'CLOTHESMAKER'},
    {skill = 'Engraver',      labor = 'ENGRAVER'},
    {skill = 'Gem cutter',    labor = 'CUT_GEM'},
    {skill = 'Gem setter',    labor = 'ENCRUST_GEM'},
    {skill = 'Glassmaker',    labor = 'GLASSMAKER'},
    {skill = 'Leatherworker', labor = 'LEATHER'},
    {skill = 'Mason',         labor = 'MASON'},
    {skill = 'Mechanic',      labor = 'MECHANIC'},
    {skill = 'Metal crafter', labor = 'METAL_CRAFT'},
    {skill = 'Metalsmith',    labor = 'FORGE_FURNITURE'},
    {skill = 'Miner',         labor = 'MINE'},
    {skill = 'Stone carver',  labor = 'STONE_CARVER'},
    {skill = 'Stone crafter', labor = 'STONE_CRAFT'},
    {skill = 'Stonecutter',   labor = 'STONECUTTER'},
    {skill = 'Tanner',        labor = 'TANNER'},
    {skill = 'Weaponsmith',   labor = 'FORGE_WEAPON'},
    {skill = 'Weaver',        labor = 'WEAVER'},
    {skill = 'Wood crafter',  labor = 'WOOD_CRAFT'},
}

if not dfhack.world.isFortressMode() then qerror('labor-groups only works in fortress mode') end

local arg = ({...})[1]
local dry = arg == 'dry'
local once = arg == 'once'

-- `once` gate: skip entirely if this fort has already had the swap applied. The flag is
-- persisted per-site (see the save at the end), so it survives save/reload.
local PERSIST_KEY = 'labor-groups'
if once then
    local st = dfhack.persistent.getSiteData(PERSIST_KEY)
    if st and st.applied then
        print('labor-groups: already applied to this fort -- skipping (run `labor-groups` to force)')
        return
    end
end

local wd = df.global.plotinfo.labor_info.work_details

-- the set of labors this script owns (the union of every group's labors). A work detail
-- is "ours" (a crafting detail to swap out) only if ALL its labors fall inside this set,
-- so DF defaults that mix in MINE / CUTWOOD / STONECUTTER / ENGRAVER / hauling are safe.
local managed = {}
for _, g in ipairs(GROUPS) do for _, l in ipairs(g.labors) do managed[l] = true end end

-- the labors actually present on an existing detail (as enum-key strings)
local function labors_of(w)
    local out = {}
    for i = 0, df.unit_labor._last_item do
        local n = df.unit_labor[i]
        if n and w.allowed_labors[n] then out[#out + 1] = n end
    end
    return out
end

-- a "ours" detail: non-empty and every labor is managed (so removing it is safe)
local function is_ours(w)
    local labs = labors_of(w)
    if #labs == 0 then return false end
    for _, l in ipairs(labs) do if not managed[l] then return false end end
    return true
end

-- SNAPSHOT: labor -> ordered, de-duped list of unit ids currently assigned to it (read
-- from every existing detail, so assignments are preserved no matter where they live)
local assigned_by_labor = {}
local function record(labor, uid)
    local list = assigned_by_labor[labor]
    if not list then list = {seen = {}}; assigned_by_labor[labor] = list end
    if not list.seen[uid] then list.seen[uid] = true; list[#list + 1] = uid end
end
for i = 0, #wd - 1 do
    local w = wd[i]
    for _, l in ipairs(labors_of(w)) do
        if managed[l] then
            for k = 0, #w.assigned_units - 1 do record(l, w.assigned_units[k]) end
        end
    end
end

-- the migrated units for a group = the union of its labors' snapshotted assignees
local function units_for(g)
    local out, seen = {}, {}
    for _, l in ipairs(g.labors) do
        for _, uid in ipairs(assigned_by_labor[l] or {}) do
            if not seen[uid] then seen[uid] = true; out[#out + 1] = uid end
        end
    end
    return out
end

local function uname(uid)
    local u = df.unit.find(uid)
    return u and dfhack.units.getReadableName(u) or ('unit ' .. uid)
end

-- list (and, unless dry, remove) the crafting details we own, capturing their names
local removed = {}
for i = #wd - 1, 0, -1 do
    local w = wd[i]
    if is_ours(w) then
        removed[#removed + 1] = w.name
        if not dry then
            wd:erase(i)
            w:delete()
        end
    end
end

-- (re)create the managed set at the TOP of the list, in order, re-applying assignments.
-- Inserting group g at index g-1 (0,1,2,...) leaves the kept defaults after them.
local created = {}
for idx, g in ipairs(GROUPS) do
    local units = units_for(g)
    created[#created + 1] = {name = g.name, units = units}
    if not dry then
        local w = df.work_detail:new()
        w.name = g.name
        for _, l in ipairs(g.labors) do w.allowed_labors[l] = true end
        w.flags.mode = df.work_detail_mode.OnlySelectedDoesThis
        w.icon = df.work_detail_icon_type.NONE
        for _, uid in ipairs(units) do
            w.assigned_units:insert('#', uid)
            local u = df.unit.find(uid)              -- keep the unit's labor flags on, so
            if u then                                -- nobody drops their job for a frame
                for _, l in ipairs(g.labors) do u.status.labors[l] = true end
            end
        end
        wd:insert(idx - 1, w)
    end
end

-- mark this fort done, so a later `labor-groups once` (e.g. a re-run of magnus-scripts)
-- becomes a no-op and leaves any manual Labor-screen edits intact
if not dry then dfhack.persistent.saveSiteData(PERSIST_KEY, {applied = true}) end

-- ---- report -----------------------------------------------------------------
print(('labor-groups: %s'):format(dry and 'DRY RUN -- no changes made' or 'swapped crafting work details'))
print(('  removed %d existing crafting detail(s): %s'):format(#removed, table.concat(removed, ', ')))
print(('  %s %d ordered detail(s):'):format(dry and 'would create' or 'created', #created))
for i, c in ipairs(created) do
    if #c.units > 0 then
        local names = {}
        for _, uid in ipairs(c.units) do names[#names + 1] = uname(uid) end
        print(('    %2d. %-18s <- %s'):format(i, c.name, table.concat(names, '; ')))
    else
        print(('    %2d. %-18s (unassigned)'):format(i, c.name))
    end
end

-- moodable coverage: after the swap, confirm every moodable labor has SOME detail
-- (one of ours, or a kept default) enabling it
local covers = {}
for i = 0, #wd - 1 do
    for _, l in ipairs(labors_of(wd[i])) do
        covers[l] = covers[l] or wd[i].name
    end
end
-- in dry mode the new details aren't in `wd` yet, so also count what we WOULD create
if dry then for _, g in ipairs(GROUPS) do for _, l in ipairs(g.labors) do covers[l] = covers[l] or g.name end end end
local missing = {}
for _, m in ipairs(MOODABLE) do if not covers[m.labor] then missing[#missing + 1] = m.skill end end
if #missing == 0 then
    print('  moodable skills: all represented')
else
    print('  moodable skills MISSING coverage: ' .. table.concat(missing, ', '))
end
