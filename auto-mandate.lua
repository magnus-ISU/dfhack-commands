-- Auto-queue manager work orders to satisfy nobles' production (Make) mandates.
--@module = true
--@enable = true
--[[
Queues a manager work order for each unfulfilled "Make" mandate, choosing the
cheapest / most renewable material the item can be made from:

    * craft / jewelry items (amulet, ring, ...) -> wood
    * furniture & wooden goods                  -> wood
    * metal gear (weapons, armor, ...)          -> copper
    * stone-only goods (mechanisms, statues)    -> any (stone)

If a mandate demands a specific material, that material is used instead.

Usage:
    auto-mandate                 queue orders for current mandates, once
    enable auto-mandate          run in the background, re-checking periodically
    disable auto-mandate         stop the background service

Safe to run repeatedly: it never double-queues a mandate that already has a
matching order. The enabled state persists with the fort.
]]

local repeatUtil = require('repeat-util')
local GLOBAL_KEY = 'auto-mandate'
local CYCLE_DAYS = 1

-- item_type token -> { job token, material policy, kind }
--   kind 'craft' : set order.item_type (MakeCrafts targets a specific craft)
--   kind 'sub'   : set order.item_subtype (forge jobs pick the specific gear)
--   kind 'fixed' : the job implies the item; set neither
local W, C, A = 'wood', 'copper', 'any'
local RAW = {
    -- jewelry/craft goods: use the SPECIFIC make-job (NOT generic "make crafts",
    -- which makes a random item and would not satisfy the mandate)
    {'AMULET', 'MakeAmulet', W, 'fixed'}, {'RING', 'MakeRing', W, 'fixed'},
    {'BRACELET', 'MakeBracelet', W, 'fixed'}, {'EARRING', 'MakeEarring', W, 'fixed'},
    {'CROWN', 'MakeCrown', W, 'fixed'}, {'SCEPTER', 'MakeScepter', W, 'fixed'},
    {'FIGURINE', 'MakeFigurine', W, 'fixed'},
    {'TOY', 'MakeToy', W, 'fixed'}, {'GOBLET', 'MakeGoblet', W, 'fixed'},
    {'FLASK', 'MakeFlask', W, 'fixed'}, {'CAGE', 'MakeCage', W, 'fixed'},
    {'BARREL', 'MakeBarrel', W, 'fixed'}, {'BUCKET', 'MakeBucket', W, 'fixed'},
    {'ANIMALTRAP', 'MakeAnimalTrap', W, 'fixed'}, {'TOTEM', 'MakeTotem', A, 'fixed'},
    {'DOOR', 'ConstructDoor', W, 'fixed'}, {'FLOODGATE', 'ConstructFloodgate', W, 'fixed'},
    {'BED', 'ConstructBed', W, 'fixed'}, {'CHAIR', 'ConstructThrone', W, 'fixed'},
    {'COFFIN', 'ConstructCoffin', W, 'fixed'}, {'TABLE', 'ConstructTable', W, 'fixed'},
    {'BOX', 'ConstructChest', W, 'fixed'}, {'CABINET', 'ConstructCabinet', W, 'fixed'},
    {'ARMORSTAND', 'ConstructArmorStand', W, 'fixed'}, {'WEAPONRACK', 'ConstructWeaponRack', W, 'fixed'},
    {'BIN', 'ConstructBin', W, 'fixed'}, {'HATCH_COVER', 'ConstructHatchCover', W, 'fixed'},
    {'BLOCKS', 'ConstructBlocks', W, 'fixed'},
    {'WEAPON', 'MakeWeapon', C, 'sub'}, {'ARMOR', 'MakeArmor', C, 'sub'},
    {'HELM', 'MakeHelm', C, 'sub'}, {'PANTS', 'MakePants', C, 'sub'},
    {'GLOVES', 'MakeGloves', C, 'sub'}, {'SHOES', 'MakeShoes', C, 'sub'},
    {'TRAPCOMP', 'MakeTrapComponent', C, 'sub'}, {'CHAIN', 'MakeChain', C, 'fixed'},
    {'SHIELD', 'MakeShield', W, 'sub'}, {'AMMO', 'MakeAmmo', W, 'sub'},
    {'STATUE', 'ConstructStatue', A, 'fixed'}, {'TRAPPARTS', 'ConstructMechanisms', A, 'fixed'},
}

local MAP = {}
for _, e in ipairs(RAW) do
    local it = df.item_type[e[1]]
    local job = df.job_type[e[2]]
    if it and job then MAP[it] = {job = job, mat = e[3], kind = e[4]} end
end

local function order_target(m, map)
    local it, sub = -1, -1
    if map.kind == 'craft' then it = m.item_type
    elseif map.kind == 'sub' then sub = m.item_subtype end
    return it, sub
end

-- ---- material availability (cheap, via per-type item lists) ----------------

local function wood_logs()
    return #df.global.world.items.other.WOOD
end

local function bars_of(mat_type, mat_index)
    local bars = df.global.world.items.other.BAR
    for i = 0, #bars - 1 do
        local it = bars[i]
        if it.mat_type == mat_type and it.mat_index == mat_index then return true end
    end
    return false
end

local function any_metal_bar()
    local bars = df.global.world.items.other.BAR
    if #bars > 0 then return bars[0].mat_type, bars[0].mat_index end
end

-- is this material in stock as a craftable input (bar/boulder/log/block)?
local function material_in_stock(mt, mi)
    for _, name in ipairs({'BAR', 'BOULDER', 'WOOD', 'BLOCKS'}) do
        local list = df.global.world.items.other[name]
        for i = 0, #list - 1 do
            local it = list[i]
            if it.mat_type == mt and it.mat_index == mi then return true end
        end
    end
    return false
