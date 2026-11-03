public import Foundation

// One video frame of a WebM sticker: the VP9 colour packet and, for stickers with
// transparency, the VP9 alpha packet from the block's BlockAdditional.
public struct WebMStickerFrame: Sendable, Equatable {
    public let timestamp: Int64
    public let color: Data
    public let alpha: Data?
}

public struct WebMSticker: Sendable {
    public let width: Int
    public let height: Int
    // Nanoseconds per frame from the track's DefaultDuration; FFmpeg takes the frame rate from it.
    public let defaultFrameDuration: Int64?
    // Segment duration in seconds, when the file has one.
    public let duration: Double?
    // Frame timestamps are in units of this many nanoseconds.
    public let timestampScale: Int64
    public let frames: [WebMStickerFrame]

    public var hasAlpha: Bool {
        return self.frames.contains(where: { $0.alpha != nil })
    }

    // Frames per second as FFmpeg reports it for a track with DefaultDuration.
    public var frameRate: Double? {
        guard let defaultFrameDuration = self.defaultFrameDuration, defaultFrameDuration > 0 else {
            return nil
        }
        return 1_000_000_000.0 / Double(defaultFrameDuration)
    }
}

// A small Matroska/WebM reader for sticker files: one VP9 video track, no lacing,
// no content encoding. Anything else returns nil, and the caller uses FFmpeg instead.
// Every read is bounds-checked; the input is untrusted.
public enum WebMStickerDemuxer {
    public static let maxFrameCount = 2000
    public static let maxDimension = 4096

    private enum ID {
        static let ebml: UInt64 = 0x1A45DFA3
        static let docType: UInt64 = 0x4282
        static let segment: UInt64 = 0x18538067
        static let info: UInt64 = 0x1549A966
        static let timestampScale: UInt64 = 0x2AD7B1
        static let duration: UInt64 = 0x4489
        static let tracks: UInt64 = 0x1654AE6B
        static let trackEntry: UInt64 = 0xAE
        static let trackNumber: UInt64 = 0xD7
        static let trackType: UInt64 = 0x83
        static let codecID: UInt64 = 0x86
        static let defaultDuration: UInt64 = 0x23E383
        static let video: UInt64 = 0xE0
        static let pixelWidth: UInt64 = 0xB0
        static let pixelHeight: UInt64 = 0xBA
        static let contentEncodings: UInt64 = 0x6D80
        static let cluster: UInt64 = 0x1F43B675
        static let clusterTimestamp: UInt64 = 0xE7
        static let simpleBlock: UInt64 = 0xA3
        static let blockGroup: UInt64 = 0xA0
        static let block: UInt64 = 0xA1
        static let blockAdditions: UInt64 = 0x75A1
        static let blockMore: UInt64 = 0xA6
        static let blockAddID: UInt64 = 0xEE
        static let blockAdditional: UInt64 = 0xA5
    }

    // Top-level elements that end a Cluster of unknown size.
    private static let segmentChildren: Set<UInt64> = [
        ID.cluster, ID.info, ID.tracks, 0x114D9B74, 0x1C53BB6B, 0x1254C367, 0x1043A770, 0x1941A469
    ]

    private struct Reader {
        let bytes: [UInt8]

        // A variable-length integer at `offset`: its value and length. The marker bit is kept for IDs.
        func vint(at offset: Int, keepMarker: Bool) -> (value: UInt64, length: Int, isUnknown: Bool)? {
            guard offset >= 0, offset < self.bytes.count else {
                return nil
            }
            let first = self.bytes[offset]
            if first == 0 {
                return nil
            }
            let length = first.leadingZeroBitCount + 1
            guard length <= 8, offset <= self.bytes.count - length else {
                return nil
            }
            let markerMask: UInt8 = 0x80 >> (length - 1)
            var value = UInt64(truncatingIfNeeded: keepMarker ? first : (first & ~markerMask))
            for i in 1 ..< length {
                value = (value << 8) | UInt64(truncatingIfNeeded: self.bytes[offset + i])
            }
            // A size with all value bits set means "unknown".
            let allOnes: UInt64 = (1 << UInt64(truncatingIfNeeded: 7 * length)) - 1
            return (value, length, !keepMarker && value == allOnes)
        }

