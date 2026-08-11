import AppKit
import SwiftUI

/// 设置窗口。单例——重复点「设置」应该把已经开着的那个窗口拿到前面来，
/// 而不是叠出第二个。
///
/// 用 `NSWindowController` + `NSHostingController` 而不是 SwiftUI 的
/// `Settings` scene：本应用的入口是裸 `NSApplication`（见 `MagicKeyApp.swift`
/// 顶部关于 `MenuBarExtra` 的说明），没有 `App` 场景可以往里挂。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: SettingsWindowController?

    /// 打开设置窗口；已经开着就拿到最前面。
    static func show(settings: Settings, updates: UpdateChecker) {
        if let existing = shared {
            existing.bringToFront()
            return
        }
        let host = NSHostingController(
            rootView: SettingsView(settings: settings, updates: updates))

        let window = NSWindow(contentViewController: host)
        window.title = "MagicKey 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false      // 关掉之后还要能再打开

        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        shared = controller
        controller.centerOnActiveScreen()
        controller.bringToFront()
    }

    /// 摆到目标屏的**正中**。
    ///
    /// 不用 `NSWindow.center()`：它只有水平方向是居中的，垂直方向刻意偏上
    /// （官方措辞是「somewhat above center」），并排看一眼就知道不是正中间。
    ///
    /// 也不用 `setFrameAutosaveName`：那会把上次拖到的位置记进 defaults，
    /// 下次打开就不在中间了——而这个窗口是关掉即销毁的单例，每次打开都是
    /// 「重新出现」，出现在正中比出现在上次的位置更符合预期。
    ///
    /// 目标屏取**指针所在的那块**：用户刚在面板里点完「设置」，指针就停在那儿。
    /// 和 `AppDelegate.clickedScreen()` 是同一个判据。
    private func centerOnActiveScreen() {
        guard let window else { return }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }

        // ⚠️ **先把尺寸定下来再居中。** `NSWindow(contentViewController:)` 建出来的
        // 窗口在 SwiftUI 跑完第一次布局之前是空的（探针实测：那一刻 frame 是 0×32）。
        // 拿 0×32 去算居中，偏差正好是半个窗口——探针报过 (+240, +210)。
        // `layoutIfNeeded()` 不够，它不改窗口尺寸，得自己按 fittingSize 设一次。
        //
        // 顺带修掉另一件事：AppKit 自己定的窗口高度取的是 `SettingsView` 声明的
        // **minHeight（420）**，一开窗内容就在滚动；`fittingSize` 给的是
        // idealHeight（560），才是那个声明本来的意思。
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            var fitting = content.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                // 矮屏上别顶满：留 48pt 给窗口投影和上下呼吸
                fitting.height = min(fitting.height, visible.height - 48)
                window.setContentSize(fitting)
            }
        }

        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                      y: (visible.midY - size.height / 2).rounded()))
    }

    /// **必须先切成 `.regular` 再激活。**
    ///
    /// `.accessory` 应用无法可靠地自我激活：`NSApp.activate(ignoringOtherApps:)`
    /// 在 macOS 14+ 已废弃，系统会忽略后台应用的抢焦点请求。实测（探针）：
    /// 调完之后 `NSApp.isActive == false`、`window.isKeyWindow == false`，
    /// 而 `canBecomeKey == true`——窗口本身没问题，是**整个应用没被激活**。
    ///
    /// 后果不是「窗口在别人后面」这么轻：AppKit 会把非 key 窗口里的每个控件
    /// 都画成非活跃样式——开关失去强调色变成灰的、滑块头是白圆点贴在浅灰轨道上，
    /// 在浅色背景里几乎看不见。看起来像配色没调好，其实是激活状态不对。
    ///
    /// 切 `.regular` 期间会多出一个 Dock 图标和菜单栏，这是菜单栏应用开设置窗口的
    /// 常规做法，也顺带让 ⌘W / ⌘Q 变得可见。窗口一关就切回去。
    private func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)

        // 窗口没成为 key 时 AppKit 会把所有控件画成非活跃样式（开关掉色、
        // 滑块头低对比），看起来像配色问题。真出问题时先看这行，别去调颜色。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let w = self?.window
            Log.write("[settings] isActive=\(NSApp.isActive) "
                      + "isKey=\(w?.isKeyWindow ?? false) "
                      + "policy=\(NSApp.activationPolicy().rawValue)")
        }
    }

    /// 关掉设置窗口**不退出应用**——`applicationShouldTerminateAfterLastWindowClosed`
    /// 已经返回 false。这里把激活策略切回纯菜单栏，并放掉单例。
    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        // 放到下一个 runloop：窗口还在关闭流程里，此刻改策略会让 AppKit
        // 在半途重排菜单栏和 Dock。
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
