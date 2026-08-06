import Foundation
import AppKit

/// 「空闲即停」的实现。见 DESIGN.md §3.3——这是硬需求，不是省电优化。
///
/// 理由：能耗未实测，唯一没被覆盖的风险是 60Hz 定时器唤醒阻止 SoC 进入深度空闲，
/// 而这部分代价不体现在 CPU 占用率里。与其去测，不如用结构消除——
/// 引擎只在用户实际可能看着键盘时运行。
///
/// 六个「该停」的信号：系统睡眠、屏幕休眠、锁屏、切换用户、用户长时间无输入，
/// 以及它们各自的恢复事件。
///
/// 「有音频在播放」是**用户在场**的信号，与上面几个并列，不是「音频效果的例外」。
/// 「120 秒无输入」只是「用户不在」的一个代理指标，而戴耳机听歌不碰键鼠是常态，
/// 这个代理在那里恰好失效——效果会在最该亮的时候准时熄灭。
/// 直接问「默认输出设备有没有在出声」比问「键盘有没有被碰过」更接近真实意图。
///
/// 注意这条信号是**收紧**而不是放宽「空闲即停」：音乐一停就立刻回到普通空闲判定，
/// 不额外续 120 秒。能耗上的账也是平的——有声音时音频栈本来就醒着
/// （coreaudiod 正在跑 IO 回调），我们的边际成本远小于凭空把 SoC 从深度空闲里唤醒。
///
/// 它对**所有**效果生效，不只音频律动。只在某个效果下启用，会让
/// 「为什么放着歌呼吸灯还是停了」变成将来一定有人来报的 bug。
@MainActor
final class IdleMonitor {

    /// 参数为「现在是否应该运行」。同一状态不会重复回调。
    var onChange: ((Bool, String) -> Void)?

    private var systemAsleep = false
    private var screensAsleep = false
    private var screenLocked = false

    // `userIdle` 严格是「距上次输入 ≥ 阈值」这一条事实，音频不去改它。
    // 另一种写法是让 userIdle 直接表示「用户不在」（有音频就置 false），两种都能跑，
    // 但那样会让日志说谎：音乐一响就打「用户恢复活动」，而用户其实什么都没碰；
    // 而且轮询节奏是按 userIdle 选的（见 activeInterval / idleInterval），
    // 混进音频后「有音乐 → 5 秒一轮」会把音乐停止的检出延迟从 1 秒拖到 5 秒。
    // 两个标志各管一件事，`shouldRun` 里才做合取。
    private var userIdle = false
    private var audioPlaying = false

    private var idleTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    /// 用户无输入多久算空闲
    var idleThreshold: TimeInterval = 120 {
        didSet { pollUserIdle() }
    }

