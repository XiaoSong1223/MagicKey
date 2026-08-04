import Foundation

// 效果曲线分析器（`--analyze`）
//
// 不碰硬件，纯计算。复用运行时真正的 Effect 与 Perceptual，
// 所以分析结果不可能和实际渲染漂移——这正是不做成独立脚本的原因。
//
// 回答两个问题：
//   1. 有没有可察觉的卡顿？（单档停留 >100ms，阈值由实机观察反推）
//   2. 需要多少 fps？（帧率不够会丢档，动作变粗）

enum Analyzer {

    /// 远高于任何实际帧率，用于求出档位切换的真实时刻
    private static let sampleHz = 20_000.0

    /// 实测得出：单档停留超过约 100ms 肉眼即可察觉为卡顿
    private static let stallThreshold = 0.100

    struct Segment {
        let start: Double
        let dwell: Double
        let level: Int
    }

    static func run(effect: Effect, opts: Options) {
        let period = opts.period
        var segments: [Segment] = []
        var lastLevel = -1
        var segStart = 0.0

        let n = Int(period * sampleHz)
        for i in 0...n {
            let t = Double(i) / sampleHz
            let ctx = FrameContext(time: t, frame: UInt64(i), base: opts.hi)
            guard let perceptual = effect.tick(ctx) else { continue }
            let physical = Perceptual.toPhysical(perceptual, gamma: opts.gamma)
            let level = Int((min(max(physical, 0), 1) * 255).rounded())

            if level != lastLevel {
                if lastLevel >= 0 {
                    segments.append(Segment(start: segStart, dwell: t - segStart, level: lastLevel))
                }
                lastLevel = level
                segStart = t
            }
        }
        if lastLevel >= 0 {
            segments.append(Segment(start: segStart, dwell: period - segStart, level: lastLevel))
        }

        guard segments.count > 1 else {
            print("效果 \(effect.name) 在一个周期内只有 1 个档位（静态），无需分析。")
            return
        }

        let dwells = segments.map(\.dwell).sorted()
        let levels = segments.map(\.level)
        let minDwell = dwells.first!
        let maxDwell = dwells.last!
        let medDwell = dwells[dwells.count / 2]
        let stalls = segments.filter { $0.dwell > stallThreshold }
                             .sorted { $0.dwell > $1.dwell }

        print("""

        ══════════ 效果曲线分析 ══════════
        效果            \(effect.name)
        周期            \(period) s
        亮度范围        \(opts.lo) … \(opts.hi)
        gamma           \(opts.gamma)\(opts.gamma == 1.0 ? " (关闭)" : "")

        ── 档位使用 ──────────────────────
        档位切换次数    \(segments.count) / 周期
        实际档位范围    \(levels.min()!) – \(levels.max()!) / 255
        可用档位利用率  \(String(format: "%.1f", Double(Set(levels).count) / 256 * 100)) %

        ── 停留时长 ──────────────────────
        最短            \(String(format: "%6.1f", minDwell * 1000)) ms
        中位            \(String(format: "%6.1f", medDwell * 1000)) ms
        最长            \(String(format: "%6.1f", maxDwell * 1000)) ms
        """)

        let punctuated = effect.motionIntent == .punctuated
        if punctuated {
            print("""

            ⓘ 该效果声明为 punctuated（含设计内的突变或保持）。
              下面两项判据是为 smooth 类效果（呼吸等渐变）设计的，
              对它只作描述性参考，不给结论——频闪的瞬间跳变、心跳的搏动间静息
              都是本意，不是缺陷。
            """)
        }

        // 1. 卡顿检查
        print("\n── \(punctuated ? "长时间保持" : "卡顿检查（阈值 \(Int(stallThreshold * 1000))ms）")────────")
        if stalls.isEmpty {
            print(punctuated ? "无超过 \(Int(stallThreshold * 1000))ms 的保持段" : "✅ 无可察觉卡顿")
        } else {
            print(punctuated ? "\(stalls.count) 处 >\(Int(stallThreshold * 1000))ms 的保持段（可能是设计内的）："
                             : "⚠️  \(stalls.count) 处可察觉卡顿：")
            for s in stalls.prefix(5) {
                let phase = s.start / period
                let where_ = phase < 0.5 ? "上升段" : "下降段"
                print(String(format: "   t=%5.2fs (%@)  档位 %3d  停留 %5.1f ms",
                             s.start, where_, s.level, s.dwell * 1000))
            }
            if stalls.count > 5 { print("   …还有 \(stalls.count - 5) 处") }
            if levels.contains(0) {
                let off = segments.filter { $0.level == 0 }.map(\.dwell).reduce(0, +)
                print(String(format: "   ⚠️  每周期完全熄灭 %.0f ms", off * 1000))
            }
        }

        // 2. 帧率需求
        //
        // 判据是**相对**亮度步进，不是跳过了多少档。
        // 韦伯定律：亮度差异的可察觉程度正比于相对变化量。曲线最陡处必然跳档，
        // 但在高亮度区跳 3 档只是 2% 的变化，眼睛分辨不出；
        // 在档位 2 附近跳 3 档却是 150% 的变化，一眼可见。
        // 所以「丢档比例」不是感知指标，最大相对步进才是。
        print("\n── 帧率需求 ────────────────────")
        print(String(format: "档位切换最快处   %.1f ms/档（= %.0f fps 才能不丢档，仅供参考）",
                     minDwell * 1000, ceil(1.0 / minDwell)))
        print("\n   fps   最大相对步进   出现位置    评价")

        for fps in [30.0, 60.0, 90.0, 120.0] {
            var worstRel = 0.0
            var worstAt = 0
            var worstJump = 0
            var prev = -1
            for i in 0..<Int(period * fps) {
                let t = Double(i) / fps
                let ctx = FrameContext(time: t, frame: UInt64(i), base: opts.hi)
                guard let p = effect.tick(ctx) else { continue }
                let level = Int((min(max(Perceptual.toPhysical(p, gamma: opts.gamma), 0), 1) * 255).rounded())
                if prev >= 0 {
                    let jump = abs(level - prev)
                    // 相对于较暗的一端——那才是感知基准
                    let rel = Double(jump) / Double(Swift.max(Swift.min(level, prev), 1))
                    if rel > worstRel { worstRel = rel; worstAt = Swift.min(level, prev); worstJump = jump }
                }
                prev = level
            }
            let verdict: String
            if punctuated {
                verdict = "—"
            } else {
                switch worstRel {
                case ..<0.05:  verdict = "✅ 平滑"
                case ..<0.20:  verdict = "⚠️  边缘可见"
                default:       verdict = "❌ 可见跳变"
                }
            }
            print(String(format: "  %4.0f      %6.1f %%      档%3d 跳%2d    %@",
                         fps, worstRel * 100, worstAt, worstJump, verdict))
        }
        print("""

        注：最大相对步进恒定出现在最暗档位附近——那里 1 档就是很大的相对变化。
            提高亮度下限（--min）比提高帧率更能改善低端观感。

        ════════════════════════════════

        """)
    }
}
