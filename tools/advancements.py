"""Development tool: the advancement list, and hooks/advancements.ts written from
it. Needs nothing but Python; build_assets.py reads the list for its icons.

Each chain starts easy and runs deep: its last tiers take a heavy user months.
An id once shipped keeps its meaning, since what has been earned stays earned.
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (id, parent, name, frame, icon, description, counter, need, secret, was)
# `was` is the id an advancement had before the tabs were regrouped, so what
# was earned under it carries over (tracker.ts reads RENAMED).
def A(i, parent, name, frame, icon, desc, counter=None, need=1, secret=False, was=None):
    return dict(id=i, parent=parent, name=name, frame=frame, icon=icon, desc=desc, counter=counter, need=need, secret=secret, was=was)
TABS = [
 # What Claude makes: edits, commits, pull requests.
 ('Building', 'stone', [
  A('root', None, 'Stone Age', 'task', 'wooden_pickaxe', 'Have Claude edit a file for you.', 'edits', was='0.stone'),
  A('upgrade', 'root', 'Getting an Upgrade', 'task', 'stone_pickaxe', 'Have Claude make 1,000 edits.', 'edits', 1000, was='0.upgrade'),
  A('iron', 'upgrade', "Isn't It Iron Pick", 'goal', 'iron_pickaxe', 'Have Claude make 10,000 edits.', 'edits', 10_000, was='0.iron'),
  A('depths', 'iron', 'Hidden in the Depths', 'challenge', 'netherite_pickaxe', 'Have Claude make 100,000 edits.', 'edits', 100_000, was='0.depths'),
  A('debris', 'upgrade', 'Cover Me in Debris', 'challenge', 'netherite_chestplate', 'Change 10,000 lines in a single reply.', secret=True, was='0.debris'),
  A('exile', 'upgrade', 'Voluntary Exile', 'challenge', 'tnt', 'Delete 10,000 more lines than Claude adds, in a single reply.', secret=True, was='3.exile'),
  A('committed', 'root', 'Committed', 'task', 'writable_book', 'Have Claude make a git commit.', 'commits', was='0.committed'),
  A('days', 'committed', 'Those Were the Days', 'goal', 'brick', 'Have Claude make 5,000 git commits.', 'commits', 5000, was='0.days'),
  A('remnants', 'days', 'Respecting the Remnants', 'challenge', 'brush', 'Have Claude make 50,000 git commits.', 'commits', 50_000, was='0.remnants'),
  A('relationship', 'committed', 'Committed Relationship', 'goal', 'cake', 'Make a git commit on five days in a row.', 'commitStreak', 5, was='0.relationship'),
  A('lode', 'relationship', 'Country Lode, Take Me Home', 'challenge', 'map', 'Make a git commit on 60 days in a row.', 'commitStreak', 60, was='0.lode'),
  A('sticky', 'committed', 'Sticky Situation', 'task', 'slime_ball', 'Run into a git merge conflict.', was='3.sticky'),
  A('frightening', 'committed', 'Very Very Frightening', 'challenge', 'trident', 'Have Claude force-push to main.', secret=True, was='0.frightening'),
  A('sender', 'committed', 'Return to Sender', 'challenge', 'fire_charge', 'Revert a commit, then get the tests passing and commit again, all in one chat.', secret=True, was='0.sender'),
  A('ship', 'committed', 'Ship It', 'goal', 'firework_rocket', 'Have Claude open a pull request.', 'prs', was='0.ship'),
  A('boat', 'ship', 'This Boat Has Legs', 'goal', 'oak_boat', 'Have Claude open 2,500 pull requests.', 'prs', 2500, was='0.boat'),
  A('twobirds', 'ship', 'Two Birds, One Arrow', 'challenge', 'spectral_arrow', 'In a single reply: edit, pass the tests, commit and open a pull request.', was='0.twobirds'),
  A('merged', 'ship', 'Merged', 'goal', 'emerald', 'Merge 25 pull requests with gh.', 'merges', 25, was='0.merged'),
  A('beacon', 'merged', 'Bring Home the Beacon', 'goal', 'end_crystal', 'Merge 1,000 pull requests with gh.', 'merges', 1000, was='0.beacon'),
  A('beaconator', 'beacon', 'Beaconator', 'challenge', 'nether_star', 'Merge 10,000 pull requests with gh.', 'merges', 10_000, was='0.beaconator'),
 ]),
 # Tests: the bugs Claude fights.
 ('Combat', 'nether', [
  A('root', None, 'Monster Hunter', 'task', 'bug', 'Run tests and have them fail.', 'testFails', was='3.hunter'),
  A('hunted', 'root', 'Monsters Hunted', 'challenge', 'diamond_sword', 'Run tests and have them fail, 5,000 times.', 'testFails', 5000, was='3.hunted'),
  A('diamonds', 'root', 'Diamonds!', 'goal', 'diamond', 'After 10+ edits, run the tests and have them pass first time.', was='0.diamonds'),
  A('sniper', 'diamonds', 'Sniper Duel', 'goal', 'bow', 'In a single reply, have a test run fail and then pass.', was='0.sniper'),
  A('cover', 'diamonds', 'Cover Me with Diamonds', 'goal', 'diamond_chestplate', 'Run tests and have them pass, 100 times.', 'passes', 100, was='0.cover'),
  A('trim', 'cover', 'Smithing with Style', 'challenge', 'netherite_upgrade_smithing_template', 'Run tests and have them pass, 10,000 times.', 'passes', 10_000, was='0.trim'),
  A('zombie', 'root', 'Zombie Doctor', 'goal', 'golden_apple', 'Make a failing test run pass, 25 times.', 'cures', 25, was='0.zombie'),
  A('cured', 'zombie', 'Good as New', 'challenge', 'enchanted_golden_apple', 'Make a failing test run pass, 1,000 times.', 'cures', 1000, was='0.cured'),
  A('arbalistic', 'zombie', 'Arbalistic', 'challenge', 'crossbow_firework', 'In a single reply, go from 25 or more failing tests to all passing.', secret=True, was='0.arbalistic'),
 ]),
 # What Claude reaches for: tools, the terminal, subagents, the web.
 ('Exploration', 'adventure', [
  A('root', None, 'Adventure', 'task', 'map', 'Watch Claude use one of its tools.', 'tools', was='3.root'),
  A('tools', 'root', 'Power Tools', 'goal', 'crossbow_arrow', 'Have Claude use its tools 10,000 times.', 'tools', 10_000, was='3.arbalistic'),
  A('rockets', 'tools', 'Who Needs Rockets?', 'challenge', 'firework_star', 'Have Claude use its tools 5 million times.', 'tools', 5_000_000, was='3.rockets'),
  A('hero', 'tools', 'Hero of the Village', 'challenge', 'bell', 'Have Claude make 500 tool calls in a single reply.', secret=True, was='3.hero'),
  A('hardware', 'root', 'Acquire Hardware', 'task', 'terminal', 'Have Claude run a terminal command.', 'commands', was='0.hardware'),
  A('hot', 'hardware', 'Hot Stuff', 'task', 'lava_bucket', 'Have a terminal command fail.', 'failures', was='0.hot'),
  A('betsy', 'hardware', "Ol' Betsy", 'task', 'crossbow_standby', 'Have Claude run 2,500 terminal commands.', 'commands', 2500, was='3.betsy'),
  A('surge', 'betsy', 'Surge Protector', 'goal', 'redstone', 'Have Claude run 250,000 terminal commands.', 'commands', 250_000, was='3.surge'),
  A('overkill', 'surge', 'Over-Overkill', 'challenge', 'mace', 'Have Claude run 2.5 million terminal commands.', 'commands', 2_500_000, was='3.overkill'),
  A('lock', 'hardware', 'Under Lock and Key', 'challenge', 'tripwire_hook', 'Run 1,000 commands in one chat without a single one failing.', secret=True, was='3.lock'),
  A('deeper', 'root', 'We Need to Go Deeper', 'task', 'flint_and_steel', 'Have Claude start a subagent.', 'agents', was='3.deeper'),
  A('help', 'deeper', 'Hired Help', 'goal', 'armor_stand', 'Have Claude start five subagents in a single reply.', was='3.help'),
  A('bubble', 'deeper', 'Subspace Bubble', 'challenge', 'ender_pearl', 'Have Claude start 25,000 subagents.', 'agents', 25_000, was='3.bubble'),
  A('bird', 'root', 'Is It a Bird?', 'task', 'spyglass', 'Have Claude look at an image.', was='3.bird'),
  A('balloon', 'bird', 'Surfing the Web', 'goal', 'compass', 'Have Claude fetch 100 web pages.', 'fetches', 100, was='3.balloon'),
  A('plane', 'balloon', 'Is It a Plane?', 'challenge', 'feather', 'Have Claude fetch 25,000 web pages.', 'fetches', 25_000, was='3.plane'),
  A('tourist', 'root', 'Hot Tourist Destinations', 'goal', 'filled_map', 'Have Claude work in 25 different folders in one chat.', was='3.tourist'),
  A('adventuring', 'tourist', 'Adventuring Time', 'challenge', 'diamond_boots', 'Have Claude work in 150 different folders in one chat.', was='3.adventuring'),
  A('deal', 'root', 'What a Deal!', 'goal', 'emerald', 'Answer 100 questions from Claude.', 'questions', 100, was='3.deal'),
  A('pillager', 'deal', "Who's the Pillager Now?", 'challenge', 'ominous_bottle', 'Answer 5,000 questions from Claude.', 'questions', 5000, was='3.pillager'),
 ]),
 # The two bars: hearts for the usage limit, hunger for the context window.
 ('Survival', 'end', [
  A('root', None, 'The Limit', 'task', 'end_stone', 'See your usage limit as hearts.', was='2.root'),
  A('scratch', 'root', 'Just a Scratch', 'task', 'sweet_berries', 'Use your first half-heart of usage limit.', was='2.scratch'),
  A('half', 'scratch', 'Half a Life', 'task', 'heart_half', 'Use half your usage limit, in ten different limit periods.', 'halves', 10, was='2.half'),
  A('edge', 'half', 'Living on the Edge', 'goal', 'heart_low', 'Use 80% of your usage limit, in ten different limit periods.', 'edges', 10, was='2.edge'),
  A('alliance', 'edge', 'Uneasy Alliance', 'challenge', 'ghast_tear', 'Use 80% of your usage limit, in 250 different limit periods.', 'edges', 250, was='2.alliance'),
  A('bell', 'edge', 'Saved by the Bell', 'goal', 'bell', 'Reach your limit reset with under 10% left.', was='2.bell'),
  A('end', 'edge', 'The End?', 'goal', 'ender_eye', 'Hit your usage limit.', 'deaths', was='2.end'),
  A('withering', 'end', 'Withering Heights', 'challenge', 'nether_star', 'Hit your 5-hour limit and your weekly limit in the same week.', was='2.withering'),
  A('postmortal', 'end', 'Postmortal', 'goal', 'totem_of_undying', 'Get your limit back after hitting it.', 'respawns', was='2.postmortal'),
  A('anchor', 'postmortal', 'Respawn Anchor', 'goal', 'glowstone_dust', 'Hit your limit and come back after the reset, ten times.', 'respawns', 10, was='2.anchor'),
  A('again', 'anchor', 'The End... Again...', 'challenge', 'dragon_breath', 'Hit your limit and come back after the reset, 250 times.', 'respawns', 250, was='2.again'),
  A('gameover', 'end', 'Game Over', 'challenge', 'bone', 'Hit your usage limit within an hour of a limit period starting, with bypass permissions on.', secret=True, was='2.gameover'),
  A('food', 'root', 'Context', 'task', 'bread', 'See your context window as a hunger bar.', was='1.root'),
  A('home', 'food', 'Half Full', 'task', 'campfire', 'Use half the context window in a chat.', was='1.home'),
  A('ice', 'home', 'Ice Bucket Challenge', 'goal', 'water_bucket', 'Fill the context window past 95%.', was='1.ice'),
  A('fire', 'home', 'Into Fire', 'goal', 'blaze_powder', 'Fill the context past 85% in ten different chats.', 'starves', 10, was='1.fire'),
  A('feels', 'fire', 'Feels Like Home', 'challenge', 'netherrack', 'Fill the context past 85% in 1,000 different chats.', 'starves', 1000, was='1.feels'),
  A('howdid', 'fire', 'How Did We Get Here?', 'challenge', 'bucket', 'Context and usage both over 90%, with bypass permissions on and three subagents running.', secret=True, was='1.howdid'),
  A('apple', 'food', 'An Apple a Day', 'task', 'apple', 'Compact a chat.', 'compacts', was='1.apple'),
  A('nine', 'apple', 'Not Quite "Nine" Lives', 'goal', 'golden_carrot', 'Let Claude compact the chat automatically nine times.', 'autos', 9, was='1.nine'),
  A('cocktail', 'apple', 'Second Helpings', 'goal', 'milk_bucket', 'Compact a chat 100 times.', 'compacts', 100, was='1.cocktail'),
  A('diet', 'cocktail', 'A Balanced Diet', 'challenge', 'pumpkin_pie', 'Compact a chat 5,000 times.', 'compacts', 5000, was='1.diet'),
 ]),
 # How you work with Claude: prompts, tokens and levels, streaks, the hours, the jukebox.
 ('Habits', 'husbandry', [
  A('root', None, 'Habits', 'task', 'hay_block', 'Get your first reply from Claude.', 'turns', was='4.root'),
  A('prompt', 'root', 'Claude Code', 'task', 'grass_block', 'Send your first prompt.', 'prompts', was='0.root'),
  A('seedy', 'prompt', 'A Seedy Place', 'goal', 'wheat_seeds', 'Send 10,000 prompts.', 'prompts', 10_000, was='4.seedy'),
  A('past', 'seedy', 'Planting the Past', 'challenge', 'torchflower_seeds', 'Send 250,000 prompts.', 'prompts', 250_000, was='4.past'),
  A('serious', 'prompt', 'Serious Dedication', 'challenge', 'netherite_hoe', 'Get 200 replies from Claude in a single chat.', was='4.serious'),
  A('bullseye', 'prompt', 'Bullseye', 'challenge', 'target', 'Hear Claude say "You\'re absolutely right".', secret=True, was='3.bullseye'),
  A('wood', 'root', 'Getting Wood', 'task', 'oak_log', 'Use 10 million tokens, across all your chats.', 'tokens', 10_000, was='4.wood'),
  A('mine', 'wood', 'Time to Mine!', 'task', 'diamond_pickaxe', 'Use 100 million tokens.', 'tokens', 100_000, was='4.mine'),
  A('strike', 'mine', 'Time to Strike!', 'goal', 'netherite_sword', 'Use 1 billion tokens.', 'tokens', 1_000_000, was='4.strike'),
  A('beginq', 'strike', 'The Beginning?', 'goal', 'soul_sand', 'Use 5 billion tokens.', 'tokens', 5_000_000, was='4.beginq'),
  A('begin', 'beginq', 'The Beginning.', 'goal', 'nether_star', 'Use 10 billion tokens.', 'tokens', 10_000_000, was='4.begin'),
  A('getaway', 'begin', 'Remote Getaway', 'challenge', 'ender_pearl', 'Use 250 billion tokens.', 'tokens', 250_000_000, was='4.getaway'),
  A('sky', 'getaway', "Sky's the Limit", 'challenge', 'elytra', 'Use 1 trillion tokens.', 'tokens', 1_000_000_000, was='4.sky'),
  A('overpowered', 'begin', 'Overpowered', 'challenge', 'enchanted_golden_apple', 'Use 10 billion tokens in a single day.', secret=True, was='4.overpowered'),
  A('goat', 'root', 'Whatever Floats Your Goat!', 'task', 'goat_horn', 'Reach XP level 10.', 'level', 10, was='4.goat'),
  A('powers', 'goat', 'With Our Powers Combined!', 'goal', 'experience_bottle', 'Reach XP level 50.', 'level', 50, was='4.powers'),
  A('eyespy', 'powers', 'Eye Spy', 'challenge', 'ender_eye', 'Reach XP level 75.', 'level', 75, was='4.eyespy'),
  A('nextgen', 'eyespy', 'The Next Generation', 'challenge', 'end_crystal', 'Reach XP level 100.', 'level', 100, was='4.nextgen'),
  A('friend', 'root', "You've Got a Friend in Me", 'task', 'cookie', 'Use Claude Code on three days in a row.', 'dayStreak', 3, was='4.friend'),
  A('bff', 'friend', 'Best Friends Forever', 'goal', 'lead', 'Use Claude Code on 30 days in a row.', 'dayStreak', 30, was='4.bff'),
  A('twobytwo', 'bff', 'Two by Two', 'challenge', 'wheat', 'Use Claude Code on 200 days in a row.', 'dayStreak', 200, was='4.twobytwo'),
  A('birthday', 'bff', 'Birthday Song', 'challenge', 'cake', 'Use Claude Code a year after your first day with this mod.', was='4.birthday'),
  A('fishy', 'root', 'Early Bird', 'task', 'fishing_rod', 'Work with Claude between 4 and 7 a.m. on 25 days.', 'earlies', 25, was='4.fishy'),
  A('dreams', 'fishy', 'Night Owl', 'task', 'clock', 'Work with Claude between midnight and 4 a.m. on 25 nights.', 'lates', 25, was='4.dreams'),
  A('sleep', 'dreams', 'Who Needs Sleep?', 'challenge', 'phantom_membrane', 'Work with Claude every hour from midnight to 6 a.m.', secret=True, was='4.sleep'),
  A('bee', 'root', 'Bee Our Guest', 'task', 'honey_bottle', 'Say please or thank you to Claude 500 times.', 'polite', 500, was='4.bee'),
  A('beelocation', 'bee', 'Total Beelocation', 'challenge', 'honeycomb', 'Say please or thank you to Claude 25,000 times.', 'polite', 25_000, was='4.beelocation'),
  A('music', 'root', 'Sound of Music', 'task', 'jukebox', 'Play a music disc in the jukebox.', 'discs', was='3.music'),
  A('ears', 'music', 'Music to My Ears', 'challenge', 'music_disc_cat', 'Play every music disc in the jukebox.', 'discsHeard', 21, was='3.ears'),
  A('parrots', 'music', 'The Parrots and the Bats', 'goal', 'parrot_spawn_egg', 'Play the jukebox with your parrot out.', was='3.parrots'),
 ]),
 # The rare ones: a few take luck, most take a reply nobody plans.
 ('The Deep Dark', 'deepslate', [
  A('root', None, 'The Deep Dark', 'task', 'echo_shard', 'Earn 50 advancements.', 'earned', 50),
  A('furious', 'root', 'A Furious Cocktail', 'goal', 'blaze_rod', 'Have Claude use 15 different tools in a single reply.'),
  A('thanks', 'furious', 'Not Today, Thank You', 'challenge', 'turtle_helmet', 'Have Claude make 100 tool calls in a single reply without one failing.'),
  A('mint', 'thanks', 'You Need a Mint', 'challenge', 'dragon_breath', 'Use 100 million tokens in a single reply.'),
  A('revaulting', 'mint', 'Revaulting', 'challenge', 'ominous_trial_key', 'Send a prompt within a minute of a limit you hit coming back.'),
  A('warpigs', 'root', 'War Pigs', 'challenge', 'cooked_porkchop', 'Have ten subagents running at once.'),
  A('tactical', 'warpigs', 'Tactical Fishing', 'challenge', 'pufferfish_bucket', 'In a single reply, go from 100 or more failing tests to all passing.', secret=True),
  A('blowback', 'warpigs', 'Blowback', 'challenge', 'wind_charge', 'Revert a revert.', secret=True),
  A('sweet', 'root', 'Sweet Dreams', 'goal', 'lantern', 'Come back to Claude after a week away.'),
  A('glow', 'sweet', 'Glow and Behold', 'challenge', 'glow_ink_sac', 'Work with Claude on every day of a calendar month.'),
  A('spooky', 'sweet', 'Spooky Scary Skeleton', 'challenge', 'skeleton_spawn_egg', 'Send a prompt at 3:33 a.m.', secret=True),
  A('catalogue', 'root', 'A Complete Catalogue', 'challenge', 'knowledge_book', 'Earn every other advancement.', 'earned'),
 ]),
]

def write(discs=None):
    """Writes hooks/advancements.ts; `discs`, when given, is how many music discs there are."""
    if discs:
        for _, _, items in TABS:
            for a in items:
                if a['counter'] == 'discsHeard': a['need'] = discs
    total = sum(len(i) for _, _, i in TABS)
    for _, _, items in TABS:
        for a in items:
            if a['id'] == 'catalogue': a['need'] = total - 1
    renamed = {a['was']: f'{ti}.{a["id"]}' for ti, (_, _, items) in enumerate(TABS) for a in items if a['was']}
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
    out += ['', '// Every advancement saved before the tabs were regrouped, by its id then: what it is now. One not here was removed.',
            f'export const RENAMED: Record<string, string> = {json.dumps(renamed, indent=1)}']
    open(os.path.join(ROOT, 'hooks', 'advancements.ts'), 'w').write('\n'.join(out) + '\n')
    return total


if __name__ == '__main__':
    print(write(), 'advancements')
