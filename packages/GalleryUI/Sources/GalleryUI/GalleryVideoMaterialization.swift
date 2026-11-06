import Foundation

enum GalleryVideoMaterialization {
    static func shouldMaterialize<Orientation>(orientation: Orientation?, isPlayerCreated: Bool) -> Bool {
        return isPlayerCreated || orientation != nil
    }
}
