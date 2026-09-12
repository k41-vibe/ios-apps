import SwiftUI
import UIKit

struct ContentView: View {
    // コンソール(G1 のログ)と全画面(iosc の出力)の 2 モード。ログはどちらからでも
    // 戻って読めるようにしておく(iosc が落ちたときに見たいのは結局ログなので)。
    private enum Mode {
        case console
        case screen
    }

    @StateObject private var log = ConsoleLog()
    @State private var runner: Runner?
    @State private var busy = false
    @State private var command = "/var/jb/usr/bin/ls -la /var/jb/usr/share"
    @State private var started = false
    @State private var mode: Mode = .console
    @State private var screen: ScreenClient?
    @State private var opening = false

    var body: some View {
        Group {
            if mode == .screen, let client = screen {
                ZStack(alignment: .topTrailing) {
                    ScreenView(client: client)
                        .ignoresSafeArea()
                    // ログは常に取り戻せるようにしておく(iosc が落ちたときに見たいのはログ)
                    Button("コンソール") { mode = .console }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(12)
                }
            } else {
                console
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let prev = log.previous()
            log.log("XiOSDesktop \(AppVersion.string)")
            log.log(prev.isEmpty ? "--- first launch ---"
                                 : "--- launch (previous log \(prev.split(separator: "\n").count) lines) ---")
            runTests()
        }
    }

    private var console: some View {
        VStack(spacing: 8) {
            Text("XiOSDesktop").font(.title2.bold())
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
                // ddx に繋いで iosc の出力を出す。必要なら iosc も起こす
                Button("画面") { openScreen() }.buttonStyle(.bordered).disabled(opening)
            }
            HStack {
                // コンポジタは繋いでくる相手が居ないと描くものが無い。まず 1 本起こす
                Button("背景") { run { $0.startBackground() } }.buttonStyle(.bordered).disabled(busy)
                Button("バー") { run { $0.startBar() } }.buttonStyle(.bordered).disabled(busy)
                Button("端末") { run { $0.startFoot() } }.buttonStyle(.bordered).disabled(busy)
                Toggle("詳細ログ", isOn: Binding(
                    get: { Runner.traceEnabled },
                    set: { Runner.traceEnabled = $0; setenv("LCSYS_TRACE", $0 ? "1" : "0", 1) }
                )).font(.footnote).fixedSize()
                if opening { ProgressView().controlSize(.small) }
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

    // 「画面」: iosc を(必要なら)起こす → ddx ソケットを待つ → 繋ぐ → 全画面に切り替える。
    // 握手までコンソールのまま進めるのは、失敗したときに見たいものがログだから。
    // busy とは別の錠(opening)を使う: G1 テスト中でも画面には行けるようにする。
    private func openScreen() {
        if screen != nil {   // 一度繋いだら以後は切り替えるだけ
            mode = .screen
            // ただしクライアントが全部落ちていると黒いままなので、そこだけ見ておく
            let r = ensureRunner()
            Thread { r.ensureClient() }.start()
            return
        }
        guard !opening else { return }
        opening = true
        let r = ensureRunner()
        let l = log
        Thread {
            defer { DispatchQueue.main.async { opening = false } }
            guard r.ensureIoscReady() else { return }
            guard let handle = r.libHandle else {
                l.log("画面: libLCsys.dylib の handle が無い(setup 前?)")
                return
            }
            guard let api = XSurfaceAPI(handle: handle, log: l) else { return }
            guard let client = ScreenClient(log: l, api: api) else { return }
            guard client.connect(path: r.ddxPath()) else { return }
            DispatchQueue.main.async {
                screen = client
                mode = .screen
            }
        }.start()
    }

    private func runCommand() {
        let argv = Runner.tokenize(command)
        guard !argv.isEmpty else { return }
        run { _ = $0.run(argv) }
    }
}
