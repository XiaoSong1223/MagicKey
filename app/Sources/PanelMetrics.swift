import AppKit
import Combine

/// 面板能用多高——由 `AppDelegate` 在**打开面板之前**算好推给视图。
///
/// **为什么是推而不是拉。** 视图内部没有任何可靠办法知道自己会被摆到哪块屏上：
/// `NSPopover` 还没 show，宿主视图也就还没有 window，更没有 screen。
/// 上一版退而求其次用了 `NSScreen.main`（"含 key window 的那块屏"），
/// 在这个 app 里恰好是错的——`togglePanel` 已经处理过两种锚点失效：
/// 按钮窗口可能落在**另一块屏**上，也可能整个不在任何屏上（全屏 Space）。
/// 那两种情况下 `NSScreen.main` 给出的正是**用户没在看的**那块屏的高度。
///
/// 而 `AppDelegate` 恰好已经算出了答案：`clickedScreen()`——用户刚点完图标，
/// 指针就停在图标上。所以让它顺手把高度一起推下来，视图只管用。
///
/// ⚠️ 这**不是**「视图量自己再设自己的 frame」。那条路是循环依赖，
/// 实测会把面板永远钉在 1pt（见 `MenuBarView` 里的警告）。这里的高度
/// 完全来自屏幕几何，和内容尺寸无关，不构成回路。
@MainActor
final class PanelMetrics: ObservableObject {

    /// 内容超过这个高度才开始滚动。初值只在「还没点过图标」的一瞬间有效。
    @Published private(set) var maxHeight: CGFloat = 600

    /// 面板底部留出的余量，免得正好贴死在屏幕下沿
    private static let bottomMargin: CGFloat = 24

    /// 面板再矮也得能放下 Header + 几行 + Footer
    private static let floor: CGFloat = 320

    /// - Parameters:
    ///   - screen: 面板实际会出现的那块屏
    ///   - statusBarHeight: 状态栏窗口的真实高度。`NSStatusBar.system.thickness`
    ///     本机返回 22pt，而刘海屏/外接屏的实际菜单栏是 33/30pt——只拿它保底。
    func update(screen: NSScreen?, statusBarHeight: CGFloat?) {
        guard let screen else { return }
        let menuBar = max(statusBarHeight ?? 0, NSStatusBar.system.thickness)

        // 普通 Space：visibleFrame 已经扣掉了菜单栏和 Dock，直接可用。
        // 全屏 Space：visibleFrame == frame，扣不掉菜单栏，得自己减。
        // 取两者较小的那个，一个式子覆盖两种情况。
        let usable = min(screen.visibleFrame.height,
                         screen.frame.height - menuBar) - Self.bottomMargin
        maxHeight = max(Self.floor, usable)
    }

    #if UI_PROBE
    /// 只在 UI 探针里编译。用来模拟矮屏幕——「内容超过上限时要滚动而不是撑破」
    /// 这条在开发机上永远测不到（屏幕太高），而它正是踩过三次的那个坑。
    func forceMaxHeight(_ h: CGFloat) { maxHeight = h }
    #endif
}
