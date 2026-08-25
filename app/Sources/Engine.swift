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

    /// 最近一次「不该跑」的结构化原因。`flash` 靠它区分「用户离开了」（可以闪）
    /// 和「屏幕锁着」（丢弃）。见 `PauseCause`。
    private var conditionsCause: PauseCause?

    // MARK: 瞬时层

    /// 还没播完的瞬时效果 + 各自的到期时刻。
    ///
    /// **主线程只存到期时刻，不问效果「你播完了吗」**——那是渲染队列独占的状态，
    /// 隔着线程去问就是数据竞争。理由见 `TransientEffect`。
    private var liveTransients: [(effect: Effect, endsAt: Date)] = []

    /// 正在临时接管（引擎本来停着，为了播一次 flash 临时把背光借过来）
    private var takingOver = false

    /// 作废「还没跑到的那个收尾闭包」用。每次开始/结束接管都 +1，
    /// 收尾闭包只在号码还对得上时才动手——比拿着一个可取消的定时器简单得多。
    private var takeoverToken = 0

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

    /// 上一次**实际生效**的渲染输入。见 `apply(_:)`。
    /// nil = 还没 apply 过，第一次必定当成「变了」。
    private var lastInputs: RenderInputs?

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

    /// 渲染状态被重建了多少次。**这是「设置变化 → 要不要重建」那条链路的硬判据。**
    ///
    /// 为什么必须是它，别的量都不行：在「本来就在跑、只是参数变了」这一支里
    /// `isRunning` / `status` / `phase` **完全不变**，从外面看无关属性和相关属性
    /// 长得一模一样——正因如此那个 bug 活了这么久（面板探针只量尺寸，
    /// `--analyze` 只跑纯效果函数，整条 `Engine` 收敛逻辑此前零覆盖）。
    /// 重建计数是唯一能把两者分开的东西。
    private(set) var probeInstallCount = 0

    /// 当前渲染状态的相位基准。重建 → 变；没重建 → 一纳秒都不差。
    /// 和 `probeInstallCount` 并列，因为「重建了几次」和「相位归没归零」
    /// 是两件事：前者是机制，后者才是用户看见的那一下闪。
    var probeStartedAt: Date? { queue.sync { self.state?.startedAt } }

    /// 还挂着几个没播完的瞬时效果。「播完自动出栈」「重建后被重挂」这两件事
    /// 在输出曲线上都看不出来（播完之后输出本来就该等于底色），只能直接数。
    var probeTransientCount: Int { queue.sync { self.state?.stack.transientCount ?? 0 } }

    /// 交还时刻。真接管要驱动，探针里跑不起来，但**这个计算**测得到——
    /// 而「追加一个短 flash 会不会把前一个截断」正好全落在这个计算上。
    var probeTakeoverDeadline: Date? { takeoverDeadline }
    #endif

    // MARK: - 外部输入

    /// 设置变了，重新收敛。由 `AppDelegate.syncFromSettings` 调用，**幂等**。
    ///
    /// ## 为什么这里必须做变化检测
    ///
    /// 调用方订阅的是 `settings.objectWillChange`——**任何一个** `@Published`
    /// 属性变化都会走到这里，包括键盘音效音量、音色包、自动检查更新这些
    /// 和背光毫无关系的项。而下面的 `reconcile` 在「本来就在跑」的分支里会
    /// `installState()`，那会新建 `RenderState`，其 `startedAt = Date()`。
    ///
    /// 后果是肉眼可见的：**拖一下键盘音效的音量滑块，正在跑的呼吸会跳到最暗
    /// 重新开始**（相位归零）。那个滑块是二十档吸附的，拖过去就是十几次重建。
    /// 音乐律动更糟一点——`PulseEffect.live` 里正在衰减的脉冲被整个丢掉，
    /// 亮着的光会在半途断掉。
    ///
    /// `sensitivity` 刻意**不在** `RenderInputs` 里：它直推已经在跑的检测器
    /// （`Settings.sensitivity` 的 didSet），重建效果只会白白打断正在衰减的脉冲，
    /// 而 tap 本来就不会被重建。那条注释写了很久，但一直被这里的全量重建架空。
    func apply(_ s: Settings) {
        let inputs = s.renderInputs
        // 无关属性变化：一个字节都不碰。**连 status/phase 都不该动**——
        // 它们是这几个输入的函数，输入没变结论就没变。
        guard inputs != lastInputs else { return }
        lastInputs = inputs

        makeEffect = { s.makeEffect() }
        fps = s.fps
        baseLevel = Float(s.hi)
        userWants = s.enabled
        reconcile(reason: "设置变更")
    }

    /// - Parameter cause: 不该跑的话是因为什么。**结构化，不要从 `reason` 反推**，
    ///   理由见 `PauseCause`。`ok == true` 时恒为 nil。
    func setConditions(ok: Bool, cause: PauseCause?, reason: String) {
        // 去重看 (能不能跑, 原因) 这一对：「空闲 120s」之后再「锁屏」，
        // 只看 Bool 的话原因会一直停在 `.userIdle`，flash 就会在锁屏时照闪。
        guard conditionsOK != ok || conditionsCause != cause else { return }
        conditionsOK = ok
        conditionsCause = cause
        conditionsReason = reason
        // 屏幕在 flash 播到一半时锁掉/睡掉：立刻交还，别把亮度留在闪光的半途。
        if cause == .displayUnavailable { endTakeover(reason: "屏幕不可用") }
        reconcile(reason: reason)
    }

    // MARK: - 瞬时命令

    /// 闪 N 下。CLI / URL Scheme 的 `flash` 动词，以及将来任何「通知一下」的入口。
    ///
    /// 三种状态，行为完全不同：
    ///
    ///   a. **引擎正在渲染** → 直接挂到瞬时层，叠在当前效果上（blend `.max`），
    ///      底色照跑不断。
    ///   b. **停着**（总开关关，或空闲停表） → **临时接管**：抓快照、借走背光、
    ///      只跑这一下、播完还回去。这是 flash 存在的主要场景——多数人平时
    ///      根本没开效果，`npm run build && magickey flash` 也该看得见。
    ///   c. **屏幕不可用**（锁屏/息屏/睡眠） → 静默丢弃 + 日志。闪给谁看，
    ///      而且会把已经睡下的 SoC 叫醒。
    func flash(times: Int) {
        let fx = FlashEffect(times: times)
        switch flashDisposition {
        case .discard(let why):                                 // c
            Log.write("[flash] \(why)，丢弃")

        case .overlay:                                          // a
            pushTransient(fx)
            Log.write("[flash] ×\(fx.times) 叠加在运行中的效果上")

        case .appendToTakeover:
            // 接管期间又来一发：挂上去并**重算**交还时刻，别在半途还权。
            pushTransient(fx)
            scheduleTakeoverEnd()
            Log.write("[flash] ×\(fx.times) 追加到正在进行的临时接管")

        case .takeover:                                         // b
            beginTakeover(with: fx)
        }
    }

    /// flash 这一下该怎么处理。
    ///
    /// **单独抽出来是为了让它可回归。** 揉在 `flash(times:)` 里的话，
    /// 「锁屏时会不会丢弃」就只能靠真的去锁一次屏来验——而那正是最不该出错
    /// 又最不可能有人反复手测的一条（错的那一侧是「锁着屏还在闪」，
    /// 没有任何用户会来报这个 bug）。
    var flashDisposition: FlashDisposition {
        guard available else { return .discard("背光不可用") }
        // 判据是结构化的 `conditionsCause`，**不是** `conditionsReason` 字符串，
        // 理由见 `PauseCause`。
        switch conditionsCause {
        case .displayUnavailable:
            return .discard("屏幕不可用（\(conditionsReason)）")
        case .lowPower:
            // 低电量下**不穿透**：用户刚刚明确要求这台机器省电，
            // 而 flash 恰恰要把停着的渲染循环重新拉起来。和锁屏是两个理由、
            // 同一个结论——所以文案分开写，日志里要看得出是哪一个。
            return .discard("低电量模式")
        case .userIdle, nil:
            break
        }
        if isRunning { return .overlay }
        if takingOver { return .appendToTakeover }
        return .takeover
    }

    enum FlashDisposition: Equatable {
        /// 引擎正在渲染 → 挂到瞬时层，叠在当前效果上
        case overlay
        /// 引擎停着（总开关关，或空闲停表）→ 临时借走背光，播完还回去
        case takeover
        /// 已经在临时接管中 → 追加，并把交还时刻往后推
        case appendToTakeover
        /// 丢弃，带原因
        case discard(String)
    }

    /// 把一个瞬时效果挂到渲染栈上。播完由 `EffectStack` 自动摘掉。
    ///
    /// 主线程这边额外记一笔到期时刻，只为了一件事：**渲染状态被重建时能重新挂上去**。
    /// 阶段 1 的变化检测已经挡掉了绝大多数无谓重建，但用户确实可能在 flash
    /// 播到一半时去改效果或亮度——那一下不该把 flash 吞掉。
    func pushTransient(_ fx: TransientEffect) {
        pruneTransients()
        liveTransients.append((fx, Date().addingTimeInterval(fx.duration)))
        queue.sync { self.state?.stack.push(fx) }
    }

    private func pruneTransients() {
        let now = Date()
        liveTransients.removeAll { $0.endsAt <= now }
    }

    /// b. 临时接管：引擎本来停着，为了播一次 flash 把背光借过来。
    ///
    /// **崩溃恢复语义在这里是完整的**：`capture()` 一落盘，磁盘上就是用户
    /// flash 之前的原始状态。接管期间崩溃/被 kill，下次启动照样还原到那个值——
    /// 和引擎正常运行时崩溃走的是同一条路。
    private func beginTakeover(with fx: FlashEffect) {
        guard let driver, let guardian, timer == nil else { return }

        // 基底 = 借走那一刻的亮度。用户原本亮着多少就还亮着多少，flash 从上面冲过去；
        // 用 0 当基底的话，一个平时开着背光的人会看到键盘先黑一下——那不是闪，是闪断。
        let level = driver.readBrightness()
        guardian.capture()
        guardian.takeOver()

        // 接管的栈是全新的，之前登记过的瞬时效果**都不在里面**——不清掉的话
        // `takeoverDeadline` 会把它们的到期时刻也算进去，接管被凭空拉长。
        // 不变量：`liveTransients` 必须严格对应**当前这个栈**里挂着的东西。
        liveTransients.removeAll()

        let stack = EffectStack(base: StaticEffect(level: level))
        queue.sync { self.state = RenderState(stack: stack, base: level) }

        // 接管恒定 60fps，**不跟省电模式**：整个过程不到一秒，而 30fps 下
        // 40ms 的起手只剩 1.2 帧，上升沿画不出来，闪光会变成一次生硬的跳变。
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in
            guard let self, let st = self.state else { return }
            let ctx = FrameContext(time: Date().timeIntervalSince(st.startedAt),
                                   frame: st.frame, base: st.base)
            driver.writeBrightness(st.stack.render(ctx))
            st.frame &+= 1
        }
        timer = t
        t.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(2))
        t.resume()

        takingOver = true
        Log.write(String(format: "[flash] ×%d 临时接管（引擎%@，基底亮度 %.3f）",
                         fx.times, userWants ? "已暂停" : "已关闭", level))
        // 走和追加同一条路：登记到期时刻 + 按最晚那个安排交还。
        // 两条路分开写的话，`beginTakeover` 那份迟早会和这份漂。
        pushTransient(fx)
        scheduleTakeoverEnd()
    }

    /// 交还时刻 = 还没播完的瞬时效果里**最晚**的那个到期时刻。
    ///
    /// 抽成一个属性是为了可回归：真接管需要驱动，探针里跑不起来，
    /// 但这个**计算**测得到。见 `probeTakeoverDeadline`。
    private var takeoverDeadline: Date? { liveTransients.map(\.endsAt).max() }

    /// 安排交还。重复调用会作废上一次的安排（`takeoverToken`）。
    ///
    /// ⚠️ **必须按 `takeoverDeadline` 算，不能按「刚追加的那个的时长」算。**
    /// 前一个 ×10（2.72s）还剩 2 秒时追加一个 ×1（0.2s），按新的那个算就会把
    /// 交还提前到 0.25s——前一个被拦腰截断，背光在闪光半途被还原回去。
    /// 这个 bug 在真机上表现为「连着发两次 flash，第一次没闪完就断了」，
    /// 而单发怎么测都是对的。
    private func scheduleTakeoverEnd() {
        pruneTransients()
        guard let deadline = takeoverDeadline else {
            // 没有待播的了（全过期）——直接还权，别把接管挂在那儿
            endTakeover(reason: "没有待播的瞬时效果")
            return
        }
        takeoverToken &+= 1
        let token = takeoverToken
        // 多给一帧的余量，让最后一帧（已经回到基底的那一帧）写完再还权，
        // 否则还原会和它撞上，键盘可能停在闪光的尾巴上。
        let delay = Swift.max(0, deadline.timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.takeoverToken == token else { return }
            self.endTakeover(reason: "flash 播完")
        }
    }

    /// 交还背光。幂等。
    ///
    /// 三个地方会调它，每个都必须调：引擎要启动了（`startLoop`）、
    /// 屏幕不可用了（`setConditions`）、进程要退出了（`shutdown`）。
    /// 漏掉任何一个，那一路都会在「还借着别人的背光」的状态下往下走——
    /// 最难看的是 `startLoop`：它会把**正在闪的那个亮度**当成用户的原始状态存进快照。
    private func endTakeover(reason: String) {
        guard takingOver else { return }
        takingOver = false
        takeoverToken &+= 1        // 作废还没跑到的收尾闭包
        liveTransients.removeAll()
        stopLoop()
        guardian?.restore(reason: reason)
        Log.write("[flash] 临时接管结束（\(reason)），背光已交还")
    }

    // MARK: - 生命周期（续）

    /// 退出、睡眠等终止路径。必须同步完成还原，不能异步派发——
    /// applicationWillTerminate 返回后进程就没了。
    func shutdown(reason: String) {
        endTakeover(reason: reason)
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
        // 没播完的瞬时效果要跟着搬过去，否则「flash 期间改了个设置」会把它吞掉。
        // 重挂的是**同一个实例**，它自己会处理 `ctx.time` 跳回 0 这件事
        // （`FlashEffect.elapsed` 用增量累加），进度不丢。
        pruneTransients()
        for t in liveTransients { fresh.stack.push(t.effect) }
        queue.sync { self.state = fresh }
        #if UI_PROBE
        probeInstallCount += 1
        #endif
    }

    private func startLoop() {
        guard let driver, let guardian else { return }

        // **必须在 capture 之前。** 还借着背光的时候去抓快照，抓到的是
        // 闪光半途的亮度，那个值会被当成「用户的原始状态」存进崩溃快照，
        // 而且引擎停下来时会把键盘还原成那个亮度。
        endTakeover(reason: "引擎启动")

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
