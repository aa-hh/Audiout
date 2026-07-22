// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

final class AppRelaunchCommandTests: XCTestCase {

    // MARK: singleQuoted

    func testSingleQuotedWrapsPlainPath() {
        XCTAssertEqual(AppRelaunchCommand.singleQuoted("/Applications/Audiouter.app"),
                       "'/Applications/Audiouter.app'")
    }

    func testSingleQuotedPreservesSpaces() {
        // The app's real path contains a space — the quoting must keep it intact
        // as ONE argument through `sh -c`.
        XCTAssertEqual(
            AppRelaunchCommand.singleQuoted("/Users/x/AirPlay Controller/build/Audiouter.app"),
            "'/Users/x/AirPlay Controller/build/Audiouter.app'")
    }

    func testSingleQuotedEscapesEmbeddedSingleQuote() {
        // A path with a literal apostrophe must use the '\'' close-escape-reopen
        // idiom so the shell sees the exact bytes.
        XCTAssertEqual(AppRelaunchCommand.singleQuoted("/Users/o'brien/App.app"),
                       "'/Users/o'\\''brien/App.app'")
    }

    // MARK: shellInvocation

    func testShellInvocationShape() {
        let argv = AppRelaunchCommand.shellInvocation(pid: 4242, bundlePath: "/tmp/A.app")
        XCTAssertEqual(argv.count, 3)
        XCTAssertEqual(argv[0], "/bin/sh")
        XCTAssertEqual(argv[1], "-c")
    }

    func testShellInvocationWaitsOnPidThenOpensQuotedBundle() {
        let argv = AppRelaunchCommand.shellInvocation(
            pid: 4242, bundlePath: "/Users/x/AirPlay Controller/build/Audiouter.app")
        let script = argv[2]
        // Waits on the captured pid…
        XCTAssertTrue(script.contains("/bin/kill -0 4242"), "should poll the captured pid: \(script)")
        // …then reopens the space-containing path as a single quoted argument.
        XCTAssertTrue(
            script.contains("/usr/bin/open '/Users/x/AirPlay Controller/build/Audiouter.app'"),
            "should open the quoted bundle path: \(script)")
        // The open must come AFTER the wait loop, never before it.
        let killIndex = script.range(of: "/bin/kill -0")!.lowerBound
        let openIndex = script.range(of: "/usr/bin/open")!.lowerBound
        XCTAssertLessThan(killIndex, openIndex, "must wait for exit before reopening")
    }
}
