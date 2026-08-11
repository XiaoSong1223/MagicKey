import SwiftUI

/// 效果选择器：2×3 网格。
///
/// **为什么不是 `Picker`。** 六段的 `.segmented` 在 360pt 宽里每格只有 55pt，
/// 图标加两个汉字放不下，标签会被截断。网格给每格 108pt，图标和名字都能完整显示。
///
/// 代价是丢掉 `Picker` 免费带来的无障碍语义（单选组、方向键切换）。
/// 用 `.accessibilityRepresentation` 把它补回来——视觉上是自定义网格，
/// VoiceOver 那边被替换成一个真正的 `Picker`，不需要手搓 AX 角色和键盘导航。
struct EffectGrid: View {

    @Binding var selection: EffectKind
    var isEnabled: Bool = true

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(EffectKind.allCases) { kind in
                cell(kind)
            }
        }
        .disabled(!isEnabled)
        // VoiceOver 看到的是一个标准单选组，不是六个孤立按钮
        .accessibilityRepresentation {
            Picker("效果", selection: $selection) {
                ForEach(EffectKind.allCases) { k in
                    Text(k.displayName).tag(k)
                }
            }
        }
    }

    private func cell(_ kind: EffectKind) -> some View {
        let selected = kind == selection
        return Button {
            selection = kind
        } label: {
            VStack(spacing: 4) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(kind.displayName)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())          // 整格可点，不只是图标和文字
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .selectionBackground(selected)
        .help(kind.note ?? kind.displayName)
    }
}

// MARK: - 选中背景

private extension View {
    /// 选中的那一格加背景，其余不加——「禁止每个区域都套玻璃」。
    ///
    /// 这是**整个面板里唯一一处自定义玻璃**。popover 的外壳玻璃由系统提供，
    /// 我们不碰。
    @ViewBuilder
    func selectionBackground(_ selected: Bool) -> some View {
        if !selected {
            self
        } else {
            #if LIQUID_GLASS_SDK
            if #available(macOS 26.0, *) {
                self.glassEffect(.regular.tint(.accentColor.opacity(0.5)).interactive(),
                                 in: .rect(cornerRadius: 10))
            } else {
                self.minimalSelection()
            }
            #else
            self.minimalSelection()
            #endif
        }
    }

    /// macOS 14–25 的兜底。**这不是一套设计过的回退外观**——
    /// 2026-08-11 决定不为旧系统做外观，本机也没有 14/15 可以实测。
    /// 它存在的唯一目的是让「哪一格被选中」在旧系统上仍然看得见，
    /// 没有它选中态就完全不可见了。
    func minimalSelection() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        )
    }
}
