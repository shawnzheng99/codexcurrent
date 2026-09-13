import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("刷新间隔").font(.headline)
            Toggle("根据任务状态自动调整", isOn: Binding(get: { store.automaticRefresh }, set: { store.setAutomaticRefresh($0) }))
            Text(store.automaticRefresh ? "\(store.taskActivity.label) · 运行 10 秒 / 闲置 15 分钟" : "手动刷新间隔")
                .font(.caption)
            IntervalSlider(index: Binding(
                get: { store.refreshIntervalIndex },
                set: { store.setRefreshInterval(index: $0) }
            ))
            .disabled(store.automaticRefresh)
            .opacity(store.automaticRefresh ? 0.4 : 1)
            Text("自动保存，立即生效。电脑休眠期间暂停刷新。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 430)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
