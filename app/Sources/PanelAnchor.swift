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
    /// 造一个当锚点用的透明小窗口。
    ///
    /// `NSPopover.show(relativeTo:of:)` 只认视图、不收裸矩形，所以必须有个真窗口。
    /// `.statusBar` 层 + `canJoinAllSpaces` / `fullScreenAuxiliary`，
    /// 否则它进不了全屏空间，面板也就跟着开不出来。
    static func makeAnchorWindow() -> NSWindow {
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

    /// 把锚点窗口摆到「`centerX` 正下方、贴着菜单栏下沿」，返回可交给
    /// `NSPopover` 的视图。
    ///
    /// ## 为什么面板必须锚在这个窗口上，而不是状态项按钮上
    ///
    /// 全屏 Space 里菜单栏会自己收起来——指针一离开屏幕顶端，系统就把整条菜单栏
    /// （连同状态项窗口）挪到屏幕外（实测停在 y=1112，两块屏最高才 1080）。
    /// 而 `NSPopover` 是**跟着定位视图的窗口走**的：锚点一飞出屏幕，
    /// 它就被约束回主屏原点——用户看到的是「鼠标刚移到面板上，面板就闪到左上角」。
    ///
    /// 锚点归自己管就没这回事：这个窗口摆好之后谁都不会动它，
    /// 系统怎么折腾状态项都与面板无关。顺带也不必再盯着状态项窗口的高度变化重钉。
    ///
    /// 纵向仍然走 `menuBarBottom`（屏幕几何），所以状态项窗口是 33 还是退化成 22
    /// 都不影响落点；横向由调用方给：图标可用时给图标中心，不可用时给指针。
    @discardableResult
    static func place(_ window: NSWindow, centerX: CGFloat, on screen: NSScreen,
                      statusBarWindowHeight: CGFloat? = nil) -> NSView? {
        let size = NSSize(width: 2, height: 2)
        let x = min(max(centerX - size.width / 2, screen.frame.minX),
                    screen.frame.maxX - size.width)
        // 全屏 Space 里 visibleFrame == frame，直接拿 visibleFrame.maxY 会把整个
        // 2pt 锚点放到屏幕外，NSPopover 随后照样把面板约束回主屏。
        let y = max(screen.frame.minY,
                    min(menuBarBottom(on: screen, statusBarWindowHeight: statusBarWindowHeight),
                        screen.frame.maxY - size.height))
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        window.orderFrontRegardless()
        return window.contentView
    }
}
