import Foundation

/// 闪 N 下然后彻底消失。CLI / URL Scheme 的 `flash` 动词就是它。
///
/// ## 和 `PulseEffect` 的区别不是形状，是所有权
///
/// `PulseEffect` 是**基础层**：一直在，等着源头发事件，永远不结束。
/// `FlashEffect` 是**瞬时层**：播完 `tick` 返回 nil，`EffectStack` 把它扔掉，
/// 引擎回到原来在做的事。所以两者的静息值刻意不同：
///
///   - PulseEffect 静息回 `lo`——它是基础层，lo 就是它自己的静息亮度；
///   - FlashEffect 静息回 **0**——它的 blend 是 `.max`，而 `max(底色, 0) == 底色`，
///     等于「这一帧我不发言」。回 lo 会给底色垫一个地板，把呼吸的波谷抬平。
///
/// **两者别互相照抄这一条。**
///
/// ## 曲线
///
/// 照项目定律：起手 smoothstep（不留硬拐角），衰减用幂函数 `(1-u)^1.6`
/// ——**不用指数**，指数永远到不了 0，截断时会留下可见台阶。gamma 不碰。
///
/// 参数是对着 `--analyze` 定的，见 `Self.attack/decay/gap` 各自的注释。
/// 改任何一个之前先跑：`magickey-tool --analyze --effect flash --times 3`。
final class FlashEffect: Effect, TransientEffect {

    let name = "flash"
    let motionIntent = MotionIntent.punctuated
    /// **必须是 `.max`。** 协议默认是 `.replace`，那会把底色整个盖掉——
    /// 呼吸跑着的时候来一发 flash，用户会看到呼吸消失 0.76 秒再回来。
    let blend = BlendMode.max

    /// 一次冲亮的起手时间。40ms：60fps 下约 2.4 帧，够画出上升沿，
    /// 又短到和「命令发出」在感知上同时。
    static let attack: TimeInterval = 0.04
    /// 衰减。比 keypulse 的 0.36s 短得多——flash 要的是「啪、啪、啪」的干脆，
    /// 不是余韵。
    static let decay: TimeInterval = 0.16
    /// 两下之间的暗场。没有它，前一下的尾巴和后一下的起手会连成一个 V，
    /// 数不清到底闪了几下。
    ///
    /// **80ms 是被 255 档地板卡住的上限**：暗场期间亮度恒为 0 档，
    /// 而单档停留超过约 100ms 肉眼就是卡顿。实测整条曲线最长停留 84.2ms
    /// （= 暗场 80 + 前一下衰减尾部约 3.2 + 后一下起手头部约 1.0），
    /// 已经贴着门槛，**别再往上加**。
    static let gap: TimeInterval = 0.08

    /// 一下的完整周期
    static let cycle: TimeInterval = attack + decay + gap

    /// 闪几下。超出这个范围的请求会被钳住——`times=999` 多半是脚本写错了，
    /// 而不是真想让键盘闪五分钟。
    static let timesRange = 1...10

    /// 没指定次数时闪几下。3 下：一下容易被当成余光错觉，五下以上开始烦人。
    ///
    /// 放在 Core 而不是 `URLCommand` 旁边，因为 `magickey-tool` 也要用它
    /// （`--effect flash` 不带 `--times` 时），而工具不编译 app 那边的源码。
    static let defaultTimes = 3

    let times: Int
    let peak: Float

    /// 总时长。**末尾不留暗场**：最后一下的衰减落到 0 就结束，
    /// 拖一个空的 gap 只会让调用方多等 80ms。
    let duration: TimeInterval

    /// 已经播了多久。
    ///
    /// ⚠️ **用增量累加，不直接吃 `ctx.time`。** 渲染状态会被重建
    /// （用户在 flash 播到一半时改了个设置），重建后 `ctx.time` 从 0 重新起算。
    /// 直接用它的话 flash 会跳回开头重播，或者干脆判定为已结束。
    ///
    /// flash 是**一条命令**，不是一段时间函数——它的进度只属于它自己。
    private var elapsed: TimeInterval = 0
    private var lastTick: TimeInterval?

    /// - Parameters:
    ///   - times: 闪几下，自动钳进 `timesRange`
    ///   - peak: 峰值亮度。默认满亮——通知类的闪光要压得住底色才看得见。
    ///     底色本来就在 1.0 时这一下会不明显，那是硬件只有一路全局亮度的直接后果，
    ///     不是这里能解决的（往下闪会和「别打穿底色」冲突）。
    init(times: Int, peak: Float = 1.0) {
        let n = Swift.min(Swift.max(times, Self.timesRange.lowerBound),
                          Self.timesRange.upperBound)
        self.times = n
        self.peak = Swift.min(Swift.max(peak, 0), 1)
        self.duration = Double(n) * Self.cycle - Self.gap
    }

    func tick(_ ctx: FrameContext) -> Float? {
        if let last = lastTick {
            // 负增量 = 时间基准换了（渲染状态被重建）。跳过这一帧，绝不倒退——
            // 代价是丢掉一帧的进度（16.7ms），比整个重播或提前结束便宜得多。
            elapsed += Swift.max(0, ctx.time - last)
        }
        lastTick = ctx.time
        guard elapsed < duration else { return nil }   // nil = 播完，出栈
        return peak * envelope(elapsed)
    }

    private func envelope(_ t: TimeInterval) -> Float {
        let i = Int(t / Self.cycle)
        guard i < times else { return 0 }
        let u = t - Double(i) * Self.cycle

        if u < Self.attack {
            let x = u / Self.attack
            return Float(x * x * (3 - 2 * x))          // smoothstep
        }
        let d = u - Self.attack
        guard d < Self.decay else { return 0 }         // 暗场：让出通道
        return Float(pow(1 - d / Self.decay, 1.6))     // 幂函数，精确落到 0
    }
}
