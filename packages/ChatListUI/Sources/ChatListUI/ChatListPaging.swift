import Foundation
import CoreGraphics

enum ChatListPageDirection: Equatable {
    case earlier
    case later
}

struct ChatListPageRequest<Anchor: Equatable>: Equatable {
    let direction: ChatListPageDirection
    let anchor: Anchor
}

struct ChatListPageWindow<Anchor: Equatable>: Equatable {
    let hasLater: Bool
    let hasEarlier: Bool
    let firstAnchor: Anchor?
    let lastAnchor: Anchor?
}

struct ChatListPageGeometry: Equatable {
    let remainingAbove: CGFloat
    let remainingBelow: CGFloat
    let viewport: CGFloat
    let rowHeight: CGFloat
}

enum ChatListPaging {
    static let minimumPreload: CGFloat = 1400
    static let halfWindowRows: CGFloat = 100

    static func preloadDistance(viewport: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let wanted = max(viewport * 2, minimumPreload)
        let keepsAPageAfterRecentring = halfWindowRows * rowHeight - viewport
        return max(min(wanted, keepsAPageAfterRecentring), rowHeight)
    }

    static func nextPageRequest<Anchor: Equatable>(window: ChatListPageWindow<Anchor>, geometry: ChatListPageGeometry, direction: ChatListPageDirection, lastRequested: Anchor?) -> ChatListPageRequest<Anchor>? {
        let distance = preloadDistance(viewport: geometry.viewport, rowHeight: geometry.rowHeight)
        let request: ChatListPageRequest<Anchor>?
        switch direction {
        case .later:
            if window.hasLater, geometry.remainingAbove < distance, let lastAnchor = window.lastAnchor {
                request = ChatListPageRequest(direction: .later, anchor: lastAnchor)
            } else {
                request = nil
            }
        case .earlier:
            if window.hasEarlier, geometry.remainingBelow < distance, let firstAnchor = window.firstAnchor {
                request = ChatListPageRequest(direction: .earlier, anchor: firstAnchor)
            } else {
                request = nil
            }
        }
        guard let request, request.anchor != lastRequested else {
            return nil
        }
        return request
    }
}

struct ChatListPager<Anchor: Equatable, Key: Equatable> {
    private(set) var window: ChatListPageWindow<Anchor>?
    private(set) var windowKey: Key?
    private(set) var direction: ChatListPageDirection = .earlier
    private(set) var lastRequested: Anchor?

    mutating func didApply(window: ChatListPageWindow<Anchor>, key: Key) {
        self.window = window
        self.windowKey = key
    }

    mutating func didScroll(towards direction: ChatListPageDirection) {
        self.direction = direction
    }

    mutating func restart() {
        self.lastRequested = nil
        self.direction = .earlier
    }

    mutating func nextRequest(currentKey: Key, geometry: ChatListPageGeometry, isAnimatingScroll: Bool) -> ChatListPageRequest<Anchor>? {
        guard !isAnimatingScroll, let window, windowKey == currentKey else {
            return nil
        }
        guard let request = ChatListPaging.nextPageRequest(window: window, geometry: geometry, direction: direction, lastRequested: lastRequested) else {
            return nil
        }
        lastRequested = request.anchor
        return request
    }
}
