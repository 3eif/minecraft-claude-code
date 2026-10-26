# Minecraft HUD for Claude Code

The Minecraft Claude Code Mod: Claude Code as Minecraft survival mode. Your usage limit is your hearts, the context window is your hunger bar, and every token you spend is XP.

It's a silly concept. It's also a real plugin.

## What it does

**The HUD** sits above the prompt in the Claude Code desktop app:

| In the game | In Claude Code |
|---|---|
| Hearts | Your usage limit: the 5-hour or weekly limit, whichever you've used more of. Each heart is 10%. |
| Hunger | The context window. It empties as the chat fills. |
| XP | Tokens, across all your chats. The first levels come fast; later ones take a while. |

**Moments**, played over the whole screen with the game's sounds:

- **Damage:** the hearts flash and shake as you use your limit.
- **Golden apple:** eaten when a chat compacts, refilling hunger.
- **The death screen:** when you hit your limit. "Claude was slain by the 5-hour limit." In bypass-permissions mode it's hardcore: "Game Over!"
- **Totem of Undying:** when your weekly limit resets. It plays once, in one chat, however many you have open.
- **Level up:** XP orbs and the level-up chime.
- **A villager's "hmm":** when Claude stops to ask you a question.

**Advancements:** 113 of them in six tabs: Building (edits, commits, pull requests), Combat (tests), Exploration (tools, the terminal, subagents, the web), Survival (your limit and your context), Habits (prompts, tokens, levels, streaks) and The Deep Dark, the rare ones, which opens at 50 earned. Toasts stack in the corner like the game's and stay ten seconds (longer while the pointer is on one); Share sends a picture of one through the Mac's share menu. In the tree, each says when you earned it, and a star marks what is new since you last looked. Each chain starts easy and runs deep: its last tiers take a heavy user months. Some are secret.

**The hotbar:** click a slot to open its screen.

| Slot | What it does |
|---|---|
| Advancements | The advancement tree. |
| Jukebox | Play the game's music discs and soundtrack, from your own Minecraft install. Click or drag along the track to seek. |
| Parrot | A 3D parrot on your desktop. It watches your pointer and dances when the Jukebox plays. Right-click it for a new coat. |
| Settings | Volume, sound types, and which animations play. |

## Requirements

- **macOS 12 or later.** Apple Silicon or Intel.
- **The Claude Code desktop app** for the pixel HUD and hotbar. In the terminal you get a one-line summary, and the full-screen moments and the parrot still work.
- **Minecraft Java Edition,** installed and launched at least once, for the Jukebox's music. Everything else works without it.
- **ffmpeg,** also for the Jukebox: `brew install ffmpeg`.

## Install

```bash
claude plugin marketplace add 3eif/minecraft-hud
```

```bash
claude plugin install minecraft-hud@minecraft-hud
```

Then start a new chat. A short guide opens the first time; type `/minecraft help` to see it again.

## Commands

Everything is under `/minecraft`:

| Command | What it does |
|---|---|
| `/minecraft advancements`, `music`, `parrot`, `settings` | Open a hotbar screen |
| `/minecraft music pause`, `next`, `prev`, `stop` | Control the Jukebox |
| `/minecraft death`, `totem`, `damage`, `apple`, `advancement`, `xp` | Preview a moment |
| `/minecraft live` | Return to your real figures after a preview |
| `/minecraft volume 50`, `mute`, `unmute` | Sound |
| `/minecraft fullscreen on\|off`, `hotbar on\|off` | Turn the full-screen moments or the hotbar off. `/minecraft hotbar on` brings a hidden hotbar back. |
| `/minecraft clear` | Reset your XP. Advancements are kept. |
| `/minecraft reset all confirm` | Start over: every advancement, your XP and the backup. Settings are kept. |

## Privacy

Everything stays on your Mac. The mod reads your usage figures and the current chat from Claude Code, and sends nothing anywhere.

What it keeps (XP, advancements, settings, the parrot's spot) lives in Claude Code's plugin storage and `~/Library/Caches/minecraft-hud`, shared by every open chat: a setting changed in one shows in the others within a few seconds. Your progress is also copied, daily and whenever you earn an advancement, to `~/Library/Application Support/minecraft-hud/backup.json`, and comes back from there if a reinstall starts the mod with nothing.

## Uninstall

```bash
claude plugin uninstall minecraft-hud@minecraft-hud
```

```bash
rm -rf ~/Library/Caches/minecraft-hud
```

A small background helper keeps the screens fast. It quits on its own after a while unused, or you can stop it now:

```bash
pkill -f MCOverlay
```

## How it works

The plugin's hooks draw the HUD in Claude Code and track your usage, context and tokens. The screens, the full-screen moments and the parrot are drawn by `overlay/MCOverlay`, a small native helper written in Swift that stays running in the background so screens open in a few milliseconds. The parrot is the game's own model, built in 3D with SceneKit.

To build the helper yourself (needs Xcode's command-line tools):

```bash
overlay/build.sh
```

## Notes

- Built for the Claude Code version it was made with. The hotbar uses a layout trick (invisible buttons over the slot pictures) that a future app update could break.
- Tested on one Mac so far. Issues welcome.

## Disclaimer

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT. Not affiliated with or endorsed by Anthropic.

Minecraft's textures, sounds and music are the property of Mojang. The music is played from your own Minecraft install and is not included here.
