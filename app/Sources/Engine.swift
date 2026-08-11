import Foundation
import Combine

/// 渲染循环独占的状态。只在渲染队列上访问，绝不从主线程碰。
///
/// 单独开一个类是为了避免「@MainActor 的属性被渲染队列读写」这种竞态——
/// 编译器在 -swift-version 5 下不会拦，但它是真的错。
private final class RenderState {
    let stack: EffectStack
    let startedAt: Date
    let base: Float
    var frame: UInt64 = 0

    init(stack: EffectStack, base: Float) {
        self.stack = stack
        self.startedAt = Date()
        self.base = base
    }
}

/// 渲染引擎。原型里散在 main.swift 顶层的循环，在这里收成一个有生命周期的对象。
///
/// 两个正交的开关：
///   - `userWants`    —— 用户在菜单里开没开
///   - `conditionsOK` —— IdleMonitor 说现在该不该跑
///
/// 两者同时为真才真正运行。分开是必要的：用户开着但屏幕休眠时要停，
/// 屏幕唤醒后要自动恢复，而不是要求用户手动再点一次。
@MainActor
final class Engine: ObservableObject {

    /// UI 用的结构化状态。
    ///
    /// **为什么不让界面去解析 `status` 字符串。** `status` 是给日志和调试看的
    /// 自由文本（"运行中 · 60fps"、"已暂停（锁屏）"）；界面要拿它决定色点颜色，
    /// 就只能 `hasPrefix("已暂停")`，以后改一个字就静默错色。两者的受众不同，
    /// 所以并存而不是二选一：`status` 一个字都没改，`phase` 是新加的。
    enum Phase: Equatable {
        /// 驱动探测失败。相关控件要禁用
        case unsupported
        /// 用户主动关掉了
        case stopped
        /// 用户开着，但条件不满足（锁屏/息屏/空闲）。**总开关保持开启**，
        /// 条件恢复时自动继续，不需要用户再点一次
        case paused(String)
        case running
    }

    @Published private(set) var isRunning = false
    @Published private(set) var status = "未启动"
    @Published private(set) var available = true
    @Published private(set) var phase: Phase = .stopped

    private var driver: CoreBrightnessDriver?
    private var guardian: StateGuard?

