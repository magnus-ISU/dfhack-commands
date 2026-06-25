-- labor-groups: (re)build & order the crafting Work Details, and tidy the default ones.
--[[
    labor-groups        rebuild the crafting Work Details and reorder the whole list.
    labor-groups dry    preview only -- change nothing.
    labor-groups once   run only if not yet applied to this fort (used by magnus-scripts,
                        so re-running that won't reshuffle later manual edits). A plain
                        `labor-groups` always re-applies.

Lays out the Labor screen as:

    1. the dig/grow defaults first -- Miners, Woodcutters, Planters, Stonecutters,
       Engravers (left exactly as they are: their modes and assigned dwarves are kept);
    2. then the crafting set, in a fixed order -- the twelve priority crafts
       (Weaponsmithing, Armorsmithing, Metal crafting, Metalsmithing, Stone carving,
       Carpentry, Glassmaker, Mechanic, Wood crafter, Stone crafter, Furnace operator,
       Wood burner) followed by a group for every remaining MOODABLE skill so a strange
       mood can always claim the right workshop (Mason, Bone carver, Bowyer, Clothier,
       Gem cutter, Gem setter, Leatherworker, Tanner, Weaver);
    3. then the rest of the defaults at the end -- Hunters, Fisherdwarves, Plant
       gatherers, Haulers, Orderlies, Siege operators, and any other detail you added.

Every crafting detail is created as "Everyone does this" (mode), so no per-dwarf
assignment is needed -- everyone pitches in on the craft. Hunters and Fisherdwarves are
forced to "Nobody does this". All other default details keep whatever mode/assignments
they already have.

The crafting details are rebuilt from scratch each run (any detail whose labors are ALL
crafting labors is removed and recreated); the default details are only reordered, never
recreated, so their assignments are safe. Idempotent.

ICONS: DF has no dedicated craft icons, so each craft borrows a recognizable built-in
glyph (the `icon` field on GROUPS, e.g. the smithing crafts use the engravers icon, the
furnace/burner/mason use haulers). The Engravers default is also re-iconned to the
stonecutters glyph (DEFAULT_ICON). The CUSTOM_1..CUSTOM_8 art slots (only 8) remain a
later option for truly custom art.

Data: Work Details live in `df.global.plotinfo.labor_info.work_details`; each has `name`,
`allowed_labors` (a unit_labor bitfield), `flags.mode` (a `work_detail_mode`),
`assigned_units`, and `icon` (a `work_detail_icon_type`).
]]

-- ordered crafting set: the twelve priority crafts first, then the missing moodables.
-- icon = a built-in work_detail_icon_type borrowed to give each craft a recognizable
-- glyph (DF has no dedicated craft icons; these are hand-picked stand-ins).
local GROUPS = {
    -- priority order (these must lead the crafting block, in exactly this order)
    {name = 'Weaponsmithing',   labors = {'FORGE_WEAPON'},    icon = 'ENGRAVERS'},
    {name = 'Armorsmithing',    labors = {'FORGE_ARMOR'},     icon = 'ENGRAVERS'},
    {name = 'Metal crafting',   labors = {'METAL_CRAFT'},     icon = 'ENGRAVERS'},
    {name = 'Metalsmithing',    labors = {'FORGE_FURNITURE'}, icon = 'ENGRAVERS'},   -- aka Blacksmithing
    {name = 'Stone carving',    labors = {'STONE_CARVER'},    icon = 'STONECUTTERS'},
    {name = 'Carpentry',        labors = {'CARPENTER'},       icon = 'WOODCUTTERS'},
    {name = 'Glassmaker',       labors = {'GLASSMAKER'},      icon = 'ORDERLIES'},
    {name = 'Mechanic',         labors = {'MECHANIC'},        icon = 'SIEGE_OPERATORS'},
    {name = 'Wood crafter',     labors = {'WOOD_CRAFT'},      icon = 'WOODCUTTERS'},
    {name = 'Stone crafter',    labors = {'STONE_CRAFT'},     icon = 'STONECUTTERS'},
    {name = 'Furnace operator', labors = {'SMELT'},           icon = 'HAULERS'},
    {name = 'Wood burner',      labors = {'BURN_WOOD'},       icon = 'HAULERS'},
    -- remaining moodable skills not covered above or by a kept DF default
    {name = 'Mason',            labors = {'MASON'},           icon = 'HAULERS'},
    {name = 'Bone carver',      labors = {'BONE_CARVE'},      icon = 'FISHERMEN'},
    {name = 'Bowyer',           labors = {'BOWYER'},          icon = 'HUNTERS'},
    {name = 'Clothier',         labors = {'CLOTHESMAKER'},    icon = 'PLANT_GATHERERS'},
    {name = 'Gem cutter',       labors = {'CUT_GEM'},         icon = 'ENGRAVERS'},
    {name = 'Gem setter',       labors = {'ENCRUST_GEM'},     icon = 'ENGRAVERS'},
    {name = 'Leatherworker',    labors = {'LEATHER'},         icon = 'HUNTERS'},
    {name = 'Tanner',           labors = {'TANNER'},          icon = 'HUNTERS'},
    {name = 'Weaver',           labors = {'WEAVER'},          icon = 'PLANT_GATHERERS'},
}

-- icon overrides for KEPT default details, by a representative labor (cosmetic only)
local DEFAULT_ICON = {ENGRAVER = 'STONECUTTERS'}   -- the Engravers detail borrows the stonecutters glyph

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

-- default details, by a representative non-crafting labor, in the order we want them:
local FRONT = {'MINE', 'CUTWOOD', 'PLANT', 'STONECUTTER', 'ENGRAVER'}            -- before crafts
local TAIL  = {'HUNT', 'FISH', 'HERBALIST', 'HAUL_STONE', 'RECOVER_WOUNDED', 'SIEGEOPERATE'}  -- after
local FORCE_NOBODY = {HUNT = true, FISH = true}   -- these defaults -> "Nobody does this"

if not dfhack.world.isFortressMode() then qerror('labor-groups only works in fortress mode') end

local arg = ({...})[1]
local dry = arg == 'dry'
local once = arg == 'once'

-- `once` gate: skip entirely if this fort already had the layout applied (flag persisted
-- per-site below, so it survives save/reload).
local PERSIST_KEY = 'labor-groups'
if once then
    local st = dfhack.persistent.getSiteData(PERSIST_KEY)
    if st and st.applied then
        print('labor-groups: already applied to this fort -- skipping (run `labor-groups` to force)')
        return
    end
end

local wd = df.global.plotinfo.labor_info.work_details

-- labors this script owns (union of every group's labors). A detail is "ours" (a crafting
-- detail to rebuild) only if it has labors and they ALL fall in this set -- so DF defaults
-- (MINE / CUTWOOD / STONECUTTER / ENGRAVER / hauling / ...) and your empty custom details
-- are never touched.
local managed = {}
for _, g in ipairs(GROUPS) do for _, l in ipairs(g.labors) do managed[l] = true end end

local function labors_of(w)
    local out = {}
    for i = 0, df.unit_labor._last_item do
        local n = df.unit_labor[i]
        if n and w.allowed_labors[n] then out[#out + 1] = n end
    end
    return out
end

local function is_ours(w)
    local labs = labors_of(w)
    if #labs == 0 then return false end
    for _, l in ipairs(labs) do if not managed[l] then return false end end
    return true
end

-- first not-yet-placed kept (non-crafting) detail enabling labor L, by INDEX. We track
-- by index, not by handle: DFHack hands back a fresh Lua wrapper on every wd[i], so
-- handles can't be used as identity keys (that was a double-listing bug).
local placed = {}
local function find_default(L)
    for i = 0, #wd - 1 do
        if not placed[i] and wd[i].allowed_labors[L] and not is_ours(wd[i]) then return i end
    end
end

-- gather kept default indices in the desired front / tail order; the rest go in "other"
-- (placed after the tail). Then grab one handle each -- handles survive erase (erase
-- doesn't delete), so we can pull them from the vector and re-insert them in new order.
local front_idx, tail_idx, other_idx = {}, {}, {}
for _, L in ipairs(FRONT) do local i = find_default(L); if i then placed[i] = true; front_idx[#front_idx + 1] = i end end
for _, L in ipairs(TAIL)  do local i = find_default(L); if i then placed[i] = true; tail_idx[#tail_idx + 1]  = i end end
for i = 0, #wd - 1 do if not placed[i] and not is_ours(wd[i]) then placed[i] = true; other_idx[#other_idx + 1] = i end end

local function handles(idxs) local h = {}; for _, i in ipairs(idxs) do h[#h + 1] = wd[i] end; return h end
local front_h, tail_h, other_h = handles(front_idx), handles(tail_idx), handles(other_idx)

-- the mode a default detail should end up with (Hunters/Fisherdwarves -> Nobody)
local function planned_mode(w)
    for L in pairs(FORCE_NOBODY) do if w.allowed_labors[L] then return df.work_detail_mode.NobodyDoesThis end end
    return w.flags.mode
end

-- names of the crafting details being replaced (for the report)
local removed = {}
for i = 0, #wd - 1 do if is_ours(wd[i]) then removed[#removed + 1] = wd[i].name end end

-- the icon a kept default should end up with (an override, or its current icon)
local function default_icon(w)
    for L, ic in pairs(DEFAULT_ICON) do if w.allowed_labors[L] then return df.work_detail_icon_type[ic] end end
    return w.icon
end

if not dry then
    -- force default modes (Hunters / Fisherdwarves -> Nobody) and icon overrides
    for _, list in ipairs({front_h, tail_h, other_h}) do
        for _, w in ipairs(list) do w.flags.mode = planned_mode(w); w.icon = default_icon(w) end
    end

    -- build the new crafting details (Everyone does this), held aside
    local craft_h = {}
    for _, g in ipairs(GROUPS) do
        local w = df.work_detail:new()
        w.name = g.name
        for _, l in ipairs(g.labors) do w.allowed_labors[l] = true end
        w.flags.mode = df.work_detail_mode.EverybodyDoesThis   -- everyone pitches in
        w.icon = df.work_detail_icon_type[g.icon]              -- borrowed built-in glyph
        craft_h[#craft_h + 1] = w
    end

    -- empty the vector: delete the owned crafting details, KEEP (don't delete) the rest
    for i = #wd - 1, 0, -1 do
        local w = wd[i]
        wd:erase(i)
        if is_ours(w) then w:delete() end
    end

    -- re-insert in the final order: front defaults, crafts, tail defaults, other details
    for _, w in ipairs(front_h) do wd:insert('#', w) end
    for _, w in ipairs(craft_h) do wd:insert('#', w) end
    for _, w in ipairs(tail_h)  do wd:insert('#', w) end
    for _, w in ipairs(other_h) do wd:insert('#', w) end

    dfhack.persistent.saveSiteData(PERSIST_KEY, {applied = true})
end

-- ---- report -----------------------------------------------------------------
print(('labor-groups: %s'):format(dry and 'DRY RUN -- planned layout (no changes made)'
    or 'rebuilt crafting details + reordered the Labor screen'))
print(('  removed %d crafting detail(s): %s'):format(#removed, table.concat(removed, ', ')))
local pos = 0
local function show(name, mode, icon)
    pos = pos + 1
    print(('    %2d. %-20s [%-20s] icon=%s'):format(pos, name, df.work_detail_mode[mode], df.work_detail_icon_type[icon]))
end
for _, w in ipairs(front_h) do show(w.name, planned_mode(w), default_icon(w)) end
for _, g in ipairs(GROUPS)  do show(g.name, df.work_detail_mode.EverybodyDoesThis, df.work_detail_icon_type[g.icon]) end
for _, w in ipairs(tail_h)  do show(w.name, planned_mode(w), default_icon(w)) end
for _, w in ipairs(other_h) do show(w.name, planned_mode(w), default_icon(w)) end

-- moodable coverage: every moodable labor must be enabled by some kept default or a craft
local covers = {}
for i = 0, #wd - 1 do if not is_ours(wd[i]) then for _, l in ipairs(labors_of(wd[i])) do covers[l] = covers[l] or wd[i].name end end end
for _, g in ipairs(GROUPS) do for _, l in ipairs(g.labors) do covers[l] = covers[l] or g.name end end
local missing = {}
for _, m in ipairs(MOODABLE) do if not covers[m.labor] then missing[#missing + 1] = m.skill end end
print(#missing == 0 and '  moodable skills: all represented'
    or ('  moodable skills MISSING coverage: ' .. table.concat(missing, ', ')))
