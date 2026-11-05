import Foundation

/// Writes a cached-representation payload to `url`.
/// On failure the partial file is removed and `false` is returned, so a truncated file is never handed
/// to the cache as `.temporaryPath` (mirrors iOS FetchCachedRepresentations.swift).
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
