import Foundation
import Darwin
import os

// 計測ログ。画面表示用の文字列と、jetsam で殺されても残るようファイルへ fsync 付きで書く。
final class ProbeLog: ObservableObject {
    @Published var text = ""
    let fileURL: URL
    private var fh: FileHandle?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("lcprobe.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fh = try? FileHandle(forWritingTo: fileURL)
        _ = try? fh?.seekToEnd()
    }

    private let lock = NSLock()

    func log(_ s: String) {
        let line = "[\(Self.stamp())] \(s)"
        DispatchQueue.main.async { self.text += line + "\n" }
        if let d = (line + "\n").data(using: .utf8) {
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

// phys_footprint(iOS が jetsam 判定に使う値)を MB で返す
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

// os_proc_available_memory: jetsam までに使える残量(iOS 13+)。モジュール依存を避けてシンボル直結。
@_silgen_name("os_proc_available_memory") private func c_os_proc_available_memory() -> Int
func availableMB() -> Int { c_os_proc_available_memory() / 1_048_576 }

enum Probes {
    static var frameworksDir: String { Bundle.main.bundlePath + "/Frameworks" }

    static func sysInfo(_ L: ProbeLog) {
        L.log("=== sysinfo ===")
        let pi = ProcessInfo.processInfo
        L.log("iOS \(pi.operatingSystemVersionString), cpus \(pi.activeProcessorCount)")
        L.log("page size \(getpagesize())")
        L.log("physical memory \(pi.physicalMemory / 1_048_576) MB")
        L.log("os_proc_available_memory \(availableMB()) MB, footprint \(footprintMB()) MB")
        var rl = rlimit()
        getrlimit(RLIMIT_NOFILE, &rl)
        L.log("RLIMIT_NOFILE \(rl.rlim_cur)/\(rl.rlim_max)")
        L.log("bundle \(Bundle.main.bundlePath)")
        L.log("home \(NSHomeDirectory())")
        let tmp = NSTemporaryDirectory()
        L.log("tmp \(tmp) (len \(tmp.utf8.count))")
        let n = (try? FileManager.default.contentsOfDirectory(atPath: frameworksDir).count) ?? -1
        L.log("Frameworks/ entries \(n)")
        L.log("pid \(getpid()) uid \(getuid())")
    }

    // Frameworks/libprobe*.dylib を段階的に dlopen し、時間と footprint を記録
    static func dlopenTiers(_ L: ProbeLog) {
        L.log("=== dlopen tiers ===")
        // 段階は Frameworks/ の実本数に合わせる(postbuild.sh の LCPROBE_DYLIBS)
        let total = (try? FileManager.default.contentsOfDirectory(atPath: frameworksDir))?
            .filter { $0.hasPrefix("libprobe") }.count ?? 0
        let tiers = [total / 4, total / 2, total].filter { $0 > 0 }
        var opened = 0
        var failed = 0
        let t0 = Date()
        var handles: [UnsafeMutableRawPointer] = []
        for tier in tiers {
            let ts = Date()
            while opened < tier {
                opened += 1
                let path = "\(frameworksDir)/libprobe\(opened).dylib"
                if let h = dlopen(path, RTLD_NOW) {
                    handles.append(h)
                } else {
                    failed += 1
                    if failed <= 3 {
                        L.log("dlopen fail #\(opened): \(String(cString: dlerror()))")
                    }
                }
            }
            let tierMs = Int(Date().timeIntervalSince(ts) * 1000)
            let cumMs = Int(Date().timeIntervalSince(t0) * 1000)
            L.log("tier \(tier): +\(tierMs) ms (cum \(cumMs) ms), failed \(failed), footprint \(footprintMB()) MB")
        }
        if let h = handles.last, let sym = dlsym(h, "probe_\(opened - failed)") {
            typealias Fn = @convention(c) () -> Int32
            let fn = unsafeBitCast(sym, to: Fn.self)
            L.log("dlsym call ok: probe_\(opened - failed)() = \(fn())")
        } else {
            L.log("dlsym failed on last handle")
        }
    }

    // 実行時に Documents へコピーした dylib を dlopen できるか。
    // 【注意】これは JIT の有無の判定には使えない。コピー元は LiveContainer が署名済みで、
    // 署名ごと複製されるため JIT-less でも成功する(実機 2026-09-12 で確認)。
    // 意味があるのは「署名済みバイナリなら実行時にコピーして読み込める」という事実のほうで、
    // procd の私的コピー方式(procd.c)はこれに乗っている。
    static func runtimeDlopen(_ L: ProbeLog) {
        L.log("=== runtime dlopen ===")
        let src = URL(fileURLWithPath: "\(frameworksDir)/libprobe1.dylib")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dst = docs.appendingPathComponent("rt_probe.dylib")
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: src, to: dst) } catch {
            L.log("copy failed: \(error)"); return
        }
        if dlopen(dst.path, RTLD_NOW) != nil {
            L.log("runtime dlopen OK (署名済み dylib のコピーは JIT-less でも読める。JIT の証拠ではない)")
        } else {
            L.log("runtime dlopen FAILED: \(String(cString: dlerror()))")
        }
    }

    // 書いたメモリを実行できるか。mprotect が拒否されるだけで落ちない設計。
    static func jitProbe(_ L: ProbeLog) {
        L.log("=== jit / W^X ===")
        let size = Int(getpagesize())
        let rwx = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0)
        L.log("mmap RWX: \(rwx == MAP_FAILED ? "failed errno \(errno)" : "ok")")
        if rwx != MAP_FAILED { munmap(rwx, size) }
        let rwxJit = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0)
        L.log("mmap RWX|MAP_JIT: \(rwxJit == MAP_FAILED ? "failed errno \(errno)" : "ok")")
        if rwxJit != MAP_FAILED { munmap(rwxJit, size) }

