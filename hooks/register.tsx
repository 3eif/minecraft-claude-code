import type { EngineInterface, Register, SessionContextUsage, SessionRateLimit } from 'claude-code'

import { ADVANCEMENTS, RENAMED } from './advancements'
import { HOTBAR, ICONS } from './hotbar'
import { DIGITS, PIX } from './pixels'
import { GLYPH, GLYPH_W, SPR, XP_BG, XP_FILL } from './sprites'
import { blank, day, due, isTest, merge, testKey, tree, type Progress } from './tracker'

// Minecraft's survival HUD above the prompt.
//   hearts  = the usage limit that will stop you first (5-hour or weekly)
//   hunger  = the context window
//   XP      = every token you have used, one point per 1,000
// Timings follow Minecraft 1.21's Gui and its 20 ticks a second: as SMIL
// animations inside the Svg on the desktop, as swapped frames in a terminal.

// Experience: every token consumed, cache reads included, for all time and
// across every chat, counted in units of 100,000 tokens. The store holds it;
// this is the figure as this chat last read it.
let xpTotal = 0
// Until when this chat's orbs are flying into the bar.
let orbsUntil = 0
const TICK = 50

type Timer = ReturnType<EngineInterface['clock']['after']>

const s = {
  contextPct: 0,
  limitPct: 0,
  ready: false,
  demo: false,
  health: 20,
  lostFrom: 20,
  damageAt: -1e12,
  food: 20,
  starving: false,
  kind: '',
  resetAt: 0,
  // When the weekly limit resets: the Totem of Undying's moment.
  weekAt: 0,
  hardcore: false,
  hungerFx: false,
  light: false,
  dead: false,
  eatAt: -1e12,
  regenAt: -1e12,
  regenMs: 0,
  countdownTo: 0,
  xpShown: 0,
  xpAt: -1e12,
  lastEdit: 0,
  lastReset: '',
}
let sounds = true
let volume = 1
let fullscreen = true
let hotbar = true
// Kinds of sound turned off in Music & Sounds, and moments turned off in
// Accessibility (the HUD stays still for those).
// The XP orbs' tick plays on every reply; it starts off, and Music & Sounds turns it on.
let muted: string[] = ['orbs']
let still: string[] = []
const motion = (moment: string) => !still.includes(moment)
const soundKind = (name: string) =>
  /^hit/.test(name) ? 'damage' : /^eat|^burp/.test(name) ? 'eating' : name === 'orb' ? 'orbs' : name === 'levelup' ? 'xp'
    : /^toast|^challenge/.test(name) ? 'advancements' : name === 'use_totem' ? 'totem' : /^villager/.test(name) ? 'villager'
      : name === 'click' ? 'clicks' : name
const prefs = () => ({ sounds, volume, fullscreen, hotbar, muted, still, orbsChosen: true })
type Prefs = Partial<ReturnType<typeof prefs>>
function usePrefs(kept: Prefs | undefined) {
  if (Array.isArray(kept?.muted)) muted = kept.muted
  // Saved before the orbs had their own switch: they start off like everyone else's.
  if (!kept?.orbsChosen && !muted.includes('orbs')) muted = [...muted, 'orbs']
  if (Array.isArray(kept?.still)) still = kept.still
  if (typeof kept?.sounds === 'boolean') sounds = kept.sounds
  if (typeof kept?.volume === 'number') volume = kept.volume
  if (typeof kept?.fullscreen === 'boolean') fullscreen = kept.fullscreen
  if (typeof kept?.hotbar === 'boolean') hotbar = kept.hotbar
}
let timers: Timer[] = []
// Whether this chat is in bypass permissions mode, as its last prompt said: /minecraft hardcore previews the look alone.
let bypass = false
let seen: unknown = null

// ---------- advancements ----------
// `saved` is what the store held when this chat last saved; `mine` is what it
// has added since. Each is earned once, ever.
let saved = blank()
let mine = blank()
let pending: string[] = []
let chat = ''
// The folders Claude has read or edited a file in, this chat.
const folders = new Set<string>()
let chatTurns = 0
let editsSinceTest = 0
let failedSinceEdits = false
const failing = new Set<string>()
const turn = { edits: 0, passed: false, committed: false, shipped: false, agents: 0, tools: 0, added: 0, removed: 0, inserted: 0, deleted: 0, failing: 0, testFailed: false, failedAny: false, tokens: 0, kinds: new Set<string>() }
// What the secret advancements watch across a whole chat.
const chatRun = { clean: 0, reverted: false, passedSince: false }
// A git subcommand, however git was started: `git commit`, `git -C dir commit`, `git -c k=v push`.
const git = (sub: string) => new RegExp(`\\bgit(?:\\s+(?:-[Cc]\\s+\\S+|--[\\w-]+(?:=\\S+)?))*\\s+(?:${sub})\\b`)
const lineCount = (text: unknown) => (typeof text === 'string' && text ? text.split('\n').length : 0)
const EDITS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

const count = (counter: string, by = 1) => {
  mine.n[counter] = (mine.n[counter] ?? 0) + by
}
const raise = (counter: string, to: number) => {
  if (to > (saved.max[counter] ?? 0)) mine.max[counter] = Math.max(mine.max[counter] ?? 0, to)
}
const once = (set: string, key: string) => {
  if (saved.sets[set]?.includes(key) || mine.sets[set]?.includes(key)) return
  ;(mine.sets[set] ??= []).push(key)
}
const award = (id: string) => {
  if (!saved.earned[id] && !pending.includes(id)) pending.push(id)
}

// ---------- java.util.Random, for the game's own shake pattern ----------
const MASK = (1n << 48n) - 1n
const MULT = 0x5deece66dn
let seed = 0n
const setSeed = (n: number) => {
  seed = (BigInt(n) ^ MULT) & MASK
}
const nextBits = (bits: number) => {
  seed = (seed * MULT + 0xbn) & MASK
  return Number(BigInt.asIntN(32, seed >> BigInt(48 - bits)))
}
const nextInt = (bound: number) => {
  if ((bound & -bound) === bound) return Number((BigInt(bound) * BigInt(nextBits(31))) >> 31n)
  let bits = 0
  let val = 0
  do {
    bits = nextBits(31)
    val = bits % bound
  } while (bits - val + (bound - 1) > 2147483647)
  return val
}

// ---------- experience ----------
// Level L needs 1 million × L^K tokens in all, K set so that 35 billion tokens,
// about a year of heavy use, is level 50: the first levels come in minutes,
// level 20 in a month of heavy use, level 100 in years.
const XP_UNIT = 100_000
const K = Math.log(35_000) / Math.log(50)
const tokensFor = (level: number) => 1e6 * Math.pow(level, K)
function levelOf(units: number) {
  const tokens = units * XP_UNIT
  let level = Math.max(0, Math.floor(Math.pow(tokens / 1e6, 1 / K)))
  while (tokensFor(level + 1) <= tokens) level++
  while (level > 0 && tokensFor(level) > tokens) level--
  return { level, progress: (tokens - tokensFor(level)) / (tokensFor(level + 1) - tokensFor(level)), toNext: tokensFor(level + 1) - tokens, tokens }
}
const short = (n: number) =>
  n >= 1e9 ? `${+(n / 1e9).toFixed(1)}B` : n >= 1e6 ? `${+(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}K` : String(Math.round(n))
const ORBS = [2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1]

// ---------- outside the module ----------
const pick = (names: string[]) => names[Math.floor(Math.random() * names.length)] ?? names[0]!

function play($: EngineInterface, name: string, gain = 1) {
  if (!sounds || muted.includes(soundKind(name))) return
  // The screen server has every sound loaded and plays it at once; the app's own audio is a few hundred ms behind.
  void (async () => {
    const inbox = await serverInbox($)
    if (inbox) await $.fs.write(`${inbox}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}~${name}~${(gain * volume).toFixed(3)}.sound`, '')
    else await $.audio.play({ asset: `assets/sounds/${name}.wav` }, { gain: gain * volume })
  })().catch(() => {})
}

// Starts the overlay helper detached: it plays one moment over the whole
// screen, click-through, and quits.
async function overlay($: EngineInterface, loudness: number, moment: string[]) {
  // With full-screen moments off, each one stays inside the app: its sound,
  // and a toast for an advancement.
  if (!fullscreen) {
    if (moment[0] === 'totem') play($, 'use_totem', loudness)
    if (moment[0] === 'tip') $.ui.toast(`${moment[2] ?? ''} ${moment[4] ?? ''}`)
    if (moment[0] === 'advancement') {
      play($, moment[1] === 'challenge' ? 'challenge_complete' : 'toast_in')
      $.ui.toast(`${moment[1] === 'challenge' ? 'Challenge Complete!' : moment[1] === 'goal' ? 'Goal Reached!' : 'Advancement Made!'} ${moment[2] ?? ''}`)
    }
    return
  }
  const inbox = await serverInbox($)
  if (inbox) {
    const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    await $.fs.write(`${inbox}/${id}.moment`, JSON.stringify({ moment, loudness, volume: sounds ? volume : 0, muted, at: Date.now() }))
    return
  }
  const root = $.plugin.root
  await $.process.run(
    [
      '/bin/sh',
      '-c',
      'v="$1"; m="$2"; shift 2; MC_VOLUME="$v" MC_MUTED="$m" "$0" "$@" >/dev/null 2>&1 &',
      `${root}/overlay/MCOverlay`,
      String(sounds ? loudness * volume : 0),
      muted.join(','),
      `${root}/assets`,
      ...moment,
    ],
    { timeoutMs: 5000 },
  )
}

const redraw = ($: EngineInterface) => $.ui.invalidate('ui.render')

// The game's tutorial toasts: one for each thing worth explaining, the first
// time it happens, and never again in any chat.
async function tipOnce($: EngineInterface, id: string, title: string, icon: string, desc: string) {
  if (s.demo || (await $.store.get(`tip:${id}`)) || !(await claim($, `tip:${id}`))) return
  await $.store.set(`tip:${id}`, true)
  await overlay($, 1, ['tip', 'tip', title, icon, desc])
}

// A reply's size, by its edits or by what git counted, whichever saw more.
function bigReply() {
  if (Math.max(turn.added + turn.removed, turn.inserted + turn.deleted) >= 10_000) award('0.debris')
}

function later($: EngineInterface, ms: number, fn: () => void) {
  timers.push($.clock.after(ms, fn))
}

