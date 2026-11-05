import Foundation
import XCTest
import BuildConfig

/// The database key is the `.tempkeyEncrypted` file beside the database, as upstream: AES with the default key, or
/// with the passcode. No keychain is involved, so a restored backup or a migrated account folder opens anywhere.
final class AppEncryptionParametersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-encryption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var keyFile: URL { root.appendingPathComponent(".tempkeyEncrypted") }
    private var plainFile: URL { root.appendingPathComponent(".tempkey") }

    private func bytes(_ parameters: DeviceSpecificEncryptionParameters?) throws -> Data {
        let parameters = try XCTUnwrap(parameters)
        return parameters.key + parameters.salt
    }

    func testFreshInstallWritesOnlyTheKeyFile() throws {
        let encryption = AppEncryptionParameters(path: root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".tempkeyEncrypted"])
        XCTAssertFalse(encryption.hasPasscode())
        XCTAssertEqual(try bytes(encryption.decrypt()).count, 48)
    }

    func testTheKeyIsStableAcrossLaunches() throws {
        let first = try bytes(AppEncryptionParameters(path: root.path).decrypt())
        XCTAssertEqual(try bytes(AppEncryptionParameters(path: root.path).decrypt()), first)
    }

    func testPasscodeChangeAndRemovalKeepTheSameKey() throws {
        let encryption = AppEncryptionParameters(path: root.path)
        let original = try bytes(encryption.decrypt())
        encryption.change("1234")
        let locked = AppEncryptionParameters(path: root.path)
        XCTAssertTrue(locked.hasPasscode())
        XCTAssertNil(locked.decrypt())
        locked.applyPasscode("0000")
        XCTAssertNil(locked.decrypt())
        locked.applyPasscode("1234")
        XCTAssertEqual(try bytes(locked.decrypt()), original)
        locked.remove()
        XCTAssertFalse(AppEncryptionParameters(path: root.path).hasPasscode())
        XCTAssertEqual(try bytes(AppEncryptionParameters(path: root.path).decrypt()), original)
    }

    func testOpeningALockedKeyNeverReplacesIt() throws {
        let encryption = AppEncryptionParameters(path: root.path)
        encryption.change("1234")
        let before = try Data(contentsOf: keyFile)
        let locked = AppEncryptionParameters(path: root.path)
        XCTAssertNil(locked.decrypt())
        locked.applyPasscode("wrong")
        XCTAssertNil(locked.decrypt())
        XCTAssertEqual(try Data(contentsOf: keyFile), before)
    }

    func testAPlainTempkeyIsUpgradedKeepingItsKey() throws {
        let plain = Data((0..<48).map { UInt8($0) })
        try plain.write(to: plainFile)
        let encryption = AppEncryptionParameters(path: root.path)
        XCTAssertEqual(try bytes(encryption.decrypt()), plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFile.path))
    }

    func testAForeignVaultFileIsIgnoredAndLeftAlone() throws {
        let vault = root.appendingPathComponent(".tempkeyVault")
        let content = Data(repeating: 7, count: 100)
        try content.write(to: vault)
        let encryption = AppEncryptionParameters(path: root.path)
        XCTAssertNotNil(encryption.decrypt())
        XCTAssertEqual(try Data(contentsOf: vault), content)
    }
}
