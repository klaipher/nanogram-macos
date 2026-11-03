import XCTest
@testable import ChatAppIntents

private final class FakeSource: ChatIntentsDataSource {
    var isLocked = false
    var chats: [ChatIntentRecord] = []
    var folders: [ChatIntentFolder] = []
    var opened: [ChatIntentRecord.ID] = []
    var sent: [(String, ChatIntentRecord.ID)] = []
    var recentLimit: Int?

    func recentChats(limit: Int) async -> [ChatIntentRecord] {
        self.recentLimit = limit
        return Array(self.chats.prefix(limit))
    }

    func searchChats(query: String, limit: Int) async -> [ChatIntentRecord] {
        return self.chats.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func chats(ids: [ChatIntentRecord.ID]) async -> [ChatIntentRecord] {
        return self.chats.filter { ids.contains($0.id) }
    }

    func allFolders() async -> [ChatIntentFolder] {
        return self.folders
    }

    func allAccounts() async -> [ChatIntentAccount] {
        return [ChatIntentAccount(id: 1, title: "Work"), ChatIntentAccount(id: 2, title: "Home")]
    }

    func openChat(_ id: ChatIntentRecord.ID) async -> Bool {
        self.opened.append(id)
        return true
    }

    func sendMessage(_ text: String, to id: ChatIntentRecord.ID) async -> Bool {
        self.sent.append((text, id))
        return true
    }
}

final class ChatAppIntentsTests: XCTestCase {
    private func source() -> FakeSource {
        let source = FakeSource()
        source.chats = [
            ChatIntentRecord(id: .init(accountId: 1, peerId: 10), title: "Alice", accountTitle: "Work"),
            ChatIntentRecord(id: .init(accountId: 1, peerId: 11), title: "Bob", accountTitle: "Work"),
            ChatIntentRecord(id: .init(accountId: 2, peerId: 10), title: "Alice (home)", accountTitle: "Home"),
        ]
        source.folders = [ChatIntentFolder(id: .init(accountId: 1, folderId: 3), title: "Family", accountTitle: "Work")]
        return source
    }

    func testIdentifiersRoundTripAcrossAccounts() {
        let id = ChatIntentRecord.ID(accountId: -42, peerId: 1234567890123)
        XCTAssertEqual(ChatIntentRecord.ID(string: id.string), id)
        XCTAssertNil(ChatIntentRecord.ID(string: "garbage"))
        XCTAssertNotEqual(ChatIntentRecord.ID(accountId: 1, peerId: 10).string, ChatIntentRecord.ID(accountId: 2, peerId: 10).string)
    }

    func testQueriesReturnRecentChatsSearchResultsAndEntitiesById() async {
        let source = self.source()
        let logic = ChatIntentsLogic(source: { source })
        let suggested = await logic.suggested()
        XCTAssertEqual(suggested.count, 3)
        XCTAssertEqual(source.recentLimit, ChatIntentsLogic.suggestedLimit)
        let found = await logic.search("ali")
        XCTAssertEqual(found.map { $0.title }, ["Alice", "Alice (home)"])
        let byId = await logic.chats(ids: [ChatIntentRecord.ID(accountId: 2, peerId: 10)])
        XCTAssertEqual(byId.map { $0.accountTitle }, ["Home"])
    }

    func testNothingIsExposedWhilePasscodeLocked() async {
        let source = self.source()
        source.isLocked = true
        let logic = ChatIntentsLogic(source: { source })
        let suggested = await logic.suggested()
        let found = await logic.search("ali")
        let byId = await logic.chats(ids: [ChatIntentRecord.ID(accountId: 1, peerId: 10)])
        let folders = await logic.folders()
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(byId.isEmpty)
        XCTAssertTrue(folders.isEmpty)
        let open = await logic.open(ChatIntentRecord.ID(accountId: 1, peerId: 10))
        XCTAssertEqual(open, .locked)
        let send = await logic.send("hi", to: ChatIntentRecord.ID(accountId: 1, peerId: 10))
        XCTAssertEqual(send, .locked)
        XCTAssertTrue(source.opened.isEmpty)
        XCTAssertTrue(source.sent.isEmpty)
    }

    func testWithoutTheAppNothingHappens() async {
        let logic = ChatIntentsLogic(source: { nil })
        let suggested = await logic.suggested()
        XCTAssertTrue(suggested.isEmpty)
        let open = await logic.open(ChatIntentRecord.ID(accountId: 1, peerId: 10))
        XCTAssertEqual(open, .unavailable)
    }

