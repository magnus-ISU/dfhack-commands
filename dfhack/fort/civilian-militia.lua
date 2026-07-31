-- Manually arrange the civilian-militia squads (pulled out of military-uniforms).
--[[
civilian-militia

Packs the fort's CIVILIAN squads (the office-holder militia with Civilian-* leather
uniforms) so each Ready squad holds only fully-equipped members, moves movable members
between civilian squads accordingly, and flips squad routines between Off-duty and
Ready. This used to run automatically inside military-uniforms' daily gear cycle, but
proved too brittle unattended -- it kept overriding hand-set squad schedules -- so it
now runs ONLY when you invoke this command. Uniform templates are still created
automatically by military-uniforms; everything else about civilian squads waits for
you.

Guarantees:
  * routines are only ever flipped between Off-duty and Ready -- a squad you put on
    ANY other routine (training, even/odd month, custom) is never touched
  * members with hand-assigned specific uniform items (e.g. noble-warriors' symbols
    of office) are PINNED: never moved between squads, and counted as fully equipped
    without needing free stock
  * needs the military-uniforms gear service ("Queue gear orders") to be on, since
    the arrangement plans against its stock/requirement snapshot

Usage:
    civilian-militia dry     print the plan (squad -> Ready/NoOrders + member counts),
                             change nothing
    civilian-militia         apply the arrangement

NEVER runs automatically -- one-shot command only, not wired into magnus-scripts.
]]

if not dfhack.world.isFortressMode() then
    qerror('civilian-militia needs a loaded fortress')
end

local mu = reqscript('fort/military-uniforms')
local dry = ({...})[1] == 'dry'

mu.civilian_arrange(dry)
print(dry and 'civilian-militia: plan printed -- nothing changed. Run `civilian-militia` to apply.'
          or 'civilian-militia: arrangement applied (Off-duty/Ready flips only; manual routines untouched).')
