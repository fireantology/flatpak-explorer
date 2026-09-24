import QtQuick
import Quickshell.Io

QtObject {
  id: root

  property var installedApps: []
  property var searchResults: []
  property var remotes: []
  property var availableUpdates: []
  property string systemDiskUsage: "?"
  property string userDiskUsage: "?"
  property bool flatpakAvailable: true
  property bool availabilityChecked: false
  // Same "not checked yet" vs "checked, and it's unsupported" distinction
  // as flatpakAvailable/availabilityChecked above, for the minimum-version
  // gate: every listing command here relies on `-j`/`--json` output, which
  // needs flatpak >= minFlatpakVersion.
  readonly property string minFlatpakVersion: "1.17.0"
  property string flatpakVersion: ""
  property bool flatpakVersionChecked: false
  property bool flatpakVersionSupported: true
  property string liveLog: ""
  property string lastActionLabel: ""
  property string lastActionOutput: ""
  property bool busy: false
  property string busyTarget: ""
  property string busyVerb: "" // "install"/"uninstall"/"update"/"add"/"remove"/"enable"/"disable"/"updateAll"
  property string statusMessage: ""

  readonly property int listingCapChars: 8 * 1024 * 1024
  readonly property int stderrCapChars: 64 * 1024
  readonly property int liveLogCapChars: 256 * 1024
 
  readonly property int liveLogTrimToChars: 192 * 1024
  readonly property int excerptChars: 2000
  readonly property int errorLineChars: 400

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

  // Listing commands run through a `head -c` pipe, so the exit code belongs to
  // `head` and is always 0 -- stderr is the only signal left that one of them
  // failed (a network error from remote-ls, say), and it used to be discarded
  // entirely.
  function logStderr(name, stderrText) {
    if (String(stderrText || "").trim().length === 0) return
    logError(name + ": " + shortError(stderrText, ""))
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
    return lines.length > 0 ? excerpt(lines[lines.length - 1], errorLineChars) : fallback
  }

  // A parse failure on a large response must not put the whole response in the
  // log -- CLAUDE.md tells users to `tee` that log and paste it into a bug
  // report. The head is where a shape problem shows: a renamed field, an HTML
  // error page, a flatpak that ignored `-j`.
  function excerpt(text, limit) {
    var s = String(text || "")
    var max = limit || excerptChars
    return s.length <= max ? s : s.slice(0, max) + "... [truncated, " + s.length + " chars total]"
  }

  // Bounds a listing command's stdout at the source. StdioCollector has no
  // size limit and only hands its buffer over once the stream ends, so a
  // length check on receipt would cap what's retained, never what was held --
  // `head -c` makes the kernel enforce it instead, and SIGPIPEs flatpak the
  // moment the cap is hit, so there's no kill path to write.
  //
  // stderr goes through `tail -c` on its own pipe (fd 3 carries stdout past
  // it) for the same reason. tail, not head: the line worth keeping is the
  // *last* one (shortError), and tail drains its input instead of SIGPIPEing
  // flatpak, so a noisy stderr can't abort the listing either.
  //
  // `arg` is passed through argv as "$1", never interpolated into the script,
  // so a search query can't reach the shell as code.
  function cappedCommand(script, arg) {
    var cmd = ["sh", "-c", "{ " + script + " 2>&1 1>&3 3>&- | tail -c " + stderrCapChars + " 1>&2 3>&-; } 3>&1 | head -c " + listingCapChars]
    if (arg !== undefined) { cmd.push("sh"); cmd.push(arg) }
    return cmd
  }

  // The mutating counterpart: stdout untouched (SplitParser already reads it
  // a line at a time into the retention-capped liveLog), stderr through the
  // same `tail -c` as above. Unlike a listing, the exit code matters here, and
  // plain sh has no pipefail -- so the status is carried out of the pipeline
  // on fd 4 and re-raised. An empty status (the pipeline was killed before it
  // got that far) exits 1, never a false 0.
  //
  // `argv` is the plain ["flatpak", ...] command and reaches the shell as
  // "$@", never as script text. Log and display that, not what this returns.
  function stderrTailedCommand(argv) {
    return ["sh", "-c",
      "exec 3>&1; st=$( { { \"$@\" 2>&1 1>&3 3>&- 4>&-; echo $? 1>&4; } | tail -c " + stderrCapChars + " 1>&2 3>&-; } 4>&1 ); exit \"${st:-1}\"",
      "sh"].concat(argv)
  }

  // head -c truncates at exactly the cap, so a response that reaches it was
  // almost certainly cut -- and whatever's left is unparseable JSON anyway.
  function overflowed(text) { return String(text || "").length >= listingCapChars }

  function beginLiveLog(command) {
    _liveLogDropped = 0
    liveLog = "$ " + command.join(" ") + "\n"
  }

  function appendLiveLogCommand(command) {
    appendLiveLog("\n$ " + command.join(" "))
  }

  property int _liveLogDropped: 0

  // Tail retention with the command line pinned at the top. This is *progress*
  // output and both consumers auto-scroll to the end, so dropping from the
  // middle is the only truncation that doesn't fight the UI -- keeping the head
  // instead would park the viewport on content that no longer grows and look
  // frozen. The first line ("$ flatpak ...") survives unconditionally: showing
  // which command is running is the whole reason the popup exists.
  function appendLiveLog(line) {
    var next = liveLog + line + "\n"
    if (next.length <= liveLogCapChars) { liveLog = next; return }
    var headEnd = next.indexOf("\n") + 1
    var cut = next.length - liveLogTrimToChars
    var resume = next.indexOf("\n", cut) // resume on a line boundary, not mid-line
    if (resume === -1 || resume + 1 >= next.length) resume = cut - 1
    _liveLogDropped += (resume + 1) - headEnd
    // The previous marker always sits between headEnd and cut, so the same
    // slice that drops the stale body drops it too -- exactly one survives.
    liveLog = next.slice(0, headEnd)
      + "[... " + _liveLogDropped + " characters of earlier output truncated ...]\n"
      + next.slice(resume + 1)
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

  function checkVersion() {
    if (!versionCheckProc.running) versionCheckProc.running = true
  }

  // Dot-separated numeric version compare (e.g. "1.17.0" vs "1.9.2") --
  // returns -1/0/1. A missing segment on either side counts as 0, so
  // "1.17" compares equal to "1.17.0".
  function compareVersions(a, b) {
    var partsA = String(a || "0").split(".")
    var partsB = String(b || "0").split(".")
    var len = Math.max(partsA.length, partsB.length)
    for (var i = 0; i < len; i++) {
      var na = parseInt(partsA[i] || "0", 10) || 0
      var nb = parseInt(partsB[i] || "0", 10) || 0
      if (na !== nb) return na < nb ? -1 : 1
    }
    return 0
  }

  function refreshInstalled() {
    if (!listProc.running) listProc.running = true
  }

  function refreshRemotes() {
    if (!remoteListUserProc.running) remoteListUserProc.running = true
    if (!remoteListSystemProc.running) remoteListSystemProc.running = true
  }

  function checkUpdates() {
    // Clear both slots first, or a second refresh can merge a fresh system
    // result against the *previous* run's user result. Live path: updateApp/
    // updateAll re-enter here once an update finishes.
    _pendingUpdateRows = ({ system: null, user: null })
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
    // The query reaches the shell as "$1" via argv, never spliced into the
    // script text; `--` keeps a query starting with `-` from being read as a
    // flag.
    searchProc.command = cappedCommand("flatpak search --columns=name,description,application,version,branch,remotes -j -- \"$1\"", query)
    log("search: " + JSON.stringify(searchProc.command))
    searchProc.running = true
  }

  // Every argv below ends its options with `--`: flatpak reads options even
  // after positional arguments, and the app ids here come from a remote's
  // appstream data (search results) -- an "id" like `--no-related` must stay
  // an id, not change what the command does. Same for typed remote names.
  //
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
    var argv = ["flatpak", "install", "-y", "--" + remoteScope(remoteName), "--", remoteName, appId]
    installProc.command = stderrTailedCommand(argv)
    log("install: " + JSON.stringify(argv))
    beginLiveLog(argv)
    installProc.running = true
  }

  function uninstall(appId, scope) {
    if (busy) { log("uninstall(" + appId + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = appId
    busyVerb = "uninstall"
    statusMessage = "Removing " + appId + "..."
    uninstallProc.running = false
    var argv = ["flatpak", "uninstall", "-y", "--" + (scope || scopeOf(appId)), "--", appId]
    uninstallProc.command = stderrTailedCommand(argv)
    log("uninstall: " + JSON.stringify(argv))
    beginLiveLog(argv)
    uninstallProc.running = true
  }

  function updateApp(appId, scope) {
    if (busy) { log("updateApp(" + appId + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = appId
    busyVerb = "update"
    statusMessage = "Updating " + appId + "..."
    updateAppProc.running = false
    var argv = ["flatpak", "update", "-y", "--" + (scope || scopeOf(appId)), "--", appId]
    updateAppProc.command = stderrTailedCommand(argv)
    log("updateApp: " + JSON.stringify(argv))
    beginLiveLog(argv)
    updateAppProc.running = true
  }

  function updateAll() {
    if (busy) { log("updateAll: ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = ""
    busyVerb = "updateAll"
    statusMessage = "Updating system packages..."
    log("updateAll: " + JSON.stringify(updateAllSystemProc.argv) + " (then --user)")
    beginLiveLog(updateAllSystemProc.argv)
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
    log("cleanUnused: " + JSON.stringify(cleanUnusedSystemProc.argv) + " (then --user)")
    beginLiveLog(cleanUnusedSystemProc.argv)
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
    log("repair: " + JSON.stringify(repairSystemProc.argv) + " (then --user)")
    beginLiveLog(repairSystemProc.argv)
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
    var argv = ["flatpak", "remote-add", "--if-not-exists", "--" + (scope || "user"), "--", name, url]
    addRemoteProc.command = stderrTailedCommand(argv)
    log("addRemote: " + JSON.stringify(argv))
    beginLiveLog(argv)
    addRemoteProc.running = true
  }

  function removeRemote(name, scope) {
    if (busy) { log("removeRemote(" + name + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = name
    busyVerb = "removeRemote"
    statusMessage = "Removing " + name + "..."
    removeRemoteProc.running = false
    var argv = ["flatpak", "remote-delete", "--" + scope, "--", name]
    removeRemoteProc.command = stderrTailedCommand(argv)
    log("removeRemote: " + JSON.stringify(argv))
    beginLiveLog(argv)
    removeRemoteProc.running = true
  }

  function setRemoteEnabled(name, scope, enabled) {
    if (busy) { log("setRemoteEnabled(" + name + "): ignored, busy with " + busyTarget); return }
    busy = true
    busyTarget = name
    busyVerb = enabled ? "enable" : "disable"
    statusMessage = (enabled ? "Enabling " : "Disabling ") + name + "..."
    setRemoteEnabledProc.running = false
    var argv = ["flatpak", "remote-modify", "--" + scope, enabled ? "--enable" : "--disable", "--", name]
    setRemoteEnabledProc.command = stderrTailedCommand(argv)
    log("setRemoteEnabled: " + JSON.stringify(argv))
    beginLiveLog(argv)
    setRemoteEnabledProc.running = true
  }

  // Parses at the point of arrival, mirroring _parseRemotes -- so what gets
  // retained between the two update-check legs is four fields per updatable
  // ref, not the raw pretty-printed JSON the two legs returned.
  function _parseUpdates(text, scope) {
    var rows
    try { rows = JSON.parse(text || "[]") } catch (e) { logError("_parseUpdates(" + scope + "): failed to parse `flatpak remote-ls -j` output: " + e + " -- raw: " + excerpt(text)); rows = [] }
    return rows.map(function(r) {
      return { appId: r.application_id, name: r.name, version: r.version, scope: scope }
    })
  }

  function mergeUpdates(systemRows, userRows) {
    var merged = (systemRows || []).concat(userRows || [])
    // Only surface updates for refs the user actually sees as an app --
    // bare runtime bumps (Mesa, Platform, ...) update implicitly as
    // dependencies when their owning app updates.
    var result = merged.filter(function(u) { return root.isInstalled(u.appId) })
    root.log("mergeUpdates: " + merged.length + " raw update(s), " + result.length + " app-level")
    return result
  }

  // Held only until both legs have reported and the merge below has run --
  // but deliberately *not* cleared afterwards, since listProc re-runs the
  // merge against a fresh installed set (see the note in listProc).
  property var _pendingUpdateRows: ({ system: null, user: null })

  property Process flatpakCheckProc: Process {
    command: ["sh", "-c", "command -v flatpak >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.flatpakAvailable = exitCode === 0
      root.availabilityChecked = true
      if (exitCode === 0) {
        root.log("flatpakCheckProc: flatpak found on PATH")
        root.checkVersion()
        root.refreshInstalled()
        root.refreshRemotes()
        root.checkUpdates()
        root.refreshDiskUsage()
      } else {
        root.logError("flatpakCheckProc: flatpak not found on PATH")
      }
    }
  }

  property Process versionCheckProc: Process {
    command: ["flatpak", "--version"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var match = String(text || "").match(/\d+(\.\d+)*/)
        root.flatpakVersion = match ? match[0] : ""
        root.flatpakVersionSupported = match ? root.compareVersions(root.flatpakVersion, root.minFlatpakVersion) >= 0 : false
        root.flatpakVersionChecked = true
        if (root.flatpakVersionSupported) {
          root.log("versionCheckProc: flatpak " + root.flatpakVersion + " >= required " + root.minFlatpakVersion)
        } else {
          root.logError("versionCheckProc: flatpak " + (root.flatpakVersion || "(unparseable: " + root.excerpt(text, 200) + ")") + " is below required " + root.minFlatpakVersion)
        }
      }
    }
  }

  property Process listProc: Process {
    command: root.cappedCommand("flatpak list --app --columns=name,description,application,version,branch,installation -j")
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("listProc", listProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = []
        if (root.overflowed(text)) {
          root.logError("listProc: `flatpak list -j` output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "Installed list: too much output, aborted"
        } else {
          try { rows = JSON.parse(text || "[]") } catch (e) { root.logError("listProc: failed to parse `flatpak list -j` output: " + e + " -- raw: " + root.excerpt(text)); rows = [] }
        }
        root.installedApps = rows.map(function(r) {
          return { name: r.name, description: r.description, appId: r.application_id, version: r.version, branch: r.branch, installation: r.installation }
        })
        root.log("listProc: " + root.installedApps.length + " installed app(s)")
        // Re-filter with the fresh installed set now, rather than racing it
        // against the (usually slower, network-bound) update-check calls.
        if (root._pendingUpdateRows.system !== null || root._pendingUpdateRows.user !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateRows.system, root._pendingUpdateRows.user)
      }
    }
  }

  property Process searchProc: Process {
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("searchProc", searchProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = []
        if (root.overflowed(text)) {
          root.logError("searchProc: `flatpak search -j` output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "Search: too much output, aborted"
        } else {
          try { rows = JSON.parse(text || "[]") } catch (e) { root.logError("searchProc: failed to parse `flatpak search -j` output: " + e + " -- raw: " + root.excerpt(text)); rows = [] }
        }
        // Assign unconditionally, even when empty: ExplorerWindow clears its
        // searchPending flag only on searchResults changing, and while that
        // flag is set the busy overlay swallows every key -- so a path that
        // returns without assigning leaves the UI with no way out.
        root.searchResults = rows.map(function(r) {
          return { name: r.name, description: r.description, appId: r.application_id, version: r.version, branch: r.branch, remotes: r.remotes }
        })
        root.log("searchProc: " + root.searchResults.length + " result(s)")
      }
    }
  }

  function _parseRemotes(text, scope) {
    var rows
    try { rows = JSON.parse(text || "[]") } catch (e) { logError("_parseRemotes(" + scope + "): failed to parse `flatpak remote-list -j` output: " + e + " -- raw: " + excerpt(text)); rows = [] }
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
    command: root.cappedCommand("flatpak remote-list --system --show-disabled --columns=name,title,url,priority,options -j")
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("remoteListSystemProc", remoteListSystemProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.overflowed(text)) {
          root.logError("remoteListSystemProc: output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "System remotes: too much output, aborted"
        }
        root._remoteLists.system = root.overflowed(text) ? [] : root._parseRemotes(text, "system")
        root.remotes = root._remoteLists.system.concat(root._remoteLists.user)
        root.log("remoteListSystemProc: " + root._remoteLists.system.length + " system remote(s)")
      }
    }
  }

  property Process remoteListUserProc: Process {
    command: root.cappedCommand("flatpak remote-list --user --show-disabled --columns=name,title,url,priority,options -j")
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("remoteListUserProc", remoteListUserProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.overflowed(text)) {
          root.logError("remoteListUserProc: output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "User remotes: too much output, aborted"
        }
        root._remoteLists.user = root.overflowed(text) ? [] : root._parseRemotes(text, "user")
        root.remotes = root._remoteLists.system.concat(root._remoteLists.user)
        root.log("remoteListUserProc: " + root._remoteLists.user.length + " user remote(s)")
      }
    }
  }

  property Process updatesSystemProc: Process {
    // --system explicit -- see the same note on remoteListSystemProc above.
    command: root.cappedCommand("flatpak remote-ls --system --updates -j")
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("updatesSystemProc", updatesSystemProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.overflowed(text)) {
          root.logError("updatesSystemProc: output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "System updates: too much output, aborted"
        }
        root._pendingUpdateRows.system = root.overflowed(text) ? [] : root._parseUpdates(text, "system")
        if (root._pendingUpdateRows.user !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateRows.system, root._pendingUpdateRows.user)
      }
    }
  }

  property Process updatesUserProc: Process {
    command: root.cappedCommand("flatpak remote-ls --user --updates -j")
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.logStderr("updatesUserProc", updatesUserProc.stderr.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.overflowed(text)) {
          root.logError("updatesUserProc: output hit the " + root.listingCapChars + " char cap -- discarding")
          root.statusMessage = "User updates: too much output, aborted"
        }
        root._pendingUpdateRows.user = root.overflowed(text) ? [] : root._parseUpdates(text, "user")
        if (root._pendingUpdateRows.system !== null)
          root.availableUpdates = root.mergeUpdates(root._pendingUpdateRows.system, root._pendingUpdateRows.user)
      }
    }
  }

  property Process installProc: Process {
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    readonly property var argv: ["flatpak", "update", "-y", "--system"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("updateAll(system)", exitCode, updateAllSystemProc.stderr.text)
      root.statusMessage = "Updating user packages..."
      root.appendLiveLogCommand(updateAllUserProc.argv)
      updateAllUserProc.running = true
    }
  }

  property Process updateAllUserProc: Process {
    readonly property var argv: ["flatpak", "update", "-y", "--user"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    readonly property var argv: ["flatpak", "uninstall", "-y", "--unused", "--system"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("cleanUnused(system)", exitCode, cleanUnusedSystemProc.stderr.text)
      root.statusMessage = "Removing unused runtimes (user)..."
      root.appendLiveLogCommand(cleanUnusedUserProc.argv)
      cleanUnusedUserProc.running = true
    }
  }

  property Process cleanUnusedUserProc: Process {
    readonly property var argv: ["flatpak", "uninstall", "-y", "--unused", "--user"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    readonly property var argv: ["flatpak", "repair", "--system"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.logOutcome("repair(system)", exitCode, repairSystemProc.stderr.text)
      root.statusMessage = "Repairing user installation..."
      root.appendLiveLogCommand(repairUserProc.argv)
      repairUserProc.running = true
    }
  }

  property Process repairUserProc: Process {
    readonly property var argv: ["flatpak", "repair", "--user"]
    command: root.stderrTailedCommand(argv)
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
    stdout: SplitParser { onRead: function(line) { root.appendLiveLog(line) } }
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
