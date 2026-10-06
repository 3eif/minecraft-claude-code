"""Development tool: copies what the screens need out of the local Minecraft
install into assets/, renders block icons as the inventory draws them, and
writes hooks/advancements.ts from the list below. Run after changing the list.
"""
import glob, io, json, math, os, subprocess, zipfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MC = os.path.expanduser('~/Library/Application Support/minecraft')
jar = zipfile.ZipFile(f'{MC}/versions/1.21.8/1.21.8.jar')
T = 'assets/minecraft/textures/'
names = set(jar.namelist())
def load(p): return Image.open(io.BytesIO(jar.read(T + p + '.png'))).convert('RGBA')
def save(im, rel):
    path = os.path.join(ROOT, 'assets', rel); os.makedirs(os.path.dirname(path), exist_ok=True); im.save(path)
def copy(src, rel): save(load(src), rel)

# (id, parent, name, frame, icon, description, counter, need, secret)
def A(i, parent, name, frame, icon, desc, counter=None, need=1, secret=False):
    return dict(id=i, parent=parent, name=name, frame=frame, icon=icon, desc=desc, counter=counter, need=need, secret=secret)
TABS = [
 ('Claude Code', 'stone', [
  A('root', None, 'Claude Code', 'task', 'grass_block', 'Send your first prompt.', 'prompts'),
  A('stone', 'root', 'Stone Age', 'task', 'wooden_pickaxe', 'Have Claude edit a file for you.', 'edits'),
  A('upgrade', 'stone', 'Getting an Upgrade', 'task', 'stone_pickaxe', 'Have Claude make 1,000 edits.', 'edits', 1000),
  A('diamonds', 'upgrade', 'Diamonds!', 'goal', 'diamond', 'After 10+ edits, run the tests and have them pass first time.'),
  A('cover', 'diamonds', 'Cover Me with Diamonds', 'challenge', 'diamond_chestplate', 'Have a test run pass 100 times.', 'passes', 100),
  A('debris', 'cover', 'Cover Me in Debris', 'challenge', 'netherite_chestplate', 'Change 10,000 lines in a single reply.', secret=True),
  A('zombie', 'diamonds', 'Zombie Doctor', 'goal', 'golden_apple', 'Make a failing test run pass, 25 times.', 'cures', 25),
  A('arbalistic', 'zombie', 'Arbalistic', 'challenge', 'crossbow_firework', 'In a single reply, go from 25 or more failing tests to all passing.', secret=True),
  A('hardware', 'root', 'Acquire Hardware', 'task', 'terminal', 'Have Claude run a terminal command.', 'commands'),
  A('hot', 'hardware', 'Hot Stuff', 'task', 'lava_bucket', 'Have a terminal command fail.', 'failures'),
  A('committed', 'hardware', 'Committed', 'task', 'writable_book', 'Have Claude make a git commit.', 'commits'),
  A('relationship', 'committed', 'Committed Relationship', 'goal', 'cake', 'Make a git commit on five days in a row.', 'commitStreak', 5),
  A('frightening', 'committed', 'Very Very Frightening', 'challenge', 'trident', 'Have Claude force-push to main.', secret=True),
  A('sender', 'committed', 'Return to Sender', 'challenge', 'fire_charge', 'Revert a commit, then get the tests passing and commit again, all in one chat.', secret=True),
  A('ship', 'committed', 'Ship It', 'goal', 'firework_rocket', 'Have Claude open a pull request.', 'prs'),
  A('twobirds', 'ship', 'Two Birds, One Arrow', 'challenge', 'spectral_arrow', 'In a single reply: edit, pass the tests, commit and open a pull request.'),
  A('merged', 'ship', 'Merged', 'challenge', 'emerald', 'Merge 25 pull requests with gh.', 'merges', 25),
  A('bench', 'root', 'Bookworm', 'task', 'written_book', 'Use a skill from the skill book.', 'skillsUsed'),
  A('librarian', 'bench', 'Librarian', 'goal', 'bookshelf', 'Use skills from the skill book 50 times.', 'skillsUsed', 50),
  A('enchanter', 'root', 'Enchanter', 'task', 'enchanted_book', 'Rewrite a prompt at the enchanting table.', 'enchants'),
 ]),
 ('Context', 'nether', [
  A('root', None, 'Context', 'task', 'bread', 'See your context window as a hunger bar.'),
  A('home', 'root', 'Half Full', 'task', 'campfire', 'Use half the context window in a chat.'),
  A('fire', 'home', 'Into Fire', 'goal', 'blaze_powder', 'Fill the context past 85% in ten different chats.', 'starves', 10),
  A('howdid', 'fire', 'How Did We Get Here?', 'challenge', 'bucket', 'Context and usage both over 90%, with bypass permissions on and three subagents running.', secret=True),
  A('apple', 'root', 'An Apple a Day', 'task', 'apple', 'Compact a chat, by hand or with /compact.', 'compacts'),
  A('nine', 'apple', 'Not Quite "Nine" Lives', 'goal', 'golden_carrot', 'Let Claude compact the chat automatically nine times.', 'autos', 9),
  A('cocktail', 'apple', 'Second Helpings', 'challenge', 'milk_bucket', 'Compact a chat 100 times.', 'compacts', 100),
 ]),
 ('The Limit', 'end', [
  A('root', None, 'The Limit', 'task', 'end_stone', 'See your usage limit as hearts.'),
  A('scratch', 'root', 'Just a Scratch', 'task', 'sweet_berries', 'Use your first half-heart of usage limit.'),
  A('half', 'scratch', 'Half a Life', 'task', 'heart_half', 'Use half your usage limit, in ten different limit periods.', 'halves', 10),
  A('edge', 'half', 'Living on the Edge', 'goal', 'heart_low', 'Use 80% of your usage limit, in ten different limit periods.', 'edges', 10),
  A('bell', 'edge', 'Saved by the Bell', 'goal', 'bell', 'Reach your limit reset with under 10% left.'),
  A('end', 'edge', 'The End?', 'goal', 'ender_eye', 'Hit your usage limit.', 'deaths'),
  A('postmortal', 'end', 'Postmortal', 'goal', 'totem_of_undying', 'Get your limit back after hitting it.', 'respawns'),
  A('anchor', 'postmortal', 'Respawn Anchor', 'challenge', 'glowstone_dust', 'Hit your limit and come back after the reset, ten times.', 'respawns', 10),
  A('gameover', 'end', 'Game Over', 'challenge', 'bone', 'Hit your usage limit within an hour of a limit period starting, with bypass permissions on.', secret=True),
 ]),
 ('Adventure', 'adventure', [
  A('root', None, 'Adventure', 'task', 'map', 'Watch Claude use one of its tools.', 'tools'),
  A('betsy', 'root', "Ol' Betsy", 'task', 'crossbow_standby', 'Have Claude run 2,500 terminal commands.', 'commands', 2500),
  A('arbalistic', 'betsy', 'Power Tools', 'challenge', 'crossbow_arrow', 'Have Claude use its tools 10,000 times.', 'tools', 10000),
  A('deeper', 'root', 'We Need to Go Deeper', 'task', 'flint_and_steel', 'Have Claude start a subagent.', 'agents'),
  A('help', 'deeper', 'Hired Help', 'goal', 'armor_stand', 'Have Claude start five subagents in a single reply.'),
  A('bird', 'root', 'Is It a Bird?', 'task', 'spyglass', 'Have Claude look at an image.'),
  A('balloon', 'bird', 'Surfing the Web', 'goal', 'compass', 'Have Claude fetch 100 web pages.', 'fetches', 100),
  A('deal', 'root', 'What a Deal!', 'goal', 'emerald', 'Answer 100 questions from Claude.', 'questions', 100),
  A('hunter', 'root', 'Monster Hunter', 'task', 'bug', 'Run tests and have them fail.', 'testFails'),
  A('sticky', 'root', 'Sticky Situation', 'task', 'slime_ball', 'Run into a git merge conflict.'),
  A('lock', 'root', 'Under Lock and Key', 'challenge', 'tripwire_hook', 'Run 1,000 commands in one chat without a single one failing.', secret=True),
  A('exile', 'root', 'Voluntary Exile', 'challenge', 'tnt', 'Delete 10,000 lines in a single reply.', secret=True),
  A('hero', 'root', 'Hero of the Village', 'challenge', 'bell', 'Have Claude make 500 tool calls in a single reply.', secret=True),
  A('bullseye', 'root', 'Bullseye', 'challenge', 'target', 'Hear Claude say "You\'re absolutely right".', secret=True),
  A('music', 'root', 'Sound of Music', 'task', 'jukebox', 'Play a music disc in the jukebox.', 'discs'),
  A('ears', 'music', 'Music to My Ears', 'challenge', 'music_disc_cat', 'Play every music disc in the jukebox.', 'discsHeard', 21),
  A('brewery', 'root', 'Local Brewery', 'task', 'potion', 'Brew a potion at the brewing stand.', 'brews'),
  A('cocktail', 'brewery', 'A Furious Cocktail', 'challenge', 'splash_potion', 'Brew every kind of potion: all five models.', 'potionKinds', 5),
  A('tourist', 'root', 'Hot Tourist Destinations', 'goal', 'filled_map', 'Open the map with 10 folders explored in one chat.'),
  A('adventuring', 'tourist', 'Adventuring Time', 'challenge', 'diamond_boots', 'Explore every island on a map of 5 or more in one chat.'),
 ]),
 ('Habits', 'husbandry', [
  A('root', None, 'Habits', 'task', 'hay_block', 'Get your first reply from Claude.', 'turns'),
  A('wood', 'root', 'Getting Wood', 'task', 'oak_log', 'Use 10 million tokens, across all your chats.', 'tokens', 10_000),
  A('mine', 'wood', 'Time to Mine!', 'task', 'diamond_pickaxe', 'Use 100 million tokens.', 'tokens', 100_000),
  A('strike', 'mine', 'Time to Strike!', 'goal', 'netherite_sword', 'Use 1 billion tokens.', 'tokens', 1_000_000),
  A('beginq', 'strike', 'The Beginning?', 'challenge', 'soul_sand', 'Use 5 billion tokens.', 'tokens', 5_000_000),
  A('begin', 'beginq', 'The Beginning.', 'challenge', 'nether_star', 'Use 10 billion tokens.', 'tokens', 10_000_000),
  A('overpowered', 'begin', 'Overpowered', 'challenge', 'enchanted_golden_apple', 'Use 1 billion tokens in a single day.', secret=True),
  A('goat', 'root', 'Whatever Floats Your Goat!', 'task', 'goat_horn', 'Reach XP level 10.', 'level', 10),
  A('powers', 'goat', 'With Our Powers Combined!', 'challenge', 'experience_bottle', 'Reach XP level 50.', 'level', 50),
  A('friend', 'root', "You've Got a Friend in Me", 'task', 'cookie', 'Use Claude Code on three days in a row.', 'dayStreak', 3),
  A('bff', 'friend', 'Best Friends Forever', 'challenge', 'lead', 'Use Claude Code on 30 days in a row.', 'dayStreak', 30),
  A('birthday', 'bff', 'Birthday Song', 'challenge', 'cake', 'Use Claude Code a year after your first day with this mod.'),
  A('fishy', 'root', 'Early Bird', 'task', 'fishing_rod', 'Work with Claude before 7 a.m. on 25 days.', 'earlies', 25),
  A('dreams', 'fishy', 'Night Owl', 'task', 'clock', 'Work with Claude after midnight on 25 nights.', 'lates', 25),
  A('sleep', 'dreams', 'Who Needs Sleep?', 'challenge', 'phantom_membrane', 'Work with Claude every hour from midnight to 6 a.m.', secret=True),
  A('bee', 'root', 'Bee Our Guest', 'task', 'honey_bottle', 'Say please or thank you to Claude 500 times.', 'polite', 500),
  A('serious', 'root', 'Serious Dedication', 'challenge', 'netherite_hoe', 'Get 200 replies from Claude in a single chat.'),
 ]),
]

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
 'enchanting_table': lambda: iso(B('enchanting_table_top'), B('enchanting_table_side'), B('enchanting_table_side'), .75),
 'bookshelf': lambda: iso(B('oak_planks'), B('bookshelf'), B('bookshelf')),
 'end_stone': lambda: iso(B('end_stone'), B('end_stone'), B('end_stone')),
 'hay_block': lambda: iso(B('hay_block_top'), B('hay_block_side'), B('hay_block_side')),
 'oak_log': lambda: iso(B('oak_log_top'), B('oak_log'), B('oak_log')),
 'soul_sand': lambda: iso(B('soul_sand'), B('soul_sand'), B('soul_sand')),
 'tnt': lambda: iso(B('tnt_top'), B('tnt_side'), B('tnt_side')),
 'jukebox': lambda: iso(B('jukebox_top'), B('jukebox_side'), B('jukebox_side')),
 'lectern': lambda: iso(B('lectern_top'), B('lectern_front'), B('lectern_sides'), .85),
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
    'writable_book', 'spyglass', 'compass', 'armor_stand', 'paper', 'map', 'knowledge_book', 'lapis_lazuli',
    'enchanting_table', 'emerald', 'diamond', 'nether_star', 'ender_eye', 'experience_bottle', 'totem_of_undying', 'golden_apple',
    'jukebox', 'netherrack', 'note_block', 'grass_block', 'end_stone', 'water_bucket', 'painting', 'comparator'}
