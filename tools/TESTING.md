# 剩余两项验收的测试方法

四项验收里 CPU、帧率、ALS 冲突、状态还原已在 30 分钟长测中通过。
剩下两项需要人工介入。

---

## 一、能耗

### 为什么不能只测「跑 / 不跑」

直接对比会把两笔完全不同的成本混在一起：

1. **LED 功耗** —— 取决于平均亮度。用户开背光本来就要付，不是 MagicKey 的锅。
2. **软件功耗** —— 渲染循环的 CPU 和写入开销。这才是 MagicKey 该被问责的部分。

呼吸（`--min 0.05 --max 0.85`）的平均亮度是 **(0.05+0.85)/2 = 0.45**。
所以对照组要固定在 0.45，而不是关掉背光。

### 前置条件

| 条件 | 原因 |
|---|---|
| **拔掉电源线** | 插电时 `Amperage` 恒为 0，什么都测不到。脚本会拒绝运行 |
| 屏幕亮度手动固定，关闭自动亮度 | 屏幕功耗是键盘的几十倍，波动会淹没信号 |
| 退出浏览器、等 Spotlight 索引结束 | 同上 |
| 采样期间不碰键盘和触控板 | 会触发 CPU 活动 |
| 三组测量之间不要改变环境光照 | 环境光自动调节会改变实际亮度 |

### ⚠️ 电池读数测不出软件成本（2026-08-03 实测教训）

第一次尝试用整机电池功耗直接对比 B / C，失败了：

```
B 静态0.45   均值 7115 mW   标准差 441 mW (6.2%)
C 呼吸       均值 6808 mW   标准差 714 mW (10.5%)
C − B = −307 mW   ← 负数，物理上不可能
```

诊断：整机基线 7W、波动 ±500mW，而目标信号只有几十 mW，**噪声比信号大十几倍**。
且 B 左偏、C 右偏，分布形状都不同，说明两次测量的后台负载根本不是同一个基线。

**结论：软件成本必须用 CPU 功耗测（信号占比高得多），电池读数只用来测 LED 成本
（那个信号有几百 mW，测得出来）。**

---

### 第一步：软件成本 → CPU 功耗

键盘 LED 不在 CPU 电源轨上，所以这个对比天然只包含软件开销。

```bash
cd ~/Documents/MagicKey/tools

# 空闲基线
sudo ./measure-cpu-power.sh "空闲" 120

# 跑 MagicKey
./magickey-tool --preview --duration 200 &
sudo ./measure-cpu-power.sh "呼吸60fps" 120
wait
```

差值即软件成本。脚本会打印**标准误**——差值必须明显大于它才可信，
否则说明仍未分辨出来，需要延长采样。

预期量级：MagicKey 占 1.1% CPU，M4 单核满载约 1–2W，故约 **10–30 mW**。

如果差值淹没在噪声里，可以先放大信号再反推：用 `--fps 120` 或 `--effect strobe --period 0.1`
跑一次，若连放大版都测不出来，那真实值必然可以忽略。

---

### 第二步：LED 成本 → 电池功耗（交替配对）

这个信号有几百 mW，电池读数够用，但**必须用交替配对抵消漂移**——
不能像第一次那样 A 测完再测 B，中间系统状态会变。

A/B 各 60 秒，交替三轮：

```bash
for i in 1 2 3; do
  ./magickey-tool --set 0
  ./measure-power.py --label "A-$i 背光关" --duration 60 --settle 15
  ./magickey-tool --set 0.45
  ./measure-power.py --label "B-$i 静态0.45" --duration 60 --settle 15
done
```

取三组**配对差** `B-i − A-i` 的均值。配对能抵消慢漂移，这是第一次测量最大的缺陷。

---

### 原始三组测量（已证明不可用，保留作参考）

每组约 3.5 分钟（30s 静置 + 180s 采样）。**顺序无所谓，但中间不要插电。**

```bash
cd ~/Documents/MagicKey/tools

# A —— 基线：背光关闭
./magickey-tool --set 0
./measure-power.py --label "A 背光关闭" --duration 180

# B —— 对照：静态 0.45（= 呼吸的平均亮度）
./magickey-tool --set 0.45
./measure-power.py --label "B 静态0.45" --duration 180

# C —— 实验：MagicKey 呼吸
./magickey-tool --preview --duration 300 &
./measure-power.py --label "C 呼吸" --duration 180
wait    # 等 MagicKey 自己跑完并还原
```

### 读数

```
B − A  =  LED 功耗          用户开背光的固有成本
C − B  =  MagicKey 软件功耗  ← 这才是要问责的数字
```

判断标准：`C − B` 若在 **100mW 以内**，对一块 ~50Wh 的电池而言是每小时 0.2%，可接受。
若超过 300mW，需要回头压渲染循环（降帧率、增大量化阈值、静态时停表）。

如果脚本报告标准差 >15%，说明有别的负载在干扰，结果不可用，排除干扰后重测。

---

## 二、睡眠 / 唤醒还原

### 要验证什么

`main.swift` 注册了 `NSWorkspace.willSleepNotification`，但**纯 CLI 进程（没有
`NSApplication`）能否收到这个通知从未被验证过**。这是六个还原时机里唯一没测的一个。

### 步骤

```bash
cd ~/Documents/MagicKey/tools
./magickey-tool --preview --duration 900 > /tmp/sleeptest.log 2>&1 &
sleep 10
pmset sleepnow
```

等屏幕黑掉、风扇停下，**至少停 30 秒**，然后唤醒。唤醒后：

```bash
cat /tmp/sleeptest.log
```

### 三种结果

**✅ 收到通知**——日志里有 `系统即将睡眠` 和 `还原原始状态（触发原因: 系统睡眠）`，
进程已退出。当前实现可用。

**⚠️ 没收到通知，进程还在跑**——日志里没有睡眠相关行，时间戳在睡眠期间断档后继续。
说明 `NSWorkspace` 通知在无 `NSApplication` 的进程里不送达。
改用 IOKit 的 `IORegisterForSystemPower`（不依赖 AppKit，且能在睡眠**前**同步回调，
比 `NSWorkspace` 更可靠）。

**❌ 进程消失但没还原**——检查是否有残留快照：

```bash
ls ~/Library/Application\ Support/MagicKey/
```

若有，说明崩溃恢复机制会在下次启动时兜底，但睡眠路径本身失效，同样改用 IOKit。

### 顺带确认

唤醒后跑一次，看键盘亮度和环境光自动调节是否都回到了睡眠前的状态：

```bash
./magickey-tool --analyze          # 不碰硬件，纯看当前配置是否正常
pmset -g | grep -i sleep
```

---

## 注意

正式产品里，睡眠的正确行为是**还原后在唤醒时恢复效果**，而不是像原型这样直接退出。
原型选择退出是为了让还原路径易于验证。
