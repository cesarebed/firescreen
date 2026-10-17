import AppKit
import CoreMedia
import FireScreenCore
import Foundation
import VirtualDisplay

/// One streaming session: virtual (or main) display -> capture -> encode -> receiver.
/// Never exits the process; reports through `onEvent`, always on the main queue.
/// Main-queue confined: callbacks from capture and network threads hop back to main before
/// touching state, hence the unchecked Sendable.
final class Session: @unchecked Sendable {
    enum Event {
        case status(String)
        case connected
        case hello(ReceiverHello)
        /// The session ended on its own (error or receiver gone). It is already cleaned up.
        case failed(String)
    }

    let options: StreamOptions
    let host: String
    var onEvent: ((Event) -> Void)?
    /// The display being streamed: the virtual monitor in extend mode, the main display in mirror mode.
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var hello: ReceiverHello?

    private var virtualDisplay: FSVirtualDisplay?
    private let capturer = Capturer()
    private var encoder: Encoder?
    private var sender: Sender?
    private var lastFrame: (CVPixelBuffer, CMTime)?
    private let frameLock = NSLock()
    private var stopped = false

    init(options: StreamOptions, host: String) {
        self.options = options
        self.host = host
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return fail("Screen Recording permission missing: allow FireScreen in System Settings > "
                        + "Privacy & Security > Screen & System Audio Recording, then start again.")
        }

        switch options.mode {
        case .mirror:
            displayID = CGMainDisplayID()
        case .extend:
            guard let display = FSVirtualDisplay(name: "Fire TV", width: UInt32(options.width),
                                                 height: UInt32(options.height),
                                                 refreshRate: 60, hiDPI: options.hiDPI) else {
                return fail("could not create the virtual display (private CGVirtualDisplay API unavailable)")
            }
            virtualDisplay = display
            displayID = display.displayID
            Displays.arrangeAsExtended(displayID)
            // macOS can re-apply a remembered mirror set shortly after the display appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.stopped else { return }
                Displays.arrangeAsExtended(self.displayID)
            }
            emit(.status("virtual display \(displayID) created, placed right of the main display"))
        }

        let encoder: Encoder
        do {
            encoder = try Encoder(width: options.width, height: options.height, fps: options.fps,
                                  bitrateMbps: options.bitrateMbps, hevc: options.hevc)
        } catch {
            return fail("encoder: \(error.localizedDescription)")
        }
        self.encoder = encoder

        let host = self.host
        let launch = options.launchReceiver
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if launch { ReceiverControl.launch(host: host) }
            DispatchQueue.main.async { self?.connect(encoder) }
        }
    }

    private func connect(_ encoder: Encoder) {
        guard !stopped else { return }
        let sender = Sender(host: host, port: options.port)
        self.sender = sender
        encoder.onParameterSets = { [weak sender] in sender?.sendCodec($0) }
        encoder.onFrame = { [weak sender] in sender?.sendFrame($0, keyframe: $1, captureTime: $2) }
        sender.onNeedKeyframe = { [weak self] in self?.refreshKeyframe() }
        sender.onClosed = { [weak self] reason in DispatchQueue.main.async { self?.fail(reason) } }
        sender.onWaiting = { [weak self] in self?.emit(.status($0)) }
        sender.onHello = { [weak self] hello in
            DispatchQueue.main.async {
                self?.hello = hello
                self?.emit(.hello(hello))
            }
        }
        sender.onReady = { [weak self] in
            guard let self else { return }
            let o = self.options
            sender.sendConfig(o)
            if o.audio {
                sender.sendAudioConfig(sampleRate: Capturer.audioSampleRate, channels: Capturer.audioChannels)
            }
            encoder.resetParameterSets()
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                if o.audio { MacOutput.muteForStreaming() }
                self.emit(.status("connected to \(self.host):\(o.port), \(o.mode.rawValue) \(o.width)x\(o.height), "
                                  + "\(o.hevc ? "HEVC" : "H.264") \(o.bitrateMbps) Mbps"
                                  + (o.smooth ? ", smooth" : "") + (o.audio ? ", audio on TV" : "")))
                self.emit(.connected)
                self.startCapture()
            }
        }
        sender.start()
    }

    private func startCapture() {
        capturer.onFrame = { [weak self] buffer, pts in
            guard let self else { return }
            Stats.shared.capture()
            self.frameLock.lock()
            self.lastFrame = (buffer, pts)
            self.frameLock.unlock()
            self.encoder?.encode(buffer, pts: pts)
        }
        capturer.onAudio = { [weak self] pcm, pts in
            Stats.shared.audio(pcm)
            self?.sender?.sendAudio(pcm, captureTime: pts)
        }
        capturer.onError = { [weak self] message in DispatchQueue.main.async { self?.fail(message) } }
        let (displayID, o) = (self.displayID, options)
        Task { [weak self] in
            do {
                try await self?.capturer.start(displayID: displayID, width: o.width, height: o.height,
                                               fps: o.fps, audio: o.audio)
            } catch {
                DispatchQueue.main.async { self?.fail("capture: \(error.localizedDescription)") }
            }
        }
    }

    /// Calibration: positive plays audio later on the TV. persist stores it on the receiver.
    func setAVOffset(ms: Int, persist: Bool) {
        sender?.sendAVOffset(ms: ms, persist: persist)
    }

    /// ScreenCaptureKit only delivers frames when pixels change. After a drop on a static
    /// screen, re-encode the last frame so the TV gets a clean keyframe without waiting.
    private func refreshKeyframe() {
        encoder?.requestKeyframe()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let frame = self.lastFrame
            self.frameLock.unlock()
            if let (buffer, pts) = frame {
                self.encoder?.encode(buffer, pts: CMTimeAdd(pts, CMTime(value: 1, timescale: 1000)))
            }
        }
    }

    /// Idempotent. Restores the Mac's sound and removes the virtual display.
    func stop() {
        guard !stopped else { return }
        stopped = true
        MacOutput.restore()
        sender?.stop()
        let capturer = self.capturer
        Task { await capturer.stop() }
        virtualDisplay = nil
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stop()
        emit(.failed(reason))
    }

    private func emit(_ event: Event) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }
}
