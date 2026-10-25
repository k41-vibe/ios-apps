import SwiftUI
import AVFoundation
import MediaPlayer
import WatchKit

// resolver の候補。届いた方を自動で使う(時計で打ち込まないため)
let CANDIDATES = ["http://192.168.10.103:8080", "http://100.111.178.20:8080"]

// 白ベース + パールオレンジのワンポイント
extension Color {
    init(_ hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
    static let bg = Color(0xFFFFFF)
    static let surface = Color(0xF4EEE6)
    static let ink = Color(0x1C1B19)
    static let sub = Color(0x8A847B)
    static let amber = Color(0xE0843C)
    static let amberDeep = Color(0xC9621F)
    static let field = Color(0x2E2A26)   // 入力欄の帯。watchOS は入力欄の文字を白で描くため濃くする
}

struct LibItem: Codable, Identifiable, Equatable { let id: String; let title: String }
struct Track: Codable, Identifiable, Equatable {
    let id: String; let title: String; let artist: String; let src: String; var cover: String?
}
struct Album: Codable { let title: String?; let cover: String?; let tracks: [Track] }
struct CustomAlbum: Codable, Identifiable { var id: String; var name: String; var tracks: [Track] }
struct Ping: Decodable { let ok: Bool; let yt: String? }

func haptic(_ type: WKHapticType = .click) { WKInterfaceDevice.current().play(type) }

/// 押した瞬間に縮んで薄くなる。触覚と合わせて「押せた」と分かるようにする
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 起動をまたいで同じ値になるハッシュ(Swift の hashValue は起動ごとに変わる)
func stableKey(_ s: String) -> String {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return String(h, radix: 16)
}

enum Disk {
    static func dir(_ name: String, caches: Bool = false) -> URL {
        let base = FileManager.default.urls(for: caches ? .cachesDirectory : .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let d = base.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
    static func save<T: Encodable>(_ value: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) }
    }
}

/// ジャケットを時計内に保存し、オフラインでも表示する
enum ArtCache {
    static let dir = Disk.dir("art", caches: true)
    static func image(_ s: String?) async -> UIImage? {
        guard let s, let u = URL(string: s) else { return nil }
        let f = dir.appendingPathComponent(stableKey(s))
        if let d = try? Data(contentsOf: f), let i = UIImage(data: d) { return i }
        guard let (d, _) = try? await URLSession.shared.data(from: u), let i = UIImage(data: d) else { return nil }
        try? d.write(to: f)
        return i
    }
}

/// 再生位置は Store と分ける。0.5秒ごとの更新で一覧の全行が描き直され、
/// 再生中にボタンが反応しなくなっていたため、再生画面だけがこれを見る
@MainActor final class Clock: ObservableObject { @Published var progress = 0.0 }

@MainActor
final class Store: ObservableObject {
    @Published var base: String?
    @Published var connecting = false
    @Published var ytState: String?
    @Published var lib: [LibItem] = []
    @Published var status = ""
    @Published var notice: String?
    @Published var current: Track?
    @Published var isPlaying = false
    @Published var downloadingID: String?
    @Published var bulk: String?
    @Published private(set) var savedIDs: Set<String> = []
    @Published private(set) var downloaded: [Track] = []
    @Published var customs: [CustomAlbum] = []
    @Published var volume = 0.7
    let clock = Clock()

    private var queue: [Track] = []
    private var index = 0
    private var queueCover: String?
    private var player: AVPlayer?
    private var observer: Any?
    private var endToken: NSObjectProtocol?
    private var inFlight: Set<String> = []

    private let audioDir = Disk.dir("audio")
    private let metaDir = Disk.dir("meta")
    private var customFile: URL { audioDir.appendingPathComponent("custom.json") }  // 旧版と同じ場所
    private var downloadedFile: URL { metaDir.appendingPathComponent("downloaded.json") }
    private var libFile: URL { metaDir.appendingPathComponent("library.json") }
    private func colFile(_ id: String) -> URL { metaDir.appendingPathComponent("col-\(stableKey(id)).json") }

