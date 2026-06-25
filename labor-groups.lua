-- labor-groups: order the Labor screen + keep the standard crafting details, NON-destructively.
--[[
    labor-groups        update icons + order the Labor list; create any missing detail.
    labor-groups dry    preview the planned order -- change nothing.
    labor-groups once   run only if not yet applied to this fort (used by magnus-scripts).

Lays the Labor screen out as:
    1. dig/grow defaults first -- Miners, Woodcutters, Planters, Stonecutters, Engravers
    2. the crafting set, in a fixed order (the twelve priority crafts, then a group for
       every remaining moodable skill)
    3. the other defaults -- Hunters, Fisherdwarves, Plant gatherers, Haulers, Orderlies,
       Siege operators, plus anything else you added
    4. the "Military" detail LAST (siege-operators icon; its members are kept in sync with
       your squads by the separate `military-labor` script)

NON-DESTRUCTIVE: existing details are reordered (and their icons updated), never deleted
and never recreated, so your manual assignments and modes are preserved. Only details that
don't exist yet are created (the crafting ones default to "Everyone does this"; "Military"
to "Only selected", with no labor -- add labors to it yourself if you want). Hunters and
Fisherdwarves are set to "Nobody does this", and the Engravers default borrows the
stonecutters icon -- neither touches assignments. Idempotent.

Each craft borrows a recognizable built-in icon (smithing -> engravers; furnace/burner/
mason -> haulers; gem cutter/setter + mechanic -> orderlies; ...). DF has no dedicated
craft icons; the CUSTOM_1..CUSTOM_8 art slots remain a later option for true custom art.

Data: Work Details live in `df.global.plotinfo.labor_info.work_details`; each has `name`,
`allowed_labors` (a unit_labor bitfield), `flags.mode` (a `work_detail_mode`),
`assigned_units`, and `icon` (a `work_detail_icon_type`).
]]

-- ordered crafting set: priority crafts first, then the missing moodables.
-- icon = a built-in work_detail_icon_type borrowed as a recognizable glyph.
local GROUPS = {
    {name = 'Weaponsmithing',   labors = {'FORGE_WEAPON'},    icon = 'ENGRAVERS'},
    {name = 'Armorsmithing',    labors = {'FORGE_ARMOR'},     icon = 'ENGRAVERS'},
    {name = 'Metal crafting',   labors = {'METAL_CRAFT'},     icon = 'ENGRAVERS'},
    {name = 'Metalsmithing',    labors = {'FORGE_FURNITURE'}, icon = 'ENGRAVERS'},   -- aka Blacksmithing
    {name = 'Stone carving',    labors = {'STONE_CARVER'},    icon = 'STONECUTTERS'},
    {name = 'Carpentry',        labors = {'CARPENTER'},       icon = 'WOODCUTTERS'},
    {name = 'Glassmaker',       labors = {'GLASSMAKER'},      icon = 'ORDERLIES'},
    {name = 'Mechanic',         labors = {'MECHANIC'},        icon = 'ORDERLIES'},   -- was siege operators
    {name = 'Wood crafter',     labors = {'WOOD_CRAFT'},      icon = 'WOODCUTTERS'},
    {name = 'Stone crafter',    labors = {'STONE_CRAFT'},     icon = 'STONECUTTERS'},
    {name = 'Furnace operator', labors = {'SMELT'},           icon = 'HAULERS'},
    {name = 'Wood burner',      labors = {'BURN_WOOD'},       icon = 'HAULERS'},
    {name = 'Mason',            labors = {'MASON'},           icon = 'HAULERS'},
    {name = 'Bone carver',      labors = {'BONE_CARVE'},      icon = 'FISHERMEN'},
    {name = 'Bowyer',           labors = {'BOWYER'},          icon = 'HUNTERS'},
    {name = 'Clothier',         labors = {'CLOTHESMAKER'},    icon = 'PLANT_GATHERERS'},
    {name = 'Gem cutter',       labors = {'CUT_GEM'},         icon = 'ORDERLIES'},   -- was engravers
    {name = 'Gem setter',       labors = {'ENCRUST_GEM'},     icon = 'ORDERLIES'},   -- was engravers
    {name = 'Leatherworker',    labors = {'LEATHER'},         icon = 'HUNTERS'},
    {name = 'Tanner',           labors = {'TANNER'},          icon = 'HUNTERS'},
    {name = 'Weaver',           labors = {'WEAVER'},          icon = 'PLANT_GATHERERS'},
}

-- the military grouping detail (no labor; membership synced by military-labor). Last.
local MILITARY_NAME = 'Military'
local MILITARY_ICON = 'SIEGE_OPERATORS'

