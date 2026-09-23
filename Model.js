// Pure helpers for the VPN plugin. No Quickshell/QML imports here so this
// stays testable the same way the first-party panels' Model.js files are
// (see panels/network/Model.js, panels/tailscale/Model.js).

// `nmcli -t -e no -f NAME,UUID,TYPE,ACTIVE connection show` output, one
// connection per line, colon-separated. We only want vpn-type rows.
function parseVpnList(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var rows = []

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var parts = splitNmcliLine(line, 4)
    if (parts.length < 4) continue
    var type = parts[2]
    if (type !== "vpn") continue
    rows.push({
      name: parts[0],
      uuid: parts[1],
      active: parts[3] === "yes"
    })
  }

  rows.sort(function(a, b) {
    if (a.active !== b.active) return a.active ? -1 : 1
    return a.name.localeCompare(b.name)
  })
  return rows
}

// nmcli -t fields can contain a literal ':' escaped as '\:'. A plain
// String.split(':') would break those apart, so walk the string respecting
// the backslash escape, same idea as nmcli's own terse-mode escaping.
function splitNmcliLine(line, maxFields) {
  var fields = []
  var current = ""
  var text = String(line || "")

  for (var i = 0; i < text.length; i++) {
    var ch = text[i]
    if (ch === "\\" && i + 1 < text.length) {
      current += text[i + 1]
      i++
      continue
    }
    if (ch === ":" && (maxFields <= 0 || fields.length < maxFields - 1)) {
      fields.push(current)
      current = ""
      continue
    }
    current += ch
  }
  fields.push(current)
  return fields
}

// `nmcli -t -e no -g vpn.data connection show <uuid>` returns the whole
// vpn.data blob as "key = value, key = value, ...". We only need a couple of
// keys out of it.
function parseVpnData(raw) {
  var text = String(raw || "")
  var result = {}
  var parts = text.split(/,\s*/)
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq === -1) continue
    var key = parts[i].substring(0, eq).trim()
    var value = parts[i].substring(eq + 1).trim()
    if (key !== "") result[key] = value
  }
  return result
}

// OpenVPN profiles NetworkManager imports from an .ovpn carry a
// connection-type of tls, password, password-tls or static-key. Only the
// password-bearing types need our username/password prompt; a pure
// certificate profile connects with no credentials at all.
function needsCredentials(vpnData) {
  var type = String((vpnData && vpnData["connection-type"]) || "")
  return type === "password" || type === "password-tls"
}

function parseImportResult(stdout, stderr) {
  var text = String(stdout || "") + "\n" + String(stderr || "")
  var match = text.match(/Connection '(.*)' \(([0-9a-fA-F-]{36})\) successfully added/)
  if (match) return { ok: true, name: match[1], uuid: match[2] }
  return { ok: false, error: elideStatus(stderr || stdout || "Import failed") }
}

function elideStatus(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 160 ? value.substring(0, 157) + "…" : value
}

// Classify a failed `nmcli connection up` so the panel knows whether to pop
// the inline credential prompt or just show the error as-is.
function connectFailureNeedsCredentials(stderr) {
  var text = String(stderr || "")
  return /no valid secrets/i.test(text)
    || /password is required/i.test(text)
    || /need to authenticate/i.test(text)
    || /secrets were required/i.test(text)
}

function connectFailureMessage(stderr, stdout) {
  var text = String(stderr || stdout || "")
  if (/no valid secrets/i.test(text) || /password is required/i.test(text)) return "Wrong username or password"
  if (/could not resolve|name or service not known|network is unreachable/i.test(text)) return "Server unreachable"
  if (/timeout/i.test(text)) return "Connection timed out"
  return elideStatus(text || "Failed to connect")
}

