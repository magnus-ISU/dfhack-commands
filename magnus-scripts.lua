-- Enable all of magnus's persistent DFHack helpers at once.
--@module = false
--[[
    magnus-scripts

Activates the "always-on" helpers in this pack:
    * needs-tomb-notification   (registers the notify-panel alert)
    * mandate-notification      (registers the immediate-mandate notification)
    * auto-mandate              (enables the background work-order service)

The one-shot commands in the pack (destroy-forbidden, clear-flows, raid-status,
attack-invaders) are run on demand and are not touched here.

no-pausing is deliberately NOT enabled here: it stops ALL pausing, so it is left
as a manual toggle -- run `no-pausing` (or `enable no-pausing`) when you want it.

Add `magnus-scripts` to dfhack-config/init/dfhack.init to turn everything on each
session.
]]

if not dfhack.world.isFortressMode() then
    qerror('magnus-scripts: load a fort first (fortress mode only)')
end

local function try(label, fn)
    local ok, err = pcall(fn)
    print(('  [%s] %s'):format(ok and 'ok' or 'FAIL', label))
    if not ok then print('       ' .. tostring(err)) end
end

print('magnus-scripts: enabling persistent helpers...')
try('needs-tomb-notification', function() dfhack.run_script('needs-tomb-notification') end)
try('mandate-notification', function() dfhack.run_script('mandate-notification') end)
try('auto-mandate (background)', function() dfhack.run_command('enable', 'auto-mandate') end)

print('Done. One-shot commands: destroy-forbidden, clear-flows, raid-status, attack-invaders.')
print('Manual toggle: no-pausing (stops all pausing).')
