import Foundation
import AppKit

// MagicKey 开发工具
//
//   --analyze   分析效果曲线：卡顿检查 + 帧率需求（纯计算，不碰硬件）
//   --preview   在真实键盘上预览效果，Ctrl-C 停止并还原
//   --set       一次性设置亮度后退出（能耗测量对照组用，见 TESTING.md）
//   --probe     测本机的按键节奏，用来定 KeyRepeatFilter 的容差（不碰硬件）

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts.suffix(9).prefix(8))] \(msg)")
    fflush(stdout)
}

Log.sink = { log($0) }

// MARK: - 参数

struct Options {
    var effect = "breathe"
    var period = 4.0
    var lo: Float = 0.05
    var hi: Float = 0.85
    var fps = 60.0
    var gamma: Float = 1.0     // 见 Core/Effects.swift：>1 会在低端产生可见卡顿
    var duration = 0.0         // 0 = 一直跑到 Ctrl-C
    var mode = Mode.analyze
    var setValue: Float = 0
    var periodExplicit = false

    /// 喂给 analyze 的合成按键序列。nil = 沿用「t=0 敲一次」的老输入。
    var sequence: String?
    var repeatFilter = true    // 关掉是为了真机 A/B 对比新旧行为

    /// `--effect flash` 闪几下
    var flashTimes = FlashEffect.defaultTimes
    var repeatInterval = PressSequence.Measured.interval
    var repeatJitter = PressSequence.Measured.jitter

    /// 分析窗口。周期性效果就是一个周期；喂了按键序列则要覆盖整条序列。
    var window = 0.0
    /// 序列里一共有多少次按下——用来和效果实际检出的次数对照
    var sequenceCount = 0

    /// 起音检测定参（`--probe-audio`）
    var audioFile: String?      // 离线重放这个文件
    var audioTruth: String?     // 标准答案 JSON
    var audioDump: String?      // 包络时间序列导出到 CSV
    var audioSweep = false      // 扫参而不是单跑
    var audioLive = false       // 走真 AudioTap 而不是离线
    var audioSeconds = 20.0
    var onset = OnsetDetector.Params()

