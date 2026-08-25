import Foundation
import Combine

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

/// `EffectKind` 的**界面那一半**。
///
/// 身份、周期区间、默认周期在 `Core/EffectFactory.swift`——那些是 `magickey-tool`
/// 也要用的，而显示名和 SF Symbol 只有面板需要。Core 不该知道自己被谁用。
extension EffectKind {

    var displayName: String {
        switch self {
        case .staticLevel: return "常亮"
        case .breathe:     return "呼吸"
        case .heartbeat:   return "心跳"
        case .strobe:      return "频闪"
        case .keyPulse:    return "按键"
        case .audioBeat:   return "音乐"
        }
    }

    var symbol: String {
        switch self {
        case .staticLevel: return "sun.max"
        case .breathe:     return "wave.3.right"
        case .heartbeat:   return "heart"
        case .strobe:      return "bolt"
        case .keyPulse:    return "hand.tap"
        case .audioBeat:   return "waveform"
        }
    }

    /// 按键脉冲不循环，「周期」这个词对它是错的
    var periodLabel: String { isPulse ? "脉冲时长" : "周期" }

    /// 最暗/最亮两个滑块在按键脉冲下的含义是「静息」和「峰值」。
    /// 主界面只用 hi（叫「亮度」），lo 收在高级里，所以这里主要是 lo 的标签。
    var levelLabels: (lo: String, hi: String) {
        isPulse ? ("静息亮度", "脉冲峰值") : ("最暗", "最亮")
    }

    /// 效果选中时的一句说明。**只写「做不到什么」**——
    /// 硬件限制导致的落差会被当成 bug 报上来，先说清楚比事后解释便宜。
    /// 其余效果不需要说明，返回 nil 就不占版面。
    var note: String? {
        switch self {
        case .keyPulse:
            return "每次敲键整块键盘闪一下。硬件只有一路全局背光，无法从单个按键扩散。"
        case .audioBeat:
            return "整块键盘跟着音乐的鼓点闪。需要「系统录音」权限（不是麦克风）。"
        default:
            return nil
        }
    }
}

/// 用 UserDefaults 持久化。每个属性 didSet 即写盘——设置项少，不需要批量提交。
final class Settings: ObservableObject {

    /// **探针必须写在自己的域里。**
    /// 本文件曾假定「裸可执行文件没有 bundle id，`UserDefaults.standard` 自然
    /// 落在单独的域里」——2026-08-23 实测**是错的**：`make probe-ui` 跑完，
    /// `io.github.xiaosong1223.MagicKey` 域里的 `keySoundEnabled` 被写成 0
    /// （探针最后一步会把音效关掉收尾），等于**默默改掉用户正在用的设置**。
    /// 判据：`defaults write … keySoundEnabled -bool true` → 跑探针 → 再读，变 0。
    #if UI_PROBE
    private static let d = UserDefaults(suiteName: "io.github.xiaosong1223.MagicKey.uiprobe")!
    #else
    private static let d = UserDefaults.standard
    #endif

