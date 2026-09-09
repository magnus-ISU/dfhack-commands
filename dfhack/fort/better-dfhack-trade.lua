-- Open DFHack's trade window at a usable size, with the caravan's goods and the fort's side by
-- side instead of behind two tabs.
--@module = true
--@enable = true
--[[
better-dfhack-trade

DFHack's trade UI is one small window with a tab bar: `Caravan goods` on one tab, `Fort goods`
on the other. Trading is a comparison -- what they will give you against what you are giving up
-- and a comparison across a tab switch is not a comparison at all. This replaces the screen
with TWO windows, side by side:

    +--------------------------+--------------------------+  +----------+
    |      Caravan goods       |        Fort goods        |  | minimap  |
    |  what they are selling   |   what you are offering  |  +----------+
    +--------------------------+--------------------------+

Each is a whole trade window in its own right -- its own search, sort, filters, sliders and
selections, all of DFHack's own -- just locked to one side of the trade instead of sharing a tab
bar. The tab bar is hidden and the window title says which side it is.

THE SIZE IS THE POINT AS MUCH AS THE SPLIT. The pair opens against the edges of the screen: four
rows of margin at the top, three columns at the left, three rows at the bottom, and on the right
just enough room left for the WHOLE MINIMAP, so the thing that tells you where the depot is
stays visible while you trade. The split is down the middle of what is left. Both windows are
still DFHack windows -- drag them, resize them, they are yours after that; this is only where
they start.

The minimap's width is measured rather than assumed: DF draws the minimap itself, so those
cells come back from the tile grid with nothing in them, and the run of empty columns at the top
right IS the minimap. A reading that makes no sense (a handful of columns, or a third of the
screen) is thrown away for a sane default, and a fort with the minimap turned off gets the full
width, since there is nothing there to keep clear.

    better-dfhack-trade           patch DFHack's trade UI (idempotent)
    enable better-dfhack-trade    the same, and re-apply on every map load
    disable better-dfhack-trade   put DFHack's own single-window trade UI back

The patch is a swap of the class DFHack's own `DFHack trade UI` button builds, so the button,
the keybinding and everything else that opens the trade UI open this instead. `magnus-scripts`
turns it on.
]]

local GLOBAL_KEY = 'better-dfhack-trade'

local gui = require('gui')
local widgets = require('gui.widgets')

local trademod = reqscript('internal/caravan/trade')

-- ---- where the windows go ----------------------------------------------------

local MARGIN_TOP = 4
local MARGIN_LEFT = 3
local MARGIN_BOTTOM = 3

-- the minimap sits in the top-right corner; row 4 is inside it and above every panel
local MINIMAP_PROBE_ROW = 4
local MINIMAP_MIN_W = 8         -- fewer empty columns than this is not a minimap
local MINIMAP_DEFAULT_W = 24    -- what it measures as on this build, for when the read is junk

-- Is DF painting this cell? The map, the panels and every bit of text come back from the tile
-- grid with a character or a texture; the minimap is drawn by DF on its own and comes back
-- empty, which is what makes it measurable.
local function is_painted(x, y)
    local ok, pen = pcall(dfhack.screen.readTile, x, y)
    if not ok or not pen then return false end
    if pen.tile and pen.tile ~= 0 then return true end
    return pen.ch and pen.ch > 32 and pen.ch < 127
end

-- how many columns of the right edge the minimap takes (0 when there is no minimap)
function minimap_width()
    local sw = dfhack.screen.getWindowSize()
    local blank = 0
    for x = sw - 1, math.floor(sw / 2), -1 do
        if is_painted(x, MINIMAP_PROBE_ROW) then break end
        blank = blank + 1
    end
    if blank < MINIMAP_MIN_W then return 0 end                    -- minimap off: use the room
    if blank > math.floor(sw / 3) then return MINIMAP_DEFAULT_W end   -- nonsense: fall back
    return blank
end

-- the two window frames: the left half and the right half of everything the margins leave
function side_frames()
    local sw = dfhack.screen.getWindowSize()
    local right = minimap_width()
    local avail = sw - MARGIN_LEFT - right
    local half = math.floor(avail / 2)
    return {t = MARGIN_TOP, b = MARGIN_BOTTOM, l = MARGIN_LEFT, w = half},
           {t = MARGIN_TOP, b = MARGIN_BOTTOM, l = MARGIN_LEFT + half, r = right}
end

-- ---- one side of the trade ---------------------------------------------------

