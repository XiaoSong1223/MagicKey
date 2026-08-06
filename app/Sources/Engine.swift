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

    @Published private(set) var isRunning = false
    @Published private(set) var status = "未启动"
    @Published private(set) var available = true

    private var driver: CoreBrightnessDriver?
    private var guardian: StateGuard?

    private let queue = DispatchQueue(label: "com.magickey.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var state: RenderState?          // 只在 queue 上读写

    private var userWants = false
    private var conditionsOK = true

    private var makeEffect: (() -> Effect)?
    private var fps: Double = 60
    private var baseLevel: Float = 0.85

    // MARK: - 生命周期

    init() {
        guard let d = CoreBrightnessDriver() else {
            available = false
            status = "此 macOS 版本不受支持"
            return
        }
        driver = d
        let g = StateGuard(driver: d, namespace: "app")
        // 上次没干净退出（崩溃、强制退出）时，先把系统还原回去再继续
        g.recoverFromPreviousCrashIfNeeded()
        guardian = g
        status = "已就绪"
    }

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