// ---------- one record for every chat ----------
// Every open chat runs its own copy of this module. What they share is the
// store, and a folder in the cache: mkdir is atomic across processes, so the
// first chat to make a folder there owns that moment (a totem, a death, a
// toast), and a folder held while the store is read and written keeps two
// chats from writing over each other's counts.
let sharedAt = ''
async function sharedDir($: EngineInterface) {
  if (!sharedAt) {
    const home = (await $.env.get('HOME')) ?? ''
    sharedAt = home ? `${home}/Library/Caches/minecraft-hud/shared` : ''
  }
  return sharedAt
}
const folderName = (key: string) => key.replace(/[^A-Za-z0-9._-]/g, '_')
const MAKE = 'mkdir -p "$(dirname "$0")" && mkdir "$0" 2>/dev/null'

/** True in exactly one chat for each key: the first to ask. Kept two days. */
async function claim($: EngineInterface, key: string) {
  const dir = await sharedDir($)
  if (!dir) return false
  const made = await $.process.run(['/bin/sh', '-c', MAKE, `${dir}/claims/${folderName(key)}`], { timeoutMs: 5000 }).catch(() => undefined)
  // With no way to ask, no chat plays it: a moment missed beats one played in every chat.
  return made?.exitCode === 0
}

/**
 * Runs `fn` while no other chat runs one under the same name. When another chat
 * keeps the lock past three seconds, `fn` is not run and `undefined` comes back,
 * unless `always`: then it runs unlocked, for a write better made late than lost.
 */
async function withLock<T>($: EngineInterface, name: string, fn: () => Promise<T>, always = false): Promise<T | undefined> {
  const dir = await sharedDir($)
  const lock = `${dir}/locks/${folderName(name)}`
  let held = false
  let contended = false
  for (let tries = 0; dir && !held && tries < 60; tries++) {
    const made = await $.process.run(['/bin/sh', '-c', MAKE, lock], { timeoutMs: 5000 }).catch(() => undefined)
    if (!made) break
    held = made.exitCode === 0
    if (held) break
    contended = true
    // A chat that quit while holding it leaves it behind: after ten seconds it is taken anyway.
    const since = await $.fs.stat(lock).then(st => Date.now() - st.mtimeMs, () => 0)
    if (since > 10_000) await $.process.run(['/bin/rmdir', lock], { timeoutMs: 5000 }).catch(() => undefined)
    else await $.clock.sleep(50)
  }
  if (!held && contended && !always) return undefined
  try {
    return await fn()
  } finally {
    if (held) await $.process.run(['/bin/rmdir', lock], { timeoutMs: 5000 }).catch(() => undefined)
  }
}

let syncedAt = 0
/** syncShared, at most every two seconds: called whenever this chat is drawn, replies or is sent a prompt. */
function syncSoon($: EngineInterface) {
  const now = Date.now()
  if (now - syncedAt < 2000) return
  syncedAt = now
  void syncShared($).catch(() => undefined)
}

/** Takes up what other chats changed: the settings, and XP they earned. */
async function syncShared($: EngineInterface) {
  const before = JSON.stringify(prefs())
  usePrefs((await $.store.get('prefs')) as Prefs | undefined)
  let changed = JSON.stringify(prefs()) !== before
  const held = ((await $.store.get('xp2')) as { units?: number } | undefined)?.units
  // Never while this chat's own orbs are still flying: the bar would overshoot.
  if (typeof held === 'number' && held > xpTotal && (await $.clock.now()) > orbsUntil) {
    xpTotal = held
    if (Math.floor(held) > s.xpShown) {
      s.xpShown = Math.floor(held)
      changed = true
    }
  }
  if (changed) redraw($)
}

// Progress since the tabs were regrouped is kept under its own key: a chat still
// running the version before writes the old one, with the old ids, and is left to it.
// The first read with nothing under the new key takes the old one up once.
const PROGRESS = 'progress2'
async function storedProgress($: EngineInterface) {
  const now = (await $.store.get(PROGRESS)) as Progress | undefined
  const old = (await $.store.get('progress')) as Progress | undefined
  if (!now || !old) return now ?? old
  const earned = { ...now.earned }
  for (const [id, at] of Object.entries(old.earned ?? {})) {
    const to = RENAMED[id]
    if (to) earned[to] = Math.min(earned[to] ?? at, at)
  }
  return { ...now, earned }
}

// ---------- the backup ----------
// The store belongs to one install of the mod, from one marketplace: installed
// from another, or uninstalled, it starts over. So the record is copied, once a
// day and whenever an advancement is earned, to a folder of its own that any
// install finds, and taken back when a chat starts with nothing in the store.
const KEPT = [PROGRESS, 'xp2', 'prefs', 'guided', 'treeSeenAt', 'lastPromptAt', 'cameBack']
async function backupFile($: EngineInterface) {
  const home = (await $.env.get('HOME')) ?? ''
  return home ? `${home}/Library/Application Support/minecraft-hud/backup.json` : ''
}

async function backUp($: EngineInterface, now: number) {
  const file = await backupFile($)
  if (!file) return
  const data: Record<string, unknown> = {}
  for (const key of KEPT) {
    const value = await $.store.get(key)
    if (value !== undefined) data[key] = value
  }
  for (const key of await $.store.keys()) if (key.startsWith('tip:')) data[key] = await $.store.get(key)
  await $.process.run(['/bin/mkdir', '-p', file.slice(0, file.lastIndexOf('/'))], { timeoutMs: 5000 }).catch(() => undefined)
  await $.fs.write(file, JSON.stringify({ at: now, data })).catch(() => undefined)
  await $.store.set('backupAt', now)
}

/** Takes the backup back into an empty store. Says what it brought back, or nothing. */
async function restore($: EngineInterface) {
  const held = ((await $.store.get('xp2')) as { units?: number } | undefined)?.units ?? 0
  if ((await $.store.get(PROGRESS)) || (await $.store.get('progress')) || held > 0) return ''
  const file = await backupFile($)
  const said = file ? await $.fs.read(file).catch(() => '') : ''
  const backup = (said ? JSON.parse(said) : {}) as { data?: Record<string, unknown> }
  const progress = backup.data?.[PROGRESS] as Progress | undefined
  if (!progress || !Object.keys(progress.earned ?? {}).length) return ''
  for (const [key, value] of Object.entries(backup.data ?? {})) await $.store.set(key, value)
  const units = (backup.data?.xp2 as { units?: number } | undefined)?.units ?? 0
  return `Progress restored from your backup: ${Object.keys(progress.earned).length} advancements, level ${levelOf(units).level}.`
}

// Counts are saved a few seconds after they change, in one write, instead of at
// every event: the store's lock costs two small processes. An advancement just
// earned is saved at once, so its toast is not late, and a chat that ends saves
// what it has first.
let settleTimer: Timer | undefined
function settleSoon($: EngineInterface) {
  if (pending.length) {
    settleTimer?.cancel()
    settleTimer = undefined
    void settle($)
    return
  }
  settleTimer ??= $.clock.after(3000, () => {
    settleTimer = undefined
    void settle($)
  })
}

// The days and hours worked with Claude, from a prompt or a reply. The shared
// record is read first, so what other chats saw counts toward a streak, a month
// or a night.
async function noteActivity($: EngineInterface, now: number) {
  saved = merge(await storedProgress($), blank())
  const today = day(now)
  const at = new Date(now)
  const hour = at.getHours()
  const seen = (set: string) => new Set([...(saved.sets[set] ?? []), ...(mine.sets[set] ?? [])])
  if (!seen('first').size) once('first', today)
  once('days', today)
  if (hour >= 4 && hour < 7) once('earlies', today)
  if (hour < 4) once('lates', today)
  // Every hour from midnight to six, the same night.
  if (hour < 6) {
    once('nightHours', `${today}:${hour}`)
    const hours = seen('nightHours')
    if ([0, 1, 2, 3, 4, 5].every(h => hours.has(`${today}:${h}`))) award('4.sleep')
  }
  // The last day of a month, with every day of it worked.
  const length = new Date(at.getFullYear(), at.getMonth() + 1, 0).getDate()
  if (at.getDate() === length) {
    const worked = seen('days')
    const month = today.slice(0, 8)
    if (Array.from({ length }, (_, i) => `${month}${String(i + 1).padStart(2, '0')}`).every(d => worked.has(d))) award('5.glow')
  }
}

// Saves what this chat has counted on top of what the store holds, and shows
// a toast for each advancement that came due.
// Another chat may have earned it first; the store is read again to see.
async function settle($: EngineInterface) {
  if (!pending.length && !Object.keys(mine.n).length && !Object.keys(mine.max).length && !Object.keys(mine.sets).length) return
  const fresh = await withLock($, 'progress', async () => {
  const now = await $.clock.now()
  const next = merge(await storedProgress($), mine)
  mine = blank()
  const first = next.sets.first?.[0]
  if (first && day(now) >= `${Number(first.slice(0, 4)) + 1}${first.slice(4)}`) pending.push('4.birthday')
  // Ten billion tokens in one day; only today's tally is kept.
  const today = `tokensOn:${day(now)}`
  for (const key of Object.keys(next.n)) if (key.startsWith('tokensOn:') && key !== today) delete next.n[key]
  if ((next.n[today] ?? 0) >= 10_000_000) pending.push('4.overpowered')
  const named = pending.map(id => ADVANCEMENTS.find(a => a.id === id)).filter(a => a !== undefined)
  pending = []
  const earned = [...new Set([...named, ...due(next, now)])].filter(a => !next.earned[a.id])
  for (const a of earned) next.earned[a.id] = now
  // What those earnings bring due in turn (the Deep Dark at 50, the catalogue at all).
  for (let more = due(next, now); more.length; more = due(next, now)) {
    for (const a of more) next.earned[a.id] = now
    earned.push(...more)
  }
  saved = next
  await $.store.set(PROGRESS, next)
  return earned
  })
  // Another chat held the record: what this one counted stays, and is saved shortly.
  if (!fresh) {
    later($, 3000, () => settleSoon($))
    return
  }
  const now = await $.clock.now()
  if (fresh.length || now - Number((await $.store.get('backupAt')) ?? 0) > 86_400_000) void backUp($, now).catch(() => undefined)
  // A tab's first advancement only opens the tab: it is earned without a toast.
  // The rest show as the game shows them, stacked down the corner, each a beat
  // after the one above so their sounds do not land together.
  fresh
    .filter(a => a.parent)
    .forEach((a, i) => later($, i * 300, () => void overlay($, 1, ['advancement', a.frame, a.name, a.icon, a.desc])))
}

// ---------- moments ----------
function hurt($: EngineInterface, to: number, now: number) {
  s.lostFrom = s.health
  s.health = Math.max(0, to)
  s.damageAt = now
  if (s.health === 0) s.dead = true
  void hurtSound($)
  redraw($)
  later($, 1100, () => redraw($))
  later($, 4100, () => redraw($))
  if (s.dead) {
    later($, 1200, () => redraw($))
    void deathMoment($, now)
  }
}

