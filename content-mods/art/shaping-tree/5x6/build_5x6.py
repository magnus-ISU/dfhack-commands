"""Compose the 5x6 Shaping Tree workshop sprite (160x192).

Layout the art has to hit (DF gives a 5x5 workshop a DIM_X x (DIM_Y+1) art grid,
so row 0 is the single free row ABOVE the footprint -- that is the tree tile):

     row 0   f T f     T = the live tree trunk, left clear
     row 1     f       stem of ferns running down from the trunk
     row 2   f f f     |
     row 3   f   f     | the ring
     row 4   f f f     |
     row 5             (spill only: stray rocks/flowers)

Nothing snaps to the grid: ferns are placed on a jittered ellipse, denser near
the tree. Counts: at most 11 ferns on the ring plus 7 more around the trunk.

The four DF build stages are a REVEAL of one fixed composition, not four
pictures: every rock is present from stage 0, while ferns and flowers start at
20% and fill in. Ferns appear nearest-the-trunk first, so the growth reads as
fronds creeping down from the tree and closing the ring last.
"""
import math, random
from PIL import Image

SRC = "/home/mag/Downloads/zips/19.07a - Gentle Forest 3.0a ($0 palettes)/Created"
W, H, TILE = 160, 192, 32
CX = 80                      # trunk column centre
RING_CY, RING_RX, RING_RY = 112, 48, 48

_cache = {}


def load(name):
    if name not in _cache:
        _cache[name] = Image.open(f"{SRC}/{name}").convert("RGBA")
    return _cache[name]


def cropped(im, box=None):
    """Sub-image trimmed to its alpha bounding box, so placement is by real art."""
    sub = im.crop(box) if box else im
    bb = sub.getbbox()
    return sub.crop(bb) if bb else sub


def ferns():
    return {
        "blue": cropped(load("gentle 32x32 fern.png")),
        "green": cropped(load("gentle 32x32 green fern.png")),
        "lime": cropped(load("gentle 32x32 lime fern.png")),
    }


def decor():
    sheet = load("gentle forest small flowers.png")
    # row 1: 16x16 rock, 16x16 rock(pair), 16x16 flower
    # row 2: 8x16 flower, 8x16 flower, 16x16 flower, 16x16 flower
    rocks = [
        cropped(sheet, (0, 0, 16, 16)),           # one big mossy boulder
        cropped(sheet, (16, 0, 16, 8)),           # upper boulder of the pair
        cropped(sheet, (16, 6, 16, 16)),          # lower boulder of the pair
    ]
    flowers = [
        cropped(sheet, (32, 0, 48, 16)),          # blue lupine spikes
        cropped(sheet, (0, 16, 8, 32)),           # pink
        cropped(sheet, (8, 16, 16, 32)),          # white daisy
        cropped(sheet, (16, 16, 32, 32)),         # orange + yellow
        cropped(sheet, (32, 16, 48, 32)),         # scattered yellow/white
    ]
    return rocks, flowers


# The tile above the workshop is where DF draws the real tree trunk. The building
# art is composited OVER the terrain, so anything painted here would hide the tree:
# this rect must come out completely empty.
TRUNK = (2 * TILE, 0, 3 * TILE, TILE)


def box_of(sprite, cx, by):
    x = int(round(cx - sprite.width / 2))
    y = int(round(by - sprite.height))
    return x, y, x + sprite.width, y + sprite.height


def hits_trunk(sprite, cx, by, inset=0):
    """True if this placement would paint anywhere inside the trunk tile. Strict:
    any intrusion at all hides part of the tree DF draws there."""
    x0, y0, x1, y1 = box_of(sprite, cx, by)
    tx0, ty0, tx1, ty1 = TRUNK
    return not (x1 <= tx0 + inset or x0 >= tx1 - inset or
                y1 <= ty0 + inset or y0 >= ty1 - inset)


def paste(canvas, sprite, cx, by, flip=False):
    """Paste `sprite` centred on cx with its BASE at by (things grow upward)."""
    if flip:
        sprite = sprite.transpose(Image.FLIP_LEFT_RIGHT)
    x, y, _, _ = box_of(sprite, cx, by)
    canvas.alpha_composite(sprite, (x, y))


def pick_fern(rnd, F, variant_pct):
    if rnd.random() < variant_pct:
        return F["green"] if rnd.random() < 0.5 else F["lime"]
    return F["blue"]


def ring_point(rnd, ang, cfg):
    """A jittered point on the ring ellipse."""
    rx = RING_RX * cfg["rx"] + rnd.uniform(-cfg["rjit"], cfg["rjit"])
    ry = RING_RY * cfg["ry"] + rnd.uniform(-cfg["rjit"], cfg["rjit"])
    return CX + rx * math.cos(ang), RING_CY + cfg["cy"] + ry * math.sin(ang)


