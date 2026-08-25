import SwiftUI
import AppKit
import Combine
import os

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

        // **必须在 `AppDelegate()` 之前。** `Engine()` 是它的存储属性，
        // 构造时就会跑 `recoverFromPreviousCrashIfNeeded()`——那会把**正在运行的
        // 那个实例**的崩溃快照还原掉并删除文件。晚一行都来不及，理由见 `AppInstance`。
        if AppInstance.anotherIsRunning() { exit(0) }

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
    let audio = AudioStatusModel()
    /// 键盘敲击音效。**独立于 `engine`**：不共享事件流、不共享生命周期，
    /// 背光不可用时它照样能用。
    let keySound = KeySoundController()
    let metrics = PanelMetrics()
    private let idle = IdleMonitor()
    private var cancellables: [Any] = []
    private var signalSources: [DispatchSourceSignal] = []

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// 面板的宿主，show 之前要叫它同步一次尺寸，见 `PanelHostingController`
    private var panelHost: (any PanelSizeSyncing)?
    private var statusImages: [Bool: NSImage] = [:]

    override init() {
        // 必须在 Engine() 之前——引擎构造时就会做崩溃恢复并输出日志，
        // 放到 applicationDidFinishLaunching 里就晚了，那几行会漏掉。
        //
        // logger 本体在 `AppInstance`：单实例检查比这里还早（`Main.main` 里，
        // `AppDelegate()` 之前），它的日志也得有地方去，一个应用留一个 logger。
        Log.sink = { AppInstance.logger.notice("\($0, privacy: .public)") }
        settings = Settings()
        engine = Engine()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        installMainMenu()
        setUpMenuBar()

        idle.onChange = { [weak self] ok, cause, reason in
            self?.engine.setConditions(ok: ok, cause: cause, reason: reason)
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

        // 音色库或指键一变就把自定义层重建一遍，否则用户在键盘图上点完，
        // 得关掉音效开关再打开才生效。只推给 keySound，不走 syncFromSettings——
        // 背光引擎和这件事毫无关系，没必要陪着收敛一次。
        cancellables.append(
            CustomSoundStore.shared.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.keySound.apply(self.settings)
                }
            }
        )
        syncFromSettings()

        // 引擎已经就绪，可以放行 URL 了。见 `pendingURLs`。
        launched = true
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handle(url) }
    }

    // MARK: - URL Scheme

    /// 冷启动时收到但还没处理的 URL。
    ///
    /// **非有不可**：`open magickey://flash` 在 app 没跑的时候会先把 app 启动起来，
    /// 而 AppKit 派发 `application(_:open:)` 的时机**早于**
    /// `applicationDidFinishLaunching`。那时 `engine.apply(settings)` 还没跑过，
    /// `makeEffect` 是 nil、`userWants` 还是 false、IdleMonitor 一次条件都还没报——
    /// 直接执行的话 flash 会落进一个「什么都还没定」的引擎里。
    ///
    /// 缓存到 `didFinishLaunching` 末尾再重放，代价是几十毫秒，换来的是
    /// 「冷启动和热启动走同一条路」。
    private var pendingURLs: [URL] = []
    private var launched = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url) }
    }

    /// 执行一条 URL 命令。
    ///
    /// **解析在 `URLCommand.parse`，这里只负责动手**——分开是为了让解析
    /// 变成可回归的纯函数，见那边的类型注释。
    private func handle(_ url: URL) {
        guard let cmd = URLCommand.parse(url) else {
            // 看不懂就记一条然后算了。**不弹窗**：脚本里打错一个字
            // 不该在用户屏幕上糊一个对话框，而他多半也不在电脑前。
            Log.write("[url] 无法理解，已忽略：\(url.absoluteString)")
            return
        }
        Log.write("[url] \(url.absoluteString) → \(cmd.summary)")
        switch cmd {
        case .flash(let times):
            // flash 是唯一不落 Settings 的动词：它是**一次性的**，
            // 不该被持久化，也不该改变用户下次打开面板时看到的任何东西。
            engine.flash(times: times)
        case .setEnabled(let on):
            settings.enabled = on
        case .setEffect(let kind):
            settings.kind = kind
            // 只切效果不等于打开。用户 `magickey effect breathe` 多半是想看到它，
            // 但替他打开总开关是越权——面板上点一格也不会自动开机。
        }
    }

    // MARK: - 主菜单

    /// **LSUIElement 应用不显示菜单栏，但键盘等价物仍然靠 `mainMenu` 路由。**
    /// 不建这个菜单，⌘Q 在本应用里就是死的——实测过：`NSApp.mainMenu` 从未设置，
    /// 按 ⌘Q 毫无反应。而在面板改版之前，那个「退出」按钮是**唯一**的退出方式，
    /// 一旦它从 Footer 里挪走，用户就只能去活动监视器了。
    ///
    /// 菜单本身永远不会被看见（没有 Dock 图标、activationPolicy 是 .accessory），
    /// 所以这里只放真正需要快捷键的项，不追求菜单结构完整。
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MagicKey",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…",
                        action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "关闭窗口",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 MagicKey",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    // MARK: - 菜单栏

    private func setUpMenuBar() {
        popover.behavior = .transient          // 点面板外面就关，和菜单一致
        popover.delegate = self
        // 用 PanelHostingController 而不是裸 NSHostingController：
        // NSPopover 靠 contentSize 定位，而它不会自己跟着 SwiftUI 的尺寸走，
        // 不同步的话面板会整体右移下移各 20pt。理由见那个类的注释。
        let host = PanelHostingController(
            rootView: MenuBarView(settings: settings, engine: engine, updates: updates,
                                  audio: audio, keySound: keySound, metrics: metrics,
                                  openSettings: { [weak self] in self?.openSettings() }))
        host.popover = popover
        popover.contentViewController = host
        panelHost = host

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

        let barHeight = button.window?.frame.height
        guard let target = anchorTarget(for: button) else { return }

        // 面板能用多高，必须在 show 之前算好推给视图——视图那时还没有 window，
        // 自己判断不出会被摆到哪块屏。见 PanelMetrics 的注释。
        metrics.update(screen: target.screen,
                       menuBar: PanelAnchor.menuBarHeight(on: target.screen,
                                                          statusBarWindowHeight: barHeight))
        // 也必须在 show 之前——定位就发生在 show 那一刻，晚一帧面板就偏了
        panelHost?.syncContentSize()

        // **锚在自己的窗口上，不锚在状态项按钮上。** 全屏时菜单栏会自己收起来，
        // 系统把状态项窗口挪到屏幕外，而 NSPopover 跟着定位视图走——面板会闪到
        // 主屏左上角。锚点归自己管就没这回事。理由见 PanelAnchor.place。
        guard let anchorView = PanelAnchor.place(anchorWindow, centerX: target.centerX,
                                                 on: target.screen,
                                                 statusBarWindowHeight: barHeight) else { return }

        // **先让锚点成为 key，再 show。** 面板里全是滑块和输入框，打开就要能直接操作，
        // 而 `.accessory` 应用不活跃时唯一能把自己拉活的手段就是对锚点这个
        // `.nonactivatingPanel` 窗口 `makeKey()`——`NSApp.activate()` 那一族全被系统
        // 忽略。理由和实测见 `PanelAnchor.AnchorPanel`。
        //
        // 顺序不能反：show 之后再 makeKey 最终状态一样，但中间会有几帧面板是灰的。
        anchorWindow.makeKey()
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)

        clearInitialFocus()
        logFocus()
    }

    /// 面板拿没拿到焦点。控件发灰、点别处关不掉、输入框打不了字——
    /// 这三个症状都是同一件事，出问题时先看这行，别去调颜色或改 popover.behavior。
    private func logFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let win = self?.popover.contentViewController?.view.window
            Log.write("[panel] isActive=\(NSApp.isActive) "
                      + "isKey=\(win?.isKeyWindow ?? false) "
                      + "keyWindow=\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil")")
        }
    }

    /// 面板开在哪：**图标正下方**；图标不可用时退回指针位置。
    ///
    /// 图标有**两种**失效方式，都实测过：
    ///   ① 挪到所有屏幕之外——`button.window?.screen == nil`，锚点矩形 y=1114.5
    ///      而两块屏最高才 1080（全屏 Space 里菜单栏收起来就是这样）。
    ///   ② 停在**另一块屏**上——外接屏全屏时按钮窗口留在内建屏，
    ///      「锚点在某块屏幕上」这个检查照样通过，面板就开到左边那块屏去了。
    /// 所以判据不是「在不在屏幕上」，而是「**在不在用户刚点的那块屏上**」。
    private func anchorTarget(for button: NSStatusBarButton) -> (screen: NSScreen, centerX: CGFloat)? {
        if buttonAnchorIsUsable(button), let window = button.window, let screen = window.screen {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            return (screen, rect.midX)
        }
        guard let screen = clickedScreen() ?? NSScreen.main else { return nil }
        return (screen, NSEvent.mouseLocation.x)
    }

    /// 打开面板时**不要**让亮度输入框自动获得焦点。
    ///
    /// `NSPopover` 的窗口会按 AppKit 惯例把第一个可编辑文本框设成
    /// initial first responder。面板里只有亮度那一个输入框，于是每次点开状态栏
    /// 都直接进了输入态：光标在闪、背景高亮，看着像出了什么事，
    /// 而用户九成是来拖滑块或换效果的。
    ///
    /// 清掉之后输入框仍然点得进去，Tab 也照样能走到它。
    ///
    /// **两个窗口都要清。** 焦点是靠锚点 `makeKey()` 拿到的，`NSApp.keyWindow`
    /// 落在锚点上而不是面板窗口上（面板是它的子窗口，只是跟着画成活跃）。
    /// 只清面板那个，字段编辑器仍然可能挂在锚点的响应链上。
    private func clearInitialFocus() {
        // show() 之后窗口才存在，推迟一个 runloop
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for win in [self.popover.contentViewController?.view.window, self.anchorWindow] {
                guard let win else { continue }
                win.initialFirstResponder = nil
                win.makeFirstResponder(nil)
            }
        }
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

    /// 面板的锚点。摆好之后**没有任何人会再动它**——这正是它存在的意义，
    /// 见 `PanelAnchor.place`。
    private lazy var anchorWindow: NSWindow = PanelAnchor.makeAnchorWindow()

    func popoverDidClose(_ notification: Notification) {
        anchorWindow.orderOut(nil)

        // **面板关掉就把前台还回去。** 打开面板会把本应用拉活（锚点 makeKey，
        // 见 `PanelAnchor.AnchorPanel`），不还的话：用户上一个 app 的标题栏一直是灰的，
        // 而本应用作为 `.accessory` 又没有任何窗口收键盘——敲字掉进黑洞。
        //
        // 设置窗口或键盘图窗口开着时**不能还**：那正好会把它变成非 key，
        // 控件全画灰，也就是 `AppWindows` 花了力气避开的那件事。
        // 判据必须是**两个窗口的并集**（`AppWindows.anyOpen`），
        // 只看设置窗口的话，从设置里点开键盘图、再关掉设置，那个键盘图就灰了。
        DispatchQueue.main.async {
            guard !AppWindows.anyOpen else { return }
            NSApp.deactivate()
        }
    }

    /// 打开设置窗口。面板是 `.transient` 的，窗口一拿到焦点它就自己关了——
    /// 这是想要的行为，不用手动 close。
    @objc private func openSettings() {
        SettingsWindowController.show(settings: settings, updates: updates)
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
        // 音效和背光引擎并列收敛，互不依赖：`engine.available == false` 时
        // 这一行照样执行，没有背光键盘的机器仍然听得到声音。
        keySound.apply(settings)
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
                    self?.keySound.shutdown()
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
        keySound.shutdown()
        idle.stop()
    }

    /// 菜单栏应用没有窗口，关掉最后一个窗口不该退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
