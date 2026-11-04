import Foundation
import XCTest
import BuildConfig

final class AppEncryptionParametersTests: XCTestCase {
    private var root: URL!
    private var store: NanogramMemoryWrapKeyStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-encryption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NanogramMemoryWrapKeyStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var legacyFile: URL { root.appendingPathComponent(".tempkeyEncrypted") }
    private var vaultFile: URL { root.appendingPathComponent(".tempkeyVault") }

    private func legacy() -> AppEncryptionParameters {
        return AppEncryptionParameters(path: root.path, wrapKeyStore: nil, iterations: 1000)
    }

    private func wrapped() -> AppEncryptionParameters {
        return AppEncryptionParameters(path: root.path, wrapKeyStore: store, iterations: 1000)
    }

    private func bytes(_ parameters: DeviceSpecificEncryptionParameters?) throws -> Data {
        let parameters = try XCTUnwrap(parameters)
        return parameters.key + parameters.salt
    }

    func testFreshInstallWritesOnlyTheVault() throws {
        let encryption = wrapped()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFile.path))
        XCTAssertFalse(encryption.hasPasscode())
        XCTAssertEqual(try bytes(encryption.decrypt()).count, 48)
        XCTAssertEqual(try bytes(wrapped().decrypt()), try bytes(encryption.decrypt()))
    }

    func testWithoutAStoreTheLegacyFormatIsUnchanged() throws {
        let encryption = legacy()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFile.path))
        XCTAssertNotNil(encryption.decrypt())
    }

    func testLegacyKeyWithoutPasscodeMigratesOnFirstLaunchKeepingTheSameKey() throws {
        let original = try bytes(legacy().decrypt())
        let encryption = wrapped()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFile.path))
        XCTAssertEqual(try bytes(encryption.decrypt()), original)
        XCTAssertFalse(encryption.hasPasscode())
    }

    func testLegacyKeyWithPasscodeStaysLockedUntilUnlockedThenMigrates() throws {
        let old = legacy()
        let original = try bytes(old.decrypt())
        XCTAssertTrue(old.change("1234"))
        let locked = wrapped()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFile.path))
        XCTAssertTrue(locked.hasPasscode())
        XCTAssertNil(locked.decrypt())
        locked.applyPasscode("0000")
        XCTAssertNil(locked.decrypt())
        locked.applyPasscode("1234")
        XCTAssertEqual(try bytes(locked.decrypt()), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let relaunched = wrapped()
        XCTAssertTrue(relaunched.hasPasscode())
        XCTAssertNil(relaunched.decrypt())
        relaunched.applyPasscode("1234")
        XCTAssertEqual(try bytes(relaunched.decrypt()), original)
    }

    func testPasscodeChangeAndRemovalRewrapTheSameKey() throws {
        let encryption = wrapped()
        let original = try bytes(encryption.decrypt())
        XCTAssertTrue(encryption.change("1111"))
        XCTAssertTrue(wrapped().hasPasscode())
        XCTAssertTrue(encryption.change("2222"))
        let reopened = wrapped()
        reopened.applyPasscode("1111")
        XCTAssertNil(reopened.decrypt())
        reopened.applyPasscode("2222")
        XCTAssertEqual(try bytes(reopened.decrypt()), original)
        XCTAssertTrue(reopened.remove())
        XCTAssertFalse(wrapped().hasPasscode())
        XCTAssertEqual(try bytes(wrapped().decrypt()), original)
        XCTAssertEqual(store.keyIds.count, 1)
    }

    func testFailedRewrapKeepsTheOldPasscodeInForce() throws {
        let encryption = wrapped()
        XCTAssertTrue(encryption.change("1111"))
        let original = try bytes(encryption.decrypt())
        store.failWrites = true
        XCTAssertFalse(encryption.change("2222"))
        store.failWrites = false
        let reopened = wrapped()
        reopened.applyPasscode("1111")
        XCTAssertEqual(try bytes(reopened.decrypt()), original)
        XCTAssertEqual(try bytes(encryption.decrypt()), original)
    }

    func testKeychainRefusingMigrationLeavesTheLegacyFileWorking() throws {
        let original = try bytes(legacy().decrypt())
        store.failWrites = true
        let encryption = wrapped()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFile.path))
        XCTAssertEqual(try bytes(encryption.decrypt()), original)
        XCTAssertFalse(encryption.hasPasscode())
        XCTAssertTrue(encryption.change("9999"))
        store.failWrites = false
        let later = wrapped()
        XCTAssertTrue(later.hasPasscode())
        later.applyPasscode("9999")
        XCTAssertEqual(try bytes(later.decrypt()), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testLockedKeychainDoesNotRegenerateOrDeleteAnything() throws {
        let original = try bytes(wrapped().decrypt())
        let before = try Data(contentsOf: vaultFile)
        store.unavailable = true
        let encryption = wrapped()
        XCTAssertNil(encryption.decrypt())
        XCTAssertFalse(encryption.change("1234"))
        XCTAssertEqual(try Data(contentsOf: vaultFile), before)
        store.unavailable = false
        XCTAssertEqual(try bytes(wrapped().decrypt()), original)
    }

    func testCrashAfterTheVaultWasWrittenButBeforeTheLegacyFileWasRemoved() throws {
        let original = try bytes(legacy().decrypt())
        let vault = NanogramKeyVault(path: vaultFile.path, store: store, iterations: 1000)
        XCTAssertEqual(vault.writePayload(original, passcode: nil), .OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        let relaunched = wrapped()
        XCTAssertEqual(try bytes(relaunched.decrypt()), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(try bytes(wrapped().decrypt()), original)
    }

    func testCrashBeforeTheVaultFileWasWrittenLeavesLegacyAuthoritative() throws {
        let original = try bytes(legacy().decrypt())
        XCTAssertTrue(store.writeWrapKey(Data(repeating: 5, count: 32), withId: "orphan"))
        let relaunched = wrapped()
        XCTAssertEqual(try bytes(relaunched.decrypt()), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testVaultWithLostWrapKeyAndNoLegacyIsReportedAsLockedNotRegenerated() throws {
        let encryption = wrapped()
        _ = encryption
        let before = try Data(contentsOf: vaultFile)
        for id in store.keyIds { store.deleteWrapKey(withId: id) }
        let relaunched = wrapped()
        XCTAssertNil(relaunched.decrypt())
        XCTAssertEqual(try Data(contentsOf: vaultFile), before)
    }

    func testProcessWithoutTheKeychainNeverReplacesAnExistingVault() throws {
        let original = try bytes(wrapped().decrypt())
        let before = try Data(contentsOf: vaultFile)
        let fallback = legacy()
        XCTAssertNil(fallback.decrypt())
        XCTAssertFalse(fallback.hasPasscode())
        XCTAssertFalse(fallback.change("1234"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(try Data(contentsOf: vaultFile), before)
        XCTAssertEqual(try bytes(wrapped().decrypt()), original)
    }

    func testProcessWithoutTheKeychainReadsThePasscodeFlagFromTheVault() throws {
        let encryption = wrapped()
        XCTAssertTrue(encryption.change("1234"))
        XCTAssertTrue(legacy().hasPasscode())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testPasscodeChangeAfterADelayedMigrationRewrapsTheVaultOnly() throws {
        let original = try bytes(legacy().decrypt())
        store.failWrites = true
        let encryption = wrapped()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFile.path))
        store.failWrites = false
        XCTAssertTrue(encryption.change("1234"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let relaunched = wrapped()
        XCTAssertTrue(relaunched.hasPasscode())
        XCTAssertNil(relaunched.decrypt())
        relaunched.applyPasscode("1234")
        XCTAssertEqual(try bytes(relaunched.decrypt()), original)
    }
}
