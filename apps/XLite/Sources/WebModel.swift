import SwiftUI
import UIKit
import WebKit

/// x.com をそのまま開く WKWebView を1つだけ持ち、画面の状態を SwiftUI へ流す。
///
/// 公式アプリのログインは端末証明(App Attest)で塞がれているが、web のログインは生きている。
/// だからここでは API を叩かず、本物の x.com をそのまま表示して、邪魔なものだけ CSS/JS で消す。
@MainActor
final class WebModel: NSObject, ObservableObject {
    static let home = URL(string: "https://x.com/home")!
    /// x.com は「Safari かどうか」を UA で見る。WKWebView の既定 UA は Version/… Safari/… を
    /// 含まないので、実機と同じ iOS 26 の Safari を名乗る
    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL = ""
    @Published private(set) var hiddenAds = 0
    @Published var lastError = ""

    @Published var config: CleanerConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()
            apply()
        }
    }

    let webView: WKWebView
    let log: ConsoleLog
    private var tokens: [NSKeyValueObservation] = []

    init(log: ConsoleLog) {
        self.log = log
        self.config = CleanerConfig.load()

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()            // cookie を残す(ログインを保つ)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()

        webView.customUserAgent = UserDefaults.standard.string(forKey: "userAgent") ?? Self.defaultUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // WKWebView は configuration を複製して持つので、作った後は必ず webView.configuration 側を触る
        webView.configuration.userContentController.add(self, name: Cleaner.messageName)
        installScript()
        observe()
    }

    // ------------------------------------------------------------ 掃除屋

    private func installScript() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(Cleaner.userScript(config))
    }

    /// 設定を変えたとき: 次の読み込み用に差し替え、いま開いている画面にも即反映する
    private func apply() {
        installScript()
        let js = "if (window.__xliteApply) { window.__xliteApply(\(config.json)); }"
        webView.evaluateJavaScript(js) { [weak self] _, err in
            if let err = err { self?.log.log("設定の反映に失敗: \(err.localizedDescription)") }
        }
    }

    // ------------------------------------------------------------ 状態の観測

    private func observe() {
        tokens = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.pageTitle = wv.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.currentURL = wv.url?.absoluteString ?? "" }
            },
        ]
    }

    // ------------------------------------------------------------ 操作

    func loadHome() { webView.load(URLRequest(url: Self.home)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reloadFromOrigin() }

    func open(_ path: String) {
        guard let u = URL(string: path.hasPrefix("http") ? path : "https://x.com" + path) else { return }
        webView.load(URLRequest(url: u))
    }

    // ------------------------------------------------------------ cookie

    /// PC のブラウザから取った auth_token / ct0 を流し込む。
    /// web のログイン画面が弾かれたときの逃げ道(xcli と同じ材料)。
    func importCookies(authToken: String, ct0: String) async -> String {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let csrf = ct0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !csrf.isEmpty else { return "auth_token と ct0 の両方が要ります" }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let expires = Date().addingTimeInterval(60 * 60 * 24 * 365)
        var made = 0
        for domain in [".x.com", ".twitter.com"] {
            for (name, value) in [("auth_token", token), ("ct0", csrf)] {
                let props: [HTTPCookiePropertyKey: Any] = [
                    .domain: domain, .path: "/", .name: name, .value: value,
                    .secure: "TRUE", .expires: expires,
                ]
                guard let c = HTTPCookie(properties: props) else { continue }
                await store.setCookie(c)
                made += 1
            }
        }
        log.log("cookie を \(made) 件入れた")
        loadHome()
        return "cookie を \(made) 件入れました。読み込み直します"
    }

    func clearCookies() async -> String {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let targets = records.filter { $0.displayName.contains("x.com") || $0.displayName.contains("twitter") }
        await store.removeData(ofTypes: types, for: targets)
        log.log("cookie とデータを消した(\(targets.count) 件)")
        loadHome()
        return "\(targets.count) 件消しました"
    }

    var userAgent: String {
        get { webView.customUserAgent ?? Self.defaultUserAgent }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ua = v.isEmpty ? Self.defaultUserAgent : v
            webView.customUserAgent = ua
            UserDefaults.standard.set(ua, forKey: "userAgent")
            reload()
        }
    }
}

// ------------------------------------------------------------ 画面遷移の振り分け

extension WebModel: WKNavigationDelegate {
    private static let inApp: Set<String> = ["x.com", "www.x.com", "mobile.x.com",
                                             "twitter.com", "www.twitter.com", "mobile.twitter.com",
                                             "api.x.com", "abs.twimg.com", "pbs.twimg.com", "video.twimg.com"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let host = url.host else {
            decisionHandler(.allow); return
        }
        // 画面の中身(iframe など)はそのまま。人が押した外部リンクだけ Safari へ出す
        if action.navigationType == .linkActivated, !Self.inApp.contains(host), url.scheme?.hasPrefix("http") == true {
            log.log("外部リンクを Safari へ: \(url.absoluteString)")
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = ""
        log.log("表示: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastError = error.localizedDescription
        log.log("失敗: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        lastError = error.localizedDescription
        log.log("接続失敗: \(error.localizedDescription)")
    }
}

// ------------------------------------------------------------ 新しい窓は同じ画面で開く

extension WebModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

// ------------------------------------------------------------ JS からの報告

extension WebModel: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let hidden = body["hidden"] as? Int else { return }
        Task { @MainActor in self.hiddenAds = hidden }
    }
}
