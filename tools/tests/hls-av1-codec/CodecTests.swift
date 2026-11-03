import Foundation

__SOURCE__

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition {
        failures += 1
    }
}

func choose(_ codecs: [String], hardwareAv1: Bool) -> String? {
    var current: String?
    for codec in codecs {
        guard HLSCodecSelection.isSupported(videoCodec: codec, isHardwareAv1Supported: hardwareAv1) else {
            continue
        }
        if HLSCodecSelection.replaces(currentCodec: current, with: codec) {
            current = codec
        }
    }
    return current
}

expect(HLSCodecSelection.isSupported(videoCodec: "h264", isHardwareAv1Supported: false), "h264 is always supported")
expect(HLSCodecSelection.isSupported(videoCodec: "hevc", isHardwareAv1Supported: false), "hevc is always supported")
expect(!HLSCodecSelection.isSupported(videoCodec: "av1", isHardwareAv1Supported: false), "av1 is not picked without hardware decode")
expect(!HLSCodecSelection.isSupported(videoCodec: "av01", isHardwareAv1Supported: false), "av01 is not picked without hardware decode")
expect(HLSCodecSelection.isSupported(videoCodec: "av1", isHardwareAv1Supported: true), "av1 is picked with hardware decode")
expect(HLSCodecSelection.isSupported(videoCodec: "av01", isHardwareAv1Supported: true), "av01 is picked with hardware decode")
expect(!HLSCodecSelection.isSupported(videoCodec: "vp9", isHardwareAv1Supported: true), "vp9 is never picked")
expect(choose(["h264", "av1"], hardwareAv1: true) == "av1", "av1 wins over h264 at the same quality (h264 first)")
expect(choose(["av1", "h264"], hardwareAv1: true) == "av1", "av1 wins over h264 at the same quality (av1 first)")
expect(choose(["h264", "av1"], hardwareAv1: false) == "h264", "h264 stays without hardware decode")
expect(choose(["av1"], hardwareAv1: false) == nil, "an av1-only quality is dropped without hardware decode")
print("\(failures) failed")
exit(failures == 0 ? 0 : 1)
