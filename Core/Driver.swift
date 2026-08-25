import Foundation

// MARK: - CoreBrightness 私有接口声明
//
// 用 @objc protocol + 显式 selector 标注映射到私有类，无需桥接头或 .m 文件。
// 所有方法在使用前都会用 responds(to:) 逐个探测，缺失即降级。

@objc private protocol KeyboardBrightnessClientProtocol {
    @objc(copyKeyboardBacklightIDs)
    func copyKeyboardBacklightIDs() -> [NSNumber]

    @objc(isKeyboardBuiltIn:)
    func isKeyboardBuiltIn(_ kb: UInt64) -> Bool

    @objc(brightnessForKeyboard:)
    func brightness(forKeyboard kb: UInt64) -> Float

    @objc(setBrightness:forKeyboard:)
    func setBrightness(_ b: Float, forKeyboard kb: UInt64) -> Bool

    @objc(enableAutoBrightness:forKeyboard:)
    func enableAutoBrightness(_ enabled: Bool, forKeyboard kb: UInt64) -> Bool

    @objc(isAutoBrightnessEnabledForKeyboard:)
    func isAutoBrightnessEnabled(forKeyboard kb: UInt64) -> Bool

    @objc(isAmbientFeatureAvailableOnKeyboard:)
    func isAmbientFeatureAvailable(onKeyboard kb: UInt64) -> Bool

    @objc(idleDimTimeForKeyboard:)
    func idleDimTime(forKeyboard kb: UInt64) -> Double

    @objc(setIdleDimTime:forKeyboard:)
    func setIdleDimTime(_ t: Double, forKeyboard kb: UInt64) -> Bool

    @objc(suspendIdleDimming:forKeyboard:)
    func suspendIdleDimming(_ suspend: Bool, forKeyboard kb: UInt64) -> Bool
}

// MARK: - 驱动协议
//
// 引擎只认这个协议。私有 API 消失时替换成 NullDriver，应用照常启动。

protocol BacklightDriver: AnyObject {
    var isAvailable: Bool { get }
    var keyboardID: UInt64 { get }

    func readBrightness() -> Float
    @discardableResult func writeBrightness(_ value: Float) -> Bool

    func readAutoBrightness() -> Bool
    func writeAutoBrightness(_ enabled: Bool)

    func readIdleDimTime() -> Double
    func writeIdleDimTime(_ seconds: Double)
    func suspendIdleDimming(_ suspend: Bool)
}

final class NullDriver: BacklightDriver {
    var isAvailable: Bool { false }
    var keyboardID: UInt64 { 0 }
    func readBrightness() -> Float { 0 }
    func writeBrightness(_ value: Float) -> Bool { false }
    func readAutoBrightness() -> Bool { false }
    func writeAutoBrightness(_ enabled: Bool) {}
    func readIdleDimTime() -> Double { 0 }
    func writeIdleDimTime(_ seconds: Double) {}
    func suspendIdleDimming(_ suspend: Bool) {}
}

// MARK: - CoreBrightness 实现

final class CoreBrightnessDriver: BacklightDriver {

    private let client: KeyboardBrightnessClientProtocol
    private let raw: NSObject
    let keyboardID: UInt64
    var isAvailable: Bool { true }

    /// 上一次实际写入的 8bit 量化档位。-1 表示尚未写入。
    private var lastLevel: Int = -1

    // 统计。
    //
    // 这里以前还有一个 `writeLatencies: [Double]`，逐次追加、上限 30 万条
    // （约 2.4MB 常驻），而唯一的读取者 `latencyStats()` **全仓库零调用**——
    // 一个跑在发行版里、谁也看不到的缓冲。单次写入耗时早就实测定死了
    // （avg 0.09ms / p99 0.24ms，记在 DESIGN.md F3），不需要常驻采样。
    // 真要再量一次就照 `KeySoundPlayer` 那样滚动聚合（count/sum/max 攒一批打一行），
    // 常数内存，别再开数组。
    private(set) var writeCount: UInt64 = 0
    private(set) var skipCount: UInt64 = 0

    /// 返回 nil 表示当前系统上不可用（私有 API 变更或无内置键盘背光）。
    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_NOW) != nil else {
            Log.write("[driver] dlopen CoreBrightness 失败")
            return nil
        }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            Log.write("[driver] 找不到类 KeyboardBrightnessClient")
            return nil
        }

        let instance = cls.init()

        // 启动自检：所有要用的 selector 必须齐全，缺一即整体降级。
        let required: [Selector] = [
            NSSelectorFromString("copyKeyboardBacklightIDs"),
            NSSelectorFromString("isKeyboardBuiltIn:"),
            NSSelectorFromString("brightnessForKeyboard:"),
            NSSelectorFromString("setBrightness:forKeyboard:"),
            NSSelectorFromString("enableAutoBrightness:forKeyboard:"),
            NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:"),
            NSSelectorFromString("idleDimTimeForKeyboard:"),
            NSSelectorFromString("setIdleDimTime:forKeyboard:"),
            NSSelectorFromString("suspendIdleDimming:forKeyboard:"),
        ]
        for sel in required where !instance.responds(to: sel) {
            Log.write("[driver] 缺少 selector: \(NSStringFromSelector(sel))")
            return nil
        }

        // @objc protocol 的 existential 就是单个对象指针，这个 cast 是安全的。
        let proto = unsafeBitCast(instance, to: KeyboardBrightnessClientProtocol.self)

        let ids = proto.copyKeyboardBacklightIDs()
        guard let builtIn = ids.map({ $0.uint64Value }).first(where: { proto.isKeyboardBuiltIn($0) }) else {
            Log.write("[driver] 未找到内置键盘背光（IDs=\(ids)）")
            return nil
        }

        self.raw = instance
        self.client = proto
        self.keyboardID = builtIn
    }

    // MARK: 亮度

    func readBrightness() -> Float {
        client.brightness(forKeyboard: keyboardID)
    }

    /// 8bit 量化去重：硬件只有 0–255 档，同档重复写入是纯浪费（每次约 3.2ms XPC）。
    @discardableResult
    func writeBrightness(_ value: Float) -> Bool {
        let clamped = min(max(value, 0), 1)
        let level = Int((clamped * 255).rounded())
        guard level != lastLevel else {
            skipCount += 1
            return true
        }

        let ok = client.setBrightness(Float(level) / 255.0, forKeyboard: keyboardID)
        if ok { lastLevel = level }
        writeCount += 1
        return ok
    }

    /// 让下一次 writeBrightness 必定实际写入（外部改动后重新同步用）。
    func invalidateCache() { lastLevel = -1 }

    // MARK: 环境光与闲置调暗

    func readAutoBrightness() -> Bool {
        client.isAutoBrightnessEnabled(forKeyboard: keyboardID)
    }

    func writeAutoBrightness(_ enabled: Bool) {
        _ = client.enableAutoBrightness(enabled, forKeyboard: keyboardID)
    }

    func readIdleDimTime() -> Double {
        client.idleDimTime(forKeyboard: keyboardID)
    }

    func writeIdleDimTime(_ seconds: Double) {
        _ = client.setIdleDimTime(seconds, forKeyboard: keyboardID)
    }

    func suspendIdleDimming(_ suspend: Bool) {
        _ = client.suspendIdleDimming(suspend, forKeyboard: keyboardID)
    }

    var isAmbientAvailable: Bool {
        raw.responds(to: NSSelectorFromString("isAmbientFeatureAvailableOnKeyboard:"))
            ? client.isAmbientFeatureAvailable(onKeyboard: keyboardID) : false
    }
}
