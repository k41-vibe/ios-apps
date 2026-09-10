import SwiftUI

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("__APP__")
                .font(.largeTitle.bold())
            Text("LiveContainer で動いています")
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Button("タップ") {
                withAnimation { count += 1 }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
