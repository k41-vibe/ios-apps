import Foundation

// LiveContainer の一覧に出る版(CFBundleShortVersionString)と、ビルド番号・コミットをまとめて表示する。
// 値は CI が xcodebuild の引数で注入する(docs/VERSIONING.md)。
enum AppVersion {
    static var string: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        let sha = info["LCGitCommit"] as? String ?? "?"
        return "v\(v) (build \(b)) \(sha)"
    }
}