    init() {
        setupRemote()
        customs = Disk.load([CustomAlbum].self, customFile) ?? []
        lib = Disk.load([LibItem].self, libFile) ?? []
        rescanSaved()
        downloaded = (Disk.load([Track].self, downloadedFile) ?? []).filter { savedIDs.contains($0.id) }
    }

    var nowCover: String? { current?.cover ?? queueCover }
    func localURL(_ id: String) -> URL { audioDir.appendingPathComponent("\(id).m4a") }
    func isSaved(_ id: String) -> Bool { savedIDs.contains(id) }

    /// 4KB 以下は旧版がエラー応答を保存したもの。消して未保存に戻す
    private func rescanSaved() {
        var ids = Set<String>()
        let fs = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for f in fs where f.pathExtension == "m4a" {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 4096 { ids.insert(f.deletingPathExtension().lastPathComponent) }
            else { try? FileManager.default.removeItem(at: f) }
        }
        savedIDs = ids
    }

    func savedBytes() -> Int {
        let fs = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return fs.filter { $0.pathExtension == "m4a" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func notify(_ text: String, after seconds: Double = 0) {
        Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            notice = text
        }
    }

    // MARK: 通信

    private func fetchData(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    func connect(force: Bool = false) async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        for c in CANDIDATES {
            guard let u = URL(string: c + "/ping"),
                  let d = try? await fetchData(u, timeout: 3),
                  let p = try? JSONDecoder().decode(Ping.self, from: d), p.ok else { continue }
            base = c; ytState = p.yt; status = ""
            await refreshLibrary(force: force)
            return
        }
        base = nil
        status = savedIDs.isEmpty ? "接続先に届きません。家の Wi-Fi を確認してください"
                                  : "オフライン: 保存済みの曲だけ再生できます"
    }

    func refreshLibrary(force: Bool = false) async {
        guard let b = base, let u = URL(string: b + "/library" + (force ? "?refresh=1" : "")) else { return }
        guard let d = try? await fetchData(u, timeout: 45),
              let items = try? JSONDecoder().decode([LibItem].self, from: d) else {
            status = "一覧を取得できませんでした"; return
        }
        lib = items
        Disk.save(items, libFile)
        if let pu = URL(string: b + "/ping"), let pd = try? await fetchData(pu, timeout: 3),
           let p = try? JSONDecoder().decode(Ping.self, from: pd) { ytState = p.yt }
    }

    func cachedCollection(_ id: String) -> Album? { Disk.load(Album.self, colFile(id)) }

    func fetchCollection(_ id: String) async -> Album? {
        guard let b = base, var c = URLComponents(string: b + "/collection") else { return nil }
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let u = c.url, let d = try? await fetchData(u, timeout: 60),
              let a = try? JSONDecoder().decode(Album.self, from: d) else { return nil }
        Disk.save(a, colFile(id))
        return a
    }

    // MARK: 保存

    /// 1曲を時計に保存する。成功なら nil、失敗なら短い理由を返す
    @discardableResult
    func ensureSaved(_ t: Track) async -> String? {
        if isSaved(t.id) { return nil }
        if inFlight.contains(t.id) {  // 再生と一括保存が同じ曲を同時に取りにいった場合は待つ
            for _ in 0..<600 where inFlight.contains(t.id) { try? await Task.sleep(nanoseconds: 500_000_000) }
            return isSaved(t.id) ? nil : "取得に失敗しました"
        }
        guard let b = base else { return "オフラインです" }
        guard var cc = URLComponents(string: b + "/audio") else { return "URL が不正です" }
        cc.queryItems = [URLQueryItem(name: "src", value: t.src)]
        guard let u = cc.url else { return "URL が不正です" }
        inFlight.insert(t.id); downloadingID = t.id
        defer { inFlight.remove(t.id); if downloadingID == t.id { downloadingID = nil } }
        var rq = URLRequest(url: u); rq.timeoutInterval = 300
        do {
            // メモリに載せず一時ファイルへ直接落とす
            let (tmp, resp) = try await URLSession.shared.download(for: rq)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let http = resp as? HTTPURLResponse
            let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if http?.statusCode != 200 || !ctype.hasPrefix("audio") {
                let body = (try? Data(contentsOf: tmp)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                return body?["error"] ?? "取得に失敗しました"
            }
            let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 4096 else { return "空のファイルでした" }
            let dst = localURL(t.id)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            savedIDs.insert(t.id)
            if !downloaded.contains(where: { $0.id == t.id }) {
                downloaded.append(t); Disk.save(downloaded, downloadedFile)
            }
            return nil
        } catch {
            return "通信できませんでした"
        }
    }

    func missingCount(_ tracks: [Track]) -> Int { tracks.filter { !isSaved($0.id) }.count }

    func saveAll(_ tracks: [Track], force: Bool) async {
        guard bulk == nil else { return }
        var ok = 0
        var failed: [String] = []
        for (n, t) in tracks.enumerated() {
            bulk = "保存中 \(n + 1)/\(tracks.count)"
            if force { removeSaved(t.id) }
            if let e = await ensureSaved(t) { failed.append("\(t.title): \(e)") } else { ok += 1 }
        }
        bulk = nil
        haptic(failed.isEmpty ? .success : .failure)
        notice = failed.isEmpty ? "\(ok)曲を保存しました"
            : "\(tracks.count)曲中\(ok)曲を保存しました。\n取れなかった曲:\n" + failed.prefix(4).joined(separator: "\n")
    }

    private func removeSaved(_ id: String) {
        try? FileManager.default.removeItem(at: localURL(id))
        savedIDs.remove(id)
    }

    func clearAll() {
        player?.pause(); isPlaying = false
        let fs = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        for f in fs where f.pathExtension == "m4a" { try? FileManager.default.removeItem(at: f) }
        let n = downloaded.count
        savedIDs = []; downloaded = []
        Disk.save(downloaded, downloadedFile)
        haptic(.success)
        notice = "保存した\(n)曲を消しました"
    }

    // MARK: 再生

    func play(_ tracks: [Track], from i: Int, cover: String?) {
        queue = tracks; index = i; queueCover = cover
        Task { await playCurrent() }
    }

    func next() {
        guard index + 1 < queue.count else { return stop() }
        index += 1
        Task { await playCurrent() }
    }

    /// 3秒以上進んでいれば曲の頭へ、そうでなければ前の曲へ
    func previous() {
        if let p = player, p.currentTime().seconds > 3 || index == 0 {
            p.seek(to: .zero); clock.progress = 0; return
        }
        guard index > 0 else { return }
        index -= 1
        Task { await playCurrent() }
    }

    func toggle() {
        guard let p = player else {
            if !queue.isEmpty { Task { await playCurrent() } }
            return
        }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func setVolume(_ v: Double) { volume = v; player?.volume = Float(v) }

    private func stop() {
        player?.pause(); isPlaying = false; updateNowPlaying()
    }

    private func playCurrent() async {
        guard queue.indices.contains(index) else { return stop() }
        player?.pause()
        let t = queue[index]
        current = t; clock.progress = 0; isPlaying = false; status = ""
        if !isSaved(t.id) {
            let err = await ensureSaved(t)
            guard current == t else { return }  // 取得中に別の曲へ移った
            if let err {  // 取れない曲は飛ばして次へ
                status = "「\(t.title)」: \(err)"
                haptic(.failure)
                if index + 1 < queue.count { index += 1; await playCurrent() } else { stop() }
                return
            }
        }
        let sess = AVAudioSession.sharedInstance()
        try? sess.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? sess.setActive(true)
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        if let tok = endToken { NotificationCenter.default.removeObserver(tok); endToken = nil }
        let item = AVPlayerItem(url: localURL(t.id))
        let p = AVPlayer(playerItem: item)
        p.volume = Float(volume)
        player = p
        let clock = self.clock
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 2),
                                             queue: .main) { time in
            if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { clock.progress = time.seconds / d }
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                          object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
        p.play(); isPlaying = true
        updateNowPlaying()
    }

    // 時計面に戻っても鳴り続けるよう、システムに再生中として登録する
    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = current?.title ?? ""
        info[MPMediaItemPropertyArtist] = current?.artist ?? ""
        if let d = player?.currentItem?.duration.seconds, d.isFinite { info[MPMediaItemPropertyPlaybackDuration] = d }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds ?? 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: 自作アルバム

    func custom(_ id: String) -> CustomAlbum? { customs.first { $0.id == id } }

    func createCustom(_ name: String) -> CustomAlbum {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = CustomAlbum(id: UUID().uuidString, name: n.isEmpty ? "新しいアルバム" : n, tracks: [])
        customs.append(a); Disk.save(customs, customFile)
        return a
    }

    /// 追加できたら true、すでに入っていたら false
    func addTrack(_ t: Track, to id: String) -> Bool {
        guard let i = customs.firstIndex(where: { $0.id == id }),
              !customs[i].tracks.contains(where: { $0.id == t.id }) else { return false }
        customs[i].tracks.append(t); Disk.save(customs, customFile)
        return true
    }

    func removeTrack(_ t: Track, from id: String) {
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        customs[i].tracks.removeAll { $0.id == t.id }; Disk.save(customs, customFile)
    }

    func deleteCustom(_ id: String) {
        customs.removeAll { $0.id == id }; Disk.save(customs, customFile)
    }
}

// MARK: - 共通の部品

@main
struct WatchTunesWatchApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).preferredColorScheme(.light) }
    }
}

