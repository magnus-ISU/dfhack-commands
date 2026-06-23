-- dwarf-rts -- TEMPORARILY DISABLED while diagnosing the squad-screen pause trap.
--@module = true
--[[
Intentionally a no-op: registers no overlay (no OVERLAY_WIDGETS) and starts no
poll, so it has zero effect on the squad screen. This is here to confirm that
reverting dwarf-rts is hot-reloadable and to isolate whether the pause-trap is
caused by dwarf-rts at all. The full RTS implementation is in git history.
]]

-- bump the poll generation so any previously-running poll exits immediately
dfhack.internal.dwarf_rts_gen = (dfhack.internal.dwarf_rts_gen or 0) + 1

if dfhack_flags.module then return end

print('dwarf-rts: DISABLED (no overlay, no poll) -- squad screen is back to vanilla')
