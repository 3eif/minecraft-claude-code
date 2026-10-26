import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { ADVANCEMENTS, RENAMED, TABS } from '../hooks/advancements'
import { blank, figure, merge, streak, tree } from '../hooks/tracker'

// ---------- the record, without the engine ----------

test('every advancement has a parent in its own tab, and every id is unique', async () => {
  const ids = new Set(ADVANCEMENTS.map(a => a.id))
  expect(ids.size).toBe(ADVANCEMENTS.length)
  for (const a of ADVANCEMENTS) {
    if (a.parent) expect(ADVANCEMENTS.find(p => p.id === a.parent)?.tab).toBe(a.tab)
  }
  expect(TABS.length).toBe(6)
})

test('progress saved before the regrouping is read under the new ids', async () => {
  const old = { earned: { '3.hunter': 10, '0.stone': 20, '3.brewery': 30 }, n: {}, max: {}, sets: {} }
  const now = merge(old, blank())
  expect(now.v).toBe(2)
  expect(now.earned[RENAMED['3.hunter']!]).toBe(10)
  expect(now.earned['0.root']).toBe(20)
  // Removed since: dropped, never read as whatever now has its number.
  expect(Object.keys(now.earned).length).toBe(2)
  // Read again, a saved record keeps its ids.
  expect(merge(now, blank()).earned).toEqual(now.earned)
})

test('a streak counts calendar days, across a change of the clocks', async () => {
  const days = ['2026-03-07', '2026-03-08', '2026-03-09']
  expect(streak(days, new Date(2026, 2, 9, 0, 30).getTime())).toBe(3)
  expect(streak(['2026-10-31', '2026-11-01'], new Date(2026, 10, 1, 23, 30).getTime())).toBe(2)
  expect(streak(days, new Date(2026, 2, 10, 12).getTime())).toBe(0)
})

test('a set keeps enough entries for the advancement that counts it', async () => {
  const chats = Array.from({ length: 1500 }, (_, i) => `chat-${String(i).padStart(4, '0')}`)
  const p = merge(undefined, { ...blank(), sets: { starves: chats } })
  expect(figure(p, 'starves', 0)).toBe(1500)
})

test('deaths in periods that have ended count as respawns', async () => {
  const p = { ...blank(), sets: { deaths: ['seven_day:1000', 'five_hour:5000'] } }
  expect(figure(p, 'respawns', 2000)).toBe(1)
  expect(figure(p, 'respawns', 6000)).toBe(2)
})

test('the tree marks what is new and opens on its tab', async () => {
  const p = { ...blank(), earned: { '0.root': 100, '3.root': 500 } }
  const shown = tree(p, 1000, 200)
  expect(shown.open).toBe(3)
  const item = (id: string) => shown.tabs.flatMap(t => t.items).find(i => i.id === id) as { fresh?: boolean; at?: number } | undefined
  expect(item('3.root')?.fresh).toBe(true)
  expect(item('0.root')?.fresh).toBe(false)
  expect(item('0.root')?.at).toBe(100)
})

// ---------- the band, through the engine ----------

// What the host would answer, so the mod's session starts as in the app.
function host(on: On, store: Record<string, unknown> = {}, backup = '') {
  mock.store(on, store)
  mock.env(on, { HOME: '/Users/test' })
  on('command.register', () => ({ value: { command: 'minecraft' } }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('fs.read', (_, e) => ({ value: String((e as { path?: string }).path ?? '').endsWith('backup.json') ? backup : '' }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.exists', () => ({ value: false }))
  on('fs.stat', () => ({ value: { kind: 'file', size: 0, mtimeMs: 0, isLink: false } }))
  on('fs.list', () => ({ value: [] }))
  on('session.id', () => ({ value: 'chat-1' }))
  on('session.cwd', () => ({ value: '/' }))
  on('config.list', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('session.usage', () => ({
    value: {
      startedAt: 0,
      context: { window: 200_000, percent: 40, usd: 0, id: 'x' },
      rateLimits: [{ kind: 'seven_day', percentUsed: 20, resetsAt: new Date(Date.UTC(2030, 0, 1)).toISOString(), source: 'test' }],
    },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // The engine's own band beneath the mod's: nothing to draw.
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
}

const BAND = {
  plugin: 'minecraft-hud',
  component: 'AbovePrompt',
  requestId: 'band',
  props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} },
} as const

test('the desktop band draws the HUD and four hotbar slots', async ($, on) => {
  mock.clock(on, { now: Date.UTC(2029, 0, 1) })
  host(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  for (const slot of ['advancements', 'music', 'parrot', 'settings']) {
    expect(await ui.find({ key: `open-${slot}` })).toBeDefined()
  }
  expect(await ui.find({ key: 'open-map' })).toBeUndefined()
  expect(await ui.find({ key: 'open-brew' })).toBeUndefined()
  await ui.unmount()
})

test('the terminal band draws the HUD as one line of pixels', async ($, on) => {
  mock.clock(on, { now: Date.UTC(2029, 0, 1) })
  host(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: false })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Image' })).toBeDefined()
  await ui.unmount()
})

const BACKUP = JSON.stringify({ at: 1, data: { progress2: { v: 2, earned: { '0.root': 1, '0.upgrade': 2 }, n: {}, max: {}, sets: {} }, xp2: { units: 400 } } })

test('an empty store takes the backup back, and says so', async ($, on) => {
  const clock = mock.clock(on, { now: Date.UTC(2029, 0, 1) })
  host(on, {}, BACKUP)
  const toasts: string[] = []
  on('ui.toast', (_, e) => {
    toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined }
  })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await clock.advance(5000)
  expect(toasts.some(t => /restored from your backup: 2 advancements/.test(t))).toBe(true)
})

test('a store with progress leaves the backup alone', async ($, on) => {
  const clock = mock.clock(on, { now: Date.UTC(2029, 0, 1) })
  host(on, { progress2: { v: 2, earned: { '0.root': 1 }, n: {}, max: {}, sets: {} } }, BACKUP)
  const toasts: string[] = []
  on('ui.toast', (_, e) => {
    toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined }
  })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await clock.advance(5000)
  expect(toasts.some(t => /restored/.test(t))).toBe(false)
})