// Reads vpn.data and vpn.user-name in one shot so the panel can decide
// whether a profile needs a username/password prompt before connecting.
// Emitted as "<vpn.data>@@OMARCHY-VPN@@<vpn.user-name>\n" so the QML side
// can split it back apart; nmcli's own field separator (':') can appear
// inside vpn.data values (escaped), so we don't reuse it here.
//
// Every external tool is referenced by its absolute path rather than a bare
// name. The QML side additionally runs this with clearEnvironment: true and
// a fixed PATH, so nothing here is resolved against the shell process's
// ambient (and therefore spoofable) $PATH.
var probeScript =
  "NMCLI=/usr/bin/nmcli;" +
  " d=$(\"$NMCLI\" -t -e no -g vpn.data connection show \"$1\");" +
  " u=$(\"$NMCLI\" -t -e no -g vpn.user-name connection show \"$1\");" +
  " printf '%s@@OMARCHY-VPN@@%s\\n' \"$d\" \"$u\""

// Connects a VPN profile that needs a username/password. The password
// arrives on stdin (never argv, never a file NetworkManager persists to
// disk) and is handed to nmcli via a mode-600 temp file that this script
// creates and removes itself, exactly the shape nmcli's own `passwd-file`
// option expects. Username is set on the profile first so NetworkManager
// prompts only for the password.
//
// This is the security-sensitive path: every tool is invoked by absolute
// path (never resolved through $PATH), and the script fails closed with a
// non-zero exit before the password is ever read if any of them is missing
// or not executable — a substituted or PATH-hijacked binary can't silently
// capture the secret. The QML side pairs this with clearEnvironment: true
// and a fixed, minimal PATH so there is no ambient-environment resolution
// left to spoof in the first place.
var credentialConnectScript =
  "set -e;" +
  " NMCLI=/usr/bin/nmcli; MKTEMP=/usr/bin/mktemp; CHMOD=/usr/bin/chmod; RM=/usr/bin/rm;" +
  " for bin in \"$NMCLI\" \"$MKTEMP\" \"$CHMOD\" \"$RM\"; do" +
  "   if [ ! -x \"$bin\" ]; then printf 'Required tool missing: %s\\n' \"$bin\" >&2; exit 127; fi;" +
  " done;" +
  " IFS= read -r pw;" +
  " \"$NMCLI\" connection modify \"$1\" vpn.user-name \"$2\" >/dev/null;" +
  " pf=$(\"$MKTEMP\"); \"$CHMOD\" 600 \"$pf\"; trap '\"$RM\" -f \"$pf\"' EXIT;" +
  " printf 'vpn.secrets.password:%s\\n' \"$pw\" > \"$pf\";" +
  " \"$NMCLI\" connection up \"$1\" passwd-file \"$pf\""

function pickFilePath(stdout) {
  var lines = String(stdout || "\n").split(/\r?\n/).filter(function(l) { return l !== "" })
  return lines.length > 0 ? lines[0] : ""
}

// Reads device/IP/gateway plus raw rx/tx byte counters for every active VPN
// uuid passed as an argv, one block per uuid so a single process covers all
// of them each poll tick. "dev" comes from GENERAL.DEVICES (the tun/tap
// NetworkManager attached this profile to); rx/tx come straight from
// /sys/class/net, same source the built-in Network panel's
// omarchy-network-status --verbose uses for Wi-Fi/Ethernet.
//
// nmcli is invoked by absolute path only (no bare "nmcli" resolved through
// $PATH); "head -1" and "cat <file>" are replaced with a bash parameter
// expansion and the `read` builtin respectively, so the whole script needs
// no external tool beyond nmcli itself. Paired with clearEnvironment: true
// and a fixed PATH on the QML side.
var statsScript =
  "NMCLI=/usr/bin/nmcli;" +
  " for uuid in \"$@\"; do" +
  " dev=$(\"$NMCLI\" -t -e no -g GENERAL.DEVICES connection show \"$uuid\" 2>/dev/null); dev=${dev%%$'\\n'*};" +
  " ip=$(\"$NMCLI\" -t -e no -g IP4.ADDRESS connection show \"$uuid\" 2>/dev/null); ip=${ip%%$'\\n'*};" +
  " gw=$(\"$NMCLI\" -t -e no -g IP4.GATEWAY connection show \"$uuid\" 2>/dev/null); gw=${gw%%$'\\n'*};" +
  " rx=0; tx=0;" +
  " if [ -n \"$dev\" ] && [ -r \"/sys/class/net/$dev/statistics/rx_bytes\" ]; then IFS= read -r rx < \"/sys/class/net/$dev/statistics/rx_bytes\"; fi;" +
  " if [ -n \"$dev\" ] && [ -r \"/sys/class/net/$dev/statistics/tx_bytes\" ]; then IFS= read -r tx < \"/sys/class/net/$dev/statistics/tx_bytes\"; fi;" +
  " printf '@@VPN=%s@@\\ndev=%s\\nip=%s\\ngw=%s\\nrx=%s\\ntx=%s\\n' \"$uuid\" \"$dev\" \"$ip\" \"$gw\" \"$rx\" \"$tx\";" +
  " done"

