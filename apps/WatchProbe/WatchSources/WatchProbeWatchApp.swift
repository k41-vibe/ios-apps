import SwiftUI

@main
struct WatchProbeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WatchProbe")
                        .font(.headline)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
                        .foregroundStyle(.secondary)
                    ForEach(DlopenProbe.run(), id: \.self) { line in
                        Text(line).font(.footnote)
                    }
                }
            }
        }
    }
}

// 時計版 LiveContainer の前提を確かめる。LiveContainer はデータ領域に置いた署名済みの実行ファイルを
// dlopen で読み込むので、watchOS の sandbox がそれを許すかを見る。
// 処理は LCProbe の runtimeDlopen と同じ。libprobe1.dylib は postbuild.sh が Frameworks/ に入れる
enum DlopenProbe {
    typealias Fn = @convention(c) () -> Int32

    static func run() -> [String] {
        guard let fw = Bundle.main.privateFrameworksPath else { return ["Frameworks が無い"] }
        let src = URL(fileURLWithPath: fw).appendingPathComponent("libprobe1.dylib")
        var out = ["1 バンドル内: " + load(src.path)]

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dst = docs.appendingPathComponent("rt_probe.dylib")
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            out.append("2 Documents: " + load(dst.path))
        } catch {
            out.append("2 コピー失敗: \(error.localizedDescription)")
        }
        return out
    }

    static func load(_ path: String) -> String {
        guard let h = dlopen(path, RTLD_NOW) else {
            return "失敗 " + (dlerror().map { String(cString: $0) } ?? "?")
        }
        guard let sym = dlsym(h, "probe_1") else { return "読込OK、関数が無い" }
        return "OK probe_1() = \(unsafeBitCast(sym, to: Fn.self)())"
    }
}
