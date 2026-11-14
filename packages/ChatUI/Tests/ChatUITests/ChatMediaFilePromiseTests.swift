import XCTest
import AppKit
import Postbox
import SwiftSignalKit
@testable import ChatUI

final class ChatMediaFilePromiseTests: XCTestCase {
    func testFileTypeFromKnownMimeType() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: "image/jpeg"), "public.jpeg")
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: "video/mp4"), "public.mpeg-4")
    }

    func testFileTypeFallsBackToData() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileType(mimeType: nil), "public.data")
    }

    func testNameKeepsExistingExtension() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: "clip.mov", mimeType: "video/mp4", fallbackStem: "FILE"), "clip.mov")
    }

    func testNameGetsExtensionFromMimeType() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: "photo", mimeType: "image/jpeg", fallbackStem: "IMAGE"), "photo.jpeg")
    }

    func testMissingNameUsesFallbackStem() {
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: nil, mimeType: "image/png", fallbackStem: "IMAGE 2026"), "IMAGE 2026.png")
    }

    func testSeparatorsAndLeadingDotAreSanitized() {
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized("a/b:c"), "a_b_c")
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized(".hidden"), "_hidden")
        XCTAssertEqual(ChatMediaPromiseNaming.sanitized("   "), "")
    }

    func testPromiseCompletionFiresOnce() {
        var calls = 0
        let completion = PromiseCompletion { _ in calls += 1 }
        completion.complete(nil)
        completion.complete(ChatMediaPromiseError.unavailable)
        XCTAssertEqual(calls, 1)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("promise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ promise: ChatMediaFilePromise, to url: URL, wait: Double = 5) -> Error?? {
        let expectation = XCTestExpectation(description: "completion")
        var result: Error??
        let provider = NSFilePromiseProvider(fileType: "public.data", delegate: promise)
        promise.filePromiseProvider(provider, writePromiseTo: url) { error in
            result = .some(error)
            expectation.fulfill()
        }
        _ = XCTWaiter().wait(for: [expectation], timeout: wait)
        return result
    }

    func testWritesCompleteDataToDestination() throws {
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("source.bin")
        try Data([1, 2, 3, 4]).write(to: source)
        let destination = dir.appendingPathComponent("out.bin")
        let data = Signal<MediaResourceData, NoError>.single(MediaResourceData(path: source.path, offset: 0, size: 4, complete: true))
        let promise = ChatMediaFilePromise(fileName: "out.bin", data: data, fetch: nil)

        let result = write(promise, to: destination)

        XCTAssertNotNil(result)
        XCTAssertNil(result.flatMap { $0 })
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3, 4]))
    }

    func testStartsFetchWhenProvided() throws {
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("source.bin")
        try Data([9]).write(to: source)
        let started = Atomic<Bool>(value: false)
        let fetch = Signal<Void, NoError> { _ in
            _ = started.swap(true)
            return EmptyDisposable
        }
        let data = Signal<MediaResourceData, NoError>.single(MediaResourceData(path: source.path, offset: 0, size: 1, complete: true))
        let promise = ChatMediaFilePromise(fileName: "x", data: data, fetch: fetch)

        _ = write(promise, to: dir.appendingPathComponent("x"))

        XCTAssertTrue(started.with { $0 })
    }

    func testIncompleteThenCompleteDataWaitsForCompletion() throws {
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("source.bin")
        try Data([7, 7]).write(to: source)
        let data = Signal<MediaResourceData, NoError> { subscriber in
            subscriber.putNext(MediaResourceData(path: source.path, offset: 0, size: 1, complete: false))
            subscriber.putNext(MediaResourceData(path: source.path, offset: 0, size: 2, complete: true))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let promise = ChatMediaFilePromise(fileName: "x", data: data, fetch: nil)
        let destination = dir.appendingPathComponent("x")

        let result = write(promise, to: destination)

        XCTAssertNil(result.flatMap { $0 })
        XCTAssertEqual(try Data(contentsOf: destination), Data([7, 7]))
    }

    func testCompletesWithErrorWhenDataEndsWithoutCompleteResource() throws {
        let dir = try makeTempDir()
        let data = Signal<MediaResourceData, NoError>.complete()
        let promise = ChatMediaFilePromise(fileName: "x", data: data, fetch: nil)

        let result = write(promise, to: dir.appendingPathComponent("x"))

        XCTAssertNotNil(result.flatMap { $0 })
    }

    func testCopyFailureCompletesWithError() throws {
        let dir = try makeTempDir()
        let data = Signal<MediaResourceData, NoError>.single(MediaResourceData(path: dir.appendingPathComponent("missing").path, offset: 0, size: 1, complete: true))
        let promise = ChatMediaFilePromise(fileName: "x", data: data, fetch: nil)

        let result = write(promise, to: dir.appendingPathComponent("x"))

        XCTAssertNotNil(result.flatMap { $0 })
    }

    func testCancelCompletesPendingWriteWithCancellation() throws {
        let dir = try makeTempDir()
        let promise = ChatMediaFilePromise(fileName: "x", data: .never(), fetch: nil)
        let expectation = XCTestExpectation(description: "completion")
        var received: Error?
        let provider = NSFilePromiseProvider(fileType: "public.data", delegate: promise)
        promise.filePromiseProvider(provider, writePromiseTo: dir.appendingPathComponent("x")) { error in
            received = error
            expectation.fulfill()
        }

        promise.cancel()

        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 2), .completed)
        XCTAssertEqual((received as? CocoaError)?.code, .userCancelled)
    }

    func testStalledDataTimesOutWithError() throws {
        let dir = try makeTempDir()
        let promise = ChatMediaFilePromise(fileName: "x", data: .never(), fetch: nil, timeout: 0.2)

        let result = write(promise, to: dir.appendingPathComponent("x"))

        XCTAssertNotNil(result.flatMap { $0 })
    }

    func testFallbackStemHasNoColonsOrDoubleDots() {
        let stem = ChatMediaPromiseNaming.fallbackStem(isImage: true, date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(stem.hasPrefix("IMAGE "))
        XCTAssertFalse(stem.contains(":"))
        XCTAssertFalse(stem.contains(".."))
        XCTAssertEqual(ChatMediaPromiseNaming.fileName(preferred: nil, mimeType: "image/jpeg", fallbackStem: stem), stem + ".jpeg")
    }
}
