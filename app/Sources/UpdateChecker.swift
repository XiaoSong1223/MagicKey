import Foundation
import Combine
import AppKit

/// 检查 GitHub Releases 上有没有新版本。
///
/// **这是这个 App 唯一的网络请求**，而 DESIGN.md §5 的隐私红线原本写的是
/// 「无网络请求、无遥测、无崩溃上报（或明确 opt-in）」。所以：
///   - 只发一个匿名 GET，不带任何标识（无 UUID、无机器信息、无使用数据）
///   - 请求里唯一会暴露的是「有人在某个 IP 上查过这个仓库的 release」，
///     这和用浏览器打开仓库页面等价
///   - 可以关（高级 → 自动检查更新），关掉之后进程不碰网络
///
/// 不用 Sparkle：它是 SwiftPM 依赖，而本机 SwiftPM 是坏的
/// （见 CLAUDE.md「SwiftPM 在这台机器上是坏的」）。这里只需要「比个版本号」，
/// 自己发一个 URLSession 请求比为此重装 Command Line Tools 便宜得多。
/// 真要做静默自动更新（下载 + 替换 + 重启）再引 Sparkle 不迟——那需要
/// 代码签名和公证，本来也排在 Developer ID 之后。
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate                       // 已是最新
        case available(String, URL)         // 新版本号、发布页
        case failed(String)                 // 如实给出原因，不吞
    }

    @Published private(set) var state: State = .idle

    /// 当前版本，取自 Info.plist 的 CFBundleShortVersionString
    let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "0"

    private static let api = URL(string:
        "https://api.github.com/repos/XiaoSong1223/MagicKey/releases/latest")!
    private static let releasesPage = URL(string:
        "https://github.com/XiaoSong1223/MagicKey/releases/latest")!

    /// 自动检查的间隔。一天一次——版本不会一小时一变，查勤了只是白发请求。
    private static let interval: TimeInterval = 24 * 3600

    private var timer: Timer?
    private var task: URLSessionTask?

    // MARK: - 生命周期

    /// 开启定期检查。启动时先查一次，之后每天一次。
    func startAuto() {
        guard timer == nil else { return }
        check(manual: false)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAuto() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        // 关掉之后状态也清掉：留着「有新版本」的提示会让人以为它还在工作
        state = .idle
    }

    func openReleasesPage() {
        if case .available(_, let url) = state { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(Self.releasesPage) }
    }

    // MARK: - 检查

    /// - Parameter manual: 用户点的。手动时即使刚查过也重新查，并且把失败显示出来；
    ///   自动检查失败则安静——网络不通不是用户的错，不该每天弹一次红字。
    func check(manual: Bool) {
        task?.cancel()
        state = .checking

        var req = URLRequest(url: Self.api)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 要求带 User-Agent，否则直接 403。只放应用名和版本，不放机器信息。
        req.setValue("MagicKey/\(current)", forHTTPHeaderField: "User-Agent")

        let t = URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.finish(data: data, response: response, error: error, manual: manual)
            }
        }
        task = t
        t.resume()
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?, manual: Bool) {
        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            state = manual ? .failed("连接失败：\(error.localizedDescription)") : .idle
            return
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // 404 在这个项目里是**预期**情况，不是 bug：仓库是 Private，
            // 未授权访问 releases API 就是 404；而且目前一个 release 都还没发。
            // 说清楚，别让人对着「检查失败」去查网络。
            let why = code == 404 ? "仓库尚未公开发布（Private 或还没有 release）"
                    : code == 403 ? "GitHub API 限流，稍后再试"
                    : "GitHub 返回 HTTP \(code)"
            state = manual ? .failed(why) : .idle
            return
        }

        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            state = manual ? .failed("返回内容解析失败") : .idle
            return
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let url = (obj["html_url"] as? String).flatMap(URL.init) ?? Self.releasesPage
        state = Self.isNewer(latest, than: current) ? .available(latest, url) : .upToDate
    }

    /// 逐段数字比较。"0.10" > "0.9"——字符串比较在这里是错的。
    /// 非数字段（"0.4-beta"）取前缀数字，比不出来就当相等，宁可不提示也不误报。
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { seg in
                Int(seg.prefix { $0.isNumber }) ?? 0
            }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<Swift.max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
