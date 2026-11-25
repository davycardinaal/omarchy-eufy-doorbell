import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons as Commons

// One per shell. Runs the eufy backend, holds the doorbell state the bar
// widget and the ring overlay read, and puts the bell on screen the moment a
// press arrives. keepLoaded in the manifest keeps it (and the backend's eufy
// session) alive while other plugins hot-reload.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "davycardinaal.eufy-doorbell"
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-eufy-doorbell/"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // starting · no-node · needs-install · installing · logged-out · logging-in
  // · captcha · 2fa · connecting · ready · error
  property string status: "starting"
  property string message: ""
  property string email: ""
  property string captchaImage: ""
  property bool captchaRetry: false
  // { sn, name, lastRing, battery }; battery is 0–100, or -1 when eufy has not said.
  property var doorbells: []

  // The ring on screen.
  property bool ringing: false
  property bool ringTest: false
  property string ringSn: ""
  property string ringName: ""
  property double ringAt: 0
  property string snapshotPath: ""
  property string liveUrl: ""

  readonly property bool listening: status === "ready"
  // States only the user can get out of; "error" retries by itself.
  readonly property bool needsUser: ["no-node", "needs-install", "logged-out", "captcha", "2fa"].indexOf(status) !== -1
  readonly property bool needsAttention: needsUser || status === "error"

  // ------------------------------------------------------------ actions

  function login(email, password, country) {
    send({ cmd: "login", email: String(email || ""), password: String(password || ""), country: String(country || "") })
  }
  function solveCaptcha(answer) { send({ cmd: "captcha", answer: String(answer || "") }) }
  function submitCode(code) { send({ cmd: "code", code: String(code || "") }) }
  function logout() { send({ cmd: "logout" }) }

  function install() {
    if (installer.running) return
    root.status = "installing"
    root.message = ""
    installer.running = true
  }

  function reconnect() {
    restartTimer.stop()
    root.backoff = 0
    if (backend.running) {
      root.restartNow = true
      backend.running = false
    } else {
      startBackend()
    }
  }

  function startBackend() {
    root.status = "starting"
    root.message = ""
    backend.running = true
  }

  // Ring on demand, with the camera when there is one: proves the whole path.
  function testRing(sn) {
    var doorbell = doorbellFor(sn) || (root.doorbells.length > 0 ? root.doorbells[0] : null)
    ring(doorbell ? doorbell.sn : "", doorbell ? doorbell.name : "", true)
    if (doorbell && root.listening) send({ cmd: "live", deviceSn: doorbell.sn })
  }

  // The overlay calls this when it closes. `seen` is false when nobody was
  // at the screen to dismiss it; that ring stays as a notification.
  function endRing(seen) {
    if (!root.ringing) return
    send({ cmd: "stop-live" })
    if (!seen && !root.ringTest) notifyMissed()
    root.ringing = false
    root.liveUrl = ""
  }

  // ------------------------------------------------------------ ring

  function ring(sn, name, test) {
    root.ringSn = sn
    root.ringName = name || strings.t("doorbell.defaultName")
    root.ringAt = Date.now()
    root.ringTest = test === true
    root.snapshotPath = ""
    root.liveUrl = ""
    root.ringing = true
    if (root.shell) root.shell.summon(root.pluginId, "{}")
    chime.play()
    if (!root.ringTest) updateDoorbell(sn, { lastRing: root.ringAt })
  }

  // A new list rather than an edit in place, so the panel's bindings update.
  function updateDoorbell(sn, changes) {
    var next = []
    for (var i = 0; i < root.doorbells.length; i++) {
      var doorbell = root.doorbells[i]
      next.push(doorbell.sn === sn ? Object.assign({}, doorbell, changes) : doorbell)
    }
    root.doorbells = next
  }

  function doorbellFor(sn) {
    for (var i = 0; i < root.doorbells.length; i++)
      if (root.doorbells[i].sn === sn) return root.doorbells[i]
    return null
  }

  function notifyMissed() {
    var time = new Date(root.ringAt).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")
    var args = [root.omarchyPath + "/bin/omarchy-notification-send", "--app-name", "Eufy Doorbell", "-g", "󰂞", "-u", "critical"]
    if (root.snapshotPath !== "") args.push("--image", root.snapshotPath)
    // The doorbell's name comes from the eufy cloud; notification bodies may render markup.
    var name = root.ringName.replace(/[<>&]/g, "")
    args.push(strings.t("notify.missedTitle"), strings.t("notify.missedBody").arg(name).arg(time))
    Quickshell.execDetached(args)
  }

  function notifyStopped() {
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send", "--app-name", "Eufy Doorbell",
      "-g", "󰂛", "-u", "critical", strings.t("notify.stoppedTitle"), strings.t("notify.stoppedBody")])
  }

  // ------------------------------------------------------------ backend

  function send(command) {
    if (backend.running) backend.write(JSON.stringify(command) + "\n")
  }

  function cleanText(value, max) {
    return String(value === undefined || value === null ? "" : value).replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, max)
  }

  function validSn(sn) {
    return typeof sn === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(sn)
  }

  function batteryLevel(value) {
    return typeof value === "number" && value >= 0 && value <= 100 ? Math.round(value) : -1
  }

  function handleLine(line) {
    var event
    try { event = JSON.parse(line) } catch (e) { return console.warn("eufy-doorbell: backend said something that is not JSON") }
    if (!event || typeof event.type !== "string") return

    if (event.type === "ring" && validSn(event.deviceSn)) {
      // A ring wins over everything else on this line; nothing before it.
      root.ring(event.deviceSn, root.cleanText(event.name, 64), false)
    } else if (event.type === "status") {
      applyStatus(event)
    } else if (event.type === "devices" && Array.isArray(event.doorbells)) {
      var list = []
      for (var i = 0; i < event.doorbells.length && list.length < 32; i++) {
        var item = event.doorbells[i]
        if (item && validSn(item.sn)) {
          list.push({ sn: item.sn, name: root.cleanText(item.name || item.sn, 64), lastRing: 0, battery: root.batteryLevel(item.battery) })
        }
      }
      root.doorbells = list
    } else if (event.type === "battery" && validSn(event.deviceSn)) {
      root.updateDoorbell(event.deviceSn, { battery: root.batteryLevel(event.level) })
    } else if (event.type === "snapshot" && event.deviceSn === root.ringSn && root.ringing) {
      var path = String(event.path || "")
      if (path.indexOf(root.runtimeDir) === 0 && /^[A-Za-z0-9_\/.-]+\.jpg$/.test(path) && path.indexOf("..") === -1) root.snapshotPath = path
    } else if (event.type === "live" && event.deviceSn === root.ringSn && root.ringing) {
      var url = String(event.url || "")
      if (/^http:\/\/127\.0\.0\.1:\d{1,5}\/live\/[0-9a-f]{32}\.ts$/.test(url)) root.liveUrl = url
    } else if (event.type === "live-ended" && event.deviceSn === root.ringSn) {
      root.liveUrl = ""
    }
  }

  function applyStatus(event) {
    var wasListening = root.listening
    root.status = root.cleanText(event.state, 24)
    root.message = root.cleanText(event.message, 300)
    root.email = root.cleanText(event.email, 254)
    root.captchaRetry = event.retry === true
    var image = String(event.image || "")
    root.captchaImage = root.status === "captcha" && image.indexOf("data:image/png;base64,") === 0 && image.length < 400000 ? image : ""
    if (root.listening) root.backoff = 0
    if (wasListening && root.needsUser) notifyStopped()
  }

  // Seconds before the next start after the backend fails. It exits non-zero
  // for anything that may pass by itself (no network yet, eufy hiccups) and
  // zero when it has said what the user must do (install, log in).
  readonly property var backoffSteps: [3, 10, 30, 60, 120, 300]
  property int backoff: 0
  property bool restartNow: false

  Process {
    id: backend
    // A missing node gets a readable status instead of a silent failed start.
    command: ["bash", "-c", "command -v node >/dev/null || { echo '{\"type\":\"status\",\"state\":\"no-node\"}'; exit 0; }; exec node \"$0\"",
      root.pluginDir + "/backend/doorbell.mjs"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { console.info("eufy-doorbell:", line) } }
    onExited: function(exitCode) {
      if (root.restartNow) {
        root.restartNow = false
        root.startBackend()
      } else if (exitCode !== 0) {
        restartTimer.interval = root.backoffSteps[Math.min(root.backoff, root.backoffSteps.length - 1)] * 1000
        root.backoff += 1
        restartTimer.restart()
      }
    }
  }

  Timer {
    id: restartTimer
    onTriggered: root.startBackend()
  }

  Process {
    id: installer
    command: [root.pluginDir + "/scripts/install-backend.sh"]
    stdout: SplitParser { onRead: function(line) { console.info("eufy-doorbell install:", line) } }
    stderr: SplitParser { onRead: function(line) { root.message = root.cleanText(line, 300); console.info("eufy-doorbell install:", line) } }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.status = "needs-install"
        if (root.message === "") root.message = strings.t("install.failed")
        return
      }
      root.startBackend()
    }
  }

  SoundEffect {
    id: chime
    source: Qt.resolvedUrl("assets/ding-dong.wav")
    volume: 0.9
  }

  Component.onCompleted: startBackend()
  Component.onDestruction: backend.running = false
}
