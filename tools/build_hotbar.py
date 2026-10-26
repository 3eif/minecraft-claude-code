import os, io, json, zipfile, math, sys
from PIL import Image
jar = zipfile.ZipFile(os.path.expanduser("~/Library/Application Support/minecraft/versions/1.21.8/1.21.8.jar"))
T = 'assets/minecraft/textures/'
def load(p): return Image.open(io.BytesIO(jar.read(T + p + '.png'))).convert('RGBA')

def iso(top, left, right, h=1.0, S=2):
    N = 16 * S; U = 10 * S
    c, s30, c30 = math.sqrt(.5), .5, math.sqrt(3) / 2
    def P(x, y, z): return ((x - z) * c * U, (x + z) * c * s30 * U - y * c30 * U)
    pts = [P(x, y, z) for x in (0, 1) for y in (0, h) for z in (0, 1)]
    ox = N / 2 - (min(p[0] for p in pts) + max(p[0] for p in pts)) / 2
    oy = N / 2 - (min(p[1] for p in pts) + max(p[1] for p in pts)) / 2
    out = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    def face(tex, o, a, b, shade):
        w, hh = tex.size
        ux, uy = (a[0] - o[0]) / w, (a[1] - o[1]) / w
        vx, vy = (b[0] - o[0]) / hh, (b[1] - o[1]) / hh
        det = ux * vy - vx * uy
        ia, ib, ic, id_ = vy / det, -vx / det, -uy / det, ux / det
        X, Y = o[0] + ox, o[1] + oy
        im = tex.transform((N, N), Image.AFFINE, (ia, ib, -(ia * X + ib * Y), ic, id_, -(ic * X + id_ * Y)), Image.NEAREST)
        r, g, bl, al = im.split()
        f = lambda v: int(v * shade)
        out.alpha_composite(Image.merge('RGBA', (r.point(f), g.point(f), bl.point(f), al)))
    rows = int(round(16 * h))
    face(top, P(0, h, 0), P(1, h, 0), P(0, h, 1), 1.0)
    face(left.crop((0, 16 - rows, 16, 16)), P(0, h, 1), P(1, h, 1), P(0, 0, 1), .8)
    face(right.crop((0, 16 - rows, 16, 16)), P(1, h, 1), P(1, h, 0), P(1, 0, 1), .6)
    return out

def frag(im, k=1):
    """One path per color, one 1-pixel-high rectangle per run, as sprites.ts has."""
    by = {}
    px = im.load()
    for y in range(im.height):
        x = 0
        while x < im.width:
            c = px[x, y]
            if c[3] == 0: x += 1; continue
            x0 = x
            while x < im.width and px[x, y] == c: x += 1
            by.setdefault(c, []).append(f'M{x0} {y}h{x - x0}v1h-{x - x0}z')
    out = ''
    for (r, g, b, a), runs in by.items():
        op = '' if a == 255 else f' fill-opacity="{a / 255:.2f}"'
        out += f'<path fill="#{r:02x}{g:02x}{b:02x}"{op} d="{"".join(runs)}"/>'
    return out if k == 1 else f'<g transform="scale({1 / k})">{out}</g>'

hb = load('gui/sprites/hud/hotbar')
SLOTS = 4; REGION = 90
# The game's nine slots cut down to SLOTS, its right cap kept.
W = 20 * SLOTS + 2
four = Image.new('RGBA', (W, 22)); four.paste(hb.crop((0, 0, W - 1, 22)), (0, 0)); four.paste(hb.crop((181, 0, 182, 22)), (W - 1, 0))
pieces = []
for i in range(SLOTS):
    x0 = 0 if i == 0 else 5 + 20 * i
    x1 = REGION if i == SLOTS - 1 else 25 + 20 * i
    a, b = max(0, x0 - 4), min(W, x1 - 4)
    pieces.append([4 + a, frag(four.crop((a, 0, b, 22)))])
icons = {
  'advancements': frag(load('item/knowledge_book')),
  'music': frag(iso(load('block/jukebox_top'), load('block/jukebox_side'), load('block/jukebox_side')), 2),
  'parrot': frag(load('item/parrot_spawn_egg')),
  'settings': frag(load('item/comparator')),
}
src = ("// Generated from the local Minecraft 1.21.8 install: four hotbar slots, the\n// selection frame and the slot icons, as SVG path fragments. Blocks are drawn\n"
       "// as the inventory draws them, at two pixels to the GUI pixel. © Mojang;\n// personal use only.\n\n"
       f"// The hotbar cut into one piece a slot, each to be drawn at [x, 1] in the region.\nexport const HOTBAR: [number, string][] = {json.dumps(pieces)}\n\nexport const SELECTION = {json.dumps(frag(load('gui/sprites/hud/hotbar_selection')))}\n\n"
       f"export const ICONS: Record<string, string> = {json.dumps(icons, indent=1)}\n")
open(sys.argv[1], 'w').write(src)
print(len(src), {k: len(v) for k, v in icons.items()}, load('gui/sprites/hud/hotbar_selection').size)
