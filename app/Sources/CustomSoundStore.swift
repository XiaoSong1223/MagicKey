import Foundation
import Combine
import AVFoundation

/// 音色库里的一条自定义采样。
///
/// `gain` 在**导入时**就算好存下来，不在播放时算——响度对齐要先把整条采样解码一遍
/// 求 RMS，那是几十毫秒的事，绝不能落在按键路径上。副作用是这个值和导入当时的
/// 对齐目标绑死：以后 `KeySoundPack.loudnessTargetDBFS` 改了，已导入的音色不会
/// 自己跟上（重新导入即可）。这是有意的取舍——为了一个几乎不会动的常量去做
/// 迁移逻辑不划算。
struct CustomSoundEntry: Codable, Identifiable, Hashable {
    let id: UUID
    /// 显示名。取原文件名去掉扩展名——用户自己挑的文件名就是他心里的名字
    var displayName: String
    /// 响度对齐系数，见 `KeySoundPack.alignmentGain`
    var gain: Float
    /// 存储目录下的文件名（`<UUID>.<原扩展名>`）。**保留原扩展名**：
    /// `AVAudioFile` 认扩展名，改成统一的 `.bin` 会让它认不出容器格式
    var fileName: String
}

/// `custom.json` 的磁盘格式。
///
/// 指键表的键是**字符串**：JSON 的对象键只能是字符串，写成 `[UInt16: UUID]`
/// 时 `JSONEncoder` 会悄悄把整个字典编码成 `[k1, v1, k2, v2]` 的**数组**，
/// 人打开文件一看根本读不出是什么。存字符串换来的是文件可读可手改。
private struct CustomSoundFile: Codable {
    var version: Int
    var sounds: [CustomSoundEntry]
    var assignments: [String: UUID]
}

/// 导入失败的原因。**每一条都要能直接说给用户听**——
/// 「导入失败」这四个字对用户毫无用处，他需要知道换个什么文件才行。
enum CustomSoundImportError: LocalizedError {
    /// 解不出音频。扩展名对不上、文件损坏、或者是个 DRM 保护的 m4a
    case unreadable(String)
    /// 超过时长上限。**带上实际时长**：只说「太长了」用户不知道要剪到多少
    case tooLong(name: String, seconds: Double, limit: Double)
    /// 拷贝进存储目录失败（磁盘满、权限）
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "「\(name)」读不出音频内容。支持常见音频格式（mp3 / m4a / wav / aiff），"
                 + "受 DRM 保护的文件不行。"
        case .tooLong(let name, let seconds, let limit):
            return String(format: "「%@」有 %.1f 秒，超过了 %.1f 秒的上限。"
                          + "按键音是一敲一响的，太长的采样连打时会互相盖住。",
                          name, seconds, limit)
        case .copyFailed(let why):
            return "存不进音色库：\(why)"
        }
    }
}

/// 自定义按键音的数据层：音色库 + 指键关系 + 磁盘存储。
///
/// **不负责出声。** 播放端是 `LoadedCustomSounds` / `KeySoundPlayer`，
/// 这里只管「有哪些音色」「哪个键指了哪条」，以及把它们落到磁盘上。
///
/// 存储目录和 `StateGuard` 的快照同在 `~/Library/Application Support/MagicKey/`
/// 之下（那个目录已经存在，路径拼法照抄它），但另起一层子目录：
/// 这里放的是用户导入的**原始文件**，和引擎的崩溃快照是两类东西，
/// 混在一起时「清掉崩溃快照」这种操作会顺手删掉用户的音色。
@MainActor
final class CustomSoundStore: ObservableObject {

    /// 单条采样的时长上限。**2 秒是「按键音」这个用途的上限，不是技术上限**：
    /// 更长的采样在连打时会一路叠上去，听起来是糊成一片而不是「音效很长」。
    /// 拒收而不是自动截断——截断会在波形中间切一刀，爆一声。
    static let maxDuration: Double = 2.0

    @Published private(set) var entries: [CustomSoundEntry] = []
    /// keyCode → 音色 id。内存里用 `UInt16` 是因为事件给的就是这个类型，
    /// 落盘时才转成字符串（见 `CustomSoundFile`）
    @Published private(set) var assignments: [UInt16: UUID] = [:]

    let directory: URL
    private var jsonURL: URL { directory.appendingPathComponent("custom.json") }

    /// 应用全局的那一份。视图层（设置窗口 → 键盘图窗口）要拿到它，
    /// 而那条链上有一段是 SwiftUI 的 `Button` 闭包，逐层传参会污染四个类型的签名。
    static let shared = CustomSoundStore()

