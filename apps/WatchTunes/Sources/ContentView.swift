import SwiftUI

// iOS 側は容れ物。再生は時計アプリ側(WatchSources)で行う。
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("WatchTunes").font(.largeTitle.bold())
            Text("時計アプリの容れ物です").foregroundStyle(.secondary)
        }
        .padding()
    }
}
