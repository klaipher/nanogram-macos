import XCTest
import SwiftSignalKit
@testable import ExternalVideoUtils

final class ExternalVideoLoaderMemoryTests: XCTestCase {
    private func video(age: TimeInterval) -> ExternalVideo {
        return ExternalVideo(dimensions: NSMakeSize(1280, 720), stream: "https://example.com/v.m3u8", quality: NSMakeSize(1280, 720), date: Date().timeIntervalSince1970 - age)
    }

    func testStatusContextsAreRemovedWhenTheirLastSubscriberLeaves() {
        let loader = ExternalVideoLoader()
        var disposables: [Disposable] = []
        for i in 0 ..< 1_000 {
            let key = "https://vimeo.com/\(i)"
            disposables.append(loader.status(forKey: key).start())
            disposables.append(loader.status(forKey: key).start())
        }
        XCTAssertEqual(loader.statusContextCount, 1_000)
        for disposable in disposables {
            disposable.dispose()
        }
        XCTAssertEqual(loader.statusContextCount, 0)
    }

    func testAStatusContextStaysWhileOneSubscriberRemains() {
        let loader = ExternalVideoLoader()
        let first = loader.status(forKey: "https://vimeo.com/1").start()
        let second = loader.status(forKey: "https://vimeo.com/1").start()
        first.dispose()
        XCTAssertEqual(loader.statusContextCount, 1)
        second.dispose()
        XCTAssertEqual(loader.statusContextCount, 0)
    }

    func testANewSubscriberStillSeesAFreshCachedVideo() {
        let loader = ExternalVideoLoader()
        let cached = video(age: 60)
        loader.store(video: cached, forKey: "https://vimeo.com/1")
        var received: ExternalVideoStatus?
        let disposable = loader.status(forKey: "https://vimeo.com/1").start(next: { status in
            received = status
        })
        XCTAssertEqual(loader.statusContextCount, 1)
        if case let .loaded(video)? = received {
            XCTAssertTrue(video === cached)
        } else {
            XCTFail("expected the cached video, got \(String(describing: received))")
        }
        disposable.dispose()
    }

    func testExpiredVideosAreDroppedWhenAnotherIsStored() {
        let loader = ExternalVideoLoader()
        for i in 0 ..< 1_000 {
            loader.store(video: video(age: 31 * 60), forKey: "https://vimeo.com/\(i)")
        }
        loader.store(video: video(age: 0), forKey: "https://vimeo.com/fresh")
        XCTAssertEqual(loader.cachedVideoCount, 1)
    }
}
