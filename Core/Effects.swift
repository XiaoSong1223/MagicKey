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

// MARK: - 脉冲效果（按键 / 鼓点共用）
//
// 「按下某个键，光以它为中心向四周扩散」做不到，也不要再试：
// 全部 LED 共用一路 PWM，`setBrightness:forKeyboard:` 一块键盘只收一个 float
// （Driver.swift）。没有分区、没有单键地址，扩散所需的空间维度根本不存在。
//
// 能做的是它在时间域上的等价物：事件发生的瞬间整块键盘冲亮，然后衰减回底色。
//
// 「事件」从哪来由 `PulseSource` 决定（Core/PulseSource.swift）——敲键、鼓点、
// 将来的 CLI 触发，对包络来说没有区别，都只是「多久之前发生了一次、有多强」。
// 拆成「源 + 包络」的唯一理由就是这个：下面那条曲线是拿 255 档硬件地板反复磨出来的
// （见文件开头 gamma 一节和 `envelope` 的注释），复制第二份出来必然漂移，
// 而漂移了没人会发现——观感差异要盯着键盘看很久才察觉得到。

/// 自动重复过滤器。
///
/// 按住一个键时内核按固定周期重复投递 keyDown（首次延迟约 0.4s，之后约 0.1s，
/// 两者都能在系统设置里调，重复间隔最快约 33ms）。`PulseEffect` 对尚未衰减完的
/// 包络取 max，0.4s 的脉冲撞上 0.1s 的重复率，任一时刻都有约 4 个包络在叠，
/// 最新那个永远刚过起手峰——幅度被钉在 0.79–1.0 之间以约 11Hz 抖动，
/// 按住多久就亮多久。这不是 Delete 特有的，按住任何键都一样。
///
/// 判据是**节奏规整度**，不是间隔长短：内核定时器的抖动在 1ms 量级，
/// 人类打字的抖动在几十 ms，连续两个间隔几乎完全相等是人产生不出来的。
/// 因此不依赖用户的重复速率设置（33ms–2s 全覆盖），也兼容 Karabiner
/// 之类自己产生重复的改键工具，更不需要读任何系统偏好。
///
/// 代价是锁定需要看见两个相等的间隔——真实按下之后还会放过两次重复
/// （默认设置下开头约 0.5s 的活动），之后按住多久都彻底安静。
/// 松手后的下一次按键间隔必然对不上，自动解除，不需要超时逻辑。
struct KeyRepeatFilter {

    /// 容差。**刻意是绝对值，不带相对项**——实测（`--probe`）表明相对项的缩放方向
    /// 正好是反的：自动重复间隔（本机 83.5ms）比人类打字间隔（150–200ms）**短**，
    /// 按比例给容差等于在人手那一侧放得更宽，误抑制不降反升。
    var tolerance: TimeInterval = 0.004

    /// 需要连续多少个「与前一个几乎相等」的间隔才锁定。
    /// 1 = 看到两个相等的间隔就抑制——实测误抑制率过高，人类打字里
    /// 偶尔就能凑出一对相差 2–3ms 的相邻间隔。要求连续两次则概率是平方级下降，
    /// 代价只是每次长按多放行一次重复（本机约 84ms）。
    var lockAfter = 2

    /// 纯诊断计数，给 `--analyze` 用。占空比看不出误抑制——被吞掉的那次按键
    /// 多半正落在前一次的包络里，曲线几乎不动，只有直接数才数得出来。
    private(set) var accepted = 0
    private(set) var suppressed = 0

    private var lastPress: TimeInterval?
    private var lastInterval: TimeInterval?
    private var matchRun = 0

    /// - Returns: true 表示这次按下应当触发脉冲
    mutating func accept(pressedAt t: TimeInterval) -> Bool {
        guard let prev = lastPress else {
            lastPress = t
            accepted += 1
            return true
        }
        let interval = t - prev
        lastPress = t

        // 时间轴回绕或乱序：清空节奏历史重新起算，绝不拿负间隔去比
        guard interval > 0 else {
            lastInterval = nil
            matchRun = 0
            accepted += 1
            return true
        }

        let matches = lastInterval.map { abs(interval - $0) <= tolerance } ?? false
        matchRun = matches ? matchRun + 1 : 0
        lastInterval = interval

        let repeated = matchRun >= lockAfter
        if repeated { suppressed += 1 } else { accepted += 1 }
        return !repeated
    }
}

/// 脉冲：每收到一次脉冲，整块键盘从 lo 冲到峰值再衰减回 lo。
///
/// 包络形状受 255 档硬件地板约束（见本文件开头的 gamma 讨论）：
///   - attack 必须短到感觉不出延迟，但别短到只剩一帧，否则上升沿画不出来
///   - decay 用幂函数而不是指数：指数永远到不了 0，截断时会留下一个可见的台阶
///
/// 改这条曲线之前先跑 `--analyze`。0.4s / 0.05…0.85 的基准是：
/// 409 次档位切换、档位 13–217、利用率 80.1%、最长单档停留 10.8ms。
/// 最长停留一旦逼近 100ms 就是肉眼可见的卡顿。
final class PulseEffect: Effect {
    let name: String
    let motionIntent = MotionIntent.punctuated

