import QtQuick
import Quickshell.Io

// Host-agnostic Flatpak backend: shells out to the `flatpak` CLI via -j/
// --json output (stable field names, no ad-hoc column parsing needed), so
// it needs nothing Hyprland- or Omarchy-specific and works wherever
// `flatpak` is on PATH -- which is checked once at startup
// (checkFlatpakAvailable) before anything else runs, so a machine without
// flatpak installed gets one clear message instead of a pile of failed
// Process launches. New installs default to --user scope to avoid a
// polkit prompt; operations on an *existing* install (uninstall, update)
// use that install's own recorded scope instead of assuming --user, since
// a remote (and the apps from it) can just as easily be system-wide.
QtObject {
  id: root

  property var installedApps: []
  property var searchResults: []
  property var remotes: []
  property var availableUpdates: []
  property string systemDiskUsage: "?"
  property string userDiskUsage: "?"
  // Whether `flatpak` was found on PATH -- checked once at startup (see
  // checkFlatpakAvailable/Component.onCompleted below) before any other
  // `flatpak` invocation is attempted, since every other Process here would
  // otherwise fail to even start. `availabilityChecked` distinguishes "not
  // checked yet" from "checked, and it's missing" so the UI doesn't flash a
  // false "not found" message before the check has actually run.
  property bool flatpakAvailable: true
  property bool availabilityChecked: false
  // Every mutating action's stdout streams into this live, in order, as it
  // runs -- prefixed with the exact `flatpak ...` command line so the busy
  // popup can show real progress (and what's actually being run) instead of
  // just a static "Installing..." message. Reset at the start of each
  // top-level action (beginLiveLog) and appended to per extra leg for
  // multi-step actions like updateAll (appendLiveLogCommand).
  property string liveLog: ""
  // Maintenance actions (cleanUnused/repair) have no single row to show
  // progress against, unlike install/uninstall/update -- so once both legs
  // finish, a snapshot of liveLog is kept here for the UI to show as its
  // own popup that survives after the busy overlay closes. lastActionLabel
  // names which one, for that popup's title; "" means none is pending.
  property string lastActionLabel: ""
  property string lastActionOutput: ""
  property bool busy: false
  // appId or remote name the in-flight action targets ("" for updateAll,
  // which has no single target) -- lets the UI highlight that one specific
  // row as "in progress" instead of just a generic busy state.
  property string busyTarget: ""
  property string busyVerb: "" // "install"/"uninstall"/"update"/"add"/"remove"/"enable"/"disable"/"updateAll"
  property string statusMessage: ""

  signal actionFinished(bool success, string message, string verb)

  // Every command run and its outcome gets logged here so a bug report can
  // just be "here's my log" -- run `quickshell -p <path> 2>&1 | tee log.txt`
  // (or check the path printed as "Saving logs to ..." at startup) and the
  // exact flatpak invocation plus its exit code/stderr will be in it. Kept
  // to command dispatch/outcome and parse failures, not routine UI state,
  // so it stays readable.
  function log(message) { console.log("[flatpak-explorer] " + message) }
  function logError(message) { console.warn("[flatpak-explorer] " + message) }
  function logOutcome(name, exitCode, stderrText) {
    if (exitCode === 0) { log(name + ": ok"); return }
    logError(name + ": exit " + exitCode + " -- " + shortError(stderrText, "(no stderr)"))
  }

  function isInstalled(appId) {
    for (var i = 0; i < installedApps.length; i++) {
      if (installedApps[i].appId === appId) return true
    }
    return false
  }

  function scopeOf(appId) {
    for (var i = 0; i < installedApps.length; i++) {
      if (installedApps[i].appId === appId) return installedApps[i].installation
    }
    return "user"
  }

  // A remote can be configured user-wide, system-wide, or (rarely) both --
  // installing from it has to target a scope where it's actually
  // registered, or flatpak fails with "No remote refs found". Prefers user
  // scope (no polkit prompt) when the remote exists in both.
  function remoteScope(remoteName) {
    var sawSystem = false
    for (var i = 0; i < remotes.length; i++) {
      if (remotes[i].name !== remoteName) continue
      if (remotes[i].scope === "user") return "user"
      sawSystem = true
    }
    return sawSystem ? "system" : "user"
  }

  // flatpak's own error text (last non-empty stderr line, typically
  // "error: ...") is far more useful in the status bar than a generic
  // "X failed" -- surface it directly instead of sending users to a
  // terminal to find out why.
  function shortError(stderrText, fallback) {
    var lines = String(stderrText || "").split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l.length > 0 })
    return lines.length > 0 ? lines[lines.length - 1] : fallback
  }

  function beginLiveLog(command) {
    liveLog = "$ " + command.join(" ") + "\n"
  }

  function appendLiveLogCommand(command) {
    liveLog += "\n$ " + command.join(" ") + "\n"
  }

  function isUpdatable(appId) {
    for (var i = 0; i < availableUpdates.length; i++) {
      if (availableUpdates[i].appId === appId) return availableUpdates[i]
    }
    return null
  }

  // Runs through `sh -c "command -v flatpak"` rather than trying to exec
  // `flatpak` directly and inspecting the failure -- Quickshell's Process
  // has no well-defined "the binary doesn't exist" signal to key off of,
  // while `sh` itself is safe to assume present everywhere this runs.
  function checkFlatpakAvailable() {
    if (!flatpakCheckProc.running) flatpakCheckProc.running = true
  }

  function refreshInstalled() {
    if (!listProc.running) listProc.running = true
  }

  function refreshRemotes() {
    if (!remoteListUserProc.running) remoteListUserProc.running = true
    if (!remoteListSystemProc.running) remoteListSystemProc.running = true
  }

  function checkUpdates() {
    if (!updatesUserProc.running) updatesUserProc.running = true
    if (!updatesSystemProc.running) updatesSystemProc.running = true
  }

  // `flatpak list -j` has no size field, so disk usage is the one place
  // this service shells out to something other than `flatpak` itself --
  // `du` against the two well-known install roots. Informational only, so
  // a missing/inaccessible path (e.g. no system-wide installs on this
  // machine) just leaves that side showing "?" rather than failing.
  function refreshDiskUsage() {
    if (!diskUsageProc.running) diskUsageProc.running = true
  }

  function search(query) {
    if (!query || query.length === 0) {
      searchResults = []
      return
    }
    searchProc.running = false
    searchProc.command = ["flatpak", "search", "--columns=name,description,application,version,branch,remotes", "-j", query]
    log("search: " + JSON.stringify(searchProc.command))
    searchProc.running = true
  }

  // Every mutating action below is serialized behind `busy`: flatpak only
  // ever has one of these running at a time, both because a second
  // `flatpak` invocation would just contend with the first (same package
  // cache/lock) and so the UI can show a single, unambiguous "here's what's
  // happening right now" state instead of overlapping status messages.
  function install(appId, remote) {
    if (busy) { log("install(" + appId + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = appId
    busyVerb = "install"
    statusMessage = "Installing " + appId + "..."
    var remoteName = remote || "flathub"
    installProc.running = false
    installProc.command = ["flatpak", "install", "-y", "--" + remoteScope(remoteName), remoteName, appId]
    log("install: " + JSON.stringify(installProc.command))
    beginLiveLog(installProc.command)
    installProc.running = true
  }

  function uninstall(appId, scope) {
    if (busy) { log("uninstall(" + appId + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = appId
    busyVerb = "uninstall"
    statusMessage = "Removing " + appId + "..."
    uninstallProc.running = false
    uninstallProc.command = ["flatpak", "uninstall", "-y", "--" + (scope || scopeOf(appId)), appId]
    log("uninstall: " + JSON.stringify(uninstallProc.command))
    beginLiveLog(uninstallProc.command)
    uninstallProc.running = true
  }

  function updateApp(appId, scope) {
    if (busy) { log("updateApp(" + appId + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = appId
    busyVerb = "update"
    statusMessage = "Updating " + appId + "..."
    updateAppProc.running = false
    updateAppProc.command = ["flatpak", "update", "-y", "--" + (scope || scopeOf(appId)), appId]
    log("updateApp: " + JSON.stringify(updateAppProc.command))
    beginLiveLog(updateAppProc.command)
    updateAppProc.running = true
  }

  function updateAll() {
    if (busy) { log("updateAll: ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = ""
    busyVerb = "updateAll"
    statusMessage = "Updating system packages..."
    log("updateAll: " + JSON.stringify(updateAllSystemProc.command) + " (then --user)")
    beginLiveLog(updateAllSystemProc.command)
    updateAllSystemProc.running = false
    updateAllSystemProc.running = true
  }

  // Removes runtimes nothing installed still depends on (the literal
  // "orphan dependency" cleanup) -- same system-then-user two-step shape as
  // updateAll, since --unused has to be run per-installation.
  function cleanUnused() {
    if (busy) { log("cleanUnused: ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = ""
    busyVerb = "cleanUnused"
    statusMessage = "Removing unused runtimes (system)..."
    log("cleanUnused: " + JSON.stringify(cleanUnusedSystemProc.command) + " (then --user)")
    beginLiveLog(cleanUnusedSystemProc.command)
    cleanUnusedSystemProc.running = false
    cleanUnusedSystemProc.running = true
  }

  // Re-verifies/fixes a corrupted installation -- also per-installation,
  // so system-then-user like cleanUnused/updateAll above.
  function repair() {
    if (busy) { log("repair: ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = ""
    busyVerb = "repair"
    statusMessage = "Repairing system installation..."
    log("repair: " + JSON.stringify(repairSystemProc.command) + " (then --user)")
    beginLiveLog(repairSystemProc.command)
    repairSystemProc.running = false
    repairSystemProc.running = true
  }

  function addRemote(name, url, scope) {
    if (busy) { log("addRemote(" + name + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = name
    busyVerb = "add"
    statusMessage = "Adding " + name + "..."
    addRemoteProc.running = false
    addRemoteProc.command = ["flatpak", "remote-add", "--if-not-exists", "--" + (scope || "user"), name, url]
    log("addRemote: " + JSON.stringify(addRemoteProc.command))
    beginLiveLog(addRemoteProc.command)
    addRemoteProc.running = true
  }

  function removeRemote(name, scope) {
    if (busy) { log("removeRemote(" + name + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = name
    busyVerb = "removeRemote"
    statusMessage = "Removing " + name + "..."
    removeRemoteProc.running = false
    removeRemoteProc.command = ["flatpak", "remote-delete", "--" + scope, name]
    log("removeRemote: " + JSON.stringify(removeRemoteProc.command))
    beginLiveLog(removeRemoteProc.command)
    removeRemoteProc.running = true
  }

  function setRemoteEnabled(name, scope, enabled) {
    if (busy) { log("setRemoteEnabled(" + name + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = name
    busyVerb = enabled ? "enable" : "disable"
    statusMessage = (enabled ? "Enabling " : "Disabling ") + name + "..."
    setRemoteEnabledProc.running = false
    setRemoteEnabledProc.command = ["flatpak", "remote-modify", "--" + scope, enabled ? "--enable" : "--disable", name]
    log("setRemoteEnabled: " + JSON.stringify(setRemoteEnabledProc.command))
    beginLiveLog(setRemoteEnabledProc.command)
    setRemoteEnabledProc.running = true
  }

  function mergeUpdates(systemText, userText) {
    var merged = []
    function collect(text, scope) {
      var rows
      try { rows = JSON.parse(text || "[]") } catch (e) { root.logError("mergeUpdates(" + scope + "): failed to parse `flatpak remote-ls -j` output: " + e + " -- raw: " + text); rows = [] }
      for (var i = 0; i < rows.length; i++) {
        merged.push({ appId: rows[i].application_id, name: rows[i].name, version: rows[i].version, scope: scope })
      }
    }
    collect(systemText, "system")
    collect(userText, "user")
    // Only surface updates for refs the user actually sees as an app --
    // bare runtime bumps (Mesa, Platform, ...) update implicitly as
    // dependencies when their owning app updates.
    var result = merged.filter(function(u) { return root.isInstalled(u.appId) })
    root.log("mergeUpdates: " + merged.length + " raw update(s), " + result.length + " app-level")
    return result
  }

  property var _pendingUpdateTexts: ({ system: null, user: null })

  property Process flatpakCheckProc: Process {
    command: ["sh", "-c", "command -v flatpak >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.flatpakAvailable = exitCode === 0
      root.availabilityChecked = true
      if (exitCode === 0) {
        root.log("flatpakCheckProc: flatpak found on PATH")
        root.refreshInstalled()
        root.refreshRemotes()
        root.checkUpdates()
        root.refreshDiskUsage()
      } else {
        root.logError("flatpakCheckProc: flatpak not found on PATH")
      }
    }
  }

  property Process listProc: Process {
    command: ["flatpak", "list", "--app", "--columns=name,description,application,version,branch,installation", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows
        try { rows = JSON.parse(text || "[]") } catch (e) { root.logError("listProc: failed to parse `flatpak list -j` output: " + e + " -- raw: " + text); rows = [] }
        root.installedApps = rows.map(function(r) {
          return { name: r.name, description: r.description, appId: r.application_id, version: r.version, branch: r.branch, installation: r.installation }
        })
        root.log("listProc: " + root.installedApps.length + " installed app(s)")
        // Re-filter with the fresh installed set now, rather than racing it
        // against the (usually slower, network-bound) update-check calls.
        if (root._pendingUpdateTexts.system !== null || root._pendingUpdateTexts.user !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateTexts.system, root._pendingUpdateTexts.user)
      }
    }
  }

  property Process searchProc: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows
        try { rows = JSON.parse(text || "[]") } catch (e) { root.logError("searchProc: failed to parse `flatpak search -j` output: " + e + " -- raw: " + text); rows = [] }
        root.searchResults = rows.map(function(r) {
          return { name: r.name, description: r.description, appId: r.application_id, version: r.version, branch: r.branch, remotes: r.remotes }
        })
        root.log("searchProc: " + root.searchResults.length + " result(s)")
      }
    }
  }

  function _parseRemotes(text, scope) {
    var rows
    try { rows = JSON.parse(text || "[]") } catch (e) { logError("_parseRemotes(" + scope + "): failed to parse `flatpak remote-list -j` output: " + e + " -- raw: " + text); rows = [] }
    return rows.map(function(r) {
      var opts = String(r.options || "")
      return { name: r.name, title: r.title || r.name, url: r.url, priority: r.priority, scope: scope, enabled: opts.indexOf("disabled") === -1 }
    })
  }

  property var _remoteLists: ({ system: [], user: [] })

  property Process remoteListSystemProc: Process {
    // --system explicit, not relied-upon-default: `flatpak remote-list -j`
    // with no scope flag actually returns *both* scopes combined once a
    // user remote exists (verified live), which silently duplicated any
    // user-scope remote here, mislabeled as system-scope.
    command: ["flatpak", "remote-list", "--system", "--show-disabled", "--columns=name,title,url,priority,options", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._remoteLists.system = root._parseRemotes(text, "system")
        root.remotes = root._remoteLists.system.concat(root._remoteLists.user)
        root.log("remoteListSystemProc: " + root._remoteLists.system.length + " system remote(s)")
      }
    }
  }

  property Process remoteListUserProc: Process {
    command: ["flatpak", "remote-list", "--user", "--show-disabled", "--columns=name,title,url,priority,options", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._remoteLists.user = root._parseRemotes(text, "user")
        root.remotes = root._remoteLists.system.concat(root._remoteLists.user)
        root.log("remoteListUserProc: " + root._remoteLists.user.length + " user remote(s)")
      }
    }
  }

  property Process updatesSystemProc: Process {
    // --system explicit -- see the same note on remoteListSystemProc above.
    command: ["flatpak", "remote-ls", "--system", "--updates", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._pendingUpdateTexts.system = text
        if (root._pendingUpdateTexts.user !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateTexts.system, root._pendingUpdateTexts.user)
      }
    }
  }

  property Process updatesUserProc: Process {
    command: ["flatpak", "remote-ls", "--user", "--updates", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._pendingUpdateTexts.user = text
        if (root._pendingUpdateTexts.system !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateTexts.system, root._pendingUpdateTexts.user)
      }
    }
  }

  property Process installProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("install", exitCode, installProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Installed" : root.shortError(installProc.stderr.text, "Install failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) root.refreshInstalled()
    }
  }

  property Process uninstallProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("uninstall", exitCode, uninstallProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Removed" : root.shortError(uninstallProc.stderr.text, "Removal failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) root.refreshInstalled()
    }
  }

  property Process updateAppProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("updateApp", exitCode, updateAppProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Updated" : root.shortError(updateAppProc.stderr.text, "Update failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) { root.refreshInstalled(); root.checkUpdates() }
    }
  }

  property Process updateAllSystemProc: Process {
    command: ["flatpak", "update", "-y"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("updateAll(system)", exitCode, updateAllSystemProc.stderr.text)
      root.statusMessage = "Updating user packages..."
      root.appendLiveLogCommand(updateAllUserProc.command)
      updateAllUserProc.running = true
    }
  }

  property Process updateAllUserProc: Process {
    command: ["flatpak", "update", "-y", "--user"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("updateAll(user)", exitCode, updateAllUserProc.stderr.text)
      root.statusMessage = "Updated all"
      root.actionFinished(true, "Updated all", "updateAll")
      root.refreshInstalled()
      root.checkUpdates()
    }
  }

  property Process cleanUnusedSystemProc: Process {
    command: ["flatpak", "uninstall", "-y", "--unused", "--system"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("cleanUnused(system)", exitCode, cleanUnusedSystemProc.stderr.text)
      root.statusMessage = "Removing unused runtimes (user)..."
      root.appendLiveLogCommand(cleanUnusedUserProc.command)
      cleanUnusedUserProc.running = true
    }
  }

  property Process cleanUnusedUserProc: Process {
    command: ["flatpak", "uninstall", "-y", "--unused", "--user"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("cleanUnused(user)", exitCode, cleanUnusedUserProc.stderr.text)
      root.statusMessage = "Removed unused runtimes"
      root.lastActionLabel = "Remove unused runtimes"
      root.lastActionOutput = root.liveLog
      root.actionFinished(true, root.statusMessage, "cleanUnused")
      root.refreshInstalled()
      root.refreshDiskUsage()
    }
  }

  property Process repairSystemProc: Process {
    command: ["flatpak", "repair", "--system"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("repair(system)", exitCode, repairSystemProc.stderr.text)
      root.statusMessage = "Repairing user installation..."
      root.appendLiveLogCommand(repairUserProc.command)
      repairUserProc.running = true
    }
  }

  property Process repairUserProc: Process {
    command: ["flatpak", "repair", "--user"]
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("repair(user)", exitCode, repairUserProc.stderr.text)
      root.statusMessage = "Repaired installation"
      root.lastActionLabel = "Repair installation"
      root.lastActionOutput = root.liveLog
      root.actionFinished(true, root.statusMessage, "repair")
      root.refreshInstalled()
    }
  }

  property Process diskUsageProc: Process {
    command: ["sh", "-c", "du -sh /var/lib/flatpak 2>/dev/null; du -sh \"$HOME/.local/share/flatpak\" 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l.length > 0 })
        root.systemDiskUsage = lines.length > 0 ? lines[0].split("\t")[0] : "?"
        root.userDiskUsage = lines.length > 1 ? lines[1].split("\t")[0] : "?"
        root.log("diskUsageProc: system=" + root.systemDiskUsage + " user=" + root.userDiskUsage)
      }
    }
  }

  property Process addRemoteProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("addRemote", exitCode, addRemoteProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Added" : root.shortError(addRemoteProc.stderr.text, "Add failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) root.refreshRemotes()
    }
  }

  property Process removeRemoteProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("removeRemote", exitCode, removeRemoteProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Removed" : root.shortError(removeRemoteProc.stderr.text, "Remove failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) root.refreshRemotes()
    }
  }

  property Process setRemoteEnabledProc: Process {
    stdout: SplitParser { onRead: function(line) { root.liveLog += line + "\n" } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var verb = root.busyVerb
      root.busy = false
      root.busyTarget = ""
      root.busyVerb = ""
      root.logOutcome("setRemoteEnabled", exitCode, setRemoteEnabledProc.stderr.text)
      var ok = exitCode === 0
      root.statusMessage = ok ? "Updated" : root.shortError(setRemoteEnabledProc.stderr.text, "Failed")
      root.actionFinished(ok, root.statusMessage, verb)
      if (ok) root.refreshRemotes()
    }
  }

  Component.onCompleted: {
    log("service starting")
    checkFlatpakAvailable()
  }
}