for name in sorted(wanted): save(icon(name), f'item/{name}.png')

# ---------- screens ----------
for p in ['gui/advancements/window', 'gui/container/crafting_table', 'gui/container/enchanting_table', 'font/ascii_sga']:
    copy(p, p + '.png')
for bg in ['stone', 'nether', 'end', 'adventure', 'husbandry']: copy(f'gui/advancements/backgrounds/{bg}', f'gui/advancements/backgrounds/{bg}.png')
for p in sorted(names):
    # The advancement frames and boxes, the tabs along the top (the only side used), the enchanting table's offers, the slider.
    if p.endswith('.png') and ((p.startswith(T + 'gui/sprites/advancements/') and '/tab_' not in p) or p.startswith(T + 'gui/sprites/advancements/tab_above_left')
                               or p.startswith(T + 'gui/sprites/advancements/tab_above_middle') or p.startswith(T + 'gui/sprites/container/enchanting_table/')
                               or p.startswith(T + 'gui/sprites/widget/slider')):
        rel = p[len(T):]; copy(rel[:-4], rel)

# ---------- the jukebox: disc icons and their titles; the music itself stays in the install ----------
lang = json.loads(jar.read('assets/minecraft/lang/en_us.json'))
ORDER = ['13', 'cat', 'blocks', 'chirp', 'creator', 'creator_music_box', 'far', 'lava_chicken', 'mall', 'mellohi', 'stal', 'strad', 'ward', '11', 'wait', 'otherside', 'relic', '5', 'pigstep', 'precipice', 'tears']
discs = [d for d in ORDER if f'jukebox_song.minecraft.{d}' in lang]
for _, _, items in TABS:
    for a in items:
        if a['counter'] == 'discsHeard': a['need'] = len(discs)
