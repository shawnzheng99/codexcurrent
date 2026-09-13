import AppKit
import SwiftUI

enum NotchGeometry {
    static func hasNotch(leftArea: CGRect?, rightArea: CGRect?, safeAreaTop: CGFloat) -> Bool {
        guard safeAreaTop > 0,
              let leftArea,
              let rightArea else { return false }
        return rightArea.minX - leftArea.maxX > 0
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        hasNotch(
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }
}

@MainActor
final class IslandController: NSObject, ObservableObject {
    private var panel: NSPanel?
    private var collapsedPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var store: UsageStore?
    private var latestSnapshot: UsageSnapshot = .unavailable
    private var latestIsRefreshing = false
    private var refreshAction: (() -> Void)?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePresentation() }
        }
    }

    func configure(store: UsageStore, snapshot: UsageSnapshot, isRefreshing: Bool) {
        self.store = store
        latestSnapshot = snapshot
        latestIsRefreshing = isRefreshing
        refreshAction = { [weak store] in store?.refresh() }
        updatePresentation()
    }

    private func updatePresentation() {
        if let screen = NSScreen.screens.first(where: NotchGeometry.hasNotch) {
            removeStatusItem()
            configureNotchPresentation(on: screen)
        } else {
            if statusItem == nil { hideNotchPresentation() }
            configureStatusItem()
        }
    }

    private func configureNotchPresentation(on screen: NSScreen) {
        guard let store else { return }
        let root = IslandView(store: store)
        if let panel {
            if panel.isVisible { position(panel, on: screen) }
            updateCollapsedBar(on: screen)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: TerminalIslandContent.size.width, height: TerminalIslandContent.size.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel
        installOutsideClickMonitors()
        updateCollapsedBar(on: screen)
    }

    func show() {
        guard let screen = NSScreen.screens.first(where: NotchGeometry.hasNotch) ?? NSScreen.main else { return }
        if panel == nil { configureNotchPresentation(on: screen) }
        guard let panel else { return }
        hideCollapsedBar()
        position(panel, on: screen)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        if let screen = NSScreen.screens.first(where: NotchGeometry.hasNotch) {
            showCollapsedBar(on: screen)
        }
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        // Align directly to the hardware notch bottom; visibleFrame changes when the menu bar hides.
        let notchBottom = NotchGeometry.hasNotch(screen)
            ? screen.frame.maxY - screen.safeAreaInsets.top
            : screen.visibleFrame.maxY - 7
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                     y: notchBottom - panel.frame.height + 1))
    }

    private func updateCollapsedBar(on screen: NSScreen) {
        let root = CollapsedIslandView(
            remainingPercent: latestSnapshot.remainingPercent,
            isRefreshing: latestIsRefreshing,
            label: latestSnapshot.summary,
            open: { [weak self] in self?.show() },
            refresh: { [weak self] in self?.refreshAction?() }
        )
        if let collapsedPanel {
            collapsedPanel.contentView = NSHostingView(rootView: root)
        } else {
            collapsedPanel = makeCollapsedPanel(root: root)
        }
        if panel?.isVisible != true { showCollapsedBar(on: screen) }
    }

    private func makeCollapsedPanel<Content: View>(root: Content) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 38),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    private func showCollapsedBar(on screen: NSScreen) {
        guard let collapsedPanel,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return }
        let wingWidth: CGFloat = 48
        let x = leftArea.maxX - wingWidth
        let width = rightArea.minX - leftArea.maxX + wingWidth * 2
        collapsedPanel.setFrame(
            NSRect(x: x, y: leftArea.minY, width: width, height: leftArea.height),
            display: true
        )
        collapsedPanel.orderFrontRegardless()
    }

    private func hideCollapsedBar() {
        collapsedPanel?.orderOut(nil)
    }

    private func installOutsideClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissForOutsideClick(at: point) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // Capture the click location before SwiftUI actions can hide or replace a window.
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            Task { @MainActor in self?.dismissForOutsideClick(at: point) }
            return event
        }
    }

    private func dismissForOutsideClick(at point: NSPoint) {
        guard let panel, panel.isVisible,
              !panel.frame.contains(point),
              collapsedPanel?.frame.contains(point) != true else { return }
        hide()
    }

    private func hideNotchPresentation() {
        panel?.orderOut(nil)
        collapsedPanel?.orderOut(nil)
    }

    private func configureStatusItem() {
        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }

        let title = latestSnapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "–"
        let color = statusColor(for: latestSnapshot.remainingPercent)
        item.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color
            ]
        )
        item.button?.toolTip = latestSnapshot.summary
        item.button?.setAccessibilityLabel(L10n.format("accessibility.remaining", title))

        let menu = NSMenu()
        let summaryItem = NSMenuItem(title: latestSnapshot.summary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        if let version = latestSnapshot.cliVersion {
            let versionItem = NSMenuItem(title: "Codex CLI \(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
        }
        menu.addItem(.separator())
        let expandItem = NSMenuItem(title: L10n.text("menu.openPanel"), action: #selector(expandFromStatusItem), keyEquivalent: "")
        expandItem.target = self
        menu.addItem(expandItem)
        let refreshItem = NSMenuItem(
            title: latestIsRefreshing ? L10n.text("menu.refreshing") : L10n.text("menu.refreshNow"),
            action: #selector(refreshFromStatusItem),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = !latestIsRefreshing
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func statusColor(for remainingPercent: Double?) -> NSColor {
        guard let remainingPercent else { return .secondaryLabelColor }
        if remainingPercent < 10 { return .systemRed }
        if remainingPercent < 30 { return .systemOrange }
        return .systemGreen
    }

    @objc private func expandFromStatusItem() { show() }

    @objc private func refreshFromStatusItem() {
        refreshAction?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct CollapsedIslandView: View {
    let remainingPercent: Double?
    let isRefreshing: Bool
    let label: String
    let open: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack {
                Text(remainingPercent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(IslandFont.mono(11, weight: .semibold))
                    .foregroundStyle(indicatorTint)
                Spacer(minLength: 54)
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: refresh) {
                RefreshGlyph(isRefreshing: isRefreshing, size: 13)
                .frame(minWidth: 42, maxWidth: 42, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .foregroundStyle(.white.opacity(0.75))
        }
        .help(label)
        .background(collapsedShape.fill(.black))
    }

    private var collapsedShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 8,
            bottomTrailingRadius: 8, topTrailingRadius: 0
        )
    }

    private var indicatorTint: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent < 10 { return .red }
        if remainingPercent < 30 { return .orange }
        return TerminalPalette.green
    }
}

private struct IslandView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TerminalIslandContent(
            snapshot: store.snapshot, isRefreshing: store.isRefreshing,
            intervalIndex: Binding(get: { store.refreshIntervalIndex }, set: { store.setRefreshInterval(index: $0) }),
            refresh: store.refresh,
            automaticRefresh: store.automaticRefresh,
            activity: store.taskActivity,
            setAutomaticRefresh: store.setAutomaticRefresh
        )
    }
}

enum TerminalPalette {
    static let green = Color(red: 0.48, green: 0.94, blue: 0.12)
    static let sage = Color(red: 0.65, green: 0.77, blue: 0.49)
    static let muted = Color(red: 0.49, green: 0.58, blue: 0.40)
    static let line = Color(red: 0.24, green: 0.33, blue: 0.18)
    static let red = Color(red: 1, green: 0.30, blue: 0.28)
    static let yellow = Color(red: 1, green: 0.81, blue: 0.12)

    static func quota(_ amount: Double?, weekly: Bool = false) -> Color {
        guard let amount else { return muted }
        if amount < 10 { return red }
        if amount < 30 { return yellow }
        return weekly ? sage : green
    }

    static func expiry(_ expiry: CreditExpiry) -> Color {
        switch expiry.urgency {
        case 2: red
        case 1: yellow
        default: green
        }
    }
}

struct TerminalIslandContent: View {
    static let size = CGSize(width: 600, height: 324)
    let snapshot: UsageSnapshot
    let isRefreshing: Bool
    @Binding var intervalIndex: Int
    let refresh: () -> Void
    var automaticRefresh = false
    var activity: TaskActivity = .unknown
    var setAutomaticRefresh: (Bool) -> Void = { _ in }


    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .top, spacing: 18) {
                    metric(title: snapshot.fiveHourWindow == nil && snapshot.weeklyWindow == nil ? L10n.text("panel.remaining") : L10n.text("panel.fiveHourRemaining"),
                           window: snapshot.fiveHourWindow ?? (snapshot.weeklyWindow == nil ? snapshot.headlineWindow : nil),
                           weekly: false, now: context.date)
                    verticalRule
                    metric(title: L10n.text("panel.weeklyRemaining"), window: snapshot.weeklyWindow, weekly: true, now: context.date)
                    verticalRule
                    credits(now: context.date)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(height: 161)
            rule
            VStack(spacing: 10) {
                HStack {
                    Text(L10n.text("panel.refreshInterval")).foregroundStyle(TerminalPalette.sage)
                    Spacer()
                    Button(automaticRefresh ? L10n.text("panel.automatic") : L10n.text("panel.manual")) { setAutomaticRefresh(!automaticRefresh) }
                        .buttonStyle(.plain)
                        .foregroundStyle(TerminalPalette.sage)
                        .help(L10n.text("panel.toggleRefresh"))
                    Text(automaticRefresh ? (activity == .active ? "10s" : "15m") : RefreshInterval.labels[intervalIndex])
                        .foregroundStyle(TerminalPalette.green)
                }
                .font(IslandFont.mono(11))
                if automaticRefresh {
                    HStack(spacing: 8) {
                        Circle().fill(activity == .unknown ? TerminalPalette.yellow : TerminalPalette.green).frame(width: 5, height: 5)
                        Text(activity.label)
                        Spacer()
                        Text(L10n.text("panel.activityIntervals"))
                    }
                    .font(IslandFont.mono(10))
                    .foregroundStyle(TerminalPalette.sage)
                    .frame(height: 39)
                    .help(L10n.text("panel.activityHelp"))
                } else {
                    IntervalSlider(index: $intervalIndex)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            footer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(TerminalPalette.sage)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 20,
                                   bottomTrailingRadius: 20, topTrailingRadius: 12)
                .fill(LinearGradient(colors: [.black, Color(red: 0.025, green: 0.035, blue: 0.02)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    SideAndBottomBorder().stroke(TerminalPalette.line, lineWidth: 1)
                }
        }
        .preferredColorScheme(.dark)
    }

    private var rule: some View { Rectangle().fill(TerminalPalette.line.opacity(0.6)).frame(height: 0.5) }
    private var verticalRule: some View { Rectangle().fill(TerminalPalette.line).frame(width: 0.5, height: 126) }

    private var header: some View {
        HStack(spacing: 10) {
            Text(">_ CODEX CURRENT").font(IslandFont.mono(13, weight: .semibold)).tracking(1.5)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.pulse, options: .repeating, isActive: isRefreshing)
            }
            .disabled(isRefreshing)
            .help(L10n.text("menu.refreshNow"))
            .accessibilityLabel(L10n.text("menu.refreshNow"))
            Button(action: { NSApplication.shared.terminate(nil) }) { Image(systemName: "power") }
                .help(L10n.text("menu.quit"))
                .accessibilityLabel(L10n.text("menu.quit"))
        }
        .buttonStyle(TerminalIconButtonStyle())
        .padding(.horizontal, 24)
        .frame(height: 46)
    }

    private func metric(title: String, window: UsageLimitWindow?, weekly: Bool, now: Date) -> some View {
        let tint = TerminalPalette.quota(window?.remainingPercent, weekly: weekly)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(IslandFont.mono(12))
            Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—")
                .font(IslandFont.mono(43, weight: .bold)).tracking(-1)
                .foregroundStyle(tint)
                .padding(.top, 8)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(weekly ? ResetCountdown.weekly(window?.resetDate, now: now) : shortReset(window?.resetDate, now: now))
                .font(IslandFont.mono(10))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.bottom, 9)
            SegmentedRemainingBar(percentage: window?.remainingPercent, tint: tint, segmentCount: 18, height: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 126)
        .accessibilityElement(children: .combine)
    }

    private func shortReset(_ date: Date?, now: Date) -> String {
        guard let date else { return L10n.text("reset.noTime") }
        if date <= now { return L10n.text("reset.soon") }
        return L10n.format("reset.at", date.formatted(date: .omitted, time: .shortened))
    }

    private func credits(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("panel.availableResets")).font(IslandFont.mono(12))
            HStack(alignment: .lastTextBaseline) {
                Text(snapshot.availableResetCount.map(String.init) ?? "—")
                    .font(IslandFont.mono(35, weight: .semibold))
                    .foregroundStyle(Color(red: 0.91, green: 0.96, blue: 0.85))
                Spacer(minLength: 4)
                Text(L10n.text("panel.expiry")).font(IslandFont.mono(9)).foregroundStyle(TerminalPalette.muted)
            }
            if let rows = snapshot.resetCredits, !rows.isEmpty {
                creditList(rows: rows, now: now)
            } else {
                Text(snapshot.availableResetCount == 0 ? L10n.text("panel.noResets") : L10n.text("panel.expiryUnavailable"))
                    .font(IslandFont.mono(10)).foregroundStyle(TerminalPalette.muted)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 152, height: 126, alignment: .topLeading)
    }

    @ViewBuilder
    private func creditList(rows: [ResetCredit], now: Date) -> some View {
        if rows.count > 3 || (snapshot.availableResetCount ?? 0) > rows.count {
            ScrollView(.vertical) { creditRows(rows: rows, now: now) }
                .frame(maxHeight: .infinity)
        } else {
            creditRows(rows: rows, now: now)
            Spacer(minLength: 0)
        }
    }

    private func creditRows(rows: [ResetCredit], now: Date) -> some View {
        VStack(spacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, credit in
                            let expiry = credit.expiry(at: now)
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 1).fill(TerminalPalette.expiry(expiry)).frame(width: 6, height: 6)
                                Text(String(format: "R%02d", index + 1))
                                Spacer(minLength: 2)
                                Text(expiry.label).foregroundStyle(TerminalPalette.expiry(expiry))
                            }
                            .font(IslandFont.mono(10))
                            .help(credit.title ?? L10n.text("panel.expiryHelp"))
                        }
                        if let count = snapshot.availableResetCount, count > rows.count {
                            Text(L10n.format("panel.moreUnknown", count - rows.count))
                                .font(IslandFont.mono(9)).foregroundStyle(TerminalPalette.muted)
                        }
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Circle().fill(snapshot.source == .live ? TerminalPalette.green : TerminalPalette.yellow).frame(width: 5, height: 5)
                Text(isRefreshing ? L10n.text("menu.refreshing") : snapshot.message ?? age(at: context.date))
                    .font(IslandFont.mono(10))
                    .foregroundStyle(TerminalPalette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .help(snapshot.cliVersion.map { "Codex CLI \($0)" } ?? L10n.text("snapshot.connecting"))
        }
    }

    private func age(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(snapshot.updatedAt)))
        if seconds < 60 {
            return seconds == 1 ? L10n.text("footer.updatedSecond") : L10n.format("footer.updatedSeconds", seconds)
        }
        let minutes = seconds / 60
        if seconds < 3600 {
            return minutes == 1 ? L10n.text("footer.updatedMinute") : L10n.format("footer.updatedMinutes", minutes)
        }
        let hours = seconds / 3600
        return hours == 1 ? L10n.text("footer.updatedHour") : L10n.format("footer.updatedHours", hours)
    }
}

