import XCTest
import Postbox
import SwiftSignalKit
import TelegramCore
@testable import ChatUI

final class ReactionEffectFileWaitTests: XCTestCase {
    private func data(complete: Bool) -> MediaResourceData {
        return MediaResourceData(path: "/tmp/reaction-effect", offset: 0, size: 10, complete: complete)
    }

    private func firstValue(of signal: Signal<MediaResourceData?, NoError>, timeout: Double = 2.0) -> MediaResourceData?? {
        let expectation = XCTestExpectation(description: "value")
        let result = Atomic<MediaResourceData??>(value: nil)
        let disposable = signal.start(next: { value in
            _ = result.swap(.some(value))
            expectation.fulfill()
        })
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
        disposable.dispose()
        return result.with { $0 }
    }

    func testAFileAlreadyOnTheDevicePlaysWithoutWaiting() {
        let signal = ReactionEffectFileWait.data(resource: .single(data(complete: true)), limit: 1.0, queue: Queue())
        let started = CFAbsoluteTimeGetCurrent()
        let value = firstValue(of: signal)
        XCTAssertNotNil(value ?? nil)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.5)
    }

    func testAMissingFilePlaysWhenItArrivesInTime() {
        let resource = Promise<MediaResourceData>(data(complete: false))
        let signal = ReactionEffectFileWait.data(resource: resource.get(), limit: 2.0, queue: Queue())
        Queue.concurrentDefaultQueue().after(0.1) {
            resource.set(.single(self.data(complete: true)))
        }
        let value = firstValue(of: signal)
        XCTAssertNotNil(value ?? nil)
    }

    func testAFileThatNeverArrivesGivesUpAfterTheLimitInsteadOfWaitingForever() {
        let pending = Promise<MediaResourceData>(data(complete: false))
        let signal = ReactionEffectFileWait.data(resource: pending.get(), limit: 0.1, queue: Queue())
        let started = CFAbsoluteTimeGetCurrent()
        let value = firstValue(of: signal)
        guard let value else {
            return XCTFail("the wait never ended")
        }
        XCTAssertNil(value)
        XCTAssertGreaterThanOrEqual(CFAbsoluteTimeGetCurrent() - started, 0.09)
    }

    func testTheDownloadKeepsRunningAfterTheWaitEnds() {
        let fetches = ReactionEffectFetches()
        let disposed = Atomic<Bool>(value: false)
        let fetch = Signal<Void, NoError> { _ in
            return ActionDisposable { _ = disposed.swap(true) }
        }
        let id = MediaId(namespace: 0, id: 777)
        XCTAssertTrue(fetches.ensure(id, fetch: fetch, cap: 30, queue: Queue()))
        let pending = Promise<MediaResourceData>(data(complete: false))
        let signal = ReactionEffectFileWait.data(resource: pending.get(), limit: 0.05, queue: Queue())
        let value = firstValue(of: signal)
        XCTAssertNotNil(value)
        XCTAssertNil(value ?? nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(disposed.with { $0 })
        XCTAssertTrue(fetches.isActive(id))
    }

    func testOneDownloadPerFileAndItIsForgottenWhenDone() {
        let fetches = ReactionEffectFetches()
        let started = Atomic<Int>(value: 0)
        let subscriber = Atomic<Subscriber<Void, NoError>?>(value: nil)
        let fetch = Signal<Void, NoError> { s in
            _ = started.modify { $0 + 1 }
            _ = subscriber.swap(s)
            return EmptyDisposable
        }
        let id = MediaId(namespace: 0, id: 778)
        XCTAssertTrue(fetches.ensure(id, fetch: fetch, cap: 30, queue: Queue()))
        XCTAssertFalse(fetches.ensure(id, fetch: fetch, cap: 30, queue: Queue()))
        XCTAssertEqual(started.with { $0 }, 1)
        subscriber.with { $0 }?.putCompletion()
        XCTAssertFalse(fetches.isActive(id))
        XCTAssertEqual(fetches.activeCount, 0)
        XCTAssertTrue(fetches.ensure(id, fetch: fetch, cap: 30, queue: Queue()))
    }

    func testADownloadThatNeverEndsIsCancelledAtTheCap() {
        let fetches = ReactionEffectFetches()
        let disposed = Atomic<Bool>(value: false)
        let fetch = Signal<Void, NoError> { _ in
            return ActionDisposable { _ = disposed.swap(true) }
        }
        let id = MediaId(namespace: 0, id: 779)
        fetches.ensure(id, fetch: fetch, cap: 0.05, queue: Queue())
        let deadline = Date().addingTimeInterval(2.0)
        while fetches.isActive(id) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(fetches.isActive(id))
        XCTAssertTrue(disposed.with { $0 })
    }

    func testTheWaitIsAboutAsLongAsAReactionFlight() {
        XCTAssertGreaterThanOrEqual(ReactionEffectFileWait.limit, 1.0)
        XCTAssertLessThanOrEqual(ReactionEffectFileWait.limit, 3.0)
    }

    private func file(_ id: Int64) -> TelegramMediaFile {
        let resource = LocalFileMediaResource(fileId: id)
        return TelegramMediaFile(fileId: MediaId(namespace: 0, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/x-tgsticker", size: 1, attributes: [], alternativeRepresentations: [])
    }

    private func reaction(_ index: Int64, enabled: Bool = true, premium: Bool = false, effects: Bool = true) -> AvailableReactions.Reaction {
        let base = index * 10
        return AvailableReactions.Reaction(isEnabled: enabled, isPremium: premium, value: .custom(index), title: "r\(index)", staticIcon: file(base), appearAnimation: file(base + 1), selectAnimation: file(base + 2), activateAnimation: file(base + 3), effectAnimation: file(base + 4), aroundAnimation: effects ? file(base + 5) : nil, centerAnimation: effects ? file(base + 6) : nil)
    }

    func testPrefetchTakesTheEffectFilesOfTheFirstReactionsOnly() {
        let reactions = (1 ... 20).map { reaction(Int64($0)) }
        let files = ReactionEffectPrefetch.files(from: reactions, includePremium: false, limit: 3)
        XCTAssertEqual(files.map { $0.fileId.id }, [15, 16, 14, 13, 25, 26, 24, 23, 35, 36, 34, 33])
    }

    func testPrefetchSkipsDisabledAndPremiumReactionsForOrdinaryAccounts() {
        let reactions = [reaction(1, enabled: false), reaction(2, premium: true), reaction(3), reaction(4, effects: false)]
        XCTAssertEqual(ReactionEffectPrefetch.files(from: reactions, includePremium: false).map { $0.fileId.id }, [35, 36, 34, 33, 44, 43])
        XCTAssertEqual(ReactionEffectPrefetch.files(from: reactions, includePremium: true).map { $0.fileId.id }, [25, 26, 24, 23, 35, 36, 34, 33, 44, 43])
    }

    func testASourceThatEndsWithoutTheFileStopsWaitingAtOnce() {
        let signal = ReactionEffectFileWait.data(resource: .single(data(complete: false)), limit: 5.0, queue: Queue())
        let started = CFAbsoluteTimeGetCurrent()
        let value = firstValue(of: signal)
        XCTAssertNotNil(value)
        XCTAssertNil(value ?? nil)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 1.0)
    }

    func testOnlyTheFirstReactionsPrefetchOnDemandFiles() {
        let reactions = (1 ... 8).map { reaction(Int64($0)) }
        let ids = Set(ReactionEffectPrefetch.files(from: reactions, includePremium: false).map { $0.fileId.id })
        XCTAssertTrue(ids.contains(44))
        XCTAssertFalse(ids.contains(54))
        XCTAssertTrue(ids.contains(55))
    }
}
