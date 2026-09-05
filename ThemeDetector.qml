import QtQuick
import Quickshell
import Quickshell.Io
import "core" as Core

// Opportunistic theming for non-Omarchy hosts: if Omarchy happens to be
// installed, read its live theme colors so the standalone build looks native
// on an Omarchy box too. If the file doesn't exist -- any other Hyprland
// setup -- this quietly falls back to core/Theme.qml's hardcoded palette.
// Mirrors the same file layout and parsing Omarchy's own Commons/Color.qml
// uses, without depending on any Omarchy QML module.
//
// On top of that, ~/.config/flatpak-explorer/theme.toml (if present) is the
// user's own override, highest priority of all three layers -- a single key
// there (e.g. just `accent = "#ff00ff"`) overrides only that one value, the
// rest still resolve from Omarchy's live theme or the hardcoded fallback as
// usual. Standalone-only: the Omarchy plugin adapter (Overlay.qml) reads the
// host's live theme directly and isn't expected to need a separate override
// file on top of it.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string themeDir: home + "/.local/state/omarchy/current/theme"
  readonly property string colorsPath: themeDir + "/colors.toml"
  // shell.toml's [font] base-size is the same rem root Omarchy's own shell
  // (qs.Commons.Style) derives its whole type scale from -- reading it here
  // is what makes this app's text track the user's chosen density instead
  // of whatever size Qt's default font happens to be. Family is left alone:
  // "monospace" already resolves through the fontconfig alias `omarchy font
  // set` writes, the same generic name Style.qml's own fontFamily binds to,
  // so there's no separate family value to read.
  readonly property string shellTomlPath: themeDir + "/shell.toml"
  readonly property string userThemePath: home + "/.config/flatpak-explorer/theme.toml"

  property Core.Theme fallback: Core.Theme {}

  // effectiveFontSize resolved once, separately, so a user override of
  // fontSize (but not fontSizeSmall) still derives the small-text ratio from
  // *their* size rather than from whatever Omarchy's base-size happens to
  // be -- undefined-checked rather than `||` since 0 is a technically-valid
  // (if silly) override that `||` would incorrectly skip.
  readonly property real effectiveFontSize: userTheme.fontSize !== undefined ? userTheme.fontSize : fontBaseSize

  readonly property var theme: ({
    background: userTheme.background || parsed.background || fallback.background,
    foreground: userTheme.foreground || parsed.foreground || fallback.foreground,
    muted: userTheme.muted || parsed.color8 || fallback.muted,
    accent: userTheme.accent || parsed.accent || fallback.accent,
    danger: userTheme.danger || parsed.color1 || fallback.danger,
    border: userTheme.border || parsed.color8 || fallback.border,
    fontFamily: userTheme.fontFamily || fallback.fontFamily,
    fontSize: effectiveFontSize,
    // Mirrors qs.Commons.Style's body-small derivation (base-size * 0.917)
    // so a non-Omarchy or colors-only setup still gets the same proportion
    // between normal and secondary/hint text that Omarchy's own shell uses.
    fontSizeSmall: userTheme.fontSizeSmall !== undefined ? userTheme.fontSizeSmall : Math.max(1, Math.round(effectiveFontSize * 0.917))
  })

  property var parsed: ({})
  property var userTheme: ({})
  property int fontBaseSize: fallback.fontSize

  function parseFlatToml(text) {
    var result = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) result[match[1]] = match[2]
    }
    return result
  }

  // The user's own theme.toml mixes quoted values (colors, fontFamily) and
  // bare numbers (fontSize/fontSizeSmall) in one flat key=value file, so
  // unlike parseFlatToml above this isn't limited to matching hex colors --
  // any quoted string or bare number is accepted as-is, no validation that
  // a color key actually got a hex value. A typo just won't override
  // anything (theme's own `||`/undefined-check falls through to the next
  // layer), rather than crashing.
  function parseUserTheme(text) {
    var result = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var strMatch = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"/)
      if (strMatch) { result[strMatch[1]] = strMatch[2]; continue }
      var numMatch = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*(-?\d+(?:\.\d+)?)\s*(?:#.*)?$/)
      if (numMatch) result[numMatch[1]] = parseFloat(numMatch[2])
    }
    return result
  }

  // shell.toml is a nested TOML file (unlike colors.toml's flat key=value
  // layout), so this only needs to track section headers well enough to
  // find `base-size =` inside `[font]` -- not a general TOML parser.
  function parseFontBaseSize(text) {
    var section = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var header = line.match(/^\s*\[([A-Za-z0-9_-]+)\]/)
      if (header) { section = header[1]; continue }
      if (section !== "font") continue
      var match = line.match(/^\s*base-size\s*=\s*(-?\d+(?:\.\d+)?)/)
      if (match) return Math.round(parseFloat(match[1]))
    }
    return fallback.fontSize
  }

  property FileView colorsFile: FileView {
    path: root.colorsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parsed = root.parseFlatToml(text())
    onLoadFailed: root.parsed = ({})
    onFileChanged: reload()
  }

  property FileView userThemeFile: FileView {
    path: root.userThemePath
    watchChanges: true
    printErrors: false
    onLoaded: root.userTheme = root.parseUserTheme(text())
    onLoadFailed: root.userTheme = ({})
    onFileChanged: reload()
  }

  property FileView shellTomlFile: FileView {
    path: root.shellTomlPath
    watchChanges: true
    printErrors: false
    onLoaded: root.fontBaseSize = root.parseFontBaseSize(text())
    onLoadFailed: root.fontBaseSize = root.fallback.fontSize
    onFileChanged: reload()
  }
}
