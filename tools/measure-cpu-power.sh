#!/bin/zsh
# 测量 CPU 封装功耗，用于隔离 MagicKey 的软件成本。
#
# 为什么不用电池读数：整机基线约 7W、波动 ±500mW，而目标信号只有几十 mW，
# 分辨不出来。CPU 功耗基线只有几百 mW，且键盘 LED 不在这条电源轨上，
# 正好把「软件成本」和「LED 成本」分开。
#
# 用法:  sudo ./tools/measure-cpu-power.sh <标签> [秒数]

set -e
LABEL="${1:?用法: sudo $0 <标签> [秒数]}"
SECS="${2:-120}"

if [[ $EUID -ne 0 ]]; then
  echo "❌ powermetrics 需要 root。请用: sudo $0 \"$LABEL\" $SECS" >&2
  exit 1
fi

echo "条件: $LABEL"
echo "采样 ${SECS}s（每秒一次）…期间请不要碰键盘和触控板"
echo

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

powermetrics --samplers cpu_power -i 1000 -n "$SECS" 2>/dev/null > "$TMP" || true

python3 - "$TMP" "$LABEL" <<'PY'
import re, statistics, sys

path, label = sys.argv[1], sys.argv[2]
text = open(path, errors="ignore").read()

# 不同机型字段名不一致，按优先级取第一个有数据的
for key in ("Combined Power (CPU + GPU + ANE)", "CPU Power", "Package Power"):
    vals = [float(m) for m in re.findall(rf"{re.escape(key)}:\s*([\d.]+)\s*mW", text)]
    if len(vals) >= 3:
        break
else:
    sys.exit("❌ 没解析到功耗数据。手动跑一次看看输出格式：\n"
             "   sudo powermetrics --samplers cpu_power -i 1000 -n 3")

# 丢掉前 5 个样本——powermetrics 启动本身会造成尖峰
vals = vals[5:] if len(vals) > 15 else vals

mean = statistics.mean(vals)
sd = statistics.stdev(vals)
print(f"── {label} ──（字段: {key}）")
print(f"  样本数   {len(vals)}")
print(f"  均值     {mean:.1f} mW")
print(f"  中位     {statistics.median(vals):.1f} mW")
print(f"  标准差   {sd:.1f} mW  ({sd/mean*100:.1f} %)")
print(f"  标准误   {sd/len(vals)**0.5:.1f} mW   ← 两组差值需明显大于此值才可信")
PY
