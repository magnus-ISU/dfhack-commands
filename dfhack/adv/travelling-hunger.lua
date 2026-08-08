-- Show the adventurer's hunger, thirst and sleep debt on the fast-travel screen.
--@module = true
--[[
adv/travelling-hunger

Fast travel is when hunger, thirst and drowsiness quietly pile up, and the travel screen shows
none of them. This overlay paints all three on the top row while travelling, as the number of
meals / drinks / 8-hour sleeps it takes to get back under the hungry/thirsty/drowsy thresholds
("Food: 2  Drink: 4  Sleep: 1") -- green when fine, yellow when behind, red when 3+ behind.

Mechanics (measured, see the eat/drink notes): DF flags Hungry at hunger_timer 50000 and
Thirsty at thirst_timer 25000; eating or drinking one item takes 50000 off the counter.
Drowsy starts at sleepiness_timer 57600 -- the same number where DF's own speed/skill
penalties kick in (Units.cpp rates drowsiness in bands 57600 / 150000 / ... / 864000).
The sleep budget: an adventure-mode hour is 7200 ticks, awake gains 1/tick and sleep works
off 2/tick, so a full 8-hour sleep clears 8*7200*2 = 115200 -- exactly the 16 waking hours
of a balanced day, which is why one night's sleep normally resets you. "Sleep: N" is how
many such sleeps until you're under the Drowsy line.

The adventurer unit stays readable through dfhack.world.getAdventurer() while the Travel
screen is up at the starting position, so the overlay just reads three ints per render.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local HUNGRY = 50000     -- hunger_timer where DF says Hungry
local THIRSTY = 25000    -- thirst_timer where DF says Thirsty
local PER_ITEM = 50000   -- one meal/drink takes this much off its counter
local DROWSY = 57600     -- sleepiness_timer where DF says Drowsy (penalty band starts here)
local PER_SLEEP = 115200 -- one 8-hour sleep works this much off (8h * 7200 ticks * 2/tick)

-- items/sleeps needed to get back under the threshold (0 = fine)
local function items_behind(v, threshold, per)
    if v < threshold then return 0 end
    return math.ceil((v - threshold + 1) / per)
end

local function severity_pen(behind)
    if behind == 0 then return COLOR_LIGHTGREEN end
    if behind <= 2 then return COLOR_YELLOW end
    return COLOR_LIGHTRED
end

TravellingHungerOverlay = defclass(TravellingHungerOverlay, overlay.OverlayWidget)
TravellingHungerOverlay.ATTRS{
    desc = 'Shows meals, drinks and sleeps needed on the fast-travel screen.',
    default_pos = {x = 2, y = 1},   -- top row
    viewscreens = 'dungeonmode/Travel',
    frame = {w = 33, h = 1},
    default_enabled = true,
}

function TravellingHungerOverlay:init()
    -- token callbacks read the values cached by onRenderBody (one unit lookup per frame, not six)
    local function val(field) return function() return self[field] or '' end end
    self:addviews{
        widgets.Label{
            frame = {l = 0, t = 0},
            text = {
                {text = 'Food: ', pen = COLOR_WHITE},
                {text = val('hunger_text'), pen = function() return self.hunger_pen end},
                {text = '  Drink: ', pen = COLOR_WHITE},
                {text = val('thirst_text'), pen = function() return self.thirst_pen end},
                {text = '  Sleep: ', pen = COLOR_WHITE},
                {text = val('sleep_text'), pen = function() return self.sleep_pen end},
            },
        },
    }
end

local function describe(v, threshold, per)
    local behind = items_behind(v, threshold, per)
    return tostring(behind), severity_pen(behind)
end

function TravellingHungerOverlay:onRenderBody(dc)
    local u = dfhack.world.getAdventurer()
    if u then
        self.hunger_text, self.hunger_pen = describe(u.counters2.hunger_timer, HUNGRY, PER_ITEM)
        self.thirst_text, self.thirst_pen = describe(u.counters2.thirst_timer, THIRSTY, PER_ITEM)
        self.sleep_text, self.sleep_pen = describe(u.counters2.sleepiness_timer, DROWSY, PER_SLEEP)
    else
        self.hunger_text, self.hunger_pen = '?', COLOR_GREY
        self.thirst_text, self.thirst_pen = '?', COLOR_GREY
        self.sleep_text, self.sleep_pen = '?', COLOR_GREY
    end
    TravellingHungerOverlay.super.onRenderBody(self, dc)
end

OVERLAY_WIDGETS = {status = TravellingHungerOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('adv/travelling-hunger: overlay registered.')
print('Meals, drinks and 8-hour sleeps needed now show on the fast-travel screen\'s top row.')
