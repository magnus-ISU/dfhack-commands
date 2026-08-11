-- GUI switchboard for all of magnus's persistent DFHack helpers.
--@module = false
local help = [====[

magnus-scripts
==============

Tags: fort | adventure | auto

GUI switchboard for all of magnus's persistent DFHack helpers.

Running `fort/magnus-scripts` opens a window with four individually-scrollable
columns -- fort/, adv/, embark/ and vanilla DFHack tools -- with a checkbox per
script. Click a row to toggle that helper on or off; the choice is saved to
dfhack-config/magnus-scripts.json and re-applied on every map load. Column
headers toggle a whole column, [m] toggles all the mod columns (fort/adv/embark)
at once, and [r] is the "recommended" master switch: everything on (or, pressed
again, everything off).

The first run enables everything: any script that has never been toggled counts
as ON, so a fresh install starts with the whole pack armed.

Usage
-----

    fort/magnus-scripts
        Apply the saved selection for the current mode, then open the GUI.

    fort/magnus-scripts apply
        Headless: apply the saved selection for the current mode (this is what
        the auto-run line in onMapLoad.init calls on every map load).

    fort/magnus-scripts disable
        Turn off everything this pack manages and remove the auto-run line.
        The saved selection is kept, so re-running restores your choices.

The one-shot commands in the pack (destroy-forbidden, clear-flows, raid-status,
attack-invaders) are run on demand and are not managed here. no-pausing is
deliberately NOT managed here either: it stops ALL pausing, so it stays a
manual toggle. embark-nobles is unfinished and likewise not run.
]====]

local gui = require('gui')
local widgets = require('gui.widgets')
local json = require('json')

-- ---- config -----------------------------------------------------------------
-- One JSON file, shared by every world: { disabled = { [key]=true } }. Absent
-- key = enabled, so a fresh install (no file) has EVERYTHING on.
local CONFIG_PATH = dfhack.getDFPath() .. '/dfhack-config/magnus-scripts.json'

local function load_cfg()
    local ok, cfg = pcall(json.decode_file, CONFIG_PATH)
    if ok and type(cfg) == 'table' and type(cfg.disabled) == 'table' then return cfg end
    return {disabled = {}}
end

local cfg = load_cfg()

local function save_cfg()
    -- encode_file would render an empty set as [] -- harmless, load_cfg accepts both
    pcall(json.encode_file, cfg, CONFIG_PATH)
end

local function is_on(key) return not cfg.disabled[key] end
local function set_on(key, on)
    cfg.disabled[key] = (not on) and true or nil
    save_cfg()
end

-- ---- helpers ----------------------------------------------------------------
local function try(label, fn)
    local ok, err = pcall(fn)
    print(('  [%s] %s'):format(ok and 'ok' or 'FAIL', label))
    if not ok then print('       ' .. tostring(err)) end
end

local function cmd(...) local a = {...} return function() dfhack.run_command(table.unpack(a)) end end
local function script(...) local a = {...} return function() dfhack.run_script(table.unpack(a)) end end
local function overlay_set(state, name)
    return function() dfhack.run_command('overlay', state, name) end
end

-- mutate the stock notify panel's config (and persist it)
local function notify_cfg(mut)
    local n = reqscript('internal/notify/notifications')
    if n.config and n.config.data then mut(n.config.data) end
    if n.config and n.config.write then n.config:write() end
end
-- turn OUR notification lines off / stock lines back on when a row is disabled
local function notify_off(ours, restore_stock)
    return function()
        notify_cfg(function(data)
            for _, nm in ipairs(ours) do
                if data[nm] then data[nm].enabled = false end
            end
            for _, nm in ipairs(restore_stock or {}) do
                if data[nm] then data[nm].enabled = true end
            end
        end)
    end
end

