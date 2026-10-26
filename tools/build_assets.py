"""Development tool: copies what the screens need out of the local Minecraft
install into assets/, renders block icons as the inventory draws them, and
writes hooks/advancements.ts from tools/advancements.py.
"""
import glob, io, json, math, os, subprocess, sys, zipfile
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from advancements import TABS, write

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MC = os.path.expanduser('~/Library/Application Support/minecraft')
jar = zipfile.ZipFile(f'{MC}/versions/1.21.8/1.21.8.jar')
T = 'assets/minecraft/textures/'
names = set(jar.namelist())
def load(p): return Image.open(io.BytesIO(jar.read(T + p + '.png'))).convert('RGBA')
def save(im, rel):
    path = os.path.join(ROOT, 'assets', rel); os.makedirs(os.path.dirname(path), exist_ok=True); im.save(path)
def copy(src, rel): save(load(src), rel)

# ---------- icons ----------
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
        r, g, bl, al = im.split(); f = lambda v: int(v * shade)
        out.alpha_composite(Image.merge('RGBA', (r.point(f), g.point(f), bl.point(f), al)))
    rows = int(round(16 * h))
    face(top, P(0, h, 0), P(1, h, 0), P(0, h, 1), 1.0)
    face(left.crop((0, 16 - rows, 16, 16)), P(0, h, 1), P(1, h, 1), P(0, 0, 1), .8)
    face(right.crop((0, 16 - rows, 16, 16)), P(1, h, 1), P(1, h, 0), P(1, 0, 1), .6)
    return out
