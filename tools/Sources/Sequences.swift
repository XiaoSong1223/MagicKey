import Foundation

// 合成按键序列——喂给 `--analyze` 的确定性输入。
//
// `KeyPress.synthetic` 只敲一次，验证不了任何跟节奏有关的东西。
// `KeyRepeatFilter` 要证明两件事，各需要一组序列：
//
//   autorepeat  长按能锁上，锁上之后彻底安静
//   typing      快速打字不会被误判（尤其是连打同一个字母）
//
// 抖动必须是确定性的：同样的参数每次跑出同样的曲线，
// 分析结果才能当回归基准用。
enum PressSequence {

    /// 实测于开发机（MacBook Air M4 / macOS 26.5.1），`--probe` 采 331 次按下、
    /// 7 段自动重复、187 次人手按键得出。系统偏好里 KeyRepeat / InitialKeyRepeat
    /// 均未设置，所以这就是 macOS 26 的内建默认：5 tick 重复、30 tick 首次延迟。
    enum Measured {
        static let initialDelay = 0.500    // 首次重复延迟（7 段实测 500.1–506.9ms）
        static let interval     = 0.0836   // 重复间隔（7 段均值 83.33–83.77ms）

        /// 常态抖动（±）。注意这里要的是**相邻间隔之差**，不是「整段里偏离均值多少」——
        /// 后者（实测 ±0.73…±4.49ms）是一整段的极值，拿它当逐次抖动会把序列做得
        /// 比真实噪得多，抑制率会被低估近一半。实测相邻差绝大多数 <1ms。
        static let jitter       = 0.0012

        /// 偶发的投递离群：一次晚到、下一次就补回来，成对出现（实测 97.27 / 70.44）。
        /// 每约 20 次重复来一发，判定器会在这里断锁再重锁——这正是要让分析看见的。
        static let outlierEvery  = 20
        static let outlierAmount = 0.012

        static let typingJitter = 0.030    // 人类打字抖动（±）
    }

    /// 长按序列：按下 → 首次延迟 → 一串重复 → 松开 → 间歇 → 再来一次。
    /// 至少两轮，好让分析器同时覆盖「锁上」和「松手后解除」。
    static func autorepeat(holds: Int = 3, repeatsPerHold: Int = 30,
                           initialDelay: Double = Measured.initialDelay,
                           interval: Double = Measured.interval,
                           jitter: Double = Measured.jitter,
                           gap: Double = 1.0) -> [Double] {
        var rng = Rand(seed: 0x5EED)
        var t = 0.0
        var out: [Double] = []
        var sinceOutlier = 0
        for _ in 0..<holds {
            out.append(t)                                   // 真实按下
            t += initialDelay + rng.signed(jitter)
            var carry = 0.0                                 // 上一次离群要补回来的量
            for _ in 0..<repeatsPerHold {
                out.append(t)
                var step = interval + rng.signed(jitter) + carry
                carry = 0
                sinceOutlier += 1
                if sinceOutlier >= Measured.outlierEvery {
                    sinceOutlier = 0
                    step += Measured.outlierAmount
                    carry = -Measured.outlierAmount         // 下一次早到，总时长不变
                }
                t += step
            }
            t += gap                                        // 松手
        }
        return out
    }

    /// 快速打字：约 8 键/秒并带人类抖动，中间穿插连打同一个字母的短促突发——
    /// 那是人最可能凑出两个相等间隔的地方，误判如果存在就该在这里出现。
    static func typing(count: Int = 60,
                       interval: Double = 0.125,
                       jitter: Double = Measured.typingJitter) -> [Double] {
        var rng = Rand(seed: 0xBEEF)
        var t = 0.0
        var out: [Double] = []
        for i in 0..<count {
            out.append(t)
            // 每 10 键来一次三连打（60ms 级），其余按正常节奏
            let burst = (i % 10) >= 7
            let base = burst ? 0.060 : interval
            t += Swift.max(0.02, base + rng.signed(burst ? jitter * 0.4 : jitter))
        }
        return out
    }

    /// 确定性伪随机。绝不能用 `Double.random`——分析结果必须可复现。
    private struct Rand {
        private var s: UInt64
        init(seed: UInt64) { s = seed }
        private mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(UInt64(1) << 53)
        }
        mutating func signed(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude }
    }
}
