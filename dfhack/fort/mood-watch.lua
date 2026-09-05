-- Watch for the next strange mood, and steer what it will be made of.
--@module = true
--[[
mood-watch

Two notices in one, both about the mood you have NOT had yet:

  * "A strange mood could strike" -- when the fort meets DF's own conditions for one.
    Clicking it dismisses it until the next mood and opens a dialog explaining how a mood
    picks its first material, with a button to reserve a metal and a button to stop telling
    you. (`magnus-scripts` turns it back on.)
  * "Ensuring slade is used for next mood" -- while a metal is reserved.

WHEN A MOOD IS POSSIBLE is not guesswork about three months. DF keeps `plotinfo.mood_cooldown`
for exactly this: a mood may be rolled when it reaches zero. `plotinfo.tasks` counts the
population and the excavated tiles DF also weighs, so those are read rather than estimated.

RESERVING A METAL forbids every other metal bar in the fort, and keeps forbidding them --
bars smelted or unloaded after you set it are caught by a sweep that runs while the reserve is
on. Only bars this forbade are ever released again, so your own forbids are safe.

Whether that actually steers the mood is a strong bet rather than a certainty, and the dialog
says so. The evidence is in `reserve_metal` below.

For the mood you already HAVE, see `fort/help-mood`: it plans the artifact, reserves the items
and can point a requirement at a different material after the roll -- which is the certain way
to choose what gets made.

    fort/mood-watch      register the notification (magnus-scripts does this), and start
                         telling you again if you had told it to stop
    fort/mood-watch gui  open the dialog straight away -- the way back in once the notice
                         has been clicked away
    fort/mood-watch off  release a reserve and stop watching
]]

local gui = require('gui')
local widgets = require('gui.widgets')

-- captured at the top of the chunk: `...` is only available in the main chunk's own scope
local ARGV_OFF = (({...})[1] == 'off')
local ARGV_GUI = (({...})[1] == 'gui')

local WATCH_KEY = 'help-mood/watch'

-- Kept under help-mood's key on purpose: this was part of that script when the state was
-- first written down, and a fort in the middle of a reserve should not lose it to a tidy-up.
local function watch_state()
    local d = dfhack.persistent.getSiteData(WATCH_KEY, {})
    if type(d) ~= 'table' then d = {} end
    d.forbidden = type(d.forbidden) == 'table' and d.forbidden or {}
    return d
end

local function save_watch(d)
    pcall(dfhack.persistent.saveSiteData, WATCH_KEY, d)
end

-- what counts as stock: the same hard-unavailability test help-mood uses, minus `foreign`,
-- which a mood takes no notice of
local function usable(item)
    local f = item.flags
    return not (f.dump or f.hostile or f.artifact or f.owned or f.garbage_collect
        or f.removed or f.in_building or f.encased or f.trader)
end

local function find_mood()
    local ok, m = pcall(reqscript, 'fort/help-mood')
    if not ok then return nil end
    return m.find_mood()
end

-- ---------------------------------------------------------------------------
-- "a mood could strike"
-- ---------------------------------------------------------------------------
--
-- DF keeps its own counter for this -- `plotinfo.mood_cooldown` -- so there is no need to
-- guess at "three months since the last one": when it reaches zero a mood may be rolled.
-- Population and excavated tiles are DF's other two conditions and are read from
-- `plotinfo.tasks`, which counts them for its own purposes.

local MOOD_POP_MIN = 20

function mood_odds()
    local citizens = #dfhack.units.getCitizens(true)
    return {
        cooldown = df.global.plotinfo.mood_cooldown,
        pop = citizens,
        pop_ok = citizens >= MOOD_POP_MIN,
        dug = df.global.plotinfo.tasks.excavated_tiles,
        in_mood = (find_mood() ~= nil),
    }
end

function mood_possible()
    local o = mood_odds()
    return o.pop_ok and o.cooldown == 0 and not o.in_mood
end

