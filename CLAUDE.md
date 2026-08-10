# MagicKey

macOS 菜单栏应用，给 MacBook 内置键盘背光加动态效果（呼吸/心跳/频闪）。

- 仓库：https://github.com/XiaoSong1223/MagicKey （**Private**）
- 开发机：MacBook Air M4 (Mac16,12) / macOS 26.5.1 / arm64
- 详细架构与实测数据见 [`DESIGN.md`](DESIGN.md)，本文件只放**每次开工需要立刻知道的东西**

---

## 硬性限制（先读这段，能省一整轮试错）

**内置键盘不能变色，不能单键控制。** 全部 LED 共用一路 PWM，只有一个 0–255 的
全局亮度寄存器。root 权限、内核驱动、私有 API 都改变不了这一点。

**拿不到「按了哪个键」，但这不再是「反正也用不上」。** 现在有了第一个真实用途：
按键位过滤（禁掉 Delete/回车/F 键触发脉冲）。做得到，代价是 `CGEventTap` 或
`NSEvent.addGlobalMonitorForEvents` 都要 **Input Monitoring 权限**。
2026-08-05 论证后**决定不付这个代价**，理由见「后续工作 v0.2」。
下次再有人提这个需求，不要再重新论证一遍权限，直接看那一条。

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
| 效果：音乐律动 `audiobeat` | ✅ 合成鼓点 100%/100% + 真机盯着定灵敏度 1.35 |
| 系统音频采集 `AudioTap` | ✅ 真机跑通，需「系统录音」授权（非麦克风） |
| 长按不再钉在峰值 `KeyRepeatFilter` | ✅ 探针实测定参 + 合成序列过 `--analyze` |
| 参数：周期、最暗、最亮 | ✅ |
| 省电模式（30fps） | ✅ |
| 「空闲即停」 | ✅ 锁屏/息屏/切换用户/无输入/**有音频在放则不算空闲** |
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
| **内建屏菜单栏没空位** | 灵动岛挂件占了 588–870pt，状态项被放到岛底下看不见 | 用户侧腾位置，见「踩过的坑」 |
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
- [x] ~~应用图标~~ 已有 `AppIcon.icns` 与状态栏专用图 `StatusKey{Active,Inactive}`
- [ ] 代码签名 + 公证（**不能上 Mac App Store**，私有 API 违反 Review Guidelines 2.5.1）
- [ ] 分发：GitHub Releases + Homebrew Cask

### v0.2 — 交互反馈

- [x] ~~`KeyPulse` 按键脉冲~~ 已实现，见「当前进展」
- [ ] **键位黑名单**（禁掉 Delete/回车/F 键触发）——**需 Input Monitoring 权限**，
      2026-08-05 论证后推迟。三个理由：① 用户报告的实际痛点是长按钉在峰值，
      已由 `KeyRepeatFilter` 零权限解决，黑名单治不了它（按住任意字母键一样钉住）；
      ② ~~TCC 授权绑定代码签名，ad-hoc 签名每次 `make install` 都掉授权~~
      **这条 2026-08-06 已被实测推翻**（见「踩过的坑」），不再是推迟的理由；③ 会推翻「零权限」这条产品线。
      真要做时：`CGEventTap` 监听 `.keyDown` 取 keycode，做成默认关闭的可选项，
      未授权时静默降级回纯 `KeyRepeatFilter` 行为。
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

- [x] ~~系统音频：`AudioHardwareCreateProcessTap`~~ 已实现。**macOS 14.2+**（不是 14.4），
      公开 API，需 TCC「系统录音」授权
- [x] ~~灵敏度~~ 已实现（菜单里的滑块，默认 1.35）
- [ ] 降级：麦克风 / BlackHole ——**优先级下调**，process tap 在 ad-hoc 签名下就能用，
      降级路径的价值远低于原先预估
- [ ] 频段选择、attack/release 可调（目前写死 150Hz / 3ms / 90ms）
- [ ] 音乐律动叠在呼吸底色上（同「按键脉冲叠加」，都卡在没人调用 `push()`）

### v0.4 — 情境自动化

- [ ] 规则引擎：当前 App / 时间段 / 电量 / 是否插电 / 专注模式 → 切换效果

### v1.0

- [ ] 效果脚本化（JavaScriptCore 或简单 DSL），社区分享
- [ ] 多键盘支持（外接妙控键盘也有 backlight ID）

### 架构上的待办

- [ ] **按键检测换成单调计数**：现在靠 `idle` 相对上一帧回落判断有没有新按键，
      当重复间隔比帧长**稍短**时 `idle` 每帧递增，下降沿永不出现，按键全漏。
      30fps 撞上系统最快重复率（33ms）正好踩中，实测 60 次只检出 1 次（`--analyze`
      会打 `❌ 只检出 n/N`）。60fps 不受影响，所以默认配置安全，但省电模式是个洞。
      修法：`CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)`
      返回单调计数，同样免权限，能数出每帧几次按下；`idle` 继续用来取最近一次的亚帧时刻
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

**自动重复会把 keypulse 钉在峰值，根因不是「哪个键」。** 按住任意键，内核按
83.6ms（本机实测，=5 个 1/60s tick）重复投递 keyDown，而脉冲默认 0.4s、
包络取 max，任一时刻都有约 5 个包络在叠，最新那个永远刚过起手峰——
幅度锁在 0.79–1.0 之间抖，按住多久亮多久。**加键位黑名单治不了它**：
按住字母键完全一样。解法是 `KeyRepeatFilter`（节奏规整度），见下条。

**「人类打不出相等的间隔」是错的，方案却仍然成立——靠的是连续两次。**
最初的判据是「连续两个间隔几乎相等 = 自动重复」，容差 4ms。实测 187 次真实按键里
最接近的一对相邻间隔只差 **0.27ms**（176.81 / 176.54），单看一对完全分不开，
误抑制率 3.2%。改成**要求连续两个间隔都匹配**（`lockAfter = 2`）后
误抑制 **0/187**，重复抑制率 85.4%。概率是平方级下降，代价只是每次长按多放行一次。

**容差不能带相对项。** 原本写的是 `max(4ms, 3% × 间隔)`，方向正好是反的：
自动重复间隔（83.6ms）比人类打字间隔（150–200ms）**短**，
按比例给容差等于在人手那一侧放得更宽，误抑制不降反升。**用绝对值。**

**分析工具的判据也会骗人，不只是曲线。** `--probe` 第一版用「彼此相差 20% 以内」
认自动重复段，把人类打字（150–200ms、抖动 ±20ms）整段归成了自动重复，
于是报出「内核抖动 ±24.85ms」的假下界，进而给出「方案要回炉」的假结论。
机器紧、人手松，**这种地方必须用绝对阈值**。同理：判定用的量必须和过滤器实际消费的量
一致——「整段偏离均值多少」（±0.73…±4.49ms）和「相邻两个间隔差多少」（多数 <1ms）
不是一回事，用前者去造合成序列会把抑制率低估近一半。

**分析器复用同一个 Effect 实例会污染有状态效果。** `Analyzer.run` 把 t 从 0
重放五轮（20kHz 一轮 + 每个候选帧率一轮）。`KeyPulseEffect` 是有状态的，
以前能跑纯属巧合（`synthetic` 让 idle 恒等于 t，每轮开头回落到 0 正好重新触发）。
加了节奏历史后状态跨轮污染，第二轮开头会算出负间隔。签名已改成收 `() -> Effect`，
每轮现造。**以后给分析器加任何有状态的东西，先确认这一点。**

**TCC 授权不跟代码签名走。** 本文件曾把「TCC 授权绑定代码签名，ad-hoc 签名每次
`make install` 都掉授权」当成键位黑名单推迟的第二条理由——**实测是错的**。
2026-08-06 用探针连测 5 次：改源码重建、cdhash 每次都变（`dc6f853f`→`d7c2e464`→
`901fc804`→`5e31c27a`→`3c9c2098`），同路径同 bundle ID 下**授权一直有效**。
所以「等 Developer ID 之后再做」对开发期的 TCC 功能不成立。
（保留一个未验的口子：`make install` 是 `rm -rf` 再 `cp -R`，整个 bundle 重建，
没单独测过。但音乐律动天天在用同一条路径，真会掉早就发现了。）

**Process tap 的失败模式是死锁，不是错误码。** 未授权时
`AudioHardwareCreateProcessTap` **照样返回 0**，真正卡住的是后面的
`AudioDeviceCreateIOProcIDWithBlock`——永久阻塞在 `_TellServerAboutStreamUsage`
的 `mach_msg` 上，不返回、不报错。所以：① 采集的建立过程必须在独立线程上并带超时
（正常也要 1.8–4.6 秒）；② 任何「未授权」的错误提示都不该挂在建 tap 那一步。
另外 coreaudiod 会缓存授权前的客户端状态，改完系统设置要 `sudo killall coreaudiod`
才生效——否则你会以为授权没用。

**tap 是被音频驱动的：没有声音在放就没有 IO 回调。** 这不是故障。
定位这条花了四轮：一直盯着「回调 0 次」改聚合设备配方，实际上全程没有任何音频在播放。
`AudioActivity.outputIsRunning()`（读 `kAudioDevicePropertyDeviceIsRunningSomewhere`，
零权限）就是为了把「tap 坏了」和「没东西可 tap」分开而存在的，**别删**。
同理，测音频的探针要自己起 `afplay` 放测试音，不要指望人和你手速同步。

**起音检测的判据是「穿过阈值」不是「高于阈值」。** 第一版写成后者，
合成鼓点上 32 个底鼓报成 48 个，多出来的每一个都正好晚一个不应期——
底鼓包络在阈值之上停留的时间比不应期长，不应期一到就立刻又满足条件。
解法是迟滞（`rearmFactor`）：触发后必须等包络掉回阈值以下才重新武装。
**加长不应期治不了**，那会连快节奏鼓点一起打死。

**合成测试全部满分，往往说明测试太简单，不是参数对了。** 起音检测扫参时
72 组参数在合成鼓点上全是 100% 命中 0 误报——因为底鼓、hi-hat、和弦在低频段上
完全不重叠，闭着眼都能分开。同一批参数在真实音乐上漏掉一半以上的拍子。
合成测试的价值是**抓 bug**（上一条就是它抓到的），不是**定参**。
定参只能靠真实输入，而最终判据是眼睛——检出率能证明「数量对了」，
证明不了「闪在拍子上」，这两件事在数字上一模一样。

**衰减包络别用指数。** 指数永远到不了 0，截断时会留下可见台阶。
幂函数 `(1-u)^1.6` 精确落到 0，实测 0.4s 脉冲最长单档停留仅 10.8ms、档位利用率 80%。

**gamma 必须保持 1.0。** 任何 γ>1 都会把暗段压进 0–2 档。γ=2.2 时单档停留 167ms
且每周期完全熄灭 150ms，肉眼明显。Apple 的 0–1 很可能已做过感知映射。
试过把 gamma 施加到 wave 而非亮度值，更差（367ms），已排除。

**60fps 已触及硬件地板。** 4s 呼吸在 60fps 下最差处仅跳 1 档，90/120fps 完全没有改善。
想改善低亮度段观感要**抬高亮度下限**，不是堆帧率（`--min 0.15@60fps` 优于 `--min 0.05@120fps`）。

**状态栏图标不显示，别在本进程里找原因——先看控制中心的日志。**
2026-08-10 图标彻底消失、点不开面板。真正的判据只有一条：

```bash
/usr/bin/log stream --style compact --predicate 'category == "appStatusItems"'
```

正常的 app 只有 `Starting to track host` → `Adding displayable items`；
出问题时中间多三行 **`Moving host to blocked list`** → `Starting to track blocked host`
→ `hiding status items`。macOS 26 由控制中心统一托管所有状态项，它按
**bundle id** 维护一张 blocked list，被记进去就直接隐藏。

被隐藏时 `NSStatusItem` 不会报错：`isVisible` 仍是 `true`、`button.image` 还在，
只是窗口退化成一个**贴着屏幕右边缘、高 22pt** 的野窗口（`{1432, 934, 38, 22}`，
built-in 菜单栏实际是 33pt、外接是 30pt），正好压在控制中心时钟底下——看不见也点不到。
**高度对不对是最快的体检指标**：等于 22 就是没被托管，等于 33/30 才是真进了菜单栏。

判定是不是 bundle id 的问题只要一步：**把同一个 app 换个 id 再跑**。
实测同一个二进制换 id 立刻正常（`{769, 923, 38, 33}`），
而一个 60 行的最小 app 只要顶着 `com.magickey.MagicKey` 就必然被 block。
`com.magickey.MagicKey2`、`com.magickey.magickey`（只差大小写）都是好的，
所以是**精确 id** 的记录。

**这些统统没用，别再试一遍**：删 app 自己的整个 defaults 域、改/删
`com.apple.controlcenter` 的 `NSStatusItem Visible Item-N`（`killall ControlCenter`
前后都试过）、删 ByHost 的 `displayablemenuextras`、`lsregister -u` 再 `-f`、
显式写 `NSStatusItem Preferred Position`、`isVisible = true`、先 false 再 true。
blocked list 存在哪至今没找到——`~/Library` 全文搜 bundle id 一无所获，
所以**进程外清不掉**。唯一可行的解法是**换 bundle id**（代价：TCC「系统录音」要重授一次，
设置用 `defaults export 旧 - | defaults import 新 -` 迁移；`StateGuard` 走
`~/Library/Application Support/MagicKey/` 路径，不受影响）。

**顺带纠正**：`NSStatusItem.Behavior` 的 `1 << 6` 不是 `neverClip`，**`1 << 7` 才是**
（扫 bit 0–11，只有它让日志打出 `neverClip: true`）。而且置上之后 12/12 照样被 block，
所以这个私有位对本问题毫无用处，别再往代码里加。

**图标「在菜单栏里但看不见」还有第二个原因：被刘海挂件盖住。**
本机装了 NookX（灵动岛），它在**层 101**（状态项是层 25）铺了一个
`x=0..1470, 高 700` 的窗口，中间那块岛是不透明的，实测遮住约 588–870pt。
built-in 菜单栏上控制中心从 900pt 起往右排，于是留给第三方状态项的空档只剩
870–900 这 30pt——装不下一个 38pt 的项，系统就把它放到 769pt，正好在岛底下，
既看不见、点击也被那个高层窗口吃掉。**在内建屏上看不到图标时先确认这一点**，
它和 blocked list 是两件独立的事，可以同时发生。

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

**`MenuBarExtra` 的面板窗口只涨不缩，所以面板改用自己管的 `NSStatusItem + NSPopover`。**
展开「高级」把窗口撑到 717pt 之后，收回、切换效果、**关掉重新打开**都停在 717，
下面留一大片空白。不是布局写法的问题：不套 ScrollView 的对照组一样卡在 1373，
`.id()` 强制重建也无效。同一棵视图树放进 `NSPopover` 是双向跟随的（717→473→326）。
代价只是 AppDelegate 里多四十行（`@main` 从 SwiftUI `App` 换成裸 `NSApplication`，
注意 `NSApplication.delegate` 是**弱引用**，必须自己留强引用）。

**全屏时状态栏按钮的锚点会失效，有两种失效方式，只防住一种等于没防。**

- **① 挪出所有屏幕**：`button.window?.screen == nil`，锚点矩形 y=1114.5 而两块屏最高才 1080。
  面板被 `NSPopover` 摆到主屏原点，还被屏幕边缘裁掉。
- **② 停在另一块屏上**：外接屏全屏时按钮窗口留在**内建屏**，
  「锚点在某块屏幕上」这个检查照样通过 → 面板开到左边那块屏去了。
  内建屏全屏时按钮和指针同屏，所以只在外接屏上复现——**别因为内建屏正常就以为修好了**。

所以判据不是「锚点在不在屏幕上」，而是「**在不在用户刚点的那块屏上**」：
拿 `NSEvent.mouseLocation` 所在屏当基准（刚点完图标，指针就停在图标上），
按钮矩形不落在这块屏上就走鼠标兜底。`show(relativeTo:of:)` 只认视图不收裸矩形，
退路要备一个透明小窗口当锚，`level = .statusBar` +
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，否则它进不了全屏空间。
普通 Space 的锚点 y 可以用 `screen.visibleFrame.maxY`，但全屏 Space 里
`visibleFrame == frame`：直接取 `maxY` 会让 2pt 锚点整个落在屏幕外，
`anchorWindow.screen == nil`，结果 `NSPopover` 被约束回左边的主屏。要同时用
状态栏窗口高度补回全屏时丢掉的上边距（`NSStatusBar.system.thickness`
只做保底，本机返回 22pt，而刘海屏/外接屏的实际菜单栏分别是 33/30pt）。

**面板展开时「所有内容跳一下」，是两个动画在打架。** 逐帧采样发现面板窗口是
**一帧之内**从 473 snap 到 717 的（中间无过渡帧，窗口上沿始终不动），
而 `DisclosureGroup` 自带的展开动画要花几帧滑动**布局**——两者错开一拍就是那一下跳。
解法不是把动画调慢或调快，是**让布局和窗口同一帧到位，只 animate 不参与布局的属性**：
自己搭展开控件，新内容用 `.transition(.opacity)` 淡入，箭头用 `rotationEffect`。
判据很硬：改完再采样，t=0 就是终值且此后不变。

**面板高度的三个坑，是同一个问题的三种表现：**

1. **别「量内容高度再反过来设自己的 frame」**——循环依赖：`@State` 初值 0 →
   `.frame(height: max(0,1))` → 面板 1pt → 量出来还是 0，**永远停在 360×1**。
2. **别把上限拍脑袋写死**。写死 620 时比展开后的真实内容（音乐律动 717pt）还矮，
   于是一展开就进滚动态、头尾被滚出视野。上限要按 `NSScreen.visibleFrame` 算。
3. **正解**：`ScrollView { … }.frame(width:).frame(maxHeight:).fixedSize(horizontal: false, vertical: true)`。
   ScrollView 在滚动轴上默认**贪心**（给多少占多少，内容不足时底部留一大片空白），
   `fixedSize` 让它改取内容理想高，`maxHeight` 封顶，超限时自动恢复滚动。

实测各效果面板高：常亮 326/457、呼吸心跳频闪 390/634、按键脉冲 409/653、
音乐律动 473/717（折叠/展开）。**加新控件前先对着这组数看会不会顶到屏幕上限。**

> 量这些数不需要人工点击：`NSStatusItem.button` 上 `performClick(nil)` 就能程序化
> 打开面板，再读 `NSPopover.contentViewController.view.frame` 和内部 `NSScrollView` 的
> `documentView` / `contentView` 高度差，就知道有没有溢出。探针里把 `Engine` 换成
> 同接口的桩（面板只用到 `available`/`status`/`isRunning` 三个属性），
> 就不必引入 `Driver`/`StateGuard`，也不会动到正在运行的那个实例的崩溃恢复状态。

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
