#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""合成漫画特效用的四个音效（16bit 44.1kHz mono WAV）→ assets/sfx/

只写 coin / stamp / bell / trombone 四个文件。tools/gen_sfx.py 会重写全部旧音效
（其中几份已换成后来的 48kHz 版本），新增特效音效因此单独放在这里，可以放心重跑。
"""
import math
import os
import random
import struct
import wave

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sfx")
SR = 44100


def write_wav(name, samples, peak=0.8):
    top = max(0.0001, max(abs(s) for s in samples))
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s / top * peak)) * 32767))
                               for s in samples))
    print("  " + name + ".wav")


def silence(seconds):
    return [0.0] * int(SR * seconds)


def add(base, layer, offset=0.0):
    start = int(SR * offset)
    out = base + [0.0] * max(0, start + len(layer) - len(base))
    for i, s in enumerate(layer):
        out[start + i] += s
    return out


def ping(freq, dur, decay, partials=((1.0, 1.0),), attack=0.002):
    """带泛音的拨响：partials 为 (频率倍数, 相对响度)。"""
    out = []
    for i in range(int(SR * dur)):
        t = i / SR
        env = min(1.0, t / attack) * math.exp(-t / decay)
        out.append(env * sum(a * math.sin(2 * math.pi * freq * k * t) for k, a in partials))
    return out


def coin():
    # 收银叮：短促的低一音接长一点的高一音，带一点金属泛音。
    metal = ((1.0, 1.0), (2.76, 0.18), (5.4, 0.06))
    return add(ping(1975.5, 0.06, 0.03, metal), ping(2637.0, 0.32, 0.09, metal), 0.045)


def stamp():
    # 印章落定：下坠的低频闷响 + 纸面被拍的一下短噪声。
    rng = random.Random(7)
    out = []
    prev = 0.0
    for i in range(int(SR * 0.22)):
        t = i / SR
        freq = 120.0 - 55.0 * min(1.0, t / 0.08)
        body = math.sin(2 * math.pi * freq * t) * math.exp(-t / 0.05)
        prev = prev * 0.55 + rng.uniform(-1, 1) * 0.45
        slap = prev * math.exp(-t / 0.012) * 0.9
        out.append(body + slap)
    return out


def bell():
    # 上市敲钟：三下，钟的分音不成整数倍，余音拖长。
    partials = ((0.5, 0.35), (1.0, 1.0), (1.19, 0.42), (1.5, 0.30), (2.0, 0.26), (2.74, 0.14), (3.76, 0.08))
    strike = ping(392.0, 1.9, 0.55, partials, attack=0.004)
    out = []
    for n, at in enumerate((0.0, 0.42, 0.84)):
        out = add(out, [s * (1.0 - 0.18 * n) for s in strike], at)
    return out


def trombone():
    # 失败的长号：「哇—哇—哇—哇——」四个下行音，最后一个带颤音慢慢泄气。
    notes = ((392.0, 0.30), (370.0, 0.30), (349.2, 0.30), (329.6, 1.05))
    out = []
    phase = 0.0
    for index, (freq, dur) in enumerate(notes):
        last = index == len(notes) - 1
        for i in range(int(SR * dur)):
            t = i / SR
            f = freq * (1.0 + (0.022 * math.sin(2 * math.pi * 5.5 * t) * min(1.0, t / 0.25) if last else 0.0))
            if last:
                f *= 1.0 - 0.05 * max(0.0, t - 0.55)
            phase += 2 * math.pi * f / SR
            # 「哇」的开口：亮度先升后落，高次谐波随之进出。
            open_mouth = math.sin(math.pi * min(1.0, t / (dur * 0.85))) ** 0.8
            bright = 0.25 + 0.55 * open_mouth
            wave_value = sum((bright ** (k - 1)) / k * math.sin(k * phase) for k in range(1, 9))
            env = min(1.0, t / 0.03) * min(1.0, (dur - t) / 0.05)
            out.append(wave_value * env * (0.9 if last else 1.0))
        out += silence(0.03)
    return out


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write_wav("coin", coin(), 0.55)
    write_wav("stamp", stamp(), 0.8)
    write_wav("bell", bell(), 0.75)
    write_wav("trombone", trombone(), 0.7)
    print("完成：assets/sfx/ 下的 4 个特效音效")
