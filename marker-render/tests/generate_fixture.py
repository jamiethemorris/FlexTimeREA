#!/usr/bin/env python3
"""Create only deterministic synthetic prerequisites for the focused Lua tests."""
from pathlib import Path
import math
import struct

ROOT = Path(__file__).resolve().parents[1]
rate = 48000
pcm = b''.join(struct.pack('<h', round(5000 * math.sin(2 * math.pi * 440 * i / rate)))
               for i in range(rate * 4))
header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36 + len(pcm), b'WAVE',
                     b'fmt ', 16, 1, 1, rate, rate * 2, 2, 16, b'data', len(pcm))
fixture = ROOT / 'tests/fixture.wav'
expected = header + pcm
if fixture.exists():
    if fixture.read_bytes() != expected:
        raise SystemExit('Existing tests/fixture.wav differs; refusing to overwrite it')
    print('Verified existing synthetic tests/fixture.wav')
else:
    with fixture.open('xb') as stream:
        stream.write(expected)
    print('Generated synthetic tests/fixture.wav (4 seconds, 48 kHz, mono PCM16)')
(ROOT / 'evidence').mkdir(exist_ok=True)
(ROOT / 'tests/Audio').mkdir(exist_ok=True)
# The fake host uses this existing WAV path as its named-project seam, not a real RPP.
