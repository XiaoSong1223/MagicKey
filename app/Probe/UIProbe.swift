import AppKit
import SwiftUI

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
                      audio: AudioStatusModel, metrics: PanelMetrics) {
        let view = MenuBarView(settings: settings, engine: engine, updates: updates,
                               audio: audio, metrics: metrics)
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
                                  audio: AudioStatusModel(), metrics: metrics))
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
                                  metrics: metrics))
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

    // MARK: - 跑

    static func run() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--repro-settings") { reproSettings() }
        if let i = args.firstIndex(of: "--shot-settings"), i + 1 < args.count {
            shootSettings(to: args[i + 1], dark: args.contains("--dark"))
        }
        if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
            shoot(to: args[i + 1], dark: args.contains("--dark"))
        }

        let settings = Settings()
        let updates = UpdateChecker()
        let audio = AudioStatusModel()
        let metrics = PanelMetrics()
        let engine = Engine(probe: .running)
        metrics.update(screen: NSScreen.main, menuBar: 33)

        print("MagicKey UI 探针")
        print("屏幕可用高度上限 = \(Int(metrics.maxHeight))pt"
              + "（visibleFrame = \(Int(NSScreen.main?.visibleFrame.height ?? 0))pt）")

        // 只装一次，之后全靠改绑定。理由见 measure 的注释。
        mount(settings: settings, engine: engine, updates: updates,
              audio: audio, metrics: metrics)

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
              audio: audio, metrics: narrow)
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
              audio: audio, metrics: metrics)
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
        failures += anchorChecks()
        failures += focusChecks()
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
        MainActor.assumeIsolated {
            Log.sink = { _ in }          // 探针不要引擎日志刷屏
            UIProbe.run()
        }
    }
}
