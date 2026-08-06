# MagicKey 设计文档

> 为 MacBook 内置键盘背光添加动态效果的开源 macOS 应用
>
> 状态：v0.1 已实现 · 最后更新 2026-08-04

---

## 1. 产品定位

**一句话**：让 MacBook 那块只会"常亮"的白色键盘背光活起来。

**不做什么**（硬件限制，非软件能力问题）：
- ❌ 彩色 / RGB
- ❌ 单键或分区控制
- ❌ 波浪、流光等空间位移效果

内置键盘的全部 LED 共用一路 PWM 通道，只有一个 0–255 的全局亮度寄存器。任何权限、内核驱动或私有 API 都无法凭空产生红绿蓝。**MagicKey 的全部创作空间是"一个数值随时间的变化"** —— 这既是限制，也是整个架构的组织原则。

**定位不要写成"RGB 键盘软件"**。定位应是：*macOS 键盘背光的动效引擎与自动化工具*。

---

## 2. 已验证的技术基础

在 macOS 26.5.1 / Apple M4 (Mac16,12) 上实测确认。

### 2.1 控制接口

`/System/Library/PrivateFrameworks/CoreBrightness.framework` → `KeyboardBrightnessClient`

```objc
- (NSArray *)copyKeyboardBacklightIDs;              // 枚举键盘，内置键盘 ID = 0x5AC0000
- (BOOL)isKeyboardBuiltIn:(uint64_t)kb;

- (float)brightnessForKeyboard:(uint64_t)kb;        // 读取 0.0 – 1.0
- (BOOL)setBrightness:(float)b forKeyboard:(uint64_t)kb;          // ✅ 主力写入接口
- (BOOL)setBrightness:(float)b fadeSpeed:(double)s
               commit:(BOOL)c forKeyboard:(uint64_t)kb;           // ⚠️ 实测无效，勿用

- (BOOL)enableAutoBrightness:(BOOL)e forKeyboard:(uint64_t)kb;    // 环境光自动调节开关
- (BOOL)isAutoBrightnessEnabledForKeyboard:(uint64_t)kb;
- (BOOL)isAmbientFeatureAvailableOnKeyboard:(uint64_t)kb;

- (BOOL)setIdleDimTime:(double)t forKeyboard:(uint64_t)kb;        // 闲置调暗
- (BOOL)suspendIdleDimming:(BOOL)s forKeyboard:(uint64_t)kb;
- (BOOL)isBacklightDimmedOnKeyboard:(uint64_t)kb;

- (BOOL)registerNotificationForKeys:(id)keys keyboardID:(uint64_t)kb
                              block:(id)block;      // 监听外部改动（用户按 F5/F6）
- (void)unregisterKeyboardNotificationBlock;
```

### 2.2 实测结论（直接约束架构）

| 编号 | 结论 | 设计后果 |
|---|---|---|
| **F1** | 普通用户权限即可读写，`uid=501` 成功 | 不需要特权 helper、`SMJobBless`、LaunchDaemon。单进程沙盒外 App 即可 |
| **F2** | `setBrightness:fadeSpeed:commit:` 返回 `YES` 但亮度不变 | **淡入淡出必须软件插值**。硬件不提供缓动 |
| **F3** | 单次 `setBrightness:` 耗时 **avg 0.09ms / p99 0.24ms / max 0.37ms** | 极便宜。60Hz 下仅占帧预算 0.5%，**120Hz 亦可行**。仍放专用串行队列（隔离 + 单一写入者），但不再是性能硬约束 |
| **F4** | 硬件 8bit 量化（0–255，步进 ≈0.0039） | 写入前按整数档位去重。实测 4s 周期呼吸省掉 **26.8%** 写入。属省电优化，非性能必需 |
| **F5** | 环境光自动调节默认开启且可编程关闭 | 引擎启动时必须关闭，退出时必须恢复，否则 ALS 会持续覆盖动画输出 |
| **F6** | `registerNotificationForKeys:` 可监听外部亮度改动 | 用户按 F5/F6 时能感知，作为"用户接管"信号 |
| **F7** | **不要做 gamma 感知映射**。255 档太少，任何 γ>1 都会把暗段压进 0–2 档，产生可见卡顿（γ=2.2 时单档停留 167ms 且每周期熄灭 150ms） | 效果曲线直接工作在物理亮度空间。Apple 的 0–1 很可能已做过感知映射 |

---

