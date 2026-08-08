-- Adds a search bar to the adventure-mode inventory list (the I/r/w/e/p/d item screens).
--@module = true
--[[
adv/inventory-search

The adventurer inventory screens (dungeonmode/Inventory -- Look, Remove, Wear, Eat/Drink, Put in,
Drop and the rest all share one screen) list every item you carry, containers included. This
overlay adds a Search field (Alt-S) that filters the list live by item description, material and
type, so "steel", "adamantine", "book" or "scroll" match even named items whose description
omits them. Clearing the search (or switching context / reopening) restores the full list.

Magic search words, combinable with each other and with normal terms:
  heavy             sort the rows by weight, heaviest first
  equip / equipped  only items you have equipped (not just hauled), ordered: things in your
                    hands (always first, even a jug), weapons and tools strapped to your body,
                    the rest of the weapons and armor, clothing, rings and trinkets,
                    everything else, containers last
  food              only food and drink, ordered: normal drinks, normal food, healing drinks,
                    healing food, then food your ethics won't let you eat (sapient flesh --
                    the same screen adv/always-be-satiated uses). Containers themselves are
                    excluded; anything edible inside one has its own row
  healing / heal    only food/drink whose material carries a beneficial (healing) syndrome --
                    plain booze's intoxication syndrome does not count

With no search active, the list itself is shown in the same "equip" order (hands, strapped
weapons/tools, weapons and armor, clothing, rings and trinkets, the rest, containers), moved
as whole blocks so container contents stay under their container. Armor vs clothing is the itemdef's armorlevel: a mail
shirt is armor, a dress is clothing.

When adv/keep-inventory auto-reopens the panel after an action, it calls restore_last_search()
here so the reopened list comes back with the same filter; a panel you left with Esc still
opens clean.

The rows live in main_interface.adventure.inventory.option_current, a vector of
adventure_optionst* that DF rebuilds from scratch every time the screen opens (the 9 per-context
`option` vectors stay empty on this build; option_current is the live list and is stable while
the screen is up). We filter that vector in place via sortoverlay's single_vector_search and let
the scope machinery drop the cache when the screen closes -- the focus string flips between
dungeonmode/Inventory and dungeonmode/Default, so unlike the squad-equipment picker the base
class's scope reset actually fires here.

Context switches (r/w/e... while open) rebuild the list too, so inv.context is returned as the
sortoverlay GROUP: a context change makes the base class drop the cached snapshot instead of
stamping the previous context's rows into the new list.

Best-effort leak guard: DF clears option_current when the screen closes, freeing only the rows
still in the vector -- rows our filter erased would leak. We restore the full list when we see
the close keys (Esc / right-click) before DF acts on them; closing by clicking a row with a
filter active can still leak a few option structs, which is harmless.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local sortoverlay = require('plugins.sort.sortoverlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local function inventory()
    return df.global.game.main_interface.adventure.inventory
end

-- Find the "Your inventory" header by reading the screen and return the SCREEN (col, row) for the
-- search bar: one row below the header, left-aligned with it. The header line ALWAYS also carries
-- the Burden readout, and requiring both strings is what keeps a stray "your inventory" elsewhere
-- on a mid-draw grid (an item description pane, leftover text) from stealing the bar -- matching
-- the phrase alone once parked it 30 rows deep in the item list. Returns nil until the real
-- header has rendered so the caller can retry.
local HEADER = 'your inventory'
local HEADER_MATE = 'burden'
local function header_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    for y = 0, sh - 1 do
        local chars = {}
        for x = 0, sw - 1 do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars):lower()
        local c = line:find(HEADER, 1, true)
        if c and line:find(HEADER_MATE, 1, true) then
            return c - 1, y + 1   -- 0-based col of the header's first char, one row down
        end
    end
end

-- the item's type words: the type enum ("book", "flask") plus the subtype name where one exists
-- ("scroll", "battle axe") -- written works describe as bare titles, so "book"/"scroll" would
-- otherwise never match
local function item_type_words(it)
    local words = (df.item_type[it:getType()] or ''):lower():gsub('_', ' ')
    local ok, sub = pcall(function() return it.subtype.name end)
    if ok and type(sub) == 'string' then words = words .. ' ' .. sub end
    -- scrolls are written works too: give them the "book" word so one search finds all reading
    if words:find('scroll', 1, true) then words = words .. ' book' end
    return words
end

-- ---- magic search words -----------------------------------------------------
-- "heavy" sorts the (remaining) rows by weight, heaviest first. "equip"/"equipped" filters to
-- items you actually have equipped -- invitem mode anything but Hauled -- with in-hand (Weapon
-- mode) items first and containers (backpack, quiver, waterskin) last. "food" filters to food
-- and drink (containers excluded -- edible contents get their own rows), tiered: normal drinks,
-- normal food, healing drinks, healing food, then ethics-refused sapient flesh last.
-- "healing" filters to food/drink whose material carries a beneficial syndrome (the mythical
-- healing loot; plain booze's intoxication syndrome does NOT count). Magic words combine with
-- each other and with normal search terms.

local function row_item(row)
    local ok, it = pcall(function() return row:getItem() end)
    return ok and it or nil
end

-- item.weight is a lazy cache: carried items have it filled, but force it like
-- adv/inventory-display-weight does in case a row's item hasn't been computed yet
local function row_weight(row)
    local it = row_item(row)
    if not it then return 0 end
    if it.weight.whole == 0 and it.weight.fraction == 0 then
        pcall(function() it:calculateWeight() end)
    end
    return it.weight.whole * 1000000 + it.weight.fraction
end

-- the row's unit_inventory_item mode (df.inv_item_role_type), or nil for rows that aren't in the
-- unit's own inventory (container contents)
local function row_mode(row)
    local ok, m = pcall(function() return row.invitem.mode end)
    return ok and m or nil
end

local function is_equipped(row)
    local m = row_mode(row)
    return m ~= nil and m ~= df.inv_item_role_type.Hauled
end

local function in_hands(row)
    return row_mode(row) == df.inv_item_role_type.Weapon
end

local function is_container_row(row)
    local it = row_item(row)
    if not it then return false end
    -- quivers don't get the container item-flag but hold ammo and nest rows like any container
    return it.flags.container or it:getType() == df.item_type.QUIVER
end

local WEAPONISH = {
    [df.item_type.WEAPON] = true, [df.item_type.SHIELD] = true, [df.item_type.AMMO] = true,
}
-- wearable types that split into armor vs clothing by their itemdef's armorlevel
-- (0 = clothing: dress, cap, mitten; 1+ = real armor: mail shirt, helm, gauntlet)
local WEARABLE = {
    [df.item_type.ARMOR] = true, [df.item_type.HELM] = true, [df.item_type.GLOVES] = true,
    [df.item_type.SHOES] = true, [df.item_type.PANTS] = true,
}
local JEWELRY = {
    [df.item_type.RING] = true, [df.item_type.EARRING] = true, [df.item_type.AMULET] = true,
    [df.item_type.BRACELET] = true, [df.item_type.CROWN] = true,
}

-- the "equip" display rank: 0 things in your hands (ALWAYS, even a jug or a backpack --
-- what you're holding right now belongs at the top), 1 weapons and tools strapped to your
-- body, 2 the rest of the weapons and armor, 3 clothing, 4 rings and trinkets, 5 everything
-- else, 6 containers, 7 spatter/coating rows (no resolvable item) at the very bottom
local function equip_rank(row)
    if in_hands(row) then return 0 end
    if row_mode(row) == df.inv_item_role_type.Strapped then return 1 end
    if is_container_row(row) then return 6 end
    local it = row_item(row)
    if not it then return 7 end
    local t = it:getType()
    if WEAPONISH[t] then return 2 end
    if WEARABLE[t] then
        local ok, lvl = pcall(function() return it.subtype.armorlevel end)
        return (ok and lvl and lvl > 0) and 2 or 3
    end
    if JEWELRY[t] then return 4 end
    return 5
end

-- ---- food / drink / healing classification ----------------------------------

local function mat_of(it)
    local ok, mi = pcall(dfhack.matinfo.decode, it)
    return ok and mi or nil
end

local function item_is_drink(it)
    local mi = mat_of(it)
    if not mi then return false end
    local f = mi.material.flags
    return f.ALCOHOL or f.ALCOHOL_PLANT or f.ALCOHOL_CREATURE or mi.material.id == 'WATER'
end

local function item_is_food(it)
    if it:getType() == df.item_type.FOOD then return true end   -- prepared meals
    local mi = mat_of(it)
    if not mi then return false end
    local f = mi.material.flags
    return f.EDIBLE_RAW or f.EDIBLE_COOKED
end

-- effects that make a syndrome "beneficial" -- the healing verbs only, so plain booze's
-- intoxication syndrome (DIZZINESS etc.) does not count as healing
local BENEFICIAL = {
    REGROW_PARTS = true, CLOSE_OPEN_WOUNDS = true, HEAL_TISSUES = true, HEAL_NERVES = true,
    STOP_BLEEDING = true, REDUCE_PAIN = true, REDUCE_DIZZINESS = true, REDUCE_NAUSEA = true,
    REDUCE_SWELLING = true, CURE_INFECTION = true, REDUCE_PARALYSIS = true, REDUCE_FEVER = true,
}

-- the item's material carries at least one beneficial syndrome effect
-- (syndromes live at matinfo.material.syndrome.syndrome -- the extra .syndrome is real)
local function item_heals(it)
    local mi = mat_of(it)
    if not mi then return false end
    local ok, syns = pcall(function() return mi.material.syndrome.syndrome end)
    if not ok then return false end
    for _, syn in ipairs(syns) do
        for _, ce in ipairs(syn.ce) do
            local okt, t = pcall(function() return df.creature_interaction_effect_type[ce:getType()] end)
            if okt and BENEFICIAL[t] then return true end
        end
    end
    return false
end

-- true when the material comes from a creature that can learn or speak (an illithid, an elf).
-- DF refuses their flesh on your civ's ethics even though the raws mark it EDIBLE -- the same
-- screen adv/always-be-satiated uses
local function sapient_source(mi)
    local cr = mi and mi.creature
    if not cr then return false end
    for _, c in ipairs(cr.caste) do
        if c.flags.CAN_LEARN or c.flags.CAN_SPEAK then return true end
    end
    return false
end

-- may the adventurer eat sapients? Their civ's ethics decide (either EAT_SAPIENT ethic
-- permitting is enough); outsiders have no civ and are refused. Mirrors always-be-satiated.
local ER = df.ethic_response
local function ethic_permits(v)
    return (v >= ER.ACCEPTABLE and v <= ER.ONLY_IF_SANCTIONED) or v == ER.REQUIRED
end
local function may_eat_sapients()
    local u = dfhack.world.getAdventurer()
    local civ_id = u and u.civ_id or -1
    if civ_id < 0 then
        local nem = df.nemesis_record.find(df.global.adventure.player_id)
        civ_id = nem and nem.figure and nem.figure.civ_id or -1
    end
    local civ = civ_id >= 0 and df.historical_entity.find(civ_id) or nil
    local raw = civ and civ.entity_raw
    if not raw then return false end
    return ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_OTHER])
        or ethic_permits(raw.ethic[df.ethic_type.EAT_SAPIENT_KILL])