    var enabled = true {
        didSet {
            if !enabled { userIdle = false }
            // 否则关掉空闲检测后会留下一个 1Hz 的空转定时器
            if idleTimer != nil { schedulePoll(Self.activeInterval) }
            publish(enabled ? "空闲检测已开启" : "空闲检测已关闭")
        }
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: NSNotification.Name,
                     _ body: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(body)
            })
        }
        func observeDistributed(_ name: String, _ body: @escaping () -> Void) {
            observers.append(dc.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(body)
            })
        }

        observe(ws, NSWorkspace.willSleepNotification)      { self.systemAsleep = true;  self.publish("系统睡眠") }
        observe(ws, NSWorkspace.didWakeNotification)        { self.systemAsleep = false; self.publish("系统唤醒") }
        observe(ws, NSWorkspace.screensDidSleepNotification){ self.screensAsleep = true; self.publish("屏幕休眠") }
        observe(ws, NSWorkspace.screensDidWakeNotification) { self.screensAsleep = false;self.publish("屏幕唤醒") }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { self.screenLocked = true;  self.publish("切换用户") }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { self.screenLocked = false; self.publish("会话恢复") }

        observeDistributed("com.apple.screenIsLocked")   { self.screenLocked = true;  self.publish("锁屏") }
        observeDistributed("com.apple.screenIsUnlocked") { self.screenLocked = false; self.publish("解锁") }

        schedulePoll(Self.activeInterval)

        publish("启动")
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        pollInterval = 0
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        for o in observers { ws.removeObserver(o); dc.removeObserver(o) }
        observers.removeAll()
    }

    // 轮询间隔。用高频轮询判断「是否空闲」本身就自相矛盾，所以活跃时 5 秒一次；
    // 但已经判定空闲后要反过来——那时轮询决定的是「多久才恢复」。
    // 按键脉冲效果下 5 秒的恢复延迟等于回来敲的头几个键完全没反应。
    // 空闲期间 1Hz 的开销相对 60Hz 渲染可以忽略，而且此时引擎本来就停着。
    private static let activeInterval: TimeInterval = 5
    private static let idleInterval: TimeInterval = 1

    private func schedulePoll(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        idleTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUserIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func pollUserIdle() {
        guard enabled else { return }
        let idle = systemIdleSeconds()
        let idleNow = idle >= idleThreshold
        // 复用这个轮询，不另开定时器：音频状态只在与 userIdle 合取后才有意义，
        // 两者不同步反而要多想一层。
        //
        // **只在用户已经空闲时才去问音频。** 实测 `outputIsRunning()` 首次调用
        // 要 80.8ms（初始化 HAL 客户端），稳态 p50 29µs。无条件调用会把那 80ms
        // 落在启动路径的主线程上——`idleThreshold.didSet` 在 `start()` 之前就会
        // 触发一次轮询。短路之后，用户不进入空闲状态，进程根本不碰 Core Audio。
        //
        // 代价是 `audioPlaying` 在用户活跃期间是陈旧的（恒为 false）。这是安全的：
        // `shouldRun` 里那一项是 `!(enabled && userIdle && !audioPlaying)`，
        // userIdle 为 false 时整个合取已经为假，audioPlaying 取什么值都不影响结果。
        // 权衡的另一面是调试时看到的标志不总是真实音频状态，所以这里写清楚。
        let audioNow = idleNow && AudioActivity.outputIsRunning()

        let wasHeldByAudio = userIdle && audioPlaying
        guard idleNow != userIdle || audioNow != audioPlaying else { return }
        let audioStopped = audioPlaying && !audioNow
        userIdle = idleNow
        audioPlaying = audioNow

        // 轮询节奏仍然只看 userIdle：无输入时 1Hz，既是「用户回来多快恢复」，
        // 也是「音乐停了多快停机」。有音乐时引擎在跑，1Hz 相对 60Hz 渲染可忽略。
        schedulePoll(idleNow ? Self.idleInterval : Self.activeInterval)

        // 音频接住的这一刻运行状态没变，publish 会去重，于是
        // 「为什么过了 120 秒还没停」在日志里一点痕迹都没有。单独补一行。
        if idleNow && audioNow && !wasHeldByAudio {
            Log.write("用户已 \(Int(idle))s 无输入，但有音频在播放 → 不按空闲停机")
        }

        if !idleNow {
            publish("用户恢复活动")
        } else if audioNow {
            publish("有音频播放")
        } else {
            publish(audioStopped ? "音频停止，用户空闲 \(Int(idle))s" : "用户空闲 \(Int(idle))s")
        }
    }

    /// 距离上一次任意输入事件的秒数
    private func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // 音频只抵消 `userIdle` 这一项，故意**不**参与前三项：睡眠 / 息屏 / 锁屏
    // 是「用户不在看键盘」的直接证据，而锁屏后继续放歌恰恰是最常见的情形。
    // 想让音乐把锁屏时的灯也点亮，方向就反了。
    private var shouldRun: Bool {
        !systemAsleep && !screensAsleep && !screenLocked
            && !(enabled && userIdle && !audioPlaying)
    }

    private func publish(_ reason: String) {
        let now = shouldRun
        guard now != lastReported else { return }
        lastReported = now
        onChange?(now, reason)
    }
}
