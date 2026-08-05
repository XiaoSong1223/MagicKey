# MagicKey

macOS 菜单栏应用，给 MacBook 内置键盘背光加动态效果（呼吸/心跳/频闪）。

- 仓库：https://github.com/XiaoSong1223/MagicKey （**Private**）
- 开发机：MacBook Air M4 (Mac16,12) / macOS 26.5.1 / arm64
- 详细架构与实测数据见 [`DESIGN.md`](DESIGN.md)，本文件只放**每次开工需要立刻知道的东西**

---

## 硬性限制（先读这段，能省一整轮试错）

**内置键盘不能变色，不能单键控制。** 全部 LED 共用一路 PWM，只有一个 0–255 的
全局亮度寄存器。root 权限、内核驱动、私有 API 都改变不了这一点。

所以整个引擎只做一件事：**决定一个 0–1 的数值随时间怎么变**。
任何涉及颜色、分区、空间移动的需求都要直接否掉，不要尝试绕。

「按键处向四周扩散」这类请求会反复出现（空间维度不存在）。
可以给的替代品是它在**时间域**上的等价物——整块键盘一起冲亮再衰减，
即已实现的 `keypulse`。回答时先说清做不到什么，再给这个。

**255 档是设计约束，不只是精度问题。** 单档停留超过约 100ms 肉眼即可察觉为卡顿。
新效果上线前必须过 `tools/magickey-tool --analyze`。

---

## 构建与运行

```bash
cd app   && make install     # 构建 + 装到 /Applications + 启动
cd app   && make run         # 直接跑 bundle 内可执行文件，日志打终端（调试用）
cd tools && make analyze     # 分析效果曲线
cd tools && make preview     # 真实键盘预览，Ctrl-C 还原
```

### ⚠️ SwiftPM 在这台机器上是坏的

`swift build` 链接失败。根因：CommandLineTools 升级时新旧文件混装，
`PackageDescription.swiftmodule/*.private.swiftinterface` 停留在 2024-02，
而 dylib 是 2025-05，`SwiftVersion` vs `SwiftLanguageMode` 类型对不上。

**不要试图修 Package.swift，改用 `make`（swiftc 直接编译）。**
引入第一个外部依赖（Sparkle）前需要重装一次 Command Line Tools。

同一次升级还留下过 `usr/include/swift/module.modulemap`（2023-08）导致 `swiftc`
完全不可用，已通过重命名解决（备份在同目录 `.bak`）。

---

## 当前进展

### v0.1 已完成并实测通过

| 模块 | 状态 |
|---|---|
| `Core/` 驱动、状态托管、效果模型 | ✅ app 与 tools 共用单一副本 |
| 效果：常亮 / 呼吸 / 心跳 / 频闪 | ✅ |
| 效果：按键脉冲 `keypulse` | ✅ 曲线分析 + 真实键盘手感均已实测 |
| 参数：周期、最暗、最亮 | ✅ |
| 省电模式（30fps） | ✅ |
| 「空闲即停」 | ✅ 锁屏/息屏/切换用户/无输入 |
| 开机自启 `SMAppService` | ⚠️ 代码就绪，未签名时会失败并如实提示 |
| 状态还原 **六个时机** | ✅ 全部实测：正常退出、手动停止、崩溃重启、系统睡眠、SIGTERM、锁屏 |

### 性能实测（30 分钟长测，10.8 万帧）

- CPU 0.99%，帧率 60.0fps 无漂移，帧超预算 3 次
- 单次 `setBrightness` avg 0.09ms / p99 0.24ms
- ALS 冲突 0 次（1799 次回读）

---

## 已知卡点

| 卡点 | 影响 | 解法 |
|---|---|---|
| **未代码签名/公证** | 开机自启不可用；别人下载会被 Gatekeeper 拦 | 需要 Apple Developer ID（$99/年） |
| **能耗未实测** | 唯一未覆盖的风险：60Hz 唤醒阻止 SoC 深度空闲 | 已用「空闲即停」硬需求结构性消除。方法见 `tools/TESTING.md` |
| SwiftPM 坏 | 不能加外部依赖 | 重装 CLT |
| 无应用图标 | 用的是 SF Symbol `keyboard` | 需要设计 |
| 只在 M4 / macOS 26 验证过 | Intel 机型、旧系统未知 | 需要更多机器 |

**不能自动化的测试**（需要人工介入，不要浪费时间尝试）：

- `sudo` 命令：Claude 的 shell 没有 TTY，密码提示读不到。必须让用户在 Terminal.app 里跑
- 能耗测量：必须**拔掉电源线**，否则 `Amperage` 恒为 0
- 合盖 / 物理按键触发的测试

---

## 后续工作

### v0.1 收尾

- [ ] 低电量自动暂停
- [ ] 缓动曲线与相位可调
- [ ] 应用图标
- [ ] 代码签名 + 公证（**不能上 Mac App Store**，私有 API 违反 Review Guidelines 2.5.1）
- [ ] 分发：GitHub Releases + Homebrew Cask

### v0.2 — 交互反馈

- [x] ~~`KeyPulse` 按键脉冲~~ 已实现，见「当前进展」
- [ ] 按键脉冲叠加在呼吸底色上（`EffectStack` 的瞬时层就是为这个建的，至今没人调用 `push()`）
- [ ] **CLI + URL Scheme** ← 这是最被低估的功能，见下方说明
- [ ] 全局快捷键切换效果
- [ ] 效果预设导入导出（JSON）

