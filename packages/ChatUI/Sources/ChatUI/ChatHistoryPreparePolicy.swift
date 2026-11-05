import Foundation

struct ChatHistoryPreparePlacement: Equatable {
    var runsOnMainQueue: Bool
    var buildsViewportFirst: Bool
}

enum ChatHistoryPreparePolicy {
    static func placement(themeChanged: Bool, isInitialUpdate: Bool, followsLoadingUpdate: Bool) -> ChatHistoryPreparePlacement {
        let viewportFirst = themeChanged || (isInitialUpdate && followsLoadingUpdate)
        return ChatHistoryPreparePlacement(runsOnMainQueue: themeChanged, buildsViewportFirst: viewportFirst)
    }
}