struct RowLabel: View {
    let icon: String
    let text: String
    var detail: String? = nil
    var tint: Color = .amber
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).foregroundStyle(Color.ink).lineLimit(2)
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.caption2).foregroundStyle(Color.sub) }
        }
    }
}

struct StatusRow: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(Color.sub).listRowBackground(Color.clear)
    }
}

/// 重要な操作のボタン。押すと縮み、時計が振動する
struct ActionRow: View {
    let title: String
    var role: ButtonRole? = nil
    var filled = true
    let action: () -> Void
    var body: some View {
        Button(role: role) { haptic(); action() } label: {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                .foregroundStyle(filled ? Color.white : (role == .destructive ? Color.red : Color.amberDeep))
        }
        .buttonStyle(PressStyle())
        .listRowBackground(filled ? Color.amber : Color.surface)
    }
}

struct TrackRow: View {
    @EnvironmentObject var store: Store
    let track: Track
    var badge: String? = nil  // 選ぶモード中に右端へ出す記号
    let action: () -> Void
    var body: some View {
        let isCurrent = store.current?.id == track.id
        Button { haptic(); action() } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(isCurrent ? .body.weight(.semibold) : .body)
                        .foregroundStyle(isCurrent ? Color.amberDeep : Color.ink).lineLimit(2)
                    Text(track.artist).font(.caption2).foregroundStyle(Color.sub).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let badge {
                    Image(systemName: badge).foregroundStyle(Color.amberDeep)
                } else if store.downloadingID == track.id {
                    ProgressView().frame(width: 18)
                } else if store.isSaved(track.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.amber)
                }
            }
        }
        .buttonStyle(PressStyle())
        .listRowBackground(isCurrent ? Color.amber.opacity(0.22) : Color.surface)
    }
}

