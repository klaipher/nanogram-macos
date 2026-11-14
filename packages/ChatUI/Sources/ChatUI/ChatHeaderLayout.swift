import Foundation
import CoreGraphics

enum ChatHeaderLayout {
    static let minimumComfortableTitleWidth: CGFloat = 218
    static let minimumAccessoryWidth: CGFloat = 320
    static let maximumAccessoryWidth: CGFloat = 560
    static let accessoryWidthFraction: CGFloat = 0.62

    /// Centers the title capsule on the chat column. leftReserved and rightReserved are the distances from the
    /// column edges to the nearest control, gaps included. The capsule never shrinks as the column grows:
    /// it takes the larger of the symmetric room and the comfortable width (bounded by the gap), then slides clear of the controls.
    static func titleCapsuleFrame(chatArea: CGRect, leftReserved: CGFloat, rightReserved: CGFloat, contentWidth: CGFloat) -> CGRect {
        let left = max(0, leftReserved)
        let right = max(0, rightReserved)
        let content = max(0, contentWidth)
        let gap = max(0, chatArea.width - left - right)
        let symmetric = max(0, chatArea.width - 2 * max(left, right))
        let width = min(content, max(symmetric, min(gap, minimumComfortableTitleWidth)))
        let centered = chatArea.minX + (chatArea.width - width) / 2
        let x = min(max(centered, chatArea.minX + left), chatArea.maxX - right - width)
        return CGRect(x: x, y: chatArea.minY, width: width, height: chatArea.height)
    }

    /// Frame of the pinned and translate bars below the title. centered gives a bounded capsule on the same axis
    /// as the title; otherwise the bar spans the room between the reserves, as every other bar does.
    static func accessoryFrame(chatArea: CGRect, leftReserved: CGFloat, rightReserved: CGFloat, centered: Bool) -> CGRect {
        let left = max(0, leftReserved)
        let right = max(0, rightReserved)
        let gap = max(0, chatArea.width - left - right)
        guard centered else {
            return CGRect(x: chatArea.minX + left, y: chatArea.minY, width: gap, height: chatArea.height)
        }
        let preferred = min(maximumAccessoryWidth, max(minimumAccessoryWidth, chatArea.width * accessoryWidthFraction))
        let width = min(preferred, gap)
        let centeredX = chatArea.minX + (chatArea.width - width) / 2
        let x = min(max(centeredX, chatArea.minX + left), chatArea.maxX - right - width)
        return CGRect(x: x, y: chatArea.minY, width: width, height: chatArea.height)
    }
}
