import Foundation
import Network

/// Whether a device is (still) advertising itself on the local network, and — if
/// so — where to reach it.
///
/// Produced by the `bonjour` seam of ``NetworkConnectionDiagnostics``. "Present"
/// means an `_airplay._tcp` or `_raop._tcp` instance matching the device was seen
/// during the bounded browse; `.endpoint` carries the first resolvable service so
/// step 4 (the TCP probe) can reach it. A device that has *vanished* from both
/// service types is the strongest signal we can get that it's simply gone
/// (brief §4, step 3).
public struct BonjourPresence: Sendable {

    /// A service endpoint the TCP probe can dial. Wraps the Bonjour service name
    /// so the real `tcpProbe` seam resolves it via `NWConnection`; tests fabricate
    /// one directly without touching the network.
    public struct Endpoint: Sendable {
        /// The Bonjour service instance name (e.g. `"Kitchen"` for `_airplay`, or
        /// `"AABBCC001122@Kitchen"` for `_raop`).
        public var serviceName: String
        /// The service type the instance was found under (`_airplay._tcp` or
        /// `_raop._tcp`).
        public var serviceType: String
        /// The Bonjour domain (almost always `"local."`).
        public var domain: String

        public init(serviceName: String, serviceType: String, domain: String = "local.") {
            self.serviceName = serviceName
            self.serviceType = serviceType
            self.domain = domain
        }
    }

    /// `true` if the device was seen advertising on either service type.
    public var isPresent: Bool
    /// The first matching endpoint, if any — used by the TCP probe (step 4).
    public var endpoint: Endpoint?

    public init(isPresent: Bool, endpoint: Endpoint? = nil) {
        self.isPresent = isPresent
        self.endpoint = endpoint
    }

    /// Convenience: not advertising on the network at all.
    public static let absent = BonjourPresence(isPresent: false, endpoint: nil)
}

/// Outcome of the bounded TCP probe against a device's AirPlay service endpoint
/// (brief §4, step 4).
///
/// The three cases map to distinct causes: a connection that goes `.ready` means
/// the port is open but the *session* still failed (`.notResponding`), a
/// `.refused` means something actively rejected us (`.refusedOrBusy`), and a
/// `.timedOut` means the port never answered within the bound (`.notResponding`,
/// same as ready per the brief — reachable-ish but not cooperating).
public enum TCPProbeResult: Sendable {
    /// The connection reached `.ready` — the port is open.
    case ready
    /// The connection was actively refused (RST / `.refused` posix error).
    case refused
    /// The connection never resolved within the probe bound.
    case timedOut
}

/// The real ``ConnectionDiagnosing`` implementation: turns raw evidence — the
/// OwnTone auth flags, the engine log, live Bonjour presence, and a TCP probe —
/// into one plain-English ``ConnectionFailure`` (design brief §4).
///
/// Every side-effecting step is behind an injectable, `@Sendable` closure seam so
/// unit tests can drive the whole decision matrix without any real network or
/// filesystem access; the *default* closures wire up `Network.framework`
/// (`NWBrowser` + `NWConnection`) and read the engine log off disk.
/// `diagnose(_:)` is bounded (~2 s browse, 3 s
/// probe, well under the 4 s contract) and **never throws** — on any internal
/// error it falls back to the caller's `priorCause`.
///
/// Decision order (first hit wins), per brief §4:
/// 1. `context.requiresAuth` → `.authRequired`.
/// 2. Engine log (dev-only, best-effort): scan the tail for lines naming the
///    device, newest first, and map known patterns to causes. The matched line
///    always becomes `detail`.
/// 3. Bonjour presence: absent from both `_airplay._tcp` and `_raop._tcp` →
///    `.vanished`.
/// 4. TCP probe of the matched endpoint: `.ready`/timeout → `.notResponding`,
///    refused → `.refusedOrBusy`.
/// 5. Nothing conclusive → `context.priorCause` (or `.unknown`), keeping any
///    log-line detail we captured along the way.
public struct NetworkConnectionDiagnostics: ConnectionDiagnosing {