for d in discs: save(icon(f'music_disc_{d}'), f'item/music_disc_{d}.png')
json.dump([dict(id=d, title=lang[f'jukebox_song.minecraft.{d}']) for d in discs], open(os.path.join(ROOT, 'assets', 'music.json'), 'w'), ensure_ascii=False, indent=1)
copy('particle/note', 'particle/note.png')
# The guide draws the HUD itself, so it needs the HUD's own sprites, and the tutorial toasts their frame.
for s in ['heart/container', 'heart/full', 'heart/half', 'food_empty', 'food_full', 'food_half', 'experience_bar_background', 'experience_bar_progress', 'hotbar']:
    copy(f'gui/sprites/hud/{s}', f'gui/sprites/hud/{s}.png')
copy('gui/sprites/toast/tutorial', 'gui/sprites/toast/tutorial.png')
copy('gui/book', 'gui/book.png')
for s in ['page_forward', 'page_forward_highlighted', 'page_backward', 'page_backward_highlighted']: copy(f'gui/sprites/widget/{s}', f'gui/sprites/widget/{s}.png')
copy('gui/sprites/container/slot', 'gui/sprites/container/slot.png')
# The map: its parchment and the markers drawn on it.
copy('map/map_background', 'map/map_background.png')
for s in ['player', 'red_banner', 'red_x']: copy(f'map/decorations/{s}', f'map/decorations/{s}.png')
copy('item/filled_map', 'item/filled_map.png')
# The parrot: its five coats, its spawn egg for the hotbar.
for v in ['red_blue', 'blue', 'green', 'yellow_blue', 'grey']: copy(f'entity/parrot/parrot_{v}', f'entity/parrot/parrot_{v}.png')
copy('item/parrot_spawn_egg', 'item/parrot_spawn_egg.png')
# The brewing stand: its window, bubbles and arrow, and the potion bottle with its tintable overlay.
copy('gui/container/brewing_stand', 'gui/container/brewing_stand.png')
for s in ['bubbles', 'brew_progress', 'fuel_length']: copy(f'gui/sprites/container/brewing_stand/{s}', f'gui/sprites/container/brewing_stand/{s}.png')
for s in ['potion', 'splash_potion', 'potion_overlay', 'glowstone_dust', 'blaze_powder', 'brewing_stand']: copy(f'item/{s}', f'item/{s}.png')

