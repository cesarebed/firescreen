import Foundation

/// Everything that shapes one streaming session.
public struct StreamOptions: Equatable {
    public enum Mode: String, CaseIterable {
        case extend, mirror
    }

    /// Receiver address. nil: use the saved receiver, else the first one found on the network.
    public var host: String?
    public var port: UInt16 = Wire.defaultPort
    public var mode = Mode.extend
    public var width = 1920
    public var height = 1080
    public var fps = 30
    public var bitrateMbps = 8.0
    public var hiDPI = false
    /// Larger playout delay on the TV for steadier motion (films).
    public var smooth = false
    public var hevc = true
    public var audio = true
    /// Open the receiver app on the TV through adb before connecting.
    public var launchReceiver = true
    public var stats = false

    public init() {}

    /// How far behind the fastest frame the receiver presents, absorbing jitter.
    public var playoutDelayMs: Int { smooth ? 120 : 50 }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let usage = """
    Options for `stream` (and `calibrate`):
      --host IP          Fire TV address (default: saved receiver, else first one discovered)
      --port N           receiver port (default 7878)
      --mode extend|mirror
                         extend: add the TV as a second display (default); mirror: show the main display
      --smooth           steadier motion for films, ~70 ms more delay on the TV
      --no-audio         keep sound on the Mac (by default it plays on the TV and the Mac is muted)
      --codec hevc|h264  video codec (default hevc: less bandwidth)
      --size WxH         stream size (default 1920x1080)
      --fps N            frame rate the encoder is tuned for (default 30)
      --bitrate MBPS     average video bitrate (default 8)
      --hidpi            extend only: Retina-style virtual display (sharper text, larger UI)
      --no-launch        do not open the receiver app on the TV through adb
      --stats            print per-second pipeline statistics
    """

    public static func parse(_ args: [String]) throws -> StreamOptions {
        var options = StreamOptions()
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw ParseError(description: "missing value for \(flag)") }
            return v
        }
        func number<T: LosslessStringConvertible>(_ flag: String, _ type: T.Type) throws -> T {
            let raw = try value(flag)
            guard let v = T(raw) else { throw ParseError(description: "\(flag): not a number: \(raw)") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--host": options.host = try value(arg)
            case "--port": options.port = try number(arg, UInt16.self)
            case "--mode":
                let raw = try value(arg)
                guard let mode = Mode(rawValue: raw) else {
                    throw ParseError(description: "--mode must be extend or mirror, not \(raw)")
                }
                options.mode = mode
            case "--size":
                let raw = try value(arg)
                let parts = raw.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else {
                    throw ParseError(description: "--size must look like 1920x1080, not \(raw)")
                }
                (options.width, options.height) = (parts[0], parts[1])
            case "--fps": options.fps = try number(arg, Int.self)
            case "--bitrate": options.bitrateMbps = try number(arg, Double.self)
            case "--hidpi": options.hiDPI = true
            case "--smooth": options.smooth = true
            case "--no-audio": options.audio = false
            case "--no-launch": options.launchReceiver = false
            case "--stats": options.stats = true
            case "--codec":
                switch try value(arg) {
                case "hevc": options.hevc = true
                case "h264": options.hevc = false
                case let other: throw ParseError(description: "--codec must be hevc or h264, not \(other)")
                }
            default: throw ParseError(description: "unknown option \(arg)")
            }
        }
        return options
    }
}