-- every moodable skill -> its labor, for the coverage check (Miner/Stonecutter/Engraver
-- ride on kept DF defaults; <none> has no labor). Reporting only.
local MOODABLE = {
    {skill = 'Armorsmith', labor = 'FORGE_ARMOR'}, {skill = 'Bone carver', labor = 'BONE_CARVE'},
    {skill = 'Bowyer', labor = 'BOWYER'}, {skill = 'Carpenter', labor = 'CARPENTER'},
    {skill = 'Clothier', labor = 'CLOTHESMAKER'}, {skill = 'Engraver', labor = 'ENGRAVER'},
    {skill = 'Gem cutter', labor = 'CUT_GEM'}, {skill = 'Gem setter', labor = 'ENCRUST_GEM'},
    {skill = 'Glassmaker', labor = 'GLASSMAKER'}, {skill = 'Leatherworker', labor = 'LEATHER'},
    {skill = 'Mason', labor = 'MASON'}, {skill = 'Mechanic', labor = 'MECHANIC'},
    {skill = 'Metal crafter', labor = 'METAL_CRAFT'}, {skill = 'Metalsmith', labor = 'FORGE_FURNITURE'},
    {skill = 'Miner', labor = 'MINE'}, {skill = 'Stone carver', labor = 'STONE_CARVER'},
    {skill = 'Stone crafter', labor = 'STONE_CRAFT'}, {skill = 'Stonecutter', labor = 'STONECUTTER'},
    {skill = 'Tanner', labor = 'TANNER'}, {skill = 'Weaponsmith', labor = 'FORGE_WEAPON'},
    {skill = 'Weaver', labor = 'WEAVER'}, {skill = 'Wood crafter', labor = 'WOOD_CRAFT'},
}

-- default details, by a representative non-crafting labor, in the order we want them:
local FRONT = {'MINE', 'CUTWOOD', 'PLANT', 'STONECUTTER', 'ENGRAVER'}            -- before crafts
local TAIL  = {'HUNT', 'FISH', 'HERBALIST', 'HAUL_STONE', 'RECOVER_WOUNDED', 'SIEGEOPERATE'}  -- after
local FORCE_NOBODY = {HUNT = true, FISH = true}   -- these defaults -> "Nobody does this"
local DEFAULT_ICON = {ENGRAVER = 'STONECUTTERS'}  -- the Engravers default borrows this glyph

if not dfhack.world.isFortressMode() then qerror('labor-groups only works in fortress mode') end

local arg = ({...})[1]
local dry = arg == 'dry'
local once = arg == 'once'

local PERSIST_KEY = 'labor-groups'
if once then
    local st = dfhack.persistent.getSiteData(PERSIST_KEY)
    if st and st.applied then
        print('labor-groups: already applied to this fort -- skipping (run `labor-groups` to force)')
        return
    end
end

local wd = df.global.plotinfo.labor_info.work_details

-- labors the crafting set owns; a detail is "a craft" only if all its labors are managed.
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
local function is_craft(w)
    local labs = labors_of(w)
    if #labs == 0 then return false end
    for _, l in ipairs(labs) do if not managed[l] then return false end end
    return true
end

-- the mode/icon a kept DEFAULT detail should end up with (no assignment changes)
local function planned_mode(w)
    for L in pairs(FORCE_NOBODY) do if w.allowed_labors[L] then return df.work_detail_mode.NobodyDoesThis end end
    return w.flags.mode
end
local function default_icon(w)
    for L, ic in pairs(DEFAULT_ICON) do if w.allowed_labors[L] then return df.work_detail_icon_type[ic] end end
    return w.icon
end

