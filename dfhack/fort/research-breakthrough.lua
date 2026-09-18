-- Turn a scholar's research breakthrough into a new craftable recipe for your civ.
--@module = true
--[[
research-breakthrough

When one of your scholars makes a **research breakthrough** (the vanilla
`RESEARCH_BREAKTHROUGH` announcement, raised when a dwarf in your library finally
discovers a topic), this hands you **one recipe unlock**: a picker opens listing every
item your civilization does not yet know how to make, and the one you choose is added to
your civ's known recipes for good -- high boots, cloaks, masks, bowls, great picks.

This is a HOUSE RULE, not a hidden vanilla link. In vanilla DF the 312 research topics
unlock exactly one thing (literary forms, so scholars can write new book types) and have
no connection whatsoever to what your civ can forge or sew. The breakthrough is used here
purely as the trigger for a reward; the topic discovered does not constrain the choice.

What the picker offers -- every item subtype that is:
    * defined in the raws for a real item (not a GENERATED procedural artifact type --
      a modded world carries hundreds of "HF749 EI1ASH1" junk entries that must be hidden),
    * not already known to your civ,
    * not a TRAINING weapon (adding those lets DF forge them out of metal).
Items native to your civ's own entity raw (MOUNTAIN, for dwarves) are marked `*` and
sorted first; everything else is exotic -- other civs' gear, yours to take anyway.

The unlock writes `historical_entity.resources.<cat>_type` on your CIVILIZATION entity
(`plotinfo.civ_id`), the same field the stock `add-recipe` script writes, and the same one
every workshop's "Add new task" menu reads. Digging implements route to `digger_type`
instead of `weapon_type`, or picks end up duplicated and in the wrong menu. The fort's
group entity is deliberately NOT touched -- DF reads the civ's list, and the stock tool
has never written the group's.

Detection is the announcement, not a scan: the script keeps a watermark on
`world.status.next_report_id` and walks only the announcements added since it last looked,
so it never sweeps units, history, or the map. Breakthroughs are rare (a scholar needs
~120+ ponder cycles for their first), so expect this to fire a few times a year at most in
a fort with a real library, and never in a young one.

Unspent unlocks are remembered per fort (`persistent` site data) and surfaced as the
`research_unlock` notification -- click it to open the picker. Closing the picker with Esc
banks the unlock rather than wasting it; the `Cancel` button at the top forfeits every
banked unlock and closes.

Commands:
    fort/research-breakthrough            start the watcher (magnus-scripts does this)
    fort/research-breakthrough pick       open the picker now (spends a banked unlock)
    fort/research-breakthrough list       print what is still unlockable
    fort/research-breakthrough grant [n]  bank n unlocks by hand (default 1)
    fort/research-breakthrough status     show the watermark and banked count
]]

local gui = require('gui')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'research-breakthrough'
local NAME = 'research_unlock'
local CHECK_FRAMES = 100   -- ~2s at 50 fps; a breakthrough is rare, no need to look often

-- ---------------------------------------------------------------------------
-- recipe categories
-- ---------------------------------------------------------------------------

-- res  = the civ's known-recipe vector under historical_entity.resources
-- nat  = the civ's native list under entity_raw.equipment (what a dwarf civ makes natively)
-- defs = the itemdef vector under world.raws.itemdefs, indexed by subtype
local CATS = {
    {key = 'weapon',    label = 'Weapon',     res = 'weapon_type',    nat = 'weapon_id',    defs = 'weapons'},
    {key = 'armor',     label = 'Body armor', res = 'armor_type',     nat = 'armor_id',     defs = 'armor'},
    {key = 'helm',      label = 'Helm',       res = 'helm_type',      nat = 'helm_id',      defs = 'helms'},
    {key = 'gloves',    label = 'Gloves',     res = 'gloves_type',    nat = 'gloves_id',    defs = 'gloves'},
    {key = 'shoes',     label = 'Footwear',   res = 'shoes_type',     nat = 'shoes_id',     defs = 'shoes'},
    {key = 'pants',     label = 'Legwear',    res = 'pants_type',     nat = 'pants_id',     defs = 'pants'},
    {key = 'shield',    label = 'Shield',     res = 'shield_type',    nat = 'shield_id',    defs = 'shields'},
    {key = 'ammo',      label = 'Ammo',       res = 'ammo_type',      nat = 'ammo_id',      defs = 'ammo'},
    {key = 'siegeammo', label = 'Siege ammo', res = 'siegeammo_type', nat = 'siegeammo_id', defs = 'siege_ammo'},
    {key = 'trapcomp',  label = 'Trap part',  res = 'trapcomp_type',  nat = 'trapcomp_id',  defs = 'trapcomps'},
    {key = 'toy',       label = 'Toy',        res = 'toy_type',       nat = 'toy_id',       defs = 'toys'},
    {key = 'instrument',label = 'Instrument', res = 'instrument_type',nat = 'instrument_id',defs = 'instruments'},
    {key = 'tool',      label = 'Tool',       res = 'tool_type',      nat = 'tool_id',      defs = 'tools'},
}

