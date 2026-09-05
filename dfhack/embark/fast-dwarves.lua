-- Jump the fortress embark screen straight to a dwarven civ and a good spot.
--@module = true
--[[
embark/fast-dwarves

One shot, run on the "create new fortress" world map (`choose_start_site`).  It
does the clicks that never vary and then gets out of the way:

0. **Dismisses the quick-start tutorial prompt** if it is up -- "Start tutorial /
   Skip tutorial", then the "On your own!" box behind it.  That pair is drawn by
   the viewscreen itself and shows up in **no** field on it (`page` stays 0 and
   not one scalar changes when you answer it), so the only way to answer it is to
   click the rendered button text, one frame apart.
1. **Picks and commits a dwarven origin civilization.**  In a modded world the origin list is
   long -- this one has 33 entries across orcs, drow, kobolds, succubi, forest
   golems, illithids and two kinds of dwarf -- and the one DF preselects is
   whatever it felt like.  This walks `start_civ` and keeps the entities whose
   race is really `DWARF`; a dark-dwarf or drow civ is NOT silently substituted,
   and if the world has no dwarves at all it says so and changes nothing.  Among
   the dwarven civs it takes the one with the most **living historical figures**
   (`start_civ_nem_num`, which is exactly the count of that entity's members whose
   `died_year` is still negative), then the most sites, then the most population.
   Living figures lead because DF's own embark warning is "your selected
   civilization is dead or dying" -- a civ can hold more sites and more abstract
   population than its rival and still be the one DF flags.
2. **Centres the map on a good spot near that civ.**  Scored, not random: see
   "Choosing the tile" below.
3. **Clicks the real "Embark" button**, which leaves you at "Click on the map to
   embark!" with the size selector up.  **The final click is yours.**  The tool
   never places the fortress; it only guarantees that the map you are now looking
   at is a sensible one.  It deliberately does not write `location`: a valid
   rectangle there plus `choosing_embark` makes DF jump straight to its
   Confirm/Abort box, one step past where this should stop.

Steps 0 and 3 are clicks, and each one needs DF to draw a frame before the next
thing is on screen, so the tool runs as a frame-paced step machine rather than
straight through.  Two things that machine has to respect, both of which broke
earlier versions outright:

- `dfhack.timeout` must use **`frames`**, not `ticks` -- world time is not
  running before the embark, so a tick timeout never fires here and everything
  after the first click is simply dropped.
- **gui/launcher is a viewscreen too.**  Run from the launcher, which is how
  anyone actually runs this, `dfhack.gui.getCurViewscreen` returns DFHack's own
  window -- so clicks fed to it never reach the game -- and the launcher is drawn
  across the middle rows, which is exactly where the tutorial prompt's buttons
  are, so a screen scan finds nothing to click either.  Clicks therefore go to
  `getDFViewscreen`, and every screen read waits until the two agree.

Choosing the tile
-----------------
Candidates are every world tile 2-6 tiles from one of the civ's own sites (near
enough for a caravan, far enough not to embark on top of a mountain hall).  Each
is scored on:

- **how many of the surrounding 5x5 world tiles are embarkable** -- this is the
  main term, and it is what "lots of embarkable tiles" means: DF refuses an
  embark that is entirely water or mountains, and a spot ringed by ocean or
  peaks leaves you no room to slide the rectangle around once you are placing it;
- a bonus for a **river or brook** on the tile, for **hills/forest/grassland**
  (soil and trees), and for **mountains adjacent** (ore and a wall at your back);
- a penalty for distance from the nearest dwarven site.

Tiles that already carry a site, and tiles that are ocean, lake or mountain, are
never candidates.

Fields where it can, clicks where it must
-----------------------------------------
The embark screen has no widgets (`scr.widgets.children` is empty) and no
interface keys -- every control is a mouse-only hit test.  Only the camera is a
plain field.  Everything else is a click:

- **The origin civilization.**  `selected_civ` is a decoy.  It reads back exactly
  what you write and DF ignores it: measured with `selected_civ` sitting on the
  dwarves while the checkbox AND the detail pane both stayed on the goblin civ,
  and again with it set to 13 while the panel kept describing entry 1.  The list
  commits on a click and nothing else.  So the target is parked at the top of the
  list with `scroll_position_civ = idx` (entries are three rows apart, name then
  race), its row is found by name and clicked, and the result is **confirmed**
  against the name DF prints in the detail pane before moving on.
- **The tutorial prompt**, which is invisible besides: `page` stays 0 and not one
  scalar on the viewscreen changes when you answer it.
- **The Embark button**, matched only on the row that also reads "Show
  elevation" -- the first plain match on this screen is the hint prose
  `Click "Embark" to place your fortress`.

How it runs
-----------
Normally it does not: **the overlay does.**  `embark/fast-dwarves.auto` fires
once per fortress embark screen, the moment that screen appears, and is what
`fort/magnus-scripts` switches on -- magnus-scripts toggles overlays, never
commands, so a one-shot command alone would sit in the script folder and never
run for anybody.  It acts only on a screen still showing the whole-world map; once
you have zoomed in or armed the placement you are steering, and it keeps out.

The command form is for checking its work:

    embark/fast-dwarves          do it now
    embark/fast-dwarves dry      print the pick and the score, change nothing
    embark/fast-dwarves list     list every dwarven civ with the numbers used
    embark/fast-dwarves civ <n>  force the `start_civ` index `list` printed
]]

