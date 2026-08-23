import Foundation

/// 键盘图上的一个键。
///
/// 几何用**键位单位**（1 = 一个标准字母键的宽），不用点：窗口可以缩放，
/// 布局表不该跟着变。画的时候乘一个 `unit` 就行。
struct KeyCap: Identifiable, Hashable {
    /// macOS 虚拟键码。这是指键表的主键，也是事件里唯一拿得到的身份
    let keyCode: UInt16
    /// 画在键帽上的字
    let label: String
    /// 说给人听的名字。左右修饰键的键帽长得一模一样，只有这里能区分
    let name: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    var id: UInt16 { keyCode }
}

/// MacBook 内置键盘（ANSI）的静态布局。
///
/// ## 键码从哪来
///
/// 全部取自 SDK 头文件里的 `kVK_*`，逐个核对过，**不是凭记忆写的**：
///
/// ```
/// $(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/Carbon.framework\
///   /Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
/// ```
///
/// 这件事非核对不可：这批常量**不是按字母或数字顺序排的**，
/// 相邻的字母键键码能差出几十（A=0x00 而 B=0x0B），
/// 数字键里 5 和 6 是反的（5=0x17、6=0x16），
/// 凭印象写出来的表会「大部分键是对的」——那正是最难发现的错法。
/// 注释里保留 `kVK_` 名字，下次核对时能直接对着头文件扫一遍。
///
/// ## 画了什么、没画什么
///
/// - **Touch ID 不画**：它不产生按键事件，画出来就是一个点了没反应的键。
/// - **左右修饰键分开画**：Shift / Control / Option / Command 的左右键码不同
///   （如 kVK_Shift=0x38、kVK_RightShift=0x3C），可以分别指音。
/// - **右 Control 不画**：MacBook 内置键盘上没有这个键。
/// - **F1–F12 画了，但系统可能吃掉**：若「将 F1、F2 等键用作标准功能键」没打开，
///   直接按下去发的是亮度/音量之类的系统事件，不是 keyDown，指键不会响。
///   这一条在窗口里对用户说明了。
enum KeyboardLayout {

    /// 画布尺寸（键位单位）。每一行都精确等于 15 个单位宽——
    /// 探针会验这件事（矩形不许越界、不许重叠），改宽度时它会当场报出来。
    static let unitsWide: Double = 15
    static let unitsHigh: Double = 5.75

    private struct Spec {
        let code: UInt16
        let label: String
        let name: String
        let w: Double
        init(_ code: UInt16, _ label: String, _ name: String? = nil, _ w: Double = 1) {
            self.code = code
            self.label = label
            self.name = name ?? label
            self.w = w
        }
    }

    /// 从左往右依次摆开，宽度自己累加——手写 77 个 x 坐标必然会写错一个
    private static func row(y: Double, h: Double = 1, _ specs: [Spec]) -> [KeyCap] {
        var x = 0.0
        return specs.map { spec in
            defer { x += spec.w }
            return KeyCap(keyCode: spec.code, label: spec.label, name: spec.name,
                          x: x, y: y, w: spec.w, h: h)
        }
    }

