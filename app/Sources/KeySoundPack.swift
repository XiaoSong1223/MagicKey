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
    /// 不认得的人靠前面两个字也能选。
    ///
    /// 轴体名不是凭印象写的，取自上游每个模块的 `caption`
    /// （`src/features/audioModules/*.js`）。核对是有意义的：`turquoise` 听起来
    /// 像个点击轴，上游写的却是 **Turquoise Tealios**，一个线性轴。
    let displayName: String
    /// 响度对齐系数。十二套包的原始 RMS 跨度 8.2dB，不对齐的话换包等于换音量，
    /// 用户会以为音量滑块坏了。取值 = `alignmentGain(rmsDBFS:peak:)`，
    /// 目标取全部包里最响的那个（bluealps −32.00dBFS），这样只放大不衰减。
    ///
    /// **整表在 2026-08-23 扩包时重算过一遍。** 目标随「最响的那个」变，
    /// 加包就可能把目标顶上去，于是全表都得跟着动——旧的三个数
    /// （1.50 / 1.00 / 1.32）是以 holypanda −33.6dBFS 为目标算的，已作废。
    /// 副作用是同一个音量滑块位置比 v1.0 整体响了约 1.6dB。
    let gain: Float
    /// 来源与许可证。**不许留空**
    let credit: String

    /// 响度对齐的目标（dBFS）。取**全部内置包里最响的那个**，
    /// 于是那张表里的 gain 恒 ≥ 1.0：内置采样只放大不衰减，
    /// 衰减等于白白丢掉本来就不多的动态。（用户导入的采样不受这条约束，
    /// 比目标响就得压下去——见 `alignmentGain`。）
    ///
    /// 自定义按键音导入时也对齐到这个值（见 `CustomSoundStore.gainFor`），
    /// 否则用户自己的采样和内置包一比不是太响就是太轻。**必须共用同一个常量**，
    /// 分头写两份的话改了一边忘了另一边，表现是「自定义音比内置的响一截」。
    static let loudnessTargetDBFS: Float = -32.00

    /// 对齐后允许的峰值上限。留 0.9 而不是 1.0 是因为后面还有两道放大：
    /// ±3% 重采样的滤波器会有轻微过冲，播放时还要乘一次 ±2dB 的音量抖动
    /// （最高 ×1.259）。实测十二套包对齐后峰值最高 0.853（cream），都在线内。
    static let peakCeiling: Float = 0.9

    /// 响度对齐系数的唯一算法。上表的十二个数就是这么算出来的，
    /// 自定义按键音导入时也调它。
    ///
    /// ⚠️ **这里会衰减，不只是放大。** 内置包那张表恰好全部 ≥ 1.0，
    /// 是因为对齐目标取的是「全部包里最响的那个」，谁都不需要压——
    /// 那是那张表的性质，不是这个函数的规则。用户导入的采样可能比目标响得多
    /// （实测一段合成音是 −19.5 dBFS，比目标高 12.5dB），此时**必须压下去**，
    /// 否则「自己录的声音不会突然比内置的响一大截」这句话就是假的。
    /// 早先这里写了个 `max(1, …)`，正是把这一支堵死了。
    ///
    /// - Parameter peak: 对齐前的峰值。乘完之后顶到 `peakCeiling` 以上就把系数压回来——
    ///   宁可这一条采样轻一点，也不能削顶（削顶的破音听起来是「坏了」，不是「轻了」）。
    static func alignmentGain(rmsDBFS: Float, peak: Float) -> Float {
        guard rmsDBFS.isFinite, peak > 0 else { return 1 }
        let raw = pow(10, (loudnessTargetDBFS - rmsDBFS) / 20)
        return Swift.min(raw, peakCeiling / peak)
    }

    /// 按听感排序，从最有点击感排到最轻——**不是按目录名字母序**。
    /// 十二项的下拉列表要能一路扫下去大致知道自己在往哪个方向走，
    /// 字母序在这里等于随机序。
    ///
    /// gain 与下表的 RMS/峰值实测数据同源，完整表见 `Resources/Sounds/CREDITS.md`。
    ///
    /// | 目录 | RMS dBFS | 峰值 | gain | 峰值×gain |
    /// |---|---|---|---|---|
    /// | boxnavy   | −37.05 | 0.333 | 1.79 | 0.595 |
    /// | bluealps  | −32.00 | 0.422 | 1.00 | 0.422 |
    /// | buckling  | −38.46 | 0.150 | 2.10 | 0.315 |
    /// | holypanda | −33.56 | 0.333 | 1.20 | 0.398 |
    /// | topre     | −39.76 | 0.294 | 2.44 | 0.718 |
    /// | cream     | −35.89 | 0.545 | 1.56 | 0.853 |
    /// | blackink  | −37.37 | 0.349 | 1.85 | 0.647 |
    /// | mxblack   | −32.37 | 0.548 | 1.04 | 0.572 |
    /// | redink    | −34.93 | 0.415 | 1.40 | 0.581 |
    /// | turquoise | −37.11 | 0.283 | 1.80 | 0.510 |
    /// | mxbrown   | −35.98 | 0.301 | 1.58 | 0.475 |
    /// | alpaca    | −40.18 | 0.242 | 2.56 | 0.620 |
    static let all: [KeySoundPack] = [
        // —— 点击感 ——
        KeySoundPack(id: "boxnavy",   displayName: "清脆（Box Navy）",             gain: 1.79, credit: kbsim),
        KeySoundPack(id: "bluealps",  displayName: "铿锵（SKCM Blue Alps）",        gain: 1.00, credit: kbsim),
        KeySoundPack(id: "buckling",  displayName: "老派（IBM Buckling Spring）",   gain: 2.10, credit: kbsim),
        // —— 厚重 ——
        KeySoundPack(id: "holypanda", displayName: "厚实（Holy Panda）",            gain: 1.20, credit: kbsim),
        KeySoundPack(id: "topre",     displayName: "绵密（Topre 静电容）",           gain: 2.44, credit: kbsim),
        KeySoundPack(id: "cream",     displayName: "浑厚（NovelKeys Cream）",       gain: 1.56, credit: kbsim),
        KeySoundPack(id: "blackink",  displayName: "深沉（Gateron Ink Black）",     gain: 1.85, credit: kbsim),
        KeySoundPack(id: "mxblack",   displayName: "闷响（Cherry MX Black）",       gain: 1.04, credit: kbsim),
        // —— 顺滑 ——
        KeySoundPack(id: "redink",    displayName: "圆润（Gateron Ink Red）",       gain: 1.40, credit: kbsim),
        KeySoundPack(id: "turquoise", displayName: "顺滑（Turquoise Tealios）",     gain: 1.80, credit: kbsim),
        // —— 轻 ——
        KeySoundPack(id: "mxbrown",   displayName: "轻柔（Cherry MX Brown）",       gain: 1.58, credit: kbsim),
        KeySoundPack(id: "alpaca",    displayName: "安静（Alpaca）",                gain: 2.56, credit: kbsim),
    ]

    private static let kbsim = "kbsim (github.com/tplai/kbsim) · MIT · Thomas Lai"

    /// 出厂默认。**按 id 取，不取 `all[0]`**——上面那张表是按听感排的，
    /// 以后插一套更脆的进去就会悄悄把所有新用户的默认音色换掉。
    static let fallback = all.first { $0.id == "boxnavy" } ?? all[0]

    static func named(_ id: String) -> KeySoundPack {
        all.first { $0.id == id } ?? fallback
    }
}

/// 解码好、格式对齐好、音高变体也备好的一套采样。
///
/// **全部在加载时算完，播放路径上不做任何 DSP。** 一次敲击到出声之间只剩
/// 「取一个已经躺在内存里的 buffer 交给 `scheduleBuffer`」，实测这一步 <0.03ms。
/// 每套包解码后约 1.1MB，**只有当前选中的那套会驻留**——所以收录十二套包
/// 增加的是磁盘（604KB mp3），不是内存。
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
    ///
    /// **自定义按键音也用这一档变体**（见 `LoadedCustomSounds`）。那边其实更需要：
    /// 一个键指一条采样，连按空格时是同一条采样在重复，机关枪效应最明显。
    static let pitchRatios: [Double] = [0.97, 1.0, 1.03]

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

    /// 自定义按键音复用这一条（见 `LoadedCustomSounds`）：解码路径只许有一份，
    /// 否则内置采样和用户采样会走出两种不同的处理，听感对不上时无从查起。
    static func decode(_ url: URL) -> AVAudioPCMBuffer? {
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
    static func resample(_ source: AVAudioPCMBuffer, by ratio: Double,
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
