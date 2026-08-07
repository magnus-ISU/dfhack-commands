-- Show the adventurer's hunger and thirst on the fast-travel screen.
--@module = true
--[[
adv/travelling-hunger

Fast travel is when hunger and thirst quietly pile up, and the travel screen shows neither.
This overlay paints both on the top row while travelling, as the number of meals and drinks it
takes to get back under the hungry/thirsty thresholds ("Food: 2  Drink: 4") -- green when fine,
yellow when behind, red when 3+ items behind.

Mechanics (measured, see the eat/drink notes): DF flags Hungry at hunger_timer 50000 and
Thirsty at thirst_timer 25000; eating or drinking one item takes 50000 off the counter. The
adventurer unit stays readable through dfhack.world.getAdventurer() even mid-travel (verified
live on the Travel screen), so the overlay just reads two ints per render.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local HUNGRY = 50000    -- hunger_timer where DF says Hungry
local THIRSTY = 25000   -- thirst_timer where DF says Thirsty
local PER_ITEM = 50000  -- one meal/drink takes this much off its counter

-- items needed to get back under the threshold (0 = fine)
local function items_behind(v, threshold)
    if v < threshold then return 0 end
    return math.ceil((v - threshold + 1) / PER_ITEM)
end

local function severity_pen(behind)
    if behind == 0 then return COLOR_LIGHTGREEN end
    if behind <= 2 then return COLOR_YELLOW end
    return COLOR_LIGHTRED
end

TravellingHungerOverlay = defclass(TravellingHungerOverlay, overlay.OverlayWidget)
TravellingHungerOverlay.ATTRS{
    desc = 'Shows meals and drinks needed on the fast-travel screen.',
    default_pos = {x = 2, y = 1},   -- top row
    viewscreens = 'dungeonmode/Travel',
    frame = {w = 22, h = 1},
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
            },
        },
    }
end

local function describe(v, threshold)
    local behind = items_behind(v, threshold)
    return tostring(behind), severity_pen(behind)
end

function TravellingHungerOverlay:onRenderBody(dc)
    local u = dfhack.world.getAdventurer()
    if u then
        self.hunger_text, self.hunger_pen = describe(u.counters2.hunger_timer, HUNGRY)
        self.thirst_text, self.thirst_pen = describe(u.counters2.thirst_timer, THIRSTY)
    else
        self.hunger_text, self.hunger_pen = '?', COLOR_GREY
        self.thirst_text, self.thirst_pen = '?', COLOR_GREY
    end
    TravellingHungerOverlay.super.onRenderBody(self, dc)
end

OVERLAY_WIDGETS = {status = TravellingHungerOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('adv/travelling-hunger: overlay registered.')
print('Meals and drinks needed now show on the fast-travel screen\'s top row.')
