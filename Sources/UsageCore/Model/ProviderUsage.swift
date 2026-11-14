import Foundation

public struct ProviderID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One successful reading from a service.
public struct ProviderUsage: Equatable, Sendable {
    /// Plan name if the service reports it ("Max", "Free").
    public var plan: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    /// Original output, for the raw output window.
    public var raw: String
    /// The service couldn't report its model caps this time; they may still exist.
    public var modelWindowsUnavailable: Bool

    public init(plan: String? = nil, windows: [UsageWindow], fetchedAt: Date = Date(), raw: String = "",
                modelWindowsUnavailable: Bool = false) {
        self.plan = plan
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.raw = raw
        self.modelWindowsUnavailable = modelWindowsUnavailable
    }

    public func window(id: String) -> UsageWindow? { windows.first { $0.id == id } }

    /// The reading without the windows of `hidden` groups; what the panel and the menu bar show.
    public func hidingGroups(_ hidden: Set<String>) -> ProviderUsage {
        var copy = self
        copy.windows.removeAll { $0.group.map(hidden.contains) ?? false }
        return copy
    }

    /// Group titles and details in the reading's order.
    public var groups: [(title: String, detail: String?)] {
        var seen = Set<String>()
        return windows.compactMap { w in
            guard let title = w.group, seen.insert(title).inserted else { return nil }
            return (title, w.groupDetail)
        }
    }
}

public enum ProviderError: Error, Equatable, Sendable {
    case notInstalled
    case launchFailed
    case notLoggedIn
    case timeout
    /// The account has no plan limits to show (e.g. API billing).
    case unsupportedPlan
    case unparsable
    case failed(String)
}

/// What `UsageProvider.fetch()` throws. Keeps the output so a failed read can still
/// be inspected in the raw output window.
public struct ProviderFailure: Error, Equatable, Sendable {
    public var error: ProviderError
    public var raw: String

    public init(_ error: ProviderError, raw: String = "") {
        self.error = error
        self.raw = raw
    }
}
