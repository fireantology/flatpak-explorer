import QtQuick
import "../core" as Core
import ".." as App

// Parsing and theme resolution. Fixture text is inline rather than read from
// disk: these are pure string->object functions, and seeing the input next to
// the expectation is worth more here than sharing files with the stub.
QtObject {
  id: root
  property var h: null
  // Injected by tests.qml -- these tests never start one of their own.
  property Core.FlatpakService svc: null
  property App.ThemeDetector td: App.ThemeDetector {}

  function run(done) {
    remotes()
    updates()
    flatToml()
    userToml()
    fontToml()
    themeLayering()
    done()
  }

  function remotes() {
    h.group("_parseRemotes")
    var json = JSON.stringify([
      { name: "flathub", title: "Flathub", url: "https://dl.flathub.org/repo/", priority: "1", options: "no-filter xa.title=Flathub" },
      { name: "flathub-beta", title: "", url: "https://dl.flathub.org/beta-repo/", priority: "1", options: "no-filter disabled" }
    ])
    var parsed = svc._parseRemotes(json, "user")
    h.equal("parses every row", parsed.length, 2)
    h.equal("keeps the name", parsed[0].name, "flathub")
    h.equal("labels the scope it was asked for", parsed[0].scope, "user")
    h.ok("a remote without the disabled option is enabled", parsed[0].enabled)
    h.ok("the disabled option is detected", !parsed[1].enabled)
    h.equal("an empty title falls back to the name", parsed[1].title, "flathub-beta")

    var broken = svc._parseRemotes('[{"name": "truncated"', "system")
    h.equal("malformed JSON yields an empty list instead of throwing", broken.length, 0)
  }

  function updates() {
    h.group("_parseUpdates")
    var json = JSON.stringify([
      { name: "GIMP", application_id: "org.gimp.GIMP", version: "2.10.40" }
    ])
    var parsed = svc._parseUpdates(json, "system")
    h.equal("maps application_id to appId", parsed[0].appId, "org.gimp.GIMP")
    h.equal("carries the version", parsed[0].version, "2.10.40")
    h.equal("labels the scope", parsed[0].scope, "system")
    h.equal("malformed JSON yields an empty list", svc._parseUpdates("nonsense", "user").length, 0)
  }

  function flatToml() {
    h.group("ThemeDetector.parseFlatToml")
    var text = 'background = "#151319"\n'
      + 'accent = #9981d4\n'
      + 'fontFamily = "monospace"\n'
      + 'shorthand = "#fff"\n'
      + '# comment = "#000000"\n'
    var parsed = td.parseFlatToml(text)
    h.equal("reads a quoted hex colour", parsed.background, "#151319")
    h.equal("reads a bare hex colour", parsed.accent, "#9981d4")
    h.equal("ignores non-colour values", parsed.fontFamily, undefined)
    h.equal("ignores three-digit hex", parsed.shorthand, undefined)
    h.equal("ignores commented-out keys", parsed.comment, undefined)
  }

  function userToml() {
    h.group("ThemeDetector.parseUserTheme")
    var text = 'accent = "#ff00ff"\n'
      + 'fontFamily = "JetBrains Mono"\n'
      + 'fontSize = 14\n'
      + 'fontSizeSmall = 12  # a trailing comment\n'
      + 'ratio = 0.917\n'
      + 'nonsense\n'
    var parsed = td.parseUserTheme(text)
    h.equal("reads quoted strings", parsed.accent, "#ff00ff")
    h.equal("keeps spaces inside quotes", parsed.fontFamily, "JetBrains Mono")
    h.equal("reads bare numbers as numbers", parsed.fontSize, 14)
    h.equal("tolerates a trailing comment", parsed.fontSizeSmall, 12)
    h.equal("reads decimals", parsed.ratio, 0.917)
    h.equal("skips lines that are not key = value", parsed.nonsense, undefined)
  }

  function fontToml() {
    h.group("ThemeDetector.parseFontBaseSize")
    var text = '[general]\nbase-size = 99\n\n[font]\nfamily = "monospace"\nbase-size = 15\n'
    h.equal("finds base-size inside [font] only", td.parseFontBaseSize(text), 15)
    h.equal("falls back when there is no [font] section",
      td.parseFontBaseSize('[general]\nbase-size = 99\n'), td.fallback.fontSize)
    h.equal("rounds a fractional size", td.parseFontBaseSize('[font]\nbase-size = 13.6\n'), 14)
    h.equal("falls back on empty input", td.parseFontBaseSize(""), td.fallback.fontSize)
  }

  function themeLayering() {
    h.group("theme layering: user file > omarchy > fallback")
    // These three properties are exactly what the FileViews assign after a
    // successful load, so setting them directly exercises the real bindings.
    td.parsed = { background: "#111111", foreground: "#222222", accent: "#333333", color8: "#444444", color1: "#555555" }
    td.userTheme = ({})
    td.fontBaseSize = 14

    h.equal("omarchy colour is used when the user has no override", String(td.theme.accent), "#333333")
    h.equal("muted comes from color8", String(td.theme.muted), "#444444")
    h.equal("danger comes from color1", String(td.theme.danger), "#555555")
    h.equal("font size follows shell.toml", td.theme.fontSize, 14)
    h.equal("small text is derived at omarchy's own ratio", td.theme.fontSizeSmall, Math.round(14 * 0.917))

    td.userTheme = { accent: "#ff00ff" }
    h.equal("a user override wins", String(td.theme.accent), "#ff00ff")
    h.equal("keys the user did not set still come from omarchy", String(td.theme.background), "#111111")

    td.parsed = ({})
    td.userTheme = ({})
    h.equal("with no omarchy theme at all, the fallback palette is used",
      String(td.theme.accent), String(td.fallback.accent))

    // `fontSize: 0` is silly but valid, and the code checks for undefined
    // rather than falsiness precisely so it survives. If this regresses the
    // symptom is a user override that mysteriously does nothing.
    td.userTheme = { fontSize: 0 }
    h.equal("a zero font size from the user still wins", td.theme.fontSize, 0)
    h.equal("small text never drops below 1", td.theme.fontSizeSmall, 1)

    td.userTheme = { fontSize: 20, fontSizeSmall: 9 }
    h.equal("an explicit small size is used verbatim", td.theme.fontSizeSmall, 9)
    td.userTheme = { fontSize: 20 }
    h.equal("otherwise small text derives from the user's own size", td.theme.fontSizeSmall, Math.round(20 * 0.917))
  }
}
