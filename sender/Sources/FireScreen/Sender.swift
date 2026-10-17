import CoreMedia
import FireScreenCore
import Foundation
import Network

/// TCP link to the Fire TV receiver (see Wire for the protocol).
final class Sender {
    var onReady: (() -> Void)?
    var onHello: ((ReceiverHello) -> Void)?
    /// Terminal: the connection failed or closed.
    var onClosed: ((String) -> Void)?
    /// Transient: no route yet, or macOS is asking for Local Network access. NWConnection retries.
    var onWaiting: ((String) -> Void)?
    /// Called when a frame had to be dropped; the encoder must restart from a keyframe.
    var onNeedKeyframe: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "firescreen.sender")
    private var reader = PacketReader()
    /// Frames handed to the socket but not yet acknowledged as sent. Above this, the
    /// network is the bottleneck and queueing more would only add latency.
    private let maxInFlight = 3
    private var inFlight = 0
    private var dropping = false
    private var closed = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .waiting(let error): self.onWaiting?("waiting for receiver: \(error)")
            case .failed(let error): self.close("connection failed: \(error)")
            case .cancelled: self.close("connection closed")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in closed = true }
        connection.cancel()
    }

    private func close(_ reason: String) {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            onClosed?(reason)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                for packet in self.reader.feed(data) where packet.type == Wire.ReceiverPacketType.hello.rawValue {
                    if let hello = ReceiverHello(payload: packet.payload) { self.onHello?(hello) }
                }
            }
            if done || error != nil {
                self.close(error.map { "receiver closed the connection: \($0)" } ?? "receiver closed the connection")
                return
            }
            self.receive()
        }
    }

    func sendConfig(_ options: StreamOptions) {
        send(.config, Wire.config(width: options.width, height: options.height, fps: options.fps,
                                  playoutDelayMs: options.playoutDelayMs, hevc: options.hevc))
    }

    func sendAudioConfig(sampleRate: Int, channels: Int) {
        send(.audioConfig, Data("\(sampleRate),\(channels)".utf8))
    }

    /// persist: store on the TV as its calibration, otherwise apply for this session only.
    func sendAVOffset(ms: Int, persist: Bool) {
        send(.avOffset, Data("\(ms),\(persist ? 1 : 0)".utf8))
    }

    func sendCodec(_ parameterSets: Data) {
        send(.codec, parameterSets)
    }

    /// Audio is never dropped: it is small next to video, and gaps would be audible.
    func sendAudio(_ pcm: Data, captureTime: CMTime) {
        send(.audio, Wire.timestamped(micros: Self.micros(captureTime), pcm))
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
            write(.timedFrame, Wire.timestamped(micros: Self.micros(captureTime), accessUnit)) { [self] in
                inFlight -= 1
            }
        }
    }

    private static func micros(_ time: CMTime) -> Int64 {
        Int64(CMTimeGetSeconds(time) * 1_000_000)
    }

    private func send(_ type: Wire.PacketType, _ payload: Data) {
        queue.async { [self] in write(type, payload) {} }
    }

    private func write(_ type: Wire.PacketType, _ payload: Data, completion: @escaping () -> Void) {
        connection.send(content: Wire.packet(type, payload), completion: .contentProcessed { [weak self] error in
            completion()
            if let error { self?.close("send failed: \(error)") }
        })
    }
}