local MIN_RING = 2          -- world tiles: no closer to a site than this
local MAX_RING = 6          -- ...and no further
local WINDOW = 2            -- 5x5 window = WINDOW tiles each way
local UNEMBARKABLE = {Ocean = true, Lake = true, Mountains = true}
local NICE_TYPES = {Hills = 3, Forest = 3, Grassland = 2, Swamp = 1}

local function wd() return df.global.world.world_data end

-- the embark screen, or nil with a reason
local function get_screen()
    local scr = dfhack.gui.getDFViewscreen(true)
    if not df.viewscreen_choose_start_sitest:is_instance(scr) then
        return nil, 'not on the fortress embark screen'
    end
    return scr
end

local function creature_id(race)
    local c = df.creature_raw.find(race)
    return c and c.creature_id or nil
end

local function race_plural(race)
    local c = df.creature_raw.find(race)
    return c and (c.name[1] ~= '' and c.name[1] or c.name[0]) or '?'
end

-- Every dwarven civ in the origin list, best first.  Only a literal DWARF race
-- counts: HA_DARK_DWARF and friends are their own people with their own gear,
-- buildings and diplomacy, and picking one because its token happens to contain
-- "DWARF" would be a different game entirely.
local function dwarf_civs(scr)
    local out = {}
    for i = 0, #scr.start_civ - 1 do
        local e = scr.start_civ[i]
        if e and creature_id(e.race) == 'DWARF' then
            out[#out + 1] = {
                idx = i,
                entity = e,
                name = dfhack.translation.translateName(e.name, true),
                living = scr.start_civ_nem_num[i] or 0,
                sites = scr.start_civ_site_num[i] or 0,
                pop = scr.start_civ_entpop_num[i] or 0,
            }
        end
    end
    -- living figures first: DF's "dead or dying" warning does not track sites or
    -- abstract population, and the larger civ in this world was the flagged one
    table.sort(out, function(a, b)
        if a.living ~= b.living then return a.living > b.living end
        if a.sites ~= b.sites then return a.sites > b.sites end
        return a.pop > b.pop
    end)
    return out
end

-- world tile -> region_map_entry, or nil off the edge of the world
local function tile(wx, wy)
    local w = wd()
    if wx < 0 or wy < 0 or wx >= w.world_width or wy >= w.world_height then return end
    local ok, rme = pcall(function() return w.region_map[wx]:_displace(wy) end)
    return ok and rme or nil