## 3. 架构

### 3.1 分层

```
┌──────────────────────────────────────────────────────────┐
│  UI                SwiftUI + MenuBarExtra                │
│  菜单栏图标 / 效果选择 / 参数面板 / 偏好设置 / 预设管理     │
└────────────────────────┬─────────────────────────────────┘
                         │ 配置 & 命令
┌────────────────────────┴─────────────────────────────────┐
│  Engine            EffectEngine                          │
│  ├─ Renderer       60Hz 渲染循环（专用 userInteractive 队列）│
│  ├─ EffectStack    基础层 + 瞬时层，按 BlendMode 混合        │
│  ├─ Easing         缓动曲线库（sine/cubic/spring/…）        │
│  └─ Governor       电池 / 降频 / 用户接管 / 熄屏 策略        │
└────────────────────────┬─────────────────────────────────┘
                         │ Float 0...1（每帧一个值）
┌────────────────────────┴─────────────────────────────────┐
│  Driver            BacklightDriver（protocol）            │
│  ├─ CoreBrightnessDriver   dlopen + 运行时探测            │
│  ├─ Quantizer              8bit 去重（F4）                │
│  ├─ StateGuard             保存/恢复系统原始状态（F5）      │
│  └─ NullDriver             API 不可用时的安全降级          │
└──────────────────────────────────────────────────────────┘
                         ▲
┌────────────────────────┴─────────────────────────────────┐
│  Sources           触发源（全部可选、各自独立降级）          │
│  KeyMonitor · AudioTap · CLI/URLScheme · AppFocus ·       │
│  Battery · Clock · GlobalHotkey                          │
└──────────────────────────────────────────────────────────┘
```

### 3.2 核心抽象：效果即时间函数

因为输出只有一个数，整个引擎可以压缩成极简的模型：

```swift
struct FrameContext {
    let time: TimeInterval        // 效果开始至今
    let frame: UInt64
    let baseBrightness: Float     // 用户设定的基准亮度
    let signals: SignalBus        // 音频能量、按键速率、电量等实时输入
}

protocol Effect: AnyObject {
    var id: EffectID { get }
    var blend: BlendMode { get }          // .replace / .max / .add / .multiply
    func tick(_ ctx: FrameContext) -> Float?   // 返回 nil 表示效果结束，自动出栈
}
```

> **255 档是设计约束，不只是精度问题**（F7）。整条效果曲线只有 255 个可用值，
> 且余弦在转折点导数为零会天然停留。设计效果时要按「档位停留时长分布」来评估，
> 而不是看曲线好不好看——单档停留超过约 100ms 肉眼就能察觉为卡顿。

**两类效果**：

- **基础层（Ambient）**——常驻，同时只有一个：`Static` `Breathe` `Heartbeat` `Strobe` `AudioReactive` `Wave`(时间维度)
- **瞬时层（Transient）**——可叠加多个，播完自动移除：`KeyPulse` `NotifyFlash` `Countdown` `SOS`

混合器每帧取基础层输出，瞬时层按 `blend` 叠加后 clamp 到 `[0,1]`。

> 这个设计的价值：调研里"呼吸灯"和"按键脉冲"是两个并列功能，实际上用户想要的是**两者同时生效**——呼吸的底色上，每次敲键闪一下。分层混合天然支持，不需要为组合写特例。

### 3.3 渲染循环

```
DispatchSourceTimer(queue: .userInteractive, serial)
  ↓ 每 16.7ms（电池模式 33.3ms）
  ├─ 采样 SignalBus（音频 RMS、按键事件队列）
  ├─ EffectStack.render() → Float
  ├─ Quantizer：量化到 0–255 整数档，同档跳过
  └─ CoreBrightnessDriver.setBrightness()   ← 约 0.09ms
```

**帧率的判据是相对亮度步进，不是丢了多少档**（`--analyze` 实测）：

韦伯定律——亮度差异的可察觉程度正比于**相对**变化量。曲线最陡处必然跳档，
但高亮度区跳 3 档只是 2% 的变化，看不出来；档位 2 附近跳 3 档是 150%，一眼可见。
所以「丢档比例」不是感知指标。

4s 呼吸（`--min 0.05`）各帧率下的最大相对步进：

| fps | 最大相对步进 | |
|---|---|---|
| 30 | 12.5%（档16 跳2） | 边缘可见 |
| 60 | 7.7%（档13 跳1） | 边缘可见 |
| 90 / 120 | **7.7%（同上）** | **无任何改善** |