local function civ()
    return df.historical_entity.find(df.global.plotinfo.civ_id)
end

-- A weapon whose melee skill is MINING is a digging implement: DF keeps those in
-- resources.digger_type, NOT weapon_type, and the workshop menus read them from there.
local function is_digger(def)
    return df.itemdef_weaponst:is_instance(def) and def.skill_melee == df.job_skill.MINING
end

local function is_training(def)
    if not df.itemdef_weaponst:is_instance(def) then return false end
    local ok, v = pcall(function() return def.flags.TRAINING end)
    return ok and v == true
end

-- Everything this civ still cannot make, newest-useful first: native items before exotic,
-- then by category order, then by raw order.
function candidates()
    local e = civ()
    if not e then return {} end
    local res, equip, raws = e.resources, e.entity_raw.equipment, df.global.world.raws.itemdefs

    -- weapons and diggers share one itemdef vector, so "already known" for a weapon means
    -- present in EITHER list
    local weapon_known = {}
    for _, v in ipairs(res.weapon_type) do weapon_known[v] = true end
    for _, v in ipairs(res.digger_type) do weapon_known[v] = true end

    local out = {}
    for ci, c in ipairs(CATS) do
        local known = {}
        for _, v in ipairs(res[c.res]) do known[v] = true end
        local native = {}
        for _, v in ipairs(equip[c.nat]) do native[v] = true end
        local defs = raws[c.defs]
        for i = 0, #defs - 1 do
            local d = defs[i]
            local have = (c.defs == 'weapons') and weapon_known[i] or known[i]
            if not d.base_flags.GENERATED and not have and not is_training(d) then
                out[#out + 1] = {
                    cat = c, cat_idx = ci, subtype = i, def = d,
                    name = d.name, id = d.id,
                    native = native[i] == true,
                    digger = is_digger(d),
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.native ~= b.native then return a.native end
        if a.cat_idx ~= b.cat_idx then return a.cat_idx < b.cat_idx end
        return a.subtype < b.subtype
    end)
    return out
end

-- Teach the civ one recipe. Permanent and saved with the fort.
function unlock(cand)
    local e = civ()
    if not e then return false end
    local vec = cand.digger and e.resources.digger_type or e.resources[cand.cat.res]
    for _, v in ipairs(vec) do
        if v == cand.subtype then return false end   -- already known; never insert twice
    end
    vec:insert('#', cand.subtype)
    return true
end

-- ---------------------------------------------------------------------------
-- persistent state
-- ---------------------------------------------------------------------------

-- last_id  = highest report/announcement id we have already considered
-- credits  = breakthroughs earned but not yet spent
-- deferred = the player closed the picker with credits banked; don't re-open unasked
local state

local function fresh_state()
    return {last_id = df.global.world.status.next_report_id - 1, credits = 0, deferred = false}
end

local function load_state()
    state = dfhack.persistent.getSiteData(GLOBAL_KEY, nil)
    if not state or not state.last_id then state = fresh_state() end
    state.credits = state.credits or 0
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- ---------------------------------------------------------------------------
-- detection
-- ---------------------------------------------------------------------------

-- Walk only the announcements added since our watermark. Ids are handed out by
-- world.status.next_report_id and appended in order, so we can stop at the first old one.
-- The announcements vector retains far longer than reports (which cap at 10000 and are
-- flooded by combat spam), which is why we read it and not reports.
local function collect_new()
    local st = df.global.world.status
    local anns = st.announcements
    local found = {}
    for i = #anns - 1, 0, -1 do
        local a = anns[i]
        if a.id <= state.last_id then break end
        if a.type == df.announcement_type.RESEARCH_BREAKTHROUGH and not a.flags.continuation then
            table.insert(found, 1, a.text)
        end
    end
    state.last_id = math.max(state.last_id, st.next_report_id - 1)
    return found
