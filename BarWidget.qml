import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bell in the bar and its panel: setup (second account, login, codes),
// the doorbells this account hears, and a button to ring the bell for fun.
// Everything it shows comes from the service, which runs once per shell
// while this widget exists once per monitor.
Panel {
  id: root
  moduleName: "davycardinaal.eufy-doorbell"
  ipcTarget: "davycardinaal.eufy-doorbell"
  manageIpc: false

  readonly property string pluginId: "davycardinaal.eufy-doorbell"
  property var doorbell: null

  readonly property string status: doorbell ? doorbell.status : "starting"
  readonly property bool listening: !!doorbell && doorbell.listening
  readonly property bool ringing: !!doorbell && doorbell.ringing
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string statusLabel: strings.t("status." + status, status)
  readonly property string glyph: ringing ? "󰂞" : (listening || status === "starting" || status === "connecting" ? "󰂚" : "󰂛")

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // The service may mount after the first bar does; look until it is there.
  Timer {
    interval: 500
    repeat: true
    running: !root.doorbell
    triggeredOnStart: true
    onTriggered: root.doorbell = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.pluginId) : null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function timeOf(ms) {
    return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")
  }

  function testRing() {
    root.close()
    if (root.doorbell) root.doorbell.testRing("")
  }

  // omarchy-shell davycardinaal.eufy-doorbell ring — rings the bell without a doorbell.
  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function ring(): void { root.testRing() }
    function status(): string { return root.status }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.ringing
    dimmed: !root.listening && !root.ringing
    tooltipText: strings.t("tooltip").arg(root.statusLabel)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.testRing()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Only the screen caps it: the setup steps and the form fit on one page.
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: FocusScope {
      id: body
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: strings.t("doorbell.title")
            meta: root.statusLabel
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.ringing ? Commons.Color.accent : root.foreground
                opacity: root.listening || root.ringing ? 1 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰂞"
                tooltipText: strings.t("action.test")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.testRing()
              }
            }
          }

          Note {
            visible: ["starting", "logging-in", "connecting", "installing", "error"].indexOf(root.status) !== -1
            text: root.status === "installing" ? strings.t("install.busy")
              : root.status === "error" ? strings.t("error.body")
              : strings.t("progress." + root.status)
          }

          Note {
            visible: root.doorbell && root.doorbell.message !== "" && !root.listening
            text: root.doorbell ? root.doorbell.message : ""
            color: root.urgent
          }

          // ------------------------------------------------ runtime missing
          Column {
            visible: root.status === "no-node"
            width: parent.width
            spacing: Style.space(10)
            Note { text: strings.t("node.body") }
            ActionButton { text: strings.t("action.retry"); onClicked: root.doorbell.reconnect() }
          }

          Column {
            visible: root.status === "needs-install"
            width: parent.width
            spacing: Style.space(10)
            Note { text: strings.t("install.body") }
            ActionButton { text: strings.t("action.install"); onClicked: root.doorbell.install() }
          }

          Column {
            visible: root.status === "error"
            width: parent.width
            ActionButton { text: strings.t("action.retry"); onClicked: root.doorbell.reconnect() }
          }

          // ------------------------------------------------ second account
          Column {
            id: loginForm
            visible: root.status === "logged-out"
            width: parent.width
            spacing: Style.space(10)

            function submit() {
              if (!root.doorbell) return
              root.doorbell.login(emailField.text, passwordField.text, countryField.text)
              passwordField.text = ""
            }

            PanelSectionHeader {
              text: strings.t("account.heading")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Note { text: strings.t("account.why") }

            Repeater {
              model: [
                { step: "step1", url: "https://service.eufy.com/article-description/Sign-up-for-A-eufy-Account" },
                { step: "step2", url: "https://service.eufy.com/article-description/Share-Your-eufy-Devices-With-Your-Family" },
                { step: "step3", url: "" },
                { step: "step4", url: "" }
              ]
              Row {
                required property var modelData
                required property int index
                width: loginForm.width
                spacing: Style.space(10)

                Text {
                  id: stepNumber
                  width: Style.space(14)
                  textFormat: Text.PlainText
                  text: String(index + 1)
                  color: Commons.Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Column {
                  width: parent.width - stepNumber.width - parent.spacing
                  spacing: Style.space(3)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: strings.t("account." + modelData.step + ".title")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }

                  Note { text: strings.t("account." + modelData.step + ".body") }

                  Link {
                    visible: modelData.url !== ""
                    label: strings.t("account." + modelData.step + ".link")
                    url: modelData.url
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            Field {
              id: emailField
              placeholderText: strings.t("form.email")
              text: root.doorbell ? root.doorbell.email : ""
              inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
              onAccepted: passwordField.forceActiveFocus()
            }

            Field {
              id: passwordField
              placeholderText: strings.t("form.password")
              password: true
              onAccepted: loginForm.submit()
            }

            Row {
              width: parent.width
              spacing: Style.space(10)

              Field {
                id: countryField
                width: Style.space(88)
                placeholderText: strings.t("form.country")
                maximumLength: 2
                onAccepted: loginForm.submit()
              }

              Note {
                width: parent.width - countryField.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("form.countryHint")
              }
            }

            ActionButton { text: strings.t("action.login"); onClicked: loginForm.submit() }
            Note { text: strings.t("form.secret"); font.pixelSize: Style.font.caption }
          }

          // ------------------------------------------------ captcha
          Column {
            visible: root.status === "captcha"
            width: parent.width
            spacing: Style.space(10)

            Note { text: root.doorbell && root.doorbell.captchaRetry ? strings.t("captcha.retry") : strings.t("captcha.body") }

            Image {
              width: parent.width
              height: Style.space(80)
              fillMode: Image.PreserveAspectFit
              source: root.doorbell ? root.doorbell.captchaImage : ""
            }

            Field {
              id: captchaField
              placeholderText: strings.t("captcha.answer")
              onAccepted: captchaButton.clicked()
            }

            ActionButton {
              id: captchaButton
              text: strings.t("action.submit")
              onClicked: {
                root.doorbell.solveCaptcha(captchaField.text)
                captchaField.text = ""
              }
            }
          }

          // ------------------------------------------------ 2FA
          Column {
            visible: root.status === "2fa"
            width: parent.width
            spacing: Style.space(10)

            Note { text: strings.t("twofa.body").arg(root.doorbell ? root.doorbell.email : "") }

            Field {
              id: codeField
              placeholderText: strings.t("twofa.code")
              inputMethodHints: Qt.ImhDigitsOnly
              onAccepted: codeButton.clicked()
            }

            ActionButton {
              id: codeButton
              text: strings.t("action.submit")
              onClicked: {
                root.doorbell.submitCode(codeField.text)
                codeField.text = ""
              }
            }
          }

          // ------------------------------------------------ listening
          Column {
            visible: root.listening
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("ready.heading")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Note {
              visible: root.doorbell && root.doorbell.doorbells.length === 0
              text: strings.t("ready.none")
            }

            Repeater {
              model: root.doorbell ? root.doorbell.doorbells : []
              CursorSurface {
                id: row
                required property var modelData
                width: parent.width
                implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
                foreground: root.foreground
                hasCursor: rowMouse.containsMouse

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.close()
                    root.doorbell.testRing(row.modelData.sn)
                  }
                }

                Row {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Text {
                    id: rowIcon
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "󰡩"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.iconLarge
                  }

                  Column {
                    width: parent.width - rowIcon.width - rowRing.width - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: row.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: row.modelData.lastRing > 0 ? strings.t("ready.lastRing").arg(root.timeOf(row.modelData.lastRing)) : strings.t("ready.noRing")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    id: rowRing
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "󰂞"
                    color: rowMouse.containsMouse ? Commons.Color.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              height: logoutButton.height

              Note {
                anchors.left: parent.left
                anchors.right: logoutButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("ready.account").arg(root.doorbell ? root.doorbell.email : "")
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
              }

              Button {
                id: logoutButton
                anchors.right: parent.right
                text: strings.t("action.logout")
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.doorbell.logout()
              }
            }
          }
        }
      }
    }
  }

  component Note: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // Opens an eufy help page in the browser.
  component Link: Text {
    property string label
    property string url
    textFormat: Text.PlainText
    text: label + "  󰏌"
    color: Commons.Color.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.underline: linkMouse.containsMouse

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.close()
        Qt.openUrlExternally(parent.url)
      }
    }
  }

  component Field: TextField {
    width: parent ? parent.width : implicitWidth
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    foreground: root.foreground
  }

  component ActionButton: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
  }
}
