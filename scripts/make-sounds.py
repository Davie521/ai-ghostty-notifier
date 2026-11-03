#!/usr/bin/env python3
"""Synthesize the app's two notification sounds into a directory.

    python3 make-sounds.py OUTPUT_DIR

writes ghostty-notify-done.wav (a long run finished) and
ghostty-notify-nudge.wav (a session needs you). Both are a soft electric
piano: FM synthesis with a 1:1 ratio whose modulation index dies away, so each
note starts a little bright and settles round, plus a faint, very short tine.
"Done" is an Fmaj7 chord whose top note arrives a beat late; "nudge" is a
falling third, C then A, the way a doorbell calls.

They are made at build time for the reason the icon is: a readable recipe in
the repository beats committed binaries, and the result is ours to bundle in a
published release, which Apple's /System/Library/Sounds are not. Standard
library only, and it runs on the Python 3.9 that ships with the Command Line
Tools. The output is deterministic.

Levels match Apple's alert sounds: the loudest 400 ms sit at about -26 dBFS
RMS, as Glass does, with peaks kept under -3 dBFS.
"""
import array
import math
import os
import sys
import wave

SR = 48000
TWO_PI = 2 * math.pi
TARGET_RMS_DB = -26.0
PEAK_CEILING_DB = -3.0

NOTES = {"F4": 349.228, "A4": 440.0, "C5": 523.251, "E5": 659.255}

# (note, start in seconds, velocity, pan from -1 left to +1 right)
SOUNDS = {
    "ghostty-notify-done": [
        ("F4", 0.00, 0.70, -0.25), ("A4", 0.00, 0.60, -0.05),
        ("C5", 0.00, 0.60, 0.10), ("E5", 0.12, 0.75, 0.25),
    ],
    "ghostty-notify-nudge": [
        ("C5", 0.00, 0.95, 0.15), ("A4", 0.22, 0.85, -0.15),
    ],
}


def electric_piano(freq, velocity, seconds=1.8):
    n = int(seconds * SR)
    out = [0.0] * n
    w = TWO_PI * freq / SR
    w_tine = w * 7.0
    amp_decay = math.exp(-1.0 / (0.45 * SR))
    index_decay = math.exp(-1.0 / (0.18 * SR))
    tine_decay = math.exp(-1.0 / (0.025 * SR))
    amp, index, tine = velocity, 1.6 * velocity, 0.05 * velocity
    for i in range(n):
        out[i] = amp * math.sin(w * i + (index + 0.15) * math.sin(w * i))
        out[i] += tine * math.sin(w_tine * i)
        amp *= amp_decay
        index *= index_decay
        tine *= tine_decay
    # A 4 ms quarter-sine attack and a 60 ms release: a note cut off
    # mid-waveform at either end clicks.
    attack = int(0.004 * SR)
    for i in range(min(n, attack)):
        out[i] *= math.sin(0.5 * math.pi * i / attack)
    release = min(n, int(0.06 * SR))
    for i in range(release):
        out[n - release + i] *= math.cos(0.5 * math.pi * i / release) ** 2
    return out


def place(left, right, mono, start, pan):
    """Equal-power pan of a mono note onto the stereo bus."""
    offset = int(start * SR)
    angle = (pan + 1) * math.pi / 4
    gain_l, gain_r = math.cos(angle), math.sin(angle)
    need = offset + len(mono)
    if need > len(left):
        left.extend([0.0] * (need - len(left)))
        right.extend([0.0] * (need - len(right)))
    for i, x in enumerate(mono):
        left[offset + i] += x * gain_l
        right[offset + i] += x * gain_r


def reverb(x, combs, allpasses, feedback=0.78, damping=0.35, wet=0.16):
    """A small Schroeder room: damped combs in parallel, then two allpasses."""
    n = len(x)
    acc = [0.0] * n
    for ms in combs:
        size = int(ms * SR / 1000)
        buf, pos, low = [0.0] * size, 0, 0.0
        for i in range(n):
            y = buf[pos]
            low = y * (1 - damping) + low * damping
            buf[pos] = x[i] + low * feedback
            pos = (pos + 1) % size
            acc[i] += y
    for ms in allpasses:
        size = int(ms * SR / 1000)
        buf, pos = [0.0] * size, 0
        for i in range(n):
            delayed = buf[pos]
            y = -acc[i] + delayed
            buf[pos] = acc[i] + delayed * 0.5
            pos = (pos + 1) % size
            acc[i] = y
    return [x[i] * (1 - wet) + acc[i] * wet * 0.25 for i in range(n)]


def loudest_rms_db(left, right, window=0.4):
    mono_sq = [((a + b) / 2) ** 2 for a, b in zip(left, right)]
    size = int(window * SR)
    run = best = sum(mono_sq[:size])
    for i in range(size, len(mono_sq)):
        run += mono_sq[i] - mono_sq[i - size]
        best = max(best, run)
    return 10 * math.log10(best / size + 1e-20)


def render(notes):
    left, right = [], []
    for name, start, velocity, pan in notes:
        place(left, right, electric_piano(NOTES[name], velocity), start, pan)
    tail = [0.0] * int(0.9 * SR)
    left = reverb(left + tail, [29.7, 37.1, 41.1, 43.7], [5.0, 1.7])
    right = reverb(right + tail, [30.9, 36.3, 40.3, 44.9], [5.3, 1.9])

    # Drop the tail once it is 50 dB below the peak, then fade the last 120 ms.
    peak = max(max(map(abs, left)), max(map(abs, right))) or 1.0
    floor = peak * 10 ** (-50 / 20)
    end = len(left)
    while end > SR // 4 and abs(left[end - 1]) < floor and abs(right[end - 1]) < floor:
        end -= 1
    left, right = left[:end], right[:end]
    fade = min(int(0.12 * SR), end)
    for i in range(fade):
        g = math.cos(0.5 * math.pi * i / fade) ** 2
        left[end - fade + i] *= g
        right[end - fade + i] *= g

    gain = 10 ** ((TARGET_RMS_DB - loudest_rms_db(left, right)) / 20)
    ceiling = 10 ** (PEAK_CEILING_DB / 20)
    peak = max(max(map(abs, left)), max(map(abs, right))) * gain
    if peak > ceiling:
        gain *= ceiling / peak
    return [v * gain for v in left], [v * gain for v in right]


def write_wav(path, left, right):
    samples = array.array("h")
    for a, b in zip(left, right):
        samples.append(max(-32767, min(32767, int(round(a * 32767)))))
        samples.append(max(-32767, min(32767, int(round(b * 32767)))))
    if sys.byteorder == "big":
        samples.byteswap()
    # Written beside the target and renamed into place, so an interrupted run
    # never leaves a truncated sound in the bundle.
    partial = path + ".partial"
    with wave.open(partial, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(SR)
        out.writeframes(samples.tobytes())
    os.replace(partial, path)


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: make-sounds.py OUTPUT_DIR (an existing directory)")
    for name, notes in SOUNDS.items():
        left, right = render(notes)
        write_wav(os.path.join(sys.argv[1], name + ".wav"), left, right)


if __name__ == "__main__":
    main()