    func testSendTrimsAndRejectsEmptyText() async {
        let source = self.source()
        let logic = ChatIntentsLogic(source: { source })
        let empty = await logic.send("  \n ", to: ChatIntentRecord.ID(accountId: 1, peerId: 10))
        XCTAssertEqual(empty, .emptyText)
        let sent = await logic.send("  hello ", to: ChatIntentRecord.ID(accountId: 1, peerId: 11))
        XCTAssertEqual(sent, .done)
        XCTAssertEqual(source.sent.first?.0, "hello")
        XCTAssertEqual(source.sent.first?.1, ChatIntentRecord.ID(accountId: 1, peerId: 11))
    }

    func testFocusFilterAllowsEverythingWhenEmpty() {
        let defaults = UserDefaults(suiteName: "ChatAppIntentsTests-\(UUID().uuidString)")!
        let filter = ChatFocusFilterStore(defaults: defaults)
        XCTAssertTrue(filter.allows(accountId: 1, peerId: 10, folderIds: Set()))
    }

    func testFocusFilterByAccountAndFolder() {
        let defaults = UserDefaults(suiteName: "ChatAppIntentsTests-\(UUID().uuidString)")!
        let filter = ChatFocusFilterStore(defaults: defaults)
        filter.update(ChatFocusFilter(accountIds: [1], folders: []))
        XCTAssertTrue(filter.allows(accountId: 1, peerId: 10, folderIds: Set()))
        XCTAssertFalse(filter.allows(accountId: 2, peerId: 10, folderIds: []))

        filter.update(ChatFocusFilter(accountIds: [], folders: [.init(accountId: 1, folderId: 3)]))
        XCTAssertTrue(filter.allows(accountId: 1, peerId: 10, folderIds: [3]))
        XCTAssertFalse(filter.allows(accountId: 1, peerId: 11, folderIds: [4]))
        XCTAssertFalse(filter.allows(accountId: 2, peerId: 10, folderIds: [3]))

        let reloaded = ChatFocusFilterStore(defaults: defaults)
        XCTAssertEqual(reloaded.current, ChatFocusFilter(accountIds: [], folders: [.init(accountId: 1, folderId: 3)]))
        XCTAssertTrue(reloaded.needsFolderMembership(accountId: 1))
        XCTAssertFalse(reloaded.needsFolderMembership(accountId: 2))

        filter.update(ChatFocusFilter(accountIds: [], folders: []))
        XCTAssertTrue(filter.allows(accountId: 2, peerId: 10, folderIds: []))
    }
}

#if canImport(AppIntents)
import AppIntents

@available(macOS 13.0, *)
final class ChatEntityQueryTests: XCTestCase {
    private var source: FakeSource!

    override func setUp() {
        super.setUp()
        self.source = FakeSource()
        self.source.chats = [ChatIntentRecord(id: .init(accountId: 1, peerId: 10), title: "Alice", accountTitle: "Work")]
        ChatIntentsBridge.dataSource = self.source
    }

    override func tearDown() {
        ChatIntentsBridge.dataSource = nil
        super.tearDown()
    }

    func testEntityQueryUsesTheBridge() async throws {
        let query = ChatEntityQuery()
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map { $0.id }, ["1:10"])
        let matched = try await query.entities(matching: "ali")
        XCTAssertEqual(matched.map { $0.title }, ["Alice"])
        let byId = try await query.entities(for: ["1:10", "bad"])
        XCTAssertEqual(byId.map { $0.accountTitle }, ["Work"])
        self.source.isLocked = true
        let locked = try await query.suggestedEntities()
        XCTAssertTrue(locked.isEmpty)
    }

    func testFocusFilterIntentStoresTheChoice() async throws {
        var intent = ChatFocusFilterIntent()
        intent.accounts = [ChatAccountEntity(ChatIntentAccount(id: 2, title: "Home"))]
        intent.folders = [ChatFolderEntity(ChatIntentFolder(id: .init(accountId: 1, folderId: 3), title: "Family", accountTitle: "Work"))]
        _ = try await intent.perform()
        XCTAssertEqual(ChatFocusFilterStore.shared.current, ChatFocusFilter(accountIds: [2], folders: [.init(accountId: 1, folderId: 3)]))
        intent.accounts = nil
        intent.folders = nil
        _ = try await intent.perform()
        XCTAssertTrue(ChatFocusFilterStore.shared.current.isEmpty)
    }
}
#endif
