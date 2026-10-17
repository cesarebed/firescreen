import AppKit
import CoreMedia
import Foundation
import VirtualDisplay

struct Options {
    enum Mode: String { case mirror, extend }

    var host = "192.168.1.3"
    var port: UInt16 = 7878
    var mode = Mode.extend
    var width = 1920
    var height = 1080
    var fps = 30
    var bitrateMbps = 8.0
    var hiDPI = false
    var launchReceiver = true
    var stats = false
    var smooth = false
    var hevc = true
    var audio = true

    static let usage = """
    Usage: FireScreen [--host IP] [--port N] [--mode extend|mirror] [--size WxH] [--fps N]
                      [--bitrate MBPS] [--hidpi] [--smooth] [--codec hevc|h264]
                      [--no-audio] [--no-launch] [--stats]

      extend   creates a virtual monitor and streams it (default)
      mirror   streams the main display
      --hidpi  extend only: Retina-style virtual monitor (sharper text, larger UI)
      --smooth  steadier motion for films: ~70 ms more delay on the TV
      --codec   hevc (default, less bandwidth) or h264
      --no-audio  keep sound on the Mac instead of sending it to the TV
                  (with audio on, the Mac is muted while streaming and restored on exit)
      --no-launch  do not start the receiver app on the Fire TV through adb
    """

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var it = args.makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("missing value for \(flag)") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--host": options.host = value(arg)
            case "--port": options.port = UInt16(value(arg)) ?? options.port
            case "--mode":
                guard let mode = Mode(rawValue: value(arg)) else { fail("mode must be extend or mirror") }
                options.mode = mode
            case "--size":
                let parts = value(arg).split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { fail("size must look like 1920x1080") }
                (options.width, options.height) = (parts[0], parts[1])
            case "--fps": options.fps = Int(value(arg)) ?? options.fps
            case "--bitrate": options.bitrateMbps = Double(value(arg)) ?? options.bitrateMbps
            case "--hidpi": options.hiDPI = true
            case "--no-launch": options.launchReceiver = false
            case "--stats": options.stats = true
            case "--smooth": options.smooth = true
            case "--no-audio": options.audio = false
            case "--codec":
                switch value(arg) {
                case "h264": options.hevc = false
                case "hevc": options.hevc = true
                default: fail("codec must be h264 or hevc")
                }
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(arg)\n\n\(usage)")
            }
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    MacOutput.restore()
    FileHandle.standardError.write(Data("firescreen: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    print("firescreen: \(message)")
}

/// Best effort: open the receiver on the TV if adb can reach it.
func launchReceiver(host: String) {
    let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
    guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    for args in [["connect", "\(host):5555"],
                 ["-s", "\(host):5555", "shell", "am", "start", "-n", "io.firescreen.receiver/.MainActivity"]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: 1.5) // let the receiver open its port
}

/// Mutes the Mac's own output while sound goes to the TV; ScreenCaptureKit still captures it.
enum MacOutput {
    private static var wasMuted: Bool?

    static func muteForStreaming() {
        let state = run("output muted of (get volume settings)")
        wasMuted = state == "true"
        if wasMuted == false { _ = run("set volume with output muted") }
    }

    static func restore() {
        if wasMuted == false { _ = run("set volume without output muted") }
        wasMuted = nil
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}

final class Session {
    let options: Options
    private var virtualDisplay: FSVirtualDisplay?
    private let capturer = Capturer()
    private var encoder: Encoder!
    private var sender: Sender!
    private var lastFrame: (CVPixelBuffer, CMTime)?
    private let frameLock = NSLock()

    init(options: Options) {
        self.options = options
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            fail("Screen Recording permission missing: allow FireScreen in System Settings > Privacy & Security > Screen Recording, then run it again")
        }

        let displayID: CGDirectDisplayID
        switch options.mode {
        case .mirror:
            displayID = CGMainDisplayID()
        case .extend:
            guard let display = FSVirtualDisplay(name: "Fire TV", width: UInt32(options.width),
                                                 height: UInt32(options.height),
                                                 refreshRate: 60, hiDPI: options.hiDPI) else {
                fail("could not create the virtual display (private CGVirtualDisplay API unavailable)")
            }
            virtualDisplay = display
            displayID = display.displayID
            arrangeAsExtended(displayID)
            // macOS can re-apply a remembered mirror set shortly after the display appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arrangeAsExtended(displayID) }
            log("virtual display \(displayID) created, placed right of the main display")
        }

        do {
            encoder = try Encoder(width: options.width, height: options.height, fps: options.fps,
                                  bitrateMbps: options.bitrateMbps, hevc: options.hevc)
        } catch {
            fail("encoder: \(error.localizedDescription)")
        }

        if options.launchReceiver { launchReceiver(host: options.host) }

        sender = Sender(host: options.host, port: options.port)
        encoder.onParameterSets = { [weak self] in self?.sender.sendCodec($0) }
        encoder.onFrame = { [weak self] in self?.sender.sendFrame($0, keyframe: $1, captureTime: $2) }
        sender.onNeedKeyframe = { [weak self] in self?.refreshKeyframe() }
        sender.onClosed = { reason in fail(reason) }
        sender.onWaiting = { log($0) }
        sender.onReady = { [weak self] in
            guard let self else { return }
            log("connected to \(self.options.host):\(self.options.port), \(self.options.mode.rawValue) " +
                "\(self.options.width)x\(self.options.height)@\(self.options.fps) \(self.options.bitrateMbps) Mbps")
            self.sender.sendConfig(width: self.options.width, height: self.options.height, fps: self.options.fps,
                                   playoutDelayMs: self.options.smooth ? 120 : 50,
                                   codec: self.options.hevc ? "hevc" : "avc")
            if self.options.audio {
                self.sender.sendAudioConfig(sampleRate: Capturer.audioSampleRate, channels: Capturer.audioChannels)
                DispatchQueue.main.async { MacOutput.muteForStreaming() }
            }
            self.encoder.resetParameterSets()
            self.startCapture(displayID)
        }
        sender.start()
    }

    private func startCapture(_ displayID: CGDirectDisplayID) {
        capturer.onFrame = { [weak self] buffer, pts in
            guard let self else { return }
            Stats.shared.capture()
            self.frameLock.lock()
            self.lastFrame = (buffer, pts)
            self.frameLock.unlock()
            self.encoder.encode(buffer, pts: pts)
        }
        capturer.onAudio = { [weak self] pcm, pts in
            Stats.shared.audio(pcm)
            self?.sender.sendAudio(pcm, captureTime: pts)
        }
        capturer.onError = { fail($0) }
        Task {
            do {
                try await capturer.start(displayID: displayID, width: options.width, height: options.height,
                                         fps: options.fps, audio: options.audio)
            } catch {
                fail("capture: \(error.localizedDescription)")
            }
        }
    }

    /// Extended desktop, not mirroring: the Mac's own display stays main at the origin and
    /// the virtual monitor sits to its right. Lasts for this login session only.
    private func arrangeAsExtended(_ virtualID: CGDirectDisplayID) {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard let primary = ids.first(where: { $0 != virtualID && CGDisplayIsBuiltin($0) != 0 })
                ?? ids.first(where: { $0 != virtualID }) else { return }
        let primaryWidth = Int32(CGDisplayCopyDisplayMode(primary)?.width ?? Int(CGDisplayBounds(primary).width))

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for id in ids {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        }
        CGConfigureDisplayOrigin(config, primary, 0, 0)
        CGConfigureDisplayOrigin(config, virtualID, primaryWidth, 0)
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            log("could not switch to extended layout; set it in System Settings > Displays")
        }
    }

    /// ScreenCaptureKit only delivers frames when pixels change. After a drop on a static
    /// screen, re-encode the last frame so the TV gets a clean keyframe without waiting.
    private func refreshKeyframe() {
        encoder.requestKeyframe()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let frame = self.lastFrame
            self.frameLock.unlock()
            if let (buffer, pts) = frame {
                self.encoder.encode(buffer, pts: CMTimeAdd(pts, CMTime(value: 1, timescale: 1000)))
            }
        }
    }

    func stop() {
        MacOutput.restore()
        sender?.stop()
        virtualDisplay = nil // removes the virtual monitor
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when redirected to a file
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

// A regular app connection to the window server; CGVirtualDisplay needs it.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let session = Session(options: options)
session.start()
if options.stats { Stats.shared.start() }

var signalSources: [DispatchSourceSignal] = []
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

app.run()
