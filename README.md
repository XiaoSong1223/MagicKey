<div align="center">
  <img src="app/Resources/AppIcon-1024.png" width="180" height="180" alt="MagicKey 应用图标">
  <h1>MagicKey</h1>
  <p>让 MacBook 内置键盘背光随呼吸、敲击与音乐流动。</p>
  <p>
    <img src="https://img.shields.io/badge/version-v0.4-B8D2FF?style=flat-square" alt="版本 v0.4">
    <img src="https://img.shields.io/badge/macOS-14%2B-171A20?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-required-303640?style=flat-square&logo=apple&logoColor=white" alt="需要 Apple Silicon">
    <img src="https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-F4F7FF?style=flat-square" alt="MIT License"></a>
  </p>
</div>

MagicKey 是一款轻量的 macOS 菜单栏工具，为 MacBook 内置键盘背光提供常亮、呼吸、心跳、频闪、按键脉冲和音乐律动效果。亮度、速度、静息亮度与音乐灵敏度均可调节；应用停止或正常退出时会立即恢复接管前的状态，异常中断留下的状态则会在下次启动时恢复。

## 安装

### 下载发行包

从 [Releases](https://github.com/XiaoSong1223/MagicKey/releases/latest) 下载 `MagicKey-<版本>.zip`，解压后把 `MagicKey.app` 拖进 `/Applications`。

发行包只做了本地 ad-hoc 签名，未经 Developer ID 公证，首次打开会被 Gatekeeper 拦下。解除隔离属性后即可正常启动：

```bash
xattr -dr com.apple.quarantine /Applications/MagicKey.app
```

也可以在“系统设置 → 隐私与安全性”中找到被拦截的提示并选择“仍要打开”。

### 从源码构建

需要先安装 Xcode Command Line Tools：

```bash
xcode-select --install
git clone https://github.com/XiaoSong1223/MagicKey.git
cd MagicKey
make -C app install
```

`make install` 会构建应用、进行本地 ad-hoc 签名、复制到 `/Applications`，然后启动 MagicKey。启动后点击菜单栏中的键帽图标即可设置效果。

卸载应用：

```bash
make -C app uninstall
```

卸载前请先在 MagicKey 中关闭“开机自动启动”。卸载命令只移除 `/Applications/MagicKey.app`，不会删除已有偏好设置。

> [!NOTE]
> 当前尚未提供 Homebrew cask，发行包也未进行 Developer ID 公证。正式分发流程仍在完善中。

## 功能

### 六种背光效果

| 模式 | 表现 |
| --- | --- |
| 常亮 | 将整块键盘保持在指定亮度 |
| 呼吸 | 在最暗与最亮之间平滑往返 |
| 心跳 | 模拟一强一弱的双脉冲节奏 |
| 频闪 | 以可调周期快速明暗切换 |
| 按键 | 每次敲键时让整块键盘闪出一道脉冲 |
| 音乐 | 识别系统播放声音中的鼓点并驱动背光 |

### 自动化与状态保护

- 调节亮度、速度、最暗亮度、脉冲时长和音乐灵敏度
- 默认以 60fps 渲染，也可切换到 30fps 低帧率模式
- 睡眠、锁屏、息屏或切换用户时自动停止，恢复使用后自动继续
- 默认在 120 秒无输入且没有音频播放时暂停，避免后台持续刷新
- 支持登录时自动启动；签名或安装位置不符合系统要求时会在界面中显示错误
- 作为纯菜单栏应用运行，不占用 Dock 位置
- 接管前保存亮度、环境光自动调节和闲置调暗设置，停止时按正确顺序恢复
- 异常退出后在下次启动时检测残留快照并先行恢复

### 菜单栏状态

| 图标 | 状态 |
| --- | --- |
| 线框键帽 | MagicKey 已停止，或因锁屏、息屏、空闲而暂时停止 |
| 实心键帽 | 背光效果正在运行 |

图标使用 macOS Template 资源，会自动适配浅色、深色、选中与高对比度菜单栏。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon MacBook
- 带背光的内置键盘
- 音乐律动需要 macOS 14.2 或更高版本

MagicKey 面向 MacBook 内置键盘背光；外接键盘不在支持范围内。

## 硬件限制

> [!IMPORTANT]
> MagicKey 不能改变背光颜色，也不能单独控制某一枚按键。MacBook 内置键盘的全部 LED 共用一路全局亮度通道，因此所有效果都会作用于整块键盘。

这不是权限或驱动层面的限制。`root`、内核驱动或私有 API 都无法产生硬件不存在的 RGB 与逐键控制能力。更完整的实测结论、量化约束和设计取舍见 [DESIGN.md](DESIGN.md)。

## 权限与隐私

| 功能 | 权限或网络行为 | 数据处理方式 |
| --- | --- | --- |
| 常亮、呼吸、心跳、频闪 | 无额外权限 | 只写入键盘的全局亮度值 |
| 按键脉冲 | 不需要“输入监控” | 只读取全局按键事件计数与距最近事件的时间，不读取 keycode 或输入内容 |
| 音乐律动 | 需要“系统录音”，不是“麦克风” | 音频仅在内存中换算为低频能量与鼓点事件，随即丢弃 |
| 更新检查 | 启动时访问一次 GitHub Releases API，之后最多每 24 小时一次 | User-Agent 只包含应用名和版本，不发送设备标识或使用数据 |

MagicKey 不录音、不写入音频文件、不上传声音、不包含遥测，也不发送崩溃报告。关闭“自动检查更新”后不会再自动联网；用户主动点击“检查更新”时仍会访问 GitHub。

音乐律动的权限位置：

```text
系统设置 → 隐私与安全性 → 系统录音
```

## 工作原理

MagicKey 通过运行时加载 `CoreBrightness.framework`，调用 `KeyboardBrightnessClient` 读写内置键盘的 0–255 全局亮度。应用不会静态链接私有框架，而是使用 `dlopen` 和 selector 探测；接口不可用时会在界面中显示“不受支持”，而不是崩溃。由于这是私有接口，未来的 macOS 更新仍可能改变其行为。

背光接管由 `StateGuard` 管理：启动效果前保存原始状态，运行期间暂停环境光自动调节与闲置调暗，停止时恢复原有设置。整个过程不需要 `root`。

由于使用了私有系统接口，MagicKey 不能通过 Mac App Store 分发。

## 常见问题

### 为什么按键脉冲不能从按下的键向外扩散？

硬件只暴露一个全局亮度值，系统没有逐键灯光通道。MagicKey 也不读取具体键值，因此按键脉冲只能让整块键盘一起变化。

### 为什么音乐模式需要“系统录音”权限？

音乐模式需要读取 Mac 当前正在播放的系统声音，才能检测低频能量和鼓点。它不使用麦克风，也不会保存或传输音频。

### 为什么低亮度时偶尔能看出档位？

键盘背光是 8 位控制量：`0...255`，共 256 个离散亮度值。60fps 已接近硬件量化下限；提高最暗亮度通常比继续提高帧率更有效。详细测量见 [DESIGN.md](DESIGN.md)。

### 为什么不发布到 Mac App Store？

App Store 不允许使用 MagicKey 所依赖的私有 `CoreBrightness` 接口。项目需要通过独立构建或未来的签名发行包分发。

## 从源码开发

项目不使用 SwiftPM；应用通过 `swiftc` 和 Makefile 手工组装 `.app` bundle，当前没有第三方运行时依赖。

```bash
make -C app          # Release 构建
make -C app debug    # 带调试信息的构建
make -C app run      # 在终端运行并查看日志
make -C app clean    # 清理产物
```

项目结构：

```text
Core/       驱动、状态托管、效果模型与音频/按键脉冲源
app/        SwiftUI 菜单栏应用、资源和手工构建脚本
tools/      效果曲线分析与能耗测试工具
DESIGN.md   架构、硬件实测与设计约束
```

测试与分析工具的使用方式见 [tools/README.md](tools/README.md) 与 [tools/TESTING.md](tools/TESTING.md)。

## Roadmap

- CLI 与 URL Scheme 触发
- Developer ID 签名、公证与稳定的发行包
- 在真实设备与更多 macOS 版本上持续验证私有接口兼容性

## 参与贡献

欢迎提交 [Issue](https://github.com/XiaoSong1223/MagicKey/issues) 或 Pull Request。涉及效果曲线、状态恢复或硬件行为的修改，请先阅读 [DESIGN.md](DESIGN.md) 中的实测约束。

## License

MagicKey 使用 [MIT License](LICENSE)。
