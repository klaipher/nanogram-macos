import Foundation
import Postbox
import SwiftSignalKit

/// The download folder in a sandboxed app. ~/Downloads is covered by an entitlement; any other folder is writable
/// only through a security-scoped bookmark created when the user picked it in the open panel.
public enum DownloadFolderAccess {
    public static var isSandboxed: Bool {
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Both spellings of ~/Downloads: the real one and the one inside the container.
    public static func downloadsRoots() -> [String] {
        var roots: [String] = []
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            roots.append(String(cString: home) + "/Downloads")
        }
        roots.append(NSHomeDirectory() + "/Downloads")
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            roots.append(url.path)
        }
        return roots
    }

    private static func normalized(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    public static func isInsideDownloads(_ path: String, roots: [String] = DownloadFolderAccess.downloadsRoots()) -> Bool {
        let path = normalized(path)
        for root in roots {
            let root = normalized(root)
            if path == root || path.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    /// A folder chosen before the sandbox (or without a bookmark) outside ~/Downloads cannot be written to.
    public static func needsReselection(_ settings: AutomaticMediaDownloadSettings, sandboxed: Bool = DownloadFolderAccess.isSandboxed, roots: [String] = DownloadFolderAccess.downloadsRoots()) -> Bool {
        if !sandboxed || settings.downloadFolderBookmark != nil {
            return false
        }
        return !isInsideDownloads(settings.downloadFolder, roots: roots)
    }

    public static func makeBookmark(for url: URL) -> Data? {
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Runs `body` with access to the download folder. `refreshed` gets new bookmark data when the stored one went stale.
    public static func withAccess<T>(_ settings: AutomaticMediaDownloadSettings, refreshed: ((Data) -> Void)? = nil, _ body: () -> T) -> T {
        guard let bookmark = settings.downloadFolderBookmark else {
            return body()
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return body()
        }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if stale, started, let data = makeBookmark(for: url) {
            refreshed?(data)
        }
        return body()
    }

    /// Resets an unusable folder to the default. Returns true when it did, so the caller can tell the user once.
    public static func resetUnusableFolder(postbox: Postbox) -> Signal<Bool, NoError> {
        let didReset = Atomic<Bool>(value: false)
        return updateMediaDownloadSettingsInteractively(postbox: postbox, { current -> AutomaticMediaDownloadSettings in
            if needsReselection(current) {
                _ = didReset.swap(true)
                return current.withUpdatedDownloadFolder(AutomaticMediaDownloadSettings.defaultSettings.downloadFolder)
            }
            return current
        })
        |> map { _ in didReset.with { $0 } }
    }

    /// Stores a refreshed bookmark when the folder is still the one it was made for.
    public static func storeRefreshed(_ data: Data, forFolder folder: String, postbox: Postbox) {
        _ = updateMediaDownloadSettingsInteractively(postbox: postbox, { current -> AutomaticMediaDownloadSettings in
            if current.downloadFolder == folder {
                return current.withUpdatedDownloadFolder(folder, bookmark: data)
            }
            return current
        }).start()
    }
}
