-- Cut monster slayers loose from the fort: two buttons on the Work Details screen that strip
-- the location off every monster-slayer occupation, and keep doing it.
--@module = true
--@enable = true
--[[
no-monster-slayers

Monster slayers turn up because you have a tavern, take a slayer's post at one of your
locations and then hang around it. This takes the post away. For every MONSTER_SLAYER
occupation belonging to the fort it deletes the location first -- the record is unhooked from
the tavern or temple holding it -- and then removes the post itself, from the unit and from the
world's occupation list.

Clearing the location alone is NOT enough, which is worth knowing if you go poking at this by
hand: a slayer whose occupation has no location and no site is still a monster slayer, because
the post is also listed on the unit. A post has three owners -- the location, the unit, and the
world list -- and it stops being real only when all three have let go.

Two buttons appear on the Work Details screen, under the work-detail list:

    [Auto][Remove Monster Slayers]

`[Auto]` sits on the left, green while it is on, and the two touch at their brackets.

What the right-hand button does depends on the left one. With `[Auto]` ON you have already said
"all of them", so it takes every post at once. With `[Auto]` OFF it asks instead: a window lists
the fort's monster slayers with their two best FIGHTING skills -- weapon, unarmed, attack,
defence, the military classes rather than whatever they happen to be best at -- and clicking a
name takes that one slayer's post away and leaves the others alone.

`[Auto]` is a toggle, and it is ON by default -- a slayer whose post you take can be offered
another, so the sweep repeats rather than being a thing you have to remember. It is cheap: the fort's occupation list is a couple of hundred records and the
sweep reads it a few times a game-day, touching nothing else.

The pair sits at the foot of the work-detail panel, with the opening bracket of
`[Remove Monster Slayers]` in the same column as "Add new work detail" and `[Auto]` hanging off
its left. The column is read off the screen, the row comes from the panel's own rectangle, and
the reason for that split is written up at `list_end_pos` below -- a screen scrape cannot find
the end of a list it is itself drawing over.

    no-monster-slayers            take every monster-slayer post now, once, and report
    no-monster-slayers status     how many slayer posts the fort is holding
    enable no-monster-slayers     Auto on (the default)
    disable no-monster-slayers    Auto off

`magnus-scripts` turns the overlay on and arms Auto.
]]

local GLOBAL_KEY = 'no-monster-slayers'
local SCAN_FRAMES = 500                -- ~ once a game-day; the sweep reads a few hundred records

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local SLAYER = df.occupation_type.MONSTER_SLAYER

-- ---- the work ---------------------------------------------------------------

-- The locations of this fort, by id, so an occupation can be unhooked from the one holding it.
local function our_locations()
    local out = {}
    local site = df.world_site.find(df.global.plotinfo.site_id)
    if not site then return out end
    for _, b in ipairs(site.buildings) do out[b.id] = b end
    return out
end

-- Is this occupation the fort's business? Its site is ours, or the unit holding it is standing
-- on our map -- a slayer who walked in from elsewhere still holds their post here.
local function is_ours(o, site_id)
    if o.site_id == site_id then return true end
    if o.unit_id >= 0 and df.unit.find(o.unit_id) then return true end
    return false
end

