import Foundation
import XCTest

final class InstallerPreflightTests: XCTestCase {
    /// Exercise the actual installer's include matcher against sudoers fixtures.
    /// No installer execution, root permissions, or real sudoers access is needed.
    private func accepts(_ fixture: String) throws -> Bool {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install-grant.sh"), encoding: .utf8)
        let matcher = try NSRegularExpression(pattern: "grep -qsE '([^']+)'")
        let range = NSRange(script.startIndex..., in: script)
        let match = try XCTUnwrap(matcher.firstMatch(in: script, range: range))
        let patternRange = try XCTUnwrap(Range(match.range(at: 1), in: script))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-qE", String(script[patternRange])]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(fixture.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertTrue([0, 1].contains(process.terminationStatus), "Include matcher must be a valid regex")
        return process.terminationStatus == 0
    }

    func testAcceptsMacOSPrivateEtcInclude() throws {
        XCTAssertTrue(try accepts("#includedir /private/etc/sudoers.d\n"))
        XCTAssertTrue(try accepts("@includedir /private/etc/sudoers.d\n"))
    }

    func testAcceptsEtcAliasQuotesWhitespaceAndTrailingSlash() throws {
        for line in [
            "#includedir /etc/sudoers.d",
            "@includedir /etc/sudoers.d/",
            "  @includedir\t\"/private/etc/sudoers.d\" # drop-ins",
            "#includedir \"/etc/sudoers.d/\"",
        ] {
            XCTAssertTrue(try accepts(line + "\n"), line)
        }
    }

    func testRejectsCommentsAndOtherDirectories() throws {
        for line in [
            "# @includedir /private/etc/sudoers.d",
            "# Read files from /etc/sudoers.d",
            "@includedir /etc/sudoers.d-other",
            "@includedir /etc/sudoersXd",
            "@includedir /etc/sudoers.d/nested",
            "@includedir /somewhere/else",
            "@includedir \"/etc/sudoers.d",
        ] {
            XCTAssertFalse(try accepts(line + "\n"), line)
        }
    }
}
