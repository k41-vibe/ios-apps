import SwiftUI

@main
struct WatchProbeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("WatchProbe")
                    .font(.headline)
                Text("時計で動いています")
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
