import Foundation
import AVFoundation

// 起音检测的定参工具（`--probe-audio`）
//
// 两种模式，分工明确：
//
//   --file <wav> [--truth <json>]   离线：全速重放文件，可扫参数、可对标准答案
//   --live [--seconds N]            实时：走真正的 AudioTap，验证管线通不通
//
// 为什么离线是主力：定参要试几百组参数，实时跑一遍 32 秒的曲子就要 32 秒，
// 而且每次的系统噪声都不一样，结果不可复现。离线重放同一段音频永远得到同样的
// 检出序列——这是「参数调好了」这句话能成立的前提。
//
// 为什么还需要实时：离线证明不了 AudioTap 能不能拿到音频、时间戳准不准、
// 实时线程上跑会不会爆。那是另一类风险，只能真跑。
//
// **有标准答案才敢说参数调好了。** 真实音乐里检出 37 个起音，其中几个是对的、
// 漏了几个，无从得知。项目里已经吃过一次亏：`--probe` 第一版用「彼此相差 20%
// 以内」认自动重复，把人类打字整段误判，报出「内核抖动 ±24.85ms」的假下界，
// 进而给出「方案要回炉」的假结论。没有标准答案时，判据本身错了你不会知道。

enum AudioProbe {

    // MARK: - 读文件