// Every open session takes the same hit; only the first one sounds it.
async function hurtSound($: EngineInterface) {
  if (!(await claim($, `hurt:${s.demo ? s.damageAt : `${s.resetAt}:${s.health}`}`))) return
  play($, pick(['hit1', 'hit2', 'hit3']))
}

// The death screen over the whole display, as in the game, until a button is
// pressed. Every open session hits the limit together; only the first plays it.
async function deathMoment($: EngineInterface, now: number) {
  // Another screen is up: try again shortly, before any chat claims this death.
  if (fullscreen && screenOpen) {
    later($, 3000, () => void deathMoment($, now))
    return
  }
  if (!(await claim($, `death:${s.demo ? now : s.resetAt}`))) return
  if (!fullscreen) return
  const said = await screen($, 'death', {
    title: s.hardcore ? 'Game Over!' : 'You Died!',
    cause: `Claude was slain by the ${limitName()}`,
    score: String(levelOf(s.xpShown).level),
    label: 'Respawn',
  })
  // Respawn can only bring a preview back to life: a real limit lifts when it
  // resets, and the hearts refill then.
  if (s.demo && said?.death === 'respawn') {
    Object.assign(s, { dead: false, health: 20, lostFrom: 20, regenAt: await $.clock.now(), regenMs: 100 * TICK })
    later($, 100 * TICK + 100, () => redraw($))
  }
  redraw($)
}

// A golden apple: 32 ticks of eating with a crunch every 4 from tick 8, a
// burp, then Regeneration II for 100 ticks.
function eat($: EngineInterface, now: number) {
  s.eatAt = now
  for (const tick of [8, 12, 16, 20, 24, 28]) {
    later($, tick * TICK, () => play($, pick(['eat1', 'eat2', 'eat3']), Math.random() < 0.5 ? 0.5 : 1))
  }
  later($, 32 * TICK, () => {
    play($, pick(['eat1', 'eat2', 'eat3']))
    play($, 'burp', 0.5)
    s.regenAt = now + 32 * TICK
    s.regenMs = 100 * TICK
    redraw($)
    later($, s.regenMs + 100, () => redraw($))
  })
  redraw($)
}

// `real` is false for a preview, which moves the bar and leaves the level alone.
async function gainXP($: EngineInterface, tokens: number, real = true) {
  if (real) {
    await withLock($, 'xp', async () => {
      // Other chats earn too, so the store is read before it is added to.
      const stored = ((await $.store.get('xp2')) as { units?: number } | undefined)?.units ?? 0
      // What other chats earned since: the bar jumps to it quietly. Only this chat's own gain gets orbs and the chime.
      if (Math.floor(stored) > s.xpShown) s.xpShown = Math.floor(stored)
      xpTotal = Math.max(0, stored) + tokens / XP_UNIT
      await $.store.set('xp2', { units: xpTotal })
    }, true)
    if (s.xpShown > xpTotal) s.xpShown = Math.floor(xpTotal)
    raise('level', levelOf(xpTotal).level)
  }
  const total = real ? xpTotal : s.xpShown + tokens / XP_UNIT
  let left = Math.floor(total) - Math.floor(s.xpShown)
  const orbs: number[] = []
  while (left > 0 && orbs.length < 12) {
    const orb = orbs.length === 11 ? left : (ORBS.find(v => v <= left) ?? 1)
    orbs.push(orb)
    left -= orb
  }
  // One orb every 2 ticks, each with its ding; the bar jumps, it never slides.
  const now = await $.clock.now()
  orbsUntil = now + orbs.length * 2 * TICK + 100
  later($, orbs.length * 2 * TICK + 4100, () => redraw($))
  orbs.forEach((orb, i) =>
    later($, i * 2 * TICK, () => {
      s.xpAt = now + i * 2 * TICK
      const before = levelOf(s.xpShown).level
      // Orbs of two gains flying at once never carry the bar past what was earned.
      s.xpShown = real ? Math.min(s.xpShown + orb, Math.max(s.xpShown, Math.floor(xpTotal))) : s.xpShown + orb
      const level = levelOf(s.xpShown).level
      play($, 'orb', 0.1)
      // Levels are rare enough now that every one gets the chime.
      if (level > before) play($, 'levelup', 0.75)
      if (real && level > before) void tipOnce($, 'level', 'Level up!', 'experience_bottle', 'XP is based on the tokens you consume.')
      redraw($)
    }),
  )
}

// How a limit period ended, for Postmortal, Saved by the Bell and Revaulting:
// read from the record every chat keeps of each limit's period, when a later
// one replaces it, so it counts once however many chats are open and whether
// or not one was open at the reset itself.
type Period = { resetAt: number; dead: boolean; health: number }
type Periods = Partial<Record<'five_hour' | 'seven_day', Period>>
let periodsSaid = ''
async function notePeriods($: EngineInterface, now: number, plan: readonly SessionRateLimit[]) {
  const was = ((await $.store.get('periods')) ?? {}) as Periods
  const next: Periods = { ...was }
  for (const limit of plan) {
    const kind = limit.kind as keyof Periods
    const resetAt = limit.resetsAt ? Date.parse(limit.resetsAt) : 0
    if (!resetAt) continue
    const left = Math.max(0, Math.ceil((100 - Math.min(100, limit.percentUsed)) / 5))
    const old = was[kind]
    // A stale reading from a chat behind the others never moves a record back.
    if (old && resetAt < old.resetAt) continue
    if (old && resetAt > old.resetAt && now >= old.resetAt - 60_000 && (await claim($, `period:${kind}:${old.resetAt}`))) {
      if (old.dead) {
        once('respawns', String(old.resetAt))
        await $.store.set('cameBack', Math.max(old.resetAt, Number((await $.store.get('cameBack')) ?? 0)))
      } else if (old.health > 0 && old.health <= 2) award('3.bell')
      settleSoon($)
    }
    const same = old?.resetAt === resetAt
    next[kind] = { resetAt, dead: limit.percentUsed >= 100 || (same && old.dead), health: same ? Math.min(old.health, left) : left }
  }
  const said = JSON.stringify(next)
  if (said !== periodsSaid) {
    periodsSaid = said
    await $.store.set('periods', next)
  }
}

// Revaulting: a prompt within a minute of a limit you hit coming back.
async function backInTime($: EngineInterface, now: number) {
  const periods = ((await $.store.get('periods')) ?? {}) as Periods
  const dead = Object.values(periods).filter(p => p?.dead).map(p => p!.resetAt)
  for (const back of [...dead, Number((await $.store.get('cameBack')) ?? 0)]) {
    if (back && now >= back && now - back <= 60_000) award('5.revaulting')
  }
}

// The hearts refill when the limit they show resets. The totem is not played
// here: it is the weekly limit's moment alone (totemMoment).
async function resetMoment($: EngineInterface, key: string) {
  if (s.lastReset === key) return
  // A reset scheduled for a limit the hearts no longer show.
  if (/^\d+$/.test(key) && key !== String(s.resetAt)) return
  const now = await $.clock.now()
  s.lastReset = key
  s.dead = false
  s.health = 20
  s.lostFrom = 20
  s.countdownTo = 0
  s.regenAt = now
  s.regenMs = 900 * TICK
  redraw($)
  later($, s.regenMs + 100, () => redraw($))
}

function countdown($: EngineInterface, to: number) {
  s.countdownTo = to
  for (let i = 0; i <= 10; i++) later($, i * 1000, () => redraw($))
}

// The Totem of Undying, when the weekly limit resets: once, in whichever chat
// gets there first, quietly, and never over your typing.
const TOTEM_LOUDNESS = 0.15
// A hotbar slot's click; the screens' own buttons click at about the same.
const CLICK = 0.3
async function totemMoment($: EngineInterface, key: string) {
  const now = await $.clock.now()
  if (now - s.lastEdit < 3000) {
    later($, 1000, () => void totemMoment($, key))
    return
  }
  if (key.startsWith('demo:') || (await claim($, `totem:${Math.round(Number(key) / 3600_000)}`))) await overlay($, TOTEM_LOUDNESS, ['totem'])
}

function schedule($: EngineInterface, now: number) {
  if (s.resetAt <= now) return
  const key = String(s.resetAt)
  later($, s.resetAt - now + 1500, () => void resetMoment($, key))
}

let totemTimers: Timer[] = []
function scheduleTotem($: EngineInterface, now: number, from: number) {
  // The weekly reset moved later before it came: what was set for the old time is
  // dropped. One that has come, or is a moment away, plays as set.
  if (from > now + 5000) for (const timer of totemTimers) timer.cancel()
  totemTimers = []
  if (s.weekAt <= now) return
  const key = String(s.weekAt)
  const wait = s.weekAt - now
  if (wait > 10_000) totemTimers.push($.clock.after(wait - 10_000, () => countdown($, s.weekAt)))
  totemTimers.push($.clock.after(wait + 1500, () => void totemMoment($, key)))
}

// Context and usage both over 90%, bypass on, and three subagents running at once.
async function warPigs($: EngineInterface) {
  if (s.demo) return
  const running = (await $.agent.list().catch(() => [])).filter(a => a.status === 'running').length
  if (running >= 10) award('5.warpigs')
}

async function howDid($: EngineInterface) {
  if (s.demo || !bypass || s.contextPct <= 90 || s.limitPct <= 90) return
  const running = (await $.agent.list().catch(() => [])).filter(a => a.status === 'running').length
  if (running >= 3) award('3.howdid')
}

