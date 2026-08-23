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
（2026-08-23 起这条有了边界：**键盘敲击音效**作为默认关闭的可选功能付了这个权限，
见 `KeySoundController`。但**背光线仍然零权限**，键位过滤依旧不做，两条线别混。）

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
cd app   && make probe-ui    # UI 回归：面板高度/收缩/窄屏/五态/更新五态/落点/焦点
cd tools && make analyze     # 分析效果曲线
cd tools && make preview     # 真实键盘预览，Ctrl-C 还原
```

### 工具链：Xcode 26.6 / SDK 26.5（2026-08-11 起）

```bash
xcode-select -p          # → /Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx --show-sdk-version   # → 26.5
```

`swiftc` 走 Xcode 的工具链（Swift 6.3.3），deployment target 仍是 `macos14.0`。

**Liquid Glass 是按「构建时链接的 SDK 版本」启用的，不是按运行时系统版本。**
用 SDK 15.5 编出来的二进制即使跑在 macOS 26 上，系统控件也仍然是 Tahoe 之前的外观
（这正是 Apple 给 SDK 26 编译的 app 留 `UIDesignRequiresCompatibility` 退出开关的原因）。
所以「靠系统免费拿到玻璃」这条也要求 SDK 26，不只是自定义 `glassEffect` 要求。
`app/Makefile` 按 SDK 主版本号定义 `-D LIQUID_GLASS_SDK`，用旧工具链构建时
那段代码整个不编译，自动走 material 回退。

~~**SwiftPM 在这台机器上是坏的**~~ ——那是 CommandLineTools 的 `PackageDescription`
新旧文件混装导致的，装了 Xcode 26 之后不再适用。**但项目仍然用 `make`（swiftc 直接编译）**：
换构建系统不解决任何现存问题，而 Sparkle 这类外部依赖本来就排在代码签名之后。
（旧 CLT 还留下过 `usr/include/swift/module.modulemap` 导致 `swiftc` 完全不可用，
已重命名解决，备份在同目录 `.bak`。切回 CLT 时会再遇到。）

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
| 面板重做「冷光玻璃控制台」 | ✅ Header/2×3 EffectGrid/固定 Footer，探针全绿 |
| 独立设置窗口 `SettingsWindowController` | ✅ 单页 Form 四分组，单例 |
| `Engine.Phase` 结构化状态（绿/灰/橙/红） | ✅ `status` 字符串原样保留 |
| 音乐律动七态 `AudioStatus` | ✅ 含「没声音在放」与推断的「未授权」+ 跳转 |
| `mainMenu` / ⌘Q | ✅ 之前 ⌘Q 完全无效（从未设过 mainMenu） |
| 面板打开即可操作（焦点） | ✅ 锚点改 `.nonactivatingPanel` 拉活应用，探针带阴性对照 |
| UI 探针 `make probe-ui` | ✅ 高度/收缩/窄屏/五态/更新五态/面板落点/面板焦点/设置窗口居中 |
| 状态还原 **六个时机** | ✅ 全部实测：正常退出、手动停止、崩溃重启、系统睡眠、SIGTERM、锁屏 |
| 键盘敲击音效 `KeySound*`（需「输入监控」，默认关） | ✅ 真机验收通过。12 套内置音色（kbsim/MIT，响度对齐 −32dBFS）+ 抬起音 + 防机关枪抖动 |
| 自定义按键音（音色库 + 77 键键盘图指键） | ✅ 真机验收通过。导入验证/响度双向对齐/删音色连带清指键；按下自定义>音色包、抬起归包 |

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
| **macOS 14/15 外观是「能用」不是「做过」** | 2026-08-11 决定不为旧系统做外观。系统控件自动走旧绘制路径（免费），唯一的自定义玻璃有回退：选中格是着色底＋accent 描边，看得见但没设计过；也没有 14/15 的机器可实测 | 真要支持就得先有机器 |
| **发行包是 arm64 单架构** | **Intel Mac 连启动都做不到**（不是外观问题）。而 2020 年前的 MacBook 全是 Intel 且全都有背光键盘，正是目标用户 | `lipo -create` 编 universal 只是一行，但 CoreBrightness 私有接口在 Intel 上是否存在**无机器可验**。README 已写明「Intel 机型无法启动」 |
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
      ② TCC 授权绑定代码签名，ad-hoc 签名每次 `make install` 都掉授权
      （2026-08-06 曾以为推翻，08-23 由 tccd 日志证实成立，见「踩过的坑」）；
      ③ 会推翻「零权限」这条产品线。
      真要做时：`CGEventTap` 监听 `.keyDown` 取 keycode，做成默认关闭的可选项，
      未授权时静默降级回纯 `KeyRepeatFilter` 行为。
      （2026-08-23 注：键盘音效已把「输入监控」做成可选项且用的是 `NSEvent` 监听而非
      `CGEventTap`——真要做黑名单时优先挂在 `KeySoundController` 的事件流上，
      对已为音效授权的用户权限成本为零。）
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

### v1.0 之后

> **发行版本号 2026-08-17 起跳到 1.0**（v0.7 之后直接发 v1.0，旧的 v0.4–v0.7
> release 已删除，tag 保留）。本节这些标题是**功能桶**，不是发行号，别把两者对齐。

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

**TCC 授权确实跟代码签名走，每次 `make install` 都会失效——而且失效得毫无声响。**
本文件 2026-08-06 曾写「实测推翻，授权一直有效」，**那条结论是错的**，
2026-08-23 被 tccd 日志直接证伪。判据只有一行：

```bash
log show --last 10m --style compact --predicate 'process == "tccd"' | grep -i magickey
# → Failed to match existing code requirement for subject io.github.xiaosong1223.MagicKey
#   and service kTCCServiceListenEvent        （AudioCapture 那条同样在报）
```

根因是 ad-hoc 签名的指定要求就是二进制哈希本身：

```bash
codesign -d -r- /Applications/MagicKey.app   # → designated => cdhash H"938f5197…"
```

TCC 在授权那一刻把这条要求存进记录，之后**改一行代码、重新编译，cdhash 就变了**，
记录再也匹配不上。08-06 那次探针之所以报「一直有效」，最可能是它验的量本身
不区分授权与否（`AudioHardwareCreateProcessTap` 未授权照样返回 0，见下一条）——
**一个查不到东西的检查报通过，比没有这个检查更糟**，这里又中了一次。

失效的样子最坑人：**系统设置里那个开关还是打开的、名字也还是 MagicKey**，
而应用查到的是未授权。用户会反复去点那个开关、反复重启应用，全都没用；
`IOHIDRequestAccess` 这时既不弹框也不放行，直接返回 false。
唯一的出路是把那条记录删掉重来（不需要 sudo，只影响点名的那个 bundle id）：

```bash
tccutil reset ListenEvent io.github.xiaosong1223.MagicKey
tccutil reset Microphone  io.github.xiaosong1223.MagicKey   # 「系统录音」同理
```

`KeySoundController.resetOwnRecord()` 就是在应用内跑这一行：面板上的
「重新授权」按钮先清记录再 `IOHIDRequestAccess`，否则用户卡在「等待授权」出不去。
**这不只是开发期的麻烦**——发行包也是 ad-hoc 签名，所以每发一个新版本，
老用户的「输入监控」都会这样静默失效。Developer ID 签名能根治
（那时指定要求变成证书链，与二进制内容无关）；在那之前也可以本地建一个
自签名证书固定签名来免掉开发期的反复授权，代价是要在钥匙串里放一份身份并授权
codesign 使用它（会弹一次系统对话框，无法在无 TTY 的环境里跑完）。

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

**`AVAudioEngine.stop()` 之后 player node 的 `isPlaying` 仍是 true，
按它决定要不要补 `play()` 会永久哑掉。** 键盘音效上线当天用户就报了
「开关关一次再开就没声」：`stop()` 作废了节点的渲染状态，但 12/12 个节点的
`isPlaying` 全留在 true，`start()` 里 `for node where !node.isPlaying { play() }`
整段跳过——引擎显示在跑、scheduleBuffer 正常返回、延迟打点全对，就是没有声音。
修法：拉起时**无条件**先 `node.stop()` 再 `node.play()`（`pause()` 恢复的路径
不受此害，但统一走这条无损）。这个 bug 逃过验收是因为当时的 harness 只量
「事件到达 → scheduleBuffer」的**时序**——时序证明不了**渲染**。判据必须是
在音频图上装 tap 量出 RMS > 0；`probe-ui` 的「渲染回归」组就是这么建的
（mixer 音量 0 + tap 打在 player 节点上，静默可测，带不敲键的阴性对照）。

**NSLog 的动态内容在统一日志里是 `<private>`，装好的 app 等于没有日志。**
`log stream/show` 按内容过滤（哪怕搜格式串后面的 "[keysound]"）一条都查不到，
诊断时两眼一抹黑。`Log.sink` 已改走 `os.Logger` + `privacy: .public`，查日志用：
`log stream --predicate 'subsystem == "io.github.xiaosong1223.MagicKey"'`。

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

**`.accessory` 应用无法自我激活，所以面板的焦点只能从锚点窗口来。**
用户报的是「点开面板要再点一次才能操作」，实际是三个连着的症状：控件全画成灰的
（像禁用）、`.transient` 面板**点别处关不掉**、亮度框打不了字。根子是同一个：
`NSApp.keyWindow == nil`。实测（`NSApp.deactivate()` 之后逐个试）：

| 调用 | 结果 |
|---|---|
| `NSApp.activate()` | 无效 |
| `NSApp.activate(ignoringOtherApps: true)`（已废弃） | 无效 |
| `NSRunningApplication.current.activate(options:)` | 无效 |
| `_NSPopoverWindow.makeKey()` | 无效（`canBecomeKey` 是 true，照样不给） |
| 往 `_NSPopoverWindow.styleMask` 塞 `.nonactivatingPanel` | setter 被 AppKit 吃掉 |

唯一还生效的是**对一个 `.nonactivatingPanel` 窗口 `makeKey()`**，它会连带把应用拉活。
锚点正好是我们自己的窗口，就让它干：`NSPanel([.nonactivatingPanel, .borderless])`
且**必须覆写 `canBecomeKey`**（borderless 默认 false，只给 style mask 不覆写照样无效），
在 `show` **之前** `makeKey()`（反过来最终态一样，但中间几帧面板是灰的）。
面板关掉时要 `NSApp.deactivate()` 把前台还回去，否则用户上一个 app 一直灰着、
敲字掉进黑洞——但**设置窗口开着时不能还**，那正好会把它变灰。

**测这件事必须先把探针自己踢出前台。** 探针进程平时是活跃的，不 `deactivate()`
就会全绿而毫无意义——这也是为什么早先量到 `isActive=true isKey=true`
却和用户的症状对不上：从终端启动的进程继承了激活权，`NSApp.activate()` 当时真的成功了。
真实场景（用户正在别的 app 里点图标）没有这个授权。`make probe-ui` 的
「面板焦点」一组带阴性对照：换回普通 borderless 锚点必须报 `isKey=false`。

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
（2026-08-23 音效区并入后的现值：常亮 321、呼吸类 349、音乐 404、不受支持 219；
音效开启再 +26（响应中）或 +51（警示态）。以 `make probe-ui` 输出为准。）

> 量这些数不需要人工点击：`NSStatusItem.button` 上 `performClick(nil)` 就能程序化
> 打开面板，再读 `NSPopover.contentViewController.view.frame` 和内部 `NSScrollView` 的
> `documentView` / `contentView` 高度差，就知道有没有溢出。探针里把 `Engine` 换成
> 同接口的桩（面板只用到 `available`/`status`/`isRunning` 三个属性），
> 就不必引入 `Driver`/`StateGuard`，也不会动到正在运行的那个实例的崩溃恢复状态。

**面板「只涨不缩」也会在 `NSPopover` 上复发——`.fixedSize(vertical:)` 必须在最外层。**
从 `MenuBarExtra` 换到 `NSPopover` 解决的是同一个症状，但换过来**不等于免疫**。
改成 Header/中段/Footer 三段布局时，我把 `.fixedSize` 从最外层挪到了中间的
ScrollView 上，最外层只剩 `.frame(maxHeight:)`——面板立刻变回只涨不缩
（探针实测：内容 312pt→197pt，面板纹丝不动停在 402pt）。
根因是 `frame(maxHeight:)` 的语义是「**接受**父级提议，钳到上限」，而
`NSHostingController` 提议的正是窗口当前尺寸，于是形成自锁。
`fixedSize(vertical:)` 把提议改成 nil，强制取内容理想高，回路才断。
**顺序是：`ScrollView{}.frame(maxHeight:).fixedSize()` 在里，整棵树再包一次
`.frame(maxHeight:).fixedSize()` 在外。**

**探针换 `contentViewController` 会量出一串假高度。** 已显示的 `NSPopover`
换控制器**不重算尺寸**：内容高正确地变了（241→80），popover 停在旧值不动。
所以 UI 探针必须「只 mount 一次，之后改绑定再量」——这既是真实 app 的路径
（一个控制器活到底、靠 SwiftUI 驱动尺寸），也顺带把「面板缩不缩」变成可回归的。
同理，`Engine` 五态要在**同一个实例**上切（`setProbePhase`），换实例就得换控制器。

**SwiftUI 的无障碍树在进程内查不到，别为它写检查。** 没有辅助客户端连上来时，
宿主视图的 `accessibilityChildren()` 返回 0 个子节点（布局却是好的）。
想强制 materialize 的两条路都是死的：`AXUIElementCreateApplication(getpid())`
查**自己**返回 `-25208`（`kAXErrorCannotComplete`，AX API 不能自查），
设 `AXEnhancedUserInterface` 同样 `-25208`。同一段遍历代码对纯 AppKit 视图是好使的。
**所以无障碍靠构造保证，不靠检查**：面板里的参数行只能由 `paramRow(title:value:help:)`
生成，三个参数必填，漏不掉。听感仍然要人工过 VoiceOver。
（附带一个更普遍的教训：第一版遍历写错找到 0 个控件，却因为「缺标签的也是 0 个」
报了「✅ 全部通过」。**一个查不到东西的检查报通过，比没有这个检查更糟。**）

**`NSPopover` 靠 `contentSize` 定位，而它不会自己跟着 SwiftUI 的尺寸走。**
症状是面板**整体右移 20pt、下移 20pt**，看起来就是「不在图标正下方，还差一截」。
实测（`tools` 外的一次性剖析脚本）：面板都显示出来了，`po.contentSize` 仍然是默认的
**320×320**。于是 NSPopover 按 320×320 算，窗口应为 346×346 摆在锚点正下方；
SwiftUI 布局跑完后宿主视图是 360×300，AppKit 把窗口撑成 386×326，**原点不动**：
宽 346→386、minX 不动 → 中心右移 (386−346)/2 = **20**；
高 346→326、minY 不动 → 顶边下移 (346−326)/2 = **20**。两个 20 是同一个 20。

**箭头是准的，跑掉的是面板本体**——这就是为什么肉眼看着「差不多在下面但又不对」。
所以判据必须落在**内容视图的屏幕坐标**上，量定位矩形一个字都发现不了。
解法是 `PanelHostingController`：在 `viewDidLayout` 里把 `view.fittingSize` 同步给
`popover.contentSize`，并在 `show` 之前手动叫一次（定位就发生在 show 那一刻）。
换效果时面板高度会变（常亮 272 / 音乐 473），所以只在 show 前设一次不够。
设对之后：内容中心与图标中心差 **0.0**，内容顶边比菜单栏下沿低 13pt——
那 13pt 是 popover 窗口四周的透明边距（箭头画在里面），是系统外观，不是空隙。

**别把面板锚在状态项按钮上。** `NSPopover` 是**跟着定位视图的窗口走**的，
而状态项窗口的几何**不由本进程决定**，系统会在两种时机改它，各对应一个真实 bug：

- **高度变**：控制中心托管时窗口高度等于菜单栏（刘海屏 33 / 外接屏 30），
  没被托管时退化成 **22**。开关设置窗口会切一次 `activationPolicy`，菜单栏当场重排，
  状态项窗口有一段时间是 22pt，底边比菜单栏下沿高 11pt → **面板整体上移 11pt**，
  等控制中心重新接管又自己回去。用户报的「点开设置再关掉，面板往上跳一下，过会儿又好了」。
- **整个挪出屏幕**：全屏 Space 里指针一离开屏幕顶端，系统就把菜单栏连同状态项窗口
  挪到屏幕外（实测停在 y=1112，两块屏最高才 1080）。锚点一失效 `NSPopover` 就把面板
  约束回主屏原点 → **「鼠标刚移到面板上，面板就闪到左上角」**。

两个都不该靠「盯着状态项窗口变化再重钉」去补——那是在追一个自己不控制的量。
解法是 `PanelAnchor.place`：面板锚在**自己的** 2pt 透明窗口上，摆好之后没人会再动它。
纵向走屏幕几何（`frame.maxY - visibleFrame.maxY`，全屏 Space 里量不到就用这块屏
在普通 Space 缓存的值），横向由调用方给（图标可用时给图标中心，否则给指针）。
健康时这和 `button.bounds` 给出同一个数，所以不是换位置，是把同一个位置钉死。

**探针那四步是有阴性对照的**：把锚点换回按钮，③ 立刻报上移 11pt、④ 报上移 193pt。
一个查不到东西的检查报通过比没有这个检查更糟，落点这种「看着差不多」的东西尤其要对照。

**`NSWindow(contentViewController:)` 装 SwiftUI 时，尺寸要等第一次布局才定得下来。**
建完那一刻窗口是 **0×32**，拿它算居中，偏差正好是半个窗口（探针报过 `(+240, +210)`）。
`window.layoutIfNeeded()` 不够——它不改窗口尺寸；要 `contentView.layoutSubtreeIfNeeded()`
再按 `fittingSize` 设一次。顺带发现 AppKit 自己定的高度取的是 SwiftUI 声明里的
**minHeight（420）而不是 idealHeight（560）**，所以设置窗口一开就在滚动，
按 `fittingSize` 设完才是那个声明本来的意思。
另外 **`NSWindow.center()` 不是正中**：只有水平居中，垂直方向刻意偏上
（官方措辞 "somewhat above center"）。要正中就自己按 `visibleFrame` 算。

**设置窗口里控件「看不清」，先查激活状态，别去调颜色。**
`.accessory` 应用**无法可靠地自我激活**：`NSApp.activate(ignoringOtherApps:)`
在 macOS 14+ 已废弃，系统会忽略后台应用抢焦点。实测：调完之后
`NSApp.isActive == false`、`window.isKeyWindow == false`，而 `canBecomeKey == true`
——窗口本身没问题，是整个应用没被激活。后果不轻：AppKit 把非 key 窗口里
**每个控件都画成非活跃样式**，开关失去强调色变灰、滑块头是白圆点贴在浅灰轨道上，
在浅色背景里几乎看不见。看起来完全像配色没调好。
解法是开窗前先 `setActivationPolicy(.regular)`，`windowWillClose` 里切回
`.accessory`（切回要推迟一个 runloop，否则 AppKit 在关闭流程半途重排菜单栏和 Dock）。
**判据**：`Log` 里那行 `[settings] isActive=… isKey=…`。
（2026-08-23 起有两个独立窗口——设置和自定义按键音键盘图。切回 `.accessory`
的判据从「我这个窗口关了」变成「**所有**窗口都关了」，逻辑集中在 `AppWindows`：
集合计数、推迟一拍后落地前再验一次。新加窗口必须走它，别自己再写一份。）

**别用 `@State` 去镜像一个 `Binding`，直接从它派生。**
亮度输入框第一版是「`@State text` 存一份，`onChange(of: value)` 时同步过去」。
实测：程序化把 `hi` 从 0.5 改到 0.87，**滑块头动了，输入框还停在 50%**。
镜像状态和真值之间永远存在对不上的时机，再加一条同步路径只是治标。
正解是不留镜像：不在编辑时显示的文字直接由 `value` 算出来，
只有获得焦点期间才存在一份本地草稿（草稿的意义是「编辑期间不回写」——
否则想输 80 的人刚打完 8，键盘就先跳到 8% 再跳回来）。

**`Slider(value:in:step:)` 会换一套外观。** 一传 `step`，AppKit 就把滑块换成
带刻度的细滑块、滑块头变成一根小针，和不带 step 的圆头并排放很突兀。
要离散档位就在 binding 的 setter 里取整，行为一样，外观保持统一。

**`onPreferenceChange` 只看得见自己子树里的 preference。**
量 Header 和 Footer 的高度时，我把收集器分别挂在这两个视图**各自身上**，
于是每个只收到自己那一份，「两块都量到才更新」的守卫永远不成立，
高度停在初值再也不动。大屏上完全看不出来（那个上限根本不起作用），
**只有屏幕矮到上限真正生效时才暴露**——探针的 300pt 压测就是为此存在的。
收集器必须挂在**容器**上。

**给中段留的最小高度不能自己超预算。** 写 `max(140, 上限 - chrome)` 时，
Header+Footer 约 120pt，加上 140 的地板就是 260…320pt，
而外层 `.frame(maxHeight:)` 压不下去——**父级无法把子视图压到它的最小尺寸以下**。
地板的作用只是「别缩到看不见」，取 80 就够。

**判断玻璃好不好看，不能用 `screencapture -l<windowID>` 抓的图。**
按窗口号抓只合成那一个窗口，玻璃背后什么都没有、折射不出任何东西，
于是退化成一块灰——拿这种图去比「嵌套玻璃 vs 着色填充」等于给玻璃判了个不公平的负
（第一轮就是这么比的，玻璃看着像块洗白的板子）。改成 `-R<x,y,w,h>` 区域抓，
把桌面一起带进来，才是用户真正看到的样子。换成区域抓之后结论反过来了，
最终选了嵌套玻璃。**Apple 劝阻嵌套玻璃，但在这个面板上实测是好看的**——
指导是默认值不是禁令，看了再定。

**「玻璃 UI 会不会在旧系统上崩」——2026-08-11 已经查完一遍，别重查。**
答案是不会，而且**这条有编译期硬保证**：Swift 会强制校验 `@available` 与
deployment target，只要 `-target arm64-apple-macos14.0` 编得过，就不存在
26-only API 漏到 14 上。不需要人工逐行审 SwiftUI 调用。
另外「用 SDK 26 编」的含义是「**在 26 上拿得到**玻璃」，不是「把玻璃塞进 14」——
系统控件在 14/15 上自动走旧绘制路径，不用你管。

编译器管不到的只有四类，当时逐个查过：① **SF Symbols 名字是字符串**
（本项目用的全是 SF Symbols 1–2 时代的，安全）；② Info.plist；③ 私有 API
（`responds(to:)` 已经在探测了，缺失降级 `NullDriver`）；④ 系统设置深链锚点
（`Privacy_AudioCapture` 在 14 上未必同名，最坏是跳错面板——`open` 写错锚点不报错）。
**加新符号或新深链时才需要重查这四类，改布局不需要。**

**想看 <26 的自定义外观长什么样，不需要旧机器**：不带 `-D LIQUID_GLASS_SDK`
编一份探针，`--shot <path>` 直接截图。这只能验自定义部分（系统控件仍是本机 26 的画法），
但自定义部分正好是唯一会写错的地方。回退路径也要**单独编一次**确认能过类型检查——
它平时在 `#if` 里被跳过，改错了主构建不会报。

