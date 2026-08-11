import Foundation
import Combine
import AppKit

/// 把 `BeatPulseSource` 的状态搬到主线程，给 SwiftUI 观察。
///
/// 这一层只做线程搬运，不加任何判断——状态怎么算的全在 `BeatPulseSource.refreshStatus()`，
/// 因为那里才拿得到 `AudioTap.diagnostics()`，而且那个调用**不能上主线程**
/// （`AudioActivity.outputIsRunning()` 首次约 80ms）。
@MainActor
final class AudioStatusModel: ObservableObject {

    @Published private(set) var status: AudioStatus = .inactive

    init() {
        // onStatusChange 在 BeatPulseSource 自己的队列上来，跳回主线程
        BeatPulseSource.shared.onStatusChange = { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        status = BeatPulseSource.shared.status
    }

    // MARK: - 展示

    /// 色点颜色。和 `Engine.Phase` 用同一套语义：绿=在工作，橙=要你处理，
    /// 灰=没在用/正常待机，红=坏了。
    var tint: Tint {
        switch status {
        case .active:                      return .good
        case .starting, .inactive:         return .neutral
        case .idleNoAudio:                 return .neutral
        case .needsPermission, .stalled:   return .warn
        case .unsupportedOS, .failed:      return .bad
        }
    }

    enum Tint { case good, neutral, warn, bad }

    /// 一句话。**「似乎」不是措辞客气，是如实**——未授权是从「建立超时」
    /// 推断出来的，macOS 没有公开 API 能查 `kTCCServiceAudioCapture`。
    var summary: String {
        switch status {
        case .inactive:        return "未启用"
        case .unsupportedOS:   return "需要 macOS 14.2 或更新版本"
        case .starting:        return "正在连接系统音频…"
        case .needsPermission: return "似乎未获得「系统录音」授权"
        case .failed(let why): return "音频采集未能启动：\(why)"
        case .idleNoAudio:     return "已就绪 · 当前没有音频在播放"
        case .stalled:         return "在放音频却收不到数据"
        case .active:          return "跟随中"
        }
    }

    /// 这一态要不要给个动作按钮，给什么
    var action: Action? {
        switch status {
        case .needsPermission: return .openSettings
        case .stalled, .failed: return .retry
        default:                return nil
        }
    }

    enum Action { case openSettings, retry }

    // MARK: - 动作

    /// 打开「系统设置 → 隐私与安全性 → 系统录音」。
    ///
    /// 锚点和 bundle id 都是从 macOS 26 的 `SecurityPrivacyExtension` 二进制里
    /// 直接取出来核对过的，不是抄来的：`Privacy_AudioCapture` 与
    /// `Privacy_Microphone` 是两个不同锚点——这正是本项目反复强调的那个区别。
    func openAudioCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:"
                      + "com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")
        // 打不开就退到系统设置本体，总好过什么都不发生
        if let url, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// 重新建立采集管线。`deactivate()` 之后下一帧 `makeEffect()` 会重新 `activate()`——
    /// 但用户可能正停在这个效果上不动，所以直接自己拉一把。
    func retry() {
        BeatPulseSource.shared.deactivate()
        BeatPulseSource.shared.activate()
    }

    /// 授权之后仍然不工作时要说的那句话。
    ///
    /// coreaudiod 会缓存**授权之前**的客户端状态，用户在系统设置里勾上之后
    /// 不重启它就不生效——而没有任何提示会告诉用户这件事，
    /// 他只会看到「我明明授权了还是不行」。实测确认过，见 CLAUDE.md。
    static let coreaudiodHint =
        "如果已经授权仍然不工作，需要在终端里跑一次 sudo killall coreaudiod —— "
        + "系统会缓存授权前的状态。"
}
