import type { On } from 'claude-code'

import { ITEMS } from './items'

// An item beside each tool call in the desktop app: a pickaxe for a command, a map for a read,
// a book and quill for an edit. A tool with no item here keeps its row as it is.
const ITEM_OF: Record<string, string> = {
  Bash: 'iron_pickaxe',
  Read: 'filled_map',
  Edit: 'writable_book',
  MultiEdit: 'writable_book',
  Write: 'writable_book',
  NotebookEdit: 'writable_book',
  Grep: 'spyglass',
  Glob: 'spyglass',
  WebFetch: 'compass',
  WebSearch: 'compass',
  Agent: 'armor_stand',
  Task: 'armor_stand',
  TodoWrite: 'paper',
}
const itemFor = (tool: string) => ITEM_OF[tool] ?? (tool.startsWith('mcp__') ? 'ender_eye' : undefined)
// The desktop draws a picture in a tool row only when its markup states its own size.
const itemSvg = (name: string) => `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" shape-rendering="crispEdges">${ITEMS[name]}</svg>`

/** `isOn` reads the setting that turns the icons off. */
export function registerIcons(on: On, isOn: () => boolean) {
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const item = e.surface === 'desktop' && isOn() ? itemFor(e.props.tool) : undefined
    if (!item) return next(e)
    const elements = $.ui.resolve(e)
    const theirs = await next(e)
    if (!('Svg' in elements)) return theirs
    const { Box, Svg } = elements
    return (
      <Box flexDirection="row" columnGap={1} alignItems="center">
        <Svg source={itemSvg(item)} alt={item.replace(/_/g, ' ')} width={16} height={16} />
        <Box flexGrow={1}>{theirs}</Box>
      </Box>
    )
  })
}