async function applyUsage($: EngineInterface, context: SessionContextUsage, limits: readonly SessionRateLimit[]) {
  if (s.demo) return
  const now = await $.clock.now()
  const plan = limits.filter(l => l.kind === 'five_hour' || l.kind === 'seven_day')
  const top = plan.reduce<SessionRateLimit | undefined>((a, b) => (!a || b.percentUsed > a.percentUsed ? b : a), undefined)
  const percent = top ? Math.min(100, top.percentUsed) : 0
  const health = Math.max(0, Math.ceil((100 - percent) / 5))
  const used = context.percent ?? 0

  s.food = Math.max(0, Math.ceil((100 - used) / 5))
  s.starving = used >= 85
  s.kind = top?.kind ?? ''
  const resetAt = top?.resetsAt ? Date.parse(top.resetsAt) : 0
  await notePeriods($, now, plan)
  if (resetAt && resetAt !== s.resetAt) {
    s.resetAt = resetAt
    schedule($, now)
  }
  const weekAt = Date.parse(plan.find(l => l.kind === 'seven_day')?.resetsAt ?? '') || 0
  if (weekAt && weekAt !== s.weekAt) {
    const from = s.weekAt
    s.weekAt = weekAt
    scheduleTotem($, now, from)
  }

  award('3.food')
  if (used >= 50) award('3.home')
  if (used > 95) award('3.ice')
  if (used > 85 && chat) once('starves', chat)
  // Both limits hit inside one weekly period: each death is filed under the week it fell in.
  const week = plan.find(l => l.kind === 'seven_day')?.resetsAt
  if (week) {
    for (const l of plan) if (l.percentUsed >= 100) once('limitDeaths', `${week}:${l.kind}`)
    const dead = new Set([...(saved.sets.limitDeaths ?? []), ...(mine.sets.limitDeaths ?? [])])
    if (dead.has(`${week}:five_hour`) && dead.has(`${week}:seven_day`)) award('3.withering')
  }
  if (top) {
    const window = `${top.kind}:${resetAt}`
    award('3.root')
    if (health < 20) award('3.scratch')
    if (health <= 10) once('halves', window)
    if (health <= 4) once('edges', window)
    if (percent >= 100) {
      once('deaths', window)
      // Out within the first hour of the period: five hours or seven days before the reset.
      const start = resetAt - (top.kind === 'five_hour' ? 5 * 3600_000 : 7 * 86_400_000)
      if (bypass && resetAt && now - start <= 3600_000) award('3.gameover')
    }
  }
  s.contextPct = used
  s.limitPct = percent
  await howDid($)
  settleSoon($)

  if (s.ready && top && health < 20) void tipOnce($, 'hearts', 'Your hearts dropped', 'apple', `Hearts are your usage limit. You have used ${Math.round(percent)}% of it.`)
  if (used >= 85) void tipOnce($, 'hungry', "You're getting hungry", 'bread', 'The context window is 85% full. Compact soon to eat.')

  if (s.ready && health < s.health) {
    hurt($, health, now)
  } else {
    if (s.ready && health >= s.health + 5 && s.dead) void resetMoment($, `seen:${now}`)
    s.health = health
    s.lostFrom = health
    s.dead = percent >= 100
  }
  s.ready = true
  redraw($)
}

async function refresh($: EngineInterface) {
  const usage = await $.session.usage()
  const theme = (await $.config.list()).find(row => row.key === 'theme')?.value
  s.light = typeof theme === 'string' && /light/i.test(theme)
  await applyUsage($, usage.context, usage.rateLimits)
}

// ---------- drawing ----------
const SCALE = 1.75
// More than a column of the desktop's code font is wide, so the HUD is drawn too wide and shrunk to fit, never short.
const PX_PER_COLUMN = 9
const H = 18
const TOP = 2
const BAR = TOP + 10
const LEVEL_Y = TOP + 4

const advance = (ch: string) => (ch === ' ' ? 4 : (GLYPH_W[ch] ?? 5) + 1)
const textWidth = (t: string) => [...t].reduce((w, ch) => w + advance(ch), 0)

function glyphs(t: string, x: number, y: number, fill: string) {
  let out = ''
  let cx = x
  for (const ch of t) {
    const d = GLYPH[ch]
    if (d) out += `<path transform="translate(${cx} ${y})" fill="${fill}" d="${d}"/>`
    cx += advance(ch)
  }
  return out
}
const clock = (ms: number) => {
  const d = new Date(ms)
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`
}
// A reset later today reads as a time; one further off, as a weekday.
const when = (ms: number, now: number) =>
  ms - now < 20 * 3600_000 ? clock(ms) : (['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][new Date(ms).getDay()] ?? clock(ms))
const limitName = () => (s.kind === 'seven_day' ? 'weekly limit' : '5-hour limit')

// `g` is the width in GUI pixels. The prompt box plays the hotbar: hearts sit
// over its left end, hunger over its right, and the XP bar spans it.
function hudSvg(now: number, g: number) {
  const RIGHT = g
  const hc = s.hardcore ? 'hc_' : ''
  const fx = s.hungerFx ? 'hf_' : 'food_'
  const low = s.health <= 4 && motion('shake')
  const regen = now - s.regenAt < s.regenMs && motion('regen')
  const blinkFor = now - s.damageAt
  const blink = blinkFor >= 0 && blinkFor < 20 * TICK && motion('flash')
  const starving = s.starving && motion('hunger')
  const period = s.food * 3 + 1
  const moving = low || regen || starving
  const len = starving ? period * Math.max(1, Math.round(100 / period)) : 100

  // The game re-seeds its random once a tick and draws hearts from the last to
  // the first, then the food; the same order here gives the same jitter.
  const heartY: number[][] = Array.from({ length: 10 }, () => [])
  const foodY: number[][] = Array.from({ length: 10 }, () => [])
  if (moving) {
    for (let t = 0; t < len; t++) {
      setSeed(Math.imul(t + 1, 312871))
      for (let i = 9; i >= 0; i--) heartY[i]!.push((low ? nextInt(2) : 0) + (regen && t % 25 === i ? -2 : 0))
      for (let i = 0; i < 10; i++) foodY[i]!.push(starving && t % period === 0 ? nextInt(3) - 1 : 0)
    }
  }
  const sway = (x: number, ys: number[]) =>
    ys.some(y => y !== 0)
      ? `<animateTransform attributeName="transform" type="translate" calcMode="discrete" dur="${(len * TICK) / 1000}s" repeatCount="indefinite" values="${ys.map(y => `${x} ${TOP + y}`).join(';')}"/>`
      : ''

  // Hovering a part shows what it tracks, as the browser's own tooltip.
  const tip = (text: string, x: number, y: number, w: number, h: number) =>
    `<title>${text.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</title><rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#000" fill-opacity="0"/>`
  const resets = s.resetAt ? ` Resets ${when(s.resetAt, now)}.` : ''

  let out = `<g>${tip(`${s.health * 5}% of your ${limitName()} left.${resets}`, 0, 0, 82, 13)}`
  for (let i = 0; i < 10; i++) {
    const x = i * 8
    const j = i * 2
    const now_ = j < s.health ? SPR[hc + (j + 1 === s.health ? 'half' : 'full')] : ''
    let flash = ''
    if (blink) {
      // 20 ticks, toggling every 3: white outlines and the lost hearts in white.
      const values = Array.from({ length: 20 }, (_, k) => (Math.floor((20 - k) / 3) % 2 === 1 ? 1 : 0)).join(';')
      const lost = j < s.lostFrom ? SPR[hc + (j + 1 === s.lostFrom ? 'half_blink' : 'full_blink')] : ''
      flash = `<g opacity="0">${SPR[hc + 'container_blink']}${lost}${now_}<animate attributeName="opacity" calcMode="discrete" dur="1.05s" begin="${(-blinkFor / 1000).toFixed(2)}s" fill="freeze" values="${values};0"/></g>`
    }
    out += `<g transform="translate(${x} ${TOP})">${sway(x, heartY[i]!)}${SPR[hc + 'container']}${now_}${flash}</g>`
  }
  out += `</g><g>${tip(`${s.food * 5}% of the context window left.`, RIGHT - 82, 0, 82, 13)}`
  for (let i = 0; i < 10; i++) {
    const x = RIGHT - i * 8 - 9
    const fill = i * 2 + 1 < s.food ? SPR[fx + 'full'] : i * 2 + 1 === s.food ? SPR[fx + 'half'] : ''
    out += `<g transform="translate(${x} ${TOP})">${sway(x, foodY[i]!)}${SPR[fx + 'empty']}${fill}</g>`
  }

  const xp = levelOf(s.xpShown)
  // The XP bar spans the full width, under the hearts and the hunger.
  const n = Math.ceil((g - 2) / 10)
  const bw = g
  const bx = 0
  out += `</g><g>${tip(`Level ${xp.level} · ${short(xp.toNext)} tokens to level ${xp.level + 1} · ${short(xp.tokens)} consumed`, bx, BAR - 1, bw, 7)}`
  // The bar is the game's own: its left cap, ten-pixel segments repeated to
  // the width (the last one cut where the width ends) and its right cap. Nothing is stretched.
  const { level, progress } = levelOf(s.xpShown)
  const piece = (i: number) => (i === n - 1 ? 18 : 1 + (i % 17))
  const pw = Math.min(bw, Math.floor(progress * (bw + 1)))
  let bar = XP_BG[0]!
  let fill = pw > 0 ? XP_FILL[0]! : ''
  for (let i = 0; i < n; i++) {
    const x = 1 + i * 10
    bar += `<g transform="translate(${x} 0)">${XP_BG[piece(i)]}</g>`
    if (x < pw) fill += `<g transform="translate(${x} 0)">${XP_FILL[piece(i)]}</g>`
  }
  bar += `<g transform="translate(${bw - 1} 0)">${XP_BG[19]}</g>`
  if (pw >= bw) fill += `<g transform="translate(${bw - 1} 0)">${XP_FILL[19]}</g>`
  out += `<g transform="translate(${bx} ${BAR})">${bar}</g>`
  if (pw > 0) out += `<svg x="${bx}" y="${BAR}" width="${pw}" height="5" viewBox="0 0 ${pw} 5">${fill}</svg>`
  if (level > 0) {
    const label = String(level)
    const x = Math.floor((g - textWidth(label)) / 2)
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) out += glyphs(label, x + dx, LEVEL_Y + dy, '#000')
    out += glyphs(label, x, LEVEL_Y, '#80ff20')
  }

  out += '</g>'

  // The apple in hand, after ItemInHandRenderer.applyEatTransform, flattened.
  const eaten = Math.floor((now - s.eatAt) / TICK)
  if (eaten >= 0 && eaten < 32 && motion('apple')) {
    const moves: string[] = []
    const turns: string[] = []
    for (let e = eaten; e < 32; e++) {
      const f = 32 - e + 1
      const f1 = f / 32
      const bob = f1 < 0.8 ? Math.abs(Math.cos((f / 4) * Math.PI) * 0.1) : 0
      const f3 = 1 - Math.pow(f1, 27)
      moves.push(`${(g / 2 + 30 - f3 * 6).toFixed(1)} ${(9 - f3 * 4 - bob * 30).toFixed(1)}`)
      turns.push(`${(-f3 * 30).toFixed(1)}`)
    }
    const dur = `${((32 - eaten) * TICK) / 1000}s`
    out +=
      `<g><animateTransform attributeName="transform" type="translate" calcMode="discrete" dur="${dur}" fill="freeze" values="${moves.join(';')}"/>` +
      `<g><animateTransform attributeName="transform" type="rotate" calcMode="discrete" dur="${dur}" fill="freeze" values="${turns.join(';')}"/>` +
      `<g transform="translate(-8 -8)">${SPR.golden_apple}</g></g>` +
      `<set attributeName="opacity" to="0" begin="${dur}"/></g>`
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${g} ${H}" width="${g * SCALE}" height="${H * SCALE}" shape-rendering="crispEdges">${out}</svg>`
}

// ---------- terminal: the same HUD as pixels, one frame a tick ----------
// Terminals that draw images (Ghostty, kitty) get the game's own layout at its
// own width, 182 pixels, composed here and swapped 20 times a second.
const FH = 18
const UP = 2
// Frame width in game pixels: the band's width, in whole XP-bar segments.
let FW = 182
// The engine's environment has these; the bundled type library does not yet.
const fromBase64 = (b64: string) => (Uint8Array as unknown as { fromBase64(s: string): Uint8Array }).fromBase64(b64)
const toBase64 = (bytes: Uint8Array) => (bytes as unknown as { toBase64(): string }).toBase64()
const sprites: Record<string, { w: number; h: number; d: Uint8Array }> = {}
function sprite(name: string) {
  let hit = sprites[name]
  if (!hit) {
    const [w, h, b64] = PIX[name]!
    hit = sprites[name] = { w, h, d: fromBase64(b64) }
  }
  return hit
}

function frame(tick: number, now: number) {
  const buf = new Uint8Array(FW * FH * 4)
  const dot = (x: number, y: number, r: number, g: number, b: number, a: number) => {
    if (x < 0 || y < 0 || x >= FW || y >= FH || a === 0) return
    const o = (y * FW + x) * 4
    const k = a / 255
    buf[o] = r * k + buf[o]! * (1 - k)
    buf[o + 1] = g * k + buf[o + 1]! * (1 - k)
    buf[o + 2] = b * k + buf[o + 2]! * (1 - k)
    buf[o + 3] = Math.max(buf[o + 3]!, a)
  }
  // Draws `count` columns of a sprite from column `from`, up to frame column `clip`.
  const put = (name: string, x: number, y: number, from = 0, count = Infinity, clip = Infinity) => {
    const { w, h, d } = sprite(name)
    for (let sy = 0; sy < h; sy++)
      for (let sx = 0; sx < Math.min(w - from, count); sx++) {
        if (x + sx >= clip) break
        const o = (sy * w + from + sx) * 4
        dot(x + sx, y + sy, d[o]!, d[o + 1]!, d[o + 2]!, d[o + 3]!)
      }
  }
  const digits = (t: string, x: number, y: number, r: number, g: number, b: number) => {
    let cx = x
    for (const ch of t) {
      const rows = DIGITS[ch]
      if (rows) rows.forEach((bits, ry) => { for (let rx = 0; rx < 8; rx++) if (bits & (1 << rx)) dot(cx + rx, y + ry, r, g, b, 255) })
      cx += advance(ch)
    }
  }

  // Minecraft's Gui.renderPlayerHealth, a tick at a time.
  const hc = s.hardcore ? 'hc_' : ''
  const fx = s.hungerFx ? 'hf_' : 'food_'
  const TOPY = 2
  setSeed(Math.imul(tick, 312871))
  const since = Math.floor((now - s.damageAt) / TICK)
  const blinking = since >= 0 && since < 20 && Math.floor((20 - since) / 3) % 2 === 1 && motion('flash')
  const regenHeart = now - s.regenAt < s.regenMs && motion('regen') ? tick % 25 : -1
  for (let i = 9; i >= 0; i--) {
    let y = TOPY
    if (s.health <= 4 && motion('shake')) y += nextInt(2)
    if (i === regenHeart) y -= 2
    const x = i * 8
    const j = i * 2
    put(hc + (blinking ? 'container_blink' : 'container'), x, y)
    if (blinking && j < s.lostFrom) put(hc + (j + 1 === s.lostFrom ? 'half_blink' : 'full_blink'), x, y)
    if (j < s.health) put(hc + (j + 1 === s.health ? 'half' : 'full'), x, y)
  }
  for (let i = 0; i < 10; i++) {
    let y = TOPY
    if (s.starving && motion('hunger') && tick % (s.food * 3 + 1) === 0) y += nextInt(3) - 1
    const x = FW - i * 8 - 9
    put(fx + 'empty', x, y)
    if (i * 2 + 1 < s.food) put(fx + 'full', x, y)
    if (i * 2 + 1 === s.food) put(fx + 'half', x, y)
  }
  const { level, progress } = levelOf(s.xpShown)
  // The bar's left cap, its ten-pixel segments repeated across the width, its
  // last segment and right cap: wider, never stretched.
  const n = (FW - 2) / 10
  const pw = Math.min(FW, Math.floor(progress * (FW + 1)))
  for (const [name, clip] of [['xp_bg', Infinity], ['xp_fill', pw]] as const) {
    put(name, 0, TOPY + 10, 0, 1, clip)
    for (let i = 0; i < n; i++) put(name, 1 + i * 10, TOPY + 10, 1 + 10 * (i === n - 1 ? 17 : i % 17), 10, clip)
    put(name, FW - 1, TOPY + 10, 181, 1, clip)
  }
  if (level > 0) {
    const label = String(level)
    const x = Math.floor((FW - textWidth(label)) / 2)
    const y = TOPY + 4
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) digits(label, x + dx, y + dy, 0, 0, 0)
    digits(label, x, y, 128, 255, 32)
  }

  // Whole-number upscale, so the terminal has little left to smooth.
  const out = new Uint8Array(FW * UP * FH * UP * 4)
  for (let y = 0; y < FH * UP; y++)
    for (let x = 0; x < FW * UP; x++) {
      const from = (Math.floor(y / UP) * FW + Math.floor(x / UP)) * 4
      const to = (y * FW * UP + x) * 4
      out[to] = buf[from]!
      out[to + 1] = buf[from + 1]!
      out[to + 2] = buf[from + 2]!
      out[to + 3] = buf[from + 3]!
    }
  return { rgba: toBase64(out), width: FW * UP, height: FH * UP }
}

