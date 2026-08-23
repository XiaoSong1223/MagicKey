import Foundation
import Combine
import AppKit
import IOKit
import IOKit.hid

/// 键盘音效的状态。和 `AudioStatus` / `Engine.Phase` 用同一套语义：
/// 绿=在工作，橙=要你处理，灰=没在用，红=坏了。
///
/// **和音乐律动的「未授权」不是一回事**：那边只能从超时**推断**，所以文案用「似乎」；
/// 这边 `IOHIDCheckAccess` 是可以直接问的公开 API，答案是确定的，可以把话说死。
enum KeySoundStatus: Equatable {
    /// 用户没开这个功能
    case off
    /// 开着，但没有「输入监控」授权。**此时一个 monitor 都不装**
    case needsPermission
    /// 系统授权框正弹着，等用户处理。**只在 `IOHIDRequestAccess` 未返回期间存在**
    case requesting
    /// 请求过了，系统仍然不放行。绝大多数时候是**旧授权记录失效**：
    /// TCC 那条记录绑的是授权当时的代码签名，重新构建/更新之后对不上，
    /// 而系统设置里的开关**看着还是打开的**。详见 `resetOwnRecord()`。
    case blocked
    /// 授权拿到了，但**是在本进程启动之后才拿到的**，对已经在跑的进程不生效。
    /// 这一态下同样一个 monitor 都不装——装了也收不到任何事件。
    /// 详见 `KeySoundController.grantedAtLaunch`。
    case needsRestart
    /// 采样加载失败，带原因
    case failed(String)
    /// 正常工作
    case running
}

/// 键盘音效的总控。事件监听 + 授权状态在这里，出声在 `KeySoundPlayer`，
/// 采样在 `KeySoundPack`。
///
/// **和背光引擎完全解耦**：不碰 `Engine`，也不给 `keypulse` 供事件。
/// 背光那条线是零权限的（`CGEventSource.secondsSinceLastEventType`），
/// 把它接到这条需要授权的事件流上等于把整条产品线的权限门槛抬上来。
///
/// **默认关闭。** 这是本应用第一个需要「输入监控」的功能，而该权限的语义是
/// 「这个 app 能看到你按的每一个键」——必须由用户主动开启，不能默认打开再让他去关。
@MainActor
final class KeySoundController: ObservableObject {

    @Published private(set) var status: KeySoundStatus = .off

    private let player = KeySoundPlayer()

    /// 自定义按键音的数据源。**只读不写**——增删指键是 UI 的事，
    /// 这里只在收敛时按当前内容把播放层重建一遍。
    private let customStore: CustomSoundStore
    /// 上一次建好的自定义层。留着是为了当下一次重建的缓存
    /// （见 `LoadedCustomSounds.init(previous:)`）：用户在键盘图上每点一个键
    /// 都会触发一次收敛，没有缓存的话每点一下都要把全部采样重解码。
    private var loadedCustom: LoadedCustomSounds?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activeObserver: NSObjectProtocol?

    /// 上一次看到的修饰键状态。`flagsChanged` 只告诉你「现在是哪些」，
    /// 不告诉你「刚才按下还是抬起」，只能自己和上一次比位。
    private var lastFlags: NSEvent.ModifierFlags = []

    /// 弹过一次授权框就不再弹。系统只会真正弹一次（之后 `IOHIDRequestAccess`
    /// 直接返回上次的结果），再调也只是白跑，还会让状态在两态之间来回跳。
    private var didRequestAccess = false

    /// - Parameter customStore: 自定义音色的数据源。探针要塞一个指向临时目录的
    ///   实例进来，正式路径传 nil 用全局那一份。
    ///
    ///   默认值写成 `nil` 再在函数体里取 `.shared`，**不能直接写
    ///   `= .shared`**：默认实参是在**调用方**求值的，而调用方不一定在主 actor 上，
    ///   Swift 6 语言模式下那是个编译错误（现在是警告）。
    init(customStore: CustomSoundStore? = nil) {
        self.customStore = customStore ?? .shared
        // **必须在这里查一次，不能等到第一次 apply()。**
        // 见 `grantedAtLaunch`：要记的是「本进程启动那一刻」的授权结果，
        // 而 apply() 只在功能开着时才会走到查询那一行——默认关闭的情况下，
        // 用户可能在启动几分钟后才第一次打开开关，那时查到的已经不是启动值了。
        Self.captureLaunchAccess()

        // 授权是在**系统设置里**改的，改完不会通知本进程。
        // 用「应用重新变为活跃」当重查时机：用户去系统设置勾完再回来点面板，
        // 正好走这一下。**这是事件驱动，不是轮询**——不开定时器，不活跃时零开销。
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckAccess() }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    // MARK: - 授权