        func unsigned(_ range: Range<Int>) -> UInt64? {
            guard range.count >= 1, range.count <= 8 else {
                return range.isEmpty ? 0 : nil
            }
            var value: UInt64 = 0
            for i in range {
                value = (value << 8) | UInt64(truncatingIfNeeded: self.bytes[i])
            }
            return value
        }

        func float(_ range: Range<Int>) -> Double? {
            if range.count == 4, let bits = self.unsigned(range) {
                return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
            } else if range.count == 8, let bits = self.unsigned(range) {
                return Double(bitPattern: bits)
            } else {
                return nil
            }
        }
    }

    private struct Element {
        let id: UInt64
        let dataStart: Int
        let dataEnd: Int
        let hasUnknownSize: Bool
    }

    // The element header at `offset`, with its data clipped to `end` when the size is unknown.
    private static func element(_ reader: Reader, at offset: Int, end: Int) -> Element? {
        guard let id = reader.vint(at: offset, keepMarker: true), id.length <= 4 else {
            return nil
        }
        guard let size = reader.vint(at: offset + id.length, keepMarker: false) else {
            return nil
        }
        let dataStart = offset + id.length + size.length
        guard dataStart <= end else {
            return nil
        }
        if size.isUnknown {
            return Element(id: id.value, dataStart: dataStart, dataEnd: end, hasUnknownSize: true)
        }
        // end >= dataStart was checked above.
        guard size.value <= UInt64(truncatingIfNeeded: end - dataStart) else {
            return nil
        }
        return Element(id: id.value, dataStart: dataStart, dataEnd: dataStart + Int(size.value), hasUnknownSize: false)
    }

    private struct Track {
        var number: UInt64?
        var type: UInt64?
        var codecID: String?
        var defaultDuration: Int64?
        var width: Int?
        var height: Int?
        var hasContentEncoding = false
    }

    private final class State {
        var timestampScale: Int64 = 1_000_000
        var duration: Double?
        var tracks: [Track] = []
        var videoTrack: Track?
        var frames: [WebMStickerFrame] = []
        var failed = false
    }

    public static func parse(_ data: Data) -> WebMSticker? {
        let reader = Reader(bytes: [UInt8](data))
        let end = reader.bytes.count
        let state = State()

        guard let header = element(reader, at: 0, end: end), header.id == ID.ebml, !header.hasUnknownSize else {
            return nil
        }
        var docTypeIsSupported = false
        var offset = header.dataStart
        while offset < header.dataEnd {
            guard let child = element(reader, at: offset, end: header.dataEnd) else {
                return nil
            }
            if child.id == ID.docType {
                let docType = String(decoding: reader.bytes[child.dataStart ..< child.dataEnd], as: UTF8.self)
                docTypeIsSupported = docType == "webm" || docType == "matroska"
            }
            offset = child.dataEnd
        }
        guard docTypeIsSupported else {
            return nil
        }

        offset = header.dataEnd
        var foundSegment = false
        while offset < end {
            guard let segment = element(reader, at: offset, end: end) else {
                break
            }
            if segment.id == ID.segment {
                foundSegment = true
                self.parseSegment(reader, segment, state)
                break
            }
            offset = segment.dataEnd
        }
        guard foundSegment, !state.failed, let track = state.videoTrack, let width = track.width, let height = track.height else {
            return nil
        }
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension, !state.frames.isEmpty else {
            return nil
        }
        // The first frame must be a key frame for a decoder to start from it.
        guard let first = state.frames.first, isVP9KeyFrame(first.color) else {
            return nil
        }
        return WebMSticker(width: width, height: height, defaultFrameDuration: track.defaultDuration, duration: state.duration, timestampScale: state.timestampScale, frames: state.frames)
    }

    private static func parseSegment(_ reader: Reader, _ segment: Element, _ state: State) {
        var offset = segment.dataStart
        while offset < segment.dataEnd, !state.failed {
            guard let child = element(reader, at: offset, end: segment.dataEnd) else {
                // A truncated tail ends the segment; what was read so far stays.
                return
            }
            switch child.id {
            case ID.info:
                self.parseInfo(reader, child, state)
                offset = child.dataEnd
            case ID.tracks:
                self.parseTracks(reader, child, state)
                offset = child.dataEnd
            case ID.cluster:
                offset = self.parseCluster(reader, child, state)
            default:
                if child.hasUnknownSize {
                    return
                }
                offset = child.dataEnd
            }
        }
    }

