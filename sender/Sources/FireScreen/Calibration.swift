import AppKit
import AVFoundation
import FireScreenCore
import Foundation

/// Audio/video sync setup for a new TV.
///
/// The Fire Stick already lines audio up with video at its HDMI output. What differs per TV is
/// what happens after: picture processing, or a soundbar, can delay one relative to the other.
/// This plays a flash-and-beep clip through the real stream, full screen on the TV, while a
/// small panel on the Mac shifts audio earlier or later until both coincide. The result is saved
/// on the Fire Stick, so it applies to that TV whichever Mac connects.
final class Calibration: NSObject {
    var onFinish: ((_ savedOffsetMs: Int?) -> Void)?

    private let session: Session
    private let clip: URL
    private var offsetMs = 0
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var tvWindow: NSWindow?
    private var panel: NSPanel?
    private var offsetLabel: NSTextField?
    private var keyMonitor: Any?

    /// clip: from TestClips.syncClip(), obtained before the session started.
    init(session: Session, clip: URL) {
        self.session = session
        self.clip = clip
    }

    /// Call once the session is connected (and ideally after its hello, for the current offset).
    func begin(currentOffsetMs: Int) {
        offsetMs = currentOffsetMs
        guard let screen = Displays.screen(for: session.displayID) else {
            return finish(saved: nil, error: "the TV display is not available")
        }
        showOnTV(clip, screen: screen)
        showPanel()
    }

    private func showOnTV(_ clip: URL, screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: clip))
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        player.play()
        self.player = player
        self.tvWindow = window
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "FireScreen: audio/video sync"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let text = NSTextField(wrappingLabelWithString:
            "Look at the TV: it flashes white once a second, with a beep.\n"
            + "If you hear the beep after the flash, press Audio earlier. If before, press Audio later.\n"
            + "Keyboard: ← earlier, → later (hold ⇧ for 50 ms steps). Save when they coincide.")
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        offsetLabel = label

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let earlier = NSStackView(views: [button("◀◀ 50 ms", #selector(earlier50)), button("◀ Audio earlier", #selector(earlier10))])
        let later = NSStackView(views: [button("Audio later ▶", #selector(later10)), button("50 ms ▶▶", #selector(later50))])
        let adjust = NSStackView(views: [earlier, label, later])
        adjust.distribution = .equalSpacing
        let save = button("Save for this TV", #selector(save))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [button("Reset to 0", #selector(reset)), button("Cancel", #selector(cancel)), save])

        let stack = NSStackView(views: [text, adjust, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            adjust.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        // The panel stays on the Mac's own display; the TV shows only the test pattern.
        let home = NSScreen.screens.first { Displays.screen(for: session.displayID) != $0 } ?? NSScreen.main
        if let frame = home?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.midY - 125))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let step = event.modifierFlags.contains(.shift) ? 50 : 10
            switch event.keyCode {
            case 123: self?.adjust(-step); return nil // ←
            case 124: self?.adjust(step); return nil // →
            default: return event
            }
        }
        refreshLabel()
    }

    @objc private func earlier10() { adjust(-10) }
    @objc private func earlier50() { adjust(-50) }
    @objc private func later10() { adjust(10) }
    @objc private func later50() { adjust(50) }
    @objc private func reset() { adjust(-offsetMs) }

    private func adjust(_ delta: Int) {
        offsetMs = max(-500, min(500, offsetMs + delta))
        session.setAVOffset(ms: offsetMs, persist: false)
        refreshLabel()
    }

    private func refreshLabel() {
        let direction = offsetMs == 0 ? "" : (offsetMs > 0 ? " (audio later)" : " (audio earlier)")
        offsetLabel?.stringValue = "\(offsetMs > 0 ? "+" : "")\(offsetMs) ms\(direction)"
    }

    @objc private func save() {
        session.setAVOffset(ms: offsetMs, persist: true)
        finish(saved: offsetMs, error: nil)
    }

    @objc private func cancel() {
        finish(saved: nil, error: nil)
    }

    private func finish(saved: Int?, error: String?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        player?.pause()
        looper = nil
        player = nil
        tvWindow?.orderOut(nil)
        tvWindow = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        if let error {
            NSLog("FireScreen calibration: %@", error)
            let alert = NSAlert()
            alert.messageText = "Calibration failed"
            alert.informativeText = error
            alert.runModal()
        }
        let done = onFinish
        onFinish = nil
        // Give the receiver a moment to receive the persisted offset before the session closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done?(saved) }
    }
}

extension Calibration: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(saved: nil, error: nil)
    }
}
