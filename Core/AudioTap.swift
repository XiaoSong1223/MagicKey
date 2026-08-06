import Foundation
import CoreAudio

// MARK: - 系统音频采集（Core Audio Process Tap）
//
// 这一层只负责一件事：把系统正在播放的声音变成一串 Float 样本交出去。
// 起音检测、频段、平滑全都不在这里——它们不需要知道 CoreAudio 长什么样，
// 这里也不需要知道最后要点亮几档灯。
//
// ## 为什么是 Process Tap 而不是麦克风
//
// tap 拿到的是**逐位精确的系统输出**，而且在**音量推子之前**：
// 实测系统音量调到 50%，读到的峰值仍等于源信号峰值（0.45）。
// 走麦克风的话，系统音量、外放位置、环境噪声会全部串进来，
// 用户把音量拧小灯就不闪了——那是个没法解释也没法调的产品行为。
//
// ## 实测数据（2026-08-06 探针，M4 / macOS 26.5.1）
//
// - **要求 macOS 14.2**，不是 DESIGN.md 里写的 14.4：`AudioHardwareCreateProcessTap`
//   的 `API_AVAILABLE` 就写着 14.2。项目部署目标是 14.0，所以整个类由 `@available`
//   守卫，宿主在低版本上直接不构造它，**不要为了这个抬部署目标**。
// - 流格式 48000Hz / 1 声道（mono mixdown）/ 32 位 float，
//   每次回调约 512 帧，回调频率约 94Hz。
// - 需要 TCC 授权 `kTCCServiceAudioCapture`，对应
//   系统设置 → 隐私与安全性 → **系统录音**（不是「麦克风」，找错地方会以为没弹框）。
//   ad-hoc 签名可用——这条授权不跟 cdhash 走，所以不像 Input Monitoring 那样
//   每次 `make install` 都掉（见 CLAUDE.md 里键位黑名单被推迟的理由）。
//
// ## 三个必须记住的行为（全部实测，不是推测）
//
// 1. `AudioDeviceCreateIOProcIDWithBlock` **会阻塞 1.8–4.6 秒**，
//    没有音频在播放时可能**永久阻塞**。所以整个建立流程绝不能跑在主线程或渲染队列上，
//    而且必须带超时——见 `buildPipeline` 里的信号量段落。
// 2. **tap 是被音频驱动的：没有声音在放就没有 IO 回调。** 这不是故障。
//    见 `Diagnostics` / 看门狗，它们存在的唯一理由就是把这两件事分开。
// 3. **泄漏的 tap / 聚合设备会把 coreaudiod 搞乱**（下一次建的 tap 直接收不到回调，
//    而且重启 app 也好不了）。所有路径都必须拆干净——见 `TapResources.destroy`。

/// 把 OSStatus 印成人能看懂的形式。CoreAudio 的错误码大多是 fourcc，
/// 打成十进制（比如 -10851）没人认得出来，打成 `'!obj'` 一眼就能查。
private func osStatusText(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    if chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'\(String(decoding: chars, as: UTF8.self))'(\(s))"
    }
    return "\(s)"
}

private func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

// MARK: - 资源句柄

/// tap + 聚合设备 + IOProc 三件套的生命周期。
///
/// 单独成类而不是三个散落的属性，是为了让「拆干净」变成一次调用而不是一段流程——
/// 失败路径、`stop()`、设备重建、`deinit`、超时后迟到的返回值，
/// 五条路径每条都要拆，散着写必然漏。
@available(macOS 14.2, *)
private final class TapResources {

    let tapID: AudioObjectID
    /// 这两个在建立过程中才逐步填上，所以是 var。只在 AudioTap 的 setupQueue 上写。
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var started = false

    private let lock = NSLock()
    private var destroyed = false

    init(tapID: AudioObjectID) { self.tapID = tapID }

    var isDestroyed: Bool {
        lock.lock(); defer { lock.unlock() }
        return destroyed
    }

