import QtQuick
import "../core" as Core

// The "flatpak isn't installed" path. This needs its own process: PATH is
// fixed at launch, so run-tests.sh starts a second run against a PATH holding
// only a couple of coreutils symlinks and no flatpak at all -- there is no way
// to fake this from inside the main run, where the stub necessarily *is* on
// PATH and `command -v flatpak` therefore succeeds.
QtObject {
  id: root
  property var h: null
  property var svc: null
  property Component svcComponent: Component { Core.FlatpakService {} }

  function run(done) {
    h.group("flatpak missing from PATH")
    svc = svcComponent.createObject(root)
    h.sequence([
      function(next) { h.waitFor("the availability check completes", function() { return svc.availabilityChecked }, next) },
      function(next) {
        // This is what gates missingFlatpakOverlay in ExplorerWindow: the
        // window hard-blocks with install instructions rather than letting
        // every other command fail one after another.
        h.equal("flatpak is reported as unavailable", svc.flatpakAvailable, false)
        h.equal("no listing was attempted", svc.installedApps.length, 0)
        h.equal("no remotes were read", svc.remotes.length, 0)
        h.equal("the version gate stays at its default until flatpak exists", svc.flatpakVersionChecked, false)
        next()
      }
    ], function() {
      svc.destroy()
      svc = null
      done()
    })
  }
}
