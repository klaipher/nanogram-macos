import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
#if SHARE
#else
#endif

private final class InlineFileDataContext {
    public enum LoadState {
        case inited
        case loading
        case loaded
    }
    public var data: TelegramMediaFile?
    public var loadState: LoadState = .inited
    public let subscribers = Bag<(TelegramMediaFile?) -> Void>()
    var fetchDisposable: Disposable?
    
    var isIdle: Bool {
        return self.subscribers.isEmpty && self.loadState != .loading
    }
}

final class IdleEvictingCache<Key: Hashable, Value: AnyObject> {
    private struct Entry {
        let value: Value
        var lastUse: UInt64
    }
    
    private var entries: [Key: Entry] = [:]
    private var useCounter: UInt64 = 0
    private let limit: Int
    private let isIdle: (Value) -> Bool

    init(limit: Int, isIdle: @escaping (Value) -> Bool) {
        self.limit = limit
        self.isIdle = isIdle
    }

    var count: Int {
        return self.entries.count
    }

    subscript(key: Key) -> Value? {
        return self.entries[key]?.value
    }

    func insert(_ value: Value, forKey key: Key) {
        self.useCounter += 1
        self.entries[key] = Entry(value: value, lastUse: self.useCounter)
        if self.entries.count > self.limit {
            self.trim(to: self.limit - self.limit / 4)
        }
    }

    func touch(_ key: Key) {
        guard self.entries[key] != nil else {
            return
        }
        self.useCounter += 1
        self.entries[key]?.lastUse = self.useCounter
    }

    func removeValue(forKey key: Key) {
        self.entries.removeValue(forKey: key)
    }

    func purgeIdle() {
        self.entries = self.entries.filter { !self.isIdle($0.value.value) }
    }

    private func trim(to target: Int) {
        let idle = self.entries.filter { self.isIdle($0.value.value) }.sorted(by: { $0.value.lastUse < $1.value.lastUse })
        let excess = self.entries.count - target
        for (key, _) in idle.prefix(max(0, excess)) {
            self.entries.removeValue(forKey: key)
        }
    }
}

public func isDefaultStatusesPackId(_ reference: StickerPackReference?) -> Bool {
    if case let .id(id, _) = reference {
        if id == 773947703670341676 || id == 2964141614563343 {
            return true
        }
    }
    return reference == .iconStatusEmoji
}

extension StickerPackReference {
    public var id: Int64? {
        switch self {
        case let .id(id, _):
            return id
        default:
            return nil
        }
    }
}

public final class InlineStickersContext {
    
    private struct Key : Hashable {
        public enum Source : Int32 {
            case normal
            case status
        }
        public let fileId: Int64
        public let source: Source
        
    }
    
    private let postbox: Postbox
    private let engine: TelegramEngine
    private let dataContexts = IdleEvictingCache<Key, InlineFileDataContext>(limit: 2048, isIdle: { $0.isIdle })
    
    public init(postbox: Postbox, engine: TelegramEngine) {
        self.postbox = postbox
        self.engine = engine
    }
    
    public func purgeUnused() {
        self.dataContexts.purgeIdle()
    }
    
    public func load(fileId: Int64, checkStatus: Bool = false) -> Signal<TelegramMediaFile?, NoError> {
        return Signal { subscriber in
            
            let key: Key = .init(fileId: fileId, source: checkStatus ? .status : .normal)
            
            let context: InlineFileDataContext
            if let current = self.dataContexts[key] {
                context = current
                self.dataContexts.touch(key)
            } else {
                context = InlineFileDataContext()
                self.dataContexts.insert(context, forKey: key)
            }
            
            if let file = context.data {
                subscriber.putNext(file)
            }

            let index = context.subscribers.add({ data in
                subscriber.putNext(data)
            })
            
            if context.loadState == .inited {
                context.loadState = .loading
                
                let signal = self.engine.stickers.resolveInlineStickers(fileIds: [fileId])
                |> deliverOnMainQueue
                
                context.fetchDisposable = signal.start(next: { file in
                    context.data = file[fileId]
                    context.loadState = .loaded
                    context.fetchDisposable = nil
                    for subscriber in context.subscribers.copyItems() {
                        subscriber(context.data)
                    }
                })
            }

            return ActionDisposable {
                context.subscribers.remove(index)
                if context.subscribers.isEmpty, context.loadState != .loaded {
                    context.loadState = .inited
                    context.fetchDisposable?.dispose()
                    context.fetchDisposable = nil
                    if self.dataContexts[key] === context {
                        self.dataContexts.removeValue(forKey: key)
                    }
                }
            }
        }
    }
    
}
