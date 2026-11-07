import Foundation

public struct CrashRecoveryLinks: Equatable {
    public let appStore: URL
    public let website: URL?

    public init(appStore: URL, website: URL?) {
        self.appStore = appStore
        self.website = website
    }

    public static let nanogramDirect = CrashRecoveryLinks(
        appStore: URL(string: "macappstore://apps.apple.com/app/id6829268176")!,
        website: URL(string: "https://github.com/klaipher/nanogram-releases/releases/latest")!
    )

    public static let nanogramAppStore = CrashRecoveryLinks(
        appStore: URL(string: "macappstore://apps.apple.com/app/id6829268176")!,
        website: nil
    )

    public static func resolve(isAppStoreEdition: Bool) -> CrashRecoveryLinks {
        return isAppStoreEdition ? .nanogramAppStore : .nanogramDirect
    }
}
