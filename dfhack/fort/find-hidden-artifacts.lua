-- Who has your artifacts: the units carrying one who should not be, and where the missing ones went.
--@module = true
--[[
fort/find-hidden-artifacts

Run by hand. Prints two lists to the DFHack console and changes nothing.

    fort/find-hidden-artifacts

THE FORT'S ARTIFACTS are everything made here, everything ever stored here, everything DF
currently places here and everything the fort's own group has laid a claim on -- read from the
world's history, not from the artifact's current site. That matters: the moment a thief picks
an artifact up DF blanks its site, so a list built from "artifacts at this site" is exactly
the list that forgets the one being carried out of the door.

ON SOMEBODY WHO IS NOT YOURS. Every unit on the map that is not a citizen and has one of the
fort's artifacts on them: how they are holding it (carrying, wearing, in hand as a weapon),
where they are standing, and who they really are. A visitor with a "name" in quotation marks is
wearing a FALSE IDENTITY, and the artifact record and the history know the real one -- so the
line gives the real name, race and profession, their civilization, and every religion, troupe
or company they belong to, because the villains who send agents after artifacts are entities
too and this is where they show. If the theft was witnessed the fort's own announcement is
quoted with its date; if it was not, the line says so, since an artifact that walked out unseen
is the one nobody has raised the alarm about. A resident scholar HAULING a codex is on this list
as well -- reading it in the library looks the same as stealing it until they reach the edge --
so the manner of holding is printed and the judgement is left to you.

Citizens are not listed. A soldier wearing an artifact helm from a uniform, a dwarf who owns
one, and a hauler moving one to a pedestal are all normal, and a list that names them is a list
you stop reading.

Visitors carrying their OWN artifacts (a bard's own scroll, a mercenary's own sword) are counted
in one line at the end of the section rather than listed, so a busy tavern does not bury the
one row that matters.

GONE FROM THE MAP. Every one of the fort's artifacts that is not on the map any more, with the
best answer the world has for where it went, in this order of confidence: destroyed (with the
date); away with one of your own units (a squad on a mission carries its gear); held by a named
figure, with their whereabouts -- at a site, on the road with an army, in a region, or dead;
placed at another site by DF's own record; lost in the wilds of a named region. When the world
has recorded none of those the artifact vanished from the map and DF has not yet caught up --
a thief on the road with it has no history until they arrive -- and the line says so, gives the
last place the item was (a display case, a stockpile, a workshop) and whether anyone saw it go.

Under each missing artifact, and each one on a stranger, are the CLAIMS: every historical
figure outside your civilization who has laid claim to it, with their whereabouts. Claims are
how the world decides who comes for an artifact, so a missing crown claimed last spring by an
elf trapper who now lives at a site a week away is a crown you can go and fetch.

One pass over the whole unit list, once, which is why this is a command and not an overlay:
DF drops a visitor from the active list the moment they reach the map edge, while they still
stand on it with the artifact in hand, and that is the one unit this command exists to name.
]]

local T = dfhack.translation.translateName

local function con(s) return dfhack.df2console(s or '') end

local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
                'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}

-- "12th Galena, 129" from a year and a tick into it; a tick of -1 (worldgen) gives just the year
local function date(year, tick)
    if not tick or tick < 0 then return ('%d'):format(year) end
    local month = math.floor(tick / 33600) + 1
    local day = math.floor((tick % 33600) / 1200) + 1
    local suffix = 'th'
    if day % 10 == 1 and day ~= 11 then suffix = 'st'
    elseif day % 10 == 2 and day ~= 12 then suffix = 'nd'
    elseif day % 10 == 3 and day ~= 13 then suffix = 'rd' end
    return ('%d%s %s, %d'):format(day, suffix, MONTHS[month] or '?', year)
end

-- ---- naming things --------------------------------------------------------------------

local function race_name(race)
    local raw = df.creature_raw.find(race)
    return raw and raw.name[0] or 'creature'
end

local function profession_name(prof)
    local name = df.profession[prof] or 'unknown'
    return name:lower():gsub('_', ' ')
end

