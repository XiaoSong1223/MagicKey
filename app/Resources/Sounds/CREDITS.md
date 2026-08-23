# 键盘音效采样来源与许可

本目录下的全部 `.mp3` 采样来自 **kbsim（Mechanical Keyboard Simulator）**，
以 **MIT License** 发布，允许再分发（含商用与再授权），条件是保留版权声明与
许可原文——本目录的 `LICENSE-kbsim.txt` 就是那份原文。

| 项目 | 内容 |
|---|---|
| 上游仓库 | <https://github.com/tplai/kbsim> |
| 项目主页 | <https://kbs.im> |
| 作者 | Thomas Lai |
| 许可证 | MIT License（仓库根目录 `LICENSE.md`，全文见 `LICENSE-kbsim.txt`） |
| 取样时的提交 | `ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4`（2021-12-23） |
| 上游路径 | `src/assets/audio/<音色包名>/` |

kbsim 的 MIT 许可覆盖整个仓库（README 的项目结构一节把 `LICENSE.md` 标为
"MIT license"，`src/assets/audio` 就在该仓库内），**没有对音频资源单列例外**。

## 旁证

另一个独立项目 [nathan-fiscaletti/keyboardsounds](https://github.com/nathan-fiscaletti/keyboardsounds)
同样再分发了这批采样，并在每个音色包目录里放了一份 `LICENSE`，开头写着：

> Audio samples from https://github.com/tplai/kbsim
>
> Copyright (c) Thomas Lai
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software …

即第三方也是按「MIT，署名后可再分发」来理解并执行的。

## 本项目做了什么改动

**文件本身逐字节未改**，原样拷贝，目录结构（`press/` 与 `release/`）也保持上游布局，
方便逐个文件回溯。收录前核对过：现有的 `boxnavy` / `holypanda` / `mxbrown`
与上述提交里的对应目录 `diff -r` 完全一致。

运行时会在**内存里**做三件事，不写回磁盘：

1. 解码为 PCM 并统一重采样到 44.1 kHz / 立体声 / Float32（单声道升混为双声道）
2. 乘以一个响度对齐系数，让十二套包在同一个音量刻度下听起来一样响
3. 预先生成 ±3% 的音高变体，播放时随机取一个，避免连打时变成「机关枪」

## 收录了哪些、为什么不收另一些

上游在该提交里有 13 套。收录判据是**大键位专属采样齐全**：
`press/` 与 `release/` 里都要有 `SPACE`、`ENTER`、`BACKSPACE`，
并且 `press/` 有 `GENERIC_R0…R4` 一组通用采样。

真实键盘上不同键的音色差别来自**键帽尺寸和稳定器**（空格、回车、退格有大键位的
卫星轴），缺了这三条专属采样的包，敲空格和敲字母会是同一个声音——
那正是「假」的来源，比少一套音色更糟。

| 上游目录 | 收录 | 原因 |
|---|---|---|
| `alpaca` `blackink` `bluealps` `boxnavy` `buckling` `cream` `holypanda` `mxblack` `mxbrown` `redink` `topre` `turquoise` | ✅ 12 套 | press/release 齐全 |
| `mxblue` | ❌ | **只有 `GENERIC` 系列**：`press/` 里没有 SPACE / ENTER / BACKSPACE，`release/` 里只有一个 `GENERIC.mp3` |

另外 `bluealps/release/` 比其余各包多一个 `GENERIC_long.mp3`。
按「原样拷贝」的原则留着了，但**本应用不加载它**——
`KeySoundSlot.releaseFileNames` 只取 `GENERIC`。响度测量时也排除了它，
否则这一套的对齐系数会被一条从不播放的采样带偏。

## 十二套音色

响度是实测值：用 `AVAudioFile` 解码每套包**实际会被加载的那 12 个文件**，
全部声道的全部样点一起算 RMS 与峰值——和 app 加载采样走的是同一条解码路径。

对齐目标取**全部包里最响的那个**（`bluealps`，−32.00 dBFS），
于是 `gain` 恒 ≥ 1.0：只放大不衰减，衰减等于白白丢掉本来就不多的动态。
`峰值 × gain` 全部 ≤ 0.9，留出的余量给后面两道放大用
（±3% 重采样的滤波器过冲，以及播放时 ±2 dB 的音量抖动，最高 ×1.259）。

| 目录 | 面板里的名字 | 轴体 | 听感 | RMS dBFS | 峰值 | gain | 峰值×gain |
|---|---|---|---|---|---|---|---|
| `boxnavy/` | 清脆（Box Navy） | Kailh Box Navy | 高频点击声，脆 | −37.05 | 0.333 | 1.79 | 0.595 |
| `bluealps/` | 铿锵（SKCM Blue Alps） | Alps SKCM Blue | 金属感的清脆，本组最响 | −32.00 | 0.422 | 1.00 | 0.422 |
| `buckling/` | 老派（IBM Buckling Spring） | IBM 屈曲弹簧 | 老式打字机，弹簧回响 | −38.46 | 0.150 | 2.10 | 0.315 |
| `holypanda/` | 厚实（Holy Panda） | Holy Panda | 低频「thock」，闷而饱满 | −33.56 | 0.333 | 1.20 | 0.398 |
| `topre/` | 绵密（Topre 静电容） | Topre 静电容 | 有缓冲感，不硬 | −39.76 | 0.294 | 2.44 | 0.718 |
| `cream/` | 浑厚（NovelKeys Cream） | NK Cream（POM） | 厚，尾巴长 | −35.89 | 0.545 | 1.56 | 0.853 |
| `blackink/` | 深沉（Gateron Ink Black） | Gateron Ink Black | 深，收得干净 | −37.37 | 0.349 | 1.85 | 0.647 |
| `mxblack/` | 闷响（Cherry MX Black） | Cherry MX Black | 钝，几乎没有高频 | −32.37 | 0.548 | 1.04 | 0.572 |
| `redink/` | 圆润（Gateron Ink Red） | Gateron Ink Red | 顺，棱角少 | −34.93 | 0.415 | 1.40 | 0.581 |
| `turquoise/` | 顺滑（Turquoise Tealios） | Tealios（线性） | 干净利落的线性声 | −37.11 | 0.283 | 1.80 | 0.510 |
| `mxbrown/` | 轻柔（Cherry MX Brown） | Cherry MX Brown | 段落感轻，最不吵 | −35.98 | 0.301 | 1.58 | 0.475 |
| `alpaca/` | 安静（Alpaca） | JWK Alpaca（线性） | 本组最轻的一套 | −40.18 | 0.242 | 2.56 | 0.620 |

> 轴体名不是凭印象写的，取自上游各模块的 `caption`
> （`src/features/audioModules/*.js`）。核对是有意义的：`turquoise` 听起来
> 像个点击轴，上游写的却是 **Turquoise Tealios**，一个线性轴。

⚠️ **这张表在 2026-08-23 扩包时整体重算过。** 对齐目标是「全部包里最响的那个」，
加包就可能把目标顶上去——`bluealps` 比原先的目标 `holypanda`（−33.6 dBFS）
响 1.56 dB，于是全表的 gain 都跟着变了。旧的三个系数
（Box Navy 1.50 / Holy Panda 1.00 / MX Brown 1.32）已作废。
副作用：同一个音量滑块位置比 v1.0 整体响约 1.6 dB。

**以后再加包，这张表必须整表重算**，不能只给新包算一个系数。

## 每套包里有什么

`press/`（按下）8 个：`SPACE` `ENTER` `BACKSPACE` 各一，通用键 `GENERIC_R0…R4` 五个。
`release/`（抬起）4 个：`SPACE` `ENTER` `BACKSPACE` 各一，通用键 `GENERIC` 一个。
（`bluealps/release/` 另有一个不被加载的 `GENERIC_long.mp3`，见上。）

**抬起音是上游的真实录音，不是由按下音合成的变体。**

## 用户自己导入的采样

「自定义按键音」导入的文件**不在本目录**，也不随应用分发——
它们被拷进 `~/Library/Application Support/MagicKey/CustomSounds/`，
只属于那台机器上的那个用户。导入时会按上面同一个目标
（`KeySoundPack.loudnessTargetDBFS`）做响度对齐，所以自己录的声音
不会突然比内置音色响一大截。
