import FireScreenCore
import Foundation
import Network

/// A FireScreen receiver advertised on the local network (Bonjour, "_firescreen._tcp").
struct DiscoveredReceiver: Hashable {
    let name: String
    let endpoint: NWEndpoint
}

/// Browses for receivers. Results are delivered on the main queue.
final class Discovery {
    var onChange: (([DiscoveredReceiver]) -> Void)?
    private(set) var receivers: [DiscoveredReceiver] = []
    private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredReceiver(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async {
                self?.receivers = found
                self?.onChange?(found)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The receiver's IP address (adb and the stream use plain addresses). Opens a short
    /// connection to the advertised service and reads where it went.
    static func resolve(_ receiver: DiscoveredReceiver, completion: @escaping (String?) -> Void) {
        // IPv4: a link-local IPv6 address is useless to adb and to a saved setting without its interface.
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: receiver.endpoint, using: parameters)
        var finished = false
        func finish(_ host: String?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(host)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
                    var text = "\(host)"
                    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) } // drop %en0
                    finish(text)
                } else {
                    finish(nil)
                }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }

    /// One-shot: wait up to `timeout` for receivers, resolving each one's address.
    static func scan(timeout: TimeInterval, completion: @escaping ([(name: String, host: String)]) -> Void) {
        let discovery = Discovery()
        discovery.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            let found = discovery.receivers
            discovery.stop()
            var resolved: [(String, String)] = []
            let group = DispatchGroup()
            for receiver in found {
                group.enter()
                resolve(receiver) { host in
                    if let host { resolved.append((receiver.name, host)) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(resolved.sorted { $0.0 < $1.0 }) }
        }
    }
}

/// Preferences shared by the menu bar app and the command line.
enum Settings {
    /// Inside FireScreen.app the standard domain is already io.firescreen.sender; a bare
    /// development binary would otherwise get its own domain, so point it at the same one.
    private static let defaults: UserDefaults = Bundle.main.bundleIdentifier == "io.firescreen.sender"
        ? .standard : UserDefaults(suiteName: "io.firescreen.sender") ?? .standard

    static var receiverHost: String? {
        get { defaults.string(forKey: "receiverHost") }
        set { defaults.set(newValue, forKey: "receiverHost") }
    }

    static var receiverName: String? {
        get { defaults.string(forKey: "receiverName") }
        set { defaults.set(newValue, forKey: "receiverName") }
    }

    /// Stream preferences as last chosen in the menu bar app.
    static var options: StreamOptions {
        get {
            var o = StreamOptions()
            o.mode = StreamOptions.Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .extend
            o.smooth = defaults.bool(forKey: "smooth")
            o.audio = defaults.object(forKey: "audio") as? Bool ?? true
            o.hevc = defaults.object(forKey: "hevc") as? Bool ?? true
            o.host = receiverHost
            return o
        }
        set {
            defaults.set(newValue.mode.rawValue, forKey: "mode")
            defaults.set(newValue.smooth, forKey: "smooth")
            defaults.set(newValue.audio, forKey: "audio")
            defaults.set(newValue.hevc, forKey: "hevc")
        }
    }
}
