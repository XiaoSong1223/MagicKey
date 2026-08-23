import AppKit
import SwiftUI
import AVFoundation

// MagicKey UI 探针
//
// 用途：把「面板会不会顶到屏幕外」「有没有控件漏了无障碍标签」这两件事变成
// 一条命令的回归测试。这两件事的共同点是**人工点击很难发现**——
// 面板超高时只是底下的东西被滚出视野，标签缺失则完全没有视觉表现。
//
// 面板高度这个坑在本项目里已经踩过三次（写死上限、循环依赖、贪心 ScrollView，
// 见 CLAUDE.md），三次都是靠肉眼发现的。这个探针就是为了不踩第四次。
//
// 它不碰键盘硬件：`Engine(probe:)` 走的是 `-D UI_PROBE` 才编译的构造器，
// 既不建驱动也不动 StateGuard，因此**可以和正在运行的 MagicKey 同时跑**。
//
//   cd app && make probe-ui

@MainActor
enum UIProbe {

    /// 一次测量的结果
    struct Measurement {
        let label: String
        let size: NSSize
        let contentHeight: CGFloat      // ScrollView 内容的理想高
        let maxHeight: CGFloat          // 当时给定的上限
        var isScrolling: Bool { contentHeight > size.height + 1 }
        var overflows: Bool { size.height > maxHeight + 1 }
    }

    // MARK: - 宿主

