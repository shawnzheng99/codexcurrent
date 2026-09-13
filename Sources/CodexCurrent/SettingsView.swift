import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("settings.refreshInterval")).font(.headline)
            Toggle(L10n.text("settings.automatic"), isOn: Binding(get: { store.automaticRefresh }, set: { store.setAutomaticRefresh($0) }))
            Text(store.automaticRefresh ? L10n.format("settings.activitySchedule", store.taskActivity.label) : L10n.text("settings.manual"))
                .font(.caption)
            IntervalSlider(index: Binding(
                get: { store.refreshIntervalIndex },
                set: { store.setRefreshInterval(index: $0) }
            ))
            .disabled(store.automaticRefresh)
            .opacity(store.automaticRefresh ? 0.4 : 1)
            Text(L10n.text("settings.saved"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 430)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