const moving = (now: number) =>
  (s.health <= 4 && motion('shake')) || (s.starving && motion('hunger')) || (now - s.damageAt < 21 * TICK && motion('flash')) || (now - s.regenAt < s.regenMs && motion('regen'))

let tick = 0
let ticker: Timer | undefined
let bandId = ''
// Runs only while something on the HUD is moving, and stops itself after.
function animate($: EngineInterface) {
  if (ticker || !bandId) return
  ticker = $.clock.every(TICK, () => {
    void (async () => {
      const now = await $.clock.now()
      tick++
      await $.ui.blit({ requestId: bandId, key: 'hud', source: frame(tick, now) }).catch(() => {})
      if (!moving(now)) {
        ticker?.cancel()
        ticker = undefined
      }
    })()
  })
}

// The figures, in the game's font, each over the part it describes: usage over
// the hearts, context over the hunger. The level is already on the bar.
function labelSvg(now: number, g: number) {
  type Part = [string, string]
  const bright = s.light ? '#2a2a2a' : '#ffffff'
  const dim = s.light ? '#6a6a6a' : '#aaaaaa'
  const widthOf = (parts: Part[]) => parts.reduce((w, [t]) => w + textWidth(t), 0)
  let out = ''
  const write = (parts: Part[], x: number) => {
    let cx = x
    for (const [t, fill] of parts) {
      if (!s.light) out += glyphs(t, cx + 1, 2, '#2a2a2a')
      out += glyphs(t, cx, 1, fill)
      cx += textWidth(t)
    }
  }
  const name = s.kind === 'seven_day' ? 'weekly' : '5-hour'
  const left: Part[] = [[`${s.health * 5}%`, bright], [` ${name} limit`, dim], ...(s.resetAt ? ([[`, resets ${when(s.resetAt, now)}`, dim]] as Part[]) : [])]
  const right: Part[] = [[`${s.food * 5}%`, bright], [' context', dim]]
  write(left, 0)
  write(right, g - widthOf(right))
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${g} 11" width="${g * SCALE}" height="${11 * SCALE}" shape-rendering="crispEdges">${out}</svg>`
}

