import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// VPN plugin popup. Imports .ovpn profiles via NetworkManager's own OpenVPN
// plugin (nmcli connection import type openvpn) and drives connect/disconnect
// through nmcli, same as the built-in Network panel drives Wi-Fi through
// Quickshell.Networking. Chrome (Panel/KeyboardPanel/Button/TextField/
// ToggleSwitch/CursorSurface/PanelSeparator/PanelSectionHeader/
// PanelActionButton) is all native Omarchy UI so this reads like a first-
// party widget rather than a bolted-on tool.
Panel {
  id: root
  moduleName: "srlinux.vpn"
  ipcTarget: "srlinux.vpn"
  manageIpc: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // ---- connection list ------------------------------------------------
  property var vpns: []
  readonly property bool anyActive: {
    for (var i = 0; i < vpns.length; i++) if (vpns[i].active) return true
    return false
  }

  // ---- per-row transient state -----------------------------------------
  property string busyUuid: ""
  property string busyKind: ""   // "connect" | "disconnect" | "remove"
  property string errorUuid: ""
  property string errorText: ""
  property string credentialsUuid: ""
  property string usernameText: ""
  property string passwordText: ""
  property bool credentialsIsRetry: false

  // ---- import flow --------------------------------------------------
  property bool importing: false
  property string importError: ""
  property string flashText: ""

  // ---- live per-connection stats (IP, gateway, rx/tx rates) ------------
  // Keyed by uuid so several VPNs open at once (or the row list reordering)
  // never mixes up counters. Refreshed on the same cadence as the built-in
  // Network panel's detailsPoll.
  property var vpnStats: ({})

  function close() {
    root.controller.hide()
    cancelCredentials()
  }

  function cancelCredentials() {
    credentialsUuid = ""
    usernameText = ""
    passwordText = ""
    credentialsIsRetry = false
  }

  function showFlash(msg) {
    flashText = msg
    flashTimer.restart()
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function refreshStats() {
    var uuids = []
    for (var i = 0; i < vpns.length; i++) if (vpns[i].active) uuids.push(vpns[i].uuid)
    if (uuids.length === 0) {
      if (Object.keys(vpnStats).length > 0) vpnStats = {}
      return
    }
    if (statsProc.running) return
    statsProc.command = ["bash", "-c", Model.statsScript, "vpn-stats"].concat(uuids)
    statsProc.running = true
  }

  function startImport() {
    if (pickFileProc.running || importing) return
    importError = ""
    pickFileProc.running = true
  }

  function importFile(path) {
    if (path === "") return
    importing = true
    importError = ""
    importProc.command = ["nmcli", "connection", "import", "type", "openvpn", "file", path]
    importProc.running = true
  }

  // Toggle a row: connected -> disconnect, otherwise -> probe then connect.
  function toggle(vpn) {
    if (busyUuid !== "" || !vpn) return
    if (vpn.active) { disconnectVpn(vpn); return }
    errorUuid = ""
    errorText = ""
    busyUuid = vpn.uuid
    busyKind = "probe"
    probeProc.targetUuid = vpn.uuid
    probeProc.command = ["bash", "-c", Model.probeScript, "vpn-probe", vpn.uuid]
    probeProc.running = true
  }

  function afterProbe(uuid, vpnData, userName) {
    busyUuid = ""
    busyKind = ""
    if (Model.needsCredentials(vpnData)) {
      credentialsUuid = uuid
      usernameText = userName
      passwordText = ""
      credentialsIsRetry = false
    } else {
      connectDirect(uuid)
    }
  }

  function connectDirect(uuid) {
    busyUuid = uuid
    busyKind = "connect"
    connectProc.targetUuid = uuid
    connectProc.command = ["nmcli", "connection", "up", uuid]
    connectProc.running = true
  }

  function submitCredentials() {
    if (credentialsUuid === "" || passwordText.length === 0 || busyUuid !== "") return
    var uuid = credentialsUuid
    var user = usernameText
    busyUuid = uuid
    busyKind = "connect"
    credConnectProc.targetUuid = uuid
    credConnectProc.secret = passwordText
    credConnectProc.command = ["bash", "-c", Model.credentialConnectScript, "vpn-connect", uuid, user]
    credConnectProc.running = true
  }

  function disconnectVpn(vpn) {
    if (busyUuid !== "" || !vpn) return
    busyUuid = vpn.uuid
    busyKind = "disconnect"
    disconnectProc.targetUuid = vpn.uuid
    disconnectProc.command = ["nmcli", "connection", "down", vpn.uuid]
    disconnectProc.running = true
  }

  function removeVpn(vpn) {
    if (busyUuid !== "" || !vpn) return
    busyUuid = vpn.uuid
    busyKind = "remove"
    removeProc.targetUuid = vpn.uuid
    removeProc.command = ["nmcli", "connection", "delete", vpn.uuid]
    removeProc.running = true
  }

  onOpenedChanged: if (opened) { refresh(); refreshStats() }

  Timer {
    id: refreshTimer
    interval: 4000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statsTimer
    interval: 1500
    repeat: true
    running: root.opened && root.anyActive
    triggeredOnStart: true
    onTriggered: root.refreshStats()
  }

  Timer {
    id: flashTimer
    interval: 2600
    repeat: false
    onTriggered: root.flashText = ""
  }

  IpcHandler {
    target: "srlinux.vpn"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ---- processes --------------------------------------------------------

  Process {
    id: listProc
    command: ["nmcli", "-t", "-e", "no", "-f", "NAME,UUID,TYPE,ACTIVE", "connection", "show"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.vpns = Model.parseVpnList(text)
    }
  }

  Process {
    id: statsProc
    command: []
    stdout: StdioCollector {
      id: statsStdout
      waitForEnd: true
      onStreamFinished: {
        var sample = Model.parseVpnStatsBlocks(text)
        root.vpnStats = Model.updateVpnStats(root.vpnStats, sample, Date.now() / 1000)
      }
    }
  }

  Process {
    id: pickFileProc
    command: ["omarchy-file-select", "--title", "Import VPN profile (.ovpn)", "--extensions", "ovpn"]
    stdout: StdioCollector {
      id: pickFileStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.importFile(Model.pickFilePath(pickFileStdout.text))
    }
  }

  Process {
    id: importProc
    command: []
    stdout: StdioCollector { id: importStdout; waitForEnd: true }
    stderr: StdioCollector { id: importStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.importing = false
      var result = Model.parseImportResult(importStdout.text, importStderr.text)
      if (result.ok) {
        root.showFlash("Imported \u201c" + result.name + "\u201d")
        root.refresh()
      } else {
        root.importError = result.error
      }
    }
  }

  Process {
    id: probeProc
    property string targetUuid: ""
    command: []
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parts = String(probeStdout.text || "").split("@@OMARCHY-VPN@@")
      var vpnData = Model.parseVpnData(parts[0] || "")
      var userName = (parts[1] || "").trim()
      root.afterProbe(probeProc.targetUuid, vpnData, userName)
    }
  }

  Process {
    id: connectProc
    property string targetUuid: ""
    command: []
    stdout: StdioCollector { id: connectStdout; waitForEnd: true }
    stderr: StdioCollector { id: connectStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busyUuid = ""
      root.busyKind = ""
      if (exitCode !== 0) {
        root.errorUuid = connectProc.targetUuid
        root.errorText = Model.connectFailureMessage(connectStderr.text, connectStdout.text)
      } else {
        root.errorUuid = ""
        root.errorText = ""
      }
      root.refresh()
      root.refreshStats()
    }
  }

  // Connects with credentials. The password travels over stdin into a
  // mode-600 temp file created *inside* the script, then straight to
  // nmcli's passwd-file option — it is never an argv value, so it never
  // appears in /proc/<pid>/cmdline. Mirrors the WiFi enterprise-connect
  // script in the built-in Network panel's Model.js.
  Process {
    id: credConnectProc
    property string targetUuid: ""
    property string secret: ""
    stdinEnabled: true
    command: []
    stdout: StdioCollector { id: credConnectStdout; waitForEnd: true }
    stderr: StdioCollector { id: credConnectStderr; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      root.busyUuid = ""
      root.busyKind = ""
      if (exitCode !== 0) {
        root.errorUuid = credConnectProc.targetUuid
        root.errorText = Model.connectFailureMessage(credConnectStderr.text, credConnectStdout.text)
        // Wrong credentials: reopen the prompt so the user can retry
        // without re-picking the row.
        if (Model.connectFailureNeedsCredentials(credConnectStderr.text)) {
          root.credentialsUuid = credConnectProc.targetUuid
          root.credentialsIsRetry = true
        }
      } else {
        root.errorUuid = ""
        root.errorText = ""
        root.cancelCredentials()
      }
      root.refresh()
      root.refreshStats()
    }
  }

  Process {
    id: disconnectProc
    property string targetUuid: ""
    command: []
    stdout: StdioCollector { id: disconnectStdout; waitForEnd: true }
    stderr: StdioCollector { id: disconnectStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busyUuid = ""
      root.busyKind = ""
      if (exitCode !== 0) {
        root.errorUuid = disconnectProc.targetUuid
        root.errorText = Model.elideStatus(disconnectStderr.text || disconnectStdout.text || "Failed to disconnect")
      } else {
        var next = {}
        for (var uuid in root.vpnStats) if (uuid !== disconnectProc.targetUuid) next[uuid] = root.vpnStats[uuid]
        root.vpnStats = next
      }
      root.refresh()
    }
  }

  Process {
    id: removeProc
    property string targetUuid: ""
    command: []
    stdout: StdioCollector { id: removeStdout; waitForEnd: true }
    stderr: StdioCollector { id: removeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busyUuid = ""
      root.busyKind = ""
      if (exitCode !== 0) {
        root.errorUuid = removeProc.targetUuid
        root.errorText = Model.elideStatus(removeStderr.text || removeStdout.text || "Failed to remove")
      } else {
        var next = {}
        for (var uuid in root.vpnStats) if (uuid !== removeProc.targetUuid) next[uuid] = root.vpnStats[uuid]
        root.vpnStats = next
      }
      root.refresh()
    }
  }

  // ---- bar icon -----------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.credentialsUuid !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---- hero: icon + title + import button ----
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, importBtn.visible ? importBtn.implicitHeight : 0)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰖂"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.anyActive ? 1.0 : 0.55
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            id: importBtn
            visible: !root.anyActive
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.importing ? "Importing\u2026" : "Import .ovpn"
            iconText: "+"
            bordered: true
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(5)
            enabled: !root.importing
            onClicked: root.startImport()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: importBtn.visible ? importBtn.left : parent.right
            anchors.rightMargin: importBtn.visible ? Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "VPN"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                var n = 0
                for (var i = 0; i < root.vpns.length; i++) if (root.vpns[i].active) n++
                if (n === 0) return "NOT CONNECTED"
                if (n === 1) return "1 CONNECTED"
                return n + " CONNECTED"
              }
              color: root.anyActive ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.importError !== ""
          width: parent.width
          text: root.importError
          color: bar ? bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.flashText !== ""
          width: parent.width
          text: root.flashText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.fg }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "VPN CONNECTIONS"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.vpns.length === 0
            width: parent.width
            text: "No VPN profiles yet. Import an .ovpn file to add one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            id: vpnColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.vpns
              VpnRow {
                required property var modelData
                width: vpnColumn.width
                vpn: modelData
              }
            }
          }
        }
      }
    }
  }

  // A single VPN profile row. Collapses to one line normally; expands
  // inline to a username/password prompt when the profile needs
  // credentials NetworkManager doesn't already have cached, or to a small
  // IP/throughput grid (mirroring the built-in Network panel's connection
  // details) once connected.
  component VpnRow: CursorSurface {
    id: row
    required property var vpn

    readonly property bool isBusy: root.busyUuid === (vpn ? vpn.uuid : "") && root.busyKind !== ""
    readonly property bool isFailed: root.errorUuid === (vpn ? vpn.uuid : "") && root.errorText !== ""
    readonly property bool isCredentialsOpen: root.credentialsUuid === (vpn ? vpn.uuid : "")
    readonly property var stats: vpn ? root.vpnStats[vpn.uuid] : undefined
    readonly property bool hasStats: vpn && vpn.active && !!stats
    readonly property string statusText: {
      if (!vpn) return ""
      if (isCredentialsOpen) return ""
      if (isBusy && root.busyKind === "probe") return "Checking\u2026"
      if (isBusy && root.busyKind === "connect") return "Connecting\u2026"
      if (isBusy && root.busyKind === "disconnect") return "Disconnecting\u2026"
      if (isBusy && root.busyKind === "remove") return "Removing\u2026"
      if (isFailed) return root.errorText
      if (vpn.active) return "Connected"
      return ""
    }
    readonly property color statusColor: isFailed ? (root.bar ? root.bar.urgent : Color.urgent) : (vpn && vpn.active ? root.fg : root.dim)

    foreground: root.fg
    current: vpn && vpn.active
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowBody.implicitHeight
      + (isCredentialsOpen ? credentialsPanel.implicitHeight + Style.spacing.md : 0)
      + (hasStats ? statsGrid.implicitHeight + Style.spacing.md : 0)

    Item {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(vpnIcon.implicitHeight, vpnInfo.implicitHeight, rowActions.implicitHeight) + Style.spacing.rowPaddingX

      Text {
        id: vpnIcon
        textFormat: Text.PlainText
        text: "󰖂"
        color: row.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      // Trailing actions: a Wi-Fi-style on/off switch to connect/disconnect,
      // plus a small remove (x) that only shows on hover so the row reads
      // clean at rest, same disclosure pattern as the Network panel's
      // per-network Forget button.
      Row {
        id: rowActions
        spacing: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Item {
          id: removeAction
          visible: !row.isBusy && (removeMouse.containsMouse || !vpn || !vpn.active)
          width: Style.space(20)
          implicitHeight: removeIcon.implicitHeight
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: removeIcon
            textFormat: Text.PlainText
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: "󰅙"
            color: removeMouse.containsMouse ? (root.bar ? root.bar.urgent : Color.urgent) : Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          MouseArea {
            id: removeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.removeVpn(row.vpn)
          }

          PanelToolTip {
            visible: removeMouse.containsMouse
            text: "Remove profile"
            fontFamily: root.fontFamily
          }
        }

        ToggleSwitch {
          id: connectSwitch
          anchors.verticalCenter: parent.verticalCenter
          checked: vpn ? vpn.active : false
          busy: row.isBusy
          foreground: root.fg
          accent: Color.accent
          onToggled: root.toggle(row.vpn)

          PanelToolTip {
            visible: connectSwitch.containsMouse
            text: vpn && vpn.active ? "Disconnect" : "Connect"
            fontFamily: root.fontFamily
          }
        }
      }

      Column {
        id: vpnInfo
        spacing: Style.space(1)
        anchors.left: vpnIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: rowActions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: row.vpn ? row.vpn.name : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: row.statusText
          visible: row.statusText !== ""
          height: visible ? implicitHeight : 0
          color: row.statusColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    // IP / throughput details, mirroring the built-in Network panel's
    // connection grid. Only mounted while this profile is active and a
    // stats sample has arrived, so a fresh connect doesn't show a
    // half-populated grid for one tick.
    GridLayout {
      id: statsGrid
      visible: row.hasStats
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowBody.bottom
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(4)
      columns: 4
      columnSpacing: Style.space(20)
      rowSpacing: Style.spacing.labelGap

      Text {
        textFormat: Text.PlainText
        text: "IP Address"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? (Model.formatVpnIp(row.stats.ip) || "--") : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        text: "Gateway"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? (row.stats.gw || "--") : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        text: "Receiving"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? Model.formatRate(row.stats.downloadRate) : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        text: "Sending"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? Model.formatRate(row.stats.uploadRate) : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        text: "Downloaded"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? Model.formatBytes(row.stats.rx) : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        text: "Uploaded"
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.hasStats ? Model.formatBytes(row.stats.tx) : "--"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Inline username/password prompt for profiles that require
    // credentials. Submitting connects; Esc cancels back to the row.
    Item {
      id: credentialsPanel
      visible: row.isCredentialsOpen
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowBody.bottom
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(4)
      implicitHeight: userField.implicitHeight + Style.space(4) + pwField.implicitHeight + Style.spacing.rowGap
      height: implicitHeight

      TextField {
        id: userField
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        placeholderText: "Username"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: root.fg
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        text: row.isCredentialsOpen ? root.usernameText : ""

        onAccepted: pwField.forceActiveFocus()
        onTextChanged: if (row.isCredentialsOpen && text !== root.usernameText) root.usernameText = text
        Keys.onEscapePressed: root.cancelCredentials()

        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
      }

      TextField {
        id: pwField
        anchors.left: parent.left
        anchors.right: connectBtn.left
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.spacing.rowGap / 2
        anchors.rightMargin: Style.space(6)
        password: true
        placeholderText: row.isCredentialsOpen && root.credentialsIsRetry ? "Wrong password \u2013 try again" : "Password"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: root.fg
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        text: row.isCredentialsOpen ? root.passwordText : ""

        onAccepted: root.submitCredentials()
        onTextChanged: if (row.isCredentialsOpen && text !== root.passwordText) root.passwordText = text
        Keys.onEscapePressed: root.cancelCredentials()
      }

      PanelActionButton {
        id: connectBtn
        anchors.right: parent.right
        anchors.verticalCenter: pwField.verticalCenter
        enabled: row.vpn && pwField.text.length > 0
        iconText: "󰄬"
        tooltipText: "Connect"
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.submitCredentials()
      }
    }
  }
}
