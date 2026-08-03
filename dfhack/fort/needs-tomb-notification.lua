-- Adds a "needs a tomb" notification + a dead-dwarf family/info browser.
--@module = true
--[[
Registers a custom notification (name: "needs_tomb") into DFHack's gui/notify
overlay: it alerts when fortress dwarves have died and are not at rest -- a loose
corpse (not interred), OR walking as a GHOST -- and have not been memorialized:
    * exactly one  -> "Urist McMiner needs a tomb!"
    * more than one -> "2 dwarves need tombs!"

Clicking the notification opens the DEAD BROWSER, a two-pane window:
    * LEFT: your dead, in two sections -- "Needs a tomb" then "Entombed"
      (dwarves already at rest in a coffin).
    * RIGHT: the selected dwarf's information -- profession, when/how they died,
      notable skills, kills, and their RELATIVES (parents, spouse, children,
      siblings, lovers). Click a relative to follow the family tree to them
      (living or dead); Back returns.
    * A "Go to corpse" button zooms the map to the selected dwarf's remains.
    * "Engrave memorial slabs for all needing" queues a memorial slab (manager
      work order) for everyone in the needs-a-tomb section.

The same browser is reachable from the vanilla Units screen's Dead/Missing tab
via a "Family & info" button (overlay `needs-tomb-notification.deceased`).

Run once per DFHack session to register (or add `needs-tomb-notification` to
dfhack-config/init/dfhack.init). Enable the overlay with `overlay rescan` once.
]]

local NAME = 'needs_tomb'

local dlg = require('gui.dialogs')
local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

-- ---------------------------------------------------------------------------
-- detection
-- ---------------------------------------------------------------------------

local function unit_display_name(u)
    return dfhack.translation.translateName(dfhack.units.getVisibleName(u))
end

-- Cache the scan so the ~1/second notification refresh doesn't re-walk every corpse each time.
local SCAN_TTL_MS = 60000
local cache = {frame = nil, t = nil, result = nil}