**60fps 已触及硬件地板**——最差处只跳 1 档，物理上不可能更小。再提高帧率纯属浪费。
而 30fps 也仅从 7.7% 劣化到 12.5%，差距不大：**电池模式降到 30Hz 是可行的**。

真正的杠杆是亮度下限而非帧率：`--min 0.15 @ 60fps` 得到 3.9%（平滑），
比 `--min 0.05 @ 120fps` 的 7.7% 好一倍。**低端观感靠抬高下限，不靠堆帧率。**

推论：引擎仍应向 Effect 查询所需 tick 频率（慢速效果无需 60Hz），
但判据用最大相对步进，且上限锁在 60Hz——再高没有收益。

**「空闲即停」是硬需求，不是省电优化**（2026-08-03 决定）：

能耗未实测（见 `tools/TESTING.md`）。已知的是软件 CPU 占用 0.99%，
换算约几十 mW，风险低。但 **CPU 占用率系统性低估了一件事：60Hz 定时器唤醒会阻止
SoC 进入深度空闲状态**，这部分代价不体现在 CPU 时间里，也是唯一没被覆盖的风险。

与其去测它，不如用结构消除它——引擎只在用户实际可能看着键盘时运行：

- 屏幕休眠 / 用户空闲 → **停掉引擎**（不是降频）
- 基础层为静态且无瞬时效果 → 停表降到 0Hz
- 电池模式 → 30Hz（已验证观感可接受）

这样 60Hz 唤醒只发生在用户活跃期间，而那时系统本来就不在深度空闲。
若将来要发布前补测能耗，`tools/TESTING.md` 里有可用的方法和一次失败教训。

**约束**：
- 单一写入者。所有亮度写入必须经过 Driver 层的串行队列，杜绝竞态。
- 渲染循环不做任何 I/O、不加锁等待 UI。信号通过无锁环形缓冲从 Sources 传入。
- 空闲时（`Static` 效果且无瞬时层）自动停表，降到 0 Hz，不做无意义写入。

### 3.4 状态托管（StateGuard）

这是最容易做砸、也最影响用户信任的部分。启动时快照，退出时还原：

```swift
struct BacklightSnapshot: Codable {
    var brightness: Float
    var autoBrightnessEnabled: Bool
    var idleDimTime: Double
    var capturedAt: Date
}
```

必须覆盖的还原时机（原型已全部验证通过，2026-08-03）：

1. 正常退出（`applicationWillTerminate`）✅
2. 引擎手动停止 / 效果切到"关闭" ✅
3. **崩溃后重启**——快照持久化，下次启动检测到"上次未干净退出"则先还原再启动 ✅
4. 系统睡眠（`NSWorkspace.willSleepNotification`）✅ 纯 CLI 进程也能收到，在断电前同步到达
5. 锁屏、切换用户
6. `SIGTERM` / `SIGINT` 信号处理器 ✅

**用户接管逻辑**（F6）：监听到外部亮度改动（用户按 F5/F6）时，默认行为是把新值作为新的 `baseBrightness` 继续跑效果；可配置为"暂停效果 30 秒"。

---

## 4. 功能规划

### v0.1 — MVP

- [x] 菜单栏应用，全局开关
- [x] 基础层效果：`Static` `Breathe` `Heartbeat` `Strobe`
- [x] 参数：周期、亮度上下限
- [x] StateGuard 完整还原链路（含崩溃恢复、SIGTERM、系统睡眠）
- [x] 开机自启（`SMAppService`，未签名时会失败并如实提示）
- [x] 省电模式：30Hz
- [x] 「空闲即停」：锁屏 / 息屏 / 切换用户 / 用户长时间无输入
- [ ] 低电量自动暂停
- [ ] 缓动曲线与相位可调

### v0.2 — 交互反馈

- [x] `KeyPulse`：敲键触发脉冲，连打时各次包络取 `max` 叠成波浪
- [x] `KeyRepeatFilter`：长按时把自动重复挡在包络层之前，见上文
- [ ] `KeyPulse` 作为瞬时层叠加在呼吸等基础层之上（当前是独立的基础层效果）
- [ ] **CLI + URL Scheme**：`magickey pulse --effect flash` / `magickey://effect/breathe`
- [ ] 全局快捷键切换效果
- [ ] 效果预设的导入导出（JSON）

