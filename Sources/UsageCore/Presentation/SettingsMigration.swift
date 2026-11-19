import Foundation

/// Moves settings saved by older versions to the current keys.
/// Pure so it can be tested; the app reads and writes UserDefaults around it.
public enum SettingsMigration {
    public static let version = 3

    /// Returns the new keys to set. Someone who picked menu bar items keeps them
    /// (custom mode), so their menu bar doesn't change.
    public static func toV2(_ old: [String: Any], now: Date = Date()) -> [String: Any] {
        var new: [String: Any] = [:]
        if let items = old["menuBarItems"] as? [String] {
            new["menuBar.mode"] = MenuBarMode.custom.rawValue
            let order = ["session", "week"]
            let sorted = items.sorted { (order.firstIndex(of: $0) ?? 2, $0) < (order.firstIndex(of: $1) ?? 2, $1) }
            new["menuBar.items"] = sorted.map { "claude:" + ($0 == "session" ? "5h" : $0) }
            // v0.3 showed labels unless turned off; v2's default is off.
            new["menuBar.labeled"] = (old["labelStyle"] as? String ?? "labeled") == "labeled"
        } else if let style = old["labelStyle"] as? String {
            new["menuBar.labeled"] = style == "labeled"
        }
        if old["barColorMode"] as? String == "fixed" {
            new["barColor"] = old["barColorHex"] as? String ?? "#D97757"
            new["highlightHigh"] = old["warnHighUsage"] as? Bool ?? true
        }
        if let models = old["knownModels"] as? [String], !models.isEmpty {
            new["knownWindows"] = ["claude": Dictionary(models.map { ("model:\($0)", now) }, uniquingKeysWith: { a, _ in a })]
        }
        return new
    }

    /// v0.4.9 called Antigravity's shared Gemini group "Gemini (Hydrogen)". Neon joined it, so it is
    /// "Gemini" now; hidden groups and menu bar picks under the old name follow. Takes and returns
    /// the values of `v3Keys`.
    public static func toV3(_ old: [String: Any]) -> [String: Any] {
        let rename = { (s: String) in s.replacingOccurrences(of: "Gemini (Hydrogen)", with: "Gemini") }
        var new: [String: Any] = [:]
        if let items = old["menuBar.items"] as? [String] {
            new["menuBar.items"] = items.map { $0.hasPrefix("antigravity:") ? rename($0) : $0 }
        }
        if var hidden = old["panel.hiddenGroups"] as? [String: [String]], let groups = hidden["antigravity"] {
            hidden["antigravity"] = groups.map(rename)
            new["panel.hiddenGroups"] = hidden
        }
        if var known = old["knownWindows"] as? [String: [String: Date]], let windows = known["antigravity"] {
            known["antigravity"] = Dictionary(windows.map { (rename($0.key), $0.value) }, uniquingKeysWith: max)
            new["knownWindows"] = known
        }
        return new
    }

    public static let v3Keys = ["menuBar.items", "panel.hiddenGroups", "knownWindows"]

    public static let oldKeys = ["menuBarItems", "labelStyle", "barColorMode", "barColorHex", "warnHighUsage", "knownModels"]
}
