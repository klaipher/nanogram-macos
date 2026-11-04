import Foundation
import XCTest
import BuildConfig

final class NanogramKeyVaultTests: XCTestCase {
    private var directory: URL!
    private var store: NanogramMemoryWrapKeyStore!
    private let payload = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = NanogramMemoryWrapKeyStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var vaultPath: String { directory.appendingPathComponent(".tempkeyVault").path }
    private var legacyPath: String { directory.appendingPathComponent(".tempkey").path }

    private func makeVault(_ store: NanogramWrapKeyStore? = nil) -> NanogramKeyVault {
        return NanogramKeyVault(path: vaultPath, store: store ?? self.store, iterations: 1000)
    }

    func testRoundTripWithoutPasscode() {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let result = vault.open(withPasscode: nil)
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload, payload)
        XCTAssertFalse(vault.hasPasscode())
        XCTAssertEqual(store.keyIds.count, 1)
    }

    func testRoundTripWithPasscodeAndWrongPasscodeIsLocked() {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: "1234"), .OK)
        XCTAssertTrue(vault.hasPasscode())
        XCTAssertEqual(vault.open(withPasscode: "1234").payload, payload)
        XCTAssertEqual(vault.open(withPasscode: "1235").outcome, .locked)
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .locked)
    }

    func testFileHoldsNeitherThePayloadNorTheWrapKey() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let file = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        XCTAssertNil(file.range(of: payload))
        XCTAssertNil(file.range(of: payload.prefix(16)))
        var wrapKey: NSData?
        XCTAssertEqual(store.readWrapKey(withId: store.keyIds[0], data: &wrapKey), .found)
        XCTAssertNil(file.range(of: wrapKey! as Data))
    }

    func testEveryByteOfTheFileIsAuthenticated() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let original = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        for index in stride(from: 0, to: original.count, by: 5) {
            var tampered = original
            tampered[index] ^= 0x01
            try tampered.write(to: URL(fileURLWithPath: vaultPath))
            let result = vault.open(withPasscode: nil)
            XCTAssertNotEqual(result.outcome, .OK, "byte \(index)")
            XCTAssertNil(result.payload)
        }
    }

    func testTruncatedFileIsCorrupt() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let original = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        try original.prefix(20).write(to: URL(fileURLWithPath: vaultPath))
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .corrupt)
    }

    func testUnavailableKeychainChangesNothing() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let before = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        store.unavailable = true
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .keychainUnavailable)
        let resolved = vault.resolve(withPasscode: nil, legacyExists: nil, legacyPayload: nil, removeLegacy: nil, create: true)
        XCTAssertEqual(resolved.outcome, .keychainUnavailable)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vaultPath)), before)
        store.unavailable = false
        XCTAssertEqual(vault.open(withPasscode: nil).payload, payload)
    }

    func testMissingWrapKeyReportsKeyLostAndNeverRegenerates() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        store.deleteWrapKey(withId: store.keyIds[0])
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .keyLost)
        let before = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        let resolved = vault.resolve(withPasscode: nil, legacyExists: nil, legacyPayload: nil, removeLegacy: nil, create: true)
        XCTAssertEqual(resolved.outcome, .keyLost)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vaultPath)), before)
    }

    func testFreshInstallCreatesRandomPayloadOnce() {
        let vault = makeVault()
        let first = vault.resolve(withPasscode: nil, legacyExists: nil, legacyPayload: nil, removeLegacy: nil, create: true)
        XCTAssertEqual(first.outcome, .OK)
        XCTAssertEqual(first.payload?.count, 48)
        XCTAssertNotEqual(first.payload, Data(count: 48))
        let second = makeVault().resolve(withPasscode: nil, legacyExists: nil, legacyPayload: nil, removeLegacy: nil, create: true)
        XCTAssertEqual(second.payload, first.payload)
    }

    func testResolveWithoutCreateReportsMissing() {
        let result = makeVault().resolve(withPasscode: nil, legacyExists: nil, legacyPayload: nil, removeLegacy: nil, create: false)
        XCTAssertEqual(result.outcome, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultPath))
    }

    private func legacyHooks(exists: Bool = true, payload: Data? = nil, removed: @escaping () -> Void) -> (() -> Bool, () -> Data?, () -> Void) {
        let data = payload ?? self.payload
        return ({ exists && FileManager.default.fileExists(atPath: self.legacyPath) }, { FileManager.default.fileExists(atPath: self.legacyPath) ? data : nil }, { try? FileManager.default.removeItem(atPath: self.legacyPath); removed() })
    }

    private func resolveWithLegacy(_ vault: NanogramKeyVault, passcode: String? = nil) -> NanogramKeyVaultResult {
        let hooks = legacyHooks(removed: {})
        return vault.resolve(withPasscode: passcode, legacyExists: hooks.0, legacyPayload: hooks.1, removeLegacy: hooks.2, create: true)
    }

    private func writeLegacy() throws {
        try Data("legacy".utf8).write(to: URL(fileURLWithPath: legacyPath))
    }

    func testMigrationWritesVaultVerifiesAndThenRemovesLegacy() throws {
        try writeLegacy()
        let result = resolveWithLegacy(makeVault())
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload, payload)
        XCTAssertTrue(result.migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(makeVault().open(withPasscode: nil).payload, payload)
        XCTAssertEqual(store.keyIds.count, 1)
    }

    func testInterruptionAtAnyStepIsRecoverableWithoutLosingTheKey() throws {
        let steps = ["beforeWrapKeyStore", "afterWrapKeyStore", "afterFileWrite", "afterOldKeyDelete", "beforeVerify", "beforeLegacyRemoval", "afterLegacyRemoval"]
        for step in steps {
            let localStore = NanogramMemoryWrapKeyStore()
            try? FileManager.default.removeItem(atPath: vaultPath)
            try writeLegacy()
            let crashing = NanogramKeyVault(path: vaultPath, store: localStore, iterations: 1000)
            crashing.faultInjector = { $0 == step }
            let interrupted = resolveWithLegacy(crashing)
            XCTAssertEqual(interrupted.outcome, .interrupted, step)
            XCTAssertNil(interrupted.payload, step)

            let relaunched = NanogramKeyVault(path: vaultPath, store: localStore, iterations: 1000)
            let recovered = resolveWithLegacy(relaunched)
            XCTAssertEqual(recovered.outcome, .OK, step)
            XCTAssertEqual(recovered.payload, payload, step)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath), step)
            XCTAssertEqual(NanogramKeyVault(path: vaultPath, store: localStore, iterations: 1000).open(withPasscode: nil).payload, payload, step)
            XCTAssertLessThanOrEqual(localStore.keyIds.count, 2, step)
        }
    }

    func testFailedWrapKeyStoreKeepsLegacyAndStillReturnsTheKey() throws {
        try writeLegacy()
        store.failWrites = true
        let result = resolveWithLegacy(makeVault())
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload, payload)
        XCTAssertFalse(result.migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultPath))
    }

    func testVaultWithLostWrapKeyFallsBackToStillPresentLegacyAndRewraps() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        store.deleteWrapKey(withId: store.keyIds[0])
        try writeLegacy()
        let result = resolveWithLegacy(vault)
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload, payload)
        XCTAssertEqual(makeVault().open(withPasscode: nil).payload, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
    }

    func testStaleLegacyEqualToVaultIsRemovedButADifferentOneIsKept() throws {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        try writeLegacy()
        XCTAssertEqual(resolveWithLegacy(vault).payload, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))

        try writeLegacy()
        let other = Data(repeating: 9, count: 48)
        let hooks = legacyHooks(payload: other, removed: {})
        let result = vault.resolve(withPasscode: nil, legacyExists: hooks.0, legacyPayload: hooks.1, removeLegacy: hooks.2, create: true)
        XCTAssertEqual(result.payload, payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath))
    }

    func testLegacyThatCannotBeReadWithThePasscodeStaysLocked() throws {
        try writeLegacy()
        let result = makeVault().resolve(withPasscode: "wrong", legacyExists: { true }, legacyPayload: { nil }, removeLegacy: { XCTFail("must not remove") }, create: true)
        XCTAssertEqual(result.outcome, .locked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultPath))
    }

    func testMigrationOfPasscodeProtectedLegacyKeepsThePasscode() throws {
        try writeLegacy()
        let result = resolveWithLegacy(makeVault(), passcode: "4321")
        XCTAssertEqual(result.outcome, .OK)
        let vault = makeVault()
        XCTAssertTrue(vault.hasPasscode())
        XCTAssertEqual(vault.open(withPasscode: "4321").payload, payload)
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .locked)
    }

    func testChangingAndRemovingThePasscodeRewrapsWithAFreshWrapKey() {
        let vault = makeVault()
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        let first = store.keyIds
        XCTAssertEqual(vault.writePayload(payload, passcode: "1111"), .OK)
        XCTAssertEqual(store.keyIds.count, 1)
        XCTAssertNotEqual(store.keyIds, first)
        XCTAssertEqual(vault.open(withPasscode: "1111").payload, payload)
        XCTAssertEqual(vault.open(withPasscode: nil).outcome, .locked)
        XCTAssertEqual(vault.writePayload(payload, passcode: nil), .OK)
        XCTAssertFalse(vault.hasPasscode())
        XCTAssertEqual(vault.open(withPasscode: nil).payload, payload)
        XCTAssertEqual(store.keyIds.count, 1)
    }

    func testInterruptedPasscodeChangeLeavesTheOldFileUsable() {
        for step in ["beforeWrapKeyStore", "afterWrapKeyStore", "afterFileWrite", "afterOldKeyDelete"] {
            let localStore = NanogramMemoryWrapKeyStore()
            try? FileManager.default.removeItem(atPath: vaultPath)
            let vault = NanogramKeyVault(path: vaultPath, store: localStore, iterations: 1000)
            XCTAssertEqual(vault.writePayload(payload, passcode: "1111"), .OK)
            vault.faultInjector = { $0 == step }
            XCTAssertEqual(vault.writePayload(payload, passcode: "2222"), .interrupted)
            let relaunched = NanogramKeyVault(path: vaultPath, store: localStore, iterations: 1000)
            let oldWorks = relaunched.open(withPasscode: "1111").payload == payload
            let newWorks = relaunched.open(withPasscode: "2222").payload == payload
            XCTAssertTrue(oldWorks != newWorks, step)
        }
    }

    func testPlainKeyFileMigration() throws {
        try payload.write(to: URL(fileURLWithPath: legacyPath))
        let vault = makeVault()
        let result = NanogramKeyVault.resolvePlainKeyFile(atPath: legacyPath, vault: vault, create: true)
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(makeVault().open(withPasscode: nil).payload, payload)
    }

    func testPlainKeyFileOfWrongSizeIsNotTreatedAsAKey() throws {
        try Data(repeating: 1, count: 20).write(to: URL(fileURLWithPath: legacyPath))
        let result = NanogramKeyVault.resolvePlainKeyFile(atPath: legacyPath, vault: makeVault(), create: true)
        XCTAssertEqual(result.outcome, .OK)
        XCTAssertEqual(result.payload?.count, 48)
    }

    func testKeychainUnavailableOnFreshInstallReportsIt() {
        store.failWrites = true
        let result = NanogramKeyVault.resolvePlainKeyFile(atPath: legacyPath, vault: makeVault(), create: true)
        XCTAssertEqual(result.outcome, .keychainUnavailable)
        XCTAssertNil(result.payload)
    }

    func testIterationCountIsStoredInTheFileSoItCanBeRaisedLater() {
        let low = NanogramKeyVault(path: vaultPath, store: store, iterations: 1000)
        XCTAssertEqual(low.writePayload(payload, passcode: "1234"), .OK)
        let high = NanogramKeyVault(path: vaultPath, store: store, iterations: 2000)
        XCTAssertEqual(high.open(withPasscode: "1234").payload, payload)
        XCTAssertGreaterThanOrEqual(NanogramKeyVault.defaultIterations(), 600_000)
    }

    private func devicePayload(_ store: NanogramWrapKeyStore?) -> Data {
        return NanogramKeyVault.deviceKeyPayload(inRootPath: directory.path, store: store)
    }

    func testDeviceKeyOnFreshInstallLivesOnlyInTheVault() {
        let first = devicePayload(store)
        XCTAssertEqual(first.count, 48)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(devicePayload(store), first)
    }

    func testDeviceKeyMigratesThePlainFileAndKeepsTheSameKey() throws {
        try payload.write(to: URL(fileURLWithPath: legacyPath))
        XCTAssertEqual(devicePayload(store), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(devicePayload(store), payload)
    }

    func testDeviceKeyUpgradesAThirtyTwoByteKeyKeepingItsPrefix() throws {
        try payload.prefix(32).write(to: URL(fileURLWithPath: legacyPath))
        let result = devicePayload(store)
        XCTAssertEqual(result.prefix(32), payload.prefix(32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
    }

    func testDeviceKeyWithoutAStoreKeepsTheOldPlainFileBehaviour() throws {
        let first = devicePayload(nil)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacyPath)), first)
        XCTAssertEqual(devicePayload(nil), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultPath))
    }

    func testDeviceKeyFallsBackToThePlainFileWhenTheKeychainRefusesAFreshKey() throws {
        store.failWrites = true
        let first = devicePayload(store)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacyPath)), first)
        store.failWrites = false
        XCTAssertEqual(devicePayload(store), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(makeVault().open(withPasscode: nil).payload, first)
    }

    func testDeviceKeyWhileTheKeychainIsLockedIsThrowawayAndPersistsNothing() throws {
        let real = devicePayload(store)
        let vaultBefore = try Data(contentsOf: URL(fileURLWithPath: vaultPath))
        store.unavailable = true
        let during = devicePayload(store)
        XCTAssertNotEqual(during, real)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vaultPath)), vaultBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        store.unavailable = false
        XCTAssertEqual(devicePayload(store), real)
    }

    func testDeviceKeyWithLegacyKeyAndLockedKeychainStillReturnsTheLegacyKey() throws {
        try payload.write(to: URL(fileURLWithPath: legacyPath))
        store.unavailable = true
        XCTAssertEqual(devicePayload(store), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultPath))
    }
}
