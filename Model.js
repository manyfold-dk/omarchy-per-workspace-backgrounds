.pragma library

// Pure rules for which background each workspace shows. No QML in here, so
// the rules can be tested with plain Node (see Model.test.mjs).
//
// Workspace N shows the Nth background of the current theme, wrapping, in the
// order omarchy-theme-bg-next cycles them. `pins` (workspace id as a string ->
// image path) override single workspaces until the theme changes.

var STATE_VERSION = 1

function defaultBackground(backgrounds, workspaceId) {
  if (!backgrounds || backgrounds.length === 0) return ""
  var count = backgrounds.length
  return backgrounds[(((workspaceId - 1) % count) + count) % count]
}

function backgroundFor(backgrounds, pins, workspaceId) {
  return pins[String(workspaceId)] || defaultBackground(backgrounds, workspaceId)
}

// The pins after path is shown on a workspace: a pin, unless path is that
// workspace's default anyway.
function pinned(backgrounds, pins, workspaceId, path) {
  var next = Object.assign({}, pins)
  var key = String(workspaceId)
  if (path === defaultBackground(backgrounds, workspaceId)) delete next[key]
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

// The scan prints the theme name on the first line, then one background path
// per line.
function parseScan(text) {
  var lines = String(text || "").split("\n")
  var theme = String(lines.shift() || "").trim()
  return { theme: theme, backgrounds: lines.filter(function(line) { return line.length > 0 }) }
}

// The saved pins for theme, or none when the file is missing, unreadable, or
// was saved under another theme.
function restoredPins(text, theme) {
  var saved
  try {
    saved = JSON.parse(String(text || ""))
  } catch (e) {
    return {}
  }
  if (!saved || typeof saved !== "object" || saved.theme !== theme) return {}

  var pins = {}
  var source = saved.pins && typeof saved.pins === "object" ? saved.pins : {}
  for (var key in source) {
    if (/^-?\d+$/.test(key) && typeof source[key] === "string" && source[key]) pins[key] = source[key]
  }
  return pins
}

function serialized(theme, pins) {
  return JSON.stringify({ version: STATE_VERSION, theme: theme, pins: pins }, null, 2) + "\n"
}
