#!/usr/bin/env python3
"""Regenerate the duplicate human entity from the installed vanilla raws.

A civilization is an entity, and an entity only *references* a creature, so a
second human civ needs no creature of its own -- [CREATURE:HUMAN] points at the
vanilla creature and always will. Only the entity block has to be duplicated,
and entity raws have no COPY_TAGS_FROM, so it is duplicated by copying the text.
Re-run this after a DF update to pick up any changes Bay 12 made to PLAINS.

    python3 sync_from_vanilla.py
"""
import os, re, sys

NEW_ID = "HA_PLAINS_ALT"
SRC = os.path.expanduser(
    "~/.local/share/Steam/steamapps/common/Dwarf Fortress"
    "/data/vanilla/vanilla_entities/objects/entity_default.txt")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "objects", "entity_ha_plains_alt.txt")

def main():
    if not os.path.isfile(SRC):
        sys.exit(f"vanilla entity file not found: {SRC}")
    text = open(SRC, encoding="utf8", errors="replace").read()

    m = re.search(r'^\[ENTITY:PLAINS\]\n(.*?)(?=^\[ENTITY:)', text, re.M | re.S)
    if not m:
        sys.exit("could not find the PLAINS entity block in the vanilla raws")
    body = m.group(1).rstrip("\n")

    if "[CREATURE:HUMAN]" not in body:
        sys.exit("PLAINS no longer lists CREATURE:HUMAN -- check the vanilla raws by hand")

    header = (
        "entity_ha_plains_alt\n"
        "\n"
        "GENERATED FILE -- do not edit by hand. Run sync_from_vanilla.py instead.\n"
        "\n"
        f"A second human civilization, copied verbatim from vanilla PLAINS and renamed to\n"
        f"{NEW_ID}. It shares the vanilla HUMAN creature rather than duplicating it, so\n"
        "nothing here has to track changes to the creature raws. Two human entities means\n"
        "humans get two draws to an orc civilization's one when worldgen places civs.\n"
        "\n"
        "The two human civs are independent powers and can war with each other.\n"
        "\n"
        "[OBJECT:ENTITY]\n"
        "\n"
        f"[ENTITY:{NEW_ID}]\n")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf8") as f:
        f.write(header + body + "\n")

    lines = body.count("\n") + 1
    print(f"wrote {OUT}")
    print(f"  {lines} lines copied from vanilla PLAINS, entity id {NEW_ID}")

if __name__ == "__main__":
    main()
