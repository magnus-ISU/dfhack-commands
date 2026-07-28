# Working in this repo — quickstart

This repo holds two kinds of deliverables for **Dwarf Fortress 0.53.x + DFHack**:

- **`dfhack/`** — standalone DFHack command scripts (`.lua`), one tool per file. Deployed
  into DFHack's script path and invoked as commands. (`adv/` and `fix/` hold a few
  category-specific command scripts too.)
- **`content-mods/high-adventure/`** — the *High Adventure* mod suite (raws + per-mod
  active scripts + graphics). Each mod is a folder with `info.txt`, `objects/`,
  `graphics/`, `scripts_modactive/`.

## Paths (this machine)

| What | Path |
|---|---|
| DF install (`$DF`) | `~/.local/share/Steam/steamapps/common/Dwarf Fortress` |
| DFHack install (`$DFH`) — **separate folder!** | `~/.local/share/Steam/steamapps/common/DFHack` |
| Worldgen mod source (seeds NEW worlds) | `$DF/mods/<mod-id>` |
| Per-world baked mod snapshots (active save) | `$DF/installed_mods/<mod-id>` |
| DFHack command-script deploy target | `$DF/dfhack-config/scripts` |
| Stock DFHack scripts (read-only reference) | `$DFH/hack/scripts` |

```sh
DF="$HOME/.local/share/Steam/steamapps/common/Dwarf Fortress"
DFH="$HOME/.local/share/Steam/steamapps/common/DFHack"
```

## Connect to the running game

DFHack exposes an RPC on **`localhost:5000`** while DF runs. Talk to it with `dfhack-run`:

```sh
"$DFH/dfhack-run" lua 'print(dfhack.getDFVersion())'   # run arbitrary lua
"$DFH/dfhack-run" <command> [args...]                  # run any DFHack command
```

- **The Bash tool sandbox blocks localhost** — pass `dangerouslyDisableSandbox: true` on
  any Bash call that uses `dfhack-run`.
- **RPC lua runs on DF's main thread and freezes it while it runs.** NEVER iterate
  `world.units.all` (~thousands) or scan `map_blocks`/tiles — a big loop hangs the game
  for a minute and risks the save. Bound every scan hard: `units.active` (hundreds), one
  squad/building, `items.other[TYPE]`. If a call hangs, stop firing more. Prefer pure file
  edits over live pokes when you can.
- Check DF is up first: `ss -ltn | grep 5000` (listening = running).

## Check mod versions

Worldgen reads from `$DF/mods/`. Each mod's version is in its `info.txt`:

```sh
grep DISPLAYED_VERSION "$DF/mods/ha-illithids/info.txt"
# list every deployed HA mod + version:
for d in "$DF/mods/"ha-*; do echo "$(basename "$d"): $(grep -h DISPLAYED_VERSION "$d/info.txt")"; done
```

An **active save** bakes raws in at gen time (in the save's own `raw/`), so raw changes
never reach an existing world — only its scripts and (via `installed_mods/`) graphics do.

## Deploy a content mod

Source of truth is `content-mods/high-adventure/<mod>/`. To ship a change:

1. **Bump the version** in `content-mods/.../<mod>/info.txt` (both lines) and add a
   `CHANGES.md` entry:
   ```
   [NUMERIC_VERSION:42]
   [DISPLAYED_VERSION:0.42]
   ```
2. **Copy atomically** into `$DF/mods/` (never edit in place mid-run):
   ```sh
   SRC="content-mods/high-adventure/ha-illithids"; DST="$DF/mods/ha-illithids"
   cp -a "$SRC" "$DST.tmp.$$" && rm -rf "$DST" && mv "$DST.tmp.$$" "$DST"
   ```
3. **Verify the deploy & purge stale copies** — DF must see exactly ONE folder per mod ID,
   at the new version, with your change present:
   ```sh
   grep -h "VERSION" "$DST/info.txt"                         # new version landed
   find "$DF/mods" "$DF/installed_mods" -name info.txt \
     | xargs grep -l "ID:HA_illithids" 2>/dev/null           # should be a single mods/ hit
   ```
   If an older duplicate exists under `mods/`, `rm -rf` it — DF may otherwise load the
   stale one.

**Raws (`objects/`) take effect only in a newly generated world.** Regenerate to test civ
spawning, creature/caste/reaction changes, etc. A mod's `scripts_modactive/` scripts *do*
reload for the active world (on save reload); graphics come from the `installed_mods/`
snapshot.

## Deploy a DFHack command script

Standalone commands live in `dfhack/` (and `adv/`, `fix/`). Deploy by copying into DFHack's
script path, then hot-reload — no game restart:

```sh
cp dfhack/auto-name.lua "$DF/dfhack-config/scripts/"
"$DFH/dfhack-run" lua 'reqscript("auto-name")'   # reload a reqscript module
# for overlay-based tools, rescan overlays:
"$DFH/dfhack-run" overlay trigger   # or: dfhack-run lua "require('plugins.overlay').reload()"
```

Deploy the whole set at once:
```sh
cp dfhack/*.lua "$DF/dfhack-config/scripts/"
```

## Run a DFHack command

```sh
"$DFH/dfhack-run" <name> [args]      # e.g. dfhack-run caravan unload
"$DFH/dfhack-run" lua '<code>'       # ad-hoc lua
```
`dfhack.findScript('name')` inside lua returns a script's real on-disk path (stock scripts
resolve to `$DFH/hack/scripts`).

## Gotchas worth remembering

- **New raws → new world.** No way to inject a new creature/syndrome into an existing save.
- **Unit spawning from scratch is unreliable** on this build; resurrect existing units
  (`full-heal -r`) instead of `units.create`.
- **Caste changes** must go through the dummy-transform-revert pattern (see
  `ha-illithids` `set_caste` / `HA_ILLITHID_TF`): set the identity caches, then a one-tick
  `CE_BODY_TRANSFORMATION` into a dummy so DF rebuilds the body/appearance. Setting
  `unit.caste` directly on a caste with different body parts crashes the description view.
- **Never recurse a viewscreen** from a script — it crashes DF.
