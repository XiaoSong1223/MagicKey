import Foundation
import AVFoundation

/// 一次敲击该播哪一条采样。
///
/// **只分四类，不做逐键映射。** 真实键盘上不同键的音色差别来自**键帽尺寸和
/// 稳定器**（空格、回车、退格有大键位的卫星轴，声音明显不同），而不是来自
/// 「这个键是 J 还是 K」。逐键配音要几十个文件，换来的差别听不出来。
///
/// 修饰键走 `generic`：它们在上游包里没有专属录音，而听感上确实接近普通键。
enum KeySoundSlot: Hashable, CaseIterable {
    case space, enter, backspace, generic

    /// macOS 虚拟键码 → 槽位。键码取自 `Carbon` 的 `kVK_*`，
    /// 这里直接写字面量，免得为四个常量把 Carbon 拖进来。
    init(keyCode: UInt16) {
        switch keyCode {
        case 49:        self = .space          // kVK_Space
        case 36, 76:    self = .enter          // Return / 小键盘 Enter
        case 51, 117:   self = .backspace      // Delete（退格）/ ForwardDelete
        default:        self = .generic
        }
    }

    /// 上游文件名（不含扩展名）。按下有五个通用采样，抬起只有一个——
    /// 这是上游的录音就这样，抬起音之间的差别本来也小。
    var pressFileNames: [String] {
        switch self {
        case .space:     return ["SPACE"]
        case .enter:     return ["ENTER"]
        case .backspace: return ["BACKSPACE"]
        case .generic:   return (0...4).map { "GENERIC_R\($0)" }
        }
    }

    var releaseFileNames: [String] {
        switch self {
        case .space:     return ["SPACE"]
        case .enter:     return ["ENTER"]
        case .backspace: return ["BACKSPACE"]
        case .generic:   return ["GENERIC"]
        }
    }
}

/// 一套音色包的元数据。**采样和许可证信息绑在一起**，不是分头维护的两张表——
/// 加包时漏写来源就编译不过。完整的来源说明见 `Resources/Sounds/CREDITS.md`。
struct KeySoundPack: Identifiable, Hashable {

    /// 同时是 `Resources/Sounds/` 下的目录名和存进 UserDefaults 的值
    let id: String
    /// 面板里显示的名字。括号里保留轴体名——认得轴的人一眼知道是什么声，
    /// 不认得的人靠前面两个字也能选
    let displayName: String
    /// 响度对齐系数。三套包的原始 RMS 差了 3.5dB，不对齐的话换包等于换音量，
    /// 用户会以为音量滑块坏了。取值 = 10^((目标 −33.6dBFS − 本包 RMS)/20)，
    /// 目标取三者里最响的那个，这样只放大不衰减、也不会削顶
    /// （对齐后峰值最高 0.50，仍有 6dB 余量）
    let gain: Float
    /// 来源与许可证。**不许留空**
    let credit: String

    static let all: [KeySoundPack] = [
        KeySoundPack(id: "boxnavy",   displayName: "清脆（Box Navy）",  gain: 1.50,
                     credit: "kbsim (github.com/tplai/kbsim) · MIT · Thomas Lai"),
        KeySoundPack(id: "holypanda", displayName: "厚实（Holy Panda）", gain: 1.00,
                     credit: "kbsim (github.com/tplai/kbsim) · MIT · Thomas Lai"),
        KeySoundPack(id: "mxbrown",   displayName: "轻柔（MX Brown）",  gain: 1.32,
                     credit: "kbsim (github.com/tplai/kbsim) · MIT · Thomas Lai"),
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> KeySoundPack {
        all.first { $0.id == id } ?? fallback
    }
}

/// 解码好、格式对齐好、音高变体也备好的一套采样。
///
/// **全部在加载时算完，播放路径上不做任何 DSP。** 一次敲击到出声之间只剩
/// 「取一个已经躺在内存里的 buffer 交给 `scheduleBuffer`」，实测这一步 <0.03ms。
/// 每套包解码后约 1.1MB，三套也不到 4MB，而且只有当前选中的那套会驻留。
final class LoadedKeySoundPack {

    let id: String

    /// [槽位: 该槽位的全部候选 buffer]。候选 = 上游采样数 × 音高变体数
    private var press: [KeySoundSlot: [AVAudioPCMBuffer]] = [:]
    private var release: [KeySoundSlot: [AVAudioPCMBuffer]] = [:]

    /// 音高变体。**这不是为了好听，是为了不难听**——上游的抬起音每个槽位
    /// 只有一条录音，原样循环播放连打时会明显听出是同一个采样在重复
    /// （即所谓「机关枪效应」）。±3% 约合三分之一个半音，单独听察觉不到，
    /// 连打时足以打散那种规律感。
    ///
    /// 做成**预渲染**而不是播放时变调：变调要在图里给每一路插一个
    /// `AVAudioUnitVarispeed`，12 路就是 12 个常驻 AudioUnit 在做重采样；
    /// 预渲染把这笔开销一次性挪到加载时，播放图退回最简单的 player → mixer。
    private static let pitchRatios: [Double] = [0.97, 1.0, 1.03]