    #if UI_PROBE
    /// **只在探针里编译。** 把存储目录挪到临时目录。
    ///
    /// 非有不可：探针跑的是真实的导入/删除路径，不挪走的话它会往用户真正的
    /// `~/Library/Application Support/MagicKey/CustomSounds/` 里写文件、
    /// 甚至删掉用户导入的音色。同一个理由让 `Settings` 也在探针里换了 defaults 域
    /// （见那边的注释，那个坑是实测踩出来的）。
    ///
    /// **必须在第一次访问 `shared` 之前设置**——`shared` 是惰性全局，
    /// 一旦解析过就再也不会重新解析目录了。
    nonisolated(unsafe) static var probeDirectoryOverride: URL?
    #endif

    /// - Parameter directory: 存储目录。nil = 真实的 App Support 路径
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
        load()
    }

    private static func defaultDirectory() -> URL {
        #if UI_PROBE
        if let forced = probeDirectoryOverride { return forced }
        #endif
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicKey", isDirectory: true)
            .appendingPathComponent("CustomSounds", isDirectory: true)
    }

    // MARK: - 读写磁盘

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let file = try? JSONDecoder().decode(CustomSoundFile.self, from: data) else { return }

        // 只收文件还在的条目。手动删过文件、或者拷贝到一半断电，
        // 留下的空条目在界面上是一条点不响的音色——比没有它更糟。
        entries = file.sounds.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
        }
        let live = Set(entries.map(\.id))
        var restored: [UInt16: UUID] = [:]
        for (key, id) in file.assignments {
            guard let code = UInt16(key), live.contains(id) else { continue }
            restored[code] = id
        }
        assignments = restored
        Log.write("[keysound] 自定义音色库：\(entries.count) 条采样，\(assignments.count) 个指键")
    }

    private func save() {
        let file = CustomSoundFile(
            version: 1,
            sounds: entries,
            assignments: Dictionary(uniqueKeysWithValues: assignments.map { (String($0.key), $0.value) }))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: jsonURL, options: .atomic)
        } catch {
            Log.write("[keysound] 自定义音色写盘失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 音色库

    func url(for entry: CustomSoundEntry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    func entry(_ id: UUID) -> CustomSoundEntry? {
        entries.first { $0.id == id }
    }

    /// 导入一条采样：验证 → 算响度对齐系数 → 拷进存储目录 → 落盘。
    ///
    /// **拷贝而不是记路径。** 记路径的话用户把源文件移走/删掉/拔掉 U 盘，
    /// 音色就静默变哑了，而界面上它还在列表里。一条按键音最多 2 秒，拷贝的代价
    /// 是几百 KB，换来的是「导进来就是我的了」。
    @discardableResult
    func importSound(from source: URL) throws -> CustomSoundEntry {
        let name = source.deletingPathExtension().lastPathComponent

        guard let file = try? AVAudioFile(forReading: source),
              file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw CustomSoundImportError.unreadable(source.lastPathComponent)
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration <= Self.maxDuration else {
            throw CustomSoundImportError.tooLong(name: source.lastPathComponent,
                                                 seconds: duration, limit: Self.maxDuration)
        }
        guard let buffer = LoadedKeySoundPack.decode(source) else {
            throw CustomSoundImportError.unreadable(source.lastPathComponent)
        }

        let level = Self.analyze(buffer)
        let gain = KeySoundPack.alignmentGain(rmsDBFS: level.rmsDBFS, peak: level.peak)

        let id = UUID()
        // 扩展名要留住：AVAudioFile 靠它认容器格式。源文件没有扩展名时
        // 用 wav 兜底——走到这里说明它已经被解码成功过，给个能读的名字即可。
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(fileName))
        } catch {
            throw CustomSoundImportError.copyFailed(error.localizedDescription)
        }

        let entry = CustomSoundEntry(id: id, displayName: name, gain: gain, fileName: fileName)
        entries.append(entry)
        save()
        Log.write(String(format: "[keysound] 导入自定义采样「%@」%.2fs  RMS %.1fdBFS 峰值 %.3f → gain %.2f",
                         name, duration, level.rmsDBFS, level.peak, gain))
        return entry
    }

    /// 删除一条音色：文件、条目、以及**引用它的全部指键**。
    ///
    /// 指键必须一起清。留着的话那些键会解析到一条不存在的音色——按下去没声，
    /// 键盘图上却还标着「已指定」，用户只会以为音效坏了。
    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        try? FileManager.default.removeItem(at: url(for: entry))
        let orphaned = assignments.filter { $0.value == id }.map(\.key)
        for code in orphaned { assignments.removeValue(forKey: code) }
        save()
        Log.write("[keysound] 删除自定义采样「\(entry.displayName)」，顺带清掉 \(orphaned.count) 个指键")
    }

    // MARK: - 指键

    /// 给某个键指一条音色。`id` 传 nil = 清除这个键的指定。
    func assign(_ id: UUID?, to keyCode: UInt16) {
        if let id, entries.contains(where: { $0.id == id }) {
            assignments[keyCode] = id
        } else {
            assignments.removeValue(forKey: keyCode)
        }
        save()
    }

    func assignedSound(for keyCode: UInt16) -> CustomSoundEntry? {
        assignments[keyCode].flatMap { id in entries.first { $0.id == id } }
    }

    // MARK: - 响度

    /// 求整条采样的 RMS（dBFS）与峰值。和内置包那张表用的是同一套口径
    /// （全部声道的全部样点一起算），换口径两边的数就不能比了。
    static func analyze(_ buffer: AVAudioPCMBuffer) -> (rmsDBFS: Float, peak: Float) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return (-.infinity, 0) }
        var sumSq = 0.0
        var peak: Float = 0
        let frames = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            let data = channels[c]
            for i in 0..<frames {
                let v = data[i]
                sumSq += Double(v) * Double(v)
                peak = Swift.max(peak, abs(v))
            }
        }
        let n = Double(frames * Int(buffer.format.channelCount))
        let rms = (sumSq / n).squareRoot()
        return (rms > 0 ? 20 * log10(Float(rms)) : -.infinity, peak)
    }
}

