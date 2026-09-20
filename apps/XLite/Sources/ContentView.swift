import SwiftUI
import WebKit

/// WKWebView を SwiftUI に載せるだけの入れ物。実体は WebModel が1つだけ持ち続ける
/// (画面を作り直すたびに新しくすると、ログインも履歴も飛ぶため)。
struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var log = ConsoleLog()
    @StateObject private var updater: Updater
    @StateObject private var relay: Relay
    @StateObject private var model: WebModel
    @State private var showSettings = false
    @State private var started = false

    init() {
        let l = ConsoleLog()
        let r = Relay(log: l)
        _log = StateObject(wrappedValue: l)
        _updater = StateObject(wrappedValue: Updater(log: l))
        _relay = StateObject(wrappedValue: r)
        _model = StateObject(wrappedValue: WebModel(log: l, relay: r))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                WebContainer(webView: model.webView)
                if model.isLoading {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
                if !model.lastError.isEmpty {
                    Text(model.lastError)
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                        .onTapGesture { model.lastError = "" }
                }
            }
            bar
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, relay: relay, updater: updater, log: log)
        }
        .task {
            guard !started else { return }
            started = true
            Updater.cleanup()          // 前回の更新で残った旧版を片づける
            log.log("起動 \(AppVersion.string)")
            // 中継を先に立ててから開く。失敗したら x.com へ直接つなぐ(model.home が切り替わる)
            if relay.enabled { await relay.start() }
            model.relayChanged()
        }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            button("chevron.backward", enabled: model.canGoBack) { model.goBack() }
            button("chevron.forward", enabled: model.canGoForward) { model.goForward() }
            button("house") { model.loadHome() }
            button("bell") { model.open("/notifications") }
            button("magnifyingglass") { model.open("/explore") }
            button("arrow.clockwise") { model.reload() }
            button("gearshape") { showSettings = true }
        }
        .padding(.top, 6)
        .background(.bar)
    }

    private func button(_ name: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}
