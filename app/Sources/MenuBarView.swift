import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var engine: Engine

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if engine.available {
                Divider()
                effectPicker
                if settings.kind != .staticLevel { periodSlider }
                if settings.kind == .audioBeat { sensitivitySlider }
                brightnessSliders
                Divider()
                options
            } else {
                unsupportedNotice
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)     // 6 个分段；330 时最后一格会被截断
    }

    // MARK: -

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

            if settings.kind == .audioBeat {
                // 同样先说清楚做不到什么：律动是整块键盘一起亮，没有频谱条
                Text("整块键盘跟着音乐的鼓点闪。需要「系统录音」权限（不是麦克风）。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.kind == .keyPulse {
                // 先说清楚做不到什么，免得用户以为是 bug：
                // 内置键盘只有一路全局 PWM，没有单键或分区控制。
                Text("每次敲键整块键盘闪一下。硬件只有一路全局背光，无法从单个按键扩散。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var periodSlider: some View {
        labeled(settings.kind.periodLabel, String(format: "%.2f s", settings.period)) {
            Slider(value: $settings.period, in: settings.kind.periodRange)
        }
    }

    /// 灵敏度：滑块往右＝更灵敏，和内部阈值方向相反，所以显示上做了翻转。
    /// 用户想的是「更灵敏」，不该让他去理解「阈值倍数越小越灵敏」。
    private var sensitivitySlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("灵敏度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f×", settings.sensitivity))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { 3.1 - settings.sensitivity },        // 1.1…2.0 → 2.0…1.1
                set: { settings.sensitivity = 3.1 - $0 }
            ), in: 1.1...2.0)
            Text("放着音乐拖动，找到跟得上又不乱闪的位置")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var brightnessSliders: some View {
        let labels = settings.kind.levelLabels
        return VStack(alignment: .leading, spacing: 10) {
            labeled(labels.lo, String(format: "%.0f%%", settings.lo * 100)) {
                Slider(value: $settings.lo, in: 0...0.95)
            }
            labeled(labels.hi, String(format: "%.0f%%", settings.hi * 100)) {
                Slider(value: $settings.hi, in: 0.05...1)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.powerSaver) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("省电模式")
                    Text("30fps，观感差异很小").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $settings.stopWhenIdle) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("空闲时停止")
                    Text("锁屏、息屏或 \(Int(settings.idleSeconds)) 秒无操作")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Toggle("开机自动启动", isOn: Binding(
                get: { launchAtLogin },
                set: { toggleLaunchAtLogin($0) }
            ))

            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.orange)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("键盘背光不可用", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("未能通过 CoreBrightness 找到内置键盘背光。可能是当前 macOS 版本改动了私有接口，或本机没有背光键盘。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("v0.1").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }

    // MARK: -

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
