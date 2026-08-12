import AppKit
import SwiftUI

/// 面板的宿主控制器。存在的唯一理由：**把 SwiftUI 的实际尺寸同步给
/// `NSPopover.contentSize`**。
///
/// ## 不同步会怎样：面板整体右移 20pt、下移 20pt
///
/// `NSPopover` 用 `contentSize` 决定窗口摆在哪，而它**不会**自己跟着
/// `NSHostingController` 的尺寸走。实测（`--dissect`）：面板都显示出来了，
/// `po.contentSize` 仍然是默认的 **320×320**。于是：
///
/// 1. NSPopover 按 320×320 算，窗口应为 346×346，摆在锚点正下方；
/// 2. SwiftUI 布局跑完，宿主视图变成 360×300，AppKit 把窗口撑成 386×326，
///    **原点不动**；
/// 3. 宽 346→386、minX 不动 → 中心右移 (386−346)/2 = **20**；
///    高 346→326、minY 不动 → 顶边下移 (346−326)/2 = **20**。
///
/// 两个 20 是同一个 20。用户看到的是「面板不在图标正下方，还差一截」——
/// 箭头其实是准的（它钉在锚点上），跑掉的是面板本体。
///
/// 补一句判据：`contentSize` 设对之后，内容中心与图标中心差 **0.0**，
/// 内容顶边比菜单栏下沿低 **13pt**——那 13pt 是 popover 窗口四周的透明边距
/// （箭头画在里面），是系统外观，不是空隙。
///
/// ## 为什么要在 `viewDidLayout` 里同步，而不是显示前设一次
///
/// 面板高度随效果变（常亮 272 / 音乐 473），换效果时 SwiftUI 会重新布局。
/// 只在 show 之前设一次，换一次效果就又偏了。
/// 让持有者不必带上 SwiftUI 的泛型参数就能叫一次同步
@MainActor
protocol PanelSizeSyncing: AnyObject {
    func syncContentSize()
}

final class PanelHostingController<Content: View>: NSHostingController<Content>, PanelSizeSyncing {

    /// 弱引用，避免和 `NSPopover.contentViewController` 形成环
    weak var popover: NSPopover?

    override func viewDidLayout() {
        super.viewDidLayout()
        syncContentSize()
    }

    /// show 之前手动叫一次：那时还没走过 `viewDidLayout`，
    /// 而定位就发生在 show 的那一刻，晚一帧都来不及。
    func syncContentSize() {
        guard let popover else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        // 相等就不写：赋值会让已显示的 popover 重新布局，不设防会来回震荡
        guard abs(size.width - popover.contentSize.width) > 0.5
              || abs(size.height - popover.contentSize.height) > 0.5 else { return }
        popover.contentSize = size
    }
}
