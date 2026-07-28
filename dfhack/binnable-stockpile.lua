-- Overlay button for the stockpile config screen: set it to "all binnables".
--@module = true
--[[
On the stockpile category-edit screen (focus dwarfmode/Stockpile/Some/Customize)
this adds controls in the bottom-left corner. Each button TOGGLES only its own
group on/off, so you can compose a pile (binnables + food, food + drink, etc.):

    * all meltables -- a melt-feeder pile: Weapons, Armor and Finished goods
                       restricted to METAL materials EXCEPT adamantine, at
                       below-masterwork quality (no coins, bars/blocks or cages).
                       Ammo is configured the same way but accepts NO item types
                       (its metal bolts/arrows are kept, not melted). Also flips on
                       DFHack's native automelt (logistics) for the pile, so items
                       routed here are auto-designated for melting.
    * all binnables -- the container categories, WITHOUT food/drink: Ammo, Armor,
                       Bars/Blocks, Cloth, Coins, Finished goods, Gems, Leather,
                       Sheets, Weapons.
    * all food      -- everything edible EXCEPT seeds and drinks, with the
                       "Extract (animal)" category trimmed to just milk & honey
                       (the rest is procedural venom/poison/extract clutter).
    * all drink     -- Drink (plant) + Drink (animal).
    * quality       -- a tri-state that overwrites the quality options in Armor,
                       Finished goods, Furniture and Weapons/trap comps:
                         all        -- every quality
                         masterwork -- only masterwork
                         inferior   -- everything except masterwork

Category toggles use DFHack's per-category library presets (cat_*.dfstock);
food/drink/quality are edited directly. Also: clicking an already-selected
main category (or middle-column sub-category) again toggles it all on/off.

Registered automatically as overlay `binnable-stockpile.button`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local stockpiles = require('plugins.stockpiles')
local logistics = require('plugins.logistics')

-- ---- shared helpers -------------------------------------------------------
local function set_elem(v, i, on)
    if type(v[i]) == 'boolean' then v[i] = on else v[i] = on and 1 or 0 end
end
local function set_vec(v, on) for i = 0, #v - 1 do set_elem(v, i, on) end end
local function vec_any_on(v)
    for i = 0, #v - 1 do local e = v[i]
        if (type(e) == 'boolean' and e) or (type(e) == 'number' and e ~= 0) then return true end end
    return false
end
-- any enabled element across every field of a category-settings struct
local function cat_any_on(s)
    if not s then return false end
    for _, v in pairs(s) do
        if type(v) == 'boolean' and v then return true end
        if type(v) == 'userdata' then
            local ok, l = pcall(function() return #v end)
            if ok and l > 0 and vec_any_on(v) then return true end
        end
    end
    return false
end
-- The stockpile being customized. dfhack.gui.getSelectedStockpile is flaky on this screen (returns
-- nil intermittently), so when the customize screen is open we find the building whose settings IS
-- the working copy the screen edits (cs.sp) -- matching by address is reliable.
local function get_sp()
    local cs = df.global.game.main_interface.custom_stockpile
    if cs.open then
        local target = select(2, df.sizeof(cs.sp))
        for _, b in ipairs(df.global.world.buildings.all) do
            if b:getType() == df.building_type.Stockpile and select(2, df.sizeof(b.settings)) == target then
                return b
            end
        end
    end
    local sp = dfhack.gui.getSelectedStockpile(true)
    if not sp then dfhack.printerr('binnable-stockpile: no stockpile selected') end
    return sp
end

-- quality overwrite for a set of categories. quality_core/quality_total are 7-wide:
-- 0 Ordinary .. 5 Masterful (masterwork) .. 6 Artifact.
local QUALITY = {                         -- indices 0..6, 1-based here
    all      = {true, true, true, true, true, true,  true},
    master   = {false, false, false, false, false, true,  true},    -- masterwork + artifact
    inferior = {true, true, true, true, true, false, false},        -- everything below masterwork
}
local function set_quality(sp, mode, cats)
    local set = QUALITY[mode]; if not set then return end
    for _, cat in ipairs(cats) do
        local s = sp.settings[cat]
        if s then
            for _, qf in ipairs({'quality_core', 'quality_total'}) do
                local v = s[qf]
                if v and #v >= 7 then for i = 0, 6 do set_elem(v, i, set[i + 1]) end end
            end
        end
    end
end

-- ---- meltables (non-masterwork, non-adamantine METAL items) ----------------
-- "all meltables" OVERWRITES the pile into a melt-feeder: it enables only the meltable metal
-- categories (Weapons, Armor, Ammo, Finished goods -- deliberately NOT bars/blocks, coins, or cages),
-- restricts their materials to metals EXCEPT adamantine, drops quality to below-masterwork, and turns
-- on DFHack's native automelt (the `logistics` per-stockpile melt flag) so anything routed here gets
-- auto-designated for melting. Toggling off disables those categories and automelt. Food is left alone.
local MELTABLE = {'cat_weapons', 'cat_armor', 'cat_ammo', 'cat_finished_goods'}
local NON_MELTABLE = {'cat_bars_blocks', 'cat_cloth', 'cat_coins', 'cat_gems', 'cat_leather',
    'cat_sheets', 'cat_animals', 'cat_corpses', 'cat_furniture', 'cat_refuse', 'cat_stone', 'cat_wood'}
-- meltable category preset name -> its sp.settings field
local MELT_FIELD = {cat_weapons = 'weapons', cat_armor = 'armor', cat_ammo = 'ammo',
    cat_finished_goods = 'finished_goods'}

-- A category's `mats` bool vector is indexed parallel to raws.inorganics.all; `other_mats` holds the
-- non-inorganic materials. mask[df_idx]=true for every metal inorganic EXCEPT adamantine.
local function metal_mask()
    local mask = {}
    local all = df.global.world.raws.inorganics.all   -- indexed 0-based, parallel to a category's `mats`
    for i = 0, #all - 1 do
        local ino = all[i]
        if ino.material.flags.IS_METAL and ino.id ~= 'ADAMANTINE' then mask[i] = true end
    end
    return mask
end

-- restrict every meltable category to metal-only-minus-adamantine (the categories must already be
-- enabled -- import_settings populates `mats`/`other_mats` -- before this filters them down).
local function set_metal_only(sp)
    local mask = metal_mask()
    for _, field in pairs(MELT_FIELD) do
        local s = sp.settings[field]
        if s then
            for i = 0, #s.mats - 1 do set_elem(s.mats, i, mask[i] == true) end
            set_vec(s.other_mats, false)
        end
    end
end

-- DFHack's per-stockpile automelt state (the native "melt" flag). Returns is_on, config.
local function melt_config(sp)
    local cfgs = logistics.logistics_getStockpileConfigs(sp.stockpile_number)
    local c = cfgs and cfgs[1]
    return (c and c.melt == 1) or false, c
end
-- flip automelt on/off, preserving the pile's other logistics features. melt_masterworks stays off
-- (the quality filter already keeps masterworks out; belt-and-suspenders so none ever get melted).
local function set_melt(sp, on, c)
    logistics.logistics_setStockpileConfig(sp.stockpile_number, on and true or false,
        (c and c.trade == 1) or false, (c and c.dump == 1) or false, (c and c.train == 1) or false,
        (c and c.forbid) or 0, false)
end

-- Toggle: automelt already on for this pile -> turn the meltable categories + automelt OFF; else
-- OVERWRITE into a meltables pile (meltable metal categories on, everything else off, metal-only mats,
-- below-masterwork quality, automelt on). Automelt state is the "meltables mode" indicator.
local function apply_meltables()
    local sp = get_sp(); if not sp then return end
    local on, c = melt_config(sp)
    if on then
        for _, cat in ipairs(MELTABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'disable'}) end
        set_melt(sp, false, c)
        print('binnable-stockpile: meltables OFF')
    else
        for _, cat in ipairs(MELTABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'enable'}) end
        for _, cat in ipairs(NON_MELTABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'disable'}) end
        set_metal_only(sp)
        set_quality(sp, 'inferior', {'weapons', 'armor', 'ammo', 'finished_goods'})
        -- ammo stays fully configured (metal mats + below-masterwork quality) but accepts NO ammo:
        -- zero its item-type list so bolts/arrows/etc. never land here (metal bolts are too handy to melt).
        set_vec(sp.settings.ammo.type, false)
        set_melt(sp, true, c)
        print('binnable-stockpile: set to all meltables (metal, no adamantine, below masterwork; automelt on)')
    end