    /// 把任意格式的音频文件读成单声道 Float。多声道取平均——
    /// 和 `CATapDescription(monoGlobalTapButExcludeProcesses:)` 的 mono mixdown 一致。
    static func loadMono(_ path: String) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write("读不了音频文件: \(path)\n".data(using: .utf8)!)
            return nil
        }
        let fmt = file.processingFormat
        let n = AVAudioFrameCount(file.length)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }

        let frames = Int(buf.frameLength)
        let channels = Int(fmt.channelCount)
        var out = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<frames { out[i] += p[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<frames { out[i] *= scale }
        }
        return (out, fmt.sampleRate)
    }

    /// 标准答案：`{"onsets": [秒, 秒, ...]}`
    static func loadTruth(_ path: String) -> [Double]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["onsets"] as? [Double] else {
            FileHandle.standardError.write("读不了标准答案: \(path)\n".data(using: .utf8)!)
            return nil
        }
        return arr.sorted()
    }

    // MARK: - 跑一遍检测

    /// 按 `chunk` 大小分块喂，模拟真实 IOProc 的缓冲区粒度——
    /// 检测器是逐样本的，分块本不该影响结果，但这样能顺带证明这一点。
    static func detect(_ samples: [Float], sampleRate: Double,
                       params: OnsetDetector.Params, chunk: Int = 512)
        -> [(time: Double, strength: Float)] {
        var det = OnsetDetector(sampleRate: sampleRate, params: params)
        var hits: [(Double, Float)] = []
        var out: [OnsetDetector.Onset] = []
        out.reserveCapacity(8)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < samples.count {
                let n = Swift.min(chunk, samples.count - i)
                det.process(base + i, count: n, into: &out)
                for o in out { hits.append((Double(i + o.offset) / sampleRate, o.strength)) }
                i += n
            }
        }
        return hits
    }

    // MARK: - 对标准答案打分

    struct Score {
        let hit: Int          // 命中
        let missed: Int       // 漏检
        let spurious: Int     // 误报
        let offsetsMs: [Double]
        var recall: Double { hit + missed > 0 ? Double(hit) / Double(hit + missed) : 0 }
        var precision: Double { hit + spurious > 0 ? Double(hit) / Double(hit + spurious) : 0 }
        var medianOffsetMs: Double {
            guard !offsetsMs.isEmpty else { return 0 }
            let s = offsetsMs.sorted()
            return s[s.count / 2]
        }
        var maxOffsetMs: Double { offsetsMs.map(abs).max() ?? 0 }
        var f1: Double {
            let denom = recall + precision
            return denom <= 0 ? 0 : 2 * recall * precision / denom
        }
    }

    /// 每个真值配最近的一次检出，容差内算命中。已被配走的检出不再复用，
    /// 所以「一次敲击报三个起音」会如实体现为 2 个误报，不会被宽容掉。
    static func score(detected: [(time: Double, strength: Float)],
                      truth: [Double], toleranceMs: Double = 60) -> Score {
        let tol = toleranceMs / 1000
        var used = [Bool](repeating: false, count: detected.count)
        var hit = 0, missed = 0
        var offs: [Double] = []

        for t in truth {
            var best = -1
            var bestD = Double.infinity
            for (i, d) in detected.enumerated() where !used[i] {
                let dt = abs(d.time - t)
                if dt < bestD { bestD = dt; best = i }
            }
            if best >= 0 && bestD <= tol {
                used[best] = true
                hit += 1
                offs.append((detected[best].time - t) * 1000)
            } else {
                missed += 1
            }
        }
        return Score(hit: hit, missed: missed,
                     spurious: used.filter { !$0 }.count, offsetsMs: offs)
    }

    // MARK: - 离线：单跑 / 扫参

    static func runOffline(file: String, truthPath: String?, sweep: Bool,
                           params: OnsetDetector.Params, dump: String?) {
        guard let (samples, sr) = loadMono(file) else { exit(1) }
        let dur = Double(samples.count) / sr
        let truth = truthPath.flatMap { loadTruth($0) }

        print("""

        ══════════ 起音检测（离线） ══════════
        文件            \(file)
        时长            \(String(format: "%.1f", dur)) s   \(Int(sr)) Hz   \(samples.count) 样本
        标准答案        \(truth.map { "\($0.count) 个起音" } ?? "无（只能看检出数，判不了对错）")
        """)

        if sweep {
            guard let truth else {
                FileHandle.standardError.write("扫参需要 --truth，否则无从判断哪组更好\n".data(using: .utf8)!)
                exit(2)
            }
            print("""

            ── 参数扫描 ──────────────────────
            判据：命中率(recall) 与 准确率(precision) 都要高。
            偏差是检出时刻减真值，正数=晚。容差 ±60ms。

              阈值  均值窗口  不应期 │ 命中 漏检 误报 │ recall  prec │ 中位偏差 最大偏差
            """)
            var best: (OnsetDetector.Params, Score)? = nil
            for th in [Float(1.3), 1.5, 1.8, 2.2, 2.8, 3.5] {
                for avgMs in [200.0, 350.0, 500.0, 800.0] {
                    for refr in [80.0, 110.0, 160.0] {
                        var p = params
                        p.threshold = th; p.avgMs = avgMs; p.refractoryMs = refr
                        let s = score(detected: detect(samples, sampleRate: sr, params: p),
                                      truth: truth)
                        // f1 相同时偏向最大偏差小的——同样准的两组参数里，
                        // 抖动小的那组在真实音乐上更不容易翻车
                        let f1 = s.f1
                        let bf1: Double = best?.1.f1 ?? -1
                        let bMax: Double = best?.1.maxOffsetMs ?? .infinity
                        if f1 > bf1 || (f1 == bf1 && s.maxOffsetMs < bMax) {
                            best = (p, s)
                        }
                        print(String(format: "  %4.1f  %5.0fms  %4.0fms │ %4d %4d %4d │ %6.1f%% %5.1f%% │ %7.1f %8.1f",
                                     th, avgMs, refr, s.hit, s.missed, s.spurious,
                                     s.recall * 100, s.precision * 100,
                                     s.medianOffsetMs, s.maxOffsetMs))
                    }
                }
            }
            if let (p, s) = best {
                print("""

                ── 最优 ──────────────────────────
                threshold=\(p.threshold)  avgMs=\(Int(p.avgMs))  refractoryMs=\(Int(p.refractoryMs))
                命中 \(s.hit) / 漏检 \(s.missed) / 误报 \(s.spurious)
                recall \(String(format: "%.1f%%", s.recall * 100))  precision \(String(format: "%.1f%%", s.precision * 100))
                中位偏差 \(String(format: "%.1f", s.medianOffsetMs))ms  最大偏差 \(String(format: "%.1f", s.maxOffsetMs))ms
                """)
            }
        } else {
            let hits = detect(samples, sampleRate: sr, params: params)
            print("""

            ── 参数 ──────────────────────────
            截止 \(Int(params.cutoffHz))Hz  attack \(Int(params.attackMs))ms  release \(Int(params.releaseMs))ms
            阈值 \(params.threshold)× 均值(\(Int(params.avgMs))ms)  不应期 \(Int(params.refractoryMs))ms

            ── 检出 \(hits.count) 个 ─────────────────
            """)
            for (i, h) in hits.prefix(40).enumerated() {
                let bar = String(repeating: "█", count: Swift.max(1, Int(h.strength * 30)))
                print(String(format: "  %3d  t=%7.3fs  强度 %.3f  %@", i + 1, h.time, h.strength, bar))
            }
            if hits.count > 40 { print("   …还有 \(hits.count - 40) 个") }

            if let truth {
                let s = score(detected: hits, truth: truth)
                print("""

                ── 对标准答案 ────────────────────
                命中 \(s.hit) / 漏检 \(s.missed) / 误报 \(s.spurious)
                recall \(String(format: "%.1f%%", s.recall * 100))  precision \(String(format: "%.1f%%", s.precision * 100))
                中位偏差 \(String(format: "%.1f", s.medianOffsetMs))ms  最大偏差 \(String(format: "%.1f", s.maxOffsetMs))ms
                """)
            }
        }

        if let dump {
            dumpEnvelope(samples, sampleRate: sr, params: params, to: dump)
            print("\n包络时间序列已写入 \(dump)（每毫秒一行，可拿去画图）")
        }
        print("")
    }

    /// 把包络、滑动均值、阈值线导成 CSV。数字看不出问题的时候画出来往往一眼就看出来。
    private static func dumpEnvelope(_ samples: [Float], sampleRate: Double,
                                     params: OnsetDetector.Params, to path: String) {
        var det = OnsetDetector(sampleRate: sampleRate, params: params)
        var out: [OnsetDetector.Onset] = []
        var csv = "t_ms,env,avg,threshold_line,onset\n"
        let step = Int(sampleRate / 1000)          // 每毫秒采一行
        var onsetAt = Set<Int>()
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < samples.count {
                let n = Swift.min(step, samples.count - i)
                det.process(base + i, count: n, into: &out)
                for o in out { onsetAt.insert((i + o.offset) / step) }
                i += n
            }
        }
        // 第二遍取样（检测器无副作用，重跑得到同样结果）
        var d2 = OnsetDetector(sampleRate: sampleRate, params: params)
        var o2: [OnsetDetector.Onset] = []
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0, ms = 0
            while i < samples.count {
                let n = Swift.min(step, samples.count - i)
                d2.process(base + i, count: n, into: &o2)
                csv += "\(ms),\(d2.debugEnv),\(d2.debugAvg),\(d2.debugAvg * params.threshold),\(onsetAt.contains(ms) ? 1 : 0)\n"
                i += n; ms += 1
            }
        }
        try? csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 实时：验证 AudioTap 管线

    @available(macOS 14.2, *)
    static func runLive(seconds: Double, playFile: String?, params: OnsetDetector.Params) {
        var player: Process?
        if let playFile {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [playFile]
            try? p.run()
            player = p
            print("已启动 afplay 播放 \(playFile)")
        }

        let tap = AudioTap()
        let lock = NSLock()
        var hits: [(time: Double, strength: Float)] = []
        var totalFrames = 0
        var det: OnsetDetector? = nil
        var scratch: [OnsetDetector.Onset] = []
        scratch.reserveCapacity(8)

        tap.onStateChange = { st in print("  [tap] 状态 → \(st)") }
        tap.onSamples = { ptr, n in
            lock.lock()
            if det == nil { det = OnsetDetector(sampleRate: tap.sampleRate, params: params) }
            det?.process(ptr, count: n, into: &scratch)
            for o in scratch {
                hits.append((Double(totalFrames + o.offset) / tap.sampleRate, o.strength))
            }
            totalFrames += n
            lock.unlock()
        }

        print("启动 AudioTap，采集 \(Int(seconds)) 秒…")
        tap.start()

        let deadline = Date().addingTimeInterval(seconds)
        var lastReport = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1.0)
            lock.lock()
            let n = hits.count, frames = totalFrames
            lock.unlock()
            let d = tap.diagnostics()
            lastReport += 1
            print(String(format: "  [%2ds] 起音 %3d 次  样本 %8d  %@",
                         lastReport, n, frames, d.summary))
        }

        tap.stop()
        player?.terminate()

        lock.lock()
        let final = hits
        lock.unlock()
        print("\n── 实时采集结果 ──────────────────")
        print("共检出 \(final.count) 次起音，样本 \(totalFrames) 个")
        for (i, h) in final.prefix(30).enumerated() {
            print(String(format: "  %3d  t=%7.3fs  强度 %.3f", i + 1, h.time, h.strength))
        }
        if final.count > 30 { print("   …还有 \(final.count - 30) 个") }
        print("")
    }
}
