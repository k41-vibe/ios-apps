import Foundation
import Darwin
import UIKit

/// 生成するテキストファイルの改行(Swift の文字列リテラル内に直接書かずに済ませる)
private let LF = String(UnicodeScalar(10))

// コンソール。画面用の文字列と、落ちても残るようファイルへ書く。
//
// 【重要】1 行ごとに fsync + @Published への追記をしていたら、経路変換の追跡を有効にした
// 実機でアプリが這った(毎秒数千行 × ディスク同期 × 全文再描画)。書き込みはまとめて行い、
// 画面用の文字列は上限で切り、fsync は節目だけにする。
final class ConsoleLog: ObservableObject {
    @Published var text = ""
    let fileURL: URL
    private var fh: FileHandle?
    private let lock = NSLock()
    private var pending = ""          // まだファイルにも画面にも出していない分
    private var flushScheduled = false
    private var sinceSync = 0
    private static let maxOnScreen = 120_000   // 画面に保持する文字数の上限
    private static let syncEvery = 256 * 1024  // これだけ書いたら 1 回 fsync

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("xiosdesktop.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fh = try? FileHandle(forWritingTo: fileURL)
        _ = try? fh?.seekToEnd()
    }

    // ホスト側の 1 行(時刻付き)
    func log(_ s: String) {
        append("[\(Self.stamp())] \(s)\n")
    }

    // ゲストの stdout/stderr(パイプから来た生バイト)
    func raw(_ s: String) {
        append(s)
    }