end

-- The "food" tier of a row, nil for rows the food search excludes. Containers are excluded
-- outright (the quiver and the jug are not food; anything edible INSIDE one gets its own row):
--   0 normal drinks, 1 normal food, 2 healing drinks, 3 healing food,
--   4 food/drink your ethics refuse to let you eat (illithid brains, for a dwarf)
local function food_rank(row, allow_sapient)
    local it = row_item(row)
    if not it or is_container_row(row) then return nil end
    local drink, food = item_is_drink(it), item_is_food(it)
    if not (drink or food) then return nil end
    if not allow_sapient and sapient_source(mat_of(it)) then return 4 end
    local heals = item_heals(it)
    if drink then return heals and 2 or 0 end
    return heals and 3 or 1
end

-- the row is (or contains) food/drink whose material heals
local function row_heals(row)
    local it = row_item(row)
    if not it then return false end
    if (item_is_drink(it) or item_is_food(it)) and item_heals(it) then return true end
    local ok, contained = pcall(dfhack.items.getContainedItems, it)
    if not ok then return false end
    for _, c in ipairs(contained) do
        if (item_is_drink(c) or item_is_food(c)) and item_heals(c) then return true end
    end
    return false
end

local function make_sort(heavy, equipped, foodish, allow_sapient)
    return function(a, b)
        if equipped then
            local ra, rb = equip_rank(a), equip_rank(b)
            if ra ~= rb then return ra < rb end
        end
        if foodish then
            local fa = food_rank(a, allow_sapient) or 99
            local fb = food_rank(b, allow_sapient) or 99
            if fa ~= fb then return fa < fb end
        end
        if heavy then
            local wa, wb = row_weight(a), row_weight(b)
            if wa ~= wb then return wa > wb end
        end
        -- deterministic tail: table.sort is unstable, so ties need SOME fixed key or rows
        -- jiggle between keystrokes
        local ma, mb = row_mode(a) or 99, row_mode(b) or 99
        if ma ~= mb then return ma < mb end
        local ia, ib = row_item(a), row_item(b)
        return (ia and ia.id or -1) < (ib and ib.id or -1)
    end
