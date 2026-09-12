import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var log = ConsoleLog()
    @State private var runner: Runner?
    @State private var busy = false
    @State private var command = "/var/jb/usr/bin/ls -la /var/jb/usr/share"
    @State private var started = false

    var body: some View {
        VStack(spacing: 8) {
            Text("XiOSLite").font(.title2.bold())
            Text(AppVersion.string).font(.footnote.monospaced()).foregroundStyle(.secondary)
            HStack {
                TextField("command line", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { runCommand() }
                Button("Run") { runCommand() }.buttonStyle(.borderedProminent).disabled(busy)
            }
            HStack {
                Button("Run G1 tests") { runTests() }.buttonStyle(.bordered).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Text("footprint \(footprintMB()) MB").font(.footnote)
            }
            HStack {
                // iosc は wl_display_run で戻ってこない。起動して 2 秒後の様子をログに出すだけ
                Button("iosc を起動") { startIosc() }.buttonStyle(.bordered).disabled(busy)
                // iosc が走っている間も押せるように busy では止めない(中身は一瞬で終わる)
                Button("状態") { showStatus() }.buttonStyle(.bordered)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("bottom")
                }
                .onChange(of: log.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(Color(.secondarySystemBackground)).cornerRadius(8)
            HStack {
                Button("Copy") { UIPasteboard.general.string = log.text }
                ShareLink("Share log", item: log.fileURL)
                Spacer()
                Button("Clear", role: .destructive) { log.clearFile() }
            }
            .font(.footnote)
        }
        .padding()
        .onAppear {
            guard !started else { return }
            started = true
            let prev = log.previous()
            log.log("XiOSLite \(AppVersion.string)")
            log.log(prev.isEmpty ? "--- first launch ---"
                                 : "--- launch (previous log \(prev.split(separator: "\n").count) lines) ---")
            runTests()
        }
    }

    private func ensureRunner() -> Runner {
        if let r = runner { return r }
        let r = Runner(log: log)
        runner = r
        return r
    }

    private func run(_ body: @escaping (Runner) -> Void) {
        let r = ensureRunner()
        busy = true
        Thread {
            body(r)
            DispatchQueue.main.async { busy = false }
        }.start()
    }

    private func runTests() {
        run { $0.runG1Tests() }
    }

    private func startIosc() {
        run { $0.startIosc() }
    }

    // busy を触らない別経路: G1 テストや iosc の起動中でも状態だけは見たい
    private func showStatus() {
        let r = ensureRunner()
        Thread { r.logStatus() }.start()
    }

    private func runCommand() {
        let argv = Runner.tokenize(command)
        guard !argv.isEmpty else { return }
        run { _ = $0.run(argv) }
    }
}
