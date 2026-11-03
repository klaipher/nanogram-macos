import Foundation

public enum NanogramLogChatSendResult: Equatable, Sendable {
    case cancelled
    case sent
    case failed
}

public enum NanogramLogChatUploadState: Equatable, Sendable {
    case pending
    case sent
    case failed
}

public func nanogramLogChatUploadResult(_ states: [NanogramLogChatUploadState]) -> NanogramLogChatSendResult? {
    if states.isEmpty {
        return .failed
    }
    if states.contains(.pending) {
        return nil
    }
    return states.contains(.failed) ? .failed : .sent
}

public enum NanogramLogEmailRoute: Equatable, Sendable {
    case compose
    case picker
}

public func nanogramLogEmailRoute(hasMailApp: Bool, canCompose: Bool) -> NanogramLogEmailRoute {
    return hasMailApp && canCompose ? .compose : .picker
}

public func nanogramLogEmailFailureOffersPicker(_ error: Error) -> Bool {
    let error = error as NSError
    return !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
}

@MainActor
final class NanogramLogExportRun {
    private let gate: NanogramLogExportGate
    private let onDelivered: (@MainActor @Sendable () -> Void)?
    private var directory: URL?
    private(set) var isFinished = false

    init?(gate: NanogramLogExportGate, onDelivered: (@MainActor @Sendable () -> Void)?) {
        guard gate.begin() else {
            return nil
        }
        self.gate = gate
        self.onDelivered = onDelivered
    }

    func attach(directory: URL) {
        self.directory = directory
    }

    func finish(delivered: Bool, removeFiles: Bool = true) {
        if self.isFinished {
            return
        }
        self.isFinished = true
        if removeFiles, let directory = self.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        self.gate.end()
        if delivered {
            self.onDelivered?()
        }
    }
}