end

-- can this order actually be worked right now (input material on hand)?
local function order_fulfillable(o)
    if o.material_category.wood then return wood_logs() > 0 end
    if o.mat_type and o.mat_type >= 0 then return material_in_stock(o.mat_type, o.mat_index) end
    return true   -- no material constraint: made from whatever is available
end

-- a matching order that can actually be fulfilled right now
local function has_fulfillable_order(job, it, sub)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job and o.item_type == it and o.item_subtype == sub
            and order_fulfillable(o)
        then
            return true
        end
    end
    return false
end

-- pick a material the order can actually be made from. Returns a description, or
-- nil if it cannot be fulfilled at all (so the caller skips it).
local function choose_material(o, policy, m)
    -- a mandate that demands a specific material: honour it (no substitution)
    if m.mat_type and m.mat_type >= 0 then
        o.mat_type = m.mat_type
        o.mat_index = m.mat_index
        local mi = dfhack.matinfo.decode(m.mat_type, m.mat_index)
        return mi and mi:toString() or 'specified material'
    end
    if policy == W then
        if wood_logs() > 0 then
            o.material_category.wood = true
            return 'wood'
        end
        return 'any material'   -- no wood: leave unconstrained (stone/bone/...)
    elseif policy == C then
        local cu = dfhack.matinfo.find('COPPER')
        if cu and bars_of(cu.type, cu.index) then
            o.mat_type, o.mat_index = cu.type, cu.index
            return 'copper'
        end
        local mt, mi = any_metal_bar()        -- fall back to any metal in stock
        if mt then
            o.mat_type, o.mat_index = mt, mi
            local info = dfhack.matinfo.decode(mt, mi)
            return info and info:toString() or 'metal'
        end
        return nil   -- no metal at all: cannot fulfil
    end
    return 'any material'   -- A: unconstrained (uses any available stone/etc.)
end

local function item_label(m)
    local tok = df.item_type[m.item_type]
    return tok and tok:lower():gsub('_', ' ') or 'goods'
end

-- exposed for other tools (e.g. the mandate notification): is there already a
-- manager order that would fulfil this Make mandate?
function has_order_for(m)
    if m.mode ~= df.mandate_type.Make then return false end
    local map = MAP[m.item_type]
    if not map then return false end
    local it, sub = order_target(m, map)
    return has_fulfillable_order(map.job, it, sub)
end

-- scan all Make mandates and queue orders; returns lists of {queued, existing, skipped}
local function scan_and_queue()
    local mandates = df.global.world.mandates.all
    local queued, skipped, existing = {}, {}, {}
    for i = 0, #mandates - 1 do
        local m = mandates[i]
        if m.mode == df.mandate_type.Make and m.amount_remaining > 0 then
            local map = MAP[m.item_type]
            local label = item_label(m)
            if not map then
                table.insert(skipped, label)
            else
                local it, sub = order_target(m, map)
                if has_fulfillable_order(map.job, it, sub) then
                    table.insert(existing, label)
                else
                    local o = df.manager_order:new()
                    o.job_type = map.job
                    o.item_type = it
                    o.item_subtype = sub
                    o.amount_total = m.amount_remaining
                    o.amount_left = m.amount_remaining
                    o.frequency = 0
                    o.status.validated = true
                    o.status.active = true
                    local matdesc = choose_material(o, map.mat, m)
                    if matdesc then
                        local mo = df.global.world.manager_orders
                        o.id = mo.manager_order_next_id
                        mo.manager_order_next_id = o.id + 1
                        mo.all:insert('#', o)
                        table.insert(queued, ('%d %s (%s)'):format(m.amount_remaining, label, matdesc))
                    else
                        o:delete()
                        table.insert(skipped, label .. ' (no material available)')
                    end
                end
            end
        end
    end
    return queued, existing, skipped
end

-- ---- enable / background service machinery --------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

-- a background cycle: queue silently, but report anything newly queued
local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    local queued = scan_and_queue()
    if #queued > 0 then
        print(('auto-mandate: queued %d order%s for new mandates:'):format(
            #queued, #queued == 1 and '' or 's'))
        for _, s in ipairs(queued) do print('  + ' .. s) end
    end
end

local function persist()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled = enabled})
end

local function start()
    enabled = true
    repeatUtil.scheduleEvery(GLOBAL_KEY, CYCLE_DAYS, 'days', do_cycle)
    do_cycle()   -- act immediately on enable
end

local function stop()
    enabled = false
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode()
            and dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled
        then
            start()
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('auto-mandate can only be enabled in fortress mode')
    end
    if dfhack_flags.enable_state then start() else stop() end
    persist()
    print('auto-mandate: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot: queue now and print a full summary
    if not dfhack.world.isFortressMode() then
        qerror('auto-mandate only works in fortress mode')
    end
    local queued, existing, skipped = scan_and_queue()
    if #queued == 0 and #existing == 0 and #skipped == 0 then
        print('auto-mandate: no production mandates to fill.')
    else
        if #queued > 0 then
            print(('auto-mandate: queued %d work order%s:'):format(#queued, #queued == 1 and '' or 's'))
            for _, s in ipairs(queued) do print('  + ' .. s) end
        end
        if #existing > 0 then
            print(('  (%d mandate%s already had a matching order)'):format(
                #existing, #existing == 1 and '' or 's'))
        end
        if #skipped > 0 then
            print('  skipped (no known recipe): ' .. table.concat(skipped, ', '))
        end
    end
end
