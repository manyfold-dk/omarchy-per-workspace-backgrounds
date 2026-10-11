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
// only. The current/background symlink follows the focused workspace, so bg
// next, the lock screen and theme transitions all see what is on screen.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string statePath: stateHome + "/omarchy/workspace-backgrounds.json"

  // The mapping (see Model.js), ready once the first scan and the saved state
  // are both in.
  property string themeName: ""
  property var backgrounds: []
  property int offset: 0
  property var pins: ({})
  property bool ready: false
  property bool scanned: false
  property bool stateLoaded: false
  property string stateText: ""

  // Where to put the defaults after the next scan: set alongside every IPC
  // background change, which can be the last step of a theme switch.
  property var pendingAnchor: null
  property bool rescanQueued: false
  property string pendingLink: ""

  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""

  readonly property int focusedWorkspaceId: workspaceIdFor(Hyprland.focusedMonitor)
  readonly property string focusedBackground: ready ? Model.backgroundFor(backgrounds, offset, pins, focusedWorkspaceId) : ""

  signal focusedTransitionRequested(string fromPath, string path, string finalPath, bool instant, bool force)

  onFocusedBackgroundChanged: syncLink()

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function workspaceIdFor(monitor) {
    return monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
  }

  // Show a background on the focused workspace and pin it there. A theme
  // switch forces the transition and re-anchors the defaults on the new theme.
  function showOnFocused(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    if (!path || !ready) return
    focusedTransitionRequested(fromPath, path, finalPath, instant, force)
    var workspaceId = focusedWorkspaceId
    pins = Model.pinned(backgrounds, offset, pins, workspaceId, finalPath)
    saveState()
    pendingAnchor = { path: finalPath, workspaceId: workspaceId, force: force }
    rescan()
  }

  function forget(path) {
    if (!path || !ready) return
    var next = Model.unpinned(pins, path)
    if (Object.keys(next).length === Object.keys(pins).length) return
    pins = next
    saveState()
  }

  function anchor(path, workspaceId) {
    var anchored = Model.anchored(backgrounds, path, workspaceId)
    offset = anchored.offset
    pins = anchored.pins
    saveState()
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

    var pending = pendingAnchor
    pendingAnchor = null
    if (!ready) {
      if (stateLoaded) initialize()
    } else if (pending && (pending.force || themeChanged)) {
      anchor(pending.path, pending.workspaceId)
    } else if (themeChanged) {
      anchor("", focusedWorkspaceId)
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
    var saved = Model.restored(stateText, themeName)
    offset = saved.offset
    pins = saved.pins
    ready = true
    saveState()
  }

  function saveState() {
    if (ready) stateFile.setText(Model.serialized(themeName, offset, pins))
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

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    setPendingTheme(colorsB64, shellB64)
    showOnFocused(fromPath, path, finalPath, false, true)
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
    onExited: {
      var path = String(readlinkOut.text || "").trim()
      root.showOnFocused("", path, path, false, false)
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.showOnFocused("", path, path, false, false)
    }

    function setInstant(path: string): void {
      root.showOnFocused("", path, path, true, false)
    }

    function transition(fromPath: string, path: string): void {
      root.showOnFocused(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  Component.onCompleted: rescan()

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      // Each screen follows its own monitor's active workspace.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool focused: !!hyprMonitor && !!Hyprland.focusedMonitor && hyprMonitor.name === Hyprland.focusedMonitor.name
      readonly property string wantedBackground: root.ready ? Model.backgroundFor(root.backgrounds, root.offset, root.pins, root.workspaceIdFor(hyprMonitor)) : ""

      property string currentBackground: ""
      property string displayedBackground: ""
      property string incomingBackground: ""
      property string oldBackground: ""
      property bool finishingTransition: false
      property int backgroundVersion: 0
      property int revealStartedVersion: -1
      property real revealProgress: 1
      property bool maskReady: false

      onWantedBackgroundChanged: transitionBackground("", wantedBackground, wantedBackground, false, false)
      // A screen plugged in later starts with its background already chosen.
      Component.onCompleted: transitionBackground("", wantedBackground, wantedBackground, false, false)

      function transitionBackground(fromPath, path, finalPath, instant, force) {
        path = String(path || "").trim()
        finalPath = String(finalPath || path).trim()
        fromPath = String(fromPath || "").trim()
        if (!path || (!force && finalPath === currentBackground)) return
        currentBackground = finalPath
        backgroundVersion += 1
        revealStartedVersion = -1

        revealAnimation.stop()
        finishingTransition = false

        if (instant || !displayedBackground) {
          oldBackground = ""
          incomingBackground = ""
          displayedBackground = path
          revealProgress = 1
          return
        }

        oldBackground = fromPath || displayedBackground
        incomingBackground = path
        revealProgress = 0
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
            panel.finishingTransition = true
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
        source: root.imageUrl(panel.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          // A pinned image that was moved or deleted falls back to the default.
          if (status === Image.Error) root.forget(panel.displayedBackground)
          if (status === Image.Ready && panel.finishingTransition) {
            panel.incomingBackground = ""
            panel.oldBackground = ""
            panel.finishingTransition = false
          }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(panel.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: panel.oldBackground !== "" && panel.revealProgress < 1
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
          source: root.imageUrl(panel.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: {
            if (status === Image.Error) root.forget(panel.incomingBackground)
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
