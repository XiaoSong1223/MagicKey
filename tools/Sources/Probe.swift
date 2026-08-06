import Foundation
import CoreGraphics

// 按键节奏探针（`--probe`）
//
// 不碰硬件，不需要任何授权，只读 `CGEventSource.secondsSinceLastEventType`——
// 和 KeyPulseEffect 用的是同一个调用。
//
// 存在的唯一理由：`KeyRepeatFilter` 的容差 ε 必须夹在两个实测量之间，
// 而这两个量都只能在真人手上测：
//
//   下界 = 内核自动重复的抖动     —— ε 小于它，长按抑制不了
//   上界 = 人类打字所能达到的     —— ε 大于它，真实按键会被当成重复吞掉
//          最小「相邻间隔之差」
//
// 采样 1kHz，远高于渲染的 60Hz：这里要量的是自动重复本身的抖动，
// 不能让采样噪声混进去。按下时刻取 `now - idle`，和效果里一样是亚帧精度的。
enum Probe {

    private static let sampleHz = 1_000.0

    /// 把一段间隔认成自动重复的条件：**绝对**紧，且够长。
    ///
    /// 第一版用的是「彼此相差 20% 以内」，结果把人类打字（150–200ms、抖动 ±20ms）
    /// 整段归成了自动重复，于是报出「内核抖动 ±24.85ms」这种假下界，
    /// 进而得出「窗口不存在，方案要回炉」的假结论。相对阈值在这里是错的工具：
    /// 人手的间隔比自动重复**长**，20% 给出的绝对余量也就更大。
    private static let runMaxDeviation = 0.012   // 12ms，机器紧、人手松
    private static let minRunLength = 5

    private static var presses: [Double] = []
    private static var lastIdle = Double.infinity
    private static var started = Date()
    private static var finished = false

