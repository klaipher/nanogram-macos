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

enum ChatListPaging {
    static let minimumPreload: CGFloat = 1400

    static func preloadDistance(viewport: CGFloat) -> CGFloat {
        return max(viewport * 2, minimumPreload)
    }

    static func nextPageRequest<Anchor: Equatable>(remainingAbove: CGFloat, remainingBelow: CGFloat, viewport: CGFloat, hasLater: Bool, hasEarlier: Bool, firstAnchor: Anchor?, lastAnchor: Anchor?, lastRequested: Anchor?) -> ChatListPageRequest<Anchor>? {
        let distance = preloadDistance(viewport: viewport)
        let request: ChatListPageRequest<Anchor>?
        if hasLater, remainingAbove < distance, let lastAnchor {
            request = ChatListPageRequest(direction: .later, anchor: lastAnchor)
        } else if hasEarlier, remainingBelow < distance, let firstAnchor {
            request = ChatListPageRequest(direction: .earlier, anchor: firstAnchor)
        } else {
            request = nil
        }
        guard let request, request.anchor != lastRequested else {
            return nil
        }
        return request
    }
}
