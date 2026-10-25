import SwiftUI
import AVFoundation
import MediaPlayer

// resolver の候補。届いた方を自動で使う(時計で打ち込まないため)
let CANDIDATES = ["http://192.168.10.103:8080", "http://100.111.178.20:8080"]

extension Color {
    init(_ hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
    static let bg = Color(0x000000)
    static let surface = Color(0x16151A)
    static let ink = Color(0xF3F1EC)
    static let sub = Color(0x8E8A82)
    static let amber = Color(0xE7B24C)
}

struct LibItem: Decodable, Identifiable { let title: String; let q: String; var id: String { q } }
struct Track: Decodable, Identifiable, Equatable { let id: String; let title: String; let artist: String; let duration: Int? }
struct Album: Decodable { let title: String?; let cover: String?; let tracks: [Track] }

@MainActor
final class Store: ObservableObject {
    @Published var base: String?
    @Published var lib: [LibItem] = []
    @Published var status = ""
    @Published var current: Track?
    @Published var currentCover: String?
    @Published var isPlaying = false
    @Published var progress = 0.0
    @Published var downloadingID: String?

    private var queue: [Track] = []
    private var index = 0
    private var player: AVPlayer?
    private var observer: Any?

    private let saveDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { setupRemote() }

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

    func localURL(_ id: String) -> URL { saveDir.appendingPathComponent("\(id).m4a") }
    func isSaved(_ id: String) -> Bool { FileManager.default.fileExists(atPath: localURL(id).path) }

    private func get(_ url: URL, timeout: TimeInterval = 10) async throws -> Data {
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        return try await URLSession.shared.data(for: r).0
    }

    func loadLibrary() async {
        status = "接続先を探しています"
        for c in CANDIDATES {
            guard let u = URL(string: c + "/library") else { continue }
            if let data = try? await get(u, timeout: 6),
               let items = try? JSONDecoder().decode([LibItem].self, from: data) {
                base = c; lib = items; status = ""; return
            }
        }
        status = "接続先に届きません。Wi-Fi を確認してください"
    }

    func fetchAlbum(_ q: String) async -> Album? {
        guard let b = base, var c = URLComponents(string: b + "/album") else { return nil }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let u = c.url, let data = try? await get(u, timeout: 25) else { return nil }
        return try? JSONDecoder().decode(Album.self, from: data)
    }

    // アルバムをキューに入れ、指定の曲から再生
    func playAlbum(_ album: Album, from i: Int) async {
        queue = album.tracks; index = i; currentCover = album.cover
        await playCurrent()
    }

    func next() { Task { if index + 1 < queue.count { index += 1; await playCurrent() } } }
    func previous() { Task { if index > 0 { index -= 1; await playCurrent() } } }

    private func playCurrent() async {
        guard queue.indices.contains(index) else { return }
        let t = queue[index]; current = t; progress = 0
        if !isSaved(t.id), !(await ensureSaved(t)) { status = "取得に失敗しました"; return }
        let sess = AVAudioSession.sharedInstance()
        try? sess.setCategory(.playback, mode: .default); try? sess.setActive(true)
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        NotificationCenter.default.removeObserver(self)
        let item = AVPlayerItem(url: localURL(t.id))
        let p = AVPlayer(playerItem: item); player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 2),
                                             queue: .main) { [weak self] time in
            guard let self, let d = p.currentItem?.duration.seconds, d > 0 else { return }
            self.progress = time.seconds / d
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                               queue: .main) { [weak self] _ in self?.next() }
        p.play(); isPlaying = true
        updateNowPlaying()
    }

    @discardableResult
    func ensureSaved(_ t: Track) async -> Bool {
        if isSaved(t.id) { return true }
        guard let b = base, let u = URL(string: b + "/audio/\(t.id).m4a") else { return false }
        downloadingID = t.id
        defer { downloadingID = nil }
        guard let data = try? await get(u, timeout: 180) else { return false }
        do { try data.write(to: localURL(t.id)); return true } catch { return false }
    }

    func saveAlbum(_ tracks: [Track]) async { for t in tracks { _ = await ensureSaved(t) } }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }
}

@main
struct WatchTunesWatchApp: App {
    @StateObject private var store = Store()
    var body: some Scene { WindowGroup { AlbumsView().environmentObject(store) } }
}

struct NowPlayingBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let t = store.current {
            NavigationLink { NowPlayingView() } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Color.amber)
                    Text(t.title).font(.caption).foregroundStyle(Color.ink).lineLimit(1)
                }
            }
        }
    }
}

struct AlbumsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack {
            List {
                NowPlayingBar()
                ForEach(store.lib) { item in
                    NavigationLink { TracksView(q: item.q, title: item.title) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "opticaldisc").foregroundStyle(Color.amber)
                            Text(item.title).foregroundStyle(Color.ink)
                        }
                    }
                }
                if !store.status.isEmpty {
                    Text(store.status).font(.caption2).foregroundStyle(Color.sub)
                    Button("再読み込み") { Task { await store.loadLibrary() } }
                }
            }
            .navigationTitle("WatchTunes")
        }
        .task { if store.lib.isEmpty { await store.loadLibrary() } }
    }
}

struct TracksView: View {
    @EnvironmentObject var store: Store
    let q: String
    let title: String
    @State private var album: Album?
    var body: some View {
        List {
            if let cover = album?.cover {
                Artwork(url: cover, size: 110).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            NowPlayingBar()
            if let a = album {
                ForEach(Array(a.tracks.enumerated()), id: \.element.id) { i, t in
                    Button { Task { await store.playAlbum(a, from: i) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body).foregroundStyle(Color.ink)
                                Text(t.artist).font(.caption2).foregroundStyle(Color.sub)
                            }
                            Spacer()
                            if store.downloadingID == t.id {
                                ProgressView().tint(Color.amber)
                            } else if store.isSaved(t.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.amber)
                            }
                        }
                    }
                }
                if !a.tracks.isEmpty {
                    Button("アルバムを保存") { Task { await store.saveAlbum(a.tracks) } }
                }
            }
        }
        .navigationTitle(title)
        .task { album = await store.fetchAlbum(q) }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Artwork(url: store.currentCover, size: 84)
                Text(store.current?.title ?? "")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color.ink).lineLimit(2).multilineTextAlignment(.center)
                Text(store.current?.artist ?? "").font(.caption2).foregroundStyle(Color.sub).lineLimit(1)
                ProgressView(value: store.progress.isFinite ? min(max(store.progress, 0), 1) : 0).tint(Color.amber)
                HStack(spacing: 18) {
                    Button { store.previous() } label: {
                        Image(systemName: "backward.fill").font(.title3).foregroundStyle(Color.ink)
                    }
                    Button { store.toggle() } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).foregroundStyle(Color.bg)
                            .frame(width: 46, height: 46).background(Color.amber, in: Circle())
                    }
                    Button { store.next() } label: {
                        Image(systemName: "forward.fill").font(.title3).foregroundStyle(Color.ink)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("再生中")
    }
}

struct Artwork: View {
    let url: String?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack { Color.surface; Image(systemName: "music.note").foregroundStyle(Color.sub) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
