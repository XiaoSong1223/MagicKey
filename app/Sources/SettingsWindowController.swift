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
        window.center()
        window.setFrameAutosaveName("MagicKey.Settings")

        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        shared = controller
        controller.bringToFront()
    }

    private func bringToFront() {
        // accessory 应用不会自动抢焦点，不显式激活的话窗口会开在别的 app 后面
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关掉设置窗口**不退出应用**——`applicationShouldTerminateAfterLastWindowClosed`
    /// 已经返回 false，这里只需要把单例放掉，让下次 `show` 重新建一个干净的。
    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
