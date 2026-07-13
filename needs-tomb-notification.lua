-- Adds a "needs a tomb" notification to DFHack's gui/notify panel.
--@ module = false
--[[
Registers a custom notification (name: "needs_tomb") into the same notification
list used by "moody dwarf is gathering items" and "N groups of citizens are
stranded" (DFHack's gui/notify overlay).

It alerts when fortress dwarves have died and are not at rest -- their corpse is
loose (not interred in a coffin), OR they are walking as a GHOST (even if some
remains are interred, or the body is gone) -- and have not been memorialized (a
built memorial slab lays a ghost to rest just as burial does):
    * exactly one  -> "Urist McMiner needs a tomb!"
    * more than one -> "2 dwarves need tombs!"

Clicking the notification opens a list of the dwarves and what killed them.
    * Clicking a name zooms the map to that dwarf's corpse.
    * A button engraves a memorial slab (manager work order) for each of them.

Run once per DFHack session to register. To make it permanent, add the line
    needs-tomb-notification
to your dfhack-config/init/dfhack.init (or onMapLoad.init).
]]

local NAME = 'needs_tomb'

local dlg = require('gui.dialogs')
local gui = require('gui')
local widgets = require('gui.widgets')

-- ---------------------------------------------------------------------------
-- detection
-- ---------------------------------------------------------------------------

local function unit_display_name(u)
    -- just the personal name, e.g. "Vucar Domastolis"
    return dfhack.translation.translateName(dfhack.units.getVisibleName(u))
end

-- Cache the scan so the ~1/second notification refresh doesn't re-walk every corpse and unit
-- each time. Two guards, together: (1) a FRAME-counter check -- if no game tick has advanced
-- since our last call (the game is PAUSED, or this is a second call in one frame) nothing can
-- have changed, so reuse for free; (2) a wall-clock TTL -- while UNPAUSED the frame advances
-- every tick, so the frame check alone would thrash; the TTL then throttles to one scan per
-- minute. Deaths/burials/memorials change slowly, so up to a minute of staleness is fine.
local SCAN_TTL_MS = 60000
local cache = {frame = nil, t = nil, list = {}}

-- Only SAPIENT (intelligent, CAN_LEARN) creatures become ghosts -- tame animals never do, so they
-- are never counted even when they belong to the fort.
local function is_sapient(u)
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    return caste ~= nil and caste.flags.CAN_LEARN or false
end

