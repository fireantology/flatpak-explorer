import QtQuick
import "../core" as Core

// ExplorerWindow's model and state logic. The window is created but never
// shown -- these are the cross-tab bookkeeping rules that break silently
// (wrong model feeding a delegate, a confirm left armed across a tab switch),
// not anything about how it looks.
QtObject {
  id: root
  property var h: null
  property Core.FlatpakService svc: null
  property var win: null
  property Component svcComponent: Component { Core.FlatpakService {} }
  property Component winComponent: Component { Core.ExplorerWindow {} }

  function run(done) {
    h.sequence([
      start,
      tabModels,
      filtering,
      confirmArming,
      remoteChoice,
      tabSwitchClears,
      maintenanceDispatch,
      stop
    ], done)
  }

  function start(done) {
    svc = svcComponent.createObject(root)
    win = winComponent.createObject(root, { service: svc })
    h.ok("the window builds with an injected service", win !== null)
    h.waitFor("its service finishes loading", function() { return svc.installedApps.length === 3 && svc.remotes.length === 4 }, done)
  }

  function stop(done) {
    if (win) { win.destroy(); win = null }
    if (svc) { svc.destroy(); svc = null }
    done()
  }

  function tabModels(done) {
    h.group("per-tab models")
    svc.searchResults = [
      { name: "Kdenlive", appId: "org.kde.kdenlive", version: "24.08.3", remotes: "flathub" },
      { name: "Krita", appId: "org.kde.krita", version: "5.2.6", remotes: "flathub,flathub-beta" }
    ]

    win.activeTab = 0
    h.equal("Installed: activeList is the installed apps", win.activeList.length, 3)
    h.equal("Installed: the app list renders them", win.appListModel.length, 3)

    win.activeTab = 1
    h.equal("Search: activeList is the results", win.activeList.length, 2)
    h.equal("Search: the app list renders them", win.appListModel.length, 2)

    // The gotcha this guards: appList is only *hidden* on these tabs, and a
    // hidden ListView still evaluates its delegate against whatever model it
    // holds -- binding it to activeList fed app-shaped delegates a repo object
    // and logged "Unable to assign [undefined] to QString" for every field.
    win.activeTab = 2
    h.equal("Repos: activeList is the remotes", win.activeList.length, 4)
    h.equal("Repos: the app list is empty, not the remotes", win.appListModel.length, 0)

    win.activeTab = 3
    h.equal("Maintenance: activeList is the action list", win.activeList.length, win.maintenanceActions.length)
    h.equal("Maintenance: the app list is empty, not the actions", win.appListModel.length, 0)

    win.activeTab = 1
    win.selectedIndex = 1
    svc.searchResults = [{ name: "Kdenlive", appId: "org.kde.kdenlive", version: "24.08.3", remotes: "flathub" }]
    h.equal("a shrinking list clamps the selection", win.selectedIndex, 0)

    win.activeTab = 0
    done()
  }

  function filtering(done) {
    h.group("filterLocal")
    var apps = svc.installedApps
    h.equal("an empty query keeps everything", win.filterLocal(apps, "").length, 3)
    h.equal("matches on the display name", win.filterLocal(apps, "gimp").length, 1)
    h.equal("matches case-insensitively", win.filterLocal(apps, "GIMP").length, 1)
    h.equal("matches on the app id too", win.filterLocal(apps, "usebottles").length, 1)
    h.equal("no match yields nothing", win.filterLocal(apps, "zzzz").length, 0)
    done()
  }

  function confirmArming(done) {
    h.group("confirm arming")
    win.activeTab = 0
    win.selectedIndex = 0
    win.armRemoveSelected()
    h.ok("removing arms a confirmation instead of running", win.pendingConfirm !== null)
    h.equal("armed against the selected app", win.pendingConfirm.targetId, svc.installedApps[0].appId)
    h.equal("nothing has started", svc.busy, false)
    // A stray Enter must not confirm: the popup always opens on Cancel.
    h.equal("Cancel is preselected", win.confirmSelectsYes, false)

    win.confirmSelectsYes = true
    win.armUpdateAll()
    h.equal("re-arming resets the selection to Cancel", win.confirmSelectsYes, false)
    h.equal("update-all arms too", win.pendingConfirm.targetId, "*updateAll*")

    win.confirmOrCancel(false)
    h.equal("cancelling clears the arming", win.pendingConfirm, null)
    h.equal("and runs nothing", svc.busy, false)
    done()
  }

  function remoteChoice(done) {
    h.group("install-time remote choice")
    var single = { appId: "org.kde.kdenlive", remotes: "flathub" }
    var multi = { appId: "org.kde.krita", remotes: "flathub,flathub-beta" }

    win.armInstallSelected(multi)
    h.ok("a result from several remotes asks which one", win.pendingRemoteChoice !== null)
    h.jsonEqual("and offers both", win.pendingRemoteChoice.remotes, ["flathub", "flathub-beta"])
    h.equal("without installing anything yet", svc.busy, false)

    win.pendingRemoteChoice = null
    h.sequence([
      function(next) {
        win.armInstallSelected(single)
        h.equal("a single-remote result installs straight away", svc.busy, true)
        h.equal("no choice is raised", win.pendingRemoteChoice, null)
        next()
      },
      function(next) { h.waitFor("the install settles", function() { return !svc.busy }, next) }
    ], done)
  }

  function tabSwitchClears(done) {
    h.group("switching tabs resets transient state")
    win.activeTab = 2
    win.beginAddRemote()
    h.equal("the add-repo wizard starts at step 1", win.addRemoteStep, 1)
    win.armRemoveSelected()
    h.ok("a repo removal can be armed", win.pendingConfirm !== null)

    win.activeTab = 0
    h.equal("the arming is dropped", win.pendingConfirm, null)
    h.equal("the wizard is cancelled", win.addRemoteStep, 0)
    h.equal("and its half-entered name is forgotten", win.pendingRemoteName, "")

    win.pendingRemoteChoice = { appId: "org.kde.krita", remotes: ["flathub", "flathub-beta"] }
    win.activeTab = 1
    h.equal("a pending remote choice is dropped too", win.pendingRemoteChoice, null)
    win.activeTab = 0
    done()
  }

  function maintenanceDispatch(done) {
    h.group("maintenance actions")
    win.activeTab = 3
    var destructive = win.maintenanceActions[0]
    var safe = win.maintenanceActions[1]
    h.equal("the first action is the destructive one", destructive.id, "cleanUnused")
    h.ok("and is marked danger", destructive.danger)

    win.runMaintenanceAction(destructive)
    h.ok("a destructive action arms a confirmation", win.pendingConfirm !== null)
    h.equal("armed against the action id", win.pendingConfirm.targetId, "cleanUnused")
    h.equal("nothing has run yet", svc.busy, false)
    win.confirmOrCancel(false)

    h.sequence([
      function(next) {
        win.runMaintenanceAction(safe)
        h.equal("a non-destructive action runs immediately", svc.busy, true)
        h.equal("with the right verb", svc.busyVerb, "repair")
        next()
      },
      function(next) { h.waitFor("it settles", function() { return !svc.busy }, next) },
      function(next) {
        h.contains("and leaves its combined output for the popup", svc.lastActionOutput, "$ flatpak repair --system")
        h.equal("labelled with the action name", svc.lastActionLabel, "Repair installation")
        svc.lastActionOutput = ""
        win.activeTab = 0
        next()
      }
    ], done)
  }
}
