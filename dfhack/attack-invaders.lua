-- Order every fort squad to kill all (uncaged) invaders on the map.
--@module = false
--[[
    attack-invaders

Gives every military squad a "kill" order targeting all live, attackable invaders
currently on the map. Caged or chained invaders (e.g. captured prisoners) are
skipped, since squads can't engage them.

Re-running replaces each squad's orders with a fresh kill list, so it is safe to
run again as new invaders arrive.
]]

if not dfhack.world.isFortressMode() then
    qerror('attack-invaders only works in fortress mode')
end

-- gather attackable invader targets
local targets = {}
local units = df.global.world.units.active
for i = 0, #units - 1 do
    local u = units[i]
    if dfhack.units.isInvader(u) and not dfhack.units.isDead(u)
        and not u.flags1.caged and not u.flags1.chained
    then
        table.insert(targets, u)
    end
end

if #targets == 0 then
    print('attack-invaders: no attackable invaders on the map.')
    return
end

-- gather this fort's squads
local fort_group = df.global.plotinfo.group_id
local squads = {}
local all_squads = df.global.world.squads.all
for i = 0, #all_squads - 1 do
    local sq = all_squads[i]
    if sq.entity_id == fort_group then
        table.insert(squads, sq)
    end
end

if #squads == 0 then
    qerror('no squads exist -- create a military squad first')
end

-- build a kill order for each squad (a fresh one per squad: orders are owned)
local manned = 0
for _, sq in ipairs(squads) do
    -- count members
    local members = 0
    for j = 0, #sq.positions - 1 do
        if sq.positions[j].occupant >= 0 then members = members + 1 end
    end
    if members > 0 then manned = manned + 1 end

    -- clear existing orders so re-running doesn't stack duplicates
    for j = #sq.orders - 1, 0, -1 do
        local old = sq.orders[j]
        sq.orders:erase(j)
        old:delete()
    end

    local order = df.squad_order_kill_listst:new()
    order.title = 'Kill the invaders'
    order.year = df.global.cur_year
    order.year_tick = df.global.cur_year_tick
    for _, u in ipairs(targets) do
        order.units:insert('#', u.id)
        local hf = (u.hist_figure_id and u.hist_figure_id >= 0) and u.hist_figure_id or -1
        order.histfigs:insert('#', hf)
    end
    sq.orders:insert('#', order)
end

print(('attack-invaders: ordered %d squad%s (%d manned) to kill %d invader%s.'):format(
    #squads, #squads == 1 and '' or 's', manned, #targets, #targets == 1 and '' or 's'))