    /// Environment variable naming the OwnTone engine log to scan (step 2). When
    /// unset we fall back to ``defaultLogPath``.
    public static let logPathEnvironmentVariable = "AIRPLAY_OWNTONE_LOG"

    /// Dev default engine-log path, relative to the current working directory —
    /// where the offline dummy rig writes it (`dev/owntone/log/owntone.log`).
    /// Absent/unreadable → the log step is silently skipped.
    public static let defaultLogPath = "dev/owntone/log/owntone.log"

    /// How long the Bonjour browse runs before we conclude "not present".
    private static let browseBound: TimeInterval = 2.0
    /// How long the TCP probe waits for a verdict.
    private static let probeBound: TimeInterval = 3.0

    private let bonjour: @Sendable (_ deviceName: String) async -> BonjourPresence
    private let tcpProbe: @Sendable (_ endpoint: BonjourPresence.Endpoint) async -> TCPProbeResult
    private let logTail: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - bonjour: Browses the network for the device (default: `NWBrowser` over
    ///     `_airplay._tcp` + `_raop._tcp`, bounded to ~2 s).
    ///   - tcpProbe: Dials a matched service endpoint (default: `NWConnection`,
    ///     bounded to 3 s, classifying `.ready` / refused / timeout).
    ///   - logTail: Returns the last ~32 KB of the engine log, or `nil` if
    ///     unavailable (default: reads ``logPathEnvironmentVariable`` /
    ///     ``defaultLogPath``).
    ///   - now: Clock seam (default `Date.init`).
    public init(
        bonjour: @escaping @Sendable (_ deviceName: String) async -> BonjourPresence = NetworkConnectionDiagnostics.defaultBonjour,
        tcpProbe: @escaping @Sendable (_ endpoint: BonjourPresence.Endpoint) async -> TCPProbeResult = NetworkConnectionDiagnostics.defaultTCPProbe,
        logTail: @escaping @Sendable () -> String? = NetworkConnectionDiagnostics.defaultLogTail,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bonjour = bonjour
        self.tcpProbe = tcpProbe
        self.logTail = logTail
        self.now = now
    }

    // MARK: - Decision

    public func diagnose(_ context: DiagnosisContext) async -> ConnectionFailure {
        // Step 1 — auth flag wins outright. If OwnTone told us the output needs a
        // password/pairing there's nothing to probe: it can't work today.
        if context.requiresAuth {
            return ConnectionFailure(cause: .authRequired)
        }

        // Step 2 — engine log (best-effort, dev-only). Any matched line becomes
        // the running `detail` even if the pattern isn't itself conclusive, so
        // "Copy details" always carries the most relevant evidence we saw.
        var detail: String?
        if let match = matchLog(deviceName: context.deviceName) {
            detail = match.line
            if let cause = match.cause {
                return ConnectionFailure(cause: cause, detail: match.line)
            }
            // A "failed to activate" line (no cause) → keep probing, retain detail.
        }

        // Step 3 — Bonjour presence. Absent from both service types is the
        // clearest "it's gone" signal.
        let presence = await bonjour(context.deviceName)
        guard presence.isPresent else {
            return ConnectionFailure(cause: .vanished, detail: detail)
        }

        // Step 4 — TCP probe of the matched endpoint (if we have one). Open port
        // or timeout → reachable but not cooperating; refused → busy/exclusive.
        if let endpoint = presence.endpoint {
            switch await tcpProbe(endpoint) {
            case .ready, .timedOut:
                return ConnectionFailure(cause: .notResponding, detail: detail)
            case .refused:
                return ConnectionFailure(cause: .refusedOrBusy, detail: detail)
            }
        }

        // Step 5 — nothing conclusive: fall back to whatever the backend already
        // inferred, keeping any log evidence.
        return ConnectionFailure(cause: context.priorCause, detail: detail)
    }

    // MARK: - Step 2: engine-log matching

    /// One matched engine-log line and the cause it implies (nil = keep probing).
    private struct LogMatch {
        var line: String
        var cause: ConnectionFailure.Cause?
    }

    /// Scan the log tail for lines naming `deviceName` (case-insensitive), newest
    /// first, and map known substrings to causes. See the pattern table in
    /// ``patternCause(for:)``.
    private func matchLog(deviceName: String) -> LogMatch? {
        guard let tail = logTail() else { return nil }
        let needle = deviceName.lowercased()
        // Newest first: OwnTone appends, so the freshest evidence is at the end.
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines.reversed() {
            let line = String(raw)
            guard line.lowercased().contains(needle) else { continue }
            return LogMatch(line: line, cause: patternCause(for: line))
        }
        return nil
    }

    /// The brief §4 log-pattern → cause table. Order matters: the more specific
    /// patterns are checked before the catch-all "failed to activate" (which maps
    /// to `nil` = "keep probing, but retain this line as detail").
    private func patternCause(for line: String) -> ConnectionFailure.Cause? {
        let lowered = line.lowercased()
        if lowered.contains("no response from") {
            return .notResponding
        }
        if lowered.contains("403") {
            return .refusedOrBusy
        }
        if lowered.contains("auth") || lowered.contains("pair") || lowered.contains("password") {
            return .authRequired
        }
        // "failed to activate" alone isn't conclusive — keep it as `detail` and
        // let Bonjour/the TCP probe decide.
        return nil
    }

    // MARK: - Default seams (real Network.framework / filesystem)

    /// Reads the engine log named by ``logPathEnvironmentVariable`` (default
    /// ``defaultLogPath``, relative to CWD) and returns its last ~32 KB, or `nil`
    /// if the file is missing/unreadable. Best-effort: any error → `nil`.
    public static let defaultLogTail: @Sendable () -> String? = {
        let env = ProcessInfo.processInfo.environment
        let path = env[logPathEnvironmentVariable] ?? defaultLogPath
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let tailByteCount: UInt64 = 32 * 1024
        do {
            let size = try handle.seekToEnd()
            let offset = size > tailByteCount ? size - tailByteCount : 0
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Real Bonjour browse: runs an `NWBrowser` over `_airplay._tcp` and
    /// `_raop._tcp` for ~2 s, matching an `_airplay` instance whose name equals
    /// `deviceName`, or a `_raop` instance whose name ends `"@\(deviceName)"`.
    /// Returns the first match's endpoint (or `.absent`).
    public static let defaultBonjour: @Sendable (_ deviceName: String) async -> BonjourPresence = { deviceName in
        await browse(deviceName: deviceName, timeout: browseBound)
    }

    private static func browse(deviceName: String, timeout: TimeInterval) async -> BonjourPresence {
        let serviceTypes = ["_airplay._tcp", "_raop._tcp"]
        for serviceType in serviceTypes {
            if let endpoint = await browseOne(serviceType: serviceType, deviceName: deviceName, timeout: timeout) {
                return BonjourPresence(isPresent: true, endpoint: endpoint)
            }
        }
        return .absent
    }

    /// Browse a single service type, resolving to the first matching endpoint or
    /// `nil` on timeout. Uses a one-shot continuation guarded so it fires exactly
    /// once, and always cancels the browser.
    private static func browseOne(
        serviceType: String,
        deviceName: String,
        timeout: TimeInterval
    ) async -> BonjourPresence.Endpoint? {
        let matcher = BrowseMatcher(serviceType: serviceType, deviceName: deviceName)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: "local."),
            using: parameters
        )
        return await withTaskGroup(of: BonjourPresence.Endpoint?.self) { group in
            group.addTask {
                // STABILITY(D5): legacy OwnTone backend - browse continuation never resumed on .cancelled — see dev/notes/stability-audit-2026-07-18.md
                await withCheckedContinuation { (continuation: CheckedContinuation<BonjourPresence.Endpoint?, Never>) in
                    let box = ContinuationBox(continuation)
                    browser.browseResultsChangedHandler = { results, _ in
                        for result in results {
                            if case let .service(name, _, _, _) = result.endpoint,
                               let endpoint = matcher.match(instanceName: name) {
                                box.resume(with: endpoint)
                                return
                            }
                        }
                    }
                    browser.stateUpdateHandler = { state in
                        if case .failed = state { box.resume(with: nil) }
                    }
                    browser.start(queue: .global())
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            browser.cancel()
            return first
        }
    }

    /// Real TCP probe: opens an `NWConnection` to the resolved Bonjour endpoint
    /// and classifies the outcome (`.ready` / refused / timeout) within 3 s.
    public static let defaultTCPProbe: @Sendable (_ endpoint: BonjourPresence.Endpoint) async -> TCPProbeResult = { endpoint in
        await probe(endpoint: endpoint, timeout: probeBound)
    }

    private static func probe(endpoint: BonjourPresence.Endpoint, timeout: TimeInterval) async -> TCPProbeResult {
        let nwEndpoint = NWEndpoint.service(
            name: endpoint.serviceName,
            type: endpoint.serviceType,
            domain: endpoint.domain,
            interface: nil
        )
        let connection = NWConnection(to: nwEndpoint, using: .tcp)
        return await withTaskGroup(of: TCPProbeResult.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<TCPProbeResult, Never>) in
                    let box = ProbeContinuationBox(continuation)
                    connection.stateUpdateHandler = { state in
                        if let verdict = probeVerdict(for: state) {
                            box.resume(with: verdict)
                        }
                    }
                    connection.start(queue: .global())
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            connection.cancel()
            return result
        }
    }

    /// Classify one `NWConnection` state transition into a probe verdict, or
    /// `nil` to keep waiting for the next transition (the 3 s task-group bound
    /// is the backstop). Per Apple's `NWConnection` documentation `.waiting` is
    /// *transient* — the connection can still reach `.ready` when a viable path
    /// comes up — so only an active refusal is a verdict there; a hard `.failed`
    /// is terminal. POSIX `ECONNREFUSED` is how an actively-refused port
    /// surfaces (usually via `.waiting`, since the connection keeps retrying).
    /// Internal (not `private`) so tests can drive this matrix directly — the
    /// real handler lives behind the `tcpProbe` seam and never runs in unit
    /// tests.
    static func probeVerdict(for state: NWConnection.State) -> TCPProbeResult? {
        switch state {
        case .ready:
            return .ready
        case let .waiting(error):
            if case let .posix(code) = error, code == .ECONNREFUSED { return .refused }
            // Any other waiting error (e.g. EHOSTUNREACH/ENETDOWN during a
            // path change) is recoverable — let the bound decide.
            return nil
        case let .failed(error):
            if case let .posix(code) = error, code == .ECONNREFUSED { return .refused }
            // A hard failure that never reached ready within the bound.
            return .timedOut
        default:
            return nil
        }
    }
}

// MARK: - Small helpers

/// Matches Bonjour instance names to a device name per the two service-type
/// conventions: `_airplay` advertises the plain device name; `_raop` advertises
/// `"<MAC>@<deviceName>"`.
private struct BrowseMatcher {
    let serviceType: String
    let deviceName: String

    func match(instanceName: String) -> BonjourPresence.Endpoint? {
        let isRAOP = serviceType.hasPrefix("_raop")
        let matches: Bool
        if isRAOP {
            matches = instanceName.lowercased().hasSuffix("@\(deviceName.lowercased())")
        } else {
            matches = instanceName.caseInsensitiveCompare(deviceName) == .orderedSame
        }
        guard matches else { return nil }
        return BonjourPresence.Endpoint(serviceName: instanceName, serviceType: serviceType)
    }
}

/// One-shot wrapper so a Network handler that can fire repeatedly only resumes
/// its continuation once. `NWBrowser`/`NWConnection` callbacks arrive on the
/// browse queue; the internal lock keeps the check-and-set atomic.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BonjourPresence.Endpoint?, Never>?

    init(_ continuation: CheckedContinuation<BonjourPresence.Endpoint?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: BonjourPresence.Endpoint?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// The `TCPProbeResult` twin of ``ContinuationBox`` — the connection's state
/// handler can transition more than once, so only the first verdict counts.
private final class ProbeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TCPProbeResult, Never>?

    init(_ continuation: CheckedContinuation<TCPProbeResult, Never>) {
        self.continuation = continuation
    }

    func resume(with value: TCPProbeResult) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
