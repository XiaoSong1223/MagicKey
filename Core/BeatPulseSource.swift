import Foundation

/// 音乐律动对用户可见的状态。
///
/// **为什么不能只有「开/关」两态。** 这条管线有三种截然不同的"没在闪"：
/// 系统版本不够、没拿到授权、以及**根本没有声音在放**。第三种是完全正常的，
/// 但它和前两种在外部看起来一模一样（都是零脉冲）。2026-08-06 定位音频问题时
/// 在这上面连着花了四轮——盯着「回调 0 次」改聚合设备配方，而全程没有任何音频在播放。
/// 把它们分开显示不是锦上添花，是那次教训的直接产物。
enum AudioStatus: Equatable {
    /// 没在用（没选中音乐效果，或已停止采集）
    case inactive
    /// 系统版本不够。`AudioHardwareCreateProcessTap` 需要 macOS 14.2+
    case unsupportedOS
    /// 正在建立管线。实测 1.8–4.6 秒，UI 要容忍，别当卡死
    case starting
    /// **推断**：撞上了建立超时，多半是没给「系统录音」授权。
    /// 见 `AudioTap.State.unavailable` 的注释——文案必须用「似乎」，不能断言
    case needsPermission
    /// 其它建立失败，带原始原因
    case failed(String)
    /// 管线好着呢，只是系统当前没有音频在播放。**这不是故障**
    case idleNoAudio
    /// 系统在放音频，却收不到样本。这才是真坏了
    case stalled
    /// 正常工作，有样本在流
    case active
}

/// 把「系统音频里的鼓点」变成 `PulseSource`，接上已经磨好的脉冲包络。
///
/// 三段拼起来：`AudioTap`（拿样本）→ `OnsetDetector`（认出起音）→ 这里（交给渲染线程）。
/// 前两段各自都能独立验证，这一层只负责跨线程交接，刻意做得很薄。
///
/// **为什么是单例。** `AudioTap` 建立一次要 1.8–4.6 秒（实测），而 `Engine` 每次
/// 设置变更都会重建效果（`installState()`）。若把 tap 的生命周期绑在效果对象上，
/// 拖一下灵敏度滑块就会把音频管线拆了重搭，几秒钟没有任何反应。
/// tap 必须比效果活得久，而这个进程里只可能有一路全局音频，单例是诚实的表达。
///
/// **为什么用「没人 drain 就自己停」而不是让 Engine 显式关。**
/// 需要停的时机有一堆：切走效果、引擎因空闲停机、锁屏、退出。
/// 让 `Engine` 逐个记住等于把一个必然会漏的清单塞给调用方——
/// 而「渲染线程不再来取脉冲了」这一个条件就把它们全覆盖了。
/// 代价是最多多跑 `idleStopSeconds` 秒。
final class BeatPulseSource: PulseSource {

    /// 全局唯一。见类型注释——tap 的建立成本决定了它不能跟着效果走。
    static let shared = BeatPulseSource()

    /// 触发灵敏度，对应 `OnsetDetector.Params.threshold`（包络要超过滑动均值的倍数）。
    ///
    /// 小 = 灵敏 = 闪得密。实测（`--probe-audio --live`，真实音乐）：
    ///   1.15 → 2.58 次/秒     1.30 → 1.55 次/秒
    ///   1.50 → 1.08 次/秒     1.80 → 0.80 次/秒（明显漏拍）
    /// 合成鼓点上定出来的 1.8 在真实音乐上跨不过门槛——母带重限幅让滑动均值
    /// 贴着峰值。**默认 1.35 是拿眼睛盯着真实键盘定的**，不是拿检出率定的：
    /// 「跟得上 / 不乱闪 / 安静段落不抽风」三件事都读不出检出率。
    ///
    /// 改它**不会**重建 tap，只在下一个音频缓冲区生效。
    var sensitivity: Float {
        get { lock.withLock { params.threshold } }
        set {
            lock.withLock {
                params.threshold = newValue
                detectorDirty = true      // 下个缓冲区重建检测器
            }
        }
    }

