import Foundation
import CoreGraphics

struct FrameContext {
    let time: TimeInterval      // 效果开始至今（秒）
    let frame: UInt64
    let base: Float             // 用户设定的基准亮度
}

enum BlendMode {
    case replace, max, add, multiply
}

/// 效果的运动意图。决定 `--analyze` 用哪套判据——
/// 对频闪来说瞬间跳变是本意，对呼吸来说是缺陷，同一个数值不能给同一个结论。
enum MotionIntent {
    case smooth       // 连续渐变：突变和长时间停留都算缺陷
    case punctuated   // 含设计内的突变或保持：心跳、频闪
}

/// 因为输出只有一个数，效果就是一个纯粹的时间函数。
/// 返回 nil 表示效果结束，可从效果栈中移除（瞬时效果用）。
protocol Effect: AnyObject {
    var name: String { get }
    var blend: BlendMode { get }
    var motionIntent: MotionIntent { get }
    func tick(_ ctx: FrameContext) -> Float?
}

extension Effect {
    var blend: BlendMode { .replace }
    var motionIntent: MotionIntent { .smooth }
}

// MARK: - 感知映射
//
// 结论（已实测，2026-08-03）：**默认关闭（gamma=1.0）。Apple 的 0–1 很可能已做过感知映射。**
//
// 最初默认 2.2，肉眼可见"亮度回升时卡住一瞬"。复现渲染管线逐帧算档位停留后定位到根因：
// 硬件只有 255 档，gamma 2.2 把呼吸最暗段压进了 0–1 档，几乎没有分辨率可用。
//
//   gamma  可用档位  档位范围   最长停留   每周期熄灭
//    2.2      89     0–178     167 ms     是（150ms）
//    1.8      95     1–190     133 ms     否
//    1.4     101     4–203     117 ms     否
//    1.0     107    13–217      83 ms     否   ← 三项全优
//
// 余弦在波谷导数为零，本就会有顿点；gamma 在低端再压一次斜率（d/dp = γ·p^(γ-1)，
// p=0.05 时仅 0.06），两个减速叠加才产生可见卡顿。
//
// 另一个信号：gamma 1.4 时最长停留已移到顶部（档 203），说明 1.0 往上就开始反向过校正。
//
// 试过把 gamma 施加到 wave 而非亮度值（physical = lo + (hi-lo)·wave^γ），
// 结果更差（367ms）——波谷被压得更平。已排除。
//
// 保留为可调参数，便于在其他机型上重新验证。
enum Perceptual {
    static func toPhysical(_ perceptual: Float, gamma: Float) -> Float {
        gamma == 1.0 ? perceptual : powf(min(max(perceptual, 0), 1), gamma)
    }
}

// MARK: - 基础层效果

final class StaticEffect: Effect {
    let name = "static"
    let motionIntent = MotionIntent.punctuated
    private let level: Float
    init(level: Float) { self.level = level }
    func tick(_ ctx: FrameContext) -> Float? { level }
}

/// 呼吸：余弦缓入缓出，在 min…max 之间往复。
final class BreatheEffect: Effect {
    let name = "breathe"
    private let period: Double
    private let lo: Float
    private let hi: Float

    init(period: Double, min lo: Float, max hi: Float) {
        self.period = Swift.max(period, 0.1)
        self.lo = lo
        self.hi = hi
    }

    func tick(_ ctx: FrameContext) -> Float? {
        let phase = (ctx.time.truncatingRemainder(dividingBy: period)) / period
        let wave = 0.5 - 0.5 * cos(2 * Double.pi * phase)   // 0…1
        return lo + (hi - lo) * Float(wave)
    }
}

/// 心跳：两次快脉冲后静息，模拟 lub-dub。
final class HeartbeatEffect: Effect {
    let name = "heartbeat"
    let motionIntent = MotionIntent.punctuated
    private let period: Double
    private let lo: Float
    private let hi: Float

    init(period: Double, min lo: Float, max hi: Float) {
        self.period = Swift.max(period, 0.4)
        self.lo = lo
        self.hi = hi
    }

    func tick(_ ctx: FrameContext) -> Float? {
        let t = ctx.time.truncatingRemainder(dividingBy: period)
        let pulse = { (center: Double, width: Double) -> Double in
            let d = abs(t - center)
            return d > width ? 0 : pow(cos(Double.pi * d / (2 * width)), 2)
        }
        let amp = Swift.max(pulse(0.10, 0.10), pulse(0.34, 0.13) * 0.75)
        return lo + (hi - lo) * Float(amp)
    }
}

/// 频闪：方波，用于压力测试写入路径。
final class StrobeEffect: Effect {
    let name = "strobe"
    let motionIntent = MotionIntent.punctuated
    private let period: Double
    private let duty: Double
    private let lo: Float
    private let hi: Float

    init(period: Double, duty: Double = 0.5, min lo: Float, max hi: Float) {
        self.period = Swift.max(period, 0.05)
        self.duty = duty
        self.lo = lo
        self.hi = hi
    }

    func tick(_ ctx: FrameContext) -> Float? {
        let phase = (ctx.time.truncatingRemainder(dividingBy: period)) / period
        return phase < duty ? hi : lo
    }
}

