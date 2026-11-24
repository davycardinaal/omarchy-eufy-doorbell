import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The doorbell going off: a swinging bell, the camera, and a countdown.
//
// keepLoaded in the manifest mounts this once at startup, so a ring only flips
// `opened`. Nothing is compiled or loaded between the press and the bell.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property int phraseIndex: 0
  property real swingPhase: 0
  property real ripplePhase: 0
  property real remaining: 1
  property bool liveShowing: false

  readonly property int autoCloseMs: 60000
  // Everything on the card grows with it; k is 1 at the card's design width.
  readonly property real k: Math.max(1, card.width / Style.space(760))
  readonly property real strike: swingPhase < 0.7 ? swingPhase / 0.7 : 1

  function px(value) { return Math.round(Style.space(value) * root.k) }
  function fpx(value) { return Math.round(value * root.k) }
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "davycardinaal.eufy-doorbell"
  readonly property bool animated: Style.duration(100) > 0
  readonly property color foreground: Commons.Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property string liveUrl: opened && service ? service.liveUrl : ""
  readonly property string snapshotPath: service ? service.snapshotPath : ""
  readonly property string doorbellName: service ? service.ringName : ""
  readonly property string ringTime: service && service.ringAt > 0
    ? new Date(service.ringAt).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm") : ""

  readonly property var phrases: [
    strings.t("ring.phrase1"), strings.t("ring.phrase2"), strings.t("ring.phrase3"), strings.t("ring.phrase4"),
    strings.t("ring.phrase5"), strings.t("ring.phrase6"), strings.t("ring.phrase7"), strings.t("ring.phrase8")
  ]

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Called by the shell on summon. Every ring gets a fresh minute.
  function open(payloadJson) {
    root.opened = true
    root.phraseIndex = Math.floor(Math.random() * root.phrases.length)
    root.remaining = 1
    countdown.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Called by the shell on hide, and by finish() through it.
  function close() {
    root.opened = false
    countdown.stop()
    root.liveShowing = false
    if (root.service && root.service.ringing) root.service.endRing(true)
  }

  // `seen` is false when the minute ran out with nobody dismissing the bell.
  function finish(seen) {
    if (root.service) root.service.endRing(seen)
    if (root.shell) root.shell.hide(root.pluginId)
    root.close()
  }

  onLiveUrlChanged: {
    root.liveShowing = false
    player.stop()
    player.source = liveUrl
    if (liveUrl !== "") player.play()
  }

  NumberAnimation {
    id: countdown
    target: root
    property: "remaining"
    from: 1
    to: 0
    duration: root.autoCloseMs
    onFinished: if (root.opened) root.finish(false)
  }

  // One looping phase each drives the bell and the sound rings, so the motion
  // stays in step without a pile of separate animations.
  NumberAnimation on swingPhase {
    from: 0
    to: 1
    duration: 1500
    loops: Animation.Infinite
    running: root.opened && root.animated
  }

  NumberAnimation on ripplePhase {
    from: 0
    to: 1
    duration: 1800
    loops: Animation.Infinite
    running: root.opened && root.animated
  }

  MediaPlayer {
    id: player
    videoOutput: video
    onErrorOccurred: function(error, errorString) {
      console.info("eufy-doorbell: live view stopped:", errorString)
      root.liveShowing = false
    }
  }

  Connections {
    target: video.videoSink
    function onVideoFrameChanged() { if (root.opened && root.liveUrl !== "") root.liveShowing = true }
  }

  OverlayWindow {
    id: window
    shown: root.opened
    WlrLayershell.namespace: "eufy-doorbell"

    // Darker than a menu's scrim: this one has to win over whatever you were doing.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.82)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.finish(true)
    }

    BorderSurface {
      id: card
      // Half the screen, so the bell reads from across the room.
      width: Math.min(Math.max(Style.space(620), window.width * 0.5), window.width - Style.gapsOut * 8)
      height: content.implicitHeight + contentTopInset + contentBottomInset
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: root.px(Style.spacing.panelPadding * 1.5)

      opacity: window.contentRevealed ? 1 : 0
      scale: window.contentRevealed ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.finish(true)
            event.accepted = true
          }
        }
      }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: root.px(20)

        Row {
          width: parent.width
          spacing: root.px(26)

          BellStage {
            id: bell
            size: root.px(150)
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - bell.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.px(6)

            PlainText {
              width: parent.width
              text: (root.ringTime !== "" ? root.doorbellName + "  ·  " + root.ringTime : root.doorbellName).toUpperCase()
              color: root.dim
              font.pixelSize: root.fpx(Style.font.caption)
              font.bold: true
              font.letterSpacing: 1.6 * root.k
              elide: Text.ElideRight
            }

            // Shakes a little with every strike of the bell.
            PlainText {
              width: parent.width
              text: strings.t("ring.title")
              color: root.foreground
              font.pixelSize: root.fpx(Style.font.displayLarge * 2)
              font.bold: true
              elide: Text.ElideRight
              transform: Translate {
                x: root.animated ? root.px(4) * Math.exp(-7 * root.strike) * Math.sin(2 * Math.PI * 6 * root.strike) : 0
              }
            }

            PlainText {
              width: parent.width
              text: root.phrases[root.phraseIndex % root.phrases.length]
              color: root.foreground
              opacity: 0.75
              font.pixelSize: root.fpx(Style.font.heading)
              wrapMode: Text.WordWrap
            }
          }
        }

        // The camera: snapshot first, live video over it once frames arrive.
        Rectangle {
          id: screenBox
          width: parent.width
          height: Math.round(width * 9 / 16)
          color: Qt.darker(Commons.Color.menu.background, 1.25)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          radius: Style.cornerRadius
          clip: true

          Column {
            anchors.centerIn: parent
            spacing: root.px(10)
            visible: !snapshot.visible && !video.visible

            PlainText {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰄀"
              color: root.dim
              font.pixelSize: root.px(56)
            }

            PlainText {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.service && root.service.listening && root.service.ringSn !== ""
                ? strings.t("ring.connecting") : strings.t("ring.noCamera")
              color: root.dim
              font.pixelSize: root.fpx(Style.font.body)
            }
          }

          Image {
            id: snapshot
            anchors.fill: parent
            anchors.margins: 1
            source: root.snapshotPath !== "" ? "file://" + root.snapshotPath : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            visible: status === Image.Ready && !root.liveShowing
          }

          VideoOutput {
            id: video
            anchors.fill: parent
            anchors.margins: 1
            fillMode: VideoOutput.PreserveAspectFit
            visible: root.liveShowing
          }

          Badge {
            visible: root.liveShowing || snapshot.visible
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: root.px(12)
            live: root.liveShowing
          }
        }

        Item {
          width: parent.width
          height: hint.implicitHeight

          PlainText {
            id: hint
            anchors.left: parent.left
            text: strings.t("ring.dismissHint")
            color: root.dim
            font.pixelSize: root.fpx(Style.font.caption)
            font.letterSpacing: 1.2 * root.k
          }

          PlainText {
            anchors.right: parent.right
            text: strings.t("ring.closesIn").arg(Math.ceil(root.remaining * root.autoCloseMs / 1000))
            color: root.dim
            font.pixelSize: root.fpx(Style.font.caption)
            font.letterSpacing: 1.2 * root.k
          }
        }
      }

      // Time left before the bell gives up and leaves a notification instead.
      Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: card.borderLeft
        anchors.bottomMargin: card.borderBottom
        width: (card.width - card.borderLeft - card.borderRight) * root.remaining
        height: Math.max(2, root.px(3))
        color: root.accent
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
    renderType: Text.NativeRendering
  }

  // The bell, swinging from its top with a strike every loop, and sound rings
  // rolling out behind it.
  component BellStage: Item {
    id: stage
    property real size: 150
    width: size
    height: size

    Repeater {
      model: 3
      Rectangle {
        required property int index
        readonly property real progress: (root.ripplePhase + index / 3) % 1
        anchors.centerIn: parent
        width: stage.size
        height: stage.size
        radius: width / 2
        color: "transparent"
        border.width: Math.max(2, root.px(3))
        border.color: root.accent
        scale: 0.45 + progress * 0.75
        opacity: root.animated ? 0.55 * (1 - progress) : 0
      }
    }

    PlainText {
      readonly property real strike: root.strike
      anchors.centerIn: parent
      text: "󰂚"
      color: root.accent
      font.pixelSize: Math.round(stage.size * 0.62)
      transformOrigin: Item.Top
      rotation: root.animated ? 24 * Math.exp(-3.6 * strike) * Math.sin(2 * Math.PI * 4 * strike) : 0
      scale: root.animated ? 1 + 0.07 * Math.exp(-9 * strike) : 1
    }
  }

  component Badge: Rectangle {
    id: badge
    property bool live: false
    width: badgeRow.implicitWidth + root.px(16)
    height: badgeRow.implicitHeight + root.px(8)
    radius: Style.cornerRadius
    color: Qt.rgba(0, 0, 0, 0.6)

    Row {
      id: badgeRow
      anchors.centerIn: parent
      spacing: root.px(6)

      Rectangle {
        visible: badge.live
        anchors.verticalCenter: parent.verticalCenter
        width: root.px(8)
        height: width
        radius: width / 2
        color: root.urgent
        opacity: root.animated ? 0.55 + 0.45 * Math.cos(root.ripplePhase * 2 * Math.PI) : 1
      }

      PlainText {
        text: badge.live ? strings.t("ring.live") : strings.t("ring.snapshot")
        color: "white"
        font.pixelSize: root.fpx(Style.font.caption)
        font.bold: true
        font.letterSpacing: 1.4 * root.k
      }
    }
  }
}
