import CoreGraphics
import Foundation
import Testing
@testable import CodexCurrent

@Test func unavailableSnapshotIsHonest() {
    #expect(UsageSnapshot.unavailable.source == .unavailable)
    #expect(UsageSnapshot.unavailable.remainingPercent == nil)
}

@Test func parsesCurrentAndShortCLIVersions() {
    #expect(CodexCLIVersion(output: "codex-cli 0.144.4")?.description == "0.144.4")
    #expect(CodexCLIVersion(output: "codex 1.2")?.description == "1.2.0")
    #expect(CodexCLIVersion(output: "unknown") == nil)
}

@Test func resolvesCLIFromEnvironmentPath() throws {
    let resolver = CLIExecutableResolver(
        homeDirectory: URL(fileURLWithPath: "/Users/test"),
        environmentPath: "/custom/bin:/usr/bin",
        isExecutable: { $0 == "/custom/bin/codex" }
    )
    #expect(try resolver.resolve().path == "/custom/bin/codex")
}

@Test func missingCLIHasActionableError() {
    let snapshot = UsageSnapshot.failure(.cliNotInstalled)
    #expect(snapshot.problem == .cliNotInstalled)
    #expect(snapshot.message == "尚未安装 Codex CLI。")
}

@Test func mapsOnlyRateLimitData() {
    let payload = RateLimitsPayload(
        rateLimits: RateLimitBucket(
            primary: RateLimitWindow(
                usedPercent: 37,
                windowDurationMins: 300,
                resetsAt: 1_800_000_000
            ),
            secondary: RateLimitWindow(
                usedPercent: 12,
                windowDurationMins: 10_080,
                resetsAt: 1_800_500_000
            )
        ),
        rateLimitsByLimitId: nil,
        rateLimitResetCredits: RateLimitResetCredits(availableCount: 1)
    )
    let snapshot = RateLimitMapper.snapshot(from: payload, version: "0.144.4")
    #expect(snapshot.remainingPercent == 63)
    #expect(snapshot.fiveHourWindow?.remainingPercent == 63)
    #expect(snapshot.weeklyWindow?.remainingPercent == 88)
    #expect(snapshot.availableResetCount == 1)
    #expect(snapshot.hasFiveHourAndWeeklyWindows)
    #expect(snapshot.cliVersion == "0.144.4")
    #expect(snapshot.problem == nil)
}

@Test func fallsBackToSingleWindowWhenFiveHourLimitIsAbsent() {
    let payload = RateLimitsPayload(
        rateLimits: RateLimitBucket(
            primary: RateLimitWindow(
                usedPercent: 25,
                windowDurationMins: 10_080,
                resetsAt: 1_800_500_000
            ),
            secondary: nil
        ),
        rateLimitsByLimitId: nil,
        rateLimitResetCredits: RateLimitResetCredits(availableCount: 0)
    )
    let snapshot = RateLimitMapper.snapshot(from: payload, version: "0.144.4")
    #expect(snapshot.remainingPercent == 75)
    #expect(snapshot.fiveHourWindow == nil)
    #expect(snapshot.availableResetCount == 0)
    #expect(!snapshot.hasFiveHourAndWeeklyWindows)
}

@Test func detectsNotchFromScreenGeometryRatherThanModelName() {
    let left = CGRect(x: 0, y: 900, width: 700, height: 32)
    let right = CGRect(x: 880, y: 900, width: 700, height: 32)
    #expect(NotchGeometry.hasNotch(leftArea: left, rightArea: right, safeAreaTop: 32))
    #expect(!NotchGeometry.hasNotch(leftArea: left, rightArea: right, safeAreaTop: 0))
    #expect(!NotchGeometry.hasNotch(leftArea: nil, rightArea: nil, safeAreaTop: 32))
}

@Test func decodesCreditDetailsAndPreservesMissingDetails() throws {
    let json = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":4,"credits":[{"id":"later","expiresAt":200000,"status":"available","title":"Bonus"},{"id":"never","expiresAt":null,"status":"available"},{"id":"soon","expiresAt":100000,"status":"available"},{"id":"used","expiresAt":90000,"status":"redeemed"}]}}"#
    let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
    let snapshot = RateLimitMapper.snapshot(from: payload, version: "test")
    #expect(snapshot.availableResetCount == 4)
    #expect(snapshot.resetCredits?.map(\.id) == ["soon", "later", "never"])
    #expect(snapshot.resetCredits?.last?.expiresAt == nil)
    let missing = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":3}}"#
    let unknown = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(missing.utf8))
    #expect(RateLimitMapper.snapshot(from: unknown, version: "test").resetCredits == nil)
}