// ---------- the hotbar: five slots beside the bars ----------
// The region is 110 by 23 GUI pixels: the hotbar at (4, 1), with room around it
// for the selection frame, which is wider and taller than a slot. It is cut
// into one tile a slot so each can tell the pointer is over it.
const SLOTS = [
  { id: 'advancements', name: 'Advancements', short: 'Tree' },
  { id: 'music', name: 'Jukebox', short: 'Music' },
  { id: 'parrot', name: 'Parrot', short: 'Parrot' },
  { id: 'settings', name: 'Settings', short: 'Settings' },
] as const
const BAR_W = 10 + 20 * SLOTS.length
const BAR_H = 23
const tileX = (i: number) => (i === 0 ? 0 : 5 + 20 * i)
const tileW = (i: number) => (i === SLOTS.length - 1 ? BAR_W : 25 + 20 * i) - tileX(i)
// Drawn at the bars' height: the hotbar's 22 pixels across the hearts-to-XP span.
const HOTBAR_SCALE = 1.375
const cut = (i: number, body: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${tileX(i)} 0 ${tileW(i)} ${BAR_H}" width="${tileW(i) * HOTBAR_SCALE}" height="${BAR_H * HOTBAR_SCALE}" shape-rendering="crispEdges">${body}</svg>`
// Each tile carries the hotbar and its own icon only: the drawing is sent whole
// on every redraw, and five copies of every icon made it several times larger.
const tileSvg = (i: number) => cut(i, `<g transform="translate(${HOTBAR[i]![0]} 1)">${HOTBAR[i]![1]}</g><g transform="translate(${7 + 20 * i} 4)">${ICONS[SLOTS[i]!.id]}</g>`)

// ---------- the screens ----------
let screenOpen = false
// When the last slot was clicked, to time how long a screen takes to appear.
let pressedAt = 0
// A slot was clicked and its click sound has not been played yet.
let clickOwed = false

// What the last draws came to, kept in the store so a HUD that fails to appear
// can be looked into from outside: /minecraft debug shows it too.
let diag: Record<string, unknown> = {}
const record = (key: string, value: unknown) => {
  diag = { ...diag, [key]: value }
}

// The helper's screen server keeps one copy of it running with its window
// built, so a screen opens at once rather than after a cold start. Each copy of
// the helper has its own inbox; `alive` there is touched every two seconds.
const inboxOf = (home: string, bin: string) => `${home}/Library/Caches/minecraft-hud/screens/${bin.replace(/[^A-Za-z0-9]/g, '-')}`
const helperOf = ($: EngineInterface) => [`${$.plugin.root}/overlay/MCOverlay`, `${$.plugin.root}/assets`] as const

/** Starts the screen server if it is not running; returns at once. */
const startServer = ($: EngineInterface) => {
  const [bin, assets] = helperOf($)
  void $.process.run([bin, assets, 'serve'], { timeoutMs: 10_000 }).catch(() => undefined)
}

// Whether the server is there, looked at no more than every two seconds. A
// missing one is started again, at most twice a minute.
let alive = { at: 0, inbox: undefined as string | undefined }
let startedServerAt = 0
async function serverInbox($: EngineInterface) {
  const now = Date.now()
  if (now - alive.at < 2000) return alive.inbox
  alive = { at: now, inbox: undefined }
  const home = (await $.env.get('HOME')) ?? ''
  if (!home) return undefined
  const inbox = inboxOf(home, helperOf($)[0])
  const beat = await $.fs.stat(`${inbox}/alive`).catch(() => undefined)
  if (beat && now - beat.mtimeMs < 5000) alive.inbox = inbox
  else if (now - startedServerAt > 30_000) {
    startedServerAt = now
    startServer($)
  }
  return alive.inbox
}

/** Asks the screen server for a screen. Undefined when it is not there or did not take it in time. */
async function askServer($: EngineInterface, mode: string, spec: unknown, env: { volume: number; muted: string[]; click: number }) {
  alive.at = 0
  const inbox = await serverInbox($)
  if (!inbox) return undefined
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const deadline = Date.now() + 800
  await $.fs.write(`${inbox}/${id}.request`, JSON.stringify({ mode, json: JSON.stringify(spec), ...env, deadline }))
  // Taken when it is gone; past the deadline (and a little) the server drops it instead.
  for (;;) {
    if (!(await $.fs.exists(`${inbox}/${id}.request`))) break
    if (Date.now() > deadline + 200) return undefined
    await $.clock.sleep(20)
  }
  for (let quiet = 0; ; ) {
    const reply = await $.fs.read(`${inbox}/${id}.reply`).catch(() => undefined)
    if (reply !== undefined) {
      const said = JSON.parse(reply) as { dropped?: boolean; result?: Record<string, unknown> | null }
      return said.dropped ? undefined : { result: said.result ?? undefined }
    }
    // A server that stopped beating while the screen was up is not coming back.
    if (++quiet % 20 === 0) {
      const beat = await $.fs.stat(`${inbox}/alive`).catch(() => undefined)
      if (!beat || Date.now() - beat.mtimeMs > 6000) return { result: undefined }
    }
    await $.clock.sleep(100)
  }
}

// Shows one of the helper's screens over the whole display and waits for it to
// close. Resolves with what the screen decided, or nothing if it was closed.
async function screen($: EngineInterface, mode: string, spec: unknown) {
  if (screenOpen) return undefined
  screenOpen = true
  try {
    await $.store.set('timing', { mode, pressed: pressedAt, launching: Date.now() })
    const click = clickOwed ? CLICK : 0
    clickOwed = false
    const env = { volume: sounds ? volume : 0, muted, click }
    const served = await askServer($, mode, spec, env).catch(() => undefined)
    if (served) return served.result
    if (click) play($, 'click', click)
    // No server, or a busy one: start the screen cold, which also starts a server for next time.
    const [bin, assets] = helperOf($)
    const { stdout } = await $.process.run([bin, assets, mode, JSON.stringify(spec)], {
      timeoutMs: 600_000,
      env: { MC_VOLUME: String(env.volume), MC_MUTED: muted.join(',') },
    })
    const line = stdout.trim().split('\n').pop()
    return line ? (JSON.parse(line) as Record<string, unknown>) : undefined
  } catch {
    return undefined
  } finally {
    screenOpen = false
  }
}

async function showGuide($: EngineInterface) {
  await $.store.set('guided', true)
  await screen($, 'guide', {})
}

// New is what was earned since the tree was last opened, in any chat.
async function showAdvancements($: EngineInterface) {
  await settle($)
  saved = merge(await storedProgress($), blank())
  const now = await $.clock.now()
  const seen = Number((await $.store.get('treeSeenAt')) ?? 0)
  const shown = screen($, 'advancements', tree(merge(saved, mine), now, seen))
  await $.store.set('treeSeenAt', now)
  await shown
}

async function clearXP($: EngineInterface) {
  xpTotal = 0
  s.xpShown = 0
  await $.store.set('xp2', { units: 0 })
  redraw($)
}

const HOTBAR_BACK = 'Type /minecraft hotbar on to bring it back.'

async function showOptions($: EngineInterface) {
  // What another chat set last, so this one does not write over it.
  await syncShared($)
  const had = hotbar
  const chose = await screen($, 'options', { ...prefs(), level: levelOf(xpTotal).level })
  if (!chose) return
  sounds = chose.sounds !== false
  if (typeof chose.volume === 'number') volume = chose.volume
  fullscreen = chose.fullscreen !== false
  hotbar = chose.hotbar !== false
  const names = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [])
  muted = names(chose.muted)
  still = names(chose.still)
  await $.store.set('prefs', prefs())
  if (chose.resetXp === true) await clearXP($)
  if (had && !hotbar) $.ui.toast(`Hotbar hidden. ${HOTBAR_BACK}`)
  redraw($)
}

// The parrot lives on the desktop, drawn by the screen server; its state is a file every server watches.
const parrotFile = async ($: EngineInterface) => `${(await $.env.get('HOME')) ?? ''}/Library/Caches/minecraft-hud/parrot.json`
const parrotState = async ($: EngineInterface) =>
  JSON.parse((await $.fs.read(await parrotFile($)).catch(() => '{}')) || '{}') as Record<string, unknown>
const parrotOut = async ($: EngineInterface) => (await parrotState($)).on === true

async function toggleParrot($: EngineInterface) {
  if (!(await $.env.get('HOME'))) return
  const path = await parrotFile($)
  const state = await parrotState($)
  const on = state.on !== true
  if (clickOwed) {
    clickOwed = false
    play($, 'click', CLICK)
  }
  await $.fs.write(path, JSON.stringify({ ...state, on }))
  if (on && !(await serverInbox($))) startServer($)
  $.ui.toast(on ? 'Your parrot is out. Drag it anywhere; right-click for a new coat.' : 'Your parrot has gone to roost.')
}

// The jukebox: the screen chooses, and a player of the helper's own keeps
// playing after it closes. The music is read from the person's Minecraft install.
async function showJukebox($: EngineInterface) {
  const said = await screen($, 'jukebox', { announce: fullscreen && motion('nowplaying') })
  if (typeof said?.played === 'number' && said.played > 0) {
    const discs = Array.isArray(said.discs) ? said.discs.filter((d): d is string => typeof d === 'string' && d.startsWith('music_disc_')) : []
    if (discs.length) count('discs', discs.length)
    if (await parrotOut($)) award('4.parrots')
    if (Array.isArray(said.discs)) for (const disc of said.discs) if (typeof disc === 'string' && disc.startsWith('music_disc_')) once('discsHeard', disc)
    await settle($)
  }
}

// What a slot opens, by its button or by /minecraft <slot>.
function open($: EngineInterface, id: string) {
  if (screenOpen) return 'A screen is already open.'
  if (id === 'parrot') void toggleParrot($)
  else if (id === 'advancements') void showAdvancements($)
  else if (id === 'music') void showJukebox($)
  else if (id === 'help') void showGuide($)
  else void showOptions($)
  if (id === 'parrot') return 'Opening the parrot.'
  return id === 'help' ? 'Opening the guide.' : `Opening ${SLOTS.find(slot => slot.id === id)?.name.toLowerCase() ?? id}.`
}

const DEMOS = ['damage', 'low', 'apple', 'starve', 'death', 'reset', 'totem', 'advancement', 'xp', 'villager', 'hardcore', 'hunger', 'live', 'debug']
const SCREENS = ['help', 'parrot', 'advancements', 'music', 'settings', 'clear', 'reset all']

