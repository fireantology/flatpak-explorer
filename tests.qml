import QtQuick
import Quickshell
import "core" as Core
import "tests" as Tests

// Test-suite entry point. Run it through ./run-tests.sh -- never directly: the
// harness refuses to start without the PATH stub that keeps these tests away
// from the real `flatpak` (see tests/Harness.qml).
//
// This lives at the repo root, not in tests/, because a Quickshell config can
// only resolve imports at or below its own root -- the same scoping rule
// CLAUDE.md documents for the app itself. From here, both "core" and "tests"
// resolve.
ShellRoot {
  id: shell

  // One service for the layers that only exercise pure functions, so the run
  // only pays for one startup battery. ServiceTests owns a separate instance:
  // it asserts on startup state, which these two are free to overwrite.
  Core.FlatpakService { id: sharedService }

  Tests.Harness { id: harness }
  Tests.PureTests { id: pureTests; h: harness; svc: sharedService }
  Tests.ParseTests { id: parseTests; h: harness; svc: sharedService }
  Tests.ServiceTests { id: serviceTests; h: harness }
  Tests.UiTests { id: uiTests; h: harness }
  Tests.MissingTests { id: missingTests; h: harness }

  // run-tests.sh runs this file twice: once normally, and once with flatpak
  // absent from PATH entirely (see MissingTests.qml).
  readonly property string mode: Quickshell.env("FLATPAK_EXPLORER_TEST_MODE") || "main"

  Component.onCompleted: {
    if (!harness.guardStub()) return
    console.log("running flatpak-explorer tests (" + mode + ")")
    if (mode === "missing") {
      harness.sequence([missingTests.run], harness.finish)
      return
    }
    harness.sequence([
      pureTests.run,
      parseTests.run,
      serviceTests.run,
      uiTests.run
    ], harness.finish)
  }
}