-- ---- the registry -----------------------------------------------------------
-- Four columns; each item: key (config id), label (shown), mode ('fort'|'adv'|
-- 'any' -- when the enable/disable runs), enable(), disable(). Order = display
-- order. dig-building leads the fort column by request.
local COLUMNS = {
    {id = 'fort', title = 'fort/', mode = 'fort', items = {
        {key = 'dig-building', label = 'dig-building',
         enable = function()
            dfhack.run_script('fort/dig-building')
            dfhack.run_command('overlay', 'enable', 'fort/dig-building.picker')
         end,
         disable = overlay_set('disable', 'fort/dig-building.picker')},
        {key = 'dig-shapes', label = 'dig-shapes',
         enable = script('fort/dig-shapes'),
         disable = overlay_set('disable', 'fort/dig-shapes.watcher')},
        {key = 'right-click-cancel', label = 'right-click-cancel',
         enable = function()
            dfhack.run_script('fort/right-click-cancel')
            dfhack.run_command('overlay', 'enable', 'fort/right-click-cancel.cancel')
         end,
         disable = overlay_set('disable', 'fort/right-click-cancel.cancel')},
        {key = 'plan-tile', label = 'plan-tile',
         enable = function()
            dfhack.run_script('fort/plan-tile')
            dfhack.run_command('overlay', 'enable', 'fort/plan-tile.tile')
         end,
         disable = overlay_set('disable', 'fort/plan-tile.tile')},
        {key = 'item-description', label = 'item-description',
         enable = overlay_set('enable', 'fort/item-description.expand'),
         disable = overlay_set('disable', 'fort/item-description.expand')},
        {key = 'dwarf-rts', label = 'dwarf-rts',
         enable = function()
            dfhack.run_command('fort/dwarf-rts')
            dfhack.run_command('overlay', 'enable', 'fort/dwarf-rts.clickmove')
         end,
         disable = overlay_set('disable', 'fort/dwarf-rts.clickmove')},
        {key = 'auto-mandate', label = 'auto-mandate',
         enable = cmd('enable', 'fort/auto-mandate'), disable = cmd('disable', 'fort/auto-mandate')},
        {key = 'auto-tomb', label = 'auto-tomb',
         enable = cmd('enable', 'fort/auto-tomb'), disable = cmd('disable', 'fort/auto-tomb')},
        {key = 'auto-elf-chop', label = 'auto-elf-chop',
         enable = cmd('enable', 'fort/auto-elf-chop'), disable = cmd('disable', 'fort/auto-elf-chop')},
        {key = 'auto-name', label = 'auto-name',
         enable = cmd('enable', 'fort/auto-name'), disable = cmd('disable', 'fort/auto-name')},
        {key = 'statue-redirect', label = 'statue-redirect',
         enable = cmd('enable', 'fort/statue-redirect'), disable = cmd('disable', 'fort/statue-redirect')},
        {key = 'rusty-legends', label = 'rusty-legends',
         enable = cmd('enable', 'fort/rusty-legends'), disable = cmd('disable', 'fort/rusty-legends')},
        {key = 'tarrasque', label = 'tarrasque',
         enable = cmd('enable', 'fort/tarrasque'), disable = cmd('disable', 'fort/tarrasque')},
        {key = 'caravan-unstick', label = 'caravan-unstick',
         enable = cmd('enable', 'fort/caravan-unstick'), disable = cmd('disable', 'fort/caravan-unstick')},
        {key = 'adamantine-hospital', label = 'adamantine-hospital',
         enable = cmd('enable', 'fort/adamantine-hospital'), disable = cmd('disable', 'fort/adamantine-hospital')},
        {key = 'stable-stockpile-bins', label = 'stable-stockpile-bins',
         enable = cmd('enable', 'fort/stable-stockpile-bins'), disable = cmd('disable', 'fort/stable-stockpile-bins')},
        {key = 'military-uniforms', label = 'military-uniforms',
         enable = function()
            -- refresh the "Steel - *" templates (idempotent) + the once-per-fort
            -- even/odd month training routines
            dfhack.run_command('fort/military-uniforms')
            dfhack.run_command('fort/military-uniforms', 'altsched', 'once')
         end,
         disable = cmd('disable', 'fort/military-uniforms')},
        {key = 'military-labor', label = 'military-labor',
         enable = cmd('enable', 'fort/military-labor'), disable = cmd('disable', 'fort/military-labor')},
        {key = 'labor-groups', label = 'labor-groups (once/fort)',
         enable = script('fort/labor-groups', 'once'),
         disable = function() end},   -- one-shot; nothing to undo (details stay editable in-game)
        {key = 'inside-burrow', label = 'inside-burrow',
         enable = cmd('enable', 'fort/inside-burrow'), disable = cmd('disable', 'fort/inside-burrow')},
        {key = 'broker-ready', label = 'broker-ready',
         enable = script('fort/broker-ready'),
         disable = function()   -- bump the heartbeat generation; the running loop exits
            dfhack.internal.broker_ready_hb_gen = (dfhack.internal.broker_ready_hb_gen or 0) + 1
         end},
        {key = 'planner-orders', label = 'planner-orders',
         enable = script('fort/planner-orders'), disable = notify_off({'planner_orders'})},
        {key = 'needs-tomb-notification', label = 'needs-tomb-notification',
         enable = script('fort/needs-tomb-notification'), disable = notify_off({'needs_tomb'})},
        {key = 'mandate-notification', label = 'mandate-notification',
         enable = script('fort/mandate-notification'),
         disable = notify_off({'mandates_active', 'mandates_expiring'})},
        {key = 'raid-notification', label = 'raid-notification',
         enable = script('fort/raid-notification'), disable = notify_off({'raids'})},
        {key = 'trader-notification', label = 'trader-notification',
         enable = script('fort/trader-notification'),
         disable = notify_off({'trader_ready'}, {'traders_ready'})},
        {key = 'empty-labor-notification', label = 'empty-labor-notification',
         enable = script('fort/empty-labor-notification'), disable = notify_off({'empty_labor'})},
        {key = 'civ-alert-notification', label = 'civ-alert-notification',
         enable = script('fort/civ-alert-notification'), disable = notify_off({'civ_alert_outside'})},
        {key = 'enemies-inside-notification', label = 'enemies-inside-notif.',
         enable = script('fort/enemies-inside-notification'), disable = notify_off({'enemies_inside'})},
        {key = 'agitated-animals-notification', label = 'agitated-animals-notif.',
         enable = script('fort/agitated-animals-notification'),
         disable = notify_off({'agitated_typed'}, {'agitated_count', 'hostile_count'})},
        -- ---- rows below reconcile the registry with FORTRESS_MODE_FEATURES ----
        {key = 'stockpile-place', label = 'stockpile-place',
         enable = overlay_set('enable', 'fort/stockpile-place.watcher'),
         disable = overlay_set('disable', 'fort/stockpile-place.watcher')},
        {key = 'binnable-stockpile', label = 'binnable-stockpile',
         enable = function()
            dfhack.run_command('overlay', 'enable', 'fort/binnable-stockpile.button')
            dfhack.run_command('overlay', 'enable', 'fort/binnable-stockpile.category_toggle')
         end,
         disable = function()
            dfhack.run_command('overlay', 'disable', 'fort/binnable-stockpile.button')
            dfhack.run_command('overlay', 'disable', 'fort/binnable-stockpile.category_toggle')
         end},
        {key = 'workshop-tools', label = 'workshop-tools',
         enable = function()
            dfhack.run_command('overlay', 'enable', 'fort/workshop-tools.dupe')
            dfhack.run_command('overlay', 'enable', 'fort/workshop-tools.sort')
         end,
         disable = function()
            dfhack.run_command('overlay', 'disable', 'fort/workshop-tools.dupe')
            dfhack.run_command('overlay', 'disable', 'fort/workshop-tools.sort')
         end},
        {key = 'quick-order', label = 'quick-order',
         enable = overlay_set('enable', 'fort/quick-order.entry'),
         disable = overlay_set('disable', 'fort/quick-order.entry')},
        {key = 'training-barracks', label = 'training-barracks',
         enable = cmd('enable', 'fort/training-barracks'),
         disable = cmd('disable', 'fort/training-barracks')},
        {key = 'squad-buttons', label = 'squad-buttons',
         enable = overlay_set('enable', 'fort/squad-buttons.killtargets'),
         disable = overlay_set('disable', 'fort/squad-buttons.killtargets')},
        {key = 'auto-pasture', label = 'auto-pasture',
         enable = cmd('enable', 'fort/auto-pasture'),
         disable = cmd('disable', 'fort/auto-pasture')},
        {key = 'butcher-shop', label = 'butcher-shop',
         enable = overlay_set('enable', 'fort/butcher-shop.butcher'),
         disable = overlay_set('disable', 'fort/butcher-shop.butcher')},
        {key = 'animal-training', label = 'animal-training',
         enable = overlay_set('enable', 'fort/animal-training.config'),
         disable = overlay_set('disable', 'fort/animal-training.config')},
        {key = 'wild-animal-train', label = 'wild-animal-train',
         enable = overlay_set('enable', 'fort/wild-animal-train.train'),
         disable = overlay_set('disable', 'fort/wild-animal-train.train')},
        {key = 'idle-smiths', label = 'idle-smiths',
         enable = cmd('enable', 'fort/idle-smiths'),
         disable = cmd('disable', 'fort/idle-smiths')},
        {key = 'noble-symbol-search', label = 'noble-symbol-search',
         enable = overlay_set('enable', 'fort/noble-symbol-search.search'),
         disable = overlay_set('disable', 'fort/noble-symbol-search.search')},
        {key = 'squad-equipment-search', label = 'squad-equipment-search',
         enable = overlay_set('enable', 'fort/squad-equipment-search.search'),
         disable = overlay_set('disable', 'fort/squad-equipment-search.search')},
        {key = 'announcement-search', label = 'announcement-search',
         enable = overlay_set('enable', 'fort/announcement-search.search'),
         disable = overlay_set('disable', 'fort/announcement-search.search')},
        {key = 'agitated-animals-notification', label = 'agitated-animals-notification',
         enable = script('fort/agitated-animals-notification'),
         disable = notify_off({'agitated_typed'})},
        {key = 'enemies-inside-notification', label = 'enemies-inside-notification',
         enable = script('fort/enemies-inside-notification'),
         disable = notify_off({'enemies_inside'})},
        -- the embark-preparation screen exists outside fort mode: apply always
        {key = 'embark-prep', label = 'embark-prep', mode = 'any',
         enable = function()
            dfhack.run_command('overlay', 'enable', 'fort/embark-prep.loadout')
            dfhack.run_command('overlay', 'enable', 'fort/embark-prep.prefs')
         end,
         disable = function()
            dfhack.run_command('overlay', 'disable', 'fort/embark-prep.loadout')
            dfhack.run_command('overlay', 'disable', 'fort/embark-prep.prefs')
         end},
        -- loading the script registers its retire/unretire event hooks; there is
        -- no off switch by design (the roster must never silently lapse), so
        -- disable only says so
        {key = 'loyal-retirees', label = 'loyal-retirees',
         enable = script('fort/loyal-retirees'),
         disable = function()
            print('loyal-retirees: no off switch -- its roster protection stays'
                .. ' registered for this session (by design).')
         end},
    }},
    {id = 'adv', title = 'adv/', mode = 'adv', items = {
        -- enable reloads the script (fresh code if the file changed), re-registers
        -- its overlay from the new env, and shows the yellow launcher icon --
        -- clicking THAT opens the window, so map loads never pop it unasked.
        -- An advfort window already open keeps running its old code: close it,
        -- then toggle here. disable hides the icon; an open window is left alone.
        {key = 'adv-advfort', label = 'advfort',
         enable = function()
            reqscript('adv/advfort')
            require('plugins.overlay').rescan()
            dfhack.run_command('overlay', 'enable', 'adv/advfort.icon')
            reqscript('adv/advfort').icon_active = true
         end,
         disable = function()
            pcall(function() reqscript('adv/advfort').icon_active = false end)
            dfhack.run_command('overlay', 'disable', 'adv/advfort.icon')
         end},
        {key = 'adv-auto-save', label = 'auto-save (20 min)',
         enable = script('adv/auto-save', 'enable', '20'),
         disable = script('adv/auto-save', 'disable')},
        {key = 'adv-keep-talking', label = 'keep-talking',
         enable = cmd('enable', 'adv/keep-talking'), disable = cmd('disable', 'adv/keep-talking')},
        {key = 'adv-im-sure', label = 'im-sure',
         enable = script('adv/im-sure'), disable = script('adv/im-sure', 'stop')},
        {key = 'adv-right-click-move', label = 'right-click-move',
         enable = script('adv/right-click-move'), disable = script('adv/right-click-move', 'stop')},
        {key = 'adv-reveal', label = 'reveal (safe auto)',
         enable = script('adv/reveal'), disable = script('adv/reveal', 'stop')},
        {key = 'adv-keep-inventory', label = 'keep-inventory',
         enable = cmd('enable', 'adv/keep-inventory'), disable = cmd('disable', 'adv/keep-inventory')},
        -- enable = arm the script (sets running=true; a bare overlay enable
        -- leaves a mid-session `stop` in force) AND enable the overlay (the
        -- persistent switch a bare script run leaves alone)
        {key = 'adv-grab-stacks', label = 'grab-stacks',
         enable = function()
            dfhack.run_script('adv/grab-stacks')
            dfhack.run_command('overlay', 'enable', 'adv/grab-stacks.watch')
         end,
         disable = script('adv/grab-stacks', 'stop')},
        {key = 'adv-enemy-recenter', label = 'enemy-recenter',
         enable = function()
            dfhack.run_script('adv/enemy-recenter')
            dfhack.run_command('overlay', 'enable', 'adv/enemy-recenter.button')
         end,
         disable = script('adv/enemy-recenter', 'stop')},
        {key = 'adv-fear-no-goblin', label = 'fear-no-goblin',
         enable = function()
            dfhack.run_script('adv/fear-no-goblin')
            dfhack.run_command('overlay', 'enable', 'adv/fear-no-goblin.watch')
         end,
         disable = script('adv/fear-no-goblin', 'stop')},
        {key = 'adv-always-be-satiated', label = 'always-be-satiated',
         enable = cmd('enable', 'adv/always-be-satiated'), disable = cmd('disable', 'adv/always-be-satiated')},
        {key = 'adv-exhaustion-meter', label = 'exhaustion-meter',
         enable = function()
            dfhack.run_script('adv/exhaustion-meter')
            dfhack.run_command('overlay', 'enable', 'adv/exhaustion-meter.meter')
         end,
         disable = overlay_set('disable', 'adv/exhaustion-meter.meter')},
        -- pure overlay button, no running flag -- overlay state is the whole switch
        {key = 'adv-posession', label = 'posession',
         enable = overlay_set('enable', 'adv/posession.regain'),
         disable = overlay_set('disable', 'adv/posession.regain')},
        {key = 'adv-creature-description', label = 'creature-description',
         enable = function()
            dfhack.run_script('fort/creature-description')
            dfhack.run_command('overlay', 'enable', 'fort/creature-description.desc')
         end,
         disable = overlay_set('disable', 'fort/creature-description.desc')},
        {key = 'adv-map-travel', label = 'map-travel',
         enable = script('adv/map-travel'), disable = script('adv/map-travel', 'stop')},
        {key = 'adv-inventory-display-weight', label = 'inventory-display-weight',
         enable = script('adv/inventory-display-weight'),
         disable = script('adv/inventory-display-weight', 'stop')},
        {key = 'adv-inventory-search', label = 'inventory-search',
         enable = overlay_set('enable', 'adv/inventory-search.search'),
         disable = overlay_set('disable', 'adv/inventory-search.search')},
        {key = 'adv-travelling-hunger', label = 'travelling-hunger',
         enable = overlay_set('enable', 'adv/travelling-hunger.status'),
         disable = overlay_set('disable', 'adv/travelling-hunger.status')},
        {key = 'adv-heat-ice', label = 'heat-ice',
         enable = overlay_set('enable', 'adv/heat-ice.sorter'),
         disable = overlay_set('disable', 'adv/heat-ice.sorter')},
        {key = 'adv-read-the-map', label = 'read-the-map',
         enable = overlay_set('enable', 'adv/read-the-map.tooltip'),
         disable = overlay_set('disable', 'adv/read-the-map.tooltip')},
        {key = 'adv-appraiser', label = 'appraiser',
         enable = function()
            dfhack.run_script('adv/appraiser')
            dfhack.run_command('overlay', 'enable', 'adv/appraiser.watch')
         end,
         disable = script('adv/appraiser', 'stop')},
        {key = 'adv-watch-their-blade', label = 'watch-their-blade',
         enable = script('adv/watch-their-blade'),
         disable = script('adv/watch-their-blade', 'stop')},
    }},
    {id = 'embark', title = 'embark/', mode = 'any', items = {
        {key = 'embark-default-items', label = 'adventurer-default-items',
         enable = overlay_set('enable', 'embark/adventurer-default-items.auto'),
         disable = overlay_set('disable', 'embark/adventurer-default-items.auto')},
        {key = 'embark-values', label = 'adventurer-values',
         enable = overlay_set('enable', 'embark/adventurer-values.values'),
         disable = overlay_set('disable', 'embark/adventurer-values.values')},
        {key = 'embark-map', label = 'adventurer-map',
         enable = overlay_set('enable', 'embark/adventurer-map.map'),
         disable = overlay_set('disable', 'embark/adventurer-map.map')},
        -- fort/-prefixed but lives here: a title-screen helper, like the rest
        -- of this column it matters before any game is loaded
        {key = 'old-saves', label = 'old-saves',
         enable = overlay_set('enable', 'fix/old-saves.stamp'),
         disable = overlay_set('disable', 'fix/old-saves.stamp')},
    }},
    {id = 'vanilla', title = 'vanilla dfhack', mode = 'mixed', items = {
        {key = 'hide-tutorials', label = 'hide-tutorials', mode = 'any',
         enable = cmd('enable', 'hide-tutorials'), disable = cmd('disable', 'hide-tutorials')},
        -- 3rd-party C++ plugin (notliad; vendored + built by `make build`). Fort mode
        -- opts into the free camera, adventure mode into the world-tile slide.
        {key = 'smooth-movement', label = 'smooth-movement', mode = 'any',
         enable = function()
            pcall(dfhack.run_command, 'load', 'smooth-movement')
            dfhack.run_command('enable', 'smooth-movement')
            if dfhack.world.isAdventureMode() then
                dfhack.run_command('smooth-movement', 'slide', 'on')
            else
                dfhack.run_command('smooth-movement', 'camera', 'on')
            end
         end,
         disable = cmd('disable', 'smooth-movement')},
        {key = 'autobutcher', label = 'autobutcher (+embark prot.)', mode = 'fort',
         enable = function()
            -- NEVER disturb custom settings: only enable fresh when off and unconfigured
            local ab = require('plugins.autobutcher')
            local configured = ab.isEnabled()
            if not configured then
                local ok, wl = pcall(ab.autobutcher_getWatchList)
                configured = ok and wl and #wl > 0
            end
            if not configured then dfhack.run_command('enable', 'autobutcher') end
            -- embark protection, once per fort: raise-only targets so the animals you
            -- ARRIVED with are never butchered down to the defaults
            if not dfhack.isMapLoaded() then return end
            local KEY = 'magnus-scripts/autobutcher-embark'
            if (dfhack.persistent.getSiteData(KEY) or {}).done then return end
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
         end,
         disable = cmd('disable', 'autobutcher')},
        {key = 'autoclothing', label = 'autoclothing', mode = 'fort',
         enable = cmd('enable', 'autoclothing'), disable = cmd('disable', 'autoclothing')},
        {key = 'autonestbox', label = 'autonestbox', mode = 'fort',
         enable = cmd('enable', 'autonestbox'), disable = cmd('disable', 'autonestbox')},
        -- auto-grow: burrows named with a trailing `+` (inside-burrow's `inside+`)
        {key = 'burrow', label = 'burrow (name+ grows)', mode = 'fort',
         enable = cmd('enable', 'burrow'), disable = cmd('disable', 'burrow')},
        {key = 'prioritize', label = 'prioritize', mode = 'fort',
         enable = cmd('enable', 'prioritize'), disable = cmd('disable', 'prioritize')},
        {key = 'seedwatch', label = 'seedwatch', mode = 'fort',
         enable = cmd('enable', 'seedwatch'), disable = cmd('disable', 'seedwatch')},
        {key = 'suspendmanager', label = 'suspendmanager', mode = 'fort',
         enable = cmd('enable', 'suspendmanager'), disable = cmd('disable', 'suspendmanager')},
        {key = 'timestream', label = 'timestream', mode = 'fort',
         enable = cmd('enable', 'timestream'), disable = cmd('disable', 'timestream')},
        {key = 'fast-heat', label = 'tweak fast-heat', mode = 'fort',
         enable = cmd('tweak', 'fast-heat'), disable = cmd('tweak', 'fast-heat', 'disable')},
        {key = 'realistic-melting', label = 'tweak realistic-melting', mode = 'fort',
         enable = cmd('tweak', 'realistic-melting'), disable = cmd('tweak', 'realistic-melting', 'disable')},
        -- vanilla DF standing orders: no automatic weaving or web collection, fish
        -- only in designated zones
        {key = 'standing-orders', label = 'standing-orders (quiet)', mode = 'fort',
         enable = function()
            df.global.standing_orders_auto_loom = 0
            df.global.standing_orders_auto_collect_webs = 0
            df.global.standing_orders_zoneonly_fish = 1
         end,
         disable = function()   -- DF defaults
            df.global.standing_orders_auto_loom = 1
            df.global.standing_orders_auto_collect_webs = 1
            df.global.standing_orders_zoneonly_fish = 0
         end},
        -- hide the stock "N thieving or mischievous creature(s)" line (kea/rhesus noise)
        {key = 'hide-nuisance-alert', label = 'hide nuisance alert', mode = 'fort',
         enable = function()
            notify_cfg(function(data)
                data.warn_nuisance = data.warn_nuisance or {version = 1}
                data.warn_nuisance.enabled = false
            end)
         end,
         disable = function()
            notify_cfg(function(data)
                if data.warn_nuisance then data.warn_nuisance.enabled = true end
            end)
         end},
    }},
}

local function item_mode(col, item) return item.mode or col.mode end

local function mode_active(m)
    if m == 'any' then return dfhack.world.isFortressMode() or dfhack.world.isAdventureMode() end
    if m == 'fort' then return dfhack.world.isFortressMode() end
    if m == 'adv' then return dfhack.world.isAdventureMode() end
    return false
end

-- ---- apply ------------------------------------------------------------------
-- Bring the game in line with the saved selection, for everything applicable to
-- the current mode. Called on every map load (the onMapLoad.init line) and when
-- the GUI opens; single items re-apply live as they are toggled.
local function apply_item(col, item)
    if not mode_active(item_mode(col, item)) then return end
    if is_on(item.key) then
        try('enable ' .. item.label, item.enable)
    else
        try('disable ' .. item.label, item.disable)
    end
end

local function apply_all()
    if not (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        print('magnus-scripts: no fort or adventurer loaded; nothing applied.')
        return
    end
    print('magnus-scripts: applying saved selection ('
        .. (dfhack.world.isFortressMode() and 'fort' or 'adventure') .. ' mode)...')
    -- make sure freshly-copied overlay widgets are discoverable before enabling them
    try('overlay rescan', function() require('plugins.overlay').rescan() end)
    for _, col in ipairs(COLUMNS) do
        for _, item in ipairs(col.items) do
            apply_item(col, item)
        end
    end
end

-- ---- self-arming: (re)run automatically on every map load --------------------
-- Exactly one `fort/magnus-scripts apply` line in dfhack-config's onMapLoad.init.
-- The strip matches every historical spelling (bare, fort/, with `lovely`) so old
-- installs upgrade cleanly the first time anything here runs.
local INIT_PATH = dfhack.getDFPath() .. '/dfhack-config/init/onMapLoad.init'

local function set_autostart(arm)
    local lines, f = {}, io.open(INIT_PATH, 'r')
    if f then
        for line in f:lines() do
            if not (line:match('^%s*magnus%-scripts') or line:match('^%s*fort/magnus%-scripts')) then
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    if arm then
        lines[#lines + 1] = 'fort/magnus-scripts apply'
    end
    local w = io.open(INIT_PATH, 'w')
    if not w then return false, 'could not write ' .. INIT_PATH end
    w:write(table.concat(lines, '\n'))
    if #lines > 0 then w:write('\n') end
    w:close()
    return true
end

-- ---- GUI --------------------------------------------------------------------
local COL_W = 30            -- interior width of one column
local COL_GAP = 1

MagnusWindow = defclass(MagnusWindow, widgets.Window)
MagnusWindow.ATTRS{
    frame_title = 'magnus-scripts',
    frame = {w = 4 * COL_W + 3 * COL_GAP + 3, h = 40},
    resizable = true,
    resize_min = {w = 70, h = 20},
}

-- do all items of `items` currently sit enabled?
local function all_on(items)
    for _, item in ipairs(items) do
        if not is_on(item.key) then return false end
    end
    return true
end

local function set_items(items, on)
    for _, item in ipairs(items) do set_on(item.key, on) end
end

function MagnusWindow:column_items(which)
    local out = {}
    for _, col in ipairs(COLUMNS) do
        if which == 'all' or which == 'mods' and col.id ~= 'vanilla' or which == col.id then
            for _, item in ipairs(col.items) do out[#out + 1] = {col = col, item = item} end
        end
    end
    return out
end

-- toggle a group: if anything is off, turn everything on; else everything off.
-- Re-apply each touched item live (only those applicable right now do anything).
function MagnusWindow:toggle_group(which)
    local pairs_ = self:column_items(which)
    local turn_on = false
    for _, p in ipairs(pairs_) do
        if not is_on(p.item.key) then turn_on = true break end
    end
    for _, p in ipairs(pairs_) do
        if is_on(p.item.key) ~= turn_on then
            set_on(p.item.key, turn_on)
            apply_item(p.col, p.item)
        end
    end
    self:refresh()
end

function MagnusWindow:toggle_item(col, item)
    set_on(item.key, not is_on(item.key))
    apply_item(col, item)
    self:refresh()
end

function MagnusWindow:init()
    local views = {
        widgets.HotkeyLabel{
            frame = {l = 0, t = 0}, key = 'CUSTOM_R', auto_width = true,
            label = function()
                return ('recommended: everything %s'):format(
                    all_on(self:column_items('all')) and 'OFF' or 'ON')
            end,
            on_activate = function() self:toggle_group('all') end,
        },
        widgets.HotkeyLabel{
            frame = {l = 36, t = 0}, key = 'CUSTOM_M', auto_width = true,
            label = function()
                return ('all new mods %s'):format(
                    all_on(self:column_items('mods')) and 'OFF' or 'ON')
            end,
            on_activate = function() self:toggle_group('mods') end,
        },
        widgets.Label{
            frame = {l = 0, t = 1},
            text = {{text = 'click a row to toggle; changes apply live and on every map load',
                     pen = COLOR_DARKGREY}},
        },
    }
    local keys = {fort = 'CUSTOM_F', adv = 'CUSTOM_A', embark = 'CUSTOM_E', vanilla = 'CUSTOM_V'}
    for i, col in ipairs(COLUMNS) do
        local l = (i - 1) * (COL_W + COL_GAP)
        table.insert(views, widgets.HotkeyLabel{
            frame = {l = l, t = 3, w = COL_W}, key = keys[col.id],
            label = function()
                return ('%s [%s]'):format(col.title,
                    all_on(col.items) and 'all off' or 'all on')
            end,
            text_pen = COLOR_LIGHTCYAN,
            on_activate = function() self:toggle_group(col.id) end,
        })
        table.insert(views, widgets.List{
            view_id = 'list_' .. col.id,
            frame = {l = l, t = 5, b = 0, w = COL_W},
            on_submit = function(_, choice) self:toggle_item(choice.col, choice.item) end,
        })
    end
    self:addviews(views)
    self:refresh()
end

-- Mouse-wheel scrolling for whichever column the pointer is over. This
-- build's widgets.List scrolls only via keyboard on the (invisibly) focused
-- list -- with four lists that reads as "not scrollable at all". Wheel events
-- arrive as CONTEXT_SCROLL_* keys; route them to the hovered list's cursor
-- (the page follows the cursor).
function MagnusWindow:onInput(keys)
    -- on_scrollbar moves the PAGE (page_top); moveCursor only moves the
    -- invisible selection, which reads as "the wheel does nothing" until the
    -- cursor happens to walk off-screen (measured: three wheel-downs, page
    -- unmoved)
    local spec = (keys.CONTEXT_SCROLL_UP and 'up_small')
        or (keys.CONTEXT_SCROLL_DOWN and 'down_small')
        or (keys.CONTEXT_SCROLL_PAGEUP and 'up_large')
        or (keys.CONTEXT_SCROLL_PAGEDOWN and 'down_large')
    if spec then
        for _, col in ipairs(COLUMNS) do
            local list = self.subviews['list_' .. col.id]
            if list:getMousePos() then
                list:on_scrollbar(spec)
                return true
            end
        end
    end
    return MagnusWindow.super.onInput(self, keys)
end

function MagnusWindow:refresh()
    for _, col in ipairs(COLUMNS) do
        local list = self.subviews['list_' .. col.id]
        local choices = {}
        for _, item in ipairs(col.items) do
            local on = is_on(item.key)
            table.insert(choices, {
                text = {
                    {text = on and '[x] ' or '[ ] ', pen = on and COLOR_LIGHTGREEN or COLOR_DARKGREY},
                    {text = item.label, pen = on and COLOR_WHITE or COLOR_GREY},
                },
                col = col, item = item,
            })
        end
        local sel = list:getSelected()
        list:setChoices(choices, sel)
    end
end

MagnusScreen = defclass(MagnusScreen, gui.ZScreen)
MagnusScreen.ATTRS{focus_path = 'magnus-scripts'}

function MagnusScreen:init()
    self:addviews{MagnusWindow{}}
end

function MagnusScreen:onDismiss()
    view = nil
end

-- ---- entry point ------------------------------------------------------------
local arg = ({...})[1]

if arg == 'disable' then
    print('magnus-scripts: disabling all managed helpers...')
    for _, col in ipairs(COLUMNS) do
        for _, item in ipairs(col.items) do
            if mode_active(item_mode(col, item)) then
                try('disable ' .. item.label, item.disable)
            end
        end
    end
    try('remove auto-run on load', function() assert(set_autostart(false)) end)
    print('Done. Helpers off and auto-run removed; your saved selection is kept.')
    print('Run `fort/magnus-scripts` to bring it all back.')
    return
end

-- `apply` = headless (the onMapLoad line); `lovely` is the legacy spelling of a
-- full enable -- treat it as apply so old init lines keep working (and get
-- rewritten to the new form below)
apply_all()
try('arm auto-run on load', function() assert(set_autostart(true)) end)

if arg ~= 'apply' and arg ~= 'lovely' then
    view = view and view:raise() or MagnusScreen{}:show()
end
