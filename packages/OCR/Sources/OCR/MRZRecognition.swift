import Foundation
import CoreGraphics
import Vision

private let td1LineLength = 30
private let td3LineLength = 44
private let mrzQueue = DispatchQueue(label: "org.telegram.mrz-recognition", qos: .userInitiated)

public func normalizedMRZCandidate(_ text: String) -> String? {
    var line = text.uppercased()
        .replacingOccurrences(of: "«", with: "<<")
        .replacingOccurrences(of: "≪", with: "<<")
        .replacingOccurrences(of: "‹", with: "<")
        .replacingOccurrences(of: "＜", with: "<")
    line.removeAll(where: { $0.isWhitespace })
    guard !line.isEmpty, line.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "<" }) else {
        return nil
    }
    let target: Int
    switch line.count {
    case td1LineLength - 2 ... td1LineLength + 1:
        target = td1LineLength
    case td3LineLength - 2 ... td3LineLength + 2:
        target = td3LineLength
    default:
        return nil
    }
    if line.count < target {
        line += String(repeating: "<", count: target - line.count)
    } else if line.count > target {
        let extra = line.suffix(line.count - target)
        guard extra.allSatisfy({ $0 == "<" }) else {
            return nil
        }
        line.removeLast(line.count - target)
    }
    return line
}

private let td1FieldMasks = [
    "AAAAAXXXXXXXXXNXXXXXXXXXXXXXXX",
    "NNNNNNNANNNNNNNAAAXXXXXXXXXXXN",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
]
private let td3FieldMasks = [
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "XXXXXXXXXNAAANNNNNNNANNNNNNNXXXXXXXXXXXXXXNN",
]

private func corrected(_ character: Character, mask: Character) -> Character {
    switch mask {
    case "A":
        switch character {
        case "0": return "O"
        case "1": return "I"
        case "2": return "Z"
        case "5": return "S"
        case "8": return "B"
        default: return character
        }
    case "N":
        switch character {
        case "O", "Q", "D": return "0"
        case "I", "L": return "1"
        case "Z": return "2"
        case "S": return "5"
        case "B": return "8"
        default: return character
        }
    default:
        return character
    }
}

func correctedMRZLines(_ lines: [String]) -> [String] {
    let masks = lines.count == 3 ? td1FieldMasks : td3FieldMasks
    return zip(lines, masks).map { line, mask in
        return String(zip(line, mask).map { corrected($0, mask: $1) })
    }
}

func mrzLines(fromBottomToTop candidates: [String]) -> [String]? {
    let bottom = candidates.prefix(3)
    if bottom.count == 3, bottom.allSatisfy({ $0.count == td1LineLength }) {
        return correctedMRZLines(bottom.reversed())
    }
    let pair = candidates.prefix(2)
    if pair.count == 2, pair.allSatisfy({ $0.count == td3LineLength }) {
        return correctedMRZLines(pair.reversed())
    }
    return nil
}

public func recognizeMRZ(_ image: CGImage) -> String? {
    guard #available(macOS 10.15, *) else {
        return nil
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return nil
    }
    let observations = (request.results ?? []).sorted(by: { $0.boundingBox.minY < $1.boundingBox.minY })
    let candidates = observations.compactMap { observation -> String? in
        return observation.topCandidates(1).first.flatMap { normalizedMRZCandidate($0.string) }
    }
    return mrzLines(fromBottomToTop: candidates)?.joined(separator: "\n")
}

public func recognizeMRZ(_ image: CGImage, completion: @escaping (String?) -> Void) {
    mrzQueue.async {
        let result = recognizeMRZ(image)
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
