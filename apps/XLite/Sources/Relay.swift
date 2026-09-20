import Foundation
import Network

/// x.com の中身を 127.0.0.1 経由で WKWebView に渡す中継。
///
/// スクリーンタイムの Web 判定は WebKit の読み込み処理の中で URL を見る。WKWebView が開く URL を
/// http://127.0.0.1:<port>/… にすれば、その判定には x.com が渡らない。中身は URLSession で
/// x.com から取る。URLSession は CFNetwork へ直接入るので WebKit の判定を通らない。
///
/// 待ち受けは 127.0.0.1 だけに縛る(requiredLocalEndpoint)。同じ Wi-Fi の他の機械から使われると、
/// この端末を経由した x.com への出口になるため。
/// 認証情報はこちらに持たない。cookie は WKWebView が持ち、リクエストごとに転送するだけなので、
/// 同じ端末の別アプリがこのポートを叩いても、ログイン済みの応答は取れない。
final class Relay: ObservableObject {
    static let upstreamHost = "x.com"
    /// 中継に載せ替えるホスト。ここ以外(abs.twimg.com 等)は遮断対象でないので素通しする
    static let mappedHosts = ["x.com", "www.x.com", "twitter.com", "www.twitter.com"]
    private static let ports: [UInt16] = Array(8787...8796)
    private static let enabledKey = "relayEnabled"

