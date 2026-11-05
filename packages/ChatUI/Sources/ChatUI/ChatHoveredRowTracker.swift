import Cocoa
import TGUIKit

final class ChatHoveredRowTracker {
    private weak var table: TableView?
    private weak var previous: TableRowView?

    init(table: TableView) {
        self.table = table
    }

    func update(windowLocation: NSPoint) {
        guard let table = self.table else {
            return
        }
        var current: TableRowView?
        if let documentView = table.documentView {
            let point = documentView.convert(windowLocation, from: nil)
            let row = table.row(at: point)
            if row >= 0 {
                current = table.viewNecessary(at: row)
            }
        }
        if let previous = self.previous, previous !== current {
            previous.updateMouse(animated: true)
        }
        current?.updateMouse(animated: true)
        self.previous = current
    }
}
