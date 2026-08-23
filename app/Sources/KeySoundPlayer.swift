import Foundation
import AVFoundation

/// 键盘音效的播放端。**不认识按键，也不认识权限**——只管「给我一个槽位，
/// 我尽快出声」。事件从哪来、该不该来，全是 `KeySoundController` 的事。
///
/// 播放不需要任何 TCC 授权（那是采集才要的），所以这一层没有任何降级路径。
@MainActor
final class KeySoundPlayer {

    /// 公共处理格式。整张图只有这一种连接格式：
    /// 采样在**加载时**就全部转过来了，切换音色包不用碰图。
    /// 输出设备是 48kHz 还是 44.1kHz 由 mainMixer 自己去转。
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// 声池路数。一次敲击约 0.10–0.24 秒，12 路意味着要每秒 50 次以上
    /// 才会轮回到还在响的那一路——比人类最快的连打还快一截。
    private static let voiceCount = 12

    /// 停手多久之后把引擎收掉。收掉是为了别让 CoreAudio 的 IO 线程空转，
    /// 而拉起只要几毫秒（实测见 `start`），所以这个值可以给得很短。
    private static let idleTimeout: TimeInterval = 30

    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0

    private var pack: LoadedKeySoundPack?

    /// 自定义按键音层。**nil = 整层旁路**（用户关了总开关，或一个键都没指）。
    /// 用「有没有这个对象」表示开关，而不是再加一个 bool：关掉时连内存也不占，
    /// 而且解析路径上少一个分支就少一处能写错的地方。
    private var custom: LoadedCustomSounds?

    /// 上一次用过的候选下标，按「槽位 + 方向」分别记。
    /// 随机取样必须**避开上一个**：真随机在 5 选 1 里有 20% 的概率连着重复，
    /// 而连着两下一模一样正是「机关枪」最刺耳的那一下。
    private var lastPicked: [Int: Int] = [:]

    /// 只在引擎运行期间存在的一次性定时器。到点前每次敲击都把它顺延，
    /// 所以打字过程中它永远不会真的触发，也就不存在常驻的周期性唤醒。
    private var idleTimer: Timer?

    private var configObserver: NSObjectProtocol?

    /// 自己留一份总音量。输出设备一换 mainMixer 可能是**新建**的，
    /// `outputVolume` 会回到默认的 1.0——不留底就没法把用户设的值放回去，
    /// 表现是「插上耳机之后键盘音效突然变得很响」。
    private var volume: Double = 0.6

    /// 「事件到达 → scheduleBuffer 返回」的耗时统计。
    /// 逐次打日志会让 NSLog 自己变成延迟的主要来源，所以攒够一批再打一行。
    private var latencyCount = 0
    private var latencySum = 0.0
    private var latencyMax = 0.0
    private static let latencyBatch = 100

    var isRunning: Bool { engine.isRunning }

    // MARK: - 生命周期

    init() {
        for _ in 0..<Self.voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            voices.append(node)
        }
        connectVoices()

