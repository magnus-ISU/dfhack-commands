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
        -- record the pre-click main category + where the click landed; judge the result next frame
        -- (DF selects on this same click, so we compare cur_main_mode before vs after to spot a re-click)
        local cs = df.global.game.main_interface.custom_stockpile
        self.pending = {mx = df.global.gps.mouse_x, my = df.global.gps.mouse_y, cm = cs.cur_main_mode}
    end
    return false   -- never consume the click; DF still does its own selection
end

function CategoryToggle:overlay_onupdate()
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