struct NowPlayingBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let t = store.current {
            NavigationLink { NowPlayingView() } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Color.amberDeep)
                    Text(t.title).font(.caption).foregroundStyle(Color.ink).lineLimit(1)
                }
            }
            .listRowBackground(Color.amber.opacity(0.18))
        }
    }
}

struct Artwork: View {
    let url: String?
    let size: CGFloat
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.surface
                Image(systemName: "music.note").foregroundStyle(Color.sub)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) { image = await ArtCache.image(url) }
    }
}

/// 終わったあとの結果通知
struct NoticeAlert: ViewModifier {
    @EnvironmentObject var store: Store
    func body(content: Content) -> some View {
        content.alert("お知らせ", isPresented: Binding(get: { store.notice != nil },
                                                    set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
    }
}

/// 実行前の確認。重い操作と消す操作は必ずここを通す
enum Confirm: Identifiable {
    case save([Track]), redo([Track]), clearAll, deleteAlbum(String), removeTrack(Track, String)
    var id: String {
        switch self {
        case .save: return "save"
        case .redo: return "redo"
        case .clearAll: return "clear"
        case .deleteAlbum(let a): return "del-\(a)"
        case .removeTrack(let t, let a): return "rm-\(a)-\(t.id)"
        }
    }
}

struct ConfirmModifier: ViewModifier {
    @EnvironmentObject var store: Store
    @Binding var item: Confirm?
    var onDone: ((Confirm) -> Void)? = nil

    func body(content: Content) -> some View {
        content.confirmationDialog(title(item), isPresented: Binding(get: { item != nil },
                                                                     set: { if !$0 { item = nil } }),
                                   titleVisibility: .visible, presenting: item) { c in
            Button(button(c), role: destructive(c) ? .destructive : nil) { haptic(); run(c) }
            Button("やめる", role: .cancel) {}
        } message: { c in
            Text(message(c))
        }
    }

    private func title(_ c: Confirm?) -> String {
        switch c {
        case .save: return "未保存の曲を保存"
        case .redo: return "全部取り直す"
        case .clearAll: return "保存した曲を全消去"
        case .deleteAlbum: return "アルバムを削除"
        case .removeTrack: return "曲を外す"
        case nil: return ""
        }
    }
    private func message(_ c: Confirm) -> String {
        switch c {
        case .save(let ts): return "\(store.missingCount(ts))曲を時計に保存します。1曲に数十秒かかることがあります"
        case .redo(let ts): return "保存済みの分も消して、\(ts.count)曲すべてを取り直します"
        case .clearAll: return "\(store.downloaded.count)曲を時計から消します。元に戻せません"
        case .deleteAlbum(let id): return "「\(store.custom(id)?.name ?? "")」を削除します。保存した曲は残ります"
        case .removeTrack(let t, _): return "「\(t.title)」をこのアルバムから外します"
        }
    }
    private func button(_ c: Confirm) -> String {
        switch c {
        case .save: return "保存する"
        case .redo: return "取り直す"
        case .clearAll: return "消す"
        case .deleteAlbum: return "削除する"
        case .removeTrack: return "外す"
        }
    }
    private func destructive(_ c: Confirm) -> Bool {
        if case .save = c { return false }
        return true
    }
    private func run(_ c: Confirm) {
        switch c {
        case .save(let ts): Task { await store.saveAll(ts, force: false) }
        case .redo(let ts): Task { await store.saveAll(ts, force: true) }
        case .clearAll: store.clearAll()
        case .deleteAlbum(let id):
            let name = store.custom(id)?.name ?? ""
            store.deleteCustom(id); store.notify("「\(name)」を削除しました", after: 0.5)
        case .removeTrack(let t, let id):
            store.removeTrack(t, from: id); store.notify("「\(t.title)」を外しました")
        }
        onDone?(c)
    }
}

/// 一括保存と取り直しのボタン。確認を挟む
struct SaveControls: View {
    @EnvironmentObject var store: Store
    let tracks: [Track]
    @Binding var confirm: Confirm?
    var body: some View {
        if let b = store.bulk { StatusRow(text: b) }
        ActionRow(title: "未保存の曲を保存") {
            if store.missingCount(tracks) == 0 { store.notify("すべて保存済みです") } else { confirm = .save(tracks) }
        }
        .disabled(store.bulk != nil || store.base == nil)
        ActionRow(title: "全部取り直す", role: .destructive, filled: false) { confirm = .redo(tracks) }
            .disabled(store.bulk != nil || store.base == nil)
    }
}

// MARK: - 画面

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            List {
                NowPlayingBar()
                if !store.status.isEmpty { StatusRow(text: store.status) }
                NavigationLink { DownloadedView() } label: {
                    RowLabel(icon: "arrow.down.circle.fill", text: "ダウンロード済み", detail: "\(store.downloaded.count)曲")
                }
                .listRowBackground(Color.surface)
                Section {
                    ForEach(store.customs) { c in
                        NavigationLink { CustomAlbumView(albumID: c.id) } label: {
                            RowLabel(icon: "star.fill", text: c.name, detail: "\(c.tracks.count)曲")
                        }
                        .listRowBackground(Color.surface)
                    }
                    NavigationLink { NewAlbumView() } label: {
                        RowLabel(icon: "plus.circle.fill", text: "新しいアルバム", tint: .amberDeep)
                    }
                    .listRowBackground(Color.surface)
                } header: { Text("自作アルバム") }
                Section {
                    if store.lib.isEmpty {
                        StatusRow(text: store.connecting ? "読み込み中…" : "一覧がありません")
                    }
                    ForEach(store.lib) { item in
                        NavigationLink { CollectionView(collId: item.id, title: item.title) } label: {
                            RowLabel(icon: "opticaldisc.fill", text: item.title)
                        }
                        .listRowBackground(Color.surface)
                    }
                } header: { Text(store.base == nil ? "ライブラリ(オフライン)" : "ライブラリ") }
                NavigationLink { SettingsView() } label: {
                    RowLabel(icon: "gearshape.fill", text: "設定", tint: .sub)
                }
                .listRowBackground(Color.surface)
            }
            .navigationTitle("WatchTunes")
            .containerBackground(Color.bg, for: .navigation)
        }
        .modifier(NoticeAlert())
        .task { if store.base == nil { await store.connect() } }
        .onChange(of: phase) { _, p in  // 家に戻って開いたら繋ぎ直す
            if p == .active && store.base == nil { Task { await store.connect() } }
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject var store: Store
    let collId: String
    let title: String
    @State private var album: Album?
    @State private var loading = true
    @State private var picking = false
    @State private var addTarget: Track?
    @State private var goNow = false
    @State private var confirm: Confirm?
    var body: some View {
        List {
            if let cover = album?.cover {
                Artwork(url: cover, size: 96).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            NowPlayingBar()
            if let a = album {
                if picking { StatusRow(text: "アルバムに入れる曲をタップ") }
                ForEach(Array(a.tracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, badge: picking ? "plus.circle.fill" : nil) {
                        if picking { addTarget = t } else { store.play(a.tracks, from: i, cover: a.cover); goNow = true }
                    }
                }
                if !a.tracks.isEmpty {
                    ActionRow(title: picking ? "選ぶのを終える" : "曲を選んでアルバムに追加", filled: false) { picking.toggle() }
                    SaveControls(tracks: a.tracks, confirm: $confirm)
                }
            } else {
                StatusRow(text: loading ? "読み込み中…" : "取得できませんでした。オフラインでは開いたことのある一覧だけ見られます")
            }
        }
        .navigationTitle(title)
        .containerBackground(Color.bg, for: .navigation)
        .task {
            if album == nil { album = store.cachedCollection(collId) }
            if let fresh = await store.fetchCollection(collId) { album = fresh }
            loading = false
        }
        .navigationDestination(isPresented: $goNow) { NowPlayingView() }
        .sheet(item: $addTarget) { AddToAlbumSheet(track: $0) }
        .modifier(ConfirmModifier(item: $confirm))
    }
}

struct DownloadedView: View {
    @EnvironmentObject var store: Store
    @State private var goNow = false
    var body: some View {
        List {
            NowPlayingBar()
            if store.downloaded.isEmpty { StatusRow(text: "まだ保存した曲がありません") }
            ForEach(Array(store.downloaded.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t) { store.play(store.downloaded, from: i, cover: nil); goNow = true }
            }
        }
        .navigationTitle("ダウンロード済み")
        .containerBackground(Color.bg, for: .navigation)
        .navigationDestination(isPresented: $goNow) { NowPlayingView() }
    }
}

struct CustomAlbumView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let albumID: String
    @State private var goNow = false
    @State private var removing = false
    @State private var confirm: Confirm?
    var body: some View {
        let album = store.custom(albumID)
        List {
            NowPlayingBar()
            if let album {
                if album.tracks.isEmpty {
                    StatusRow(text: "曲がありません。ライブラリの一覧の「曲を選んでアルバムに追加」か、再生画面の右上の + から入れられます")
                }
                if removing { StatusRow(text: "外す曲をタップ") }
                ForEach(Array(album.tracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, badge: removing ? "minus.circle.fill" : nil) {
                        if removing { confirm = .removeTrack(t, albumID) }
                        else { store.play(album.tracks, from: i, cover: nil); goNow = true }
                    }
                }
                if !album.tracks.isEmpty {
                    SaveControls(tracks: album.tracks, confirm: $confirm)
                    ActionRow(title: removing ? "外すのを終える" : "曲を外す", filled: false) { removing.toggle() }
                }
                ActionRow(title: "このアルバムを削除", role: .destructive, filled: false) { confirm = .deleteAlbum(albumID) }
            }
        }
        .navigationTitle(album?.name ?? "")
        .containerBackground(Color.bg, for: .navigation)
        .navigationDestination(isPresented: $goNow) { NowPlayingView() }
        .modifier(ConfirmModifier(item: $confirm, onDone: { c in
            if case .deleteAlbum = c { dismiss() }
        }))
    }
}

struct NewAlbumView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var addTrack: Track? = nil
    var onFinish: (() -> Void)? = nil
    @State private var name = ""
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        List {
            Section {
                // watchOS は入力欄の文字色の指定を無視して白で描くので、欄だけ濃い帯にする
                TextField("アルバム名", text: $name, prompt: Text("タップして入力"))
                    .listRowBackground(Color.field)
            } header: { Text("アルバム名") }
            if !trimmed.isEmpty {
                Text("「\(trimmed)」").font(.headline).foregroundStyle(Color.ink).listRowBackground(Color.clear)
            }
            ActionRow(title: addTrack == nil ? "作成" : "作成して追加") {
                let a = store.createCustom(trimmed)
                if let t = addTrack { _ = store.addTrack(t, to: a.id) }
                store.notify(addTrack == nil ? "「\(a.name)」を作りました" : "「\(a.name)」を作って追加しました", after: 0.6)
                if let onFinish { onFinish() } else { dismiss() }
            }
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.4 : 1)
        }
        .navigationTitle("新しいアルバム")
        .containerBackground(Color.bg, for: .navigation)
    }
}

