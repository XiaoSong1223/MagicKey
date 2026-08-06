import Foundation

/// 低频起音检测：从音频样本里认出「鼓点来了」。
///
/// 为什么是起音而不是响度跟随：现代母带做过重限幅，整曲 RMS 方差极小，
/// 拿它直接驱动亮度会得到一条几乎不动的亮线，看起来像坏了。
/// 而鼓点是离散事件，正好对得上已经磨好的脉冲包络（`PulseEffect`）——
/// 「什么时候亮」和「怎么亮」是两件事，后者早就做完了。
///
/// **为什么不上 FFT**：512 点 FFT 用 vDSP 完全跑得动，但它给的是整个频谱，
/// 而这里只需要「底鼓来了没有」一个布尔值加一个强度。多出来的频谱信息
/// 全都得靠调参才能变回那个布尔值，等于凭空多出一堆旋钮。
///
/// 全部状态都在结构体里，逐样本推进，不读时钟、不分配内存——
/// 因此既能在音频实时线程上跑，也能离线以任意速度重放同一段音频得到同样结果。
/// 后者是定参的前提：`--probe-audio --file` 一秒能扫几百组参数，
/// 而实时跑一遍要一分钟。
struct OnsetDetector {

    struct Params {
        /// 低通截止。底鼓基频通常 40–100Hz，150 能把人声吉他和 hi-hat 滤掉，
        /// 又不至于把军鼓的低频体完全砍没。
        var cutoffHz: Double = 150

        /// 包络跟随：attack 要快（起音是瞬态，慢了就抹平了），release 要慢
        /// （否则包络在鼓点尾巴里反复穿越阈值，一次敲击报好几个起音）。
        var attackMs: Double = 3
        var releaseMs: Double = 90

        /// 滑动均值的时间常数，自适应阈值的基准。
        /// 太短会被鼓点自己抬起来（阈值追着信号跑，永远触发不了），
        /// 太长则跟不上段落之间的响度变化。
        var avgMs: Double = 500

        /// 触发判据：包络 > threshold × 滑动均值。
        /// **必须是相对量**：不同曲目的母带响度能差十几 dB，
        /// 同一个绝对阈值在重限幅的流行乐上一直触发，在古典乐上一次都不触发。
        ///
        /// 默认 1.35 是**盯着真实键盘定的，不是算出来的**。合成鼓点上
        /// 1.3–3.5 的每一个值都是 100% 命中 0 误报（信号太干净，判据没有区分度），
        /// 而同一组参数在真实音乐上漏掉一半以上的拍子：
        ///   1.15 → 2.6 次/秒   1.30 → 1.6   1.50 → 1.1   1.80 → 0.8（明显漏拍）
        /// 检出率只能证明「数量对了」，证明不了「闪在拍子上」——
        /// 后者没有任何离线判据，只能看。
        var threshold: Float = 1.35

        /// 不应期。500 BPM 以上不是音乐，是同一次敲击被拆成了好几个。
        var refractoryMs: Double = 110

        /// 重新武装的门限（× 滑动均值），必须低于 `threshold`。
        ///
        /// **这一条是被标准答案逼出来的。** 最初的判据是「包络高于阈值就触发」，
        /// 合成鼓点上每个底鼓都报两次，第二次正好晚一个不应期——因为底鼓包络
        /// 在阈值之上停留的时间比不应期长，不应期一到就立刻又满足条件。
        /// 要的是**上升沿**（穿过阈值）而不是**上方区域**（高于阈值）。
        ///
        /// 加长不应期治不了：那会连快节奏鼓点一起打死，而且长到多少才够
        /// 取决于曲子，等于把一个确定性问题变成调参问题。
        var rearmFactor: Float = 1.1

        /// 静音下限。低于它一律不触发——否则安静段落里滑动均值趋近 0，
        /// 任何一点底噪都能满足「> threshold 倍均值」。
        var floor: Float = 2e-4