        // **必须处理。** 换耳机、插拔外接显示器的扬声器、切换输出设备都会发这个通知，
        // 系统会在发之前把引擎停掉并可能拆掉连接。不重建的话表现是「插上耳机之后
        // 键盘就再也不响了」，而且没有任何报错——引擎只是安静地不再运行。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func connectVoices() {
        for node in voices {
            engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        }
    }

    // MARK: - 外部输入

    /// 换音色包。加载失败保留原来那套——把用户正在用的声音换成静音，
    /// 比留着一套不是他选的声音更糟。
    func load(_ requested: KeySoundPack) {
        guard pack?.id != requested.id else { return }
        guard let loaded = LoadedKeySoundPack(pack: requested, format: Self.format) else {
            Log.write("[keysound] 音色包「\(requested.id)」加载失败，继续用「\(pack?.id ?? "无")」")
            return
        }
        pack = loaded
    }

    /// 换掉自定义层。传 nil 就是整层旁路。
    ///
    /// **每次都换，不做 id 比对**——这个方法的调用者是「库或指键变了」，
    /// 变化本身就是重载的理由。重复解码的代价由 `LoadedCustomSounds(previous:)`
    /// 的缓存兜住，不需要在这里再判一次。
    func setCustom(_ layer: LoadedCustomSounds?) {
        custom = layer
    }

    /// 0–1。走 mainMixer 的总音量，不逐个节点设——逐个设的话
    /// 拖滑块时已经在响的那几路会跟着跳变，听起来像杂音。
    func setVolume(_ v: Double) {
        volume = max(0, min(1, v))
        engine.mainMixerNode.outputVolume = Float(volume)
    }

    /// 预热。开关一打开就调，把只发生一次的那些开销（首次 `play()` 实测 19.8ms）
    /// 挡在用户第一次敲键之前。
    func start() {
        guard pack != nil else { return }
        guard !engine.isRunning else { armIdleTimer(); return }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.write("[keysound] 音频引擎启动失败：\(error.localizedDescription)")
            return
        }
        // **节点必须无条件先 stop 再 play，不能按 isPlaying 跳过。**
        // `engine.stop()` 会作废 player node 的渲染状态，但 `isPlaying` 留在
        // true（实测 12/12 全是 true）——按 `!isPlaying` 补 play() 会整段跳过，
        // 此后 scheduleBuffer 排什么都无声：「开关关一次再开就哑」的根因就是这行。
        // 先 stop 把节点状态归零，再 play 才真的接回渲染。
        // pause 恢复的路径本不受此害，但统一走这条也无损：暂停期间残留的排期
        // 本来就是过期的敲击，丢掉是对的。
        for node in voices { node.stop() }
        for node in voices { node.play() }
        Log.write(String(format: "[keysound] 引擎拉起 %.2fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        armIdleTimer()
    }

    /// 用户关掉功能、或应用退出。和「空闲收掉」不同，这里要把定时器也撤掉。
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        flushLatency()
        guard engine.isRunning else { return }
        engine.stop()
    }

    // MARK: - 播放

    /// 这一下该播哪一组候选。
    ///
    /// **优先级：按下 = 自定义指键 > 音色包槽位；抬起 = 永远走音色包。**
    ///
    /// 抬起不走自定义是定下来的取舍，不是没做完：用户导入的多半是一整声
    /// 「哒」，把它同时当按下音和抬起音，一次敲击就会听到两遍同样的声音。
    /// 让抬起继续用音色包的抬起音，两段音的手感反而是连着的。
    ///
    /// 抽成单独一个函数是为了让探针能验这条优先级——`play` 里内联的话，
    /// 探针只能靠听，而「解析到了哪一层」听不出来。
    private func candidates(_ slot: KeySoundSlot, isDown: Bool,
                            keyCode: UInt16) -> (buffers: [AVAudioPCMBuffer], fromCustom: Bool) {
        if isDown, let mine = custom?.buffers(for: keyCode) {
            return (mine, true)
        }
        return (pack?.buffers(slot, isDown: isDown) ?? [], false)
    }

    /// - Parameter keyCode: 事件里的虚拟键码。自定义指键按它查表——
    ///   槽位（空格/回车/退格/通用）粒度太粗，指不到具体某个键。
    /// - Parameter arrival: 事件到达的时刻。用来量「事件到达 → scheduleBuffer」
    ///   这一段，也就是本进程真正能控制的那部分延迟。
    func play(_ slot: KeySoundSlot, isDown: Bool, keyCode: UInt16, arrival: CFAbsoluteTime) {
        guard pack != nil else { return }

        // 空闲收掉之后的第一次敲击：在这里把引擎拉回来。这一下会比后续的慢
        // 几毫秒，`start()` 里那行日志就是给这一下看的。
        if !engine.isRunning { start() }
        guard engine.isRunning else { return }

        let (candidates, fromCustom) = candidates(slot, isDown: isDown, keyCode: keyCode)
        guard !candidates.isEmpty else { return }

        // 「上一次挑了哪个」要按**候选来源**分开记。自定义键和音色包槽位共用
        // 一个计数器的话，两边的下标会互相顶掉，避免重复那件事就白做了。
        let key = fromCustom
            ? Int(keyCode) &+ 1_000_000
            : slot.hashValue &* 2 &+ (isDown ? 1 : 0)
        var index = Int.random(in: 0..<candidates.count)
        if candidates.count > 1, index == lastPicked[key] {
            index = (index + 1) % candidates.count
        }
        lastPicked[key] = index

        let node = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        // ±2dB 音量抖动。和音高变体是两个正交的维度，叠起来才够散——
        // 只抖音量的话连打时音色还是一模一样，只是忽大忽小，反而更像故障。
        node.volume = Self.jitter()
        node.scheduleBuffer(candidates[index], at: nil, options: [], completionHandler: nil)

        record(latency: CFAbsoluteTimeGetCurrent() - arrival)
        armIdleTimer()
    }

    /// ±2dB → ×0.794…×1.259
    private static func jitter() -> Float {
        Float(pow(10.0, Double.random(in: -2...2) / 20.0))
    }

    // MARK: - 空闲收掉

    private func armIdleTimer() {
        let deadline = Date().addingTimeInterval(Self.idleTimeout)
        // 顺延优先于重建：改 `fireDate` 不产生新对象，也不重排 runloop 源
        if let t = idleTimer, t.isValid { t.fireDate = deadline; return }
        let t = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTimeoutFired() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func idleTimeoutFired() {
        idleTimer = nil
        guard engine.isRunning else { return }
        // `pause()` 而不是 `stop()`：保留渲染资源，下次拉起才是几毫秒级
        engine.pause()
        flushLatency()
        Log.write("[keysound] \(Int(Self.idleTimeout))s 无敲击，引擎已暂停")
    }

    // MARK: - 输出设备变化

    /// 系统在发这个通知之前已经把引擎停了，连接也可能被拆掉。
    /// 重连一遍再按原状态拉起——`isRunning` 此刻一定是 false，
    /// 所以「之前在不在跑」得看定时器还在不在。
    private func handleConfigurationChange() {
        let wasRunning = idleTimer != nil
        engine.stop()
        connectVoices()
        setVolume(volume)          // mixer 可能是新建的，音量得放回去
        Log.write("[keysound] 输出设备变化，已重建音频图（之前在运行：\(wasRunning)）")
        if wasRunning { start() }
    }

    // MARK: - 延迟打点

    private func record(latency: CFAbsoluteTime) {
        let ms = latency * 1000
        latencyCount += 1
        latencySum += ms
        latencyMax = max(latencyMax, ms)
        if latencyCount >= Self.latencyBatch { flushLatency() }
    }

    private func flushLatency() {
        guard latencyCount > 0 else { return }
        Log.write(String(format: "[keysound] 事件到达 → scheduleBuffer  n=%d avg=%.3fms max=%.3fms",
                         latencyCount, latencySum / Double(latencyCount), latencyMax))
        latencyCount = 0
        latencySum = 0
        latencyMax = 0
    }

    // MARK: - 探针

    #if UI_PROBE
    /// **只在探针里编译。** 渲染验证要在 mainMixer 上装 tap 量实际输出的 RMS——
    /// 「scheduleBuffer 被调用了」和「真的有声音渲染出来」是两回事，
    /// 时序打点证明不了后者。
    var probeEngine: AVAudioEngine { engine }
    /// 模拟「空闲 30 秒」那一下，不用真等 30 秒
    func probeForceIdlePause() { idleTimeoutFired() }

    /// 一次敲击解析到了哪一层。**走的就是 `play` 用的那个函数**——
    /// 探针复刻一份优先级判断的话，测的是探针自己写对没有，不是 app 写对没有。
    enum Resolution: String { case custom = "自定义", pack = "音色包", none = "无" }

    func probeResolve(_ slot: KeySoundSlot, isDown: Bool, keyCode: UInt16) -> Resolution {
        let (buffers, fromCustom) = candidates(slot, isDown: isDown, keyCode: keyCode)
        if buffers.isEmpty { return .none }
        return fromCustom ? .custom : .pack
    }

    var probeCustomIsLoaded: Bool { custom != nil }
    #endif
}
