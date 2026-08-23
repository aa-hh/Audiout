// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

// cast-spike — the roadmap 006 Phase-0 measurement CLI.
//
// Connects to a Cast receiver, launches the Default Media Receiver, serves it
// a live WAV stream, and prints how long every step took. `--fake` runs the
// whole thing against an in-process fake receiver, so the tooling is proven
// before any hardware exists; `--device` runs it against the real thing.

import CastFakeReceiver
import CastSender
import Foundation
import Network

// MARK: - Argument parsing (dependency-free, like dev/audiocap)

struct Options {
    enum Mode {
        case list
        case fake
        case device(String)
        case host(String)
    }

    var mode: Mode?
    var holdSeconds: Double = 20
    var volumeLevel: Double = 0.3
    var streamHost: String?
    var primeMilliseconds: Int = 0
    var streamType = "LIVE"
    var appID = CastClient.defaultMediaReceiverAppID
    var autoplay = true
}

struct UsageError: Error {
    let message: String
}

func parseArgs(_ args: [String]) throws -> Options {
    var options = Options()
    var modeFlags = 0
    var index = 0
    while index < args.count {
        let argument = args[index]
        func next(_ what: String) throws -> String {
            index += 1
            guard index < args.count else { throw UsageError(message: "\(argument) requires \(what)") }
            return args[index]
        }
        switch argument {
        case "--list":
            modeFlags += 1
            options.mode = .list
        case "--fake":
            modeFlags += 1
            options.mode = .fake
        case "--device":
            modeFlags += 1
            options.mode = .device(try next("a name substring"))
        case "--host":
            modeFlags += 1
            options.mode = .host(try next("an ip[:port]"))
        case "--hold":
            let raw = try next("a number of seconds")
            guard let value = Double(raw), value >= 0 else { throw UsageError(message: "--hold: '\(raw)' is not a number of seconds") }
            options.holdSeconds = value
        case "--volume":
            let raw = try next("a level from 0 to 1")
            guard let value = Double(raw), value >= 0, value <= 1 else { throw UsageError(message: "--volume: '\(raw)' is not a level from 0 to 1") }
            options.volumeLevel = value
        case "--stream-host":
            options.streamHost = try next("an IP address")
        case "--stream-type":
            let raw = try next("LIVE, BUFFERED or NONE").uppercased()
            guard ["LIVE", "BUFFERED", "NONE"].contains(raw) else { throw UsageError(message: "--stream-type: '\(raw)' is not LIVE, BUFFERED or NONE") }
            options.streamType = raw
        case "--no-autoplay":
            options.autoplay = false
        case "--app-id":
            options.appID = try next("a Cast app id")
        case "--prime-ms":
            let raw = try next("a number of milliseconds")
            guard let value = Int(raw), value >= 0 else { throw UsageError(message: "--prime-ms: '\(raw)' is not a number of milliseconds") }
            options.primeMilliseconds = value
        default:
            throw UsageError(message: "unknown argument: \(argument)")
        }
        index += 1
    }
    // Two modes would silently run only the last one named.
    guard modeFlags == 1 else {
        throw UsageError(message: "give exactly one of --list, --fake, --device or --host")
    }
    return options
}

let usage = """
cast-spike — Google Cast Phase-0 measurement (roadmap 006)

USAGE:
  cast-spike --list
  cast-spike --fake [OPTIONS]
  cast-spike --device <name substring> [OPTIONS]
  cast-spike --host <ip[:port]> [OPTIONS]

MODES:
  --list                 browse _googlecast._tcp for 5s and print what answers
  --fake                 run against an in-process fake receiver (macOS 15+)
  --device <substring>   run against the first device whose name contains it
  --host <ip[:port]>     skip Bonjour and connect to an address (port 8009)

OPTIONS:
  --hold <seconds>       how long to keep playing before pausing (default 20)
  --volume <0..1>        the level to set and time (default 0.3)
  --stream-host <ip>     the address the receiver fetches audio from
  --prime-ms <n>         milliseconds of audio to send up front (default 0)
  --stream-type <t>      Cast streamType for LOAD: LIVE (default), BUFFERED, NONE
  --no-autoplay          LOAD with autoplay=false, then an explicit PLAY (AirConnect)
  --app-id <id>          receiver app to launch (default CC1AD845; AirConnect uses 46C1A819)
"""

// MARK: - Run

/// Top-level state a network callback writes and the main thread reads.
final class Exit: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32 = 0
    let done = DispatchSemaphore(value: 0)

    func finish(_ code: Int32) {
        lock.withLock { self.code = code }
        done.signal()
    }

    var status: Int32 { lock.withLock { code } }
}

