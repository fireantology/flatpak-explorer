import Quickshell
import Quickshell.Io
import "core" as Core

// Generic-Hyprland entry point. Run directly with:
//   quickshell -p <path-to-this-repo>
// No Omarchy install, ~/.config/quickshell convention, or host shell
// required -- this owns its own process and window. (manifest.json and
// Overlay.qml alongside this file are the separate Omarchy-plugin entry
// point; Quickshell ignores them here since only shell.qml is loaded.)
ShellRoot {
  property ThemeDetector themeBridge: ThemeDetector {}

  Core.ExplorerWindow {
    id: explorer
    theme: themeBridge.theme
    open: true
  }

  IpcHandler {
    target: "explorer"

    function show(): void { explorer.show() }
    function hide(): void { explorer.close() }
    function toggle(): void { explorer.toggle() }
  }
}
