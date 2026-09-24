import QtQuick
import "../core" as Core

// FlatpakService against the fake `flatpak` on PATH (tests/stub/flatpak).
// Two things are being checked throughout: what the service *parsed* out of a
// canned response, and what it *ran* -- the stub records its own argv, so the
// scope rules CLAUDE.md spells out become assertions rather than conventions.
QtObject {
  id: root
  property var h: null
  property Core.FlatpakService svc: null
  property Component svcComponent: Component { Core.FlatpakService {} }

  // Last actionFinished payload, captured by the connection made in start().
  property bool sawAction: false
  property bool lastOk: false
  property string lastMessage: ""
  property string lastVerb: ""

  function run(done) {
    var groups = [
      startupListings,
      scopeFlags,
      searchQuoting,
      installScope,
      uninstallScope,
      optionShapedIds,
      busySerialization,
      failurePath,
      twoStepScopes,
      twoStepFailure,
      malformedJson,
      overflowDiscard,
      stderrFlood,
      versionGate
    ]
    var steps = [start]
    groups.forEach(function(group) { steps.push(settle); steps.push(group) })
    steps.push(stop)
    h.sequence(steps, done)
  }

  // Actions end by kicking off refreshes (refreshInstalled/checkUpdates/
  // refreshDiskUsage) that outlive them. A group that starts while one is
  // still in flight gets its stray argv line in the log it's about to read,
  // or has its own refresh no-op -- the proc is already running, under the
  // previous group's scenario. So every group starts from idle.
  function settle(done) {
    var procs = [svc.listProc, svc.searchProc, svc.remoteListSystemProc, svc.remoteListUserProc,
      svc.updatesSystemProc, svc.updatesUserProc, svc.diskUsageProc, svc.versionCheckProc]
    h.waitFor("(background refreshes have settled)", function() {
      return !svc.busy && !procs.some(function(p) { return p.running })
    }, done)
  }

  function start(done) {
    h.setScenario("default", function() {
      svc = svcComponent.createObject(root)
      svc.actionFinished.connect(function(ok, message, verb) {
        root.sawAction = true
        root.lastOk = ok
        root.lastMessage = message
        root.lastVerb = verb
      })
      done()
    })
  }

  function stop(done) {
    if (svc) { svc.destroy(); svc = null }
    done()
  }

  // Everything the service fires on its own at startup.
  function startupListings(done) {
    h.group("startup listings")
    h.sequence([
      function(next) { h.waitFor("flatpak is detected on PATH", function() { return svc.availabilityChecked && svc.flatpakAvailable }, next) },
      function(next) { h.waitFor("the version check accepts 1.18.2", function() { return svc.flatpakVersionChecked && svc.flatpakVersionSupported }, next) },
      function(next) { h.waitFor("installed apps are listed", function() { return svc.installedApps.length === 3 }, next) },
      function(next) {
        var gimp = svc.installedApps[1]
        h.equal("name is mapped", gimp.name, "GIMP")
        h.equal("application_id becomes appId", gimp.appId, "org.gimp.GIMP")
        h.equal("installation scope is kept", gimp.installation, "system")
        h.equal("version is kept", gimp.version, "2.10.38")
        next()
      },
      function(next) { h.waitFor("both remote scopes are merged", function() { return svc.remotes.length === 4 }, next) },
      function(next) {
        var system = svc.remotes.filter(function(r) { return r.scope === "system" })
        var user = svc.remotes.filter(function(r) { return r.scope === "user" })
        h.equal("system remotes are labelled system", system.length, 2)
        h.equal("user remotes are labelled user", user.length, 2)
        // The bug this guards: with no explicit scope flag, flatpak returns
        // both scopes from each call, so the user remotes came back twice --
        // once correctly and once labelled system.
        var flathubs = svc.remotes.filter(function(r) { return r.name === "flathub" })
        h.equal("a remote in both scopes appears once per scope", flathubs.length, 2)
        h.jsonEqual("and with distinct scopes",
          flathubs.map(function(r) { return r.scope }).sort(), ["system", "user"])
        next()
      },
      function(next) { h.waitFor("updates are checked", function() { return svc.availableUpdates.length > 0 }, next) },
      function(next) {
        // remote-ls returned three refs across both scopes; only the two that
        // are actually installed apps may surface.
        h.equal("only installed apps surface as updates", svc.availableUpdates.length, 2)
        var ids = svc.availableUpdates.map(function(u) { return u.appId }).sort()
        h.jsonEqual("and they are the right two", ids, ["org.gimp.GIMP", "org.prismlauncher.PrismLauncher"])
        next()
      },
      function(next) { h.waitFor("disk usage is read", function() { return svc.systemDiskUsage !== "?" }, next) },
      function(next) {
        h.equal("system install size", svc.systemDiskUsage, "100M")
        h.equal("user install size", svc.userDiskUsage, "200M")
        next()
      }
    ], done)
  }

  function scopeFlags(done) {
    h.group("every listing names its scope explicitly")
    h.readArgvLog(function(text) {
      var lines = String(text).split("\n").filter(function(l) { return l.length > 0 })
      var scoped = lines.filter(function(l) { return l.indexOf("remote-list\t") === 0 || l.indexOf("remote-ls\t") === 0 })
      // Every FlatpakService alive in this process logs here, so this is a
      // floor, not an exact count -- and the check below is all the stronger
      // for covering their invocations too.
      h.ok("the scope-sensitive listings ran", scoped.length >= 4, "saw only " + scoped.length)
      var unscoped = scoped.filter(function(l) { return l.indexOf("--user") === -1 && l.indexOf("--system") === -1 })
      // Relying on flatpak's documented "defaults to system" is what produced
      // duplicated, mislabelled remotes: with a user remote configured it
      // actually returns both scopes at once.
      h.equal("none of them relies on flatpak's default scope", unscoped.length, 0)
      done()
    })
  }

  function searchQuoting(done) {
    h.group("search")
    var evil = '"; touch /tmp/flatpak-explorer-pwned #'
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      function(next) { svc.search(evil); next() },
      function(next) { h.waitFor("results come back", function() { return svc.searchResults.length === 2 }, next) },
      function(next) {
        var multi = svc.searchResults[1]
        h.equal("remotes column is kept for the install-time choice", multi.remotes, "flathub,flathub-beta")
        h.equal("description is mapped", svc.searchResults[0].description, "Video editor")
        next()
      },
      function(next) {
        h.readArgvLog(function(text) {
          var line = text.split("\n")[0] || ""
          // The query must arrive as one argv element -- if it were spliced
          // into the script text the shell would have eaten the quote and the
          // `#`, and the trailing `--` guard would be gone.
          h.contains("the query reaches flatpak intact", line, evil)
          h.contains("and is guarded by a -- separator", line, "--\t" + evil)
          next()
        })
      }
    ], done)
  }

  function installScope(done) {
    h.group("install")
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      function(next) { root.sawAction = false; svc.install("org.kde.krita", "flathub"); next() },
      function(next) { h.waitFor("the install finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) {
        h.equal("actionFinished reports success", root.lastOk, true)
        h.equal("actionFinished names the verb", root.lastVerb, "install")
        h.equal("status message is the friendly one", svc.statusMessage, "Installed")
        next()
      },
      function(next) {
        h.readArgvLog(function(text) {
          var line = text.split("\n")[0] || ""
          // flathub exists in both scopes in the fixtures; remoteScope() must
          // pick user, so no polkit prompt for a plain install.
          h.equal("installs from the user copy of a dual-scope remote", line,
            "install\t-y\t--user\t--\tflathub\torg.kde.krita\t")
          next()
        })
      }
    ], done)
  }

  function uninstallScope(done) {
    h.group("uninstall")
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      // No scope passed: it has to come from the installed list, where GIMP is
      // recorded as a system install.
      function(next) { root.sawAction = false; svc.uninstall("org.gimp.GIMP"); next() },
      function(next) { h.waitFor("the uninstall finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) {
        h.readArgvLog(function(text) {
          var line = text.split("\n")[0] || ""
          h.equal("uses the scope the app is actually installed in", line,
            "uninstall\t-y\t--system\t--\torg.gimp.GIMP\t")
          next()
        })
      },
      function(next) {
        h.equal("actionFinished names the verb", root.lastVerb, "uninstall")
        next()
      }
    ], done)
  }

  // flatpak reads options even after positional arguments, and install()'s
  // app id comes from a remote's appstream data -- so an "id" shaped like a
  // flag must reach flatpak after `--`, as a positional, never as an option.
  function optionShapedIds(done) {
    h.group("option-shaped ids stay positional")
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      function(next) { root.sawAction = false; svc.install("--no-related", "flathub"); next() },
      function(next) { h.waitFor("the install finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) { root.sawAction = false; svc.addRemote("--no-gpg-verify", "https://example.invalid/x.flatpakrepo", "user"); next() },
      function(next) { h.waitFor("the remote-add finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) {
        h.readArgvLog(function(text) {
          var lines = text.split("\n")
          h.ok("install puts the id after --", lines.indexOf("install\t-y\t--user\t--\tflathub\t--no-related\t") !== -1, JSON.stringify(lines))
          h.ok("remote-add puts the name after --", lines.indexOf("remote-add\t--if-not-exists\t--user\t--\t--no-gpg-verify\thttps://example.invalid/x.flatpakrepo\t") !== -1, JSON.stringify(lines))
          next()
        })
      }
    ], done)
  }

  function busySerialization(done) {
    h.group("one mutating command at a time")
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      function(next) {
        svc.install("org.kde.krita", "flathub")
        h.ok("busy is set synchronously", svc.busy)
        h.equal("busyVerb names what is running", svc.busyVerb, "install")
        h.equal("busyTarget names what it is running on", svc.busyTarget, "org.kde.krita")
        // Second mutating call while the first is in flight: must no-op.
        svc.uninstall("org.gimp.GIMP")
        h.equal("a second command does not steal busyVerb", svc.busyVerb, "install")
        h.equal("nor busyTarget", svc.busyTarget, "org.kde.krita")
        next()
      },
      function(next) { h.waitFor("the first command finishes", function() { return !svc.busy }, next) },
      function(next) {
        h.readArgvLog(function(text) {
          var mutations = text.split("\n").filter(function(l) { return l.indexOf("install\t") === 0 || l.indexOf("uninstall\t") === 0 })
          h.equal("only one flatpak invocation actually happened", mutations.length, 1)
          next()
        })
      }
    ], done)
  }

  function failurePath(done) {
    h.group("a failing command")
    h.sequence([
      function(next) { h.setScenario("failmutate", next) },
      function(next) { root.sawAction = false; svc.install("org.kde.krita", "flathub"); next() },
      function(next) { h.waitFor("it finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) {
        h.equal("actionFinished reports failure", root.lastOk, false)
        // flatpak's own last stderr line, not a generic "install failed".
        h.contains("the real error text is surfaced", svc.statusMessage, "Network unreachable")
        h.equal("busy is released anyway", svc.busy, false)
        h.equal("busyTarget is cleared", svc.busyTarget, "")
        next()
      },
      function(next) { h.setScenario("default", next) }
    ], done)
  }

  // updateAll/cleanUnused/repair: one --system leg, one --user leg, and never
  // a scopeless one -- `flatpak update` with no flag updates *both*
  // installations (flatpak-update(1)), which is what updateAll's system leg
  // silently did until it got an explicit --system.
  function twoStepScopes(done) {
    h.group("two-step actions pass an explicit scope")
    var verbs = ["update", "uninstall", "repair"]
    h.sequence([
      function(next) { h.clearArgvLog(next) },
      function(next) { root.sawAction = false; svc.updateAll(); next() },
      function(next) { h.waitFor("updateAll finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) { h.equal("and reports success", root.lastOk, true); next() },
      function(next) { root.sawAction = false; svc.cleanUnused(); next() },
      function(next) { h.waitFor("cleanUnused finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) { h.equal("and reports success", root.lastOk, true); next() },
      function(next) { root.sawAction = false; svc.repair(); next() },
      function(next) { h.waitFor("repair finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) { h.equal("and reports success", root.lastOk, true); next() },
      function(next) {
        h.readArgvLog(function(text) {
          var mutations = text.split("\n").map(function(l) { return l.split("\t") })
            .filter(function(a) { return verbs.indexOf(a[0]) !== -1 })
          verbs.forEach(function(verb) {
            var runs = mutations.filter(function(a) { return a[0] === verb })
            h.ok(verb + " runs a --system leg", runs.some(function(a) { return a.indexOf("--system") !== -1 }))
            h.ok(verb + " runs a --user leg", runs.some(function(a) { return a.indexOf("--user") !== -1 }))
          })
          var scopeless = mutations.filter(function(a) { return a.indexOf("--system") === -1 && a.indexOf("--user") === -1 })
          h.equal("no leg runs without a scope", scopeless.map(function(a) { return a.join(" ").trim() }).join(" | "), "")
          next()
        })
      }
    ], done)
  }

  // A failed system leg (a cancelled polkit prompt, say) used to be reported
  // as success, since only the user leg's completion decided the verdict.
  function twoStepFailure(done) {
    h.group("a failed system leg fails the two-step action")
    var cases = [
      { verb: "updateAll", argv0: "update", run: function() { svc.updateAll() } },
      { verb: "cleanUnused", argv0: "uninstall", run: function() { svc.cleanUnused() } },
      { verb: "repair", argv0: "repair", run: function() { svc.repair() } }
    ]
    var steps = [function(next) { h.setScenario("failsystem", next) }]
    cases.forEach(function(c) {
      steps.push(function(next) { h.clearArgvLog(next) })
      steps.push(function(next) { root.sawAction = false; c.run(); next() })
      steps.push(function(next) { h.waitFor(c.verb + " finishes", function() { return !svc.busy && root.sawAction }, next) })
      steps.push(function(next) {
        h.equal(c.verb + ": reports failure", root.lastOk, false)
        h.contains(c.verb + ": with flatpak's own error, tagged by scope", svc.statusMessage, "system: error: Not allowed to")
        h.contains(c.verb + ": which also lands in the live log", svc.liveLog, "system: error: Not allowed to")
        next()
      })
      steps.push(function(next) {
        h.readArgvLog(function(text) {
          h.ok(c.verb + ": the user leg still ran", text.split("\n").some(function(l) { return l.indexOf(c.argv0 + "\t") === 0 && l.indexOf("\t--user\t") !== -1 }))
          next()
        })
      })
    })
    steps.push(function(next) { h.setScenario("default", next) })
    h.sequence(steps, done)
  }

  function malformedJson(done) {
    h.group("malformed JSON from flatpak")
    h.sequence([
      function(next) { h.setScenario("malformed", next) },
      function(next) { svc.refreshInstalled(); next() },
      function(next) { h.waitFor("the installed list empties instead of throwing", function() { return svc.installedApps.length === 0 }, next) },
      // searchProc must assign searchResults even when parsing failed:
      // ExplorerWindow clears its searchPending flag on that change, and while
      // the flag is set the busy overlay swallows every key -- a path that
      // returns without assigning strands the UI with no way out.
      function(next) { svc.searchResults = [{ appId: "sentinel" }]; svc.search("anything"); next() },
      function(next) { h.waitFor("searchResults is still assigned on a parse failure", function() { return svc.searchResults.length === 0 }, next) },
      function(next) { h.setScenario("default", next) }
    ], done)
  }

  function overflowDiscard(done) {
    h.group("oversized response")
    h.sequence([
      function(next) { h.setScenario("overflow", next) },
      function(next) { svc.statusMessage = ""; svc.refreshInstalled(); next() },
      function(next) { h.waitFor("the response is reported as too large", function() { return svc.statusMessage.indexOf("too much output") !== -1 }, next) },
      function(next) {
        h.equal("and is discarded rather than parsed as truncated JSON", svc.installedApps.length, 0)
        next()
      },
      function(next) { h.setScenario("default", next) }
    ], done)
  }

  // stderr is capped at the source like stdout: the collector must hold no
  // more than stderrCapChars however much flatpak writes, and the last line --
  // the one shortError shows -- must survive the cut.
  function stderrFlood(done) {
    h.group("oversized stderr")
    h.sequence([
      function(next) { h.setScenario("stderrflood", next) },
      function(next) { svc.installedApps = []; svc.refreshInstalled(); next() },
      function(next) { h.waitFor("a listing still parses despite the stderr flood", function() { return svc.installedApps.length > 0 }, next) },
      function(next) {
        var held = svc.listProc.stderr.text.length
        h.ok("listing stderr is held to the cap", held > 0 && held <= svc.stderrCapChars, "held " + held)
        next()
      },
      function(next) { root.sawAction = false; svc.install("org.kde.krita", "flathub"); next() },
      function(next) { h.waitFor("the install finishes", function() { return !svc.busy && root.sawAction }, next) },
      function(next) {
        var held = svc.installProc.stderr.text.length
        h.ok("mutating stderr is held to the cap", held > 0 && held <= svc.stderrCapChars, "held " + held)
        h.equal("flatpak's own non-zero exit still reads as failure", root.lastOk, false)
        h.equal("the last stderr line survives the cut", svc.statusMessage, "error: install after a flood of warnings")
        next()
      },
      function(next) { h.setScenario("default", next) }
    ], done)
  }

  function versionGate(done) {
    h.group("minimum flatpak version")
    h.sequence([
      function(next) { h.setScenario("oldversion", next) },
      function(next) { svc.flatpakVersionChecked = false; svc.checkVersion(); next() },
      function(next) { h.waitFor("an old flatpak is rejected", function() { return svc.flatpakVersionChecked && !svc.flatpakVersionSupported }, next) },
      function(next) { h.equal("and the version it found is reported", svc.flatpakVersion, "1.9.2"); next() },
      function(next) { h.setScenario("unparseableversion", next) },
      function(next) { svc.flatpakVersionChecked = false; svc.checkVersion(); next() },
      function(next) { h.waitFor("a version string with no digits is rejected too", function() { return svc.flatpakVersionChecked && !svc.flatpakVersionSupported }, next) },
      function(next) { h.equal("with an empty version", svc.flatpakVersion, ""); next() },
      function(next) { h.setScenario("default", next) },
      function(next) { svc.flatpakVersionChecked = false; svc.checkVersion(); next() },
      function(next) { h.waitFor("a current flatpak is accepted again", function() { return svc.flatpakVersionChecked && svc.flatpakVersionSupported }, next) }
    ], done)
  }
}