// Splits statsScript's stdout back into one key/value object per uuid.
function parseVpnStatsBlocks(raw) {
  var text = String(raw || "")
  var blocks = text.split(/@@VPN=/).slice(1)
  var result = {}

  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i]
    var end = block.indexOf("@@")
    if (end === -1) continue
    var uuid = block.substring(0, end)
    var body = block.substring(end + 2)
    var entry = { dev: "", ip: "", gw: "", rx: 0, tx: 0 }
    var lines = body.split(/\r?\n/)
    for (var j = 0; j < lines.length; j++) {
      var line = lines[j]
      var eq = line.indexOf("=")
      if (eq === -1) continue
      var key = line.substring(0, eq)
      var value = line.substring(eq + 1)
      if (key === "dev") entry.dev = value
      else if (key === "ip") entry.ip = value
      else if (key === "gw") entry.gw = value
      else if (key === "rx") entry.rx = parseFloat(value) || 0
      else if (key === "tx") entry.tx = parseFloat(value) || 0
    }
    result[uuid] = entry
  }
  return result
}

// Folds a fresh statsScript sample into the previous per-uuid rate state,
// producing instantaneous download/upload rates from the rx/tx byte deltas.
// Mirrors the built-in Network panel's Model.js `throughputState`, but keyed
// by uuid instead of a single active iface so several VPNs can be open at
// once without clobbering each other's counters.
function updateVpnStats(previous, sample, now) {
  var prevMap = previous || {}
  var next = {}

  for (var uuid in sample) {
    var entry = sample[uuid]
    var prev = prevMap[uuid] || {}
    var prevTime = Number(prev.sampleTime || 0)
    var downloadRate = 0
    var uploadRate = 0

    if (prev.dev === entry.dev && prevTime > 0) {
      var dt = now - prevTime
      if (dt > 0) {
        downloadRate = Math.max(0, (entry.rx - Number(prev.rx || 0)) / dt)
        uploadRate = Math.max(0, (entry.tx - Number(prev.tx || 0)) / dt)
      } else {
        downloadRate = Number(prev.downloadRate || 0)
        uploadRate = Number(prev.uploadRate || 0)
      }
    }

    next[uuid] = {
      dev: entry.dev,
      ip: entry.ip,
      gw: entry.gw,
      rx: entry.rx,
      tx: entry.tx,
      sampleTime: now,
      downloadRate: downloadRate,
      uploadRate: uploadRate
    }
  }

  return next
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// vpn.data's ip4 field wraps the address as "10.8.0.2/24 ...", and the
// live nmcli IP4.ADDRESS probe returns "192.168.168.93/24" too. The
// built-in Network panel shows a bare address with no CIDR suffix, so
// strip both the trailing fields and the /prefix to match that look.
function formatVpnIp(raw) {
  var value = String(raw || "").trim()
  if (value === "") return ""
  return value.split(/\s+/)[0].split("/")[0]
}

if (typeof module !== "undefined") {
  module.exports = {
    parseVpnList: parseVpnList,
    splitNmcliLine: splitNmcliLine,
    parseVpnData: parseVpnData,
    needsCredentials: needsCredentials,
    parseImportResult: parseImportResult,
    elideStatus: elideStatus,
    connectFailureNeedsCredentials: connectFailureNeedsCredentials,
    connectFailureMessage: connectFailureMessage,
    pickFilePath: pickFilePath,
    probeScript: probeScript,
    credentialConnectScript: credentialConnectScript,
    statsScript: statsScript,
    parseVpnStatsBlocks: parseVpnStatsBlocks,
    updateVpnStats: updateVpnStats,
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatVpnIp: formatVpnIp
  }
}