# ---------- sounds ----------
objects = json.load(open(sorted(glob.glob(f'{MC}/assets/indexes/*.json'))[-1]))['objects']
for key, out in [*[(f'minecraft/sounds/mob/parrot/idle{i}.ogg', f'parrot{i}') for i in range(1, 7)], ('minecraft/sounds/mob/parrot/fly1.ogg', 'parrot_fly'), ('minecraft/sounds/block/brewing_stand/brew1.ogg', 'brew1'), ('minecraft/sounds/block/brewing_stand/brew2.ogg', 'brew2'), ('minecraft/sounds/item/bottle/fill1.ogg', 'bottle'), ('minecraft/sounds/block/enchantment_table/enchant1.ogg', 'enchant1'), ('minecraft/sounds/block/enchantment_table/enchant2.ogg', 'enchant2'), ('minecraft/sounds/block/enchantment_table/enchant3.ogg', 'enchant3')]:
    h = objects[key]['hash']
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', f'{MC}/assets/objects/{h[:2]}/{h}', os.path.join(ROOT, 'assets', 'sounds', out + '.wav')], check=True)

# ---------- hooks/advancements.ts ----------
out = ['// Generated by tools/build_assets.py from the list there. Each advancement is',
       '// earned once, ever. One with a `counter` is earned when that lifetime count',
       '// reaches `need`; the rest are awarded by name where they happen.', '',
       'export type Advancement = { id: string; tab: number; parent: string | null; name: string; frame: string; icon: string; desc: string; counter: string | null; need: number; secret: boolean }', '',
       f'export const TABS = {json.dumps([dict(name=n, bg=b, icon=items[0]["icon"]) for n, b, items in TABS])}', '',
       'export const ADVANCEMENTS: Advancement[] = [']
for ti, (_, _, items) in enumerate(TABS):
    for a in items:
        d = dict(a); d['id'] = f'{ti}.{a["id"]}'; d['tab'] = ti; d['parent'] = f'{ti}.{a["parent"]}' if a['parent'] else None
        out.append(' ' + json.dumps({k: d[k] for k in ['id', 'tab', 'parent', 'name', 'frame', 'icon', 'desc', 'counter', 'need', 'secret']}) + ',')
out.append(']')
open(os.path.join(ROOT, 'hooks', 'advancements.ts'), 'w').write('\n'.join(out) + '\n')
print(sum(len(i) for _, _, i in TABS), 'advancements,', len(wanted), 'icons')
