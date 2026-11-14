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
        (command?.data?.groups ?? []).flatMap { group in
            group.buckets.enumerated()
                .sorted { (Self.rank($0.element.window), $0.offset) < (Self.rank($1.element.window), $1.offset) }
                .map { Self.window($0.element, group: group) }
        }
    }

    private static func rank(_ window: String) -> Int {
        switch window {
        case "5h": return 0
        case "weekly": return 1
        default: return 2
        }
    }

    private static func window(_ bucket: Bucket, group: Group) -> UsageWindow {
        let name = shortName(bucketID: bucket.id, groupName: group.name)
        let label: String
        let minutes: Int?
        switch bucket.window {
        case "5h": (label, minutes) = ("\(name) 5h", 300)
        // A model cap reads as weekly elsewhere in the app, like Claude's "Fable".
        case "weekly": (label, minutes) = (name, 10080)
        default: (label, minutes) = ("\(name) \(bucket.window)", nil)
        }
        return UsageWindow(id: "model:\(label)", kind: .model(name: label, minutes: minutes),
                           usedPercent: min(max((1 - bucket.remainingFraction) * 100, 0), 100),
                           resetsAt: bucket.resetTime.flatMap(date))
    }

    /// The group names are long ("Claude and GPT models"); the bucket IDs say the same in short.
    private static func shortName(bucketID: String, groupName: String) -> String {
        if bucketID.hasPrefix("gemini-argon-") { return "Argon" }
        if bucketID.hasPrefix("gemini-") { return "Gemini" }
        if bucketID.hasPrefix("3p-") { return "Claude·GPT" }
        return groupName
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}