> **为什么 CLI 是核心而非附属**：没有任何干净的公开 API 能监听系统通知
> （读 Notification Center 数据库要完全磁盘访问且随版本失效）。
> 把触发权交给用户脚本反而更强：`npm run build && magickey flash --times 3`、
> CI 结束、长任务完成都能接。对开发者用户这是主要卖点。
> 观赏性效果的新鲜感撑不过两周，实用价值才留得住人。

### v0.3 — 音频律动

- [ ] 系统音频：`AudioHardwareCreateProcessTap`（macOS 14.4+，公开 API）
- [ ] 降级：麦克风 / BlackHole
- [ ] 频段选择、灵敏度、attack/release 平滑

### v0.4 — 情境自动化

- [ ] 规则引擎：当前 App / 时间段 / 电量 / 是否插电 / 专注模式 → 切换效果

### v1.0

- [ ] 效果脚本化（JavaScriptCore 或简单 DSL），社区分享
- [ ] 多键盘支持（外接妙控键盘也有 backlight ID）

### 架构上的待办

- [ ] **帧率按效果推导**：慢速效果无需 60Hz。判据用最大相对步进，**上限锁 60Hz**（再高无收益）
- [ ] `registerNotificationForKeys:` 监听用户按 F5/F6，作为「用户接管」信号（DESIGN.md F6，尚未实现）

---

## 踩过的坑（别重复踩）

**监听按键不需要输入监控权限。** 本文件曾写着 KeyPulse「需输入监控权限，必须做成可选」——
这是**错的**，白白把一个功能推迟了一个版本。`CGEventSource.secondsSinceLastEventType(
.combinedSessionState, eventType: .keyDown)` 是公开 API，返回「距上次按键多少秒」，
不弹授权框，实测 p99 0.04µs（60fps 下占帧预算 0.0002%）。IdleMonitor 早就在用同一个调用。
代价是拿不到「按了哪个键」——而硬件只有一路全局亮度，这个信息本来也用不上。
判断按键的方法是逐帧比较该值是否**回落**；用 `ctx.time - idle` 而不是 `ctx.time`
记录按下时刻，上升沿起点才是亚帧精度的（实测采样峰值 0.844 vs 量化到帧边界的 0.815）。

**衰减包络别用指数。** 指数永远到不了 0，截断时会留下可见台阶。
幂函数 `(1-u)^1.6` 精确落到 0，实测 0.4s 脉冲最长单档停留仅 10.8ms、档位利用率 80%。

**gamma 必须保持 1.0。** 任何 γ>1 都会把暗段压进 0–2 档。γ=2.2 时单档停留 167ms
且每周期完全熄灭 150ms，肉眼明显。Apple 的 0–1 很可能已做过感知映射。
试过把 gamma 施加到 wave 而非亮度值，更差（367ms），已排除。

**60fps 已触及硬件地板。** 4s 呼吸在 60fps 下最差处仅跳 1 档，90/120fps 完全没有改善。
想改善低亮度段观感要**抬高亮度下限**，不是堆帧率（`--min 0.15@60fps` 优于 `--min 0.05@120fps`）。

**Cocoa 应用默认不处理 SIGTERM。** `pkill`/`killall`/部分注销关机路径都不走
`applicationWillTerminate`，状态会卡在「ALS 已关闭」。必须用 `DispatchSourceSignal` 显式处理。

**还原时亮度必须最后写。** 先恢复环境光自动调节的话，它会抢在写入之后再调一档（实测差 1/255）。

**`Log.sink` 必须在 `Engine()` 之前设置。** 引擎构造时就做崩溃恢复并输出日志，
放到 `applicationDidFinishLaunching` 里那几行会漏掉。

**`setBrightness:fadeSpeed:commit:` 是空壳。** 返回 YES 但亮度纹丝不动，
所有缓动必须软件实现。别照抄其他项目调 fadeSpeed 的代码。

**渲染状态必须由队列独占。** `RenderState` 单独一个类只在渲染队列访问；
让渲染队列直接读写 `@MainActor` 的 `Engine` 属性是数据竞争，
`-swift-version 5` 下编译器不拦但它是真的错。

**「丢档比例」不是感知指标。** 判据是最大**相对**亮度步进（韦伯定律）。
高亮度区跳 3 档只有 2% 变化看不出来，档位 2 附近跳 3 档是 150% 一眼可见。

**分析工具不要写成独立脚本。** 必须复用 `Core/` 里真正的 `Effect` 和 `Perceptual`，
否则改了曲线忘了改脚本，分析结果就开始骗人。这是 `--analyze` 做进二进制的唯一理由。

---

## 本文档的维护约定

**每次新会话开始时读本文件**，了解进展、卡点、后续工作。

**以下情况必须更新本文件**：

1. 一个功能测试完成并正式上线 → 移到「当前进展」，从「后续工作」划掉
2. 发现新的卡点或环境问题 → 记进「已知卡点」
3. 踩到一个会浪费后来人时间的坑 → 记进「踩过的坑」，**写清楚现象和根因，不只是结论**
4. 架构决策变更 → 更新 `DESIGN.md`，本文件只留一句指向

**不要往本文件里塞**：代码结构（读代码就知道）、git 历史、能从 `DESIGN.md`
查到的详细数据。本文件是每次会话都要读的，臃肿就没人读了。
判断标准：**这条信息能不能让下一个会话少走一段弯路？** 不能就别写。
