import Foundation

/// `magickey://` 的一条命令。
///
/// ## 为什么是纯值类型 + 纯函数
///
/// 解析和执行分开，探针才测得到。反过来写（在 `AppDelegate` 里边解析边动手）
/// 的话，要验「`times=abc` 会不会闪 0 下」就得真的起一个 app、发一个 Apple Event、
/// 再想办法观察背光——没人会写那种测试，于是这一层永远没有回归。
///
/// ## 命令面只有三个动词，这是有意的
///
/// `flash` / `on`·`off` / `effect`。**别再加**，除非有人真的拿着一个脚本来要。
/// 每加一个动词都要同时改：解析、执行、shell 脚本、`--help`、README、探针。
/// 而 `on`/`off`/`effect` 本身已经把「面板上能点的东西」覆盖完了——
/// 它们写的就是 `Settings` 现有属性，持久化是白拿的。
///
/// ## 零新增权限
///
/// URL scheme 走 LaunchServices，不需要任何 TCC 授权，也不需要常驻端口/socket。
/// 这是选它而不是 XPC / DistributedNotification 的**首要**理由，
/// 其次才是「CLI 第一版可以只是一个 shell 脚本」。
enum URLCommand: Equatable {

    /// 闪 N 下
    case flash(times: Int)
    /// 总开关。等价于用户在面板上拨那个开关
    case setEnabled(Bool)
    /// 换效果。等价于在面板上点那一格
    case setEffect(EffectKind)

    static let scheme = "magickey"

    /// `times` 缺省值。定义在 `FlashEffect`——`magickey-tool` 也要用同一个数，
    /// 而它不编译 app 这边的源码。
    static let defaultFlashTimes = FlashEffect.defaultTimes

    /// 解析一条 URL。**无法理解就返回 nil**——调用方记一条日志然后忽略，
    /// 不弹窗。脚本里打错一个字不该在用户屏幕上糊一个对话框。
    ///
    /// 形式：
    /// ```
    /// magickey://flash            闪 3 下
    /// magickey://flash?times=5    闪 5 下
    /// magickey://on
    /// magickey://off
    /// magickey://effect/breathe
    /// ```
    static func parse(_ url: URL) -> URLCommand? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme else { return nil }

        // 动词在 host 上。`magickey://flash` 的 host 就是 "flash"。
        switch c.host?.lowercased() {
        case "flash":
            return .flash(times: flashTimes(from: c))

        case "on":
            return .setEnabled(true)

        case "off":
            return .setEnabled(false)

        case "effect":
            // `magickey://effect/breathe` → path == "/breathe"
            let raw = c.path.split(separator: "/").first.map(String.init) ?? ""
            // **用 `EffectKind(rawValue:)` 验证，不要自己列一张表**——
            // 加效果时那张表一定会忘记改，而失败方式是「命令静默无效」。
            guard let kind = EffectKind(rawValue: raw.lowercased()) else { return nil }
            return .setEffect(kind)

        default:
            return nil
        }
    }

    /// `times` 的取值规则，两条刻意不同：
    ///   - **压根不是数字**（`times=abc`、`times=`）→ 按缺省 3。调用方多半是
    ///     shell 变量没展开，给个合理的默认比什么都不做有用。
    ///   - **是数字但超出范围**（`times=0`、`times=999`）→ 钳进 1…10。
    ///     他确实想表达次数，只是给大了；钳住比忽略更接近本意。
    private static func flashTimes(from c: URLComponents) -> Int {
        guard let raw = c.queryItems?.first(where: { $0.name.lowercased() == "times" })?.value,
              let n = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return defaultFlashTimes }
        return Swift.min(Swift.max(n, FlashEffect.timesRange.lowerBound),
                         FlashEffect.timesRange.upperBound)
    }

    /// 给日志用的一句话
    var summary: String {
        switch self {
        case .flash(let n):      return "flash ×\(n)"
        case .setEnabled(let on): return on ? "开启" : "关闭"
        case .setEffect(let k):  return "切换效果 → \(k.rawValue)"
        }
    }
}
