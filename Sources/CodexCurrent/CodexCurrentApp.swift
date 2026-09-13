import AppKit
import Combine
import SwiftUI

@main
struct CodexCurrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { SettingsView(store: appDelegate.store) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(provider: CLIUsageProvider(), activityProvider: DesktopTaskActivityProvider())
    private let islandController = IslandController()
    private var snapshotSubscription: AnyCancellable?
    private var presentedIssueKeys = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        #if DEBUG
        if CommandLine.arguments.contains("--render-preview") {
            do { try IslandPreviewRenderer.render() }
            catch { print("Preview failed: \(error)") }
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
        snapshotSubscription = store.$snapshot.combineLatest(store.$isRefreshing).sink { [weak self] snapshot, isRefreshing in
            guard let self else { return }
            islandController.configure(store: store, snapshot: snapshot, isRefreshing: isRefreshing)
            presentStartupIssueIfNeeded(snapshot.problem)
        }
        if CommandLine.arguments.contains("--expanded") { islandController.show() }
    }

    private func presentStartupIssueIfNeeded(_ problem: UsageProblem?) {
        guard let problem,
              let key = problem.alertKey,
              presentedIssueKeys.insert(key).inserted else { return }

        // Publish callbacks are synchronous. Yield before opening a modal alert so UsageStore can
        // finish the current refresh and a "重新检查" action is not discarded as still in flight.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.runStartupAlert(for: problem, key: key)
        }
    }

    private func runStartupAlert(for problem: UsageProblem, key: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = alertTitle(for: problem)
        alert.informativeText = problem.message
        alert.addButton(withTitle: recoveryButtonTitle(for: problem))
        alert.addButton(withTitle: L10n.text("alert.retry"))
        alert.addButton(withTitle: L10n.text("alert.quit"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "https://github.com/openai/codex#quickstart") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            presentedIssueKeys.remove(key)
            store.refresh()
        case .alertThirdButtonReturn:
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    private func alertTitle(for problem: UsageProblem) -> String {
        switch problem {
        case .cliNotInstalled: L10n.text("alert.installTitle")
        case .loginRequired: L10n.text("alert.loginTitle")
        case .versionUnavailable, .incompatible: L10n.text("alert.updateTitle")
        case .timedOut, .serviceUnavailable: L10n.text("alert.connectTitle")
        }
    }

    private func recoveryButtonTitle(for problem: UsageProblem) -> String {
        switch problem {
        case .cliNotInstalled: L10n.text("alert.installGuide")
        case .loginRequired: L10n.text("alert.loginGuide")
        case .versionUnavailable, .incompatible: L10n.text("alert.updateGuide")
        case .timedOut, .serviceUnavailable: L10n.text("alert.help")
        }
    }
}