> CLI 是这个产品最被低估的功能。调研里提到的"编译完成 / 下载完成时闪烁"，没有任何干净的公开 API 能监听系统通知（读 Notification Center 数据库需要完全磁盘访问权限且随版本失效）。**把触发权交给用户的脚本**反而更强：`npm run build && magickey flash --times 3`、CI 结束、`ssh` 断连、长任务完成——全都能接。对开发者用户这是核心卖点，不是附属功能。

### v0.3 — 音频律动

- [x] 系统音频采集：**macOS 14.2+**（不是 14.4）的 Core Audio Process Tap
      （`AudioHardwareCreateProcessTap`），公开 API。已实现，见 `Core/AudioTap.swift`
- [ ] 降级：麦克风采集 / BlackHole 虚拟设备
- [ ] 频段选择（低频跟鼓点最有效）、灵敏度、attack/release 平滑
- [ ] 静音自动回落到基础层

### v0.4 — 情境自动化

- [ ] 规则引擎：条件 → 效果
  - 当前 App、时间段、电量、是否插电、专注模式、是否会议中、屏幕是否锁定
- [ ] 示例：`Terminal 前台 → Breathe(慢)`、`剩余电量 <20% → Heartbeat(红...不行，改成快速心跳)`

### v1.0 — 生态

- [ ] 效果脚本化：暴露 `tick(t, ctx) -> Float` 给 JavaScriptCore 或简单 DSL，社区可分享效果
- [ ] 多键盘支持（外接 Apple 妙控键盘同样有 backlight ID）
- [ ] 效果市集 / GitHub Gist 一键导入

---

## 5. 权限与隐私

| 能力 | 所需权限 | 缺失时的行为 |
|---|---|---|
| 亮度控制 | **无** | — |
| 按键脉冲 | **无**（见下） | — |
| 系统音频律动 | **系统录音**（`kTCCServiceAudioCapture` / `NSAudioCaptureUsageDescription`） | 该效果不可用，其余效果照常 |
| 麦克风律动 | 麦克风 | 效果置灰 |
| 开机自启 | 无（`SMAppService`） | — |

