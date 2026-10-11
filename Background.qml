import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A different background on each workspace. This replaces Omarchy's built-in
// background renderer (omarchy.background) and keeps its IPC target, its
// transitions and its double-click actions.
//
// Workspace N shows the Nth background of the current theme, wrapping, in the
// order omarchy-theme-bg-next cycles them. Setting a background (bg next, the
// background switcher, omarchy theme bg set) pins it to the focused workspace
// until the theme changes. The current/background symlink follows the focused
// workspace, so bg next, the lock screen and theme transitions all see what
// is on screen.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string statePath: stateHome + "/omarchy/per-workspace-backgrounds.json"

  // The mapping (see Model.js), ready once the first scan and the saved state
  // are both in.
  property string themeName: ""
  property var backgrounds: []
  property var pins: ({})
  // Bumped on every theme change; see imageUrl.
  property int themeGeneration: 0

  // Screen-size copies of the backgrounds ("WxH|path" -> copy), filled in by
  // screen-copies.sh as each copy is ready. A switch then decodes a few
  // megapixels instead of the full file.
  readonly property string copiesDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/omarchy/per-workspace-backgrounds"
  readonly property string copiesScript: decodeURIComponent(String(Qt.resolvedUrl("screen-copies.sh")).replace(/^file:\/\//, ""))
  property var screenCopies: ({})
  property bool copiesQueued: false
  readonly property var decodeSizes: {
    var sizes = []
    for (var i = 0; i < screens.instances.length; i++) {
      var size = screens.instances[i].sizeKey
      if (size && sizes.indexOf(size) === -1) sizes.push(size)
    }
    return sizes
  }
  // The theme generation is part of the request: a theme reset clears the
  // copies, and a theme with the same file names would otherwise leave the
  // request unchanged and never get them back.
  readonly property string copiesRequest: ready && decodeSizes.length > 0 ? JSON.stringify([themeGeneration, decodeSizes, Model.copyPaths(backgrounds, pins)]) : ""

  onCopiesRequestChanged: copiesTimer.restart()
  property bool ready: false
  property bool scanned: false
  property bool stateLoaded: false
  property string stateText: ""

  // A theme switch waits for the scan of the new theme's backgrounds.
  property var pendingThemeSwitch: null
  property bool rescanQueued: false
  property string pendingLink: ""

  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""

  readonly property int focusedWorkspaceId: workspaceIdFor(Hyprland.focusedMonitor)
  readonly property string focusedBackground: ready ? Model.backgroundFor(backgrounds, pins, focusedWorkspaceId) : ""

  signal focusedTransitionRequested(string fromPath, string path, string finalPath, bool instant, bool force)

  onFocusedBackgroundChanged: syncLink()

  // The theme generation is part of every image URL. A new theme can ship a
  // file under a name the old one used (every stock theme has an omarchy.png
  // at the same path), and an unchanged URL would keep the old decode.
  function imageUrl(path, generation, size) {
    if (!path) return ""
    return Util.fileUrl(screenCopies[Model.copyKey(size, path)] || path) + "?g=" + generation
  }

  function makeScreenCopies() {
    if (!copiesRequest) return
    if (copiesProc.running) {
      copiesQueued = true
      return
    }
    var request = JSON.parse(copiesRequest)
    copiesProc.generation = themeGeneration
    copiesProc.command = ["bash", copiesScript, copiesDir, request[1].join(",")].concat(request[2])
    copiesProc.running = true
  }

  // imageUrl builds every URL: the original file's, unless a copy was used.
  function usesCopy(url, path) {
    return !!url && !!path && url.slice(0, url.indexOf("?")) !== Util.fileUrl(path)
  }

  // A copy that will not load (deleted along with the cache, say) is dropped,
  // so the original is used, and the next run makes it again.
  function dropCopy(size, path) {
    screenCopies = Model.withoutCopy(screenCopies, size, path)
    copiesTimer.restart()
  }

  function addScreenCopy(line) {
    // Copies made for the previous theme can name a path the new theme reuses.
    if (copiesProc.generation !== themeGeneration) return
    var copy = Model.parseScreenCopy(line)
    if (!copy) return
    var next = Object.assign({}, screenCopies)
    next[copy.key] = copy.path
    screenCopies = next
  }

  function workspaceIdFor(monitor) {
    return monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
  }

  // Show a background on the focused workspace and pin it there. The set can
  // be the last step of a theme switch, so the scan looks for a new theme.
  function showOnFocused(fromPath, path, instant) {
    path = String(path || "").trim()
    if (!path || !ready) return
    focusedTransitionRequested(fromPath, path, path, instant, false)
    pins = Model.pinned(backgrounds, pins, focusedWorkspaceId, path)
    saveState()
    rescan()
  }

  function forget(path) {
    if (!path || !ready) return
    var next = Model.unpinned(pins, path)
    if (Object.keys(next).length === Object.keys(pins).length) return
    pins = next
    saveState()
  }

  // A new theme starts over: every workspace shows its own default. A theme
  // switch reveals the focused workspace's default from the old background.
  function resetForTheme(themeSwitch) {
    themeGeneration += 1
    screenCopies = {}
    if (themeSwitch) {
      var target = Model.defaultBackground(backgrounds, focusedWorkspaceId)
      focusedTransitionRequested(themeSwitch.fromPath, target, target, false, true)
    }
    pins = {}
    saveState()
    // omarchy-theme-set links its own pick after reporting the theme.
    relinkTimer.restart()
  }

  function rescan() {
    if (scanProc.running) rescanQueued = true
    else scanProc.running = true
  }

  function applyScan(text) {
    var scan = Model.parseScan(text)
    var themeChanged = scanned && scan.theme !== themeName
    themeName = scan.theme
    backgrounds = scan.backgrounds
    scanned = true

    var themeSwitch = pendingThemeSwitch
    pendingThemeSwitch = null
    if (!ready) {
      if (stateLoaded) initialize()
    } else if (themeSwitch || themeChanged) {
      resetForTheme(themeSwitch)
    }
  }

  function loadState(text) {
    // FileView can report a load more than once during startup.
    if (stateLoaded) return
    stateText = text
    stateLoaded = true
    if (scanned && !ready) initialize()
  }

  function initialize() {
    pins = Model.restoredPins(stateText, themeName)
    ready = true
    saveState()
  }

  function saveState() {
    if (ready) stateFile.setText(Model.serialized(themeName, pins))
  }

  // Point current/background at the focused workspace's background.
  function syncLink() {
    if (!focusedBackground) return
    pendingLink = focusedBackground
    if (linkProc.running) return
    linkProc.command = ["ln", "-nsf", pendingLink, currentBackgroundLink]
    linkProc.running = true
  }

  function refreshBackground() {
    rescan()
    if (ready && !readlinkProc.running) readlinkProc.running = true
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = 0
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Commons.Color.loadColors(pendingColorsRaw)
    // Commons.Color.loadShell also refreshes Style so the type scale flips
    // with the background reveal instead of waiting for a separate reload path.
    Commons.Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  // omarchy-theme-set names its own pick (path, finalPath). The plugin shows
  // each workspace's own default instead, revealed from the old background.
  function transitionBackgroundWithTheme(fromPath, colorsB64, shellB64) {
    setPendingTheme(colorsB64, shellB64)
    if (!ready) return
    pendingThemeSwitch = { fromPath: String(fromPath || "").trim() }
    rescan()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  // Lists the theme's backgrounds the way omarchy-theme-bg-next does, so both
  // agree on the order and on the exact paths.
  Process {
    id: scanProc
    command: ["bash", "-c", "theme=$(cat \"$HOME/.local/state/omarchy/current/theme.name\" 2>/dev/null)\n"
      + "printf '%s\\n' \"$theme\"\n"
      + "find -L \"$HOME/.config/omarchy/backgrounds/$theme/\" \"$HOME/.local/state/omarchy/current/theme/backgrounds/\" -maxdepth 1 -type f "
      + "\\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \\) "
      + "-print0 2>/dev/null | sort -z | tr '\\0' '\\n'"]
    stdout: StdioCollector { id: scanOut }
    onExited: {
      // A scan requested while this one ran supersedes it.
      if (root.rescanQueued) {
        root.rescanQueued = false
        running = true
        return
      }
      root.applyScan(scanOut.text)
    }
  }

  Process {
    id: copiesProc
    property int generation: -1
    stdout: SplitParser {
      onRead: function(data) { root.addScreenCopy(data) }
    }
    onExited: {
      if (!root.copiesQueued) return
      root.copiesQueued = false
      root.makeScreenCopies()
    }
  }

  // Waits for the screens and the mapping to settle before making copies.
  Timer {
    id: copiesTimer
    interval: 500
    repeat: false
    onTriggered: root.makeScreenCopies()
  }

  Process {
    id: linkProc
    onExited: {
      if (command[2] === root.pendingLink) return
      command = ["ln", "-nsf", root.pendingLink, root.currentBackgroundLink]
      running = true
    }
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  // omarchy-theme-set reports the new theme over IPC, so there is nothing to
  // refresh when the switcher exits.
  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
  }

  Process {
    id: readlinkProc
    command: ["readlink", root.currentBackgroundLink]
    stdout: StdioCollector { id: readlinkOut }
    onExited: root.showOnFocused("", String(readlinkOut.text || "").trim(), false)
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.showOnFocused("", path, false)
    }

    function setInstant(path: string): void {
      root.showOnFocused("", path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.showOnFocused(fromPath, path, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: relinkTimer
    interval: 2000
    repeat: false
    onTriggered: root.syncLink()
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  Component.onCompleted: rescan()

  Variants {
    id: screens
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      // Each screen follows its own monitor's active workspace.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool focused: !!hyprMonitor && !!Hyprland.focusedMonitor && hyprMonitor.name === Hyprland.focusedMonitor.name
      readonly property string wantedBackground: root.ready ? Model.backgroundFor(root.backgrounds, root.pins, root.workspaceIdFor(hyprMonitor)) : ""

      property string currentBackground: ""
      property int currentGeneration: 0
      property string displayedBackground: ""
      property string displayedUrl: ""
      property string incomingBackground: ""
      property string incomingUrl: ""
      property string oldUrl: ""
      property bool finishingTransition: false
      property int backgroundVersion: 0
      property int revealStartedVersion: -1
      property real revealProgress: 1
      property bool maskReady: false

      // Decode at the size this screen shows, not the size a wallpaper ships
      // at: theme backgrounds run to 8192x5461, 179 MB decoded, and every
      // workspace switch decodes one. With PreserveAspectCrop, Qt decodes to
      // cover sourceSize. The images wait for the window's size so nothing
      // decodes at full size first.
      readonly property bool sized: width > 0 && height > 0
      readonly property size decodeSize: Qt.size(Math.ceil(width * modelData.devicePixelRatio), Math.ceil(height * modelData.devicePixelRatio))
      readonly property string sizeKey: sized ? Model.sizeKey(decodeSize.width, decodeSize.height) : ""

      // Follow the mapping once per event-loop turn, after a scan or a theme
      // switch has finished changing it.
      function followWanted() {
        transitionBackground("", wantedBackground, wantedBackground, false, false)
      }

      onWantedBackgroundChanged: Qt.callLater(panel.followWanted)
      // A screen plugged in later starts with its background already chosen.
      Component.onCompleted: followWanted()

      function transitionBackground(fromPath, path, finalPath, instant, force) {
        path = String(path || "").trim()
        finalPath = String(finalPath || path).trim()
        fromPath = String(fromPath || "").trim()
        var generation = root.themeGeneration
        if (!path || (!force && finalPath === currentBackground && generation === currentGeneration)) return
        currentBackground = finalPath
        currentGeneration = generation
        backgroundVersion += 1
        revealStartedVersion = -1

        revealAnimation.stop()
        finishingTransition = false

        if (instant || !displayedBackground) {
          oldUrl = ""
          incomingBackground = ""
          incomingUrl = ""
          displayedBackground = path
          displayedUrl = root.imageUrl(path, generation, sizeKey)
          revealProgress = 1
          return
        }

        // The outgoing frame is the image base already shows, under the same
        // URL, so it reuses that decode.
        oldUrl = fromPath ? root.imageUrl(fromPath, generation, sizeKey) : displayedUrl
        incomingBackground = path
        incomingUrl = root.imageUrl(path, generation, sizeKey)
        revealProgress = 0
      }

      // Falls back from a copy that failed to load to the original file.
      // Returns whether there was a copy to fall back from.
      function dropFailedCopy(url, path) {
        if (!root.usesCopy(url, path)) return false
        root.dropCopy(sizeKey, path)
        return true
      }

      function finishTransition() {
        incomingBackground = ""
        incomingUrl = ""
        oldUrl = ""
        finishingTransition = false
      }

      function startReveal() {
        if (!incomingBackground) return
        maskReady = true
        if (revealStartedVersion === backgroundVersion) return
        revealStartedVersion = backgroundVersion
        root.applyPendingTheme()
        revealAnimation.restart()
      }

      function maybeStartReveal() {
        if (!incomingBackground || revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!panel.incomingBackground || panel.revealProgress !== 0 || panel.maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          panel.startReveal()
        })
      }

      Connections {
        target: root
        function onFocusedTransitionRequested(fromPath, path, finalPath, instant, force) {
          if (!panel.focused) return
          panel.transitionBackground(fromPath, path, finalPath, instant, force)
          if (!panel.incomingBackground || panel.revealProgress >= 1) root.applyPendingTheme()
        }
        function onThemeGenerationChanged() {
          Qt.callLater(panel.followWanted)
        }
      }

      NumberAnimation {
        id: revealAnimation
        target: panel
        property: "revealProgress"
        from: 0
        to: 1
        duration: 420
        easing.type: Easing.InOutCubic
        onFinished: {
          if (panel.incomingBackground) {
            panel.displayedBackground = panel.currentBackground || panel.incomingBackground
            // Normally the incoming frame's URL, so base takes over its decode.
            panel.displayedUrl = panel.displayedBackground === panel.incomingBackground
              ? panel.incomingUrl
              : root.imageUrl(panel.displayedBackground, panel.currentGeneration, panel.sizeKey)
            panel.finishingTransition = true
            // Base usually takes over the incoming frame's cached decode: it is
            // ready at once and reports no status change.
            if (base.status === Image.Ready) panel.finishTransition()
          }
          panel.revealProgress = 1
        }
      }

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        source: panel.sized ? panel.displayedUrl : ""
        sourceSize: panel.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Error) {
            if (panel.dropFailedCopy(panel.displayedUrl, panel.displayedBackground))
              panel.displayedUrl = root.imageUrl(panel.displayedBackground, panel.currentGeneration, panel.sizeKey)
            // A pinned image that was moved or deleted falls back to the default.
            else root.forget(panel.displayedBackground)
          }
          if (status === Image.Ready && panel.finishingTransition) panel.finishTransition()
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: panel.sized ? panel.oldUrl : ""
        sourceSize: panel.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Shares decodes with base and the incoming frame.
        cache: true
        smooth: true
        mipmap: true
        visible: panel.oldUrl !== "" && panel.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: panel.incomingBackground !== "" && incomingFrame.status === Image.Ready && (panel.revealProgress >= 1 || panel.maskReady)
        layer.enabled: panel.incomingBackground !== "" && panel.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: panel.sized ? panel.incomingUrl : ""
          sourceSize: panel.decodeSize
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          smooth: true
          mipmap: true
          onStatusChanged: {
            if (status === Image.Error) {
              if (panel.dropFailedCopy(panel.incomingUrl, panel.incomingBackground))
                panel.incomingUrl = root.imageUrl(panel.incomingBackground, panel.currentGeneration, panel.sizeKey)
              else root.forget(panel.incomingBackground)
            }
            panel.maybeStartReveal()
          }
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * panel.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: panel
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
