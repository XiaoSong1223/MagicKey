import SwiftUI
import AppKit
import Combine

/// **不用 `MenuBarExtra`。** 它的面板窗口只涨不缩：展开「高级」把窗口撑高之后，
/// 收回、切换效果、甚至关掉重开都停在最高那次的高度，下面留一大片空白。
/// 探针实测确认这是 `MenuBarExtra` 自身的行为（不套 ScrollView 的对照组一样，
/// `.id()` 强制重建也无效），而同样的视图放进 `NSPopover` 是双向跟随的
/// （620 → 519 → 347）。代价只是自己管一个 NSStatusItem。
@main
enum Main {
    /// `NSApplication.delegate` 是弱引用，必须自己留一份强引用
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let d = MainActor.assumeIsolated { AppDelegate() }
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {

    private static let statusItemAutosaveName = "MagicKey.StatusItem"

    let settings: Settings
    let engine: Engine
    let updates = UpdateChecker()
    private let idle = IdleMonitor()
    private var cancellables: [Any] = []
    private var signalSources: [DispatchSourceSignal] = []

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusImages: [Bool: NSImage] = [:]

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
        setUpMenuBar()

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

    // MARK: - 菜单栏

    private func setUpMenuBar() {
        popover.behavior = .transient          // 点面板外面就关，和菜单一致
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(settings: settings, engine: engine, updates: updates))

        // autosaveName 让菜单栏位置在重装/重建之间稳定下来。**别再往这里加
        // 「修复可见性」的代码**：图标不显示是控制中心按 bundle id 把它记进了
        // blocked list，进程内看到的 isVisible 仍然是 true，怎么写都没用。
        // 诊断方法和已经排除掉的一长串做法见 CLAUDE.md「状态栏图标不显示」。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.statusItemAutosaveName
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        updateIcon()

        // 图标要跟着运行状态变。Engine 的 isRunning 是 private(set)，
        // 拿不到 $isRunning，所以订阅 objectWillChange——它在 didSet 之前触发，
        // 推迟一个 runloop 再读，否则拿到的是旧值（同 syncFromSettings）。
        cancellables.append(engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        })
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // 全屏时按钮的锚点会失效，且有**两种**失效方式，都实测过：
        //   ① 挪到所有屏幕之外——button.window?.screen == nil，锚点矩形 y=1114.5
        //      而两块屏最高才 1080。面板被甩到主屏左上角还被屏幕边缘裁掉。
        //   ② 停在**另一块屏**上——外接屏全屏时按钮窗口留在内建屏，
        //      锚点「在某块屏幕上」这个检查照样通过，面板就开到左边那块屏去了。
        // 所以判据不是「锚点在不在屏幕上」，而是「**在不在用户刚点的那块屏上**」。
        if buttonAnchorIsUsable(button) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            showPanelNearMouse(statusBarHeight: button.window?.frame.height)
        }
        // 面板里全是滑块，打开就要能直接拖，所以得让本进程拿到焦点
        NSApp.activate()
    }

    /// 按钮锚点能不能用：必须落在**用户刚点击的那块屏**上。
    /// 只验「在不在某块屏幕上」不够——外接屏全屏时按钮停在内建屏，那个检查会放行。
    private func buttonAnchorIsUsable(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.screen != nil else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let clicked = clickedScreen() else {
            return NSScreen.screens.contains { $0.frame.intersects(rect) }
        }
        return clicked.frame.intersects(rect)
    }

    /// 用户刚点完图标，指针就停在图标上，指针所在屏就是他点的那块屏
    private func clickedScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    /// 锚点失效时的退路：改用指针位置。用一个透明小窗口当锚，
    /// 因为 `show(relativeTo:of:)` 只认视图，不收裸矩形。
    private func showPanelNearMouse(statusBarHeight: CGFloat?) {
        let mouse = NSEvent.mouseLocation
        guard let screen = clickedScreen() ?? NSScreen.main else { return }

        let window = anchorWindow
        // 贴着菜单栏下沿，水平对齐指针。普通 Space 里 visibleFrame.maxY
        // 就是菜单栏下沿；但全屏 Space 里 visibleFrame == frame，直接用
        // visibleFrame.maxY 会把整个 2pt 锚点放到屏幕外，NSPopover 随后会被
        // 约束回主屏。用状态栏窗口的真实高度补回全屏时丢掉的上边距；
        // NSStatusBar.thickness 只作为窗口不可用时的保底。
        let menuBarHeight = max(statusBarHeight ?? 0, NSStatusBar.system.thickness)
        let menuBarBottom = screen.frame.maxY - menuBarHeight
        let anchorSize = NSSize(width: 2, height: 2)
        let anchorX = min(max(mouse.x - anchorSize.width / 2, screen.frame.minX),
                          screen.frame.maxX - anchorSize.width)
        let anchorY = max(screen.frame.minY,
                          min(min(screen.visibleFrame.maxY, menuBarBottom),
                              screen.frame.maxY - anchorSize.height))
        window.setFrame(NSRect(origin: NSPoint(x: anchorX, y: anchorY), size: anchorSize),
                        display: false)
        window.orderFrontRegardless()
        guard let anchor = window.contentView else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private lazy var anchorWindow: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar          // 和菜单栏同层，全屏空间里也在
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSView()
        return w
    }()

    func popoverDidClose(_ notification: Notification) {
        anchorWindow.orderOut(nil)
    }

    /// 运行时用实心图标，停止时用线框，一眼能看出状态
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isRunning = engine.isRunning
        let label = isRunning ? "MagicKey 正在运行" : "MagicKey 已停止"
        let image = customStatusImage(isRunning: isRunning) ?? NSImage(
            systemSymbolName: isRunning ? "keyboard.fill" : "keyboard",
            accessibilityDescription: label)

        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func customStatusImage(isRunning: Bool) -> NSImage? {
        if let cached = statusImages[isRunning] { return cached }

        let name = isRunning ? "StatusKeyActive" : "StatusKeyInactive"
        let size = NSSize(width: 18, height: 18)
        // 让 AppKit 从应用包按名称加载 1x/@2x 表示。macOS 26 会把状态项
        // 托管给 Control Center；直接使用 bundle-backed NSImage 才能稳定地
        // 复制到外接显示器，运行时拼装 NSBitmapImageRep 会丢失状态项副本。
        guard let image = Bundle.main.image(forResource: NSImage.Name(name)) else { return nil }
        image.size = size
        image.isTemplate = true
        statusImages[isRunning] = image
        return image
    }

    private func syncFromSettings() {
        // 更新检查的开关也在这里收敛，不放到视图的 onChange 里——
        // 生命周期由持有者管，视图只负责显示。startAuto/stopAuto 都是幂等的。
        settings.autoCheckUpdates ? updates.startAuto() : updates.stopAuto()

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
