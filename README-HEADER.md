<!-- GENERATED FILE — do not edit README.md directly.
     Composed by `make readme` from README-HEADER.md, FORTRESS_MODE_FEATURES.md,
     ADVENTURE_MODE_FEATURES.md and HIGH_ADVENTURE_FEATURES.md.
     Edit those instead; anything written here is overwritten on the next build. -->

# dfhack-commands

A personal pack of **DFHack scripts** for the latest Dwarf Fortress (0.53.x / Steam),
plus the **Dwarf Fortress: High Adventure** content-mod suite.

- Scripts live in [`dfhack/`](dfhack/), in folders that mirror the deployed tree —
  `fort/`, `adv/`, `embark/`, `fix/`. The folder is the command prefix: `fort/auto-name`,
  `adv/reveal`. Copy them into `dfhack-config/scripts/` and they become commands.
- Content mods live in [`content-mods/high-adventure/`](content-mods/high-adventure/).
- Things that don't work yet are kept out of this list — see
  [`BROKEN_FEATURES.md`](BROKEN_FEATURES.md).
- **Full command reference, implementation notes and TODOs:**
  [`DEVNOTES.md`](DEVNOTES.md). Repo/workflow quickstart: [`instructions.md`](instructions.md).

## Turning it all on — `magnus-scripts`

`magnus-scripts` is the switchboard for the whole pack. Running it opens a window with four
individually-scrollable columns — `fort/`, `adv/`, `embark/` and vanilla DFHack tools — with
a checkbox per helper. Click a row to toggle it; the selection is saved (to
`dfhack-config/magnus-scripts.json`) and re-applied automatically on every map load. Column
headers toggle a whole column, `m` toggles all the mod columns at once, and `r` is the
recommended master switch: everything on. On a fresh install everything starts enabled.

```sh
fort/magnus-scripts           # apply the saved selection, then open the GUI
fort/magnus-scripts apply     # headless apply (what the auto-run line calls)
fort/magnus-scripts disable   # everything off + remove the auto-run line
```

It is safe to re-run at any time: each helper it starts is idempotent, and it disables and
re-enables its own services rather than stacking them. Anything destructive or situational
(no-pausing, embark-nobles, the one-shot commands) is deliberately left out and stays a
command you run by hand.

---
