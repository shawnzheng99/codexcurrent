import Foundation

enum CodexStatus: String, Sendable {
    case idle, unavailable

    var title: String {
        switch self {
        case .idle: L10n.text("status.idle")
        case .unavailable: L10n.text("status.unavailable")
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "checkmark.circle"
        case .unavailable: "exclamationmark.circle"
        }
    }
}

enum DataSourceQuality: String, Sendable {
    case live, cached, estimated, unavailable

    var label: String {
        switch self {
        case .live: L10n.text("source.live")
        case .cached: L10n.text("source.cached")
        case .estimated: L10n.text("source.estimated")
        case .unavailable: L10n.text("source.unavailable")
        }
    }
}

enum UsageProblem: Equatable, Sendable {
    case cliNotInstalled
    case versionUnavailable
    case loginRequired(version: String)
    case incompatible(version: String?)
    case timedOut
    case serviceUnavailable

    var message: String {
        switch self {
        case .cliNotInstalled:
            L10n.text("problem.cliNotInstalled")
        case .versionUnavailable:
            L10n.text("problem.versionUnavailable")
        case let .loginRequired(version):
            L10n.format("problem.loginRequired", version)
        case let .incompatible(version):
            version.map { L10n.format("problem.incompatibleVersion", $0) }
                ?? L10n.text("problem.incompatible")
        case .timedOut:
            L10n.text("problem.timedOut")
        case .serviceUnavailable:
            L10n.text("problem.serviceUnavailable")
        }
    }

    var alertKey: String? {
        switch self {
        case .cliNotInstalled: "cli-not-installed"
        case .versionUnavailable: "version-unavailable"
        case .loginRequired: "login-required"
        case .incompatible: "incompatible"
        case .timedOut, .serviceUnavailable: nil
        }
    }
}

struct UsageLimitWindow: Equatable, Sendable {
    var remainingPercent: Double
    var resetDate: Date?
    var durationMinutes: Int?
}

struct UsageSnapshot: Equatable, Sendable {
    var primaryWindow: UsageLimitWindow?
    var secondaryWindow: UsageLimitWindow?
    var availableResetCount: Int?
    var status: CodexStatus
    var source: DataSourceQuality
    var updatedAt: Date
    var message: String?
    var cliVersion: String?
    var problem: UsageProblem?
    var resetCredits: [ResetCredit]? = nil

    static let unavailable = UsageSnapshot(
        primaryWindow: nil, secondaryWindow: nil, availableResetCount: nil,
        status: .unavailable,
        source: .unavailable, updatedAt: .now,
        message: L10n.text("snapshot.connecting"),
        cliVersion: nil,
        problem: nil
    )

    /// The first available window remains the compact island's single headline value.
    /// This preserves the old presentation when the service adds or removes a window.
    var headlineWindow: UsageLimitWindow? { primaryWindow ?? secondaryWindow }

    var remainingPercent: Double? { headlineWindow?.remainingPercent }
    var resetDate: Date? { headlineWindow?.resetDate }

    var fiveHourWindow: UsageLimitWindow? {
        [primaryWindow, secondaryWindow].compactMap { $0 }.first { $0.durationMinutes == 300 }
    }

    var weeklyWindow: UsageLimitWindow? {
        [primaryWindow, secondaryWindow].compactMap { $0 }.first { $0.durationMinutes == 10_080 }
    }

    var hasFiveHourAndWeeklyWindows: Bool {
        fiveHourWindow != nil && weeklyWindow != nil
    }

    var summary: String {
        if let remainingPercent { return L10n.format("snapshot.remaining", Int(remainingPercent.rounded()), source.label) }
        return message ?? L10n.text("snapshot.noData")
    }

    var resetSummary: String? {
        guard let resetDate else { return nil }
        return L10n.format("snapshot.reset", resetDate.formatted(.relative(presentation: .named)))
    }

    static func failure(_ problem: UsageProblem, version: String? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primaryWindow: nil,
            secondaryWindow: nil,
            availableResetCount: nil,
            status: .unavailable,
            source: .unavailable,
            updatedAt: .now,
            message: problem.message,
            cliVersion: version,
            problem: problem
        )
    }
}

protocol CodexUsageProviding: Sendable {
    func fetchSnapshot() async -> UsageSnapshot
}

struct ResetCredit: Equatable, Sendable, Identifiable {
    let id: String
    let expiresAt: Date?
    var title: String? = nil

    func expiry(at now: Date) -> CreditExpiry {
        guard let expiresAt else { return .never }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        return .days(Int(ceil(seconds / 86_400)))
    }
}

enum CreditExpiry: Equatable {
    case never, expired, days(Int)

    var label: String {
        switch self {
        case .never: L10n.text("credit.never")
        case .expired: L10n.text("credit.expired")
        case .days(1): L10n.text("credit.oneDay")
        case .days(let days): L10n.format("credit.days", days)
        }
    }

    var urgency: Int {
        switch self {
        case .expired: 2
        case .days(let days) where days <= 1: 2
        case .days(let days) where days <= 3: 1
        default: 0
        }
    }
}

enum RefreshInterval {
    static let seconds: [Double] = [30, 60, 300, 600, 900, 1800]
    static let labels = ["30s", "1m", "5m", "10m", "15m", "30m"]
    static let defaultsKey = "refreshIntervalSeconds"
    static func index(for seconds: Double) -> Int {
        Self.seconds.firstIndex(of: seconds) ?? 2
    }
}

enum ResetCountdown {
    static func weekly(_ date: Date?, now: Date, calendar: Calendar = .current, language: AppLanguage = .system) -> String {
        guard let date else { return L10n.text("reset.noTime", language: language) }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return L10n.text("reset.soon", language: language) }
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            return L10n.format("reset.today", language: language, hour, minute)
        }
        let days = Int(ceil(seconds / 86_400))
        return days == 1
            ? L10n.text("reset.oneDay", language: language)
            : L10n.format("reset.days", language: language, days)
    }
}
