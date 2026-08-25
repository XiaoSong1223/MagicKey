import AppKit
import os

/// 单实例保护，以及全应用共用的那个 `os.Logger`。
///
/// ## 为什么第二个实例不是「多开一个窗口」而是数据损坏
///
/// 这个应用有两样东西是**全机唯一**的，不是进程内唯一：
///
///   - 键盘背光那个 0–255 的全局亮度寄存器。`Driver` 的串行队列只保证
///     **进程内**单一写入者；两个进程各跑一个 60Hz 循环，就是两个写入者在抢，
///     谁也不知道最后一帧是谁写的。
///   - `~/Library/Application Support/MagicKey/app-snapshot.json`。
///     `StateGuard` 的快照路径由 `namespace` 决定（app 恒传 "app"），
///     两个实例用的是**同一个文件**。
///
/// 第二样才是真正的损坏：后启动的那个在 `Engine.init` 里就会跑
/// `recoverFromPreviousCrashIfNeeded()`——它看见磁盘上有快照，于是断定
/// 「上次没干净退出」，把系统还原成那份快照**并把文件删掉**。
/// 而那份快照属于**正在正常运行的第一个实例**。此后第一个实例退出时
/// 无文件可依，用户的原始亮度/环境光设置就永久丢了。
///
/// 所以检查必须发生在 `AppDelegate()` 之前——`Engine()` 是 `AppDelegate`
/// 的存储属性，构造函数体还没开始跑，破坏就已经发生了。
///
/// 撞得到的实际路径不是「用户双击两次」（LaunchServices 会拦），而是
/// **`/Applications` 里那份正开着，同时在源码树里 `make run`**。
/// `make install` 里有 `pkill -x MagicKey` 所以那条路径一直没暴露这个问题。
enum AppInstance {

    /// 全应用唯一的日志出口。
    ///
    /// **不能用 NSLog**：它的动态内容在统一日志里被标成 `<private>`，
    /// `log stream/show` 按内容过滤一条都查不到，装好的 app 等于没有日志。
    /// 查日志用：
    ///   log stream --predicate 'subsystem == "io.github.xiaosong1223.MagicKey"'
    static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.xiaosong1223.MagicKey",
        category: "app")

    /// 同 bundle id 的另一个实例正在跑吗。
    ///
    /// **这一步不能有任何副作用**：不 capture 快照、不碰 `StateGuard`、
    /// 不建 `Engine`、不装状态栏项。它跑在 `NSApplication.shared` 之后、
    /// `AppDelegate()` 之前，那时进程还什么都没接管，直接 `exit` 是干净的。
    ///
    /// 拿不到 bundle id（UI 探针那种裸可执行文件）就直接放行——那种进程本来
    /// 也不接管键盘、不写快照，拦它没有意义。
    static func anotherIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        // 按 pid 排掉自己：本进程这时多半已经登记进 LaunchServices 了，
        // 不排的话每次启动都会认为「已有实例在跑」然后自杀。
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine }
        guard !others.isEmpty else { return false }

        let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
        let why = "[instance] 已有 MagicKey 在运行（pid \(pids)），本次启动直接退出。"
            + "两个实例会抢同一个亮度寄存器，后启动的那个还会把前一个的崩溃快照还原并删除。"
        logger.notice("\(why, privacy: .public)")
        // **统一日志和 stderr 都要写。** 这一步发生在 `Log.sink` 被接管之前，
        // 而它的两个受众在两个地方：装好的 app 只有统一日志；
        // 而开发时是 `make run`（直接跑 bundle 里的可执行文件，日志打终端）——
        // 那条路径下进程会**一声不响地立刻退出**，不给 stderr 就完全没法理解。
        FileHandle.standardError.write(Data((why + "\n").utf8))
        // 把已经在跑的那个拿到前台：用户多半就是想打开它。
        // 本应用是 `.accessory`，激活的效果是菜单栏图标那边可以被点，
        // 不会凭空弹出窗口。
        others.first?.activate()
        return true
    }
}
