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

const SET_LIMIT = 400

/** What one chat has added since it last saved, laid over what the store holds. */
export function merge(stored: Progress | undefined, mine: Progress): Progress {
  const out = blank()
  const base = stored ?? blank()
  for (const key of new Set([...Object.keys(base.n ?? {}), ...Object.keys(mine.n)])) out.n[key] = (base.n?.[key] ?? 0) + (mine.n[key] ?? 0)
  for (const key of new Set([...Object.keys(base.max ?? {}), ...Object.keys(mine.max)])) out.max[key] = Math.max(base.max?.[key] ?? 0, mine.max[key] ?? 0)
  for (const key of new Set([...Object.keys(base.sets ?? {}), ...Object.keys(mine.sets)])) {
    out.sets[key] = [...new Set([...(base.sets?.[key] ?? []), ...(mine.sets[key] ?? [])])].sort().slice(-SET_LIMIT)
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
  let run = 0
  while (have.has(day(today - run * 86_400_000))) run++
  return run
}

/** The figure an advancement's counter stands at. */
export function figure(p: Progress, counter: string, now: number) {
  if (counter === 'dayStreak') return streak(p.sets.days ?? [], now)
  if (counter === 'earned') return ADVANCEMENTS.filter(a => p.earned[a.id]).length
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

/** The tree as the advancements screen takes it. A secret one stays out until it is earned. */
export function tree(p: Progress, now: number) {
  return {
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
          progress: !earned && a.counter && a.need > 1 ? `${short(at * scale)}/${short(a.need * scale)}` : null,
          part: a.counter ? Math.min(1, at / a.need) : 0,
        }
      }),
    })),
  }
}

// ---------- reading what a command was ----------
export const isTest = (command: string) =>
  /\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\b(vitest|jest|pytest|rspec|phpunit)\b|\b(cargo|go|swift|mix|dotnet|gradle|make)\s+test\b|\bxcodebuild\b.*\btest\b|\bgradlew\s+test\b/.test(command)

/** A test command with its changing parts dropped, so a rerun reads as the same command. */
export const testKey = (command: string) => (/(?:npm|pnpm|yarn|bun|cargo|go|swift|mix|dotnet|gradle|make)\s+(?:run\s+)?test|vitest|jest|pytest|rspec|phpunit|xcodebuild/.exec(command)?.[0] ?? 'test')