-- ---------------------------------------------------------------------------
-- reserving a metal for the next mood
-- ---------------------------------------------------------------------------
--
-- WHY THIS WORKS, AND WHAT IS NOT CERTAIN ABOUT IT. A mood decides its materials the instant
-- it begins -- measured here: the job's item filters existed while the workshop was still
-- unclaimed -- and the wiki's Strange mood page says the choice is made from what is
-- AVAILABLE: "Metalworkers will demand adamantine wafers or divine metals if any are
-- available (unforbidden)", and "You can selectively forbid types of material through the
-- stocks screen so that only the material you want them to use is available."
--
-- Against that: DFHack's own strangemood plugin, which reimplements the selection, scans
-- `items.other[ANY_GOES_IN_CHEST]` for bars and checks only the item type, the material and
-- the DEEP_SPECIAL inorganic flag -- no forbid check at all. One of the two is wrong, and
-- this fort's evidence favours the wiki: the mood in progress rolled ADAMANTINE, which the
-- plugin's rule would have excluded outright (adamantine is DEEP_SPECIAL) and which the
-- wiki's rule predicts exactly, because nine unforbidden adamantine bars were sitting there.
--
-- So: this forbids the other metals, and it is honest about being a bet. The certain way to
-- get the artifact you want is the picker's material swap, which rewrites the requirement
-- after the roll and does not care how the roll was made.

local function metal_bars()
    local counts = {}
    for _, it in ipairs(df.global.world.items.other.BAR) do
        if it:getMaterial() == 0 and usable(it) then
            local idx = it:getMaterialIndex()
            counts[idx] = (counts[idx] or 0) + 1
        end
    end
    local out = {}
    for idx, n in pairs(counts) do
        local mi = dfhack.matinfo.decode(0, idx)
        out[#out + 1] = {index = idx, count = n, name = mi and mi:toString() or ('#' .. idx)}
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function reserved_metal()
    local d = watch_state()
    if not d.reserved then return nil end
    local mi = dfhack.matinfo.decode(0, d.reserved)
    return d.reserved, mi and mi:toString() or ('#' .. d.reserved)
end

function clear_reserve()
    local d = watch_state()
    local n = 0
    for id in pairs(d.forbidden or {}) do
        local it = df.item.find(tonumber(id))
        if it and it.flags.forbid then it.flags.forbid = false; n = n + 1 end
    end
    d.forbidden, d.reserved = {}, nil
    save_watch(d)
    return n
end

function reserve_metal(idx)
    clear_reserve()
    local d = watch_state()
    local n = 0
    for _, it in ipairs(df.global.world.items.other.BAR) do
        if it:getMaterial() == 0 and it:getMaterialIndex() ~= idx and usable(it)
            and not it.flags.forbid then
            it.flags.forbid = true
            d.forbidden[tostring(it.id)] = true
            n = n + 1
        end
    end
    d.reserved = idx
    save_watch(d)
    reserve_watch()
    return n
end

-- A RESERVE IS NOT A ONE-OFF SWEEP. Bars keep arriving -- a smelter finishes, a caravan
-- unloads -- and every one of them is another metal the next mood can see. So while a metal
-- is reserved this keeps running, forbidding what turns up, and it only ever touches bars it
-- forbade itself: your own forbids are never released when the reserve is lifted.
reserve_gen = reserve_gen or 0

function reserve_sweep()
    local d = watch_state()
    if not d.reserved then return 0 end
    local n = 0
    for _, it in ipairs(df.global.world.items.other.BAR) do
        if it:getMaterial() == 0 and it:getMaterialIndex() ~= d.reserved and usable(it)
            and not it.flags.forbid then
            it.flags.forbid = true
            d.forbidden[tostring(it.id)] = true
            n = n + 1
        end
    end
    if n > 0 then save_watch(d) end
    return n
end

function reserve_watch()
    reserve_gen = reserve_gen + 1
    local my_gen = reserve_gen
    local function tick()
        if my_gen ~= reserve_gen then return end
        if not watch_state().reserved then return end       -- lifted: stop quietly
        pcall(reserve_sweep)
        dfhack.timeout(100, 'frames', tick)
    end
    tick()
end

function watch_hidden()
    return watch_state().hidden == true
end

function set_watch_hidden(on)
    local d = watch_state()
    d.hidden = on and true or nil
    save_watch(d)
end

function watch_message()
    local _, name = reserved_metal()
    if name then
        return {{text = ('Ensuring %s is used for next mood'):format(name), pen = COLOR_LIGHTCYAN}}
    end
    if watch_hidden() then return nil end
    if not mood_possible() then return nil end
    return {{text = 'A strange mood could strike', pen = COLOR_LIGHTMAGENTA}}
end

-- ---------------------------------------------------------------------------
-- the dialogs
-- ---------------------------------------------------------------------------

MetalPicker = defclass(MetalPicker, widgets.Window)
MetalPicker.ATTRS{
    frame_title = 'Reserve a metal',
    frame = {w = 56, h = 24},
    resizable = true,
    on_change = DEFAULT_NIL,
}

function MetalPicker:init()
    local reserved = reserved_metal()
    local choices = {}
    choices[#choices + 1] = {text = {{text = '  (none -- leave every metal available)',
                                     pen = reserved and COLOR_GREY or COLOR_LIGHTGREEN}},
                             index = false}
    for _, m in ipairs(metal_bars()) do
        local on = reserved == m.index
        choices[#choices + 1] = {
            index = m.index,
            text = {{text = ('  %s%-22s %4d bar%s'):format(on and '* ' or '  ', m.name, m.count,
                                                           m.count == 1 and '' or 's'),
                     pen = on and COLOR_LIGHTGREEN or nil}},
        }
    end
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text_pen = COLOR_GREY,
            text = 'Forbids every other metal bar, so the next mood has only this one to see.'},
        widgets.List{
            frame = {t = 2, l = 0, r = 0, b = 3},
            choices = choices,
            on_submit = function(_, ch)
                if ch.index == false then
                    local n = clear_reserve()
                    self.subviews.status:setText(('Released %d bar%s.'):format(n, n == 1 and '' or 's'))
                else
                    local n = reserve_metal(ch.index)
                    local _, name = reserved_metal()
                    self.subviews.status:setText(
                        ('Forbade %d other bar%s; %s is what is left.'):format(
                            n, n == 1 and '' or 's', name or '?'))
                end
                if self.on_change then self.on_change() end
                self:updateLayout()
            end,
        },
        widgets.Label{view_id = 'status', frame = {b = 1, l = 0}, text = '', text_pen = COLOR_GREY},
        widgets.Label{frame = {b = 0, l = 0}, text_pen = COLOR_GREY,
            text = 'Your own forbids are left alone; only what this set is undone. Esc closes.'},
    }
