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

    let log: ConsoleLog
    private var spawnFn: SpawnFn?
    private var waitFn: WaitFn?
    private var ready = false
    private var pipeWrite: Int32 = -1
    private let lock = NSLock()   // 同時に 1 コマンドずつ(stdout/env がプロセス共有なので)

    static let pathDirs = "/var/jb/usr/bin:/var/jb/usr/local/bin:/var/jb/bin"

    let home: String
    let tmp: String
    let runtimeDir: String

    init(log: ConsoleLog) {
        self.log = log
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        home = docs + "/home"
        var t = NSTemporaryDirectory()
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        tmp = t
        runtimeDir = t + "/xdg-runtime"
    }

    // ゲストが getenv で見るのはプロセス環境なので setenv も行う(G1 ではプロセス全体で 1 つ)
    func environment() -> [String: String] {
        [
            "HOME": home,
            "TMPDIR": tmp,
            "PATH": Self.pathDirs,
            "XDG_RUNTIME_DIR": runtimeDir,
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
        for d in [home, runtimeDir] {
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

    // G1 関門: ls, bash -c, pkg-config, そして ls をもう一度(静的状態の回帰テスト)
    func runG1Tests() {
        log.log("=== G1 tests start ===")
        // pkg-config は libpcre の版ずれで読めない(G1 の関門から外し、参考として最後に回す)
        let seq: [[String]] = [
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            ["/var/jb/usr/bin/bash", "-c", "echo hello from bash; echo HOME=$HOME; cd /var/jb/usr/share && echo cwd ok"],
            ["/var/jb/usr/bin/cat", "/var/jb/usr/lib/pkgconfig/wayland-server.pc"],
            ["/var/jb/usr/bin/ls", "-la", "/var/jb/usr/bin"],
            ["/var/jb/usr/bin/ls", "-l", "/var/jb/usr/share/X11/xkb"],
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