    private func append(_ s: String) {
        lock.lock()
        pending += s
        let needSchedule = !flushScheduled
        if needSchedule { flushScheduled = true }
        lock.unlock()
        if needSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
        }
    }

    /// たまった分をファイルへ書き、画面用の文字列を更新する(主スレッド)。
    func flush() {
        lock.lock()
        let chunk = pending
        pending = ""
        flushScheduled = false
        if let d = chunk.data(using: .utf8), !d.isEmpty {
            fh?.write(d)
            sinceSync += d.count
            if sinceSync >= Self.syncEvery {
                try? fh?.synchronize()
                sinceSync = 0
            }
        }
        lock.unlock()
        guard !chunk.isEmpty else { return }
        var t = text + chunk
        if t.count > Self.maxOnScreen {
            t = "…(古い行は省略。全文は共有かファイルで)\n" + String(t.suffix(Self.maxOnScreen))
        }
        text = t
    }

    /// 共有やコピーの直前に呼ぶ。取りこぼしを無くす。
    func sync() {
        flush()
        lock.lock(); try? fh?.synchronize(); sinceSync = 0; lock.unlock()
    }

    func previous() -> String {
        sync()
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func clearFile() {
        lock.lock()
        pending = ""
        try? fh?.truncate(atOffset: 0)
        sinceSync = 0
        lock.unlock()
        text = ""
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

// phys_footprint(jetsam 判定値)を MB で
func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}

// libLCsys.dylib を dlopen し、procd 経由でゲストを「スレッドとして」走らせる。
//
// ホストが受け持つのは 3 つだけ: 画面(ScreenView)、指と文字(xinput)、土台(procd と環境)。
// 何を起動してどう並べるかは xiOS 自身のシェル(バーとドック)の仕事で、ここは
// run-shell.sh(iosc → ioscbg → ioscbar → ioscdock)と同じ順に起こすところまで。
final class Runner {
    typealias InitFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    typealias SpawnFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                                        UnsafePointer<UnsafeMutablePointer<CChar>?>?, Int32, Int32) -> Int32
    typealias WaitFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>?) -> Int32
    typealias AliveFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>?) -> Int32

    let log: ConsoleLog
    // dlopen した libLCsys.dylib。ScreenView が xs_* をここから引く
    private(set) var libHandle: UnsafeMutableRawPointer?
    private var spawnFn: SpawnFn?
    private var waitFn: WaitFn?
    private var aliveFn: AliveFn?
    private var ready = false
    private var pipeWrite: Int32 = -1
    private let lock = NSLock()   // 同時に 1 コマンドずつ(stdout/env がプロセス共有なので)
    // 待たずに起動したゲスト(iosc など)。lock とは別の錠: iosc が走っている間 lock は空けておく
    private var started: [Int32: String] = [:]
    private let startedLock = NSLock()

    static let pathDirs = "/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin"
    static let ioscPath = "/var/jb/usr/local/bin/iosc"
    static let footPath = "/var/jb/usr/bin/foot"

    // ------------------------------------------------------------ 画面の大きさ
    //
    // xiOS のシェルは幅 1440 を基準に描き、その縮尺 ui = 論理幅/1440 を 0.6〜2.5 に
    // 収める(iosc-shell.c pl_ui)。iPhone の 393 幅をそのまま渡すと 0.27 → 0.6 に
    // 切り上げられ、「幅 864 のつもり」で描いた帯の右が切れる(実機 2026-09-12)。
    // xiOS 自身も iPad で 1440 論理を 2160 のパネルに縮小して映しているので
    // (xios-app.md "Render Scale")、同じ手で行く: 論理幅を 864 に固定し、高さは
    // 画面の縦横比から決め、ScreenView が aspect-fit で縮小する。タッチの逆変換は
    // ScreenView.fbPoint がビューポート基準なので、そのままで合う。
    static let logicalWidth = 864
    static var logicalPoints = CGSize(width: 864, height: 1668)   // 14 Pro の縦横比の既定
    static var topInsetPoints: CGFloat = 59

    /// UIKit から安全領域を読んで logicalPoints を決める。**メインスレッドから呼ぶこと**。
    static func measureScreen() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
                ?? scenes.flatMap({ $0.windows }).first else {
            return "画面の大きさが読めないので既定値 \(Int(logicalPoints.width))x\(Int(logicalPoints.height)) を使う"
        }
        let b = win.bounds, ins = win.safeAreaInsets
        topInsetPoints = ins.top
        // 上は Dynamic Island、下はホームインジケータ。どちらも iOS に譲った残りが画面
        let usableW = b.width, usableH = b.height - ins.top - ins.bottom
        let h = (CGFloat(logicalWidth) * usableH / max(usableW, 1)).rounded()
        logicalPoints = CGSize(width: CGFloat(logicalWidth), height: h)
        return "画面 \(Int(b.width))x\(Int(b.height)) pt、安全領域 上 \(Int(ins.top)) / 下 \(Int(ins.bottom)) pt "
            + "-> 使える範囲 \(Int(usableW))x\(Int(usableH)) pt、コンポジタの論理画面は \(logicalWidth)x\(Int(h))"
            + "(縮小率 \(String(format: "%.2f", usableW / CGFloat(logicalWidth))))"
    }

    /// 背景スレッドから: いまの向きで測り直す(UIWindow は主スレッドでしか読めない)
    static func remeasureOnMain() -> String {
        if Thread.isMainThread { return measureScreen() }
        var r = ""
        DispatchQueue.main.sync { r = measureScreen() }
        return r
    }

    static func logicalArg() -> String {
        "\(Int(logicalPoints.width.rounded()))x\(Int(logicalPoints.height.rounded()))"
    }
    /// 経路変換の追跡。iosc を起こす前に立てること(環境変数はプロセス全体で 1 つ)
    static var traceEnabled = false
    /// fork の再現(スタック複製)を使うか。暴れたときに実機から切れるようにしておく
    static var forkCloneEnabled = true
    /// ドック(下のアプリ一覧)を出すか。出すと画面の下 70 が窓の置けない領域になり、
    /// 窓の既定の高さ(画面 - 80)が作業領域(画面 - 92)に必ず 12 収まらなくなる。
    /// 出さなければ作業領域は画面 - 22 になり、窓が収まる。一覧はコンソールの「一覧」から開ける
    static var dockEnabled = true

    let home: String
    let tmp: String
    let runtimeDir: String
    let xiosDir: String

    init(log: ConsoleLog) {
        self.log = log
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        home = docs + "/home"
        var t = NSTemporaryDirectory()
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        tmp = t
        // 名前が 1 文字なのは AF_UNIX の sun_path が 104 バイトしかないから。
        // 実機の $TMPDIR は 88 文字(G0)で、"/xdg-runtime/wayland-0" を足すと 111 B で超える。
        runtimeDir = t + "/r"
        xiosDir = t + "/x"
    }

    // ------------------------------------------------------------ 環境
    //
    // ゲストが getenv で見るのはプロセス環境なので setenv も行う(プロセス全体で 1 つ)。
    // 値は xiOS 側の起動スクリプトに合わせる: run-shell.sh(iosc-shell)、
    // shell-draw.h sd_launch(ドックからの起動)、xios-session-lib.sh の `app` 節。
    func environment() -> [String: String] {
        [
            "HOME": home,
            "TMPDIR": tmp,
            "PATH": Self.pathDirs,
            "XDG_RUNTIME_DIR": runtimeDir,
            // 絶対パス。xios-session-lib.sh:1236 と同じ作法で、シェルが起動するアプリの
            // XDG_RUNTIME_DIR を共有バスの置き場へ差し替えても(sd_launch)、
            // クライアントはコンポジタを見失わない。iosc 自身は -s wayland-0 で作る
            "WAYLAND_DISPLAY": runtimeDir + "/wayland-0",
            // IOSC_DEBUG は「毎フレーム GPU から画素を読み戻して検証する」モード
            // (wayland_iosc.c:1924、同期の GPU→CPU 読み戻し)。実機で「重い」の原因なので切る。
            // 起動時の要点(listening / globals)は IOSC_DEBUG 無しでも出る
            "IOSC_SHELL_DEBUG": "1",             // run-shell.sh の既定。タッチの当たり判定を記録する
            "IOSC_PANEL_SCALE": "2",             // iosc の -scale と同じ(帯の描画倍率)
            // 経路変換の 1 件ずつの記録。毎秒数千行出るので既定は切る(「詳細ログ」で入れる)
            "LCSYS_TRACE": Runner.traceEnabled ? "1" : "0",
            // fork をスタック複製で再現する。"fail" にすると従来どおり -1 を返す
            "LCSYS_FORK": Runner.forkCloneEnabled ? "clone" : "fail",
            "IOSC_IGNORE_ACTIVE_SESSION": "1",   // /var/jb/tmp/xios-active-session は読めない
            "XIOS_RUNTIME_TMP": runtimeDir,      // クライアント側のログ置き場 (XSurface.c)
            "XDG_DATA_DIRS": "/var/jb/usr/share:/var/jb/usr/local/share",
            // iOS に在る UTF-8 ロケールはこの綴りだけ(foot の iOS パッチ 0001、wayland-apps.md、
            // sd_launch の setenv("LC_CTYPE","UTF-8") の 3 箇所が一致)。LANG / LC_ALL は
            // 設定しない: en_US.UTF-8 も C.UTF-8 も引けず、LC_ALL は LC_CTYPE を上書きする
            "LC_CTYPE": "UTF-8",
            // GTK/GLib のアプリ向け(sd_launch:415-422 と同じ)。壁紙やバーには無害
            "GDK_BACKEND": "wayland",
            // gl(古い OpenGL 描画)。ngl は描画中に落ちた(2026-09-16 の SIGSEGV)。
            // cairo(CPU 描画)は安定だが遅い。この GTK は gl も持っており、上流で ngl が
            // 落ちるときの定番の回避先がこれ。落ちるようなら cairo に戻す。
            // 元の指摘: xiOS 自身は profile.d/10-gtk-renderer.sh で cairo を指定している。
            // getenv はプロセスの環境を読むので、効くのはここ(procd の envp 上書きは見えない)
            "GSK_RENDERER": "gl",
            "ANGLE_REAL_LIBEGL": "/var/jb/lib/angle/libEGL.angle.dylib",
            "GSETTINGS_BACKEND": "memory",
            "GTK_A11Y": "none",
            // 初回起動で生成する「パッケージの後処理」の置き場(firstLaunchSetup)
            "GSETTINGS_SCHEMA_DIR": schemaDir,
            "GDK_PIXBUF_MODULE_FILE": loadersCachePath,
            "XDG_CACHE_HOME": cacheDir,
            // 保存先や設定の置き場。渡していないと GLib は既定値を組み立てられず、
            // gnome-text-editor は書類フォルダが決まらないまま保存に失敗する
            // (実機 2026-09-14 のログ: improperly configured XDG_DOCUMENTS_DIR)
            "XDG_DATA_HOME": dataHome,
            "XDG_CONFIG_HOME": configHome,
            "XDG_STATE_HOME": stateHome,
            // ioscbg のデスクトップ部品(Storage / Memory / Load / Session)の置き場
            "IOSC_WIDGET_CONFIG": widgetConfigPath,
            // 一覧とドックに出すアプリ(shell-draw.h sd_scan_apps: ここを先に読み、そのあと
            // /usr/share/applications を足す)。xiOS の deb には GUI アプリの .desktop がほぼ無く
            // (実機 2026-09-13: foot 系 3 件だけ)、テキストエディタが一覧に出なかった
            "IOSC_APPS_DIR": appsDir,
            "IOSC_WM_SOCK": xiosDir + "/wm",     // procd が「2 回目のタップ = 既存の窓を前へ」に使う
            "XCURSOR_THEME": "Adwaita",          // libwayland-cursor 側の既定(settings.ini と同じ向き)
            "XCURSOR_SIZE": "32",
            "SHELL": "/var/jb/usr/bin/bash",
            "USER": "mobile",
        ]
    }

    // ------------------------------------------------------------ 初回起動の後処理
    //
    // deb の postinst は一度も走っていない(ipa は読み取り専用で、そこには書けない)。
    // 必要なものを書ける場所に生成して環境変数で指す。
    //   libgtk-4-1 の postinst: glib-compile-schemas → GSETTINGS_SCHEMA_DIR
    //   libgdk-pixbuf の loaders.cache          → GDK_PIXBUF_MODULE_FILE
    //   fontconfig の fc-cache                   → XDG_CACHE_HOME
    // これが無いと GTK4 のアプリは g_settings_new で abort し(wayland-apps.md の hitori の項)、
    // SVG のアイコンは描けない(ドックが頭文字になっていた一因)。

    var schemaDir: String { home + "/glib-schemas" }
    var loadersCachePath: String { home + "/loaders.cache" }
    var cacheDir: String { home + "/cache" }
    var widgetConfigPath: String { home + "/iosc-widgets.conf" }
    var appsDir: String { home + "/applications" }
    var dataHome: String { home + "/.local/share" }
    var configHome: String { home + "/.config" }
    var stateHome: String { home + "/.local/state" }
    var documentsDir: String { home + "/Documents" }

    private func firstLaunchSetup() {
        let fm = FileManager.default
        // fontconfig は cachedir が無いと作らずに諦める(実機 2026-09-13: "not cleaning non-existent cache directory")
        try? fm.createDirectory(atPath: cacheDir + "/fontconfig", withIntermediateDirectories: true)
        for d in [dataHome, configHome, stateHome, documentsDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        // g_get_user_special_dir は環境変数ではなく user-dirs.dirs だけを読む。
        // 無いと書類フォルダが NULL になり、保存の経路が途中で止まる
        let userDirs = configHome + "/user-dirs.dirs"
        if !fm.fileExists(atPath: userDirs) {
            let text = ["XDG_DOCUMENTS_DIR=\"$HOME/Documents\"",
                        "XDG_DOWNLOAD_DIR=\"$HOME/Documents\"",
                        "XDG_DESKTOP_DIR=\"$HOME/Documents\"", ""].joined(separator: LF)
            do { try text.write(toFile: userDirs, atomically: true, encoding: .utf8) }
            catch { log.log("user-dirs.dirs が書けない: \(error.localizedDescription)") }
        }

        // gdk-pixbuf: 積んでいるローダーは SVG の 1 本だけ(PNG/JPEG は本体に内蔵)。
        // 形式は gdk-pixbuf-query-loaders の出力そのもので、モジュールの場所はゲストの
        // パスで書く(g_module_open → dlopen → 経路変換 → Frameworks/ の実体)
        // 書式は gdk-pixbuf-io.c gdk_pixbuf_io_init_modules のパーサに厳密に合わせる:
        // モジュールの終わりは「空行」。`""` の行を置くとパターン行として読まれて失敗し、
        // 上流のエラー経路が配列の途中を g_free してプロセスごと落ちる
        // (2026-09-13 のクラッシュレポート: ioscbar → gdk_pixbuf_new_from_file → abort)。
        // 生成物なので毎回書き直す(前の版の壊れた内容を残さない)。
        let loaders = [
            "# GdkPixbuf Image Loader Modules file",
            "# generated by XiOSDesktop at launch",
            "#",
            "\"/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so\"",
            "\"svg\" 6 \"gdk-pixbuf\" \"Scalable Vector Graphics\" \"LGPL\"",
            "\"image/svg+xml\" \"image/svg\" \"image/svg-xml\" \"image/vnd.adobe.svg+xml\" \"text/xml-svg\" \"image/svg+xml-compressed\" \"\"",
            "\"svg\" \"svgz\" \"svg.gz\" \"\"",
            "\" <svg\" \"*    \" 100",
            "\" <!DOCTYPE svg\" \"*             \" 100",
            "",
            "",
        ].joined(separator: "\n")
        do { try loaders.write(toFile: loadersCachePath, atomically: true, encoding: .utf8) }
        catch { log.log("loaders.cache が書けない: \(error.localizedDescription)") }

        // 一覧・ドック用の .desktop(生成物なので毎回書く)。Exec は PATH から引ける名前で、
        // sd_launch が `sh -lc "<Exec>"` にし、procd が dash を通さず直接起こす
        try? fm.createDirectory(atPath: appsDir, withIntermediateDirectories: true)
        let apps: [(file: String, body: [String])] = [
            ("org.gnome.TextEditor.desktop", [
                "[Desktop Entry]", "Type=Application", "Name=Text Editor",
                "Exec=gnome-text-editor", "Icon=org.gnome.TextEditor",
            ]),
            // Gears(mesa-demos 8.4.0 の es2gears)は GL の確認用。閉じる要求を無視する古いデモで
            // 消せないので一覧からは外す(NoDisplay)。必要ならコンソールの「歯車」で起こせる
            ("es2gears.desktop", [
                "[Desktop Entry]", "Type=Application", "Name=Gears", "NoDisplay=true",
                "Exec=es2gears_wayland", "Icon=applications-graphics",
            ]),
        ]
        for a in apps {
            let text = a.body.joined(separator: LF) + LF
            do { try text.write(toFile: appsDir + "/" + a.file, atomically: true, encoding: .utf8) }
            catch { log.log("\(a.file) が書けない: \(error.localizedDescription)") }
        }

        // GTK4 の設定(GtkSettings が $XDG_CONFIG_HOME/gtk-4.0/settings.ini を読む)。
        // カーソルテーマ名が無いと GDK は "default" を探し、ipa には Adwaita しか無いので失敗、
        // その後ポインタが窓に入った瞬間に g_assert(cursor_theme_name) で abort する
        // (クラッシュレポート 2026-09-13 20:09、gdkdisplay-wayland.c)。名前を Adwaita にしておく
        let gtkConf = home + "/.config/gtk-4.0"
        try? fm.createDirectory(atPath: gtkConf, withIntermediateDirectories: true)
        let settings = ["[Settings]", "gtk-cursor-theme-name=Adwaita", "gtk-cursor-theme-size=32",
                        "gtk-icon-theme-name=Adwaita", ""].joined(separator: LF)
        do { try settings.write(toFile: gtkConf + "/settings.ini", atomically: true, encoding: .utf8) }
        catch { log.log("settings.ini が書けない: \(error.localizedDescription)") }

        // ioscbg の部品の配置。書式は `名前 x y 有効`(ioscbg.c:224 fscanf "%31s %d %d %d")。
        // ioscbg は部品を動かすたびに同じファイルへ書き戻すので、初回だけ書く
        if !fm.fileExists(atPath: widgetConfigPath) {
            let text = "storage 24 140 1\nmemory 24 260 1\nload 24 380 1\nuptime 24 500 1\n"
            do { try text.write(toFile: widgetConfigPath, atomically: true, encoding: .utf8) }
            catch { log.log("デスクトップ部品の設定が書けない: \(error.localizedDescription)") }
        }
    }

    /// ゲストを走らせる後処理(setup の後、iosc の前)。
    private func firstLaunchGuestSetup() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: schemaDir + "/gschemas.compiled") {
            try? fm.createDirectory(atPath: schemaDir, withIntermediateDirectories: true)
            log.log("初回: GSettings のスキーマを compile(libgtk-4-1 の postinst 相当)")
            _ = run(["/var/jb/usr/bin/glib-compile-schemas", "--targetdir=" + schemaDir,
                     "/var/jb/usr/share/glib-2.0/schemas"])
        }
        if !fm.fileExists(atPath: cacheDir + "/fontconfig") {
            log.log("初回: フォントのキャッシュを作る(fontconfig の postinst 相当)")
            // -v: 実機 2026-09-13 で全ディレクトリが "failed to write cache" になった。
            // どの cachedir に書こうとして何で失敗したかをログに残す
            _ = run(["/var/jb/usr/bin/fc-cache", "-fv"])
        }
    }

    // 1 回だけ: パイプを fd1/2 に被せ、libLCsys を読み、lcsys_init
    func setup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ready { return true }
        let bundle = Bundle.main.bundlePath
        // tmp/run/dbus: /var/jb/var/run の写し先(pathmap.c)。dbus-daemon は socket を作るだけで dir は作らない
        for d in [home, runtimeDir, xiosDir, tmp + "/run/dbus"] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        // 前回終了したときのソケットとロックが残っている。中身は死んでいるのに
        // ファイルとしては在るので、「wayland-0 があるから iosc は動いている」という
        // 判定が外れる(実機 2026-09-12)。起動時に掃除する。
        // 共有バスの置き場(/var/jb/tmp/iosc-shell-bus → tmp/iosc-shell-bus)も同じ
        let fm = FileManager.default
        for d in [runtimeDir, xiosDir, tmp + "/iosc-shell-bus"] {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n != "procd" {
                try? fm.removeItem(atPath: d + "/" + n)
            }
        }
        firstLaunchSetup()
        for (k, v) in environment() { setenv(k, v, 1) }
        unsetenv("LANG")
        unsetenv("LC_ALL")

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { log.log("pipe failed errno \(errno)"); return false }
        pipeWrite = fds[1]
        let rd = fds[0]
        let logRef = log
        Thread {
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(rd, &buf, buf.count)
                if n <= 0 { break }
                logRef.raw(String(decoding: buf[0..<n], as: UTF8.self))
            }
        }.start()
        dup2(pipeWrite, 1)
        dup2(pipeWrite, 2)

        let lib = bundle + "/Frameworks/libLCsys.dylib"
        guard let h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL) else {
            log.log("dlopen(libLCsys) FAILED: \(String(cString: dlerror()))")
            return false
        }
        libHandle = h
        guard let pi = dlsym(h, "lcsys_init"), let ps = dlsym(h, "lcsys_spawn"), let pw = dlsym(h, "lcsys_wait"),
              let pa = dlsym(h, "lcsys_alive") else {
            log.log("dlsym(lcsys_*) FAILED: \(String(cString: dlerror()))")
            return false
        }
        let initFn = unsafeBitCast(pi, to: InitFn.self)
        spawnFn = unsafeBitCast(ps, to: SpawnFn.self)
        waitFn = unsafeBitCast(pw, to: WaitFn.self)
        aliveFn = unsafeBitCast(pa, to: AliveFn.self)
        let rc = initFn(bundle, home, tmp, pipeWrite)
        log.log("lcsys_init -> \(rc); home=\(home) tmp=\(tmp)")
        ready = rc == 0
        return ready
    }

    // argv[0] はゲストの元パス(coreutils の multi-call と bash が見る)。戻りは (終了コード, ms)。
    @discardableResult
    func run(_ argv: [String]) -> (status: Int32, ms: Int) {
        guard setup(), let spawnFn = spawnFn, let waitFn = waitFn, !argv.isEmpty else { return (-1, 0) }
        lock.lock(); defer { lock.unlock() }
        let env = environment().map { "\($0.key)=\($0.value)" }
        log.log("$ \(argv.joined(separator: " "))   [footprint \(footprintMB()) MB]")
        let t0 = Date()
        let pid = withCStrings(argv) { argvp in
            withCStrings(env) { envp in
                spawnFn(argv[0], argvp, envp, 1, 2)
            }
        }
        if pid < 0 {
            log.log("spawn failed errno \(errno) (\(String(cString: strerror(errno))))")
            return (-1, 0)
        }
        var status: Int32 = -1
        let wr = waitFn(pid, &status)
        // ゲストの出力が読み取りスレッドを通ってから終了行を出す
        fflush(nil)
        usleep(50_000)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.log("pid \(pid) exit=\(status) wait=\(wr) \(ms) ms [footprint \(footprintMB()) MB]")
        return (status, ms)
    }

    // ------------------------------------------------------------ 待たない起動

    // 戻ってこないゲスト(iosc は wl_display_run で止まる)用。spawn して pid を返すだけで join しない。
    // lock は spawn の一瞬だけ取る。ここで持ったままにすると run() が二度と動かなくなる。
    @discardableResult
    func start(_ argv: [String], label: String) -> Int32 {
        guard setup(), let spawnFn = spawnFn, !argv.isEmpty else { return -1 }
        let env = environment().map { "\($0.key)=\($0.value)" }
        log.log("$ \(argv.joined(separator: " "))   [start \(label), footprint \(footprintMB()) MB]")
        lock.lock()
        let pid = withCStrings(argv) { argvp in
            withCStrings(env) { envp in
                spawnFn(argv[0], argvp, envp, 1, 2)
            }
        }
        lock.unlock()
        if pid < 0 {
            log.log("start \(label): spawn failed errno \(errno) (\(String(cString: strerror(errno))))")
            return -1
        }
        startedLock.lock()
        started[pid] = label
        startedLock.unlock()
        log.log("start \(label): pid \(pid) (wait しない)")
        return pid
    }

    // start() で起こした pid それぞれの生死。lcsys_alive は proc をリストから外さないので何度でも呼べる
    func status() -> String {
        startedLock.lock()
        let snapshot = started.sorted { $0.key < $1.key }
        startedLock.unlock()
        if snapshot.isEmpty { return "started: なし" }
        guard let aliveFn = aliveFn else { return "started: (lcsys_alive 無し)" }
        return snapshot.map { e -> String in
            var st: Int32 = -1
            switch aliveFn(e.key, &st) {
            case 1:  return "pid \(e.key) \(e.value): 実行中"
            case 0:  return "pid \(e.key) \(e.value): 終了 exit=\(st)"
            default: return "pid \(e.key) \(e.value): 不明(wait 済み?)"
            }
        }.joined(separator: " | ")
    }

    // ディレクトリの中身を 1 行で(ソケットができたかを見る)
    func listing(_ dir: String) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return "\(dir): 読めない" }
        if names.isEmpty { return "\(dir): 空" }
        let items = names.sorted().map { n -> String in
            let attrs = (try? fm.attributesOfItem(atPath: dir + "/" + n)) ?? [:]
            let type = attrs[.type] as? String
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            if type == FileAttributeType.typeSocket.rawValue { return "\(n) (socket)" }
            if type == FileAttributeType.typeDirectory.rawValue { return "\(n) (dir)" }
            return "\(n) (\(size) B)"
        }
        return "\(dir): " + items.joined(separator: ", ")
    }

    func logDirs() {
        for d in [runtimeDir, xiosDir] { log.log(listing(d)) }
    }

    // 「状態」ボタン
    func logStatus() {
        log.log("状態: \(status())  [footprint \(footprintMB()) MB]")
        logDirs()
        dumpShellLogs()
    }

    /// iosc-shell の部品は IOSC_SHELL_DEBUG=1 のとき $XDG_RUNTIME_DIR/<名前>.log に自前で書く
    /// (ioscoverview.c:46)。ドックから起きたものは XDG_RUNTIME_DIR が共有バスの置き場に
    /// 差し替わっている(sd_launch)ので、両方を見て末尾をこちらのログへ写す
    func dumpShellLogs() {
        for dir in [runtimeDir, tmp + "/iosc-shell-bus"] {
            for name in ["ioscoverview.log", "ioscbar.log", "ioscdock.log", "ioscbg.log"] {
                let path = dir + "/" + name
                guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                let tail = lines.suffix(40).joined(separator: "\n")
                log.log("--- \(path) (末尾 \(min(40, lines.count)) / \(lines.count) 行) ---\n\(tail)")
            }
        }
    }

    /// いま生きているものの名前。
    func aliveLabels() -> Set<String> {
        startedLock.lock()
        let pairs = started.map { ($0.key, $0.value) }
        startedLock.unlock()
        guard let aliveFn = aliveFn else { return Set(pairs.map { $0.1 }) }
        var out = Set<String>()
        for (pid, label) in pairs {
            var st: Int32 = -1
            if aliveFn(pid, &st) == 1 { out.insert(label) }
        }
        return out
    }

    // ------------------------------------------------------------ iosc

    // iosc(Wayland コンポジタ)の起動フラグ。出どころは全部 upstream の wayland/iosc_options.c。
    // ソケット類の既定値は /var/jb/tmp/... なので、全部こちらの tmp 配下に明示する。
    func ioscArgv() -> [String] {
        [Self.ioscPath,
         "-classic", "-logical", Self.logicalArg(), "-scale", "2", "-dpi", "96",
         "-s", "wayland-0",
         "-ddx-sock", xiosDir + "/ddx",
         "-json", xiosDir + "/j.json",
         "-input-sock", xiosDir + "/in",
         "-clipboard-sock", xiosDir + "/clip",
         "-wm-sock", xiosDir + "/wm"]
    }

    func ddxPath() -> String { xiosDir + "/ddx" }
    /// 指も文字も iosc の入力ソケットに直結する。iosc は自前の text-input-v3 で文字を
    /// 今選ばれている窓に入れる(iosc.c in_dispatch_text → text_input_commit_text)。
    /// `improxy=0 (local fallback)` はその「いつもの道」で、ios-inputd は KWin などを
    /// 入れ子にしたときだけの橋渡しなので、ここでは起こさない。
    func inputPath() -> String { xiosDir + "/in" }

    // start() で起こした iosc がまだ生きているか
    func ioscAlive() -> Bool {
        startedLock.lock()
        let pids = started.filter { $0.value == "iosc" }.keys.sorted()
        startedLock.unlock()
        guard let aliveFn = aliveFn else { return !pids.isEmpty }
        for p in pids {
            var st: Int32 = -1
            if aliveFn(p, &st) == 1 { return true }
        }
        return false
    }

    func startIosc() {
        guard setup() else { log.log("iosc: setup 失敗"); return }
        // 2 本目は wayland-0.lock を取れずに必ず失敗するが、そこに至るまでに
        // IOSurface 3 枚と ANGLE の初期化を済ませてしまう。手前で止める。
        if ioscAlive() {
            log.log("iosc: すでに起動済み(\(status()))")
            return
        }
        firstLaunchGuestSetup()
        log.log("=== iosc 起動 ===")
        log.log(Self.remeasureOnMain())   // 起動前に向きを確定(横向きなら論理 864 が等倍近くになる)
        for d in [runtimeDir, xiosDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        for (k, v) in environment() { setenv(k, v, 1) }
        let argv = ioscArgv()
        // AF_UNIX の sun_path は 104 バイト。実機の $TMPDIR は 89 文字(G0)なので先に測っておく
        for p in [runtimeDir + "/wayland-0"] + argv.filter({ $0.hasPrefix(xiosDir + "/") }) {
            let n = p.utf8.count
            if n > 103 { log.log("*** sun_path の上限 104 B 超え (\(n) B): \(p)") }
        }
        let pid = start(argv, label: "iosc")
        guard pid >= 0 else { return }
        Thread.sleep(forTimeInterval: 2.0)   // ゲストの出力がパイプの読み手を通るのも待つ
        fflush(nil)
        log.log("iosc 2 秒後: \(status())  [footprint \(footprintMB()) MB]")
        logDirs()
    }

    // 「画面」の前段: iosc が居なければ起こし、ddx ソケットが現れるまで最大 10 秒待つ。
    // startIosc() が 2 秒眠るので、**必ずバックグラウンドスレッドから**呼ぶこと。
    func ensureIoscReady() -> Bool {
        guard setup() else { log.log("画面: setup 失敗"); return false }
        if ioscAlive() {
            log.log("画面: iosc は起動済み(\(status()))")
        } else {
            startIosc()
        }
        let path = ddxPath()
        var waited = 0
        while waited <= 10_000 {
            if FileManager.default.fileExists(atPath: path) {
                log.log("画面: ddx ソケットあり(待ち \(waited) ms)")
                ensureClient()
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
            waited += 100
        }
        log.log("画面: ddx ソケットが 10 秒経っても現れない: \(path)")
        log.log("画面: \(status())")
        logDirs()
        return false
    }

    // ------------------------------------------------------------ クライアント

    /// Wayland クライアントを 1 本起こす。コンポジタは繋いでくる相手が居ないと描くものが無い。
    func startClient(_ path: String, label: String, args: [String] = [],
                     settle: TimeInterval = 1.5) {
        guard setup() else { log.log("\(label): setup 失敗"); return }
        // 同じものを 2 本起こしても窓が重なるだけで得が無い
        if aliveLabels().contains(label) {
            log.log("\(label): すでに動いているので起こさない(\(status()))")
            return
        }
        // ソケットの**ファイルがある**ことは iosc が生きている証拠にならない。
        // 前回の残骸でも在るように見えるので、動いているかを直接見る
        if !ioscAlive() {
            log.log("\(label): iosc が動いていないので先に起こす")
            guard ensureIoscReady() else { log.log("\(label): iosc を起こせなかった"); return }
        }
        log.log("=== \(label) 起動 ===")
        let pid = start([path] + args, label: label)
        guard pid >= 0 else { return }
        Thread.sleep(forTimeInterval: settle)
        fflush(nil)
        log.log("\(label) \(String(format: "%.1f", settle)) 秒後: \(status())  [footprint \(footprintMB()) MB]")
    }

    /// 画面に何かを描くクライアントではないもの。数に入れると壁紙が起きなくなる
    static let nonDrawing: Set<String> = ["iosc"]

    /// iosc 以外で生きているスレッド(= 画面に描く Wayland クライアント)の本数。
    func clientCount() -> Int {
        startedLock.lock()
        let pids = started.filter { !Self.nonDrawing.contains($0.value) }.keys.sorted()
        startedLock.unlock()
        guard let aliveFn = aliveFn else { return pids.count }
        var n = 0
        for p in pids {
            var st: Int32 = -1
            if aliveFn(p, &st) == 1 { n += 1 }
        }
        return n
    }

    /// 画面に出すものが 1 つも無ければ壁紙を起こす。
    func ensureClient() {
        let n = clientCount()
        if n > 0 {
            log.log("画面: クライアント \(n) 本が起動済み")
            return
        }
        log.log("画面: クライアントが 1 本も居ないので壁紙(ioscbg)を起こす")
        startBackground()
    }

    /// 壁紙(run-shell.sh の 2 番目)。
    func startBackground() { startClient("/var/jb/usr/local/bin/ioscbg", label: "ioscbg") }
    /// 上の帯(3 番目)。
    func startBar() { startClient("/var/jb/usr/local/bin/ioscbar", label: "ioscbar") }
    /// 下のドック(4 番目)。
    func startDock() { startClient("/var/jb/usr/local/bin/ioscdock", label: "ioscdock") }
    /// 端末。子シェルの stdio がプロセス全体の 0/1/2 になるので、まだ成立しない(review C6)。
    func startFoot() { startClient(Self.footPath, label: "foot") }
    /// xiOS 付属の最小クライアント。xdg_toplevel を 1 枚出してフレームを commit するだけ。
    func startTestClient() { startClient("/var/jb/usr/local/bin/iosc-client", label: "iosc-client") }
    /// 開いている窓の一覧(画面全体を覆う)。
    func startOverview() { startClient("/var/jb/usr/local/bin/ioscoverview", label: "ioscoverview") }
    /// Wayland 版の回る歯車。dbus も子プロセスも要らない。
    func startGears() { startClient("/var/jb/usr/bin/es2gears_wayland", label: "es2gears", settle: 1.5) }

    /// GTK4 のテキストエディタ。GApplication は連絡係(dbus)が要るので、xiOS と同じく
    /// dbus-run-session に包んで起こす(run-kgx.sh、shell-draw.h sd_launch の落ち先と同じ形)。
    /// dbus-run-session は fork で dbus-daemon を起こし、アプリを起こして waitpid する。
    func startEditor() {
        startClient("/var/jb/usr/bin/dbus-run-session", label: "gnome-text-editor",
                    args: ["--", "/var/jb/usr/bin/gnome-text-editor"], settle: 3.0)
    }

    /// xiOS のセッションを立ち上げる: run-shell.sh と同じ順(iosc → 壁紙 → 0.3 秒 → 帯 → ドック)。
    /// こちらが並べるのはここまでで、何を起動するか・どう見せるかは向こうのシェルの仕事。
    func startSession() {
        guard setup() else { log.log("セッション: setup 失敗"); return }
        log.log("=== セッション開始 ===")
        guard ensureIoscReady() else { log.log("セッション: iosc を起こせなかった"); return }
        startBackground()
        Thread.sleep(forTimeInterval: 0.3)   // 壁紙を先に map させる(最初のフレームをきれいに)
        startBar()
        if Runner.dockEnabled {
            startDock()
        } else {
            log.log("ドックは出さない(窓が下に潜るため)。一覧はコンソールの「一覧」から開ける")
        }
        log.log("=== セッション: \(status())  [footprint \(footprintMB()) MB] ===")
    }

    /// 試験用の「全部入り」。どれが出てどれが出ないかを 1 回で見るためのもの。
    func startEverything() {
        startSession()
        for (path, label) in [("/var/jb/usr/local/bin/iosc-client", "iosc-client"),
                              ("/var/jb/usr/bin/es2gears_wayland", "es2gears")] {
            startClient(path, label: label, settle: 0.8)
        }
        log.log("=== 全部起動 おわり: \(status())  [footprint \(footprintMB()) MB] ===")
        logDirs()
    }

    // G1 関門: ls / bash / cat / ls 再実行(静的状態の回帰)/ readdir の .lc 剥がし / pkg-config
    func runG1Tests() {
        log.log("=== G1 tests start ===")
        let seq: [[String]] = [
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            ["/var/jb/usr/bin/bash", "-c", "echo hello from bash; echo HOME=$HOME; cd /var/jb/usr/share && echo cwd ok"],
            ["/var/jb/usr/bin/cat", "/var/jb/usr/lib/pkgconfig/wayland-server.pc"],
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            ["/var/jb/usr/bin/ls", "/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"],
            ["/var/jb/usr/bin/pkg-config", "--list-all"],
        ]
        var results: [String] = []
        for (i, argv) in seq.enumerated() {
            log.log("--- test \(i + 1)/\(seq.count) ---")
            let r = run(argv)
            results.append("test\(i + 1) \(argv[0].split(separator: "/").last ?? "") exit=\(r.status) \(r.ms)ms")
        }
        log.log("=== G1 tests done: " + results.joined(separator: " | ") + " ===")
    }

    // 空白区切り + "..." / '...' だけの簡易トークナイザ
    static func tokenize(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var has = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else {
                cur.append(ch)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    private func withCStrings<R>(_ strings: [String],
                                 _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
