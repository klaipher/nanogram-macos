import Cocoa
import SwiftSignalKit
public class WindowSaver : NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool {
        return true
    }

    public var rect:NSRect
    let requiredName:String
    var isFullScreen: Bool
    private let disposable:MetaDisposable = MetaDisposable()
    init(name: String, rect:NSRect, isFullScreen: Bool) {
        self.rect = rect
        self.requiredName = name
        self.isFullScreen = isFullScreen
    }
    
    required public init?(coder aDecoder: NSCoder) {
        guard let name = aDecoder.decodeObject(of: NSString.self, forKey: "name") else {
            return nil
        }
        self.rect = aDecoder.decodeRect(forKey: "rect")
        self.requiredName = name as String
        self.isFullScreen = aDecoder.decodeBool(forKey: "isFullScreen")
    }
    
    public func encode(with aCoder: NSCoder) {
        aCoder.encode(rect, forKey: "rect")
        aCoder.encode(self.requiredName, forKey: "name")
        aCoder.encode(self.isFullScreen, forKey: "isFullScreen")
    }
    
    static public func find(for window:Window) -> WindowSaver {
        let user = UserDefaults.standard
        let data = user.object(forKey: "window_saver_".appending(window.name))
        var archiver: WindowSaver?
        if let data = data as? Data {
            archiver = WindowSaver.unarchive(data)
        }
        if archiver == nil {
            archiver = WindowSaver(name: window.name, rect: window.frame, isFullScreen: window.isFullScreen)
        }
        return archiver!
    }
    
    static func unarchive(_ data: Data) -> WindowSaver? {
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: WindowSaver.self, from: data)
    }
    
    func archivedData() -> Data? {
        return try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }
    
    public func save() {
        let single:Signal<Void,Void> = .single(Void()) |> delay(0.5, queue: Queue.mainQueue())
        
        disposable.set(single.start(next: { [weak self] in
            if let strongSelf = self {
                let user = UserDefaults.standard
                if let data = strongSelf.archivedData() {
                    user.set(data, forKey: "window_saver_".appending(strongSelf.requiredName))
                }
                user.synchronize()
            }
        }))
    }
    
    deinit {
        disposable.dispose()
    }
}
