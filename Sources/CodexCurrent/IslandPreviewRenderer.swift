#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum IslandPreviewRenderer {
    static func render() throws {
        let now = Date.now
        var sample = UsageSnapshot(
            primaryWindow: UsageLimitWindow(remainingPercent: 82, resetDate: now.addingTimeInterval(7200), durationMinutes: 300),
            secondaryWindow: UsageLimitWindow(remainingPercent: 64, resetDate: now.addingTimeInterval(4 * 86400), durationMinutes: 10080),
            availableResetCount: 3, status: .idle, source: .live,
            updatedAt: now.addingTimeInterval(-12),
            resetCredits: [
                ResetCredit(id: "1", expiresAt: now.addingTimeInterval(80000)),
                ResetCredit(id: "2", expiresAt: now.addingTimeInterval(240000)),
                ResetCredit(id: "3", expiresAt: now.addingTimeInterval(12 * 86400))
            ]
        )
        try save(sample, name: "expanded")
        sample.availableResetCount = 8
        sample.resetCredits = nil
        try save(sample, name: "unknown-expiry")
        try save(.failure(.serviceUnavailable), name: "unavailable")
    }

    private static func save(_ snapshot: UsageSnapshot, name: String) throws {
        let renderer = ImageRenderer(content: TerminalIslandContent(
            snapshot: snapshot, isRefreshing: false, intervalIndex: .constant(2), refresh: {}
        ))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let directory = URL(fileURLWithPath: "/tmp/codex-current-ui-qa")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
#endif
