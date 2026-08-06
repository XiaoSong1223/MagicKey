import Foundation
import Combine

enum EffectKind: String, CaseIterable, Identifiable {
    case staticLevel = "static"
    case breathe
    case heartbeat
    case strobe
    case keyPulse = "keypulse"
    case audioBeat = "audiobeat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .staticLevel: return "常亮"
        case .breathe:     return "呼吸"
        case .heartbeat:   return "心跳"
        case .strobe:      return "频闪"
        case .keyPulse:    return "按键"
        case .audioBeat:   return "音乐"
        }
    }

    var symbol: String {
        switch self {
        case .staticLevel: return "sun.max"
        case .breathe:     return "wave.3.right"
        case .heartbeat:   return "heart"
        case .strobe:      return "bolt"
        case .keyPulse:    return "hand.tap"
        case .audioBeat:   return "waveform"
        }
    }

    /// 各效果合适的周期范围与默认值（秒）
    var periodRange: ClosedRange<Double> {
        switch self {
        case .staticLevel: return 1...1
        case .breathe:     return 1...20
        case .heartbeat:   return 0.6...3
        case .strobe:      return 0.1...2
        case .keyPulse:    return 0.15...1.5
        case .audioBeat:   return 0.15...1.5
        }
    }

    var defaultPeriod: Double {
        switch self {
        case .staticLevel: return 1
        case .breathe:     return 4
        case .heartbeat:   return 1.2
        case .strobe:      return 0.5
        case .keyPulse:    return 0.4
        case .audioBeat:   return 0.35
        }
    }

    /// 按键脉冲不循环，「周期」这个词对它是错的
    var periodLabel: String {
        self == .keyPulse || self == .audioBeat ? "脉冲时长" : "周期"
    }

    /// 最暗/最亮两个滑块在按键脉冲下的含义是「静息」和「峰值」
    var levelLabels: (lo: String, hi: String) {
        self == .keyPulse || self == .audioBeat ? ("静息亮度", "脉冲峰值") : ("最暗", "最亮")
    }
}

/// 用 UserDefaults 持久化。每个属性 didSet 即写盘——设置项少，不需要批量提交。
final class Settings: ObservableObject {

    private static let d = UserDefaults.standard

    private static func double(_ key: String, _ fallback: Double) -> Double {
        d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    @Published var enabled: Bool = Settings.bool("enabled", false) {
        didSet { Self.d.set(enabled, forKey: "enabled") }
    }

    @Published var kind: EffectKind = EffectKind(rawValue: d.string(forKey: "kind") ?? "") ?? .breathe {
        didSet {
            Self.d.set(kind.rawValue, forKey: "kind")
            // 换效果时把周期拉回该效果的合理区间
            if !kind.periodRange.contains(period) { period = kind.defaultPeriod }
        }
    }

    @Published var period: Double = Settings.double("period", 4.0) {
        didSet { Self.d.set(period, forKey: "period") }
    }

    @Published var lo: Double = Settings.double("lo", 0.05) {
        didSet {
            Self.d.set(lo, forKey: "lo")
            if lo > hi - 0.05 { hi = Swift.min(1.0, lo + 0.05) }
        }
    }

    @Published var hi: Double = Settings.double("hi", 0.85) {
        didSet {
            Self.d.set(hi, forKey: "hi")
            if hi < lo + 0.05 { lo = Swift.max(0.0, hi - 0.05) }
        }
    }

    /// 省电模式：30fps。实测最大相对步进从 7.7% 劣化到 12.5%，观感可接受。
    @Published var powerSaver: Bool = Settings.bool("powerSaver", false) {
        didSet { Self.d.set(powerSaver, forKey: "powerSaver") }
    }

    /// 「空闲即停」是硬需求而非优化——见 DESIGN.md §3.3。
    /// 默认开启，且不建议关闭：60Hz 唤醒会阻止 SoC 进入深度空闲。
    @Published var stopWhenIdle: Bool = Settings.bool("stopWhenIdle", true) {
        didSet { Self.d.set(stopWhenIdle, forKey: "stopWhenIdle") }
    }

    @Published var idleSeconds: Double = Settings.double("idleSeconds", 120) {
        didSet { Self.d.set(idleSeconds, forKey: "idleSeconds") }
    }

    /// 音乐律动的触发灵敏度（`OnsetDetector` 的阈值倍数）。小 = 灵敏 = 闪得密。
    ///
    /// 直接推给已经在跑的检测器，**不重建效果、不重建 tap**——
    /// tap 建立要 1.8–4.6 秒，拖滑块时重建等于卡死。
    @Published var sensitivity: Double = Settings.double("sensitivity", 1.35) {
        didSet {
            Self.d.set(sensitivity, forKey: "sensitivity")
            BeatPulseSource.shared.sensitivity = Float(sensitivity)
        }
    }

    var fps: Double { powerSaver ? 30 : 60 }

    func makeEffect() -> Effect {
        switch kind {
        case .staticLevel: return StaticEffect(level: Float(hi))
        case .breathe:     return BreatheEffect(period: period, min: Float(lo), max: Float(hi))
        case .heartbeat:   return HeartbeatEffect(period: period, min: Float(lo), max: Float(hi))
        case .strobe:      return StrobeEffect(period: period, min: Float(lo), max: Float(hi))
        case .keyPulse:    return PulseEffect(duration: period, min: Float(lo), max: Float(hi),
                                             source: KeyboardPulseSource(), name: "keypulse")
        case .audioBeat:
            // tap 的启停不在这里做生命周期管理：它比效果活得久（重建要几秒），
            // 停止由「没人 drain 就自停」的看门狗负责。见 BeatPulseSource 类注释。
            let src = BeatPulseSource.shared
            src.sensitivity = Float(sensitivity)
            src.activate()
            // ⚠️ filterRepeats 必须为 false：`KeyRepeatFilter` 的判据是
            // 「连续两个间隔几乎相等 = 自动重复」，而音乐的鼓点**本来就是等间隔**。
            // 开着的话一首 120BPM 的歌前三拍之后就再也不闪了。
            return PulseEffect(duration: period, min: Float(lo), max: Float(hi),
                               source: src, filterRepeats: false, name: "audiobeat")
        }
    }
}
