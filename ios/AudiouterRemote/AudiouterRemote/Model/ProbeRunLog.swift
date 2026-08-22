// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ProbeKit

/// Persisted history of alignment-probe runs, for the longitudinal
/// ear-vs-probe study (dev/notes/bt-autocal-spike-spec.md follow-up): every
/// analysis lands here with a timestamp so multi-session numbers accumulate
/// without screenshots. razor: spike tooling — one JSON file in Documents,
/// newest first, capped; graduates or dies with the probe.
struct ProbeRunRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let targetDeviceID: String
    let targetName: String
    let referenceName: String
    let offsetMs: Double
    let spreadMs: Double
    let usedPairs: Int
    let confident: Bool
    let recordedSeconds: Double
    /// The target's sync trim (ms) the run was measured under, from the
    /// snapshot — nil when the Mac build predates the field.
    let trimMsAtRun: Double?
    var applied: Bool
    /// Alec's by-ear verdict for the session, set from the history row:
    /// nil = not judged, true = sounded in sync BEFORE this run, false = flam.
    var earSaidInSync: Bool?
}

enum ProbeRunLog {
    private static let cap = 200

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("probe-run-log.json")
    }

    static func load() -> [ProbeRunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProbeRunRecord].self, from: data)) ?? []
    }

    @discardableResult
    static func append(_ record: ProbeRunRecord) -> [ProbeRunRecord] {
        var all = load()
        all.insert(record, at: 0)
        if all.count > cap { all.removeLast(all.count - cap) }
        save(all)
        return all
    }

    static func update(_ record: ProbeRunRecord) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == record.id }) else { return }
        all[index] = record
        save(all)
    }

    /// The whole log as shareable JSON (AirDrop to the Mac for analysis).
    static func exportURL() -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func save(_ records: [ProbeRunRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) { try? data.write(to: url) }
    }
}