-- Resolve the final order as a list of indices into wd (existing) plus "new" specs,
-- WITHOUT mutating. Each entry: {idx=<int> | nil, name, icon_name, mode_name, status}.
-- Shared by the dry preview and the live apply so both agree.
local function plan()
    local by_name = {}
    for i = 0, #wd - 1 do by_name[wd[i].name] = i end
    local placed, rows = {}, {}
    local function take_by_labor(L)
        for i = 0, #wd - 1 do
            if not placed[i] and not is_craft(wd[i]) and wd[i].allowed_labors[L] then placed[i] = true; return i end
        end
    end
    local function add_default(i)
        local w = wd[i]
        rows[#rows + 1] = {idx = i, name = w.name, icon_name = df.work_detail_icon_type[default_icon(w)],
                           mode_name = df.work_detail_mode[planned_mode(w)], status = 'kept'}
    end
    for _, L in ipairs(FRONT) do local i = take_by_labor(L); if i then add_default(i) end end
    for _, g in ipairs(GROUPS) do
        local i = by_name[g.name]
        if i and not placed[i] then
            placed[i] = true
            rows[#rows + 1] = {idx = i, name = g.name, icon_name = g.icon,
                               mode_name = df.work_detail_mode[wd[i].flags.mode], status = 'kept'}
        else
            rows[#rows + 1] = {name = g.name, icon_name = g.icon, mode_name = 'EverybodyDoesThis', status = 'NEW'}
        end
    end
    for _, L in ipairs(TAIL) do local i = take_by_labor(L); if i then add_default(i) end end
    local mil_idx = by_name[MILITARY_NAME]
    if mil_idx then placed[mil_idx] = true end                  -- reserve military for last
    for i = 0, #wd - 1 do                                       -- any other details
        if not placed[i] then placed[i] = true
            local w = wd[i]
            rows[#rows + 1] = {idx = i, name = w.name, icon_name = df.work_detail_icon_type[w.icon],
                               mode_name = df.work_detail_mode[w.flags.mode], status = 'kept'}
        end
    end
    if mil_idx then
        rows[#rows + 1] = {idx = mil_idx, name = MILITARY_NAME, icon_name = MILITARY_ICON,
                           mode_name = df.work_detail_mode[wd[mil_idx].flags.mode], status = 'kept', military = true}
    else
        rows[#rows + 1] = {name = MILITARY_NAME, icon_name = MILITARY_ICON,
                           mode_name = 'OnlySelectedDoesThis', status = 'NEW', military = true}
    end
    return rows
end

local rows = plan()

if not dry then
    -- build the ordered list of handles (existing kept; create only the NEW ones),
    -- applying icon/mode tweaks in place. assigned_units is never touched.
    local order = {}
    for _, r in ipairs(rows) do
        local h
        if r.idx then
            h = wd[r.idx]
            h.icon = df.work_detail_icon_type[r.icon_name]
            if not r.military then h.flags.mode = df.work_detail_mode[r.mode_name] end
        else
            h = df.work_detail:new()
            h.name = r.name
            if r.military then
                h.flags.mode = df.work_detail_mode.OnlySelectedDoesThis   -- members synced by military-labor
            else
                h.flags.mode = df.work_detail_mode.EverybodyDoesThis      -- new craft
                for _, g in ipairs(GROUPS) do
                    if g.name == r.name then for _, l in ipairs(g.labors) do h.allowed_labors[l] = true end end
                end
            end
            h.icon = df.work_detail_icon_type[r.icon_name]
        end
        order[#order + 1] = h
    end
    -- ensure each existing craft has its labor enabled (idempotent; additive, no clearing)
    for _, g in ipairs(GROUPS) do
        for i = 0, #wd - 1 do
            if wd[i].name == g.name then for _, l in ipairs(g.labors) do wd[i].allowed_labors[l] = true end end
        end
    end
    -- rewrite the vector in the new order: erase every slot (erase does NOT delete the
    -- object -- we hold each handle), then reinsert. Nothing is freed, nothing is reset.
    for i = #wd - 1, 0, -1 do wd:erase(i) end
    for _, h in ipairs(order) do wd:insert('#', h) end
    dfhack.persistent.saveSiteData(PERSIST_KEY, {applied = true})
end

-- ---- report -----------------------------------------------------------------
print(('labor-groups: %s'):format(dry and 'DRY RUN -- planned layout (no changes made)'
    or 'ordered the Labor screen (assignments preserved)'))
local pos = 0
for _, r in ipairs(rows) do
    pos = pos + 1
    print(('  %2d. %-18s [%-20s] icon=%-15s%s'):format(pos, r.name, r.mode_name, r.icon_name,
        r.status == 'NEW' and '  (new)' or ''))
end

-- moodable coverage (informational): every moodable labor covered by a kept default or craft
local covers = {}
for i = 0, #wd - 1 do
    if not is_craft(wd[i]) then for _, l in ipairs(labors_of(wd[i])) do covers[l] = covers[l] or wd[i].name end end
end
for _, g in ipairs(GROUPS) do for _, l in ipairs(g.labors) do covers[l] = covers[l] or g.name end end
local missing = {}
for _, m in ipairs(MOODABLE) do if not covers[m.labor] then missing[#missing + 1] = m.skill end end
print(#missing == 0 and '  moodable skills: all represented'
    or ('  moodable skills MISSING coverage: ' .. table.concat(missing, ', ')))
