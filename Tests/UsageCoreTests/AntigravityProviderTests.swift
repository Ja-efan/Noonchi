import XCTest
@testable import UsageCore

final class AntigravityProviderTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "agy-usage-1.5.9", withExtension: "json", subdirectory: "Fixtures"))
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func usage(_ json: String) -> Result<ProviderUsage, ProviderFailure> {
        AntigravityProvider.usage(from: Data(json.utf8))
    }

    private func group(_ name: String, _ buckets: String) -> String {
        #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"\#(name)","buckets":[\#(buckets)]}]}}}"#
    }

    /// Recorded from agy 1.5.9, signed in, nothing used yet.
    func testRealOutputBecomesFiveWindows() throws {
        let usage = try AntigravityProvider.usage(from: Data(contentsOf: fixtureURL())).get()
        XCTAssertNil(usage.plan)
        let week = date("2026-11-21T07:48:52Z"), fiveHours = date("2026-11-14T12:48:52Z")
        XCTAssertEqual(usage.windows, [
            UsageWindow(id: "model:Gemini 5h", kind: .model(name: "Gemini 5h", minutes: 300), usedPercent: 0, resetsAt: fiveHours),
            UsageWindow(id: "model:Gemini", kind: .model(name: "Gemini", minutes: 10080), usedPercent: 0, resetsAt: week),
            UsageWindow(id: "model:Claude·GPT 5h", kind: .model(name: "Claude·GPT 5h", minutes: 300), usedPercent: 0,
                        resetsAt: fiveHours),
            UsageWindow(id: "model:Claude·GPT", kind: .model(name: "Claude·GPT", minutes: 10080), usedPercent: 0,
                        resetsAt: week),
            UsageWindow(id: "model:Argon", kind: .model(name: "Argon", minutes: 10080), usedPercent: 0, resetsAt: week),
        ])
        XCTAssertTrue(usage.raw.contains("gemini-argon-wtu-weekly"))
        XCTAssertFalse(usage.raw.contains("conversation_id"))
    }

    func testRemainingFractionBecomesUsedPercent() throws {
        let json = group("Gemini Models", #"{"id":"gemini-5h","window":"5h","remaining_fraction":0.25,"reset_time":"2026-11-14T12:48:52.500Z"}"#)
        let window = try XCTUnwrap(usage(json).get().windows.first)
        XCTAssertEqual(window.usedPercent, 75)
        XCTAssertEqual(window.resetsAt, Date(timeInterval: 0.5, since: date("2026-11-14T12:48:52Z")))
    }

    func testUnknownGroupAndWindowKeepTheirOwnNames() throws {
        let json = group("Imagen", #"{"id":"imagen-weekly","window":"weekly","remaining_fraction":1},{"id":"imagen-daily","window":"daily","remaining_fraction":0.5}"#)
        let windows = try usage(json).get().windows
        XCTAssertEqual(windows.map(\.id), ["model:Imagen", "model:Imagen daily"])
        XCTAssertEqual(windows.map(\.kind.minutes), [10080, nil])
        XCTAssertEqual(windows[1].usedPercent, 50)
    }

    func testErrors() {
        func error(_ json: String) -> ProviderError? {
            guard case .failure(let f) = usage(json) else { return nil }
            return f.error
        }
        XCTAssertEqual(error(#"{"status":"ERROR","error":"authentication failed or timed out"}"#), .notLoggedIn)
        XCTAssertEqual(error(#"{"status":"ERROR","error":"quota service unavailable"}"#), .failed("quota service unavailable"))
        XCTAssertEqual(error("not json"), .unparsable)
        XCTAssertEqual(error(group("Gemini Models", "")), .unparsable)
    }

    func testMenuBarPicksTheShortestMostUsedLimit() throws {
        let json = #"""
        {"status":"SUCCESS","command":{"data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.1},
                                             {"id":"gemini-5h","window":"5h","remaining_fraction":0.7}]},
          {"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.05},
                                                     {"id":"3p-5h","window":"5h","remaining_fraction":0.4}]}]}}}
        """#
        let usage = try usage(json).get()
        XCTAssertEqual(MenuBarFormatter.autoWindow(usage)?.id, "model:Claude·GPT 5h")
        let items = MenuBarFormatter.items(for: [(ProviderID("antigravity"), state(usage))], mode: .auto, selected: [],
                                           labeled: true, highlightHigh: true)
        XCTAssertEqual(items.map(\.text), ["Claude·GPT 5h 60%"])
    }

    private func state(_ usage: ProviderUsage) -> ProviderState {
        var s = ProviderState()
        s.apply(.success(usage))
        return s
    }

    private func read(fake body: String) throws -> (Result<ProviderUsage, ProviderFailure>, dir: URL, seconds: TimeInterval) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("agy")
        try "#!/bin/sh\n\(body)\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("NOONCHI_AGY_PATH", fake.path, 1)
        defer { unsetenv("NOONCHI_AGY_PATH") }
        let start = Date()
        let result = AntigravityProvider(workDirectory: dir.appendingPathComponent("work").path).read()
        return (result, dir, Date().timeIntervalSince(start))
    }

    /// Signed out, agy prints a login URL, opens it, and waits about 60 s.
    func testSignedOutFailsFastWithoutABrowser() throws {
        let (result, dir, seconds) = try read(fake: """
        command -v open > "$(dirname "$0")/which-open"
        echo 'Authentication required. Please visit the URL to log in:' >&2
        echo 'https://accounts.google.com/o/oauth2/auth?client_id=x' >&2
        exec sleep 60
        """)
        guard case .failure(let failure) = result else { return XCTFail("signed out must not read") }
        XCTAssertEqual(failure.error, .notLoggedIn)
        XCTAssertLessThan(seconds, 5)
        let open = try String(contentsOf: dir.appendingPathComponent("which-open"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(open, dir.appendingPathComponent("work/no-browser/open").path)
    }

    func testFakeCLIReadsEndToEnd() throws {
        let (result, _, _) = try read(fake: "cat '\(try fixtureURL().path)'")
        let usage = try result.get()
        XCTAssertEqual(usage.windows.map(\.id),
                       ["model:Gemini 5h", "model:Gemini", "model:Claude·GPT 5h", "model:Claude·GPT", "model:Argon"])
    }
}
