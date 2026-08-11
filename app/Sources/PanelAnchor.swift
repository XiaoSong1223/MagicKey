import AppKit

/// 面板的落点：**钉在状态栏图标正下方，且不跟着状态项窗口的几何抖动跑。**
///
/// ## 为什么不直接把 `button.bounds` 交给 NSPopover
///
/// 那样最自然，但等于把面板的纵向位置外包给了状态项窗口的高度——而这个高度
/// **不由本进程决定**。macOS 26 上状态项由控制中心统一托管：被托管时窗口高度
/// 等于菜单栏（刘海屏 33 / 外接屏 30），没被托管时退化成 22
/// （见 CLAUDE.md「状态栏图标不显示」，那里把这个高度当体检指标用）。
///
/// 开关设置窗口会切一次 `NSApp.activationPolicy`，菜单栏在那一刻重排，
/// 状态项窗口有一段时间是 22pt——底边比菜单栏下沿高出 11pt，面板就跟着整体上移；
/// 等控制中心重新接管，高度回到 33，面板又自己回去了。用户看到的正是
/// 「点开设置再关掉，面板往上跳了一下，过一会儿又好了」。
///
/// 所以纵向位置改从**屏幕几何**推：菜单栏下沿 = `frame.maxY - visibleFrame.maxY`，
/// 只和显示器有关，没得抖。横向仍然取按钮自己的位置——那一维本来就是准的，
/// 而且必须准，「正下方」说的就是它。
///
/// 健康状态下这两种算法给出的是**同一个数**（状态项窗口高度就等于菜单栏高度），
/// 所以这不是「换个位置」，是「把同一个位置钉死」。
@MainActor
enum PanelAnchor {

    /// 各屏最近一次量到的菜单栏高度。
    /// 全屏 Space 里 `visibleFrame == frame`，当场量不出来，只能用上一次的。
    private static var cachedMenuBar: [CGDirectDisplayID: CGFloat] = [:]

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// 菜单栏高度。
    ///
    /// - Parameter statusBarWindowHeight: 状态项窗口的高度，**只在这块屏从没在
    ///   普通 Space 里被量到过时才用**（刚开机就在全屏 Space 里）。它正是本文件
    ///   要绕开的那个不可靠的量，所以排在最后。
    static func menuBarHeight(on screen: NSScreen,
                              statusBarWindowHeight: CGFloat? = nil) -> CGFloat {
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        let id = displayID(of: screen)
        if measured > 0 {
            if let id { cachedMenuBar[id] = measured }
            return measured
        }
        if let id, let cached = cachedMenuBar[id] { return cached }
        // NSStatusBar.thickness 本机返回 22，比真实菜单栏（33/30）矮，只当保底
        return max(statusBarWindowHeight ?? 0, NSStatusBar.system.thickness)
    }

    /// 菜单栏下沿的屏幕 y —— 面板顶边要贴的那条线
    static func menuBarBottom(on screen: NSScreen,
                              statusBarWindowHeight: CGFloat? = nil) -> CGFloat {
        screen.frame.maxY - menuBarHeight(on: screen,
                                          statusBarWindowHeight: statusBarWindowHeight)
    }

    /// 交给 `NSPopover` 的定位矩形，在 `button` 自己的坐标系里。
    /// 横向原样保留（就是图标本身），纵向拉到菜单栏下沿。
    ///
    /// 面板开着的时候如果锚点窗口的几何变了，这个矩形就过期了——
    /// 调用方要盯着窗口的 move/resize 重算一次，见 `AppDelegate.observeAnchorGeometry`。
    static func positioningRect(for button: NSView, on screen: NSScreen) -> NSRect {
        guard let window = button.window else { return button.bounds }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let dy = menuBarBottom(on: screen, statusBarWindowHeight: window.frame.height)
               - onScreen.minY
        // NSView 默认 y 向上，翻转过的视图要反号。NSStatusBarButton 不翻转，
        // 但这里不该依赖那个实现细节。
        let rect = button.bounds.offsetBy(dx: 0, dy: button.isFlipped ? -dy : dy)

        // ⚠️ **定位矩形必须和按钮 bounds 有交集，否则 NSPopover 静默不显示。**
        // 实测：按钮窗口被挪到所有屏幕之外（全屏 Space，见 AppDelegate 里那两种
        // 锚点失效）时 dy 会是 -189，矩形整个飞出按钮，面板压根不出现——
        // 比原来那 11pt 的位移糟糕得多。
        //
        // 正常修正量只有几个 pt（状态项窗口高度和菜单栏高度之差），
        // 一旦大到脱离按钮，说明调用方的几何前提已经不成立了，退回按钮本身。
        guard rect.intersects(button.bounds) else {
            Log.write("[panel] 锚点几何异常（dy=\(Int(dy))），落点退回按钮矩形")
            return button.bounds
        }
        return rect
    }
}
