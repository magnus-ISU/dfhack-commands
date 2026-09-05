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

-- THE RESERVE IS FOR THE MOOD YOU HAVE NOT HAD. Once one actually begins, its materials are
-- already rolled: keeping the other metals forbidden can no longer steer anything, and it can
-- only do harm -- a clothier's mood wants cloth, and every forbidden bar is just a bar the
-- fort cannot use for anything else while the artifact is built. (Seen live: a Fey clothier
-- mooding while "Ensuring slade is used for next mood" still had every non-slade bar locked
-- down.) The reserve only ever steered the FIRST material anyway -- the base material of a
-- metalworking mood -- so for any other craft it was never in the running.
--
-- So a mood starting lifts the reserve, putting every bar this forbade back.
function release_on_mood()
    local d = watch_state()
    if not d.reserved then return nil end
    if not find_mood() then return nil end
    local name = select(2, reserved_metal())
    local n = clear_reserve()
    return name, n
end

function reserve_sweep()
    local d = watch_state()
    if not d.reserved then return 0 end
    if find_mood() then                 -- a mood is under way: lift, don't keep forbidding
        local name, n = release_on_mood()
        if name then
            dfhack.gui.showAnnouncement(
                ('A strange mood has begun -- the %s reserve is lifted (%d bar%s unforbidden).')
                    :format(name, n or 0, (n or 0) == 1 and '' or 's'), COLOR_LIGHTGREEN, true)
        end
        return 0
    end
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
    local d = watch_state()
    return d.hidden == true or d.never == true
end

-- `hidden` lasts until the next mood; `never` lasts until something re-enables the script.
-- Two refusals, two flags: a fort that said "not this time" should be asked again.
function set_watch_never(on)
    local d = watch_state()
    d.never = on and true or nil
    save_watch(d)
end

function set_watch_hidden(on)
    local d = watch_state()
    d.hidden = on and true or nil
    save_watch(d)
end

function watch_message()
    local _, name = reserved_metal()
    -- a mood already under way has rolled its materials: the reserve is not steering it
    if name and not find_mood() then
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
    frame_title = 'fort/mood-watch gui',
    frame = {w = 76, h = 28},
    resizable = true,
}

-- The dwarves' own words. Written as lines rather than a paragraph to be wrapped, and the
-- window is sized to the longest of them: wrapping decided where to break these and made a
-- mess of it, and the wrapped block also grew past the row the status line was pinned at and
-- printed straight through it.
local EXPLAIN = {
    'Our fortress has grown to attract the attention of the gods. Surely they will',
    'soon bless us with artifacts of indestructible quality and peerless power.',
    '',
    'Typically, the gods will choose an item pleasing to the lucky artisan; but we',
    'can influence it by ignoring our industry now and showing them only our',
    'preferred items.',
    '',
    'Of course, all dwarves love adamantium... we must dig deeper, and we can',
    'abandon our dreams of platinum warhammers...',
}

function MoodOdds:init()
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = table.concat(EXPLAIN, NEWLINE)},
        -- Wide enough for the key prefix DFHack draws into the label ("Ctrl+m: "): sized to
        -- the words alone, every one of these read "[Ctrl+m: reserve a ]".
        widgets.TextButton{
            frame = {b = 1, l = 0, w = 26, h = 1},
            label = 'Reserve a metal',
            key = 'CUSTOM_CTRL_M',
            on_activate = function()
                MetalPickerScreen{on_change = function() self:refresh() end}:show()
            end,
        },
        -- Two ways of saying no, because they are different answers. "Not this time" is about
        -- this mood; the notice is back for the next one. "Don't ever" is about the notice.
        widgets.TextButton{
            frame = {b = 1, l = 28, w = 38, h = 1},
            label = 'Don\'t ever show this again',
            key = 'CUSTOM_CTRL_H',
            on_activate = function()
                set_watch_never(true)
                self.parent_view:dismiss()
            end,
        },
        widgets.TextButton{
            frame = {b = 1, l = 68, w = 24, h = 1},
            label = 'Not this time',
            key = 'CUSTOM_CTRL_N',
            on_activate = function()
                set_watch_hidden(true)
                self.parent_view:dismiss()
            end,
        },
        -- what is reserved, under the buttons: it is the result of pressing one, so it reads
        -- as the answer rather than as part of the question
        widgets.Label{view_id = 'odds', frame = {b = 0, l = 0}, text = ''},
    }

    local widest = 92
    for _, line in ipairs(EXPLAIN) do widest = math.max(widest, #line) end
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame.w = math.min(sw - 4, widest + 4)
    self.frame.h = math.min(sh - 4, #EXPLAIN + 7)   -- +1 so the buttons sit off the prose
    self:refresh()
end

function MoodOdds:refresh()
    local _, name = reserved_metal()
    self.subviews.odds:setText(name
        and {{text = ('We are showing them only our %s.'):format(name), pen = COLOR_LIGHTCYAN}}
        or {{text = 'We are showing them everything we have.', pen = COLOR_GREY}})
end

MoodOddsScreen = defclass(MoodOddsScreen, gui.ZScreenModal)
MoodOddsScreen.ATTRS{focus_path = 'help-mood/odds', force_pause = false}
function MoodOddsScreen:init() self:addviews{MoodOdds{}} end

-- Clicking the "could strike" notification dismisses it until the next mood AND opens this,
-- which is the only way it is ever useful: the notice is a prompt to decide something.
function watch_click()
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
        d.hidden = nil               -- `never` is left alone: it meant never
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
    set_watch_never(false)
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
