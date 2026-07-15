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
    * dwarf-rts                 (registers the RTS-style squad-screen overlay)
    * inside-burrow             (arms the auto-seeded "inside+" burrow watcher)
    * labor-groups once         (builds the ordered crafting Work Details -- once per
                                 fort; skipped if its "Weaponsmithing" detail already
                                 exists, so manual tweaks survive. Run `labor-groups`
                                 by hand to force a re-apply.)
    * military-labor            (daily-syncs the "Military" work detail to your squads)
    * auto-tomb                 (1x1 Tomb zone on each coffin, 1x1 Pasture zone on each nest box)
    * auto-elf-chop             (enables the autochop gate that respects the elven tree limit)
    * item-description.expand   (overlay: expands a long item description to half-screen)
    * right-click-cancel        (overlay: right-click cancels designations/constructions)
    * dig-shapes                (overlay: right-click=mining; shaped digs -> stairs/walls/chop/remove)
    * plan-tile                 (overlay: left-drag during building placement -> tile a grid of it)

Run as `magnus-scripts lovely` to ALSO set two standing orders (no automatic
weaving, no automatic web collection), enable auto-name (letter-per-wave migrant
renamer), enable statue-redirect (selecting a statue jumps to its item sheet /
full description), and enable a batch of stock DFHack tools:
    enable: autobutcher, autoclothing, autonestbox, autotraining, burrow (auto-grow
            `name+` burrows), hide-tutorials, prioritize, seedwatch, suspendmanager,
            timestream
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
    -- soft return (not qerror): this script auto-runs from onMapLoad.init, which
    -- also fires on non-fort maps -- we just do nothing there instead of erroring.
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
    -- variant: nil -> remove our line; '' -> `magnus-scripts`; 'lovely' -> `magnus-scripts lovely`
    local lines, f = {}, io.open(INIT_PATH, 'r')
    if f then
        for line in f:lines() do
            if not line:match('^%s*magnus%-scripts') then lines[#lines + 1] = line end
        end
        f:close()
    end
    if variant then
        lines[#lines + 1] = 'magnus-scripts' .. (variant ~= '' and (' ' .. variant) or '')
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
    try('disable auto-mandate', function() dfhack.run_command('disable', 'auto-mandate') end)
    try('disable military-uniforms (gear service)', function() dfhack.run_command('disable', 'military-uniforms') end)
    try('disable inside-burrow', function() dfhack.run_command('disable', 'inside-burrow') end)
    try('disable military-labor', function() dfhack.run_command('disable', 'military-labor') end)
    try('disable auto-elf-chop', function() dfhack.run_command('disable', 'auto-elf-chop') end)
    try('disable tarrasque', function() dfhack.run_command('disable', 'tarrasque') end)
    try('disable dwarf-rts overlay', function() dfhack.run_command('overlay', 'disable', 'dwarf-rts.clickmove') end)
    try('disable item-description overlay', function() dfhack.run_command('overlay', 'disable', 'item-description.expand') end)
    try('disable right-click-cancel overlay', function() dfhack.run_command('overlay', 'disable', 'right-click-cancel.cancel') end)
    try('disable plan-tile overlay', function() dfhack.run_command('overlay', 'disable', 'plan-tile.tile') end)
    try('disable auto-name (migrant renamer)', function() dfhack.run_command('disable', 'auto-name') end)
    -- notifications (turn off + persist the notify config)
    try('disable notifications', function()
        local n = reqscript('internal/notify/notifications')
        for _, nm in ipairs({'needs_tomb', 'mandates_active', 'mandates_expiring', 'raids', 'planner_orders', 'trader_ready', 'empty_labor', 'civ_alert_outside', 'enemies_inside', 'agitated_typed'}) do
            if n.config and n.config.data and n.config.data[nm] then n.config.data[nm].enabled = false end
        end
        -- trader-notification suppressed DFHack's stock "traders_ready" alert; restore it.
        -- agitated-animals-notification hid the stock "agitated_count" line; restore that too.
        for _, nm in ipairs({'traders_ready', 'agitated_count'}) do
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
try('needs-tomb-notification', function() dfhack.run_script('needs-tomb-notification') end)
try('mandate-notification', function() dfhack.run_script('mandate-notification') end)
try('raid-notification', function() dfhack.run_script('raid-notification') end)
try('trader-notification', function() dfhack.run_script('trader-notification') end)
try('broker-ready (broker squad -> Ready while requested at depot)', function() dfhack.run_script('broker-ready') end)
try('empty-labor-notification', function() dfhack.run_script('empty-labor-notification') end)
try('civ-alert-notification', function() dfhack.run_script('civ-alert-notification') end)
try('enemies-inside-notification', function() dfhack.run_script('enemies-inside-notification') end)
try('agitated-animals-notification', function() dfhack.run_script('agitated-animals-notification') end)
try('planner-orders', function() dfhack.run_script('planner-orders') end)
try('auto-mandate (background)', function() dfhack.run_command('enable', 'auto-mandate') end)
try('military-uniforms (steel templates)', function() dfhack.run_command('military-uniforms') end)
try('dwarf-rts (squad RTS overlay)', function() dfhack.run_command('dwarf-rts') end)
-- embark-nobles intentionally NOT run here: it's unfinished and appears to interfere
-- with position assignments. Run `embark-nobles` by hand if you want it.
try('inside-burrow (arm auto-seed "inside+" burrow)', function() dfhack.run_command('enable', 'inside-burrow') end)
-- once per fort: skipped if labor-groups' signature detail ("Weaponsmithing") is already
-- present, so manual tweaks survive. Run `labor-groups` (no `once`) by hand to force.
try('labor-groups (ordered craft work details, once/fort)', function() dfhack.run_script('labor-groups', 'once') end)
try('military-labor (daily-sync the Military work detail)', function() dfhack.run_command('enable', 'military-labor') end)
try('auto-tomb (1x1 tomb zone on each coffin, pasture on each nest box)', function() dfhack.run_command('enable', 'auto-tomb') end)
try('auto-elf-chop (gate autochop by the elven tree-cutting limit)', function() dfhack.run_command('enable', 'auto-elf-chop') end)
-- make sure the Equip-screen overlay is picked up even on a freshly-added script
try('overlay rescan', function() require('plugins.overlay').rescan() end)
-- our custom overlays default to OFF when first discovered -- turn them on
try('overlay enable item-description.expand', function() dfhack.run_command('overlay', 'enable', 'item-description.expand') end)
try('right-click-cancel (load + enable overlay)', function() dfhack.run_script('right-click-cancel') end)
try('dig-shapes (right-click=mining; shaped digs->stairs/walls/chop/remove)', function() dfhack.run_script('dig-shapes') end)
try('plan-tile (drag to tile many buildings during placement)', function() dfhack.run_script('plan-tile') end)

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
        function() dfhack.run_command('enable', 'auto-name') end)

    -- selecting a statue jumps straight to the statue item's sheet (its full description)
    try('statue-redirect (auto-open statue details)',
        function() dfhack.run_command('enable', 'statue-redirect') end)

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
    for _, c in ipairs({'autoclothing', 'autonestbox', 'autotraining', 'burrow',
                        'hide-tutorials', 'prioritize', 'seedwatch', 'suspendmanager',
                        'timestream'}) do enable_tool(c) end
    for _, c in ipairs({'fast-heat', 'realistic-melting'}) do tweak_tool(c) end
end

-- arm (or refresh) auto-run on the next fort load, recording which variant was used
try('arm auto-run on load (' .. (lovely and 'lovely' or 'plain') .. ')',
    function() assert(set_autostart(lovely and 'lovely' or '')) end)

print('Done. One-shot commands: destroy-forbidden, clear-flows, raid-status, attack-invaders.')
print('Manual toggle: no-pausing (stops all pausing).')
print(('Auto-run-on-load ARMED (%s). It will re-run every time this fort loads until you run '
    .. '`magnus-scripts disable`.'):format(lovely and 'magnus-scripts lovely' or 'magnus-scripts'))
