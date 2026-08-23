import SwiftUI
import ServiceManagement

/// 设置窗口的内容：单页滚动，四个分组。
///
/// **为什么不是四个标签页。** 全部加起来只有十来个控件——拆成四页之后每页平均
/// 三个，点四次才看完一屏能装下的东西。分组标题已经把「四个区域」表达清楚了。
///
/// 放进来的判据是「**不需要一边看键盘一边调**」：
///   - 开机自启、省电、空闲策略、自动更新都是设一次就忘的全局开关
///   - 静息亮度和精确周期是逐效果的细节，日常调的是主面板上的「亮度」和「快慢」
struct SettingsView: View {

    @ObservedObject var settings: Settings
    @ObservedObject var updates: UpdateChecker

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            generalSection
            if settings.kind != .staticLevel { effectSection }
            keySoundSection
            updateSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 720)
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section("通用") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { toggleLaunchAtLogin($0) }
                ))
                .accessibilityValue(launchAtLogin ? "已开启" : "已关闭")

                // 错误就贴在触发它的控件下面。堆到窗口底部的话，
                // 用户点完开关看不到任何反应，只会以为是卡了。
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $settings.powerSaver) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("省电模式")
                    Text("以 30fps 渲染，观感差异很小")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("省电模式")
            .accessibilityValue(settings.powerSaver ? "已开启，30fps" : "已关闭，60fps")

            Toggle(isOn: $settings.stopWhenIdle) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("空闲时自动停止")
                    Text("锁屏、息屏、或长时间无操作且没有音频在播放时停止并还原键盘。不建议关闭")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel("空闲时自动停止")
            .accessibilityValue(settings.stopWhenIdle ? "已开启" : "已关闭")

            if settings.stopWhenIdle {
                Picker("无操作多久算空闲", selection: $settings.idleSeconds) {
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("2 分钟").tag(120.0)
                    Text("5 分钟").tag(300.0)
                    Text("10 分钟").tag(600.0)
                }
                .accessibilityLabel("无操作多久算空闲")
            }
        }
    }

    // MARK: - 效果

    /// 只显示**当前选中效果**的细节。列出全部六个效果的参数会让这一页
    /// 长出六倍，而其中五份没人在看。
    private var effectSection: some View {
        Section("效果 · \(settings.kind.displayName)") {
            paramRow(settings.kind.levelLabels.lo,
                     value: String(format: "%.0f%%", settings.lo * 100),
                     help: "调高可改善低亮度段的观感，比提高帧率有效",
                     binding: $settings.lo, in: 0...0.95)

            paramRow(settings.kind.periodLabel,
                     value: String(format: "%.2f s", settings.period),
                     help: "主面板上的「快慢」是同一个值的粗调",
                     binding: $settings.period, in: settings.kind.periodRange)

            // lo 和 hi 会互相推（相差不足 5% 时另一个被顶开），
            // 而 hi 的滑块在**另一个窗口**里。不说的话就是「我改了 A，B 自己变了」。
            Text("静息亮度太靠近主面板的「亮度」时，「亮度」会被自动抬高，两者至少相差 5%。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 键盘音效

    /// **只放音色。** 开关和音量是每天要碰的，留在主面板；音色是选一次就忘的，
    /// 放这里正好——判据和这一页其余分组一致，见类注释。
    private var keySoundSection: some View {
        Section("键盘音效") {
            Picker("音色", selection: $settings.keySoundPack) {
                ForEach(KeySoundPack.all) { pack in
                    Text(pack.displayName).tag(pack.id)
                }
            }
            .accessibilityLabel("键盘音效音色")
            .accessibilityValue(KeySoundPack.named(settings.keySoundPack).displayName)
            .help("三套都是真实机械键盘的录音，已做过响度对齐，换音色不会顺带换音量")

            VStack(alignment: .leading, spacing: 6) {
                // 开关不在这一页，不说的话用户会在这里找它
                Text("开关和音量在菜单栏面板里。首次开启需要授予「输入监控」权限，"
                     + "授权后要退出并重新打开 MagicKey 才生效。")
                Text("采样来自 kbsim（github.com/tplai/kbsim），MIT 许可，作者 Thomas Lai。"
                     + "完整说明见应用包内的 Sounds/CREDITS.md。")
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 更新

    private var updateSection: some View {
        Section("更新") {
            Toggle(isOn: $settings.autoCheckUpdates) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("自动检查更新")
                    Text("每天一次，向 GitHub 发一个不含任何标识的请求。关掉之后本应用完全不联网")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel("自动检查更新")
            .accessibilityValue(settings.autoCheckUpdates ? "已开启" : "已关闭")

            HStack {
                updateStateLabel
                Spacer()
                Button("立即检查") { updates.check(manual: true) }
                    .disabled(updates.state == .checking)
                    .help("立刻向 GitHub 查询最新版本")
            }
        }
    }

    /// 更新状态贴在「立即检查」旁边，不堆到窗口底部——
    /// 失败原因和触发它的按钮离得越近越好。
    @ViewBuilder
    private var updateStateLabel: some View {
        switch updates.state {
        case .idle:
            Text("当前 v\(updates.current)").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("检查中…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let version, _):
            Button {
                updates.openReleasesPage()
            } label: {
                Label("有新版本 \(version)，前往下载", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.link)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: updates.current)

            VStack(alignment: .leading, spacing: 6) {
                Text("MagicKey 给 MacBook 内置键盘背光加上动态效果。")
                Text("内置键盘的全部 LED 共用一路 PWM，只有一个全局亮度值——"
                     + "所以不能变色，也不能单键控制。这是硬件限制。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("亮度控制走 CoreBrightness 的私有接口，因此无法上架 Mac App Store。"
                     + "探测失败时会整体降级为「不受支持」，不会崩溃。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link("GitHub 仓库", destination:
                        URL(string: "https://github.com/XiaoSong1223/MagicKey")!)
                Text("MIT License").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: -

    /// 和主面板同一套契约：label / value / help 必填，无障碍标签漏不掉。
    private func paramRow(_ title: String,
                          value: String,
                          help: String,
                          binding: Binding<Double>,
                          in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .help(help)
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            loginError = nil
        } catch {
            // 未签名、或没放进 /Applications 时会失败。如实告知，别假装成功
            loginError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
