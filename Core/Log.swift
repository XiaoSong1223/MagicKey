import Foundation

/// Core 层的日志出口。默认写 stderr；宿主可替换成带时间戳的 stdout（原型）
/// 或环形缓冲供 UI 展示（app）。
///
/// Core 不该知道自己被谁用，所以这里只留一个可替换的 sink。
enum Log {
    nonisolated(unsafe) static var sink: (String) -> Void = { msg in
        FileHandle.standardError.write(("[magickey] " + msg + "\n").data(using: .utf8)!)
    }

    static func write(_ msg: String) { sink(msg) }
}
