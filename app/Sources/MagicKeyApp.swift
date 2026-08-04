import SwiftUI
import AppKit

@main
struct MagicKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: delegate.settings, engine: delegate.engine)
        } label: {
            // 运行时用实心图标，停止时用线框，一眼能看出状态
            Image(systemName: delegate.engine.isRunning ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    let settings: Settings
    let engine: Engine
    private let idle = IdleMonitor()
    private var cancellables: [Any] = []
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        // 必须在 Engine() 之前——引擎构造时就会做崩溃恢复并输出日志，
        // 放到 applicationDidFinishLaunching 里就晚了，那几行会漏掉。
        Log.sink = { NSLog("[MagicKey] %@", $0) }
        settings = Settings()
        engine = Engine()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        idle.onChange = { [weak self] ok, reason in
            self?.engine.setConditions(ok: ok, reason: reason)
        }
        idle.enabled = settings.stopWhenIdle
        idle.idleThreshold = settings.idleSeconds
        idle.start()

        // 设置任一项变化就重新收敛引擎状态。
        // Settings 的属性都是 @Published，objectWillChange 在 didSet 之前触发，
        // 所以这里推迟一个 runloop 再读，否则拿到的是旧值。
        cancellables.append(
            settings.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncFromSettings() }
            }
        )
        syncFromSettings()
    }

    private func syncFromSettings() {
        idle.enabled = settings.stopWhenIdle
        idle.idleThreshold = settings.idleSeconds
        engine.apply(settings)
    }

    /// Cocoa 应用默认不处理 SIGTERM——`killall`、`pkill`、部分注销/关机路径
    /// 都不会走 applicationWillTerminate，状态就留在「ALS 已关闭」上。
    /// 实测确认过：pkill 之后下次启动会报「检测到上次未干净退出」。
    /// 崩溃恢复能兜底，但用户若不再打开本应用就一直恢复不了，所以必须显式处理。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)          // 屏蔽默认行为，改由 DispatchSource 接管
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.engine.shutdown(reason: "收到终止信号")
                    self?.idle.stop()
                    exit(0)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// 正常退出路径。六个还原时机之一——其余五个由 StateGuard、IdleMonitor
    /// 和上面的信号处理覆盖。
    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown(reason: "应用退出")
        idle.stop()
    }

    /// 菜单栏应用没有窗口，关掉最后一个窗口不该退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
