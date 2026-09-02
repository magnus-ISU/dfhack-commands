# burrow-stamper prototype

`sandbox.html` is a throwaway browser prototype of the `fort/burrow-stamper` packer and
its in-game UI (picker and preset editor). Open it in a browser; nothing here is loaded
by DFHack. The design it implements is `burrow-stamper-plan.md` at the repo root, sections
3, 4 and 4b.

It runs the same algorithm the Lua will: roads grow from the entry or from existing
geometry one segment at a time, each segment is dressed with road stamps and lined with
districts as it is laid, a road with nothing along it is refused, and a second pass fills
leftover frontage. Stamps are ASCII grids using quickfort's build codes.