def outside_ring(x, y, cfg, pad):
    dx = (x - CX) / (RING_RX * cfg["rx"] + pad)
    dy = (y - (RING_CY + cfg["cy"])) / (RING_RY * cfg["ry"] + pad)
    return dx * dx + dy * dy > 1.0


def build(seed=0, stage=3, stages=4, first_frac=0.20, **over):
    """Compose the sprite. The layout is FIXED for a given seed; `stage` only controls
    how much of it has appeared yet, so the four DF build stages are a reveal of one
    composition rather than four different pictures.

    stage 0 shows every rock plus `first_frac` of the ferns and flowers; later stages
    reveal more. Ferns appear nearest-the-trunk first, so the growth reads as fronds
    creeping down from the tree and closing the ring last.

    Each concern draws from its OWN rng stream, so turning one knob (fern colour, rock
    count) does not shuffle everything else's positions.
    """
    cfg = dict(rx=1.0, ry=1.0, cy=0, rjit=3.0, ring_ferns=11, angle_jit=0.07,
               variant_pct=0.40, near_tree=7, rocks=5, flowers=30, rock_visible=0.40)
    cfg.update(over)
    rp = random.Random(seed * 7 + 1)        # placement of ferns
    rc = random.Random(seed * 7 + 2)        # fern colour + mirroring
    rk = random.Random(seed * 7 + 3)        # rocks
    rf = random.Random(seed * 7 + 4)        # flowers
    F = ferns()
    rocks, flowers = decor()

    ferns_out = []          # (dist_from_trunk, baseline_y, sprite, x, flip)

    def add_fern(x, y, flip=None, tries=8):
        """Place a fern, nudging it clear of the trunk tile rather than dropping it."""
        spr = pick_fern(rc, F, cfg["variant_pct"])
        y = max(y, spr.height)                      # never clip off the canvas top
        for _ in range(tries):
            if not hits_trunk(spr, x, y):
                d = math.hypot(x - CX, y - TILE)    # distance from the trunk tile
                ferns_out.append((d, y, spr, x,
                                  rc.random() < 0.5 if flip is None else flip))
                return True
            y += 7                                  # push it down out of the tile
        return False

    # --- the ring: at most cfg["ring_ferns"], evenly stratified so it closes ---
    n = cfg["ring_ferns"]
    for i in range(n):
        a = -math.pi / 2 + 2 * math.pi * (i / n)
        a += rp.uniform(-cfg["angle_jit"], cfg["angle_jit"])
        x, y = ring_point(rp, a, cfg)
        add_fern(x, y)

    # --- cfg["near_tree"] ferns around the trunk: 2 flanking it, 2 on the stem
    #     running down toward the ring, the rest an overlapping clump ---
    near = cfg["near_tree"]
    for sx in (-1, 1):
        if near <= 0:
            break
        add_fern(CX + sx * rp.uniform(30, 36), rp.uniform(28, 36), flip=sx < 0)
        near -= 1
    stem = min(2, near)
    for i in range(stem):
        t = (i + 1) / (stem + 1)
        add_fern(CX + rp.uniform(-9, 9), 52 + t * (RING_CY - RING_RY - 40))
        near -= 1
    for i in range(near):
        side = -1 if i % 2 == 0 else 1
        add_fern(CX + side * rp.uniform(20, 38), rp.uniform(34, 60))

    # --- flowers: tight around the trunk, inside the ring and on the ring;
    #     only sparse anywhere else ---
    flowers_out = []
    for _ in range(cfg["flowers"]):
        r = rf.random()
        for _try in range(8):
            if r < 0.36:                            # tight around the tree
                x = CX + rf.uniform(-34, 34)
                y = rf.uniform(34, 72)
            elif r < 0.66:                          # inside the ring
                a = rf.uniform(0, 2 * math.pi)
                rad = rf.uniform(0.15, 0.72)
                x = CX + RING_RX * cfg["rx"] * rad * math.cos(a)
                y = RING_CY + cfg["cy"] + RING_RY * cfg["ry"] * rad * math.sin(a)
            elif r < 0.90:                          # on the ring itself
                a = rf.uniform(0, 2 * math.pi)
                x, y = ring_point(rf, a, cfg)
                x += rf.uniform(-9, 9)
                y += rf.uniform(-5, 10)
            else:                                   # sparse, everywhere else
                x, y = rf.uniform(6, W - 6), rf.uniform(34, H - 3)
            x = min(max(x, 5), W - 5)
            y = min(max(y, 30), H - 2)
            spr = rf.choice(flowers)
            if not hits_trunk(spr, x, y):
                flowers_out.append((y, spr, x, rf.random() < 0.5))
                break

    # --- rocks: strictly OUTSIDE the ring, present from the very first stage, and
    #     each one retried until it lands somewhere it will actually be SEEN --
    #     "outside the ring" alone buries them, because the ring ferns straddle the
    #     ring path by half a sprite. Tested against the finished (stage 3) canopy.
    canopy = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for y, spr, x, flip in sorted(flowers_out, key=lambda t: t[0]):
        paste(canopy, spr, x, y, flip=flip)
    for d, y, spr, x, flip in sorted(ferns_out, key=lambda t: t[1]):
        paste(canopy, spr, x, y, flip=flip)
    canopy_a = canopy.split()[3]

    def visible_frac(spr, x, y):
        """Fraction of this rock's own pixels that nothing else would cover."""
        x0, y0, x1, y1 = box_of(spr, x, y)
        if x0 < 0 or y0 < 0 or x1 > W or y1 > H:
            return 0.0
        rock_a = spr.split()[3]
        over_a = canopy_a.crop((x0, y0, x1, y1))
        own = clear = 0
        for ra, oa in zip(rock_a.getdata(), over_a.getdata()):
            if ra > 128:
                own += 1
                if oa < 32:
                    clear += 1
        return clear / own if own else 0.0

    rocks_out = []
    for i in range(cfg["rocks"]):
        # sample by ANGLE around the ring rather than uniformly over the canvas --
        # uniform sampling only ever finds clear ground below the ring, and lines
        # every rock up along the bottom edge
        # ...and skip the sector directly above the ring: it is outside the ellipse
        # but visually INSIDE the grove, between the trunk and the ring
        top, gap = -math.pi / 2, 1.0
        span = 2 * math.pi - 2 * gap
        base = top + gap + span * (i / max(1, cfg["rocks"] - 1))
        for attempt in range(4000):                 # retry until this rock is placed
            spr = rocks[0] if rk.random() < 0.18 else rk.choice(rocks[1:])
            a = base + rk.uniform(-0.35, 0.35)
            rad = rk.uniform(1.16, 1.5)
            x = CX + RING_RX * cfg["rx"] * rad * math.cos(a)
            y = RING_CY + cfg["cy"] + RING_RY * cfg["ry"] * rad * math.sin(a)
            if not outside_ring(x, y, cfg, 20) or hits_trunk(spr, x, y):
                continue
            if visible_frac(spr, x, y) < cfg["rock_visible"]:
                continue
            rocks_out.append((y, spr, x, rk.random() < 0.5))
            break
        else:
            raise RuntimeError("could not place a rock outside the ring")

    # ---- reveal ----------------------------------------------------------------
    frac = 1.0 if stages < 2 else first_frac + (1 - first_frac) * (stage / (stages - 1))
    frac = min(max(frac, 0.0), 1.0)
    ferns_by_dist = sorted(ferns_out, key=lambda t: t[0])        # trunk outward
    shown_ferns = ferns_by_dist[:max(1, round(len(ferns_by_dist) * frac))]
    shown_flowers = flowers_out[:max(1, round(len(flowers_out) * frac))]

    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for y, spr, x, flip in sorted(rocks_out, key=lambda t: t[0]):
        paste(canvas, spr, x, y, flip=flip)
    for y, spr, x, flip in sorted(shown_flowers, key=lambda t: t[0]):
        paste(canvas, spr, x, y, flip=flip)
    for d, y, spr, x, flip in sorted(shown_ferns, key=lambda t: t[1]):
        paste(canvas, spr, x, y, flip=flip)

    assert not canvas.crop(TRUNK).getbbox(), "trunk tile must stay empty"
    return canvas