    static func run(duration: Double) {
        print("""

        ══════════ 按键节奏探针 ══════════

        请依次做这两件事（顺序无所谓，都要做）：

          1. 按住某个键不放 2–3 秒，松开。重复 4–5 次，换不同的键。
             → 量内核自动重复的间隔与抖动（ε 的下界）

          2. 正常打一段字，尽量打快，包括连续相同的字母（比如 aaa、lll）。
             → 量人类能达到的最小「相邻间隔之差」（ε 的上界）

        \(duration > 0 ? "\(Int(duration)) 秒后自动结束" : "完成后按 Ctrl-C 结束并出报告")

        ────────────────────────────────
        """)
        fflush(stdout)

        started = Date()
        let queue = DispatchQueue(label: "com.magickey.tool.probe", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / sampleHz, leeway: .microseconds(200))
        timer.setEventHandler { sample() }

        @Sendable func finish() {
            guard !finished else { return }
            finished = true
            timer.cancel()
            queue.sync {}
            report()
            exit(0)
        }

        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { finish() }
            src.resume()
            sources.append(src)
        }

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
        }

        timer.resume()
        RunLoop.main.run()
        _ = sources
    }

    private static func sample() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let now = Date().timeIntervalSince(started)
        defer { lastIdle = idle }
        guard idle < lastIdle else { return }
        guard lastIdle != .infinity else { return }   // 首帧那次下降沿是假的

        let at = now - idle
        presses.append(at)
        if presses.count > 1 {
            let gap = (at - presses[presses.count - 2]) * 1000
            print(String(format: "  #%-3d  间隔 %7.2f ms", presses.count, gap))
        } else {
            print(String(format: "  #%-3d  间隔       —", presses.count))
        }
        fflush(stdout)
    }

    // MARK: - 报告

    /// 一段自动重复：intervals 在 [from, to] 闭区间内（下标指向 intervals）
    private struct Run {
        let from: Int
        let to: Int
        let mean: Double
        let maxDeviation: Double
        var count: Int { to - from + 1 }
    }

    private static func report() {
        guard presses.count >= 2 else {
            print("\n采到 \(presses.count) 次按下，不足以分析。请重跑并按说明操作。\n")
            return
        }

        var intervals: [Double] = []
        for i in 1..<presses.count { intervals.append(presses[i] - presses[i - 1]) }

        let runs = detectRuns(intervals)
        var inRun = [Bool](repeating: false, count: intervals.count)
        for r in runs { for i in r.from...r.to { inRun[i] = true } }

        print("""

        ══════════ 探针报告 ══════════
        采样率          \(Int(sampleHz)) Hz
        按下次数        \(presses.count)
        间隔样本        \(intervals.count)
        """)

        // ── 自动重复
        print("\n── 自动重复段 ──────────────────")
        if runs.isEmpty {
            print("⚠️  没有识别出自动重复段。是不是没有按住键不放？")
        } else {
            for (n, r) in runs.enumerated() {
                let initial = r.from > 0 ? String(format: "%.1f ms", intervals[r.from - 1] * 1000)
                                         : "—（这段前面没有可用的间隔）"
                print(String(format: "  段%-2d  %2d 次重复   间隔均值 %6.2f ms   最大偏差 ±%.2f ms   首次延迟 %@",
                             n + 1, r.count, r.mean * 1000, r.maxDeviation * 1000, initial))
            }
            let allMean = runs.map(\.mean).reduce(0, +) / Double(runs.count)
            let worstDev = runs.map(\.maxDeviation).max() ?? 0
            print(String(format: "\n  合计   间隔均值 %.2f ms   最大抖动 ±%.2f ms   ← ε 的下界",
                         allMean * 1000, worstDev * 1000))
        }

        // ── 人类打字
        print("\n── 人类打字 ────────────────────")
        var closest = Double.infinity
        var closestPair = (0.0, 0.0)
        var pairs = 0
        for i in 1..<max(intervals.count, 1) where !inRun[i] && !inRun[i - 1] {
            pairs += 1
            let d = abs(intervals[i] - intervals[i - 1])
            if d < closest { closest = d; closestPair = (intervals[i - 1], intervals[i]) }
        }
        if pairs == 0 {
            print("⚠️  没有采到自动重复段之外的相邻间隔对。是不是没有正常打字？")
        } else {
            print("  相邻间隔对    \(pairs) 对")
            print(String(format: "  最接近的一次  %.2f ms 与 %.2f ms，相差 %.2f ms   ← ε 的上界",
                         closestPair.0 * 1000, closestPair.1 * 1000, closest * 1000))
        }

        // ── 样本是否够用。参数是从这批数据扫出来的，样本不够就等于在拿噪声定参数。
        print("\n── 样本量 ──────────────────────")
        let repeatPresses = runs.reduce(0) { $0 + $1.count }
        let humanPresses = presses.count - repeatPresses
        var enough = true
        if runs.count < 3 {
            print("⚠️  只有 \(runs.count) 段自动重复，至少要 3 段。请多按住几个不同的键各 2–3 秒。")
            enough = false
        }
        if humanPresses < 60 {
            print("⚠️  只有 \(humanPresses) 次人手按键，至少要 60 次。请正常打一段字，并夹杂连打同一字母。")
            enough = false
        }
        if enough { print("✅ 自动重复 \(runs.count) 段 / \(repeatPresses) 次，人手 \(humanPresses) 次，够用") }

        // ── 参数扫描
        if runs.isEmpty {
            print("\n没有识别出自动重复段，无法扫参数。")
        } else {
            var isRepeat = [Bool](repeating: false, count: presses.count)
            // intervals[i] 是 presses[i] → presses[i+1]，落在重复段里就说明 presses[i+1] 是重复按下
            for r in runs { for i in r.from...r.to { isRepeat[i + 1] = true } }
            sweep(presses: presses, repeatPress: isRepeat)
            if !enough {
                print("  ⚠️  样本不足，上面这张表只能当趋势看，不要拿来定最终参数。")
            }
        }
        print("\n════════════════════════════════\n")
    }

    /// 贪心找极大的「间隔彼此绝对接近」的连续段
    private static func detectRuns(_ intervals: [Double]) -> [Run] {
        var runs: [Run] = []
        var i = 0
        while i < intervals.count {
            var j = i
            var sum = intervals[i]
            while j + 1 < intervals.count {
                let mean = sum / Double(j - i + 1)
                guard abs(intervals[j + 1] - mean) <= runMaxDeviation else { break }
                j += 1
                sum += intervals[j]
            }
            let count = j - i + 1
            if count >= minRunLength {
                let mean = sum / Double(count)
                let dev = intervals[i...j].map { abs($0 - mean) }.max() ?? 0
                runs.append(Run(from: i, to: j, mean: mean, maxDeviation: dev))
            }
            i = j + 1
        }
        return runs
    }

    // MARK: - 参数扫描
    //
    // 拿采到的真实按下时刻直接回放 `KeyRepeatFilter`——用的是 Core 里那个真家伙，
    // 不是这里另写一份。理由和 `--analyze` 一样：一旦另写一份，改了过滤器忘了改探针，
    // 报出来的数就开始骗人。
    private static func sweep(presses: [Double], repeatPress: [Bool]) {
        print("\n── 参数扫描（回放真实按键）──────")
        print("  容差   需连续   误抑制(人手)      抑制率(重复)    长按放行数")
        print("  " + String(repeating: "─", count: 62))

        for lockAfter in [1, 2, 3] {
            for tol in [0.002, 0.003, 0.004, 0.006] {
                var filter = KeyRepeatFilter()
                filter.tolerance = tol
                filter.lockAfter = lockAfter

                var falseSuppress = 0, humanTotal = 0
                var trueSuppress = 0, repeatTotal = 0
                var leaked = 0, leaks: [Int] = []

                for (i, p) in presses.enumerated() {
                    let fired = filter.accept(pressedAt: p)
                    if repeatPress[i] {
                        repeatTotal += 1
                        if fired { leaked += 1 } else { trueSuppress += 1 }
                    } else {
                        humanTotal += 1
                        if !fired { falseSuppress += 1 }
                        if leaked > 0 { leaks.append(leaked); leaked = 0 }
                    }
                }
                if leaked > 0 { leaks.append(leaked) }

                let fpRate = humanTotal > 0 ? Double(falseSuppress) / Double(humanTotal) * 100 : 0
                let tpRate = repeatTotal > 0 ? Double(trueSuppress) / Double(repeatTotal) * 100 : 0
                let mark = fpRate == 0 && tpRate >= 90 ? " ✅" : ""
                print(String(format: "  %4.0fms  %5d    %3d/%-3d = %5.1f%%   %3d/%-3d = %5.1f%%   %@%@",
                             tol * 1000, lockAfter,
                             falseSuppress, humanTotal, fpRate,
                             trueSuppress, repeatTotal, tpRate,
                             leaks.isEmpty ? "—" : leaks.map(String.init).joined(separator: " "),
                             mark))
            }
            print("")
        }
        print("""
          误抑制 = 真实按键被当成自动重复吞掉，代价是那一下没有光，必须为 0
          抑制率 = 自动重复被挡住的比例，越高长按越安静
          放行数 = 每段长按里漏过去的重复次数，理想是「锁定前的那几下」而已
        """)
    }
}