private struct TerminalIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(TerminalPalette.green)
            .frame(width: 28, height: 28)
            .background(TerminalPalette.green.opacity(configuration.isPressed ? 0.18 : 0.02))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(TerminalPalette.line, lineWidth: 0.7))
    }
}

struct IntervalSlider: View {
    @Binding var index: Int

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 16
            let step = width / 5
            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                    Capsule().fill(TerminalPalette.green).frame(width: max(0, step * CGFloat(index)), height: 3)
                    ForEach(0..<6) { tick in
                        Circle().fill(tick <= index ? TerminalPalette.green : Color(red: 0.30, green: 0.32, blue: 0.28))
                            .frame(width: 5, height: 5).offset(x: step * CGFloat(tick) - 2.5)
                    }
                    Circle().fill(Color.black).frame(width: 17, height: 17)
                        .overlay(Circle().stroke(TerminalPalette.green, lineWidth: 1.5))
                        .overlay(Circle().fill(TerminalPalette.green).padding(4))
                        .offset(x: step * CGFloat(index) - 8.5)
                }
                .frame(height: 20)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    index = min(5, max(0, Int(((value.location.x - 8) / step).rounded())))
                })
                ZStack(alignment: .leading) {
                    ForEach(0..<6) { tick in
                        Text(RefreshInterval.labels[tick])
                            .font(IslandFont.mono(10, weight: tick == index ? .semibold : .regular))
                            .foregroundStyle(tick == index ? TerminalPalette.green : TerminalPalette.muted)
                            .frame(width: 36).offset(x: 8 + step * CGFloat(tick) - 18)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 14)
            }
        }
        .frame(height: 39)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("panel.refreshInterval"))
        .accessibilityValue(RefreshInterval.labels[index])
        .accessibilityAdjustableAction { direction in
            if direction == .increment { index = min(5, index + 1) }
            if direction == .decrement { index = max(0, index - 1) }
        }
    }
}

