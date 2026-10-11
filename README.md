# Workspace Backgrounds

A different background on each workspace, for [Omarchy](https://omarchy.org) Quattro.

Workspace 1 shows the current theme's first background, workspace 2 its second, and so on, wrapping around when you have more workspaces than the theme has backgrounds. The plugin takes over from Omarchy's built-in background renderer, so everything that already changes your background keeps working -- it now changes the workspace you are on.

## Install

```bash
omarchy plugin add https://github.com/manyfold-dk/omarchy-workspace-backgrounds.git --enable
```

Enabling it switches off the built-in `omarchy.background`. There is nothing to configure.

## How it behaves

| You | What happens |
|---|---|
| Switch workspace | The background changes, with the same reveal transition Omarchy uses |
| Run `omarchy theme bg next`, pick one in the background switcher (double-click the desktop), or run `omarchy theme bg set <image>` | Only the focused workspace changes, and it keeps that background |
| Switch theme | Per-workspace choices reset. The focused workspace keeps the background the theme switch chose; the other workspaces get the rest of the new theme's backgrounds |
| Lock the screen | The lock screen shows the focused workspace's background |
| Use several monitors | Each monitor follows its own active workspace |

The backgrounds are the ones `omarchy theme bg next` cycles through, in the same order (by file name): the theme's own `backgrounds/` folder plus `~/.config/omarchy/backgrounds/<theme>/`. Add images to the latter for more variety; `omarchy theme bg install` opens it.

The plugin keeps its state in `~/.local/state/omarchy/workspace-backgrounds.json`: the theme it applies to, the rotation, and the backgrounds you picked per workspace. Omarchy's `~/.local/state/omarchy/current/background` link follows the focused workspace.

## Remove

```bash
omarchy plugin remove manyfold.workspace-backgrounds
rm -f ~/.local/state/omarchy/workspace-backgrounds.json
```

Removing the plugin switches the built-in background renderer back on.

## Compatibility

- Omarchy Quattro (4.x) on Hyprland.
- Still images only. Video backgrounds are not supported.
- No dependencies beyond what Omarchy ships (`bash`, `find`, `ln`, `readlink`).

The plugin is derived from Omarchy's own background plugin and keeps its IPC interface (`omarchy-shell background ...`), transitions and double-click actions. When Omarchy changes that plugin in a way this one has to follow, please open an issue.

## Development

The mapping rules live in `Model.js`, without QML, and are tested with plain Node:

```bash
node --test Model.test.mjs
omarchy plugin validate .
```

`Background.qml` is the renderer. Edits under `~/.config/omarchy/plugins/` normally reload on save; if the shell keeps running the old code, `omarchy restart shell` loads the new one.

## License

MIT -- see [LICENSE](LICENSE). Derived from Omarchy's background plugin, which is MIT-licensed by David Heinemeier Hansson.
