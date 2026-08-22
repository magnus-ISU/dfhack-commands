<!-- GENERATED FILE — do not edit README.md directly.
     Composed by `make readme` from README-HEADER.md, FORTRESS_MODE_FEATURES.md,
     ADVENTURE_MODE_FEATURES.md and HIGH_ADVENTURE_FEATURES.md.
     Edit those instead; anything written here is overwritten on the next build. -->

A personal pack of **DFHack scripts** for the latest Dwarf Fortress (0.53.x / Steam),
plus the **Dwarf Fortress: High Adventure** content-mod suite.

## Install

```sh
git clone https://github.com/magnus-ISU/dfhack-commands
cd dfhack-commands
make install     # scripts + content mods + plugins
```

Then restart Dwarf Fortress, and in the DFHack console run:

```sh
fort/magnus-scripts
```

That opens the switchboard — a checkbox per helper in this pack. Click rows to turn things
on or off; your choice is saved and re-applied on every map load, so it is a one-time setup.
Press `r` if you just want everything on.

Non-standard install path, installing individual scripts by hand, or the rest of the
arguments: [`SETUP_INSTRUCTIONS.md`](SETUP_INSTRUCTIONS.md).

## Where things are

- Scripts: [`dfhack/`](dfhack/) — `fort/`, `adv/`, `embark/`, `fix/`. The feature lists
  below cover what each one does.
- Content mods: [`content-mods/high-adventure/`](content-mods/high-adventure/).
- Things that don't work yet: [`BROKEN_FEATURES.md`](BROKEN_FEATURES.md).
- Full command reference, implementation notes and TODOs: [`DEVNOTES.md`](DEVNOTES.md).
  Repo/workflow quickstart: [`instructions.md`](instructions.md).

---
