import Foundation

public enum PlistCacheFile {
    public static func read<T>(atPath path: String, decode: (Data) -> T?) -> T? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return nil
        }
        if let value = decode(data) {
            return value
        }
        guard let unwrapped = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSData.self, from: data) else {
            return nil
        }
        return decode(unwrapped as Data)
    }

    @discardableResult
    public static func write(_ data: Data, toPath path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