-- A dead unit whose loose corpse means it will haunt the fort as a ghost if not laid to rest. Only
-- the fort's OWN people come back to haunt it -- so the FINAL list (below) requires a loose corpse
-- to belong to the fort (isOwnCiv / isOwnGroup, which read stable data that survives death, unlike
-- the resident/merchant unit flags). A dead FOREIGN visitor, mercenary or defeated attacker does NOT
-- ghost your fort even if it has a historical figure (e.g. a passing human bard) -- those were the
-- over-zealous false positives. `ghost_risk` here is just the first, cheap cut that drops the
-- obviously-not-a-tomb cases before the membership test:
--   * INVADERS (dead attackers) and the undead / opposed-to-life -- isInvader/isOpposedToLife stay
--     reliable on the dead (verified: the fort's ~340 dead attackers all still test as invaders);
--   * wild / unaffiliated creatures -- a cavern troll or feral beast that died here has NO
--     civilization (civ_id < 0), whereas the fort's own dead carry the fort civ.
-- (A GHOST already walking is exempt from the membership test -- it is surfaced no matter whose it
-- was in life, so a rare visitor/merchant ghost is never missed.)
local function ghost_risk(u)
    return u.civ_id and u.civ_id >= 0
        and not dfhack.units.isInvader(u) and not dfhack.units.isOpposedToLife(u)
end

local function scan()
    local fc = df.global.world.frame_counter or 0
    local now = dfhack.getTickCount()
    if cache.list and (fc == cache.frame or (cache.t and now - cache.t < SCAN_TTL_MS)) then
        cache.frame = fc     -- track the latest frame so a following pause reuses immediately
        return cache.list
    end

    local fortrace = df.global.plotinfo.race_id
    local fortciv  = df.global.plotinfo.civ_id

    -- per dead unit: is any part interred (buried) / is any part loose (unburied)
    local info, order = {}, {}
    -- hf ids with a BUILT memorial slab: a memorial lays a ghost to rest just like a burial, so
    -- a memorialized dwarf needs no tomb. The slab's `topic` is the memorialized hf; it must be
    -- ENGRAVED as a Memorial and actually BUILT (in_building) -- an engraved slab still sitting in
    -- a stockpile hasn't laid anyone to rest yet.
    local memorialized = {}
    local vec = df.global.world.items.other.IN_PLAY
    for i = 0, #vec - 1 do
        local it = vec[i]
        local t = it and it:getType()
        if it and t == df.item_type.SLAB
            and it.engraving_type == df.slab_engraving_type.Memorial
            and it.topic and it.topic >= 0 and it.flags.in_building
            and not (it.flags.garbage_collect or it.flags.removed)
        then
            memorialized[it.topic] = true
        end
        if it and (t == df.item_type.CORPSE or t == df.item_type.CORPSEPIECE)
            and not (it.flags.garbage_collect or it.flags.removed)
        then
            local uid = it.unit_id
            local u = uid and uid >= 0 and df.unit.find(uid)
            -- Anyone who can become a GHOST needs laying to rest: any dead sapient at the
            -- fort that isn't a hostile invader (or the undead) -- our citizens & residents,
            -- plus visitors and caravan merchants who died here (see ghost_risk). Require the
            -- unit to be actually dead (a CORPSEPIECE can also be a limb lost by a LIVING unit).
            if u and dfhack.units.isDead(u) and is_sapient(u) and ghost_risk(u) then
                local rec = info[uid]
                if not rec then
                    rec = {unit = u, buried = false, unburied = false, pos = nil,
                           ghostly = u.flags3.ghostly}
                    info[uid] = rec
                    table.insert(order, uid)
                end
                if it.flags.in_building then
                    rec.buried = true                 -- in a coffin
                else
                    rec.unburied = true
                    if not rec.pos then
                        local x, y, z = dfhack.items.getPosition(it)
                        if x then rec.pos = xyz2pos(x, y, z) end
                    end
                end
            end
        end
    end

    -- GHOSTS: any ghost wandering the fort is DEFINITIVELY not at rest and needs a slab/tomb --
    -- even if some remains are interred (a partial burial still leaves the ghost), or the body is
    -- gone entirely (no corpse item at all). Do NOT require fort-GROUP membership here: a ghost in
    -- the (bounded) active-unit list is on THIS map haunting THIS fort no matter who it was in life
    -- -- e.g. a dead merchant, or a resident/mercenary whose histfig never carried a fort-group link
    -- (is_fort_member would wrongly drop them -- exactly the bug that let a caravan merchant's ghost
    -- slip past the alert). Ghosts are always dead & sapient, so those two guards are all we need.
    for _, u in ipairs(df.global.world.units.active) do
        if u.flags3.ghostly and dfhack.units.isDead(u) and is_sapient(u) then
            local uid = u.id
            local rec = info[uid]
            if not rec then
                rec = {unit = u, buried = false, unburied = false, pos = nil, ghostly = true}
                info[uid] = rec
                table.insert(order, uid)
            else
                rec.ghostly = true
            end
            if not rec.pos then
                local x, y, z = dfhack.units.getPosition(u)
                if x then rec.pos = xyz2pos(x, y, z) end
            end
        end
    end

    -- a dwarf needs a tomb if their body is loose (a loose part, none interred) OR they are a
    -- ghost (not at rest regardless of burial) -- and they have NOT been memorialized (a built
    -- memorial slab lays their ghost to rest just as a burial would)
    local list = {}
    for _, uid in ipairs(order) do
        local rec = info[uid]
        local hf = rec.unit.hist_figure_id
        -- A loose CORPSE only comes back to haunt THIS fort if the dead unit BELONGS to the fort: its
        -- own civilization (isOwnCiv) or its site group (isOwnGroup -- which also covers a foreign-civ
        -- resident who joined). FOREIGN dead -- visitors, mercenaries passing through, defeated
        -- attackers -- do NOT ghost your fort even when they have a historical figure (e.g. a visiting
        -- human bard like "Ishas"), and were the over-zealous false positives. Both checks read stable
        -- data, so they survive death (the resident/merchant unit FLAGS do not; civ_id does). A GHOST
        -- already walking is ALWAYS surfaced no matter whose it was in life -- it is haunting this map
        -- right now -- so a rare visitor/merchant ghost is never missed.
        local belongs = dfhack.units.isOwnCiv(rec.unit) or dfhack.units.isOwnGroup(rec.unit)
        if (rec.ghostly or (rec.unburied and not rec.buried and belongs))
            and not memorialized[hf] then
            table.insert(list, {
                unit_id = uid,
                hf = hf,
                name = unit_display_name(rec.unit),
                pos = rec.pos,
            })
        end
    end

    cache.frame = fc
    cache.t = now
    cache.list = list
    return list
end

-- ---------------------------------------------------------------------------
-- cause of death (only computed when the dialog is opened, not every refresh)
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

-- from a historical "figure died" event (best for named slayers, even long-gone)
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

-- from an incident record (fills in recent fort deaths lacking a history event)
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

-- some "figure died" / death-incident records carry a PLACEHOLDER death_type (MEMORIALIZE)
-- rather than a real cause -- e.g. a resident/mercenary whose death DF abstracted. Skip those so
-- we keep looking for a record with an actual cause and never print the raw "memorialize" token.
local PLACEHOLDER_CAUSE = {}
if df.death_type.MEMORIALIZE then PLACEHOLDER_CAUSE[df.death_type.MEMORIALIZE] = true end
local function meaningful_cause(dc) return dc ~= nil and dc >= 0 and not PLACEHOLDER_CAUSE[dc] end

local function attach_death_info(list)
    local by_hf, by_unit, remaining = {}, {}, 0
    for _, e in ipairs(list) do
        e.killed_by = nil
        by_unit[e.unit_id] = e
        if e.hf and e.hf >= 0 then by_hf[e.hf] = e end
        remaining = remaining + 1
    end
    -- 1) historical death events (reverse: first match per victim is latest)
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
    -- 2) incident log, keyed reliably by victim unit id
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