end

local function region_type(rme)
    local w = wd()
    local ok, t = pcall(function()
        return df.world_region_type[w.regions[rme.region_id].type]
    end)
    return ok and t or nil
end

-- memoized: can a fortress stand here at all?  DF's own rule is "not entirely on
-- water or mountains"; a tile already carrying a site is out because the embark
-- rectangle would land inside somebody's town.
local function make_embarkable()
    local memo = {}
    return function(wx, wy)
        local key = wx * 4096 + wy
        local v = memo[key]
        if v ~= nil then return v end
        local rme = tile(wx, wy)
        local t = rme and region_type(rme)
        v = (t ~= nil) and not UNEMBARKABLE[t] and (#rme.sites == 0)
        memo[key] = v
        return v
    end
end

-- every world tile MIN_RING..MAX_RING from one of the civ's sites, deduplicated
local function candidate_tiles(sites)
    local seen, out = {}, {}
    for _, s in ipairs(sites) do
        for dx = -MAX_RING, MAX_RING do
            for dy = -MAX_RING, MAX_RING do
                local d = math.max(math.abs(dx), math.abs(dy))
                if d >= MIN_RING and d <= MAX_RING then
                    local wx, wy = s.x + dx, s.y + dy
                    local key = wx * 4096 + wy
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = {x = wx, y = wy}
                    end
                end
            end
        end
    end
    return out
end

local function nearest_site_dist(sites, wx, wy)
    local best = math.huge
    for _, s in ipairs(sites) do
        local d = math.max(math.abs(s.x - wx), math.abs(s.y - wy))
        if d < best then best = d end
    end
    return best
end

local function score_tile(wx, wy, embarkable, sites)
    if not embarkable(wx, wy) then return end
    local rme = tile(wx, wy)
    local t = region_type(rme)
    -- the main term: elbow room.  Every embarkable tile in the 5x5 window is a
    -- tile the placement rectangle could still slide onto.
    local room, mountains = 0, 0
    for dx = -WINDOW, WINDOW do
        for dy = -WINDOW, WINDOW do
            if embarkable(wx + dx, wy + dy) then room = room + 1 end
            if math.max(math.abs(dx), math.abs(dy)) == 1 then
                local n = tile(wx + dx, wy + dy)
                if n and region_type(n) == 'Mountains' then mountains = mountains + 1 end
            end
        end
    end
    local score = room * 4
    score = score + (NICE_TYPES[t] or 0) * 3
    if mountains > 0 then score = score + 6 end          -- ore, and a wall at your back
    local ok, water = pcall(function()
        return rme.flags.has_river or rme.flags.is_brook
    end)
    if ok and water then score = score + 8 end
    score = score - nearest_site_dist(sites, wx, wy) * 2
    return score, {room = room, biome = t or '?', mountains = mountains,
                   dist = nearest_site_dist(sites, wx, wy)}
end

-- world-tile positions of every site this civ owns
local function civ_sites(entity_id)
    local out = {}
    for _, s in ipairs(wd().sites) do
        if s.civ_id == entity_id then out[#out + 1] = {x = s.pos.x, y = s.pos.y} end
    end
    return out
end

-- Park the map on (wx, wy): the world-map camera and the zoomed-in camera, which
-- is in EMBARK tiles, 16 to a world tile.
--
-- `location` is deliberately NOT written.  Writing a valid rectangle there while
-- `choosing_embark` is set makes DF treat the spot as already chosen and go
-- straight to its Confirm/Abort box, which is one step past where this tool is
-- supposed to stop.  Zooming and then clicking the real Embark button leaves the
-- rectangle following the player's cursor, which is the point.
local function go_to(scr, wx, wy)
    scr.choosing_civilization = false
    scr.choosing_reclaim = false
    scr.choosing_embark = false
    scr.doing_site_finder = false
    scr.region_cent_x, scr.region_cent_y = wx, wy
    scr.zoom_cent_x, scr.zoom_cent_y = wx * 16 + 8, wy * 16 + 8
    scr.zoomed_in = true
end

-- ---- the quick-start tutorial prompt ----------------------------------------

local gui = require('gui')

local function read_row(y)
    local gps = df.global.gps
    local row = {}
    for x = 0, gps.dimx - 1 do
        local t = dfhack.screen.readTile(x, y)
        local ch = t and t.ch or 0
        row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- Find `needle`, optionally only on a row that also carries `anchor`.  Returns
-- the cell to click, or nil.
local function find_text(needle, anchor)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local row = read_row(y)
        if not anchor or row:find(anchor, 1, true) then
            local a, b = row:find(needle, 1, true)
            if a then return (a - 1 + b - 1) // 2, y end
        end
    end
end

-- Click the middle of `needle`.  gps.mouse_* has to be moved first (DF hit-tests
-- against it) and `precise_mouse_*` with it -- the cell pair alone is not enough
-- on this screen.
--
-- The click goes to `getDFViewscreen`, NOT `getCurViewscreen`: when this is run
-- from gui/launcher -- which is how anyone actually runs it -- the current
-- viewscreen is DFHack's own launcher window, and every click was landing there
-- instead of on the embark screen.
local function click_at(cx, cy)
    local gps = df.global.gps
    gps.mouse_x, gps.mouse_y = cx, cy
    gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = cy * gps.tile_pixel_y + gps.tile_pixel_y // 2
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
end

local function click_text(needle, anchor)
    local cx, cy = find_text(needle, anchor)
    if not cx then return false end
    click_at(cx, cy)
    return true
end

-- True while a DFHack window (gui/launcher, gui/control-panel) is drawn over
-- the game.  Nothing may be read off the screen until it has gone: the launcher
-- covers the middle rows, which is exactly where the tutorial prompt's buttons
-- are, so a screen scan run the instant the command fires finds nothing.
local function dfhack_screen_up()
    return dfhack.gui.getCurViewscreen(true) ~= dfhack.gui.getDFViewscreen(true)
end

-- A frame-paced step machine.  Everything here has to wait for DF to RENDER
-- before the next thing is clickable -- `dfhack.screen.readTile` reads the last
-- drawn frame, and a fed click is processed immediately but its consequences are
-- only visible one frame later.  ('frames' is the right unit: world time is not
-- running pre-embark, so a 'ticks' timeout never fires here.  Measured.)
-- MAX_STEPS is a backstop, not a budget: every caller stops itself long before
-- it. It exists because a callback that forgets to return true reschedules for
-- ever, and a runaway chain here does not just spin -- it keeps clicking.
local MAX_STEPS = 200

local function every_frame(fn)
    local n = 0
    local function step()
        n = n + 1
        if fn(n) or n >= MAX_STEPS then return end
        dfhack.timeout(2, 'frames', step)
    end
    step()
end

-- "Skip tutorial", then the "On your own!" box that replaces it.  Polls rather
-- than assuming a fixed delay, and calls `cont` either way -- immediately on the
-- first frame when no prompt is up at all.
local WAIT_FRAMES = 40       -- give-up budget, in loop iterations (2 frames each)
local SETTLE = 8             -- clean iterations before believing "no prompt"
local NUDGE_AFTER = 6        -- iterations before Escaping a DFHack window shut

-- Is the game's own screen readable this frame?  If a DFHack window is over it,
-- give it a moment to close on its own and then close it: this tool cannot work
-- through one, and gui/launcher does not always go away by itself.
local function screen_ready(n)
    if not dfhack_screen_up() then return true end
    if n >= NUDGE_AFTER then
        gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'LEAVESCREEN')
    end
    return false
end

local function skip_tutorial(cont)
    local stage = 1          -- 1 = want "Skip tutorial", 2 = want "Okay", 3 = done
    local clean = 0          -- consecutive iterations with a readable, empty screen
    local function finish()
        if stage > 1 then
            print('embark/fast-dwarves: dismissed the quick-start tutorial prompt.')
        end
        cont()
        return true
    end
    every_frame(function(n)
        -- Nothing on screen can be trusted while a DFHack window is over it, so
        -- wait the launcher out rather than reading through it.
        if not screen_ready(n) then
            clean = 0
            if n >= WAIT_FRAMES then return finish() end
            return false
        end
        if stage == 1 then
            if click_text('Skip tutorial') then
                stage = 2
                return false
            end
            -- the second box on its own: the first was answered by hand
            if click_text('Okay') then
                stage = 3
                return finish()
            end
            -- Neither button is on an unobstructed screen -- but that is only
            -- worth believing after it has stayed that way for a few frames.
            -- When the launcher closes, DF takes about six frames to redraw the
            -- prompt into the buffer, and concluding "no tutorial" inside that
            -- gap is exactly how this failed: measured 3 clean-but-empty
            -- iterations before "Skip tutorial" appeared at 95,21.
            --
            -- It has to be a settle count and not a landmark: the world-map hint
            -- line is drawn BEHIND the prompt and is on screen the whole time,
            -- so there is nothing on the plain screen that the prompt hides.
            clean = clean + 1
            if clean >= SETTLE then return finish() end
            return false
        end
        -- stage 2: the "On your own!" box takes a frame to replace the first
        if click_text('Okay') then
            stage = 3
            return finish()
        end
        if n >= WAIT_FRAMES then return finish() end
        return false
    end)
end

-- The civilization DF has actually committed to, read off its own panel: the
-- detail block under the list, whose name sits two rows above "Population:".
-- Sliced from the column "Population:" starts in, not taken as the whole row --
-- embark/extra-info's own panel shares these rows and would be read as part of
-- the name.
local function committed_civ_name()
    local gps = df.global.gps
    for y = 2, gps.dimy - 1 do
        local a = read_row(y):find('Population:', 1, true)
        if a then
            return (read_row(y - 2):sub(a):gsub('%s+$', ''))
        end
    end
end

-- The civ list draws each entry as two rows, the name then its race, so a row
-- carrying the name with the race directly under it is a list row and nothing
-- else.  This matters: embark/extra-info lists the very same civilization names
-- in its neighbour block, and a plain screen-wide search for the name found THAT
-- first and clicked the map instead -- which also closed the civ panel.
local function find_civ_row(needle, race_word)
    local gps = df.global.gps
    for y = 0, gps.dimy - 2 do
        local a, b = read_row(y):find(needle, 1, true)
        if a and read_row(y + 1):find(race_word, 1, true) then
            return (a - 1 + b - 1) // 2, y
        end
    end
end

-- Pick the origin civilization the only way that sticks: by clicking its row.
--
-- `selected_civ` is a decoy.  It reads back exactly what you write, it is an
-- index into `start_civ`, and DF ignores it -- measured with `selected_civ`
-- sitting on the dwarves while the checkbox AND the detail pane both stayed on
-- the goblin civ, and again with it set to 13 while the panel kept describing
-- entry 1.  Only a click moves DF's own bookkeeping.
--
-- `scroll_position_civ = idx` parks that entry at the top of the list (rows step
-- by 3, name then race), so the row is on screen and can be found by name.  The
-- click is confirmed against the detail pane rather than assumed, and repeated a
-- few times if it did not take.
local function panel_open()
    -- the civ list's detail block is the only thing on this screen that prints
    -- "Population:"; the hover info panel prints "Neighbors:" and biome lines
    local gps = df.global.gps
    for y = 2, gps.dimy - 1 do
        if read_row(y):find('Population:', 1, true) then return true end
    end
    return false
end

local function choose_civ(scr, pick, cont)
    local needle = pick.name:sub(1, 18)
    local race = race_plural(pick.entity.race)
    local race_word = race:sub(1, 1):upper() .. race:sub(2)   -- the list capitalises it
    local tries, last_open, last_click = 0, -99, -99
    -- MUST return true, not `cont`'s value: every_frame reschedules on anything
    -- falsy, and `cont` here starts the placement step, which returns nothing.
    -- Returning it meant this loop never ended and kicked off a fresh placement
    -- every pass -- dozens of concurrent step machines clicking over each other,
    -- which is what made the whole thing look intermittent.
    local function stop(ok)
        scr.choosing_civilization = false
        cont(ok)
        return true
    end
    every_frame(function(n)
        if not screen_ready(n) then
            if n >= WAIT_FRAMES then return stop(false) end
            return false
        end
        tries = tries + 1
        if tries >= WAIT_FRAMES then return stop(false) end

        if not panel_open() then
            -- Open it by its own button.  Writing `choosing_civilization` does
            -- open the panel for a frame, but DF drops it again as soon as the
            -- cursor is over the map -- it draws the hover info panel instead --
            -- so a run with the mouse anywhere near the world map would find the
            -- list gone before it could click a row.  Clicking the button makes
            -- DF hold it open the way it does for a player.
            if tries - last_open >= 6 then
                last_open = tries
                click_text('Choose origin civilization')
            end
            return false
        end

        local cur = committed_civ_name()
        if cur and cur:sub(1, #needle) == needle then return stop(true) end

        scr.scroll_position_civ = pick.idx
        local cx, cy = find_civ_row(needle, race_word)
        if cx and tries - last_click >= 6 then
            last_click = tries
            click_at(cx, cy)
        end
        return false
    end)
end

-- ---- the command ------------------------------------------------------------

local function place(scr, pick, dry, done)
    local civ = pick.entity
    local sites = civ_sites(civ.id)
    if #sites == 0 then
        print(('embark/fast-dwarves: %s (%s) holds no sites this tool can find, ' ..
               'so there is nowhere to aim. Nothing changed.')
            :format(pick.name, race_plural(civ.race)))
        return done()
    end

    local embarkable = make_embarkable()
    local best, best_score, best_why
    for _, c in ipairs(candidate_tiles(sites)) do
        local s, detail = score_tile(c.x, c.y, embarkable, sites)
        if s and (not best_score or s > best_score) then
            best, best_score, best_why = c, s, detail
        end
    end
    if not best then
        print(('embark/fast-dwarves: no embarkable tile within %d world tiles of ' ..
               'any %s site. Nothing changed.'):format(MAX_RING, pick.name))
        return done()
    end

    print(('embark/fast-dwarves: origin civ [%d] %s (%s) -- %d living figures, ' ..
           '%d sites, ~%d population.')
        :format(pick.idx, pick.name, race_plural(civ.race),
                pick.living, pick.sites, pick.pop))
    print(('  tile (%d, %d): %s, %d/%d embarkable tiles around it, %d world tiles ' ..
           'from the nearest hall%s.')
        :format(best.x, best.y, best_why.biome, best_why.room,
                (WINDOW * 2 + 1) * (WINDOW * 2 + 1), best_why.dist,
                best_why.mountains > 0 and ', mountains next door' or ''))

    if dry then
        print('  dry run: nothing changed.')
        return done()
    end

    scr.selected_civ = pick.idx
    go_to(scr, best.x, best.y)

    -- The zoomed-in view has to be drawn once before its button row exists to be
    -- clicked.  "Embark" is matched only on the row that also says "Show
    -- elevation" -- that pair is the button bar; the first plain match for
    -- "Embark" on this screen is the hint prose `Click "Embark" to place your
    -- fortress`, and clicking that does nothing.
    every_frame(function(n)
        if screen_ready(n) and click_text('Embark', 'Show elevation') then
            print('  Click on the map to place the fortress -- that part is yours.')
            done()
            return true
        end
        if n > WAIT_FRAMES then
            print('  Could not find the Embark button; the map is centred, ' ..
                  'click Embark yourself.')
            done()
            return true
        end
        return false
    end)
end

function run(mode, arg, done)
    done = done or function() end
    local scr, why = get_screen()
    if not scr then
        qerror(('embark/fast-dwarves: %s. Open "Create new world/fortress" first.')
            :format(why))
    end
    -- claim the screen so the overlay does not start a second run alongside a
    -- hand-typed one; two step machines clicking at once is a mess
    handled_screen = scr

    local civs = dwarf_civs(scr)
    if #civs == 0 then
        print('embark/fast-dwarves: this world has no dwarven civilization ' ..
              '(nothing whose race is DWARF). Nothing changed.')
        return done()
    end

    if mode == 'list' then
        print('embark/fast-dwarves: dwarven origin civilizations, best first.')
        print('  idx  living  sites   pop  name')
        for _, c in ipairs(civs) do
            print(('  %3d  %6d  %5d  %4d  %s')
                :format(c.idx, c.living, c.sites, c.pop, c.name))
        end
        print('  Force one with:  embark/fast-dwarves civ <idx>')
        return done()
    end

    local pick = civs[1]
    if mode == 'civ' then
        local want = tonumber(arg)
        pick = nil
        for _, c in ipairs(civs) do if c.idx == want then pick = c end end
        if not pick then
            qerror(('embark/fast-dwarves: %s is not a dwarven civ index; ' ..
                    'run "embark/fast-dwarves list".'):format(tostring(arg)))
        end
    end

    -- the tutorial prompt eats clicks and hides the map, so it goes first; the
    -- rest runs in its continuation, a frame or two later
    skip_tutorial(function()
        if mode == 'dry' then return place(scr, pick, true, done) end
        choose_civ(scr, pick, function(ok)
            if not ok then
                print(('embark/fast-dwarves: could not get DF to commit to %s; ' ..
                       'pick it yourself under "Choose origin civilization".')
                    :format(pick.name))
            end
            place(scr, pick, false, done)
        end)
    end)
end

-- ---- the overlay that actually runs it ---------------------------------------

-- This is how the tool reaches anybody: `fort/magnus-scripts` toggles overlays,
-- not commands, so a one-shot command sitting in the script folder never fires
-- on its own no matter how correct it is.  The widget runs the sequence once per
-- embark screen, the moment that screen appears -- which is also the only
-- context where the screen reads cleanly, since there is no gui/launcher window
-- over the game to own the top viewscreen or cover the prompt's buttons.
local overlay = require('plugins.overlay')

-- kept in the script env so a reqscript reload does not re-fire on a screen that
-- has already been handled
handled_screen = handled_screen or nil
busy = busy or false

AutoEmbark = defclass(AutoEmbark, overlay.OverlayWidget)
AutoEmbark.ATTRS{
    desc = 'On a new fortress, pick a dwarven civ and a good spot and click Embark.',
    default_enabled = false,
    viewscreens = 'choose_start_site',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function AutoEmbark:overlay_onupdate()
    if busy then return end
    local scr = get_screen()
    if not scr then return end
    -- only on a fresh screen: once the player has zoomed in or armed the
    -- placement they are steering, and re-centring the map under them would be
    -- rude.  The screen identity guard stops it re-firing when they right-click
    -- back out to the world map.
    if handled_screen == scr then return end
    if scr.zoomed_in or scr.choosing_embark then
        handled_screen = scr
        return
    end
    handled_screen = scr
    busy = true
    local ok, err = pcall(run, nil, nil, function() busy = false end)
    if not ok then
        busy = false
        dfhack.printerr('embark/fast-dwarves: ' .. tostring(err))
    end
end

OVERLAY_WIDGETS = {auto = AutoEmbark}

if dfhack_flags.module then return end

local a1, a2 = ...
if a1 == '-dry' or a1 == '--dry' then a1 = 'dry' end
run(a1, a2)