        /// 强度归一化用的峰值保持衰减时间。强度 = 包络 / 近期峰值，
        /// 所以整曲变轻时脉冲不会跟着一起变暗到看不见。
        var peakDecayMs: Double = 3000
    }

    private let p: Params
    private let sampleRate: Double

    // 二阶低通（RBJ cookbook）的系数与状态
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    // 一阶跟随器的系数（每样本乘性衰减）
    private let attackCoef, releaseCoef, avgCoef, peakCoef: Float

    private var env: Float = 0
    private var avg: Float = 0
    private var peak: Float = 0
    private var samplesSinceOnset: Int = .max
    private let refractorySamples: Int

    /// 是否允许下一次触发。上电即武装，触发后解除，包络掉回 `rearmFactor × avg` 以下才恢复。
    private var armed = true

    /// 纯诊断。`--probe-audio --dump` 把这几条导成 CSV——
    /// 数字看不出问题的时候画成曲线往往一眼就看出来（阈值线是不是被鼓点自己抬起来了、
    /// 安静段落里包络有没有贴着阈值反复穿越）。
    private(set) var processed: Int = 0
    var debugEnv: Float { env }
    var debugAvg: Float { avg }
    var debugPeak: Float { peak }

    init(sampleRate: Double, params: Params = Params()) {
        self.p = params
        self.sampleRate = sampleRate

        // RBJ 低通，Q = 1/√2（Butterworth，无过冲）
        let w0 = 2 * Double.pi * min(params.cutoffHz, sampleRate / 2 - 1) / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * 0.70710678)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0)
        b1 = Float((1 - cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)

        func coef(_ ms: Double) -> Float {
            ms <= 0 ? 0 : Float(exp(-1.0 / (ms / 1000 * sampleRate)))
        }
        attackCoef  = coef(params.attackMs)
        releaseCoef = coef(params.releaseMs)
        avgCoef     = coef(params.avgMs)
        peakCoef    = coef(params.peakDecayMs)
        refractorySamples = Int(params.refractoryMs / 1000 * sampleRate)
    }

    /// 一次起音。`offset` 是相对本次调用所传缓冲区起点的样本数——
    /// 换算成时间就是采样级精度的发生时刻，比帧（16.7ms）细三个数量级。
    struct Onset {
        let offset: Int
        let strength: Float
    }

    /// 逐样本推进。不分配内存，可在音频实时线程上调用。
    mutating func process(_ x: UnsafePointer<Float>, count n: Int, into out: inout [Onset]) {
        out.removeAll(keepingCapacity: true)
        for i in 0..<n {
            let s = x[i]

            // 低通
            let y = b0 * s + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = s
            y2 = y1; y1 = y

            // 整流 + 快攻慢放跟随
            let mag = abs(y)
            let c = mag > env ? attackCoef : releaseCoef
            env = mag + (env - mag) * c

            // 滑动均值与近期峰值
            avg = env + (avg - env) * avgCoef
            peak = env > peak ? env : env + (peak - env) * peakCoef

            if samplesSinceOnset < Int.max { samplesSinceOnset += 1 }

            // 掉回重新武装门限以下才允许下一次触发。少了这一步，
            // 判据就从「上升沿」退化成「上方区域」，一次敲击会按不应期的节奏
            // 反复报（合成鼓点实测：32 个底鼓报成 48 个）。
            if !armed, env < p.rearmFactor * avg { armed = true }

            // 触发：武装状态、超过自适应阈值、高于静音下限、且过了不应期
            if armed,
               env > p.floor,
               env > p.threshold * avg,
               samplesSinceOnset >= refractorySamples {
                samplesSinceOnset = 0
                armed = false
                let strength = peak > 0 ? Swift.min(1, Swift.max(0, env / peak)) : 0
                out.append(Onset(offset: i, strength: strength))
            }
        }
        processed += n
    }
}
