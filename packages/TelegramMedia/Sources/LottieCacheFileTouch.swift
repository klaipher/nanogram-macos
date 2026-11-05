import Foundation

let lottieCacheTouchInterval: TimeInterval = 24 * 60 * 60

@discardableResult
func touchLottieCacheFileIfStale(atPath path: String, now: Date = Date(), staleAfter: TimeInterval = lottieCacheTouchInterval) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0 else {
        return false
    }
    let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    guard now.timeIntervalSince1970 - modified > staleAfter else {
        return false
    }
    return utimes(path, nil) == 0
}

@discardableResult
func createLottieCacheFileIfMissing(atPath path: String) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT, 0o644)
    guard fd >= 0 else {
        return false
    }
    close(fd)
    return true
}
