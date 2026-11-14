import Foundation
import CryptoKit
import os

public enum IsolatedImageOutcome: Equatable, Sendable {
    case decoded(DecodedBitmap)
    case refused
    case unavailable
}

public final class DecoderQuarantine: Sendable {
    private struct State {
        var members: Set<Data> = []
        var order: [Data] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public static func digest(_ content: Data) -> Data {
        return Data(SHA256.hash(data: content))
    }

    public func contains(_ digest: Data) -> Bool {
        return state.withLock { $0.members.contains(digest) }
    }

    public func insert(_ digest: Data) {
        let capacity = self.capacity
        state.withLock { state in
            guard state.members.insert(digest).inserted else {
                return
            }
            state.order.append(digest)
            if state.order.count > capacity {
                state.members.remove(state.order.removeFirst())
            }
        }
    }
}

public struct IsolatedDecoderBackend: Sendable {
    public static let attemptsPerContent = 2

    public let client: DecoderXPCClient
    public let quarantine: DecoderQuarantine

    public init(client: DecoderXPCClient, quarantine: DecoderQuarantine = DecoderQuarantine()) {
        self.client = client
        self.quarantine = quarantine
    }

    private enum Admission {
        case isolate
        case inProcess
        case refuse
    }

    private func admission(digest: Data) -> Admission {
        if quarantine.contains(digest) {
            return .refuse
        }
        if client.isAvailable {
            return .isolate
        }
        return client.hasServiceAnswered ? .refuse : .inProcess
    }

    public func makeAnimation(json: Data, preferTLottie: Bool, fallback: @escaping () -> AnimationRendering?) -> AnimationRendering? {
        let digest = DecoderQuarantine.digest(json)
        switch admission(digest: digest) {
        case .refuse:
            return nil
        case .inProcess:
            return fallback()
        case .isolate:
            break
        }
        var failures = 0
        while failures < Self.attemptsPerContent {
            do {
                let opened = try client.openAnimation(json, preferTLottie: preferTLottie)
                return IsolatedAnimationRenderer(client: client, quarantine: quarantine, json: json, digest: digest, preferTLottie: preferTLottie, opened: opened)
            } catch DecoderError.serviceUnavailable {
                return fallback()
            } catch let error as DecoderError where error.countsAsServiceFailure {
                failures += 1
                if !client.isAvailable {
                    break
                }
            } catch {
                return nil
            }
        }
        if failures >= Self.attemptsPerContent {
            quarantine.insert(digest)
        }
        return nil
    }

    public func decodeImage(_ data: Data, maxPixelSize: Int) -> IsolatedImageOutcome {
        let digest = DecoderQuarantine.digest(data)
        switch admission(digest: digest) {
        case .refuse:
            return .refused
        case .inProcess:
            return .unavailable
        case .isolate:
            break
        }
        var failures = 0
        while failures < Self.attemptsPerContent {
            do {
                return .decoded(try client.decodeImage(data, maxPixelSize: maxPixelSize))
            } catch DecoderError.serviceUnavailable {
                return .unavailable
            } catch let error as DecoderError where error.countsAsServiceFailure {
                failures += 1
                if !client.isAvailable {
                    break
                }
            } catch {
                return .refused
            }
        }
        if failures >= Self.attemptsPerContent {
            quarantine.insert(digest)
        }
        return .refused
    }
}

final class IsolatedAnimationRenderer: AnimationRendering, @unchecked Sendable {
    let startFrame: Int32
    let endFrame: Int32
    let fps: Int32

    private let client: DecoderXPCClient
    private let quarantine: DecoderQuarantine
    private let json: Data
    private let digest: Data
    private let preferTLottie: Bool
    private let renderLock = NSLock()
    private let stateLock = NSLock()
    private var opened: DecoderXPCClient.OpenedAnimation?
    private var colors: [(keyPath: String, color: DecoderColor)] = []
    private var serviceFailures = 0
    private var blank = false

    init(client: DecoderXPCClient, quarantine: DecoderQuarantine, json: Data, digest: Data, preferTLottie: Bool, opened: DecoderXPCClient.OpenedAnimation) {
        self.client = client
        self.quarantine = quarantine
        self.json = json
        self.digest = digest
        self.preferTLottie = preferTLottie
        self.opened = opened
        self.startFrame = opened.startFrame
        self.endFrame = opened.endFrame
        self.fps = opened.fps
    }

    func renderFrame(_ index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
        renderLock.lock()
        defer { renderLock.unlock() }
        if !blank, let frame = renderThroughService(index, width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow)) {
            frame.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(buffer, base, raw.count)
                }
            }
            return
        }
        memset(buffer, 0, Int(height) * Int(bytesPerRow))
    }

    private func renderThroughService(_ index: Int32, width: Int, height: Int, bytesPerRow: Int) -> Data? {
        var reopens = 0
        while !blank {
            guard let current = currentSession() ?? reopen() else {
                return nil
            }
            do {
                let frame = try client.renderFrame(current, index: index, width: width, height: height, bytesPerRow: bytesPerRow)
                serviceFailures = 0
                return frame
            } catch DecoderError.invalidDimensions {
                return nil
            } catch DecoderError.staleSession, DecoderError.unknownSession {
                dropSession()
                reopens += 1
                if reopens > IsolatedDecoderBackend.attemptsPerContent {
                    return nil
                }
            } catch let error as DecoderError where error.countsAsServiceFailure {
                dropSession()
                noteServiceFailure()
            } catch {
                blank = true
            }
        }
        return nil
    }

    private func noteServiceFailure() {
        serviceFailures += 1
        if serviceFailures >= IsolatedDecoderBackend.attemptsPerContent {
            quarantine.insert(digest)
            blank = true
        }
    }

    private func currentSession() -> DecoderXPCClient.OpenedAnimation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return opened
    }

    private func dropSession() {
        stateLock.lock()
        opened = nil
        stateLock.unlock()
    }

    private func reopen() -> DecoderXPCClient.OpenedAnimation? {
        if quarantine.contains(digest) {
            blank = true
            return nil
        }
        guard client.isAvailable else {
            return nil
        }
        let fresh: DecoderXPCClient.OpenedAnimation
        do {
            fresh = try client.openAnimation(json, preferTLottie: preferTLottie)
        } catch let error as DecoderError where error.countsAsServiceFailure {
            noteServiceFailure()
            return nil
        } catch {
            blank = true
            return nil
        }
        stateLock.lock()
        opened = fresh
        let replay = colors
        stateLock.unlock()
        for entry in replay {
            client.setColor(fresh, color: entry.color, keyPath: entry.keyPath)
        }
        return fresh
    }

    func setColor(_ color: DecoderColor, keyPath: String) {
        stateLock.lock()
        colors.removeAll(where: { $0.keyPath == keyPath })
        colors.append((keyPath: keyPath, color: color))
        let current = opened
        stateLock.unlock()
        if let current {
            client.setColor(current, color: color, keyPath: keyPath)
        }
    }

    deinit {
        if let opened {
            client.closeAnimation(opened)
        }
    }
}
