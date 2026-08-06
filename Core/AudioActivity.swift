import Foundation
import CoreAudio

/// 「系统当前有没有声音在放」。
///
/// 两个地方要用，所以单独成文件：
///   - `IdleMonitor`：把「有音频输出」当成用户在场的信号（听歌时不碰键鼠是常态）
///   - `AudioTap`：tap 是被音频驱动的，没有声音就没有 IO 回调。
///     分不清「tap 坏了」和「没东西可 tap」会把调试带进沟里——
///     2026-08-06 的探针就在这上面浪费了四轮：一直盯着「回调 0 次」改聚合设备配方，
///     实际上全程没有任何音频在播放。
///
/// 零权限、零依赖：只是读默认输出设备的一个属性。
enum AudioActivity {

    /// 默认输出设备当前是否正被某个进程使用。
    ///
    /// 注意它问的是**当前默认输出设备**——用户从扬声器切到 AirPods 时会自动跟随，
    /// 不需要额外处理设备切换。
    static func outputIsRunning() -> Bool {
        guard let devID = defaultOutputDevice() else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    /// 默认输出设备的 AudioObjectID
    static func defaultOutputDevice() -> AudioObjectID? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devID) == noErr,
              devID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return devID
    }

    /// 默认输出设备的 UID，建聚合设备时要用
    static func defaultOutputUID() -> String? {
        guard let devID = defaultOutputDevice() else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (uid as String) : nil
    }
}
