import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell

// The whole app. Pure QtQuick plus Quickshell's own FloatingWindow -- no
// qs.* (Omarchy) imports, so it runs identically whether it's the sole
// window under a bespoke ShellRoot (standalone) or loaded inside Omarchy's
// shared shell process (plugin adapter). Hosts inject look and feel via
// `theme`; nothing in here reaches out to a host-specific singleton.
//
// FloatingWindow, not QtQuick.Window: a plain Window works fine as the
// static top-level content of a fresh process's own ShellRoot (the
// standalone build), but a host that loads this dynamically via a Loader
// deep inside its own already-running Quickshell process (the Omarchy
// plugin adapter) never maps a plain Window as a real surface at all --
// no error, it just never appears. FloatingWindow (Quickshell._Window,
// auto-imported by plain `import Quickshell`) is Quickshell's own answer
// to exactly that case; Omarchy's own reference plugin
// ($OMARCHY_PATH/shell/plugins/dev-gallery/GalleryPanel.qml) uses the same
// type for the same reason. Its API differs from Window in a few places
// (see below) but is otherwise a normal, decorated, resizable top-level
// window (not a layer-shell overlay) -- tileable/movable/alt-tabbable like
// any other app, since this is meant to be used as a real package-manager
// window, not a quick popup.
//
// TUI-style: monospace, sharp corners, an arrow + underline marking the
// selected row (no full-row highlight fill), bordered (not filled) buttons
// with an always-black backing in the style of Omarchy's own panels --
// driven entirely by keyboard with every action also reachable by mouse.
// Four tabs (Installed/Search/Repos/Maintenance) share one input line,
// whose role changes per tab: local substring filter (Installed, which
// also shows a per-row [update] when one is pending -- no separate Updates
// tab), Flathub query fired only on Enter -- never as-you-type -- (Search),
// a two-step add-repo wizard (Repos), or nothing at all (Maintenance,
// which is just a short list of one-shot actions). Tab/Shift-Tab (or a
// mouse click on the tab strip) is the only way to switch tabs -- no
// number-key shortcuts, so the tab strip doesn't need to renumber itself
// whenever a tab is added or reordered.
FloatingWindow {
  id: root

  title: "Flatpak Explorer"
  implicitWidth: 900
  implicitHeight: 600
  // Floor chosen so a row's essentials -- name, id, and its action button --
  // stay legible when tiled narrow next to another window, without yet
  // needing to hide the version column (see row delegates below).
  // FloatingWindow takes one QSize rather than separate min-width/height.
  minimumSize: Qt.size(560, 320)
  color: root.theme.background

  property var theme: Theme {}
  property bool open: false

  // No raise()/requestActivate() on FloatingWindow (WindowInterface has no
  // equivalent) -- becoming visible is enough for the compositor to focus
  // a newly-mapped toplevel.
  // Always starts back on Installed -- matches the Omarchy plugin adapter,
  // where the host destroys and recreates this component on every
  // hide/summon cycle (no keepLoaded in manifest.json) and so can't
  // remember the tab either. Keeping the standalone build's own
  // toggle-via-IPC behavior consistent with that rather than adding
  // keepLoaded to make the plugin remember instead.
  function show() { activeTab = 0; open = true }
  function close() { open = false }
  function toggle() { open = !open }

  visible: open
  onOpenChanged: if (open) Qt.callLater(function() { searchField.forceActiveFocus() })
  // FloatingWindow has no cancelable closing event to override (unlike
  // QtQuick.Window, it never ties a window's close to the process quitting
  // in the first place) -- the window-manager close button just sets
  // `visible` false directly, so this syncs `open` back to match instead.
  // Keeps the standalone build's toggle-via-IPC design working the same
  // way: the process (and FlatpakService state) stays alive, a later
  // `ipc call explorer toggle` brings the window straight back.
  onVisibleChanged: if (!visible) root.open = false

  property FlatpakService service: FlatpakService {}

  // Jumping back to Installed + clearing the filter after a successful
  // install means "what I just got" is immediately visible without an
  // extra tab switch or manual clear.
  Connections {
    target: root.service
    function onActionFinished(success, message, verb) {
      if (success && verb === "install") {
        root.activeTab = 0
        searchField.text = ""
      }
    }
  }

  readonly property var tabNames: ["Installed", "Search", "Repos", "Maintenance"]
  property int activeTab: 0
  onActiveTabChanged: { selectedIndex = 0; pendingConfirm = null; pendingRemoteChoice = null; if (activeTab !== 2) cancelAddRemote() }

  // A small static list of one-shot maintenance actions rather than
  // anything backed by a flatpak listing -- each entry is its own {label,
  // desc, actionLabel, danger, run} so the Maintenance tab's GridView
  // delegate and runMaintenanceAction() below can stay generic as more
  // actions get added here. `desc` is plain-language, not the flatpak
  // invocation itself -- that's an implementation detail, not something
  // the person clicking the card needs to see.
  readonly property var maintenanceActions: [
    {
      id: "cleanUnused",
      label: "Remove unused runtimes",
      desc: "Frees disk space by removing runtimes and locale packs nothing installed still depends on.",
      actionLabel: "clean",
      danger: true,
      run: function() { service.cleanUnused() }
    },
    {
      id: "repair",
      label: "Repair installation",
      desc: "Re-verifies every installed file and fixes anything corrupted, e.g. after an interrupted update.",
      actionLabel: "repair",
      danger: false,
      run: function() { service.repair() }
    }
  ]

  function runMaintenanceAction(action) {
    if (service.busy) return
    if (action.danger) pendingConfirm = { label: action.label.toLowerCase(), targetId: action.id, run: action.run }
    else action.run()
  }

  function filterLocal(list, query) {
    if (!query || query.length === 0) return list
    var q = query.toLowerCase()
    return list.filter(function(it) {
      return it.name.toLowerCase().indexOf(q) !== -1 || it.appId.toLowerCase().indexOf(q) !== -1
    })
  }

  readonly property var activeList: {
    if (activeTab === 0) return filterLocal(service.installedApps, searchField.text)
    if (activeTab === 1) return service.searchResults
    if (activeTab === 2) return service.remotes
    return maintenanceActions
  }

  // appList's delegate expects app-shaped objects (modelData.version,
  // .appId, ...) -- binding its model straight to activeList would feed it
  // remote/maintenance-action objects while on those tabs (the ListView is
  // only visually hidden, its delegates still evaluate against whatever
  // model it holds), producing "Unable to assign [undefined] to QString"
  // warnings for every field those objects don't have. A proper computed
  // property (not a `visible ? activeList : []` ternary, which would let
  // activeList's own change tracking go stale while hidden) keeps that
  // tracking intact while giving appList an empty, safe model on the tabs
  // it doesn't apply to.
  readonly property var appListModel: {
    if (activeTab === 0) return filterLocal(service.installedApps, searchField.text)
    if (activeTab === 1) return service.searchResults
    return []
  }

  property int selectedIndex: 0
  onActiveListChanged: selectedIndex = activeList.length > 0 ? Math.min(selectedIndex, activeList.length - 1) : 0

  function activeListView() {
    if (activeTab === 2) return repoList
    if (activeTab === 3) return maintenanceList
    return appList
  }

  function moveSelection(delta) {
    if (activeList.length === 0) return
    selectedIndex = (selectedIndex + delta + activeList.length) % activeList.length
    activeListView().positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  // Search only ever runs on Enter -- no as-you-type debounce -- so it's a
  // single deliberate network call rather than one per pause in typing.
  // Search tab's Enter is dual-purpose: if the box holds a query that
  // hasn't actually been searched yet, fire it (showing the searching
  // popup below) -- otherwise act on the currently selected result, same
  // as Installed does.
  property string lastSearchedQuery: ""
  property bool searchPending: false

  Connections {
    target: root.service
    function onSearchResultsChanged() { root.searchPending = false }
  }

  function activateSelection() {
    if (service.busy || searchPending || activeTab === 2) return
    if (activeTab === 3) {
      if (activeList.length === 0) return
      runMaintenanceAction(activeList[selectedIndex])
      return
    }
    if (activeTab === 1 && searchField.text.length > 0 && searchField.text !== lastSearchedQuery) {
      lastSearchedQuery = searchField.text
      searchPending = true
      service.search(searchField.text)
      return
    }
    if (activeList.length === 0) return
    var item = activeList[selectedIndex]
    var pending = service.isUpdatable(item.appId)
    if (pending) { service.updateApp(item.appId, service.scopeOf(item.appId)); return }
    if (!service.isInstalled(item.appId)) armInstallSelected(item)
  }

  // Confirm-arming for destructive/bulk actions: {label, targetId, run}.
  // Set instead of running immediately; Left/Right picks yes/cancel and
  // Enter activates whichever is selected (or click the same action label
  // again to confirm directly). Defaults to Cancel selected -- a stray
  // Enter while the popup is up should never confirm something destructive.
  property var pendingConfirm: null
  property bool confirmSelectsYes: false
  onPendingConfirmChanged: confirmSelectsYes = false

  function confirmOrCancel(accepted) {
    if (pendingConfirm && accepted) pendingConfirm.run()
    pendingConfirm = null
  }

  // `flatpak search` queries every enabled remote at once, so a result can
  // legitimately come from more than one (e.g. flathub + flathub-beta).
  // Rather than silently installing from whichever remote happens to be
  // first in that comma list, arm a choice -- {appId, remotes: [...]} --
  // and let a number key (or nothing, if there's only one remote) pick it.
  property var pendingRemoteChoice: null

  function armInstallSelected(item) {
    var remotesList = (item.remotes || "flathub").split(",").map(function(r) { return r.trim() }).filter(function(r) { return r.length > 0 })
    if (remotesList.length <= 1) { service.install(item.appId, remotesList[0] || "flathub"); return }
    pendingRemoteChoice = { appId: item.appId, remotes: remotesList }
  }

  function chooseInstallRemote(index) {
    if (!pendingRemoteChoice) return
    var choice = pendingRemoteChoice
    pendingRemoteChoice = null
    if (index >= 0 && index < choice.remotes.length) service.install(choice.appId, choice.remotes[index])
  }

  function armRemoveSelected() {
    if (service.busy) return
    if (activeTab === 2) {
      if (service.remotes.length === 0) return
      var repo = service.remotes[selectedIndex]
      pendingConfirm = { label: "remove repo " + repo.name, targetId: repo.name, run: function() { service.removeRemote(repo.name, repo.scope) } }
      return
    }
    if (activeList.length === 0) return
    var item = activeList[selectedIndex]
    if (!service.isInstalled(item.appId)) return
    pendingConfirm = { label: "remove " + item.appId, targetId: item.appId, run: function() { service.uninstall(item.appId, service.scopeOf(item.appId)) } }
  }

  function armUpdateAll() {
    if (service.busy) return
    pendingConfirm = { label: "update all pending updates", targetId: "*updateAll*", run: function() { service.updateAll() } }
  }

  // Repos tab: 'a' starts a three-step inline wizard reusing the shared
  // input line (name, then url, then scope) instead of a separate dialog.
  // Scope is a keypress choice (u/s), not free text -- flatpak's system
  // helper handles the actual elevation via polkit, so this app never
  // prompts for a password itself; if no polkit agent is running on the
  // desktop, --system just fails and that error surfaces the normal way.
  property int addRemoteStep: 0 // 0 inactive, 1 entering name, 2 entering url, 3 choosing scope
  property string pendingRemoteName: ""
  property string pendingRemoteUrl: ""

  function beginAddRemote() {
    if (service.busy) return
    addRemoteStep = 1
    searchField.text = ""
  }

  function submitAddRemoteStep() {
    if (addRemoteStep === 1) {
      var name = searchField.text.trim()
      if (name.length === 0) { cancelAddRemote(); return }
      pendingRemoteName = name
      addRemoteStep = 2
      // Flathub's URL is the one repo URL anyone can be expected to type
      // from memory zero times -- pre-fill (and select, so typing anything
      // else just overwrites it) rather than making everyone paste it in.
      if (name.toLowerCase() === "flathub") {
        searchField.text = "https://flathub.org/repo/flathub.flatpakrepo"
        searchField.selectAll()
      } else {
        searchField.text = ""
      }
    } else if (addRemoteStep === 2) {
      var url = searchField.text.trim()
      if (url.length === 0) { cancelAddRemote(); return }
      pendingRemoteUrl = url
      addRemoteStep = 3
      searchField.text = ""
    }
  }

  function chooseAddRemoteScope(scope) {
    service.addRemote(pendingRemoteName, pendingRemoteUrl, scope)
    cancelAddRemote()
  }

  function cancelAddRemote() {
    addRemoteStep = 0
    pendingRemoteName = ""
    pendingRemoteUrl = ""
    searchField.text = ""
  }

  function toggleSelectedRemote() {
    if (service.busy || service.remotes.length === 0) return
    var repo = service.remotes[selectedIndex]
    service.setRemoteEnabled(repo.name, repo.scope, !repo.enabled)
  }

  readonly property string hintText: {
    if (pendingRemoteChoice) return "install " + pendingRemoteChoice.appId + " from: " + pendingRemoteChoice.remotes.map(function(r, i) { return (i + 1) + " " + r }).join("  ") + "   (esc cancels)"
    if (pendingConfirm) return "←/→ choose   ⏎ confirm   esc cancel"
    if (activeTab === 2 && addRemoteStep === 1) return "repo name, then enter (esc cancels)"
    if (activeTab === 2 && addRemoteStep === 2) return "repo url, then enter (esc cancels)"
    if (activeTab === 2 && addRemoteStep === 3) return "u user (default) / s system -- requires polkit auth   (enter = user, esc cancels)"
    if (activeTab === 2) return "↑/↓ move   a add   e/space enable-disable   del remove   tab switch"
    if (activeTab === 3) return "←/→ move   ⏎ run selected action   tab switch"
    return "↑/↓ move   ⏎ install/update/search   del remove   ^⏎ update all   tab switch   esc clear/close"
  }

  // Spinner for the busy/searching popup below -- purely decorative, but a
  // static "Installing..." reads as stuck; a moving glyph confirms it's alive.
  readonly property var spinnerFrames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  property int spinnerIndex: 0
  readonly property string spinnerFrame: spinnerFrames[spinnerIndex]
  Timer {
    interval: 80
    running: root.service.busy || root.searchPending
    repeat: true
    onTriggered: root.spinnerIndex = (root.spinnerIndex + 1) % root.spinnerFrames.length
  }

  // Keys can only attach to an Item, not the Window itself.
  Item {
    id: content
    anchors.fill: parent
    focus: true

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 1
      spacing: 4

      // Title bar + tabs
      RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 8
        Layout.rightMargin: 8
        Layout.topMargin: 14
        Layout.bottomMargin: 8
        spacing: 14

        Label {
          // The tab strip is the functional part of this row; the app name
          // is purely decorative, so it's the first thing to go when
          // there's not enough width for both.
          visible: root.width >= 700
          text: "flatpak-explorer"
          color: root.theme.accent
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.fontSize
          font.bold: true
        }

        Row {
          spacing: 4
          Repeater {
            model: root.tabNames
            delegate: Rectangle {
              // Bordered even when inactive -- Omarchy's own panels always
              // outline a button, filling it in only for the active choice
              // (see e.g. its DHCP/Cloudflare/Google/Custom row), rather
              // than leaving unselected options borderless.
              readonly property bool active: index === root.activeTab
              width: tabLabel.implicitWidth + 14
              height: tabLabel.implicitHeight + 8
              radius: 0
              color: active ? root.theme.accent : "transparent"
              border.width: 1
              border.color: active ? root.theme.accent : root.theme.border
              Label {
                id: tabLabel
                anchors.centerIn: parent
                text: modelData
                color: active ? root.theme.background : root.theme.muted
                font.family: root.theme.fontFamily
                font.pixelSize: root.theme.fontSize
                font.bold: active
              }
              MouseArea { anchors.fill: parent; onClicked: root.activeTab = index }
            }
          }
        }

        Item { Layout.fillWidth: true }
        Label {
          // Only post-action feedback ("Installed", an error, ...) -- while
          // an action is actually running the popup below already covers
          // it, so showing the same "Installing..." text up here too would
          // just be noise.
          visible: !root.service.busy
          text: root.service.statusMessage
          color: root.theme.muted
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.fontSize
          elide: Text.ElideRight
          // Explicit minimum -- a Label's implicit minimum in a Layout is
          // its own text width, which would push the (functional) tab
          // strip off the edge instead of eliding at narrow sizes.
          Layout.minimumWidth: 0
          Layout.maximumWidth: 300
        }
      }

      Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.border }

      // Search / filter / wizard line
      RowLayout {
        Layout.fillWidth: true
        Layout.margins: 10
        spacing: 6
        visible: root.activeTab !== 3 && !(root.activeTab === 2 && root.addRemoteStep === 0)

        Label {
          text: root.activeTab === 1 ? "search>" : (root.activeTab === 2 ? (root.addRemoteStep === 1 ? "name>" : (root.addRemoteStep === 2 ? "url>" : "scope>")) : "filter>")
          color: root.theme.accent
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.fontSize
          font.bold: true
        }

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: root.activeTab === 1 ? "type a query, press enter to search Flathub" : (root.activeTab === 2 && root.addRemoteStep === 3 ? "u user (default) / s system" : "filter installed apps")
          placeholderTextColor: root.theme.muted
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.fontSize
          color: root.theme.foreground
          selectionColor: root.theme.accent
          background: Item {}
          padding: 0

          Keys.onPressed: function(event) {
            if (root.service.busy || root.searchPending) { event.accepted = true; return }
            if (root.service.lastActionOutput !== "") {
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.service.lastActionOutput = ""
              event.accepted = true
              return
            }
            if (root.pendingRemoteChoice !== null) {
              if (event.key === Qt.Key_Escape) { root.pendingRemoteChoice = null; event.accepted = true; return }
              var choiceIndex = event.key - Qt.Key_1
              if (choiceIndex >= 0 && choiceIndex < 9) root.chooseInstallRemote(choiceIndex)
              event.accepted = true
              return
            }
            if (root.pendingConfirm !== null) {
              if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.confirmSelectsYes = !root.confirmSelectsYes
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirmOrCancel(root.confirmSelectsYes)
              } else if (event.key === Qt.Key_Escape) {
                root.confirmOrCancel(false)
              }
              event.accepted = true
              return
            }
            if (root.activeTab === 2 && root.addRemoteStep === 3) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_U) {
                root.chooseAddRemoteScope("user")
              } else if (event.key === Qt.Key_S) {
                root.chooseAddRemoteScope("system")
              } else if (event.key === Qt.Key_Escape) {
                root.cancelAddRemote()
              }
              event.accepted = true
              return
            }
            if (root.activeTab === 2 && root.addRemoteStep > 0) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitAddRemoteStep(); event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.cancelAddRemote(); event.accepted = true
              }
              return
            }
            if (event.modifiers & Qt.ControlModifier) {
              if (event.key === Qt.Key_N) { root.moveSelection(1); event.accepted = true; return }
              if (event.key === Qt.Key_P) { root.moveSelection(-1); event.accepted = true; return }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.armUpdateAll(); event.accepted = true; return }
            }
            if (event.key === Qt.Key_Tab) {
              root.activeTab = (root.activeTab + ((event.modifiers & Qt.ShiftModifier) ? (root.tabNames.length - 1) : 1)) % root.tabNames.length
              event.accepted = true; return
            }
            if (event.key === Qt.Key_Backtab) {
              root.activeTab = (root.activeTab + (root.tabNames.length - 1)) % root.tabNames.length
              event.accepted = true; return
            }
            // Maintenance's cards lay out left-to-right (a GridView, not a
            // vertical list), so Left/Right navigate it instead of Up/Down
            // -- Up/Down are left doing nothing there rather than also
            // working, so there's one clear way to move, not two.
            if (root.activeTab === 3) {
              if (event.key === Qt.Key_Right) { root.moveSelection(1); event.accepted = true; return }
              if (event.key === Qt.Key_Left) { root.moveSelection(-1); event.accepted = true; return }
            } else {
              if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true; return }
              if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true; return }
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.activeTab !== 2) root.activateSelection()
              event.accepted = true; return
            }
            if (event.key === Qt.Key_Escape) {
              if (text.length > 0) text = ""; else root.close()
              event.accepted = true; return
            }
            if (event.key === Qt.Key_Delete) {
              root.armRemoveSelected(); event.accepted = true; return
            }
            if (root.activeTab === 2) {
              if (event.key === Qt.Key_A) { root.beginAddRemote(); event.accepted = true; return }
              if (event.key === Qt.Key_E || event.key === Qt.Key_Space) { root.toggleSelectedRemote(); event.accepted = true; return }
            }
          }
        }
      }

      Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.border }

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        ListView {
          id: appList
          anchors.fill: parent
          clip: true
          spacing: 8
          visible: root.activeTab === 0 || root.activeTab === 1
          // root.appListModel (not root.activeList directly): activeList
          // holds repo/maintenance-action objects on the other two tabs,
          // which this delegate can't render (see the comment on
          // appListModel above) -- appListModel is empty there instead.
          model: root.appListModel
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: row
            width: appList.width
            height: 42
            readonly property bool selected: index === root.selectedIndex
            readonly property var pendingUpdate: root.service.isUpdatable(modelData.appId)
            readonly property bool installed: root.service.isInstalled(modelData.appId)
            readonly property bool armed: root.pendingConfirm && root.pendingConfirm.targetId === modelData.appId
            color: "transparent"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onClicked: root.selectedIndex = index
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              spacing: 8

              ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: 2

                Label {
                  // Just the short/pretty title (e.g. "Prism Launcher") --
                  // the reverse-DNS app ID (e.g. org.prismlauncher.PrismLauncher)
                  // used to be shown here too, dominating the row width, which
                  // read as a confusing file-path-like string rather than a
                  // package name. The ID is still used internally everywhere
                  // (installs/removes/updates key off modelData.appId) -- it's
                  // just not displayed anymore.
                  text: (selected ? "> " : "  ") + modelData.name
                  color: root.theme.foreground
                  font.family: root.theme.fontFamily
                  font.pixelSize: root.theme.fontSize
                  font.underline: selected
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                  // A Label's implicit Layout.minimumWidth is its own text
                  // width, which would push later columns (the action
                  // buttons) off the edge instead of eliding -- explicit 0
                  // lets this column actually give up space when it's tight.
                  Layout.minimumWidth: 0
                }
                Label {
                  // Flathub's own one-line blurb (flatpak list/search
                  // --columns=description) -- not every remote's metadata
                  // includes one, so this just collapses away when empty
                  // rather than showing a blank second line.
                  visible: !!modelData.description
                  text: "  " + (modelData.description || "")
                  color: root.theme.muted
                  font.family: root.theme.fontFamily
                  font.pixelSize: root.theme.fontSizeSmall
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                }
              }
              Label {
                // Least essential column -- first to go when narrow, so
                // name/id/actions keep their room instead of clipping.
                visible: row.width > 640
                // On the Search tab, a result available from more than one
                // remote is called out here -- that's exactly the case
                // where install-time remote choice (see armInstallSelected)
                // actually matters, so it's the only time this adds noise.
                text: {
                  var base = row.pendingUpdate ? (modelData.version + " → " + row.pendingUpdate.version) : modelData.version
                  if (root.activeTab === 1 && modelData.remotes && modelData.remotes.indexOf(",") !== -1) base += "  [" + modelData.remotes + "]"
                  return base
                }
                color: row.pendingUpdate ? root.theme.accent : root.theme.muted
                font.family: root.theme.fontFamily
                font.pixelSize: root.theme.fontSize
                font.underline: selected
                Layout.preferredWidth: implicitWidth
              }

              ActionButton {
                fontFamily: root.theme.fontFamily
                fontPixelSize: root.theme.fontSize
                visible: row.pendingUpdate !== null
                text: "update"
                textColor: root.theme.accent
                bold: true
                Layout.preferredWidth: implicitWidth
                onClicked: {
                  root.selectedIndex = index
                  root.service.updateApp(modelData.appId, root.service.scopeOf(modelData.appId))
                }
              }

              ActionButton {
                fontFamily: root.theme.fontFamily
                fontPixelSize: root.theme.fontSize
                text: !row.installed ? "install" : (row.armed ? "y, remove?" : "remove")
                textColor: !row.installed ? root.theme.accent : root.theme.danger
                bold: true
                Layout.preferredWidth: implicitWidth

                onClicked: {
                  root.selectedIndex = index
                  if (!row.installed) root.armInstallSelected(modelData)
                  else if (row.armed) root.confirmOrCancel(true)
                  else root.armRemoveSelected()
                }
              }
            }
          }

          Label {
            anchors.centerIn: parent
            visible: appList.count === 0
            text: root.activeTab === 1 ? "no results" : "no flatpaks installed"
            color: root.theme.muted
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
          }
        }

        ListView {
          id: repoList
          anchors.fill: parent
          clip: true
          spacing: 8
          visible: root.activeTab === 2
          model: service.remotes // unconditional -- see note on appList.model above
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: repoRow
            width: repoList.width
            height: 28
            readonly property bool selected: index === root.selectedIndex
            color: "transparent"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onClicked: root.selectedIndex = index
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              spacing: 8

              Label {
                text: (selected ? "> " : "  ") + modelData.name
                color: root.theme.foreground
                font.family: root.theme.fontFamily
                font.pixelSize: root.theme.fontSize
                font.underline: selected
                elide: Text.ElideRight
                Layout.preferredWidth: Math.min(parent.width * 0.2, 160)
                Layout.minimumWidth: 60
              }
              Label {
                text: modelData.url
                color: root.theme.muted
                font.family: root.theme.fontFamily
                font.pixelSize: root.theme.fontSize
                font.underline: selected
                elide: Text.ElideMiddle
                Layout.fillWidth: true
                Layout.minimumWidth: 0
              }
              Label {
                // Least essential column -- first to go when narrow.
                visible: repoRow.width > 640
                text: modelData.scope
                color: root.theme.muted
                font.family: root.theme.fontFamily
                font.pixelSize: root.theme.fontSize
                font.underline: selected
                Layout.preferredWidth: implicitWidth
              }
              ActionButton {
                fontFamily: root.theme.fontFamily
                fontPixelSize: root.theme.fontSize
                text: modelData.enabled ? "enabled" : "disabled"
                textColor: modelData.enabled ? root.theme.accent : root.theme.muted
                Layout.preferredWidth: implicitWidth
                onClicked: { root.selectedIndex = index; root.service.setRemoteEnabled(modelData.name, modelData.scope, !modelData.enabled) }
              }
              ActionButton {
                fontFamily: root.theme.fontFamily
                fontPixelSize: root.theme.fontSize
                readonly property bool armed: root.pendingConfirm && root.pendingConfirm.targetId === modelData.name
                text: armed ? "y, remove?" : "remove"
                textColor: root.theme.danger
                bold: true
                Layout.preferredWidth: implicitWidth
                onClicked: { root.selectedIndex = index; if (armed) root.confirmOrCancel(true); else root.armRemoveSelected() }
              }
            }
          }

          Label {
            anchors.centerIn: parent
            visible: repoList.count === 0
            text: "no repositories configured"
            color: root.theme.muted
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
          }
        }

        ColumnLayout {
          id: maintenanceView
          anchors.fill: parent
          visible: root.activeTab === 3
          spacing: 4

          Label {
            Layout.fillWidth: true
            Layout.margins: 10
            text: "disk usage -- system: " + root.service.systemDiskUsage + "   user: " + root.service.userDiskUsage
            color: root.theme.muted
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
          }

          Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.border }

          // A GridView (not a Flow) specifically because it's the one
          // QtQuick view type that still gives us positionViewAtIndex --
          // activeListView() below needs that for every tab uniformly, and
          // a plain Flow of Rectangles wouldn't have it.
          GridView {
            id: maintenanceList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: 240
            cellHeight: 210
            model: root.maintenanceActions // small static list -- unconditional either way
            currentIndex: root.selectedIndex

            delegate: Item {
              id: maintCell
              width: maintenanceList.cellWidth
              height: maintenanceList.cellHeight
              readonly property bool selected: index === root.selectedIndex
              readonly property bool armed: root.pendingConfirm && root.pendingConfirm.targetId === modelData.id

              Rectangle {
                anchors.fill: parent
                anchors.margins: 8
                radius: 0
                color: "transparent"
                border.width: 1
                border.color: maintCell.selected ? root.theme.accent : root.theme.border

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: root.selectedIndex = index
                  onClicked: root.selectedIndex = index
                }

                ColumnLayout {
                  anchors.fill: parent
                  anchors.margins: 12
                  spacing: 8

                  Label {
                    text: modelData.label
                    color: root.theme.foreground
                    font.family: root.theme.fontFamily
                    font.pixelSize: root.theme.fontSize
                    font.bold: true
                    font.underline: maintCell.selected
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                  }
                  Label {
                    text: modelData.desc
                    color: root.theme.muted
                    font.family: root.theme.fontFamily
                    font.pixelSize: root.theme.fontSize
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                  }
                  // A spacer, not Layout.fillHeight on the Label above --
                  // a wrapped Text item's implicitHeight is measured before
                  // its final width is resolved, so fillHeight on it fights
                  // the layout and the button ends up overlapping the last
                  // wrapped line. This pushes the button down cleanly.
                  Item { Layout.fillHeight: true }
                  ActionButton {
                    fontFamily: root.theme.fontFamily
                    fontPixelSize: root.theme.fontSize
                    text: maintCell.armed ? "y, confirm?" : modelData.actionLabel
                    textColor: modelData.danger ? root.theme.danger : root.theme.accent
                    bold: true
                    Layout.alignment: Qt.AlignRight
                    onClicked: {
                      root.selectedIndex = index
                      if (maintCell.armed) root.confirmOrCancel(true)
                      else root.runMaintenanceAction(modelData)
                    }
                  }
                }
              }
            }
          }
        }
      }

      Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.border }

      Label {
        Layout.fillWidth: true
        Layout.margins: 8
        text: root.hintText
        color: root.pendingConfirm ? root.theme.accent : root.theme.muted
        font.family: root.theme.fontFamily
        font.pixelSize: root.theme.fontSizeSmall
        elide: Text.ElideRight
      }
    }

    // Blocks the entire window while an install/remove/update/repo action
    // or an explicit search is running -- flatpak only ever does one
    // mutating action at a time (see FlatpakService's `busy` guard), and a
    // deliberate "search now" deserves the same clear feedback -- so
    // rather than scatter per-row disabled states, one popup says exactly
    // what's happening and eats all input until it's done.
    Item {
      id: busyOverlay
      anchors.fill: parent
      visible: root.service.busy || root.searchPending

      Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.65) }
      MouseArea { anchors.fill: parent } // swallow all clicks underneath

      Rectangle {
        id: busyBox
        anchors.centerIn: parent
        radius: 0
        color: root.theme.background
        border.color: root.theme.accent
        border.width: 1
        // A mutating action's own stdout streams live into this box (see
        // FlatpakService.liveLog) -- showing real progress/the exact
        // command running, not just a static "Installing..." message.
        // Search has no comparable log (it's a single JSON call, already
        // parsed into results), so it stays the old compact spinner row.
        readonly property bool showLiveLog: root.service.busy && root.service.liveLog !== ""
        // Capped to the window size (minus a margin) rather than sized
        // purely from content -- a long flatpak error message, or a long
        // log, must not push this popup past the window itself.
        width: showLiveLog ? Math.min(440, root.width - 40) : Math.min(progressRow.implicitWidth + 40, root.width - 40)
        height: showLiveLog ? Math.min(300, root.height - 40) : (progressRow.implicitHeight + 28)

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 14
          spacing: 10

          RowLayout {
            id: progressRow
            Layout.fillWidth: true
            spacing: 10
            Label {
              text: root.spinnerFrame
              color: root.theme.accent
              font.family: root.theme.fontFamily
              font.pixelSize: root.theme.fontSize
              font.bold: true
            }
            Label {
              text: root.service.busy ? root.service.statusMessage : ("Searching Flathub for \"" + root.lastSearchedQuery + "\"...")
              color: root.theme.foreground
              font.family: root.theme.fontFamily
              font.pixelSize: root.theme.fontSize
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          ScrollView {
            visible: busyBox.showLiveLog
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            TextArea {
              readOnly: true
              selectByMouse: true
              text: root.service.liveLog
              color: root.theme.muted
              font.family: root.theme.fontFamily
              font.pixelSize: root.theme.fontSizeSmall
              wrapMode: TextArea.Wrap
              background: Item {}
              // Auto-scroll to the newest line -- moving the cursor to the
              // end scrolls it into view within the enclosing ScrollView,
              // the same way a terminal follows its own output.
              onTextChanged: cursorPosition = text.length
            }
          }
        }
      }
    }

    // Destructive/bulk actions (remove app, remove repo, update all) arm
    // via pendingConfirm rather than running immediately -- see
    // confirmOrCancel/armRemoveSelected/armUpdateAll. This is the popup for
    // that arming state, styled to match busyOverlay above rather than the
    // old inline hint-bar text. Left/Right/Tab toggle which button is
    // selected (confirmSelectsYes, reset to false -- Cancel -- whenever
    // pendingConfirm changes) and Enter activates it; a stray 'y' no longer
    // confirms anything, which was the whole point -- it was too easy to
    // trigger by accident. The buttons are just a mouse-friendly equivalent
    // of the same state.
    Item {
      id: confirmOverlay
      anchors.fill: parent
      visible: root.pendingConfirm !== null

      Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.65) }
      MouseArea { anchors.fill: parent } // swallow all clicks underneath

      Rectangle {
        anchors.centerIn: parent
        radius: 0
        color: root.theme.background
        border.color: root.theme.accent
        border.width: 1
        width: Math.min(confirmColumn.implicitWidth + 40, root.width - 40)
        height: confirmColumn.implicitHeight + 28

        ColumnLayout {
          id: confirmColumn
          anchors.centerIn: parent
          width: Math.min(implicitWidth, parent.width - 20)
          spacing: 14

          Label {
            text: root.pendingConfirm ? (root.pendingConfirm.label.charAt(0).toUpperCase() + root.pendingConfirm.label.slice(1)) + "?" : ""
            color: root.theme.foreground
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
            font.bold: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }

          RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8

            // Deliberately no danger/red anywhere here -- it used to color
            // "yes, confirm" permanently, which competed with `focused`'s
            // border for the reader's attention and made it hard to tell
            // which button Enter would actually activate. Accent now means
            // exactly one thing: "this is the one that's selected."
            ActionButton {
              fontFamily: root.theme.fontFamily
              fontPixelSize: root.theme.fontSize
              text: "cancel"
              textColor: root.confirmSelectsYes ? root.theme.muted : root.theme.accent
              bold: !root.confirmSelectsYes
              focused: !root.confirmSelectsYes
              onClicked: root.confirmOrCancel(false)
            }
            ActionButton {
              fontFamily: root.theme.fontFamily
              fontPixelSize: root.theme.fontSize
              text: "yes, confirm"
              textColor: root.confirmSelectsYes ? root.theme.accent : root.theme.muted
              bold: root.confirmSelectsYes
              focused: root.confirmSelectsYes
              onClicked: root.confirmOrCancel(true)
            }
          }
        }
      }
    }

    // Maintenance actions (clean/repair) run two flatpak invocations with
    // no single row to show progress against, so instead of just a terse
    // status-bar message, their combined output gets its own popup once
    // both legs finish -- see FlatpakService.lastActionOutput.
    Item {
      id: maintenanceOutputOverlay
      anchors.fill: parent
      visible: root.service.lastActionOutput !== ""

      Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.75) }
      MouseArea { anchors.fill: parent } // swallow all clicks underneath

      Rectangle {
        anchors.centerIn: parent
        radius: 0
        color: root.theme.background
        border.color: root.theme.accent
        border.width: 1
        width: Math.min(480, root.width - 40)
        height: Math.min(360, root.height - 40)

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 14
          spacing: 10

          Label {
            text: root.service.lastActionLabel + " -- output"
            color: root.theme.accent
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
            font.bold: true
            Layout.fillWidth: true
            elide: Text.ElideRight
          }

          ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            TextArea {
              readOnly: true
              selectByMouse: true
              text: root.service.lastActionOutput
              color: root.theme.foreground
              font.family: root.theme.fontFamily
              font.pixelSize: root.theme.fontSizeSmall
              wrapMode: TextArea.Wrap
              background: Item {}
              // Auto-scroll to the end -- this popup opens with the whole
              // action already finished, so the most relevant part (the
              // final lines) would otherwise be scrolled out of view for
              // any output longer than the box.
              onTextChanged: cursorPosition = text.length
            }
          }

          RowLayout {
            Layout.alignment: Qt.AlignRight
            ActionButton {
              fontFamily: root.theme.fontFamily
              fontPixelSize: root.theme.fontSize
              text: "close"
              textColor: root.theme.accent
              bold: true
              onClicked: root.service.lastActionOutput = ""
            }
          }
        }
      }
    }

    // Every other Process here shells out to `flatpak` itself, so on a
    // machine without it installed they'd all fail one after another with
    // little indication why. checkFlatpakAvailable() runs first and gates
    // everything else -- this is the one overlay that takes priority over
    // busy/confirm (there's nothing meaningful to be busy or confirm doing
    // without flatpak), so it's declared last / drawn on top.
    Item {
      id: missingFlatpakOverlay
      anchors.fill: parent
      visible: root.service.availabilityChecked && !root.service.flatpakAvailable

      Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.8) }
      MouseArea { anchors.fill: parent } // swallow all clicks underneath

      Rectangle {
        anchors.centerIn: parent
        radius: 0
        color: root.theme.background
        border.color: root.theme.danger
        border.width: 1
        width: Math.min(missingColumn.implicitWidth + 40, root.width - 40)
        height: missingColumn.implicitHeight + 28

        ColumnLayout {
          id: missingColumn
          anchors.centerIn: parent
          width: Math.min(implicitWidth, parent.width - 40)
          spacing: 8

          Label {
            text: "flatpak was not found on PATH"
            color: root.theme.danger
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
            font.bold: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }
          Label {
            text: "flatpak-explorer needs the flatpak CLI installed to do anything. Install it with:"
            color: root.theme.foreground
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }
          Label { text: "  Arch / Manjaro:  sudo pacman -S flatpak"; color: root.theme.muted; font.family: root.theme.fontFamily; font.pixelSize: root.theme.fontSize }
          Label { text: "  Debian / Ubuntu: sudo apt install flatpak"; color: root.theme.muted; font.family: root.theme.fontFamily; font.pixelSize: root.theme.fontSize }
          Label { text: "  Fedora:          sudo dnf install flatpak"; color: root.theme.muted; font.family: root.theme.fontFamily; font.pixelSize: root.theme.fontSize }
          Label { text: "  openSUSE:        sudo zypper install flatpak"; color: root.theme.muted; font.family: root.theme.fontFamily; font.pixelSize: root.theme.fontSize }
          Label { text: "  other distros:   https://flatpak.org/setup/"; color: root.theme.muted; font.family: root.theme.fontFamily; font.pixelSize: root.theme.fontSize }

          RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: 6
            ActionButton {
              fontFamily: root.theme.fontFamily
              fontPixelSize: root.theme.fontSize
              text: "recheck"
              textColor: root.theme.accent
              bold: true
              onClicked: root.service.checkFlatpakAvailable()
            }
          }
        }
      }
    }
  }
}
