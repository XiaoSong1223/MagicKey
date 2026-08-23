import Foundation
import AVFoundation

/// 试听用的轻量播放器。
///
/// **刻意不复用正在跑的 `KeySoundPlayer`。** 那一个有自己的生命周期
/// （空闲 30 秒暂停引擎、按敲击顺延定时器），借它来试听会把那套状态搅乱：
/// 用户在键盘图里点几下试听，正在打字的那条链的空闲计时就被无声地重置了。
/// 而且试听要在**功能关着、甚至没授权**的时候也能用——指键是纯配置，
/// 不该等到拿了「输入监控」权限才让人听得到自己导入的是什么声音。
///
/// 播放本身不需要任何 TCC 授权（那是采集才要的），所以这一层没有降级路径。
@MainActor
final class SoundPreviewPlayer {

    static let shared = SoundPreviewPlayer()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    /// 解码结果按文件名缓存。试听是「点一下听一下、再点一下再听」的用法，
    /// 每次重解码会让第二次之后的点击明显慢半拍（一条 2 秒的 wav 约 15ms）。
    private var cache: [String: AVAudioPCMBuffer] = [:]

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: KeySoundPlayer.format)
    }

    /// 试听一条采样。`gain` 传音色库里存的那个对齐系数——
    /// 试听要和真正敲下去时**一样响**，否则用户是照着一个错的音量在挑音色。
    func play(url: URL, gain: Float) {
        let key = url.lastPathComponent
        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else {
            // 走和播放层完全相同的解码 + 增益路径（`by: 1.0` 即不变调），
            // 这样试听到的就是之后真会听到的那一条，不是「差不多的那一条」。
            guard let source = LoadedKeySoundPack.decode(url),
                  let prepared = LoadedKeySoundPack.resample(source, by: 1.0, gain: gain,
                                                             to: KeySoundPlayer.format) else {
                Log.write("[keysound] 试听失败，采样读不出来：\(key)")
                return
            }
            cache[key] = prepared
            buffer = prepared
        }

        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                Log.write("[keysound] 试听引擎启动失败：\(error.localizedDescription)")
                return
            }
        }
        // 和 `KeySoundPlayer.start` 同一个道理：节点必须先 stop 再 play。
        // `engine.stop()` 会作废渲染状态而 `isPlaying` 仍留在 true，
        // 按 `!isPlaying` 跳过补 play() 的话，此后排什么都无声。
        node.stop()
        node.play()
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// 一条音色被删掉时把它的缓存也丢掉——文件都没了，留着只会占内存
    func forget(fileName: String) {
        cache.removeValue(forKey: fileName)
    }

    /// 键盘图窗口关掉时调。别让 CoreAudio 的 IO 线程在没人听的时候空转。
    func stop() {
        guard engine.isRunning else { return }
        node.stop()
        engine.stop()
    }
}
