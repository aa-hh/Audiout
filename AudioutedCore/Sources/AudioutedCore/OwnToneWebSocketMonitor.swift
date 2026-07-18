import Foundation

/// Best-effort websocket accelerant for the OwnTone `notify` protocol (`:3688`).
///
/// **This is not load-bearing.** Per `dev/notes/p1-owntone-api-brief.md` §3, push
/// notifications did NOT fire in 4/4 live test runs on OwnTone 29.2, so the
/// backend's state sync is driven entirely by 1 s polling. This monitor exists
/// only so that IF a notification ever arrives, the backend can trigger an
/// immediate out-of-band poll instead of waiting for the next tick.
///
/// Contract, straight from the brief §3:
/// - Dial `ws://host:port/` with the `notify` subprotocol (URLSession negotiates
///   the `Sec-WebSocket-Protocol: notify` handshake via the initializer).
/// - After the upgrade, send one text frame declaring interest in the event
///   types. The server never acks — silence is "accepted."
/// - Each push frame carries only event **names**, no payload — so we ignore the
///   frame contents entirely and just fire `onNotification` ("something changed,
///   re-GET now").
/// - Any receive failure means poll-only from here; we reconnect on a backoff
///   but never let a websocket failure gate state refresh.
final class OwnToneWebSocketMonitor: NSObject, @unchecked Sendable {

    /// Called on ANY received frame (or, more precisely, whenever the server
    /// hints something changed). The backend reacts by kicking an immediate
    /// poll. Never carries data — there's nothing in the frame to parse.
    var onNotification: (@Sendable () -> Void)?

    private let url: URL
    private let subscribeTypes: [String]
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var reconnectAttempts = 0

    init(host: String = "localhost", port: Int = 3688,
         subscribeTypes: [String] = ["player", "outputs", "volume", "queue", "update"]) {
        self.url = URL(string: "ws://\(host):\(port)/")!
        self.subscribeTypes = subscribeTypes
        super.init()
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        connect()
    }

    func stop() {
        lock.lock()
        running = false
        let task = self.task
        self.task = nil
        session?.invalidateAndCancel()
        session = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func connect() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url, protocols: ["notify"])
        self.session = session
        self.task = task
        lock.unlock()

        task.resume()
        subscribe(on: task)
        receiveLoop(on: task)
    }

    private func subscribe(on task: URLSessionWebSocketTask) {
        let body = ["notify": subscribeTypes]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in
            // The server neither acks nor errors a good subscribe; a send error
            // just means this connection is dead and the receive loop's failure
            // path will schedule a reconnect. Nothing to do here.
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Frame contents are irrelevant (names only, no payload) — any
                // frame means "re-GET now."
                self.onNotification?()
                self.receiveLoop(on: task)
            case .failure:
                // Poll remains the primary path; reconnect on a backoff so a
                // transient drop self-heals without ever blocking state refresh.
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        lock.lock()
        guard running else { lock.unlock(); return }
        reconnectAttempts += 1
        // 1, 2, 4, 8 … capped at 30 s. Cheap, and orthogonal to polling.
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
        session?.invalidateAndCancel()
        session = nil
        task = nil
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}

extension OwnToneWebSocketMonitor: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        reconnectAttempts = 0   // a clean open resets the backoff
        lock.unlock()
    }
}
