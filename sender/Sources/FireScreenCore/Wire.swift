import Foundation

/// FireScreen wire protocol v1. Every packet, both directions: [type u8][length u32 BE][payload].
/// See docs/PROTOCOL.md.
public enum Wire {
    public static let protocolVersion = 1
    public static let defaultPort: UInt16 = 7878
    public static let serviceType = "_firescreen._tcp"

    /// Sender to receiver.
    public enum PacketType: UInt8 {
        /// ascii "width,height,fps,playoutDelayMs,avc|hevc"
        case config = 1
        /// Untimed access unit (legacy; the receiver stamps it on arrival).
        case frame = 2
        /// Parameter sets (SPS/PPS, plus VPS for HEVC), Annex B.
        case codec = 3
        /// [capture time µs, i64 BE][access unit, Annex B]
        case timedFrame = 4
        /// [capture time µs of the first sample, i64 BE][s16le interleaved PCM]
        case audio = 5
        /// ascii "sampleRate,channels"
        case audioConfig = 6
        /// ascii "offsetMs,persist": positive plays audio later; persist=1 stores it on the TV.
        case avOffset = 7
    }

    /// Receiver to sender.
    public enum ReceiverPacketType: UInt8 {
        /// ascii "protocolVersion|avOffsetMs|deviceName", once on connect
        case hello = 1
    }

    public static func packet(_ type: UInt8, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(type)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func packet(_ type: PacketType, _ payload: Data) -> Data {
        packet(type.rawValue, payload)
    }

    /// Prefixes a payload with a capture timestamp in microseconds.
    public static func timestamped(micros: Int64, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 8)
        var be = micros.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func config(width: Int, height: Int, fps: Int, playoutDelayMs: Int, hevc: Bool) -> Data {
        Data("\(width),\(height),\(fps),\(playoutDelayMs),\(hevc ? "hevc" : "avc")".utf8)
    }
}

/// What the receiver says about itself when a sender connects.
public struct ReceiverHello: Equatable {
    public let protocolVersion: Int
    public let avOffsetMs: Int
    public let deviceName: String

    public init(protocolVersion: Int, avOffsetMs: Int, deviceName: String) {
        self.protocolVersion = protocolVersion
        self.avOffsetMs = avOffsetMs
        self.deviceName = deviceName
    }

    public init?(payload: Data) {
        let parts = String(decoding: payload, as: UTF8.self).split(separator: "|", maxSplits: 2,
                                                                     omittingEmptySubsequences: false)
        guard parts.count == 3, let version = Int(parts[0]), let offset = Int(parts[1]) else { return nil }
        self.init(protocolVersion: version, avOffsetMs: offset, deviceName: String(parts[2]))
    }
}

/// Incremental parser for packets arriving in arbitrary TCP chunks.
public struct PacketReader {
    private var buffer = Data()

    public init() {}

    /// Appends bytes and returns every complete packet now available, in order.
    public mutating func feed(_ bytes: Data) -> [(type: UInt8, payload: Data)] {
        buffer.append(bytes)
        var packets: [(UInt8, Data)] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let length = buffer[(start + 1)..<(start + 5)].reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count >= 5 + length else { break }
            packets.append((buffer[start], Data(buffer[(start + 5)..<(start + 5 + length)])))
            buffer.removeFirst(5 + length)
        }
        return packets
    }
}
