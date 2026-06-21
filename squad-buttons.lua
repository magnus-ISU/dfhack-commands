-- Overlay buttons for the Squads screens.
--@module = true
--[[
While giving a squad a kill order, adds two buttons that fill the kill-target
list (using DF's own targeting flow, so the squads actually engage -- confirm the
order as normal afterwards):

    * Target all invaders  -- goblin sieges / ambushers (isInvader)
    * Target all hostiles  -- other dangers like forgotten beasts & megabeasts

Caged/chained prisoners and hidden units are skipped.

Registered automatically as overlay widget `squad-buttons.killtargets`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local function in_kill_mode()
    return df.global.game.main_interface.squads.giving_kill_order
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
    desc = 'Buttons to target all invaders / hostiles when giving a squad a kill order.',
    default_pos = {x = -31, y = -3},   -- bottom-right (negative = from right/bottom edge)
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 30, h = 2},
    version = 3,
}

function KillTargetsOverlay:init()
    self:addviews{
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
    }
end

function KillTargetsOverlay:add_targets(get_ids)
    local kill_unid = df.global.game.main_interface.squads.kill_unid
    local present = {}
    for i = 0, #kill_unid - 1 do present[kill_unid[i]] = true end
    for _, id in ipairs(get_ids()) do
        if not present[id] then
            kill_unid:insert('#', id)
            present[id] = true
        end
    end
end

function KillTargetsOverlay:overlay_onupdate()
    self.visible = in_kill_mode()
end

OVERLAY_WIDGETS = {killtargets = KillTargetsOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('squad-buttons: registered overlay squad-buttons.killtargets')
