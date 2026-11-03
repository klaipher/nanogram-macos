import AVFoundation

public final class VoiceRecorderInputStream {
    private var converter: VoiceRecorderInputConverter?
    private let packetizer = VoiceRecorderPacketizer()
    public private(set) var converterGeneration: Int = 0

    public init() {
    }

    public func process(_ buffer: AVAudioPCMBuffer, packet: (UnsafePointer<Int16>, Int) -> Void) {
        if let current = self.converter, current.inputFormat != buffer.format {
            current.flush { samples, count in
                self.packetizer.append(samples, count: count, packet: packet)
            }
            self.converter = nil
        }
        if self.converter == nil {
            self.converter = VoiceRecorderInputConverter(inputFormat: buffer.format)
            self.converterGeneration += 1
        }
        guard let converter = self.converter else {
            return
        }
        converter.convert(buffer) { samples, count in
            self.packetizer.append(samples, count: count, packet: packet)
        }
    }

    public func finish(packet: (UnsafePointer<Int16>, Int) -> Void) {
        if let converter = self.converter {
            converter.flush { samples, count in
                self.packetizer.append(samples, count: count, packet: packet)
            }
        }
    }
}
