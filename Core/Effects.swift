import Foundation

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
