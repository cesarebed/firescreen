import Foundation

/// Per-second pipeline counters, printed with --stats. Diagnostics only.
final class Stats {
    static let shared = Stats()

    private let lock = NSLock()
    private var captured = 0
    private var lastCapture: UInt64 = 0
    private var captureGapMsMax = 0.0
    private var encoded = 0
    private var encodeMsTotal = 0.0
    private var encodeMsMax = 0.0
    private var sent = 0
    private var sentBytes = 0
    private var dropped = 0
    private var keyframes = 0
    private var keyframeBytesMax = 0
    private var inFlightMax = 0
    private var audioPackets = 0
    private var audioPeak: Int16 = 0
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    func capture() {
        let now = DispatchTime.now().uptimeNanoseconds
        update {
            captured += 1
            if lastCapture != 0 { captureGapMsMax = max(captureGapMsMax, Double(now - lastCapture) / 1_000_000) }
            lastCapture = now
        }
    }

    func encoded(ms: Double) {
        update {
            encoded += 1
            encodeMsTotal += ms
            encodeMsMax = max(encodeMsMax, ms)
        }
    }

    func sent(bytes: Int, keyframe: Bool, inFlight: Int) {
        update {
            sent += 1
            sentBytes += bytes
            inFlightMax = max(inFlightMax, inFlight)
            if keyframe {
                keyframes += 1
                keyframeBytesMax = max(keyframeBytesMax, bytes)
            }
        }
    }

    func drop() { update { dropped += 1 } }

    func audio(_ pcm: Data) {
        var peak: Int16 = 0
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) where v != .min { peak = max(peak, abs(v)) }
        }
        update {
            audioPackets += 1
            audioPeak = max(audioPeak, peak)
        }
    }

    private func update(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let line = String(format: "stats cap=%d (maxgap %.0fms) enc=%d (avg %.1fms max %.1fms) sent=%d %.1fMbps drop=%d key=%d (max %dKB) inflight<=%d audio=%d peak=%d",
                          captured, captureGapMsMax, encoded, encoded > 0 ? encodeMsTotal / Double(encoded) : 0, encodeMsMax,
                          sent, Double(sentBytes) * 8 / 1_000_000, dropped, keyframes, keyframeBytesMax / 1024,
                          inFlightMax, audioPackets, Int(audioPeak))
        captured = 0; captureGapMsMax = 0; encoded = 0; encodeMsTotal = 0; encodeMsMax = 0; sent = 0; sentBytes = 0
        dropped = 0; keyframes = 0; keyframeBytesMax = 0; inFlightMax = 0
        audioPackets = 0; audioPeak = 0
        lock.unlock()
        print("firescreen: \(line)")
    }
}
