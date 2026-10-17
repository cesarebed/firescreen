import AppKit
import FireScreenCore
import Foundation

/// Command line entry points. Every command runs inside the app's run loop (the virtual display
/// and ScreenCaptureKit need a window-server connection) and ends with exit().
enum CLI {
    static let usage = """
    FireScreen: use a Fire TV as a wireless display for your Mac.

    Usage:
      FireScreen                         menu bar app (also what opening FireScreen.app does)
      FireScreen stream [options]        stream until Ctrl-C
      FireScreen discover                list Fire TVs running the receiver
      FireScreen install-receiver IP     install or update the receiver on a Fire TV (adb)
      FireScreen calibrate [options]     audio/video sync setup for the current TV
      FireScreen make-test-clips DIR     write sync and motion test videos for manual testing

    \(StreamOptions.usage)
    """

    static func run(_ args: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when redirected to a file
        guard let command = args.first else { return }
        let rest = Array(args.dropFirst())
        switch command {
        case "stream": stream(rest, calibrate: false)
        case "calibrate": stream(rest, calibrate: true)
        case "discover": discover()
        case "install-receiver": installReceiver(rest)
        case "make-test-clips": makeTestClips(rest)
        case "-h", "--help", "help": print(usage); exit(0)
        // Flags without a command: `stream`, for compatibility with `FireScreen --mode extend`.
        case let flag where flag.hasPrefix("--"): stream(args, calibrate: false)
        default: fail("unknown command \(command)\n\n\(usage)")
        }
    }

    static func log(_ message: String) {
        print("firescreen: \(message)")
    }

    static func fail(_ message: String) -> Never {
        MacOutput.restore()
        FileHandle.standardError.write(Data("firescreen: \(message)\n".utf8))
        exit(1)
    }

    // MARK: stream / calibrate

    private static var session: Session?
    private static var calibration: Calibration?
    private static var signalSources: [DispatchSourceSignal] = []

    private static func stream(_ args: [String], calibrate: Bool) {
        var options: StreamOptions
        do {
            options = try StreamOptions.parse(args)
        } catch {
            fail("\(error)\n\n\(StreamOptions.usage)")
        }
        var clip: URL?
        if calibrate {
            options.mode = .extend
            options.audio = true
            options.smooth = true
            do {
                clip = try TestClips.syncClip()
            } catch {
                fail("could not create the test pattern: \(error)")
            }
        }
        withHost(options.host) { host in
            let session = Session(options: options, host: host)
            self.session = session
            session.onEvent = { event in
                switch event {
                case .status(let text): log(text)
                case .connected where calibrate:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { startCalibration(session, clip: clip!) }
                case .connected: break
                case .hello(let hello): log("receiver: \(hello.deviceName), saved audio offset \(hello.avOffsetMs) ms")
                case .failed(let reason): fail(reason)
                }
            }
            session.start()
            if options.stats { Stats.shared.start() }
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    log("stopping")
                    session.stop()
                    exit(0)
                }
                source.resume()
                signalSources.append(source)
            }
        }
    }

    private static func startCalibration(_ session: Session, clip: URL) {
        let calibration = Calibration(session: session, clip: clip)
        self.calibration = calibration
        calibration.onFinish = { saved in
            if let saved { log("saved audio offset \(saved) ms on the receiver") } else { log("calibration cancelled") }
            session.stop()
            exit(0)
        }
        calibration.begin(currentOffsetMs: session.hello?.avOffsetMs ?? 0)
    }

    /// --host, else the saved receiver, else the first receiver found on the network.
    private static func withHost(_ explicit: String?, _ body: @escaping (String) -> Void) {
        if let host = explicit ?? Settings.receiverHost { return body(host) }
        log("looking for a Fire TV on the network…")
        // Generous: the first run may wait on macOS's Local Network permission prompt.
        Discovery.scan(timeout: 6) { found in
            guard let first = found.first else {
                fail("no receiver found. Open FireScreen on the TV, or pass --host IP.")
            }
            log("using \(first.name) at \(first.host)")
            Settings.receiverHost = first.host
            Settings.receiverName = first.name
            body(first.host)
        }
    }

    // MARK: other commands

    private static func discover() {
        Discovery.scan(timeout: 3) { found in
            if found.isEmpty { print("No receivers found. Is FireScreen open on the TV?") }
            for receiver in found { print("\(receiver.host)\t\(receiver.name)") }
            exit(0)
        }
    }

    private static func installReceiver(_ args: [String]) {
        guard let host = args.first else { fail("usage: FireScreen install-receiver IP [--apk PATH]") }
        var apk = ReceiverControl.bundledAPK
        if let index = args.firstIndex(of: "--apk"), index + 1 < args.count {
            apk = URL(fileURLWithPath: args[index + 1])
        }
        guard let apk else { fail("receiver APK not found: build it with `make receiver` or pass --apk PATH") }
        DispatchQueue.global().async {
            do {
                try ReceiverControl.install(host: host, apk: apk) { log($0) }
                Settings.receiverHost = host
                log("done: FireScreen is open on the TV")
                exit(0)
            } catch {
                fail("\(error)")
            }
        }
    }

    private static func makeTestClips(_ args: [String]) {
        guard let dir = args.first else { fail("usage: FireScreen make-test-clips DIR") }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        DispatchQueue.global().async {
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                for (name, kind) in [("firescreen-sync.mov", TestClips.Kind.sync), ("firescreen-motion.mov", .motion)] {
                    let url = base.appendingPathComponent(name)
                    log("writing \(url.path)")
                    try TestClips.write(kind, seconds: 30, to: url)
                }
                exit(0)
            } catch {
                fail("\(error)")
            }
        }
    }
}