    /// 幂等。**拆除顺序不能改**：先停 IO，再拆 IOProc，再拆聚合设备，最后拆 tap。
    /// 反过来（先拆 tap）会让聚合设备引用一个已经不存在的 sub-tap，
    /// coreaudiod 那边留下的残骸下次会以「新建的 tap 一次回调都不来」的形式复现。
    func destroy(reason: String) {
        lock.lock()
        guard !destroyed else { lock.unlock(); return }
        destroyed = true
        let agg = aggregateID
        let proc = procID
        let wasStarted = started
        procID = nil
        started = false
        lock.unlock()

        if agg != AudioObjectID(kAudioObjectUnknown), let proc {
            if wasStarted { _ = AudioDeviceStop(agg, proc) }
            let st = AudioDeviceDestroyIOProcID(agg, proc)
            if st != noErr { Log.write("[audiotap] DestroyIOProcID 失败 \(osStatusText(st))") }
        }
        if agg != AudioObjectID(kAudioObjectUnknown) {
            let st = AudioHardwareDestroyAggregateDevice(agg)
            if st != noErr { Log.write("[audiotap] DestroyAggregateDevice 失败 \(osStatusText(st))") }
        }
        let st = AudioHardwareDestroyProcessTap(tapID)
        if st != noErr { Log.write("[audiotap] DestroyProcessTap 失败 \(osStatusText(st))") }

        Log.write("[audiotap] 已拆除采集管线（\(reason)）")
    }
}

/// 实时线程写、任意线程读的计数器。
///
/// 用一个 class 而不是 `AudioTap` 的属性：IO block 强引用它，
/// 于是它的存活期跟着 block 走。`AudioTap` 先 deinit 而 block 还在跑的窗口里，
/// 直接写 `self` 的字段就是 use-after-free。
///
/// 没有加锁：单一写入者（音频线程），arm64 上对齐的 64 位读写本身不撕裂，
/// 读到的最坏情况是慢一拍的旧值——这是诊断量，不是控制量，慢一拍无所谓。
/// **实时线程上不能加锁**，这是硬约束不是偷懒。
private final class TapStats {
    var callbacks: UInt64 = 0
    var lastCallbackNanos: UInt64 = 0
    var frames: UInt64 = 0

    func reset() {
        callbacks = 0
        lastCallbackNanos = 0
        frames = 0
    }
}

/// `AudioDeviceCreateIOProcIDWithBlock` 那次可能永不返回的调用的交接点。
/// 超时之后 setup 线程走人，这个 box 由后台线程独占，用来决定「谁负责收尸」。
private final class IOProcHandoff {
    let lock = NSLock()
    var status: OSStatus = kAudioHardwareUnspecifiedError
    var procID: AudioDeviceIOProcID?
    /// setup 线程已经放弃等待。置位之后，收尸责任转移给后台线程。
    var abandoned = false
}

// MARK: - AudioTap

@available(macOS 14.2, *)
final class AudioTap {

    // MARK: 对外接口

