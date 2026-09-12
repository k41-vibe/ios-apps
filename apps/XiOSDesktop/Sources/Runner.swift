import Foundation
import Darwin
import UIKit

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

    static let pathDirs = "/var/jb/usr/bin:/var/jb/usr/local/bin:/var/jb/bin"
    static let ioscPath = "/var/jb/usr/local/bin/iosc"
    static let footPath = "/var/jb/usr/bin/foot"

    // ------------------------------------------------------------ 画面の大きさ
    // 上端は Dynamic Island と iOS のステータスバーが占めているので、そこを避けた
    // 範囲をコンポジタの「画面」として渡す。避けずに全面を渡すと、一番上に置かれる
    // ioscbar が島の下に潜って読めなくなる(実機 2026-09-12)。
    // ContentView が起動時に実機の値を入れる。入らなかったときは 14 Pro の実寸。
    static var logicalPoints = CGSize(width: 393, height: 852 - 59 - 34)
    static var topInsetPoints: CGFloat = 59

    /// 実際に使えるロケールを 1 回だけ探す。Darwin の libc に glibc の "C.UTF-8" は無く、
    /// "en_US.UTF-8" もこのサンドボックスからは引けなかった(実機 2026-09-12:
    /// `setlocale: LC_ALL: cannot change locale (en_US.UTF-8): No such file or directory`)。
    /// ホストとゲストは同じ libSystem を使うので、ここで通った名前はゲストでも通る。
    static let locale: String = {
        let saved = setlocale(LC_ALL, nil).map { String(cString: $0) }
        var chosen = "C"
        for cand in ["en_US.UTF-8", "UTF-8", "C.UTF-8"] where setlocale(LC_ALL, cand) != nil {
            chosen = cand
            break
        }
        if let s = saved { setlocale(LC_ALL, s) }
        return chosen
    }()

    /// UIKit から安全領域を読んで logicalPoints を決める。**メインスレッドから呼ぶこと**。
    static func measureScreen() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
                ?? scenes.flatMap({ $0.windows }).first else {
            return "画面の大きさが読めないので既定値 \(Int(logicalPoints.width))x\(Int(logicalPoints.height)) を使う"
        }
        let b = win.bounds, ins = win.safeAreaInsets
        topInsetPoints = ins.top
        // 下端はホームインジケータ(横棒)が乗る。ここに描くと指で触れないし、
        // ドックを置いても棒と重なって読めない(実機 2026-09-12)
        logicalPoints = CGSize(width: b.width, height: b.height - ins.top - ins.bottom)
        return "画面 \(Int(b.width))x\(Int(b.height)) pt、安全領域 上 \(Int(ins.top)) / 下 \(Int(ins.bottom)) pt "
            + "-> コンポジタには \(Int(logicalPoints.width))x\(Int(logicalPoints.height)) pt を渡す"
    }

    static func logicalArg() -> String {
        "\(Int(logicalPoints.width.rounded()))x\(Int(logicalPoints.height.rounded()))"
    }
    /// 経路変換の追跡。iosc を起こす前に立てること(環境変数はプロセス全体で 1 つ)
    static var traceEnabled = false

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

    // ゲストが getenv で見るのはプロセス環境なので setenv も行う(G1 ではプロセス全体で 1 つ)
    func environment() -> [String: String] {
        [
            "HOME": home,
            "TMPDIR": tmp,
            "PATH": Self.pathDirs,
            "XDG_RUNTIME_DIR": runtimeDir,
            "WAYLAND_DISPLAY": "wayland-0",   // iosc の -s と同じ名前(クライアントが見る側)
            "IOSC_DEBUG": "1",
            // 経路変換の 1 件ずつの記録。毎秒数千行出るので既定は切る(「詳細ログ」で入れる)
            "LCSYS_TRACE": Runner.traceEnabled ? "1" : "0",
            "IOSC_IGNORE_ACTIVE_SESSION": "1",   // /var/jb/tmp/xios-active-session は読めない
            "XIOS_RUNTIME_TMP": runtimeDir,      // クライアント側のログ置き場 (XSurface.c)
            "XDG_DATA_DIRS": "/var/jb/usr/share",
            "PKG_CONFIG_PATH": "/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig:/var/jb/usr/local/lib/pkgconfig",
            "TERM": "dumb",
            // Darwin の libc に glibc の "C.UTF-8" は無い(setlocale が失敗して "C" に落ち、
            // foot が「'C' is not a UTF-8 locale」と言う)。Darwin にある綴りを使う
            // LC_ALL は LANG より優先される。3 つとも「実際に引ける名前」で揃える
            "LANG": Runner.locale,
            "LC_CTYPE": Runner.locale,
            "LC_ALL": Runner.locale,
            // ioscbg のデスクトップ部品(Storage / Memory / Load / Session)の置き場。
            // 設定ファイルが無いと 1 つも描かれない(実機 2026-09-12「ストレージが出ない」)
            "IOSC_WIDGET_CONFIG": widgetConfigPath,
            // GTK / Qt のアプリは連絡係(dbus)が居ないと起動を諦めることがある。
            // 先に場所だけ教えておき、実体は「dbus」ボタンで起こす
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + dbusSocketPath,
            "SHELL": "/var/jb/usr/bin/bash",
            "USER": "mobile",
        ]
    }

    // ------------------------------------------------------------ デスクトップ部品

    var widgetConfigPath: String { home + "/iosc-widgets.conf" }

    /// ioscbg が読む部品の配置。書式は逆アセンブルで確かめた `名前 x y 有効` の 4 つ組
    /// (`fscanf(f, "%31s %d %d %d")` が 4 を返したときだけ採用し、3 番目は 0 以外なら表示)。
    /// 名前は storage / memory / load / uptime の 4 つで、表示名は Storage / Memory / Load / Session。
    /// 既定の置き場 /var/mobile/Library/Preferences/com.max.iosc-widgets.conf は
    /// このサンドボックスには無いので、環境変数で自前の場所を指す。
    func writeWidgetConfig() {
        let text = """
        storage 24 140 1
        memory 24 260 1
        load 24 380 1
        uptime 24 500 1
        """
        do {
            try text.write(toFile: widgetConfigPath, atomically: true, encoding: .utf8)
        } catch {
            log.log("デスクトップ部品の設定が書けない: \(error.localizedDescription)")
        }
    }

    // 1 回だけ: パイプを fd1/2 に被せ、libLCsys を読み、lcsys_init
    func setup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ready { return true }
        let bundle = Bundle.main.bundlePath
        for d in [home, runtimeDir, xiosDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        // 前回終了したときのソケットとロックが残っている。中身は死んでいるのに
        // ファイルとしては在るので、「wayland-0 があるから iosc は動いている」という
        // 判定が外れる(実機 2026-09-12: iosc 未起動のまま iosc-client が
        // wl_display_connect failed で落ちた)。起動時に掃除する
        for d in [runtimeDir, xiosDir] {
            let fm = FileManager.default
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n != "procd" {
                try? fm.removeItem(atPath: d + "/" + n)
            }
        }
        log.log("ロケール: \(Runner.locale)(この名前だけが setlocale を通った)")
        writeWidgetConfig()
        for (k, v) in environment() { setenv(k, v, 1) }

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
        log.log("stdout/stderr -> pipe (process-global in G1)")

        let lib = bundle + "/Frameworks/libLCsys.dylib"
        guard let h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL) else {
            log.log("dlopen(libLCsys) FAILED: \(String(cString: dlerror()))")
            return false
        }
        libHandle = h
        guard let pi = dlsym(h, "lcsys_init"), let ps = dlsym(h, "lcsys_spawn"), let pw = dlsym(h, "lcsys_wait") else {
            log.log("dlsym(lcsys_*) FAILED: \(String(cString: dlerror()))")
            return false
        }
        let initFn = unsafeBitCast(pi, to: InitFn.self)
        spawnFn = unsafeBitCast(ps, to: SpawnFn.self)
        waitFn = unsafeBitCast(pw, to: WaitFn.self)
        // 古い libLCsys でも G1 のテストは動かしたいので、これだけは無くても致命傷にしない
        if let pa = dlsym(h, "lcsys_alive") {
            aliveFn = unsafeBitCast(pa, to: AliveFn.self)
        } else {
            log.log("dlsym(lcsys_alive) not found (old libLCsys; status() は pid だけ出す)")
        }
        let rc = initFn(bundle, home, tmp, pipeWrite)
        log.log("lcsys_init -> \(rc); bundle=\(bundle)")
        // metal-event-broker(root の XPC)の肩代わり。lcsys_init が中で入れているので
        // ここでは「その libLCsys に入っているか」だけ見る。無ければ古い dylib で、
        // iosc は起動時に FATAL(iosc.c:6921)で落ちる
        if dlsym(h, "lcsys_install_xpc_shim") != nil {
            log.log("lcsys_install_xpc_shim: あり(lcsys_init が導入済み。詳細は xpcshim: の行)")
        } else {
            log.log("lcsys_install_xpc_shim: 無し ← 古い libLCsys.dylib。iosc は fence 無しで落ちる")
        }
        log.log("home=\(home) tmp=\(tmp)")
        let fw = (try? FileManager.default.contentsOfDirectory(atPath: bundle + "/Frameworks").count) ?? -1
        let jb = FileManager.default.fileExists(atPath: bundle + "/jb/usr/bin/ls.lc")
        log.log("Frameworks/ entries \(fw), jb/usr/bin/ls.lc stub present \(jb)")
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

    // ------------------------------------------------------------ 待たない起動(G2)

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
        guard let aliveFn = aliveFn else {
            return "started: " + snapshot.map { "pid \($0.key) \($0.value)" }.joined(separator: " | ")
                 + " (lcsys_alive 無し)"
        }
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
    }

    // iosc(Wayland コンポジタ)の起動フラグ。出どころは全部 upstream の wayland/iosc_options.c。
    // ソケット類の既定値は /var/jb/tmp/... = 読み取り専用の bundle 配下に落ちるので、全部明示する。
    //   -g       出力 IOSurface のピクセル寸法(iPhone 14 Pro の画面と同じ 1170x2532)
    //   -logical 論理解像度(= -g ÷ scale)
    //   -scale   HiDPI 倍率
    //   -s       wl_display_add_socket() に渡す名前($XDG_RUNTIME_DIR/<名前> にできる)
    //   -ddx-sock -json -input-sock -clipboard-sock -wm-sock
    //            既定は /var/jb/tmp/{iosc-ddx.sock, xios.json, iosc-input.sock,
    //            iosc-clipboard.sock, iosc-wm.sock}
    func ioscArgv() -> [String] {
        [Self.ioscPath,
         // 14 Pro は 393x852 pt @3x。上の安全領域(59 pt)を引いた範囲を渡し、
         // 表示側も同じ範囲に置くことで拡大縮小を 1:1 に保つ
         "-classic", "-logical", Self.logicalArg(), "-scale", "3", "-dpi", "96",
         "-s", "wayland-0",

         "-ddx-sock", xiosDir + "/ddx",
         "-json", xiosDir + "/j.json",
         "-input-sock", xiosDir + "/in",
         "-clipboard-sock", xiosDir + "/clip",
         "-wm-sock", xiosDir + "/wm"]
    }

    // iosc を起動して 2 秒後の様子を見るだけ(G2 の最初の一歩。画も入力もまだ無い)。
    // 2 秒眠るので**必ずバックグラウンドスレッドから**呼ぶこと。
    /// Wayland クライアントを 1 本起こす。コンポジタは繋いでくる相手が居ないと描くものが無いので、
    /// 画面に何かを出すには最低 1 本要る。ioscbg(背景)は fork も dbus も要らない一番軽い相手。
    func startClient(_ path: String, label: String, args: [String] = [],
                     settle: TimeInterval = 1.5) {
        guard setup() else { log.log("\(label): setup 失敗"); return }
        log.log("=== \(label) 起動 ===")
        // クライアントが見るのはこの 2 つ。コンポジタと同じ値でなければ繋がらない
        for k in ["XDG_RUNTIME_DIR", "WAYLAND_DISPLAY"] {
            if let v = environment()[k] { setenv(k, v, 1); log.log("\(label) env \(k)=\(v)") }
        }
        // 同じものを 2 本起こしても窓が重なるだけで得が無い(実機 2026-09-12:
        // iosc-client が 2 枚重なって「ぐちゃぐちゃ」に見えた)
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
        let pid = start([path] + args, label: label)
        guard pid >= 0 else { return }
        Thread.sleep(forTimeInterval: settle)
        fflush(nil)
        log.log("\(label) \(String(format: "%.1f", settle)) 秒後: \(status())  [footprint \(footprintMB()) MB]")
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

    /// iosc 以外で生きているスレッド(= Wayland クライアント)の本数。
    func clientCount() -> Int {
        startedLock.lock()
        let pids = started.filter { $0.value != "iosc" }.keys.sorted()
        startedLock.unlock()
        guard let aliveFn = aliveFn else { return pids.count }
        var n = 0
        for p in pids {
            var st: Int32 = -1
            if aliveFn(p, &st) == 1 { n += 1 }
        }
        return n
    }

    /// 画面に出すものが 1 つも無ければ背景を起こす。コンポジタは繋いでくる相手が
    /// 居ないと描くものが無いので、これを忘れると「黒いまま」にしか見えない
    /// (実機 2026-09-12: 画面 -> 背景 の順で押したため 1 フレームも出なかった)。
    func ensureClient() {
        let n = clientCount()
        if n > 0 {
            log.log("画面: クライアント \(n) 本が起動済み")
            return
        }
        log.log("画面: クライアントが 1 本も居ないので背景(ioscbg)を起こす")
        startBackground()
    }

    /// 背景を描くだけのクライアント。画面に何か出るかを確かめる最小の相手。
    func startBackground() { startClient("/var/jb/usr/local/bin/ioscbg", label: "ioscbg") }
    /// パネル/ドック。cairo と pango で描くので、文字が出れば描画経路は完全に通っている。
    func startBar() { startClient("/var/jb/usr/local/bin/ioscbar", label: "ioscbar") }
    /// 端末。子プロセスを作れないので今は起動に失敗する見込み(G3 で解決)。
    func startFoot() { startClient(Self.footPath, label: "foot") }
    /// xiOS 付属の最小クライアント。xdg_toplevel を 1 枚出してフレームを commit するだけで、
    /// 子プロセスも dbus も要らない。「普通のアプリの窓」が出るかを確かめる相手。
    func startTestClient() { startClient("/var/jb/usr/local/bin/iosc-client", label: "iosc-client") }
    /// ドック(下の帯)。バーと同じ iosc-shell の別の顔。
    func startDock() { startClient("/var/jb/usr/local/bin/ioscdock", label: "ioscdock") }
    // ------------------------------------------------------------ dbus とアプリ

    /// 短くしておく。AF_UNIX の sun_path は 104 バイトしかない
    var dbusSocketPath: String { tmp + "/d" }

    /// アプリ同士の連絡係。`--nofork` があるので分身を作らずそのまま動く。
    /// つまり iOS が禁じている fork を一度も踏まない。
    func startDbus() {
        startClient("/var/jb/usr/bin/dbus-daemon", label: "dbus-daemon",
                    args: ["--session", "--nofork", "--address=unix:path=" + dbusSocketPath],
                    settle: 1.2)
    }

    /// GTK4 のテキストエディタ。**打った文字がその場に出る**はずの窓。
    func startEditor() {
        if !aliveLabels().contains("dbus-daemon") { startDbus() }
        startClient("/var/jb/usr/bin/gnome-text-editor", label: "gnome-text-editor", settle: 2.5)
    }

    /// Wayland 版の回る歯車。dbus も子プロセスも要らないので、
    /// 「動く絵が届くか」だけを見るのに一番向いている。
    func startGears() {
        startClient("/var/jb/usr/bin/es2gears_wayland", label: "es2gears", settle: 1.5)
    }

    /// 開いている窓の一覧。
    func startOverview() { startClient("/var/jb/usr/local/bin/ioscoverview", label: "ioscoverview") }

    /// 試験用の「全部入り」。iosc を起こし、繋がる相手を端から全部起こす。
    /// どれが出てどれが出ないかを 1 回で見るためのもので、普段使いの順番ではない。
    /// 端末(foot)は擬似端末が開けないので必ず失敗する。それも含めて見たいので入れてある。
    func startEverything() {
        guard setup() else { log.log("全部: setup 失敗"); return }
        log.log("=== 全部起動 ===")
        guard ensureIoscReady() else { log.log("全部: iosc を起こせなかった"); return }
        let all: [(String, String)] = [
            ("/var/jb/usr/local/bin/ioscbar", "ioscbar"),
            ("/var/jb/usr/local/bin/ioscdock", "ioscdock"),
            ("/var/jb/usr/local/bin/iosc-client", "iosc-client"),
            ("/var/jb/usr/bin/es2gears_wayland", "es2gears"),
            (Self.footPath, "foot"),
            // 一覧(ioscoverview)は画面全体を覆う切り替え画面で、出すと壁紙もバーも
            // 隠れる。単体のボタンから出す方が分かるのでここには入れない
        ]
        for (path, label) in all {
            startClient(path, label: label, settle: 0.8)
        }
        log.log("=== 全部起動 おわり: \(status())  [footprint \(footprintMB()) MB] ===")
        logDirs()
    }

    func startIosc() {
        guard setup() else { log.log("iosc: setup 失敗"); return }
        // 2 本目は wayland-0.lock を取れずに必ず失敗するが、そこに至るまでに
        // IOSurface 3 枚と ANGLE の初期化を済ませてしまうので約 40MB を捨てることになる
        // (実機 2026-09-12: pid 1007 が exit=1、footprint 82 -> 121MB)。手前で止める。
        if ioscAlive() {
            log.log("iosc: すでに起動済み(\(status()))。2 本目は lock を取れないので起こさない")
            return
        }
        log.log("=== iosc 起動 ===")
        for d in [runtimeDir, xiosDir] {
            do { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            catch { log.log("iosc: mkdir \(d) 失敗: \(error.localizedDescription)") }
        }
        // 環境変数は G1 ではプロセス全体で 1 つ(environment() が持っている値をそのまま入れ直す)
        let env = environment()
        for k in ["XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "IOSC_DEBUG", "IOSC_IGNORE_ACTIVE_SESSION", "XIOS_RUNTIME_TMP"] {
            guard let v = env[k] else { continue }
            setenv(k, v, 1)
            log.log("iosc env \(k)=\(v)")
        }
        let argv = ioscArgv()
        // AF_UNIX の sun_path は 104 バイト。実機の $TMPDIR は 89 文字(G0)なので先に測っておく
        for p in [runtimeDir + "/wayland-0"] + argv.filter({ $0.hasPrefix(xiosDir + "/") }) {
            let n = p.utf8.count
            log.log("path \(n) B\(n > 103 ? "  *** sun_path の上限 104 B 超え ***" : "") \(p)")
        }
        let pid = start(argv, label: "iosc")
        guard pid >= 0 else { return }
        Thread.sleep(forTimeInterval: 2.0)   // ゲストの出力がパイプの読み手を通るのも待つ
        fflush(nil)
        log.log("iosc 2 秒後: \(status())  [footprint \(footprintMB()) MB]")
        logDirs()
    }

    // ------------------------------------------------------------ 画面(ddx)

    // クライアント(ScreenView)が繋ぎに行く先。ioscArgv() の -ddx-sock と同じ文字列。
    func ddxPath() -> String { xiosDir + "/ddx" }

    // 入力ソケット。ioscArgv() の -input-sock と同じ文字列
    func inputPath() -> String { xiosDir + "/in" }

    // start() で起こした iosc がまだ生きているか
    func ioscAlive() -> Bool {
        startedLock.lock()
        let pids = started.filter { $0.value == "iosc" }.keys.sorted()
        startedLock.unlock()
        guard let aliveFn = aliveFn else { return !pids.isEmpty }   // 古い libLCsys: pid の有無で代用
        for p in pids {
            var st: Int32 = -1
            if aliveFn(p, &st) == 1 { return true }
        }
        return false
    }

    // 「画面」ボタンの前段: iosc が居なければ起こし、ddx ソケットが現れるまで最大 10 秒待つ。
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
                log.log("画面: ddx ソケットあり \(path)(待ち \(waited) ms)")
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

    // G1 関門: ls / bash / cat / ls 再実行(静的状態の回帰)/ readdir の .lc 剥がし / pkg-config
    func runG1Tests() {
        log.log("=== G1 tests start ===")
        let seq: [[String]] = [
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            ["/var/jb/usr/bin/bash", "-c", "echo hello from bash; echo HOME=$HOME; cd /var/jb/usr/share && echo cwd ok"],
            ["/var/jb/usr/bin/cat", "/var/jb/usr/lib/pkgconfig/wayland-server.pc"],
            // 4: 1 と同じ。gnulib getopt の静的状態が残っていれば "invalid option" で落ちる
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            // 5: readdir が ".lc" を剥がしているか。名前は ".so" で終わること(".so.lc" は失格)
            ["/var/jb/usr/bin/ls", "/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"],
            // 6: libpcre2 が読めるか(_SLJIT_UPDATE_WX_FLAGS を libLCsys が no-op で提供)
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