    private static func parseInfo(_ reader: Reader, _ info: Element, _ state: State) {
        var offset = info.dataStart
        while offset < info.dataEnd {
            guard let child = element(reader, at: offset, end: info.dataEnd), !child.hasUnknownSize else {
                state.failed = true
                return
            }
            if child.id == ID.timestampScale {
                guard let value = reader.unsigned(child.dataStart ..< child.dataEnd), value > 0, value <= 1_000_000_000 else {
                    state.failed = true
                    return
                }
                state.timestampScale = Int64(value)
            } else if child.id == ID.duration {
                state.duration = reader.float(child.dataStart ..< child.dataEnd)
            }
            offset = child.dataEnd
        }
        if let duration = state.duration {
            let seconds = duration * Double(state.timestampScale) / 1_000_000_000.0
            state.duration = seconds.isFinite && seconds >= 0.0 ? seconds : nil
        }
    }

    private static func parseTracks(_ reader: Reader, _ tracks: Element, _ state: State) {
        var offset = tracks.dataStart
        while offset < tracks.dataEnd {
            guard let entry = element(reader, at: offset, end: tracks.dataEnd), !entry.hasUnknownSize else {
                state.failed = true
                return
            }
            if entry.id == ID.trackEntry {
                guard let track = self.parseTrackEntry(reader, entry) else {
                    state.failed = true
                    return
                }
                state.tracks.append(track)
                if track.type == 1 {
                    // Exactly one VP9 video track without content encoding.
                    if state.videoTrack != nil || track.codecID != "V_VP9" || track.hasContentEncoding || track.number == nil {
                        state.failed = true
                        return
                    }
                    state.videoTrack = track
                }
            }
            offset = entry.dataEnd
        }
    }

    private static func parseTrackEntry(_ reader: Reader, _ entry: Element) -> Track? {
        var track = Track()
        var offset = entry.dataStart
        while offset < entry.dataEnd {
            guard let child = element(reader, at: offset, end: entry.dataEnd), !child.hasUnknownSize else {
                return nil
            }
            let range = child.dataStart ..< child.dataEnd
            switch child.id {
            case ID.trackNumber:
                track.number = reader.unsigned(range)
            case ID.trackType:
                track.type = reader.unsigned(range)
            case ID.codecID:
                track.codecID = String(decoding: reader.bytes[range], as: UTF8.self)
            case ID.defaultDuration:
                if let value = reader.unsigned(range), value > 0, value <= UInt64(truncatingIfNeeded: Int64.max) {
                    track.defaultDuration = Int64(value)
                }
            case ID.contentEncodings:
                track.hasContentEncoding = true
            case ID.video:
                var videoOffset = child.dataStart
                while videoOffset < child.dataEnd {
                    guard let video = element(reader, at: videoOffset, end: child.dataEnd), !video.hasUnknownSize else {
                        return nil
                    }
                    let videoRange = video.dataStart ..< video.dataEnd
                    if video.id == ID.pixelWidth, let value = reader.unsigned(videoRange), value <= UInt64(truncatingIfNeeded: maxDimension) {
                        track.width = Int(value)
                    } else if video.id == ID.pixelHeight, let value = reader.unsigned(videoRange), value <= UInt64(truncatingIfNeeded: maxDimension) {
                        track.height = Int(value)
                    }
                    videoOffset = video.dataEnd
                }
            default:
                break
            }
            offset = child.dataEnd
        }
        return track
    }

    // Returns where parsing continues: the end of the cluster, or for a cluster of unknown
    // size the next top-level element.
    private static func parseCluster(_ reader: Reader, _ cluster: Element, _ state: State) -> Int {
        var clusterTimestamp: Int64 = 0
        var offset = cluster.dataStart
        while offset < cluster.dataEnd, !state.failed {
            guard let child = element(reader, at: offset, end: cluster.dataEnd) else {
                return cluster.dataEnd
            }
            if cluster.hasUnknownSize && self.segmentChildren.contains(child.id) {
                return offset
            }
            switch child.id {
            case ID.clusterTimestamp:
                guard let value = reader.unsigned(child.dataStart ..< child.dataEnd), value <= UInt64(truncatingIfNeeded: Int32.max) else {
                    state.failed = true
                    return cluster.dataEnd
                }
                clusterTimestamp = Int64(value)
            case ID.simpleBlock:
                self.addBlock(reader, child.dataStart ..< child.dataEnd, alpha: nil, clusterTimestamp: clusterTimestamp, state)
            case ID.blockGroup:
                self.parseBlockGroup(reader, child, clusterTimestamp: clusterTimestamp, state)
            default:
                if child.hasUnknownSize {
                    state.failed = true
                    return cluster.dataEnd
                }
            }
            offset = child.dataEnd
        }
        return cluster.dataEnd
    }

