import SwiftUI
import AVFoundation

// resolver が返す曲とアルバム
struct Track: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let duration: Int?
}
struct Album: Decodable {
    let title: String?
    let artists: [String]?
    let tracks: [Track]
}

@MainActor
final class Store: ObservableObject {
    @Published var resolver: String { didSet { UserDefaults.standard.set(resolver, forKey: "resolver") } }
    @Published var query = "Discovery Daft Punk"
    @Published var album: Album?
    @Published var status = ""
    @Published var nowPlaying = ""
    private var player: AVPlayer?

    init() { resolver = UserDefaults.standard.string(forKey: "resolver") ?? "" }

    private func base() -> URL? {
        let s = resolver.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : URL(string: s)
    }

    func load() async {
        guard let b = base() else { status = "resolver URL を入れてください"; return }
        status = "読み込み中"
        do {
            var c = URLComponents(url: b.appendingPathComponent("album"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            let (data, _) = try await URLSession.shared.data(from: c.url!)
            album = try JSONDecoder().decode(Album.self, from: data)
            status = "\(album?.tracks.count ?? 0) 曲"
        } catch { status = "失敗: \(error.localizedDescription)" }
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
        } catch { status = "失敗: \(error.localizedDescription)" }
    }
}

@main
struct WatchTunesWatchApp: App {
    var body: some Scene { WindowGroup { WatchHome() } }
}

struct WatchHome: View {
    @StateObject private var store = Store()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("resolver URL", text: $store.resolver)
                    TextField("検索", text: $store.query)
                    Button("読み込み") { Task { await store.load() } }
                }
                if !store.nowPlaying.isEmpty {
                    Section("再生中") { Text(store.nowPlaying).font(.footnote) }
                }
                if let album = store.album {
                    Section(album.title ?? "アルバム") {
                        ForEach(album.tracks) { t in
                            Button { Task { await store.play(t) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.body)
                                    Text(t.artist).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !store.status.isEmpty {
                    Section { Text(store.status).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("WatchTunes")
        }
    }
}