    static let keys: [KeyCap] = {
        var all: [KeyCap] = []

        // 功能键排。esc 1.5u + 12 × 1.125u = 15u
        all += row(y: 0, h: 0.75, [
            Spec(53, "esc", "Esc", 1.5),        // kVK_Escape        0x35
            Spec(122, "F1", nil, 1.125),        // kVK_F1            0x7A
            Spec(120, "F2", nil, 1.125),        // kVK_F2            0x78
            Spec(99,  "F3", nil, 1.125),        // kVK_F3            0x63
            Spec(118, "F4", nil, 1.125),        // kVK_F4            0x76
            Spec(96,  "F5", nil, 1.125),        // kVK_F5            0x60
            Spec(97,  "F6", nil, 1.125),        // kVK_F6            0x61
            Spec(98,  "F7", nil, 1.125),        // kVK_F7            0x62
            Spec(100, "F8", nil, 1.125),        // kVK_F8            0x64
            Spec(101, "F9", nil, 1.125),        // kVK_F9            0x65
            Spec(109, "F10", nil, 1.125),       // kVK_F10           0x6D
            Spec(103, "F11", nil, 1.125),       // kVK_F11           0x67
            Spec(111, "F12", nil, 1.125),       // kVK_F12           0x6F
        ])

        // 数字排。13 × 1u + 退格 2u = 15u
        all += row(y: 0.75, [
            Spec(50, "`", "反引号"),             // kVK_ANSI_Grave    0x32
            Spec(18, "1"),                       // kVK_ANSI_1       0x12
            Spec(19, "2"),                       // kVK_ANSI_2       0x13
            Spec(20, "3"),                       // kVK_ANSI_3       0x14
            Spec(21, "4"),                       // kVK_ANSI_4       0x15
            Spec(23, "5"),                       // kVK_ANSI_5       0x17 ← 和 6 是反的
            Spec(22, "6"),                       // kVK_ANSI_6       0x16
            Spec(26, "7"),                       // kVK_ANSI_7       0x1A
            Spec(28, "8"),                       // kVK_ANSI_8       0x1C
            Spec(25, "9"),                       // kVK_ANSI_9       0x19
            Spec(29, "0"),                       // kVK_ANSI_0       0x1D
            Spec(27, "-", "减号"),               // kVK_ANSI_Minus   0x1B
            Spec(24, "=", "等号"),               // kVK_ANSI_Equal   0x18
            Spec(51, "⌫", "删除", 2),            // kVK_Delete       0x33
        ])

        // QWERTY 排。tab 1.5u + 12 × 1u + 反斜杠 1.5u = 15u
        all += row(y: 1.75, [
            Spec(48, "⇥", "Tab", 1.5),           // kVK_Tab          0x30
            Spec(12, "Q"),                       // kVK_ANSI_Q       0x0C
            Spec(13, "W"),                       // kVK_ANSI_W       0x0D
            Spec(14, "E"),                       // kVK_ANSI_E       0x0E
            Spec(15, "R"),                       // kVK_ANSI_R       0x0F
            Spec(17, "T"),                       // kVK_ANSI_T       0x11
            Spec(16, "Y"),                       // kVK_ANSI_Y       0x10
            Spec(32, "U"),                       // kVK_ANSI_U       0x20
            Spec(34, "I"),                       // kVK_ANSI_I       0x22
            Spec(31, "O"),                       // kVK_ANSI_O       0x1F
            Spec(35, "P"),                       // kVK_ANSI_P       0x23
            Spec(33, "[", "左方括号"),           // kVK_ANSI_LeftBracket  0x21
            Spec(30, "]", "右方括号"),           // kVK_ANSI_RightBracket 0x1E
            Spec(42, "\\", "反斜杠", 1.5),       // kVK_ANSI_Backslash    0x2A
        ])

        // 主排。大写锁定 1.75u + 11 × 1u + 回车 2.25u = 15u
        all += row(y: 2.75, [
            Spec(57, "⇪", "大写锁定", 1.75),      // kVK_CapsLock     0x39
            Spec(0,  "A"),                       // kVK_ANSI_A       0x00
            Spec(1,  "S"),                       // kVK_ANSI_S       0x01
            Spec(2,  "D"),                       // kVK_ANSI_D       0x02
            Spec(3,  "F"),                       // kVK_ANSI_F       0x03
            Spec(5,  "G"),                       // kVK_ANSI_G       0x05 ← 和 H 是反的
            Spec(4,  "H"),                       // kVK_ANSI_H       0x04
            Spec(38, "J"),                       // kVK_ANSI_J       0x26
            Spec(40, "K"),                       // kVK_ANSI_K       0x28
            Spec(37, "L"),                       // kVK_ANSI_L       0x25
            Spec(41, ";", "分号"),               // kVK_ANSI_Semicolon 0x29
            Spec(39, "'", "引号"),               // kVK_ANSI_Quote     0x27
            Spec(36, "⏎", "回车", 2.25),         // kVK_Return         0x24
        ])

        // ZXCV 排。左 Shift 2.25u + 10 × 1u + 右 Shift 2.75u = 15u
        all += row(y: 3.75, [
            Spec(56, "⇧", "左 Shift", 2.25),      // kVK_Shift        0x38
            Spec(6,  "Z"),                       // kVK_ANSI_Z       0x06
            Spec(7,  "X"),                       // kVK_ANSI_X       0x07
            Spec(8,  "C"),                       // kVK_ANSI_C       0x08
            Spec(9,  "V"),                       // kVK_ANSI_V       0x09
            Spec(11, "B"),                       // kVK_ANSI_B       0x0B
            Spec(45, "N"),                       // kVK_ANSI_N       0x2D
            Spec(46, "M"),                       // kVK_ANSI_M       0x2E
            Spec(43, ",", "逗号"),               // kVK_ANSI_Comma   0x2B
            Spec(47, ".", "句号"),               // kVK_ANSI_Period  0x2F
            Spec(44, "/", "斜杠"),               // kVK_ANSI_Slash   0x2C
            Spec(60, "⇧", "右 Shift", 2.75),      // kVK_RightShift   0x3C
        ])

        // 底排的左半段。fn 1 + ⌃ 1 + ⌥ 1 + ⌘ 1.25 + 空格 5.5 + ⌘ 1.25 + ⌥ 1 = 12u
        all += row(y: 4.75, [
            Spec(63, "fn", "fn / 地球键"),        // kVK_Function     0x3F
            Spec(59, "⌃", "左 Control"),          // kVK_Control      0x3B
            Spec(58, "⌥", "左 Option"),           // kVK_Option       0x3A
            Spec(55, "⌘", "左 Command", 1.25),    // kVK_Command      0x37
            Spec(49, "", "空格", 5.5),            // kVK_Space        0x31
            Spec(54, "⌘", "右 Command", 1.25),    // kVK_RightCommand 0x36
            Spec(61, "⌥", "右 Option"),           // kVK_RightOption  0x3D
        ])

        // 方向键的倒 T。剩下的 3u（x=12…15）。
        // ← ↓ → 是半高、贴着底边，↑ 半高压在 ↓ 上面——MacBook 就长这样，
        // 画成四个满高的键会让整张图一眼就不像自己的键盘。
        all += [
            KeyCap(keyCode: 123, label: "←", name: "左箭头",  // kVK_LeftArrow  0x7B
                   x: 12, y: 5.25, w: 1, h: 0.5),
            KeyCap(keyCode: 126, label: "↑", name: "上箭头",  // kVK_UpArrow    0x7E
                   x: 13, y: 4.75, w: 1, h: 0.5),
            KeyCap(keyCode: 125, label: "↓", name: "下箭头",  // kVK_DownArrow  0x7D
                   x: 13, y: 5.25, w: 1, h: 0.5),
            KeyCap(keyCode: 124, label: "→", name: "右箭头",  // kVK_RightArrow 0x7C
                   x: 14, y: 5.25, w: 1, h: 0.5),
        ]
        return all
    }()

    static func key(for keyCode: UInt16) -> KeyCap? {
        keys.first { $0.keyCode == keyCode }
    }
}
