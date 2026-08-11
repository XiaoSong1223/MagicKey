import SwiftUI

/// 百分比输入框：显示 `85%`，可直接键入数字。放在滑块右侧，绑同一个 0–1 的值。
///
/// ## 不要用 `@State` 去镜像 binding
///
/// 第一版是「`@State text` 存一份，`onChange(of: value)` 时同步过去」。
/// 实测：程序化把 `hi` 从 0.5 改到 0.87，**滑块头动了，输入框还停在 50%**。
/// 镜像状态和真值之间永远存在对不上的时机，靠再加一条同步路径去补是治标。
///
/// 现在的写法**没有镜像**：不在编辑时，显示的文字直接由 `value` 算出来，
/// 天然同步、没有可以失配的中间状态；只有获得焦点期间才存在一份本地草稿。
///
/// ## 编辑期间不回写
///
/// 边打字边把每个中间值推给引擎，会让人在想输 `80`、刚打完 `8` 的那一瞬间
/// 就把键盘调到 8% —— 闪一下再跳回去。所以草稿只在回车或失焦时提交一次。
struct PercentField: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 无障碍标签沿用外面那行的标题，别再单独起一个名字
    let label: String

    /// nil = 没在编辑，显示的是 `value` 算出来的值
    @State private var draft: String?
    @FocusState private var focused: Bool

    private var percent: Int { Int((value * 100).rounded()) }

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: Binding(get: { draft ?? "\(percent)" },
                                        set: { draft = $0 }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.caption).monospacedDigit()
                .frame(width: 26)
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onChange(of: focused) { _, isFocused in
                    // 进入编辑时把当前值抄成草稿；离开时提交并回到派生显示。
                    // 失焦也要提交——用户点回滑块就走了，不会专门按回车。
                    if isFocused { draft = "\(percent)" } else { commit() }
                }
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary.opacity(focused ? 0.9 : 0.45))
        )
        .accessibilityLabel("\(label)百分比")
        .accessibilityValue("\(percent)%")
    }

    private func commit() {
        defer { draft = nil }            // 无论如何都回到派生显示
        guard let draft else { return }
        // 容忍用户连 % 一起打、或者打了空格
        let cleaned = draft.filter { $0.isNumber || $0 == "." }
        guard let typed = Double(cleaned) else { return }   // 不是数字就当没改
        value = min(max(typed / 100, range.lowerBound), range.upperBound)
    }
}
