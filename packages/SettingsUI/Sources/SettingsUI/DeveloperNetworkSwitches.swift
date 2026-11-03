import TelegramCore

struct DeveloperNetworkSwitches: Equatable {
    let networkFrameworkTransport: Bool
    let downloadsV2: Bool

    init(settings: NetworkSettings?) {
        self.networkFrameworkTransport = settings?.useNetworkFramework ?? false
        self.downloadsV2 = settings?.useExperimentalDownload ?? true
    }

    static func toggleNetworkFrameworkTransport(_ settings: NetworkSettings) -> NetworkSettings {
        var settings = settings
        settings.useNetworkFramework = !DeveloperNetworkSwitches(settings: settings).networkFrameworkTransport
        return settings
    }

    static func toggleDownloadsV2(_ settings: NetworkSettings) -> NetworkSettings {
        var settings = settings
        settings.useExperimentalDownload = !DeveloperNetworkSwitches(settings: settings).downloadsV2
        return settings
    }
}
