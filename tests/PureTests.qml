import QtQuick
import "../core" as Core

// Synchronous tests for FlatpakService's pure functions -- no process, no
// waiting. Anything that reads instance state sets that state and asserts in
// the same step, so an in-flight startup query can never land in between (QML
// runs JS to completion on one thread).
QtObject {
  id: root
  property var h: null
  // Injected by tests.qml -- these tests never start one of their own.
  property Core.FlatpakService svc: null

  function run(done) {
    versions()
    capping()
    excerpts()
    liveLog()
    lookups()
    done()
  }

  function versions() {
    h.group("compareVersions")
    h.equal("equal versions", svc.compareVersions("1.17.0", "1.17.0"), 0)
    h.equal("missing segment counts as zero", svc.compareVersions("1.17", "1.17.0"), 0)
    // The whole reason this function exists instead of a string compare:
    // "1.9.2" > "1.17.0" alphabetically, but 9 < 17 numerically.
    h.equal("1.9.2 is older than 1.17.0", svc.compareVersions("1.9.2", "1.17.0"), -1)
    h.equal("1.18.1 is newer than 1.17.0", svc.compareVersions("1.18.1", "1.17.0"), 1)
    h.equal("2.0 is newer than 1.99.99", svc.compareVersions("2.0", "1.99.99"), 1)
    h.equal("empty reads as older", svc.compareVersions("", "1.17.0"), -1)
    h.equal("garbage reads as older", svc.compareVersions("not-a-version", "1.17.0"), -1)
  }

  function capping() {
    h.group("cappedCommand / overflowed")
    var plain = svc.cappedCommand("flatpak list -j")
    h.equal("wraps in sh -c", plain[0], "sh")
    h.equal("second arg is -c", plain[1], "-c")
    h.contains("execs the command", plain[2], "exec flatpak list -j")
    h.contains("pipes through head -c", plain[2], "| head -c " + svc.listingCapChars)
    h.equal("no extra argv without an argument", plain.length, 3)

    // The injection guard: a query must reach the shell as argv, never as
    // script text. If this ever regresses, a search for `; rm -rf ~` runs it.
    var evil = '"; rm -rf ~ #'
    var withArg = svc.cappedCommand('flatpak search -j -- "$1"', evil)
    h.equal("user input is passed as argv", withArg.length, 5)
    h.equal("argv[3] is sh (the $0 placeholder)", withArg[3], "sh")
    h.equal("argv[4] is the raw query", withArg[4], evil)
    h.contains("script references $1", withArg[2], '"$1"')
    h.notContains("script text never contains the query", withArg[2], "rm -rf")

    var cap = svc.listingCapChars
    var atCap = new Array(cap + 1).join("x")
    h.equal("test string really is cap-sized", atCap.length, cap)
    h.ok("output at the cap counts as overflowed", svc.overflowed(atCap))
    h.ok("output one short of the cap does not", !svc.overflowed(atCap.slice(0, cap - 1)))
    h.ok("empty output does not", !svc.overflowed(""))
  }

  function excerpts() {
    h.group("excerpt / shortError")
    h.equal("short text is untouched", svc.excerpt("hello", 100), "hello")
    h.equal("null is empty", svc.excerpt(null, 100), "")
    var long = new Array(5001).join("y")
    var cut = svc.excerpt(long, 2000)
    h.ok("long text is clamped", cut.length < long.length)
    h.contains("truncation is announced with the real total", cut, "[truncated, 5000 chars total]")

    h.equal("last non-empty stderr line wins",
      svc.shortError("Looking for matches...\nerror: Nothing matches\n\n", "fallback"),
      "error: Nothing matches")
    h.equal("empty stderr falls back", svc.shortError("   \n\n", "fallback"), "fallback")
    var huge = "error: " + new Array(2001).join("z")
    h.ok("a single huge stderr line is still bounded", svc.shortError(huge, "fallback").length < huge.length)
  }

  function liveLog() {
    h.group("appendLiveLog")
    var command = ["flatpak", "install", "-y", "--user", "flathub", "org.kde.krita"]
    svc.beginLiveLog(command)
    h.equal("starts with the command line", svc.liveLog, "$ " + command.join(" ") + "\n")

    var filler = new Array(1001).join("x")
    for (var i = 0; i < 400; i++) svc.appendLiveLog(i + " " + filler)

    h.ok("stays under the retention cap", svc.liveLog.length <= svc.liveLogCapChars,
      "length " + svc.liveLog.length + " > cap " + svc.liveLogCapChars)
    h.ok("the command line survives truncation", svc.liveLog.indexOf("$ " + command.join(" ")) === 0)

    var marker = "characters of earlier output truncated"
    h.equal("exactly one truncation marker", svc.liveLog.split(marker).length - 1, 1)
    var firstTotal = parseInt(svc.liveLog.split("[... ")[1], 10)

    // What follows the marker must be a whole line, not the tail of one.
    var afterMarker = svc.liveLog.split(marker + " ...]\n")[1] || ""
    h.ok("resumes on a line boundary", /^\d+ x+\n/.test(afterMarker),
      "started with " + JSON.stringify(afterMarker.slice(0, 40)))

    for (var j = 0; j < 400; j++) svc.appendLiveLog("second round " + j + " " + filler)
    h.equal("still exactly one marker after a second overflow", svc.liveLog.split(marker).length - 1, 1)
    var secondTotal = parseInt(svc.liveLog.split("[... ")[1], 10)
    h.ok("the dropped-character total keeps accumulating", secondTotal > firstTotal,
      firstTotal + " -> " + secondTotal)
  }

  function lookups() {
    h.group("installed / scope / update lookups")
    svc.installedApps = [
      { appId: "org.prismlauncher.PrismLauncher", installation: "user" },
      { appId: "org.gimp.GIMP", installation: "system" }
    ]
    h.ok("isInstalled finds an installed app", svc.isInstalled("org.gimp.GIMP"))
    h.ok("isInstalled rejects an unknown app", !svc.isInstalled("org.kde.krita"))
    h.equal("scopeOf uses the recorded installation", svc.scopeOf("org.gimp.GIMP"), "system")
    h.equal("scopeOf defaults to user when unknown", svc.scopeOf("org.kde.krita"), "user")

    svc.remotes = [
      { name: "flathub", scope: "system" },
      { name: "flathub", scope: "user" },
      { name: "fedora", scope: "system" }
    ]
    // A remote registered in both scopes must resolve to user -- installing
    // from the system copy would raise a polkit prompt for no reason.
    h.equal("remoteScope prefers user when a remote is in both", svc.remoteScope("flathub"), "user")
    h.equal("remoteScope uses system when that is all there is", svc.remoteScope("fedora"), "system")
    h.equal("remoteScope defaults to user when unknown", svc.remoteScope("nope"), "user")

    svc.availableUpdates = [{ appId: "org.gimp.GIMP", version: "2.10.40" }]
    h.equal("isUpdatable returns the pending row", svc.isUpdatable("org.gimp.GIMP").version, "2.10.40")
    h.equal("isUpdatable returns null otherwise", svc.isUpdatable("org.kde.krita"), null)

    // Runtime bumps come back from remote-ls but must not surface as app
    // updates -- they ride along when their owning app updates.
    var merged = svc.mergeUpdates(
      [{ appId: "org.gimp.GIMP" }],
      [{ appId: "org.prismlauncher.PrismLauncher" }, { appId: "org.freedesktop.Platform.GL.default" }])
    h.equal("mergeUpdates keeps only installed apps", merged.length, 2)
    h.ok("mergeUpdates drops the bare runtime",
      merged.map(function(u) { return u.appId }).indexOf("org.freedesktop.Platform.GL.default") === -1)
  }
}
