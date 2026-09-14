import Foundation
import WebKit

/// x.com に流し込む掃除屋の設定。JSON にして JS 側へ渡す。
struct CleanerConfig: Codable, Equatable {
    var ads = true          // プロモーション(広告)の投稿を隠す
    var sidebar = true      // 右の余計な段(トレンド・おすすめユーザー)
    var grok = true         // Grok の導線
    var premium = true      // Premium 勧誘
    var appBanner = true    // 「アプリで開く」の帯
    var following = true    // 起動後の最初の1回だけ「フォロー中」タブに寄せる
    var userCSS = ""        // 自分で足す CSS(画面を見ながら育てる用)

    static let key = "cleanerConfig"

    static func load() -> CleanerConfig {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(CleanerConfig.self, from: d) else { return CleanerConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var json: String {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

enum Cleaner {
    static let messageName = "xlite"

    /// 読み込みのたびに最初に走る本体。CSS を貼り、DOM の変化を見張って広告の行を畳む。
    /// x.com は画面を差し替えても再読み込みしない作りなので、MutationObserver が要る。
    static func source(_ cfg: CleanerConfig) -> String {
        #"""
        (function () {
          if (window.__xliteReady) { window.__xliteApply(__CFG__); return; }
          window.__xliteReady = true;

          var CFG = __CFG__;
          var AD_WORDS = ["プロモーション", "Promoted", "広告", "Sponsored", "Promocionado"];
          var RULES = {
            sidebar: '[data-testid="sidebarColumn"]',
            grok: 'a[href="/i/grok"],[data-testid="GrokDrawer"],[data-testid="grokImagineButton"]',
            premium: 'a[href="/i/premium_sign_up"],a[href="/i/verified-choose"],[data-testid="premium-signup-tab"]',
            appBanner: '[data-testid="BottomBar"],[data-testid="AppTabBar_AppDownloadCallout"]'
          };
          var hiddenCount = 0;
          var swept = 0;

          function styleEl() {
            var el = document.getElementById("xlite-style");
            if (!el) {
              el = document.createElement("style");
              el.id = "xlite-style";
              (document.head || document.documentElement).appendChild(el);
            }
            return el;
          }

          function applyCSS() {
            var parts = [];
            for (var k in RULES) { if (CFG[k]) { parts.push(RULES[k] + "{display:none !important;}"); } }
            if (CFG.userCSS) { parts.push(CFG.userCSS); }
            styleEl().textContent = parts.join("\n");
          }

          // 広告かどうか。文字で判定するのは誤爆するので、短い span がまるごと
          // 「プロモーション」等と一致する場合だけに絞る
          function isAd(cell) {
            if (cell.querySelector('[data-testid="placementTracking"]')) { return true; }
            var spans = cell.querySelectorAll("span");
            var n = spans.length < 40 ? spans.length : 40;
            for (var i = 0; i < n; i++) {
              var t = (spans[i].textContent || "").trim();
              for (var j = 0; j < AD_WORDS.length; j++) { if (t === AD_WORDS[j]) { return true; } }
            }
            return false;
          }

          function sweep() {
            if (!CFG.ads) { return; }
            var cells = document.querySelectorAll('[data-testid="cellInnerDiv"]:not([data-xlite])');
            for (var i = 0; i < cells.length; i++) {
              var c = cells[i];
              c.setAttribute("data-xlite", "1");
              swept++;
              if (isAd(c)) { c.style.display = "none"; hiddenCount++; }
            }
          }

          // 起動後の最初の1回だけ「フォロー中」に寄せる。毎回やると手で切り替えられなくなる
          function preferFollowing() {
            if (!CFG.following) { return; }
            try { if (sessionStorage.getItem("xliteFollowing")) { return; } } catch (e) { return; }
            if (location.pathname !== "/home") { return; }
            var tabs = document.querySelectorAll('[role="tablist"] [role="tab"]');
            if (tabs.length < 2) { return; }
            try { sessionStorage.setItem("xliteFollowing", "1"); } catch (e) {}
            if (tabs[0].getAttribute("aria-selected") === "true") { tabs[1].click(); }
          }

          var timer = null;
          function schedule() {
            if (timer) { return; }
            timer = setTimeout(function () {
              timer = null;
              sweep();
              preferFollowing();
            }, 120);
          }

          window.__xliteApply = function (c) {
            CFG = c;
            applyCSS();
            // 設定を変えたら判定をやり直す
            var marked = document.querySelectorAll("[data-xlite]");
            for (var i = 0; i < marked.length; i++) {
              marked[i].removeAttribute("data-xlite");
              marked[i].style.display = "";
            }
            hiddenCount = 0;
            sweep();
          };

          window.__xliteStats = function () {
            return { hidden: hiddenCount, swept: swept, url: location.href };
          };

          applyCSS();
          schedule();

          function observe() {
            if (!document.body) { setTimeout(observe, 50); return; }
            new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
            schedule();
          }
          observe();

          // 画面遷移(履歴の push/replace)も拾う
          var push = history.pushState;
          history.pushState = function () { push.apply(this, arguments); schedule(); };
          var rep = history.replaceState;
          history.replaceState = function () { rep.apply(this, arguments); schedule(); };
          window.addEventListener("popstate", schedule);

          setInterval(function () {
            try {
              window.webkit.messageHandlers.xlite.postMessage(window.__xliteStats());
            } catch (e) {}
          }, 5000);
        })();
        """#
        .replacingOccurrences(of: "__CFG__", with: cfg.json)
    }

    static func userScript(_ cfg: CleanerConfig) -> WKUserScript {
        WKUserScript(source: source(cfg), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