    private let attack: Double
    private let decay: Double
    private let lo: Float
    private let hi: Float
    private let source: PulseSource

    /// 合成源没有自己的时钟，得靠这里把效果时间推给它；真实源（键盘/音频）为 nil。
    private let timed: TimedPulseSource?

    /// 仍在衰减中的脉冲：效果时间轴上的发生时刻 + 强度。
    /// 连打时各自的包络取 max 叠成波浪。
    private var live: [(at: Double, strength: Float)] = []

    /// 长按时把自动重复挡在包络层之前。常开，`--no-repeat-filter` 只为真机 A/B 对比。
    ///
    /// ⚠️ 这是**键盘专用**的防御：判据是「连续两个间隔几乎相等」，
    /// 而音乐的鼓点恰恰就是相等间隔——给节拍源建 `PulseEffect` 必须传 false，
    /// 否则一首 120BPM 的歌前三拍之后就再也不闪了。
    private var repeats: KeyRepeatFilter?

    /// 诊断出口，`--analyze` 用来数误抑制。nil = 没开过滤。
    var repeatStats: (accepted: Int, suppressed: Int)? {
        repeats.map { ($0.accepted, $0.suppressed) }
    }

    private static let maxConcurrent = 16

    /// - Parameters:
    ///   - duration: 单次脉冲的总时长（attack + decay）
    ///   - source: 脉冲从哪来。键盘、鼓点、合成时刻表共用下面这一份包络
    ///   - filterRepeats: 键盘自动重复过滤，见 `repeats`。非键盘源必须关掉
    ///   - name: 只用于日志与 `--analyze` 的抬头。键盘脉冲传 "keypulse"
    init(duration: Double, min lo: Float, max hi: Float,
         source: PulseSource, filterRepeats: Bool = true, name: String = "pulse") {
        let d = Swift.max(duration, 0.1)
        self.repeats = filterRepeats ? KeyRepeatFilter() : nil
        // 40ms 起手：60fps 下约 2.4 帧，够画出上升沿，加上最多一帧的检测延迟
        // 仍在「和敲击同时发生」的感知范围内。
        self.attack = Swift.min(0.04, d * 0.2)
        self.decay = d - self.attack
        self.lo = lo
        self.hi = hi
        self.source = source
        self.timed = source as? TimedPulseSource
        self.name = name
    }

    func tick(_ ctx: FrameContext) -> Float? {
        // 合成源要先知道「现在几点」才知道有哪些脉冲到期了，见 TimedPulseSource。
        timed?.advance(to: ctx.time)

        // drain 取走的是**增量**，语义上不可能漏。这里不再有「相对上一帧回落」
        // 那种判据，也就不再有它的盲区（事件间隔比帧长稍短时下降沿永不出现，
        // 30fps 撞上 33ms 重复率实测 60 次只检出 1 次）。见 PulseSource.swift。
        for pulse in source.drain() {
            // 用「多久之前」换算回效果时间轴，而不是直接拿 ctx.time 当发生时刻：
            // 敲击/鼓点落在帧与帧之间，减掉 secondsAgo 后上升沿起点才是亚帧精度的
            // （实测采样峰值 0.844 vs 量化到帧边界的 0.815）。
            // 节奏判定同样吃这个精度——量化到帧边界的话，16.7ms 的量化噪声
            // 会盖过内核 1ms 量级的抖动，规整度就无从谈起。
            let at = ctx.time - pulse.secondsAgo
            guard repeats?.accept(pressedAt: at) ?? true else { continue }
            // 这里假定 drain 返回的是按时间递增的。万一不是，`KeyRepeatFilter`
            // 见到非正间隔会自己清空节奏历史（不会拿负间隔去比），包络取 max
            // 更是与顺序无关，所以最坏情况只是少抑制一次，不会算错。
            live.append((at, Swift.min(Swift.max(pulse.strength, 0), 1)))
            if live.count > Self.maxConcurrent { live.removeFirst() }
        }

        let span = attack + decay
        live.removeAll { ctx.time - $0.at > span }

        // strength 乘在**单个脉冲的包络上、取 max 之前**：
        //   ① 逐个乘才有意义——放到 max 外面等于让弱鼓点蹭上重鼓点的幅度；
        //   ② 乘的是包络的**幅度**不是时间轴。缩时间轴会连带改衰减时长，
        //      而 255 档下的停留分布是照现在这个形状调出来的，一动就得重跑 --analyze；
        //   ③ 乘在 lo…hi 的插值系数上，弱脉冲收敛回 lo（静息亮度）而不是 0——
        //      将来叠在呼吸底色上时才不会把底色打穿。
        // 键盘源恒为 1.0，而 IEEE-754 下 1.0 × x 精确等于 x，按键行为逐位不变。
        var amp: Float = 0
        for p in live { amp = Swift.max(amp, p.strength * envelope(ctx.time - p.at)) }
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