    /// 一个借来当锚点的透明小窗口。`NSPopover.show(relativeTo:of:)` 只认视图，
    /// 所以必须有个真窗口——但探针不建 NSStatusItem：无 bundle 的进程没有
    /// bundle id，而 macOS 26 的控制中心是**按 bundle id** 托管状态项的
    /// （见 CLAUDE.md「状态栏图标不显示」），在这里引入它只会带来噪声。
    private static let anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 8, height: 8),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = NSView()
        w.orderFrontRegardless()
        return w
    }()

    private static let popover = NSPopover()

    /// `--repro-settings` 用的锚点窗口，和 app 里那个同款
    private static let reproAnchor: NSWindow = PanelAnchor.makeAnchorWindow()

    /// 让 SwiftUI 把布局跑完。改完绑定之后必须转几圈 runloop，
    /// 否则量到的是**上一帧**的尺寸——这会让整个探针安静地报出错误数字。
    private static func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - 测量

    /// 装一次面板。**整个探针只调一次**——见下。
    static func mount(settings: Settings, engine: Engine, updates: UpdateChecker,
                      audio: AudioStatusModel, keySound: KeySoundController,
                      metrics: PanelMetrics) {
        let view = MenuBarView(settings: settings, engine: engine, updates: updates,
                               audio: audio, keySound: keySound, metrics: metrics)
        // 必须先关掉：给已显示的 popover 换控制器不会重算尺寸，
        // 后面量到的会是上一次 mount 的旧尺寸（这个坑本文件上面刚记过一次）。
        if popover.isShown { popover.performClose(nil); settle(0.3) }
        // 必须和 app 用同一个宿主控制器。它会把 SwiftUI 的尺寸同步给
        // NSPopover.contentSize，而那正是「面板缩不缩」这条检查要覆盖的东西——
        // 用裸 NSHostingController 等于测了个和线上不一样的配置。
        let host = PanelHostingController(rootView: view)
        host.popover = popover
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        if let anchorView = anchor.contentView {
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        }
        // 和 AppDelegate.clearInitialFocus 保持一致——否则这里测不出那个回归
        DispatchQueue.main.async {
            guard let w = popover.contentViewController?.view.window else { return }
            w.initialFirstResponder = nil
            w.makeFirstResponder(nil)
        }
        settle(0.5)
    }

    /// 量当前面板。
    ///
    /// ⚠️ **不要在这里换 `contentViewController`。** 已显示的 `NSPopover`
    /// 换控制器不会重算尺寸：实测内容从 241pt 掉到 80pt，而 popover 纹丝不动
    /// 停在 331pt，于是探针会报出一串全都相同的假高度。
    ///
    /// 真实 app 也是一个控制器活到底、靠 SwiftUI 驱动尺寸变化的，所以
    /// 「改绑定再量」既是唯一正确的做法，也顺带验证了**面板会不会缩回去**
    /// ——这正是当初从 `MenuBarExtra` 换到 `NSPopover` 的全部理由。
    static func measure(label: String, metrics: PanelMetrics) -> Measurement {
        settle()
        let root = popover.contentViewController?.view
        let size = root?.frame.size ?? .zero
        return Measurement(label: label,
                           size: size,
                           contentHeight: scrollContentHeight(in: root) ?? size.height,
                           maxHeight: metrics.maxHeight)
    }

    /// 找到面板里的 NSScrollView，取它 documentView 的高。
    /// 内容高 > 可见高 就说明此刻处在滚动态。
    private static func scrollContentHeight(in view: NSView?) -> CGFloat? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView {
            return scroll.documentView?.frame.height
        }
        for sub in view.subviews {
            if let h = scrollContentHeight(in: sub) { return h }
        }
        return nil
    }

    // MARK: - 无障碍

    struct AXNode {
        let role: String
        let label: String?
        let value: String?
        let help: String?
        let depth: Int

        /// 会被 VoiceOver 读到、因此必须有名字的角色。
        /// 静态文本自己就是内容，不需要额外标签，所以不在此列。
        var isControl: Bool {
            ["AXButton", "AXSlider", "AXCheckBox", "AXRadioButton",
             "AXPopUpButton", "AXIncrementor", "AXDisclosureTriangle"].contains(role)
        }
        var isUnnamed: Bool { isControl && (label?.isEmpty ?? true) }
    }

    /// 就地遍历 AppKit 的无障碍树。**只是信息性输出，不作为判据**——见下。
    ///
    /// ## 为什么这里量不到 SwiftUI 的控件（2026-08-11 实测）
    ///
    /// SwiftUI 的无障碍元素是**惰性创建**的：没有辅助客户端连上来时，
    /// 宿主视图的 `accessibilityChildren()` 返回 0 个子节点，尽管布局早已完成
    /// （同一次测量里面板高度是正确的 377pt）。同一段遍历代码对纯 AppKit 视图
    /// 是好使的（`NSButton` 能查到，`accessibilityLabel` 正确返回）。
    ///
    /// 想强制materialize 只有两条路，都走不通：
    ///   - `AXUIElementCreateApplication(getpid())` 查自己 → `-25208`
    ///     （`kAXErrorCannotComplete`）。AX API **不能自查**，这是设计如此。
    ///   - 设 `AXEnhancedUserInterface` → 同样 `-25208`，它也得走 AX API。
    ///
    /// 剩下的办法是再起一个拿了「辅助功能」授权的进程去观察——为一个检查换一次
    /// TCC 授权，和本项目的零权限路线相反，不做。
    ///
    /// **所以无障碍不靠检查保证，靠构造保证**：面板里的参数行只能由
    /// `MenuBarView.paramRow(...)` 生成，而它强制要求 label/value/help，
    /// 漏不掉。运行时听感仍然需要人工过一遍 VoiceOver。
    ///
    /// ⚠️ 遍历的元素类型必须是 `Any` / `NSAccessibilityProtocol`，**不能是 `NSView`**。
    /// `accessibilityChildren() as? [NSView]` 是**数组整体转换**——只要有一个
    /// 不是 NSView，整个转换返回 nil，遍历就悄悄退回 `subviews` 走了另一条路。
    /// 第一版就是这么错的，结果一个控件都没找到却报「全部通过」。
    static func accessibilityTree(of element: Any?, depth: Int = 0) -> [AXNode] {
        guard depth < 40, let el = element as? NSAccessibilityProtocol else { return [] }

        var out: [AXNode] = []
        let role = el.accessibilityRole()?.rawValue ?? "AXUnknown"
        out.append(AXNode(role: role,
                          label: el.accessibilityLabel() ?? el.accessibilityTitle(),
                          value: el.accessibilityValue().map { "\($0)" },
                          help: el.accessibilityHelp(),
                          depth: depth))

        // accessibilityChildren() 为 nil 时退回 subviews：AppKit 对普通 NSView
        // 是惰性计算子元素的，nil 不代表「没有子节点」。
        let children: [Any] = el.accessibilityChildren()
            ?? (el as? NSView).map { $0.subviews as [Any] }
            ?? []
        for child in children {
            out += accessibilityTree(of: child, depth: depth + 1)
        }
        return out
    }

    // MARK: - 截图
    //
    // 外观只能看了才知道，文档说不清——这个项目一贯的判据就是
    // 「定参只能靠真实输入，最终判据是眼睛」。
    //
    //   ./magickey-uiprobe --shot out.png [--dark]

    static func shoot(to path: String, dark: Bool) {
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }

        let settings = Settings()
        let a = ProcessInfo.processInfo.arguments
        settings.kind = (a.firstIndex(of: "--effect").map { a[$0 + 1] })
            .flatMap(EffectKind.init(rawValue:)) ?? .breathe
        mount(settings: settings,
              engine: Engine(probe: .running),
              updates: UpdateChecker(),
              audio: AudioStatusModel(),
              keySound: KeySoundController(),
              metrics: PanelMetrics())
        settle(0.6)
        // 验证「拖滑块时右侧数值跟着变」：程序化改 hi，看输入框认不认
        if let i = a.firstIndex(of: "--hi"), i + 1 < a.count, let v = Double(a[i + 1]) {
            settings.hi = v
            settle(0.5)
        }

        guard let win = popover.contentViewController?.view.window else {
            print("❌ 拿不到 popover 窗口"); exit(1)
        }
        // **按区域抓，不要按窗口号抓。** `-l<windowID>` 只合成那一个窗口，
        // 玻璃背后什么都没有，于是折射不出任何东西、退化成一块灰——
        // 拿这种图去判断「玻璃好不好看」等于给玻璃判了个不公平的负。
        // 区域抓能把桌面一起带进来，才是用户真正看到的样子。
        let f = win.frame
        let screenTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        let rect = "\(Int(f.minX)),\(Int(screenTop - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(rect)", path]
        try? p.run()
        p.waitUntilExit()
        print("\(path)  (\(dark ? "深色" : "浅色"))  退出码 \(p.terminationStatus)")
        exit(p.terminationStatus)
    }

    /// 截设置窗口。`--shot-settings <path> [--dark]`
    static func shootSettings(to path: String, dark: Bool) {
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let settings = Settings()
        settings.kind = .breathe
        SettingsWindowController.show(settings: settings, updates: UpdateChecker())
        settle(0.8)
        guard let win = NSApp.windows.first(where: { $0.title == "MagicKey 设置" }) else {
            print("❌ 没找到设置窗口"); exit(1)
        }
        print("  NSApp.isActive       = \(NSApp.isActive)")
        print("  window.isKeyWindow   = \(win.isKeyWindow)")
        print("  window.isMainWindow  = \(win.isMainWindow)")
        print("  window.canBecomeKey  = \(win.canBecomeKey)")
        print("  activationPolicy     = \(NSApp.activationPolicy().rawValue) (0=regular 1=accessory 2=prohibited)")
        let f = win.frame
        let top = NSScreen.screens.first?.frame.maxY ?? f.maxY
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width)),\(Int(f.height))",
                       path]
        try? p.run(); p.waitUntilExit()
        print("\(path)  (\(dark ? "深色" : "浅色"))")
        exit(0)
    }

    // MARK: - 复现：开关设置窗口之后面板跑位

    /// 用户报告：点开设置界面再关闭，然后点状态栏图标，面板整体向上移动，
    /// 过一会儿又恢复。这里把这个序列走一遍，逐帧记面板窗口和内容的几何。
    static func reproSettings() {
        let settings = Settings()
        let updates = UpdateChecker()
        let engine = Engine(probe: .running)
        let metrics = PanelMetrics()
        settings.kind = .breathe

        // 必须用**真的 NSStatusItem**：用普通窗口当锚点复现不出来（试过）。
        // 差别就在状态项——它的宿主窗口归菜单栏管，几何会被系统改。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard",
                                     accessibilityDescription: "probe")
        item.button?.image?.isTemplate = true
        settle(0.5)

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(settings: settings, engine: engine, updates: updates,
                                  audio: AudioStatusModel(), keySound: KeySoundController(),
                                  metrics: metrics))
        popover.behavior = .transient

        func openPanel() {
            guard let b = item.button else { return }
            let screen = b.window?.screen ?? NSScreen.main
            metrics.update(screen: screen,
                           menuBar: screen.map {
                               PanelAnchor.menuBarHeight(on: $0,
                                                         statusBarWindowHeight: b.window?.frame.height)
                           } ?? 33)
            // 和 AppDelegate 走同一条定位路径，否则这里复现不出真实几何
            guard let s = screen,
                  let anchorView = PanelAnchor.place(reproAnchor, centerX: b.window?.frame.midX ?? 0,
                                                     on: s,
                                                     statusBarWindowHeight: b.window?.frame.height)
            else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            NSApp.activate()
        }

        func snapshot(_ tag: String) {
            let root = popover.contentViewController?.view
            let win = root?.window
            let bw = item.button?.window
            print(String(format: "  %-20@ 面板 y=%7.1f h=%6.1f | 按钮窗 y=%7.1f h=%5.1f | 内容 h=%.0f",
                         tag as NSString,
                         win?.frame.origin.y ?? -1, win?.frame.height ?? -1,
                         bw?.frame.origin.y ?? -1, bw?.frame.height ?? -1,
                         root?.frame.height ?? -1))
        }

        print("\n── 复现：设置窗口开关前后的面板几何 ──")
        print("（面板 y 是窗口左下角；变大 = 面板整体上移）")

        openPanel(); settle(0.6); snapshot("① 首次打开")
        popover.performClose(nil); settle(0.4)
        openPanel(); settle(0.6); snapshot("② 关掉再开（对照）")

        SettingsWindowController.show(settings: settings, updates: updates)
        settle(1.0); snapshot("③ 设置窗口开着")
        NSApp.windows.first { $0.title == "MagicKey 设置" }?.performClose(nil)
        settle(1.0); snapshot("④ 设置刚关掉")

        popover.performClose(nil); settle(0.4)
        openPanel()
        for t in [0.5, 1.5, 2.5, 4.5, 7.5] {
            settle(t == 0.5 ? 0.5 : 1.0)
            snapshot("⑤ 重开 +\(t)s")
        }
        exit(0)
    }

    // MARK: - 面板落点

    /// 面板必须落在**图标正下方、贴着菜单栏下沿**，而且
    /// **系统怎么折腾状态项窗口都不许动**。
    ///
    /// 这一组必须自动化：三个真实症状（开关设置窗口后上移 11pt、整体右移下移
    /// 各 20pt、全屏下菜单栏一收面板闪到左上角）人工点击全靠碰运气复现，
    /// 而它们的成因都是确定的几何——把状态项窗口的坏状态直接造出来量就行。
    ///
    /// 造的是普通窗口而不是真 `NSStatusItem`：真状态项的几何归系统管，
    /// 探针改不动它，也就没法制造那些坏状态。
    ///
    /// ⚠️ 判据落在**内容视图的屏幕坐标**上，不是定位矩形。那一层真的会骗人：
    /// `contentSize` 不同步时面板整体偏 20pt，而定位矩形一个字都没错。
    static func anchorChecks() -> [String] {
        var failures: [String] = []
        // 挑一块**普通 Space** 的屏：全屏 Space 里量不出菜单栏高度
        guard let screen = NSScreen.screens.first(where: { $0.frame.maxY > $0.visibleFrame.maxY })
                ?? NSScreen.main else { return ["拿不到屏幕"] }

        let menuBar = PanelAnchor.menuBarHeight(on: screen)
        let bottom = PanelAnchor.menuBarBottom(on: screen)
        print("\n── 面板落点 ──")
        print(String(format: "  屏 %.0f×%.0f，菜单栏 %.1fpt，下沿 y=%.1f",
                     screen.frame.width, screen.frame.height, menuBar, bottom))

        // 冒充状态项的窗口。必须和真状态项同层：普通层的窗口会被 AppKit 的
        // constrainFrameRect 挡在菜单栏下面（整整推下来一个菜单栏高），
        // 那样造出来的就不是「状态项窗口」而是别的东西。
        let item = NSWindow(contentRect: NSRect(x: screen.frame.midX, y: bottom,
                                                width: 38, height: menuBar),
                            styleMask: .borderless, backing: .buffered, defer: false)
        item.isOpaque = false
        item.backgroundColor = .clear
        item.hasShadow = false
        item.level = .statusBar
        item.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: menuBar))
        item.orderFrontRegardless()
        let iconCenter = item.frame.midX

        let settings = Settings()
        settings.kind = .breathe
        let metrics = PanelMetrics()
        metrics.update(screen: screen, menuBar: menuBar)
        let po = NSPopover()
        po.behavior = .applicationDefined
        let host = PanelHostingController(
            rootView: MenuBarView(settings: settings, engine: Engine(probe: .running),
                                  updates: UpdateChecker(), audio: AudioStatusModel(),
                                  keySound: KeySoundController(), metrics: metrics))
        host.popover = po
        po.contentViewController = host
        host.syncContentSize()

        // 走和 app 完全相同的落点计算
        let anchorWindow = PanelAnchor.makeAnchorWindow()
        guard let anchorView = PanelAnchor.place(anchorWindow, centerX: iconCenter, on: screen,
                                                 statusBarWindowHeight: item.frame.height) else {
            return ["锚点窗口没建起来"]
        }
        po.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        settle(0.6)

        /// popover 窗口四周有一圈透明边距（箭头画在里面），所以量**内容视图**
        func panelRect() -> NSRect? {
            guard let cv = po.contentViewController?.view, let pw = cv.window else { return nil }
            return pw.convertToScreen(cv.convert(cv.bounds, to: nil))
        }
        func check(_ tag: String) -> NSRect? {
            guard let r = panelRect() else { failures.append("面板没显示出来（\(tag)）"); return nil }
            print(String(format: "  %-26@ 面板 %.0f×%.0f  中心 x=%.1f（图标 %.1f，差 %+.1f）  顶边 y=%.1f（菜单栏下沿差 %+.1f）",
                         tag as NSString, r.width, r.height,
                         r.midX, iconCenter, r.midX - iconCenter, r.maxY, r.maxY - bottom))
            if abs(r.midX - iconCenter) > 1 {
                failures.append(String(format: "面板没在图标正下方，偏 %+.1fpt（%@）", r.midX - iconCenter, tag))
            }
            // 内容顶边比菜单栏下沿低一点是正常的：popover 窗口的透明边距（箭头在里面）。
            // 实测 13pt。放宽到 16pt，超了说明真的掉下来了。
            let gap = bottom - r.maxY
            if gap < 0 || gap > 16 {
                failures.append(String(format: "面板顶边离菜单栏 %.1fpt（%@）", gap, tag))
            }
            return r
        }

        guard let baseline = check("① 图标正下方") else { return failures }

        // ② 换效果重新布局（300 → 355pt）：只许往下长，落点不许动
        settings.kind = .audioBeat
        settle(0.6)
        _ = check("② 换成音乐（内容变高）")

        // ③④ 系统折腾状态项窗口。**面板一个像素都不许动。**
        //   ③ 高度退化成 22 —— 控制中心放开托管时就是这样（切 activationPolicy 会触发）
        //   ④ 挪出所有屏幕 —— 全屏 Space 里菜单栏自动收起时就是这样
        for (tag, frame) in [
            ("③ 状态项缩成 22pt", NSRect(x: screen.frame.midX, y: screen.frame.maxY - 22,
                                          width: 38, height: 22)),
            ("④ 状态项挪出屏幕", NSRect(x: screen.frame.midX, y: screen.frame.maxY + 160,
                                          width: 38, height: 30)),
        ] {
            item.setFrame(frame, display: false)
            settle(0.5)
            guard let r = check(tag) else { continue }
            // 和基线逐点比：这四步里面板本来就该纹丝不动（②只是变高，顶边和中心不变）
            if abs(r.midX - baseline.midX) > 0.5 || abs(r.maxY - baseline.maxY) > 0.5 {
                failures.append(String(format: "状态项一动面板就跟着跑了（%@，Δ%.1f, %.1f）",
                                       tag, r.midX - baseline.midX, r.maxY - baseline.maxY))
            }
        }

        po.performClose(nil)
        settle(0.3)
        anchorWindow.orderOut(nil)
        item.orderOut(nil)
        return failures
    }

    /// 面板打开就能操作：**应用被拉活，面板按活跃样式绘制。**
    ///
    /// 这一组测的是那个「点开面板要再点一次才能用」的 bug。它有三副面孔——
    /// 控件发灰像禁用、点别处关不掉、亮度框打不了字——根子是同一个：
    /// `.accessory` 应用不活跃时没有任何自我激活的手段，`NSApp.keyWindow` 是 nil。
    ///
    /// **它能自动化，全靠 `NSApp.deactivate()`。** 把探针自己踢出前台之后，
    /// `NSApp.activate()` / `activate(ignoringOtherApps:)` /
    /// `NSRunningApplication.activate` 三个全部失效（实测），也就精确复现了
    /// 「用户正在别的 app 里，伸手点一下状态栏图标」那一刻的处境。
    /// 探针进程平时是活跃的，不先踢出去的话这一组会**全绿而毫无意义**。
    ///
    /// 阴性对照就在函数里：同样的步骤换回改之前的普通 borderless 锚点，
    /// 面板必须**拿不到** key。拿不到，才证明这个检查测得到东西。
    static func focusChecks() -> [String] {
        var failures: [String] = []
        print("\n── 面板焦点 ──")
        guard let screen = NSScreen.screens.first(where: { $0.frame.maxY > $0.visibleFrame.maxY })
                ?? NSScreen.main else { return ["拿不到屏幕"] }

        /// 改之前的锚点：普通 borderless 窗口，`canBecomeKey == false`
        func plainAnchor() -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSView()
            return w
        }

        /// 走 app 的真实顺序：place → 锚点 makeKey → show
        func trial(_ tag: String, _ anchor: NSWindow) -> (active: Bool, key: Bool)? {
            NSApp.deactivate()
            settle(0.9)
            guard !NSApp.isActive else {
                failures.append("探针退不出前台，焦点检查没跑成（\(tag)）")
                print("  \(tag)：⚠️ 探针仍在前台，这一步测不了")
                return nil
            }
            let po = NSPopover()
            po.behavior = .applicationDefined
            let vc = NSViewController()
            vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            po.contentViewController = vc
            defer { po.performClose(nil); anchor.orderOut(nil); settle(0.3) }

            guard let anchorView = PanelAnchor.place(anchor, centerX: screen.frame.midX,
                                                     on: screen) else {
                failures.append("锚点窗口没建起来（\(tag)）")
                return nil
            }
            anchor.makeKey()
            po.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            settle(0.5)
            let active = NSApp.isActive
            let key = po.contentViewController?.view.window?.isKeyWindow ?? false
            print("  \(tag)：canBecomeKey=\(anchor.canBecomeKey) → "
                  + "isActive=\(active) 面板 isKey=\(key)")
            return (active, key)
        }

        // 现状：锚点是 .nonactivatingPanel，makeKey 连带把应用拉活
        if let now = trial("① 现在的锚点", PanelAnchor.makeAnchorWindow()) {
            if !now.active { failures.append("点开面板没能把应用拉活（控件会画成灰的）") }
            if !now.key { failures.append("面板窗口不是 key（控件会画成灰的、点别处关不掉）") }
        }
        // 阴性对照：换回普通窗口，必须失败
        if let before = trial("② 阴性对照（改之前的普通锚点）", plainAnchor()) {
            if before.key {
                failures.append("阴性对照没复现：普通锚点也拿到了 key，说明这个检查测不出东西")
            }
        }
        return failures
    }

    /// 设置里的音色 Picker 直接遍历这张表。先把「本来就只有一项」这种数据回归
    /// 钉死，和后面的全屏 Space 呈现问题分开判断。
    static func keySoundPackInventoryChecks() -> [String] {
        print("\n── 键盘音效：内置音色清单 ──")
        let packs = KeySoundPack.all
        let ids = Set(packs.map(\.id))
        let allResolvable = packs.allSatisfy { KeySoundPack.named($0.id).id == $0.id }
        let ok = packs.count == 12 && ids.count == packs.count && allResolvable
        print("  \(packs.count) 套、\(ids.count) 个不重复 ID、"
              + "全部可按 Picker tag 解析  \(ok ? "✅" : "❌")")

        var failures: [String] = []
        if packs.count != 12 { failures.append("内置音色应有 12 套，实际 \(packs.count) 套") }
        if ids.count != packs.count { failures.append("内置音色 ID 有重复") }
        if !allResolvable { failures.append("有音色的 Picker tag 无法解析回对应音色") }
        return failures
    }

    /// 键盘音效：**未授权时必须什么都不装。**
    ///
    /// 这一条非测不可。「开着但没授权」是这个功能最常见的一态（默认关闭 →
    /// 用户打开 → 还没去系统设置勾），而它的正确行为是**完全静默地什么都不做**：
    /// 不装 monitor、不起音频引擎、不开定时器。写错了不会崩、不会报错，
    /// 只会在系统里留下一条「这个 app 在监听输入」的记录，外加一个白跑的音频引擎——
    /// 人工点击**永远发现不了**。
    ///
    /// ⚠️ 不能靠真实 TCC 状态来测：探针是从终端起的裸可执行文件，TCC 把它算在
    /// **终端**头上（本机实测 `IOHIDCheckAccess` 返回「已授权」，那是终端的授权），
    /// 于是「被拒绝」那一支永远走不到。所以用 `probeAccessOverride` 直接注入。
    ///
    /// 第三步是**阴性对照**：同样的开关、只把授权改成「已给」，就必须装上 monitor
    /// 并把引擎跑起来。测不出差别的检查等于没有这个检查。
    static func keySoundChecks(settings: Settings) -> [String] {
        var failures: [String] = []
        print("\n── 键盘音效：未授权降级 ──")

        let controller = KeySoundController()
        let originallyEnabled = settings.keySoundEnabled
        defer {
            // 别把监听留到探针后面的步骤里
            settings.keySoundEnabled = false
            KeySoundController.probeAccessOverride = nil
            KeySoundController.setProbeLaunchAccess(nil)
            controller.apply(settings)
            settings.keySoundEnabled = originallyEnabled
        }

        /// - Parameters:
        ///   - atLaunch: 「本进程启动那一刻」的授权结果
        ///   - granted: 「现在」的授权结果。两者不同正是 ⑤ 要测的那件事
        ///   - listening: 期望「装了 monitor 没有」
        ///   - engineRunning: 期望「音频引擎在不在跑」。nil = 不作判据，只打印
        func step(_ tag: String, enabled: Bool, atLaunch: Bool, granted: Bool,
                  didRequest: Bool = false,
                  expect status: KeySoundStatus, listening: Bool, engineRunning: Bool?) {
            KeySoundController.setProbeLaunchAccess(atLaunch)
            KeySoundController.probeAccessOverride = granted
            controller.setProbeDidRequest(didRequest)
            settings.keySoundEnabled = enabled
            controller.apply(settings)
            settle(0.4)

            let gotListening = controller.probeIsListening
            let gotEngine = controller.probeEngineIsRunning
            var bad: [String] = []
            if controller.status != status { bad.append("status=\(controller.status)") }
            if gotListening != listening { bad.append("monitor=\(gotListening)") }
            if let engineRunning, gotEngine != engineRunning { bad.append("engine=\(gotEngine)") }

            print(String(format: "  %-30@ status=%-18@ monitor=%@ engine=%@  %@",
                         tag as NSString, "\(controller.status)" as NSString,
                         (gotListening ? "已装" : "未装") as NSString,
                         (gotEngine ? "运行" : "停") as NSString,
                         (bad.isEmpty ? "✅" : "❌ 期望 \(status)/\(listening)") as NSString))
            if !bad.isEmpty {
                failures.append("键盘音效「\(tag)」不对：" + bad.joined(separator: " "))
            }
        }

        step("① 未授权 + 开关打开", enabled: true, atLaunch: false, granted: false,
             expect: .needsPermission, listening: false, engineRunning: false)
        step("② 已授权 + 开关关闭", enabled: false, atLaunch: true, granted: true,
             expect: .off, listening: false, engineRunning: false)
        // 阴性对照。引擎跑不跑还取决于采样能不能加载（探针走源码树里的
        // Resources/Sounds，见 KeySoundPack.soundsRoot），所以它一起作为判据。
        step("③ 已授权 + 开关打开（对照）", enabled: true, atLaunch: true, granted: true,
             expect: .running, listening: true, engineRunning: true)
        step("④ 撤销授权后再收敛一次", enabled: true, atLaunch: true, granted: false,
             expect: .needsPermission, listening: false, engineRunning: false)
        // ⑤ 最容易被写成绿灯的那一态：**跑起来之后才拿到的授权**。
        // 「输入监控」对已运行的进程不生效，此刻装 monitor 一个事件都收不到，
        // 面板却会亮绿灯说「响应中」——比直接报未授权糟得多。
        // 判据必须同时压住三项：状态是 needsRestart、monitor 未装、引擎没起。
        step("⑤ 启动时未授权，运行中才给", enabled: true, atLaunch: false, granted: true,
             expect: .needsRestart, listening: false, engineRunning: false)
        // ⑥ 请求过了系统仍不放行——真机上就是「设置里开着、应用说没授权」那一态
        //（TCC 旧记录绑的 cdhash 对不上，2026-08-23 实测）。
        // 判据不只是 `.blocked`：这一态**同样一个 monitor 都不能装**，
        // 而且面板必须给得出 `.regrant`，否则用户卡在这里出不去。
        step("⑥ 请求过仍未放行（旧记录失效）", enabled: true, atLaunch: false, granted: false,
             didRequest: true, expect: .blocked, listening: false, engineRunning: false)
        if controller.action != .regrant {
            failures.append("键盘音效「⑥」不对：blocked 态没给出「重新授权」按钮"
                            + "（action=\(String(describing: controller.action))）")
        }
        // 阴性对照：没请求过时必须还是 `.needsPermission`，不能一律报 blocked
        step("⑦ 没请求过（阴性对照）", enabled: true, atLaunch: false, granted: false,
             didRequest: false, expect: .needsPermission, listening: false, engineRunning: false)

        return failures
    }

    /// 键盘音效：**声音真的渲染出来了吗。**
    ///
    /// 「scheduleBuffer 被调用了」和「有声」是两回事：`engine.stop()` 会作废
    /// player node 的渲染状态而 `isPlaying` 仍留在 true，`start()` 若按
    /// `!isPlaying` 跳过补 play()，之后排什么都无声——引擎显示在跑、时序打点
    /// 全部正常，只有在音频图上装 tap 量 RMS 才测得出。
    /// 「开关关一次再开就哑」（2026-08-23 用户真机报告）当初就是这么漏掉的。
    ///
    /// **完全静默**：mixer 总音量设 0，tap 打在各 **player 节点**上——
    /// 节点渲染不渲染与下游 mixer 音量无关，量得到又听不到。
    static func keySoundRenderChecks() -> [String] {
        print("\n── 键盘音效：渲染回归（静默，tap 在混音前）──")
        var failures: [String] = []

        final class Meter: @unchecked Sendable {
            private var sum = 0.0
            private var n = 0
            private let lock = NSLock()
            func add(_ buf: AVAudioPCMBuffer) {
                guard let ch = buf.floatChannelData else { return }
                var s = 0.0
                for i in 0..<Int(buf.frameLength) { let v = Double(ch[0][i]); s += v * v }
                lock.lock(); sum += s; n += Int(buf.frameLength); lock.unlock()
            }
            func readAndReset() -> Double {
                lock.lock(); defer { lock.unlock() }
                let rms = n > 0 ? (sum / Double(n)).squareRoot() : 0
                sum = 0; n = 0
                return rms
            }
        }

        let player = KeySoundPlayer()
        player.load(KeySoundPack.named(KeySoundPack.fallback.id))
        player.setVolume(0)   // 回归测试不许出声
        defer { player.stop() }

        let meter = Meter()
        for node in player.probeEngine.attachedNodes.compactMap({ $0 as? AVAudioPlayerNode }) {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in meter.add(buf) }
        }

        func measure(_ tag: String, hit: Bool, expectSound: Bool, _ prep: () -> Void) {
            prep()
            _ = meter.readAndReset()
            // keyCode 12 = kVK_ANSI_Q，没有任何自定义指键，所以走音色包
            if hit { player.play(.generic, isDown: true, keyCode: 12,
                                 arrival: CFAbsoluteTimeGetCurrent()) }
            settle(0.4)
            let rms = meter.readAndReset()
            let sounded = rms > 1e-6
            let ok = sounded == expectSound
            print(String(format: "  %@ rms=%.6f → %@  %@",
                         tag, rms, sounded ? "有声" : "无声", ok ? "✅" : "❌"))
            if !ok {
                failures.append("键盘音效渲染「\(tag)」：期望\(expectSound ? "有" : "无")声，"
                                + String(format: "实测 rms=%.6f", rms))
            }
        }

        measure("① 新引擎首播        ", hit: true, expectSound: true) { player.start() }
        // ② 就是「开关关一次再开」。修掉的那个 bug 在这里会报 rms=0
        measure("② stop 后重启再播   ", hit: true, expectSound: true) { player.stop(); player.start() }
        measure("③ 空闲暂停后恢复播  ", hit: true, expectSound: true) { player.probeForceIdlePause() }
        // ④ 阴性对照：不敲键必须量到 0——证明探头不是永远报「有声」
        measure("④ 不敲键（阴性对照）", hit: false, expectSound: false) { }

        return failures
    }

    // MARK: - 自定义按键音

    /// 键位表的健全性：**键码不重复、矩形不重叠、全部落在画布内。**
    ///
    /// 这三条都是「写错了界面照样画得出来」的错：键码抄错一个，那个键指的音
    /// 会跑到另一个键上（甚至指到一个根本不在图上的键）；宽度写错 0.25，
    /// 整排键往右挪，肉眼看着还是一张键盘。人工检查得对着头文件数 77 个数。
    ///
    /// 「相邻允许贴边」是这一组的关键放宽：布局表里的键**就是**首尾相接的
    /// （x 靠宽度累加），键与键之间那道缝是画的时候减 2pt 留出来的，不在表里。
    /// 判据用面积严格大于 0，贴边（面积 == 0）放行。
    static func keyboardLayoutChecks() -> [String] {
        print("\n── 键位表健全性 ──")
        var failures: [String] = []
        let keys = KeyboardLayout.keys
        let eps = 1e-6

        // ① 键码不重复。重复的话两个键帽指向同一条指键记录，
        // 点了 A 却看到 B 也亮起来
        var seen: [UInt16: String] = [:]
        for k in keys {
            if let prev = seen[k.keyCode] {
                failures.append("键位表键码重复：\(k.keyCode) 同时是「\(prev)」和「\(k.name)」")
            }
            seen[k.keyCode] = k.name
        }

        // ② 全部落在画布内
        var outside = 0
        for k in keys where k.x < -eps || k.y < -eps
            || k.x + k.w > KeyboardLayout.unitsWide + eps
            || k.y + k.h > KeyboardLayout.unitsHigh + eps {
            failures.append(String(format: "「%@」超出画布：x=%.3f y=%.3f w=%.3f h=%.3f",
                                   k.name, k.x, k.y, k.w, k.h))
            outside += 1
        }

        // ③ 两两不重叠
        var overlaps = 0
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let a = keys[i], b = keys[j]
                let dx = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
                let dy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
                guard dx > eps, dy > eps else { continue }   // 贴边 / 不相交
                failures.append(String(format: "「%@」和「%@」重叠 %.3f×%.3f 单位",
                                       a.name, b.name, dx, dy))
                overlaps += 1
            }
        }

        // ④ 键帽总面积。这一条抓的是上面三条抓不到的错：把某个键的宽度写窄
        // （比如回车 2.25 打成 2.0），既不会重叠也不会越界，整行只是往左缩，
        // 肉眼看还是一张键盘。
        //
        // **不按行查宽度**：方向键那一簇是半高的倒 T，按 y 分组会把底排
        // 劈成 y=4.75（含 ↑）和 y=5.25 两段，两段各自都不等于 15——
        // 于是正确的布局会被报成可疑。这种「对着正确数据喊狼来了」的检查
        // 用两次就没人看了。面积是一个精确、不用分情况的不变量。
        //
        // 画布 15×5.75 = 86.25，键帽合计 85.25，差出来的 1.0 正是
        // ← 和 → 上方那两个半格空位（2 × 1 × 0.5）——MacBook 上就是空的。
        let covered = keys.reduce(0.0) { $0 + $1.w * $1.h }
        let canvas = KeyboardLayout.unitsWide * KeyboardLayout.unitsHigh
        let expectedBlank = 1.0
        let areaOK = abs(canvas - covered - expectedBlank) < 1e-9
        print(String(format: "  画布 %.2f 单位²，键帽合计 %.2f，空位 %.2f（应为 %.2f：←/→ 上方两个半格）%@",
                     canvas, covered, canvas - covered, expectedBlank, areaOK ? " ✅" : " ❌"))
        if !areaOK {
            failures.append(String(format: "键位表面积对不上：画布 %.2f − 键帽 %.2f = %.2f，应为 %.2f"
                                   + "（多半是某个键的宽或高写错了）",
                                   canvas, covered, canvas - covered, expectedBlank))
        }

        // 每一行的键数与宽度，只作诊断输出——真正的判据是上面那四条
        let rows = Dictionary(grouping: keys, by: { $0.y }).sorted { $0.key < $1.key }
        for (y, row) in rows {
            print(String(format: "  y=%.2f  %2d 键  合计宽 %.3f 单位",
                         y, row.count, row.reduce(0.0) { $0 + $1.w }))
        }
        print("  共 \(keys.count) 个键，键码 \(seen.count) 个不重复，"
              + "越界 \(outside) 个，重叠 \(overlaps) 对 "
              + (failures.isEmpty ? "✅" : "❌"))
        return failures
    }

    /// 在临时目录里合成一条 wav。
    ///
    /// **不带二进制夹具进仓库。** 探针要的是「一条能读的音频」和「一条超长的音频」，
    /// 两者都能现场算出来；夹具文件会在 review 里变成一坨看不懂的二进制，
    /// 而且时长一改就得重新生成。
    ///
    /// 用带衰减包络的正弦而不是等幅正弦：等幅的 RMS 顶到 −9dBFS，
    /// 对齐系数会被峰值一路压到底，测不出「gain 正常算出来」那一支。
    /// - Parameter amplitude: 峰值幅度。要能造出**比对齐目标响**和**比目标轻**
    ///   两种采样——响度对齐是双向的，只测一边就漏掉了另一边（早先
    ///   `alignmentGain` 里那个 `max(1, …)` 把衰减那一支堵死了，
    ///   只用一条采样测的话它会一路报绿）。
    ///
    /// ⚠️ 写句柄必须在本函数内析构：`AVAudioFile` 是在**析构时**收尾文件头的，
    /// 还活着的时候读回来会报「读不出音频」。
    private static func writeSynthWav(to url: URL, seconds: Double,
                                      amplitude: Double = 0.35) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(seconds * 44_100)),
              let ch = buf.floatChannelData else { return false }
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / 44_100
            ch[0][i] = Float(sin(2 * .pi * 440 * t) * amplitude * exp(-t * 2.0))
        }
        return (try? file.write(from: buf)) != nil
    }

    /// 导入往返：**合法文件进得来、超长文件进不来、删了音色指键跟着没。**
    ///
    /// ⚠️ 全程在临时目录里做（`CustomSoundStore.probeDirectoryOverride`）。
    /// 不隔离的话这一组会往用户真正的
    /// `~/Library/Application Support/MagicKey/CustomSounds/` 里塞测试文件，
    /// 甚至在「删除」那一步删掉用户自己导入的音色。同一个理由让 `Settings`
    /// 也在探针里换了 defaults 域——那个坑是实测踩出来的，不要再踩一次。
    static func customImportChecks(store: CustomSoundStore) -> [String] {
        print("\n── 自定义按键音：导入往返 ──")
        var failures: [String] = []
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("magickey-probe-src-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let quietURL = tmp.appendingPathComponent("探针轻音.wav")
        let loudURL = tmp.appendingPathComponent("探针响音.wav")
        let edgeURL = tmp.appendingPathComponent("探针临界音.wav")
        let longURL = tmp.appendingPathComponent("探针超长音.wav")
        guard writeSynthWav(to: quietURL, seconds: 0.30, amplitude: 0.02),
              writeSynthWav(to: loudURL, seconds: 0.30, amplitude: 0.60),
              writeSynthWav(to: edgeURL, seconds: 1.90),
              writeSynthWav(to: longURL, seconds: 2.50) else {
            return ["合成测试 wav 失败，这一组没跑成"]
        }

        /// 导入一条并验响度对齐。
        ///
        /// 判据是**对齐后的 RMS 落在目标上**，不是「gain 大于几」——
        /// 后者把「只放大」这条内置包才有的性质当成了通则，
        /// 于是一条比目标响的采样不被压下去也能报绿（早先就是这么漏的）。
        /// 被峰值余量顶住时对齐不到位是正常的，那一支单独放行。
        func importAndCheck(_ tag: String, _ url: URL) -> CustomSoundEntry? {
            let target = KeySoundPack.loudnessTargetDBFS
            let ceiling = KeySoundPack.peakCeiling
            do {
                let entry = try store.importSound(from: url)
                guard let decoded = LoadedKeySoundPack.decode(store.url(for: entry)) else {
                    failures.append("\(tag)：导入后的文件读不回来")
                    return entry
                }
                let level = CustomSoundStore.analyze(decoded)
                let headroom = level.peak * entry.gain
                let alignedRMS = level.rmsDBFS + 20 * log10(entry.gain)
                let peakLimited = abs(headroom - ceiling) < 1e-3
                let aligned = abs(alignedRMS - target) < 0.05
                // 削顶是硬判据；对齐不到位只在「被峰值顶住」时才放行
                let ok = headroom <= 1.0 && (aligned || peakLimited)
                print(String(format: "  %@ %.1fdBFS → gain %.2f → %.1fdBFS（目标 %.1f）"
                             + " 峰值×gain=%.3f%@  %@",
                             tag, level.rmsDBFS, entry.gain, alignedRMS, target, headroom,
                             peakLimited ? "（峰值顶住）" : "", ok ? "✅" : "❌"))
                if headroom > 1.0 {
                    failures.append(String(format: "%@：会削顶，峰值×gain=%.3f", tag, headroom))
                }
                if !aligned && !peakLimited {
                    failures.append(String(format: "%@：对齐后 %.2fdBFS，偏离目标 %.2fdB"
                                           + "（响度对齐是双向的，比目标响也要压下去）",
                                           tag, alignedRMS, alignedRMS - target))
                }
                return entry
            } catch {
                failures.append("\(tag)：\(error.localizedDescription)")
                print("  \(tag) ❌ \(error.localizedDescription)")
                return nil
            }
        }

        // ①a 比目标**轻**的采样：要被放大上来
        let imported = importAndCheck("①a 轻音 0.30s 需放大", quietURL)
        // ①b 比目标**响**的采样：要被压下去。这一条是 `max(1, …)` 那个 bug 的判据
        if let loud = importAndCheck("①b 响音 0.30s 需衰减", loudURL) {
            if loud.gain >= 1.0 {
                failures.append(String(format: "比目标响的采样没有被衰减（gain=%.2f）", loud.gain))
            }
            store.remove(loud.id)
        }

        // ② 阴性对照：1.90s **必须收**。
        // 少了这一条，「上限一律拒收」也能让 ③ 报绿——一个查不到东西的检查
        // 报通过，比没有这个检查更糟。
        do {
            let entry = try store.importSound(from: edgeURL)
            print("  ② 导入 1.90s（阴性对照）收下了  ✅")
            store.remove(entry.id)
        } catch {
            failures.append("1.90s 的采样被拒了，上限判据可能写成了「一律拒收」：\(error.localizedDescription)")
            print("  ② 导入 1.90s（阴性对照）❌ \(error.localizedDescription)")
        }

        // ③ 超长：拒收，而且提示里要带**实际时长**
        let before = store.entries.count
        do {
            _ = try store.importSound(from: longURL)
            failures.append("2.50s 的采样被收下了，时长上限没起作用")
            print("  ③ 导入 2.50s      ❌ 居然收下了")
        } catch {
            let why = error.localizedDescription
            let mentionsDuration = why.contains("2.5")
            print("  ③ 导入 2.50s      拒收：\(why)  \(mentionsDuration ? "✅" : "❌ 没说实际时长")")
            if !mentionsDuration {
                failures.append("超长拒收的提示里没有实际时长，用户不知道要剪到多短")
            }
            if store.entries.count != before {
                failures.append("超长文件被拒了，音色库里却多了一条")
            }
        }

        // ④ 删除音色 → 引用它的指键必须一起消失
        if let entry = imported {
            let keys: [UInt16] = [49, 36, 51]        // 空格 / 回车 / 退格
            for code in keys { store.assign(entry.id, to: code) }
            let assignedBefore = store.assignments.count
            let fileExisted = FileManager.default.fileExists(atPath: store.url(for: entry).path)
            store.remove(entry.id)
            let leftover = keys.filter { store.assignments[$0] != nil }
            let fileGone = !FileManager.default.fileExists(atPath: store.url(for: entry).path)
            let ok = leftover.isEmpty && fileGone
            print("  ④ 删除音色        指键 \(assignedBefore) → \(store.assignments.count)，"
                  + "文件\(fileExisted ? (fileGone ? "已删" : "还在") : "本来就没有")  \(ok ? "✅" : "❌")")
            if !leftover.isEmpty {
                failures.append("删掉音色后还留着 \(leftover.count) 个指键，那些键会按下无声")
            }
            if !fileGone { failures.append("删掉音色后文件还在磁盘上") }
        }
        return failures
    }

    /// 解析优先级：**按下走自定义，抬起走音色包，总开关关掉整层旁路。**
    ///
    /// 这一组测的是听不出来的东西。「有声」证明不了「声是从哪一层来的」，
    /// 所以判据落在 `probeResolve` 上——它调的就是 `play` 用的那个函数，
    /// 探针不复刻一份优先级判断（复刻的话测的是探针自己写对没有）。
    static func customResolutionChecks(store: CustomSoundStore,
                                       settings: Settings) -> [String] {
        print("\n── 自定义按键音：解析优先级 ──")
        var failures: [String] = []

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("magickey-probe-res-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("探针指键音.wav")
        guard writeSynthWav(to: src, seconds: 0.40) else { return ["合成测试 wav 失败"] }

        guard let entry = try? store.importSound(from: src) else {
            return ["解析优先级这一组：测试采样导不进去"]
        }
        defer { store.remove(entry.id) }
        let space: UInt16 = 49          // kVK_Space
        let q: UInt16 = 12              // kVK_ANSI_Q
        store.assign(entry.id, to: space)

        let player = KeySoundPlayer()
        player.load(KeySoundPack.named(KeySoundPack.fallback.id))
        player.setVolume(0)
        defer { player.stop() }
        player.setCustom(LoadedCustomSounds(entries: store.entries,
                                            assignments: store.assignments,
                                            directory: store.directory,
                                            format: KeySoundPlayer.format))

        func expect(_ tag: String, _ got: KeySoundPlayer.Resolution,
                    _ want: KeySoundPlayer.Resolution) {
            let ok = got == want
            print("  \(tag) → \(got.rawValue)  \(ok ? "✅" : "❌ 期望 \(want.rawValue)")")
            if !ok { failures.append("解析优先级「\(tag)」解析到了 \(got.rawValue)，期望 \(want.rawValue)") }
        }

        expect("① 空格 按下（已指键）  ", player.probeResolve(.space, isDown: true, keyCode: space), .custom)
        // ② 抬起永远走音色包。写反的话一次敲击会听到两遍同一条采样
        expect("② 空格 抬起（已指键）  ", player.probeResolve(.space, isDown: false, keyCode: space), .pack)
        // ③ 阴性对照：没指键的键必须还是音色包
        expect("③ Q 按下（未指键）     ", player.probeResolve(.generic, isDown: true, keyCode: q), .pack)

        // ④ 整层旁路。判据落在 **controller** 上：这是收敛逻辑，
        // 直接 setCustom(nil) 测的是播放层，测不到「设置有没有被读进来」。
        let controller = KeySoundController(customStore: store)
        let savedEnabled = settings.keySoundEnabled
        let savedCustom = settings.keySoundCustomEnabled
        defer {
            settings.keySoundEnabled = savedEnabled
            settings.keySoundCustomEnabled = savedCustom
            KeySoundController.probeAccessOverride = nil
            KeySoundController.setProbeLaunchAccess(nil)
            controller.apply(settings)
        }
        KeySoundController.setProbeLaunchAccess(true)
        KeySoundController.probeAccessOverride = true
        settings.keySoundEnabled = true

        settings.keySoundCustomEnabled = true
        controller.apply(settings)
        settle(0.3)
        let onLoaded = controller.probeCustomIsLoaded
        settings.keySoundCustomEnabled = false
        controller.apply(settings)
        settle(0.3)
        let offLoaded = controller.probeCustomIsLoaded
        let offResolves = controller.probePlayer.probeResolve(.space, isDown: true, keyCode: space)

        print("  ④ 总开关 开→关         自定义层 \(onLoaded ? "已装" : "未装")"
              + " → \(offLoaded ? "已装" : "未装")，关掉后空格解析到 \(offResolves.rawValue)"
              + "  \(onLoaded && !offLoaded && offResolves == .pack ? "✅" : "❌")")
        if !onLoaded { failures.append("总开关打开时自定义层没装上") }
        if offLoaded { failures.append("总开关关掉后自定义层还在（没有旁路）") }
        if offResolves != .pack { failures.append("总开关关掉后没有回落到音色包") }

        return failures
    }

    /// 自定义采样**真的从播放路径渲染出声了吗**。
    ///
    /// 判据不能只是「有声」——音色包也有声。这里用**时长**当判别器：
    /// 自定义采样合成成 1.5 秒，而音色包的采样只有 0.10–0.24 秒。
    /// 敲下去等 0.7 秒之后再开始量，那时音色包早就静了，
    /// 还在响的只可能是自定义那一条。阴性对照就是同样时刻去量一个没指键的键。
    static func customRenderChecks(store: CustomSoundStore) -> [String] {
        print("\n── 自定义按键音：渲染回归（静默，tap 在混音前）──")
        var failures: [String] = []

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("magickey-probe-render-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("探针长音.wav")
        // 1.5s：比音色包最长的采样（0.24s）长一个数量级，
        // ±3% 音高变体最短也有 1.46s，量窗（0.7–1.1s）稳稳落在里面
        guard writeSynthWav(to: src, seconds: 1.5) else { return ["合成测试 wav 失败"] }
        guard let entry = try? store.importSound(from: src) else {
            return ["渲染回归这一组：测试采样导不进去"]
        }
        defer { store.remove(entry.id) }
        let space: UInt16 = 49
        store.assign(entry.id, to: space)

        final class Meter: @unchecked Sendable {
            private var sum = 0.0
            private var n = 0
            private let lock = NSLock()
            func add(_ buf: AVAudioPCMBuffer) {
                guard let ch = buf.floatChannelData else { return }
                var s = 0.0
                for i in 0..<Int(buf.frameLength) { let v = Double(ch[0][i]); s += v * v }
                lock.lock(); sum += s; n += Int(buf.frameLength); lock.unlock()
            }
            func readAndReset() -> Double {
                lock.lock(); defer { lock.unlock() }
                let rms = n > 0 ? (sum / Double(n)).squareRoot() : 0
                sum = 0; n = 0
                return rms
            }
        }

        let player = KeySoundPlayer()
        player.load(KeySoundPack.named(KeySoundPack.fallback.id))
        player.setVolume(0)          // 回归测试不许出声
        player.setCustom(LoadedCustomSounds(entries: store.entries,
                                            assignments: store.assignments,
                                            directory: store.directory,
                                            format: KeySoundPlayer.format))
        player.start()
        defer { player.stop() }

        let meter = Meter()
        for node in player.probeEngine.attachedNodes.compactMap({ $0 as? AVAudioPlayerNode }) {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in meter.add(buf) }
        }

        func measure(_ tag: String, keyCode: UInt16, expectSound: Bool) {
            _ = meter.readAndReset()
            player.play(KeySoundSlot(keyCode: keyCode), isDown: true,
                        keyCode: keyCode, arrival: CFAbsoluteTimeGetCurrent())
            settle(0.7)                     // 音色包的采样到这时早就静了
            _ = meter.readAndReset()
            settle(0.4)                     // 量窗 0.7–1.1s
            let rms = meter.readAndReset()
            let sounded = rms > 1e-6
            let ok = sounded == expectSound
            print(String(format: "  %@ 0.7–1.1s 窗内 rms=%.6f → %@  %@",
                         tag, rms, sounded ? "仍在响" : "已静", ok ? "✅" : "❌"))
            if !ok {
                failures.append("自定义渲染「\(tag)」：期望\(expectSound ? "仍在响" : "已静")，"
                                + String(format: "实测 rms=%.6f", rms))
            }
        }

        // ① 指了 1.5s 采样的空格：0.7 秒之后还在响
        measure("① 空格（已指 1.5s 采样）", keyCode: space, expectSound: true)
        // ② 阴性对照：没指键的 Q 走音色包，同一时刻必须已经静了。
        // 这一条要是也报「仍在响」，说明判别器根本没在判别
        measure("② Q（未指键，走音色包） ", keyCode: 12, expectSound: false)

        return failures
    }

    /// 键盘图窗口：**开得出来、落在屏幕里，而且两个窗口的前台策略取并集。**
    ///
    /// 并集那一条是本次改动最容易翻车的地方：关掉设置窗口时若直接切回
    /// `.accessory`，还开着的键盘图窗口会当场被 AppKit 画成非活跃样式
    /// （开关掉色、滑块头几乎看不见）。这个症状看起来完全像配色问题，
    /// 人工点击时也只有「先开设置、再开键盘图、再关设置」这一个顺序能复现。
    ///
    /// 阴性对照在第 ④ 步：两个都关掉之后**必须**切回 `.accessory`——
    /// 否则「永远停在 .regular」也能让 ③ 报绿。
    static func keyMapWindowChecks(store: CustomSoundStore, settings: Settings,
                                   updates: UpdateChecker) -> [String] {
        print("\n── 自定义按键音窗口 + 两窗口前台策略 ──")
        var failures: [String] = []

        func policy() -> String {
            switch NSApp.activationPolicy() {
            case .regular: return "regular"
            case .accessory: return "accessory"
            default: return "其他"
            }
        }
        func keyMapWindow() -> NSWindow? {
            NSApp.windows.first { $0.title == "自定义按键音" }
        }

        // ① 开出来，量尺寸
        KeyMapWindowController.show(store: store, settings: settings)
        settle(0.9)
        guard let win = keyMapWindow() else {
            return ["键盘图窗口没开出来"]
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let f = win.frame
            // 窗口投影会超出 frame 一点，所以留 2pt 容差
            let inside = f.minX >= visible.minX - 2 && f.maxX <= visible.maxX + 2
                      && f.minY >= visible.minY - 2 && f.maxY <= visible.maxY + 2
            print(String(format: "  ① 窗口 %.0f×%.0f 于 (%.0f, %.0f)；可用区 %.0f×%.0f  %@",
                         f.width, f.height, f.minX, f.minY,
                         visible.width, visible.height, inside ? "✅ 在屏内" : "❌ 超出屏幕"))
            if !inside {
                failures.append(String(format: "键盘图窗口没落在屏幕里：%.0f×%.0f @ (%.0f, %.0f)",
                                       f.width, f.height, f.minX, f.minY))
            }
        }

        // ①b Space 行为。**这一条只验标志位，验不了行为**——真正的判据
        // 「别的 app 全屏时菜单仍能完整展开」需要另一个进程占着全屏 Space，
        // 进程内造不出来。但误加任一跨 Space 标志就是这个 bug 的成因，而且
        // 很容易被当作「让窗口跟着用户走」的修复补回来，所以这里反向守住它。
        failures += spaceNormalizationCheck()
        failures += spaceBehaviorCheck("①b 键盘图", win)

        // ② 再开一次必须是同一个窗口（单例），不能叠出第二个
        KeyMapWindowController.show(store: store, settings: settings)
        settle(0.5)
        let count = NSApp.windows.filter { $0.title == "自定义按键音" }.count
        print("  ② 重复打开 → \(count) 个窗口  \(count == 1 ? "✅" : "❌ 叠出来了")")
        if count != 1 { failures.append("键盘图窗口不是单例，重复点开叠出了 \(count) 个") }

        // ③ 两个窗口都开着，关掉设置窗口 —— **策略必须还停在 regular**
        SettingsWindowController.show(settings: settings, updates: updates)
        settle(0.8)
        if let sw = NSApp.windows.first(where: { $0.title == "MagicKey 设置" }) {
            failures += spaceBehaviorCheck("①c 设置", sw)
        }
        let bothOpen = "\(policy())/anyOpen=\(AppWindows.anyOpen)"
        NSApp.windows.first { $0.title == "MagicKey 设置" }?.performClose(nil)
        settle(0.8)
        let afterSettingsClosed = policy()
        let stillOpen = AppWindows.anyOpen
        print("  ③ 两窗都开(\(bothOpen)) → 关掉设置 → \(afterSettingsClosed)"
              + "/anyOpen=\(stillOpen)  "
              + (afterSettingsClosed == "regular" && stillOpen ? "✅" : "❌ 键盘图会被画灰"))
        if afterSettingsClosed != "regular" {
            failures.append("关掉设置窗口后切回了 \(afterSettingsClosed)，"
                            + "还开着的键盘图窗口会被画成非活跃样式")
        }
        if !stillOpen { failures.append("键盘图还开着，AppWindows.anyOpen 却报 false") }

        // ④ 阴性对照：全关掉之后必须切回 accessory
        win.performClose(nil)
        settle(0.9)
        let afterAllClosed = policy()
        let noneOpen = !AppWindows.anyOpen
        print("  ④ 再关掉键盘图 → \(afterAllClosed)/anyOpen=\(AppWindows.anyOpen)  "
              + (afterAllClosed == "accessory" && noneOpen ? "✅" : "❌"))
        if afterAllClosed != "accessory" {
            failures.append("窗口全关掉了却没切回 .accessory（Dock 图标会一直挂着），"
                            + "而且这说明 ③ 的绿灯是「永远停在 regular」蒙的")
        }
        if !noneOpen { failures.append("窗口全关掉了，AppWindows.anyOpen 却还报 true") }

        return failures
    }

    /// 小面板必须锚在**被点的那个键**上，不能都弹在左上角。
    ///
    /// ## 为什么这一条非有不可
    ///
    /// 键盘图是 `ZStack(alignment: .topLeading)` + 每个键各自 `.offset` 摆位的。
    /// `.offset` 只在画的时候平移，**不改布局矩形**——每个键的布局矩形都还压在
    /// ZStack 左上角，而 `.popover` 锚的正是布局矩形，于是点哪个键小面板都弹在
    /// 左上角（2026-08-23 用户报告）。改成 `.padding` 占位之后位置才跟着走。
    /// 这类「画对了但布局没对」的错误肉眼在静态截图上看不出来，只能量。
    ///
    /// 判据取**两个键之间的位移**而不是绝对坐标：位移只和 `unit` 有关，
    /// 不需要知道键盘图在窗口里的内边距，而且出错时的表现极干净——
    /// 旧代码下两个键的小面板位置完全相同，位移是 0。
    static func keyPopoverAnchorChecks(store: CustomSoundStore, settings: Settings) -> [String] {
        print("\n── 自定义按键音：小面板锚在自己那个键上 ──")
        var failures: [String] = []

        // 避开最左最右：靠边时 NSPopover 会被窗口边缘钳住，量到的就不是锚点了
        func key(nearX x: Double) -> KeyCap? {
            KeyboardLayout.keys.min { abs($0.x - x) < abs($1.x - x) }
        }
        guard let a = key(nearX: 3), let b = key(nearX: 10), a.keyCode != b.keyCode else {
            return ["键位表里找不到两个可用来对比的键"]
        }

        let contentWidth: CGFloat = 760
        let unit = (contentWidth - 32) / CGFloat(KeyboardLayout.unitsWide)

        /// 开一个只装 `KeyMapView` 的窗口，量小面板相对窗口原点的中心。
        /// 不走 `KeyMapWindowController`：那是单例，还会来回切激活策略，
        /// 这一组只关心几何。
        func popoverCenter(_ cap: KeyCap) -> CGPoint? {
            let host = NSHostingController(
                rootView: KeyMapView(store: store, settings: settings,
                                     probeOpenKeyCode: cap.keyCode))
            let win = NSWindow(contentViewController: host)
            win.title = "探针键盘图"
            win.setContentSize(NSSize(width: contentWidth, height: 652))
            win.setFrameOrigin(NSPoint(x: 200, y: 200))
            win.makeKeyAndOrderFront(nil as Any?)
            settle(1.2)
            // **必须按「中心落在宿主窗口里」挑，不能取第一个可见的 popover。**
            // 探针前面几组（面板落点、面板焦点）留下的 `_NSPopoverWindow` 实例
            // 还在 `NSApp.windows` 里，其中一个是可见的——取第一个会量到它，
            // 而它的位置和本组的窗口无关，两次测出来一模一样，
            // 于是「位移 0」这个**恰好等于 bug 表现**的假结果就出来了。
            let pop = NSApp.windows.first {
                String(describing: type(of: $0)).contains("NSPopoverWindow")
                    && $0.isVisible
                    && win.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            let center = pop.map {
                CGPoint(x: $0.frame.midX - win.frame.minX, y: $0.frame.midY - win.frame.minY)
            }
            win.close()
            settle(0.5)
            return center
        }

        guard let ca = popoverCenter(a), let cb = popoverCenter(b) else {
            return ["小面板没弹出来，量不到位置（probeOpenKeyCode 没生效？）"]
        }

        let expected = CGFloat(b.x - a.x) * unit
        let got = cb.x - ca.x
        let ok = abs(got - expected) <= 12
        print(String(format: "  「%@」中心 x=%.0f，「%@」中心 x=%.0f；位移 %.0f（应为 %.0f）  %@",
                     a.name as NSString, ca.x, b.name as NSString, cb.x,
                     got, expected, (ok ? "✅" : "❌") as NSString))
        if !ok {
            failures.append(String(format: "小面板没跟着键走：「%@」和「%@」相距 %.0fpt，"
                                   + "小面板却只差 %.0fpt（0 = 全都弹在左上角）",
                                   a.name, b.name, expected, got))
        }
        return failures
    }

    /// 窗口的 Space 行为：**三个标志一个都不能有。**
    ///
    /// 窗口摆在哪由 `centerOnActiveScreen` 决定（鼠标所在那块屏）。任何一个
    /// Space 标志都会让系统再把它挪进别人的全屏 Space，而**标志不传给子窗口**——
    /// 窗口看着好好的，里面 `Picker` 的菜单只剩一行、键盘图小面板全弹到左上角。
    /// 这些标志都踩过坑（2026-08-23），所以这一条是**反向**守的：
    /// 后来人很容易觉得「全屏下窗口不出现是不是漏了 fullScreenAuxiliary」而补上去。
    ///
    /// 只验标志位，验不了行为——进程内造不出别的应用的全屏 Space
    /// （`--repro-fullscreen` 造的是本进程的，复现不出来）。
    private static func spaceBehaviorCheck(_ tag: String, _ w: NSWindow) -> [String] {
        let cb = w.collectionBehavior
        let bad = [(".moveToActiveSpace", cb.contains(.moveToActiveSpace)),
                   (".fullScreenAuxiliary", cb.contains(.fullScreenAuxiliary)),
                   (".canJoinAllSpaces", cb.contains(.canJoinAllSpaces))]
            .filter { $0.1 }.map { $0.0 }
        print("  \(tag)窗口 collectionBehavior=\(cb.rawValue)"
              + "（Space 标志应为空）  \(bad.isEmpty ? "✅" : "❌ 带了 \(bad)")")
        guard !bad.isEmpty else { return [] }
        return ["\(tag)窗口带了 Space 标志 \(bad.joined(separator: " "))："
                + "窗口会被挪进别人的全屏 Space，而标志不传给子窗口——"
                + "音色下拉只剩一行、键盘图小面板全弹到左上角"]
    }

    /// 阴性对照：不只查真实窗口现在碰巧没带标志，还要证明归一化逻辑真的会
    /// 清掉它们。保留 `.participatesInCycle` 则防止实现被写成粗暴的整体覆盖。
    private static func spaceNormalizationCheck() -> [String] {
        // `.moveToActiveSpace` 和 `.canJoinAllSpaces` 不能同时存在，AppKit 会直接
        // 抛 NSInternalInconsistencyException，所以必须逐项种进三个窗口。
        let dangerous: [NSWindow.CollectionBehavior] = [
            .moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllSpaces
        ]
        let results = dangerous.map { flag -> Bool in
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.collectionBehavior = [flag, .participatesInCycle]
            AppWindows.keepOnPlacedSpace(w)
            return !w.collectionBehavior.contains(flag)
                && w.collectionBehavior.contains(.participatesInCycle)
        }
        let ok = results.allSatisfy { $0 }
        print("  ①a Space 归一化阴性对照：危险标志已清、无关标志"
              + "\(ok ? "保留" : "未正确处理")  \(ok ? "✅" : "❌")")
        guard !ok else { return [] }
        return ["Space 行为归一化失效：危险标志未清干净，或误删了无关窗口行为"]
    }

    /// 设置窗口每次打开都在屏幕正中
    static func settingsCenterChecks(settings: Settings, updates: UpdateChecker) -> [String] {
        print("\n── 设置窗口位置 ──")
        SettingsWindowController.show(settings: settings, updates: updates)
        settle(0.8)
        guard let win = NSApp.windows.first(where: { $0.title == "MagicKey 设置" }) else {
            return ["没找到设置窗口"]
        }
        defer { win.performClose(nil); settle(0.5) }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return ["拿不到屏幕"] }

        let f = win.frame
        let dx = f.midX - visible.midX, dy = f.midY - visible.midY
        print(String(format: "  窗口 %.0f×%.0f 中心 (%.1f, %.1f)；可用区中心 (%.1f, %.1f)；偏差 (%+.1f, %+.1f)",
                     f.width, f.height, f.midX, f.midY, visible.midX, visible.midY, dx, dy))
        // 顺带把「按 fittingSize 定尺寸有没有留下空白/仍在滚动」摆出来。
        // SettingsView 声明的是 minHeight 420 / idealHeight 560：
        // AppKit 自己会取**最小值**开窗（内容一进来就滚动），取 fittingSize 才是理想高。
        if let content = win.contentView {
            let form = scrollContentHeight(in: content) ?? content.frame.height
            print(String(format: "  内容区 %.0fpt，Form 理想高 %.0fpt → %@",
                         content.frame.height, form,
                         form > content.frame.height + 1 ? "仍在滚动"
                             : form < content.frame.height - 1 ? "底部留白" : "正好放下"))
        }
        guard abs(dx) > 1 || abs(dy) > 1 else { return [] }
        return [String(format: "设置窗口没居中，偏差 (%+.1f, %+.1f)", dx, dy)]
    }

    /// `--repro-fullscreen`：自己造一块真的全屏 Space，在里面开设置窗口，
    /// 把 12 项音色菜单弹出来截图。
    ///
    /// 用户报的两条（音色下拉只剩一项、键盘图小面板全弹左上角）**只在全屏下出现**，
    /// 而在这之前已经猜错两次原因（`.offset` 不影响 popover 锚点；菜单也没有被
    /// 可用高度挤住——窗口压到屏底时它会向上翻转、12 项全在）。猜不动了，只能复现。
    ///
    /// ⚠️ 这不是「别的 app 全屏」的完美等价物：这里造出来的 Space 属于本进程。
    /// 但「managed 窗口 vs 全屏 Space」这个机制是同一套，够用来做判据。
    /// 放在**第二块屏**上做，不占用户正在用的那块。
    static func reproFullscreen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let target = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.screens[0]
        let v = target.visibleFrame
        let host = NSWindow(contentRect: NSRect(x: v.minX + 60, y: v.minY + 60,
                                                width: 900, height: 600),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        host.title = "假装成全屏的别的应用"
        host.makeKeyAndOrderFront(nil as Any?)
        settle(1.0)
        host.toggleFullScreen(nil)
        settle(3.5)
        print("宿主窗口 全屏=\(host.styleMask.contains(.fullScreen)) "
              + "onActiveSpace=\(host.isOnActiveSpace) frame=\(host.frame)")

        let settings = Settings()
        SettingsWindowController.show(settings: settings, updates: UpdateChecker())
        settle(2.0)
        guard let win = NSApp.windows.first(where: { $0.title == "MagicKey 设置" }),
              let root = win.contentView else {
            print("❌ 设置窗口没开出来"); host.toggleFullScreen(nil); settle(2.0); exit(1)
        }
        print("设置窗口 onActiveSpace=\(win.isOnActiveSpace) frame=\(win.frame)")
        print("        screen=\(win.screen.map { "\($0.frame)" } ?? "nil")")
        print("        collectionBehavior=\(win.collectionBehavior.rawValue)")
        print("宿主此刻 onActiveSpace=\(host.isOnActiveSpace)")

        guard let pop = allPopUps(root).max(by: { $0.frame.width < $1.frame.width }) else {
            print("❌ 没找到下拉框"); host.toggleFullScreen(nil); settle(2.0); exit(1)
        }
        let path = "/private/tmp/claude-501/-Users-xiaosongxiaosong-Documents-MagicKey/"
                 + "23c17b13-e1d0-4b03-acbd-88d060201b54/scratchpad/fullscreen.png"
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1.5)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -C 带上所有屏，省得又截错那一块
            p.arguments = ["-x", "-C", path]
            try? p.run(); p.waitUntilExit()
            print("截图 → \(path)")
            DispatchQueue.main.async {
                host.toggleFullScreen(nil)
                settle(2.5)
                exit(0)
            }
        }
        pop.performClick(nil)
        settle(8.0)
        exit(0)
    }

    /// `--dump-picker`：把设置窗口里那几个 `NSPopUpButton` 的菜单项全打出来。
    ///
    /// 用户报「音色下拉只有一项」。在动任何布局之前先分清两件事：
    /// **是菜单本身只有一项（数据/绑定的问题），还是菜单有 12 项但显示不出来
    /// （呈现/Space 的问题）**。这两者的界面表现一模一样，猜不出来，只能查。
    static func dumpPicker() {
        let settings = Settings()
        SettingsWindowController.show(settings: settings, updates: UpdateChecker())
        settle(1.2)
        guard let win = NSApp.windows.first(where: { $0.title == "MagicKey 设置" }),
              let root = win.contentView else {
            print("❌ 没找到设置窗口"); exit(1)
        }
        func walk(_ v: NSView, _ depth: Int) {
            if let pop = v as? NSPopUpButton {
                print("NSPopUpButton  frame=\(pop.frame)  enabled=\(pop.isEnabled)")
                print("  numberOfItems = \(pop.numberOfItems)")
                for (i, item) in pop.itemArray.enumerated() {
                    print("   [\(i)] \(item.title)  enabled=\(item.isEnabled)")
                }
                print("  menu.numberOfItems = \(pop.menu?.numberOfItems ?? -1)")
            }
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(root, 0)
        print("KeySoundPack.all.count = \(KeySoundPack.all.count)")

        // `numberOfItems` 在弹出之前是 0——SwiftUI 是点开那一刻才建菜单的，
        // 所以静态查什么都查不到。只能真的把它弹开再截图。
        // 截图必须在**另一个线程**上发：菜单跟踪自己跑一个 runloop mode，
        // 主线程上的 asyncAfter 在那期间根本不会 fire。
        if let target = allPopUps(root).max(by: { $0.frame.width < $1.frame.width }) {
            // 挪到主屏：`screencapture -R` 的坐标是主屏坐标系，
            // 窗口开在第二块屏上时截出来的是主屏的桌面（第一次就这么翻车的）。
            // `--screen2`：摆到第二块屏。怀疑「菜单只剩一行 / popover 弹到左上角」
            // 是 AppKit 给子窗口算可用区域时落回了**主屏**——窗口在副屏上时，
            // 按钮的全局坐标在主屏矩形里可能贴边甚至在外面，于是算出来只剩一行。
            let useSecond = ProcessInfo.processInfo.arguments.contains("--screen2")
                            && NSScreen.screens.count > 1
            guard let main = useSecond ? NSScreen.screens[1] : NSScreen.screens.first
            else { exit(1) }
            // `--low`：把窗口压到屏幕最底下，看菜单在可用高度不足时是什么样。
            // 用户报「音色下拉只有一项」，而 12 项菜单要约 280pt——
            // 弹出方向上放不下时 AppKit 会改成可滚动菜单，空间越小显示的项越少。
            let lowY = main.visibleFrame.minY
            let highY = main.visibleFrame.minY + 40
            let low = ProcessInfo.processInfo.arguments.contains("--low")
            win.setFrameOrigin(NSPoint(x: main.visibleFrame.minX + 40,
                                       y: low ? lowY : highY))
            settle(0.6)
            let f = win.frame
            // 截图坐标是**全局主屏坐标系**（原点在主屏左上），不是这块屏的
            let top = (NSScreen.screens.first ?? main).frame.maxY
            let rect = "\(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width) + 420),\(Int(f.height))"
            print("弹开最宽的那个（\(Int(target.frame.width))pt），截 \(rect)…")
            let path = "/private/tmp/claude-501/-Users-xiaosongxiaosong-Documents-MagicKey/"
                     + "23c17b13-e1d0-4b03-acbd-88d060201b54/scratchpad/picker.png"
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 1.5)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // 两块屏各存一张：菜单可能根本不在窗口那块屏上，
                // 只截窗口所在区域就会「什么都没拍到」而误以为菜单没弹出来。
                p.arguments = ["-x", path, path.replacingOccurrences(of: ".png", with: "_2.png")]
                try? p.run(); p.waitUntilExit()
                print("截图 → \(path)")
                exit(0)
            }
            target.performClick(nil)
        }
        exit(0)
    }

    private static func allPopUps(_ v: NSView) -> [NSPopUpButton] {
        var out: [NSPopUpButton] = []
        if let p = v as? NSPopUpButton { out.append(p) }
        for sub in v.subviews { out += allPopUps(sub) }
        return out
    }

    // MARK: - 跑

    static func run() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--repro-settings") { reproSettings() }
        if args.contains("--dump-picker") { dumpPicker() }
        if args.contains("--repro-fullscreen") { reproFullscreen() }
        if let i = args.firstIndex(of: "--shot-settings"), i + 1 < args.count {
            shootSettings(to: args[i + 1], dark: args.contains("--dark"))
        }
        if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
            shoot(to: args[i + 1], dark: args.contains("--dark"))
        }

        let settings = Settings()
        let updates = UpdateChecker()
        let audio = AudioStatusModel()
        let keySound = KeySoundController()
        let metrics = PanelMetrics()
        let engine = Engine(probe: .running)
        metrics.update(screen: NSScreen.main, menuBar: 33)

        // 音效开着会多出状态行和音量行，面板就高一截。高度这一组要可复现，
        // 所以显式摆成出厂状态（关闭）——探针自己的 UserDefaults 域里可能
        // 留着上一次跑 keySoundChecks 时写进去的值。
        settings.keySoundEnabled = false

        print("MagicKey UI 探针")
        print("屏幕可用高度上限 = \(Int(metrics.maxHeight))pt"
              + "（visibleFrame = \(Int(NSScreen.main?.visibleFrame.height ?? 0))pt）")

        // 只装一次，之后全靠改绑定。理由见 measure 的注释。
        mount(settings: settings, engine: engine, updates: updates,
              audio: audio, keySound: keySound, metrics: metrics)

        var failures: [String] = []
        var overflow: [String] = []

        // ── 1. 六效果的面板高度 ─────────────────────────────────────
        print("\n── 面板高度（只显示当前效果需要的参数）──")
        var heights: [String: CGFloat] = [:]
        for kind in EffectKind.allCases {
            settings.kind = kind
            let m = measure(label: kind.displayName, metrics: metrics)
            heights[kind.displayName] = m.size.height
            let flag = m.overflows ? "❌ 超出上限" : m.isScrolling ? "· 滚动中" : "✅"
            print(String(format: "  %-8@ %6.0fpt  内容 %.0fpt  %@",
                         kind.displayName as NSString, m.size.height,
                         m.contentHeight, flag as NSString))
            if m.overflows { overflow.append(kind.displayName) }
        }

        // ── 2. 面板收缩 ────────────────────────────────────────────
        // 从最高的效果切回最矮的，面板必须真的缩回去。
        // 这是当初从 MenuBarExtra 换成 NSPopover 的全部理由，必须有回归。
        print("\n── 面板收缩（音乐 → 常亮）──")
        settings.kind = .audioBeat
        let tall = measure(label: "音乐", metrics: metrics).size.height
        settings.kind = .staticLevel
        let short = measure(label: "常亮", metrics: metrics).size.height
        let shrank = short < tall - 1
        print(String(format: "  %.0fpt → %.0fpt  %@", tall, short,
                     (shrank ? "✅ 缩回去了" : "❌ 只涨不缩") as NSString))
        if !shrank { failures.append("面板不缩回") }

        // ── 3. 窄屏：超了要滚，不能撑破 ──────────────────────────────
        print("\n── 窄屏（上限压到 300pt）──")
        let narrow = PanelMetrics()
        narrow.forceMaxHeight(300)
        mount(settings: settings, engine: engine, updates: updates,
              audio: audio, keySound: keySound, metrics: narrow)
        for kind in [EffectKind.staticLevel, .audioBeat] {
            settings.kind = kind
            let m = measure(label: kind.displayName, metrics: narrow)
            let ok = m.size.height <= narrow.maxHeight + 1
            print(String(format: "  %-8@ %6.0fpt / 上限 %.0fpt  %@",
                         kind.displayName as NSString, m.size.height, narrow.maxHeight,
                         (ok ? "✅" : "❌ 撑破") as NSString))
            if !ok { overflow.append("\(kind.displayName)@窄屏") }
        }

        // ── 4. Engine 五态 ─────────────────────────────────────────
        print("\n── Engine 五态 ──")
        mount(settings: settings, engine: engine, updates: updates,
              audio: audio, keySound: keySound, metrics: metrics)
        settings.kind = .breathe
        let phases: [(String, Engine.Phase)] = [
            ("运行中",     .running),
            ("已关闭",     .stopped),
            ("暂停·锁屏",  .paused("锁屏")),
            ("暂停·空闲",  .paused("用户空闲 120s")),
            ("不受支持",   .unsupported),
        ]
        for (name, phase) in phases {
            engine.setProbePhase(phase)
            let m = measure(label: name, metrics: metrics)
            print(String(format: "  %-10@ %6.0fpt 内容%.0fpt  available=%@  status=%@",
                         name as NSString, m.size.height, m.contentHeight,
                         (engine.available ? "是" : "否") as NSString,
                         engine.status as NSString))
        }
        // 不受支持时中段换成一句提示，必须明显比正常态矮
        engine.setProbePhase(.unsupported)
        let unsupported = measure(label: "不受支持", metrics: metrics).size.height
        engine.setProbePhase(.running)
        let normal = measure(label: "运行中", metrics: metrics).size.height
        if unsupported >= normal {
            failures.append("不受支持时面板没有变矮（中段可能没切到提示）")
        }

        // ── 5. 更新五态 ────────────────────────────────────────────
        print("\n── UpdateChecker 五态（Footer 不该被撑宽）──")
        for (name, state) in UpdateChecker.probeStates {
            updates.setProbeState(state)
            let m = measure(label: name, metrics: metrics)
            let ok = abs(m.size.width - 360) < 1
            print(String(format: "  %-14@ %6.0f×%.0fpt  %@", name as NSString,
                         m.size.width, m.size.height,
                         (ok ? "✅" : "❌ 宽度被撑到 \(Int(m.size.width))") as NSString))
            if !ok { failures.append("更新状态「\(name)」撑宽了 Footer") }
        }
        updates.setProbeState(.idle)

        // ── 5c. 键盘音效各态的面板高度 ─────────────────────────────
        // 音效区在**所有**效果下都在，所以它撑高的是每一个面板。
        // 未授权那几态还会多一行文字加一个按钮，是里面最高的——
        // 加控件之前先看这一行会不会顶到窄屏上限。
        print("\n── 键盘音效五态（面板高度）──")
        settings.kind = .breathe
        let baseHeight = measure(label: "关闭", metrics: metrics).size.height
        settings.keySoundEnabled = true
        // 「未放行」「需重开」那两句文案最长，最可能折行把面板顶高——
        // 正因如此它必须在这一组里，不能只测好看的那几态。
        for (name, s) in [("需要授权", KeySoundStatus.needsPermission),
                          ("请求中",   .requesting),
                          ("未放行",   .blocked),
                          ("需重开",   .needsRestart),
                          ("响应中",   .running)] {
            keySound.setProbeStatus(s)
            let m = measure(label: name, metrics: metrics)
            let ok = abs(m.size.width - 360) < 1
            print(String(format: "  开·%-8@ %6.0f×%.0fpt（关闭时 %.0fpt，+%.0f）  %@",
                         name as NSString, m.size.width, m.size.height, baseHeight,
                         m.size.height - baseHeight,
                         (ok ? "✅" : "❌ 宽度被撑到 \(Int(m.size.width))") as NSString))
            if !ok { failures.append("键盘音效「\(name)」撑宽了面板") }
            if m.size.height <= baseHeight {
                failures.append("键盘音效打开后面板没变高（「\(name)」那一区可能没画出来）")
            }
        }
        settings.keySoundEnabled = false
        keySound.setProbeStatus(.off)

        // ── 5b. 初始焦点：**只打印，不作判据** ────────────────────────
        //
        // 「打开面板时亮度输入框不该自动获得焦点」这条探针**测不了**。
        // 阴性对照：把 AppDelegate 那段 clearInitialFocus 从探针里去掉，
        // 甚至再补一次 window.makeKey()，firstResponder 照样停在
        // _NSPopoverWindow，报「✅」——因为探针进程从后台 shell 起，
        // 应用不活跃，AppKit 根本没走到指派 initial first responder 那一步。
        //
        // 所以这里只打印观测值。**不要把它加回 failures**：
        // 一个查不到东西的检查报通过，比没有这个检查更糟（本文件上面已经栽过一次）。
        print("\n── 初始焦点（信息性，探针测不了，见注释）──")
        settings.kind = .breathe
        _ = measure(label: "focus", metrics: metrics)
        let fr = popover.contentViewController?.view.window?.firstResponder
        print("  firstResponder = \(fr.map { "\(type(of: $0))" } ?? "nil")"
              + "   （真机验证：点开状态栏，亮度框不该有光标）")

        // ── 6. 无障碍（信息性，判据见注释）──────────────────────────
        let nodes = accessibilityTree(of: popover.contentViewController?.view)
        let controls = nodes.filter(\.isControl)
        let unnamed = nodes.filter(\.isUnnamed)
        if ProcessInfo.processInfo.arguments.contains("--dump-ax") {
            print("\n── 无障碍树 ──")
            for n in nodes {
                print("  " + String(repeating: "  ", count: n.depth) + n.role
                      + (n.label.map { "  label=\($0)" } ?? ""))
            }
        }

        // ── 7. 面板落点与设置窗口位置 ──────────────────────────────
        // 放在最后：settingsCenterChecks 会把 activationPolicy 切成 .regular，
        // 别让它影响前面那些尺寸测量。
        failures += keySoundPackInventoryChecks()
        failures += keySoundChecks(settings: settings)
        failures += keySoundRenderChecks()
        failures += keyboardLayoutChecks()
        failures += customImportChecks(store: CustomSoundStore.shared)
        failures += customResolutionChecks(store: CustomSoundStore.shared, settings: settings)
        failures += customRenderChecks(store: CustomSoundStore.shared)
        failures += anchorChecks()
        failures += focusChecks()
        // 这两组会把 activationPolicy 切成 .regular，放在最后，
        // 别让它影响前面那些尺寸测量
        failures += keyPopoverAnchorChecks(store: CustomSoundStore.shared, settings: settings)
        failures += keyMapWindowChecks(store: CustomSoundStore.shared, settings: settings,
                                       updates: updates)
        failures += settingsCenterChecks(settings: settings, updates: updates)

        // ── 汇总 ───────────────────────────────────────────────────
        print("\n── 汇总 ──")
        if controls.isEmpty {
            print("无障碍：进程内查不到 SwiftUI 控件（预期，非故障——见 accessibilityTree 注释）")
            print("        标签由 paramRow 的构造强制保证；听感需人工过 VoiceOver")
        } else {
            print("无障碍控件 \(controls.count) 个，缺标签 \(unnamed.count) 个")
            if !unnamed.isEmpty { failures.append("\(unnamed.count) 个控件缺标签") }
        }
        if !overflow.isEmpty { failures.append("超出屏幕：" + overflow.joined(separator: "、")) }

        if failures.isEmpty {
            print("✅ 全部通过")
            exit(0)
        }
        for f in failures { print("❌ \(f)") }
        exit(1)
    }
}

@main
enum ProbeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // ⚠️ **必须在碰到任何 `CustomSoundStore.shared` 之前设。**
        // `shared` 是惰性全局，解析过一次就再也不会重新解析目录了，
        // 而 `UIProbe.run()` 里第一行造的 `KeySoundController` 就会碰它。
        // 不挪走的话，探针会往用户真正的 App Support 目录里写测试采样，
        // 「删除音色」那一步还会删掉用户自己导入的东西。
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("magickey-uiprobe-sounds", isDirectory: true)
        try? FileManager.default.removeItem(at: sandbox)   // 每次从干净状态开始
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        CustomSoundStore.probeDirectoryOverride = sandbox

        MainActor.assumeIsolated {
            Log.sink = { _ in }          // 探针不要引擎日志刷屏
            UIProbe.run()
        }
    }
}
