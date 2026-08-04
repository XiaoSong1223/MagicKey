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
@MainActor
final class IdleMonitor {

    /// 参数为「现在是否应该运行」。同一状态不会重复回调。
    var onChange: ((Bool, String) -> Void)?

    private var systemAsleep = false
    private var screensAsleep = false
    private var screenLocked = false
    private var userIdle = false

    private var idleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    /// 用户无输入多久算空闲
    var idleThreshold: TimeInterval = 120 {
        didSet { pollUserIdle() }
    }

    var enabled = true {
        didSet {
            if !enabled { userIdle = false }
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

        // 用户无输入检测。5 秒一次 = 0.2Hz，开销可忽略；
        // 用高频轮询来判断「是否空闲」本身就自相矛盾。
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUserIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t

        publish("启动")
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        for o in observers { ws.removeObserver(o); dc.removeObserver(o) }
        observers.removeAll()
    }

    private func pollUserIdle() {
        guard enabled else { return }
        let idle = systemIdleSeconds()
        let now = idle >= idleThreshold
        if now != userIdle {
            userIdle = now
            publish(now ? "用户空闲 \(Int(idle))s" : "用户恢复活动")
        }
    }

    /// 距离上一次任意输入事件的秒数
    private func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private var shouldRun: Bool {
        !systemAsleep && !screensAsleep && !screenLocked && !(enabled && userIdle)
    }

    private func publish(_ reason: String) {
        let now = shouldRun
        guard now != lastReported else { return }
        lastReported = now
        onChange?(now, reason)
    }
}
