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
    /// Groups that read the same (a blank-named one, say) are one group.
    var windows: [UsageWindow] {
        let buckets = (command?.data?.groups ?? []).flatMap { group in
            let title = Self.title(for: group)
            let detail = group.description.flatMap { text in
                text.hasPrefix(Self.modelsPrefix) ? String(text.dropFirst(Self.modelsPrefix.count)) : nil
            } ?? (group.name.trimmingCharacters(in: .whitespaces).isEmpty ? title : group.name)
            return group.buckets.map { (title: title, detail: detail, bucket: $0) }
        }
        var titles: [String] = []
        for b in buckets where !titles.contains(b.title) { titles.append(b.title) }
        var ids = Set<String>()
        return buckets.enumerated()
            .sorted { a, b in
                (titles.firstIndex(of: a.element.title)!, Self.rank(a.element.bucket.window), a.offset)
                    < (titles.firstIndex(of: b.element.title)!, Self.rank(b.element.bucket.window), b.offset)
            }
            .map { Self.window($0.element.bucket, title: $0.element.title, detail: $0.element.detail, ids: &ids) }
    }

    private static let modelsPrefix = "Models within this group: "

    /// The CLI's group names are long ("Claude and GPT models") or occasionally blank.
    private static func title(for group: Group) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return group.buckets.first.map { bucketTitle($0.id) } ?? ""
        }
        switch name {
        case "Gemini Models": return "Gemini"
        case "Claude and GPT models": return "Claude·GPT"
        default: return name.hasPrefix("Gemini 4 ") ? String(name.dropFirst("Gemini 4 ".count)) : name
        }
    }

    private static func bucketTitle(_ id: String) -> String {
        let prefixes: [(String, String)] = [
            ("gemini-carbon-", "Carbon"),
            ("gemini-argon-", "Argon"),
            ("3p-", "Claude·GPT"),
            ("gemini-", "Gemini"),
        ]
        return prefixes.first { id.hasPrefix($0.0) }?.1 ?? id
    }

    /// Window IDs are settings keys, so two buckets that read the same get a number.
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
