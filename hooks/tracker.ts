import { ADVANCEMENTS, RENAMED, TABS } from './advancements'

// What has been counted and earned, for all time and across every chat. Three
// kinds of figure, because several chats write to it at once:
//   n     counts that add up (edits, commands, tokens in thousands)
//   max   figures that only ever rise (level)
//   sets  things counted once each however many chats see them (a day, a
//         limit window, a chat), so a set's size is the count
export type Progress = {
  // 2 since the tabs were regrouped: advancements saved before it carry their old ids.
  v?: number
  earned: Record<string, number>
  n: Record<string, number>
  max: Record<string, number>
  sets: Record<string, string[]>
}

export const blank = (): Progress => ({ v: 2, earned: {}, n: {}, max: {}, sets: {} })

// How many of each set are kept: enough to cover what any advancement counts in it.
const SET_LIMIT = 400
const SET_LIMITS: Record<string, number> = { starves: 2000 }

/** What one chat has added since it last saved, laid over what the store holds. */
export function merge(stored: Progress | undefined, mine: Progress): Progress {
  const out = blank()
  const base = stored ?? blank()
  for (const key of new Set([...Object.keys(base.n ?? {}), ...Object.keys(mine.n)])) out.n[key] = (base.n?.[key] ?? 0) + (mine.n[key] ?? 0)
  for (const key of new Set([...Object.keys(base.max ?? {}), ...Object.keys(mine.max)])) out.max[key] = Math.max(base.max?.[key] ?? 0, mine.max[key] ?? 0)
  for (const key of new Set([...Object.keys(base.sets ?? {}), ...Object.keys(mine.sets)])) {
    out.sets[key] = [...new Set([...(base.sets?.[key] ?? []), ...(mine.sets[key] ?? [])])].sort().slice(-(SET_LIMITS[key] ?? SET_LIMIT))
  }
  // Saved before the regrouping: each id read as what it is now, and one removed since dropped.
  const was = Object.entries(base.earned ?? {})
  const held = base.v === 2 ? was : was.flatMap(([id, at]) => (RENAMED[id] ? [[RENAMED[id], at] as [string, number]] : []))
  for (const [id, at] of [...Object.entries(mine.earned), ...held]) out.earned[id] = Math.min(out.earned[id] ?? at, at)
  return out
}

