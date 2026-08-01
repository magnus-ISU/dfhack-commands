#!/usr/bin/env python3
"""Generate the bulky, uninteresting parts of the crash-repro mod:

  objects/entity_crash_repro.txt    vanilla MOUNTAIN, renamed, pointed at our creature
  graphics/crash_repro/body.png     8x1 tiles of flat colour (the page declares 1x1)
  graphics/crash_repro/palettes.png 4 palette rows; row 0 is the sheet's own colours

Everything that actually demonstrates the bug is hand-written and tiny -- see
graphics/graphics_crash_repro.txt and README.md.

    python3 generate.py [path-to-DF-install]
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DF = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    '~/.local/share/Steam/steamapps/common/Dwarf Fortress')

# ---- entity: vanilla MOUNTAIN with a new ID and our creature ----------------

VANILLA_ENTITY = os.path.join(DF, 'data/vanilla/vanilla_entities/objects/entity_default.txt')

HEADER = """entity_crash_repro

GENERATED FILE -- run generate.py to rebuild.

The vanilla MOUNTAIN entity copied verbatim, with two changes: the entity ID is
CRASH_REPRO_CIV and its creature is CRASH_REPRO. This is boilerplate, not part
of the bug: a civ has to be complete to be embark-able, and a proven-good copy
keeps the repro from failing for unrelated reasons. The bug lives in
graphics/graphics_crash_repro.txt.

[OBJECT:ENTITY]

"""


def build_entity():
    with open(VANILLA_ENTITY, encoding='cp437') as f:
        lines = f.read().splitlines()
    out, inside = [], False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('[ENTITY:'):
            if inside:
                break
            inside = stripped == '[ENTITY:MOUNTAIN]'
            if inside:
                out.append('[ENTITY:CRASH_REPRO_CIV]')
                continue
        if inside:
            out.append('\t[CREATURE:CRASH_REPRO]' if stripped == '[CREATURE:DWARF]' else line)
    if not out:
        raise SystemExit(f'[ENTITY:MOUNTAIN] not found in {VANILLA_ENTITY}')
    dest = os.path.join(HERE, 'objects/entity_crash_repro.txt')
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, 'w', encoding='cp437') as f:
        f.write(HEADER + '\n'.join(out) + '\n')
    print(f'wrote {dest} ({len(out)} lines)')


# ---- images -----------------------------------------------------------------
# body.png is EIGHT 32x32 tiles in a row. The tile page declares one. Tile 0 is
# the only tile that officially exists; tiles 1..7 are real pixels the
# declaration hides, and the layers ask for some of them anyway.

TILE = 32
TILES = 8
COLOURS = [
    (200, 40, 160, 255),   # 0 magenta  -- the declared tile
    (40, 200, 200, 255),   # 1 cyan     -- one tile past the declared edge
    (240, 160, 40, 255),   # 2 orange
    (80, 220, 90, 255),    # 3 green
    (220, 220, 60, 255),   # 4 yellow
    (150, 90, 230, 255),   # 5 violet
    (230, 70, 70, 255),    # 6 red
    (60, 110, 240, 255),   # 7 blue     -- seven tiles past the declared edge
]


def png_bytes(width, height, pixel):
    """pixel(x, y) -> RGBA tuple"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)                     # filter type 0 for this scanline
        for x in range(width):
            raw.extend(pixel(x, y))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
            + chunk(b'IEND', b''))


def write_png(relpath, width, height, pixel):
    dest = os.path.join(HERE, relpath)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, 'wb') as f:
        f.write(png_bytes(width, height, pixel))
    print(f'wrote {dest} ({width}x{height})')


def build_images():
    # the sprite sheet: one flat colour per tile
    write_png('graphics/crash_repro/body.png', TILE * TILES, TILE,
              lambda x, y: COLOURS[x // TILE])

    # the palette sheet: row 0 must hold the sheet's own colours (that is what
    # LS_PALETTE_DEFAULT:0 means -- the colours to swap FROM). Rows 1..3 are
    # progressively darker versions, so each USE_PALETTE index forces DF to
    # build a separate recoloured copy of the sprite.
    def palette_pixel(x, y):
        r, g, b, a = COLOURS[x]
        if y == 0:
            return (r, g, b, a)
        f = 1.0 - 0.25 * y
        return (int(r * f), int(g * f), int(b * f), a)

    write_png('graphics/crash_repro/palettes.png', TILES, 4, palette_pixel)


if __name__ == '__main__':
    build_entity()
    build_images()
