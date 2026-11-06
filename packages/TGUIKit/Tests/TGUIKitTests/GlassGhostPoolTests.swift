import XCTest
import AppKit
@testable import TGUIKit

final class GlassGhostPoolTests: XCTestCase {
    private let spec = GlassGhostSpec(cornerRadius: 20, hasShadow: true, hasBorder: true, tintAlpha: 0.3, group: .inputRow)
    private let otherSpec = GlassGhostSpec(cornerRadius: 22, hasShadow: true, hasBorder: true, tintAlpha: 0.4, group: .chatHeader)

    override func setUp() {
        super.setUp()
        TGUIKitTestBootstrap.install()
        GlassChromeReuse.isEnabled = false
    }

    override func tearDown() {
        GlassChromeReuse.isEnabled = false
        super.tearDown()
    }

    func testFlagOffAcquireBuildsFreshUntaggedGhostsAndReleaseDoesNothing() {
        let pool = GlassGhostPool()
        let first = pool.acquire(spec)
        XCTAssertNil(first.glassReuseSpec)
        XCTAssertEqual(first.glassGroup, .inputRow)
        pool.release(first)
        XCTAssertEqual(pool.pooledCount, 0)
        let second = pool.acquire(spec)
        XCTAssertFalse(first === second)
        XCTAssertEqual(pool.reusedCount, 0)
        XCTAssertEqual(pool.createdCount, 0)
    }

    func testFlagOnReleasedGhostIsHandedBackOnTheNextAcquire() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        let first = pool.acquire(spec)
        XCTAssertEqual(first.glassReuseSpec, spec)
        XCTAssertEqual(pool.createdCount, 1)
        pool.release(first)
        XCTAssertEqual(pool.pooledCount, 1)
        XCTAssertNil(first.glassReuseSpec)
        let second = pool.acquire(spec)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.glassReuseSpec, spec)
        XCTAssertEqual(pool.reusedCount, 1)
        XCTAssertEqual(pool.createdCount, 1)
        XCTAssertEqual(pool.pooledCount, 0)
    }

    func testGhostsOfDifferentSpecsAreNeverMixed() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        let input = pool.acquire(spec)
        pool.release(input)
        let header = pool.acquire(otherSpec)
        XCTAssertFalse(header === input)
        XCTAssertEqual(header.cornerRadius, 22)
        XCTAssertEqual(header.glassGroup, .chatHeader)
        XCTAssertEqual(pool.pooledCount, 1)
    }

    func testReleaseResetsEveryPerChatField() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        let ghost = pool.acquire(spec)
        var appearanceCalls = 0
        ghost.onAppearanceChange = { _ in appearanceCalls += 1 }
        ghost.customTint = .systemPink
        ghost.isHidden = true
        ghost.alphaValue = 0.3
        ghost.frame = NSMakeRect(10, 20, 100, 40)
        ghost.validGhostFrame = ghost.frame
        ghost.glassGroup = nil
        ghost.layer?.transform = CATransform3DMakeScale(1.2, 1.2, 1)
        ghost.effectView.alphaValue = 0.5
        pool.release(ghost)
        let reused = pool.acquire(spec)
        XCTAssertTrue(reused === ghost)
        XCTAssertNil(reused.customTint)
        XCTAssertFalse(reused.isHidden)
        XCTAssertFalse(reused.effectView.isHidden)
        XCTAssertEqual(reused.alphaValue, 1)
        XCTAssertEqual(reused.effectView.alphaValue, 1)
        XCTAssertEqual(reused.frame, .zero)
        XCTAssertNil(reused.validGhostFrame)
        XCTAssertEqual(reused.glassGroup, .inputRow)
        XCTAssertNil(reused.onAppearanceChange)
        XCTAssertNil(reused.superview)
        XCTAssertTrue(reused.effectView.superview === reused)
        XCTAssertTrue(CATransform3DIsIdentity(reused.layer?.transform ?? CATransform3DIdentity))
        let before = appearanceCalls
        reused.updateLocalizationAndTheme(theme: presentation)
        XCTAssertEqual(appearanceCalls, before)
    }

    func testReleaseFromContainerTakesBackOnlyPoolGhostsAndTheyReattachCleanly() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        let container = GlassContainerView(frame: NSMakeRect(0, 0, 300, 100), flipped: false, spacing: 5)
        let pooled = pool.acquire(spec)
        let foreign = LiquidGlassView(frame: .zero, cornerRadius: 20)
        container.addGhost(pooled)
        container.addGhost(foreign)
        container.setGhostFrame(pooled, frame: NSMakeRect(5, 5, 100, 40), transition: .immediate)
        pool.release(from: container)
        XCTAssertEqual(container.ghosts.count, 1)
        XCTAssertTrue(container.ghosts.first === foreign)
        XCTAssertEqual(pool.pooledCount, 1)
        XCTAssertNil(pooled.superview)

        let next = GlassContainerView(frame: NSMakeRect(0, 0, 300, 100), flipped: false, spacing: 5)
        let reused = pool.acquire(spec)
        XCTAssertTrue(reused === pooled)
        next.addGhost(reused)
        next.setGhostFrame(reused, frame: NSMakeRect(7, 7, 80, 40), transition: .immediate)
        XCTAssertTrue(reused.superview === next.glassContent)
        XCTAssertEqual(reused.frame, NSMakeRect(7, 7, 80, 40))
        XCTAssertEqual(next.ghosts.count, 1)
    }

    func testCapacityBoundsThePool() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        pool.capacity = 2
        let ghosts = (0..<4).map { _ in pool.acquire(spec) }
        ghosts.forEach { pool.release($0) }
        XCTAssertEqual(pool.pooledCount, 2)
        XCTAssertEqual(pool.droppedCount, 2)
    }

    func testReleaseAfterTheFlagTurnedOffDropsTheGhost() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        let ghost = pool.acquire(spec)
        GlassChromeReuse.isEnabled = false
        pool.release(ghost)
        XCTAssertEqual(pool.pooledCount, 0)
        XCTAssertEqual(pool.droppedCount, 1)
    }

    func testDrainEmptiesThePool() {
        GlassChromeReuse.isEnabled = true
        let pool = GlassGhostPool()
        pool.release(pool.acquire(spec))
        pool.release(pool.acquire(otherSpec))
        XCTAssertEqual(pool.pooledCount, 2)
        pool.drain()
        XCTAssertEqual(pool.pooledCount, 0)
    }
}