**按键脉冲不使用 `CGEventTap`，因此不需要输入监控权限。**
这里原本的设计（`CGEventTap` + `.listenOnly` + TCC 授权 + 效果置灰的降级路径）是多余的。
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)`
是公开 API，返回一个标量「距上次按键多少秒」，逐帧比较它是否回落即可判定有按键。
不弹授权框，实测 p99 0.04µs。IdleMonitor 早就在用同一个调用做空闲检测。

代价是拿不到 keycode——而 §1 的硬件结论是全部 LED 共用一路 PWM，
「按了哪个键」在**渲染**这一侧无处可用。所以这不是妥协方案，而是更优解：
它顺带把整条隐私红线变成了结构上不可能违反。

**2026-08-05 修正：「无处可用」只对渲染成立，对过滤不成立。**
用户提出禁掉 Delete/回车/F 键触发脉冲，这需要 keycode，只能靠 `CGEventTap`
（Input Monitoring 权限）。论证后决定不做，理由见 CLAUDE.md「后续工作 v0.2」，
核心是：用户报告的实际痛点是**长按时亮度钉在峰值**，而那与键位身份无关
（按住任意字母键完全一样），已由零权限的 `KeyRepeatFilter` 解决。
所以本节结论仍然有效，但**不能再用「这个信息本来也用不上」来支撑它**——
它现在是一个权衡，不是一个恒等式。

### 长按抑制（`KeyRepeatFilter`）

按住一个键时内核按固定周期重复投递 keyDown。本机实测：首次延迟 **500ms**，
重复间隔 **83.6ms**（=5 个 1/60s tick，系统偏好未设置，即 macOS 26 内建默认）。
脉冲默认 0.4s 且包络取 `max`，于是任一时刻约 5 个包络在叠，
最新那个永远刚过起手峰——幅度锁在 0.79–1.0 抖动，按住多久亮多久。

判据是**节奏规整度**而非间隔长短：内核是定时器，人手不是。
不读任何系统偏好，因此不依赖用户的重复速率设置（33ms–2s 全覆盖），
也兼容 Karabiner 之类自己产生重复的改键工具。

参数由 `magickey-tool --probe` 实测定出（331 次按下 / 7 段自动重复 / 187 次人手）：

| 容差 | 需连续匹配 | 误抑制（人手） | 抑制率（重复） |
|---|---|---|---|
| 4ms | 1 | 3.2 % | 91.0 % |
| **4ms** | **2** | **0 %** | **85.4 %** |
| 6ms | 2 | 0.5 % | 88.9 % |
| 4ms | 3 | 0 % | 79.9 % |

取 `tolerance = 4ms, lockAfter = 2`：误抑制必须为 0（用户选的是硬抑制，
误判的代价是那一下完全没有光），在此前提下抑制率最高。

**为什么不能只要求一对相等的间隔**：实测 187 次真实按键里最接近的一对
相邻间隔只差 0.27ms，单看一对分不开。要求连续两次让误判概率平方级下降。

**为什么容差不带相对项**：自动重复间隔（83.6ms）比人类打字间隔（150–200ms）短，
按比例给容差等于在人手那一侧放得更宽，方向是反的。

**隐私红线**（必须写进 README 并在代码里做到）：
- 按键检测只读一个标量时间差，**进程内不存在任何能获取按键内容的代码路径**
- 若未来引入 `CGEventTap`（例如全局快捷键），必须重新评估本节
- 无网络请求、无遥测、无崩溃上报（或明确 opt-in）
- 一个会监听全部键盘输入的开源工具，可审计性就是产品的一部分——按键处理路径应尽量短、集中在单个文件，方便人工审计

---

## 6. 私有 API 的风险控制

`CoreBrightness` 是私有框架，macOS 大版本升级可能变化。控制手段：

1. **绝不静态链接**。`dlopen` + `NSClassFromString` + `respondsToSelector:` 逐个探测。
2. **协议隔离**。引擎只认 `BacklightDriver` 协议，`CoreBrightnessDriver` 是唯一实现；API 消失时替换为 `NullDriver`，UI 显示"当前 macOS 版本不受支持"，**应用照常启动不崩溃**。
3. **启动自检**。首次运行做一次读-写-还原探测，确认真的能控制，失败则进入降级模式。
4. **CI 冒烟测试**。在 macOS beta 上跑接口探测，提前一个版本发现变化。

**不推荐虚拟 HID 作为降级路径**（LightBoard 走的模拟 F5/F6 按键）：系统亮度键只有 16 档，用于动画会明显卡顿跳变，观感比不做还差。宁可明确告知不可用。

---

## 7. 发布

- **不上 Mac App Store**。私有 API 违反 App Review Guidelines 2.5.1，必被拒。
- **Developer ID 签名 + 公证（notarization）**。公证不禁止私有 API，只有 MAS 审核禁止。
- 分发：**GitHub Releases + Homebrew Cask**（`brew install --cask magickey`）
- 自动更新：Sparkle
- 开源许可：MIT

**可借鉴的代码来源**（均为 MIT，可安全使用）：
- `mac-brightnessctl` —— 最简洁的 CoreBrightness 封装，适合作为 Driver 层参考
- `KBPulse` —— 动画配置与调用方式
- `BeatKeys` —— 音频分析与律动映射

⚠️ **`LightBoard` 目前没有 LICENSE 文件**。GitHub 公开仓库未声明许可证时，默认保留全部权利，**不可复制、分发或制作衍生作品**。可以阅读学习思路，不可拷贝代码。

---

## 8. 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| macOS 升级破坏私有 API | 核心功能失效 | 第 6 节的四层防护 |
| 键盘背光耗电 | 续航下降，差评 | 电池模式降频、低电量自动停、亮度上限约束 |
| 用户信任（键盘监听） | 采用率 | 权限可选、只取时间戳、代码可审计、README 明说 |
| 状态未还原 | 键盘卡在奇怪亮度 | StateGuard 六重还原时机 + 崩溃恢复 |
| 长期新鲜感不足 | 装了就卸 | 靠 CLI 触发和情境自动化提供**实用价值**，而非只靠观赏性 |

---

## 9. 建议的第一步

先做一个约 200 行的技术验证原型（无 UI）：

```
CoreBrightnessDriver（dlopen + 探测 + 量化去重）
  + StateGuard（快照 / 还原）
  + 60Hz 渲染循环
  + 一个 Breathe 效果
```

跑通并连续运行 30 分钟，观察：CPU 占用、能耗（`powermetrics`）、是否与 ALS 冲突、退出后亮度是否精确还原。这四项决定了产品是否成立——都过了再动 SwiftUI。