    enum Mode { case analyze, preview, set, probe, probeAudio }
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        func val() -> String { it.next() ?? "" }
        switch arg {
        case "--effect":   o.effect = val()
        case "--period":   o.period = Double(val()) ?? o.period; o.periodExplicit = true
        case "--min":      o.lo = Float(val()) ?? o.lo
        case "--max":      o.hi = Float(val()) ?? o.hi
        case "--fps":      o.fps = Double(val()) ?? o.fps
        case "--gamma":    o.gamma = Float(val()) ?? o.gamma
        case "--duration": o.duration = Double(val()) ?? o.duration
        case "--analyze":  o.mode = .analyze
        case "--preview":  o.mode = .preview
        case "--set":      o.mode = .set; o.setValue = Float(val()) ?? 0
        case "--probe":    o.mode = .probe
        case "--sequence": o.sequence = val()
        case "--times":    o.flashTimes = Int(val()) ?? o.flashTimes
        case "--no-repeat-filter": o.repeatFilter = false
        case "--repeat-interval":  o.repeatInterval = (Double(val()) ?? 100) / 1000
        case "--repeat-jitter":    o.repeatJitter = (Double(val()) ?? 1) / 1000

        case "--probe-audio":  o.mode = .probeAudio
        case "--file":         o.audioFile = val()
        case "--truth":        o.audioTruth = val()
        case "--dump":         o.audioDump = val()
        case "--sweep":        o.audioSweep = true
        case "--live":         o.audioLive = true
        case "--seconds":      o.audioSeconds = Double(val()) ?? o.audioSeconds
        case "--cutoff":       o.onset.cutoffHz = Double(val()) ?? o.onset.cutoffHz
        case "--threshold":    o.onset.threshold = Float(val()) ?? o.onset.threshold
        case "--avg-ms":       o.onset.avgMs = Double(val()) ?? o.onset.avgMs
        case "--refractory":   o.onset.refractoryMs = Double(val()) ?? o.onset.refractoryMs
        case "--attack-ms":    o.onset.attackMs = Double(val()) ?? o.onset.attackMs
        case "--release-ms":   o.onset.releaseMs = Double(val()) ?? o.onset.releaseMs
        case "-h", "--help":
            print("""
            用法: magickey-tool <模式> [选项]

            模式
              --analyze          分析效果曲线（默认）：卡顿检查 + 帧率需求，不碰硬件
              --preview          在真实键盘上预览，Ctrl-C 停止并还原
              --set <0–1>        一次性设置亮度后退出，不做还原（见 TESTING.md）
              --probe            测本机按键节奏，定 KeyRepeatFilter 的容差，不碰硬件

            选项
              --effect <static|breathe|heartbeat|strobe|keypulse|audiobeat|flash>
                                 默认 breathe。未知名字直接报错，不会静默退回。
                                 flash 是 CLI 的瞬时效果，面板上选不到它
              --times  <1–10>    仅 flash：闪几下，默认 3。窗口自动取它的总时长
              --period <秒>      效果周期，默认 4.0
                                 （keypulse / audiobeat 是单次脉冲总时长，
                                   不显式给时分别取 0.4 / 0.35）
              --min    <0–1>     亮度下限，默认 0.05（脉冲类是「静息亮度」）
              --max    <0–1>     亮度上限，默认 0.85（脉冲类是「脉冲峰值」）
              --fps    <帧率>    默认 60
              --gamma  <值>      感知映射，默认 1.0（关闭）
              --duration <秒>    预览/探针时长，0 = 直到 Ctrl-C

            脉冲类效果（keypulse / audiobeat）
              analyze 用确定性的合成脉冲，preview 用真来源——keypulse 读键盘
              （零权限），audiobeat 接系统音频（需「系统录音」授权，且必须有声音在放）

              --sequence <autorepeat|typing>
                                 给 analyze 喂合成按键序列。不给则沿用「t=0 敲一次」，
                                 那种输入验证不了任何跟节奏有关的东西。
                                 两条序列都是**按键**节奏，对 audiobeat 没有意义
              --no-repeat-filter 关掉自动重复过滤，用于真机 A/B 对比新旧行为。
                                 audiobeat 本来就是关的（鼓点就是等间隔，开着必哑）
              --repeat-interval <毫秒>   合成序列的重复间隔，默认按 --probe 实测
              --repeat-jitter   <毫秒>   合成序列的重复抖动，默认按 --probe 实测
            """)
            exit(0)
        default:
            FileHandle.standardError.write("未知参数: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

var opts = parseArgs()

// MARK: - probe：纯读事件时间戳，既不碰硬件也不需要授权

if opts.mode == .probe {
    Probe.run(duration: opts.duration)
    exit(0)
}

// MARK: - probe-audio：起音检测定参
//
// 离线（--file）不碰硬件也不需要授权，是定参的主力；
// 实时（--live）走真正的 AudioTap，需要「系统录音」授权，只用来验证管线。

if opts.mode == .probeAudio {
    if opts.audioLive {
        guard #available(macOS 14.2, *) else {
            FileHandle.standardError.write(
                "系统音频采集需要 macOS 14.2+（AudioHardwareCreateProcessTap）\n".data(using: .utf8)!)
            exit(1)
        }
        AudioProbe.runLive(seconds: opts.audioSeconds,
                           playFile: opts.audioFile, params: opts.onset)
    } else {
        guard let file = opts.audioFile else {
            FileHandle.standardError.write(
                "--probe-audio 需要 --file <音频文件>（离线），或 --live（走真实采集）\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        AudioProbe.runOffline(file: file, truthPath: opts.audioTruth,
                              sweep: opts.audioSweep, params: opts.onset,
                              dump: opts.audioDump)
    }
    exit(0)
}

// 效果名解析。**未知名字要报错，不能默默退回 breathe**——旧版就是那样，
// 于是 `--effect audiobeat` 一直在分析呼吸曲线而没有任何人发现。
//
// `flash` 刻意**不在** `EffectKind` 里：那个枚举驱动面板上的 2×3 网格
// （`EffectGrid` 遍历 `allCases`），把 flash 加进去会凭空多出一格用户选不了的效果。
// 它是瞬时层，只由 CLI 触发。所以这里是「效果名」而不是「EffectKind」。
enum ToolEffect {
    case base(EffectKind)
    case flash(times: Int)
}

let toolEffect: ToolEffect = {
    if opts.effect == "flash" { return .flash(times: opts.flashTimes) }
    guard let kind = EffectKind(rawValue: opts.effect) else {
        let known = (EffectKind.allCases.map(\.rawValue) + ["flash"]).joined(separator: " / ")
        FileHandle.standardError.write("未知效果: \(opts.effect)（可用 \(known)）\n".data(using: .utf8)!)
        exit(2)
    }
    return .base(kind)
}()

// 脉冲类效果的 --period 语义是「单次脉冲时长」，4 秒的通用默认值对它们毫无意义
if case .base(let kind) = toolEffect, !opts.periodExplicit, kind.isPulse {
    opts.period = kind.defaultPeriod
}

// 合成按键序列。只对 analyze 有意义——preview 用的是真键盘。
let pressTimes: [Double]? = { () -> [Double]? in
    guard opts.mode == .analyze, let seq = opts.sequence else { return nil }
    switch seq {
    case "autorepeat":
        return PressSequence.autorepeat(interval: opts.repeatInterval, jitter: opts.repeatJitter)
    case "typing":
        return PressSequence.typing()
    default:
        FileHandle.standardError.write("未知序列: \(seq)（可用 autorepeat / typing）\n".data(using: .utf8)!)
        exit(2)
    }
}()

// 分析窗口：周期性效果一个周期就够；喂了按键序列则要覆盖整条序列，
// 末尾还要留出最后一次脉冲衰减完的时间，否则会把没播完的包络当成结尾。
//
// flash 自己就有明确的总时长，窗口取它——**不能多给**：多出来的那一截
// flash 已经返回 nil（出栈了），分析器会把它算成一段超长的尾部停留，
// 报出一个不存在的「卡顿」。
if case .flash(let n) = toolEffect {
    opts.window = FlashEffect(times: n).duration
    // 报告抬头那行「周期」对 flash 而言就是**一下的周期**（起手+衰减+暗场）。
    // 留着 --period 的 4.0 默认值只会让人以为分析跑错了参数。
    opts.period = FlashEffect.cycle
} else {
    opts.window = pressTimes.map { ($0.last ?? 0) + opts.period + 0.5 } ?? opts.period
}
opts.sequenceCount = pressTimes?.count ?? 0

/// **实现在 `Core/EffectFactory.swift`，和 app 走同一份。**
/// 这里以前是第二个 switch，和 `Settings.makeEffect()` 漂了——理由见工厂那个文件开头。
func makeEffect(_ o: Options) -> Effect {
    switch toolEffect {
    case .flash(let times):
        // flash 的峰值恒为 1.0（见 FlashEffect），--min/--max 对它没有意义：
        // 它是瞬时层，静息值必须是 0（= 这一帧不发言），不是 lo。
        return FlashEffect(times: times)

    case .base(let kind):
        // preview 用真来源（键盘 / 系统音频）；analyze 要确定性输入——
        // 给了序列就重放序列，没给就退回「t=0 敲一次」，那是包络曲线的回归基准输入。
        let pulses: PulseSourcePolicy
        if let times = pressTimes  { pulses = .synthetic(times: times) }
        else if o.mode == .analyze { pulses = .synthetic(times: [0]) }
        else                       { pulses = .live }

        return EffectFactory.make(EffectSpec(
            kind: kind, period: o.period, lo: o.lo, hi: o.hi,
            pulses: pulses,
            // nil = 按效果取默认（keypulse 开、audiobeat 必须关）。
            // `--no-repeat-filter` 是真机 A/B 用的显式覆盖，只往 false 的方向压。
            filterRepeats: o.repeatFilter ? nil : false))
    }
}

// MARK: - analyze：纯计算，不碰硬件

if opts.mode == .analyze {
    Analyzer.run(make: { makeEffect(opts) }, opts: opts)
    exit(0)
}

guard let driver = CoreBrightnessDriver() else {
    FileHandle.standardError.write("CoreBrightness 不可用，此 macOS 版本可能不受支持\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - set：刻意不做快照/接管/还原，目的就是把亮度留在设定值上

if opts.mode == .set {
    driver.writeBrightness(opts.setValue)
    print(String(format: "亮度已设为 %.3f（未改动环境光/闲置设置，不做还原）", driver.readBrightness()))
    exit(0)
}

// MARK: - preview

let guardian = StateGuard(driver: driver, namespace: "tool")
guardian.recoverFromPreviousCrashIfNeeded()
guardian.capture()
guardian.takeOver()

let stack = EffectStack(base: makeEffect(opts))
log("预览 \(opts.effect)  周期=\(opts.period)s  范围=\(opts.lo)…\(opts.hi)  fps=\(opts.fps)"
    + (opts.effect == "keypulse" && !opts.repeatFilter ? "  ⚠️ 自动重复过滤已关闭" : ""))
log(opts.duration > 0 ? "时长 \(Int(opts.duration))s" : "Ctrl-C 停止并还原")

let queue = DispatchQueue(label: "com.magickey.tool.render", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 1.0 / opts.fps, leeway: .milliseconds(2))

let started = Date()
var frame: UInt64 = 0
let base = opts.hi
let gamma = opts.gamma

timer.setEventHandler {
    let ctx = FrameContext(time: Date().timeIntervalSince(started), frame: frame, base: base)
    driver.writeBrightness(Perceptual.toPhysical(stack.render(ctx), gamma: gamma))
    frame &+= 1
}

var shuttingDown = false
@Sendable func shutdown(_ reason: String) {
    guard !shuttingDown else { return }
    shuttingDown = true
    timer.cancel()
    queue.sync {}                     // 等最后一帧写完，否则还原会被它覆盖
    guardian.restore(reason: reason)
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shutdown("收到终止信号") }
    src.resume()
    signalSources.append(src)
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
) { _ in shutdown("系统睡眠") }

if opts.duration > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + opts.duration) { shutdown("到达设定时长") }
}

timer.resume()
RunLoop.main.run()