    private static func parseBlockGroup(_ reader: Reader, _ group: Element, clusterTimestamp: Int64, _ state: State) {
        var block: Range<Int>?
        var alpha: Data?
        var offset = group.dataStart
        while offset < group.dataEnd {
            guard let child = element(reader, at: offset, end: group.dataEnd), !child.hasUnknownSize else {
                state.failed = true
                return
            }
            if child.id == ID.block {
                block = child.dataStart ..< child.dataEnd
            } else if child.id == ID.blockAdditions {
                var moreOffset = child.dataStart
                while moreOffset < child.dataEnd {
                    guard let more = element(reader, at: moreOffset, end: child.dataEnd), !more.hasUnknownSize else {
                        state.failed = true
                        return
                    }
                    if more.id == ID.blockMore {
                        var addID: UInt64 = 1
                        var additional: Range<Int>?
                        var itemOffset = more.dataStart
                        while itemOffset < more.dataEnd {
                            guard let item = element(reader, at: itemOffset, end: more.dataEnd), !item.hasUnknownSize else {
                                state.failed = true
                                return
                            }
                            if item.id == ID.blockAddID, let value = reader.unsigned(item.dataStart ..< item.dataEnd) {
                                addID = value
                            } else if item.id == ID.blockAdditional {
                                additional = item.dataStart ..< item.dataEnd
                            }
                            itemOffset = item.dataEnd
                        }
                        // BlockAddID 1 carries the alpha channel in WebM.
                        if addID == 1, let additional, !additional.isEmpty {
                            alpha = Data(reader.bytes[additional])
                        }
                    }
                    moreOffset = more.dataEnd
                }
            }
            offset = child.dataEnd
        }
        if let block {
            self.addBlock(reader, block, alpha: alpha, clusterTimestamp: clusterTimestamp, state)
        }
    }

    private static func addBlock(_ reader: Reader, _ range: Range<Int>, alpha: Data?, clusterTimestamp: Int64, _ state: State) {
        guard let videoTrack = state.videoTrack, let videoTrackNumber = videoTrack.number else {
            // Blocks before the track list cannot be assigned to a track.
            state.failed = true
            return
        }
        guard let trackNumber = reader.vint(at: range.lowerBound, keepMarker: false), !trackNumber.isUnknown else {
            state.failed = true
            return
        }
        let headerEnd = range.lowerBound + trackNumber.length + 3
        guard headerEnd <= range.upperBound else {
            state.failed = true
            return
        }
        if trackNumber.value != videoTrackNumber {
            return
        }
        let relative = Int16(bitPattern: UInt16(truncatingIfNeeded: reader.bytes[range.lowerBound + trackNumber.length]) << 8 | UInt16(truncatingIfNeeded: reader.bytes[range.lowerBound + trackNumber.length + 1]))
        let flags = reader.bytes[range.lowerBound + trackNumber.length + 2]
        // Laced blocks hold several frames; stickers do not use them.
        if flags & 0x06 != 0 {
            state.failed = true
            return
        }
        guard headerEnd < range.upperBound, state.frames.count < maxFrameCount else {
            state.failed = true
            return
        }
        state.frames.append(WebMStickerFrame(timestamp: clusterTimestamp + Int64(relative), color: Data(reader.bytes[headerEnd ..< range.upperBound]), alpha: alpha))
    }

    // VP9 uncompressed header: frame_marker 2, profile, show_existing_frame, frame_type 0 = key frame.
    public static func isVP9KeyFrame(_ data: Data) -> Bool {
        guard let first = data.first else {
            return false
        }
        if first >> 6 != 0x2 {
            return false
        }
        let profile = Int((first >> 5) & 1) | (Int((first >> 4) & 1) << 1)
        var bit = 4
        if profile == 3 {
            bit -= 1
        }
        // show_existing_frame
        if (first >> (bit - 1)) & 1 == 1 {
            return false
        }
        let frameType = (first >> (bit - 2)) & 1
        return frameType == 0
    }
}