-- ---------------------------------------------------------------------------
-- memorial slab manager orders
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

-- a memorial slab ALREADY engraved for this hf exists in the fort (ready to be placed/built) --
-- so there's no point engraving another; it just needs building. Matches any Memorial-engraved
-- slab whose topic is this hf (a built one means they're memorialized and off the list anyway).
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
    local o = df.manager_order:new()      -- ownership passes to the vector on insert
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = mo.manager_order_next_id + 1
    o.job_type = df.job_type.EngraveSlab
    o.amount_total = 1
    o.amount_left = 1
    o.frequency = 0                       -- one-off (matches normal active orders)
    o.status.validated = true
    o.status.active = true
    o.specdata.hist_figure_id = hf        -- which dead dwarf this slab memorializes
    mo.all:insert('#', o)
end

local function count_blank_slabs()
    local n = 0
    local vec = df.global.world.items.other.IN_PLAY
    for i = 0, #vec - 1 do
        local it = vec[i]
        if it:getType() == df.item_type.SLAB
            and it.engraving_type == df.slab_engraving_type.Slab    -- un-engraved
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
    o.job_type = df.job_type.ConstructSlab     -- "make rock slab"
    o.amount_total = amount
    o.amount_left = amount
    o.frequency = 0
    o.status.validated = true
    o.status.active = true
    -- material left unconstrained: the mason uses any available stone
    mo.all:insert('#', o)
end

-- Queue an engrave order for EVERY listed dwarf who needs one, PLUS a "make rock slab" order for
-- however many extra blanks those engravings need. An EngraveSlab job simply waits for a blank
-- slab to exist, so we never cap engravings by the current blank count -- we queue them all and
-- make sure enough blanks get produced. Returns: engraved, made (extra blanks), skipped.
local function enqueue_memorial_slabs(list)
    -- only engrave for the dead who have neither an engraved slab ready nor an engrave order queued;
    -- count the two "already handled" cases separately so we can report them separately.
    local need, have_slab, have_order = {}, 0, 0
    for _, e in ipairs(list) do
        if e.hf and e.hf >= 0 then
            if has_engraved_slab(e.hf) then have_slab = have_slab + 1        -- a slab already engraved (needs placing)
            elseif has_pending_slab_order(e.hf) then have_order = have_order + 1  -- an engrave order already queued
            else table.insert(need, e) end
        end
        -- an entry with no historical figure can't be memorialized by slab; it's simply not queued
    end

    -- blanks available for the NEW engrave orders, measured BEFORE we add them: existing engrave
    -- orders each consume a blank; already-queued make-slab orders each add one.
    local pending_engrave, pending_make = count_slab_orders()
    local free = count_blank_slabs() - pending_engrave + pending_make

    -- always engrave for everyone who needs it
    for i = 1, #need do
        create_slab_order(need[i].hf)
    end

    -- queue a "make rock slab" order for the shortfall so the extra blanks those engravings need
    -- actually get produced (the engrave jobs just wait until a blank exists)
    local shortfall = #need - free
    if shortfall > 0 then
        create_make_slab_order(shortfall)
    else
        shortfall = 0
    end

    return #need, shortfall, have_slab, have_order
end

-- ---------------------------------------------------------------------------
-- the click dialog: list of names + cause, with a memorial-slab button
-- ---------------------------------------------------------------------------

local MemorialScreen = defclass(nil, gui.ZScreen)
MemorialScreen.ATTRS{
    focus_path = 'needs-tomb/memorial',
    list = DEFAULT_NIL,
}

function MemorialScreen:init()
    local list = self.list or {}
    local choices = {}
    for _, e in ipairs(list) do
        table.insert(choices, {
            text = ('%s  -  %s'):format(e.name, e.killed_by or '?'),
            pos = e.pos,
        })
    end

    self:addviews{
        widgets.Window{
            frame_title = 'Dead needing a tomb',
            frame = {w = 66, h = 22},
            resizable = true,
            resize_min = {w = 44, h = 10},
            subviews = {
                widgets.List{
                    view_id = 'list',
                    frame = {t = 0, l = 0, r = 0, b = 3},
                    choices = choices,
                    on_submit = function(_, choice)
                        if choice and choice.pos then
                            dfhack.gui.revealInDwarfmodeMap(choice.pos, true, true)
                        end
                    end,
                },
                widgets.Label{
                    frame = {b = 2, l = 0},
                    text = {{text = 'Click a name to zoom to the corpse.', pen = COLOR_GRAY}},
                },
                widgets.HotkeyLabel{
                    view_id = 'slab_btn',
                    frame = {b = 0, l = 0},
                    key = 'CUSTOM_CTRL_E',
                    auto_width = true,
                    label = ('Engrave memorial slabs for all (%d)'):format(#choices),
                    on_activate = function() self:queue_slabs() end,
                },
            },
        },
    }
end

function MemorialScreen:queue_slabs()
    local engraved, made, have_slab, have_order = enqueue_memorial_slabs(self.list or {})
    local parts = {}
    if engraved > 0 then
        table.insert(parts, ('Queued %d memorial-slab engraving%s.'):format(
            engraved, engraved == 1 and '' or 's'))
    end
    if made > 0 then
        table.insert(parts, ('Not enough blank slabs -- queued a "make rock slab" order for %d more.'):format(made))
    end
    if have_slab > 0 then
        table.insert(parts, ('%d already have a slab.'):format(have_slab))
    end
    if have_order > 0 then
        table.insert(parts, ('%d already have an order.'):format(have_order))
    end
    if #parts == 0 then
        table.insert(parts, 'Nothing to do.')
    end
    dlg.showMessage('Memorial slabs', table.concat(parts, '\n'), COLOR_WHITE)
end

function MemorialScreen:onDismiss()
    -- nothing persistent to clean up
end

local function show_dialog()
    local list = scan()
    if #list == 0 then return end
    -- enrich a shallow copy so the cached scan list stays lean
    local enriched = {}
    for _, e in ipairs(list) do
        enriched[#enriched + 1] = {
            unit_id = e.unit_id, hf = e.hf, name = e.name, pos = e.pos,
        }
    end
    attach_death_info(enriched)
    MemorialScreen{list = enriched}:show()
end

-- ---------------------------------------------------------------------------
-- notification message (runs frequently; keep it light)
-- ---------------------------------------------------------------------------

local function needs_tomb_message()
    if not dfhack.world.isFortressMode() then return end
    local list = scan()
    local count = #list
    if count == 0 then return end
    if count == 1 then
        return ('%s needs a tomb!'):format(list[1].name)
    end
    return ('%d need tombs!'):format(count)
end

-- ---------------------------------------------------------------------------
-- registration (idempotent; survives notify-module reloads via onStateChange)
-- ---------------------------------------------------------------------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    -- (re)assign callbacks every time so re-running the script picks up edits
    entry.desc = 'Notifies when a fortress dwarf has died but has no tomb (unburied corpse).'
    entry.dwarf_fn = needs_tomb_message
    entry.on_click = show_dialog
    -- the overlay gates on config.data[name].enabled; make sure it exists so it
    -- doesn't nil-index (and so the notification is on by default)
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()

-- re-apply if the notify module is reloaded on a new world/map load
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then
        register()
    end
end

print('needs-tomb-notification: "needs_tomb" registered.')
print('Click the notification for a list of the dead + a memorial-slab button.')
print('Add `needs-tomb-notification` to dfhack.init to load it every session.')
