-- Designate a burrow that strange-mood dwarves are confined to until they claim
-- their first (artifact-defining) item.
--@module = true
--@enable = true
--[[
A [Mood burrow: <name>] line on the burrow screen (top right). Clicking it cycles
through your burrows (none -> each burrow -> none); the designated one becomes the
MOOD burrow:

  * a dwarf struck by a strange mood (fey / secretive / possessed / macabre) is
    assigned to that burrow the moment the mood is noticed;
  * the assignment is dropped as soon as the FIRST item is claimed into their
    workshop -- the first item sets the artifact's base material, so a burrow
    containing your forge + only steel bars gets you steel weapons/armor instead
    of whatever random bars were closest. The rest of the demands (cloth, gems,
    bones...) are then gathered from anywhere as usual;
  * the assignment is also dropped when the mood ends (artifact done, or the
    dwarf went insane).

The mood burrow's unit list is fully managed: anyone in it who is not an active
first-item-pending mood dwarf is removed each cycle -- don't assign dwarves to it
by hand. FELL moods are left alone (the dwarf must reach a victim first;
burrowing them would break the murder). Make sure the burrow contains the right
workshops (e.g. a forge) plus the materials you want claimed, or the moody dwarf
will sit demanding items it cannot reach.

Usage:
    enable mood-burrow      run the watcher in the background
    disable mood-burrow     stop it
    mood-burrow             one-shot status / sync now

The designated burrow and the enabled state persist with the fort.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'mood-burrow'
local CYCLE_TICKS = 20   -- re-check moods a few dozen times a game day (cheap scan)

-- the workshop-claiming, item-gathering moods we manage. Fell is intentionally
-- absent (the dwarf first murders a fort member -- burrowing would block that);
-- insanities (melancholy/raving/berserk) gather nothing.
local MANAGED_MOOD = {
    [df.mood_type.Fey] = true,
    [df.mood_type.Secretive] = true,
    [df.mood_type.Possessed] = true,
    [df.mood_type.Macabre] = true,
}

-- ---- shared config (persisted with the fort) ------------------------------
state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY,
            {enabled = false, burrow_id = -1})
    end
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

local function mood_burrow()
    load_state()
    if state.burrow_id < 0 then return nil end
    local b = df.burrow.find(state.burrow_id)
    if not b then state.burrow_id = -1; save_state() end
    return b
end

local function burrow_label(b)
    if not b then return 'none' end
    if b.name and #b.name > 0 then return b.name end
    return ('Burrow %d'):format(b.id)
end

-- ---- mood tracking ---------------------------------------------------------

-- has this moody dwarf already claimed the first item of the creation? True once
-- the strange-mood job in the claimed workshop has any item attached to it (items
-- attach one by one as the dwarf claims them; the first one fixes the material).
local function first_item_picked(u)
    local j = u.job.current_job
    if not j then return false end
    local jt = df.job_type[j.job_type]
    if not jt or not tostring(jt):match('^StrangeMood') then return false end
    return #j.items > 0
end

-- liveness/debug counters, readable via `mood-burrow` (the one-shot status)
syncs = syncs or 0
last_confined = last_confined or 'never'

-- announce in-game (and on the console) so confinement is visible when it happens
local function announce(msg)
    print('mood-burrow: ' .. msg)
    pcall(dfhack.gui.showAnnouncement, 'mood-burrow: ' .. msg, COLOR_LIGHTMAGENTA, true)
end

-- is the unit assigned to burrow id `bid`? Checked on the UNIT side (unit.burrows):
-- that is the vector the game's own assignment UI maintains on this build --
-- burrow.units stays empty for manually-assigned burrows, so it can't be trusted
-- as the membership authority. setAssignedUnit keeps both sides in step anyway.
local function in_burrow(u, bid)
    for _, id in ipairs(u.burrows) do
        if id == bid then return true end
    end
    return false
end

-- one sync pass, fully stateless, keyed on unit.burrows: every citizen in a
-- managed strange mood who hasn't picked their first item is in the mood burrow;
-- every other citizen (mood over, first item claimed, manually added) is not.
local function do_sync()
    syncs = syncs + 1
    local b = mood_burrow()
    if not b then return 0 end

    local changed = 0
    for _, u in ipairs(dfhack.units.getCitizens()) do
        local should = MANAGED_MOOD[u.mood] and not first_item_picked(u)
        local is = in_burrow(u, b.id)
        if should and not is then
            dfhack.burrows.setAssignedUnit(b, u, true)
            announce(('%s confined to %s for the mood\'s first item')
                :format(dfhack.units.getReadableName(u), burrow_label(b)))
            last_confined = dfhack.units.getReadableName(u)
            changed = changed + 1
        elseif is and not should then
            dfhack.burrows.setAssignedUnit(b, u, false)
            announce(('%s released from %s (first item claimed / mood over)')
                :format(dfhack.units.getReadableName(u), burrow_label(b)))
            changed = changed + 1
        end
    end
    return changed
end

-- ---- enable / background service ------------------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

-- per-frame heartbeat gated on the game calendar (same rationale as
-- auto-pasture: repeat-util day timeouts are frame-counted on this build)
local last_run = nil
local hb_gen = 0

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= CYCLE_TICKS then
            last_run = now
            if dfhack.world.isFortressMode() then do_sync() end
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

-- cycle the designation: none -> burrow 1 -> burrow 2 -> ... -> none
local function cycle_burrow()
    load_state()
    local list = df.global.plotinfo.burrows.list
    if #list == 0 then return end
    local next_idx = 0                            -- default: first burrow
    if state.burrow_id >= 0 then
        next_idx = nil                            -- current not found -> none
        for i = 0, #list - 1 do
            if list[i].id == state.burrow_id then
                next_idx = (i + 1 <= #list - 1) and i + 1 or nil  -- past the end -> none
                break
            end
        end
    end
    if next_idx then
        state.burrow_id = list[next_idx].id
        if not enabled then start() end
        state.enabled = true
        do_sync()
    else
        state.burrow_id = -1
    end
    save_state()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state = nil
    end
end

-- ---- overlay --------------------------------------------------------------

MoodBurrowOverlay = defclass(MoodBurrowOverlay, overlay.OverlayWidget)
MoodBurrowOverlay.ATTRS{
    desc = 'Adds a mood-burrow selector to the burrow screen.',
    default_pos = {x = 9, y = 8},                 -- top left: 8 right, 7 down from the corner
    -- OFF by default: the feature is filed in BROKEN_FEATURES (TODO) and was only
    -- ever meant as a manual toggle -- the fort/ move's widget rename reset it to
    -- the old default and silently switched it on everywhere
    default_enabled = false,
    viewscreens = 'dwarfmode/Burrow',
    frame = {w = 30, h = 1},
    version = 3,                                  -- bumped so the corrected default overrides saved state
}

function MoodBurrowOverlay:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = {{
                text = function()
                    load_state()
                    return ('[Mood burrow: %s]'):format(burrow_label(mood_burrow()))
                end,
                pen = function()
                    return mood_burrow() and COLOR_GREEN or COLOR_WHITE
                end,
            }},
            on_click = cycle_burrow,
        },
    }
end

OVERLAY_WIDGETS = {mood = MoodBurrowOverlay}

-- exported so it can be driven via reqscript (the `enable` command goes through
-- run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('mood-burrow can only be enabled in fortress mode')
    end
    load_state()
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('mood-burrow: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot
    if not dfhack.world.isFortressMode() then
        qerror('mood-burrow only works in fortress mode')
    end
    load_state()
    local b = mood_burrow()
    if not b then
        print('mood-burrow: no mood burrow designated yet.')
        print('  Open the burrow screen and click [Mood burrow: ...] (top right) to cycle.')
    else
        local n = do_sync()
        print(('mood-burrow: %s is the mood burrow (%d assignment change%s)')
            :format(burrow_label(b), n, n == 1 and '' or 's'))
        print(('  service=%s syncs=%d last confined: %s')
            :format(tostring(enabled), syncs, last_confined))
    end
end