        let rw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard rw != MAP_FAILED, let p = rw else { L.log("mmap RW failed errno \(errno)"); return }
        let code: [UInt32] = [0x5280_0540, 0xD65F_03C0] // mov w0,#42 ; ret
        code.withUnsafeBytes { memcpy(p, $0.baseAddress, 8) }
        let r = mprotect(p, size, PROT_READ | PROT_EXEC)
        if r != 0 {
            L.log("mprotect RW->RX failed errno \(errno) (no JIT: expected in JIT-less mode)")
            munmap(p, size); return
        }
        if let inv = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sys_icache_invalidate") {
            typealias Inv = @convention(c) (UnsafeMutableRawPointer, Int) -> Void
            unsafeBitCast(inv, to: Inv.self)(p, 8)
        }
        typealias Fn = @convention(c) () -> Int32
        let fn = unsafeBitCast(p, to: Fn.self)
        L.log("mprotect RX ok; executing written code -> \(fn()) (expect 42)")
        munmap(p, size)
    }

    // JIT が有る場合と無い場合で、同じ計算にどれだけ時間差が出るか。
    //
    // jitProbe は「実行可能にできるか」しか答えない。エミュレーターが JIT から得るものは、
    // 命令を機械語に変換して直接実行できることなので、そこを直接測る。
    //
    //   生成した機械語 : add w0,w0,#1 を K 個並べて呼ぶ。JIT が無いと実行できない
    //   解釈実行       : 同じ K 個の命令を配列から 1 つずつ読んで分岐で処理する。JIT 不要
    //
    // 出る比は上限であって、エミュレーターの実際の速度差ではない。ここで並べているのは
    // メモリ参照もフラグ更新も無い最も単純な命令なので、解釈実行側の不利が最大に出る。
    static func jitBenchmark(_ L: ProbeLog) {
        L.log("=== jit benchmark ===")
        let instructions = 1024          // 1 回の呼び出しで実行する命令数
        let iterations = 20_000          // 呼び出し回数
        let total = Double(instructions * iterations)

        // --- 解釈実行。JIT の有無に関わらず動く ---
        // 配列から読ませることで、命令列を定数に畳み込まれないようにする
        let program = [UInt8](repeating: 0, count: instructions)
        var acc: Int32 = 0
        let interpStart = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        for _ in 0..<iterations {
            var i = 0
            while i < instructions {
                switch program[i] {
                case 0: acc &+= 1
                default: break
                }
                i += 1
            }
        }
        let interpNs = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC) - interpStart)
        L.log(String(format: "解釈実行: %.2f ns/命令 (合計 %.0f ms, acc=%d)",
                     interpNs / total, interpNs / 1_000_000, acc))

        // --- 生成した機械語 ---
        var code = [UInt32](repeating: 0x1100_0400, count: instructions) // add w0, w0, #1
        code.append(0xD65F_03C0)                                          // ret
        let codeBytes = code.count * 4
        let pageSize = Int(getpagesize())
        let size = (codeBytes + pageSize - 1) / pageSize * pageSize

        // 実行可能なメモリの取り方は 2 通りある。デバッガが付いていれば最初から RWX で取れる。
        // 取れなければ RW で取って書き込み、あとから実行可能に変える。
        var page = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0)
        var viaMprotect = false
        if page == MAP_FAILED {
            page = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            viaMprotect = true
        }
        guard page != MAP_FAILED, let p = page else {
            L.log("実行可能メモリを確保できない errno \(errno)。JIT 無しと判定")
            return
        }
        code.withUnsafeBytes { memcpy(p, $0.baseAddress, codeBytes) }

        if viaMprotect, mprotect(p, size, PROT_READ | PROT_EXEC) != 0 {
            L.log("mprotect RW->RX failed errno \(errno)。JIT は効いていない")
            L.log("比較できるのは解釈実行だけ。エミュレーターは同じ条件で動くことになる")
            munmap(p, size)
            return
        }
        if let inv = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sys_icache_invalidate") {
            typealias Inv = @convention(c) (UnsafeMutableRawPointer, Int) -> Void
            unsafeBitCast(inv, to: Inv.self)(p, codeBytes)
        }

        typealias Fn = @convention(c) (Int32) -> Int32
        let fn = unsafeBitCast(p, to: Fn.self)

        // 書いたとおりに動いているかを先に確かめる。ここが合わないと時間に意味がない
        let check = fn(0)
        guard check == Int32(instructions) else {
            L.log("生成した機械語の戻り値が \(check)、期待は \(instructions)。測定を中止")
            munmap(p, size)
            return
        }

        var jitAcc: Int32 = 0
        let jitStart = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        for _ in 0..<iterations { jitAcc = fn(jitAcc) }
        let jitNs = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC) - jitStart)
        munmap(p, size)

        L.log(String(format: "生成した機械語: %.2f ns/命令 (合計 %.0f ms, acc=%d)",
                     jitNs / total, jitNs / 1_000_000, jitAcc))
        L.log(String(format: "比: %.1f 倍 (%@ で実行可能にした)",
                     interpNs / jitNs, viaMprotect ? "mprotect" : "mmap RWX"))
        L.log("JIT は効いている")
    }

    // socketpair の往復時間と、パス付き Unix ソケットの bind/connect
    static func sockets(_ L: ProbeLog) {
        L.log("=== sockets ===")
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            L.log("socketpair failed errno \(errno)"); return
        }
        let n = 5000
        let srvFd = fds[1], cliFd = fds[0]
        let server = Thread {
            var buf = [UInt8](repeating: 0, count: 32)
            for _ in 0..<n {
                _ = read(srvFd, &buf, 32)
                _ = write(srvFd, buf, 32)
            }
        }
        server.start()
        var buf = [UInt8](repeating: 7, count: 32)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n {
            _ = write(cliFd, buf, 32)
            _ = read(cliFd, &buf, 32)
        }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 / Double(n)
        L.log("socketpair round trip \(String(format: "%.1f", us)) us (n=\(n))")
        close(cliFd); close(srvFd)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        for dir in [NSTemporaryDirectory(), docs] {
            let path = (dir as NSString).appendingPathComponent("lcprobe.sock")
            L.log("bind \(path): \(tryPathSocket(path))")
        }
    }

    private static func tryPathSocket(_ path: String) -> String {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { return "path too long (\(path.utf8.count) > \(maxLen))" }
        unlink(path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { _ = strncpy($0, path, maxLen) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(s); unlink(path) }
        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) }
        }
        if b != 0 { return "bind failed errno \(errno)" }
        if listen(s, 4) != 0 { return "listen failed errno \(errno)" }
        let c = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(c) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, len) }
        }
        if r != 0 { return "connect failed errno \(errno)" }
        let a = accept(s, nil, nil)
        if a < 0 { return "accept failed errno \(errno)" }
        var one: UInt8 = 1
        _ = write(c, &one, 1)
        var got: UInt8 = 0
        _ = read(a, &got, 1)
        close(a)
        return got == 1 ? "ok (bind/listen/connect/accept/io)" : "io mismatch"
    }

    // スレッドを作れるだけ作る(各 64KB スタック、3 秒寝て終了)
    static func threads(_ L: ProbeLog) {
        L.log("=== threads ===")
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_setstacksize(&attr, 65536)
        var made = 0
        var lastErr: Int32 = 0
        for _ in 0..<4000 {
            var t: pthread_t?
            let r = pthread_create(&t, &attr, { _ in sleep(3); return nil }, nil)
            if r != 0 { lastErr = r; break }
            if let t = t { pthread_detach(t) }
            made += 1
        }
        L.log("threads created \(made) (stop errno \(lastErr)), footprint \(footprintMB()) MB")
        sleep(4)
    }

    // 32MB ずつ確保して触る。jetsam で殺されるまで続く。最後の行がファイルに残る。
    static func memoryUntilKill(_ L: ProbeLog) {
        L.log("=== memory until kill ===")
        let chunk = 32 * 1_048_576
        var total = 0
        var chunks: [UnsafeMutableRawPointer] = []
        while true {
            guard let p = malloc(chunk) else {
                L.log("malloc returned nil at \(total / 1_048_576) MB"); break
            }
            memset(p, 0x5a, chunk)
            chunks.append(p)
            total += chunk
            L.log("alloc \(total / 1_048_576) MB, footprint \(footprintMB()) MB, avail \(availableMB()) MB")
        }
        for p in chunks { free(p) }
    }
}
