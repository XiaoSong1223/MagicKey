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
| 上游路径 | `src/assets/audio/{boxnavy,holypanda,mxbrown}/` |

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
方便逐个文件回溯。

运行时会在**内存里**做三件事，不写回磁盘：

1. 解码为 PCM 并统一重采样到 44.1 kHz / 立体声 / Float32（单声道升混为双声道）
2. 乘以一个响度对齐系数，让三套包在同一个音量刻度下听起来一样响
   （实测 RMS：Box Navy −37.1 dBFS、Holy Panda −33.6 dBFS、MX Brown −36.0 dBFS）
3. 预先生成 ±3% 的音高变体，播放时随机取一个，避免连打时变成「机关枪」

## 收录的三套

| 目录 | 面板里的名字 | 轴体 | 听感 |
|---|---|---|---|
| `boxnavy/` | 清脆（Box Navy） | Kailh Box Navy | 高频点击声，最响最脆 |
| `holypanda/` | 厚实（Holy Panda） | Holy Panda | 低频「thock」，闷而饱满 |
| `mxbrown/` | 轻柔（MX Brown） | Cherry MX Brown | 段落感轻，最不吵 |

## 每套包里有什么

`press/`（按下）8 个：`SPACE` `ENTER` `BACKSPACE` 各一，通用键 `GENERIC_R0…R4` 五个。
`release/`（抬起）4 个：`SPACE` `ENTER` `BACKSPACE` 各一，通用键 `GENERIC` 一个。

**抬起音是上游的真实录音，不是由按下音合成的变体。**