end

MetalPickerScreen = defclass(MetalPickerScreen, gui.ZScreenModal)
MetalPickerScreen.ATTRS{focus_path = 'help-mood/metal', force_pause = false,
                        on_change = DEFAULT_NIL}
function MetalPickerScreen:init()
    self:addviews{MetalPicker{on_change = self.on_change}}
end

MoodOdds = defclass(MoodOdds, widgets.Window)
MoodOdds.ATTRS{
    frame_title = 'A strange mood',
    frame = {w = 76, h = 28},
    resizable = true,
}

-- The explanation, as lines rather than a paragraph to be wrapped. The window is then sized
-- to the longest of them, which is the whole point: wrapping decided where to break these and
-- made a mess of it -- "-- not", "the", "change" alone on their own lines -- and the wrapped
-- block also grew past the fixed offset the numbers were pinned at and printed straight
-- through them.
local EXPLAIN = {
    'A mood decides everything it will ask for at the instant it strikes -- not when the',
    'dwarf claims a workshop. By then it is already too late to change their mind.',
    '',
    'The FIRST requirement is the base material, and it is chosen from what the fort has',
    'AVAILABLE. Forbidden stock does not count as available, so forbidding every metal but',
    'one is the way to steer a metalworker\'s mood -- that is what the button below does.',
    '',
    'This is the game\'s documented behaviour rather than something measurable from outside,',
    'so treat it as a strong bet, not a guarantee. The guarantee is on the other side: once',
    'a mood has struck, fort/help-mood can point any requirement at another material you',
    'own, which does not care how the roll was made.',
}

