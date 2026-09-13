import Foundation
import Compression
import UIKit

// アプリ内アップデート。
//
// LiveContainer(3.7.2)は、ゲストを開くたびに LCAppInfo.patchExecAndSignIfNeed を呼ぶ
// (LCAppModel.runApp)。そこでは LCAppInfo.plist の LCPatchRevision が現在値(7)未満なら
// 実行ファイルを加工し直し、続けて署名もやり直す。だからこのアプリは
//   1. PC の配布サーバー(tools/serve-ipa.py)から新しい ipa を取り
//   2. Payload/XiOSDesktop.app を自分の .app(LiveContainer の Documents/Applications/
//      com.rutoi.xiosdesktop.app)と入れ替え
//   3. 元の LCAppInfo.plist(データ置き場の UUID 等)を引き継いで LCPatchRevision を 0 に戻し
//   4. 終了する
// だけでよく、次に LiveContainer から開くと「加工 → 署名 → 起動」が自動で走る。
//
// ゲストからの livecontainer://install?url= は 3.7.2 では「再起動して入れてください」の
// 警告を出すだけ(TweakLoader/UIKit+GuestHooks.m)なので、こちらの道にした。
@MainActor
final class Updater: ObservableObject {
    struct Manifest: Decodable {
        let app: String
        let version: String
        let build: Int
        let commit: String
        let size: Int64
        let ipa: String
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing, done, failed
    }

    @Published var phase: Phase = .idle
    @Published var message = ""
    @Published var progress: Double = 0          // 0..1(取得と展開)
    @Published var manifest: Manifest?
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "updateServer") }
    }
    private var manifestBase: URL?

    /// 既定は LAN。Tailscale の 100.x への平文 http は ATS(App Transport Security)が拒む
    /// (実機 2026-09-13: "requires the use of a secure connection")。ATS は本体 LiveContainer の
    /// Info.plist で決まるのでこちらでは緩められない。LAN は「ローカルネットワーク」の例外で通る。
    /// Tailscale を使うなら `tailscale cert` の正規証明書で https にする(未着手)
    static let defaultServers = ["http://192.168.10.113:8788", "http://100.111.178.20:8788"]

    let log: ConsoleLog

    init(log: ConsoleLog) {
        self.log = log
        baseURL = UserDefaults.standard.string(forKey: "updateServer") ?? Self.defaultServers[0]
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    // ------------------------------------------------------------ 確認

    func check() async {
        guard phase != .downloading && phase != .installing else { return }
        phase = .checking
        message = "更新を確認中"
        var servers = [baseURL]
        for s in Self.defaultServers where !servers.contains(s) { servers.append(s) }
        for s in servers {
            guard let url = URL(string: s + "/XiOSDesktop.json") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let m = try JSONDecoder().decode(Manifest.self, from: data)
                manifest = m
                manifestBase = URL(string: s)
                if m.build > Self.currentBuild {
                    phase = .available
                    message = "build \(m.build) (\(m.version) \(m.commit)) があります(いまは build \(Self.currentBuild))"
                } else {
                    phase = .upToDate
                    message = "最新です(build \(Self.currentBuild)、サーバーも build \(m.build))"
                }
                log.log("更新: \(s) -> \(message)")
                return
            } catch {
                log.log("更新: \(s) に届かない(\(error.localizedDescription))")
            }
        }
        phase = .failed
        message = "配布サーバーに届きません(PC で tools/build.ps1 か tools/serve-ipa.py が動いているか)"
    }

    // ------------------------------------------------------------ 取得と入れ替え

    func update() async {
        guard let m = manifest, let base = manifestBase, phase == .available else { return }
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("update", isDirectory: true)
        try? fm.removeItem(at: tmpDir)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let ipaURL = tmpDir.appendingPathComponent("XiOSDesktop.ipa")
        do {
            // 1. 取得
            phase = .downloading
            progress = 0
            message = "build \(m.build) を取得中"
            log.log("更新: \(base.absoluteString)/\(m.ipa) を取得(\(m.size / 1_048_576) MB)")
            let dl = Downloader()
            let got = try await dl.download(base.appendingPathComponent(m.ipa), to: ipaURL) { [weak self] done, total in
                Task { @MainActor in
                    guard let self = self else { return }
                    let t = total > 0 ? total : m.size
                    self.progress = t > 0 ? Double(done) / Double(t) : 0
                    self.message = "build \(m.build) を取得中 \(done / 1_048_576) / \(t / 1_048_576) MB"
                }
            }
            let size = (try? fm.attributesOfItem(atPath: got.path)[.size] as? Int64) ?? -1
            guard size == m.size else {
                throw NSError(domain: "Updater", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "大きさが違う(\(size) B、期待 \(m.size) B)"])
            }

            // 2. 展開。自分の .app の隣に置く(同じボリュームなので最後の入れ替えが rename で済む)
            phase = .installing
            progress = 0
            message = "展開中"
            let bundle = Bundle.main.bundleURL.standardizedFileURL
            let parent = bundle.deletingLastPathComponent()
            let staging = parent.appendingPathComponent("xiosdesktop-update.tmp", isDirectory: true)
            let old = parent.appendingPathComponent("xiosdesktop-old.tmp", isDirectory: true)
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: old)
            let zip = try ZipReader(path: got.path)
            let entries = try zip.entries()
            // Payload/<名前>.app/ の下だけを staging/ に出す
            var appPrefix: String?
            for e in entries where e.name.hasPrefix("Payload/") {
                let parts = e.name.dropFirst(8).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0].hasSuffix(".app") {
                    appPrefix = "Payload/" + String(parts[0]) + "/"
                    break
                }
            }
            guard let appPrefix = appPrefix else {
                throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "ipa の中に Payload/*.app が無い"])
            }
            let wanted = entries.filter { $0.name.hasPrefix(appPrefix) && $0.name.count > appPrefix.count }
            log.log("更新: \(appPrefix) の \(wanted.count) 件を展開")
            // 展開は主スレッドの外で(数百ファイル、数秒)。進捗だけ主スレッドへ返す
            let total = wanted.count
            try await Task.detached(priority: .userInitiated) { [weak self] in
                var n = 0
                for e in wanted {
                    let rel = String(e.name.dropFirst(appPrefix.count))
                    try zip.extract(e, to: staging.appendingPathComponent(rel).path)
                    n += 1
                    if n % 25 == 0 || n == total {
                        let done = n
                        await MainActor.run {
                            self?.progress = Double(done) / Double(total)
                            self?.message = "展開中 \(done) / \(total)"
                        }
                    }
                }
            }.value
            try? fm.removeItem(at: got)

            // 3. LiveContainer の台帳を引き継ぐ。LCPatchRevision を 0 にすると次の起動で
            //    加工と署名をやり直す(LCAppInfo.m patchExecAndSignIfNeed: needPatch → forceSign)
            let infoSrc = bundle.appendingPathComponent("LCAppInfo.plist")
            var info: [String: Any] = [:]
            if let d = try? Data(contentsOf: infoSrc),
               let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                info = p
            }
            info["LCPatchRevision"] = 0
            let out = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try out.write(to: staging.appendingPathComponent("LCAppInfo.plist"))
            try? fm.removeItem(at: staging.appendingPathComponent("zsign_cache.json"))
            // ここで開いていた自分の bundle を差し替える。動いている dylib は mmap 済みなので消えても平気
            try fm.moveItem(at: bundle, to: old)
            do {
                try fm.moveItem(at: staging, to: bundle)
            } catch {
                try? fm.moveItem(at: old, to: bundle)   // 戻す
                throw error
            }
            phase = .done
            progress = 1
            message = "build \(m.build) を入れました。終了して LiveContainer から開き直してください(開くときに署名し直します。1〜3 分)"
            log.log("更新: 入れ替え完了。旧版は \(old.lastPathComponent) に退避(次回起動で消す)")
            // 旧版は次回起動で消す(今消すと、動いているこのプロセスの経路が壊れる)
        } catch {
            phase = .failed
            message = "更新に失敗: \(error.localizedDescription)"
            log.log("更新: 失敗 \(error)")
        }
    }

    /// 起動時: 前回の更新で退避した旧版を消す
    static func cleanup() {
        let fm = FileManager.default
        let parent = Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent()
        for n in ["xiosdesktop-old.tmp", "xiosdesktop-update.tmp"] {
            let u = parent.appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) {
                DispatchQueue.global(qos: .utility).async { try? fm.removeItem(at: u) }
            }
        }
    }

    func quit() {
        log.sync()
        exit(0)
    }
}

