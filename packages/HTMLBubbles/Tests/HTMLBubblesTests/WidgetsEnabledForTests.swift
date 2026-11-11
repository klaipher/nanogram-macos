import Foundation
@testable import HTMLBubbles

func enableMessageWidgetsForTests() {
    MessageWidgetsSwitch.setEnabled(true, in: .standard)
}