    @Published private(set) var port: UInt16 = 0
    @Published private(set) var lastError = ""
    /// 中継を使うかどうか。切ると x.com へ直接つなぐ(遮断されるかを比べるため)
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        }
    }

    var isRunning: Bool { port != 0 }
    var baseURL: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)") }

    private let log: ConsoleLog
    private let queue = DispatchQueue(label: "com.rutoi.xlite.relay", attributes: .concurrent)
    private let session: URLSession
    private let noRedirect = NoRedirect()
    private var listener: NWListener?

    init(log: ConsoleLog) {
        self.log = log
        self.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never       // cookie は WKWebView 側が持つ
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil                        // 304 をそのまま WKWebView へ返す
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // ------------------------------------------------------------ 起動と停止

    /// 空いているポートを順に試す。全部塞がっていたら false
    @discardableResult
    func start() async -> Bool {
        guard port == 0 else { return true }
        for p in Self.ports {
            if await bind(p) { return true }
        }
        publish { self.lastError = "中継のポートを開けませんでした" }
        log.log("中継: \(Self.ports.first!)〜\(Self.ports.last!) が全部塞がっている")
        return false
    }

    func stop() {
        listener?.cancel()
        listener = nil
        publish { self.port = 0 }
    }

    private func bind(_ p: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            var settled = false
            let finish: (Bool) -> Void = { ok in
                guard !settled else { return }
                settled = true
                cont.resume(returning: ok)
            }
            guard let nwPort = NWEndpoint.Port(rawValue: p) else { finish(false); return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            guard let l = try? NWListener(using: params) else { finish(false); return }

            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener = l
                    self?.publish {
                        self?.port = p
                        self?.lastError = ""
                    }
                    self?.log.log("中継: 127.0.0.1:\(p) で待ち受け開始")
                    finish(true)
                case .failed(let e), .waiting(let e):
                    l.cancel()
                    self?.log.log("中継: \(p) は使えない (\(e))")
                    finish(false)
                case .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: queue)
        }
    }

    private func publish(_ change: @escaping () -> Void) {
        DispatchQueue.main.async { change() }
    }

    // ------------------------------------------------------------ 1接続の処理

    private struct Head {
        var method = "GET"
        var target = "/"
        var fields: [(String, String)] = []
        var bodyLength = 0
        func first(_ name: String) -> String? {
            fields.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
    }

    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let maxHead = 128 * 1024
    private static let maxBody = 16 * 1024 * 1024

    private func serve(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: queue)
        readHead(conn, buf: Data())
    }

    private func readHead(_ conn: NWConnection, buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, done, error in
            guard let self = self else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            var buf = buf
            if let chunk = chunk { buf.append(chunk) }

            guard let end = buf.range(of: Self.headTerminator) else {
                if done || buf.count > Self.maxHead { conn.cancel() } else { self.readHead(conn, buf: buf) }
                return
            }
            guard let head = self.parse(buf[..<end.lowerBound]) else {
                self.send(conn, status: 400, body: "リクエストを読めません")
                return
            }
            if head.first("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                // 長さの分かる本文だけ中継する。黙って壊すより、はっきり失敗させる
                self.send(conn, status: 411, body: "Content-Length のない本文は中継しません")
                return
            }
            guard head.bodyLength <= Self.maxBody else {
                self.send(conn, status: 413, body: "本文が大きすぎます")
                return
            }
            self.readBody(conn, head: head, body: Data(buf[end.upperBound...]))
        }
    }

    private func readBody(_ conn: NWConnection, head: Head, body: Data) {
        guard body.count < head.bodyLength else {
            forward(conn, head: head, body: Data(body.prefix(head.bodyLength)))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, done, error in
            guard let self = self else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            var body = body
            if let chunk = chunk { body.append(chunk) }
            if body.count >= head.bodyLength {
                self.forward(conn, head: head, body: Data(body.prefix(head.bodyLength)))
            } else if done {
                conn.cancel()
            } else {
                self.readBody(conn, head: head, body: body)
            }
        }
    }

    private func parse(_ raw: Data.SubSequence) -> Head? {
        guard let text = String(data: Data(raw), encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let request = lines.removeFirst().split(separator: " ")
        guard request.count >= 2 else { return nil }

        var head = Head()
        head.method = String(request[0])
        head.target = String(request[1])
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            head.fields.append((name, value))
        }
        head.bodyLength = Int(head.first("Content-Length") ?? "0") ?? 0
        return head
    }

    // ------------------------------------------------------------ x.com へ取りに行く

    /// URLSession が自分で付け直すか、中継してはいけないリクエストヘッダー
    private static let dropFromRequest: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "accept-encoding",
    ]
    /// こちらで作り直すか、127.0.0.1 に対して害になる応答ヘッダー。
    /// ponytail: CSP を落としている。upgrade-insecure-requests が入ると http の中継先へ
    /// 繋がらなくなるため。残すなら、この一覧から外して個別に書き換える
    private static let dropFromResponse: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive",
        "set-cookie", "strict-transport-security", "alt-svc", "public-key-pins",
        "content-security-policy", "content-security-policy-report-only",
    ]

    private func forward(_ conn: NWConnection, head: Head, body: Data) {
        let path = head.target.hasPrefix("http")
            ? (URL(string: head.target)?.pathAndQuery ?? "/")
            : head.target
        guard let url = URL(string: "https://\(Self.upstreamHost)\(path)") else {
            send(conn, status: 400, body: "URL を組み立てられません")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = head.method
        req.httpShouldHandleCookies = false
        if !body.isEmpty { req.httpBody = body }
        for (name, value) in head.fields {
            let key = name.lowercased()
            guard !Self.dropFromRequest.contains(key) else { continue }
            // x.com は API 呼び出しで Origin と Referer を見る。127.0.0.1 のまま送ると弾かれる
            switch key {
            case "origin": req.setValue("https://\(Self.upstreamHost)", forHTTPHeaderField: name)
            case "referer": req.setValue(toUpstream(value), forHTTPHeaderField: name)
            default: req.setValue(value, forHTTPHeaderField: name)
            }
        }

        Task { [weak self] in
            guard let self = self else { conn.cancel(); return }
            do {
                let (data, response) = try await self.session.data(for: req, delegate: self.noRedirect)
                guard let http = response as? HTTPURLResponse else {
                    self.send(conn, status: 502, body: "応答を読めません")
                    return
                }
                self.send(conn, upstream: http, url: url, data: data)
            } catch {
                self.log.log("中継: \(path) の取得に失敗 (\(error.localizedDescription))")
                self.publish { self.lastError = error.localizedDescription }
                self.send(conn, status: 502, body: "x.com へ繋がりません: \(error.localizedDescription)")
            }
        }
    }

    private func toUpstream(_ s: String) -> String {
        guard let base = baseURL?.absoluteString, s.hasPrefix(base) else { return s }
        return "https://\(Self.upstreamHost)" + s.dropFirst(base.count)
    }

    /// x.com 宛ての絶対 URL を中継の URL に直す。他のホストはそのまま
    func toLocal(_ s: String) -> String {
        guard let base = baseURL?.absoluteString else { return s }
        for host in Self.mappedHosts {
            for prefix in ["https://\(host)", "http://\(host)", "//\(host)"] {
                if s == prefix { return base }
                if s.hasPrefix(prefix + "/") { return base + s.dropFirst(prefix.count) }
            }
        }
        return s
    }

    // ------------------------------------------------------------ WKWebView へ返す

    private func send(_ conn: NWConnection, status: Int, body: String) {
        let data = Data(body.utf8)
        var headers = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        headers += "Content-Type: text/plain; charset=utf-8\r\n"
        headers += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        write(conn, Data(headers.utf8) + data)
    }

    private func send(_ conn: NWConnection, upstream: HTTPURLResponse, url: URL, data: Data) {
        var headers = "HTTP/1.1 \(upstream.statusCode) \(Self.reason(upstream.statusCode))\r\n"
        var fields: [String: String] = [:]
        for (rawKey, rawValue) in upstream.allHeaderFields {
            guard let key = rawKey as? String, let value = rawValue as? String else { continue }
            fields[key] = value
            guard !Self.dropFromResponse.contains(key.lowercased()) else { continue }
            if key.caseInsensitiveCompare("Location") == .orderedSame {
                headers += "Location: \(toLocal(value))\r\n"
            } else {
                headers += "\(key): \(value)\r\n"
            }
        }
        // Set-Cookie は allHeaderFields だと1本に繋がるので、解析し直して1件ずつ出す。
        // 中継先は http の 127.0.0.1 なので Domain と Secure は外す(付けたままだと保存されない)
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            headers += "Set-Cookie: \(Self.serialize(cookie))\r\n"
        }
        headers += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        write(conn, Data(headers.utf8) + data)
    }

    private func write(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func serialize(_ c: HTTPCookie) -> String {
        var s = "\(c.name)=\(c.value); Path=\(c.path.isEmpty ? "/" : c.path)"
        if let expires = c.expiresDate { s += "; Expires=\(rfc1123.string(from: expires))" }
        if c.isHTTPOnly { s += "; HttpOnly" }
        return s
    }

    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    // ------------------------------------------------------------ ページ側の細工

    /// JS が組み立てる絶対 URL(https://x.com/…)は WebKit の通信に入って判定に当たるので、
    /// 読み込みの最初に fetch と XMLHttpRequest を差し替えて 127.0.0.1 に向け直す。
    /// Service Worker は中継と噛み合わないので登録させない。
    static func patchScript(base: String) -> String {
        """
        (function () {
          var local = \(jsonString(base));
          var hosts = \(jsonString(mappedHosts.map { "https://" + $0 }));
          function map(u) {
            if (typeof u !== 'string') return u;
            for (var i = 0; i < hosts.length; i++) {
              if (u === hosts[i]) return local;
              if (u.indexOf(hosts[i] + '/') === 0) return local + u.slice(hosts[i].length);
            }
            return u;
          }
          var f = window.fetch;
          if (f) {
            window.fetch = function (input, init) {
              if (typeof input === 'string') input = map(input);
              else if (input && input.url && map(input.url) !== input.url) input = new Request(map(input.url), input);
              return f.call(this, input, init);
            };
          }
          var open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function () {
            if (arguments.length > 1) arguments[1] = map(arguments[1]);
            return open.apply(this, arguments);
          };
          if (navigator.sendBeacon) {
            var beacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function (u, d) { return beacon(map(u), d); };
          }
          if (navigator.serviceWorker && navigator.serviceWorker.register) {
            navigator.serviceWorker.register = function () {
              return Promise.reject(new Error('relay: service worker disabled'));
            };
          }
        })();
        """
    }

    private static func jsonString(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }
}

/// リダイレクトは追わずに 3xx のまま返す。Location を 127.0.0.1 に直して WKWebView 自身に
/// 辿らせないと、表示中の URL が x.com に戻って判定に当たる
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension URL {
    var pathAndQuery: String {
        var s = path.isEmpty ? "/" : path
        if let q = query { s += "?" + q }
        return s
    }
}