**旧系统真正的风险是架构，不是外观**：二进制 arm64-only，Intel 机器连启动都没有。
见「已知卡点」。

**系统设置的深层链接锚点要从系统二进制里取，别抄。**
「系统录音」是 `Privacy_AudioCapture`，和 `Privacy_Microphone` 是两个不同锚点：

```
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture
```

核对方法：`strings /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension | grep -oE 'Privacy_[A-Za-z]+'`。
**不能靠 `open` 试**——锚点写错时它照样返回 0，只是打开了错误的面板。
**但 strings 那个 Mach-O 查不全**（2026-08-23）：里面只有硬编码在代码里的十来个锚点，
「输入监控」的 `Privacy_ListenEvent` 就不在其中。完整的表在同 bundle 的
`Contents/Resources/TCCServiceList.plist`——`kTCCService…` 条目的
`revealElementKeyName` 字段才是锚点名。先查 plist，再拿 strings 兜底。

**「输入监控」有三个和别的 TCC 权限都不一样的脾气**（2026-08-23，键盘音效实测）：
① **授权对已运行进程不生效**，必须退出重开——勾完之后 `IOHIDCheckAccess` 立刻返回
「已授权」，但 `NSEvent` 全局监听装上去一个事件都收不到。只看当前值就会亮着绿灯却无声，
所以 `KeySoundController` 存了 `grantedAtLaunch` 快照：现在有、启动时没有 →
`.needsRestart` 态（不装 monitor），面板给一键重开。
② **没有 usage description 键**：tccd 的 UsageDescription 列表里没有 ListenEvent
对应项，授权框文案由系统给定，Info.plist 里加什么都没用（核对命令在 Info.plist 注释里）。
③ **探针测不到「被拒绝」**：从终端起的裸可执行文件，TCC 把它算在**终端**头上
（实测返回终端的「已授权」），降级分支永远走不到——必须 `probeAccessOverride` 注入，
launch 快照同理要 `setProbeLaunchAccess` 可注入。
④ **重新构建之后授权会静默失效，而设置里的开关仍显示打开**——见上面
「TCC 授权确实跟代码签名走」那条。面板的 `.blocked` 态和「重新授权」按钮就是为它做的。

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