GRASS = (86, 122, 61, 255)


def mock_tree(zoom):
    """Stand-in for the real tree DF draws on the trunk tile, so composition can be
    judged the way it will actually be seen."""
    t = Image.new("RGBA", (TILE * zoom, TILE * zoom), (0, 0, 0, 0))
    from PIL import ImageDraw
    d = ImageDraw.Draw(t)
    s = TILE * zoom
    d.ellipse([s * .16, s * .16, s * .84, s * .84], fill=(92, 62, 38, 255),
              outline=(58, 38, 22, 255), width=max(1, zoom))
    d.ellipse([s * .32, s * .32, s * .68, s * .68], outline=(126, 88, 54, 255),
              width=max(1, zoom))
    d.ellipse([s * .45, s * .45, s * .55, s * .55], fill=(126, 88, 54, 255))
    return t


def preview(img, zoom=3, grid=True, bg=GRASS, label=None, tree=True):
    from PIL import ImageDraw
    out = Image.new("RGBA", (W * zoom, H * zoom), bg)
    if tree:
        out.alpha_composite(mock_tree(zoom), (2 * TILE * zoom, 0))
    out.alpha_composite(img.resize((W * zoom, H * zoom), Image.NEAREST))
    if grid:
        d = ImageDraw.Draw(out)
        for c in range(1, 5):
            d.line([(c * TILE * zoom, 0), (c * TILE * zoom, H * zoom)],
                   fill=(0, 0, 0, 60))
        for r in range(1, 6):
            col = (255, 70, 70, 200) if r == 1 else (0, 0, 0, 60)
            d.line([(0, r * TILE * zoom), (W * zoom, r * TILE * zoom)], fill=col)
        d.rectangle([2 * TILE * zoom, 0, 3 * TILE * zoom, TILE * zoom],
                    outline=(255, 210, 60, 255), width=2)
    return out


