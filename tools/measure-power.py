#!/usr/bin/env python3
"""采样电池放电功率，用于测量 MagicKey 的边际能耗。

用法:
    ./tools/measure-power.py --label "静态0.45" --duration 180

必须拔掉电源——插电时 Amperage 恒为 0，测不出任何东西。
"""
import argparse, re, statistics, subprocess, sys, time

U64 = 1 << 64


def battery():
    """返回 (功率 mW, 是否插电)。放电时功率为正。"""
    out = subprocess.run(["ioreg", "-rn", "AppleSmartBattery"],
                         capture_output=True, text=True).stdout

    def field(name):
        m = re.search(rf'"{name}"\s*=\s*(-?\d+)', out)
        return int(m.group(1)) if m else None

    amp = field("InstantAmperage")
    if amp is None or amp == 0:
        amp = field("Amperage") or 0
    # ioreg 把负数打印成无符号 64 位，需还原
    if amp > U64 // 2:
        amp -= U64

    volt = field("Voltage") or 0
    external = '"ExternalConnected" = Yes' in out
    # amp: mA, volt: mV  ->  mW
    return abs(amp) * volt / 1000.0, external


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True, help="本次测量的条件名")
    ap.add_argument("--duration", type=float, default=180, help="采样时长（秒），默认 180")
    ap.add_argument("--interval", type=float, default=2.0, help="采样间隔（秒），默认 2")
    ap.add_argument("--settle", type=float, default=30, help="正式采样前的静置时长，默认 30")
    a = ap.parse_args()

    _, external = battery()
    if external:
        sys.exit("❌ 当前插着电源。测能耗必须先拔掉电源线，否则电池不放电、读数恒为 0。")

    print(f"条件: {a.label}")
    print(f"静置 {a.settle:.0f}s 让系统稳定（这期间请不要碰键盘和触控板）…")
    time.sleep(a.settle)

    print(f"采样 {a.duration:.0f}s，每 {a.interval:.0f}s 一次…\n")
    samples = []
    t_end = time.time() + a.duration
    while time.time() < t_end:
        mw, external = battery()
        if external:
            sys.exit("\n❌ 采样中途接上了电源，本次结果作废。")
        samples.append(mw)
        bar = "▏" * min(60, int(mw / 100))
        print(f"\r  {len(samples):3d}  {mw:7.0f} mW  {bar}", end="", flush=True)
        time.sleep(a.interval)

    if len(samples) < 3:
        sys.exit("\n采样点太少，加大 --duration。")

    mean = statistics.mean(samples)
    sd = statistics.stdev(samples)
    print(f"\n\n── {a.label} ──")
    print(f"  样本数   {len(samples)}")
    print(f"  均值     {mean:.0f} mW")
    print(f"  中位     {statistics.median(samples):.0f} mW")
    print(f"  标准差   {sd:.0f} mW  ({sd / mean * 100:.1f} %)")
    print(f"  范围     {min(samples):.0f} – {max(samples):.0f} mW")
    if sd / mean > 0.15:
        print("\n  ⚠️  波动偏大（>15%），说明有别的负载在干扰。")
        print("     关掉浏览器/Spotlight 索引，确认屏幕亮度固定，重测。")


if __name__ == "__main__":
    main()
