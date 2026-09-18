import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var log = ProbeLog()
    @State private var surfaceProbe: SurfaceProbe?
    @State private var busy = false
    @State private var showPrevious = false

    var body: some View {
        VStack(spacing: 8) {
            Text("LCProbe").font(.title2.bold())
            Text(AppVersion.string).font(.footnote.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("安全な計測を全部") { runSafe() }.buttonStyle(.borderedProminent).disabled(busy)
                Button("Metal/IOSurface") { startSurface() }.buttonStyle(.bordered).disabled(surfaceProbe != nil)
            }
            HStack {
                Button("JIT/W^X") { run { Probes.jitProbe(log) } }.buttonStyle(.bordered).disabled(busy)
                Button("JIT速度") { run { Probes.jitBenchmark(log) } }.buttonStyle(.bordered).disabled(busy)
                Button("スレッド上限") { run { Probes.threads(log) } }.buttonStyle(.bordered).disabled(busy)
                Button("メモリ上限(落ちる)", role: .destructive) { run { Probes.memoryUntilKill(log) } }
                    .buttonStyle(.bordered).disabled(busy)
            }
            if let p = surfaceProbe {
                MetalProbeView(probe: p).frame(height: 160).cornerRadius(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(showPrevious ? log.previous() : log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("bottom")
                }
                .onChange(of: log.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(Color(.secondarySystemBackground)).cornerRadius(8)
            HStack {
                Button(showPrevious ? "今回分を表示" : "ファイル全体を表示") { showPrevious.toggle() }
                Spacer()
                Button("コピー") { UIPasteboard.general.string = log.previous() }
                ShareLink("共有", item: log.fileURL)
                Button("消去", role: .destructive) { log.clearFile() }
            }
            .font(.footnote)
        }
        .padding()
        .onAppear {
            let prev = log.previous()
            if !prev.isEmpty {
                log.log("--- launch (previous log has \(prev.split(separator: "\n").count) lines; last: \(prev.split(separator: "\n").last ?? "")) ---")
            } else {
                log.log("--- first launch ---")
            }
        }
    }

    private func run(_ body: @escaping () -> Void) {
        busy = true
        Thread {
            body()
            DispatchQueue.main.async { busy = false }
        }.start()
    }

    private func runSafe() {
        run {
            Probes.sysInfo(log)
            Probes.dlopenTiers(log)
            Probes.runtimeDlopen(log)
            Probes.sockets(log)
            log.log("=== safe probes done ===")
        }
    }

    private func startSurface() {
        surfaceProbe = SurfaceProbe(log: log)
    }
}
