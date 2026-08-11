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
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .applicationDefined
        if let anchorView = anchor.contentView {
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        }
        settle(0.4)
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
        settings.kind = .breathe          // 选中态要看得见，随便挑一个非首项
        mount(settings: settings,
              engine: Engine(probe: .running),
              updates: UpdateChecker(),
              audio: AudioStatusModel(),
              metrics: PanelMetrics())
        settle(0.6)

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

    // MARK: - 跑

    static func run() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
            shoot(to: args[i + 1], dark: args.contains("--dark"))
        }

        let settings = Settings()
        let updates = UpdateChecker()
        let audio = AudioStatusModel()
        let metrics = PanelMetrics()
        let engine = Engine(probe: .running)
        metrics.update(screen: NSScreen.main, statusBarHeight: 33)

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
