import "core" as Core

// Omarchy "service" kind entry point: the host (shell.qml's _syncServices)
// instantiates this once, eagerly, as soon as the plugin is enabled --
// independent of whether the bar widget or the overlay window is currently
// visible -- and hands the same instance to both (Overlay.qml via direct
// property injection, BarWidget.qml via bar.shell.serviceFor(id)). Zero
// Omarchy imports: this is just a thin host adapter, the same category as
// Overlay.qml/shell.qml, not a change to core/'s portability.
Core.FlatpakService {}
