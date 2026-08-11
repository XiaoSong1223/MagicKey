import SwiftUI

/// 菜单栏面板。
///
/// **主界面只放会被日常调整的东西**，其余进设置窗口。判据不是「这个参数重要吗」，
/// 而是「普通用户改它会不会更好」：
///
///   - 「最暗 / 最亮」拆成两个滑块是引擎的实现细节。用户的心智是「多亮」，
///     所以主界面只给亮度（= 峰值），静息亮度进设置窗口。
///   - 「周期 4.0 秒」是工程师语言。主界面给「快慢」，方向翻转成右＝快；
///     要精确数值的人去设置窗口，两处绑同一个 `period`。
///   - 「灵敏度」留在主界面：实测证明不同曲风的最佳值不同，而且它直接决定
///     音乐律动看起来对不对——这是唯一一个「不调就可能觉得坏了」的参数。
///
/// 布局是 **Header / 可滚动中段 / Footer** 三段：开关和状态永远看得见，
/// 设置入口和退出永远够得着，只有参数区会滚。
struct MenuBarView: View {

    @ObservedObject var settings: Settings
    @ObservedObject var engine: Engine
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var audio: AudioStatusModel
    @ObservedObject var metrics: PanelMetrics

    /// 打开设置窗口。由 AppDelegate 注入，视图不认识窗口控制器。
    var openSettings: () -> Void = {}

    /// Header + Footer 实测占掉的高度，用来算中段还剩多少。
    ///
    /// 量它们是安全的：两者的高度和中段能滚多高**无关**，不构成回路。
    /// （构成回路的是「量整个面板再反过来设面板自己的 frame」，那条路实测会把
    /// 面板永远钉在 1pt，别再试。）动态字号下这两块会变高，所以不能写死常数。
    @State private var chromeHeight: CGFloat = 96

