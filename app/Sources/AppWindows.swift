import AppKit

/// 本应用那几个独立窗口（设置、自定义按键音）共用的**前台策略**与**居中**。
///
/// ## 为什么必须集中在一处
///
/// `.accessory` 应用开窗要做两件事，两件都不能各窗口自己一份：
///
/// 1. **开窗前切 `.regular`**。`.accessory` 应用无法可靠地自我激活
///    （`NSApp.activate(ignoringOtherApps:)` 在 macOS 14+ 已废弃且被系统忽略），
///    窗口拿不到 key 时 AppKit 会把里面**每个控件**画成非活跃样式——开关掉色、
///    滑块头是白圆点贴在浅灰轨道上，在浅色背景里几乎看不见。看起来完全像
///    配色没调好，其实是激活状态不对。
/// 2. **关窗后切回 `.accessory`**，否则 Dock 图标一直挂着。
///
/// 有两个窗口之后，第 2 步就不能由各自的 `windowWillClose` 独立决定了：
/// 关掉设置窗口时若键盘图还开着，切回 `.accessory` 会让**那个还开着的窗口
/// 当场变灰**——正是第 1 步花力气避开的那件事。同理，`AppDelegate` 在面板关闭时
/// 的 `NSApp.deactivate()` 也必须对两个窗口取并集。
///
/// 所以判据是「**还有没有窗口开着**」，不是「我这个窗口关了没有」。
@MainActor
enum AppWindows {

    /// 开着的窗口控制器。用 `ObjectIdentifier` 而不是计数：
    /// 计数会被「重复点设置」这类重入调用悄悄加成 2，然后永远回不到 0。
    private static var open: Set<ObjectIdentifier> = []

    /// 还有窗口开着没有。面板关闭时据此决定还不还前台
    /// （见 `AppDelegate.popoverDidClose`）。
    static var anyOpen: Bool { !open.isEmpty }

    /// 开窗前调。幂等——同一个控制器调两次只算一个。
    ///
    /// 收 `NSWindowController` 而不是 `AnyObject`，是为了**顺手把窗口的
    /// Space 行为一起设掉**（见 `keepOnPlacedSpace`）：这两个窗口都是从
    /// 状态栏图标开出来的，摆到哪块屏就该待在哪块屏。
    static func willOpen(_ owner: NSWindowController) {
        open.insert(ObjectIdentifier(owner))
        if let window = owner.window { keepOnPlacedSpace(window) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        logState(owner)
    }

    /// 开窗之后回头看一眼真实状态。**三项缺一不可**：
    ///   - `isKey`：窗口没成为 key 时 AppKit 把每个控件画成非活跃样式
    ///     （开关掉色、滑块头低对比），看起来像配色问题，别去调颜色；
    ///   - `onActiveSpace`：窗口开在了另一块 Space 上——用户眼前什么都没有，
    ///     而窗口本身一切正常，从进程内查什么都是对的。这一项就是为它加的；
    ///   - `policy`：0 = `.regular`。切晚了 / 切回早了都会让窗口变灰。
    private static func logState(_ owner: NSWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak owner] in
            guard let w = owner?.window else { return }
            Log.write("[window] \(w.title) isActive=\(NSApp.isActive) "
                      + "isKey=\(w.isKeyWindow) onActiveSpace=\(w.isOnActiveSpace) "
                      + "policy=\(NSApp.activationPolicy().rawValue)")
        }
    }

    /// 窗口的 Space 行为：**三个标志都不要，保持默认的 `.managed`。**
    ///
    /// 摆位由 `centerOnActiveScreen` 决定（鼠标所在那块屏，也就是刚点过状态栏
    /// 图标的那块）。这里要做的只是**别让系统再把它挪走**。
    ///
    /// ## 会跨 Space 的标志都更糟（2026-08-23 真机，VSCode 全屏在外接屏）
    ///
    /// - `.fullScreenAuxiliary`：窗口能作为「客人」显示在别人的全屏 Space 上，
    ///   但**这个标志不传给子窗口**。窗口在眼前、里面全坏：`Picker` 弹出的
    ///   `NSMenu` 只显示一行，键盘图上点键弹的 `NSPopover` 被钳到屏幕左上角。
    /// - `.moveToActiveSpace`：更隐蔽。这台机器两块屏各有独立 Space，
    ///   「active space」是**外接屏上那块全屏 Space**——于是窗口被从鼠标所在的
    ///   内建屏**拽到外接屏、浮在全屏 VSCode 上**，落进和上一条一模一样的坑。
    ///   实测截图：内建屏空无一物，外接屏上设置窗口浮在全屏 VSCode 之上。
    /// - `.canJoinAllSpaces`：让窗口直接出现在全屏 Space，最终落进同一个
    ///   「父窗口能显示、菜单和 popover 子窗口不能正确显示」的状态。
    ///
    /// 这些标志都会造成「窗口看着好好的、子窗口全废」，而子窗口正是这个窗口的主要内容。
    /// 默认行为下窗口留在被摆到的那块屏的普通 Space 上，菜单和小面板都正常。
    ///
    /// 面板锚点那个 2pt 透明窗口是另一回事——它自己就是全部内容、没有子窗口，
    /// 所以那边该用 `.canJoinAllSpaces + .fullScreenAuxiliary`，两处别互相照抄。
    static func keepOnPlacedSpace(_ window: NSWindow) {
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.canJoinAllSpaces)
    }

    /// 窗口关闭时调。**全关了才切回 `.accessory`。**
    static func didClose(_ owner: AnyObject) {
        open.remove(ObjectIdentifier(owner))
        guard open.isEmpty else { return }
        // 放到下一个 runloop：窗口还在关闭流程里，此刻改策略会让 AppKit
        // 在半途重排菜单栏和 Dock。
        //
        // 推迟一拍就意味着这中间可能又开了一个窗口（比如从设置里点开键盘图，
        // 而设置窗口正好关掉），所以落地前必须再验一次。
        DispatchQueue.main.async {
            guard open.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 摆到目标屏的**正中**。
    ///
    /// 不用 `NSWindow.center()`：它只有水平方向是居中的，垂直方向刻意偏上
    /// （官方措辞是「somewhat above center」），并排看一眼就知道不是正中间。
    ///
    /// 目标屏取**指针所在的那块**：用户刚在面板或设置窗口里点完按钮，
    /// 指针就停在那儿。和 `AppDelegate.clickedScreen()` 是同一个判据。
    ///
    /// ⚠️ **先把尺寸定下来再居中。** `NSWindow(contentViewController:)` 建出来的
    /// 窗口在 SwiftUI 跑完第一次布局之前是空的（探针实测：那一刻 frame 是 0×32）。
    /// 拿 0×32 去算居中，偏差正好是半个窗口——探针报过 (+240, +210)。
    /// `layoutIfNeeded()` 不够，它不改窗口尺寸，得自己按 `fittingSize` 设一次。
    ///
    /// 顺带修掉另一件事：AppKit 自己定的窗口高度取的是 SwiftUI 声明里的
    /// **minHeight** 而不是 idealHeight，一开窗内容就在滚动；
    /// 按 `fittingSize` 设完才是那个声明本来的意思。
    static func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }

        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            var fitting = content.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                // 矮屏/窄屏上别顶满：留 48pt 给窗口投影和上下呼吸。
                // 宽度也要钳——键盘图那个窗口比设置窗口宽得多。
                fitting.height = min(fitting.height, visible.height - 48)
                fitting.width = min(fitting.width, visible.width - 48)
                window.setContentSize(fitting)
            }
        }

        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                      y: (visible.midY - size.height / 2).rounded()))
    }
}