struct AddToAlbumSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let track: Track
    var body: some View {
        NavigationStack {
            List {
                StatusRow(text: "「\(track.title)」を入れるアルバム")
                ForEach(store.customs) { c in
                    Button {
                        haptic()
                        let added = store.addTrack(track, to: c.id)
                        store.notify(added ? "「\(c.name)」に追加しました" : "「\(c.name)」にはもう入っています", after: 0.6)
                        dismiss()
                    } label: {
                        RowLabel(icon: "star.fill", text: c.name, detail: "\(c.tracks.count)曲")
                    }
                    .buttonStyle(PressStyle())
                    .listRowBackground(Color.surface)
                }
                NavigationLink { NewAlbumView(addTrack: track, onFinish: { dismiss() }) } label: {
                    RowLabel(icon: "plus.circle.fill", text: "新しく作って追加", tint: .amberDeep)
                }
                .listRowBackground(Color.surface)
            }
            .navigationTitle("アルバムに追加")
            .containerBackground(Color.bg, for: .navigation)
        }
        .preferredColorScheme(.light)
    }
}

struct ProgressLine: View {
    @ObservedObject var clock: Clock
    var body: some View {
        let v = clock.progress.isFinite ? min(max(clock.progress, 0), 1) : 0
        ProgressView(value: v).tint(Color.amber)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var store: Store
    @State private var vol = 0.7
    @State private var adding: Track?
    var body: some View {
        VStack(spacing: 5) {
            Artwork(url: store.nowCover, size: 52)
            Text(store.current?.title ?? "")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color.ink).lineLimit(1)
            Text(store.current?.artist ?? "").font(.caption2).foregroundStyle(Color.sub).lineLimit(1)
            if let c = store.current, store.downloadingID == c.id {
                Text("取得中…").font(.caption2).foregroundStyle(Color.amberDeep)
            } else if !store.status.isEmpty {
                Text(store.status).font(.caption2).foregroundStyle(Color.red).lineLimit(2)
            } else {
                ProgressLine(clock: store.clock)
            }
            HStack(spacing: 14) {
                Button { haptic(); store.previous() } label: {
                    Image(systemName: "backward.fill").font(.title3).foregroundStyle(Color.ink)
                        .frame(width: 38, height: 38)
                }
                Button { haptic(); store.toggle() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).foregroundStyle(Color.white)
                        .frame(width: 46, height: 46).background(Color.amber, in: Circle())
                }
                Button { haptic(); store.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).foregroundStyle(Color.ink)
                        .frame(width: 38, height: 38)
                }
            }
            .buttonStyle(PressStyle())
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(Color.sub)
                ProgressView(value: vol).tint(Color.amberDeep)
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(Color.sub)
            }
        }
        .padding(.horizontal, 6)
        .containerBackground(Color.bg, for: .navigation)
        .navigationTitle("再生中")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { haptic(); adding = store.current } label: {
                    Image(systemName: "plus").foregroundStyle(Color.amberDeep)
                }
                .disabled(store.current == nil)
            }
        }
        .focusable(true)  // デジタルクラウンで音量を回す
        .digitalCrownRotation($vol, from: 0, through: 1, by: 0.02, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: vol) { _, v in store.setVolume(v) }
        .onAppear { vol = store.volume }
        .sheet(item: $adding) { AddToAlbumSheet(track: $0) }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.sub)
            Text(value).font(.footnote).foregroundStyle(Color.ink).lineLimit(3)
        }
        .listRowBackground(Color.surface)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var confirm: Confirm?
    @State private var bytes = 0
    var body: some View {
        List {
            Section {
                InfoRow(label: "接続先", value: store.base?.replacingOccurrences(of: "http://", with: "") ?? "オフライン")
                InfoRow(label: "YouTube の一覧", value: store.ytState ?? "未確認")
                ActionRow(title: store.connecting ? "接続中…" : "繋ぎ直して一覧を更新", filled: false) {
                    Task {
                        await store.connect(force: true)
                        store.notify(store.base == nil ? "接続できませんでした" : "一覧を更新しました")
                    }
                }
                .disabled(store.connecting)
            } header: { Text("接続") }
            Section {
                InfoRow(label: "保存した曲", value: "\(store.downloaded.count)曲 / \(bytes / 1_048_576)MB")
                ActionRow(title: "保存した曲を全消去", role: .destructive, filled: false) { confirm = .clearAll }
                    .disabled(bytes == 0)
            } header: { Text("保存") }
        }
        .navigationTitle("設定")
        .containerBackground(Color.bg, for: .navigation)
        .onAppear { bytes = store.savedBytes() }
        .onChange(of: store.downloaded.count) { _, _ in bytes = store.savedBytes() }
        .modifier(ConfirmModifier(item: $confirm))
    }
}