export const register: Register = (on, options) => {
  const chosen = options as { sounds?: boolean; volume?: string; fullscreen?: boolean }
  sounds = chosen.sounds !== false
  volume = (parseInt(chosen.volume ?? '100', 10) || 100) / 100
  fullscreen = chosen.fullscreen !== false

  on('session.start', async ($, e, next) => {
    for (const timer of timers) timer.cancel()
    timers = []
    ticker?.cancel()
    ticker = undefined
    await $.command.register({
      name: 'minecraft',
      description: 'Minecraft HUD: open a screen, preview a moment, or change sound',
      argumentHint: `[${[...SCREENS, ...DEMOS].join('|')}]`,
      immediate: true,
    })
    startServer($)
    chat = await $.session.id()
    const restored = await restore($).catch(() => '')
    if (restored) later($, 4000, () => $.ui.toast(restored))
    const replies = (await $.store.get(`replies:${chat}`)) as { n?: number } | number | undefined
    chatTurns = typeof replies === 'number' ? replies : (replies?.n ?? 0)
    saved = merge(await storedProgress($), blank())
    const held = (await $.store.get('xp2')) as { units?: number } | undefined
    const old = (await $.store.get('xp')) as { xp?: number } | undefined
    if (typeof held?.units === 'number') xpTotal = held.units
    else if (typeof old?.xp === 'number') {
      // The old count was 1,000 tokens a point, without cache reads.
      xpTotal = (old.xp * 1000) / XP_UNIT
      await $.store.set('xp2', { units: xpTotal })
    } else {
      // The level used to be kept per chat: the highest of those carries over.
      for (const key of await $.store.keys()) {
        if (!key.startsWith('xp:')) continue
        xpTotal = Math.max(xpTotal, ((await $.store.get(key)) as { xp?: number } | undefined)?.xp ?? 0)
        await $.store.delete(key)
      }
      xpTotal = (xpTotal * 1000) / XP_UNIT
      await $.store.set('xp2', { units: xpTotal })
    }
    s.xpShown = Math.floor(xpTotal)
    usePrefs((await $.store.get('prefs')) as Prefs | undefined)
    await refresh($)
    // Every chat takes up what the others changed whenever it is drawn, replies or is
    // sent a prompt; this slow look is for a chat on screen that does none of those.
    timers.push($.clock.every(30_000, () => void syncShared($).then(() => refresh($)).catch(() => undefined)))
    const dir = await sharedDir($)
    if (dir) await $.process.run(['/usr/bin/find', `${dir}/claims`, '-mindepth', '1', '-maxdepth', '1', '-mtime', '+2', '-exec', 'rmdir', '{}', '+'], { timeoutMs: 5000 }).catch(() => undefined)
    // The guide opens by itself once, on the first run anywhere, a moment after the chat appears.
    if (e.isInteractive && e.surface && !(await $.store.get('guided'))) later($, 3000, () => void showGuide($))
    for (const key of await $.store.keys()) {
      const stamp = Number(/(\d{13})/.exec(key)?.[1] ?? 0)
      if (stamp && stamp < (await $.clock.now()) - 2 * 24 * 3600_000) await $.store.delete(key)
      // A chat's reply count, a month after its last reply; one saved before it carried a time goes too.
      if (key.startsWith('replies:') && key !== `replies:${chat}`) {
        const held = (await $.store.get(key)) as { at?: number } | number | undefined
        if (typeof held !== 'object' || !held.at || held.at < (await $.clock.now()) - 30 * 86_400_000) await $.store.delete(key)
      }
    }

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await applyUsage($, e.context, e.rateLimits)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const usage = e.usage
    // A subagent's turns are its own, not replies to you.
    if (!e.agentId) {
      count('turns')
      if (++chatTurns >= 200) award('4.serious')
      if (chat) await $.store.set(`replies:${chat}`, { n: chatTurns, at: await $.clock.now() })
      // Judged on the whole reply: a failure late in it, or lines added back, count against it.
      if (turn.tools >= 100 && !turn.failedAny) award('5.thanks')
      if (Math.max(turn.removed - turn.added, turn.deleted - turn.inserted) >= 10_000) award('0.exile')
      if (/you(?:'|\u2019| a)re absolutely right/i.test(e.answer ?? '')) award('4.bullseye')
      await noteActivity($, await $.clock.now())
    } else {
      // A subagent finishing: the others still running are counted.
      void warPigs($)
    }
    if (usage) {
      // Every token consumed, cache reads included, so the count matches what usage tools report.
      const tokens = usage.input_tokens + usage.output_tokens + usage.cache_creation_input_tokens + (usage.cache_read_input_tokens ?? 0)
      count('tokens', tokens / 1000)
      if (!e.agentId) {
        turn.tokens += tokens
        if (turn.tokens >= 100_000_000) award('5.mint')
      }
      count(`tokensOn:${day(await $.clock.now())}`, tokens / 1000)
      await gainXP($, tokens)
    }
    settleSoon($)
    syncSoon($)

    return next(e)
  })

  on('session.compact', async ($, e, next) => {
    if (e.trigger !== 'precompute') {
      eat($, await $.clock.now())
      count('compacts')
      void tipOnce($, 'apple', 'Golden apple!', 'golden_apple', 'Compacting refilled your hunger bar.')
      if (e.trigger === 'auto') count('autos')
      settleSoon($)
    }

    return next(e)
  })

  // A new chat after /clear: its own turn count. The level stays.
  on('session.end', async ($, e, next) => {
    await settle($)
    if (e.reason === 'clear') {
      chatTurns = 0
      folders.clear()
      editsSinceTest = 0
      failedSinceEdits = false
      failing.clear()
      Object.assign(chatRun, { clean: 0, reverted: false, passedSince: false })
    }

    return next(e)
  })

  on('prompt.edit', async ($, e, next) => {
    s.lastEdit = await $.clock.now()

    return next(e)
  })

  // Bypass mode is hardcore: the hearts change and death reads "Game Over!".
  on('classic.UserPromptSubmit', async ($, e, next) => {
    syncSoon($)
    const hardcore = e.permission_mode === 'bypassPermissions'
    bypass = hardcore
    if (!s.demo && hardcore !== s.hardcore) {
      s.hardcore = hardcore
      redraw($)
    }
    const said = typeof e.prompt === 'string' ? e.prompt.trim() : ''
    const now = await $.clock.now()
    Object.assign(turn, { edits: 0, passed: false, committed: false, shipped: false, agents: 0, tools: 0, added: 0, removed: 0, inserted: 0, deleted: 0, failing: 0, testFailed: false, failedAny: false, tokens: 0, kinds: new Set<string>() })
    count('prompts')
    if (/\b(please|thanks|thank you)\b/i.test(said)) count('polite')
    // Back after a week or more with no prompt in any chat.
    const lastPrompt = Number((await $.store.get('lastPromptAt')) ?? 0)
    if (lastPrompt && now - lastPrompt >= 7 * 86_400_000) award('5.sweet')
    await $.store.set('lastPromptAt', now)
    const at = new Date(now)
    if (at.getHours() === 3 && at.getMinutes() === 33) award('5.spooky')
    await backInTime($, now)
    await noteActivity($, now)
    settleSoon($)

    return next(e)
  })

  // Every tool call is counted.
  on('tool.call', async ($, e, next) => {
    const named = String((e as unknown as Record<string, unknown>).tool ?? '')
    if (named === 'Agent' || named === 'Task') void later($, 1500, () => void howDid($).then(() => warPigs($)))
    const ran = await next(e)
    const failed = 'isError' in ran && ran.isError === true
    const input = e as unknown as Record<string, unknown>
    const tool = String(input.tool ?? '')
    const now = await $.clock.now()
    count('tools')
    if (++turn.tools >= 500) award('2.hero')
    turn.kinds.add(tool)
    if (turn.kinds.size >= 15) award('5.furious')
    if (failed) turn.failedAny = true
    if (EDITS.has(tool) && !failed) {
      count('edits')
      turn.edits++
      editsSinceTest++
      // Lines in and out, for the two secrets about the size of a reply.
      const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [input]
      for (const edit of edits) {
        turn.removed += lineCount(edit.old_string)
        turn.added += lineCount(edit.new_string)
      }
      if (tool === 'Write') turn.added += lineCount(input.content)
      bigReply()
    }
    const touched = typeof input.file_path === 'string' ? input.file_path : typeof input.notebook_path === 'string' ? input.notebook_path : ''
    if (touched.includes('/') && !failed && (tool === 'Read' || EDITS.has(tool))) {
      folders.add(touched.slice(0, touched.lastIndexOf('/')))
      if (folders.size >= 25) award('2.tourist')
      if (folders.size >= 150) award('2.adventuring')
    }
    if (tool === 'Read' && !failed) {
      const path = typeof input.file_path === 'string' ? input.file_path : ''
      if (/\.(png|jpe?g|gif|webp)$/i.test(path)) award('2.bird')
    }
    if (tool === 'WebFetch' && !failed) count('fetches')
    if ((tool === 'Agent' || tool === 'Task') && !failed) {
      count('agents')
      if (++turn.agents >= 5) award('2.help')
    }
    if (tool === 'Bash') {
      const command = typeof input.command === 'string' ? input.command : ''
      count('commands')
      if (failed) count('failures')
      chatRun.clean = failed ? 0 : chatRun.clean + 1
      if (chatRun.clean >= 1000) award('2.lock')
      const said = JSON.stringify(ran)
      if (isTest(command)) {
        const key = testKey(command)
        if (failed) {
          count('testFails')
          turn.testFailed = true
          failing.add(key)
          failedSinceEdits = true
          const counts = [...said.matchAll(/(\d+)\s+(?:failed|failing|failures?)\b/gi)].map(m => Number(m[1]))
          turn.failing = Math.max(turn.failing, ...counts)
        } else {
          count('passes')
          turn.passed = true
          if (turn.testFailed) award('1.sniper')
          if (turn.failing >= 25) award('1.arbalistic')
          if (turn.failing >= 100) award('5.tactical')
          if (chatRun.reverted) chatRun.passedSince = true
          if (failing.delete(key)) count('cures')
          if (editsSinceTest >= 10 && !failedSinceEdits) award('1.diamonds')
          editsSinceTest = 0
          failedSinceEdits = false
        }
      }
      if (!failed) {
        if (git('commit').test(command) && !/--dry-run\b/.test(command)) {
          count('commits')
          once('commitDays', day(now))
          turn.committed = true
          if (chatRun.reverted && chatRun.passedSince) award('0.sender')
        }
        // What git counts at a commit: "12 insertions(+), 10500 deletions(-)".
        if (git('commit|merge|pull|revert|cherry-pick').test(command)) {
          turn.inserted += Number(/(\d+) insertions?\(\+\)/.exec(said)?.[1] ?? 0)
          turn.deleted += Number(/(\d+) deletions?\(-\)/.exec(said)?.[1] ?? 0)
          bigReply()
        }
        if (git('revert').test(command)) Object.assign(chatRun, { reverted: true, passedSince: false })
        // A revert, a passing test run and a commit in one command, in that order.
        if (git('revert').test(command) && isTest(command) && git('commit').test(command)) award('0.sender')
        // A revert of a revert: git titles it Revert "Revert ...".
        if (git('revert').test(command) && /Revert \\*"Revert/.test(said)) award('5.blowback')
        if (git('push').test(command) && /\s(--force(-with-lease)?|-f)\b|\s\+\S/.test(command) && /(?:\s|:)(?:main|master)(?=\s|$)/.test(command)) award('0.frightening')
        if (/\bgh\s+pr\s+create\b/.test(command)) {
          count('prs')
          turn.shipped = true
        }
        // --auto only queues the merge: it may never happen.
        if (/\bgh\s+pr\s+merge\b/.test(command) && !/--auto\b/.test(command)) count('merges')
      }
      if (git('merge|rebase|pull|cherry-pick|stash\\s+pop').test(command) && JSON.stringify(ran).includes('CONFLICT')) award('0.sticky')
      if (turn.edits > 0 && turn.passed && turn.committed && turn.shipped) award('0.twobirds')
    }

    return ran
  })

  // A villager's "hmm" whenever Claude stops to ask you something.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    play($, pick(['villager1', 'villager2', 'villager3']))
    const ran = await next(e)
    const asked = (e as unknown as { questions?: unknown }).questions
    if (!('isError' in ran && ran.isError === true)) count('questions', Array.isArray(asked) ? Math.max(1, asked.length) : 1)

    return ran
  })

  // /minecraft <moment> previews a moment with made-up figures; /minecraft live returns.
  on('command.run', { command: 'minecraft' }, async ($, e) => {
    const typed = e.args.trim()
    // /minecraft mute, /minecraft unmute, /minecraft volume 50, /minecraft fullscreen on|off, /minecraft hotbar on|off
    const [word, value] = typed.split(/\s+/)
    if (word === 'parrot' || word === 'advancements' || word === 'settings' || word === 'help') {
      return { text: open($, word) }
    }
    // /minecraft music opens the jukebox; with pause, next, prev or stop it tells the player.
    if (word === 'music') {
      const told = { pause: 'toggle', play: 'toggle', resume: 'toggle', toggle: 'toggle', next: 'next', skip: 'next', prev: 'prev', back: 'prev', stop: 'stop' }[value ?? '']
      if (!told) return { text: open($, 'music') }
      await $.process.run([`${$.plugin.root}/overlay/MCOverlay`, `${$.plugin.root}/assets`, 'music', told], { timeoutMs: 5000 })
      return { text: told === 'stop' ? 'Music stopped.' : told === 'toggle' ? 'Paused or resumed.' : 'Skipped.' }
    }
    if (word === 'clear') {
      await clearXP($)
      return { text: 'Your level is back to 0. Advancements are kept.' }
    }
    // A fresh start: every advancement, the XP and the backup. Asked twice.
    if (word === 'reset' && value === 'all') {
      if (typed.split(/\s+/)[2] !== 'confirm') {
        return { text: 'This erases every advancement, your XP and level, and the backup of them. Settings are kept. To do it, type /minecraft reset all confirm.' }
      }
      for (const key of await $.store.keys()) {
        if (key !== 'prefs' && !key.startsWith('tip:') && key !== 'guided') await $.store.delete(key)
      }
      const file = await backupFile($)
      if (file) await $.fs.write(file, JSON.stringify({ at: await $.clock.now(), data: {} })).catch(() => undefined)
      saved = blank()
      mine = blank()
      pending = []
      xpTotal = 0
      s.xpShown = 0
      redraw($)
      return { text: 'Everything is reset: no advancements, level 0, and an empty backup. Chats already open pick it up as they go.' }
    }
    if (['mute', 'unmute', 'volume', 'fullscreen', 'hotbar'].includes(word ?? '')) {
      if (word === 'mute') sounds = false
      if (word === 'unmute') sounds = true
      if (word === 'volume') {
        const percent = parseInt(value ?? '', 10)
        if (!(percent >= 0 && percent <= 100)) return { text: 'Use /minecraft volume with a number from 0 to 100.' }
        volume = percent / 100
        sounds = percent > 0
      }
      if (word === 'fullscreen') {
        if (value !== 'on' && value !== 'off') return { text: 'Use /minecraft fullscreen on or /minecraft fullscreen off.' }
        fullscreen = value === 'on'
      }
      if (word === 'hotbar') {
        if (value !== 'on' && value !== 'off') return { text: 'Use /minecraft hotbar on or /minecraft hotbar off.' }
        hotbar = value === 'on'
        redraw($)
      }
      const status = `Sounds ${sounds ? `on at ${Math.round(volume * 100)}%` : 'off'}. Full-screen moments ${fullscreen ? 'on' : 'off'}. Hotbar ${hotbar ? 'on.' : `off. ${HOTBAR_BACK}`}`
      await $.store.set('prefs', prefs())
      if (sounds) play($, 'orb', 0.6)
      return { text: status }
    }
    // /minecraft advancement [task|goal|challenge] <title> shows a toast of your own.
    if ((word === 'advancement' || word === 'achievement') && value) {
      const words = typed.split(/\s+/).slice(1)
      const type = ['task', 'goal', 'challenge'].includes(words[0] ?? '') ? words.shift()! : 'task'
      const title = words.join(' ') || 'Test Driven'
      await overlay($, 1, ['advancement', type, title, type === 'challenge' ? 'nether_star' : type === 'goal' ? 'diamond' : 'emerald'])
      return { text: `${title}.` }
    }
    const scene = typed === 'achievement' ? 'advancement' : typed
    const now = await $.clock.now()
    if (!DEMOS.includes(scene)) return { text: `Moments: ${DEMOS.join(', ')}. Screens: help, advancements, music, parrot, settings. Music: music pause|next|prev|stop. Also: clear (XP only), reset all, mute, unmute, volume 0-100, fullscreen on|off, hotbar on|off.` }
    if (scene === 'debug') return { text: `${JSON.stringify(diag)} · ready ${s.ready} · demo ${s.demo} · hotbar ${hotbar} · band: ${JSON.stringify(seen)} · health ${s.health} · food ${s.food} · xp ${s.xpShown}` }
    if (scene === 'villager') {
      play($, pick(['villager1', 'villager2', 'villager3']))
      return { text: 'Hmm.' }
    }
    if (scene === 'totem') {
      await overlay($, TOTEM_LOUDNESS, ['totem'])
      return { text: 'Totem of Undying.' }
    }
    if (scene === 'advancement') {
      await overlay($, 1, ['advancement', 'challenge', 'Test Driven', 'nether_star', 'Pass the tests on the first try.'])
      return { text: 'Advancement.' }
    }
    if (scene === 'live') {
      s.demo = false
      s.hardcore = bypass
      s.dead = false
      s.starving = false
      await refresh($)
      return { text: 'Showing live figures.' }
    }
    if (!s.demo) Object.assign(s, { demo: true, ready: true, health: 17, lostFrom: 17, food: 14, starving: false, dead: false })
    if (scene === 'damage') hurt($, Math.max(1, s.health - 7), now)
    if (scene === 'low') Object.assign(s, { health: 4, lostFrom: 4, dead: false })
    if (scene === 'apple') {
      eat($, now)
      later($, 32 * TICK, () => Object.assign(s, { food: 20, starving: false }))
    }
    if (scene === 'starve') Object.assign(s, { food: 3, starving: true })
    if (scene === 'death') {
      s.kind = s.kind || 'five_hour'
      hurt($, 0, now)
    }
    if (scene === 'reset') {
      countdown($, now + 10_000)
      later($, 10_000, () => {
        void resetMoment($, `demo:${now}`)
        void totemMoment($, `demo:${now}`)
      })
    }
    if (scene === 'xp') await gainXP($, 3_000_000, false)
    if (scene === 'hardcore') s.hardcore = !s.hardcore
    if (scene === 'hunger') s.hungerFx = !s.hungerFx
    redraw($)

    return { text: `Previewing: ${scene}. /minecraft live returns to your real figures.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    syncSoon($)
    record('asked', { at: Date.now(), surface: e.surface, ready: s.ready, survey: Boolean(e.props.hasSurvey), columns: e.props.bodyColumns })
    if (e.props.hasSurvey || !s.ready) return next(e)
    const now = await $.clock.now()
    const usage = `${s.health * 5}% of your ${limitName()} left${s.resetAt ? ` · resets ${clock(s.resetAt)}` : ''}`
    const context = `${s.food * 5}% of context left`
    const seconds = Math.ceil((s.countdownTo - now) / 1000)
    const soon = s.countdownTo > now ? `Totem of Undying in ${seconds}s: your weekly limit is resetting` : ''

    if (e.surface === 'terminal') {
      const { Box, Image, Text } = $.ui.resolve(e)
      bandId = e.requestId
      if (moving(now)) animate($)
      // Minecraft's own width: 182 game pixels, which 42 columns by 2 rows holds
      // at close to their own shape.
      FW = 182
      return (
        <Box flexDirection="column" alignItems="center">
          <Image key="hud" source={frame(tick, now)} columns={Math.round((FW * 42) / 182)} rows={2} alt={`${usage} · ${context}`} />
          {s.dead ? <Text color="red">{`You died! Out of your ${limitName()}.${s.resetAt ? ` Respawn at ${clock(s.resetAt)}.` : ''}`}</Text> : null}
          {soon ? <Text dimColor>{soon}</Text> : null}
        </Box>
      )
    }
    if (e.surface !== 'desktop') {
      const { Text } = $.ui.resolve(e)
      return <Text dimColor>{soon || `${usage} · ${context}`}</Text>
    }

    try {
    const { Box, Button, Svg, Text } = $.ui.resolve(e)
    const theirs = await next(e)
    seen = { bodyColumns: e.props.bodyColumns, viewport: e.viewport ?? null }
    // The desktop reports the band in text columns, not pixels. The HUD is drawn
    // for a little more than it can hold and given no width of its own, so the
    // desktop shrinks it to the room the hotbar leaves: it always meets both edges.
    const room = ((e.props.bodyColumns || 95) + 5) * PX_PER_COLUMN - (hotbar ? BAR_W * HOTBAR_SCALE : 0)
    const g = Math.max(182, Math.floor(room / SCALE))
    // The hotbar: each slot is its picture with buttons laid over it, from its
    // left edge to its right. The app lets no picture take a click, so buttons
    // do: their labels are blank braille cells, which draw nothing, and a slot
    // holds as many as cover it, the rest clipped (a longer label would be cut
    // to a visible ellipsis). Each slot's buttons start at its own edge, so
    // nothing they measure can add up from one slot to the next.
    const BLANK = '\u2800'
    const slots = !hotbar
      ? null
      : h(
          Box,
          { flexDirection: 'row', flexShrink: 0 },
          ...SLOTS.map((slot, i) =>
            h(
              Box,
              { flexShrink: 0 },
              h(Svg, { source: tileSvg(i), alt: `${slot.name}: /minecraft ${slot.id}`, width: tileW(i) * HOTBAR_SCALE, height: BAR_H * HOTBAR_SCALE }),
              h(
                Box,
                { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, flexDirection: 'row', alignItems: 'stretch', overflow: 'hidden' },
                ...Array.from({ length: 3 }, (_, n) =>
                  h(
                    Box,
                    { flexShrink: 0 },
                    h(Button, {
                      key: n === 0 ? `open-${slot.id}` : `open-${slot.id}-${n}`,
                      label: BLANK,
                      plain: true,
                      onPress: () => {
                        pressedAt = Date.now()
                        // The click plays from the screen server, the instant the screen opens.
                        clickOwed = true
                        const said = open($, slot.id)
                        if (!said.startsWith('Opening')) {
                          clickOwed = false
                          play($, 'click', CLICK)
                          $.ui.toast(said)
                        }
                      },
                    }),
                  ),
                ),
              ),
            ),
          ),
        )
    record('drew', { at: Date.now(), g, hotbar, theirs: theirs === null || theirs === undefined ? 'nothing' : typeof theirs })
    return (
      <Box flexDirection="column">
        <Box flexDirection="row" alignItems="flex-end">
          <Box key="hud" flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
            <Box display="none" flexDirection="column" hover={{ display: 'flex' }}>
              {hotbar ? null : <Text dimColor>{`Hotbar hidden. ${HOTBAR_BACK}`}</Text>}
              <Svg source={labelSvg(now, g)} alt={`${usage}. ${context}.`} />
            </Box>
            <Svg source={hudSvg(now, g)} alt={`${usage}. ${context}. Level ${levelOf(s.xpShown).level}.`} />
          </Box>
          {slots}
        </Box>
        {s.dead ? <Text color="red">{`Out of your ${limitName()}.${s.resetAt ? ` Respawn at ${clock(s.resetAt)}.` : ''}`}</Text> : null}
        {soon ? <Text dimColor>{soon}</Text> : null}
        {theirs}
      </Box>
    )
    } catch (problem) {
      record('error', { at: Date.now(), message: String(problem) })
      return next(e)
    }
  })
}