// ------------------------------------------------------------ 取得(進捗つき)

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<URL, Error>?
    private var dest: URL?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var session: URLSession?

    func download(_ url: URL, to dest: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        self.dest = dest
        self.onProgress = progress
        return try await withCheckedThrowingContinuation { c in
            cont = c
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            s.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = dest else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)   // この関数を抜けると location は消える
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw NSError(domain: "Updater", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
            }
            cont?.resume(returning: dest)
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, let c = cont {
            cont = nil
            c.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }
}

// ------------------------------------------------------------ zip の読み出し
//
// ipa は普通の zip(deflate)。Foundation に zip は無いので、中央ディレクトリを読み、
// deflate は Compression の COMPRESSION_ZLIB(生の deflate)で戻す。zip64 は要らない(100MB 級)。

struct ZipEntry {
    let name: String
    let method: UInt16
    let csize: UInt64
    let usize: UInt64
    let localHeaderOffset: UInt64
    let externalAttrs: UInt32
    var isDirectory: Bool { name.hasSuffix("/") }
    var unixMode: UInt32 { externalAttrs >> 16 }
    var isSymlink: Bool { (unixMode & 0xF000) == 0xA000 }
}

final class ZipReader {
    private let fh: FileHandle
    private let size: UInt64

    init(path: String) throws {
        fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        size = try fh.seekToEnd()
    }
    deinit { try? fh.close() }