-- Every monster-slayer post the fort is holding.
function slayer_posts()
    local out, site_id = {}, df.global.plotinfo.site_id
    for _, o in ipairs(df.global.world.occupations.all) do
        if o.type == SLAYER and is_ours(o, site_id) then out[#out + 1] = o end
    end
    return out
end

-- Take one post away. The location is deleted from it first -- the record is unhooked from the
-- tavern or temple holding it -- and then the post itself is taken off the unit and out of the
-- world, because clearing the location alone does NOT stop anyone being a monster slayer: the
-- unit keeps the occupation in `unit.occupations` and DF still reads it there. A post has three
-- owners and all three have to let go: the location, the unit, and world.occupations.all.
local function strip(o, locs)
    local loc = locs[o.location_id]
    if loc and loc.occupations then
        for i = #loc.occupations - 1, 0, -1 do
            if loc.occupations[i] == o then loc.occupations:erase(i) end
        end
    end
    o.location_id, o.site_id = -1, -1
    local u = o.unit_id >= 0 and df.unit.find(o.unit_id)
    if u then
        for i = #u.occupations - 1, 0, -1 do
            if u.occupations[i] == o then u.occupations:erase(i) end
        end
    end
    local all = df.global.world.occupations.all
    for i = #all - 1, 0, -1 do
        if all[i] == o then
            all:erase(i)
            o:delete()
            break
        end
    end
end

-- Returns how many posts were taken away.
function remove_slayers()
    local posts = slayer_posts()
    if #posts == 0 then return 0 end
    local locs = our_locations()
    for _, o in ipairs(posts) do strip(o, locs) end
    return #posts
end

-- Take one named post away, by the record. Used by the picker, where the choice is a person
-- rather than "all of them".
function remove_post(o)
    strip(o, our_locations())
end

-- The two best FIGHTING skills of a post's holder, as "Sword (Accomplished), Fighting (Adept)".
-- Fighting means the military skill classes -- weapon, unarmed, attack, defence and the rest --
-- so a slayer's actual trade shows rather than whatever they are best at overall.
local MILITARY_SKILL = {
    [df.job_skill_class.MilitaryWeapon] = true,
    [df.job_skill_class.MilitaryUnarmed] = true,
    [df.job_skill_class.MilitaryAttack] = true,
    [df.job_skill_class.MilitaryDefense] = true,
    [df.job_skill_class.MilitaryMisc] = true,
}
local function fighting_skills(u, count)
    local soul = u and u.status and u.status.current_soul
    if not soul then return 'no skills to read' end
    local rows = {}
    for _, sk in ipairs(soul.skills) do
        local attrs = df.job_skill.attrs[sk.id]
        if attrs and MILITARY_SKILL[attrs.type] and sk.rating > 0 then
            rows[#rows + 1] = {name = attrs.caption, rating = sk.rating}
        end
    end
    if #rows == 0 then return 'no fighting skill' end
    table.sort(rows, function(a, b) return a.rating > b.rating end)
    local out = {}
    for i = 1, math.min(count or 2, #rows) do
        local r = rows[i]
        local rank = df.skill_rating.attrs[r.rating]
        out[#out + 1] = ('%s (%s)'):format(r.name, rank and rank.caption or r.rating)
    end
    return table.concat(out, ', ')
end

-- a readable name for a post's holder, for the report
local function holder_name(o)
    local u = o.unit_id >= 0 and df.unit.find(o.unit_id)
    if u then return dfhack.units.getReadableName(u) end
    local hf = o.histfig_id >= 0 and df.historical_figure.find(o.histfig_id)
    if hf then return dfhack.translation.translateName(hf.name, true) end
    return 'an unnamed slayer'
end

-- ---- state (persisted per fort) ---------------------------------------------

state = state or nil
local function load_state()
    if not state then state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {} end
    -- filled on every call, not just the first: a script's environment survives a hot reload,
    -- so `state` can arrive from a copy of this file that predates a field.
    -- AUTO IS ON BY DEFAULT.
    if state.auto == nil then state.auto = true end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().auto end

-- ---- the auto sweep ----------------------------------------------------------

local function hb_gen(set)
    if set ~= nil then dfhack.internal.no_monster_slayers_hb_gen = set end
    return dfhack.internal.no_monster_slayers_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        if dfhack.world.isFortressMode() then pcall(remove_slayers) end
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

function set_enabled(v)
    load_state()
    state.auto = v
    save_state()
    if v then start_heartbeat() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- arm as soon as the file loads on a live fort, so the overlay and the sweep come up together
if not (dfhack_flags and dfhack_flags.module) and dfhack.world.isFortressMode() and isEnabled() then
    start_heartbeat()
end

-- ---- the buttons -------------------------------------------------------------

-- ---- the picker ---------------------------------------------------------------
-- With Auto off, the button asks rather than acts: a list of the fort's monster slayers and what
-- each of them can actually fight with, and clicking one name takes that one post away. Auto on
-- means you have already said "all of them", so the button just does it.

SlayerPicker = defclass(SlayerPicker, widgets.Window)
SlayerPicker.ATTRS{
    frame_title = 'Monster slayers',
    frame = {w = 76, h = 18},
    resizable = true,
}

function SlayerPicker:init()
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text_pen = COLOR_GREY,
            text = 'Click a name to take that slayer\'s post away. Esc closes.'},
        widgets.List{
            view_id = 'list',
            frame = {t = 2, l = 0, r = 0, b = 2},
            choices = {},
            on_submit = function(_, ch)
                if not ch.post then return end
                remove_post(ch.post)
                self.subviews.status:setText(('Took the post from %s.'):format(ch.who))
                self:refresh()
            end,
        },
        widgets.Label{view_id = 'status', frame = {b = 0, l = 0}, text = '', text_pen = COLOR_GREY},
    }
    self:refresh()
end

function SlayerPicker:refresh()
    local choices = {}
    for _, o in ipairs(slayer_posts()) do
        local u = o.unit_id >= 0 and df.unit.find(o.unit_id)
        local who = holder_name(o)
        choices[#choices + 1] = {
            post = o,
            who = who,
            text = {{text = ('  %-36s %s'):format(who:sub(1, 36), fighting_skills(u, 2))}},
        }
    end
    if #choices == 0 then
        choices[#choices + 1] = {text = {{text = '  no monster slayer holds a post here',
                                          pen = COLOR_GREY}}}
    end
    self.subviews.list:setChoices(choices)
    -- only re-lay-out once there IS a layout: refresh runs from init too, before the window has
    -- a parent rectangle, and updateLayout on a parentless view throws
    if self.frame_parent_rect then self:updateLayout() end
