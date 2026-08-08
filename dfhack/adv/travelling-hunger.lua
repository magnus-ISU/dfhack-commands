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

The adventurer unit is readable through dfhack.world.getAdventurer() only while the Travel
screen sits at the starting position; the moment travel moves, the local map unloads and the
character is abstracted into an ARMY. The army's member entry (army_nemesisst) carries its
own hunger_timer/thirst_timer/sleepiness_timer -- the same field names -- which DF ticks
during travel and writes back to the unit on arrival. So mid-travel we read the counters
from the player army instead: the army in world.armies.all with flags.player set, member
whose nemesis_id is adventure.player_id. The armies vector runs to four digits in a mature
world, so the found army id is cached and the linear hunt is throttled to a cache miss twice
a second.

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

-- The struct holding the live counters: the unit's counters2 while the unit is loaded, else
-- the player army's member entry (mid-travel the unit is offloaded and DF ticks the army's
-- copy). Both spell the fields hunger_timer / thirst_timer / sleepiness_timer.
--
-- The armies vector is NOT small (1136 in the current world), and this runs every render
-- frame, so the linear hunt for the player flag happens only on a cache miss -- and at most
-- twice a second, for the frames between travel starting and DF minting the army. Once found,
-- df.army.find (a binsearch) revalidates the cached id each frame.
local cached_army_id, next_hunt
local function player_counters()
    local u = dfhack.world.getAdventurer()
    if u then return u.counters2 end
    local army = cached_army_id and df.army.find(cached_army_id)
    if army and not army.flags.player then army = nil end
    if not army then
        cached_army_id = nil
        local now = dfhack.getTickCount()
        if now < (next_hunt or 0) then return end
        next_hunt = now + 500
        for _, a in ipairs(df.global.world.armies.all) do
            if a.flags.player then
                cached_army_id, army = a.id, a
                break
            end
        end
        if not army then return end
    end
    local pid = df.global.adventure.player_id
    for _, mem in ipairs(army.members) do
        if mem.nemesis_id == pid then return mem end
    end
end

function TravellingHungerOverlay:onRenderBody(dc)
    local ok, c = pcall(player_counters)
    if ok and c then
        self.hunger_text, self.hunger_pen = describe(c.hunger_timer, HUNGRY, PER_ITEM)
        self.thirst_text, self.thirst_pen = describe(c.thirst_timer, THIRSTY, PER_ITEM)
        self.sleep_text, self.sleep_pen = describe(c.sleepiness_timer, DROWSY, PER_SLEEP)
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
