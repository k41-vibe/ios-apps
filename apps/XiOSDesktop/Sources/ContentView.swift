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
                // 自前のボタンはコンポジタの絵の上に重なる。上端には ioscbar が
                // 居るので(実機 2026-09-12 でバーの上に被っていた)、右下の空きに
                // 小さく置く。ドックは中央寄せなので右下だけは空いている。
                ZStack(alignment: .bottomTrailing) {
                    ScreenView(client: client)
                        // 上は Dynamic Island、下はホームインジケータ。どちらも iOS に譲る
                        // (コンポジタに渡す -logical も同じ分だけ小さくしてある)
                        .ignoresSafeArea(edges: .horizontal)
                    // ログは常に取り戻せるようにしておく(iosc が落ちたときに見たいのはログ)
                    VStack(spacing: 6) {
                        Button {
                            client.toggleKeyboard()
                        } label: {
                            Image(systemName: "keyboard").frame(width: 32, height: 28)
                        }
                        Button {
                            mode = .console
                        } label: {
                            Image(systemName: "terminal").frame(width: 32, height: 28)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .opacity(0.75)
                    .padding(6)
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
            log.log(Runner.measureScreen())
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
                // 普段はこれだけ。土台(iosc + 入力メソッド + 壁紙)を立てて、
                // あとは xiOS 自身のシェル(バーとドック)に任せて画面へ行く
                Button("セッション開始") { startSession() }
                    .buttonStyle(.borderedProminent).disabled(busy || opening)
                if opening { ProgressView().controlSize(.small) }
                Spacer()
                Text("footprint \(footprintMB()) MB").font(.footnote)
            }
            DisclosureGroup("部品ごとに起こす(診断用)") {
              VStack(spacing: 6) {
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
            }
            HStack {
                Button("窓") { run { $0.startTestClient() } }.buttonStyle(.bordered).disabled(busy)
                Button("ドック") { run { $0.startDock() } }.buttonStyle(.bordered).disabled(busy)
                Button("一覧") { run { $0.startOverview() } }.buttonStyle(.bordered).disabled(busy)
                Button("全部") { startEverything() }.buttonStyle(.borderedProminent).disabled(busy || opening)
            }
            HStack {
                Button("歯車") { run { $0.startGears() } }.buttonStyle(.bordered).disabled(busy)
                Button("dbus") { run { $0.startDbus() } }.buttonStyle(.bordered).disabled(busy)
                Button("エディタ") { run { $0.startEditor() } }.buttonStyle(.borderedProminent).disabled(busy)
                Spacer()
                }
              }
            }
            .font(.footnote)
            HStack {
                Toggle("詳細ログ", isOn: Binding(
                    get: { Runner.traceEnabled },
                    set: { Runner.traceEnabled = $0; setenv("LCSYS_TRACE", $0 ? "1" : "0", 1) }
                )).font(.footnote).fixedSize()
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

    // 普段の入口。土台を立てて画面へ行くだけで、何を起動するかは向こうのシェルの仕事
    private func startSession() {
        let r = ensureRunner()
        busy = true
        Thread {
            r.startSession()
            DispatchQueue.main.async {
                busy = false
                openScreen()
            }
        }.start()
    }

    // 試験用: 繋がる相手を全部起こしてから画面へ行く。1 回で全部見たいとき用。
    private func startEverything() {
        let r = ensureRunner()
        busy = true
        Thread {
            r.startEverything()
            DispatchQueue.main.async {
                busy = false
                openScreen()
            }
        }.start()
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
            // 入力は画面と別のソケット。繋がらなくても画面は出るので、失敗しても進む
            client.xin = XInputAPI(handle: handle, log: l)
            client.connectInput(path: r.inputPath())
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
