import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WebModel
    @ObservedObject var relay: Relay
    @ObservedObject var updater: Updater
    @ObservedObject var log: ConsoleLog
    @Environment(\.dismiss) private var dismiss

    @State private var authToken = ""
    @State private var ct0 = ""
    @State private var cookieResult = ""
    @State private var userAgent = ""
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            Form {
                relaySection
                cleaner
                login
                display
                update
                logs
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .onAppear { userAgent = model.userAgent }
        }
    }

    // ------------------------------------------------------------ 中継

    private var relaySection: some View {
        Section {
            Toggle("中継を使う", isOn: $relay.enabled)
                .onChange(of: relay.enabled) { on in
                    Task {
                        if on { await relay.start() } else { relay.stop() }
                        model.relayChanged()
                    }
                }
            HStack {
                Text("状態")
                Spacer()
                Text(relay.isRunning ? "127.0.0.1:\(relay.port)" : "止まっています")
                    .foregroundStyle(.secondary)
                    .font(.system(.footnote, design: .monospaced))
            }
            if !relay.lastError.isEmpty {
                Text(relay.lastError).font(.footnote).foregroundStyle(.red)
            }
            Text(model.currentURL.isEmpty ? "(まだ開いていません)" : model.currentURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("中継")
        } footer: {
            Text("入にすると、画面は 127.0.0.1 を開き、中身だけを x.com から取ってきます。切ると x.com へ直接つなぎます。遮断されるかどうかを比べるときに切り替えてください。")
        }
    }

    // ------------------------------------------------------------ 掃除

    private var cleaner: some View {
        Section {
            Toggle("広告(プロモーション)を隠す", isOn: $model.config.ads)
            Toggle("右の段(トレンド等)を隠す", isOn: $model.config.sidebar)
            Toggle("Grok の導線を隠す", isOn: $model.config.grok)
            Toggle("Premium の勧誘を隠す", isOn: $model.config.premium)
            Toggle("「アプリで開く」の帯を隠す", isOn: $model.config.appBanner)
            Toggle("起動後は「フォロー中」を開く", isOn: $model.config.following)
            VStack(alignment: .leading, spacing: 4) {
                Text("追加 CSS").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.config.userCSS)
                    .frame(height: 90)
                    .font(.system(.footnote, design: .monospaced))
                Text("例: [data-testid=\"cellInnerDiv\"] { border: 0; }")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("画面の掃除")
        } footer: {
            Text("この画面で隠した広告: \(model.hiddenAds) 件。選んだ内容はすぐ反映されます。")
        }
    }

    // ------------------------------------------------------------ ログイン

    private var login: some View {
        Section {
            Text("まず画面でそのままログインしてみてください。弾かれるときだけ、PC のブラウザから取った cookie を貼ります。")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("auth_token", text: $authToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
            TextField("ct0", text: $ct0)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
            Button("cookie を入れる") {
                Task {
                    cookieResult = await model.importCookies(authToken: authToken, ct0: ct0)
                    authToken = ""
                    ct0 = ""
                }
            }
            Button("cookie を消す(ログアウト)", role: .destructive) {
                Task { cookieResult = await model.clearCookies() }
            }
            if !cookieResult.isEmpty {
                Text(cookieResult).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("ログイン")
        } footer: {
            Text("取り方: PC の Chrome で x.com を開く → F12 → Application → Cookies → https://x.com → auth_token と ct0 の値。これはパスワードと同じ重みなので人に渡さないでください。")
        }
    }

    // ------------------------------------------------------------ 表示

    private var display: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("User-Agent", text: $userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption2, design: .monospaced))
                HStack {
                    Button("適用") { model.userAgent = userAgent }
                    Spacer()
                    Button("既定に戻す") {
                        userAgent = WebModel.defaultUserAgent
                        model.userAgent = userAgent
                    }
                }
                .font(.footnote)
            }
        } header: {
            Text("名乗り(User-Agent)")
        } footer: {
            Text("x.com はここを見て「公式アプリを使え」と言うことがあります。既定は実機と同じ iOS 26 の Safari です。")
        }
    }

    // ------------------------------------------------------------ 更新

    private var update: some View {
        Section {
            Text(AppVersion.string).font(.footnote).foregroundStyle(.secondary)
            TextField("配布サーバー", text: $updater.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.caption2, design: .monospaced))
            HStack {
                Button("更新を確認") { Task { await updater.check() } }
                Spacer()
                if updater.phase == .available {
                    Button("入れる") { Task { await updater.update() } }.buttonStyle(.borderedProminent)
                }
            }
            if updater.phase == .downloading || updater.phase == .installing {
                ProgressView(value: updater.progress)
            }
            if !updater.message.isEmpty {
                Text(updater.message).font(.footnote).foregroundStyle(.secondary)
            }
            if updater.phase == .done {
                Button("終了する") { updater.quit() }
            }
        } header: {
            Text("アップデート")
        }
    }

    // ------------------------------------------------------------ ログ

    private var logs: some View {
        Section {
            Button(showLog ? "ログを隠す" : "ログを見る") { showLog.toggle() }
            if showLog {
                ScrollView {
                    Text(log.text.isEmpty ? "(まだ何もありません)" : log.text)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 200)
            }
            Button("PC へ送る") { Task { await updater.sendLog() } }
            if !updater.sendState.isEmpty {
                Text(updater.sendState).font(.footnote).foregroundStyle(.secondary)
            }
            Button("ログを消す", role: .destructive) { log.clear() }
        } header: {
            Text("ログ")
        }
    }
}