-- Only SAPIENT (CAN_LEARN) creatures become ghosts / get tombs.
local function is_sapient(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    return caste ~= nil and caste.flags.CAN_LEARN or false
end

-- First cheap cut: drop dead attackers / undead / wild creatures before the membership test.
local function ghost_risk(u)
    return u.civ_id and u.civ_id >= 0
        and not dfhack.units.isInvader(u) and not dfhack.units.isOpposedToLife(u)
end

-- Fort membership never changes once a unit is dead, and `isOwnGroup` is a comparatively
-- expensive call (~140ms across a 1600-unit world), so the answer is remembered per unit id.
local member_cache = {}
local function is_fort_member(u)
    local v = member_cache[u.id]
    if v == nil then
        v = dfhack.units.isOwnGroup(u) or false
        member_cache[u.id] = v
    end
    return v
end

-- Full scan: corpses, corpse-less dead, and ghosts, then derives the two lists plus a
-- unit-id -> corpse-position map (for jumping to a relative's remains).
-- Returns (and caches) {needs_tomb=<list>, entombed=<list>, pos_by_unit=<map>}.
local function scan()
    local fc = df.global.world.frame_counter or 0
    local now = dfhack.getTickCount()
    if cache.result and (fc == cache.frame or (cache.t and now - cache.t < SCAN_TTL_MS)) then
        cache.frame = fc
        return cache.result
    end

    -- Memorial slabs, keyed by the historical figure they name. ENGRAVED and BUILT are kept
    -- apart: an engraved slab means the memorial already exists (don't queue another), but
    -- only a BUILT one actually lays the dead to rest.
    local slab_built, slab_engraved = {}, {}
    for _, it in ipairs(df.global.world.items.other.SLAB) do
        if it.engraving_type == df.slab_engraving_type.Memorial
            and it.topic and it.topic >= 0
            and not (it.flags.garbage_collect or it.flags.removed)
        then
            slab_engraved[it.topic] = true
            if it.flags.in_building then slab_built[it.topic] = true end
        end
    end

    -- per dead unit: interred part / loose part / positions / ghost
    local info, order = {}, {}
    local function rec_for(u)
        local rec = info[u.id]
        if not rec then
            rec = {unit = u, buried = false, unburied = false, pos = nil, bpos = nil,
                   ghostly = u.flags3.ghostly}
            info[u.id] = rec
            table.insert(order, u.id)
        end
        return rec
    end

    -- Corpses, via the TYPED vectors rather than items.other.IN_PLAY: 500-odd items instead
    -- of ~9500 for exactly the same answer.
    for _, vec in ipairs({df.global.world.items.other.CORPSE,
                          df.global.world.items.other.CORPSEPIECE}) do
        for _, it in ipairs(vec) do
            if not (it.flags.garbage_collect or it.flags.removed) then
                local uid = it.unit_id
                local u = uid and uid >= 0 and df.unit.find(uid)
                if u and dfhack.units.isDead(u) and is_sapient(u) and ghost_risk(u) then
                    local rec = rec_for(u)
                    local x, y, z = dfhack.items.getPosition(it)
                    if it.flags.in_building then
                        rec.buried = true                 -- in a coffin
                        if not rec.bpos and x then rec.bpos = xyz2pos(x, y, z) end
                    else
                        rec.unburied = true
                        if not rec.pos and x then rec.pos = xyz2pos(x, y, z) end
                    end
                end
            end
        end
    end

    -- Dead fort members with NO CORPSE AT ALL -- killed off-site on a raid, eaten, or burned
    -- up. A corpse-driven scan can never see them, which is exactly where this list used to
    -- fall short of DF's own "needs a memorial" filter, and they are the people a memorial
    -- slab is *for*: with no body, engraving is the only way to lay them to rest.
    -- `flags2.killed` is a raw field read (~1ms across every unit in the world) while
    -- dfhack.units.isDead() is a call costing 150x that, so the flag is the first cut and the
    -- real tests only run on what survives it.
    for _, u in ipairs(df.global.world.units.all) do
        if (u.flags2.killed or u.flags3.ghostly) and not info[u.id]
            and is_sapient(u) and is_fort_member(u) and dfhack.units.isDead(u)
        then
            rec_for(u)
        end
    end

    -- GHOSTS: any ghost on the map is not at rest, whatever the burial state.
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags3.ghostly and dfhack.units.isDead(u) and is_sapient(u) then
            local rec = rec_for(u)
            rec.ghostly = true
            if not rec.pos then
                local x, y, z = dfhack.units.getPosition(u)
                if x then rec.pos = xyz2pos(x, y, z) end
            end
        end
    end

    local pos_by_unit = {}
    local needs_tomb, entombed = {}, {}
    for _, uid in ipairs(order) do
        local rec = info[uid]
        local hf = rec.unit.hist_figure_id
        -- Match DF's own memorial list: fort MEMBERS, not everyone sharing our civilization.
        -- A dead caravan guard or visiting civ member is not ours to bury, and this world has
        -- ~145 such dead against 51 of our own.
        local belongs = is_fort_member(rec.unit)
        pos_by_unit[uid] = rec.pos or rec.bpos
        local entry = {
            unit_id = uid, hf = hf,
            name = unit_display_name(rec.unit),
            pos = rec.pos or rec.bpos,
        }
        -- A ghost is not at rest however its body lies -- only a BUILT slab settles one.
        local at_rest = rec.ghostly and slab_built[hf] or (not rec.ghostly and (rec.buried or slab_built[hf]))
        if belongs and not at_rest then
            table.insert(needs_tomb, entry)
        elseif belongs and rec.buried then
            -- at rest in a coffin and not on the needs list = entombed
            table.insert(entombed, entry)
        end
    end
    table.sort(entombed, function(a, b) return a.name < b.name end)

    cache.frame = fc
    cache.t = now
    cache.result = {needs_tomb = needs_tomb, entombed = entombed, pos_by_unit = pos_by_unit}
    return cache.result
end

-- ---------------------------------------------------------------------------
-- cause of death
-- ---------------------------------------------------------------------------

local DEATH_PHRASE = {
    OLD_AGE='died of old age', HUNGER='starved to death', THIRST='died of thirst',
    BLEED='bled to death', DROWN='drowned', SUFFOCATION='suffocated',
    STRUCK_DOWN='was struck down', SCALD='was scalded to death',
    BURNED='burned to death', FIRE='burned to death', MAGMA='burned in magma',
    COLD='froze to death', FREEZING='froze to death', HEAT='died of heat',
    CAVEIN='was crushed by a cave-in', INFECTION='died of infection',
    VOMIT_BLOOD='succumbed to bleeding',
}

local function slayer_str(name, raceidx)
    local racenoun
    if raceidx and raceidx >= 0 then
        local cr = df.global.world.raws.creatures.all[raceidx]
        if cr then racenoun = cr.name[0] end
    end
    if name and #name > 0 then
        return racenoun and (name .. ' the ' .. racenoun) or name
    elseif racenoun then
        return 'a ' .. racenoun
    end
end

local function cause_phrase(death_cause)
    local cn = df.death_type[death_cause]
    if cn and DEATH_PHRASE[cn] then return DEATH_PHRASE[cn] end
    if cn then return (cn:lower():gsub('_', ' ')) end
end

local function describe_death_event(ev)
    local name, raceidx
    if ev.slayer_hf and ev.slayer_hf >= 0 then
        local sh = df.historical_figure.find(ev.slayer_hf)
        if sh then
            name = dfhack.translation.translateName(sh.name)
            raceidx = sh.race
        end
    end
    if (not raceidx or raceidx < 0) and ev.slayer_race and ev.slayer_race >= 0 then
        raceidx = ev.slayer_race
    end
    local slayer = slayer_str(name, raceidx)
    if slayer then return 'slain by ' .. slayer end
    return cause_phrase(ev.death_cause) or 'cause of death unknown'
end

local function describe_incident(inc)
    local name, raceidx
    if inc.criminal and inc.criminal >= 0 then
        local cu = df.unit.find(inc.criminal)
        if cu then
            name = dfhack.translation.translateName(dfhack.units.getVisibleName(cu))
            raceidx = cu.race
        end
    end
    if (not raceidx or raceidx < 0) and inc.criminal_race and inc.criminal_race >= 0 then
        raceidx = inc.criminal_race
    end
    local slayer = slayer_str(name, raceidx)
    if slayer then return 'slain by ' .. slayer end
    return cause_phrase(inc.death_cause) or 'cause of death unknown'
end

local PLACEHOLDER_CAUSE = {}
if df.death_type.MEMORIALIZE then PLACEHOLDER_CAUSE[df.death_type.MEMORIALIZE] = true end
local function meaningful_cause(dc) return dc ~= nil and dc >= 0 and not PLACEHOLDER_CAUSE[dc] end

-- batch: fill killed_by for a whole list in one pass (for the left-hand rows)
local function attach_death_info(list)
    local by_hf, by_unit, remaining = {}, {}, 0
    for _, e in ipairs(list) do
        e.killed_by = nil
        by_unit[e.unit_id] = e
        if e.hf and e.hf >= 0 then by_hf[e.hf] = e end
        remaining = remaining + 1
    end
    local events = df.global.world.history.events
    for i = #events - 1, 0, -1 do
        if remaining <= 0 then break end
        local ev = events[i]
        if df.history_event_hist_figure_diedst:is_instance(ev) then
            local e = by_hf[ev.victim_hf]
            if e and not e.killed_by and meaningful_cause(ev.death_cause) then
                e.killed_by = describe_death_event(ev)
                remaining = remaining - 1
            end
        end
    end
    if remaining > 0 then
        local incidents = df.global.world.incidents.all
        for i = #incidents - 1, 0, -1 do
            if remaining <= 0 then break end
            local inc = incidents[i]
            if inc.type == df.incident_type.Death then
                local e = by_unit[inc.victim]
                if e and not e.killed_by and meaningful_cause(inc.death_cause) then
                    e.killed_by = describe_incident(inc)
                    remaining = remaining - 1
                end
            end
        end
    end
    for _, e in ipairs(list) do
        if not e.killed_by then e.killed_by = 'cause of death unknown' end
    end
end

-- single figure (for a relative navigated to on demand)
local function cause_for(hf, unit_id)
    local events = df.global.world.history.events
    for i = #events - 1, 0, -1 do
        local ev = events[i]
        if df.history_event_hist_figure_diedst:is_instance(ev)
            and ev.victim_hf == hf and meaningful_cause(ev.death_cause) then
            return describe_death_event(ev)
        end
    end
    if unit_id and unit_id >= 0 then
        local incs = df.global.world.incidents.all
        for i = #incs - 1, 0, -1 do
            local inc = incs[i]
            if inc.type == df.incident_type.Death and inc.victim == unit_id
                and meaningful_cause(inc.death_cause) then
                return describe_incident(inc)
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- memorial slab manager orders (unchanged)
-- ---------------------------------------------------------------------------

local function has_pending_slab_order(hf)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == df.job_type.EngraveSlab and o.specdata.hist_figure_id == hf then
            return true
        end
    end
    return false
end

local function has_engraved_slab(hf)
    local vec = df.global.world.items.other.IN_PLAY
    for i = 0, #vec - 1 do
        local it = vec[i]
        if it:getType() == df.item_type.SLAB
            and it.engraving_type == df.slab_engraving_type.Memorial
            and it.topic == hf
            and not (it.flags.garbage_collect or it.flags.removed)
        then
            return true
        end
    end
    return false
end

local function create_slab_order(hf)
    local mo = df.global.world.manager_orders
    local o = df.manager_order:new()
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = mo.manager_order_next_id + 1
    o.job_type = df.job_type.EngraveSlab
    o.amount_total = 1
    o.amount_left = 1
    o.frequency = 0
    o.status.validated = true
    o.status.active = true
    o.specdata.hist_figure_id = hf
    mo.all:insert('#', o)
end

local function count_blank_slabs()
    local n = 0
    local vec = df.global.world.items.other.IN_PLAY
    for i = 0, #vec - 1 do
        local it = vec[i]
        if it:getType() == df.item_type.SLAB
            and it.engraving_type == df.slab_engraving_type.Slab
            and not (it.flags.garbage_collect or it.flags.removed)
        then
            n = n + 1
        end
    end
    return n
end

local function count_slab_orders()
    local engrave, make = 0, 0
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == df.job_type.EngraveSlab then engrave = engrave + o.amount_left
        elseif o.job_type == df.job_type.ConstructSlab then make = make + o.amount_left end
    end
    return engrave, make
end

local function create_make_slab_order(amount)
    local mo = df.global.world.manager_orders
    local o = df.manager_order:new()
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = o.id + 1
    o.job_type = df.job_type.ConstructSlab
    o.amount_total = amount
    o.amount_left = amount
    o.frequency = 0
    o.status.validated = true
    o.status.active = true
    mo.all:insert('#', o)
end

local function enqueue_memorial_slabs(list)
    local need, have_slab, have_order = {}, 0, 0
    for _, e in ipairs(list) do
        if e.hf and e.hf >= 0 then
            if has_engraved_slab(e.hf) then have_slab = have_slab + 1
            elseif has_pending_slab_order(e.hf) then have_order = have_order + 1
            else table.insert(need, e) end
        end
    end
    local pending_engrave, pending_make = count_slab_orders()
    local free = count_blank_slabs() - pending_engrave + pending_make
    for i = 1, #need do
        create_slab_order(need[i].hf)
    end
    local shortfall = #need - free
    if shortfall > 0 then create_make_slab_order(shortfall) else shortfall = 0 end
    return #need, shortfall, have_slab, have_order
end

-- ---------------------------------------------------------------------------
-- figure info (profession / death / skills / kills / relatives)
-- ---------------------------------------------------------------------------

local LINK_LABEL = {
    [df.histfig_hf_link_type.FATHER]          = 'Father',
    [df.histfig_hf_link_type.MOTHER]          = 'Mother',
    [df.histfig_hf_link_type.SPOUSE]          = 'Spouse',
    [df.histfig_hf_link_type.DECEASED_SPOUSE] = 'Late spouse',
    [df.histfig_hf_link_type.FORMER_SPOUSE]   = 'Former spouse',
    [df.histfig_hf_link_type.LOVER]           = 'Lover',
    [df.histfig_hf_link_type.CHILD]           = 'Child',
}
local REL_RANK = {Father=1, Mother=2, Spouse=3, ['Late spouse']=3, ['Former spouse']=4,
                  Lover=5, Child=6, Sibling=7}

-- build a figure descriptor from a historical figure id
local function fig_from_hf(hf_id, pos_by_unit)
    local hf = df.historical_figure.find(hf_id)
    local name = hf and dfhack.translation.translateName(hf.name) or '(unknown)'
    local uid, unit = -1, nil
    if hf and hf.unit_id and hf.unit_id >= 0 then
        unit = df.unit.find(hf.unit_id)
        if unit then uid = unit.id end
    end
    local pos = pos_by_unit and pos_by_unit[uid]
    if not pos and unit and not dfhack.units.isDead(unit) then
        local x, y, z = dfhack.units.getPosition(unit)
        if x then pos = xyz2pos(x, y, z) end
    end
    local dead = (hf and hf.died_year and hf.died_year >= 0) or (unit and dfhack.units.isDead(unit)) or false
    return {hf = hf_id, unit_id = uid, name = name, pos = pos, dead = dead}
end

local function fig_from_unit(u, pos_by_unit)
    return {
        hf = u.hist_figure_id, unit_id = u.id,
        name = unit_display_name(u),
        pos = (pos_by_unit and pos_by_unit[u.id]) or (function()
            local x, y, z = dfhack.units.getPosition(u); return x and xyz2pos(x, y, z) or nil end)(),
        dead = dfhack.units.isDead(u),
    }
end

-- parents/spouse/children/lovers from histfig links, siblings derived via parents
local function build_relatives(fig, pos_by_unit)
    local hf = fig.hf and fig.hf >= 0 and df.historical_figure.find(fig.hf)
    if not hf then return {} end
    local out, seen = {}, {}
    local mother, father
    for _, l in ipairs(hf.histfig_links) do
        local ok, ty = pcall(function() return l:getType() end)
        local label = ok and LINK_LABEL[ty]
        local tgt = l.target_hf
        if label and tgt and tgt >= 0 and not seen[label .. ':' .. tgt] then
            seen[label .. ':' .. tgt] = true
            if label == 'Mother' then mother = tgt elseif label == 'Father' then father = tgt end
            out[#out + 1] = {label = label, fig = fig_from_hf(tgt, pos_by_unit)}
        end
    end
    -- siblings: other children of either parent
    for _, phf in ipairs({father, mother}) do
        local p = phf and df.historical_figure.find(phf)
        if p then
            for _, l in ipairs(p.histfig_links) do
                local ok, ty = pcall(function() return l:getType() end)
                if ok and ty == df.histfig_hf_link_type.CHILD then
                    local sib = l.target_hf
                    if sib and sib >= 0 and sib ~= fig.hf and not seen['Sibling:' .. sib] then
                        seen['Sibling:' .. sib] = true
                        out[#out + 1] = {label = 'Sibling', fig = fig_from_hf(sib, pos_by_unit)}
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = REL_RANK[a.label] or 9, REL_RANK[b.label] or 9
        if ra ~= rb then return ra < rb end
        return a.fig.name < b.fig.name
    end)
    return out
end

local function top_skills(u, n)
    if not (u and u.status and u.status.current_soul) then return {} end
    local sk = u.status.current_soul.skills
    local arr = {}
    for i = 0, #sk - 1 do
        local s = sk[i]
        if s.rating and s.rating > 0 then arr[#arr + 1] = s end
    end
    table.sort(arr, function(a, b) return a.rating > b.rating end)
    local out = {}
    for i = 1, math.min(n, #arr) do
        local a = df.job_skill.attrs[arr[i].id]
        out[#out + 1] = ('%s %d'):format(a and a.caption or tostring(arr[i].id), arr[i].rating)
    end
    return out
end

-- returns {info_tokens = <Label text>, relatives = <List choices>}
local function build_figure_info(fig, pos_by_unit)
    local hf = fig.hf and fig.hf >= 0 and df.historical_figure.find(fig.hf)
    local unit = fig.unit_id and fig.unit_id >= 0 and df.unit.find(fig.unit_id)
    local T = {}
    local function line(tokens) for _, t in ipairs(tokens) do T[#T + 1] = t end T[#T + 1] = NEWLINE end
    local L = function(s) return {text = s, pen = COLOR_GRAY} end
    local V = function(s) return {text = s, pen = COLOR_WHITE} end

    line({{text = fig.name, pen = COLOR_YELLOW}})
    if unit then
        line({L('Profession: '), V(dfhack.units.getProfessionName(unit))})
    end

    local cur_year = df.global.cur_year
    local born = hf and hf.born_year
    local died = hf and hf.died_year
    -- Determine death from the LIVE records, not fig.dead: the browser's left-list entries come from
    -- the scan, which carries no `dead` field, so trusting fig.dead rendered every dead dwarf as
    -- "Alive". A recorded death year (died_year >= 0) or a loaded dead unit each mean dead.
    local dead = (hf and hf.died_year and hf.died_year >= 0) or (unit and dfhack.units.isDead(unit)) or false
    if dead then
        local when = (died and died >= 0) and ('year %d'):format(died) or 'unknown'
        local age = (born and born >= 0 and died and died >= 0) and (' (age %d)'):format(died - born) or ''
        line({L('Died: '), V(when .. age)})
        local cause = cause_for(fig.hf, fig.unit_id) or (unit and 'cause of death unknown')
        if cause then line({L('Cause: '), V(cause)}) end
    else
        local age = (born and born >= 0) and (' (age %d)'):format(cur_year - born) or ''
        line({{text = 'Alive' .. age, pen = COLOR_GREEN}})
    end

    if unit then
        local sk = top_skills(unit, 6)
        if #sk > 0 then line({L('Skills: '), V(table.concat(sk, ', '))}) end
        local ok, cd = pcall(reqscript, 'fort/creature-description')
        if ok and cd and cd.kill_summary then
            local okk, ks = pcall(cd.kill_summary, unit)
            if okk and ks and #ks > 0 then line({L('Kills: '), V(ks)}) end
        end
    end

    T[#T + 1] = NEWLINE
    local rels = build_relatives(fig, pos_by_unit)
    local choices = {}
    if #rels == 0 then
        line({{text = 'No recorded relatives.', pen = COLOR_GRAY}})
    else
        for _, r in ipairs(rels) do
            local dead = r.fig.dead
            choices[#choices + 1] = {
                text = {
                    {text = ('%-12s '):format(r.label .. ':'), pen = COLOR_GRAY},
                    {text = r.fig.name, pen = dead and COLOR_GRAY or COLOR_LIGHTGREEN},
                    {text = dead and '  (deceased)' or '  (alive)', pen = COLOR_DARKGRAY},
                },
                fig = r.fig,
            }
        end
    end
    return {info_tokens = T, relatives = choices}
end

-- ---------------------------------------------------------------------------
-- the dead browser
-- ---------------------------------------------------------------------------

local DeadScreen = defclass(DeadScreen, gui.ZScreen)
DeadScreen.ATTRS{
    focus_path = 'needs-tomb/dead',
    needs_list = DEFAULT_NIL,
    entombed_list = DEFAULT_NIL,
    pos_by_unit = DEFAULT_NIL,
    initial = DEFAULT_NIL,   -- optional figure to focus on open
}

function DeadScreen:init()
    self.history = {}
    self.current = nil

    local choices = {}
    local function header(txt)
        choices[#choices + 1] = {text = {{text = txt, pen = COLOR_YELLOW}}, fig = nil, header = true}
    end
    local function none()
        choices[#choices + 1] = {text = {{text = '  (none)', pen = COLOR_GRAY}}, fig = nil, header = true}
    end
    header(('Needs a tomb (%d)'):format(#self.needs_list))
    if #self.needs_list == 0 then none() end
    for _, e in ipairs(self.needs_list) do
        choices[#choices + 1] = {text = ('%s - %s'):format(e.name, e.killed_by or '?'), fig = e}
    end
    header(('Entombed (%d)'):format(#self.entombed_list))
    if #self.entombed_list == 0 then none() end
    for _, e in ipairs(self.entombed_list) do
        choices[#choices + 1] = {text = e.name, fig = e}
    end

    self:addviews{
        widgets.Window{
            frame_title = 'Fortress dead',
            frame = {w = 84, h = 30},
            resizable = true,
            resize_min = {w = 60, h = 18},
            subviews = {
                widgets.List{
                    view_id = 'deadlist',
                    frame = {t = 0, l = 0, w = 34, b = 4},
                    choices = choices,
                    on_select = function(_, choice)
                        if self.subviews.info and choice and choice.fig then
                            self:goto_figure(choice.fig, false)
                        end
                    end,
                },
                widgets.Panel{
                    frame = {t = 0, l = 36, r = 0, b = 4},
                    subviews = {
                        widgets.Label{
                            view_id = 'info',
                            frame = {t = 0, l = 0, r = 0, h = 11},
                            text = '',
                        },
                        widgets.Label{
                            frame = {t = 12, l = 0},
                            text = {{text = 'Relatives (click to follow):', pen = COLOR_GRAY}},
                        },
                        widgets.List{
                            view_id = 'relatives',
                            frame = {t = 13, l = 0, r = 0, b = 0},
                            choices = {},
                            on_submit = function(_, choice)
                                if choice and choice.fig then self:goto_figure(choice.fig, true) end
                            end,
                        },
                    },
                },
                widgets.Label{
                    frame = {b = 3, l = 0},
                    text = {{text = 'Left: pick a dwarf.  Right: click a relative to follow the family.',
                             pen = COLOR_GRAY}},
                },
                widgets.HotkeyLabel{
                    frame = {b = 2, l = 0},
                    key = 'CUSTOM_CTRL_G',
                    auto_width = true,
                    label = 'Go to corpse',
                    on_activate = function() self:goto_corpse() end,
                },
                widgets.HotkeyLabel{
                    frame = {b = 2, l = 22},
                    key = 'CUSTOM_CTRL_B',
                    auto_width = true,
                    label = 'Back',
                    on_activate = function() self:go_back() end,
                },
                widgets.HotkeyLabel{
                    frame = {b = 0, l = 0},
                    key = 'CUSTOM_CTRL_E',
                    auto_width = true,
                    label = ('Engrave memorial slabs for all needing (%d)'):format(#self.needs_list),
                    on_activate = function() self:queue_slabs() end,
                },
            },
        },
    }

    local init = self.initial or self.needs_list[1] or self.entombed_list[1]
    if init then self:goto_figure(init, false) end
end

function DeadScreen:refresh_current()
    local built = build_figure_info(self.current, self.pos_by_unit)
    self.subviews.info:setText(built.info_tokens)
    self.subviews.relatives:setChoices(built.relatives)
    self.subviews.relatives:setSelected(1)
end

function DeadScreen:goto_figure(fig, is_nav)
    if not fig then return end
    if is_nav and self.current then
        table.insert(self.history, self.current)
    elseif not is_nav then
        self.history = {}          -- fresh context from the left list
    end
    self.current = fig
    self:refresh_current()
end

function DeadScreen:go_back()
    local prev = table.remove(self.history)
    if prev then
        self.current = prev
        self:refresh_current()
    end
end

function DeadScreen:goto_corpse()
    if self.current and self.current.pos then
        dfhack.gui.revealInDwarfmodeMap(self.current.pos, true, true)
    else
        dlg.showMessage('Go to corpse',
            'No known remains on the map for ' .. (self.current and self.current.name or 'this figure') .. '.',
            COLOR_GRAY)
    end
end

function DeadScreen:queue_slabs()
    local engraved, made, have_slab, have_order = enqueue_memorial_slabs(self.needs_list or {})
    local parts = {}
    if engraved > 0 then
        table.insert(parts, ('Queued %d memorial-slab engraving%s.'):format(
            engraved, engraved == 1 and '' or 's'))
    end
    if made > 0 then
        table.insert(parts, ('Not enough blank slabs -- queued a "make rock slab" order for %d more.'):format(made))
    end
    if have_slab > 0 then table.insert(parts, ('%d already have a slab.'):format(have_slab)) end
    if have_order > 0 then table.insert(parts, ('%d already have an order.'):format(have_order)) end
    if #parts == 0 then table.insert(parts, 'Nothing to do.') end
    dlg.showMessage('Memorial slabs', table.concat(parts, '\n'), COLOR_WHITE)
end

function DeadScreen:onDismiss() end

-- open the browser; optional focus_unit selects that unit on open
local function open_browser(focus_unit)
    local r = scan()
    if #r.needs_tomb == 0 and #r.entombed == 0 and not focus_unit then return false end
    -- enrich copies with cause-of-death for the rows
    local function enrich(src)
        local out = {}
        for _, e in ipairs(src) do
            out[#out + 1] = {unit_id = e.unit_id, hf = e.hf, name = e.name, pos = e.pos}
        end
        attach_death_info(out)
        return out
    end
    local needs = enrich(r.needs_tomb)
    local entombed = enrich(r.entombed)
    local initial
    if focus_unit then
        -- reuse the matching row if present, else build a fresh figure for it
        for _, e in ipairs(needs) do if e.unit_id == focus_unit.id then initial = e break end end
        if not initial then for _, e in ipairs(entombed) do if e.unit_id == focus_unit.id then initial = e break end end end
        if not initial then initial = fig_from_unit(focus_unit, r.pos_by_unit) end
    end
    DeadScreen{needs_list = needs, entombed_list = entombed,
               pos_by_unit = r.pos_by_unit, initial = initial}:show()
    return true
end

local function show_dialog()
    open_browser(nil)
end

-- ---------------------------------------------------------------------------
-- notification message
-- ---------------------------------------------------------------------------

local function needs_tomb_message()
    if not dfhack.world.isFortressMode() then return end
    local list = scan().needs_tomb
    local count = #list
    if count == 0 then return end
    if count == 1 then
        return ('%s needs a tomb!'):format(list[1].name)
    end
    return ('%d need tombs!'):format(count)
end

-- ---------------------------------------------------------------------------
-- overlay: a button on the vanilla Dead/Missing units tab
-- ---------------------------------------------------------------------------

DeceasedButtonOverlay = defclass(DeceasedButtonOverlay, overlay.OverlayWidget)
DeceasedButtonOverlay.ATTRS{
    desc = 'Adds a "Family & info" button to the dead/missing units tab.',
    default_pos = {x = 72, y = -7},
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/CREATURES/DECEASED',
    frame = {w = 18, h = 1},
}

-- selected unit from the Dead/Missing list (mirrors DFHack's deathcause_button)
local function get_selected_dead_unit()
    local creatures = df.global.game.main_interface.info.creatures
    local list_widget = dfhack.gui.getWidget(creatures, 'Tabs', 'Dead/Missing')
    if not list_widget then return nil end
    local children = dfhack.gui.getWidgetChildren(list_widget)
    local list_container = children[1]
    if not list_container then return nil end
    local grandchildren = dfhack.gui.getWidgetChildren(list_container)
    local scrollable_list = grandchildren[2]
    if not scrollable_list then return nil end
    local rows = dfhack.gui.getWidgetChildren(scrollable_list)
    local cursor_idx = list_widget.cursor_idx or 0
    if cursor_idx >= 0 and cursor_idx < #rows then
        local row = rows[cursor_idx + 1]
        local ok, unit = pcall(function() return dfhack.gui.getWidget(row, 0).u end)
        if ok and unit then return unit end
    end
    return nil
end

function DeceasedButtonOverlay:init()
    self:addviews{
        widgets.TextButton{
            frame = {t = 0, l = 0},
            label = 'Family & info',
            key = 'CUSTOM_CTRL_F',
            on_activate = function()
                local unit = get_selected_dead_unit()
                if not open_browser(unit) then
                    dlg.showMessage('Fortress dead', 'No fortress dead to show yet.', COLOR_GRAY)
                end
            end,
        },
    }
end

OVERLAY_WIDGETS = {deceased = DeceasedButtonOverlay}

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Notifies when a fortress dwarf has died but has no tomb (unburied corpse).'
    entry.dwarf_fn = needs_tomb_message
    entry.on_click = show_dialog
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

-- keep the notification registered across world/map loads
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

if not dfhack_flags.module then
    register()
    print('needs-tomb-notification: "needs_tomb" registered.')
    print('Click the notification (or the Dead/Missing tab button) for the dead browser.')
    print('Run `overlay rescan` once to enable the Dead/Missing "Family & info" button.')
    print('Add `needs-tomb-notification` to dfhack.init to load it every session.')
end