end

-- ---- binnables (container categories, WITHOUT food/drink) ------------------
-- "all binnables" OVERWRITES the pile to a binnables pile: it turns the container categories fully
-- ON and the non-container ones OFF, and resets their quality to "all". It deliberately leaves the
-- food category alone, so food/drink (their own toggles) compose on top -- and a binnables pile no
-- longer drags in cat_food's procedural venom/ink/forgotten-beast extract clutter.
local BINNABLE = {'cat_ammo', 'cat_armor', 'cat_bars_blocks', 'cat_cloth', 'cat_coins',
    'cat_finished_goods', 'cat_gems', 'cat_leather', 'cat_sheets', 'cat_weapons'}
local NON_BINNABLE = {'cat_animals', 'cat_corpses', 'cat_furniture', 'cat_refuse', 'cat_stone', 'cat_wood'}
local CAT_FIELD = {cat_ammo = 'ammo', cat_armor = 'armor', cat_bars_blocks = 'bars_blocks',
    cat_cloth = 'cloth', cat_coins = 'coins', cat_finished_goods = 'finished_goods',
    cat_gems = 'gems', cat_leather = 'leather', cat_sheets = 'sheet', cat_weapons = 'weapons'}

-- Toggle: if it's ALREADY a full binnables pile (every binnable category on) turn those categories
-- OFF; otherwise OVERWRITE into a binnables pile (all binnable categories on, non-container ones off,
-- quality reset to "all"). Checking "every" (not "any") is what makes a half-configured pile overwrite
-- to full instead of getting wiped. Food is left alone, so food/drink compose on top.
local function apply_binnables()
    local sp = get_sp(); if not sp then return end
    local all_on = true
    for _, cat in ipairs(BINNABLE) do
        if not cat_any_on(sp.settings[CAT_FIELD[cat]]) then all_on = false; break end
    end
    if all_on then
        for _, cat in ipairs(BINNABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'disable'}) end
        print('binnable-stockpile: binnables OFF')
    else
        for _, cat in ipairs(BINNABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'enable'}) end
        for _, cat in ipairs(NON_BINNABLE) do stockpiles.import_settings('library/' .. cat, {id = sp.id, mode = 'disable'}) end
        set_quality(sp, 'all', {'armor', 'finished_goods', 'weapons'})
        print('binnable-stockpile: set to all binnables')
    end