end

SlayerPickerScreen = defclass(SlayerPickerScreen, gui.ZScreenModal)
SlayerPickerScreen.ATTRS{focus_path = 'no-monster-slayers/picker', force_pause = false}
function SlayerPickerScreen:init() self:addviews{SlayerPicker{}} end

-- the buttons, drawn as their own brackets so they read as one pair with nothing between them
local AUTO_TEXT = '[Auto]'
local REMOVE_TEXT = '[Remove Monster Slayers]'

-- Where the work-detail list begins: the "Add new work detail" button, which sits at the top of
-- the column and never moves with the list. Reading the screen is how the panel's real position
-- is discovered -- the game exposes no rectangle for it -- and it is the same trick
-- fort/squad-equipment-search uses to sit under "Select item.".
local ADD_NEW = 'add new work detail'

-- Returns the screen column to line up with, and the row to sit on: the column of the anchor,
-- and the bottom of the labor panel, one row up.
--
-- The row comes from the game's own geometry (`info.labor.rect`), NOT from reading the screen.
-- Scraping for the last drawn row of the list cannot work here, because the buttons are drawn
-- in that same column: whatever they cover is not in the grid to be read, so the scan cannot
-- tell "the list ends here" from "the list is behind our own row". Two earlier tries showed
-- both failure modes -- the row chasing itself down to the bottom of the screen, and the row
-- parking itself on top of the last work detail. The panel's own rectangle has neither problem.
-- (The column is still read off the screen: the anchor sits above the buttons, so nothing we
-- draw can hide it.)
local function list_end_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    local col
    for y = 0, sh - 1 do
        local chars = {}
        for x = 0, sw - 1 do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local c = table.concat(chars):lower():find(ADD_NEW, 1, true)
        if c then col = c - 1 break end
    end
    if not col then return nil end
    local rect = df.global.game.main_interface.info.labor.rect
    return col, math.min(rect.y2 - 1, sh - 2)
end

