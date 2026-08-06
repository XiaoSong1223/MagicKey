import Foundation
import CoreGraphics

/// 一次脉冲事件。
///
/// - `secondsAgo`：相对 `drain()` **调用时刻**已经过去了多少秒。
///   用「多久之前」而不是绝对时刻，是为了不把音频线程的时间基准
///   （host time）泄漏到效果层——效果只认自己的 `ctx.time`。
///   这个量必须是亚帧精度的：按键/鼓点都发生在帧与帧之间，
///   量化到帧边界会让上升沿起点抖动（实测采样峰值 0.844 vs 0.815）。
/// - `strength`：0…1。按键恒为 1；鼓点按力度给，弱拍暗、重拍亮。
struct Pulse {
    let secondsAgo: TimeInterval
    let strength: Float
}

/// 脉冲的来源。渲染线程每帧调用一次 `drain()`，取走自上次调用以来的**全部**新脉冲。
///
/// **为什么是「取走增量」而不是「读当前值再比较」**：
/// 旧的 `KeyPulseEffect` 靠「距上次按键的秒数相对上一帧是否回落」判断有没有新按键。
/// 当事件间隔比帧长**稍短**时，该值每帧都在递增，下降沿永不出现，事件全漏——
/// 30fps 撞上系统最快按键重复率（33ms）正好踩中，实测 60 次只检出 1 次。
/// 见 CLAUDE.md「架构上的待办」第一条。
///
/// `drain()` 语义上不可能漏：实现方各自维护单调计数，两次调用之间发生了几次就返回几个。
///
/// 实现方需自行保证线程安全——`BeatPulseSource` 会被音频实时线程写、渲染线程读。
protocol PulseSource: AnyObject {
    /// 取走自上次调用以来的新脉冲。没有新事件时返回空数组。
    ///
    /// 由渲染线程调用，每帧一次。实现里**不得阻塞**，也不得做重量级分配。
    func drain() -> [Pulse]
}

/// 时间由外部驱动的脉冲源。`PulseEffect` 每帧在 `drain()` 之前调一次 `advance(to:)`。
///
/// 为什么要有这个：`secondsAgo` 是相对「drain 调用时刻」的，真实源（键盘、音频）
/// 读系统时钟就知道那是几点，合成源没有时钟可读——而且**也不能有**。
/// `--analyze` 要把同一条时间轴从 0 重放好几轮（20kHz 一轮 + 每个候选帧率各一轮），
/// 全都远快于实时；挂在系统时钟上跑出来的曲线既不确定也没法当回归基准。
/// 于是唯一的时间来源只能是效果自己的 `ctx.time`，由 `PulseEffect` 推给它。
///
/// 真实源不实现这个协议，`PulseEffect` 里那次 `as?` 转换就是 nil，没有额外开销。
protocol TimedPulseSource: PulseSource {
    func advance(to time: TimeInterval)
}

// MARK: - 键盘

/// 键盘按下 → 强度恒为 1.0 的脉冲。
///
/// **零权限。** 用到的两个 `CGEventSource` 类方法都是公开 API，只回答
/// 「按了几次」和「距上次多久」，不给按键内容，不弹授权框——`IdleMonitor`
/// 早就在用同一套调用做空闲检测。实测开销 p99 0.04µs（60fps 下占帧预算 0.0002%）。
/// 代价是拿不到「按了哪个键」，而硬件只有一路全局亮度，这个信息本来也无处可用。
/// 想按键位过滤（禁掉 Delete/回车）就得上 `CGEventTap`，那才需要输入监控权限，
/// 已论证并推迟，见 CLAUDE.md v0.2——不要再重新论证一遍。
///
/// **为什么用单调计数而不是「距上次按键的秒数相对上一帧是否回落」**：
/// 回落判据在事件间隔比帧长**稍短**时彻底失效——该值每帧递增（增量 = 帧长 − 间隔），
/// 下降沿永远不出现，事件整段漏掉。30fps（33.3ms）撞上系统最快重复率（33ms）
/// 正好踩中，实测 60 次只检出 1 次。计数是单调的，两次 drain 之间变没变一目了然，
/// 不存在这个盲区。
///
/// 只由渲染队列调用，因此不加锁——计数差要求单一调用者，两个线程各 drain 一半
/// 会互相吃掉对方的增量。
final class KeyboardPulseSource: PulseSource {

