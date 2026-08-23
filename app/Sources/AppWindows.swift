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
    static func willOpen(_ owner: AnyObject) {
        open.insert(ObjectIdentifier(owner))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
