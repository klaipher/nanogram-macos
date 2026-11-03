import Foundation
import PasscodeCore

enum WebAppKeychainNames {
    static var secureStorageService: String {
        return self.scoped("TMASecureStorage")
    }

    static var biometryTokenService: String {
        return self.scoped("TelegramMiniApp")
    }

    private static func scoped(_ service: String) -> String {
        if #available(macOS 10.15, *) {
            return PasscodeKeychainScope.service(service)
        }
        return service
    }
}
