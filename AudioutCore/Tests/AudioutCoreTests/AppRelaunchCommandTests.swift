// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

@Suite struct AppRelaunchCommandTests {

    // MARK: singleQuoted

    @Test func singleQuotedWrapsPlainPath() {
        #expect(AppRelaunchCommand.singleQuoted("/Applications/Audiout.app") ==
                       "'/Applications/Audiout.app'")
    }

    @Test func singleQuotedPreservesSpaces() {
        // The app's real path contains a space — the quoting must keep it intact
        // as ONE argument through `sh -c`.
        #expect(
            AppRelaunchCommand.singleQuoted("/Users/x/AirPlay Controller/build/Audiout.app") ==
            "'/Users/x/AirPlay Controller/build/Audiout.app'")
    }

    @Test func singleQuotedEscapesEmbeddedSingleQuote() {
        // A path with a literal apostrophe must use the '\'' close-escape-reopen
        // idiom so the shell sees the exact bytes.
        #expect(AppRelaunchCommand.singleQuoted("/Users/o'brien/App.app") ==
                       "'/Users/o'\\''brien/App.app'")
    }

    // MARK: shellInvocation

    @Test func shellInvocationShape() {
        let argv = AppRelaunchCommand.shellInvocation(pid: 4242, bundlePath: "/tmp/A.app")
        #expect(argv.count == 3)
        #expect(argv[0] == "/bin/sh")
        #expect(argv[1] == "-c")
    }

    @Test func shellInvocationWaitsOnPidThenOpensQuotedBundle() {
        let argv = AppRelaunchCommand.shellInvocation(
            pid: 4242, bundlePath: "/Users/x/AirPlay Controller/build/Audiout.app")
        let script = argv[2]
        // Waits on the captured pid…
        #expect(script.contains("/bin/kill -0 4242"), "should poll the captured pid: \(script)")
        // …then reopens the space-containing path as a single quoted argument.
        #expect(
            script.contains("/usr/bin/open '/Users/x/AirPlay Controller/build/Audiout.app'"),
            "should open the quoted bundle path: \(script)")
        // The open must come AFTER the wait loop, never before it.
        let killIndex = script.range(of: "/bin/kill -0")!.lowerBound
        let openIndex = script.range(of: "/usr/bin/open")!.lowerBound
        #expect(killIndex < openIndex, "must wait for exit before reopening")
    }
}
