import Foundation

enum CodexStatus: String, Sendable {
    case idle, unavailable

    var title: String {
        switch self {
        case .idle: "Codex 空闲"
        case .unavailable: "等待 Codex CLI"
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
        case .live: "实时"
        case .cached: "缓存"
        case .estimated: "估算"
        case .unavailable: "不可用"
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
            "尚未安装 Codex CLI。"
        case .versionUnavailable:
            "无法确认 Codex CLI 版本。"
        case let .loginRequired(version):
            "Codex CLI \(version) 尚未登录，请先运行 codex login。"
        case let .incompatible(version):
            version.map { "Codex CLI \($0) 不支持所需的额度接口，请升级后重试。" }
                ?? "当前 Codex CLI 不支持所需的额度接口，请升级后重试。"
        case .timedOut:
            "读取 Codex 用量超时，请检查网络后重试。"
        case .serviceUnavailable:
            "Codex CLI 暂时无法返回额度状态。"
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
        message: "正在连接 Codex CLI。",
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
        if let remainingPercent { return "剩余 \(Int(remainingPercent.rounded()))% · \(source.label)" }
        return message ?? "暂无额度数据"
    }

    var resetSummary: String? {
        guard let resetDate else { return nil }
        return "重置 \(resetDate.formatted(.relative(presentation: .named)))"
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
        case .never: "不过期"
        case .expired: "已过期"
        case .days(let days): "剩 \(days) 天"
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
    static func weekly(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "重置时间 —" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "即将重置" }
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            return String(format: "今天 %02d:%02d 重置", hour, minute)
        }
        return "还剩 \(Int(ceil(seconds / 86_400))) 天重置"
    }
}
