import Foundation
import Testing

/// The `until` half of `AudioutCoreTests/SuiteWait.swift`, copied verbatim
/// because the two packages cannot share test code.
enum SuiteWait {

    /// The one deadline, sized to match the AudioutCoreTests helper.
    static let timeout: TimeInterval = 30

    /// Poll `condition` from an async context until it holds.
    ///
    /// `description` is what the reader needs in the failure message: name the
    /// state being waited FOR, not the act of waiting ("the coordinator reaches
    /// .running", not "waiting for state").
    static func until(
        _ description: @autoclosure () -> String = "condition to hold",
        timeout: TimeInterval? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let limit = timeout ?? Self.timeout
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard timeout == nil else { return }   // explicit deadline: expiry is the point
        // Fail CLOSED, at the caller. A silent return here is what let a
        // starved wait masquerade as the next assertion's failure.
        Issue.record(
            "timed out after \(limit)s waiting for \(description())",
            sourceLocation: sourceLocation
        )
    }
}
