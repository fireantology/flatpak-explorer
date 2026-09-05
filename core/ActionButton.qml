import QtQuick
import QtQuick.Controls.Basic

// Omarchy-style button: a plain outlined box around the label, matching the
// DHCP/Cloudflare/Google/Custom buttons in Omarchy's own network panel,
// rather than bracketed inline text. Always a solid black fill regardless
// of what it's sitting on (a selected row, an active tab, ...) -- a
// transparent fill let colored text/border inherit whatever background was
// behind it, which was unreadable in some combinations (e.g. a red danger
// border on the purple row-selection highlight).
Rectangle {
  id: root

  property alias text: label.text
  property color textColor: "white"
  property bool bold: false
  property bool italic: false
  // Callers pass root.theme.fontFamily/fontSize so a button's text tracks
  // the same Omarchy [font] base-size as the rest of the row it's on --
  // defaults here only matter if a caller forgets to pass them.
  property string fontFamily: "monospace"
  property int fontPixelSize: 12
  // Keyboard-navigable choices (e.g. the remove-confirm popup's yes/cancel)
  // use this to show which one Enter would activate, distinct from mouse
  // hover -- a thicker border rather than a color change, since textColor
  // already carries meaning (danger vs. accent) that shouldn't be masked.
  property bool focused: false
  signal clicked()

  radius: 0
  color: "black"
  border.width: focused ? 2 : 1
  border.color: textColor
  implicitWidth: label.implicitWidth + 16
  implicitHeight: label.implicitHeight + 6

  Label {
    id: label
    anchors.centerIn: parent
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: root.fontPixelSize
    font.bold: root.bold
    font.italic: root.italic
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
