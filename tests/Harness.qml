import QtQuick
import Quickshell
import Quickshell.Io

// Minimal test harness. Hand-rolled on purpose: Quickshell's QML types are
// compiled into the `quickshell` binary itself (its qmldir says `optional
// plugin` + `prefer :/qt/qml/Quickshell/`, and no .so is installed), so
// qmltestrunner cannot `import Quickshell` and Qt Quick Test can't drive any
// of this. Everything here runs inside a real `quickshell` process instead.
//
// Two consequences shape the API below:
//   - Neither Qt.exit() nor Qt.quit() is wired up by quickshell ("Signal
//     QQmlEngine::exit() emitted, but no receivers connected"), so the run
//     ends by SIGTERMing its own pid, and the pass/fail verdict travels out
//     on the __TESTS__ sentinel line that run-tests.sh greps for -- not in
//     the exit code, which is always 143.
//   - Anything involving a Process is asynchronous, so tests are written as
//     a sequence of steps that each call done() when finished.
QtObject {
  id: root

  property int passed: 0
  property int failed: 0
  property string currentGroup: ""
  // Generous: these waits are for a stub shell script, not the network, but a
  // loaded CI box can still be slow to fork.
  property int waitTimeoutMs: 10000

  readonly property string controlPath: Quickshell.env("FLATPAK_EXPLORER_TEST_CONTROL") || ""
  readonly property string argvLogPath: Quickshell.env("FLATPAK_EXPLORER_TEST_LOG") || ""

  // ---------------------------------------------------------------- asserts

  function group(name) {
    currentGroup = name
    console.log("")
    console.log("-- " + name)
  }

  function ok(name, condition, detail) {
    if (condition) {
      passed += 1
      console.log("  ok   " + name)
    } else {
      failed += 1
      console.warn("  FAIL " + name + (detail ? " -- " + detail : ""))
    }
    return !!condition
  }

  function equal(name, actual, expected) {
    return ok(name, actual === expected, "expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual))
  }

  function jsonEqual(name, actual, expected) {
    var a = JSON.stringify(actual)
    var b = JSON.stringify(expected)
    return ok(name, a === b, "expected " + b + ", got " + a)
  }

  function contains(name, haystack, needle) {
    var h = String(haystack)
    return ok(name, h.indexOf(needle) !== -1, "expected to find " + JSON.stringify(needle) + " in " + JSON.stringify(h.length > 300 ? h.slice(0, 300) + "..." : h))
  }

  function notContains(name, haystack, needle) {
    var h = String(haystack)
    return ok(name, h.indexOf(needle) === -1, "expected NOT to find " + JSON.stringify(needle) + " in " + JSON.stringify(h.length > 300 ? h.slice(0, 300) + "..." : h))
  }

  // --------------------------------------------------------------- stepping

  // Runs steps in order, each receiving a done callback. Nests safely: every
  // sequence keeps its own cursor in a closure, so a step can itself be a
  // whole sub-sequence.
  function sequence(steps, done) {
    var index = 0
    function next() {
      if (index >= steps.length) {
        if (done) done()
        return
      }
      var step = steps[index++]
      step(next)
    }
    next()
  }

  property var _waitPredicate: null
  property var _waitDone: null
  property string _waitName: ""
  property int _waitElapsed: 0

  property Timer _waitTimer: Timer {
    interval: 25
    repeat: true
    onTriggered: root._waitTick()
  }

  // Polls until predicate() goes true. Only one wait is ever in flight, since
  // everything runs as a sequence.
  function waitFor(name, predicate, done) {
    _waitName = name
    _waitPredicate = predicate
    _waitDone = done
    _waitElapsed = 0
    if (predicate()) {
      ok(name, true)
      done()
      return
    }
    _waitTimer.running = true
  }

  function _waitTick() {
    _waitElapsed += _waitTimer.interval
    var settled = false
    try {
      settled = !!_waitPredicate()
    } catch (e) {
      _waitTimer.running = false
      ok(_waitName, false, "predicate threw: " + e)
      var errDone = _waitDone
      _waitDone = null
      errDone()
      return
    }
    if (!settled && _waitElapsed < waitTimeoutMs) return

    _waitTimer.running = false
    ok(_waitName, settled, settled ? "" : "timed out after " + waitTimeoutMs + "ms")
    var done = _waitDone
    _waitDone = null
    done()
  }

  // ---------------------------------------------------------------- helpers

  property var _helperDone: null

  property Process helperProc: Process {
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var callback = root._helperDone
      root._helperDone = null
      if (callback) callback(exitCode, helperProc.stdout.text)
    }
  }

  function runHelper(command, done) {
    _helperDone = done
    helperProc.running = false
    helperProc.command = command
    helperProc.running = true
  }

  // Switches what tests/stub/flatpak answers with. The stub re-reads this file
  // on every invocation, so a scenario can change mid-run.
  function setScenario(name, done) {
    runHelper(["sh", "-c", 'printf %s "$1" > "$2"', "sh", name, controlPath], function() { done() })
  }

  function clearArgvLog(done) {
    runHelper(["sh", "-c", ': > "$1"', "sh", argvLogPath], function() { done() })
  }

  // Hands back everything the stub has recorded since the last clear, one
  // invocation per line, arguments tab-separated.
  function readArgvLog(done) {
    runHelper(["cat", argvLogPath], function(exitCode, text) { done(String(text || "")) })
  }

  // ------------------------------------------------------------------ gates

  // Some tests call install()/uninstall() to assert on the argv that gets
  // built. Against a real flatpak those would mutate the tester's system, so
  // the suite refuses to run unless run-tests.sh put the stub on PATH.
  function guardStub() {
    if (Quickshell.env("FLATPAK_EXPLORER_TEST_STUB") === "1") return true
    console.warn("")
    console.warn("REFUSING TO RUN: the flatpak stub is not on PATH.")
    console.warn("These tests call install/uninstall/repair and would hit your real")
    console.warn("flatpak installation. Run them with ./run-tests.sh instead.")
    failed += 1
    finish()
    return false
  }

  function finish() {
    console.log("")
    console.log("== " + passed + " passed, " + failed + " failed")
    // The verdict has to leave on stdout: quickshell ignores Qt.exit(), so the
    // process always dies by signal and its exit code carries no information.
    console.log("__TESTS__ passed=" + passed + " failed=" + failed)
    runHelper(["kill", "-TERM", String(Quickshell.processId)], function() {})
  }
}
