"""Development tool: the advancement list, and hooks/advancements.ts written from
it. Needs nothing but Python; build_assets.py reads the list for its icons.

Each chain starts easy and runs deep: its last tiers take a heavy user months.
An id once shipped keeps its meaning, since what has been earned stays earned.
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (id, parent, name, frame, icon, description, counter, need, secret)
def A(i, parent, name, frame, icon, desc, counter=None, need=1, secret=False):
    return dict(id=i, parent=parent, name=name, frame=frame, icon=icon, desc=desc, counter=counter, need=need, secret=secret)
TABS = [
 ('Claude Code', 'stone', [
  A('root', None, 'Claude Code', 'task', 'grass_block', 'Send your first prompt.', 'prompts'),
  A('stone', 'root', 'Stone Age', 'task', 'wooden_pickaxe', 'Have Claude edit a file for you.', 'edits'),
  A('upgrade', 'stone', 'Getting an Upgrade', 'task', 'stone_pickaxe', 'Have Claude make 1,000 edits.', 'edits', 1000),
  A('iron', 'upgrade', "Isn't It Iron Pick", 'goal', 'iron_pickaxe', 'Have Claude make 10,000 edits.', 'edits', 10_000),
  A('depths', 'iron', 'Hidden in the Depths', 'challenge', 'netherite_pickaxe', 'Have Claude make 100,000 edits.', 'edits', 100_000),
  A('diamonds', 'upgrade', 'Diamonds!', 'goal', 'diamond', 'After 10+ edits, run the tests and have them pass first time.'),
  A('sniper', 'diamonds', 'Sniper Duel', 'goal', 'bow', 'In a single reply, have a test run fail and then pass.'),
  A('cover', 'diamonds', 'Cover Me with Diamonds', 'goal', 'diamond_chestplate', 'Have a test run pass 100 times.', 'passes', 100),
  A('trim', 'cover', 'Smithing with Style', 'challenge', 'netherite_upgrade_smithing_template', 'Have a test run pass 10,000 times.', 'passes', 10_000),
  A('debris', 'cover', 'Cover Me in Debris', 'challenge', 'netherite_chestplate', 'Change 10,000 lines in a single reply.', secret=True),
  A('zombie', 'diamonds', 'Zombie Doctor', 'goal', 'golden_apple', 'Make a failing test run pass, 25 times.', 'cures', 25),
  A('cured', 'zombie', 'Good as New', 'challenge', 'enchanted_golden_apple', 'Make a failing test run pass, 1,000 times.', 'cures', 1000),
  A('arbalistic', 'zombie', 'Arbalistic', 'challenge', 'crossbow_firework', 'In a single reply, go from 25 or more failing tests to all passing.', secret=True),
  A('hardware', 'root', 'Acquire Hardware', 'task', 'terminal', 'Have Claude run a terminal command.', 'commands'),
  A('hot', 'hardware', 'Hot Stuff', 'task', 'lava_bucket', 'Have a terminal command fail.', 'failures'),
  A('committed', 'hardware', 'Committed', 'task', 'writable_book', 'Have Claude make a git commit.', 'commits'),
  A('days', 'committed', 'Those Were the Days', 'goal', 'brick', 'Have Claude make 5,000 git commits.', 'commits', 5000),
  A('remnants', 'days', 'Respecting the Remnants', 'challenge', 'brush', 'Have Claude make 50,000 git commits.', 'commits', 50_000),
  A('relationship', 'committed', 'Committed Relationship', 'goal', 'cake', 'Make a git commit on five days in a row.', 'commitStreak', 5),
  A('lode', 'relationship', 'Country Lode, Take Me Home', 'challenge', 'map', 'Make a git commit on 60 days in a row.', 'commitStreak', 60),
  A('frightening', 'committed', 'Very Very Frightening', 'challenge', 'trident', 'Have Claude force-push to main.', secret=True),
  A('sender', 'committed', 'Return to Sender', 'challenge', 'fire_charge', 'Revert a commit, then get the tests passing and commit again, all in one chat.', secret=True),
  A('ship', 'committed', 'Ship It', 'goal', 'firework_rocket', 'Have Claude open a pull request.', 'prs'),
  A('boat', 'ship', 'This Boat Has Legs', 'goal', 'oak_boat', 'Have Claude open 2,500 pull requests.', 'prs', 2500),
  A('twobirds', 'ship', 'Two Birds, One Arrow', 'challenge', 'spectral_arrow', 'In a single reply: edit, pass the tests, commit and open a pull request.'),
  A('merged', 'ship', 'Merged', 'goal', 'emerald', 'Merge 25 pull requests with gh.', 'merges', 25),
  A('beacon', 'merged', 'Bring Home the Beacon', 'goal', 'end_crystal', 'Merge 1,000 pull requests with gh.', 'merges', 1000),
  A('beaconator', 'beacon', 'Beaconator', 'challenge', 'nether_star', 'Merge 10,000 pull requests with gh.', 'merges', 10_000),
 ]),
 ('Context', 'nether', [
  A('root', None, 'Context', 'task', 'bread', 'See your context window as a hunger bar.'),
  A('home', 'root', 'Half Full', 'task', 'campfire', 'Use half the context window in a chat.'),
  A('ice', 'home', 'Ice Bucket Challenge', 'goal', 'water_bucket', 'Fill the context window to 99%.'),
  A('fire', 'home', 'Into Fire', 'goal', 'blaze_powder', 'Fill the context past 85% in ten different chats.', 'starves', 10),
  A('feels', 'fire', 'Feels Like Home', 'challenge', 'netherrack', 'Fill the context past 85% in 1,000 different chats.', 'starves', 1000),
  A('howdid', 'fire', 'How Did We Get Here?', 'challenge', 'bucket', 'Context and usage both over 90%, with bypass permissions on and three subagents running.', secret=True),
  A('apple', 'root', 'An Apple a Day', 'task', 'apple', 'Compact a chat, by hand or with /compact.', 'compacts'),
  A('nine', 'apple', 'Not Quite "Nine" Lives', 'goal', 'golden_carrot', 'Let Claude compact the chat automatically nine times.', 'autos', 9),
  A('cocktail', 'apple', 'Second Helpings', 'goal', 'milk_bucket', 'Compact a chat 100 times.', 'compacts', 100),
  A('diet', 'cocktail', 'A Balanced Diet', 'challenge', 'pumpkin_pie', 'Compact a chat 5,000 times.', 'compacts', 5000),
 ]),
 ('The Limit', 'end', [
  A('root', None, 'The Limit', 'task', 'end_stone', 'See your usage limit as hearts.'),
  A('scratch', 'root', 'Just a Scratch', 'task', 'sweet_berries', 'Use your first half-heart of usage limit.'),
  A('half', 'scratch', 'Half a Life', 'task', 'heart_half', 'Use half your usage limit, in ten different limit periods.', 'halves', 10),
  A('edge', 'half', 'Living on the Edge', 'goal', 'heart_low', 'Use 80% of your usage limit, in ten different limit periods.', 'edges', 10),
  A('alliance', 'edge', 'Uneasy Alliance', 'challenge', 'ghast_tear', 'Use 80% of your usage limit, in 250 different limit periods.', 'edges', 250),
  A('bell', 'edge', 'Saved by the Bell', 'goal', 'bell', 'Reach your limit reset with under 10% left.'),
  A('end', 'edge', 'The End?', 'goal', 'ender_eye', 'Hit your usage limit.', 'deaths'),
  A('withering', 'end', 'Withering Heights', 'challenge', 'nether_star', 'Hit your 5-hour limit and your weekly limit in the same week.'),
  A('postmortal', 'end', 'Postmortal', 'goal', 'totem_of_undying', 'Get your limit back after hitting it.', 'respawns'),
  A('anchor', 'postmortal', 'Respawn Anchor', 'goal', 'glowstone_dust', 'Hit your limit and come back after the reset, ten times.', 'respawns', 10),
  A('again', 'anchor', 'The End... Again...', 'challenge', 'dragon_breath', 'Hit your limit and come back after the reset, 250 times.', 'respawns', 250),
  A('gameover', 'end', 'Game Over', 'challenge', 'bone', 'Hit your usage limit within an hour of a limit period starting, with bypass permissions on.', secret=True),
 ]),
 ('Adventure', 'adventure', [
  A('root', None, 'Adventure', 'task', 'map', 'Watch Claude use one of its tools.', 'tools'),
  A('betsy', 'root', "Ol' Betsy", 'task', 'crossbow_standby', 'Have Claude run 2,500 terminal commands.', 'commands', 2500),
  A('surge', 'betsy', 'Surge Protector', 'goal', 'redstone', 'Have Claude run 250,000 terminal commands.', 'commands', 250_000),
  A('overkill', 'surge', 'Over-Overkill', 'challenge', 'mace', 'Have Claude run 2.5 million terminal commands.', 'commands', 2_500_000),
  A('arbalistic', 'betsy', 'Power Tools', 'goal', 'crossbow_arrow', 'Have Claude use its tools 10,000 times.', 'tools', 10_000),
  A('rockets', 'arbalistic', 'Who Needs Rockets?', 'challenge', 'wind_charge', 'Have Claude use its tools 5 million times.', 'tools', 5_000_000),
  A('deeper', 'root', 'We Need to Go Deeper', 'task', 'flint_and_steel', 'Have Claude start a subagent.', 'agents'),
  A('help', 'deeper', 'Hired Help', 'goal', 'armor_stand', 'Have Claude start five subagents in a single reply.'),
  A('bubble', 'deeper', 'Subspace Bubble', 'challenge', 'ender_pearl', 'Have Claude start 25,000 subagents.', 'agents', 25_000),
  A('bird', 'root', 'Is It a Bird?', 'task', 'spyglass', 'Have Claude look at an image.'),
  A('balloon', 'bird', 'Surfing the Web', 'goal', 'compass', 'Have Claude fetch 100 web pages.', 'fetches', 100),
  A('plane', 'balloon', 'Is It a Plane?', 'challenge', 'feather', 'Have Claude fetch 25,000 web pages.', 'fetches', 25_000),
  A('deal', 'root', 'What a Deal!', 'goal', 'emerald', 'Answer 100 questions from Claude.', 'questions', 100),
  A('pillager', 'deal', "Who's the Pillager Now?", 'challenge', 'ominous_bottle', 'Answer 5,000 questions from Claude.', 'questions', 5000),
  A('hunter', 'root', 'Monster Hunter', 'task', 'bug', 'Run tests and have them fail.', 'testFails'),
  A('hunted', 'hunter', 'Monsters Hunted', 'challenge', 'diamond_sword', 'Run tests and have them fail, 5,000 times.', 'testFails', 5000),
  A('sticky', 'root', 'Sticky Situation', 'task', 'slime_ball', 'Run into a git merge conflict.'),
  A('lock', 'root', 'Under Lock and Key', 'challenge', 'tripwire_hook', 'Run 1,000 commands in one chat without a single one failing.', secret=True),
  A('exile', 'root', 'Voluntary Exile', 'challenge', 'tnt', 'Delete 10,000 lines in a single reply.', secret=True),
  A('hero', 'root', 'Hero of the Village', 'challenge', 'bell', 'Have Claude make 500 tool calls in a single reply.', secret=True),
  A('bullseye', 'root', 'Bullseye', 'challenge', 'target', 'Hear Claude say "You\'re absolutely right".', secret=True),
  A('music', 'root', 'Sound of Music', 'task', 'jukebox', 'Play a music disc in the jukebox.', 'discs'),
  A('ears', 'music', 'Music to My Ears', 'challenge', 'music_disc_cat', 'Play every music disc in the jukebox.', 'discsHeard', 21),
  A('parrots', 'music', 'The Parrots and the Bats', 'goal', 'parrot_spawn_egg', 'Play the jukebox with your parrot out.'),
  A('tourist', 'root', 'Hot Tourist Destinations', 'goal', 'filled_map', 'Have Claude work in 25 different folders in one chat.'),
  A('adventuring', 'tourist', 'Adventuring Time', 'challenge', 'diamond_boots', 'Have Claude work in 150 different folders in one chat.'),
 ]),
 ('Habits', 'husbandry', [
  A('root', None, 'Habits', 'task', 'hay_block', 'Get your first reply from Claude.', 'turns'),
  A('seedy', 'root', 'A Seedy Place', 'goal', 'wheat_seeds', 'Send 10,000 prompts.', 'prompts', 10_000),
  A('past', 'seedy', 'Planting the Past', 'challenge', 'torchflower_seeds', 'Send 250,000 prompts.', 'prompts', 250_000),
  A('wood', 'root', 'Getting Wood', 'task', 'oak_log', 'Use 10 million tokens, across all your chats.', 'tokens', 10_000),
  A('mine', 'wood', 'Time to Mine!', 'task', 'diamond_pickaxe', 'Use 100 million tokens.', 'tokens', 100_000),
  A('strike', 'mine', 'Time to Strike!', 'goal', 'netherite_sword', 'Use 1 billion tokens.', 'tokens', 1_000_000),
  A('beginq', 'strike', 'The Beginning?', 'goal', 'soul_sand', 'Use 5 billion tokens.', 'tokens', 5_000_000),
  A('begin', 'beginq', 'The Beginning.', 'goal', 'nether_star', 'Use 10 billion tokens.', 'tokens', 10_000_000),
  A('getaway', 'begin', 'Remote Getaway', 'challenge', 'ender_pearl', 'Use 250 billion tokens.', 'tokens', 250_000_000),
  A('sky', 'getaway', "Sky's the Limit", 'challenge', 'elytra', 'Use 1 trillion tokens.', 'tokens', 1_000_000_000),
  A('overpowered', 'begin', 'Overpowered', 'challenge', 'enchanted_golden_apple', 'Use 1 billion tokens in a single day.', secret=True),
  A('goat', 'root', 'Whatever Floats Your Goat!', 'task', 'goat_horn', 'Reach XP level 10.', 'level', 10),
  A('powers', 'goat', 'With Our Powers Combined!', 'goal', 'experience_bottle', 'Reach XP level 50.', 'level', 50),
  A('eyespy', 'powers', 'Eye Spy', 'challenge', 'ender_eye', 'Reach XP level 75.', 'level', 75),
  A('nextgen', 'eyespy', 'The Next Generation', 'challenge', 'end_crystal', 'Reach XP level 100.', 'level', 100),
  A('friend', 'root', "You've Got a Friend in Me", 'task', 'cookie', 'Use Claude Code on three days in a row.', 'dayStreak', 3),
  A('bff', 'friend', 'Best Friends Forever', 'goal', 'lead', 'Use Claude Code on 30 days in a row.', 'dayStreak', 30),
  A('twobytwo', 'bff', 'Two by Two', 'challenge', 'wheat', 'Use Claude Code on 200 days in a row.', 'dayStreak', 200),
  A('birthday', 'bff', 'Birthday Song', 'challenge', 'cake', 'Use Claude Code a year after your first day with this mod.'),
  A('fishy', 'root', 'Early Bird', 'task', 'fishing_rod', 'Work with Claude before 7 a.m. on 25 days.', 'earlies', 25),
  A('dreams', 'fishy', 'Night Owl', 'task', 'clock', 'Work with Claude after midnight on 25 nights.', 'lates', 25),
  A('sleep', 'dreams', 'Who Needs Sleep?', 'challenge', 'phantom_membrane', 'Work with Claude every hour from midnight to 6 a.m.', secret=True),
  A('bee', 'root', 'Bee Our Guest', 'task', 'honey_bottle', 'Say please or thank you to Claude 500 times.', 'polite', 500),
  A('beelocation', 'bee', 'Total Beelocation', 'challenge', 'honeycomb', 'Say please or thank you to Claude 25,000 times.', 'polite', 25_000),
  A('serious', 'root', 'Serious Dedication', 'challenge', 'netherite_hoe', 'Get 200 replies from Claude in a single chat.'),
 ]),
]


def write(discs=None):
    """Writes hooks/advancements.ts; `discs`, when given, is how many music discs there are."""
    if discs:
        for _, _, items in TABS:
            for a in items:
                if a['counter'] == 'discsHeard': a['need'] = discs
    out = ['// Generated by tools/advancements.py from the list there. Each advancement is',
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
    return sum(len(i) for _, _, i in TABS)


if __name__ == '__main__':
    print(write(), 'advancements')
