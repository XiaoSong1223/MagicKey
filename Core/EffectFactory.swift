import Foundation

// 「参数 → Effect」这一层。
//
// **为什么它必须在 Core 里。** 这段代码曾经有两份：`Settings.makeEffect()` 一份、
// `magickey-tool` 的 `makeEffect(_:)` 一份。它们漂了，而且漂得很难发现——
// 工具那份**压根没有 audiobeat 分支**（unknown 一律落回 breathe），
// 于是「音乐律动」的曲线从上线到现在从来没有过一次 `--analyze`，
// 谁也不知道它在 255 档硬件地板上是什么样子。
//
// CLAUDE.md 早就写着「分析工具必须复用 Core 里真正的 Effect，否则分析结果会开始骗人」。
// 上一版复用了 `Effect`，但没复用**「参数怎么变成 Effect」**——而漂移正好发生在那一层。
// 所以判据要收紧一格：**app 和工具必须走同一个 `EffectFactory.make`。**

/// 效果的身份。
///
/// **只放身份、取值范围和运动语义**——显示名、SF Symbol、面板说明那些是界面的事，
/// 由 app 侧的扩展补（`app/Sources/Settings.swift`）。Core 不该知道自己被谁用。
enum EffectKind: String, CaseIterable, Identifiable {
    case staticLevel = "static"
    case breathe
    case heartbeat
    case strobe
    case keyPulse = "keypulse"
    case audioBeat = "audiobeat"

    var id: String { rawValue }

    /// 事件驱动的脉冲类效果。
    ///
    /// 这两个和上面四个是两种东西，很多地方要分开处理：
    /// 「周期」的语义是**单次脉冲时长**而不是循环周期；亮度上下限的语义是
    /// 「静息 / 峰值」而不是「最暗 / 最亮」；帧率也不能按曲线陡峭程度推导
    /// （静息时理论上 0Hz，来一次事件就要 60Hz）。
    var isPulse: Bool { self == .keyPulse || self == .audioBeat }

    /// 各效果合适的周期范围（秒）
    var periodRange: ClosedRange<Double> {
        switch self {
        case .staticLevel: return 1...1
        case .breathe:     return 1...20
        case .heartbeat:   return 0.6...3
        case .strobe:      return 0.1...2
        case .keyPulse:    return 0.15...1.5
        case .audioBeat:   return 0.15...1.5
        }
    }

    var defaultPeriod: Double {
        switch self {
        case .staticLevel: return 1
        case .breathe:     return 4
        case .heartbeat:   return 1.2
        case .strobe:      return 0.5
        case .keyPulse:    return 0.4
        case .audioBeat:   return 0.35
        }
    }
}

/// 脉冲从哪来。非脉冲效果忽略这一项。
enum PulseSourcePolicy {
    /// 真实来源：keypulse 读键盘按下计数（零权限），audiobeat 接系统音频
    /// （顺带把采集拉起来，见 `BeatPulseSource.activate`）。
    case live
    /// 按一张确定性时刻表重放，`--analyze` 专用。
    /// 不读时钟、不用随机数——分析的全部价值就在于同样的输入每次跑出同样的曲线。
    case synthetic(times: [TimeInterval])
}

/// 造一个效果需要的全部输入。**值类型**：工厂不该拿着 `Settings` 那种活对象，
/// 那会让「这次到底用的是哪一组参数」变得不可复现。
struct EffectSpec {
    var kind: EffectKind
    /// 循环周期；脉冲类效果是单次脉冲总时长
    var period: Double
    var lo: Float
    var hi: Float
    var pulses: PulseSourcePolicy = .live
    /// 键盘自动重复过滤。nil = 按 kind 取默认，见 `EffectFactory.defaultFilterRepeats`。
    /// 只有 `--no-repeat-filter` 那个真机 A/B 开关会显式传 false。
    var filterRepeats: Bool?

    init(kind: EffectKind, period: Double, lo: Float, hi: Float,
         pulses: PulseSourcePolicy = .live, filterRepeats: Bool? = nil) {
        self.kind = kind
        self.period = period
        self.lo = lo
        self.hi = hi
        self.pulses = pulses
        self.filterRepeats = filterRepeats
    }
}

enum EffectFactory {

    static func make(_ spec: EffectSpec) -> Effect {
        switch spec.kind {
        case .staticLevel:
            return StaticEffect(level: spec.hi)
        case .breathe:
            return BreatheEffect(period: spec.period, min: spec.lo, max: spec.hi)
        case .heartbeat:
            return HeartbeatEffect(period: spec.period, min: spec.lo, max: spec.hi)
        case .strobe:
            return StrobeEffect(period: spec.period, min: spec.lo, max: spec.hi)
        case .keyPulse, .audioBeat:
            // 名字直接用 rawValue，所以 `--analyze` 的抬头和设置里存的值天然一致，
            // 不会出现「面板说 audiobeat、分析报告说 pulse」这种对不上。
            return PulseEffect(duration: spec.period, min: spec.lo, max: spec.hi,
                               source: pulseSource(spec),
                               filterRepeats: spec.filterRepeats
                                   ?? defaultFilterRepeats(spec.kind),
                               name: spec.kind.rawValue)
        }
    }

    /// ⚠️ **audiobeat 必须是 false。** `KeyRepeatFilter` 的判据是
    /// 「连续两个间隔几乎相等 = 自动重复」，而音乐的鼓点**本来就是等间隔**——
    /// 开着的话一首 120BPM 的歌前三拍之后就再也不闪了。
    ///
    /// 这条以前散在两个调用点上（app 传 false、工具传 `o.repeatFilter`），
    /// 工具那份还恰好没有 audiobeat 分支所以从没生效过。收进来一次写死。
    private static func defaultFilterRepeats(_ kind: EffectKind) -> Bool {
        kind == .keyPulse
    }

    private static func pulseSource(_ spec: EffectSpec) -> PulseSource {
        switch spec.pulses {
        case .live:
            guard spec.kind == .audioBeat else { return KeyboardPulseSource() }
            // tap 的启停不在这里做生命周期管理：它比效果活得久（重建要 1.8–4.6 秒），
            // 停止由「没人 drain 就自停」的看门狗负责。见 `BeatPulseSource` 类注释。
            let src = BeatPulseSource.shared
            src.activate()
            return src

        case .synthetic(let times):
            // `collapsePerDrain` 要照着**被模拟的那个真实源**给，不能随手选：
            // 键盘源只知道最近一次按下的时刻（`secondsSinceLastEventType` 就给这一个），
            // 而音频 tap 拿得到每个鼓点的采样级时刻。分析器要是比真实源更精确，
            // 报出来的抑制率就是假的——「分析工具开始骗人」是这个项目最贵的坑之一。
            return SyntheticPulseSource(times: times,
                                        collapsePerDrain: spec.kind == .keyPulse)
        }
    }
}