    /// 上次 drain 时的按下总数。构造时就取，所以「构造之前发生的按键」不算数：
    /// 那不属于「自上次调用以来」。
    ///
    /// 顺带修掉一个旧实现的副作用：旧 `KeyPulseEffect` 的 `lastIdle` 初值是
    /// `.infinity`，第一帧的回落判据无条件成立，等于把「上一次按键」当成刚发生的，
    /// 若那次按键正好在 0.4s 以内，切到 keypulse 的瞬间会看到半截衰减尾巴。
    /// 那是实现漏出来的，不是设计，不复现。
    private var lastCount: UInt32

    init() { lastCount = Self.pressCount() }

    func drain() -> [Pulse] {
        let now = Self.pressCount()
        // 只问「变了没有」，所以 UInt32 回绕（约 43 亿次按下）不需要特殊处理。
        guard now != lastCount else { return [] }
        lastCount = now

        // **一帧内按了 n 次也只发一个脉冲。** 计数差知道 n 是几，但
        // `secondsSinceLastEventType` 只给得出**最近那一次**的时刻，
        // 中间几次的时刻无从得知——按平均间隔铺开就是在编数据，不做。
        // 观感上不亏：相隔 16ms 的两次冲亮肉眼分不开，合成一个看不出来。
        // 亏的是节奏判定：`KeyRepeatFilter` 会看到忽 1 帧忽 2 帧的间隔，
        // 30fps 撞上 33ms 重复率时仍然锁不上，长按还是会偏亮。
        // 但那已经是「抑制不掉」而不是旧实现的「脉冲整段消失」，
        // 且 60fps 帧长 16.7ms 短于任何系统重复率，默认配置根本走不到这里。
        let ago = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown)
        // 时钟异常时给出负数会让效果把脉冲记到未来去，钳一下。
        return [Pulse(secondsAgo: Swift.max(ago, 0), strength: 1)]
    }

    private static func pressCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }
}

// MARK: - 合成

/// 按一张确定性的时刻表发脉冲。`--analyze` 专用，运行时不要用。
///
/// 分析的全部价值就在于「同样的参数每次跑出同样的曲线」，所以这里
/// 不读时钟、不用随机数，时间完全由 `advance(to:)` 喂。
final class SyntheticPulseSource: TimedPulseSource {

    private let times: [TimeInterval]
    private let strength: Float
    private let collapsePerDrain: Bool

    /// 下一个还没发出去的时刻
    private var cursor = 0
    private var now: TimeInterval = 0

    /// - Parameters:
    ///   - times: 脉冲发生时刻（秒，效果时间轴）。默认 `[0]` = 「t=0 敲一次」，
    ///     与重构前的 `KeyPress.synthetic` 完全等价，是包络曲线的回归基准输入。
    ///   - strength: 整条序列共用一个强度。目前分析只关心包络形状，
    ///     逐拍不同的力度等音频源接进来再说。
    ///   - collapsePerDrain: 一次 drain 内有多个时刻到期时，只发最近的那一个。
    ///     **默认 true，因为要模拟的是 `KeyboardPulseSource`**——它只知道最近一次的
    ///     时刻（原因见上）。分析器要是比真实源更精确，报出来的抑制率就是假的，
    ///     而「分析工具开始骗人」是这个项目踩过最贵的坑之一。
    ///     将来给音频源做分析时传 false：音频 tap 拿得到每个鼓点的采样级时刻，
    ///     不存在这个损失。
    init(times: [TimeInterval] = [0], strength: Float = 1, collapsePerDrain: Bool = true) {
        self.times = times.sorted()
        self.strength = strength
        self.collapsePerDrain = collapsePerDrain
    }

    func advance(to time: TimeInterval) {
        // 时间轴回退 = 分析器又从 0 开始重放了一轮，游标跟着回零，否则第二轮
        // 一个脉冲都不会发。`Analyzer.run` 收的是工厂、每轮现造，正常走不到这里；
        // 但「分析器复用同一个实例污染有状态效果」在这个项目里已经坑过一轮
        // （见 CLAUDE.md），自愈比留个陷阱便宜得多。
        if time < now { cursor = 0 }
        now = time
    }

    func drain() -> [Pulse] {
        let start = cursor
        while cursor < times.count, times[cursor] <= now { cursor += 1 }
        guard cursor > start else { return [] }
        let first = collapsePerDrain ? cursor - 1 : start
        return (first..<cursor).map { Pulse(secondsAgo: now - times[$0], strength: strength) }
    }
}