def tinted(im, rgb):
    r, g, b, a = im.split()
    return Image.merge('RGBA', (r.point(lambda v: v * rgb[0] // 255), g.point(lambda v: v * rgb[1] // 255), b.point(lambda v: v * rgb[2] // 255), a))
B = lambda n: load('block/' + n)
grass_side = B('grass_block_side'); grass_side.alpha_composite(tinted(B('grass_block_side_overlay'), (124, 189, 107)))
BLOCKS = {
 'grass_block': lambda: iso(tinted(B('grass_block_top'), (124, 189, 107)), grass_side, grass_side),
 'crafting_table': lambda: iso(B('crafting_table_top'), B('crafting_table_front'), B('crafting_table_side')),
 'end_stone': lambda: iso(B('end_stone'), B('end_stone'), B('end_stone')),
 'hay_block': lambda: iso(B('hay_block_top'), B('hay_block_side'), B('hay_block_side')),
 'oak_log': lambda: iso(B('oak_log_top'), B('oak_log'), B('oak_log')),
 'soul_sand': lambda: iso(B('soul_sand'), B('soul_sand'), B('soul_sand')),
 'tnt': lambda: iso(B('tnt_top'), B('tnt_side'), B('tnt_side')),
 'jukebox': lambda: iso(B('jukebox_top'), B('jukebox_side'), B('jukebox_side')),
 'netherrack': lambda: iso(B('netherrack'), B('netherrack'), B('netherrack')),
 'note_block': lambda: iso(B('note_block'), B('note_block'), B('note_block')),
 'target': lambda: iso(B('target_top'), B('target_side'), B('target_side')),
}
P = {'.': None, 'k': '#1b1b1f', 'w': '#f2f2f2', 'g': '#80ff20', 'r': '#e8231c', 'R': '#8a1410', 'S': '#4a4a4a'}
CUSTOM = {
 'terminal': ['................','.kkkkkkkkkkkkkk.','.kSSSSSSSSSSSSk.','.kkkkkkkkkkkkkk.','.k............k.','.k.g..........k.','.k..g.........k.','.k...g........k.',
              '.k..g.........k.','.k.g...gggg...k.','.k............k.','.k............k.','.kkkkkkkkkkkkkk.','................','................','................'],
 'bug': ['................','...k........k...','....k......k....','.....kkkkkk.....','....krrrrrrk....','.k.krwkrrkwrk.k.','..kkrrrrrrrrkk..','...krrRRRRrrk...',
         '.kkkrrRRRRrrkkk.','...krrRRRRrrk...','..kkrrrrrrrrkk..','.k.krrrrrrrrk.k.','....krrrrrrk....','.....kkkkkk.....','................','................'],
}
def custom(rows):
    im = Image.new('RGBA', (16, 16), (0, 0, 0, 0))
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if P[c]: im.putpixel((x, y), tuple(int(P[c][i:i + 2], 16) for i in (1, 3, 5)) + (255,))
    return im
def heart(layers):
    im = Image.new('RGBA', (16, 16), (0, 0, 0, 0))
    for l in layers: im.alpha_composite(load('gui/sprites/hud/heart/' + l), (3, 3))
    return im
ALIAS = {'clock': 'clock_00', 'compass': 'compass_16', 'enchanted_golden_apple': 'golden_apple', 'map': 'filled_map'}
def icon(name):
    if name in BLOCKS: return BLOCKS[name]()
    if name in CUSTOM: return custom(CUSTOM[name])
    if name == 'heart_half': return heart(['container', 'half'])
    if name == 'heart_low': return heart(['container_blinking', 'half'])
    name = ALIAS.get(name, name)
    im = load(('item/' if T + 'item/' + name + '.png' in names else 'block/') + name)
    return im.crop((0, 0, im.width, im.width)) if im.height > im.width else im

wanted = {a['icon'] for _, _, items in TABS for a in items} | {
    'writable_book', 'spyglass', 'compass', 'armor_stand', 'paper', 'map', 'knowledge_book',
    'emerald', 'diamond', 'nether_star', 'ender_eye', 'experience_bottle', 'totem_of_undying', 'golden_apple',
    'jukebox', 'netherrack', 'note_block', 'grass_block', 'end_stone', 'water_bucket', 'painting', 'comparator'}
for name in sorted(wanted): save(icon(name), f'item/{name}.png')

# ---------- screens ----------
for p in ['gui/advancements/window', 'gui/container/crafting_table']:
    copy(p, p + '.png')
for bg in ['stone', 'nether', 'end', 'adventure', 'husbandry']: copy(f'gui/advancements/backgrounds/{bg}', f'gui/advancements/backgrounds/{bg}.png')
for p in sorted(names):
    # The advancement frames and boxes, the tabs along the top (the only side used), the slider.
    if p.endswith('.png') and ((p.startswith(T + 'gui/sprites/advancements/') and '/tab_' not in p) or p.startswith(T + 'gui/sprites/advancements/tab_above_left')
                               or p.startswith(T + 'gui/sprites/advancements/tab_above_middle')
                               or p.startswith(T + 'gui/sprites/widget/slider')):
        rel = p[len(T):]; copy(rel[:-4], rel)

# ---------- the jukebox: disc icons and their titles; the music itself stays in the install ----------
lang = json.loads(jar.read('assets/minecraft/lang/en_us.json'))
ORDER = ['13', 'cat', 'blocks', 'chirp', 'creator', 'creator_music_box', 'far', 'lava_chicken', 'mall', 'mellohi', 'stal', 'strad', 'ward', '11', 'wait', 'otherside', 'relic', '5', 'pigstep', 'precipice', 'tears']
discs = [d for d in ORDER if f'jukebox_song.minecraft.{d}' in lang]
for d in discs: save(icon(f'music_disc_{d}'), f'item/music_disc_{d}.png')
json.dump([dict(id=d, title=lang[f'jukebox_song.minecraft.{d}']) for d in discs], open(os.path.join(ROOT, 'assets', 'music.json'), 'w'), ensure_ascii=False, indent=1)
copy('particle/note', 'particle/note.png')
# The guide draws the HUD itself, so it needs the HUD's own sprites, and the tutorial toasts their frame.
for s in ['heart/container', 'heart/full', 'heart/half', 'food_empty', 'food_full', 'food_half', 'experience_bar_background', 'experience_bar_progress', 'hotbar']:
    copy(f'gui/sprites/hud/{s}', f'gui/sprites/hud/{s}.png')
copy('gui/sprites/toast/tutorial', 'gui/sprites/toast/tutorial.png')
copy('gui/sprites/container/slot', 'gui/sprites/container/slot.png')
# The parrot: its five coats, its spawn egg for the hotbar.
for v in ['red_blue', 'blue', 'green', 'yellow_blue', 'grey']: copy(f'entity/parrot/parrot_{v}', f'entity/parrot/parrot_{v}.png')
copy('item/parrot_spawn_egg', 'item/parrot_spawn_egg.png')

# ---------- sounds ----------
objects = json.load(open(sorted(glob.glob(f'{MC}/assets/indexes/*.json'))[-1]))['objects']
for key, out in [*[(f'minecraft/sounds/mob/parrot/idle{i}.ogg', f'parrot{i}') for i in range(1, 7)], ('minecraft/sounds/mob/parrot/fly1.ogg', 'parrot_fly')]:
    h = objects[key]['hash']
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', f'{MC}/assets/objects/{h[:2]}/{h}', os.path.join(ROOT, 'assets', 'sounds', out + '.wav')], check=True)

# ---------- hooks/advancements.ts ----------
print(write(len(discs)), 'advancements,', len(wanted), 'icons')
