import AppKit
import SwiftUI

/// 「自定义按键音」窗口。单例——重复点那个按钮应该把已经开着的窗口拿到前面来，
/// 而不是叠出第二个（两个窗口各自持有同一份 store，改动会打架）。
///
/// 和 `SettingsWindowController` 是**并列**的两个独立窗口，不是父子关系：
/// 键盘图内容宽（一张键盘至少要 700pt），塞进 480pt 宽的设置窗口里会挤成一团。
///
/// ⚠️ 激活策略和居中都走 `AppWindows`，**不要在这里再写一份**。
/// 关窗时若直接切回 `.accessory`，还开着的设置窗口会当场被画成灰的。
@MainActor
final class KeyMapWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: KeyMapWindowController?

    static var isOpen: Bool { shared != nil }

    static func show(store: CustomSoundStore, settings: Settings) {
        if let existing = shared {
            existing.bringToFront()
            return
        }
        let host = NSHostingController(rootView: KeyMapView(store: store, settings: settings))

        let window = NSWindow(contentViewController: host)
        window.title = "自定义按键音"
        // 可缩放：键盘图按宽度缩放，用户想看大一点就该能拉大。
        // 设置窗口是固定宽的单页表单，没有这个需求，所以两边 styleMask 不同。
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        let controller = KeyMapWindowController(window: window)
        window.delegate = controller
        shared = controller
        AppWindows.centerOnActiveScreen(window)
        controller.bringToFront()
    }

    private func bringToFront() {
        AppWindows.willOpen(self)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        // 试听引擎跟着窗口走：没人听的时候别让 CoreAudio 的 IO 线程空转
        SoundPreviewPlayer.shared.stop()
        AppWindows.didClose(self)
    }
}
