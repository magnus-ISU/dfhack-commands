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
| DF user data (`$B12`) — saves + snapshots | `~/.local/share/Bay 12 Games/Dwarf Fortress` |
| Worldgen mod source (seeds NEW worlds) | `$DF/mods/<mod-id>` |
| Saves | `$B12/save/<region>` |
| Per-world baked mod snapshots | `$B12/data/installed_mods/<MOD_ID> (n)` |
| DFHack command-script deploy target | `$DF/dfhack-config/scripts` |
| Stock DFHack scripts (read-only reference) | `$DFH/hack/scripts` |

```sh
DF="$HOME/.local/share/Steam/steamapps/common/Dwarf Fortress"
DFH="$HOME/.local/share/Steam/steamapps/common/DFHack"
B12="$HOME/.local/share/Bay 12 Games/Dwarf Fortress"   # saves: $B12/save, snapshots: $B12/data/installed_mods
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

An **active save** bakes raws in at gen time, so raw changes never reach an existing
world. Each world's scripts + graphics load from its own versioned snapshot under
`$B12/data/installed_mods/<MOD_ID> (n)` (find the live one via
`dfhack.findScript('high-adventure/<name>')`). To hot-patch a script into an existing
world, copy it into that snapshot and `reqscript` + overlay-rescan.

**Delete old-version snapshots — `rm -rf` them.** This project keeps exactly ONE version
of each mod alive: the current one. Old snapshots under `$B12/data/installed_mods/` are
purged even though that breaks any world generated against them. Old worlds are expendable
here; a mod list cluttered with stale versions is not worth keeping them for. Two concrete
harms the clutter causes: DF lists a mod once per copy it can see, so the picker fills with
versions you can pick by mistake, and a stale snapshot keeps serving its old description
and old `scripts_modactive/` to anything still pointed at it.

```sh
B12="$HOME/.local/share/Bay 12 Games/Dwarf Fortress"
# every snapshot whose NUMERIC_VERSION is below the copy in $DF/mods
ls -d "$B12/data/installed_mods/"*/          # inspect first, then rm -rf the old ones
```

Snapshots that MATCH the current `$DF/mods` version are not "old" — leave those; they are
what the live world loads scripts and graphics from.

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
   stale one. Same for old snapshots under `$B12/data/installed_mods/`.

4. **Regenerate the bundle — every time any member mod changes.** The all-in-one
   `high-adventure` mod is GENERATED from the sibling `ha-*` mods; it is not edited by
   hand and it does not update itself. Leave it stale and the bundle ships the old raws,
   old scripts and a description advertising member versions that no longer exist.
   ```sh
   cd content-mods/high-adventure
   # bump NUMERIC_VERSION / DISPLAYED_VERSION at the top of the build script FIRST
   python3 build-high-adventure.py      # 11 mods, N files, 0 duplicate defs
   ```
   **Bump the bundle's own version on every rebuild.** DF keys its snapshot by
   `<MOD_ID> (numeric_version)`, so a rebuild that keeps the old number leaves DF serving
   the previous `HIGH_ADVENTURE (n)` snapshot — the contents change and DF never notices.
   Then deploy `high-adventure` like any other mod and `rm -rf` the superseded snapshot.
   The build script wipes its output directory, so anything hand-added inside
   `high-adventure/` (a CHANGES.md, say) is destroyed on the next run — keep such files in
   the member mods or beside the script.

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

Deploy the whole set at once (category folders deploy as subdirectories, so the
command name keeps its prefix — `adv/reveal`, `embark/adventurer-values`):
```sh
cp dfhack/*.lua "$DF/dfhack-config/scripts/"
mkdir -p "$DF/dfhack-config/scripts/"{adv,fix,embark}
cp adv/*.lua "$DF/dfhack-config/scripts/adv/"
cp fix/*.lua "$DF/dfhack-config/scripts/fix/"
cp embark/*.lua "$DF/dfhack-config/scripts/embark/"
```

## Run a DFHack command

```sh
"$DFH/dfhack-run" <name> [args]      # e.g. dfhack-run caravan unload
"$DFH/dfhack-run" lua '<code>'       # ad-hoc lua
```
`dfhack.findScript('name')` inside lua returns a script's real on-disk path (stock scripts
resolve to `$DFH/hack/scripts`).

## Generate a world

`dfhack/gen-world.lua` drives world creation from the title screen. It writes
`viewscreen_new_regionst`'s own fields for anything DF exposes as data (the mod list, the
five sliders) and only *clicks* the buttons that have no data equivalent.

```sh
"$DFH/dfhack-run" gen-world civilizations=max sites=max history=2 mods=ha
```

`civilizations` / `sites` / `history` / `worldsize` / `beasts` / `savagery` / `minerals`
each take `max`, `min` or `0`-`4`; `mods=` takes `ha` (everything installed bar upstream
fork sources), `all` or `none`. History: `0`=5 years, `1`=50, `2`=100, `3`=250, `4`=500.
World size: `0`=Pocket, `1`=Smaller, `2`=Small, `3`=Medium, `4`=Large.

Then poll until the year stops climbing and sites appear:

```sh
"$DFH/dfhack-run" lua 'print(df.global.cur_year, #df.global.world.world_data.sites)'
```

**Restart DF after every raw change.** DF scans `$DF/mods/` exactly once, at startup, so a
mod deployed while the game is running is invisible — worldgen will silently use the old
raws. This has produced two full worlds' worth of misleading data.

**DF lists a mod once per copy it can see** — the live one under `mods/` and any older
snapshot in `installed_mods/` — under the same ID at different versions. `gen-world` takes
the highest version, but deleting a mod from `mods/` is not enough to retire it: `rm -rf`
its `installed_mods/` copies too or it stays selectable forever.

**The first-run "Welcome to Dwarf Fortress" modal reappears after every restart**, swallows
the Create-world click silently, and leaves the sliders untouched with no error. `gen-world`
detects it and asks you to dismiss it; when driving the screen by hand, search the text grid
for `Welcome to Dwarf` and click its `Okay` first.

**A bad entity gives an endless reject loop, not an error.** The counter on the generation
screen climbs ("88 rejected") while the year never leaves 1. The reason is printed at the
top of that screen and *nowhere else* — not in `errorlog.txt` — so read it there. Seen so
far: `FARMING CIVILIZATION PLACED WITHOUT CROPS`, caused both by removing `BIOME_SUPPORT`
entirely from a farming civ and by putting `[MYTHICAL]` on one.

### Take the census

```sh
"$DFH/dfhack-run" ha-census
```

`dfhack/ha-census.lua` reports population at years 1/25/50/75/100, final population with
civ counts, sites and castles, site terrain per civ, and the terrain available on the map.
Run it **straight after generation, before saving**.

Notes for writing your own queries:

- DF stores no historical population. "Alive in year Y" is reconstructed from each
  historical figure's `born_year` / `died_year`. Exact for megabeasts and rare castes;
  a *sample* for bulk races. Say which you are reporting.
- Current head count is `entity.total_pop` summed over `world.entities.all`, grouped by
  `entity.entity_raw.code`. `entity.populations` is usually empty; don't trust it.
- Civilization *count* means entities of type `df.historical_entity_type.Civilization` —
  most entity records are site governments, and the vanilla animal peoples add hundreds.
- Site terrain: `world_data.region_map[x]:_displace(y).region_id` into
  `world_data.regions[...].type`, read through `df.world_region_type`. `region_map[x][y]`
  does **not** work — the row is a pointer and needs `_displace`.
- War events carry `attacker_civ` / `defender_civ`. There are no `*_civ_id` fields; reading
  those under `pcall` silently reports zero wars for every civ in the world.
- Necromancers: classify by `hf.info.curse.active_interactions` being non-empty. Filtering
  on `curse.name == "necromancer"` misses nearly all of them, since worldgen names each
  secret procedurally.
- `df.history_event_type` does not enumerate as a Lua table; index it with the numeric type
  from `event:getType()`.

### Keep the world

Click `Keep world and return to main menu` to save and land back at the title screen.
Saves go to `~/.local/share/Bay 12 Games/Dwarf Fortress/save/regionN` — **not** the Steam
install directory. Avoid the post-worldgen `Play now` shortcut; it has crashed DF on large
worlds. To play, keep the world, then load it from the title screen.

## Drive the DF UI

Two ways, and picking right matters.

**Write the data.** Wherever DF exposes state as fields, set them. Nothing to mis-target,
no timing to get wrong.

```lua
local vs = dfhack.gui.getCurViewscreen(true)
while vs and not df.viewscreen_new_regionst:is_instance(vs) do vs = vs.parent end
vs.simple_civ_num, vs.simple_site_cap, vs.simple_history, vs.simple_world_size = 4, 4, 2, 3
```

**Feed a click** for buttons with no data equivalent: park DF's own cursor, then send the
event. Works on every screen tried — title menu, world creation, the world load list, game
type, the civ picker, the embark map and its popups.

```lua
df.global.gps.mouse_x, df.global.gps.mouse_y = cell_x, cell_y
require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
```

Find the cell by reading the text grid with `dfhack.screen.readTile(x, y)` and searching for
the button's label. Search from the bottom for labels that also appear in help text.

- **Wait ~2s after any screen transition.** The grid you read is the last rendered frame;
  clicking and immediately searching for the next screen's label returns nothing, which
  looks exactly like a failed click.
- **`row and row:find(...)` truncates to one return value** in a multiple assignment, so the
  end index comes back nil. Check the nil first, then call `find`.
- **xdotool cannot click DF.** On Wayland it moves the pointer — DF polls cursor position,
  so `gps.mouse_x/y` follows — but no button or key event ever arrives. Use fed clicks.
- **Sliders ignore fed clicks**, but they are plain ints you can assign.
- Check DF is alive with `pgrep -x dwarfort`. Do **not** use
  `pgrep -f "Dwarf Fortress/dwarfort"` — it matches your own shell command line and will
  report a dead DF as running. Likewise `pkill -f` will kill your own shell.
- Restart with `setsid steam -applaunch 2346660` (that appid is DFHack, which launches DF).

## Gotchas worth remembering

- **New raws → new world.** No way to inject a new creature/syndrome into an existing save.
- **Unit spawning from scratch is unreliable** on this build; resurrect existing units
  (`full-heal -r`) instead of `units.create`.
- **Caste changes** must go through the dummy-transform-revert pattern (see
  `ha-illithids` `set_caste` / `HA_ILLITHID_TF`): set the identity caches, then a one-tick
  `CE_BODY_TRANSFORMATION` into a dummy so DF rebuilds the body/appearance. Setting
  `unit.caste` directly on a caste with different body parts crashes the description view.
- **Never recurse a viewscreen** from a script — it crashes DF.
