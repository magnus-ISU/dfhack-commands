-- Combat-exertion meter for adventure mode (blood-meter manners and placement).
--@module = true
--[[
adv/exhaustion-meter

One bar with DF's native blood meter's manners: INVISIBLE while you are fine,
appearing in the blood meter's corner (bottom-left, above the action bar) once
combat exertion starts to matter, and draining toward empty = you collapse.

``Ex`` tracks counters2.exhaustion -- the counter built by attacking, sprinting
and jumping that knocks you over mid-fight (DF shows no meter for it at all):
green once winded past half-Tired, yellow at Tired (2,000), red at Exhausted
(4,000), empty at the ~6,000 falling-over point. It decays quickly when you
stop exerting yourself.

Overlay `adv/exhaustion-meter.meter`, enabled by default; reposition with
gui/overlay.
]]

local overlay = require('plugins.overlay')

local TIRED = 2000             -- exertion "Tired"
local EXHAUSTED = 4000         -- exertion "Exhausted" (stumbling starts)
local COLLAPSE = 6000          -- falling-over point; the bar is empty here
local SHOW_AT = TIRED // 2     -- appear once meaningfully winded
local BAR_W = 10               -- cells in the bar

ExhaustionMeter = defclass(ExhaustionMeter, overlay.OverlayWidget)
ExhaustionMeter.ATTRS{
    desc = 'Combat-exertion meter that runs out as collapse nears.',
    default_pos = {x = 2, y = -4},   -- the native blood meter's corner
    default_enabled = true,
    viewscreens = 'dungeonmode/Default',
    frame = {w = BAR_W + 9, h = 1},
    overlay_onupdate_max_freq_seconds = 0.5,
}

function ExhaustionMeter:overlay_onupdate()
    local adv = dfhack.world.getAdventurer()
    self.exert_v = adv and adv.counters2.exhaustion or nil
end

function ExhaustionMeter:onRenderBody(dc)
    local v = self.exert_v
    if not v or v < SHOW_AT then return end
    local remaining = math.max(0, 1 - v / COLLAPSE)
    local cells = math.floor(remaining * BAR_W + 0.5)
    if remaining > 0 and cells == 0 then cells = 1 end
    local pen
    if v >= EXHAUSTED then pen = COLOR_LIGHTRED
    elseif v >= TIRED then pen = COLOR_YELLOW
    else pen = COLOR_LIGHTGREEN end
    dc:seek(0, 0):pen{fg = COLOR_WHITE, bg = COLOR_BLACK}:string('Ex ')
    dc:pen{fg = pen, bg = COLOR_BLACK}:string(string.rep(string.char(219), cells))
    dc:pen{fg = COLOR_DARKGREY, bg = COLOR_BLACK}:string(string.rep(string.char(177), BAR_W - cells))
    dc:pen{fg = pen, bg = COLOR_BLACK}:string((' %3d%%'):format(math.floor(remaining * 100 + 0.5)))
end

OVERLAY_WIDGETS = {meter = ExhaustionMeter}

if dfhack_flags and dfhack_flags.module then return end

require('plugins.overlay').rescan()
local adv = dfhack.world.getAdventurer()
if adv then
    print(('exhaustion-meter: exertion %d (Tired %d, collapse ~%d); the bar shows once past %d.')
        :format(adv.counters2.exhaustion, TIRED, COLLAPSE, SHOW_AT))
end
print('adv/exhaustion-meter: combat-exertion bar in the blood meter corner '
    .. '(overlay adv/exhaustion-meter.meter; gui/overlay to move).')
