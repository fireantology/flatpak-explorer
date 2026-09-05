import QtQuick
import Quickshell.Io
import qs.Commons
import "core" as Core

// Omarchy adapter: the only file here that imports qs.Commons/qs.Ui. Wraps
// the portable core in the host's live, theme-switch-aware colors instead of
// the file-watching fallback the standalone build needs -- Omarchy already
// keeps Color in sync, no reason to duplicate that. Also passes through the
// shared FlatpakService instance (see Service.qml) instead of letting
// ExplorerWindow default-construct its own -- BarWidget.qml reads the same
// shared instance (via bar.shell.serviceFor), so the bar icon and this
// window always agree and flatpak is only ever queried once. Kept
// intentionally thin: all real UI/logic lives in core/, shared with the
// standalone build.
Item {
  id: root

  // Host-injected once Service.qml (the plugin's shared "service" kind
  // entry point) is instantiated -- shell.qml's panel Loader does
  // `if ("service" in item) item.service = shell.serviceFor(pluginId)`
  // automatically after this Item is constructed, no manual wiring needed
  // beyond declaring the property. Starts null for one construction pass
  // on every summon (this whole subtree is destroyed/recreated each time,
  // no keepLoaded) -- core/ExplorerWindow.qml's unguarded service.* reads
  // will log a harmless burst of null-property warnings during that first
  // pass, before explorer.open() is ever called, so it's never user-visible.
  property var service: null

  readonly property var theme: ({
    background: Color.background,
    foreground: Color.foreground,
    muted: Color.muted,
    accent: Color.accent,
    danger: Color.urgent,
    // Not Color.menu.border (or popups/tooltip/notifications -- every
    // "border" token Omarchy's Color singleton has is designed for a
    // prominent popup-card border, defaulting to foreground or accent at
    // full opacity). This app only uses theme.border for plain 1px section
    // dividers -- theme.accent already covers this app's own popup borders
    // (confirm/busy/missing-flatpak overlays) -- so Color.muted is the
    // actual semantic match, not any of the *.border tokens.
    border: Color.muted,
    // Style already derives these from shell.toml's [font] base-size
    // (and honors any per-token pin like body/body-small) -- no reason to
    // re-parse shell.toml ourselves the way the standalone ThemeDetector
    // has to, when the host's already-computed values are right here.
    fontFamily: Style.font.family,
    fontSize: Style.font.body,
    fontSizeSmall: Style.font.bodySmall
  })

  Core.ExplorerWindow {
    id: explorer
    theme: root.theme
    service: root.service
  }

  function open() { explorer.show() }
  function close() { explorer.close() }
  function toggle() { explorer.toggle() }
  readonly property alias opened: explorer.open

  IpcHandler {
    target: "dev.mauro.flatpak-explorer"

    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }
}
