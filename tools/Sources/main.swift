import Foundation
import AppKit

// MagicKey 开发工具
//
//   --analyze   分析效果曲线：卡顿检查 + 帧率需求（纯计算，不碰硬件）
//   --preview   在真实键盘上预览效果，Ctrl-C 停止并还原
//   --set       一次性设置亮度后退出（能耗测量对照组用，见 TESTING.md）

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

    enum Mode { case analyze, preview, set }
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
        case "-h", "--help":
            print("""
            用法: magickey-tool <模式> [选项]

            模式
              --analyze          分析效果曲线（默认）：卡顿检查 + 帧率需求，不碰硬件
              --preview          在真实键盘上预览，Ctrl-C 停止并还原
              --set <0–1>        一次性设置亮度后退出，不做还原（见 TESTING.md）

            选项
              --effect <static|breathe|heartbeat|strobe|keypulse>   默认 breathe
              --period <秒>      效果周期，默认 4.0
                                 （keypulse 是单次脉冲总时长，默认 0.4）
              --min    <0–1>     亮度下限，默认 0.05
              --max    <0–1>     亮度上限，默认 0.85
              --fps    <帧率>    默认 60
              --gamma  <值>      感知映射，默认 1.0（关闭）
              --duration <秒>    预览时长，0 = 直到 Ctrl-C
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

// keypulse 的 --period 语义是「单次脉冲时长」，4 秒的默认值对它毫无意义
if !opts.periodExplicit && opts.effect == "keypulse" { opts.period = 0.4 }

func makeEffect(_ o: Options) -> Effect {
    switch o.effect {
    case "static":    return StaticEffect(level: o.hi)
    case "heartbeat": return HeartbeatEffect(period: o.period, min: o.lo, max: o.hi)
    case "strobe":    return StrobeEffect(period: o.period, min: o.lo, max: o.hi)
    case "keypulse":
        // analyze 要确定性输入（t=0 敲一次），preview 要真键盘
        return KeyPulseEffect(duration: o.period, min: o.lo, max: o.hi,
                              clock: o.mode == .analyze ? KeyPress.synthetic : KeyPress.system)
    default:          return BreatheEffect(period: o.period, min: o.lo, max: o.hi)
    }
}

// MARK: - analyze：纯计算，不碰硬件

if opts.mode == .analyze {
    Analyzer.run(effect: makeEffect(opts), opts: opts)
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
log("预览 \(opts.effect)  周期=\(opts.period)s  范围=\(opts.lo)…\(opts.hi)  fps=\(opts.fps)")
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