NoMonsterSlayersOverlay = defclass(NoMonsterSlayersOverlay, overlay.OverlayWidget)
NoMonsterSlayersOverlay.ATTRS{
    desc = 'Adds Remove Monster Slayers / Auto buttons under the work detail list.',
    default_pos = {x = 14, y = -8},     -- fallback until the list is found on screen
    viewscreens = 'dwarfmode/Info/LABOR/WORK_DETAILS',
    frame = {w = #AUTO_TEXT + #REMOVE_TEXT, h = 1},
    version = 2,
}

function NoMonsterSlayersOverlay:init()
    self:addviews{
        -- [Auto] first, and the two labels butt up against each other so the brackets touch.
        -- Green while it is on, so the state reads at a glance without a second word.
        widgets.Label{
            view_id = 'auto',
            frame = {l = 0, t = 0, w = #AUTO_TEXT, h = 1},
            text = {{text = AUTO_TEXT,
                     pen = function() return isEnabled() and COLOR_LIGHTGREEN or COLOR_GRAY end}},
            on_click = function() self:toggle_auto() end,
        },
        widgets.Label{
            view_id = 'remove',
            frame = {l = #AUTO_TEXT, t = 0, w = #REMOVE_TEXT, h = 1},
            text = {{text = REMOVE_TEXT, pen = COLOR_WHITE}},
            on_click = function() self:do_remove() end,
        },
    }
end

function NoMonsterSlayersOverlay:do_remove()
    -- Auto off: show who they are and let one be picked. Auto on: the sweep is already the
    -- standing answer, so the button does what the sweep does.
    if not isEnabled() then
        SlayerPickerScreen{}:show()
        return
    end
    local n = remove_slayers()
    dfhack.println(n > 0
        and ('no-monster-slayers: took %d monster slayer post%s.'):format(n, n == 1 and '' or 's')
        or 'no-monster-slayers: no monster slayer holds a post here.')
end

function NoMonsterSlayersOverlay:toggle_auto()
    set_enabled(not isEnabled())
    -- the label's pen is a function of the toggle, so the colour follows on the next render
    if isEnabled() then remove_slayers() end
end

-- sit under the end of the list, aligned with "Add new work detail" (frame coords are relative
-- to the interface rect, so the screen position is converted by the interface origin)
function NoMonsterSlayersOverlay:reposition()
    local col, row = list_end_pos()
    if not col then return false end
    local ir = gui.get_interface_rect()
    -- [Remove Monster Slayers] lines up with "Add new work detail" -- its opening bracket sits
    -- in the anchor's column -- and [Auto] hangs off its left, so the pair ends under the list
    -- rather than sticking out past it.
    self.frame = {w = self.frame.w, h = self.frame.h,
                  l = col - #AUTO_TEXT - ir.x1, t = row - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    self.placed = true
    self.placed_size = {dfhack.screen.getWindowSize()}
    return true
end

-- Nothing is drawn until the panel has been found. `default_pos` is a guess -- it has to be
-- something, and whatever it is lands in the middle of the work-detail list -- so on the first
-- frame after the screen opens the buttons would sit on top of a labor until the first
-- reposition moved them off. Finding the anchor first and drawing second means the pair is only
-- ever seen where it belongs.
function NoMonsterSlayersOverlay:render(dc)
    if self.placed then
        -- a resize moves the panel, and the position worked out for the old window is as good
        -- as a guess: go back to finding it before drawing again
        local w, h = dfhack.screen.getWindowSize()
        if w ~= self.placed_size[1] or h ~= self.placed_size[2] then self.placed = false end
    end
    if not self.placed then
        -- the scrape reads the frame the game has already drawn, so it works from here; the
        -- draw itself waits for the next frame, which is a fifteenth of a second and unseen
        self:reposition()
        return
    end
    NoMonsterSlayersOverlay.super.render(self, dc)
end

-- The list grows, shrinks and scrolls, so the end of it moves: re-find it on a slow tick rather
-- than once. Reading the screen is not free, so this is deliberately lazy -- twice a second is
-- far faster than a work detail can be added.
function NoMonsterSlayersOverlay:overlay_onupdate()
    local now = dfhack.getTickCount()
    if self.placed and self.placed_ms and now >= self.placed_ms
        and now - self.placed_ms < 500 then return end
    self.placed_ms = now
    self:reposition()
end

OVERLAY_WIDGETS = {buttons = NoMonsterSlayersOverlay}

-- ---- entry point -------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('no-monster-slayers only works in fortress mode')
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('no-monster-slayers: Auto ' .. (isEnabled() and 'ON (sweeping)' or 'off'))
    return
end

local args = {...}
if args[1] == 'status' then
    local held = slayer_posts()
    print(('no-monster-slayers: %d monster slayer post%s in the fort.')
        :format(#held, #held == 1 and '' or 's'))
    for _, o in ipairs(held) do
        print(('  %s -- location %d'):format(holder_name(o), o.location_id))
    end
    print('  Auto: ' .. (isEnabled() and 'on' or 'off'))
    return
end

local posts = slayer_posts()
local names = {}
for _, o in ipairs(posts) do names[#names + 1] = holder_name(o) end
local n = remove_slayers()
for _, nm in ipairs(names) do print('  took the slayer post from ' .. nm) end
print(n > 0
    and ('no-monster-slayers: cleared %d monster slayer post%s.'):format(n, n == 1 and '' or 's')
    or 'no-monster-slayers: no monster slayer holds a post here.')