    /// 查询「输入监控」授权。**不弹框**，可以随便调。
    ///
    /// 对应 TCC 的 `kTCCServiceListenEvent`。走 IOKit 而不是去猜
    /// `CGPreflightListenEventAccess`：后者是 CoreGraphics 私有接口，
    /// 而 `IOHIDCheckAccess` 从 10.15 起就是公开 API。
    static func accessGranted() -> Bool {
        #if UI_PROBE
        if let forced = probeAccessOverride { return forced }
        #endif
        let raw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        // **只在变化时打**：`apply()` 每次收敛都会走到这里，无条件打日志
        // 等于把统一日志刷满，真出问题时反而找不到那一行。
        if raw != lastLoggedAccess {
            lastLoggedAccess = raw
            Log.write("[keysound] IOHIDCheckAccess(ListenEvent) = \(describe(raw))")
        }
        return raw == kIOHIDAccessTypeGranted
    }

    private static var lastLoggedAccess: IOHIDAccessType?

    private static func describe(_ t: IOHIDAccessType) -> String {
        switch t {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied:  return "denied"
        default:                      return "unknown(\(t.rawValue))"
        }
    }

    /// 本进程**启动那一刻**的授权结果。由 `init()` 抓一次，之后永不更新。
    ///
    /// ## 为什么需要这个快照
    ///
    /// 「输入监控」和别的 TCC 权限不一样：**授权对已经在运行的进程不生效**。
    /// 用户在系统设置里勾上之后，`IOHIDCheckAccess` 会立刻返回「已授权」，
    /// 但 `NSEvent.addGlobalMonitorForEvents` 装上去照样一个事件都收不到——
    /// 系统弹的那个「退出并重新打开」对话框说的就是这件事。
    ///
    /// 只看 `accessGranted()` 的话会走到一个**最坏的状态**：面板亮绿灯说「响应中」，
    /// 在别的 app 里打字却完全没声。用户看到的是「明明授权了、显示正常、就是不响」，
    /// 这比老老实实说「还没生效」糟得多。所以两个值要一起看：
    /// 现在授权了、但启动时没有 → `.needsRestart`，不装 monitor、不起引擎。
    static var grantedAtLaunch: Bool {
        launchAccess ?? accessGranted()
    }

    private static var launchAccess: Bool?

    private static func captureLaunchAccess() {
        guard launchAccess == nil else { return }
        launchAccess = accessGranted()
        // `KeySoundController` 是 `AppDelegate` 的存储属性，构造发生在
        // `override init()` 的**函数体之前**，而 `Log.sink` 是在函数体里设的——
        // 上面那次查询的日志必然掉进空 sink。清掉节流标记，让第一次 `apply()`
        // 把它补打出来，否则「启动时到底有没有授权」在日志里永远看不到。
        lastLoggedAccess = nil
    }

