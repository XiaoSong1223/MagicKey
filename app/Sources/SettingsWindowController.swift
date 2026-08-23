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

    /// 设置窗口开着没有。
    ///
    /// ⚠️ **不要拿这个去判断「该不该把前台还回去」**——现在还有一个键盘图窗口，
    /// 那个判断的正确判据是 `AppWindows.anyOpen`（两个窗口的并集）。
    static var isOpen: Bool { shared != nil }

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

    /// 摆到目标屏的正中。
    ///
    /// 实现在 `AppWindows.centerOnActiveScreen`——键盘图窗口要走同一套
    /// （连「先按 fittingSize 定尺寸再居中」那个坑一起），复制第二份必然会漂。
    ///
    /// 不用 `setFrameAutosaveName`：那会把上次拖到的位置记进 defaults，
    /// 下次打开就不在中间了——而这个窗口是关掉即销毁的单例，每次打开都是
    /// 「重新出现」，出现在正中比出现在上次的位置更符合预期。
    private func centerOnActiveScreen() {
        guard let window else { return }
        AppWindows.centerOnActiveScreen(window)
    }

    /// **必须先切成 `.regular` 再激活**，理由和「为什么这件事归 `AppWindows` 管」
    /// 一起写在那边的类型注释里。
    ///
    /// 切 `.regular` 期间会多出一个 Dock 图标和菜单栏，这是菜单栏应用开设置窗口的
    /// 常规做法，也顺带让 ⌘W / ⌘Q 变得可见。**所有**窗口都关掉之后才切回去。
    private func bringToFront() {
        AppWindows.willOpen(self)
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
    /// 已经返回 false。这里放掉单例，激活策略交给 `AppWindows`：
    /// 键盘图窗口还开着时**不能**切回 `.accessory`，那会把它当场画灰。
    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        AppWindows.didClose(self)
    }
}