private struct SideAndBottomBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.5, y: 12))
        path.addLine(to: CGPoint(x: 0.5, y: rect.height - 20))
        path.addQuadCurve(to: CGPoint(x: 20, y: rect.height - 0.5), control: CGPoint(x: 0.5, y: rect.height - 0.5))
        path.addLine(to: CGPoint(x: rect.width - 20, y: rect.height - 0.5))
        path.addQuadCurve(to: CGPoint(x: rect.width - 0.5, y: rect.height - 20), control: CGPoint(x: rect.width - 0.5, y: rect.height - 0.5))
        path.addLine(to: CGPoint(x: rect.width - 0.5, y: 12))
        return path
    }
}

private enum IslandFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private struct SegmentedRemainingBar: View {
    let percentage: Double?
    let tint: Color
    var segmentCount = 20
    var height: CGFloat = 16

    var body: some View {
        let filled = Int(ceil((percentage ?? 0) / 100 * Double(segmentCount)))
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(index < filled ? tint : tint.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 0.5).stroke(tint.opacity(0.24), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            }
        }
        .accessibilityLabel(percentage.map { L10n.format("accessibility.remaining", "\(Int($0.rounded()))%") }
            ?? L10n.text("accessibility.remainingUnknown"))
    }
}

private struct RefreshGlyph: View {
    let isRefreshing: Bool
    let size: CGFloat
    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(TerminalPalette.green)
            .opacity(isRefreshing ? 0.4 : 1)
    }
}