    private static let width: CGFloat = 360
    private static let padding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.padding)
                .padding(.vertical, 12)
                .measureHeight(into: $chromeHeight, slot: .header)

            Divider()

            // 中段：内容不足时按内容高（底部不留空白），超了才滚。
            //
            // `.fixedSize` 必须在**最外层**：它向内提议 nil 高度，ScrollView
            // 于是返回内容理想高，再由 frame 封顶。反过来写（fixedSize 在里层）
            // ScrollView 会按理想高渲染然后被裁掉，不会滚。
            ScrollView {
                middle.padding(Self.padding)
            }
            .frame(maxHeight: max(140, metrics.maxHeight - chromeHeight))
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            footer
                .padding(.horizontal, Self.padding)
                .padding(.vertical, 10)
                .measureHeight(into: $chromeHeight, slot: .footer)
        }
        .frame(width: Self.width)
        // 兜底：chromeHeight 首帧还没量到时中段可能要多一点，
        // 这一层保证整个面板任何时候都不会超出屏幕。
        .frame(maxHeight: metrics.maxHeight)
        // ⚠️ 这一行**必须在最外层**，删了面板就只涨不缩。
        //
        // `frame(maxHeight:)` 的语义是「接受父级提议，钳到上限」。而
        // NSHostingController 提议的正是**窗口当前尺寸**——于是切到更矮的效果时，
        // 视图照旧报告旧高度，popover 没有理由缩小。探针实测：内容 312pt→197pt，
        // 面板纹丝不动停在 402pt。
        //
        // `fixedSize(vertical:)` 把提议改成 nil，强制取内容理想高，回路就断了。
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    /// 紧凑状态头：键帽图标、名字、一句人能看懂的状态、总开关。
    /// **不显示 fps**——那是给日志看的，用户不需要知道渲染帧率。
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("MagicKey").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 6, height: 6)
                    Text(phaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: $settings.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!engine.available)
                .accessibilityLabel("MagicKey 总开关")
                .accessibilityValue(settings.enabled ? "已开启" : "已关闭")
                .help(settings.enabled ? "关闭键盘背光动效" : "开启键盘背光动效")
        }
        // 整个 Header 作为一个无障碍单元朗读，而不是三段碎片
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MagicKey，\(phaseText)")
    }

    /// 绿=在跑，橙=自动暂停（总开关仍开着，条件恢复会自动继续），
    /// 灰=用户关掉了，红=硬件/系统不支持。
    private var phaseColor: Color {
        switch engine.phase {
        case .running:     return .green
        case .paused:      return .orange
        case .stopped:     return .secondary
        case .unsupported: return .red
        }
    }

    private var phaseText: String {
        switch engine.phase {
        case .running:          return "运行中 · \(settings.kind.displayName)"
        case .paused(let why):  return "已暂停 · \(why)"
        case .stopped:          return "已关闭"
        case .unsupported:      return "不受支持"
        }
    }

    // MARK: - 中段

    @ViewBuilder
    private var middle: some View {
        if engine.available {
            VStack(alignment: .leading, spacing: 14) {
                EffectGrid(selection: $settings.kind)
                effectStatusRow
                brightnessRow
                if settings.kind != .staticLevel { speedRow }
                if settings.kind == .audioBeat { sensitivityRow }
            }
        } else {
            unsupportedNotice
        }
    }

    /// 效果网格下方的单一槽位。**动态状态优先于静态说明**——
    /// 音乐效果两者都有，但正在跑的时候「跟随中」比「需要授权」有用得多。
    @ViewBuilder
    private var effectStatusRow: some View {
        if settings.kind == .audioBeat {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(audioTint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                Text(audio.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                audioActionButton
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("音乐律动状态：\(audio.summary)")
        } else if let note = settings.kind.note {
            // 先说清楚做不到什么，免得硬件限制被当成 bug 报上来
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioTint: Color {
        switch audio.tint {
        case .good:    return .green
        case .warn:    return .orange
        case .bad:     return .red
        case .neutral: return .secondary
        }
    }

    @ViewBuilder
    private var audioActionButton: some View {
        switch audio.action {
        case .openSettings:
            Button("打开设置") { audio.openAudioCaptureSettings() }
                .buttonStyle(.link).font(.caption)
                .help(AudioStatusModel.coreaudiodHint)
        case .retry:
            Button("重试") { audio.retry() }
                .buttonStyle(.link).font(.caption)
                .help("拆掉音频采集管线重新建立一次")
        case nil:
            EmptyView()
        }
    }

    // MARK: - 参数

    private var brightnessRow: some View {
        paramRow("亮度",
                 value: percent(settings.hi),
                 help: "效果最亮时的键盘背光亮度",
                 binding: $settings.hi, in: 0.05...1)
    }

    /// 归一化速度，右＝快。见 `Settings.speed`——各效果周期区间不同，
    /// 归一化之后同一个滑块位置在不同效果下含义一致。
    private var speedRow: some View {
        paramRow("快慢",
                 value: speedLabel,
                 help: "\(settings.kind.periodLabel) \(String(format: "%.2f", settings.period)) 秒，向右更快",
                 binding: Binding(get: { settings.speed }, set: { settings.speed = $0 }),
                 in: 0...1)
    }

    /// 滑块往右＝更灵敏，和内部阈值方向相反，所以显示上做了翻转。
    /// 用户想的是「更灵敏」，不该让他去理解「阈值倍数越小越灵敏」。
    private var sensitivityRow: some View {
        paramRow("灵敏度",
                 value: String(format: "%.2f", 3.1 - settings.sensitivity),
                 help: "放着音乐拖动，找到跟得上又不乱闪的位置",
                 binding: Binding(get: { 3.1 - settings.sensitivity },
                                  set: { settings.sensitivity = 3.1 - $0 }),
                 in: 1.1...2.0)
    }

    /// **面板里唯一的参数行构造方式。**
    ///
    /// `label` / `value` / `help` 三个都是必填参数——这就是无障碍标签
    /// 「漏不掉」的全部保证。不能靠事后检查：SwiftUI 的无障碍元素在进程内
    /// 根本查不到（实测，见 `UIProbe.accessibilityTree` 的注释），
    /// 所以只能靠「不给你一条不带标签的路」。加新参数时照着这个签名走。
    private func paramRow(_ title: String,
                          value: String,
                          help: String,
                          binding: Binding<Double>,
                          in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .help(help)
    }

    private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private var speedLabel: String {
        switch settings.speed {
        case ..<0.2:  return "很慢"
        case ..<0.4:  return "慢"
        case ..<0.6:  return "中"
        case ..<0.8:  return "快"
        default:      return "很快"
        }
    }

    // MARK: - 不支持

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("键盘背光不可用", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("未能通过 CoreBrightness 找到内置键盘背光。可能是当前 macOS 版本改动了私有接口，或本机没有背光键盘。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    /// 固定在底部：设置入口、版本与更新状态、退出。
    ///
    /// **退出必须留在这里。** 本应用是 LSUIElement，没有 Dock 图标；
    /// 虽然现在补上了 mainMenu 让 ⌘Q 能用，但那是不可见的，
    /// 不能当成普通用户唯一的退出方式。
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityLabel("打开设置")
            .help("开机启动、效果细节、更新与关于")

            Spacer(minLength: 6)
            updateStatus
            Spacer(minLength: 6)

            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.link).font(.caption)
                .accessibilityLabel("退出 MagicKey")
                .help("退出 MagicKey（⌘Q），键盘背光会还原到你原来的设置")
        }
    }

    /// 版本号兼作「检查更新」按钮。**失败原因如实显示**，不缩成一句「检查失败」——
    /// 让人对着「检查失败」去查网络是浪费别人时间。
    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle:
            Button("v\(updates.current)") { updates.check(manual: true) }
                .buttonStyle(.link).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("当前版本 \(updates.current)，点按检查更新")
                .help("检查更新")

        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("检查中…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityLabel("正在检查更新")

        case .upToDate:
            Button("v\(updates.current) 已是最新") { updates.check(manual: true) }
                .buttonStyle(.link).font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("已是最新版本 \(updates.current)，点按重新检查")
                .help("重新检查")

        case .available(let version, _):
            Button {
                updates.openReleasesPage()
            } label: {
                Label("新版本 \(version)", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityLabel("有新版本 \(version)，点按前往下载")
            .help("前往 GitHub Releases 下载")

        case .failed(let why):
            Button {
                updates.check(manual: true)
            } label: {
                Label("更新检查失败", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .foregroundStyle(.orange)
            .accessibilityLabel("更新检查失败：\(why)，点按重试")
            .help(why)          // 完整原因放在悬停提示里，不撑宽 Footer
        }
    }
}

// MARK: - 高度测量

private enum ChromeSlot { case header, footer }

private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: [ChromeSlot: CGFloat] = [:]
    static func reduce(value: inout [ChromeSlot: CGFloat],
                       nextValue: () -> [ChromeSlot: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// 量 Header / Footer 的高，合计写回 `total`。
    ///
    /// 只量这两块，**不量整个面板**——量整个面板再反过来设面板自己的 frame
    /// 是循环依赖，实测会把面板钉死在 1pt。这两块的高度不受中段影响，安全。
    func measureHeight(into total: Binding<CGFloat>, slot: ChromeSlot) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ChromeHeightKey.self,
                                       value: [slot: geo.size.height])
            }
        )
        .onPreferenceChange(ChromeHeightKey.self) { parts in
            // 两块都量到了才更新，避免只有一半时把上限算得过大
            guard parts.count == 2 else { return }
            let sum = parts.values.reduce(0, +) + 2      // 两条 Divider
            if abs(sum - total.wrappedValue) > 0.5 { total.wrappedValue = sum }
        }
    }
}
