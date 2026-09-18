import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var log = ProbeLog()
    @StateObject private var updater: Updater
    @State private var surfaceProbe: SurfaceProbe?
    @State private var busy = false
    @State private var showPrevious = false

    init() {
        let l = ProbeLog()
        _log = StateObject(wrappedValue: l)
        _updater = StateObject(wrappedValue: Updater(log: l))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("LCProbe").font(.title2.bold())
            Text(AppVersion.string).font(.footnote.monospaced()).foregroundStyle(.secondary)
            updateSection
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
            Updater.cleanup()
            let prev = log.previous()
            if !prev.isEmpty {
                log.log("--- launch (previous log has \(prev.split(separator: "\n").count) lines; last: \(prev.split(separator: "\n").last ?? "")) ---")
            } else {
                log.log("--- first launch ---")
            }
        }
    }

    // 更新の確認と取り込み。実体は shared/Updater.swift
    private var updateSection: some View {
        VStack(spacing: 4) {
            HStack {
                Button("更新を確認") { Task { await updater.check() } }
                    .buttonStyle(.bordered)
                    .disabled(updater.phase == .checking || updater.phase == .downloading || updater.phase == .installing)
                if updater.phase == .available {
                    Button("更新する") { Task { await updater.update() } }.buttonStyle(.borderedProminent)
                }
                if updater.phase == .done {
                    Button("終了") { updater.quit() }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("ログをPCへ") { Task { await updater.sendLog() } }.buttonStyle(.bordered)
            }
            .font(.footnote)
            if updater.phase == .downloading || updater.phase == .installing {
                ProgressView(value: updater.progress)
            }
            if !updater.message.isEmpty || !updater.sendState.isEmpty {
                Text([updater.message, updater.sendState].filter { !$0.isEmpty }.joined(separator: " / "))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
