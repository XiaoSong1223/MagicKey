import Foundation

/// 系统原始状态快照。持久化到磁盘，用于崩溃后恢复。
struct BacklightSnapshot: Codable {
    var brightness: Float
    var autoBrightnessEnabled: Bool
    var idleDimTime: Double
    var capturedAt: Date
    var pid: Int32
}

/// 负责「进来什么样，出去还什么样」。
///
/// 这是最容易做砸也最影响信任的部分——键盘卡在诡异亮度是这类工具最典型的差评来源。
/// 六个还原时机：正常退出 / 手动停止 / 崩溃后重启 / 睡眠 / SIGINT / SIGTERM。
final class StateGuard {

    private let driver: BacklightDriver
    private var snapshot: BacklightSnapshot?
    private var restored = false
    private let lock = NSLock()

    private let snapshotURL: URL

    /// - Parameter namespace: 快照文件名前缀。原型和正式 app 是两个独立进程，
    ///   必须用不同的快照，否则一方的崩溃恢复会误还原另一方的状态。
    init(driver: BacklightDriver, namespace: String) {
        self.driver = driver
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.snapshotURL = dir.appendingPathComponent("\(namespace)-snapshot.json")
    }

    // MARK: - 崩溃恢复

    /// 启动时调用。磁盘上还留着快照 = 上次没干净退出，先还原再继续。
    func recoverFromPreviousCrashIfNeeded() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let stale = try? JSONDecoder().decode(BacklightSnapshot.self, from: data) else {
            return
        }
        let ago = Int(Date().timeIntervalSince(stale.capturedAt))
        Log.write("检测到上次未干净退出（pid=\(stale.pid), \(ago)s 前），先还原原始状态")
        apply(stale)
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    // MARK: - 快照与还原

    func capture() {
        let snap = BacklightSnapshot(
            brightness: driver.readBrightness(),
            autoBrightnessEnabled: driver.readAutoBrightness(),
            idleDimTime: driver.readIdleDimTime(),
            capturedAt: Date(),
            pid: ProcessInfo.processInfo.processIdentifier
        )
        lock.lock(); snapshot = snap; restored = false; lock.unlock()

        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: snapshotURL, options: .atomic)
        }
        Log.write(String(format: "已保存原始状态: brightness=%.3f auto=%@ idleDim=%.1f",
                   snap.brightness,
                   snap.autoBrightnessEnabled ? "on" : "off",
                   snap.idleDimTime))
    }

    /// 接管：关掉会和动画打架的系统行为。
    ///
    /// 环境光自动调节默认开启，不关掉它会持续覆盖引擎的输出（实测结论 F5）。
    func takeOver() {
        driver.writeAutoBrightness(false)
        driver.suspendIdleDimming(true)
        Log.write("已接管: 环境光自动调节 off, 闲置调暗已挂起")
    }

    /// 幂等——多个还原时机可能同时触发，只生效一次。
    func restore(reason: String) {
        lock.lock()
        guard !restored, let snap = snapshot else { lock.unlock(); return }
        restored = true
        lock.unlock()

        Log.write("还原原始状态（触发原因: \(reason)）")
        apply(snap)
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private func apply(_ snap: BacklightSnapshot) {
        driver.suspendIdleDimming(false)
        driver.writeIdleDimTime(snap.idleDimTime)
        // 亮度必须最后写：若先恢复环境光自动调节，它会抢在写入之后再调一档，
        // 用户看到的就不是自己原来的亮度了（实测差 1/255）。
        driver.writeBrightness(snap.brightness)
        driver.writeAutoBrightness(snap.autoBrightnessEnabled)
    }

    /// 还原是否精确——原型验收的四项指标之一。
    func verifyRestoration() -> (expected: Float, actual: Float, exact: Bool)? {
        guard let snap = snapshot else { return nil }
        let actual = driver.readBrightness()
        // 8bit 量化下，同档即算精确
        let exact = Int((snap.brightness * 255).rounded()) == Int((actual * 255).rounded())
        return (snap.brightness, actual, exact)
    }
}
