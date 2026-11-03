import XCTest
@testable import NanogramKit

final class UpdateFlowTests: XCTestCase {
    private func flow(_ events: [UpdateFlow<String>.Event]) -> UpdateFlow<String> {
        var flow = UpdateFlow<String>()
        events.forEach { flow.apply($0) }
        return flow
    }

    func test_startsIdle() {
        XCTAssertEqual(UpdateFlow<String>().phase, .idle)
    }

    func test_checkWithoutUpdate_isUpToDate() {
        XCTAssertEqual(flow([.checkStarted]).phase, .checking)
        XCTAssertEqual(flow([.checkStarted, .notFound]).phase, .upToDate)
    }

    func test_download_countsBytesAgainstExpectedLength() {
        let phase = flow([.checkStarted, .found("2.0"), .downloadStarted, .expectedLength(1000), .received(300), .received(200)]).phase
        XCTAssertEqual(phase, .downloading("2.0", received: 500, expected: 1000))
    }

    func test_download_moreBytesThanAnnounced_raisesExpected() {
        let phase = flow([.found("2.0"), .downloadStarted, .expectedLength(100), .received(150)]).phase
        XCTAssertEqual(phase, .downloading("2.0", received: 150, expected: 150))
    }

    func test_newExpectedLength_restartsCount() {
        let phase = flow([.found("2.0"), .downloadStarted, .received(50), .expectedLength(400)]).phase
        XCTAssertEqual(phase, .downloading("2.0", received: 0, expected: 400))
    }

    func test_fullUpdate_reachesReadyThenInstalling() {
        let ready = flow([.checkStarted, .found("2.0"), .downloadStarted, .expectedLength(10), .received(10), .extractionStarted, .ready])
        XCTAssertEqual(ready.phase, .readyToInstall("2.0"))
        XCTAssertEqual(ready.item, "2.0")
        var installing = ready
        installing.apply(.installing)
        XCTAssertEqual(installing.phase, .installing)
    }

    func test_backgroundCheck_neverHidesAnUpdateInProgress() {
        for progressed in [
            flow([.found("2.0"), .downloadStarted, .expectedLength(10)]),
            flow([.found("2.0"), .downloadStarted, .extractionStarted]),
            flow([.found("2.0"), .ready]),
            flow([.found("2.0"), .ready, .installing]),
        ] {
            var checked = progressed
            checked.apply(.checkStarted)
            checked.apply(.notFound)
            XCTAssertEqual(checked.phase, progressed.phase)
        }
    }

    func test_newerUpdateFoundWhileReady_replacesIt() {
        XCTAssertEqual(flow([.found("2.0"), .ready, .found("2.1")]).phase, .found("2.1"))
    }

    func test_progressWithoutAnItem_isIgnored() {
        XCTAssertEqual(flow([.downloadStarted, .received(10), .extractionStarted, .ready]).phase, .idle)
    }

    func test_failure_isShownAndARecheckRecovers() {
        let failed = flow([.found("2.0"), .downloadStarted, .failed("network")])
        XCTAssertEqual(failed.phase, .failed("network"))
        XCTAssertNil(failed.item)
        var recovered = failed
        recovered.apply(.checkStarted)
        XCTAssertEqual(recovered.phase, .checking)
    }

    func test_dismissedBeforeDownload_goesBackToIdle_butKeepsAReadyUpdate() {
        XCTAssertEqual(flow([.found("2.0"), .dismissed]).phase, .idle)
        XCTAssertEqual(flow([.found("2.0"), .ready, .dismissed]).phase, .readyToInstall("2.0"))
    }
}
