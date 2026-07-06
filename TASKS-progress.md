# Work batch progress (scratch — delete when done)

Started 2026-06-30. Tracking the multi-part request. Status keys: ⬜ todo · 🟡 in progress · ✅ done · ❓ needs decision

## 1. ✅ Missing-workshop detector counts magma versions
Bug: "auto jobs for missing tasks" thinks there's no smith / furnace / glass furnace when
only the **magma** variants exist. Need to treat magma forge/smelter/glass-furnace/kiln as
satisfying the same requirement.
- Script: TBD (grep smith/furnace/glass). Likely planner-orders / labor-groups / a notification.

## 2. ✅ Drag-to-dig: right-click-drag erase shows preview + eraser icon
Script: right-click-cancel.lua. FIXED the scaling bug: now draws on the MAP grid via
`paintTile(pen, x, y, nil, nil, true)` with a real graphics tile CURSORS(3,0) (the red
"destroy" art DFHack's mass-remove uses) + keep_lower — same technique dwarf-rts uses for its
selection box. Deployed + reloaded. NEEDS IN-GAME VISUAL CHECK.

## 3. ❌ DELETED (not reliably possible) — 1x1xN column → staircase
Removed per user OK-to-delete. Two desires can't both be met: (A) extend the stairwell into
the capping OPEN-SPACE tile (Mine can't designate it, a stair can) AND (B) NOT convert a
dig designation directly below that's contiguous in the same z-stack but not part of the
selection. DF designations are per-z with no multi-z "selection", and (B)'s tile is the same
type & contiguous with the shaft, so no heuristic can include (A) while excluding (B).
Code deleted from right-click-cancel.lua (kept only the tiny `dig_val` helper #4 uses).

## 4. ✅ Right-click on a just-added tile forwards instead of cancelling
right-click-cancel.lua. On left-up we record `last_add={pos,ms}` when a dig designation or an
under-construction building now exists at the release tile. A right-CLICK on that same tile
within 2s (real-time, so it works while paused) forwards `_MOUSE_R` (exits the tool) instead of
running cancel_at; consumed on use so a later right-click cancels normally. NEEDS IN-GAME TEST.

## 5. ✅ Right-click mid-placement backs out only that instance; left cancels erase-drag
right-click-cancel.lua.
- 5a: DF exposes no "corner pending" flag (only stale mouse_anchor_*), so the overlay
  self-tracks it: in rectangle mode a plain click toggles corner1(pending)<->corner2(done), a
  drag completes (no pending), any non-rectangle context clears it. A right-click while a
  corner is pending FORWARDS `_MOUSE_R` (game backs out that placement) instead of cancel_at.
  Heuristic — needs in-game test; worst case desync just makes one right-click behave like the
  old way and self-corrects next click.
- 5b: onInput swallows a LEFT press while a right-drag erase is active; the poller nils
  self.rpress so the erase is aborted and the left press doesn't designate.
NEEDS IN-GAME TEST.

## 6. ✅ auto-pasture warnings (graze made twice-again generous: now ~1 animal per grass tile)
- Remove the **Scavenge** pasture space warning entirely.
- Make the **Graze** warning twice as generous (fire at half the grass-tile density).
Script: auto-pasture.lua.

## 7. ✅ auto-name: more names for thin letters + roll-over fallback
- Add authentic names for thin letters (Q/U/V/W/X/Y/Z, esp. female) in auto-name-names.txt.
- Change fallback: when a letter's pool is exhausted, roll forward to the NEXT letter
  (Q→R→S…), not back to A / not random.
Scripts: auto-name.lua + auto-name-names.txt.

## 8. ✅ magnus-scripts should re-arm itself on next launch
`magnus-scripts` (and `magnus-scripts lovely`) currently don't auto-run on reload. Make the
command enqueue itself to run automatically next launch (persist which variant), until
`magnus-scripts disable` is run. Script: magnus-scripts.lua (+ dfhack.init or persistence).

## 9. 🟡 NEW script: auto-expand build (b) menu — BLOCKED: need the menu OPEN to introspect the toolbar (interface_category_building enum is material-select sub-cats, not the top-level Workshops/Furniture/... toolbar; that model is not readable while the menu is closed)
When the build/Structures menu is opened (click or hotkey `b`), auto-open all categories:
workshops, furniture, doors, constructions, traps, machines, military. New script.

## 10. ✅ NEW script: presets.lua — save/load military uniforms AND stockpile settings (validated: steel uniform round-tripped by subtype-name + INORGANIC:STEEL token; stockpiles delegate to stockpiles plugin)
A script (UI or commands) to save and load military uniform templates and stockpile settings
to named presets. Stockpiles already have DFHack import/export to build on; uniforms need custom.

---
### Status summary (2026-06-30)
DONE + deployed: **1, 2, 6, 7, 8** (2 needs in-game visual confirm).
REMAINING: **3, 4, 5, 9, 10.**
- 3/4/5 all live in right-click-cancel.lua and are mouse-interaction features — they need
  in-game click/drag testing to verify (can't be done headless).
- 5 needs the box-select ANCHOR state (first-corner-placed); not found in
  `main_interface.designation` (only mine_mode/marker_only/priority there). Must locate where
  DF stores the pending first corner before implementing 5 correctly.
- 9, 10 are net-new scripts.

### Notes / decisions
- T3 mechanism assumption: "1x1xN vertical column" = the same x,y dug on N stacked z-levels;
  convert that isolated 1-wide vertical run to up/down stairs (top=down, mid=up/down, bottom=up)
  so it's actually traversable. Trigger only in plain Mine mode (designation.mine_mode).
- T8 writes `magnus-scripts[ lovely]` into dfhack-config/init/onMapLoad.init; disable removes it. ✓ verified line present.
- Magma enum ids (T1): forge 5→6, smelter 1→4, glassfurnace 2→5, kiln 3→6.
