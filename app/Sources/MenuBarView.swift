import SwiftUI
import ServiceManagement

/// 菜单栏面板。
///
/// **主界面只放会被日常调整的东西**，其余收进「高级」。判据不是「这个参数重要吗」，
/// 而是「普通用户改它会不会更好」：
///
///   - 「最暗 / 最亮」拆成两个滑块是引擎的实现细节。用户的心智是「多亮」，
///     不是「下限多少上限多少」。主界面只给亮度（= 峰值），下限进高级。
///   - 「周期 4.0 秒」是工程师语言。主界面给「快慢」，方向翻转成右＝快。
///   - 「省电模式」的观感代价实测很小，但它声称的收益（能耗）**从未实测**。
///     一个收益未经证实的开关不值得占主界面的位置。
///   - 「空闲时停止」在 DESIGN.md §3.3 里是**硬需求不是优化**，代码注释写着
///     「不建议关闭」。不建议关闭的开关摆在主界面只会诱导用户去关，
///     然后撞上那个特意用结构消除掉的能耗风险。保留开关，但收进高级。
///   - 「灵敏度」留在主界面：实测证明不同曲风的最佳值不同，而且它直接决定
///     音乐律动看起来对不对——这是唯一一个「不调就可能觉得坏了」的参数。

struct MenuBarView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var engine: Engine
    @ObservedObject var updates: UpdateChecker

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// 超过这个高度才开始滚动。**必须按当前屏幕真实可用高度算，不能拍脑袋写死。**
    /// 上一版写死 620，比展开「高级」后的实际内容还矮（音乐律动 717pt），
    /// 于是面板一展开就进滚动态，头尾两头被滚出视野——正是要避免的那个问题。
    /// 实测各效果展开后 457…717pt，而 visibleFrame 通常有 800…1050pt，够放。
    private var maxHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
    }

    var body: some View {
        // 面板高度跟着内容走：展开「高级」会多出四五行，写死高度的话
        // 多出来的部分会被直接挤出视野（而且没有任何滚动提示）。
        //
        // 关键是 `fixedSize(vertical:)`：ScrollView 在滚动轴上默认是**贪心**的，
        // 给多少占多少；套上它之后改为向内容提议 nil，于是取内容的理想高度，
        // 内容不足时不会在底部留一大片空白。外层 maxHeight 负责封顶，
        // 超限时 ScrollView 恢复本职开始滚动。
        //
        // ⚠️ 不要改回「用 GeometryReader 量内容高度再反过来设自己的 frame」——
        // 那是循环依赖：初始高度 0 → 面板 1pt → 量出来还是 0，
        // 面板永远停在 1pt（NSPopover 探针实测，展开与否都不动）。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if engine.available {
                    Divider()
                    effectPicker
                    brightnessSlider
                    if settings.kind != .staticLevel { speedSlider }
                    if settings.kind == .audioBeat { sensitivitySlider }
                    Divider()
                    basicOptions
                    advanced
                } else {
                    unsupportedNotice
                }

                Divider()
                footer
            }
            .padding(16)
        }
        .frame(width: 360)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MagicKey").font(.headline)
                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(engine.isRunning ? .green : .secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!engine.available)
        }
    }

    private var effectPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("效果").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.kind) {
                ForEach(EffectKind.allCases) { k in
                    Label(k.displayName, systemImage: k.symbol).tag(k)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // 先说清楚做不到什么，免得用户以为是 bug
            if let note = settings.kind.note {
                Text(note)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 基础参数

    /// 亮度 = 效果的峰值（`hi`）。对常亮就是恒定亮度，对脉冲就是冲亮到哪。
    private var brightnessSlider: some View {
        labeled("亮度", String(format: "%.0f%%", settings.hi * 100)) {
            Slider(value: $settings.hi, in: 0.05...1)
        }
    }

    /// 快慢：归一化速度，右＝快。见 `Settings.speed`——各效果周期区间不同，
    /// 归一化之后同一个滑块位置在不同效果下含义一致。
    private var speedSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("快慢").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { settings.speed },
                                  set: { settings.speed = $0 }), in: 0...1)
            HStack {
                Text("慢").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("快").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 灵敏度：滑块往右＝更灵敏，和内部阈值方向相反，所以显示上做了翻转。
    /// 用户想的是「更灵敏」，不该让他去理解「阈值倍数越小越灵敏」。
    private var sensitivitySlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("灵敏度").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { 3.1 - settings.sensitivity },        // 1.1…2.0 → 2.0…1.1
                set: { settings.sensitivity = 3.1 - $0 }
            ), in: 1.1...2.0)
            Text("放着音乐拖动，找到跟得上又不乱闪的位置")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var basicOptions: some View {
        Toggle("开机自动启动", isOn: Binding(
            get: { launchAtLogin },
            set: { toggleLaunchAtLogin($0) }
        ))
        .toggleStyle(.checkbox)
    }

    // MARK: - 高级

    /// 不用 `DisclosureGroup`：它自带的展开动画会让**布局**在几帧里滑动，
    /// 而面板窗口是一帧之内直接 snap 到最终高度的（探针实测 473→717，中间无过渡帧，
    /// 窗口上沿始终不动）。两者错开一拍，看起来就是「所有内容跳一下」。
    ///
    /// 所以这里自己搭：布局与窗口同一帧到位，只让新出现的内容**淡入**——
    /// opacity 不参与布局，animate 它不会再制造中间态。箭头用旋转，同理。
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { settings.showAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(settings.showAdvanced ? 90 : 0))
                    Text("高级").font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())      // 整行可点，不只是文字
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if settings.showAdvanced { advancedBody.transition(.opacity) }
        }
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
                if settings.kind != .staticLevel {
                    labeled(settings.kind.levelLabels.lo,
                            String(format: "%.0f%%", settings.lo * 100)) {
                        Slider(value: $settings.lo, in: 0...0.95)
                    }
                    // 低端观感靠抬高下限，不靠堆帧率——
                    // 实测 --min 0.15@60fps 优于 --min 0.05@120fps。
                    Text("调高可改善低亮度段的观感，比提高帧率有效")
                        .font(.caption2).foregroundStyle(.tertiary)

                    labeled(settings.kind.periodLabel,
                            String(format: "%.2f s", settings.period)) {
                        Slider(value: $settings.period, in: settings.kind.periodRange)
                    }
                }

                Toggle(isOn: $settings.powerSaver) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("省电模式")
                        Text("30fps。观感差异很小，但省下的电从未实测")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.stopWhenIdle) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("空闲时停止")
                        Text("锁屏、息屏、\(Int(settings.idleSeconds)) 秒无操作且没有音频在放。不建议关闭")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.autoCheckUpdates) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("自动检查更新")
                        Text("这是本应用唯一的网络请求：一个不含任何标识的 GET，关掉后完全不联网")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        .toggleStyle(.checkbox)
        .padding(.top, 8)
    }

    // MARK: -

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("键盘背光不可用", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("未能通过 CoreBrightness 找到内置键盘背光。可能是当前 macOS 版本改动了私有接口，或本机没有背光键盘。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.orange)
            }
            updateRow
            HStack {
                Text("v\(updates.current)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// 更新状态。**失败原因如实显示**，不缩成一句「检查失败」——
    /// 目前最常见的失败是仓库还是 Private（releases API 未授权返回 404），
    /// 那不是网络问题，让人对着「检查失败」去查网络是浪费别人时间。
    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: 6) {
            switch updates.state {
            case .idle:
                Button("检查更新") { updates.check(manual: true) }
                    .buttonStyle(.borderless).font(.caption)
            case .checking:
                ProgressView().controlSize(.small)
                Text("检查中…").font(.caption2).foregroundStyle(.secondary)
            case .upToDate:
                Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.caption)
                Text("已是最新版本").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("重新检查") { updates.check(manual: true) }
                    .buttonStyle(.borderless).font(.caption2)
            case .available(let version, _):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue).font(.caption)
                Button("有新版本 \(version)，前往下载") { updates.openReleasesPage() }
                    .buttonStyle(.borderless).font(.caption)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                Text(why).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("重试") { updates.check(manual: true) }
                    .buttonStyle(.borderless).font(.caption2)
            }
        }
    }

    private func labeled<C: View>(_ title: String, _ value: String,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            loginError = nil
        } catch {
            // 未签名或未放进 /Applications 时会失败，这不是 bug，如实告知即可
            loginError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