    /// - Parameter format: 公共处理格式。所有 buffer 都转到这个格式，
    ///   于是播放节点和 mixer 之间只有一种连接格式，切换音色包不用重建图。
    init?(pack: KeySoundPack, format: AVAudioFormat) {
        self.id = pack.id
        guard let root = Self.soundsRoot?
            .appendingPathComponent(pack.id, isDirectory: true) else { return nil }

        for slot in KeySoundSlot.allCases {
            press[slot] = Self.load(slot.pressFileNames, from: root.appendingPathComponent("press"),
                                    gain: pack.gain, format: format)
            release[slot] = Self.load(slot.releaseFileNames, from: root.appendingPathComponent("release"),
                                      gain: pack.gain, format: format)
        }

        // 通用槽位是**每次敲键**都要用的，它空了整套包就等于哑的。
        // 空格/回车/退格缺了还能退回通用（见 `buffers`），所以只在这里拦。
        guard let g = press[.generic], !g.isEmpty else {
            Log.write("[keysound] 音色包「\(pack.id)」没有可用的通用采样，加载失败")
            return nil
        }
        let total = press.values.reduce(0) { $0 + $1.count }
                  + release.values.reduce(0) { $0 + $1.count }
        Log.write("[keysound] 音色包「\(pack.id)」已载入 \(total) 条 buffer"
                  + "（含 \(Self.pitchRatios.count) 档音高变体）")
    }

    /// 某个槽位的候选。空格/回车/退格缺采样时**退回通用**——
    /// 宁可音色不对也不能有的键有声有的键没声，那种「漏音」听起来就是坏了。
    func buffers(_ slot: KeySoundSlot, isDown: Bool) -> [AVAudioPCMBuffer] {
        let table = isDown ? press : release
        if let b = table[slot], !b.isEmpty { return b }
        return table[.generic] ?? []
    }

    // MARK: - 加载

    /// 采样目录。正式构建就是 `MagicKey.app/Contents/Resources/Sounds`。
    private static var soundsRoot: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        #if UI_PROBE
        // 探针是**裸可执行文件**（见 Makefile 里 PROBE_BIN 的注释），没有 bundle，
        // `Bundle.main.resourceURL` 指向的是可执行文件自己所在的目录 `app/`。
        // 补一条源码树里的路径，好让探针能走完真正的加载与播放路径，
        // 而不是在「音色包加载失败」上打住——那样这条链就没被测到。
        let inTree = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Resources/Sounds", isDirectory: true)
        if FileManager.default.fileExists(atPath: inTree.path) { return inTree }
        #endif
        return nil
    }

    private static func load(_ names: [String], from dir: URL,
                             gain: Float, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        for name in names {
            let url = dir.appendingPathComponent(name).appendingPathExtension("mp3")
            guard let source = decode(url) else { continue }
            for ratio in pitchRatios {
                if let b = resample(source, by: ratio, gain: gain, to: format) { out.append(b) }
            }
        }
        return out
    }

    private static func decode(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else {
            Log.write("[keysound] 采样读不出来：\(url.lastPathComponent)")
            return nil
        }
        return buf
    }

    /// 变调的做法：把源重采样到 `目标采样率 / ratio`，再**原样贴上目标采样率的标签**。
    /// 同一批样点按更高的采样率播出去就是放得更快、音更高——这正是加速磁带的原理，
    /// 也正是机械键盘上两个不同键之间真实存在的那种细微差别。
    ///
    /// 顺手在贴标签这一步把响度对齐系数乘进去，省一趟遍历。
    private static func resample(_ source: AVAudioPCMBuffer, by ratio: Double,
                                 gain: Float, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // ratio == 1 时不用绕这一圈，直接转到目标格式
        guard let work = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate / ratio,
                                       channels: format.channelCount),
              let converter = AVAudioConverter(from: source.format, to: work) else { return nil }

        let stretch = work.sampleRate / source.format.sampleRate
        // +1024 是重采样滤波器的尾巴，宁可多要一点也不要被截断
        let capacity = AVAudioFrameCount(Double(source.frameLength) * stretch) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: work, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, converted.frameLength > 0 else {
            Log.write("[keysound] 重采样失败：\(error?.localizedDescription ?? "未知")")
            return nil
        }

        // 贴标签：样点逐字照抄，只把 format 换成公共格式。两边都是
        // standard（Float32 非交错）且声道数相同，所以是逐声道的直拷。
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: converted.frameLength),
              let src = converted.floatChannelData, let dst = out.floatChannelData else { return nil }
        let frames = Int(converted.frameLength)
        for ch in 0..<Int(format.channelCount) {
            let s = src[ch], d = dst[ch]
            for i in 0..<frames { d[i] = s[i] * gain }
        }
        out.frameLength = converted.frameLength
        return out
    }
}
