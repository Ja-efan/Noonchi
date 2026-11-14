import Foundation

/// The part of `agy -p /usage --output-format json` the app uses (agy 1.5.9).
struct AgyUsageResponse: Decodable {
    let status: String
    let error: String?
    let command: Command?

    struct Command: Decodable {
        let data: Usage?
    }

    struct Usage: Decodable {
        let groups: [Group]
    }

    struct Group: Decodable {
        let name: String
        let description: String?
        let buckets: [Bucket]
    }

    struct Bucket: Decodable {
        let id: String
        let window: String
        /// 1 means unused.
        let remainingFraction: Double
        let resetTime: String?
    }

    static func decode(_ data: Data) -> AgyUsageResponse? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Self.self, from: data)
    }
}

extension AgyUsageResponse {
    /// One window per bucket, 5h before weekly within each group, groups in the CLI's order.
    var windows: [UsageWindow] {
        var titles = Set<String>(), ids = Set<String>()
        return (command?.data?.groups ?? []).flatMap { group in
            let title = Self.unique(Self.title(group.name), in: &titles)
            let detail = group.description.flatMap { text in
                text.hasPrefix(Self.modelsPrefix) ? String(text.dropFirst(Self.modelsPrefix.count)) : nil
            } ?? group.name
            return group.buckets.enumerated()
                .sorted { (Self.rank($0.element.window), $0.offset) < (Self.rank($1.element.window), $1.offset) }
                .map { Self.window($0.element, title: title, detail: detail, ids: &ids) }
        }
    }

    private static let modelsPrefix = "Models within this group: "

    /// The CLI's group names are long ("Claude and GPT models").
    private static func title(_ groupName: String) -> String {
        switch groupName {
        case "Gemini Models": return "Gemini (Hydrogen)"
        case "Claude and GPT models": return "Claude·GPT"
        default: return groupName.hasPrefix("Gemini 4 ") ? String(groupName.dropFirst("Gemini 4 ".count)) : groupName
        }
    }

    /// Window IDs are settings keys, so two groups or buckets that read the same get a number.
    private static func unique(_ base: String, in used: inout Set<String>) -> String {
        var name = base, n = 2
        while !used.insert(name).inserted { name = "\(base) \(n)"; n += 1 }
        return name
    }

    private static func rank(_ window: String) -> Int {
        switch window {
        case "5h": return 0
        case "weekly": return 1
        default: return 2
        }
    }

    private static func window(_ bucket: Bucket, title: String, detail: String, ids: inout Set<String>) -> UsageWindow {
        let base: String
        let minutes: Int?
        switch bucket.window {
        case "5h": (base, minutes) = ("\(title) 5h", 300)
        // A model cap reads as weekly elsewhere in the app, like Claude's "Fable".
        case "weekly": (base, minutes) = (title, 10080)
        default: (base, minutes) = ("\(title) \(bucket.window)", nil)
        }
        let label = unique(base, in: &ids)
        return UsageWindow(id: "model:\(label)", kind: .model(name: label, minutes: minutes),
                           usedPercent: min(max((1 - bucket.remainingFraction) * 100, 0), 100),
                           resetsAt: bucket.resetTime.flatMap(date), group: title, groupDetail: detail)
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}