/// A one-shot latch: `claim()` returns true exactly once. The browse callback
/// and the browse deadline race, and only one of them may act.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// Keeps the browser, the fake receiver and the run alive for the life of the
/// process. Nothing else owns them: a `let` inside a `switch` case dies at the
/// end of that case, and the failure is silent rather than loud — the objects
/// hold their network callbacks `weak`, so the sockets simply stop answering.
let retainer = Retainer()

final class Retainer: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject] = []
    func keep(_ object: AnyObject) { lock.withLock { objects.append(object) } }
}

func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "nil"
}

/// Runs the spike against `endpoint` and signals `exit` when it is over.
func spike(endpoint: NWEndpoint, options: Options, loopbackOnly: Bool, exit: Exit) {
    let run = CastSpikeRun(
        options: CastSpikeRun.Options(
            endpoint: endpoint,
            streamHost: options.streamHost,
            loopbackOnly: loopbackOnly,
            holdSeconds: options.holdSeconds,
            volumeLevel: options.volumeLevel,
            primeMilliseconds: options.primeMilliseconds,
            streamType: options.streamType,
            appID: options.appID,
            autoplay: options.autoplay
        ),
        log: { print($0) }
    )
    retainer.keep(run)
    run.run { result in
        switch result {
        case .failure:
            exit.finish(1)
        case .success(let summary):
            print("summary load_to_playing_ms=\(format(summary.loadToPlayingMs))"
                + " buffering_to_playing_ms=\(format(summary.bufferingToPlayingMs))"
                + " volume_roundtrip_ms=\(format(summary.volumeRoundTripMs))"
                + " pause_roundtrip_ms=\(format(summary.pauseRoundTripMs))"
                + " resume_roundtrip_ms=\(format(summary.resumeRoundTripMs))")
            exit.finish(0)
        }
    }
}

// Unbuffered stdout: under a pipe, `print` would otherwise hold every line
// until exit, and a run that hangs would look like one that never started.
setvbuf(stdout, nil, _IONBF, 0)

let options: Options
do {
    options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
} catch let error as UsageError {
    print(error.message)
    print(usage)
    Foundation.exit(2)
}

guard let mode = options.mode else {
    print(usage)
    Foundation.exit(2)
}

let exitState = Exit()

switch mode {
case .list:
    let browser = CastBrowser()
    retainer.keep(browser)
    // Every browse update carries the WHOLE device list, not a delta, so a
    // device would print again on each change without this.
    var printed: Set<String> = []
    browser.onUpdate = { devices in
        for device in devices where printed.insert(device.id).inserted {
            print("id=\(device.id) fn=\(device.friendlyName) md=\(device.model ?? "nil") endpoint=\(device.endpoint)")
        }
    }
    browser.start()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        browser.stop()
        exitState.finish(0)
    }

case .fake:
    guard #available(macOS 15, *) else {
        print("--fake needs macOS 15: the fake receiver's TLS identity is imported with kSecImportToMemoryOnly")
        Foundation.exit(1)
    }
    var fakeOptions = options
    fakeOptions.streamHost = options.streamHost ?? "127.0.0.1"
    let fake = FakeCastReceiver()
    retainer.keep(fake)
    fake.start { result in
        switch result {
        case .failure(let error):
            print("error=\(error)")
            exitState.finish(1)
        case .success(let endpoint):
            spike(endpoint: endpoint, options: fakeOptions, loopbackOnly: true, exit: exitState)
        }
    }

case .device(let substring):
    let browser = CastBrowser()
    retainer.keep(browser)
    let chosen = Once()
    browser.onUpdate = { devices in
        guard let match = devices.first(where: { $0.friendlyName.range(of: substring, options: .caseInsensitive) != nil }),
              chosen.claim() else { return }
        print("device id=\(match.id) fn=\(match.friendlyName) endpoint=\(match.endpoint)")
        browser.stop()
        spike(endpoint: match.endpoint, options: options, loopbackOnly: false, exit: exitState)
    }
    browser.start()
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        guard chosen.claim() else { return }
        browser.stop()
        print("error=no device whose name contains '\(substring)' answered within 10s")
        exitState.finish(1)
    }

case .host(let spec):
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard let host = parts.first, !host.isEmpty,
          let port = NWEndpoint.Port(parts.count > 1 ? parts[1] : "8009") else {
        print("error=--host wants ip[:port], got '\(spec)'")
        Foundation.exit(2)
    }
    spike(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port), options: options, loopbackOnly: false, exit: exitState)
}

exitState.done.wait()
Foundation.exit(exitState.status)