    private static func double(_ key: String, _ fallback: Double) -> Double {
        d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    @Published var enabled: Bool = Settings.bool("enabled", false) {
        didSet { Self.d.set(enabled, forKey: "enabled") }
    }

    @Published var kind: EffectKind = EffectKind(rawValue: d.string(forKey: "kind") ?? "") ?? .breathe {
        didSet {
            Self.d.set(kind.rawValue, forKey: "kind")
            // 换效果时把周期拉回该效果的合理区间
            if !kind.periodRange.contains(period) { period = kind.defaultPeriod }
        }
    }

    @Published var period: Double = Settings.double("period", 4.0) {
        didSet { Self.d.set(period, forKey: "period") }
    }

    @Published var lo: Double = Settings.double("lo", 0.05) {
        didSet {
            Self.d.set(lo, forKey: "lo")
            if lo > hi - 0.05 { hi = Swift.min(1.0, lo + 0.05) }
        }
    }

    @Published var hi: Double = Settings.double("hi", 0.85) {
        didSet {
            Self.d.set(hi, forKey: "hi")
            if hi < lo + 0.05 { lo = Swift.max(0.0, hi - 0.05) }
        }
    }

    /// 省电模式：30fps。实测最大相对步进从 7.7% 劣化到 12.5%，观感可接受。
    @Published var powerSaver: Bool = Settings.bool("powerSaver", false) {
        didSet { Self.d.set(powerSaver, forKey: "powerSaver") }
    }

    /// 「空闲即停」是硬需求而非优化——见 DESIGN.md §3.3。
    /// 默认开启，且不建议关闭：60Hz 唤醒会阻止 SoC 进入深度空闲。
    @Published var stopWhenIdle: Bool = Settings.bool("stopWhenIdle", true) {
        didSet { Self.d.set(stopWhenIdle, forKey: "stopWhenIdle") }
    }

    @Published var idleSeconds: Double = Settings.double("idleSeconds", 120) {
        didSet { Self.d.set(idleSeconds, forKey: "idleSeconds") }
    }

    /// 音乐律动的触发灵敏度（`OnsetDetector` 的阈值倍数）。小 = 灵敏 = 闪得密。
    ///
    /// 直接推给已经在跑的检测器，**不重建效果、不重建 tap**——
    /// tap 建立要 1.8–4.6 秒，拖滑块时重建等于卡死。
    @Published var sensitivity: Double = Settings.double("sensitivity", 1.35) {
        didSet {
            Self.d.set(sensitivity, forKey: "sensitivity")
            BeatPulseSource.shared.sensitivity = Float(sensitivity)
        }
    }

    /// 键盘音效。**默认关闭，且必须默认关闭**——它是本应用唯一需要
    /// 「输入监控」授权的功能，那个权限的语义是「这个 app 能看到你按的每一个键」。
    /// 默认打开等于替用户做了这个决定。
    @Published var keySoundEnabled: Bool = Settings.bool("keySoundEnabled", false) {
        didSet { Self.d.set(keySoundEnabled, forKey: "keySoundEnabled") }
    }

    /// 键盘音效的总音量 0–1。默认 0.6：各音色包已经做过响度对齐，
    /// 这个位置在 MacBook 内置扬声器上大致等于「听得见但不盖过视频」。
    ///
    /// ⚠️ 2026-08-23 扩包时对齐目标抬高了 1.56dB（见 `KeySoundPack.gain`），
    /// 所以同一个滑块位置比 v1.0 整体响一点。默认值没跟着调——
    /// 0.6 仍在合适区间，而改默认值会让老用户的音量莫名其妙地变。
    @Published var keySoundVolume: Double = Settings.double("keySoundVolume", 0.6) {
        didSet { Self.d.set(keySoundVolume, forKey: "keySoundVolume") }
    }

    /// 音色包目录名。存字符串而不是枚举：以后加包只动 `KeySoundPack.all`，
    /// 而已经存进 UserDefaults 的旧值遇到不认识的名字会退回默认包（见 `named`）。
    @Published var keySoundPack: String = d.string(forKey: "keySoundPack") ?? KeySoundPack.fallback.id {
        didSet { Self.d.set(keySoundPack, forKey: "keySoundPack") }
    }

    /// 自定义按键音的总开关。**默认打开，和 `keySoundEnabled` 的理由正好相反**：
    /// 那个开关背后是一项权限，必须由用户主动同意；而指键本身就是用户一个键一个键
    /// 点出来的主动行为，点完了却不响才是意外。这个开关的用途是快速 A/B
    /// （「我加的音到底有没有起作用」），不是准入。
    @Published var keySoundCustomEnabled: Bool = Settings.bool("keySoundCustomEnabled", true) {
        didSet { Self.d.set(keySoundCustomEnabled, forKey: "keySoundCustomEnabled") }
    }

    /// 自动检查更新。**这是 App 唯一的网络请求**，所以给了明确的开关——
    /// DESIGN.md §5 的隐私红线要求网络行为可关闭。关掉之后进程不碰网络。
    @Published var autoCheckUpdates: Bool = Settings.bool("autoCheckUpdates", true) {
        didSet { Self.d.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }

    /// 「快慢」滑块用的归一化速度：0 = 最慢，1 = 最快。
    ///
    /// 主界面不暴露「周期 4.0 秒」这种工程师语言。方向也是反的——
    /// 周期越短越快，而滑块往右理应变快，所以这里做了翻转。
    /// 各效果的周期区间不同（呼吸 1–20s，频闪 0.1–2s），归一化之后
    /// 同一个滑块位置在不同效果下含义一致：都是「这个效果的最快/最慢」。
    var speed: Double {
        get {
            let r = kind.periodRange
            guard r.upperBound > r.lowerBound else { return 0.5 }
            return (r.upperBound - period) / (r.upperBound - r.lowerBound)
        }
        set {
            let r = kind.periodRange
            period = r.upperBound - newValue.clamped(0, 1) * (r.upperBound - r.lowerBound)
        }
    }

    var fps: Double { powerSaver ? 30 : 60 }

    /// **实现在 `Core/EffectFactory.swift`，这里只负责把设置转成 `EffectSpec`。**
    /// 以前这里是个 switch，`magickey-tool` 里还有一份一模一样的——两份漂了，
    /// 工具那份甚至没有 audiobeat 分支。理由写在工厂那个文件的开头。
    func makeEffect() -> Effect {
        // 灵敏度**不经过效果**：它直推已经在跑的检测器（见 `sensitivity` 的 didSet），
        // 因为重建 tap 要 1.8–4.6 秒，拖滑块时重建等于卡死。
        // 这里补一次是因为**启动时读盘不走 didSet**——不补的话 `BeatPulseSource`
        // 一直用着出厂默认阈值，用户上次调的灵敏度要等他再动一次滑块才生效。
        if kind == .audioBeat {
            BeatPulseSource.shared.sensitivity = Float(sensitivity)
        }
        return EffectFactory.make(EffectSpec(kind: kind, period: period,
                                             lo: Float(lo), hi: Float(hi)))
    }

    /// 真正会改变**渲染输出**的那几项。
    ///
    /// `Engine.apply` 收的是 `Settings` 这个引用对象，没有值语义，所以它没法自己
    /// 判断「这次变的到底是不是我关心的东西」，只能把每次调用都当成参数变了、
    /// 把渲染状态整个重建一遍。后果见 `Engine.RenderInputs`。
    ///
    /// **加新设置项时的判据**：它会不会改变 `makeEffect()` 的产物或帧率？
    /// 会 → 加进来；不会 → 千万别加，加了就等于把那个「无关设置也重启动画」的
    /// bug 再引入一次。
    var renderInputs: RenderInputs {
        RenderInputs(enabled: enabled, kind: kind, period: period,
                     lo: lo, hi: hi, fps: fps)
    }
}

/// 见 `Settings.renderInputs`。放在 `Settings` 外面是因为 `Engine` 要存一份
/// 上次生效的快照，而它不该持有第二个 `Settings` 引用。
struct RenderInputs: Equatable {
    let enabled: Bool
    let kind: EffectKind
    let period: Double
    let lo: Double
    let hi: Double
    /// `powerSaver` 的派生值。存 fps 而不是 powerSaver：引擎关心的是帧率本身，
    /// 将来「帧率按效果推导」落地时这里换个算法就行，比较逻辑一个字都不用动。
    let fps: Double
}