    private func read(_ off: UInt64, _ n: Int) throws -> Data {
        try fh.seek(toOffset: off)
        let d = fh.readData(ofLength: n)
        guard d.count == n else { throw Self.err("zip が途中で切れている(\(off) + \(n))") }
        return d
    }
    private static func err(_ s: String) -> NSError {
        NSError(domain: "Zip", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    func entries() throws -> [ZipEntry] {
        // EOCD(0x06054b50)は末尾 22 B + コメント(最大 64KB)の中
        let tailLen = Int(min(size, 22 + 65_536))
        let tail = try read(size - UInt64(tailLen), tailLen)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail.le32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Self.err("zip の終端(EOCD)が見つからない") }
        let count = Int(tail.le16(eocd + 10))
        let cdSize = UInt64(tail.le32(eocd + 12))
        let cdOff = UInt64(tail.le32(eocd + 16))
        guard count != 0xFFFF, cdOff != 0xFFFF_FFFF else { throw Self.err("zip64 は未対応") }
        let cd = try read(cdOff, Int(cdSize))
        var out: [ZipEntry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.le32(p) == 0x0201_4b50 else { throw Self.err("中央ディレクトリが壊れている") }
            let flags = cd.le16(p + 8)
            let method = cd.le16(p + 10)
            let csize = UInt64(cd.le32(p + 20))
            let usize = UInt64(cd.le32(p + 24))
            let nlen = Int(cd.le16(p + 28)), elen = Int(cd.le16(p + 30)), clen = Int(cd.le16(p + 32))
            let eattr = cd.le32(p + 38)
            let lho = UInt64(cd.le32(p + 42))
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            guard flags & 1 == 0 else { throw Self.err("暗号化された zip") }
            guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, lho != 0xFFFF_FFFF else { throw Self.err("zip64 は未対応") }
            out.append(ZipEntry(name: name, method: method, csize: csize, usize: usize,
                                localHeaderOffset: lho, externalAttrs: eattr))
            p += 46 + nlen + elen + clen
        }
        return out
    }

    /// 1 件を path に出す。ディレクトリ、シンボリックリンク、権限も再現する
    func extract(_ e: ZipEntry, to path: String) throws {
        let fm = FileManager.default
        if e.isDirectory {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return
        }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let lh = try read(e.localHeaderOffset, 30)
        guard lh.le32(0) == 0x0403_4b50 else { throw Self.err("\(e.name): ローカルヘッダが壊れている") }
        let dataOff = e.localHeaderOffset + 30 + UInt64(lh.le16(26)) + UInt64(lh.le16(28))
        if e.isSymlink {
            let target = String(decoding: try inflateToData(e, at: dataOff), as: UTF8.self)
            try? fm.removeItem(atPath: path)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
            return
        }
        try? fm.removeItem(atPath: path)
        guard fm.createFile(atPath: path, contents: nil) else { throw Self.err("\(path) が作れない") }
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? out.close() }
        try inflate(e, at: dataOff) { chunk in out.write(chunk) }
        let mode = e.unixMode & 0o777
        if mode != 0 {
            try? fm.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: path)
        }
    }

    private func inflateToData(_ e: ZipEntry, at off: UInt64) throws -> Data {
        var d = Data()
        try inflate(e, at: off) { d.append($0) }
        return d
    }

    private func inflate(_ e: ZipEntry, at off: UInt64, sink: (Data) -> Void) throws {
        let chunk = 1 << 20
        if e.method == 0 {
            var left = e.csize
            var pos = off
            while left > 0 {
                let n = Int(min(UInt64(chunk), left))
                sink(try read(pos, n))
                pos += UInt64(n)
                left -= UInt64(n)
            }
            return
        }
        guard e.method == 8 else { throw Self.err("\(e.name): 圧縮方式 \(e.method) は未対応") }
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Self.err("deflate の初期化に失敗")
        }
        defer { compression_stream_destroy(sp) }
        let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { inBuf.deallocate(); outBuf.deallocate() }
        var left = e.csize
        var pos = off
        sp.pointee.src_size = 0
        var status = COMPRESSION_STATUS_OK
        var produced: UInt64 = 0
        repeat {
            if sp.pointee.src_size == 0 && left > 0 {
                let n = Int(min(UInt64(chunk), left))
                let d = try read(pos, n)
                d.copyBytes(to: inBuf, count: n)
                sp.pointee.src_ptr = UnsafePointer(inBuf)
                sp.pointee.src_size = n
                pos += UInt64(n)
                left -= UInt64(n)
            }
            sp.pointee.dst_ptr = outBuf
            sp.pointee.dst_size = chunk
            let flags: Int32 = left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            status = compression_stream_process(sp, flags)
            let got = chunk - sp.pointee.dst_size
            if got > 0 {
                sink(Data(bytesNoCopy: UnsafeMutableRawPointer(outBuf), count: got, deallocator: .none))
                produced += UInt64(got)
            }
            if status == COMPRESSION_STATUS_ERROR { throw Self.err("\(e.name): deflate が壊れている") }
        } while status != COMPRESSION_STATUS_END
        guard produced == e.usize else { throw Self.err("\(e.name): 展開後の大きさが違う(\(produced) / \(e.usize))") }
    }
}

private extension Data {
    func le16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func le32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
}
