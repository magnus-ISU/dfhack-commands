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

`magnus-scripts` is the switch for the whole pack. Run it once per session — or add it to
`dfhack-config/init/dfhack.init` and forget about it — and every always-on helper below is
enabled at once: the notification overlays, the watchdog services, the map and stockpile
tools. Anything destructive or situational is deliberately left out and stays a command you
run by hand.

```sh
magnus-scripts          # enable the always-on helpers for this session
magnus-scripts lovely   # ...plus a batch of stock DFHack tools and a few extras
```

It is safe to re-run at any time: each helper it starts is idempotent, and it disables and
re-enables its own services rather than stacking them.

---
