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
    * planner-orders            (notify + 1-click orders for planned-building items)
    * auto-mandate              (enables the background work-order service)
    * military-uniforms         (creates the steel uniform templates + registers
                                 the Equip-screen auto-gear overlay/work-orders)
    * dwarf-rts                 (registers the RTS-style squad-screen overlay)
    * embark-nobles             (assigns the key fort positions by skill)
    * inside-burrow             (arms the auto-seeded "inside+" burrow watcher)
    * labor-groups once         (builds the ordered crafting Work Details -- once per
                                 fort; a re-run is a no-op so manual tweaks survive)
    * military-labor            (daily-syncs the "Military" work detail to your squads)

Run as `magnus-scripts lovely` to ALSO set two standing orders (no automatic
weaving, no automatic web collection) and enable a batch of stock DFHack tools:
    enable: autobutcher, autoclothing, autonestbox, autotraining, hide-tutorials,
            prioritize, seedwatch, suspendmanager, timestream
    tweak:  fast-heat, realistic-melting
(The timer-driven tools -- autocheese, automilk, autoshear, cleanowned,
orders-reevaluate -- aren't plain enables; turn those on in gui/control-panel.)

The one-shot commands in the pack (destroy-forbidden, clear-flows, raid-status,
attack-invaders) are run on demand and are not touched here.

military-uniforms is safe to run every session: it refreshes its own "Steel - *"
templates and re-removes the default metal uniforms (idempotent). The gear-order
service stays OFF until you flip its toggles on the squad Equip screen (Shift-G
queue, Shift-M masterwork); that choice persists with the fort.

embark-nobles is safe every session: it only fills VACANT positions and leaves
already-assigned nobles untouched, so your manual noble choices are respected.
`embark-nobles dry` previews what (if anything) it would fill.

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
    qerror('magnus-scripts: load a fort first (fortress mode only)')
end

local function try(label, fn)
    local ok, err = pcall(fn)
    print(('  [%s] %s'):format(ok and 'ok' or 'FAIL', label))
    if not ok then print('       ' .. tostring(err)) end
end

-- ---- `magnus-scripts disable`: turn off everything this pack switched on ------
if ({...})[1] == 'disable' then
    print('magnus-scripts: disabling all helpers...')
    -- background services + the one enableable overlays
    try('disable auto-mandate', function() dfhack.run_command('disable', 'auto-mandate') end)
    try('disable military-uniforms (gear service)', function() dfhack.run_command('disable', 'military-uniforms') end)
    try('disable inside-burrow', function() dfhack.run_command('disable', 'inside-burrow') end)
    try('disable military-labor', function() dfhack.run_command('disable', 'military-labor') end)
    try('disable dwarf-rts overlay', function() dfhack.run_command('overlay', 'disable', 'dwarf-rts.clickmove') end)
    -- notifications (turn off + persist the notify config)
    try('disable notifications', function()
        local n = reqscript('internal/notify/notifications')
        for _, nm in ipairs({'needs_tomb', 'mandates_active', 'mandates_expiring', 'raids', 'planner_orders'}) do
            if n.config and n.config.data and n.config.data[nm] then n.config.data[nm].enabled = false end
        end
        if n.config and n.config.write then n.config:write() end
    end)
    print('Done. Pack helpers disabled. (One-shots already applied -- embark-nobles,')
    print('labor-groups, the steel uniform templates -- are left as-is. The `lovely`')
    print('stock tools, if you enabled them, stay on -- toggle those in gui/control-panel.)')
    return
end

print('magnus-scripts: enabling persistent helpers...')
try('needs-tomb-notification', function() dfhack.run_script('needs-tomb-notification') end)
try('mandate-notification', function() dfhack.run_script('mandate-notification') end)
try('raid-notification', function() dfhack.run_script('raid-notification') end)
try('planner-orders', function() dfhack.run_script('planner-orders') end)
try('auto-mandate (background)', function() dfhack.run_command('enable', 'auto-mandate') end)
try('military-uniforms (steel templates)', function() dfhack.run_command('military-uniforms') end)
try('dwarf-rts (squad RTS overlay)', function() dfhack.run_command('dwarf-rts') end)
try('embark-nobles (assign key fort positions)', function() dfhack.run_command('embark-nobles') end)
try('inside-burrow (arm auto-seed "inside+" burrow)', function() dfhack.run_command('enable', 'inside-burrow') end)
try('labor-groups (ordered craft work details, once/fort)', function() dfhack.run_script('labor-groups', 'once') end)
try('military-labor (daily-sync the Military work detail)', function() dfhack.run_command('enable', 'military-labor') end)
-- make sure the Equip-screen overlay is picked up even on a freshly-added script
try('overlay rescan', function() require('plugins.overlay').rescan() end)

-- ---- `magnus-scripts lovely`: standing orders + the stock-tool batch ---------
if ({...})[1] == 'lovely' then
    -- standing orders (1 = on/auto, 0 = off): enforce off every session
    df.global.standing_orders_auto_loom = 0
    df.global.standing_orders_auto_collect_webs = 0
    print('  [ok] standing orders: no automatic weaving, no automatic web collection')

    local function enable_tool(c) try('enable ' .. c, function() dfhack.run_command('enable', c) end) end
    local function tweak_tool(c) try('tweak ' .. c, function() dfhack.run_command('tweak', c) end) end
    for _, c in ipairs({'autobutcher', 'autoclothing', 'autonestbox', 'autotraining',
                        'hide-tutorials', 'prioritize', 'seedwatch', 'suspendmanager',
                        'timestream'}) do enable_tool(c) end
    for _, c in ipairs({'fast-heat', 'realistic-melting'}) do tweak_tool(c) end
end

print('Done. One-shot commands: destroy-forbidden, clear-flows, raid-status, attack-invaders.')
print('Manual toggle: no-pausing (stops all pausing).')