end

-- ---------------------------------------------------------------------------
-- picker
-- ---------------------------------------------------------------------------

view = view or nil

Picker = defclass(Picker, widgets.Window)
Picker.ATTRS{
    frame_title = 'Research breakthrough -- choose a recipe',
    frame = {w = 72, h = 32},
    resizable = true,
}

function Picker:init()
    self:addviews{
        widgets.Label{
            view_id = 'banner',
            frame = {t = 0, l = 0, r = 14, h = 2},
            text = '',
        },
        -- CANCEL, top right, FORFEITS every banked unlock and closes -- the way to get rid
        -- of a credit you do not want (a test grant, say). Esc is the gentle exit: it
        -- banks the unlock and the notification brings you back.
        widgets.HotkeyLabel{
            frame = {t = 0, r = 0, w = 13},
            key = 'CUSTOM_SHIFT_C',
            label = 'Cancel',
            on_activate = function()
                state.credits = 0
                state.deferred = false
                save_state()
                print('research-breakthrough: unlock(s) forfeited.')
                self.parent_view:dismiss()
            end,
        },
        widgets.EditField{
            view_id = 'search',
            frame = {t = 3, l = 0},
            label_text = 'Search: ',
            on_change = function() self:refresh() end,
        },
        widgets.List{
            view_id = 'list',
            frame = {t = 5, l = 0, b = 3},
            on_submit = function(_, choice) self:choose(choice) end,
        },
        widgets.Label{
            frame = {b = 0, l = 0, h = 2},
            text = {
                '* = native to your civ.  Enter/click learns it -- permanent.',
                NEWLINE,
                'Esc banks the unlock (the notice reopens this); Cancel forfeits it.',
            },
            text_pen = COLOR_GREY,
        },
    }
    self:refresh()
end

