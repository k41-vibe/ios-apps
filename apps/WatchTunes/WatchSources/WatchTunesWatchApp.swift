import SwiftUI
import AVFoundation

// resolver の固定アドレス(Tailscale)。時計で打ち込まないため焼き込む。変えるときは再ビルド
let DEFAULT_RESOLVER = "http://100.111.178.20:8080"

struct LibItem: Decodable, Identifiable { let title: String; let q: String; var id: String { q } }
struct Track: Decodable, Identifiable { let id: String; let title: String; let artist: String; let duration: Int? }
struct Album: Decodable { let title: String?; let tracks: [Track] }

@MainActor
final class Store: ObservableObject {
    @Published var resolver = UserDefaults.standard.string(forKey: "resolver") ?? DEFAULT_RESOLVER
    @Published var lib: [LibItem] = []
    @Published var status = ""
    @Published var nowPlaying = ""
    private var player: AVPlayer?

    private func base() -> URL? { URL(string: resolver) }

    func loadLibrary() async {
        guard let b = base() else { return }
        status = "ライブラリ取得中"
        do {
            let (data, _) = try await URLSession.shared.data(from: b.appendingPathComponent("library"))
            lib = try JSONDecoder().decode([LibItem].self, from: data)
            status = lib.isEmpty ? "ライブラリが空" : ""
        } catch { status = "取得失敗: \(error.localizedDescription)" }
    }

    func fetchAlbum(_ q: String) async -> Album? {
        guard let b = base() else { return nil }
        do {
            var c = URLComponents(url: b.appendingPathComponent("album"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            let (data, _) = try await URLSession.shared.data(from: c.url!)
            return try JSONDecoder().decode(Album.self, from: data)
        } catch { status = "アルバム取得失敗: \(error.localizedDescription)"; return nil }
    }

    func play(_ t: Track) async {
        guard let b = base() else { return }
        let dst = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(t.id).m4a")
        do {
            if !FileManager.default.fileExists(atPath: dst.path) {
                status = "取得中: \(t.title)"
                let src = b.appendingPathComponent("audio").appendingPathComponent("\(t.id).m4a")
                let (data, _) = try await URLSession.shared.data(from: src)
                try data.write(to: dst)
            }
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default)
            try? s.setActive(true)
            player = AVPlayer(url: dst)
            player?.play()
            nowPlaying = "\(t.title) / \(t.artist)"
            status = "再生中"
        } catch { status = "再生失敗: \(error.localizedDescription)" }
    }
}

@main
struct WatchTunesWatchApp: App {
    @StateObject private var store = Store()
    var body: some Scene { WindowGroup { AlbumsView().environmentObject(store) } }
}

struct AlbumsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.lib) { item in
                    NavigationLink(item.title) { TracksView(q: item.q, title: item.title) }
                }
                if !store.status.isEmpty { Text(store.status).font(.caption2).foregroundStyle(.secondary) }
                Button("再読み込み") { Task { await store.loadLibrary() } }
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
    @State private var tracks: [Track] = []
    var body: some View {
        List {
            if !store.nowPlaying.isEmpty { Section("再生中") { Text(store.nowPlaying).font(.footnote) } }
            ForEach(tracks) { t in
                Button { Task { await store.play(t) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.body)
                        Text(t.artist).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !store.status.isEmpty { Text(store.status).font(.caption2).foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .task { if let a = await store.fetchAlbum(q) { tracks = a.tracks } }
    }
}
