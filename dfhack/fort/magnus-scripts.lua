-- Enable all of magnus's persistent DFHack helpers at once.
--@module = false
local help = [====[

magnus-scripts
==============

Tags: fort | auto

Enable all of magnus's persistent DFHack helpers at once.

Activates the "always-on" helpers in this pack:
    * needs-tomb-notification   (registers the notify-panel alert)
    * mandate-notification      (registers the immediate-mandate notification)
    * trader-notification       (counts down the days a caravan is at your depot)
    * empty-labor-notification  (warns: a work detail is "Only Selected" with no workers)
    * civ-alert-notification    (warns: citizens still outside the civilian-alert burrow)
    * enemies-inside-notification (warns: enemies inside the civilian-alert burrow)
    * planner-orders            (notify + 1-click orders for planned-building items)
    * auto-mandate              (enables the background work-order service)
    * military-uniforms         (creates the steel uniform templates + registers
                                 the Equip-screen auto-gear overlay/work-orders)
    * military-uniforms altsched once  (creates the "even month"/"odd month" training
                                 routines on every squad -- once per fort; skipped
                                 if they already exist so schedule edits survive)
    * dwarf-rts                 (registers the RTS-style squad-screen overlay)
    * inside-burrow             (arms the auto-seeded "inside+" burrow watcher)
    * labor-groups once         (builds the ordered crafting Work Details -- once per
                                 fort; skipped if its "Weaponsmithing" detail already
                                 exists, so manual tweaks survive. Run `labor-groups`
                                 by hand to force a re-apply.)
    * military-labor            (daily-syncs the "Military" work detail to your squads)
    * auto-tomb                 (1x1 Tomb zone on each coffin, 1x1 Pasture zone on each nest box)
    * auto-elf-chop             (manages tree-chopping under the elven limit -- keeps stock
                                 autochop OFF and designates the closest trees itself; dormant
                                 until you flag a chop burrow in gui/autochop)
    * caravan-unstick           (weekly watchdog: clears stuck caravans, which silently
                                 block ALL future caravans and, for the home civ, migrants)
    * item-description.expand   (overlay: expands a long item description to half-screen)
    * right-click-cancel        (overlay: right-click cancels designations/constructions)
    * dig-shapes                (overlay: right-click=mining; shaped digs -> stairs/walls/chop/remove)
    * plan-tile                 (overlay: left-drag during building placement -> tile a grid of it)
    * smooth-movement           (plugin: smooth creature movement between tiles, plus
                                 the free camera -- scroll glide, pixel-perfect drag
                                 pan, sub-tile rest; opted in for fort mode here)
    * hide-tutorials            (stock tool: suppresses the tutorial popups; covers
                                 ADVENTURE popups too, so the adventure-mode branch
                                 enables it as well)

In ADVENTURE mode this script instead enables the adventure helpers, among them
adv/auto-save (saves as "adventurer-autosave" every 20 minutes, timed from the
last successful save and deferred until no menu is open) and smooth-movement
(the free camera is auto-on in adventure mode; the glide is set to a slow,
cinematic catch-up: `smooth-movement camera speed 150`).

Run as `magnus-scripts lovely` to ALSO set two standing orders (no automatic
weaving, no automatic web collection), enable auto-name (letter-per-wave migrant
renamer), enable statue-redirect (selecting a statue jumps to its item sheet /
full description), enable rusty-legends (yearly sweep that keeps skill rust off
retired adventurers and off anyone's legendary skills), and enable a batch of stock
DFHack tools:
    enable: autobutcher, autoclothing, autonestbox, burrow (auto-grow
            `name+` burrows), prioritize, seedwatch, suspendmanager, timestream
    tweak:  fast-heat, realistic-melting
It also applies autobutcher EMBARK PROTECTION once per fort: any animal you
arrive with in numbers above autobutcher's target for its category (e.g. 9
female dogs vs the default 4 female adults) gets that race's target raised to
the embark count, so your starting animals aren't butchered. Raise-only, never
re-runs (later-bred surplus is still butchered down to those targets).
(The timer-driven tools -- autocheese, automilk, autoshear, cleanowned,
orders-reevaluate -- aren't plain enables; turn those on in gui/control-panel.)

The one-shot commands in the pack (destroy-forbidden, clear-flows, raid-status,
attack-invaders) are run on demand and are not touched here.

military-uniforms is safe to run every session: it refreshes its own "Steel - *"
templates and re-removes the default metal uniforms (idempotent). The gear-order
service stays OFF until you flip its toggles on the squad Equip screen (Shift-G
queue, Shift-M masterwork); that choice persists with the fort.

embark-nobles is NOT run by this pack: it is UNFINISHED (it appears to interfere
with position assignments), so it was removed from magnus-scripts. Run it by hand
(`embark-nobles`) only if you want to, and `embark-nobles dry` to preview first.

inside-burrow is safe every session: it only acts when the fort has NO burrows
yet, seeding a self-expanding `inside+` burrow on the first interior tile a miner
digs, then disabling itself. Once you have any burrow it does nothing.

no-pausing is deliberately NOT enabled here: it stops ALL pausing, so it is left
as a manual toggle -- run `no-pausing` (or `enable no-pausing`) when you want it.

Add `magnus-scripts` to dfhack-config/init/dfhack.init to turn everything on each
session.

Usage
-----

    magnus-scripts
        Enable the always-on helper set (the list above).

    magnus-scripts lovely
        Also set the two standing orders and enable the stock-tool batch.

    magnus-scripts disable
        Turn off everything this pack switched on (services, the dwarf-rts overlay, and
        the notifications). One-shot results and the `lovely` stock tools are left alone.
]====]

if not dfhack.world.isFortressMode() then
    -- ADVENTURE mode: enable the adventure-mode helpers here. onMapLoad.init runs this script on
    -- every map load (forts AND adventurers), so once the pack is armed these re-enable on each
    -- adventure load -- i.e. they persist / stay on across sessions, same as the fort helpers.
    if dfhack.world.isAdventureMode() then
        local function atry(label, fn)
            local ok, err = pcall(fn)
            print(('  [%s] %s'):format(ok and 'ok' or 'FAIL', label))
            if not ok then print('       ' .. tostring(err)) end
        end
        if ({...})[1] == 'disable' then
            atry('disable adv/auto-save', function() dfhack.run_script('adv/auto-save', 'disable') end)
            atry('disable adv/keep-talking', function() dfhack.run_command('disable', 'adv/keep-talking') end)
            atry('stop adv/im-sure', function() dfhack.run_script('adv/im-sure', 'stop') end)
            atry('stop adv/right-click-move', function() dfhack.run_script('adv/right-click-move', 'stop') end)
            atry('stop adv/reveal', function() dfhack.run_script('adv/reveal', 'stop') end)
            atry('disable adv/keep-inventory', function() dfhack.run_command('disable', 'adv/keep-inventory') end)
            atry('disable adv/always-be-satiated', function() dfhack.run_command('disable', 'adv/always-be-satiated') end)
            atry('disable hide-tutorials', function() dfhack.run_command('disable', 'hide-tutorials') end)
            atry('disable smooth-movement', function() dfhack.run_command('disable', 'smooth-movement') end)
        else
            -- saves every 20 minutes by driving the escape menu the way a player
            -- does. Counted from the last successful save, and it waits for a
            -- quiet moment (no menu/conversation) rather than interrupt one.
            atry('adv/auto-save (save "adventurer-autosave" every 20 minutes)',
                function() dfhack.run_script('adv/auto-save', 'enable', '20') end)
            atry('adv/keep-talking (auto-reopen conversations after picking a topic)',
                function() dfhack.run_command('enable', 'adv/keep-talking') end)
            atry('adv/im-sure (auto-dismiss the "can\'t act" prompt)',
                function() dfhack.run_script('adv/im-sure') end)
            -- the right-click pathing half of the old im-sure. Every screen scan sits behind
            -- option_list.open, so it is free at rest (~800 FPS with it on, vs 59 for the
            -- ungated version it replaced).
            atry('adv/right-click-move (right-click a tile to just walk there)',
                function() dfhack.run_script('adv/right-click-move') end)
            -- map stays revealed while it's safe; combat, the travel screen and sleep
            -- unreveal it (unreveal-before-travel keeps the reveal plugin's backup valid)
            atry('adv/reveal (map revealed while safe; hidden in combat/travel/sleep)',
                function() dfhack.run_script('adv/reveal') end)
            -- keeps the inventory panel open after each action, in the same mode and at the
            -- same scroll offset; Escape/right-click still close it
            atry('adv/keep-inventory (inventory stays open after actions)',
                function() dfhack.run_command('enable', 'adv/keep-inventory') end)
            -- eats/drinks from the pack when hungry/thirsty, out of combat, vomit-safe;
            -- it mutes keep-inventory for the moment each consumption takes
            atry('adv/always-be-satiated (auto eat/drink from pack)',
                function() dfhack.run_command('enable', 'adv/always-be-satiated') end)
            -- adv/fear-no-goblin is deliberately NOT armed here: it patches world_site
            -- types, so it stays a manual toggle -- run `adv/fear-no-goblin` when you
            -- actually want to fast-travel a goblin pit, `stop` when done.
            -- hide-tutorials handles ADVENTURE_POPUP_* too, not just fortress popups
            atry('hide-tutorials (suppress adventure tutorial popups)',
                function() dfhack.run_command('enable', 'hide-tutorials') end)
            -- unit-sheet description + kills + weight/volume panel; registered for
            -- dungeonmode too, so make sure it is loaded and switched on here
            atry('creature-description overlay (unit sheet info panel)', function()
                dfhack.run_script('fort/creature-description')
                dfhack.run_command('overlay', 'enable', 'fort/creature-description.desc')
            end)
            -- the adventurer-creation helpers are default-enabled overlays; re-assert
            -- them here so they stay armed for the NEXT character even if toggled off
            atry('embark creation overlays (auto-outfit, values, map tooltips)', function()
                for _, w in ipairs({'embark/adventurer-default-items.auto',
                                    'embark/adventurer-values.values',
                                    'embark/adventurer-map.map'}) do
                    dfhack.run_command('overlay', 'enable', w)
                end
            end)
            -- smooth creature movement + the free camera (auto-on in adventure mode: the
            -- camera follows the player, so every step glides instead of snapping). The
            -- slow glide tau makes the catch-up leisurely/cinematic (default 35 = ~100ms;
            -- 150 = ~450ms). Fails gracefully when the plugin binary isn't installed
            -- (run `make build` in dfhack-commands).
            atry('smooth-movement (player/creature interpolation + slow camera glide)', function()
                pcall(dfhack.run_command, 'load', 'smooth-movement')
                dfhack.run_command('enable', 'smooth-movement')
                pcall(dfhack.run_command, 'smooth-movement', 'camera', 'speed', '150')
            end)
        end
    end
    -- soft return (not qerror): onMapLoad.init also fires on other non-fort maps; do nothing there.
    return
end

local function try(label, fn)
    local ok, err = pcall(fn)
    print(('  [%s] %s'):format(ok and 'ok' or 'FAIL', label))
    if not ok then print('       ' .. tostring(err)) end
end

-- ---- self-arming: (re)run automatically on every fort load ------------------
-- We keep exactly one `magnus-scripts [lovely]` line in dfhack-config's
-- onMapLoad.init (which DFHack runs each time a fort map loads). `disable`
-- removes it. This is what makes the pack persist across game restarts.
local INIT_PATH = dfhack.getDFPath() .. '/dfhack-config/init/onMapLoad.init'

local function set_autostart(variant)
    -- variant: nil -> remove our line; '' -> `fort/magnus-scripts`; 'lovely' -> `... lovely`.
    -- The strip also matches the bare pre-fort/ spelling so old installs upgrade cleanly.
    local lines, f = {}, io.open(INIT_PATH, 'r')
    if f then
        for line in f:lines() do
            if not (line:match('^%s*magnus%-scripts') or line:match('^%s*fort/magnus%-scripts')) then
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    if variant then
        lines[#lines + 1] = 'fort/magnus-scripts' .. (variant ~= '' and (' ' .. variant) or '')
    end
    local w = io.open(INIT_PATH, 'w')
    if not w then return false, 'could not write ' .. INIT_PATH end
    w:write(table.concat(lines, '\n'))
    if #lines > 0 then w:write('\n') end
    w:close()
    return true
end

-- ---- `magnus-scripts disable`: turn off everything this pack switched on ------
if ({...})[1] == 'disable' then
    print('magnus-scripts: disabling all helpers...')
    -- background services + the one enableable overlays
    try('disable auto-mandate', function() dfhack.run_command('disable', 'fort/auto-mandate') end)
    try('disable military-uniforms (gear service)', function() dfhack.run_command('disable', 'fort/military-uniforms') end)
    try('disable inside-burrow', function() dfhack.run_command('disable', 'fort/inside-burrow') end)
    try('disable military-labor', function() dfhack.run_command('disable', 'fort/military-labor') end)
    try('disable auto-elf-chop', function() dfhack.run_command('disable', 'fort/auto-elf-chop') end)
    try('disable tarrasque', function() dfhack.run_command('disable', 'fort/tarrasque') end)
    try('disable caravan-unstick', function() dfhack.run_command('disable', 'fort/caravan-unstick') end)
    try('disable hide-tutorials', function() dfhack.run_command('disable', 'hide-tutorials') end)
    try('disable smooth-movement', function() dfhack.run_command('disable', 'smooth-movement') end)
    try('disable dwarf-rts overlay', function() dfhack.run_command('overlay', 'disable', 'fort/dwarf-rts.clickmove') end)
    try('disable item-description overlay', function() dfhack.run_command('overlay', 'disable', 'fort/item-description.expand') end)
    try('disable right-click-cancel overlay', function() dfhack.run_command('overlay', 'disable', 'fort/right-click-cancel.cancel') end)
    try('disable plan-tile overlay', function() dfhack.run_command('overlay', 'disable', 'fort/plan-tile.tile') end)
    try('disable auto-name (migrant renamer)', function() dfhack.run_command('disable', 'fort/auto-name') end)
    try('disable statue-redirect (auto-open statue details)', function() dfhack.run_command('disable', 'fort/statue-redirect') end)
    try('disable rusty-legends', function() dfhack.run_command('disable', 'fort/rusty-legends') end)
    -- notifications (turn off + persist the notify config)
    try('disable notifications', function()
        local n = reqscript('internal/notify/notifications')
        for _, nm in ipairs({'needs_tomb', 'mandates_active', 'mandates_expiring', 'raids', 'planner_orders', 'trader_ready', 'empty_labor', 'civ_alert_outside', 'enemies_inside', 'agitated_typed'}) do
            if n.config and n.config.data and n.config.data[nm] then n.config.data[nm].enabled = false end
        end
        -- trader-notification suppressed DFHack's stock "traders_ready" alert; restore it.
        -- agitated-animals-notification hid the stock "agitated_count" + "hostile_count"
        -- lines and `lovely` hid "warn_nuisance"; restore those too.
        for _, nm in ipairs({'traders_ready', 'agitated_count', 'hostile_count', 'warn_nuisance'}) do
            if n.config and n.config.data and n.config.data[nm] then n.config.data[nm].enabled = true end
        end
        if n.config and n.config.write then n.config:write() end
    end)
    try('remove auto-run on load', function() assert(set_autostart(nil)) end)
    print('Done. Pack helpers disabled and auto-run-on-load removed. (One-shots already')
    print('applied -- labor-groups, the steel uniform templates -- are left as-is. The')
    print('`lovely` stock tools, if enabled, stay on -- toggle in gui/control-panel.)')
    return
end

local lovely = ({...})[1] == 'lovely'

print('magnus-scripts: enabling persistent helpers...')
try('needs-tomb-notification', function() dfhack.run_script('fort/needs-tomb-notification') end)
try('mandate-notification', function() dfhack.run_script('fort/mandate-notification') end)
try('raid-notification', function() dfhack.run_script('fort/raid-notification') end)
try('trader-notification', function() dfhack.run_script('fort/trader-notification') end)
try('broker-ready (broker squad -> Ready while requested at depot)', function() dfhack.run_script('fort/broker-ready') end)
try('empty-labor-notification', function() dfhack.run_script('fort/empty-labor-notification') end)
try('civ-alert-notification', function() dfhack.run_script('fort/civ-alert-notification') end)
try('enemies-inside-notification', function() dfhack.run_script('fort/enemies-inside-notification') end)
try('agitated-animals-notification', function() dfhack.run_script('fort/agitated-animals-notification') end)
try('planner-orders', function() dfhack.run_script('fort/planner-orders') end)
try('auto-mandate (background)', function() dfhack.run_command('enable', 'fort/auto-mandate') end)
try('military-uniforms (steel templates)', function() dfhack.run_command('fort/military-uniforms') end)
-- once per fort: creates the "even month"/"odd month" training routines (train that month,
-- Ready the rest) on every squad; skipped if they already exist so schedule edits survive.
try('military-uniforms altsched (even/odd month training routines, once/fort)',
    function() dfhack.run_command('fort/military-uniforms', 'altsched', 'once') end)
try('dwarf-rts (squad RTS overlay)', function() dfhack.run_command('fort/dwarf-rts') end)
-- embark-nobles intentionally NOT run here: it's unfinished and appears to interfere
-- with position assignments. Run `embark-nobles` by hand if you want it.
try('inside-burrow (arm auto-seed "inside+" burrow)', function() dfhack.run_command('enable', 'fort/inside-burrow') end)
-- once per fort: skipped if labor-groups' signature detail ("Weaponsmithing") is already
-- present, so manual tweaks survive. Run `labor-groups` (no `once`) by hand to force.
try('labor-groups (ordered craft work details, once/fort)', function() dfhack.run_script('fort/labor-groups', 'once') end)
try('military-labor (daily-sync the Military work detail)', function() dfhack.run_command('enable', 'fort/military-labor') end)
try('auto-tomb (1x1 tomb zone on each coffin, pasture on each nest box)', function() dfhack.run_command('enable', 'fort/auto-tomb') end)
try('auto-elf-chop (gate autochop by the elven tree-cutting limit)', function() dfhack.run_command('enable', 'fort/auto-elf-chop') end)
try('caravan-unstick (weekly watchdog: stuck caravans block trade AND migrants)', function() dfhack.run_command('enable', 'fort/caravan-unstick') end)
-- stock DFHack tool, but always-on rather than `lovely`-only: it also covers ADVENTURE
-- popups (it keys off an ADVENTURE_POPUP_ prefix), so the adventure branch enables it too
try('hide-tutorials (suppress fort AND adventure tutorial popups)', function() dfhack.run_command('enable', 'hide-tutorials') end)
-- make sure the Equip-screen overlay is picked up even on a freshly-added script
try('overlay rescan', function() require('plugins.overlay').rescan() end)
-- our custom overlays default to OFF when first discovered -- turn them on
try('overlay enable item-description.expand', function() dfhack.run_command('overlay', 'enable', 'fort/item-description.expand') end)
-- belt-and-braces: the fort/ move renamed every widget, orphaning saved overlay
-- states -- and dwarf-rts' own re-enable pointed at the OLD name for a while, so
-- installs from that window have it persisted off under the new name. Enabling
-- here makes running magnus-scripts always bring it back, whatever the history.
try('overlay enable fort/dwarf-rts.clickmove', function() dfhack.run_command('overlay', 'enable', 'fort/dwarf-rts.clickmove') end)
try('overlay enable fort/right-click-cancel.cancel', function() dfhack.run_command('overlay', 'enable', 'fort/right-click-cancel.cancel') end)
try('overlay enable fort/plan-tile.tile', function() dfhack.run_command('overlay', 'enable', 'fort/plan-tile.tile') end)
try('right-click-cancel (load + enable overlay)', function() dfhack.run_script('fort/right-click-cancel') end)
try('dig-shapes (right-click=mining; shaped digs->stairs/walls/chop/remove)', function() dfhack.run_script('fort/dig-shapes') end)
try('plan-tile (drag to tile many buildings during placement)', function() dfhack.run_script('fort/plan-tile') end)

-- render-only smooth interpolation of creature sprites between adjacent tiles, plus the
-- free camera (scroll glide + pixel-perfect drag pan + sub-tile rest). 3rd-party C++
-- plugin by notliad; source vendored as the other-authors/df-smooth-movement submodule,
-- binary installed in DFHack's hack/plugins/. It auto-loads at DFHack startup when the
-- .plug.so is present; `load` here is a harmless fallback for a mid-session install. If
-- the binary isn't installed this just fails gracefully -- run `make build` to build it
-- (SDL 2D renderer only). Part of the BASE set (not just lovely): the camera is opted in
-- here for fort mode too (adventure mode turns it on by itself).
try('smooth-movement (smooth creature movement + free camera)', function()
    pcall(dfhack.run_command, 'load', 'smooth-movement')
    dfhack.run_command('enable', 'smooth-movement')
    pcall(dfhack.run_command, 'smooth-movement', 'camera', 'on')
end)

-- ---- `magnus-scripts lovely`: standing orders + the stock-tool batch ---------
if lovely then
    -- standing orders (1 = on/auto, 0 = off): enforce off every session
    df.global.standing_orders_auto_loom = 0
    df.global.standing_orders_auto_collect_webs = 0
    -- fish only in designated fishing zones (1 = on), so fishers don't wander the whole map
    df.global.standing_orders_zoneonly_fish = 1
    print('  [ok] standing orders: no automatic weaving, no automatic web collection, fish only in zones')

    -- rename each migrant wave to a shared starting letter (A, B, C, ...); enabling
    -- also does the one-time retroactive pass and keeps watching for new waves
    try('auto-name (letter-per-wave migrant renamer)',
        function() dfhack.run_command('enable', 'fort/auto-name') end)

    -- selecting a statue jumps straight to the statue item's sheet (its full description)
    try('statue-redirect (auto-open statue details)',
        function() dfhack.run_command('enable', 'fort/statue-redirect') end)

    -- a retired adventurer arrives with a lifetime of skills and then rusts them away
    -- sitting in a dining room; a legendary crafter loses an edge to a season of
    -- hauling. Scrubs rust off adventurers (every skill, matched on the nemesis
    -- ADVENTURER flag) and off any citizen's Legendary+ skills. Nothing else rusts less.
    try('rusty-legends (no skill rust on adventurers or legendary skills)',
        function() dfhack.run_command('enable', 'fort/rusty-legends') end)

    -- hide the stock "N thieving or mischievous creature(s)" notify line (kea/rhesus
    -- noise). The other stock lines this pack replaces (agitated_count, hostile_count)
    -- are hidden by agitated-animals-notification, which plain magnus-scripts loads.
    try('hide "thieving or mischievous" notification', function()
        local n = reqscript('internal/notify/notifications')
        n.config.data.warn_nuisance = n.config.data.warn_nuisance or {version = 1}
        n.config.data.warn_nuisance.enabled = false
    end)

    -- dead forgotten beasts / titans / bronze colossi roll 1/100 each winter solstice to
    -- revive and later RETURN as a real attack (the megabeast pool never runs dry)
    try('tarrasque (solstice megabeast revival)',
        function() dfhack.run_command('enable', 'fort/tarrasque') end)

    local function enable_tool(c) try('enable ' .. c, function() dfhack.run_command('enable', c) end) end
    local function tweak_tool(c) try('tweak ' .. c, function() dfhack.run_command('tweak', c) end) end

    -- autobutcher: NEVER disturb custom settings. If you already have it enabled (or a
    -- watch list configured), leave it exactly as you set it; only enable it fresh when
    -- it's off and unconfigured. (`enable` doesn't wipe settings, but this avoids even
    -- touching it when you've tuned your target counts / watch list.)
    try('autobutcher (skip if already configured)', function()
        local ab = require('plugins.autobutcher')
        local configured = ab.isEnabled()
        if not configured then
            local ok, wl = pcall(ab.autobutcher_getWatchList)
            configured = ok and wl and #wl > 0
        end
        if configured then
            print('       autobutcher already configured -- left untouched')
        else
            dfhack.run_command('enable', 'autobutcher')
        end
    end)

    -- embark protection (once per fort): if you arrive with MORE of an animal than
    -- autobutcher's target for its category (e.g. 9 female dogs vs a default of 4),
    -- raise that race's target to the count you embarked with so your starting
    -- animals are never butchered down to the default. Raise-only; never lowers
    -- targets, and never re-runs on later loads (so animals bred later still get
    -- butchered down to these targets as usual).
    try('autobutcher embark protection (once/fort)', function()
        if not dfhack.isMapLoaded() then return end
        local KEY = 'magnus-scripts/autobutcher-embark'
        if (dfhack.persistent.getSiteData(KEY) or {}).done then
            print('       already applied on this fort -- skipped')
            return
        end
        local ab = require('plugins.autobutcher')
        local defaults = ab.autobutcher_getSettings()
        local watch = {}
        for _, d in ipairs(ab.autobutcher_getWatchList()) do watch[d.id] = d end
        local counts = {}
        for _, u in ipairs(df.global.world.units.active) do
            if dfhack.units.isFortControlled(u) and dfhack.units.isTame(u)
                and dfhack.units.isAlive(u) and dfhack.units.isAnimal(u) then
                local c = counts[u.race] or {fk = 0, mk = 0, fa = 0, ma = 0}
                local adult = dfhack.units.isAdult(u)
                local male = u.sex == df.pronoun_type.he
                local k = adult and (male and 'ma' or 'fa') or (male and 'mk' or 'fk')
                c[k] = c[k] + 1
                counts[u.race] = c
            end
        end
        for race, c in pairs(counts) do
            local base = watch[race] or defaults
            local fk, mk = math.max(base.fk, c.fk), math.max(base.mk, c.mk)
            local fa, ma = math.max(base.fa, c.fa), math.max(base.ma, c.ma)
            if fk > base.fk or mk > base.mk or fa > base.fa or ma > base.ma then
                ab.autobutcher_setWatchListRace(race, fk, mk, fa, ma, true)
                local cr = df.creature_raw.find(race)
                print(('       %s: targets raised to %d/%d/%d/%d (fk/mk/fa/ma)')
                    :format(cr and cr.name[1] or ('race ' .. race), fk, mk, fa, ma))
            end
        end
        dfhack.persistent.saveSiteData(KEY, {done = true})
    end)

    -- `burrow` = auto-grow: burrows named with a trailing `+` (e.g. inside-burrow's
    -- `inside+`) expand into adjacent tiles as they're dug out. inside-burrow only
    -- enables it when it seeds -- enable it here unconditionally so manually-made
    -- `name+` burrows grow too.
    -- hide-tutorials is NOT in this list: it moved to the always-on set above, so
    -- plain `magnus-scripts` gets it (and so does the adventure branch).
    for _, c in ipairs({'autoclothing', 'autonestbox', 'burrow',
                        'prioritize', 'seedwatch', 'suspendmanager',
                        'timestream'}) do enable_tool(c) end
    for _, c in ipairs({'fast-heat', 'realistic-melting'}) do tweak_tool(c) end
end

-- arm (or refresh) auto-run on the next fort load, recording which variant was used
try('arm auto-run on load (' .. (lovely and 'lovely' or 'plain') .. ')',
    function() assert(set_autostart(lovely and 'lovely' or '')) end)

print('Done. One-shot commands: destroy-forbidden, clear-flows, raid-status, attack-invaders.')
print('Manual toggle: no-pausing (stops all pausing).')
print(('Auto-run-on-load ARMED (%s). It will re-run every time this fort loads until you run '
    .. '`fort/magnus-scripts disable`.'):format(lovely and 'fort/magnus-scripts lovely' or 'fort/magnus-scripts'))