    // MARK: - 跨线程状态
    //
    // 音频实时线程写、渲染线程读。用 NSLock 而不是手写无锁环形缓冲：
    // 渲染侧 60Hz 取、音频侧最多 94Hz 放，争用概率极低，
    // 而实时线程上的无锁结构写错的代价远高于这点开销。

    private let lock = NSLock()
    private var pending: [(at: TimeInterval, strength: Float)] = []
    private var params = OnsetDetector.Params()
    private var detectorDirty = true
    private var lastDrain = Date.distantPast
    private var _status: AudioStatus = .inactive
    private var _onStatusChange: ((AudioStatus) -> Void)?

    /// 当前状态。任意线程可读。
    var status: AudioStatus { lock.withLock { _status } }

    /// 状态变更通知。**在 `queue` 上调用，不是主线程**——UI 要自己切回去。
    /// 只在状态真正改变时触发，所以 1Hz 轮询不会把它变成一个刷屏的回调。
    var onStatusChange: ((AudioStatus) -> Void)? {
        get { lock.withLock { _onStatusChange } }
        set { lock.withLock { _onStatusChange = newValue } }
    }

    /// 只在音频线程上碰
    private var detector: OnsetDetector?
    private var framesSeen: Int = 0

    /// 只在 `queue` 上碰。连续多少次轮询看到「在放音频却没有新回调」。
    /// 需要计数而不是一次就报：管线刚建好那一两秒本来就还没有第一次回调，
    /// 那时候下「坏了」的结论是冤枉它（`AudioTap.Diagnostics.summary` 里同样的谨慎）。
    private var stalledPolls = 0

    private var tap: AnyObject?          // AudioTap，@available 挡着不能写进类型
    private var idleTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.magickey.beat")

    /// 没人来取脉冲多久之后停掉 tap。取 3 秒：比任何一次渲染停顿都长，
    /// 又短到用户切走效果之后不会觉得「怎么还在录」。
    private static let idleStopSeconds: TimeInterval = 3

    private init() {}

    // MARK: - 生命周期