// MARK: - 按键脉冲
//
// 「按下某个键，光以它为中心向四周扩散」做不到，也不要再试：
// 全部 LED 共用一路 PWM，`setBrightness:forKeyboard:` 一块键盘只收一个 float
// （Driver.swift）。没有分区、没有单键地址，扩散所需的空间维度根本不存在。
//
// 能做的是它在时间域上的等价物：敲键的瞬间整块键盘冲亮，然后衰减回底色。
//
// **不需要输入监控权限。** `CGEventSource.secondsSinceLastEventType` 是公开 API，
// 只返回「距上次按键多少秒」，不给按键内容，不弹授权框——IdleMonitor 早就在用
// 同一个调用做空闲检测。代价是拿不到「按了哪个键」，
// 而硬件本来就只有一个全局亮度寄存器，这个信息也无处可用。限制和需求正好抵消。

/// 距上次按键的秒数。参数是效果时间轴上的当前时刻：
/// 系统实现用不到，合成实现（`--analyze` 需要确定性输入）需要。
///
/// 做成注入而非在效果里直接调 CGEventSource，是为了让 `--analyze` 能跑真正的
/// `KeyPulseEffect`——分析工具一旦另写一份曲线，就会开始骗人。
typealias KeyPressClock = (TimeInterval) -> TimeInterval

enum KeyPress {
    /// 真实按键。无需任何授权。
    static let system: KeyPressClock = { _ in
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// 合成：t=0 敲一次，此后一直空闲。
    /// 分析器会把 t 从 0 重放好几轮（每个候选帧率一轮），每轮都会重新触发，正合用。
    static let synthetic: KeyPressClock = { t in t }
}

/// 按键脉冲：每次敲键，整块键盘从 lo 冲到 hi 再衰减回 lo。
///
/// 包络形状受 255 档硬件地板约束（见本文件开头的 gamma 讨论）：
///   - attack 必须短到感觉不出延迟，但别短到只剩一帧，否则上升沿画不出来
///   - decay 用幂函数而不是指数：指数永远到不了 0，截断时会留下一个可见的台阶
final class KeyPulseEffect: Effect {
    let name = "keypulse"
    let motionIntent = MotionIntent.punctuated

    private let attack: Double
    private let decay: Double
    private let lo: Float
    private let hi: Float
    private let clock: KeyPressClock

    /// 仍在衰减中的按键时刻（效果时间轴）。连打时各自的包络取 max 叠成波浪。
    private var presses: [Double] = []
    private var lastIdle = Double.infinity

    private static let maxConcurrent = 16

    /// - Parameter duration: 单次脉冲的总时长（attack + decay）
    init(duration: Double, min lo: Float, max hi: Float, clock: @escaping KeyPressClock) {
        let d = Swift.max(duration, 0.1)
        // 40ms 起手：60fps 下约 2.4 帧，够画出上升沿，加上最多一帧的检测延迟
        // 仍在「和敲击同时发生」的感知范围内。
        self.attack = Swift.min(0.04, d * 0.2)
        self.decay = d - self.attack
        self.lo = lo
        self.hi = hi
        self.clock = clock
    }

    func tick(_ ctx: FrameContext) -> Float? {
        let idle = clock(ctx.time)

        // 空闲时间回落 = 上一帧之后有新按键。
        // 同一帧内按下多个键只记一次——相隔 16ms 的两次脉冲本来也分辨不出。
        if idle < lastIdle {
            // 减 idle 而不是直接用 ctx.time：按下的瞬间落在帧与帧之间，
            // 这样上升沿的起点是亚帧精度的，不会被量化到帧边界。
            presses.append(ctx.time - idle)
            if presses.count > Self.maxConcurrent { presses.removeFirst() }
        }
        lastIdle = idle

        let span = attack + decay
        presses.removeAll { ctx.time - $0 > span }

        var amp: Float = 0
        for p in presses { amp = Swift.max(amp, envelope(ctx.time - p)) }
        return lo + (hi - lo) * amp
    }

    private func envelope(_ t: Double) -> Float {
        guard t >= 0 else { return 0 }
        if t < attack {
            let u = t / attack
            return Float(u * u * (3 - 2 * u))       // smoothstep：起点不留硬拐角
        }
        let u = (t - attack) / decay
        guard u < 1 else { return 0 }
        return Float(pow(1 - u, 1.6))               // 离峰即走，接近 lo 时才慢下来
    }
}

// MARK: - 效果栈
//
// 基础层同时只有一个；瞬时层可叠加多个，播完自动出栈。
// 这样"呼吸的底色上，每次敲键闪一下"是天然支持的，不需要为组合写特例。
final class EffectStack {
    private(set) var base: Effect
    private var transients: [Effect] = []

    init(base: Effect) { self.base = base }

    func setBase(_ effect: Effect) { base = effect }
    func push(_ effect: Effect) { transients.append(effect) }

    func render(_ ctx: FrameContext) -> Float {
        var value = base.tick(ctx) ?? ctx.base

        if !transients.isEmpty {
            var survivors: [Effect] = []
            survivors.reserveCapacity(transients.count)
            for fx in transients {
                guard let v = fx.tick(ctx) else { continue }   // nil = 结束，出栈
                switch fx.blend {
                case .replace:  value = v
                case .max:      value = Swift.max(value, v)
                case .add:      value += v
                case .multiply: value *= v
                }
                survivors.append(fx)
            }
            transients = survivors
        }

        return min(max(value, 0), 1)
    }
}
