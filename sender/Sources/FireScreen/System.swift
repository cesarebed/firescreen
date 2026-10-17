import AppKit
import FireScreenCore
import Foundation

enum Displays {
    /// Extended desktop, not mirroring: the Mac's own display stays main at the origin and
    /// the virtual monitor sits to its right. Lasts for this login session only.
    static func arrangeAsExtended(_ virtualID: CGDirectDisplayID) {
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
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}

/// Mutes the Mac's own output while sound goes to the TV; ScreenCaptureKit still captures it.
enum MacOutput {
    private static var wasMuted: Bool?

    static func muteForStreaming() {
        guard wasMuted == nil else { return }
        wasMuted = run("output muted of (get volume settings)") == "true"
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

/// The receiver side of setup, over adb (Fire TV: Settings > My Fire TV > Developer options > ADB debugging).
enum ReceiverControl {
    static let package = "io.firescreen.receiver"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var adbPath: String? {
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The receiver APK bundled in FireScreen.app, or next to a development build.
    static var bundledAPK: URL? {
        if let url = Bundle.main.url(forResource: "firescreen-receiver", withExtension: "apk") { return url }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../../receiver/build/firescreen-receiver.apk").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Best effort: open the receiver on the TV so it is listening before we connect.
    static func launch(host: String) {
        guard adbPath != nil else { return }
        _ = try? adb(["connect", "\(host):5555"], timeout: 5)
        _ = try? adb(["-s", "\(host):5555", "shell", "am", "start", "-n", "\(package)/.MainActivity"], timeout: 5)
        Thread.sleep(forTimeInterval: 1.5) // let the receiver open its port
    }

    /// Installs (or updates) and opens the receiver. Blocking; run off the main thread.
    /// The first time, the TV shows "Allow USB debugging?": the user must accept within ~60 s.
    static func install(host: String, apk: URL, progress: (String) -> Void) throws {
        guard adbPath != nil else {
            throw Failure(description: "adb not found. Install it with: brew install --cask android-platform-tools")
        }
        let serial = "\(host):5555"
        progress("Connecting to \(serial)…")
        _ = try adb(["connect", serial], timeout: 10)
        progress("Waiting for the TV to authorize this Mac (accept the prompt on the TV)…")
        var state = ""
        for _ in 0..<60 {
            state = (try? adb(["-s", serial, "get-state"], timeout: 5))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if state == "device" { break }
            if state.isEmpty { _ = try? adb(["connect", serial], timeout: 5) }
            Thread.sleep(forTimeInterval: 1)
        }
        guard state == "device" else {
            throw Failure(description: "The Fire TV did not authorize this Mac. On the TV, enable "
                          + "Settings > My Fire TV > Developer options > ADB debugging, then accept "
                          + "\"Allow USB debugging?\" and try again.")
        }
        progress("Installing the receiver…")
        let result = try adb(["-s", serial, "install", "-r", apk.path], timeout: 120)
        guard result.contains("Success") else { throw Failure(description: "adb install failed: \(result)") }
        progress("Opening FireScreen on the TV…")
        _ = try adb(["-s", serial, "shell", "am", "start", "-n", "\(package)/.MainActivity"], timeout: 10)
    }

    @discardableResult
    static func adb(_ args: [String], timeout: TimeInterval) throws -> String {
        guard let adbPath else { throw Failure(description: "adb not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw Failure(description: "adb \(args.joined(separator: " ")) timed out")
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
