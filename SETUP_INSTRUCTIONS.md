# Setup — the details

The [README](README.md) covers the normal case. This file covers everything else:
non-standard install paths, installing pieces by hand, and the `magnus-scripts` arguments.

## What `make install` actually does

```sh
make install          # scripts, then content mods (+ snapshot prune), then the plugins
make install-scripts  # dfhack/ only; hot-reloads a running DF
make install-mods     # content mods only, then prune superseded snapshots
make install-plugin   # download + checksum-verify the prebuilt plugins, install into DFHack
make mods-status      # repo vs deployed vs snapshot versions; changes nothing
make help             # every target
```

Restart Dwarf Fortress after installing mods. DF scans `mods/` exactly once, at startup, so
a mod deployed into a running game is invisible to worldgen.

`make install-mods` (and therefore `make install`) **deletes per-world mod snapshots older
than the version being deployed**. That is deliberate — it keeps DF's mod picker from
filling with stale duplicates — but it breaks existing saves generated against those old
versions. Use `make install-scripts` alone if you have a world you care about.

## Non-standard paths

The Makefile assumes a Steam install. Override any of these on the command line:

| Variable | Default (Linux) | What it is |
|---|---|---|
| `DF_DIR` | `~/.local/share/Steam/steamapps/common/Dwarf Fortress` | the game folder — contains `dfhack-config/` and `mods/` |
| `B12_DIR` | `~/.local/share/Bay 12 Games/Dwarf Fortress` | DF's *user data*: saves and baked mod snapshots |
| `DFHACK_DIR` | alongside `DF_DIR` | the DFHack install, for plugin installs |

```sh
make install DF_DIR="/games/Dwarf Fortress"
make install-scripts DF_DIR="$HOME/df"
```

On Windows the defaults are `C:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress`,
and `B12_DIR` is the game folder itself — Windows DF keeps saves and snapshots inside the
install rather than in a separate user tree.

Run `make help` to print the values currently in effect.

## Installing by hand

Nothing here needs the Makefile; it is all file copies.

**Scripts.** `dfhack/` mirrors DFHack's script tree, so the folder is the command prefix.
Copy a file into `<DF>/dfhack-config/scripts/`, keeping its folder, and it becomes a command
named after that path:

```sh
cp dfhack/fort/auto-name.lua "<DF>/dfhack-config/scripts/fort/"   # -> fort/auto-name
cp dfhack/adv/reveal.lua     "<DF>/dfhack-config/scripts/adv/"    # -> adv/reveal
cp -r dfhack/.               "<DF>/dfhack-config/scripts/"        # all of them
```

Plain commands are re-read on every invocation. Overlay-based tools need a rescan to pick up
new code — either reload the save, or, with DF running:

```sh
"<DFHack>/dfhack-run" lua 'require("plugins.overlay").rescan()'
```

**Content mods.** Copy a folder out of `content-mods/high-adventure/` into `<DF>/mods/`:

```sh
cp -r content-mods/high-adventure/ha-illithids "<DF>/mods/"
```

`high-adventure` is the all-in-one bundle of every `ha-*` mod — install *either* the bundle
*or* the individual mods you want, not both. Raws only take effect in a **newly generated
world**; an existing save has its raws baked in.

**Plugins.** `make install-plugin` fetches prebuilt binaries for
[smooth-movement](https://github.com/anmej/df-smooth-movement) and `ssaudio` and drops them
into DFHack's plugin folder. To build from source instead, `make build` (clones the DFHack
source tree into `build/` on first run). Never overwrite a plugin binary while DF is
running — it crashes the game. Restart DF after installing one.

## `magnus-scripts` arguments

```sh
fort/magnus-scripts           # apply the saved selection, then open the GUI
fort/magnus-scripts apply     # headless apply; this is what the auto-run line calls
fort/magnus-scripts disable   # turn everything off + remove the auto-run line
```

The GUI has five individually-scrollable columns — `fort/`, `adv/`, `embark/`, vanilla
DFHack tools and `joke/` — with a checkbox per script. Click a row to toggle it; changes
apply live.

| Key | Effect |
|---|---|
| column header | toggle that whole column |
| `m` | toggle all the mod columns (`fort/`, `adv/`, `embark/`) at once |
| `r` | the recommended master switch: everything on, or pressed again, everything off |
| `j` | the `joke/` column |

The selection is saved to `<DF>/dfhack-config/magnus-scripts.json` and re-applied on every
map load, via one auto-run line that the script adds to `onMapLoad.init`. `disable` removes
that line but keeps your saved choices, so re-running restores them.

Anything that has never been toggled counts as **on**, so a fresh install starts with the
whole pack armed. `joke/` is the exception both ways round: off until you turn it on, and
untouched by `r` and `m`.

It is safe to re-run at any time — each helper it starts is idempotent, and it disables and
re-enables its own services rather than stacking them.

**Not managed here**, on purpose: the one-shot commands (`destroy-forbidden`, `clear-flows`,
`raid-status`, `attack-invaders`), which are run on demand; `no-pausing`, which stops *all*
pausing and so stays a manual toggle; and `embark-nobles`, which is unfinished.

## Working on the repo

See [`instructions.md`](instructions.md) for the development workflow — deploying mods,
version bumps, driving the DF UI over DFHack's RPC — and [`DEVNOTES.md`](DEVNOTES.md) for
the full command reference and implementation notes.

`README.md` is **generated**: edit `README-HEADER.md` and the `*_MODE_FEATURES.md` part
files, then run `make readme`.
