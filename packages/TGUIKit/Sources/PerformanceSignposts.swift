import Foundation
import SwiftSignalKit

/// The signposts of both apps live in the shared core (`NanogramSignposts`, `UserSignpost`, `PerformanceSignpostName`
/// in SwiftSignalKit), so iOS and macOS emit identical names with the same API. See docs/profiling.md, "Signposts".
public typealias PerformanceSignposts = NanogramSignposts
