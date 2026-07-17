-- Assign each noble's symbols of office as specific items in their squad uniform.
--[[
noble-warriors

For every fort noble position that has SYMBOLS OF OFFICE assigned (items picked on the
Nobles screen's symbol picker -- see noble-symbol-search) AND whose holder serves in a
squad, this adds each wearable/wieldable symbol item to that noble's squad-position
uniform as a SPECIFIC-item assignment (the native "specific item" uniform mode), so the
noble actually wears their regalia into battle.

Rules:
  * idempotent -- a symbol already assigned in the uniform is left alone
  * RECLAIMS the noble's rightful items: any OTHER squad position that has one of the
    symbols assigned (as a hand-picked specific item, or picked up by DF's uniform
    solver against a filter) gets it unassigned, and that slot is dirtied so the other
    soldier re-solves a replacement
  * skipped: vacant positions, dead holders, holders not in a squad, and symbol items
    that don't fit a uniform slot (figurines, scepters, ...)
  * NEVER runs automatically -- one-shot command only, not wired into magnus-scripts

Usage:
    noble-warriors dry     preview what would change, touch nothing
    noble-warriors         apply

Data model: symbols live on the fort entity as `artifact_claims` with
claim_type=Symbol, keyed by `symbol_claim_id` == the position ASSIGNMENT id;
artifact_id -> artifact_record.item. A specific-item uniform spec is
squad_uniform_spec{item=<id>} with every filter field -1.
]]

-- item type -> uniform slot index (squad_position.equipment.uniform)
local SLOT = {
    [df.item_type.ARMOR]  = 0,
    [df.item_type.HELM]   = 1,
    [df.item_type.PANTS]  = 2,
    [df.item_type.GLOVES] = 3,
    [df.item_type.SHOES]  = 4,
    [df.item_type.SHIELD] = 5,
    [df.item_type.WEAPON] = 6,
}
-- slot -> plotinfo.equipment.update dirty field, so DF re-solves and picks the items up
local UPDATE_FIELD = {[0] = 'armor', [1] = 'helm', [2] = 'pants', [3] = 'gloves',
                      [4] = 'shoes', [5] = 'shield', [6] = 'weapon'}

if not dfhack.world.isFortressMode() then qerror('noble-warriors needs a loaded fortress') end

local utils = require('utils')

local dry = ({...})[1] == 'dry'

-- strip every reference to item id from OTHER squad positions (the noble's rightful
-- gear may be assigned to some other warrior -- hand-picked or via DF's solver).
-- Returns a list of 'name (squad)' strings for reporting.
local function reclaim_elsewhere(item_id, own_pos, apply)
    local fort = df.global.plotinfo.group_id
    local freed = {}
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for pi = 0, #sq.positions - 1 do
                local pos = sq.positions[pi]
                if pos ~= own_pos and pos.occupant >= 0 then
                    local touched = false
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = #v - 1, 0, -1 do
                            local sp = v[j]
                            if sp.item == item_id then
                                -- someone else's hand-picked specific assignment: remove the spec
                                touched = true
                                if apply then
                                    for k = #sp.assigned - 1, 0, -1 do
                                        utils.erase_sorted(pos.equipment.assigned_items, sp.assigned[k])
                                        sp.assigned:erase(k)
                                    end
                                    v:erase(j)
                                end
                            else
                                -- solver-assigned against a filter spec: release just the item
                                for k = #sp.assigned - 1, 0, -1 do
                                    if sp.assigned[k] == item_id then
                                        touched = true
                                        if apply then
                                            sp.assigned:erase(k)
                                            utils.erase_sorted(pos.equipment.assigned_items, item_id)
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if touched then
                        local hf = df.historical_figure.find(pos.occupant)
                        freed[#freed + 1] = ('%s (%s)'):format(
                            hf and dfhack.translation.translateName(hf.name) or '?',
                            dfhack.translation.translateName(sq.name))
                    end
                end
            end
        end
    end
    return freed
end

local ent
for _, e in ipairs(df.global.world.entities.all) do
    if e.id == df.global.plotinfo.group_id then ent = e break end
end
if not ent then qerror('fort entity not found') end

-- symbol claims grouped by position-assignment id
local symbols_by_asn = {}
for i = 0, #ent.artifact_claims - 1 do
    local c = ent.artifact_claims[i]
    if c.claim_type == df.artifact_claim_type.Symbol and c.symbol_claim_id >= 0 then
        symbols_by_asn[c.symbol_claim_id] = symbols_by_asn[c.symbol_claim_id] or {}
        table.insert(symbols_by_asn[c.symbol_claim_id], c.artifact_id)
    end
end

local changed_total = 0
for asn_id, artifact_ids in pairs(symbols_by_asn) do
    -- resolve the assignment -> position name + holder
    local asn, pos_name
    for j = 0, #ent.positions.assignments - 1 do
        if ent.positions.assignments[j].id == asn_id then asn = ent.positions.assignments[j] end
    end
    if asn then
        for _, p in ipairs(ent.positions.own) do
            if p.id == asn.position_id then pos_name = tostring(p.name[0]) end
        end
    end
    local hf = asn and asn.histfig >= 0 and df.historical_figure.find(asn.histfig)
    local u = hf and hf.died_year < 0 and hf.unit_id >= 0 and df.unit.find(hf.unit_id)
    local squad = u and u.military.squad_id >= 0 and df.squad.find(u.military.squad_id)
    local label = ('%s (%s)'):format(hf and dfhack.translation.translateName(hf.name) or '(vacant)',
        pos_name or ('assignment ' .. asn_id))

    if not hf then
        print(('noble-warriors: %s -- skipped (no holder)'):format(label))
    elseif not u then
        print(('noble-warriors: %s -- skipped (holder dead or not present)'):format(label))
    elseif not squad then
        print(('noble-warriors: %s -- skipped (not in a squad)'):format(label))
    else
        -- the holder's squad position
        local spos
        for pi = 0, #squad.positions - 1 do
            if squad.positions[pi].occupant == hf.id then spos = squad.positions[pi] end
        end
        if not spos then
            print(('noble-warriors: %s -- skipped (no squad position?)'):format(label))
        else
            local added, already, unwearable = 0, 0, 0
            for _, aid in ipairs(artifact_ids) do
                local ar = df.artifact_record.find(aid)
                local it = ar and ar.item
                local slot = it and SLOT[it:getType()]
                if not it then
                    unwearable = unwearable + 1
                elseif not slot then
                    unwearable = unwearable + 1
                    print(('  ~ %s: no uniform slot for %s -- skipped'):format(label,
                        dfhack.items.getDescription(it, 0, true)))
                else
                    -- reclaim the item from any OTHER warrior currently assigned it
                    local freed = reclaim_elsewhere(it.id, spos, not dry)
                    for _, who in ipairs(freed) do
                        print(('  < reclaimed %s from %s'):format(
                            dfhack.items.getDescription(it, 0, true), who))
                        local f = UPDATE_FIELD[slot]
                        if f and not dry then df.global.plotinfo.equipment.update[f] = true end
                    end
                    local have = false
                    for j = 0, #spos.equipment.uniform[slot] - 1 do
                        if spos.equipment.uniform[slot][j].item == it.id then have = true end
                    end
                    if have then
                        already = already + 1
                    else
                        added = added + 1
                        if not dry then
                            spos.equipment.uniform[slot]:insert('#', {
                                new = df.squad_uniform_spec,
                                item = it.id,
                                item_type = -1, item_subtype = -1,
                                material_class = -1, mattype = -1, matindex = -1,
                                color = -1,
                            })
                            local f = UPDATE_FIELD[slot]
                            if f then df.global.plotinfo.equipment.update[f] = true end
                        end
                        print(('  + %s -> %s uniform'):format(
                            dfhack.items.getDescription(it, 0, true),
                            dfhack.translation.translateName(squad.name)))
                    end
                end
            end
            changed_total = changed_total + added
            print(('noble-warriors: %s -- %d symbol%s %s, %d already assigned, %d not wearable'):format(
                label, added, added == 1 and '' or 's',
                dry and 'would be added' or 'added', already, unwearable))
        end
    end
end

if changed_total == 0 then
    print('noble-warriors: nothing to change.')
elseif dry then
    print(('noble-warriors: DRY RUN -- %d assignment%s would be made. Run `noble-warriors` to apply.')
        :format(changed_total, changed_total == 1 and '' or 's'))
else
    print(('noble-warriors: %d symbol%s assigned to squad uniforms.'):format(
        changed_total, changed_total == 1 and '' or 's'))
end