    private let queue = DispatchQueue(label: "com.magickey.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var state: RenderState?          // 只在 queue 上读写

    private var userWants = false
    private var conditionsOK = true

    /// 最近一次**条件**变化的原因，只由 `setConditions` 写。
    ///
    /// 不能直接用 `reconcile(reason:)` 的参数来做「已暂停 · 原因」：那个参数
    /// 也可能是 `apply(_:)` 传来的"设置变更"。锁屏期间拖一下亮度滑块，
    /// 界面就会从「已暂停 · 锁屏」翻成「已暂停 · 设置变更」——原因被顶掉了。
    /// （`status` 字符串至今有这个毛病，这次不动它，只保证 `phase` 是对的。）
    private var conditionsReason = "启动"

    private var makeEffect: (() -> Effect)?
    private var fps: Double = 60
    private var baseLevel: Float = 0.85

    // MARK: - 生命周期

    init() {
        guard let d = CoreBrightnessDriver() else {
            available = false
            status = "此 macOS 版本不受支持"
            phase = .unsupported
            return
        }
        driver = d
        let g = StateGuard(driver: d, namespace: "app")
        // 上次没干净退出（崩溃、强制退出）时，先把系统还原回去再继续
        g.recoverFromPreviousCrashIfNeeded()
        guardian = g
        status = "已就绪"
    }

    #if UI_PROBE
    /// **只在 UI 探针里编译。** `app/Makefile` 的正式目标不带 `-D UI_PROBE`，
    /// 所以这段代码不会进入发布的二进制——不是「测试代码留在生产里但没人调用」，
    /// 是真的编译不到。
    ///
    /// 不走正常 `init()` 的理由是 `StateGuard`：正常路径会跑一次
    /// `recoverFromPreviousCrashIfNeeded()`，那会**清掉正在运行的那个 MagicKey
    /// 的崩溃恢复标记**。探针只是要摆一个界面出来看，不该有这种副作用。
    init(probe phase: Phase) {
        self.phase = phase
        switch phase {
        case .unsupported:
            available = false; isRunning = false; status = "此 macOS 版本不受支持"
        case .stopped:
            isRunning = false; status = "已停止"
        case .paused(let why):
            isRunning = false; status = "已暂停（\(why)）"
        case .running:
            isRunning = true;  status = "运行中 · 60fps"
        }
    }

    /// 探针切状态用。真实的 Engine 只有一个实例、靠 `reconcile` 改 phase，
    /// 探针也必须只有一个实例——换 `Engine` 对象就得换 `NSHostingController`，
    /// 而**换控制器的 NSPopover 不会重算尺寸**，量出来的高度会全是上一次的。
    func setProbePhase(_ p: Phase) {
        phase = p
        available = p != .unsupported
        isRunning = p == .running
        switch p {
        case .unsupported:   status = "此 macOS 版本不受支持"
        case .stopped:       status = "已停止"
        case .paused(let w): status = "已暂停（\(w)）"
        case .running:       status = "运行中 · 60fps"
        }
    }
    #endif

    // MARK: - 外部输入

    func apply(_ s: Settings) {
        makeEffect = { s.makeEffect() }
        fps = s.fps
        baseLevel = Float(s.hi)
        userWants = s.enabled
        reconcile(reason: "设置变更")
    }

    func setConditions(ok: Bool, reason: String) {
        guard conditionsOK != ok else { return }
        conditionsOK = ok
        conditionsReason = reason
        reconcile(reason: reason)
    }

    /// 退出、睡眠等终止路径。必须同步完成还原，不能异步派发——
    /// applicationWillTerminate 返回后进程就没了。
    func shutdown(reason: String) {
        stopLoop()
        // 音频采集不靠「没人 drain 就自停」的看门狗来收——那要等 3 秒，
        // 而 applicationWillTerminate 返回后进程就没了。显式关一次。
        BeatPulseSource.shared.deactivate()
        guardian?.restore(reason: reason)
        isRunning = false
        status = "已还原（\(reason)）"
        phase = .stopped
    }

    // MARK: - 状态收敛

    private func reconcile(reason: String) {
        guard available else { return }
        let should = userWants && conditionsOK

        switch (should, isRunning) {
        case (true, false):
            startLoop()
            isRunning = true
            status = "运行中 · \(Int(fps))fps"

        case (false, true):
            stopLoop()
            guardian?.restore(reason: reason)
            isRunning = false
            status = userWants ? "已暂停（\(reason)）" : "已停止"

        case (true, true):
            // 参数变了：重建效果和定时器，但不动接管状态
            installState()
            rescheduleTimer()
            status = "运行中 · \(Int(fps))fps"

        case (false, false):
            status = userWants ? "已暂停（\(reason)）" : "已停止"
        }

        // 四个分支的 phase 是同一个式子，所以收在这里算一次。
        // 注意用 conditionsReason 而不是 reason——理由见它的声明。
        phase = should ? .running
              : userWants ? .paused(conditionsReason)
              : .stopped
    }

    private func installState() {
        guard let make = makeEffect else { return }
        let fresh = RenderState(stack: EffectStack(base: make()), base: baseLevel)
        queue.sync { self.state = fresh }
    }

    private func startLoop() {
        guard let driver, let guardian else { return }

        guardian.capture()
        guardian.takeOver()          // 关掉 ALS 和闲置调暗，否则它们会覆盖我们的输出

        installState()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in
            // 全程在 queue 上：state 与 driver 都只有这一个写入者
            guard let self, let st = self.state else { return }
            let ctx = FrameContext(time: Date().timeIntervalSince(st.startedAt),
                                   frame: st.frame, base: st.base)
            driver.writeBrightness(st.stack.render(ctx))
            st.frame &+= 1
        }
        timer = t
        rescheduleTimer()
        t.resume()
    }

    private func rescheduleTimer() {
        timer?.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(2))
    }

    private func stopLoop() {
        timer?.cancel()
        timer = nil
        queue.sync { self.state = nil }   // 等最后一帧写完，否则还原会被它覆盖
    }
}