end

-- ---- food + drink (both live in the single food category) ------------------
local DRINK_FIELDS = {drink_plant = true, drink_animal = true}

-- extract-animal ("Extract (animal)") = organic category CreatureLiquid, indexed parallel to
-- mat_table.organic. Keep only MILK + HONEY; the rest is procedural venom/poison/extract clutter.
local function set_extracts_milk_honey(f)
    local mt = df.global.world.raws.mat_table
    local c = df.organic_mat_category.CreatureLiquid
    local types, idxs = mt.organic_types[c], mt.organic_indexes[c]
    local la = f.liquid_animal
    for i = 0, #la - 1 do
        local mi = dfhack.matinfo.decode(types[i], idxs[i])
        local id = mi and mi.material and mi.material.id
        set_elem(la, i, id == 'MILK' or id == 'HONEY')
    end
end

-- The food vectors are empty until the food category is touched. Populate them if needed, starting
-- from all-OFF so the food/drink toggles only turn on what they mean to (and don't clobber a group
-- the other button owns).
local function ensure_food(sp)
    local f = sp.settings.food
    if #f.drink_plant > 0 then return f end
    stockpiles.import_settings('library/cat_food', {id = sp.id, mode = 'enable'})
    for k, v in pairs(f) do
        if type(v) == 'boolean' then f[k] = false
        elseif type(v) == 'userdata' then local ok = pcall(function() return #v end); if ok then set_vec(v, false) end end
    end
    return f
end

-- iterate the food fields we manage as "food" (everything except the two drink fields)
local function food_fields(f, fn)
    for k, v in pairs(f) do
        if not DRINK_FIELDS[k] and (type(v) == 'boolean' or type(v) == 'userdata') then fn(k, v) end
    end
end

-- toggle non-drink food: all edible food EXCEPT seeds and drinks, extract-animal = milk/honey
local function apply_food()
    local sp = get_sp(); if not sp then return end
    local f = ensure_food(sp)
    local on = false
    food_fields(f, function(k, v)
        if not on then
            if type(v) == 'boolean' then on = v
            else local ok, l = pcall(function() return #v end); on = ok and l > 0 and vec_any_on(v) end
        end
    end)
    if on then
        food_fields(f, function(k, v) if type(v) == 'boolean' then f[k] = false else set_vec(v, false) end end)
    else
        food_fields(f, function(k, v)
            if k ~= 'seeds' then if type(v) == 'boolean' then f[k] = true else set_vec(v, true) end end
        end)
        set_extracts_milk_honey(f)
    end
    print('binnable-stockpile: food ' .. (on and 'OFF' or 'ON'))
end

-- toggle drinks (Drink (plant) + Drink (animal))
local function apply_drink()
    local sp = get_sp(); if not sp then return end
    local f = ensure_food(sp)
    local on = vec_any_on(f.drink_plant) or vec_any_on(f.drink_animal)
    set_vec(f.drink_plant, not on); set_vec(f.drink_animal, not on)
    print('binnable-stockpile: drink ' .. (on and 'OFF' or 'ON'))
end

-- ---- quality tri-state (armor / finished goods / furniture / weapons+trapcomps) -----------
local QUALITY_CATS = {'armor', 'finished_goods', 'furniture', 'weapons'}
local function apply_quality(mode)
    local sp = get_sp(); if not sp then return end
    set_quality(sp, mode, QUALITY_CATS)
    print('binnable-stockpile: quality -> ' .. mode)
end

BinnableButton = defclass(BinnableButton, overlay.OverlayWidget)
BinnableButton.ATTRS{
    desc = 'Stockpile screen: toggle meltables / binnables / food / drink groups, and a quality tri-state.',
    default_pos = {x = 8, y = -5},   -- bottom-left area, clear of the native buttons
    default_enabled = true,
    viewscreens = 'dwarfmode/Stockpile/Some/Customize',
    frame = {w = 26, h = 5},
    version = 7,   -- bumped so the new size/position takes effect (added meltables row, nudged down)
}

function BinnableButton:init()
    self:addviews{
        widgets.TextButton{
            view_id = 'meltables', frame = {t = 0, l = 0, w = 26, h = 1},
            label = 'all meltables', key = 'CUSTOM_CTRL_M', on_activate = apply_meltables,
        },
        widgets.TextButton{
            view_id = 'binnables', frame = {t = 1, l = 0, w = 26, h = 1},
            label = 'all binnables', key = 'CUSTOM_CTRL_B', on_activate = apply_binnables,
        },
        widgets.TextButton{
            view_id = 'food', frame = {t = 2, l = 0, w = 26, h = 1},
            label = 'all food', key = 'CUSTOM_CTRL_F', on_activate = apply_food,
        },
        widgets.TextButton{
            view_id = 'drink', frame = {t = 3, l = 0, w = 26, h = 1},
            label = 'all drink', key = 'CUSTOM_CTRL_D', on_activate = apply_drink,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'quality', frame = {t = 4, l = 0, w = 26, h = 1},
            label = 'quality', key = 'CUSTOM_CTRL_Q',
            options = {
                {label = '(set)', value = 'none'},
                {label = 'all', value = 'all'},
                {label = 'masterwork', value = 'master'},
                {label = 'inferior', value = 'inferior'},
            },
            on_change = function(new) if new ~= 'none' then apply_quality(new) end end,
        },
    }
end

-- ---- click an already-selected category again to toggle it all on/off ----------------------
-- Re-click model (no click-timing): when the category that is ALREADY selected gets clicked again,
-- toggle every item under it on/off (so a triple-click = on, then off). The column is found by
-- SCANNING the "All" header buttons, so it survives any font/window resize -- no hardcoded coords.

-- A category (or sub-category) settings object holds every filter -- item types, materials
-- (mats/other_mats) and quality (quality_core/quality_total) -- as boolean or number flags, some
-- loose, some in vectors. Toggling a category flips ALL of them together (a full on/off, like the
-- native "All"/"None"), so we do not special-case any field. Wood/Stone hold only `mats`; corpses
-- only `corpses`; that all just works when we visit every field.
local function elem_on(e)
    local t = type(e)
    return (t == 'boolean' and e) or (t == 'number' and e ~= 0)
end
local function any_on(obj)
    for _, v in pairs(obj) do
        if elem_on(v) then return true end
        if type(v) == 'userdata' then
            local ok, len = pcall(function() return #v end)
            if ok then for i = 0, len - 1 do if elem_on(v[i]) then return true end end end
        end
    end
    return false
end

-- category settings field name -> DFHack library preset name (mostly cat_<name>; "sheet" is plural)
local function cat_preset(name)
    return name == 'sheet' and 'library/cat_sheets' or ('library/cat_' .. name)
end

-- x-positions of the "All" column headers, and the row they sit on. Scans the top rows and keeps the
-- row with the MOST "All" markers -- normal categories have 3 columns, but Wood/Stone/Corpses have no
-- middle column and show only 2, so we require >=2 (not 3) or those would be skipped. Resolution-
-- independent (scans rendered tiles); returns nil if no header row is found.
local function all_columns()
    local gps = df.global.gps
    local function ch(x, y) local ok, c = pcall(dfhack.screen.readTile, x, y); return (ok and c and c.ch) or 0 end
    local best, best_y
    for y = 0, math.min(gps.dimy - 1, 20) do
        local xs, x = {}, 0
        while x < gps.dimx - 2 do
            if ch(x, y) == 65 and ch(x + 1, y) == 108 and ch(x + 2, y) == 108 then   -- "All"
                xs[#xs + 1] = x; x = x + 3
            else x = x + 1 end
        end
        if #xs >= 2 and (not best or #xs > #best) then best, best_y = xs, y end
    end
    return best, best_y
end

-- the sp.settings field name of the selected MAIN category. cur_main_mode is a category VALUE, not
-- an index, so we find its row in main_mode and read that row's group_set identity (the one flag it
-- sets is the category's name -- animals / food / bars_blocks / ...).
local function main_cat_name(cs)
    for i = 0, #cs.main_mode - 1 do
        if cs.main_mode[i] == cs.cur_main_mode then
            local gs = cs.main_mode_flag[i]
            if gs then for k, v in pairs(gs) do if v == true then return tostring(k) end end end
            return
        end
    end
end

-- ---- middle (sub-category) column: re-click a sub to toggle all its spec items -----------------
-- There's no clean write path for a sub (its sub_mode_ptr is nil, spec_item[] is a stale display
-- cache, and subs like Metal/Gem/Stone are slices of one field). So instead we let DF do it: on a
-- re-click we move the mouse onto col3's own "All"/"None" header and hand the real click to the
-- native screen, which toggles exactly the selected sub's items (slices included). Direction still
-- needs the current on/off state; for that we read the sub's backing vector out of cs.sp.

-- x of the "None" header on row y, at/after x0 (its "All" twin is at cols[3])
local function none_x(y, x0)
    local function ch(x) local ok, c = pcall(dfhack.screen.readTile, x, y); return (ok and c and c.ch) or 0 end
    for x = x0, df.global.gps.dimx - 4 do
        if ch(x) == 78 and ch(x + 1) == 111 and ch(x + 2) == 110 and ch(x + 3) == 101 then return x end
    end
end

-- Is any item in the currently-selected sub-category enabled? Read straight from the live col3
-- item list (spec_item[].set_pointer points at the real setting byte, 0 = off). This is robust
-- where a positional field map isn't: subs like Stone/clay|Metal|Gem are three slices of ONE
-- field, and Color / Total quality then land on the wrong field -- but their col3 items are always
-- exactly what's shown, so reading those directly gives the right on/off state every time.
local function sub_any_on(cs)
    for i = 0, cs.cur_spec_item_sz - 1 do
        if cs.spec_item[i].set_pointer.value ~= 0 then return true end
    end
    return false
end

CategoryToggle = defclass(CategoryToggle, overlay.OverlayWidget)
CategoryToggle.ATTRS{
    desc = 'Stockpile customize: click an already-selected category again to toggle it all on/off.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Stockpile/Some/Customize',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

-- is the click on our OWN all-binnables/food/drink/quality buttons (a separate overlay)? Those sit
-- bottom-left, overlapping the main-category column, so without this guard clicking "all food"
-- would be misread as a re-click on the selected category and toggle it. Both overlays live on the
-- same screen, so the button overlay's frame_rect is valid here.
local function over_buttons(mx, my)
    local e = overlay.get_state().db['binnable-stockpile.button']
    local r = e and e.widget and e.widget.frame_rect
    return (r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2) and true or false
end

function CategoryToggle:onInput(keys)
    if keys._MOUSE_L then
        local cs = df.global.game.main_interface.custom_stockpile
        local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
        if over_buttons(mx, my) then return false end   -- a click on our buttons, not a category re-click
        local cols, all_y = all_columns()
        -- Only act on clicks in the list area (below the "All/None" header row). This deliberately
        -- ignores clicks ON the header -- including the phantom click DF replays at the position we
        -- redirect to below -- so those never overwrite self.prev and steal the next real re-click.
        if cols and all_y and my > all_y then
            -- second click on the SAME middle-column (sub-category) row: redirect this real click onto
            -- col3's All/None so the native screen toggles the sub. Only for 3-column categories.
            if cols[3] and self.prev and my == self.prev.my and mx >= cols[2] and mx < cols[3]
               and cs.cur_spec_item_sz > 0 then
                -- Direction = flip the current state. cs.sp lags a frame behind a just-applied
                -- toggle, so on rapid re-clicks of the SAME sub we trust our own last-applied
                -- state instead of the stale read -- keeps 3rd/4th clicks alternating, not no-op.
                local key = cs.cur_main_mode .. '/' .. cs.cur_sub_mode
                local current
                if self.applied and self.applied.key == key then current = self.applied.state
                else current = sub_any_on(cs) end
                local target_on = not current
                -- target on -> col3 "All"; target off -> col3 "None"
                df.global.gps.mouse_x = target_on and cols[3] or (none_x(all_y, cols[3] + 3) or cols[3])
                df.global.gps.mouse_y = all_y
                self.applied = {key = key, state = target_on}
                self.restore = {mx = mx, my = my}   -- put the cursor back next frame (see below)
            end
            self.prev = {mx = mx, my = my}
            -- also record the pre-click main category for the col1 re-click test judged next frame
            self.pending = {mx = mx, my = my, cm = cs.cur_main_mode}
        end
    end
    return false   -- never consume the click; DF still does its own selection
end

function CategoryToggle:overlay_onupdate()
    -- After a redirect DF leaves gps.mouse parked on the header (it only refreshes the cursor on real
    -- OS movement), so the user's next stationary click would land on "All/None" and do nothing. Put
    -- the cursor back on the row they actually clicked so consecutive clicks keep toggling.
    if self.restore then
        df.global.gps.mouse_x = self.restore.mx
        df.global.gps.mouse_y = self.restore.my
        self.restore = nil
    end
    local p = self.pending
    if not p then return end
    self.pending = nil
    local cols, all_y = all_columns()
    if not cols or p.my <= all_y then return end   -- need the header row; ignore clicks on it
    -- only the MAIN-category (left) column: a click left of the 2nd "All" header. Wood/Stone/Corpses
    -- have no middle column so cols[2] is their spec-item "All", which still sits right of the list.
    if p.mx >= cols[2] then return end
    local cs = df.global.game.main_interface.custom_stockpile
    -- toggle only when the SAME category is still selected after the click (i.e. a re-click, not a
    -- switch to a new category) -- so first click selects, next click flips the whole category
    if cs.cur_main_mode ~= p.cm then return end
    local sp = dfhack.gui.getSelectedStockpile(true)
    local name = sp and main_cat_name(cs)
    if name and sp.settings[name] then
        -- flip the whole category on/off via DFHack's own preset (item types + materials + quality
        -- together; populates the enable vectors so even a never-touched category still toggles)
        local mode = any_on(sp.settings[name]) and 'disable' or 'enable'
        stockpiles.import_settings(cat_preset(name), {id = sp.id, mode = mode})
    end
end

OVERLAY_WIDGETS = {button = BinnableButton, category_toggle = CategoryToggle}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('binnable-stockpile: registered overlay binnable-stockpile.button')