# ---------------------------------------------------------------- deployment ----
# The chosen composition. Seed 31, B-sketch shape: 11 ferns on the ring, 7 more
# around the trunk, 40% of them green/lime, 5 rocks ringing the outside.
SEED = 31
STAGES = 4

MODS = [
    dict(mod="ha-high-elves", page="HA_HE_SHAPING_TREE_PAGE",
         code="HA_HE_SHAPING_TREE", tokens="graphics/graphics_ha_high_elf_buildings.txt",
         tile_page="graphics/tile_page_ha_high_elf.txt"),
    dict(mod="ha-playable-civs", page="HA_SHAPING_TREE_PAGE",
         code="HA_SHAPING_TREE", tokens="graphics/graphics_ha_playable_buildings.txt",
         tile_page="graphics/tile_page_ha_playable.txt"),
]


def page_image(seed=SEED, stages=STAGES):
    """The four build stages stacked into one 160 x (192*4) tile page."""
    page = Image.new("RGBA", (W, H * stages), (0, 0, 0, 0))
    for v in range(stages):
        page.alpha_composite(build(seed=seed, stage=v, stages=stages), (0, v * H))
    return page


def tokens(page_id, code, stages=STAGES):
    """One TILE_GRAPHICS per art cell: 4 variants x 5 columns x 6 rows = 120.

    DF gives a 5x5 workshop a 5 x (5+1) art grid. wy 0 is the free row ABOVE the
    footprint -- the tree tile -- and wy 1..5 are the footprint rows, which is why
    the old 0..4 tokens sat one row too high. Variant index == construction stage,
    3 being the finished workshop.
    """
    out = []
    for v in range(stages):
        out.append(f"\tstage {v}" + ("  (finished)" if v == stages - 1 else ""))
        for wy in range(H // TILE):
            for wx in range(W // TILE):
                out.append(f"\t[TILE_GRAPHICS:{page_id}:{wx}:{v * (H // TILE) + wy}:"
                           f"WORKSHOP_CUSTOM:{code}:{v}:{wx}:{wy}]")
    return out


def deploy(repo="/home/mag/Downloads/code/dfhack-commands/content-mods/high-adventure"):
    """Write the page image, the 120 tokens and the page dimensions into both mods."""
    import re, os
    page = page_image()
    for m in MODS:
        root = os.path.join(repo, m["mod"])
        img = os.path.join(root, "graphics/images/shaping_tree.png")
        page.save(img)

        tok = os.path.join(root, m["tokens"])
        head = os.path.basename(tok)[:-4]
        body = "\n".join([
            head, "",
            "[OBJECT:GRAPHICS]", "",
            "Shaping Tree -- 5 wide x 6 tall art grid (DIM_X x DIM_Y+1). Row 0 is the",
            "free row ABOVE the workshop, where the living tree stands, so it is left",
            "blank in every stage. The four variants are DF's construction stages, not",
            "random art: ferns and flowers fill in from the trunk outward, and the ring",
            "closes only at stage 3.",
        ] + tokens(m["page"], m["code"])) + "\n"
        open(tok, "w").write(body)

        tp = os.path.join(root, m["tile_page"])
        src = open(tp).read()
        src = re.sub(r"(\[TILE_PAGE:" + m["page"] + r"\][^\[]*\[FILE:[^\]]*\]\s*"
                     r"\[TILE_DIM:\d+:\d+\]\s*\[PAGE_DIM_PIXELS:)\d+:\d+(\])",
                     rf"\g<1>{page.width}:{page.height}\g<2>", src)
        open(tp, "w").write(src)
        print(f"{m['mod']}: {img.split('/')[-1]} {page.size}, "
              f"120 tokens, PAGE_DIM_PIXELS {page.width}:{page.height}")
