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
        let gemini = "Gemini 4 Hydrogen, Gemini 3.8 Flash", thirdParty = "Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"
        XCTAssertEqual(usage.windows, [
            UsageWindow(id: "model:Gemini 5h", kind: .model(name: "Gemini 5h", minutes: 300), usedPercent: 0,
                        resetsAt: fiveHours, group: "Gemini", groupDetail: gemini),
            UsageWindow(id: "model:Gemini", kind: .model(name: "Gemini", minutes: 10080), usedPercent: 0,
                        resetsAt: week, group: "Gemini", groupDetail: gemini),
            UsageWindow(id: "model:Claude·GPT 5h", kind: .model(name: "Claude·GPT 5h", minutes: 300), usedPercent: 0,
                        resetsAt: fiveHours, group: "Claude·GPT", groupDetail: thirdParty),
            UsageWindow(id: "model:Claude·GPT", kind: .model(name: "Claude·GPT", minutes: 10080), usedPercent: 0,
                        resetsAt: week, group: "Claude·GPT", groupDetail: thirdParty),
            UsageWindow(id: "model:Argon", kind: .model(name: "Argon", minutes: 10080), usedPercent: 0, resetsAt: week,
                        group: "Argon", groupDetail: "Gemini 4 Argon"),
        ])
        XCTAssertEqual(usage.groups.map(\.title), ["Gemini", "Claude·GPT", "Argon"])
        XCTAssertTrue(usage.raw.contains("gemini-argon-wtu-weekly"))
        XCTAssertFalse(usage.raw.contains("conversation_id"))
    }

    /// Recorded from agy 1.5.12: Gemini 4 Neon joined the shared Gemini group, not a group of its own.
    func testNeonSharesTheGeminiGroup() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "agy-usage-1.5.12", withExtension: "json", subdirectory: "Fixtures"))
        let usage = try AntigravityProvider.usage(from: Data(contentsOf: url)).get()
        XCTAssertEqual(usage.groups.map(\.title), ["Gemini", "Claude·GPT", "Argon"])
        let gemini = try XCTUnwrap(usage.windows.first { $0.group == "Gemini" })
        XCTAssertEqual(gemini.groupDetail, "Gemini 4 Neon, Gemini 4 Hydrogen, Orchestrator (Neon), Gemini 3.8 Flash")
    }

    func testRemainingFractionBecomesUsedPercent() throws {
        let json = group("Gemini Models", #"{"id":"gemini-5h","window":"5h","remaining_fraction":0.25,"reset_time":"2026-11-14T12:48:52.500Z"}"#)
        let window = try XCTUnwrap(usage(json).get().windows.first)
        XCTAssertEqual(window.usedPercent, 75)
        XCTAssertEqual(window.resetsAt, Date(timeInterval: 0.5, since: date("2026-11-14T12:48:52Z")))
    }

    /// Carbon's buckets start with "gemini-" too; naming by bucket ID once merged it into Gemini.
    func testANewGeminiGroupGetsItsOwnWindows() throws {
        let json = #"""
        {"status":"SUCCESS","command":{"data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1},
                                             {"id":"gemini-5h","window":"5h","remaining_fraction":1}]},
          {"name":"Gemini 4 Carbon","buckets":[{"id":"gemini-carbon-weekly","window":"weekly","remaining_fraction":0.5},
                                               {"id":"gemini-carbon-5h","window":"5h","remaining_fraction":0.8}]},
          {"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1}]}]}}}
        """#
        let windows = try usage(json).get().windows
        XCTAssertEqual(windows.map(\.id), ["model:Gemini 5h", "model:Gemini", "model:Gemini 2",
                                           "model:Carbon 5h", "model:Carbon"])
        XCTAssertEqual(windows[2].group, "Gemini")
        XCTAssertEqual(windows[3].usedPercent, 20, accuracy: 0.001)
        XCTAssertEqual(windows[4].group, "Carbon")
    }

    func testBlankCarbonGroupMergesWithNamedCarbonGroupAfterFixture() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any])
        var command = try XCTUnwrap(root["command"] as? [String: Any])
        var data = try XCTUnwrap(command["data"] as? [String: Any])
        var groups = try XCTUnwrap(data["groups"] as? [[String: Any]])
        groups.append([
            "name": "Gemini 4 Carbon",
            "buckets": [["id": "gemini-carbon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.75]],
        ])
        groups.append([
            "name": " ",
            "buckets": [["id": "gemini-carbon-5h", "window": "5h", "remaining_fraction": 0.6]],
        ])
        data["groups"] = groups
        command["data"] = data
        root["command"] = command
        let encoded = try JSONSerialization.data(withJSONObject: root)

        let usage = try AntigravityProvider.usage(from: encoded).get()
        let ids = usage.windows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)

        let carbon = usage.windows.filter { $0.group == "Carbon" }
        XCTAssertEqual(carbon.map(\.id), ["model:Carbon 5h", "model:Carbon"])
        XCTAssertEqual(carbon.map(\.kind), [.model(name: "Carbon 5h", minutes: 300), .model(name: "Carbon", minutes: 10080)])
        XCTAssertEqual(usage.groups.map(\.title), ["Gemini", "Claude·GPT", "Argon", "Carbon"])
    }

    func testBlankGroupNameDerivesTitleFromFirstBucketID() throws {
        let unknown = try usage(group("   ", #"{"id":"foo-5h","window":"5h","remaining_fraction":0.5}"#)).get()
        XCTAssertEqual(unknown.windows.map(\.group), ["foo-5h"])
        XCTAssertEqual(unknown.windows.map(\.id), ["model:foo-5h 5h"])
        XCTAssertEqual(unknown.groups.map(\.title), ["foo-5h"])

        let json = #"""
        {"status":"SUCCESS","command":{"data":{"groups":[
          {"name":"","buckets":[{"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":1}]},
          {"name":"\t\n","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":1}]},
          {"name":" ","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":1}]}]}}}
        """#
        let known = try usage(json).get()
        XCTAssertEqual(known.groups.map(\.title), ["Argon", "Claude·GPT", "Gemini"])
    }

    func testUnknownGroupAndWindowKeepTheirOwnNames() throws {
        let json = group("Imagen", #"{"id":"imagen-weekly","window":"weekly","remaining_fraction":1},{"id":"imagen-daily","window":"daily","remaining_fraction":0.5}"#)
        let windows = try usage(json).get().windows
        XCTAssertEqual(windows.map(\.id), ["model:Imagen", "model:Imagen daily"])
        XCTAssertEqual(windows.map(\.kind.minutes), [10080, nil])
        XCTAssertEqual(windows[1].usedPercent, 50)
        XCTAssertEqual(windows.map(\.group), ["Imagen", "Imagen"])
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

    func testHiddenGroupLeavesThePanelAndTheMenuBar() throws {
        let json = #"""
        {"status":"SUCCESS","command":{"data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.7},
                                             {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9}]},
          {"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":0.4},
                                                     {"id":"3p-weekly","window":"weekly","remaining_fraction":0.8}]},
          {"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.9}]}]}}}
        """#
        let usage = try usage(json).get()
        let id = ProviderID("antigravity"), hidden = [id: Set(["Claude·GPT"])]
        XCTAssertEqual(usage.hidingGroups(["Claude·GPT"]).windows.map(\.id),
                       ["model:Gemini 5h", "model:Gemini", "model:Argon"])

        func text(_ mode: MenuBarMode, _ selected: [String], _ hidden: [ProviderID: Set<String>]) -> [String] {
            MenuBarFormatter.items(for: [(id, state(usage))], mode: mode, selected: selected, labeled: true,
                                   highlightHigh: true, hiddenGroups: hidden).map(\.text)
        }
        XCTAssertEqual(text(.auto, [], [:]), ["Claude·GPT 5h 60%"])
        XCTAssertEqual(text(.auto, [], hidden), ["Gemini 5h 30%"])
        XCTAssertEqual(text(.custom, ["antigravity:model:Claude·GPT", "antigravity:model:Argon"], hidden), ["Argon 10%"])
        XCTAssertEqual(text(.custom, ["antigravity:model:Claude·GPT"], hidden), ["Gemini 5h 30%"])
        XCTAssertEqual(text(.auto, [], [id: ["Gemini", "Claude·GPT", "Argon"]]), [""])
    }

    func testServicesWithoutGroupsIgnoreHiddenGroups() {
        let usage = ProviderUsage(windows: [UsageWindow(id: "5h", kind: .rolling(minutes: 300), usedPercent: 40),
                                            UsageWindow(id: "model:Fable", kind: .model(name: "Fable", minutes: 10080), usedPercent: 9)])
        XCTAssertEqual(usage.hidingGroups(["Fable", "Claude·GPT"]), usage)
        XCTAssertTrue(usage.groups.isEmpty)
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