@Test func countdownAndExpiryBoundaries() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(ResetCountdown.weekly(nil, now: now) == "重置时间 —")
    #expect(ResetCountdown.weekly(now, now: now) == "即将重置")
    #expect(ResetCountdown.weekly(now.addingTimeInterval(86401), now: now) == "还剩 2 天重置")
    for (seconds, expected, urgency) in [(0.0, CreditExpiry.expired, 2), (1, .days(1), 2), (86400, .days(1), 2), (86401, .days(2), 1), (259200, .days(3), 1), (259201, .days(4), 0)] {
        let expiry = ResetCredit(id: "test", expiresAt: now.addingTimeInterval(seconds)).expiry(at: now)
        #expect(expiry == expected)
        #expect(expiry.urgency == urgency)
    }
    #expect(ResetCredit(id: "forever", expiresAt: nil).expiry(at: now) == .never)
}

private struct TestUsageProvider: CodexUsageProviding {
    func fetchSnapshot() async -> UsageSnapshot { .unavailable }
}

@Test @MainActor func refreshSelectionPersistsAndRejectsInvalidIndices() {
    let suite = "CodexCurrentTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UsageStore(provider: TestUsageProvider(), defaults: defaults)
    #expect(store.refreshIntervalIndex == 2)
    for index in RefreshInterval.seconds.indices {
        store.setRefreshInterval(index: index)
        #expect(defaults.double(forKey: RefreshInterval.defaultsKey) == RefreshInterval.seconds[index])
    }
    store.setRefreshInterval(index: 99)
    #expect(store.refreshIntervalIndex == 5)
    let restored = UsageStore(provider: TestUsageProvider(), defaults: defaults)
    #expect(restored.refreshIntervalIndex == 5)
}

@Test func weeklyResetUsesLocalCalendarDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 10))!
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 23, minute: 45))!
    let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 0, minute: 5))!
    #expect(ResetCountdown.weekly(today, now: now, calendar: calendar) == "今天 23:45 重置")
    #expect(ResetCountdown.weekly(tomorrow, now: now, calendar: calendar) == "还剩 1 天重置")
    #expect(ResetCountdown.weekly(now, now: now, calendar: calendar) == "即将重置")
    calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
    #expect(ResetCountdown.weekly(today, now: now, calendar: calendar) == "还剩 1 天重置")
}

@Test @MainActor func automaticRefreshTracksActivityWithoutOverwritingManualPreference() {
    let suite = "CodexCurrentTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UsageStore(provider: TestUsageProvider(), defaults: defaults)
    #expect(store.automaticRefresh)
    #expect(store.effectiveRefreshSeconds == 900)
    store.updateActivity(.active)
    #expect(store.effectiveRefreshSeconds == 10)
    store.updateActivity(.idle)
    #expect(store.effectiveRefreshSeconds == 900)
    store.updateActivity(.unknown)
    #expect(store.taskActivity == .unknown)
    #expect(store.effectiveRefreshSeconds == 900)
    store.setAutomaticRefresh(false)
    store.setRefreshInterval(index: 1)
    store.updateActivity(.active)
    #expect(store.effectiveRefreshSeconds == 60)
    store.setAutomaticRefresh(true)
    #expect(store.effectiveRefreshSeconds == 10)
    #expect(store.refreshIntervalIndex == 1)
    #expect(UsageStore.activitySamplingSeconds == 5)
}

private actor GatedUsageProvider: CodexUsageProviding {
    private(set) var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    func fetchSnapshot() async -> UsageSnapshot {
        count += 1
        if count == 1 { await withCheckedContinuation { gate = $0 } }
        return .unavailable
    }
    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor func taskBoundaryDuringRefreshQueuesFinalUsageRead() async {
    let suite = "CodexCurrentTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = GatedUsageProvider()
    let store = UsageStore(provider: provider, defaults: defaults)
    for _ in 0..<1000 {
        if await provider.count == 1 { break }
        await Task.yield()
    }
    store.updateActivity(.active)
    store.updateActivity(.idle)
    await provider.release()
    for _ in 0..<1000 {
        if await provider.count == 2 { break }
        await Task.yield()
    }
    #expect(await provider.count == 2)
    #expect(store.effectiveRefreshSeconds == 900)
}
