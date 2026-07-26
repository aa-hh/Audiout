import Testing
import Foundation

/// Regression test: ensures that the incorrect Core Audio selector
/// `kAudioHardwarePropertyDefaultSystemOutputDevice` (the alert-sound device,
/// meant for system beeps) never appears in real source code.
///
/// The correct selector is `kAudioHardwarePropertyDefaultOutputDevice` (the
/// current audio output device). This bug has drifted back into the codebase
/// twice before and silently breaks audio routing. This test fails immediately
/// if the bad selector ever appears in non-comment code again.
@Suite final class OutputSelectorGuardTests: IsolatedSuite {

    @Test func defaultSystemOutputDeviceSelectorNeverUsedInRealCode() throws {
        // Resolve the source directories from this test file's location.
        let testFilePath = URL(fileURLWithPath: #filePath)

        // Walk up from the test file to find AudiouterCore root:
        // #filePath = /path/to/.../AudiouterCore/Tests/AudiouterCoreTests/OutputSelectorGuardTests.swift
        // Target: /path/to/.../AudiouterCore/Sources
        let fileURL = testFilePath
        let audiouterCoreRoot = fileURL
            .deletingLastPathComponent()  // OutputSelectorGuardTests.swift → AudiouterCoreTests
            .deletingLastPathComponent()  // AudiouterCoreTests → Tests
            .deletingLastPathComponent()  // Tests → AudiouterCore

        let audiouterCoreSources = audiouterCoreRoot.appendingPathComponent("Sources", isDirectory: true)

        // Also check AirPlayEngine/Sources if it's a sibling package
        let parentDir = audiouterCoreRoot.deletingLastPathComponent()
        let airPlayEngineSources = parentDir.appendingPathComponent("AirPlayEngine/Sources", isDirectory: true)

        var violations: [(filePath: String, lineNumber: Int, line: String)] = []

        // Check both source directories
        for sourceDir in [audiouterCoreSources, airPlayEngineSources] {
            violations += try checkSourceDirectory(sourceDir)
        }

        if !violations.isEmpty {
            var message = "ERROR: kAudioHardwarePropertyDefaultSystemOutputDevice found in real code:\n\n"
            for violation in violations {
                message += "\(violation.filePath):\(violation.lineNumber)\n"
                message += "  \(violation.line.trimmingCharacters(in: .whitespaces))\n"
            }
            message += "\nUSE kAudioHardwarePropertyDefaultOutputDevice INSTEAD (the actual current output device, not the alert-sound device)."
            Issue.record("\(message)")
        }
    }

    private func checkSourceDirectory(_ sourceDir: URL) throws -> [(filePath: String, lineNumber: Int, line: String)] {
        var violations: [(filePath: String, lineNumber: Int, line: String)] = []

        // Verify the directory exists before walking it
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            // Directory doesn't exist (e.g., AirPlayEngine not present in this package structure)
            return violations
        }

        // Recursively find all .swift files
        guard let enumerator = FileManager.default.enumerator(atPath: sourceDir.path) else {
            return violations
        }

        for case let file as String in enumerator {
            guard file.hasSuffix(".swift") else { continue }

            let filePath = sourceDir.appendingPathComponent(file)
            let contents = try String(contentsOf: filePath, encoding: .utf8)

            let fileViolations = checkFileForBadSelector(contents, filePath: filePath.path)
            violations.append(contentsOf: fileViolations)
        }

        return violations
    }

    /// Check a single file's contents for the bad selector.
    /// Uses a line-based heuristic to strip comments:
    /// - Remove everything after `//` on each line (line comments)
    /// - Track `/* */` block comments by maintaining state across lines
    /// - Search for the bad selector in the remaining code
    private func checkFileForBadSelector(_ contents: String, filePath: String) -> [(filePath: String, lineNumber: Int, line: String)] {
        let lines = contents.components(separatedBy: .newlines)
        var violations: [(filePath: String, lineNumber: Int, line: String)] = []

        var inBlockComment = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1

            // Process the line to strip comments
            var processedLine = ""
            var currentIndex = line.startIndex

            while currentIndex < line.endIndex {
                // Check for block comment open
                if !inBlockComment {
                    if currentIndex < line.index(line.endIndex, offsetBy: -1) {
                        let nextIdx = line.index(after: currentIndex)
                        let twoChar = String(line[currentIndex..<line.index(after: nextIdx)])
                        if twoChar == "/*" {
                            inBlockComment = true
                            currentIndex = line.index(after: nextIdx)
                            continue
                        }
                    }

                    // Check for line comment
                    if currentIndex < line.index(line.endIndex, offsetBy: -1) {
                        let nextIdx = line.index(after: currentIndex)
                        let twoChar = String(line[currentIndex..<line.index(after: nextIdx)])
                        if twoChar == "//" {
                            // Rest of line is a comment, stop processing
                            break
                        }
                    }

                    // Not in a comment, add this character
                    processedLine.append(line[currentIndex])
                } else {
                    // We're in a block comment, look for the close
                    if currentIndex < line.index(line.endIndex, offsetBy: -1) {
                        let nextIdx = line.index(after: currentIndex)
                        let twoChar = String(line[currentIndex..<line.index(after: nextIdx)])
                        if twoChar == "*/" {
                            inBlockComment = false
                            currentIndex = line.index(after: nextIdx)
                            continue
                        }
                    }
                }

                currentIndex = line.index(after: currentIndex)
            }

            // Now check the processed line for the bad selector
            if processedLine.contains("kAudioHardwarePropertyDefaultSystemOutputDevice") {
                violations.append((filePath: filePath, lineNumber: lineNumber, line: line))
            }
        }

        return violations
    }
}
