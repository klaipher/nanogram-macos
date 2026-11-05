import Foundation
import TelegramCore

public enum CallCaptureFailureAction: Equatable {
    case ignore
    case stopScreenCapture
    case stopVideo
}

public func callCaptureFailureAction(isCurrentCapturer: Bool, isScreenCapture: Bool) -> CallCaptureFailureAction {
    guard isCurrentCapturer else {
        return .ignore
    }
    return isScreenCapture ? .stopScreenCapture : .stopVideo
}

public func callCameraSwitchTarget(newCameraId: String?, hasCapturer: Bool, isScreenCapture: Bool, isVideoAvailable: Bool) -> String? {
    guard let newCameraId, hasCapturer, !isScreenCapture, isVideoAvailable else {
        return nil
    }
    return newCameraId
}

public func callSessionReleasesCapture(_ state: CallSessionState) -> Bool {
    switch state {
    case .terminated, .dropping:
        return true
    default:
        return false
    }
}

public func callSessionAllowsCapture(_ state: CallSessionState?) -> Bool {
    guard let state else {
        return true
    }
    switch state {
    case .terminated, .dropping, .switchedToConference:
        return false
    default:
        return true
    }
}