-- Several raws share a display name ("skirt" is ITEM_PANTS_SKIRT, _SHORT and _LONG), which
-- makes them indistinguishable in the list. For those, tack on whatever the raw id says
-- beyond the name itself: "skirt", "skirt (short)", "skirt (long)".
local function disambiguate(cands)
    local seen = {}
    for _, c in ipairs(cands) do seen[c.name] = (seen[c.name] or 0) + 1 end
    for _, c in ipairs(cands) do
        c.display = c.name
        if seen[c.name] > 1 then
            local token = c.id:gsub('^ITEM_[A-Z]+_', ''):lower():gsub('_', ' ')
            local extra = token:sub(#c.name + 1):gsub('^%s+', '')
            if extra ~= '' then c.display = ('%s (%s)'):format(c.name, extra) end
        end
    end
    return cands
end

function Picker:refresh()
    local filter = (self.subviews.search.text or ''):lower()
    local choices = {}
    for _, c in ipairs(disambiguate(candidates())) do
        local label = ('%s%-24s %s'):format(c.native and '* ' or '  ', c.display, c.cat.label)
        if filter == '' or label:lower():find(filter, 1, true) or c.id:lower():find(filter, 1, true) then
            choices[#choices + 1] = {
                text = {{text = label, pen = c.native and COLOR_WHITE or COLOR_GREY}},
                cand = c,
            }
        end
    end
    self.subviews.list:setChoices(choices)
    local n = state.credits
    self.subviews.banner:setText{
        {text = ('%d unlock%s to spend'):format(n, n == 1 and '' or 's'), pen = COLOR_LIGHTGREEN},
        NEWLINE,
        {text = ('%d recipe%s your civ still cannot make'):format(#choices, #choices == 1 and '' or 's'),
         pen = COLOR_GREY},
    }
end

function Picker:choose(choice)
    if not choice or state.credits <= 0 then return end
    if not unlock(choice.cand) then return end
    state.credits = state.credits - 1
    save_state()
    print(('research-breakthrough: learned %s (%s).'):format(choice.cand.name, choice.cand.id))
    dfhack.gui.showAnnouncement(
        ('Your civilization has learned to make the %s!'):format(choice.cand.name), COLOR_LIGHTGREEN)
    if state.credits > 0 then
        self:refresh()
    else
        self.parent_view:dismiss()
    end
end

PickerScreen = defclass(PickerScreen, gui.ZScreen)
PickerScreen.ATTRS{focus_path = 'research-breakthrough/pick'}
function PickerScreen:init() self:addviews{Picker{}} end
function PickerScreen:onDismiss()
    view = nil
    if state.credits > 0 then            -- banked, not wasted; stop auto-reopening
        state.deferred = true
        save_state()
    end
end

function open_picker()
    if view then view:raise() return true end
    if state.credits <= 0 then return false end
    if #candidates() == 0 then return false end
    state.deferred = false
    view = PickerScreen{}:show()
    return true
end

-- ---------------------------------------------------------------------------
-- notification
-- ---------------------------------------------------------------------------

local function notify_message()
    if not state or state.credits <= 0 then return end
    local n = state.credits
    -- the notify panel takes ONE return: a string or a token list. Returning the colour
    -- first handed it the number 10, which the label parser choked on every frame
    -- ("attempt to index a number value") -- and killed the whole notification panel.
    return {{text = n == 1 and 'A research breakthrough! Choose a recipe.'
                         or ('%d research breakthroughs! Choose recipes.'):format(n),
             pen = COLOR_LIGHTGREEN}}
end

local function register_notification()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Notifies when a scholar has made a research breakthrough and a new craftable recipe is waiting to be chosen.'
    entry.dwarf_fn = notify_message
    entry.on_click = function() open_picker() end
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

-- ---------------------------------------------------------------------------
-- watcher
-- ---------------------------------------------------------------------------

local function tick()
    if not dfhack.world.isFortressMode() then return end
    if not state then load_state() end

    local found = collect_new()
    if #found > 0 then
        state.credits = state.credits + #found
        state.deferred = false
        save_state()
        for _, text in ipairs(found) do
            print('research-breakthrough: ' .. text)
        end
    end

    -- Only ever open on top of a quiet map view -- never steal focus from a menu the
    -- player is in the middle of using.
    if state.credits > 0 and not state.deferred and not view then
        if dfhack.gui.matchFocusString('dwarfmode/Default') then open_picker() end
    end
end

local function hb_gen(set)
    if set ~= nil then dfhack.internal.research_breakthrough_hb_gen = set end
    return dfhack.internal.research_breakthrough_hb_gen or 0
end

local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if my ~= hb_gen() then return end          -- superseded by a newer heartbeat -> exit
        pcall(tick)
        dfhack.timeout(CHECK_FRAMES, 'frames', hb)
    end
    hb()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_WORLD_LOADED or sc == SC_MAP_LOADED then
        register_notification()
        if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() then
            state = nil
            load_state()
            start_heartbeat()
        end
    elseif sc == SC_MAP_UNLOADED then
        hb_gen(hb_gen() + 1)                        -- stop the heartbeat
        if view then view:dismiss() end
        state = nil
    end
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local cmd = args[1]

if not dfhack.world.isFortressMode() then
    qerror('research-breakthrough: fortress mode only.')
end

register_notification()
load_state()

if cmd == 'list' then
    local cands = candidates()
    print(('research-breakthrough: %d recipe(s) your civ cannot make yet (* = native):'):format(#cands))
    for _, c in ipairs(cands) do
        print(('  %s%-18s %-11s %s'):format(c.native and '* ' or '  ', c.name, c.cat.label, c.id))
    end
elseif cmd == 'grant' then
    local n = tonumber(args[2]) or 1
    state.credits = state.credits + n
    state.deferred = false
    save_state()
    print(('research-breakthrough: banked %d unlock(s); %d total.'):format(n, state.credits))
elseif cmd == 'pick' then
    if not open_picker() then
        print(('research-breakthrough: nothing to spend (%d banked, %d recipes left).')
              :format(state.credits, #candidates()))
    end
elseif cmd == 'status' then
    print(('research-breakthrough: watermark id %d, %d unlock(s) banked%s, %d recipe(s) unlockable.')
          :format(state.last_id, state.credits, state.deferred and ' (deferred)' or '', #candidates()))
else
    start_heartbeat()
    print(('research-breakthrough: watching for scholar breakthroughs (%d banked, %d recipes unlockable).')
          :format(state.credits, #candidates()))
    print('Run `overlay rescan` once so the "research_unlock" notification appears.')
end