    /// 选中音频效果时调用。重复调用无害。
    func activate() {
        guard #available(macOS 14.2, *) else {
            Log.write("[beat] 需要 macOS 14.2+，音频律动不可用")
            setStatus(.unsupportedOS)
            return
        }
        lock.withLock { lastDrain = Date() }
        setStatus(.starting)          // 立刻置位，别让 UI 停在上一次的状态上等 1 秒
        queue.async { [self] in
            startIdleWatchdogIfNeeded()
            guard tap == nil else { return }

            let t = AudioTap()
            t.onSamples = { [weak self] ptr, n in self?.consume(ptr, n) }
            // onStateChange 在 AudioTap 自己的 setupQueue 上来，跳回本队列再算，
            // 免得 refreshStatus 同时被两条队列调用。
            t.onStateChange = { [weak self] st in
                Log.write("[beat] tap 状态 → \(st)")
                self?.queue.async { self?.refreshStatus() }
            }
            tap = t
            t.start()
        }
    }

    /// 立刻停。正常路径不需要显式调用——看门狗会做——但退出时同步停一下更干净。
    func deactivate() {
        queue.async { [self] in
            if #available(macOS 14.2, *), let t = tap as? AudioTap { t.stop() }
            tap = nil
            idleTimer?.cancel()
            idleTimer = nil
            lock.withLock {
                pending.removeAll()
                detectorDirty = true
            }
            detector = nil
            framesSeen = 0
            stalledPolls = 0
            setStatus(.inactive)
        }
    }

    private func startIdleWatchdogIfNeeded() {
        guard idleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { Date().timeIntervalSince(self.lastDrain) }
            if idle > Self.idleStopSeconds {
                Log.write("[beat] 已 \(Int(idle))s 无人取脉冲 → 停止音频采集")
                self.deactivate()
                return
            }
            // 「有没有样本在流」不是状态变更，`onStateChange` 报不出来——
            // tap 一直是 .running，变的只是回调有没有来。只能轮询。
            self.refreshStatus()
        }
        t.resume()
        idleTimer = t
    }

    // MARK: - 状态推导

    private func setStatus(_ new: AudioStatus) {
        // 回调不能在持锁时调用（实现方多半要 DispatchQueue.main.async，
        // 但万一它同步回来读 status 就死锁了）。取出来，放锁，再调。
        let notify: ((AudioStatus) -> Void)? = lock.withLock {
            guard _status != new else { return nil }
            _status = new
            return _onStatusChange
        }
        notify?(new)
    }

    /// 只在 `queue` 上调用。
    ///
    /// **`.running` 不等于「在闪」**，这是整个七态存在的理由：管线建好之后，
    /// 「有样本流入」「系统没在放声音」「在放声音却收不到」三种情况下 tap 的
    /// `state` 完全一样。区分它们要靠 `diagnostics()` 里的 `outputIsRunning`
    /// 和 `secondsSinceLastCallback`。
    ///
    /// `diagnostics()` 会调 `AudioActivity.outputIsRunning()`——首次约 80ms，
    /// 所以这个函数**绝不能上主线程**。放在 utility QoS 的 `queue` 上是安全的，
    /// 而且 `AudioTap` 自己的看门狗本来就每 2 秒调一次同一个东西，没有新增成本。
    private func refreshStatus() {
        guard #available(macOS 14.2, *) else { setStatus(.unsupportedOS); return }
        guard let t = tap as? AudioTap else { setStatus(.inactive); return }

        let d = t.diagnostics()
        switch d.state {
        case .idle, .starting:
            stalledPolls = 0
            setStatus(.starting)

        case .unavailable(let why, let timedOut):
            stalledPolls = 0
            setStatus(timedOut ? .needsPermission : .failed(why))

        case .running:
            if let ago = d.secondsSinceLastCallback, ago < 1.0 {
                stalledPolls = 0
                setStatus(.active)
            } else if !d.outputIsRunning {
                stalledPolls = 0
                setStatus(.idleNoAudio)          // 正常，不是故障
            } else {
                stalledPolls += 1
                setStatus(stalledPolls >= 3 ? .stalled : .starting)
            }
        }
    }

    // MARK: - 音频线程

    /// 在 `AudioTap` 的实时线程上调用。不分配、不阻塞、不打日志。
    private func consume(_ ptr: UnsafePointer<Float>, _ n: Int) {
        // 灵敏度变了就现造一个检测器。不在原地改参数：滤波器系数和跟随器系数
        // 都是构造时算好的，中途换等于让状态和系数对不上。
        let (needsNew, p) = lock.withLock { (detectorDirty, params) }
        if needsNew || detector == nil {
            detector = OnsetDetector(sampleRate: 48000, params: p)
            lock.withLock { detectorDirty = false }
        }

        detector?.process(ptr, count: n, into: &scratch)
        guard !scratch.isEmpty else { framesSeen += n; return }

        let now = Date().timeIntervalSinceReferenceDate
        lock.withLock {
            for o in scratch {
                // 起音发生在这个缓冲区的第 offset 个样本上，也就是「现在」往前
                // (n - offset) 个样本。保住采样级精度——这正是把检测放在
                // 音频线程而不是渲染线程的全部理由（20µs vs 16.7ms）。
                let ago = Double(n - o.offset) / 48000
                pending.append((at: now - ago, strength: o.strength))
            }
            // 渲染线程要是卡住了，别让队列无限涨
            if pending.count > 32 { pending.removeFirst(pending.count - 32) }
        }
        framesSeen += n
    }

    /// 只在音频线程上用，避免每个缓冲区都分配
    private var scratch: [OnsetDetector.Onset] = []

    // MARK: - 渲染线程

    func drain() -> [Pulse] {
        let now = Date().timeIntervalSinceReferenceDate
        return lock.withLock {
            lastDrain = Date()
            guard !pending.isEmpty else { return [] }
            let out = pending.map {
                Pulse(secondsAgo: Swift.max(0, now - $0.at), strength: $0.strength)
            }
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
