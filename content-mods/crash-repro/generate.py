#!/usr/bin/env python3
"""Generate the two bulky, uninteresting parts of the crash-repro mod:

  objects/entity_crash_repro.txt   vanilla MOUNTAIN, renamed, pointed at our creature
  graphics/crash_repro/body.png    a 2x1-tile sheet (the page declares 1x1)

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


# ---- sprite sheet: two 32x32 tiles side by side ----------------------------
# Tile 0 (magenta) is the only one the tile page admits exists.
# Tile 1 (cyan) is real image data that the page declaration hides -- the layer
# in graphics_crash_repro.txt asks for it anyway.

TILE = 32
LEFT = (200, 40, 160, 255)     # magenta: in-bounds tile
RIGHT = (40, 200, 200, 255)    # cyan: the out-of-bounds tile


def build_png():
    width, height = TILE * 2, TILE
    raw = bytearray()
    for _ in range(height):
        raw.append(0)                                   # filter type 0 per scanline
        for x in range(width):
            raw.extend(LEFT if x < TILE else RIGHT)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    dest = os.path.join(HERE, 'graphics/crash_repro/body.png')
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, 'wb') as f:
        f.write(png)
    print(f'wrote {dest} ({width}x{height})')


if __name__ == '__main__':
    build_entity()
    build_png()
