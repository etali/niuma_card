#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""合成游戏音效（16bit 44.1kHz mono WAV）→ assets/sfx/"""
import math
import os
import struct
import wave

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sfx")
os.makedirs(OUT, exist_ok=True)
SR = 44100


def write_wav(name, samples):
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples)
        w.writeframes(frames)
    print("  " + name + ".wav")


def tone(freq, dur, vol=0.5, attack=0.005, decay_exp=3.0, vibrato=0.0):
    n = int(SR * dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = freq * (1.0 + vibrato * math.sin(2 * math.pi * 6 * t))
        phase += 2 * math.pi * f / SR
        env = min(1.0, t / attack) * math.exp(-decay_exp * t / dur)
        out.append(vol * env * math.sin(phase))
    return out


def noise_hit(dur, vol=0.5, lowcut=0.3, seed=42):
    """滤波噪声冲击（攻击/落桌）"""
    import random
    rng = random.Random(seed)
    n = int(SR * dur)
    out = []
    prev = 0.0
    for i in range(n):
        t = i / SR
        white = rng.uniform(-1, 1)
        prev = prev * lowcut + white * (1 - lowcut)  # 低通
        env = math.exp(-6.0 * t / dur)
        out.append(vol * env * prev * 2.2)
    return out


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, s in enumerate(t):
            out[i] += s
    peak = max(0.01, max(abs(s) for s in out))
    return [s / peak * 0.8 for s in out]


def seq(notes, note_dur, gap=0.0, **kw):
    out = []
    silence = [0.0] * int(SR * gap)
    for f in notes:
        out += tone(f, note_dur, **kw)
        out += silence
    return out


# 抓起：短促上扬
write_wav("pickup", seq([520, 700], 0.05, vol=0.35, decay_exp=6.0))

# 落桌：闷响
write_wav("drop", mix(noise_hit(0.12, vol=0.5, lowcut=0.15), tone(90, 0.1, vol=0.4, decay_exp=8.0)))

# 堆叠吸附：咔哒 + 上翘
write_wav("stack", mix(tone(880, 0.06, vol=0.4, decay_exp=8.0),
                       [0.0] * int(SR * 0.05) + tone(1320, 0.08, vol=0.35, decay_exp=6.0)))

# 配方凑满：风铃双叮（带泛音，和咔哒/金币琶音明显区分）——语义：这个组合可以结算了
def bell(freq, dur, vol=0.4):
    return mix(tone(freq, dur, vol=vol, decay_exp=3.5),
               tone(freq * 2.76, dur * 0.7, vol=vol * 0.3, decay_exp=5.0))
write_wav("complete", bell(1568, 0.16) + [0.0] * int(SR * 0.05) + bell(2093, 0.22))

# 确认组卡：柔和上行双音（区别于成组咔哒和凑满风铃）
write_wav("confirm", seq([523, 784], 0.09, gap=0.04, vol=0.35, decay_exp=3.5))

# 购买：收银叮咚
write_wav("buy", seq([1046, 1318, 1568], 0.09, gap=0.02, vol=0.4))

# 拒绝：低沉双音
write_wav("deny", seq([220, 185], 0.12, vol=0.45, decay_exp=2.5))

# 产出没有自己的音效：产出就是「一批资源牌落到桌上」，
# 每张牌落地各响一声 drop（scenes/main.gd 的 _fly_from）

# 升级：上行五连
write_wav("upgrade", seq([523, 659, 784, 1046, 1318], 0.09, gap=0.02, vol=0.4))

# 攻击：噪声冲击 + 低频
write_wav("attack", mix(noise_hit(0.3, vol=0.7, lowcut=0.4), tone(70, 0.25, vol=0.5, decay_exp=4.0)))

# 组合作废：下行滑音
def slide_down():
    n = int(SR * 0.4)
    out = []
    for i in range(n):
        t = i / SR
        f = 600 * (1 - t / 0.5)
        env = math.exp(-3.0 * t / 0.4)
        out.append(0.45 * env * math.sin(2 * math.pi * f * t))
    return out
write_wav("broken", slide_down())

# 胜利：欢快琶音
write_wav("win", seq([523, 659, 784, 1046, 784, 1046, 1318], 0.14, gap=0.04, vol=0.45))

# 失败：下行挽歌
write_wav("lose", seq([392, 330, 262, 196], 0.25, gap=0.06, vol=0.45, decay_exp=1.8))

print("完成：assets/sfx/")
