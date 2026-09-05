import QtQuick
import qs.Ui
import qs.Commons

// Omarchy "bar-widget" kind entry point: always-visible entry point for the
// app, swapping glyph + color when Flatpak updates are pending instead of
// a numeric badge (Omarchy's own Color/Ui kit has no badge component --
// this mirrors the same glyph-swap-plus-color-swap approach Omarchy's own
// system-update bar icon uses). Reads the shared FlatpakService instance
// (see Service.qml) via bar.shell.serviceFor -- NOT direct property
// injection, which only happens for the overlay/panel/menu Loader.
BarWidget {
  id: root
  moduleName: "dev.mauro.flatpak-explorer"

  readonly property var service: root.bar && root.bar.shell ? root.bar.shell.serviceFor("dev.mauro.flatpak-explorer") : null
  readonly property int updateCount: service && service.availableUpdates ? service.availableUpdates.length : 0
  readonly property bool hasUpdates: updateCount > 0

  // Required: BarWidget's own Item base sets no implicit size of its own,
  // and Bar.qml's ModuleSlot sizes the bar slot directly off these two --
  // every shipped bar-widget forwards them explicitly. Omitting this
  // renders the icon at 0x0 with no error at all.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-cube (package-like) normally; nf-fa-refresh when updates are
    // pending -- the same glyph Omarchy's own system-update bar icon uses.
    text: root.hasUpdates ? "" : ""
    active: root.hasUpdates
    activeColor: Color.accent
    tooltipText: root.hasUpdates ? ("Flatpak: " + root.updateCount + " update(s) available") : "Flatpak Explorer"
    onPressed: function(mouseButton) {
      if (root.bar && root.bar.shell) root.bar.shell.summon("dev.mauro.flatpak-explorer")
    }
  }
}