-- DFHack's own trade window, locked to one side. Everything it does -- the choices, the
-- filters, the selection, the bin handling -- is theirs and untouched; `cur_page` is the field
-- their tab bar writes, so setting it and hiding the tab bar is the whole change.
BetterTrade = defclass(BetterTrade, trademod.Trade)
BetterTrade.ATTRS{
    page = 1,       -- 1 = the caravan's goods, 2 = the fort's
}

function BetterTrade:init()
    self.frame_title = self.page == 1 and 'Caravan goods' or 'Fort goods'
    -- Hide the tab bar. It is the one widget in there with a `get_cur_page`, which is a surer
    -- way to find it than a position: the layout above it is fixed, so nothing moves and the
    -- two rows it leaves are the gap under the sort and bins controls.
    for _, view in ipairs(self.subviews) do
        if view.get_cur_page then view.visible = false end
    end
    if self.page ~= 1 then
        self.cur_page = self.page
        self:refresh_list()
    end
end

-- ---- the screen that holds both ----------------------------------------------

-- gui.ZScreen rather than a subclass of DFHack's TradeScreen: that one builds its single window
-- in its own init, and a screen with a stray third window on it is worse than repeating the
-- three short methods it defines. `focus_path` is deliberately the same as theirs, since their
-- own code (and ours) matches on `dfhack/lua/caravan/trade`.
BetterTradeScreen = defclass(BetterTradeScreen, gui.ZScreen)
BetterTradeScreen.ATTRS{
    focus_path = 'caravan/trade',
}

function BetterTradeScreen:init()
    local left, right = side_frames()
    self.windows = {
        BetterTrade{page = 1, frame = left},
        BetterTrade{page = 2, frame = right},
    }
    self:addviews(self.windows)
end

-- a click that lands on neither window may have been DF's own "trade" or "offer" button, and
-- the cached item lists are stale the moment it is: this is DFHack's own reset, over two windows
function BetterTradeScreen:onInput(keys)
    if self.reset_pending then return false end
    local handled = BetterTradeScreen.super.onInput(self, keys)
    if keys._MOUSE_L then
        local on_a_window = false
        for _, w in ipairs(self.windows) do
            if w:getMouseFramePos() then on_a_window = true end
        end
        if not on_a_window then self.reset_pending = true end
    end
    return handled
end

function BetterTradeScreen:onRenderFrame()
    if not df.global.game.main_interface.trade.open then
        self:dismiss()
    elseif self.reset_pending and
        (dfhack.gui.matchFocusString('dfhack/lua/caravan/trade') or
         dfhack.gui.matchFocusString('dwarfmode/Trade/Default'))
    then
        self.reset_pending = nil
        for _, w in ipairs(self.windows) do w:reset_cache() end
    end
end

function BetterTradeScreen:onDismiss()
    -- the handle DFHack's own button checks before opening another one
    trademod.trade_view = nil
end

-- ---- the patch ---------------------------------------------------------------

-- DFHack's trade UI is opened from several places -- the banner button on the trade screen, its
-- keybinding -- and every one of them builds `TradeScreen` by name out of that module's own
-- globals, at the moment of the click. Swapping the name is therefore the whole hook: no
-- copies, no wrappers, and the original is kept so `disable` can put it back.
local function original()
    return dfhack.internal.better_dfhack_trade_original
end

function is_patched()
    return trademod.TradeScreen == BetterTradeScreen
end

function patch()
    if is_patched() then return false end
    dfhack.internal.better_dfhack_trade_original =
        original() or trademod.TradeScreen
    trademod.TradeScreen = BetterTradeScreen
    return true
end

function unpatch()
    if not original() then return false end
    trademod.TradeScreen = original()
    return true
end

-- ---- enable/disable ----------------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

local function set_enabled(v)
    enabled = v
    if v then patch() else unpatch() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    -- the trade module can be reloaded out from under us on a world change, which puts their
    -- own class back; re-apply rather than quietly reverting to the tabbed window
    if sc == SC_MAP_LOADED and enabled then
        trademod = reqscript('internal/caravan/trade')
        dfhack.internal.better_dfhack_trade_original = nil
        patch()
    end
end

if dfhack_flags and dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('better-dfhack-trade: ' .. (enabled and 'on -- DFHack\'s trade UI opens as two windows'
                                              or 'off -- DFHack\'s own trade window is back'))
    return
end

set_enabled(true)
print('better-dfhack-trade: DFHack\'s trade UI now opens as two windows, caravan goods on the')
print('left and fort goods on the right, sized to the screen with the minimap left clear.')
