import AppKit
import FireScreenCore
import Foundation

/// The menu bar app: a TV icon with everything FireScreen does.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let discovery = Discovery()
    private var session: Session?
    private var calibration: Calibration?
    private var status = "Not connected"
    private var installing = false

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        discovery.onChange = { [weak self] found in self?.followSavedReceiver(found) }
        discovery.start()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let options = Settings.options
        let streaming = session != nil

        menu.addItem(disabled(status))
        menu.addItem(.separator())

        for mode in StreamOptions.Mode.allCases {
            let title = mode == .extend ? "Extend display to TV" : "Mirror display on TV"
            let entry = action(title, #selector(startMode(_:)), represented: mode.rawValue)
            entry.state = streaming && session?.options.mode == mode ? .on : .off
            menu.addItem(entry)
        }
        let stop = action("Stop", #selector(stopStreaming))
        stop.isEnabled = streaming
        menu.addItem(stop)
        menu.addItem(.separator())

        let tv = NSMenuItem(title: "Fire TV: \(Settings.receiverName ?? Settings.receiverHost ?? "none")",
                            action: nil, keyEquivalent: "")
        let tvMenu = NSMenu()
        if discovery.receivers.isEmpty {
            tvMenu.addItem(disabled("Searching the network…"))
        }
        for receiver in discovery.receivers {
            let entry = action(receiver.name, #selector(chooseReceiver(_:)), represented: receiver.name)
            entry.state = receiver.name == Settings.receiverName ? .on : .off
            tvMenu.addItem(entry)
        }
        tvMenu.addItem(.separator())
        tvMenu.addItem(action("Enter address…", #selector(enterAddress)))
        tv.submenu = tvMenu
        menu.addItem(tv)

        let smooth = action("Film mode (smoother, +70 ms delay)", #selector(toggleSmooth))
        smooth.state = options.smooth ? .on : .off
        menu.addItem(smooth)
        let audio = action("Play sound on TV", #selector(toggleAudio))
        audio.state = options.audio ? .on : .off
        menu.addItem(audio)
        let codec = NSMenuItem(title: "Video codec", action: nil, keyEquivalent: "")
        let codecMenu = NSMenu()
        for (title, hevc) in [("HEVC (less bandwidth)", true), ("H.264", false)] {
            let entry = action(title, #selector(chooseCodec(_:)), represented: hevc)
            entry.state = options.hevc == hevc ? .on : .off
            codecMenu.addItem(entry)
        }
        codec.submenu = codecMenu
        menu.addItem(codec)
        if streaming { menu.addItem(disabled("Changes apply from the next start")) }
        menu.addItem(.separator())

        menu.addItem(action("Calibrate audio/video sync…", #selector(calibrate)))
        let install = action(installing ? "Installing receiver…" : "Install receiver on Fire TV…",
                             #selector(installReceiver))
        install.isEnabled = !installing
        menu.addItem(install)
        menu.addItem(.separator())
        menu.addItem(action("Quit FireScreen", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, represented: Any? = nil, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        entry.representedObject = represented
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func refreshIcon() {
        let symbol = session != nil ? "tv.fill" : "tv"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FireScreen")
        item.button?.toolTip = "FireScreen: \(status)"
    }

    // MARK: Streaming

    @objc private func startMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = StreamOptions.Mode(rawValue: raw) else { return }
        var options = Settings.options
        options.mode = mode
        Settings.options = options
        startSession(options) { _ in }
    }

    /// Starts a session with the saved receiver; `connected` runs once it streams.
    private func startSession(_ options: StreamOptions, connected: @escaping (Session) -> Void) {
        stopSession()
        guard let host = Settings.receiverHost else {
            alert("Choose your Fire TV first", "Open FireScreen on the TV, then pick it under Fire TV in this menu "
                  + "(or enter its address). New TV? Use Install receiver on Fire TV first.")
            return
        }
        let session = Session(options: options, host: host)
        self.session = session
        setStatus("Connecting to \(Settings.receiverName ?? host)…")
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            switch event {
            case .status: break
            case .connected:
                self.setStatus("Streaming to \(Settings.receiverName ?? host) (\(options.mode.rawValue))")
                connected(session)
            case .hello(let hello):
                if Settings.receiverName == nil { Settings.receiverName = "FireScreen \(hello.deviceName)" }
            case .failed(let reason):
                self.session = nil
                self.calibration = nil
                self.setStatus("Stopped: \(reason)")
                self.alert("FireScreen stopped", reason)
            }
        }
        session.start()
    }

    @objc private func stopStreaming() {
        stopSession()
    }

    private func stopSession() {
        session?.stop()
        session = nil
        setStatus("Not connected")
    }

    private func setStatus(_ text: String) {
        status = text
        refreshIcon()
    }

    // MARK: Receivers

    @objc private func chooseReceiver(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let receiver = discovery.receivers.first(where: { $0.name == name }) else { return }
        Discovery.resolve(receiver) { [weak self] host in
            guard let host else { return self?.alert("Could not reach \(name)", "Is FireScreen open on the TV?") ?? () }
            Settings.receiverHost = host
            Settings.receiverName = name
            self?.setStatus("Fire TV: \(name) (\(host))")
        }
    }

    /// The TV's address can change (DHCP). If the saved receiver shows up, refresh its address.
    private func followSavedReceiver(_ found: [DiscoveredReceiver]) {
        if Settings.receiverName == nil, found.count == 1 {
            Discovery.resolve(found[0]) { host in
                guard let host, Settings.receiverName == nil else { return }
                Settings.receiverHost = host
                Settings.receiverName = found[0].name
            }
            return
        }
        guard session == nil, let saved = found.first(where: { $0.name == Settings.receiverName }) else { return }
        Discovery.resolve(saved) { host in
            if let host { Settings.receiverHost = host }
        }
    }

    @objc private func enterAddress() {
        guard let host = ask("Fire TV address", "The IP address shown on the TV by the FireScreen app, "
                             + "or in Settings > My Fire TV > About > Network.", value: Settings.receiverHost ?? "")
        else { return }
        Settings.receiverHost = host
        Settings.receiverName = nil
        setStatus("Fire TV: \(host)")
    }

    // MARK: Options

    @objc private func toggleSmooth() {
        var o = Settings.options
        o.smooth.toggle()
        Settings.options = o
    }

    @objc private func toggleAudio() {
        var o = Settings.options
        o.audio.toggle()
        Settings.options = o
    }

    @objc private func chooseCodec(_ sender: NSMenuItem) {
        guard let hevc = sender.representedObject as? Bool else { return }
        var o = Settings.options
        o.hevc = hevc
        Settings.options = o
    }

    // MARK: Setup

    @objc private func calibrate() {
        var options = Settings.options
        options.mode = .extend // the test pattern needs the TV to itself
        options.audio = true
        options.smooth = true
        setStatus("Preparing the test pattern…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let clip = Result { try TestClips.syncClip() }
            DispatchQueue.main.async {
                switch clip {
                case .success(let url): self?.runCalibration(options, clip: url)
                case .failure(let error): self?.alert("Could not create the test pattern", "\(error)")
                }
            }
        }
    }

    private func runCalibration(_ options: StreamOptions, clip: URL) {
        startSession(options) { [weak self] session in
            guard let self else { return }
            // Wait briefly for the receiver's hello, which carries the current calibration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard self.session === session else { return }
                let calibration = Calibration(session: session, clip: clip)
                self.calibration = calibration
                calibration.onFinish = { [weak self] saved in
                    self?.calibration = nil
                    self?.stopSession()
                    if let saved {
                        self?.alert("Saved on the Fire TV", "Audio offset \(saved) ms. It applies to this TV "
                                    + "from now on, from any Mac.")
                    }
                }
                calibration.begin(currentOffsetMs: session.hello?.avOffsetMs ?? 0)
            }
        }
    }

    @objc private func installReceiver() {
        guard let apk = ReceiverControl.bundledAPK else {
            return alert("Receiver not bundled", "Build it with `make receiver`, then `make app`.")
        }
        guard ReceiverControl.adbPath != nil else {
            return alert("adb is needed once", "Install it with:\n\nbrew install --cask android-platform-tools\n\n"
                         + "then try again.")
        }
        guard let host = ask("Install the receiver on your Fire TV",
                             "1. On the TV: Settings > My Fire TV > About: click the device name 7 times "
                             + "to unlock Developer options.\n"
                             + "2. Settings > My Fire TV > Developer options: turn on ADB debugging.\n"
                             + "3. Enter the TV's IP address (Settings > My Fire TV > About > Network).\n"
                             + "4. When the TV asks \"Allow USB debugging?\", choose Always allow and OK.",
                             value: Settings.receiverHost ?? "") else { return }
        installing = true
        setStatus("Installing receiver on \(host)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ReceiverControl.install(host: host, apk: apk) { step in
                    DispatchQueue.main.async { self?.setStatus(step) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installing = false
                switch result {
                case .success:
                    Settings.receiverHost = host
                    Settings.receiverName = nil
                    self.setStatus("Receiver installed on \(host)")
                    self.alert("Receiver installed", "FireScreen is open on the TV. Next: Calibrate audio/video "
                               + "sync once for this TV, then Extend or Mirror.")
                case .failure(let error):
                    self.setStatus("Install failed")
                    self.alert("Install failed", "\(error)")
                }
            }
        }
    }

    @objc private func quit() {
        stopSession()
        NSApp.terminate(nil)
    }

    // MARK: Dialogs

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func ask(_ title: String, _ text: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = "192.168.1.20"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }
}