export const day = (ms: number) => {
  const d = new Date(ms)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** How many days in a row end at `today`, in a list of dates. */
export function streak(days: readonly string[], today: number) {
  const have = new Set(days)
  const at = new Date(today)
  let run = 0
  // Back a calendar day at a time: a day is 23 or 25 hours long when the clocks change.
  while (have.has(day(at.getTime()))) {
    run++
    at.setDate(at.getDate() - 1)
  }
  return run
}

/** The figure an advancement's counter stands at. */
export function figure(p: Progress, counter: string, now: number) {
  if (counter === 'dayStreak') return streak(p.sets.days ?? [], now)
  if (counter === 'earned') return ADVANCEMENTS.filter(a => p.earned[a.id]).length
  // A limit hit in a period that has since ended came back: counted from the deaths too,
  // since the respawns were once missed when a new period's figures arrived first.
  if (counter === 'respawns') {
    const ended = (p.sets.deaths ?? []).map(w => w.split(':')[1] ?? '').filter(at => Number(at) > 0 && Number(at) <= now)
    return new Set([...(p.sets.respawns ?? []), ...ended]).size
  }
  // Music discs alone: the soundtrack's albums were once counted with them.
  if (counter === 'discsHeard') return (p.sets.discsHeard ?? []).filter(d => d.startsWith('music_disc_')).length
  if (counter === 'commitStreak') return streak(p.sets.commitDays ?? [], now)
  if (counter in p.max) return p.max[counter] ?? 0
  if (counter in p.sets) return p.sets[counter]?.length ?? 0
  return p.n[counter] ?? 0
}

/** The advancements whose counters have reached their mark and are not yet earned. */
export function due(p: Progress, now: number) {
  return ADVANCEMENTS.filter(a => a.counter && !p.earned[a.id] && figure(p, a.counter, now) >= a.need)
}

const short = (n: number) =>
  n >= 1e9 ? `${+(n / 1e9).toFixed(1)}B` : n >= 1e6 ? `${+(n / 1e6).toFixed(1)}M` : n >= 1e4 ? `${Math.floor(n / 1e3)}K` : String(Math.floor(n))

/**
 * The tree as the advancements screen takes it. A secret one stays out until it is
 * earned. One earned after `seen` (when the tree was last opened) is new, and the
 * tree opens on the tab of the newest.
 */
export function tree(p: Progress, now: number, seen = now) {
  const newest = ADVANCEMENTS.filter(a => (p.earned[a.id] ?? 0) > seen).sort((a, b) => p.earned[b.id]! - p.earned[a.id]!)[0]
  return {
    ...(newest ? { open: newest.tab } : {}),
    tabs: TABS.map((tab, index) => ({
      ...tab,
      items: ADVANCEMENTS.filter(a => a.tab === index && (!a.secret || p.earned[a.id])).map(a => {
        const earned = Boolean(p.earned[a.id])
        const at = a.counter ? figure(p, a.counter, now) : 0
        const scale = a.counter === 'tokens' ? 1000 : 1
        return {
          id: a.id,
          parent: a.parent,
          name: a.name,
          frame: a.frame,
          icon: a.icon,
          desc: a.desc,
          earned,
          // When, for the screen to write as a date in this Mac's own time.
          ...(earned ? { at: p.earned[a.id], fresh: p.earned[a.id]! > seen } : {}),
          progress: !earned && a.counter && a.need > 1 ? `${short(at * scale)}/${short(a.need * scale)}` : null,
          part: a.counter ? Math.min(1, at / a.need) : 0,
        }
      }),
    })),
  }
}

/** What the Statistics screen lists, as the game's General tab does: each figure's name and its count. */
export function stats(p: Progress, now: number): [string, string][] {
  const whole = (counter: string) => String(Math.floor(figure(p, counter, now))).replace(/\B(?=(\d{3})+$)/g, ',')
  return [
    ['Playing since', p.sets.first?.[0] ?? day(now)],
    ['Tokens used', short(figure(p, 'tokens', now) * 1000)],
    ['Advancements made', `${figure(p, 'earned', now)}/${ADVANCEMENTS.length}`],
    ['Days in a row', whole('dayStreak')],
    ['Prompts sent', whole('prompts')],
    ['Replies', whole('turns')],
    ['Tool calls', whole('tools')],
    ['Edits made', whole('edits')],
    ['Commands run', whole('commands')],
    ['Commands failed', whole('failures')],
    ['Test runs passed', whole('passes')],
    ['Test runs failed', whole('testFails')],
    ['Commits', whole('commits')],
    ['Pull requests opened', whole('prs')],
    ['Pull requests merged', whole('merges')],
    ['Subagents started', whole('agents')],
    ['Web pages fetched', whole('fetches')],
    ['Questions answered', whole('questions')],
    ['Chats compacted', whole('compacts')],
    ['Limits hit', whole('deaths')],
    ['Music discs played', whole('discs')],
  ]
}

// ---------- reading what a command was ----------
// What may stand in front of a command and still leave it that command.
const RUNNER = /^(?:\w+=\S*\s+|(?:sudo|time|env|npx|bunx|pnpx|timeout\s+\S+|(?:pnpm|yarn|bun)\s+(?:exec|dlx|x)|(?:uv|poetry|pipenv|pdm|hatch)\s+run|bundle\s+exec|python3?\s+-m)\s+)+/

/** A command line's commands, one for each side of a `&&`, `;` or pipe, without what runs them. */
export const segments = (command: string) => command.split(/&&|\|\||[;|\n]/).map(part => part.trim().replace(/^\(\s*/, '').replace(RUNNER, ''))

// A test runner started, not its name passing by in a path or a search.
const TEST =
  /^(?:(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test\b|(?:vitest|jest|pytest|unittest|rspec|phpunit|ctest|tox|nox)\b|(?:cargo|go|swift|mix|dotnet|gradle|make|deno|flutter|dart|rails|rake)\s+test\b|cargo\s+nextest\b|playwright\s+test\b|(?:\.\/)?mvnw?\s+(?:\S+\s+)*(?:test|verify)\b|xcodebuild\b.*\btest\b|(?:\.\/)?gradlew\s+(?:\S+\s+)*test\b)/
const testRun = (command: string) => segments(command).map(part => TEST.exec(part)?.[0]).find(run => run !== undefined)
export const isTest = (command: string) => testRun(command) !== undefined

/** A test command with its changing parts dropped, so a rerun reads as the same command. */
export const testKey = (command: string) => testRun(command)?.split(/\s+/).slice(0, 2).join(' ') ?? 'test'