end

-- The default (no search) display order: the "equip" ranking applied to the whole list. The
-- list is a flattened tree -- a depth-0 row followed by its indented content rows -- so BLOCKS
-- move together and container contents stay under their container.
local function default_order(vec)
    local blocks, cur = {}, nil
    for i = 0, #vec - 1 do
        local row = vec[i]
        local ok, depth = pcall(function() return row.depth end)
        if not ok then return nil end
        if depth == 0 or not cur then
            cur = {rank = equip_rank(row), rows = {row}}
            blocks[#blocks + 1] = cur
        else
            cur.rows[#cur.rows + 1] = row
        end
    end
    local out = {}
    for rank = 0, 7 do
        for _, b in ipairs(blocks) do
            if b.rank == rank then
                for _, r in ipairs(b.rows) do out[#out + 1] = r end
            end
        end
    end
    return out
end

-- searchable text for a row: the item's readable description plus its material and type names.
-- Plain descriptions already name the material ("dog leather waterskin"), but artifacts, books
-- and other named items don't -- appending them lets "steel", "adamantine", "book" or "scroll"
-- find those too. Rows with NO resolvable item -- in practice the "spatter of X" / "coating
-- of X" contamination rows, whose getItem() yields nothing -- key as '' so any active search
-- drops them (returning nil instead would keep them in EVERY result list, which is how six
-- fat-spatter rows once survived a search for "book"); with no search they stay listed.
local function get_row_search_key(row)
    local ok, it = pcall(function() return row:getItem() end)
    if not ok or not it then return '' end
    local ok2, desc = pcall(dfhack.items.getReadableDescription, it)
    local key = ok2 and desc or ''
    local ok3, mi = pcall(dfhack.matinfo.decode, it)
    if ok3 and mi then key = key .. ' ' .. mi:toString() end
    return key .. ' ' .. item_type_words(it)
end

-- module state (the module env is cached by reqscript, so these persist across invocations):
-- the live overlay instance and the last text typed into it
last_text = last_text or ''
active_widget = active_widget or nil

-- Re-seed the search box with the last query, for the NEXT time the panel opens. Called by
-- adv/keep-inventory when its auto-reopen lands, so an act-and-reopen cycle keeps the filter.
-- Works by planting prev_text in sortoverlay's state and clearing cur_key: the base class's
-- onRenderBody sees the key "change" back to INV, setTexts the planted text and re-runs the
-- search -- the exact path it uses when the player switches contexts, so no custom apply logic.
-- debug breadcrumbs, readable via `lua reqscript('adv/inventory-search').trace`
trace = trace or {calls = 0, planted = 0, last_seen = '', applied = 0}

function restore_last_search()
    trace.calls = trace.calls + 1
    trace.last_seen = last_text
    local self = active_widget
    if not self or last_text == '' then return end
    self.state.INV = {prev_text = last_text}
    self.state.cur_key = nil
    trace.planted = trace.planted + 1
end

-- Forget the remembered query. keep-inventory calls this when the player DELIBERATELY leaves
-- the panel (Esc / right-click), so a later action-reopen doesn't resurrect a stale filter
-- from a previous session with the panel.
function clear_last_search()
    last_text = ''
end

AdvInventorySearchOverlay = defclass(AdvInventorySearchOverlay, sortoverlay.SortOverlay)
AdvInventorySearchOverlay.ATTRS{
    desc = 'Adds a search bar to the adventure-mode inventory list.',
    default_pos = {x = 2, y = 2},   -- fallback until it snaps below the "Your inventory" header
    viewscreens = 'dungeonmode/Inventory',
    -- interior: 'Alt+s: ' fills cols 1-7, button labels to col 28, ']' at 29
    frame = {w = 30, h = 1},
}

-- snap the search bar one row below the header, left-aligned (frame coords are relative to the
-- interface rect, so convert the screen position by the interface origin). False until drawn.
function AdvInventorySearchOverlay:reposition()
    local col, row = header_pos()
    if not col then return false end
    local ir = gui.get_interface_rect()
    local l, t = col - ir.x1, row - ir.y1
    if self.frame.l ~= l or self.frame.t ~= t then
        self.frame = {w = self.frame.w, h = self.frame.h, l = l, t = t}
        self:updateLayout(gui.ViewRect{rect = ir})
    end
    return true
end

-- Re-scrape and reposition on a 500ms throttle the whole time the panel is open, not just once
-- per open: the grid read on the opening frame can be the PREVIOUS screen's leftovers (that is
-- how the bar once landed 30 rows deep), and continuous revalidation self-heals a bad first
-- placement as soon as the real header renders. Chains to the SortOverlay base (scope reset /
-- cache cleanup). Also applies the DEFAULT display order (equip ranking: hands first, containers
-- last) whenever the row set changes and no search is active.
local SCAN_MS = 500
function AdvInventorySearchOverlay:overlay_onupdate()
    AdvInventorySearchOverlay.super.overlay_onupdate(self)
    if not self:get_key() then self.sorted_n = nil; self.next_scan = nil; self.header_ok = nil; return end
    local now = dfhack.getTickCount()
    if now >= (self.next_scan or 0) then
        self.header_ok = self:reposition()         -- also gates the box's visibility
        if self.header_ok then
            self.next_scan = now + SCAN_MS         -- placed; revalidate at the slow cadence
        else
            self.next_scan = now + 100             -- not rendered yet; retry quickly
        end
    end
    local vec = inventory().option_current
    if #vec ~= (self.sorted_n or -1) and self.subviews.search.text == '' then
        self.sorted_n = #vec
        local want = default_order(vec)
        if want and #want == #vec then
            local changed = false
            for i = 1, #want do
                if vec[i - 1] ~= want[i] then changed = true; break end
            end
            if changed then vec:assign(want) end
        end
    end
end

function AdvInventorySearchOverlay:init()
    active_widget = self
    -- visible only while the picker is open AND the "Your inventory" header has actually been
    -- found on screen -- until the header renders (or on sub-screens without it) the box hides
    -- instead of floating at a stale position
    local panel = widgets.Panel{
        visible = function() return self:get_key() ~= nil and self.header_ok == true end,
    }
    -- preset buttons just type into the search box for you: setText fires on_change, so the
    -- normal capture + search path runs exactly as if the word had been typed
    local function preset(text)
        return function() self.subviews.search:setText(text) end
    end
    -- The bar renders as `[Alt+s: ] [Food] [Heal] [Book]` when idle. The EditField spans
    -- the whole banner underneath; the `]` and the three buttons are labels drawn over its
    -- (empty) text area, hidden the moment there is text or focus -- so typed text overflows
    -- rightward across where the buttons were, and only the banner's final `]` (the one that
    -- closes [Book]) keeps rendering at the far edge.
    local function buttons_visible()
        local s = self.subviews.search
        return s.text == '' and not s.focus
    end
    panel:addviews{
        widgets.BannerPanel{
            frame = {l = 0, t = 0, r = 0, h = 1},
            subviews = {
                widgets.EditField{
                    view_id = 'search',
                    frame = {l = 1, t = 0, r = 1},
                    key = 'CUSTOM_ALT_S',
                    -- last_text is captured HERE and not in the search handler (the handler
                    -- also runs with text='' on every reopen/context flip). But EditField's
                    -- setText() ALSO fires on_change when the text changes (measured:
                    -- edit_field.lua line 177) -- so the scope-exit reset() and the
                    -- closing-frame key flip, which both setText(''), would stomp the
                    -- remembered text at the exact moment the panel closes. Every one of
                    -- those programmatic paths runs when the picker is no longer open, and
                    -- real typing can ONLY happen while it is -- so gate on get_key().
                    on_change = function(text)
                        if self:get_key() then
                            last_text = text
                            trace.typed = text
                        end
                        self:do_search(text)
                    end,
                },
                -- 'Alt+s: ' fills interior cols 1-7; these overlays start at 8
                widgets.Label{frame = {l = 8, t = 0, w = 1}, text = ']', visible = buttons_visible},
                widgets.Label{frame = {l = 10, t = 0, w = 6}, text = '[Food]',
                              on_click = preset('food'), visible = buttons_visible},
                widgets.Label{frame = {l = 17, t = 0, w = 6}, text = '[Heal]',
                              on_click = preset('healing'), visible = buttons_visible},
                -- no closing bracket: the banner's own ']' at the bar's right edge finishes it
                widgets.Label{frame = {l = 24, t = 0, w = 5}, text = '[Book',
                              on_click = preset('book'), visible = buttons_visible},
            },
        },
    }
    self:addviews{panel}

    self:register_handler('INV',
        function() return inventory().option_current end,
        function(vec, data, text, incremental)
            -- peel magic words out of the query; whatever remains searches normally
            local heavy, equipped, food, healing, rest = false, false, false, false, {}
            for _, tok in ipairs(text:split()) do
                local t = tok:lower()
                if t == 'heavy' then heavy = true
                elseif t == 'equip' or t == 'equipped' then equipped = true
                elseif t == 'food' then food = true
                elseif t == 'healing' or t == 'heal' then healing = true
                elseif t ~= '' then rest[#rest + 1] = tok end
            end
            local fns = {get_search_key_fn = get_row_search_key}
            -- the ethics check hits entity records, so resolve it once per search, not per row
            local allow_sapient = (food or healing) and may_eat_sapients() or false
            local filters = {}
            if equipped then filters[#filters + 1] = is_equipped end
            if food then filters[#filters + 1] = function(row) return food_rank(row, allow_sapient) ~= nil end end
            if healing then filters[#filters + 1] = row_heals end
            if #filters > 0 then
                fns.matches_filters_fn = function(row)
                    for _, f in ipairs(filters) do
                        if not f(row) then return false end
                    end
                    return true
                end
            end
            if heavy or equipped or food or healing then
                fns.get_sort_fn = function() return make_sort(heavy, equipped, food or healing, allow_sapient) end
                -- a magic word must act on the FULL list, but while typing one ("heav") the
                -- previous keystroke's ordinary search already filtered the vector down --
                -- force the non-incremental path so single_vector_search restores it first
                incremental = false
            end
            sortoverlay.single_vector_search(fns, vec, data, table.concat(rest, ' '), incremental)
            -- the list just shrank or grew back; a stale scroll offset past the end draws garbage
            local inv = inventory()
            inv.scroll_position = math.max(0, math.min(inv.scroll_position, #inv.option_current - 1))
        end)
end

-- key = active while the screen is open; group = the context (Look/Remove/Wear/...), so a context
-- switch -- which rebuilds option_current -- drops the cached row snapshot instead of restoring
-- the previous context's rows into the new list
function AdvInventorySearchOverlay:get_key()
    local inv = inventory()
    if inv.open then
        return 'INV', tostring(inv.context)
    end
end

-- restore the full list before DF processes a close, so DF's own teardown frees every row.
-- A right-click while the search field is focused only unfocuses it (the base class swallows
-- it and the screen stays open), so that one must not wipe the filter.
function AdvInventorySearchOverlay:onInput(keys)
    local closing = keys.LEAVESCREEN or (keys._MOUSE_R and not self.subviews.search.focus)
    if closing and self:get_key() then
        local data = self.state and self.state.INV
        if data and data.saved_original then
            local vec = inventory().option_current
            vec:assign(data.saved_original)
            vec:resize(data.saved_original_size)
            data.saved_original = nil
        end
    end
    return AdvInventorySearchOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {search = AdvInventorySearchOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('adv/inventory-search: overlay registered.')
print('Open the adventurer inventory (I/r/w/e...) and press Alt-S to search by description,')
print('material or type. Magic words: "heavy" (sort by weight), "equip" (equipped, hands first).')
