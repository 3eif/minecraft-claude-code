import { ADVANCEMENTS, TABS } from './advancements'

// What has been counted and earned, for all time and across every chat. Three
// kinds of figure, because several chats write to it at once:
//   n     counts that add up (edits, commands, tokens in thousands)
//   max   figures that only ever rise (level)
//   sets  things counted once each however many chats see them (a day, a
//         limit window, a chat), so a set's size is the count
export type Progress = {
  earned: Record<string, number>
  n: Record<string, number>
  max: Record<string, number>
  sets: Record<string, string[]>
}

export const blank = (): Progress => ({ earned: {}, n: {}, max: {}, sets: {} })

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
  for (const [id, at] of [...Object.entries(mine.earned), ...Object.entries(base.earned ?? {})]) out.earned[id] = Math.min(out.earned[id] ?? at, at)
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

// ---------- what the enchanting table asks a model for ----------
export const ENCHANTMENTS = [
  { name: 'Clarity I', need: 1, desc: 'Tidy the wording and keep it short.', how: 'Tidy it: fix wording, grammar and ambiguity. Keep it about the same length and keep every request in it.' },
  {
    name: 'Clarity II',
    need: 3,
    desc: 'Restructure into goal, context and constraints.',
    how: 'Restructure it into a clear prompt: the goal first, then the context a reader needs, then constraints. Short paragraphs or a brief list. Add nothing the author did not imply.',
  },
  {
    name: 'Clarity III',
    need: 5,
    desc: 'A full brief with acceptance criteria and what to verify.',
    how: 'Turn it into a full brief: the goal, context, constraints, acceptance criteria, and what to verify before calling it done. Where the author left a real decision open, say so as a question rather than guessing.',
  },
] as const

export const enchantSystem = (how: string) =>
  `You rewrite a prompt that a developer is about to send to a coding agent. ${how} Keep the author's intent, voice and every specific (names, paths, numbers). Reply with the rewritten prompt only: no preamble, no quotes, no explanation.`
