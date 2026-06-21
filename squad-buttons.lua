-- Overlay buttons for the Squads screen.
--@module = true
--[[
On the Squads screen (focus dwarfmode/Squads/Default) this adds:

    * Select all/no squads  -- toggles selection of every squad (always shown)

and, while giving a squad a kill order, two more buttons that fill the
kill-target list using DF's own targeting flow (confirm the order as normal):

    * Target all invaders   -- goblin sieges / ambushers (isInvader)
    * Target all hostiles   -- other dangers like forgotten beasts & megabeasts

Caged/chained prisoners and hidden units are skipped.

Registered automatically as overlay `squad-buttons.killtargets`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local function squads_panel()
    return df.global.game.main_interface.squads
end

local function in_kill_mode()
    return squads_panel().giving_kill_order
end

local function collect(pred)
    local ids = {}
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        if not dfhack.units.isDead(u)
            and not u.flags1.caged and not u.flags1.chained
            and not dfhack.units.isHidden(u)
            and pred(u)
        then
            table.insert(ids, u.id)
        end
    end
    return ids
end

local function invader_targets()
    return collect(function(u) return dfhack.units.isInvader(u) end)
end

-- "hostile" = a danger that is NOT an invader (forgotten beasts, megabeasts,
-- night creatures, etc.) and not one of our own units
local function hostile_targets()
    return collect(function(u)
        return dfhack.units.isDanger(u)
            and not dfhack.units.isInvader(u)
            and not dfhack.units.isFortControlled(u)
    end)
end

KillTargetsOverlay = defclass(KillTargetsOverlay, overlay.OverlayWidget)
KillTargetsOverlay.ATTRS{
    desc = 'Squads screen buttons: select all/no squads, and target all invaders/hostiles.',
    default_pos = {x = -31, y = -3},   -- bottom-right (negative = from right/bottom edge)
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 30, h = 3},
    version = 4,
}

function KillTargetsOverlay:init()
    self:addviews{
        -- kill-target buttons (top two rows; only while giving a kill order)
        widgets.TextButton{
            view_id = 'invaders',
            frame = {t = 0, l = 0, w = 30, h = 1},
            label = 'Target all invaders',
            key = 'CUSTOM_CTRL_A',
            on_activate = function() self:add_targets(invader_targets) end,
        },
        widgets.TextButton{
            view_id = 'hostiles',
            frame = {t = 1, l = 0, w = 30, h = 1},
            label = 'Target all hostiles',
            key = 'CUSTOM_CTRL_H',
            on_activate = function() self:add_targets(hostile_targets) end,
        },
        -- always-present: select all / none squads (bottom row)
        widgets.TextButton{
            view_id = 'selectall',
            frame = {t = 2, l = 0, w = 30, h = 1},
            label = 'Select all/no squads',
            key = 'CUSTOM_CTRL_S',
            on_activate = function() self:toggle_select_all() end,
        },
    }
end

function KillTargetsOverlay:add_targets(get_ids)
    local kill_unid = squads_panel().kill_unid
    local present = {}
    for i = 0, #kill_unid - 1 do present[kill_unid[i]] = true end
    for _, id in ipairs(get_ids()) do
        if not present[id] then
            kill_unid:insert('#', id)
            present[id] = true
        end
    end
end

-- if not every squad is selected, select them all; otherwise clear the selection
function KillTargetsOverlay:toggle_select_all()
    local sq = squads_panel()
    local n = #sq.squad_id
    local selected = 0
    for i = 0, n - 1 do if sq.squad_selected[i] then selected = selected + 1 end end
    local want = selected < n
    for i = 0, n - 1 do sq.squad_selected[i] = want end
end

function KillTargetsOverlay:overlay_onupdate()
    local kill = in_kill_mode()
    self.subviews.invaders.visible = kill
    self.subviews.hostiles.visible = kill
    self.visible = squads_panel().open
end

OVERLAY_WIDGETS = {killtargets = KillTargetsOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('squad-buttons: registered overlay squad-buttons.killtargets')