local function entity_name(id)
    local ent = df.historical_entity.find(id)
    if not ent then return ('entity #%d'):format(id) end
    local name = T(ent.name, true)
    return name ~= '' and name or ('entity #%d'):format(id)
end

local function entity_kind(ent)
    local kind = df.historical_entity_type[ent.type] or 'group'
    return kind:gsub('(%l)(%u)', '%1 %2'):lower()
end

local function site_desc(id)
    local site = df.world_site.find(id)
    if not site then return ('site #%d'):format(id) end
    local name = T(site.name, true)
    if name == '' then name = ('site #%d'):format(id) end
    local kind = (df.world_site_type[site.type] or 'site'):gsub('(%l)(%u)', '%1 %2'):lower()
    local owner = site.civ_id ~= -1 and (' of ' .. entity_name(site.civ_id)) or ''
    return ('%s, a %s%s'):format(name, kind, owner)
end

local function region_desc(id)
    local region = df.global.world.world_data.regions[id]
    if not region then return ('region #%d'):format(id) end
    local name = T(region.name, true)
    return name ~= '' and name or ('region #%d'):format(id)
end

local function hf_desc(hf)
    local civ = hf.civ_id ~= -1 and (' of ' .. entity_name(hf.civ_id)) or ''
    return ('%s, %s %s%s'):format(T(hf.name), race_name(hf.race), profession_name(hf.profession), civ)
end

-- Where the world says a figure is. Whereabouts are only kept for figures off the map.
local function hf_whereabouts(hf)
    if hf.died_year ~= -1 then return ('dead since %d'):format(hf.died_year) end
    local w = hf.info and hf.info.whereabouts
    if not w then return 'whereabouts unknown' end
    if w.site_id ~= -1 then return 'at ' .. site_desc(w.site_id) end
    if w.army_id ~= -1 then return 'on the road with an army' end
    if w.subregion_id ~= -1 then return 'in ' .. region_desc(w.subregion_id) end
    return 'whereabouts unknown'
end

