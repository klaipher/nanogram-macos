import Foundation

@discardableResult
public func writeTemporaryRepresentation(_ data: Data, to url: URL) -> Bool {
    do {
        try data.write(to: url)
        return true
    } catch {
        try? FileManager.default.removeItem(at: url)
        return false
    }
}
