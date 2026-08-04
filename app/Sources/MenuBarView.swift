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
        .frame(width: 300)
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
        }
    }

    private var periodSlider: some View {
        labeled("周期", String(format: "%.1f s", settings.period)) {
            Slider(value: $settings.period, in: settings.kind.periodRange)
        }
    }

    private var brightnessSliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("最暗", String(format: "%.0f%%", settings.lo * 100)) {
                Slider(value: $settings.lo, in: 0...0.95)
            }
            labeled("最亮", String(format: "%.0f%%", settings.hi * 100)) {
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
