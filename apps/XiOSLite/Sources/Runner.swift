import Foundation
import Darwin

// コンソール。画面用の文字列と、落ちても残るよう Documents/xioslite.log に fsync 付きで書く(LCProbe と同じ作り)。
final class ConsoleLog: ObservableObject {
    @Published var text = ""
    let fileURL: URL
    private var fh: FileHandle?
    private let lock = NSLock()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("xioslite.log")
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
        DispatchQueue.main.async { self.text += s }
        if let d = s.data(using: .utf8) {
            lock.lock()
            fh?.write(d)
            try? fh?.synchronize()
            lock.unlock()
        }
    }

    func previous() -> String { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }

    func clearFile() {
        try? fh?.truncate(atOffset: 0)
        DispatchQueue.main.async { self.text = "" }
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
            "IOSC_IGNORE_ACTIVE_SESSION": "1",   // /var/jb/tmp/xios-active-session は読めない
            "XIOS_RUNTIME_TMP": runtimeDir,      // クライアント側のログ置き場 (XSurface.c)
            "XDG_DATA_DIRS": "/var/jb/usr/share",
            "PKG_CONFIG_PATH": "/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig:/var/jb/usr/local/lib/pkgconfig",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "LC_ALL": "C",
            "SHELL": "/var/jb/usr/bin/bash",
            "USER": "mobile",
        ]
    }

    // 1 回だけ: パイプを fd1/2 に被せ、libLCsys を読み、lcsys_init
    func setup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ready { return true }
        let bundle = Bundle.main.bundlePath
        for d in [home, runtimeDir, xiosDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
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
         // 14 Pro は 393x852 pt @3x = 1179x2556 px。等倍にして表示の変換を 1:1 にする
         "-classic", "-logical", "393x852", "-scale", "3", "-dpi", "96",
         "-s", "wayland-0",

         "-ddx-sock", xiosDir + "/ddx",
         "-json", xiosDir + "/j.json",
         "-input-sock", xiosDir + "/in",
         "-clipboard-sock", xiosDir + "/clip",
         "-wm-sock", xiosDir + "/wm"]
    }

    // iosc を起動して 2 秒後の様子を見るだけ(G2 の最初の一歩。画も入力もまだ無い)。
    // 2 秒眠るので**必ずバックグラウンドスレッドから**呼ぶこと。
    func startIosc() {
        guard setup() else { log.log("iosc: setup 失敗"); return }
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