-- Every non-civilization group a figure belongs to -- religions, troupes, companies. The
-- villains who send agents are entities like these, so the memberships are what to read.
local function hf_memberships(hf)
    local out = {}
    for _, link in ipairs(hf.entity_links) do
        if link:getType() == df.histfig_entity_link_type.MEMBER then
            local ent = df.historical_entity.find(link.entity_id)
            if ent and ent.type ~= df.historical_entity_type.Civilization
                    and ent.type ~= df.historical_entity_type.SiteGovernment then
                out[#out + 1] = ('%s (%s)'):format(entity_name(ent.id), entity_kind(ent))
            end
        end
    end
    return out
end

local function artifact_name(a)
    local name = T(a.name)
    if name == '' then name = ('artifact #%d'):format(a.id) end
    return name
end

-- "Ashoknothis, cherry wood bracelet" -- but a codex describes itself by its title already
local function artifact_line(a)
    local item = a.item
    local what = item and dfhack.items.getDescription(item, 0) or 'unknown item'
    local name = artifact_name(a)
    if what:find(name, 1, true) then return what end
    return ('%s, %s'):format(name, what)
end

local HOLDING = {
    Hauled = 'carried', Weapon = 'held in hand', Worn = 'worn', Strapped = 'strapped on',
    Flask = 'carried as a flask', WrappedAround = 'wrapped around', Piercing = 'worn as a piercing',
    InMouth = 'held in the mouth', SewnInto = 'sewn in', Nocked = 'nocked',
}
local function holding(mode)
    local name = df.inv_item_role_type[mode]
    return HOLDING[name] or ('held (' .. tostring(name) .. ')')
end

-- ---- the world's memory of the fort's artifacts -----------------------------------------

-- One pass over history, comparing type ids only: a name lookup or is_instance per event turns
-- 0.1s into 14s on a 280k-event world.
local function read_history(fort_site)
    local E = df.history_event_type
    local mine, created, destroyed, claims = {}, {}, {}, {}
    local ev = df.global.world.history.events
    for i = 0, #ev - 1 do
        local e = ev[i]
        local t = e:getType()
        if t == E.ARTIFACT_CREATED then
            if e.site == fort_site then
                mine[e.artifact_id] = true
                created[e.artifact_id] = {year = e.year, tick = e.seconds}
            end
        elseif t == E.ARTIFACT_STORED then
            if e.site == fort_site then mine[e.artifact] = true end
        elseif t == E.ARTIFACT_DESTROYED then
            destroyed[e.artifact] = {year = e.year, tick = e.seconds, site = e.site, hf = e.destroyer_hf}
        elseif t == E.ARTIFACT_CLAIM_FORMED then
            local list = claims[e.artifact]
            if not list then list = {}; claims[e.artifact] = list end
            list[#list + 1] = {hf = e.histfig, entity = e.entity, kind = e.claim_type,
                               year = e.year, tick = e.seconds}
        end
    end
    return mine, created, destroyed, claims
end

-- The fort's artifacts: made here, ever stored here, placed here now, or claimed by the group.
local function fort_artifacts(mine, fort_site, group_id)
    local list = {}
    for _, a in ipairs(df.global.world.artifacts.all) do
        local own = mine[a.id] or a.site == fort_site or a.storage_site == fort_site
        if not own then
            for _, ent in ipairs(a.entity_claims) do
                if ent == group_id then own = true; break end
            end
        end
        if own then list[#list + 1] = a end
    end
    return list
end

-- "<name> was seen being stolen!" announcements, by artifact name; the fort's only alarm.
local function theft_reports()
    local out = {}
    for _, r in ipairs(df.global.world.status.reports) do
        local name = r.text:match('^(.-) was seen being stolen!$')
        if name then out[name] = r end
    end
    return out
end

local function artifact_of(item)
    local ref = dfhack.items.getGeneralRef(item, df.general_ref_type.IS_ARTIFACT)
    return ref and df.artifact_record.find(ref.artifact_id)
end

-- ---- printing ----------------------------------------------------------------------------

-- Claims are cheap: the rumour system hands one to every figure who hears of the artifact,
-- so a two-year-old crown has sixty. The count says how widely it is coveted; the newest few
-- living claimants are the ones still in a position to act on it.
local function print_claims(a, claims, our_civ, indent)
    local list = claims[a.id]
    if not list then return end
    local foreign, seen = {}, {}
    for _, claim in ipairs(list) do
        local hf = df.historical_figure.find(claim.hf)
        if hf and hf.civ_id ~= our_civ and not seen[claim.hf] then
            seen[claim.hf] = true
            foreign[#foreign + 1] = {hf = hf, claim = claim}
        end
    end
    if #foreign == 0 then return end
    local living = 0
    for _, f in ipairs(foreign) do if f.hf.died_year == -1 then living = living + 1 end end
    print(('%sclaimed by %d foreign figure%s, %d of them alive; the newest:'):format(indent, #foreign,
          #foreign == 1 and '' or 's', living))
    local shown = 0
    for i = #foreign, 1, -1 do
        local f = foreign[i]
        if f.hf.died_year == -1 then
            shown = shown + 1
            local kind = (df.artifact_claim_type[f.claim.kind] or 'claim'):lower()
            print(('%s    as a %s on %s: %s -- %s'):format(indent, kind, date(f.claim.year, f.claim.tick),
                  con(hf_desc(f.hf)), con(hf_whereabouts(f.hf))))
            local groups = hf_memberships(f.hf)
            if #groups > 0 then print(('%s        member of %s'):format(indent, con(table.concat(groups, '; ')))) end
            if shown == 3 then break end
        end
    end
end

local function print_theft(name, reports, indent, still_here)
    local r = reports[name]
    if r then
        print(('%sseen being stolen on %s: "%s"'):format(indent, date(r.year, r.time), con(r.text)))
    elseif still_here then
        print(indent .. 'no theft has been announced')
    else
        print(indent .. 'nobody saw it go')
    end
end

-- Where an item was before it left the map, from the references it still carries.
local function last_seen(item)
    for _, ref in ipairs(item.general_refs) do
        local t = ref:getType()
        if t == df.general_ref_type.BUILDING_DISPLAY_FURNITURE or t == df.general_ref_type.BUILDING_HOLDER then
            local bld = df.building.find(ref.building_id)
            if bld then
                return ('on a %s at (%d, %d, %d)'):format(con(dfhack.buildings.getName(bld)):lower(),
                                                        bld.centerx, bld.centery, bld.z)
            end
        end
    end
    if item.pos.x >= 0 then return ('at (%d, %d, %d)'):format(item.pos.x, item.pos.y, item.pos.z) end
    return 'at no recorded place'
end

-- Every unit in the world list carrying one of the fort's artifacts, by artifact id. This is
-- the one whole-list pass, and it is why the command is run by hand: `units.active` drops a
-- visitor the moment they reach the map edge, while they still stand on it with the artifact
-- in hand, and a squad away on a mission is in this list and nowhere else.
local function holders_of(ours)
    local wanted = {}
    for _, a in ipairs(ours) do if a.item then wanted[a.item.id] = a.id end end
    local out = {}
    for _, u in ipairs(df.global.world.units.all) do
        if not dfhack.units.isDead(u) then
            for _, inv in ipairs(u.inventory) do
                local aid = wanted[inv.item.id]
                if aid then out[aid] = {unit = u, mode = inv.mode} end
            end
        end
    end
    return out
end

-- a unit still standing on the map: a real position, and not yet removed from play
local function on_map(u)
    return u.pos.x >= 0 and dfhack.units.isActive(u)
end

local function print_missing(a, ctx)
    local item = a.item
    print(('  %s'):format(con(artifact_line(a))))
    local made = ctx.created[a.id]
    if made then print(('      made here on %s'):format(date(made.year, made.tick))) end
    local gone = ctx.destroyed[a.id]
    local holder = ctx.holders[a.id]
    local hf = a.holder_hf ~= -1 and df.historical_figure.find(a.holder_hf)
    if gone then
        local where = gone.site ~= -1 and (' at ' .. site_desc(gone.site)) or ''
        local by = gone.hf ~= -1 and df.historical_figure.find(gone.hf)
        print(('      DESTROYED on %s%s%s'):format(date(gone.year, gone.tick), con(where),
              by and (' by ' .. con(hf_desc(by))) or ''))
    elseif holder and not on_map(holder.unit) then
        local who = dfhack.units.getReadableName(holder.unit)
        if dfhack.units.isCitizen(holder.unit, true) then
            print(('      away with %s, one of your own -- off the map on a mission (%s)'):format(
                  con(who), holding(holder.mode)))
        else
            print(('      off the map with %s (%s)'):format(con(who), holding(holder.mode)))
        end
    elseif hf then
        print(('      held by %s -- %s'):format(con(hf_desc(hf)), con(hf_whereabouts(hf))))
        local groups = hf_memberships(hf)
        if #groups > 0 then print(('          member of %s'):format(con(table.concat(groups, '; ')))) end
    elseif a.site ~= -1 and a.site ~= ctx.fort_site then
        print(('      at %s'):format(con(site_desc(a.site))))
    elseif a.storage_site ~= -1 and a.storage_site ~= ctx.fort_site then
        print(('      stored at %s'):format(con(site_desc(a.storage_site))))
    elseif a.loss_region ~= -1 then
        print(('      lost in the wilds of %s'):format(con(region_desc(a.loss_region))))
    else
        print('      gone from the map; the world has not yet recorded where it went')
        if item then print(('      last %s'):format(last_seen(item))) end
        print_theft(artifact_name(a), ctx.reports, '      ')
    end
    print_claims(a, ctx.claims, ctx.our_civ, '      ')
end

-- ---- main --------------------------------------------------------------------------------

function run()
    if not dfhack.world.isFortressMode() then
        qerror('fort/find-hidden-artifacts needs a loaded fortress')
    end
    local fort_site = df.global.plotinfo.site_id
    local group_id = df.global.plotinfo.group_id
    local our_civ = df.global.plotinfo.civ_id

    local mine, created, destroyed, claims = read_history(fort_site)
    local ours = fort_artifacts(mine, fort_site, group_id)
    local is_ours = {}
    for _, a in ipairs(ours) do is_ours[a.id] = true end
    local reports = theft_reports()

    local holders = holders_of(ours)

    -- ---- on the map, on somebody who is not a citizen ----
    print(('The fort has %d artifacts on record.'):format(#ours))
    print('')
    print('ON SOMEBODY WHO IS NOT YOURS')
    local strangers = 0
    local by_id = {}
    for aid in pairs(holders) do by_id[#by_id + 1] = aid end
    table.sort(by_id)
    for _, aid in ipairs(by_id) do
        local h = holders[aid]
        local u = h.unit
        if on_map(u) and not dfhack.units.isCitizen(u, true) then
            local a = df.artifact_record.find(aid)
            strangers = strangers + 1
            local hf = df.historical_figure.find(u.hist_figure_id)
            local identity = dfhack.units.getIdentity(u)
            local kind = dfhack.units.isVisitor(u) and 'visitor'
                or dfhack.units.isMerchant(u) and 'merchant'
                or dfhack.units.isInvader(u) and 'invader'
                or dfhack.units.isResident(u) and 'resident' or 'not one of yours'
            local leaving = u.idle_area_type == df.unit_station_type.HeadForEdge
            print(('  %s'):format(con(artifact_line(a))))
            print(('      %s by %s (%s) at (%d, %d, %d)%s'):format(holding(h.mode),
                  con(dfhack.units.getReadableName(u)), kind, u.pos.x, u.pos.y, u.pos.z,
                  leaving and ' -- HEADING FOR THE MAP EDGE' or ''))
            if identity and hf then
                print(('      FALSE IDENTITY -- really %s'):format(con(hf_desc(hf))))
            elseif hf then
                print(('      %s'):format(con(hf_desc(hf))))
            end
            if hf then
                local groups = hf_memberships(hf)
                if #groups > 0 then print(('          member of %s'):format(con(table.concat(groups, '; ')))) end
                -- the thief who laid a claim first is the one who came for it on purpose
                for _, claim in ipairs(claims[aid] or {}) do
                    if claim.hf == hf.id then
                        print(('      they laid claim to it themselves, as a %s, on %s'):format(
                              (df.artifact_claim_type[claim.kind] or 'claim'):lower(), date(claim.year, claim.tick)))
                        break
                    end
                end
            end
            print_theft(artifact_name(a), reports, '      ', not leaving)
            print_claims(a, claims, our_civ, '      ')
        end
    end
    if strangers == 0 then print('  none') end

    -- visitors carrying their own artifacts: counted, not listed
    local own_count = 0
    for _, u in ipairs(df.global.world.units.active) do
        if on_map(u) and not dfhack.units.isCitizen(u, true) and not dfhack.units.isDead(u) then
            for _, inv in ipairs(u.inventory) do
                if inv.item.flags.artifact then
                    local a = artifact_of(inv.item)
                    if a and not is_ours[a.id] then own_count = own_count + 1 end
                end
            end
        end
    end
    if own_count > 0 then
        print(('  (%d more on the map: visitors\' own artifact%s, not listed)')
              :format(own_count, own_count == 1 and '' or 's'))
    end

    -- ---- gone from the map ----
    local missing = {}
    for _, a in ipairs(ours) do
        local h = holders[a.id]
        local away = not a.item or dfhack.items.getPosition(a.item) == nil or (h and not on_map(h.unit))
        if away then missing[#missing + 1] = a end
    end
    print('')
    print('GONE FROM THE MAP')
    if #missing == 0 then
        print('  none -- every artifact on record is here')
        return
    end
    local ctx = {
        fort_site = fort_site, our_civ = our_civ, created = created, destroyed = destroyed,
        claims = claims, reports = reports, holders = holders,
    }
    table.sort(missing, function(x, y) return x.id < y.id end)
    for _, a in ipairs(missing) do print_missing(a, ctx) end
end

if not dfhack_flags.module then run() end
