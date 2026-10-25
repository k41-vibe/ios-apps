import SwiftUI
import AVFoundation

// resolver の候補。時計で打ち込まず、届いた方を自動で使う。家の Wi-Fi なら LAN、無ければ Tailscale を試す
let CANDIDATES = ["http://192.168.10.103:8080", "http://100.111.178.20:8080"]

struct LibItem: Decodable, Identifiable { let title: String; let q: String; var id: String { q } }
struct Track: Decodable, Identifiable { let id: String; let title: String; let artist: String; let duration: Int? }
struct Album: Decodable { let title: String?; let tracks: [Track] }

@MainActor
final class Store: ObservableObject {
    @Published var base: String?        // 届いた resolver
    @Published var lib: [LibItem] = []
    @Published var status = ""
    @Published var nowPlaying = ""
    private var player: AVPlayer?

    private func get(_ url: URL, timeout: TimeInterval = 8) async throws -> Data {
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        let (d, _) = try await URLSession.shared.data(for: r)
        return d
    }

    func loadLibrary() async {
        status = "resolver を探しています"
        for cand in CANDIDATES {
            guard let u = URL(string: cand + "/library") else { continue }
            do {
                let data = try await get(u, timeout: 6)
                lib = try JSONDecoder().decode([LibItem].self, from: data)
                base = cand
                status = lib.isEmpty ? "ライブラリが空" : "接続: \(cand)"
                return
            } catch { continue }
        }
        status = "resolver に届きません(Wi-Fi と PC を確認)"
    }

    func fetchAlbum(_ q: String) async -> Album? {
        guard let b = base, var c = URLComponents(string: b + "/album") else { return nil }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        do { return try JSONDecoder().decode(Album.self, from: try await get(c.url!, timeout: 20)) }
        catch { status = "アルバム取得失敗: \(error.localizedDescription)"; return nil }
    }

    func play(_ t: Track) async {
        guard let b = base else { return }
        let dst = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(t.id).m4a")
        do {
            if !FileManager.default.fileExists(atPath: dst.path) {
                status = "取得中: \(t.title)"
                guard let s = URL(string: b + "/audio/\(t.id).m4a") else { return }
                try (try await get(s, timeout: 120)).write(to: dst)
            }
            let sess = AVAudioSession.sharedInstance()
            try? sess.setCategory(.playback, mode: .default)
            try? sess.setActive(true)
            player = AVPlayer(url: dst); player?.play()
            nowPlaying = "\(t.title) / \(t.artist)"; status = "再生中"
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