/// 解码好、音高变体也备好的自定义层：keyCode → 候选 buffer。
///
/// 和 `LoadedKeySoundPack` 是同一套做法（加载期把 DSP 做完，播放路径零计算），
/// 而且**共用它的解码与重采样实现**——两份实现意味着内置音和自定义音会走出
/// 两种不同的处理，听感对不上时无从查起。
final class LoadedCustomSounds {

    /// keyCode → 候选（= 1 条采样 × 3 档音高变体）
    private var byKey: [UInt16: [AVAudioPCMBuffer]] = [:]
    /// 音色 id → 候选。同一条音色指给十个键时只解码一次
    private let bySound: [UUID: [AVAudioPCMBuffer]]

    var isEmpty: Bool { byKey.isEmpty }
    var keyCount: Int { byKey.count }

    /// - Parameter previous: 上一次的加载结果。用户在键盘图上每点一个键都会触发
    ///   一次重载，没有这个缓存的话每点一下都要把全部采样重解码一遍
    ///   （一条 2 秒的 wav 约 15ms，指了十个键就是 150ms 的主线程卡顿）。
    ///   只复用**内容没变过**的音色：条目是不可变值类型，id 相同即内容相同。
    init(entries: [CustomSoundEntry], assignments: [UInt16: UUID],
         directory: URL, format: AVAudioFormat, previous: LoadedCustomSounds? = nil) {

        // 只解码真正被指到的音色。库里躺着二十条、只指了一条时，
        // 剩下十九条不该占内存——它们的用途只有试听，那条路径是另建的。
        let needed = Set(assignments.values)
        var cache: [UUID: [AVAudioPCMBuffer]] = [:]
        var decoded = 0

        for entry in entries where needed.contains(entry.id) {
            if let reused = previous?.bySound[entry.id] {
                cache[entry.id] = reused
                continue
            }
            let url = directory.appendingPathComponent(entry.fileName)
            guard let source = LoadedKeySoundPack.decode(url) else { continue }
            var variants: [AVAudioPCMBuffer] = []
            for ratio in LoadedKeySoundPack.pitchRatios {
                if let b = LoadedKeySoundPack.resample(source, by: ratio,
                                                       gain: entry.gain, to: format) {
                    variants.append(b)
                }
            }
            guard !variants.isEmpty else { continue }
            cache[entry.id] = variants
            decoded += 1
        }
        bySound = cache

        for (code, id) in assignments {
            guard let buffers = cache[id] else { continue }
            byKey[code] = buffers
        }
        if !byKey.isEmpty || decoded > 0 {
            Log.write("[keysound] 自定义层已载入 \(byKey.count) 个指键"
                      + "（\(cache.count) 条采样，其中新解码 \(decoded) 条）")
        }
    }

    func buffers(for keyCode: UInt16) -> [AVAudioPCMBuffer]? {
        guard let b = byKey[keyCode], !b.isEmpty else { return nil }
        return b
    }
}
