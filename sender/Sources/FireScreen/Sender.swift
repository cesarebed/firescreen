import CoreMedia
import Foundation
import Network

/// TCP link to the Fire TV receiver. Wire protocol v1: [type u8][length u32 BE][payload].
final class Sender {
    enum PacketType: UInt8 {
        case config = 1
        case frame = 2
        case codec = 3
        /// [capture time µs, i64 BE][access unit]; the receiver paces presentation with it.
        case timedFrame = 4
    }

    var onReady: (() -> Void)?
    var onClosed: ((String) -> Void)?
    var onWaiting: ((String) -> Void)?
    /// Called when a frame had to be dropped; the encoder must restart from a keyframe.
    var onNeedKeyframe: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "firescreen.sender")
    /// Frames handed to the socket but not yet acknowledged as sent. Above this, the
    /// network is the bottleneck and queueing more would only add latency.
    private let maxInFlight = 3
    private var inFlight = 0
    private var dropping = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onClosed?("connection failed: \(error)")
            // Transient: no route yet, or macOS is asking for Local Network access. NWConnection retries.
            case .waiting(let error): self?.onWaiting?("waiting for receiver: \(error)")
            case .cancelled: self?.onClosed?("connection closed")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection.cancel()
    }

    /// playoutDelayMs: how far behind the fastest frame the receiver presents, absorbing jitter.
    /// codec: "avc" or "hevc".
    func sendConfig(width: Int, height: Int, fps: Int, playoutDelayMs: Int, codec: String) {
        send(.config, Data("\(width),\(height),\(fps),\(playoutDelayMs),\(codec)".utf8))
    }

    func sendCodec(_ parameterSets: Data) {
        send(.codec, parameterSets)
    }

    func sendFrame(_ accessUnit: Data, keyframe: Bool, captureTime: CMTime) {
        queue.async { [self] in
            if dropping && !keyframe { Stats.shared.drop(); return }
            if inFlight >= maxInFlight && !keyframe {
                dropping = true
                Stats.shared.drop()
                onNeedKeyframe?()
                return
            }
            dropping = false
            inFlight += 1
            Stats.shared.sent(bytes: accessUnit.count, keyframe: keyframe, inFlight: inFlight)
            var payload = Data(capacity: accessUnit.count + 8)
            var micros = Int64(CMTimeGetSeconds(captureTime) * 1_000_000).bigEndian
            withUnsafeBytes(of: &micros) { payload.append(contentsOf: $0) }
            payload.append(accessUnit)
            write(.timedFrame, payload) { [self] in inFlight -= 1 }
        }
    }

    private func send(_ type: PacketType, _ payload: Data) {
        queue.async { [self] in write(type, payload) {} }
    }

    private func write(_ type: PacketType, _ payload: Data, completion: @escaping () -> Void) {
        var packet = Data(capacity: payload.count + 5)
        packet.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            completion()
            if let error { self?.onClosed?("send failed: \(error)") }
        })
    }
}
