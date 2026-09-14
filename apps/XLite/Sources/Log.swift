import Foundation

/// 画面とファイルの両方に残す小さなログ。Updater が使う API(log / sync / fileURL)だけを持つ。
/// 実機で何が起きたかは、設定画面から PC の配布サーバーへ送って読む。
final class ConsoleLog: ObservableObject {
    @Published var text = ""
    let fileURL: URL
    private var fh: FileHandle?
    private let lock = NSLock()
    private static let maxOnScreen = 60_000

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("xlite.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fh = try? FileHandle(forWritingTo: fileURL)
        _ = try? fh?.seekToEnd()
    }

    func log(_ s: String) {
        let line = "[\(Self.stamp())] \(s)\n"
        lock.lock()
        if let d = line.data(using: .utf8) { fh?.write(d) }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.text += line
            if self.text.count > Self.maxOnScreen {
                self.text = String(self.text.suffix(Self.maxOnScreen / 2))
            }
        }
    }

    func sync() {
        lock.lock()
        try? fh?.synchronize()
        lock.unlock()
    }

    func clear() {
        lock.lock()
        try? fh?.truncate(atOffset: 0)
        try? fh?.synchronize()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.text = "" }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
