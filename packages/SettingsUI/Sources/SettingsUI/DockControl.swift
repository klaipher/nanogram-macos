import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit
import InAppSettings
import NanogramAppIcons

public final class DockControl {
    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let update = MetaDisposable()

    public init(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        self.accountManager = accountManager
        observeSelection()
    }

    private func observeSelection() {
        let accountManager = self.accountManager
        let signal = dockSettings(accountManager: accountManager)
        |> map { $0.iconSelected }
        |> distinctUntilChanged
        |> deliverOnMainQueue
        update.set(signal.start(next: { stored in
            let migrated = NanogramAppIcon.migratedStoredName(stored)
            if migrated != stored {
                _ = updateDockSettings(accountManager: accountManager, { settings in
                    return settings.withUpdatedIcon(migrated)
                }).start()
            }
            let icon = NanogramAppIcon.selected(storedName: stored)
            Dock.setCustomAppIcon(path: icon.isDefault ? nil : icon.url?.path)
        }))
    }

    public func clear() {
        update.dispose()
    }

    deinit {
        clear()
    }
}
