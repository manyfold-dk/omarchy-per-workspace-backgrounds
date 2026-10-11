.pragma library

// Pure rules for which background each workspace shows. No QML in here, so
// the rules can be tested with plain Node (see Model.test.mjs).
//
// Workspace N shows the Nth background of the current theme, wrapping, in the
// order omarchy-theme-bg-next cycles them. `offset` rotates that mapping, and
// `pins` (workspace id as a string -> image path) override single workspaces.

var STATE_VERSION = 1

function wrap(index, count) {
  return ((index % count) + count) % count
}

function defaultBackground(backgrounds, offset, workspaceId) {
  if (!backgrounds || backgrounds.length === 0) return ""
  return backgrounds[wrap(workspaceId - 1 + offset, backgrounds.length)]
}

function backgroundFor(backgrounds, offset, pins, workspaceId) {
  return pins[String(workspaceId)] || defaultBackground(backgrounds, offset, workspaceId)
}

// The pins after path is shown on a workspace: a pin, unless path is that
// workspace's default anyway.
function pinned(backgrounds, offset, pins, workspaceId, path) {
  var next = Object.assign({}, pins)
  var key = String(workspaceId)
  if (path === defaultBackground(backgrounds, offset, workspaceId)) delete next[key]
  else next[key] = path
  return next
}

// The pins without any that show path, for an image that failed to load.
function unpinned(pins, path) {
  var next = {}
  for (var key in pins) {
    if (pins[key] !== path) next[key] = pins[key]
  }
  return next
}

// The offset and pins that put path on a workspace and rotate the defaults
// around it, so the other workspaces keep distinct backgrounds. A path that is
// not one of the theme's backgrounds becomes a pin over plain defaults.
function anchored(backgrounds, path, workspaceId) {
  var index = path ? backgrounds.indexOf(path) : -1
  if (index >= 0) return { offset: wrap(index - (workspaceId - 1), backgrounds.length), pins: {} }
  var pins = {}
  if (path) pins[String(workspaceId)] = path
  return { offset: 0, pins: pins }
}

// The scan prints the theme name on the first line, then one background path
// per line.
function parseScan(text) {
  var lines = String(text || "").split("\n")
  var theme = String(lines.shift() || "").trim()
  return { theme: theme, backgrounds: lines.filter(function(line) { return line.length > 0 }) }
}

// The saved offset and pins for theme, or plain defaults when the file is
// missing, unreadable, or was saved under another theme.
function restored(text, theme) {
  var fresh = { offset: 0, pins: {} }
  var saved
  try {
    saved = JSON.parse(String(text || ""))
  } catch (e) {
    return fresh
  }
  if (!saved || typeof saved !== "object" || saved.theme !== theme) return fresh

  var pins = {}
  var source = saved.pins && typeof saved.pins === "object" ? saved.pins : {}
  for (var key in source) {
    if (/^-?\d+$/.test(key) && typeof source[key] === "string" && source[key]) pins[key] = source[key]
  }
  return { offset: Number.isInteger(saved.offset) ? saved.offset : 0, pins: pins }
}

function serialized(theme, offset, pins) {
  return JSON.stringify({ version: STATE_VERSION, theme: theme, offset: offset, pins: pins }, null, 2) + "\n"
}