    /// 退出并重新打开自己，让「输入监控」授权生效。
    ///
    /// 路径取 `Bundle.main.bundlePath` 而**不是写死 `/Applications`**：
    /// `make run` 时 bundle 就在源码树里，写死路径会去开一个不存在的（或更糟，
    /// 开了另一份旧的）应用。
    ///
    /// 先派一个 shell 睡半秒再 `open`：`NSApp.terminate` 之后本进程就没了，
    /// 而 `open` 必须等旧实例真的退出，否则 LaunchServices 会认为它还开着、
    /// 只是把已有实例拿到前台，等于没重启。
    func restartApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        do {
            try task.run()
        } catch {
            // 起不来就别退出——退了用户就得自己去 Finder 里找
            Log.write("[keysound] 重启失败，未退出：\(error.localizedDescription)")
            openInputMonitoringSettings()
            return
        }
        Log.write("[keysound] 为使「输入监控」授权生效，正在重启：\(path)")
        NSApp.terminate(nil)
    }

    /// 打开「系统设置 → 隐私与安全性 → 输入监控」。
    ///
    /// 锚点 `Privacy_ListenEvent` 是从系统里核对出来的，不是抄的：
    /// `SecurityPrivacyExtension.appex/Contents/Resources/TCCServiceList.plist`
    /// 里 `kTCCServiceListenEvent` 那一条的 `revealElementKeyName` 就是它。
    ///
    /// ⚠️ 注意**只 strings 那个 Mach-O 是查不到的**——二进制里只有硬编码在代码里的
    /// 那十来个锚点（`Privacy_AudioCapture` 在，`Privacy_ListenEvent` 不在），
    /// 完整的表在同 bundle 的 `TCCServiceList.plist` 里。
    /// 也不能靠 `open` 试：锚点写错时它照样返回 0，只是打开了别的面板。
    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:"
                      + "com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")
        if let url, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// 触发系统授权框。用户**主动打开开关**时才调——不能在启动时调，
    /// 那等于一装上就跟人要「看你按的每一个键」的权限。
    func requestAccess() {
        didRequestAccess = true
        status = .requesting
        // 放到后台队列：这个调用在用户点掉对话框之前可能不返回，
        // 卡在主线程上就是整个 UI 假死。对话框是系统进程画的，不需要我们在主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            // **每次都先清掉自己那条旧记录。** 只要走到这里就说明当前没有授权，
            // 那条记录要么不存在（清了是空操作），要么已经失效或是「拒绝」——
            // 三种情况都该清。不清的话 `IOHIDRequestAccess` 会既不弹框也不放行，
            // 用户就卡在「等待授权」上出不去了（2026-08-23 真机踩到）。
            let didReset = Self.resetOwnRecord()
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Task { @MainActor [weak self] in
                Log.write("[keysound] 已请求「输入监控」授权（先重置记录=\(didReset)），返回 \(granted)")
                self?.recheckAccess()
            }
        }
    }

    /// 删掉 TCC 里**本应用自己**这一条「输入监控」记录，好让下一次请求重新弹框。
    ///
    /// ## 为什么必须能清
    ///
    /// TCC 记录里存的是授权当时的**代码要求**（`csreq`）。ad-hoc 签名的
    /// 指定要求就是 `cdhash H"…"`——一个字节都不能变的二进制哈希，
    /// **每次重新构建、每次版本更新都不一样**。于是：
    ///
    /// - 系统设置里那个开关还亮着，名字也还是 MagicKey；
    /// - `IOHIDCheckAccess` 却返回未授权，tccd 日志里是
    ///   `Failed to match existing code requirement ... kTCCServiceListenEvent`；
    /// - 用户看到的是「我明明授权了」，而在设置里点开关、重启应用统统没用。
    ///
    /// 这是本项目实测踩到的（2026-08-23）。唯一的出路是把那条记录删掉重来。
    ///
    /// `tccutil` 是系统自带的公开命令，`reset <service> <bundle-id>` 只影响
    /// **点名的那个 bundle id**，不需要 sudo，也碰不到别的应用。
    /// 拿不到 bundle id（比如探针那种裸可执行文件）就直接不做——
    /// 不带 id 的 `tccutil reset` 会清掉**所有**应用的该项授权，绝不能走到。
    ///
    /// `nonisolated`：只碰 `Bundle`/`Process`/`Log`（都线程安全），而
    /// `waitUntilExit()` 是阻塞调用，本来就必须在后台队列跑。之前没标，
    /// 从 `requestAccess` 的后台闭包里调它是 Swift 6 意义上的错误
    /// （`-swift-version 5` 只报 ActorIsolatedCall 警告，别等到换语言模式才炸）。
    @discardableResult
    nonisolated static func resetOwnRecord() -> Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else {
            Log.write("[keysound] 无 bundle id，跳过授权记录重置")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ListenEvent", id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            Log.write("[keysound] 已重置「输入监控」授权记录（\(id)）：\(ok ? "成功" : "失败")")
            return ok
        } catch {
            Log.write("[keysound] 重置授权记录失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 授权状态可能变了，重新收敛一次。没有变化时 `apply` 是幂等的。
    private func recheckAccess() {
        guard let settings = boundSettings else { return }
        apply(settings)
    }

    /// 授权之后仍然不响时要说的那句话。
    ///
    /// 「输入监控」和别的权限不一样：**授权后必须重启应用才生效**。
    /// 系统自己的对话框会提示「退出并重新打开」，但用户从系统设置里直接勾选时
    /// 看不到那句话，只会觉得「我明明授权了还是没声音」。
    static let restartHint =
        "在系统设置里勾选之后，需要退出并重新打开 MagicKey 才会生效——"
        + "这是「输入监控」权限的固有行为，不是设置没保存。"

    /// 「系统设置里明明是打开的，应用却说没授权」时要说的那句话。
    ///
    /// 这一态**最像 bug**，也最容易让人在开关上来回点：系统那条授权记录绑的是
    /// 授权当时的代码签名，MagicKey 每次重新构建/更新签名都会变，旧记录随之失效，
    /// 但设置界面照旧把它画成打开的。
    static let staleHint =
        "系统里那条授权记录绑的是授权当时的应用签名，MagicKey 更新后就对不上了，"
        + "而设置界面仍然把它显示成打开的。点这里会清掉这条旧记录并重新申请授权，"
        + "之后需要重新打开一次 MagicKey。"

    // MARK: - 收敛

    /// 弱持有一份设置，`recheckAccess` 要用。生命周期由 `AppDelegate` 管，
    /// 这里只是不想让每个重查入口都去要一次参数。
    private weak var boundSettings: Settings?

    /// 由 `AppDelegate.syncFromSettings` 调用，幂等。
    func apply(_ settings: Settings) {
        boundSettings = settings

        guard settings.keySoundEnabled else {
            teardown()
            status = .off
            return
        }

        guard Self.accessGranted() else {
            // **未授权的降级路径：什么都不装。** 不装 monitor（装了也收不到事件，
            // 只会在系统里留一条「这个 app 想监听输入」的记录）、不起音频引擎、
            // 不开定时器。这一态下本功能的运行时开销严格为零。
            teardown()
            // 请求过一次还是不放行 → `.blocked`，**不能停在 `.requesting`**：
            // 那一态的按钮只会再把系统设置打开一次，而设置里的开关看着是好的，
            // 用户就卡死在「等待授权」上出不来了。
            status = didRequestAccess ? .blocked : .needsPermission
            return
        }

        // 现在授权了，但启动时没有 → 这一份授权对本进程无效。**同样什么都不装**：
        // 装上去的 monitor 一个事件都收不到，只会让面板亮起绿灯骗人。
        // 理由见 `grantedAtLaunch`。
        guard Self.grantedAtLaunch else {
            teardown()
            status = .needsRestart
            return
        }

        player.load(KeySoundPack.named(settings.keySoundPack))
        refreshCustomLayer(settings)
        player.setVolume(settings.keySoundVolume)
        #if UI_PROBE
        // 探针里静音：要走的是完整的真实路径（装 monitor、起引擎、排 buffer），
        // 但不该在开发者跑回归测试的时候真的出声。
        if Self.probeAccessOverride != nil { player.setVolume(0) }
        #endif
        installMonitors()
        player.start()
        status = .running
    }

    /// 退出路径。和 `Engine.shutdown` 一样必须同步做完。
    func shutdown() {
        teardown()
        status = .off
    }

    private func teardown() {
        removeMonitors()
        player.stop()
        // 自定义采样也一并放掉。功能关着/没授权时本功能的运行时开销要严格为零，
        // 内存也算在内——一条 2 秒的采样解码后是三份 700KB 的 buffer。
        loadedCustom = nil
        player.setCustom(nil)
    }

    /// 按音色库的当前内容重建自定义层。幂等。
    ///
    /// 库或指键一变就要调（`AppDelegate` 订阅了 `CustomSoundStore`），
    /// 否则用户在键盘图上点完，得关掉再打开开关才生效。
    private func refreshCustomLayer(_ settings: Settings) {
        // 总开关关掉、或者一个键都没指 → 整层不存在。
        // 「没指键」这一支很重要：绝大多数用户永远不会用这个功能，
        // 他们不该为此多出任何一次解码或一层查表。
        guard settings.keySoundCustomEnabled, !customStore.assignments.isEmpty else {
            loadedCustom = nil
            player.setCustom(nil)
            return
        }
        let layer = LoadedCustomSounds(entries: customStore.entries,
                                       assignments: customStore.assignments,
                                       directory: customStore.directory,
                                       format: KeySoundPlayer.format,
                                       previous: loadedCustom)
        loadedCustom = layer
        player.setCustom(layer)
    }

    // MARK: - 事件监听

    /// **两个 monitor 都要装。**
    ///   - global：别的 app 在前台时的按键，也就是绝大多数情况
    ///   - local：本应用自己的窗口（面板里的亮度输入框、设置窗口）收到的按键。
    ///     global monitor **收不到自己进程的事件**，只装它的话「点开面板打字没声音」。
    ///
    /// 用 `NSEvent` 而不是 `CGEventTap`：两者都要「输入监控」授权，但 event tap
    /// 是**同步插在事件流里**的，回调慢了会拖慢整个系统的按键响应，而且被系统
    /// 判定超时后会被静默禁用（还得自己监听 `tapDisabled` 再启用）。
    /// 这个功能只需要**旁观**，不需要修改或吞掉事件，没有理由付那份风险。
    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

        // 装的这一刻用户可能正按着 Shift。不种下当前值的话，第一次
        // flagsChanged（松开 Shift）会被算成「按下」，凭空多一声。
        lastFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event        // 只是旁观，必须原样放行
        }
        Log.write("[keysound] 已安装按键监听（global=\(globalMonitor != nil) local=\(localMonitor != nil)）")
    }

    private func removeMonitors() {
        for m in [globalMonitor, localMonitor] where m != nil {
            NSEvent.removeMonitor(m!)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    /// 时间戳要在**函数第一行**取。晚一点取都会把本函数自己的耗时算漏，
    /// 而这条链上要量的正是「事件到手之后我们花了多久」。
    private func handle(_ event: NSEvent) {
        let arrival = CFAbsoluteTimeGetCurrent()
        switch event.type {
        case .keyDown:
            // **忽略自动重复。** 内核按 83.6ms（本机实测）重复投递 keyDown，
            // 而真实键盘按住一个键只有最初那一声。不滤掉的话按住退格
            // 就是一串连珠炮，比不做这个功能还糟。
            guard !event.isARepeat else { return }
            player.play(KeySoundSlot(keyCode: event.keyCode), isDown: true,
                        keyCode: event.keyCode, arrival: arrival)

        case .keyUp:
            player.play(KeySoundSlot(keyCode: event.keyCode), isDown: false,
                        keyCode: event.keyCode, arrival: arrival)

        case .flagsChanged:
            handleFlagsChanged(event, arrival: arrival)

        default:
            break
        }
    }

    /// 只跟这六个真实的修饰键。`deviceIndependentFlagsMask` 里还有
    /// `.numericPad` 和 `.help`，但那两个是**按键的属性**（按方向键时会带上），
    /// 不对应任何一个能被按下的键——跟着它们走会在敲方向键时多出一声。
    private static let trackedFlags: [NSEvent.ModifierFlags] =
        [.shift, .control, .option, .command, .capsLock, .function]

    private func handleFlagsChanged(_ event: NSEvent, arrival: CFAbsoluteTime) {
        let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let changed = now.symmetricDifference(lastFlags)
        lastFlags = now
        guard !changed.isEmpty else { return }

        for flag in Self.trackedFlags where changed.contains(flag) {
            // Caps Lock 是**锁定键**：按下点亮、松开不发事件，再按一次才熄灭。
            // 按位推断的话「熄灭」那一次会被算成抬起，于是两次按键听起来不一样。
            // 它每次都是一次完整的按下，所以固定给按下音。
            let isDown = flag == .capsLock ? true : now.contains(flag)
            // **把真实键码带下去。** 这里原先只报 `.generic`，于是修饰键
            // 在自定义层里是查不到的。左右 Shift / Option / Command 的键码不同
            // （kVK_Shift=0x38 而 kVK_RightShift=0x3C），带上之后可以分别指音——
            // 而槽位仍然给 `.generic`：音色包本来就没有修饰键的专属录音。
            player.play(.generic, isDown: isDown, keyCode: event.keyCode, arrival: arrival)
        }
    }

    // MARK: - 展示

    /// 色点颜色，和 `AudioStatusModel.tint` 同一套语义
    var tint: Tint {
        switch status {
        case .running:                     return .good
        case .off:                         return .neutral
        case .needsPermission, .requesting: return .warn
        case .blocked:                     return .warn
        case .needsRestart:                return .warn
        case .failed:                      return .bad
        }
    }

    enum Tint { case good, neutral, warn, bad }

    var summary: String {
        switch status {
        case .off:             return "未启用"
        case .needsPermission: return "需要「输入监控」权限"
        case .requesting:      return "正在请求「输入监控」授权…"
        // 「等待授权」这种说法在这一态是骗人的：系统那边**已经有答复了，就是不放行**。
        // 而最常见的成因（旧记录失效）恰好长得和「设置里已经打开」一模一样，
        // 所以这句话必须把那个矛盾直接点出来，否则用户只会反复去开关那个开关。
        case .blocked:         return "系统未放行 · 设置里已开启则是旧记录失效"
        // 措辞要同时说清「你没做错」和「还差一步」——这一态最容易被当成 bug
        case .needsRestart:    return "已授权 · 退出并重新打开 MagicKey 后生效"
        case .failed(let why): return "音效未能启动：\(why)"
        case .running:         return "响应中"
        }
    }

    /// 这一态要不要给个动作按钮，给什么
    var action: Action? {
        switch status {
        case .needsPermission: return .grant
        case .blocked:         return .regrant
        case .requesting:      return nil
        case .needsRestart:    return .restart
        default:               return nil
        }
    }

    enum Action { case grant, regrant, openSettings, restart }

    // MARK: - 探针

    #if UI_PROBE
    /// **只在 UI 探针里编译。** 覆盖 `accessGranted()` 的返回值，
    /// 好让「未授权时不装 monitor」这条降级路径变成可回归的。
    ///
    /// 不能靠真实的 TCC 状态来测：探针是从终端起的裸可执行文件，TCC 把它算在
    /// **终端**头上，于是 `IOHIDCheckAccess` 会返回终端的授权结果（本机实测是
    /// 已授权），永远测不到「被拒绝」那一支。
    static var probeAccessOverride: Bool?

    /// **只在 UI 探针里编译。** 直接摆布「启动时的授权结果」。
    ///
    /// `launchAccess` 是进程级的静态量，正常只在 `init()` 里落一次；
    /// 探针要在一次运行里同时测「启动就有授权」和「启动时没有、跑起来才给」
    /// 两条分支，就必须能逐步重设它。
    static func setProbeLaunchAccess(_ v: Bool?) { launchAccess = v }

    var probeIsListening: Bool { globalMonitor != nil || localMonitor != nil }
    var probeEngineIsRunning: Bool { player.isRunning }
    /// 「总开关关掉 → 自定义层整个旁路」这条线是收敛逻辑，不是播放逻辑，
    /// 所以判据要落在 controller 上，不能只测 player
    var probeCustomIsLoaded: Bool { player.probeCustomIsLoaded }
    var probePlayer: KeySoundPlayer { player }

    /// 面板五态用。真实路径下 status 由 `apply` 收敛，探针要直接摆状态看外观。
    func setProbeStatus(_ s: KeySoundStatus) { status = s }

    /// 摆布「请求过没有」。`.blocked` 只在请求过之后才可能出现，
    /// 不能注入这个就测不到那一支。
    func setProbeDidRequest(_ v: Bool) { didRequestAccess = v }
    #endif
}
