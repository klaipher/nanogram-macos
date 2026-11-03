import Foundation
#if canImport(AppIntents)
import AppIntents

public struct ChatAppIntentsPackage: AppIntentsPackage {
}

public struct ChatEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    public static let defaultQuery = ChatEntityQuery()

    public var id: String
    public var title: String
    public var accountTitle: String

    public init(_ record: ChatIntentRecord) {
        self.id = record.id.string
        self.title = record.title
        self.accountTitle = record.accountTitle
    }

    public var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(title: "\(self.title)", subtitle: "\(self.accountTitle)")
    }
}

public struct ChatEntityQuery: EntityStringQuery {
    public init() {
    }

    public func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        return await ChatIntentsBridge.logic.chats(ids: identifiers.compactMap(ChatIntentRecord.ID.init(string:))).map(ChatEntity.init)
    }

    public func entities(matching string: String) async throws -> [ChatEntity] {
        return await ChatIntentsBridge.logic.search(string).map(ChatEntity.init)
    }

    public func suggestedEntities() async throws -> [ChatEntity] {
        return await ChatIntentsBridge.logic.suggested().map(ChatEntity.init)
    }
}

public struct ChatAccountEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    public static let defaultQuery = ChatAccountEntityQuery()

    public var id: String
    public var title: String

    public init(_ account: ChatIntentAccount) {
        self.id = "\(account.id)"
        self.title = account.title
    }

    public var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(title: "\(self.title)")
    }
}

public struct ChatAccountEntityQuery: EntityQuery {
    public init() {
    }

    public func entities(for identifiers: [ChatAccountEntity.ID]) async throws -> [ChatAccountEntity] {
        return await ChatIntentsBridge.logic.accounts().filter { identifiers.contains("\($0.id)") }.map(ChatAccountEntity.init)
    }

    public func suggestedEntities() async throws -> [ChatAccountEntity] {
        return await ChatIntentsBridge.logic.accounts().map(ChatAccountEntity.init)
    }
}

public struct ChatFolderEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    public static let defaultQuery = ChatFolderEntityQuery()

    public var id: String
    public var title: String
    public var accountTitle: String

    public init(_ folder: ChatIntentFolder) {
        self.id = folder.id.string
        self.title = folder.title
        self.accountTitle = folder.accountTitle
    }

    public var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(title: "\(self.title)", subtitle: "\(self.accountTitle)")
    }
}

public struct ChatFolderEntityQuery: EntityQuery {
    public init() {
    }

    public func entities(for identifiers: [ChatFolderEntity.ID]) async throws -> [ChatFolderEntity] {
        return await ChatIntentsBridge.logic.folders().filter { identifiers.contains($0.id.string) }.map(ChatFolderEntity.init)
    }

    public func suggestedEntities() async throws -> [ChatFolderEntity] {
        return await ChatIntentsBridge.logic.folders().map(ChatFolderEntity.init)
    }
}

public enum ChatIntentError: Error, CustomLocalizedStringResourceConvertible {
    case locked
    case unavailable
    case emptyText
    case failed

    init?(_ result: ChatIntentResult) {
        switch result {
        case .done:
            return nil
        case .locked:
            self = .locked
        case .unavailable:
            self = .unavailable
        case .emptyText:
            self = .emptyText
        case .failed:
            self = .failed
        }
    }

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .locked:
            return "Nanogram is locked with a passcode."
        case .unavailable:
            return "Nanogram is not ready yet."
        case .emptyText:
            return "The message is empty."
        case .failed:
            return "The chat could not be found."
        }
    }
}

public struct OpenChatIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Chat"
    public static let description = IntentDescription("Opens a Telegram chat.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Chat")
    public var chat: ChatEntity

    public init() {
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let id = ChatIntentRecord.ID(string: self.chat.id) else {
            throw ChatIntentError.failed
        }
        if let error = ChatIntentError(await ChatIntentsBridge.logic.open(id)) {
            throw error
        }
        return .result()
    }
}

public struct SendMessageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Send Message"
    public static let description = IntentDescription("Sends a text message to a Telegram chat after you confirm it.")

    @Parameter(title: "Chat")
    public var chat: ChatEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String

    public init() {
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$chat)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = ChatIntentRecord.ID(string: self.chat.id) else {
            throw ChatIntentError.failed
        }
        try await self.requestConfirmation(actionName: .send, dialog: "Send “\(self.text)” to \(self.chat.title)?")
        if let error = ChatIntentError(await ChatIntentsBridge.logic.send(self.text, to: id)) {
            throw error
        }
        return .result(dialog: "Sent to \(self.chat.title).")
    }
}

public struct ChatFocusFilterIntent: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "Set Nanogram Notifications"
    public static let description: IntentDescription? = IntentDescription("Only notify about chats in the chosen accounts or folders while this Focus is on.")

    @Parameter(title: "Accounts")
    public var accounts: [ChatAccountEntity]?

    @Parameter(title: "Folders")
    public var folders: [ChatFolderEntity]?

    public init() {
    }

    public var displayRepresentation: DisplayRepresentation {
        let names = (self.accounts ?? []).map { $0.title } + (self.folders ?? []).map { $0.title }
        if names.isEmpty {
            return DisplayRepresentation(title: "All chats")
        }
        return DisplayRepresentation(title: "\(names.joined(separator: ", "))")
    }

    public func perform() async throws -> some IntentResult {
        let accountIds = (self.accounts ?? []).compactMap { Int64($0.id) }
        let folders = (self.folders ?? []).compactMap { ChatIntentFolder.ID(string: $0.id) }
        ChatFocusFilterStore.shared.update(ChatFocusFilter(accountIds: accountIds, folders: folders))
        return .result()
    }
}

#endif
