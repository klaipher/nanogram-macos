import Cocoa
import os

public class TransactionHandler: NSObject {

    private let lock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()

    private var handler:(() ->Void)?
    
    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }
    
    public func set(handler:(() ->Void)?) -> Void {
        os_unfair_lock_lock(self.lock)
        self.handler = handler
        os_unfair_lock_unlock(self.lock)
    }
    
    public var isExutable:Bool {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return self.handler != nil
    }
    
    public func execute() -> Bool {
        os_unfair_lock_lock(self.lock)
        let handler = self.handler
        self.handler = nil
        os_unfair_lock_unlock(self.lock)
        guard let handler = handler else {
            return false
        }
        handler()
        return true
    }
    
}