function MoodOdds:init()
    local odds_at = #EXPLAIN + 1
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = table.concat(EXPLAIN, NEWLINE)},
        widgets.Label{view_id = 'odds', frame = {t = odds_at, l = 0}, text = ''},
        widgets.TextButton{
            frame = {b = 2, l = 0, w = 26, h = 1},
            label = 'reserve a metal',
            key = 'CUSTOM_CTRL_M',
            on_activate = function()
                MetalPickerScreen{on_change = function() self:refresh() end}:show()
            end,
        },
        widgets.TextButton{
            view_id = 'hide',
            frame = {b = 2, l = 28, w = 30, h = 1},
            label = 'stop telling me',
            key = 'CUSTOM_CTRL_H',
            on_activate = function()
                set_watch_hidden(not watch_hidden())
                self:refresh()
            end,
        },
        widgets.Label{view_id = 'status', frame = {b = 0, l = 0}, text = '', text_pen = COLOR_GREY},
    }

    -- wide enough that nothing wraps, tall enough for the lot: the explanation, the four
    -- lines of numbers under it, the buttons and the frame
    local widest = 0
    for _, line in ipairs(EXPLAIN) do widest = math.max(widest, #line) end
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame.w = math.min(sw - 4, math.max(60, widest + 4))
    -- odds_at rows of text, four of numbers under it, then the buttons, the status line and
    -- the frame. Measured: at +9 the buttons printed across the last line of the numbers.
    self.frame.h = math.min(sh - 4, odds_at + 11)
    self:refresh()
end

function MoodOdds:refresh()
    local o = mood_odds()
    local _, name = reserved_metal()
    self.subviews.odds:setText({
        {text = ('Population %d (needs %d)   '):format(o.pop, MOOD_POP_MIN),
         pen = o.pop_ok and COLOR_GREEN or COLOR_LIGHTRED},
        {text = ('Tiles dug %d'):format(o.dug)},
        NEWLINE,
        {text = ('DF\'s own mood cooldown: %d'):format(o.cooldown),
         pen = o.cooldown == 0 and COLOR_GREEN or COLOR_GREY},
        {text = o.cooldown == 0 and '  -- a mood may strike at any time' or '  -- not yet'},
        NEWLINE, NEWLINE,
        {text = name and ('Reserved: %s. Every other metal bar is forbidden.'):format(name)
                      or 'No metal reserved.',
         pen = name and COLOR_LIGHTCYAN or COLOR_GREY},
    })
    self.subviews.hide:setLabel(watch_hidden() and 'tell me again' or 'stop telling me')
end

MoodOddsScreen = defclass(MoodOddsScreen, gui.ZScreenModal)
MoodOddsScreen.ATTRS{focus_path = 'help-mood/odds', force_pause = false}
function MoodOddsScreen:init() self:addviews{MoodOdds{}} end

-- Clicking the "could strike" notification dismisses it until the next mood AND opens this,
-- which is the only way it is ever useful: the notice is a prompt to decide something.
function watch_click()
    if not reserved_metal() then set_watch_hidden(true) end
    MoodOddsScreen{}:show()
end

-- ...and the same dialog without the dismissal, for `fort/mood-watch gui`: asking for it back
-- is not the same gesture as clicking the notice away.
function watch_click_no_hide()
    MoodOddsScreen{}:show()
end


-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

local NOTIFY_WATCH = 'mood_watch'

local function live_call(fn)
    return function(...)
        local ok, m = pcall(reqscript, 'fort/mood-watch')
        local f = (ok and m and m[fn]) or _ENV[fn]
        return f(...)
    end
end

-- A mood ending is a new question, so the notice comes back on its own rather than staying
-- dismissed forever.
function watch_tick()
    local d = watch_state()
    local in_mood = find_mood() ~= nil
    if in_mood and not d.was_in_mood then
        d.was_in_mood = true
        d.hidden = nil
        save_watch(d)
    elseif not in_mood and d.was_in_mood then
        d.was_in_mood = nil
        save_watch(d)
    end
end

hb_gen = hb_gen or 0

function watch_heartbeat()
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function tick()
        if my_gen ~= hb_gen then return end
        pcall(watch_tick)
        dfhack.timeout(100, 'frames', tick)
    end
    tick()
end

function register_watch()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok then return end
    local w = n.NOTIFICATIONS_BY_NAME[NOTIFY_WATCH]
    if not w then
        w = {name = NOTIFY_WATCH, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, w)
        n.NOTIFICATIONS_BY_NAME[NOTIFY_WATCH] = w
    end
    w.desc = 'Notifies when a strange mood could strike, and while a metal is reserved for one.'
    w.dwarf_fn = live_call('watch_message')
    w.on_click = live_call('watch_click')
    if n.config and n.config.data and not n.config.data[NOTIFY_WATCH] then
        n.config.data[NOTIFY_WATCH] = {enabled = true, version = 1}
    end
    set_watch_hidden(false)          -- asking for it back means you want to hear it
    if watch_state().reserved then reserve_watch() end
    watch_heartbeat()
end

if dfhack_flags and dfhack_flags.module then return end
if not dfhack.world.isFortressMode() then qerror('fort/mood-watch needs a fort') end

if ARGV_GUI then
    -- the notice hides itself when you click it, so this is the door back in
    watch_click_no_hide()
    return
end
if ARGV_OFF then
    local n = clear_reserve()
    set_watch_hidden(true)
    hb_gen = hb_gen + 1
    print(('fort/mood-watch: released %d bar%s and stopped watching.')
        :format(n, n == 1 and '' or 's'))
    return
end

register_watch()
print('fort/mood-watch: watching for the next strange mood.')
print('`fort/mood-watch gui` opens the dialog again after you click the notice away.')
