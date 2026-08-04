# MagicKey.app — 菜单栏应用 v0.1

```bash
make          # 构建 MagicKey.app
make run      # 直接跑 bundle 内的可执行文件，日志打到终端（调试用）
make install  # 装到 /Applications 并启动
make uninstall
```

不走 SwiftPM——本机 CLT 的 `PackageDescription` 新旧文件混装导致 `swift build` 链接失败。
v0.1 无外部依赖，`swiftc` + 手工组装 bundle 完全够用。引入 Sparkle 前需重装一次 CLT。

## 功能

- 效果：常亮 / 呼吸 / 心跳 / 频闪
- 周期、最暗、最亮可调（周期范围随效果自适应）
- 省电模式（30fps）
- 空闲时停止
- 开机自动启动（`SMAppService`）

## 代码结构

```
../Core/            与原型共用，单一副本
  Log.swift         可注入的日志出口，Core 不反向依赖宿主
  Driver.swift      CoreBrightness 封装、运行时探测、8bit 量化去重
  StateGuard.swift  快照 / 还原 / 崩溃恢复
  Effects.swift     Effect 协议、效果栈、MotionIntent

Sources/
  MagicKeyApp.swift @main、AppDelegate、信号处理
  Engine.swift      渲染循环，两个正交开关的状态收敛
  IdleMonitor.swift 「空闲即停」的六路信号
  Settings.swift    UserDefaults 持久化
  MenuBarView.swift SwiftUI 面板
```

## 两个设计要点

**1. `userWants` 与 `conditionsOK` 是正交的**

用户在菜单里开没开，和 IdleMonitor 说现在该不该跑，是两件事。两者同时为真才运行。
分开是必要的——屏幕休眠时要停，唤醒后要**自动**恢复，而不是要求用户再点一次开关。

**2. 渲染状态由队列独占**

`RenderState` 单独一个类，只在渲染队列上访问。`Engine` 是 `@MainActor`，
若让渲染队列直接读写它的属性就是数据竞争——`-swift-version 5` 下编译器不拦，但它是真的错。

## 已验证

| 路径 | 结果 |
|---|---|
| 效果渲染 | ✅ 亮度 0.84→0.05 平滑，ALS 正确接管 |
| 菜单退出 / `applicationWillTerminate` | ✅ 精确还原 |
| **SIGTERM / SIGINT / SIGHUP** | ✅ 已显式处理（见下） |
| `kill -9` 后重启 | ✅ 检出残留快照，先还原再以还原后状态为新基准 |
| 空闲即停 | ✅ 启动时用户已空闲则引擎不启动 |

### 踩过的坑

**Cocoa 应用默认不处理 SIGTERM。** `pkill` / `killall` / 部分注销关机路径都不会走
`applicationWillTerminate`，状态会留在「ALS 已关闭」上。实测确认：pkill 之后下次启动
报「检测到上次未干净退出」。崩溃恢复能兜底，但用户若不再打开本应用就一直恢复不了。
已用 `DispatchSourceSignal` 显式处理。

**还原时亮度必须最后写。** 先恢复环境光自动调节的话，它会抢在写入之后再调一档，
用户看到的就不是原来的亮度（实测差 1/255）。已修正 `StateGuard.apply()` 的顺序。

**`Log.sink` 必须在 `Engine()` 之前设置。** 引擎构造时就会做崩溃恢复并输出日志，
放到 `applicationDidFinishLaunching` 里那几行会漏掉。已移到 `AppDelegate.init()`。

## 尚未做

- 按键脉冲（需输入监控权限）
- CLI / URL Scheme 触发
- 音频律动
- 帧率按效果推导（当前固定 60 / 30）
- 应用图标（现在用 SF Symbol `keyboard`）
