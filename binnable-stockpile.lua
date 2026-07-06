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
    default_pos = {x = 1, y = -4},   -- bottom-left, 3 rows up to clear the native buttons
    default_enabled = true,
    viewscreens = 'dwarfmode/Stockpile/Some/Customize',
    frame = {w = 26, h = 1},
    version = 1,
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

OVERLAY_WIDGETS = {button = BinnableButton}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('binnable-stockpile: registered overlay binnable-stockpile.button')
