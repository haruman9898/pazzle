#!/usr/bin/env python3
"""効果音の素材を、標準ライブラリだけで合成する（外部の音源は使わない。小さな波形ファイル）。
バブルの破裂音は、このシステムの気持ちよさの中心なので、音程違いを3つ用意し、
ゲーム側で連鎖に応じて音程を上げる。
使い方: python3 tools/make_sounds.py  → game/assets/sounds/*.wav
"""
import math, os, random, struct, wave

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "game", "assets", "sounds")
os.makedirs(OUT, exist_ok=True)

def write(name, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s / peak * 0.85)) * 32767)) for s in samples)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data)

def pop(f0, dur=0.18, seed=1):
    rnd = random.Random(seed)
    out = []; phase = 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        f = f0 * (1.7 * math.exp(-t * 18.0) + 0.7)              # 上から下へ素早く落ちる（ぷちっ）
        phase += 2 * math.pi * f / SR
        env = math.exp(-t * 26.0)
        tone = math.sin(phase) * env
        click = (rnd.random() * 2 - 1) * math.exp(-t * 400.0) * 0.8   # 最初の短い破裂
        out.append(tone + click)
    return out

def place(dur=0.26, seed=2):
    rnd = random.Random(seed)
    out = []; phase = 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        phase += 2 * math.pi * (95 + 110 * math.exp(-t * 30.0)) / SR
        out.append(math.sin(phase) * math.exp(-t * 13.0) + (rnd.random() * 2 - 1) * math.exp(-t * 220.0) * 0.5)
    return out

def demolish(dur=0.34, seed=3):
    rnd = random.Random(seed)
    out = []; phase = 0.0; lp = 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        phase += 2 * math.pi * (140 * math.exp(-t * 6.0) + 55) / SR
        n = rnd.random() * 2 - 1
        lp += (n - lp) * 0.25
        out.append(math.sin(phase) * math.exp(-t * 9.0) * 0.8 + lp * math.exp(-t * 11.0))
    return out

write("pop0.wav", pop(520, seed=11))
write("pop1.wav", pop(640, seed=12))
write("pop2.wav", pop(770, seed=13))
write("place.wav", place())
write("demolish.wav", demolish())
for f in sorted(os.listdir(OUT)):
    print(f, os.path.getsize(os.path.join(OUT, f)), "bytes")
