import QtQuick

// Fallback palette used whenever no richer theme source is available (plain
// Hyprland with no Omarchy installed, or Omarchy present but its colors.toml
// unreadable for some reason). Adapters override individual properties by
// passing their own `theme` object into ExplorerWindow rather than editing
// this file -- keep this the single source of "looks reasonable anywhere".
QtObject {
  readonly property color background: "#151319"
  readonly property color foreground: "#fbfafd"
  readonly property color muted: "#9a95a8"
  readonly property color accent: "#9981d4"
  readonly property color danger: "#c95f98"
  readonly property color border: "#47444e"

  // Matches Omarchy's own stock [font] base-size (12) and its derived
  // body-small token (base-size * 0.917, the same ratio qs.Commons.Style
  // uses) -- so a system with no Omarchy theme at all still looks exactly
  // like Omarchy's own default scale, not an arbitrary unrelated size.
  readonly property string fontFamily: "monospace"
  readonly property int fontSize: 12
  readonly property int fontSizeSmall: 11
}
