import Foundation

/// The part of `account/rateLimits/read` the app uses (codex-cli 0.159.2).
struct RateLimitsResponse: Decodable {
    /// Single-bucket view. `rateLimitsByLimitId` can hold more buckets, but no
    /// real response with more than one has been seen, so they're not read yet.
    let rateLimits: Snapshot

    struct Snapshot: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        /// Unix seconds.
        let resetsAt: Int64?
    }
}

extension RateLimitsResponse {
    /// Windows with an unknown length are dropped: they can't be labeled or compared.
    var windows: [UsageWindow] {
        [rateLimits.primary, rateLimits.secondary].compactMap { w in
            guard let w, let minutes = w.windowDurationMins else { return nil }
            return UsageWindow(id: UsageWindow.rollingID(minutes: minutes), kind: .rolling(minutes: minutes),
                               usedPercent: w.usedPercent,
                               resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    var planName: String? {
        guard let plan = rateLimits.planType, plan != "unknown" else { return nil }
        let names = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                     "promax": "Pro Max", "team": "Team", "business": "Business",
                     "self_serve_business_prolite": "Business", "self_serve_business_usage_based": "Business",
                     "enterprise": "Enterprise", "enterprise_cbp_automation": "Enterprise",
                     "enterprise_cbp_usage_based": "Enterprise",
                     "edu": "Edu", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro"]
        return names[plan] ?? plan
    }
}
