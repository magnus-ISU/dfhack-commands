-- Overlay button for the stockpile config screen: set it to "all binnables".
--@module = true
--[[
On the stockpile category-edit screen (focus dwarfmode/Stockpile/Some/Customize)
this adds a single button in the very bottom-left corner:

    * all binnables  -- configures the selected stockpile to accept exactly the
                        item categories that live in a bin, barrel, bag, or pot.

"Binnable" = every category that uses a container. Enabled:
    Ammo, Armor, Bars/Blocks, Cloth, Coins, Finished goods, Food, Gems,
    Leather, Sheets, Weapons
Disabled (no container -- loose on the floor / in cages):
    Animals, Corpses, Furniture, Refuse, Stone, Wood

So the click both turns the binnable categories fully ON and turns the
non-binnable ones OFF -- the pile ends up holding exactly the container goods,
no matter what it held before. Implemented by importing DFHack's own per-category
library presets (cat_*.dfstock), so it tracks item subtypes across versions.

Registered automatically as overlay `binnable-stockpile.button`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local stockpiles = require('plugins.stockpiles')

-- Category library presets that use a container (bin / barrel / bag / pot).
local BINNABLE = {
    'cat_ammo', 'cat_armor', 'cat_bars_blocks', 'cat_cloth', 'cat_coins',
    'cat_finished_goods', 'cat_food', 'cat_gems', 'cat_leather', 'cat_sheets',
    'cat_weapons',
}

-- Everything else: never stored in a container, so we clear it.
local NON_BINNABLE = {
    'cat_animals', 'cat_corpses', 'cat_furniture', 'cat_refuse', 'cat_stone',
    'cat_wood',
}

local function apply_binnables()
    local sp = dfhack.gui.getSelectedStockpile(true)
    if not sp then
        dfhack.printerr('binnable-stockpile: no stockpile selected')
        return
    end
    -- enable the binnable categories (whole-category on), disable the rest
    for _, name in ipairs(BINNABLE) do
        stockpiles.import_settings('library/' .. name, {id = sp.id, mode = 'enable'})
    end
    for _, name in ipairs(NON_BINNABLE) do
        stockpiles.import_settings('library/' .. name, {id = sp.id, mode = 'disable'})
    end
    print('binnable-stockpile: set stockpile #' .. sp.id .. ' to all binnables')
end

BinnableButton = defclass(BinnableButton, overlay.OverlayWidget)
BinnableButton.ATTRS{
    desc = 'Stockpile screen button: set the pile to accept all binnable/barrelable items.',
    default_pos = {x = 8, y = -5},   -- bottom-left area, clear of the native buttons
    default_enabled = true,
    viewscreens = 'dwarfmode/Stockpile/Some/Customize',
    frame = {w = 26, h = 1},
    version = 2,   -- bumped so the moved default position takes effect
}

function BinnableButton:init()
    self:addviews{
        widgets.TextButton{
            view_id = 'binnables',
            frame = {t = 0, l = 0, w = 26, h = 1},
            label = 'all binnables',
            key = 'CUSTOM_CTRL_B',
            on_activate = apply_binnables,
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

-- the cs.sp vector backing the selected sub-category. The col2 list shows the settings struct's
-- len>0 vector fields in declaration order (empty fields are hidden; boolean/special subs carry a
-- non-NONE sub_mode_ptr_type), so the Nth NONE-type sub is the Nth len>0 vector field. Positional,
-- so it stays correct even when two fields share a length (e.g. fish vs unprepared_fish).
local function sub_vector(cs)
    local mn = main_cat_name(cs)
    local s = mn and cs.sp[mn]
    if not s then return end
    local fields = {}
    for _, v in pairs(s) do
        if type(v) == 'userdata' then
            local ok, l = pcall(function() return #v end)
            if ok and l > 0 then fields[#fields + 1] = v end
        end
    end
    local pos = 0
    for i = 0, #cs.sub_mode - 1 do
        if cs.sub_mode_ptr_type[i] == df.stock_pile_pointer_type.NONE then
            if cs.sub_mode[i] == cs.cur_sub_mode then return fields[pos + 1] end
            pos = pos + 1
        end
    end
end

local function any_elem_on(field)
    for i = 0, #field - 1 do
        local e = field[i]
        if (type(e) == 'boolean' and e) or (type(e) == 'number' and e ~= 0) then return true end
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

function CategoryToggle:onInput(keys)
    if keys._MOUSE_L then
        local cs = df.global.game.main_interface.custom_stockpile
        local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
        local cols, all_y = all_columns()
        -- Only act on clicks in the list area (below the "All/None" header row). This deliberately
        -- ignores clicks ON the header -- including the phantom click DF replays at the position we
        -- redirect to below -- so those never overwrite self.prev and steal the next real re-click.
        if cols and all_y and my > all_y then
            -- second click on the SAME middle-column (sub-category) row: redirect this real click onto
            -- col3's All/None so the native screen toggles the sub. Only for 3-column categories.
            if cols[3] and self.prev and my == self.prev.my and mx >= cols[2] and mx < cols[3] then
                local field = sub_vector(cs)
                if field then
                    -- Direction = flip the current state. cs.sp lags a frame behind a just-applied
                    -- toggle, so on rapid re-clicks of the SAME sub we trust our own last-applied
                    -- state instead of the stale read -- keeps 3rd/4th clicks alternating, not no-op.
                    local key = cs.cur_main_mode .. '/' .. cs.cur_sub_mode
                    local current
                    if self.applied and self.applied.key == key then current = self.applied.state
                    else current = any_elem_on(field) end
                    local target_on = not current
                    -- target on -> col3 "All"; target off -> col3 "None"
                    df.global.gps.mouse_x = target_on and cols[3] or (none_x(all_y, cols[3] + 3) or cols[3])
                    df.global.gps.mouse_y = all_y
                    self.applied = {key = key, state = target_on}
                    self.restore = {mx = mx, my = my}   -- put the cursor back next frame (see below)
                end
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