    /// 采集到的样本会在**音频实时线程**上回调，参数是 `(单声道 Float 样本首地址, 样本数)`。
    ///
    /// 实现方在这个回调里**不得做内存分配、不得加锁、不得调用任何可能阻塞的东西**
    /// （包括 `Log.write`）。指针只在回调期间有效，要留就自己拷进预分配的环形缓冲。
    ///
    /// **必须在 `start()` 之前设置。** 实时线程读的是 `start()` 时抓的快照，
    /// 而不是每次回调都去读这个属性——后者等于让实时线程和主线程并发访问一个
    /// Swift 闭包引用（ARC 操作 + 可能的堆释放），那是真的数据竞争。
    /// 运行中改写会有日志提示，不会静默生效也不会崩。
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)? {
        didSet {
            if case .running = state {
                Log.write("[audiotap] ⚠️ onSamples 在运行中被改写，本次不生效"
                          + "（实时线程用的是 start() 时的快照）。改完请 stop() 再 start()")
            }
        }
    }

    enum State: Equatable {
        /// 没在跑，也没失败过。
        case idle
        /// 正在建立管线。这个状态可能持续好几秒——`AudioDeviceCreateIOProcIDWithBlock`
        /// 实测阻塞 1.8–4.6 秒，UI 得容忍它，不要当成卡死。
        case starting
        /// 管线已建立。**注意：running 不等于「有样本在流」**——
        /// 系统没在放声音时一次回调都不会有，那是正常的。要分辨请看 `diagnostics()`。
        case running
        /// 整体不可用，附带原因。不做任何后台重试的假装。
        case unavailable(String)
    }

    /// 状态变更通知。**在 AudioTap 自己的串行队列上调用**，UI 要自己切回主线程。
    var onStateChange: ((State) -> Void)?

    /// 只读。setupQueue 写，任意线程读，所以走锁。
    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    /// tap 实际协商出来的采样率。起音检测要用它换算窗口长度，所以必须暴露。
    /// 建立成功前是实测默认值 48000。
    var sampleRate: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _sampleRate
    }

    // MARK: 诊断
    //
    // 「tap 坏了」和「系统没在放声音」在外部看起来完全一样：都是零回调。
    // 2026-08-06 的探针就栽在这里，连续四轮在改聚合设备的配方，
    // 而实际上全程没有任何音频在播放（见 AudioActivity.swift 的注释）。
    // 所以这两个状态必须能从外部一眼分辨，这不是锦上添花。

    struct Diagnostics {
        let state: State
        /// 系统当前有没有声音在放。没有的话零回调是**预期行为**。
        let outputIsRunning: Bool
        let callbackCount: UInt64
        let frameCount: UInt64
        /// nil = 从未回调过。
        let secondsSinceLastCallback: TimeInterval?

        /// 一句话结论。调试时先看这个，别去数回调次数。
        var summary: String {
            switch state {
            case .idle:                 return "未启动"
            case .starting:             return "正在建立管线（可能要几秒）"
            case .unavailable(let why): return "不可用：\(why)"
            case .running:
                if let ago = secondsSinceLastCallback, ago < 1.0 {
                    return String(format: "运行中，有样本流入（累计 %llu 次回调）", callbackCount)
                }
                if !outputIsRunning {
                    return "运行中，但系统当前没有音频在播放 —— 零回调是预期的，不是故障"
                }
                // 从未回调过和「回调停了」要分开说：刚 start() 完的那一两百毫秒
                // 本来就还没有第一次回调，那时候下「坏了」的结论是冤枉它。
                guard secondsSinceLastCallback != nil else {
                    return "运行中，系统在放音频但还没收到过任何回调 —— 持续数秒即为故障"
                }
                return "运行中，系统在放音频却收不到回调 —— tap 真的坏了"
            }
        }
    }

    func diagnostics() -> Diagnostics {
        let n = stats.callbacks
        let last = stats.lastCallbackNanos
        let ago: TimeInterval? = last == 0 ? nil
            : Double(DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000_000
        return Diagnostics(state: state,
                           outputIsRunning: AudioActivity.outputIsRunning(),
                           callbackCount: n,
                           frameCount: stats.frames,
                           secondsSinceLastCallback: ago)
    }

    // MARK: 内部状态

    /// 建立/拆除全部在这条串行队列上做。**绝不能是主队列或渲染队列**——
    /// 建立过程会阻塞好几秒（见文件头注释第 1 条）。
    private let setupQueue = DispatchQueue(label: "com.magickey.audiotap.setup", qos: .utility)

    private let stateLock = NSLock()
    private var _state: State = .idle
    private var _sampleRate: Double = 48_000

    /// IO block 强引用它，所以它必须活得比 `self` 久，用 let 持有。
    private let stats = TapStats()

    /// 以下全部只在 setupQueue 上访问，故不加锁。deinit 是唯一例外，理由见 deinit。
    private var desiredRunning = false
    private var resources: TapResources?
    private var watchdog: DispatchSourceTimer?
    private var lastDiagnosis: Diagnosis?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rebuildGeneration: UInt64 = 0

    /// 等 `AudioDeviceCreateIOProcIDWithBlock` 的上限。实测最长 4.6 秒，
    /// 给到 10 秒是留两倍余量给更慢的机器；真到 10 秒还没回来，
    /// 基本可以断定是「无音频播放时永久阻塞」那条路径，等下去没有意义。
    private let setupTimeout: TimeInterval = 10

    init() {}

    deinit {
        // 不能 async 到 setupQueue：self 正在消失，异步块里的 self 已经是悬垂引用。
        // 同步拆干净——泄漏的 tap / 聚合设备活得比进程还久（文件头第 3 条）。
        //
        // 这里读 setupQueue 独占的字段是安全的：deinit 意味着没有任何强引用了，
        // 而 setupQueue 上正在执行的块要么已经结束，要么持有强引用（那就不会 deinit）。
        watchdog?.cancel()
        watchdog = nil
        removeDeviceListener()
        resources?.destroy(reason: "deinit")
        resources = nil
    }

    // MARK: 启停

    /// 异步。调用方不会被阻塞——建立过程要好几秒，全部在 setupQueue 上做。
    /// 结果通过 `state` / `onStateChange` 汇报。
    func start() {
        setupQueue.async { [weak self] in self?.performStart() }
    }

    /// 异步。若此刻正卡在 `AudioDeviceCreateIOProcIDWithBlock` 里，
    /// 这次 stop 会排在它后面（同一条串行队列），最长等 `setupTimeout`。
    /// 这是对的：不能在管线半建好的时候去拆它。
    func stop() {
        setupQueue.async { [weak self] in self?.performStop(reason: "stop()") }
    }

    // MARK: 状态

    private func setState(_ new: State) {
        stateLock.lock()
        guard _state != new else { stateLock.unlock(); return }
        _state = new
        stateLock.unlock()
        onStateChange?(new)
    }

    private func setSampleRate(_ rate: Double) {
        stateLock.lock(); _sampleRate = rate; stateLock.unlock()
    }

    // MARK: 主流程（全部在 setupQueue 上）

    private func performStart() {
        guard !desiredRunning else {
            Log.write("[audiotap] start() 忽略：已经启动过了（state=\(state)）")
            return
        }
        desiredRunning = true
        installDeviceListener()

        if !buildPipeline(trigger: "start()") {
            // **首次建立失败不留后台重试。** 失败原因基本都是结构性的
            // （未授权系统录音 / 没有默认输出设备 / 系统太老），
            // 悄悄重试只会让「为什么不亮」更难查。如实降级，让宿主决定要不要再来一次。
            desiredRunning = false
            removeDeviceListener()
        }
    }

    private func performStop(reason: String) {
        desiredRunning = false
        removeDeviceListener()
        stopWatchdog()
        resources?.destroy(reason: reason)
        resources = nil
        setState(.idle)
    }

    /// 默认输出设备变了以后的重建。和 `performStop` + `performStart` 的区别是
    /// 保留 `desiredRunning` 和设备监听器：即使这次重建失败，
    /// 用户下次插拔耳机还有机会自愈。
    private func performRebuild(reason: String) {
        guard desiredRunning else { return }
        stopWatchdog()
        resources?.destroy(reason: reason)
        resources = nil
        if !buildPipeline(trigger: reason) {
            Log.write("[audiotap] 重建失败，保留设备监听——下次输出设备变化会再试一次")
        }
    }

    // MARK: 建立管线

    private func fail(_ message: String) -> Bool {
        resources?.destroy(reason: "建立失败")
        resources = nil
        Log.write("[audiotap] ❌ \(message)")
        setState(.unavailable(message))
        return false
    }

    private func buildPipeline(trigger: String) -> Bool {
        setState(.starting)
        stats.reset()
        lastDiagnosis = nil
        Log.write("[audiotap] 建立采集管线（触发: \(trigger)）")

        // 聚合设备的 main sub-device 要一个真实输出设备的 UID。
        // 用 AudioActivity 的实现而不是自己再抄一份——同一个查询有两份实现，
        // 迟早会有一份先腐烂。
        guard let outputUID = AudioActivity.defaultOutputUID() else {
            return fail("拿不到默认输出设备的 UID（当前没有可用的输出设备？）")
        }

        // ── 1. tap ──────────────────────────────────────────────────
        // 空数组 = 排除零个进程 = 抓全部进程的输出。
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "MagicKey"
        // 私有：只有创建它的进程看得见。不这么做的话，用户的音频设备列表里
        // 会凭空多出一个 MagicKey 的输入源，别的 app 也能选到它。
        desc.isPrivate = true
        // muteBehavior 保持默认（CATapUnmuted）——**绝不能改**。
        // CATapMuted 会让被 tap 的进程完全没有声音送到硬件，
        // 也就是「开了灯效之后音乐没了」。一个背光动效应用不该有能力做这件事。

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            return fail("AudioHardwareCreateProcessTap 失败 \(osStatusText(tapStatus))。"
                        + "最可能的原因是未授权：系统设置 → 隐私与安全性 → 系统录音"
                        + "（不是「麦克风」那一项）")
        }
        let res = TapResources(tapID: tapID)
        resources = res   // 立刻挂上，此后任何失败路径都由 fail() 统一拆除

        // ── 2. 流格式 ───────────────────────────────────────────────
        // 实测是 48000Hz / 1ch / Float32。这里不是走个过场：
        // 拿到非 float32 还硬按 float 解读，出来的是噪声而不是错误，
        // 现象只是「灯在乱闪」，从那儿倒推回格式不匹配要花掉一整个下午。
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = globalAddress(kAudioTapPropertyFormat)
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil,
                                                      &asbdSize, &asbd)
        if formatStatus == noErr {
            Log.write(String(format: "[audiotap] 流格式 %.0fHz %uch %ubit flags=0x%x",
                             asbd.mSampleRate, asbd.mChannelsPerFrame,
                             asbd.mBitsPerChannel, asbd.mFormatFlags))
            let isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM
                && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && asbd.mBitsPerChannel == 32
            guard isFloat32 else {
                return fail("tap 流格式不是 32 位 float，无法按 Float 解读样本")
            }
            guard asbd.mChannelsPerFrame == 1 else {
                return fail("tap 流格式是 \(asbd.mChannelsPerFrame) 声道，"
                            + "但 onSamples 的契约是单声道——交出去会被当成两倍长的 mono")
            }
            if asbd.mSampleRate > 0 { setSampleRate(asbd.mSampleRate) }
        } else {
            // 读不到格式不构成失败：它只是个校验，管线本身不依赖它。
            // ⚠️ 这条分支没有实测过（探针那次读得到），走到这里时下游拿到的
            // sampleRate 是 48000 这个默认值。
            Log.write("[audiotap] ⚠️ 读不到 kAudioTapPropertyFormat "
                      + "\(osStatusText(formatStatus))，按 48000Hz/1ch/Float32 继续")
        }

        // ── 3. tap 的 UID ───────────────────────────────────────────
        var uidAddr = globalAddress(kAudioTapPropertyUID)
        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) {
            AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, $0)
        }
        guard uidStatus == noErr else {
            return fail("读 kAudioTapPropertyUID 失败 \(osStatusText(uidStatus))")
        }

        // ── 4. 私有聚合设备 ─────────────────────────────────────────
        // 下面这份配方是实测跑通的，**不要凭直觉改**：
        //   - SubDeviceList 留空：我们不想混任何真实设备的输入进来，只要 tap。
        //   - MainSubDevice 仍然要给默认输出设备的 UID：聚合设备需要一个时钟主设备，
        //     缺了它建不起来。这也是本类唯一和「当前输出设备是谁」耦合的地方——
        //     用户插拔 AirPods 要重建，就是因为这一行。
        //   - TapAutoStart：tap 随聚合设备自动启动，省掉一次单独的启动握手。
        //   - DriftCompensation：tap 的时钟和主设备不是同一个，不补偿会缓慢漂移。
        let aggregateUID = UUID().uuidString
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MagicKey Audio Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [Any](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID as String,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary,
                                                           &aggregateID)
        guard aggStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            return fail("AudioHardwareCreateAggregateDevice 失败 \(osStatusText(aggStatus))")
        }
        res.aggregateID = aggregateID

        // ── 5. IOProc（会阻塞好几秒的那一步）────────────────────────
        let sink = onSamples
        if sink == nil {
            Log.write("[audiotap] ⚠️ onSamples 为空，采集到的样本会被直接丢弃")
        }
        let stats = self.stats
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            // ⚠️ 以下是音频实时线程。不分配、不加锁、不打日志。
            let abl = inInputData.pointee            // 结构体拷到栈上，不是堆分配
            guard abl.mNumberBuffers > 0 else { return }
            let buffer = abl.mBuffers                // mono 只有一个 buffer
            guard let raw = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }

            stats.callbacks &+= 1
            stats.frames &+= UInt64(count)
            stats.lastCallbackNanos = DispatchTime.now().uptimeNanoseconds
            sink?(raw.assumingMemoryBound(to: Float.self), count)
        }

        // 超时机制：把真正的调用甩到全局队列，setupQueue 只等信号量。
        // **不能复用一条固定的后台串行队列**——万一这次真的永久阻塞，
        // 下一次 start() 会排在它后面，症状变成「第二次开就再也起不来」。
        let handoff = IOProcHandoff()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var procID: AudioDeviceIOProcID?
            let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock)

            handoff.lock.lock()
            if handoff.abandoned {
                // setup 线程已经走人并拆掉了 tap 和聚合设备。
                // 这个 procID 是我们创建的，收尸责任在这里，漏掉就是文件头第 3 条。
                handoff.lock.unlock()
                Log.write("[audiotap] AudioDeviceCreateIOProcIDWithBlock 在超时之后才返回"
                          + " \(osStatusText(st))，补做清理")
                if let procID { _ = AudioDeviceDestroyIOProcID(aggregateID, procID) }
                return
            }
            handoff.status = st
            handoff.procID = procID
            handoff.lock.unlock()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + setupTimeout) == .timedOut {
            handoff.lock.lock()
            // 极小的窗口：它可能刚好在超时那一瞬返回了。真返回了就收下来，
            // 让下面的 fail() 连同它一起拆——否则这个 procID 谁都不管。
            res.procID = handoff.procID
            handoff.abandoned = true
            handoff.lock.unlock()

            // 这里立刻拆掉 tap 和聚合设备，而不是傻等：一来能不能拆是确定的，
            // 二来聚合设备一消失，卡住的那次调用多半会带着错误返回（**这一点是推测，
            // 没实测过**）；就算它真的永不返回，至少 tap 不会一直挂在 coreaudiod 上。
            return fail("AudioDeviceCreateIOProcIDWithBlock 超过 \(Int(setupTimeout))s 未返回。"
                        + "实测它在有音频播放时耗时 1.8–4.6s，无音频播放时可能永久阻塞")
        }

        guard handoff.status == noErr, let procID = handoff.procID else {
            return fail("AudioDeviceCreateIOProcIDWithBlock 失败 "
                        + "\(osStatusText(handoff.status))")
        }
        res.procID = procID

        // ── 6. 启动 ────────────────────────────────────────────────
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            return fail("AudioDeviceStart 失败 \(osStatusText(startStatus))")
        }
        res.started = true

        setState(.running)
        Log.write(String(format: "[audiotap] ✅ 已启动（tap=%u agg=%u, %.0fHz）",
                         tapID, aggregateID, sampleRate))
        // running ≠ 有样本。系统此刻没在放声音的话一次回调都不会有，
        // 先把这句说清楚，免得又去查配方。
        if !AudioActivity.outputIsRunning() {
            Log.write("[audiotap] · 系统当前没有音频在播放，暂时不会有回调（这是预期的）")
        }
        startWatchdog()
        return true
    }

    // MARK: 看门狗
    //
    // 只做一件事：把「没东西可 tap」和「tap 坏了」说出来。
    // 只在结论**变化**时打一行，所以放着不管也不会刷屏。

    /// 看门狗的三种结论。**必须是枚举而不是拿日志文本去比**——
    /// 「有样本流入」和「没在播放」两句话开头都是同一个符号，
    /// 按文本前缀去重会把这两者之间的切换整个吃掉，而那正是最该报出来的一次转变。
    private enum Diagnosis {
        case flowing
        case quiet
        case stalled
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: setupQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        var seenCallbacks: UInt64 = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.stats.callbacks
            let diagnosis: Diagnosis
            if now != seenCallbacks {
                diagnosis = .flowing
            } else if !AudioActivity.outputIsRunning() {
                diagnosis = .quiet
            } else {
                diagnosis = .stalled
            }
            seenCallbacks = now

            // 只在结论变化时打一行。回调计数每 2 秒都不一样，
            // 把它算进去的话「有样本流入」会一直刷屏。
            guard diagnosis != self.lastDiagnosis else { return }
            self.lastDiagnosis = diagnosis

            switch diagnosis {
            case .flowing:
                Log.write("[audiotap] · 有样本流入（累计 \(now) 次回调 / \(self.stats.frames) 帧）")
            case .quiet:
                Log.write("[audiotap] · 系统没有音频在播放，零回调是预期的")
            case .stalled:
                Log.write("[audiotap] ❌ 系统在放音频却收不到回调 —— "
                          + "tap 真的坏了，不是没东西可 tap")
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        lastDiagnosis = nil
    }

    // MARK: 默认输出设备变化
    //
    // 聚合设备的 MainSubDeviceKey 钉着**建立时**的默认输出设备。
    // 用户插拔 AirPods 之后那个设备就没了，聚合设备会连同 IO 回调一起哑掉，
    // 而 state 还停在 .running——正是「静默失效」。
    //
    // 策略是**整条管线重建**，不是原地改属性：
    // 聚合设备的 sub-device 列表可以改，但 tap 的时钟基准、drift 补偿都得跟着重来，
    // 拆了重搭一次的代价（几秒，且在自己的队列上）远低于维护一条只在换设备时
    // 才走一次、因此永远测不充分的原地修改路径。
    //
    // 重建失败不假装还在工作：进 .unavailable 并记日志，但保留监听器，
    // 下一次设备变化会再试（用户把耳机插回去就自愈）。

    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var addr = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // 这个 block 已经被派发到 setupQueue 上执行。
            // 一次切换设备会连着触发好几次通知，而重建要几秒；
            // 用世代号把这一串合并成最后一次，否则会排出一队重建。
            self.rebuildGeneration &+= 1
            let generation = self.rebuildGeneration
            self.setupQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.rebuildGeneration == generation else { return }
                Log.write("[audiotap] 默认输出设备已变化，重建采集管线")
                self.performRebuild(reason: "默认输出设备变化")
            }
        }
        let st = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, setupQueue, block)
        guard st == noErr else {
            // 不致命：管线照样能建，只是用户换输出设备时不会自愈。
            // 但必须说出来，否则现象是「插上耳机以后灯就不跟音乐了」而毫无线索。
            Log.write("[audiotap] ⚠️ 注册默认输出设备监听失败 \(osStatusText(st))，"
                      + "换输出设备后需要手动重启采集")
            return
        }
        deviceListener = block
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        deviceListener = nil
        var addr = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, setupQueue, block)
    }
}
