# Licensing and attribution

This repository contains **our own work** (DFHack scripts, mod raws, build tooling, docs) and a
significant amount of **third-party content** — sprite sheets, raws and code borrowed from other
Dwarf Fortress mods and from open-source projects. This file records what came from where.

Provenance below was established by byte-comparing every image in `content-mods/high-adventure/`
against the reference mods in `content-mods/` and against Dwarf Fortress's own
`data/vanilla/`, not by memory. Re-run that comparison after any art change.

> **UNRESOLVED — read before publishing.** Steam Workshop items carry **no explicit licence** by
> default, and the Workshop's terms do not grant redistribution rights between users. Every mod
> in the table below is in that position: we forked them under the assumption that DF's modding
> culture permits it, which is customary but is *not* a licence. Before this repository is
> published or the mods are uploaded anywhere, the right move is to ask each author for
> permission, and to honour any refusal by redrawing or dropping the asset.

## 1. Our own work

Everything not listed in sections 2–5: the `dfhack/` scripts, the `plugins/ssaudio` source,
`content-mods/high-adventure/` raws and scripts, the build tooling and all documentation.

**Licence: NOT YET CHOSEN.** MIT is the natural fit (DFHack itself is zlib-licensed and the
script ecosystem is permissive) but this is the repository owner's call and nothing here should
be treated as licensed until it is made. Note that any decision interacts with section 3 —
CC-BY-SA art would impose share-alike on the art regardless of the code licence.

## 2. Art borrowed from other Dwarf Fortress mods

259 image files in `content-mods/high-adventure/` are **byte-identical** to files shipped by the
reference mods under `content-mods/` (which are themselves downloaded from the Steam Workshop
via `steamcmd`, app 975370, and are gitignored). All rights remain with their authors.

| Our mod | Source mod | Author | Steam ID | Files |
|---|---|---|---|---|
| `ha-orcs` | Topples' Orcs | Topples | 2946888253 | 86 |
| `ha-succubi` | Succubus Dungeon | Boltie | 2950544248 | 78 |
| `ha-drow` | Dark Elves Redux | Endali | 3243046197 | 36 |
| `ha-kobolds` | Cute Kobold Caverns | Ottfried & GadgetPatch, packaged by DeltaFire | 3477662286 | 29 |
| `ha-illithids` | Illithids | Myphicbowser | 3027569318 | 8 |
| `ha-dark-dwarves` | Fantastic Fantasy Fortress | chipathingy | 2905522743 | 4 |
| `ha-high-elves` | Vanilla Drow Expanded Playable | LeDouke | 2923379473 | 3 |
| `ha-kobolds` | Naut's Procedural Dragons | Nautilus | 3424029801 | 3 |
| `ha-illithids`, `ha-high-elves`, `ha-drow` | Fantastic Fantasy Fortress | chipathingy | 2905522743 | 5 |
| `ha-drow`, `ha-beasts`, `ha-dark-dwarves`, `ha-illithids` | Cute Kobold Caverns | Ottfried & GadgetPatch | 3477662286 | 5 |
| `ha-succubi` | Illithids | Myphicbowser | 3027569318 | 2 |

**Onward credits declared by those authors, which pass through to us:**

- *Illithids* (Myphicbowser) credits **dikbutdagrate** for the illithid sprites, **McNuggy**
  for the Brainwyrm sprite, and **DPh Kraken** for the illithid language.
- *Cute Kobold Caverns* is itself a combination of Ottfried's *Cute Kobolds* and GadgetPatch's
  *Kobold Caverns*, packaged by DeltaFire.
- *Dark Elves Redux* (Endali) is an overhaul of *Dark Elf Civilization* by **Avery4life**.

Raws, languages, entity structures and reaction patterns were also forked from these mods; each
of our mods keeps a `CHANGES.md` documenting its diff from the original.

## 3. Warlocks reference material — CC-BY-SA, unresolved

`content-mods/warlocks/` (gitignored) holds material from Meph's **☼Warlocks☼**
(bay12 thread 175304). The 1.0 release itself no longer exists anywhere; what we have is the
Masterwork-era raws from [Meph248/MDF-Dev-Version](https://github.com/Meph248/MDF-Dev-Version)
and the sprite images posted in the forum thread.

Meph credits that art to **himself, Vordak, Redshrike and Denzi**:

- **Denzi** — <http://www3.wind.ne.jp/DENZI/diary/>, also on OpenGameArt.
  **CC-BY-SA 3.0**: attribution *and* share-alike.
- **Redshrike** (Stephen Challener) — OpenGameArt; attribution plus a link back to
  <https://opengameart.org>.
- **Vordak** — used by Meph with permission granted to *him*, which does not transfer to us.

**We cannot tell which sprite came from which artist.** The decision on record is to credit all
four and accept CC-BY-SA on this art; the alternative is redrawing. Note that the Vordak
permission problem is not solved by attribution — his permission was granted to Meph, not to us.

**As of ha-warlocks 0.2 this art is shipped**, not merely referenced:
`content-mods/high-adventure/ha-warlocks/graphics/images/ha_warlock_creatures.png` is fifteen
32x32 sprites cut from the thread's cheat sheet (`Kp8JNP7.png`) — warlock, witch, skeleton,
bone golem, five prisoners, three mephits and three gargoyles. It is the only asset in this
repository whose licence obliges share-alike, and it is the thing to redraw first if the
project ever wants a clean permissive licence.

## 4. Dwarf Fortress's own assets

45 images in `content-mods/high-adventure/` are byte-identical to art shipped with Dwarf
Fortress under `data/vanilla/` — vanilla dwarf, goblin and elf sprite sheets and palette strips,
re-keyed to our creatures (`ha-drow` 30, `ha-dark-dwarves` 5, `ha-illithids` 3, `ha-kobolds` 3,
`ha-high-elves` 2, `ha-beasts` 1, `ha-succubi` 1). Copyright **Bay 12 Games / Kitfox Games**.
Re-keying vanilla graphics is standard practice for DF mods and the game ships the files, but
they are not ours and are not redistributable outside a DF mod context.

The same applies to raws derived from `data/vanilla` (creature bodies, tissue templates,
entity scaffolding).

## 5. Code dependencies

| Component | Origin | Licence |
|---|---|---|
| `plugins/ssaudio/minimp3.h`, `minimp3_ex.h` | lieff/minimp3 | **CC0 1.0** (public domain dedication) |
| SDL2 (linked, not vendored; a Windows import lib comes from DFHack's `depends/`) | libsdl.org | **zlib** |
| `other-authors/df-smooth-movement` (git submodule) | <https://github.com/anmej/df-smooth-movement> | **MIT**, © 2026 notliad |
| DFHack (build dependency, not vendored) | DFHack project | **zlib** |

## 6. Maintenance

When art is added, changed, or a new mod is forked:

1. Re-run the byte-comparison against `content-mods/*` and `data/vanilla` and update
   sections 2 and 4.
2. Record the source in that mod's `CHANGES.md` as well.
3. If an asset is drawn from scratch, say so explicitly — "no exact match" in the comparison
   means *not byte-identical*, which is not the same as *original*; a recolour or a crop of
   someone else's sprite is still a derivative work.
