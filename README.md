# FlexTimeREA

Experimental source-only offline wrapper around the **separately installed**
Logic Pro MADSP framework. This is not a standalone replacement for Logic's
engines, a public Apple API, or a REAPER stretch plug-in.

## Status and dependency

- Native execution is limited to macOS **arm64**, the investigated Logic Pro
  **12.4** framework, and the exact SHA-256 pinned in `build.py`:
  `1fd28ddf6592db72533511ea6f916d9a500659269c8a2f71ff758e9f90376e3b`.
  Other versions/architectures require independent ABI validation; changing the
  hash alone is not validation. Install and authorize Logic normally yourself.
- Default dependency: `/Applications/Logic Pro.app/Contents/Frameworks/`.
  Set `FLEX_LOGIC_APP` to another installed app bundle before **both building and
  testing/rendering**. `CXX` selects a C++17 compiler (default `c++`). The library
  also depends on other Logic private frameworks: do not extract/copy it out.
  The generated sandbox deliberately does not admit a bundle under HOME outside
  this checkout; use a normal application installation outside HOME. Arbitrary
  relocated installs/dependency layouts are not validated.
- Polyphonic, Speed and Tempophone have synthetic offline regression coverage.
  Rhythmic and Slicing require **explicit source onset frames**; no automatic
  transient analysis is provided. Monophonic is deliberately refused because
  its separate pitch-analysis-provider contract is unresolved.
- No Logic-reference null test, audio-quality equivalence, general latency/tail
  contract, supported commercial deployment, or complete REAPER integration is
  claimed. This tree contains no vendor DSP implementation, binary, disassembly,
  private input audio, or raw investigation evidence.

## Build and run

Requires Python 3.10+, C++17, and macOS `sandbox-exec` for native tests/renders.
From this directory:

```sh
python3 build.py
python3 -m unittest test_build test_renderer test_modes -v
python3 offline.py input.wav --stretch 1.5
python3 offline.py input.wav --mode slicing --stretch 0.75 --transients 24000 72000
```

`input.wav` is **your own** uncompressed PCM16 WAV: mono/stereo, 44.1/48 kHz,
1 frame through 30 seconds. `--stretch` is output/input duration, 0.5–2.
`--block` is 1–1024 frames. Speed changes pitch with duration; the other admitted
modes use the installed engines' stretch behavior. Explicit transient frames
must be strictly increasing and inside the source, excluding start/end.

Default output is a unique `runtime/render-*/output.wav`. `--output` must name
an absent file below `runtime/`; existing files are never overwritten. Each
native child has a 20-second deadline. Generated PCM, WAVs, path-bearing JSON
receipts, the executable and generated sandbox policy remain ignored in
`runtime/`; **do not publish that directory**.

`build.py` compiles without loading MADSP, checks its exact dependency hash,
then preflights the generated local sandbox with synthetic data. The preflight
checks denied loopback connection, denied out-of-runtime write and denied
unrelated synthetic read, plus permitted runtime writes. Its temporary sentinel
is created beside this checkout and removed; the checkout should be inside
HOME for this particular read-denial check. The policy denies child network,
fork and outside-runtime writes, and home reads except this checkout. It is an
experimental macOS policy, not a comprehensive sandbox/security guarantee.
It never changes system security settings or reads real personal config as a
preflight sentinel. If the preflight fails, stop; do not disable it to run DSP.

For source-build checks without Logic or a supported execution host:

```sh
python3 build.py --compile-only
python3 -m unittest test_build -v
```

This compiles the wrapper but **does not validate native DSP execution**. Do not
invoke `runtime/flex-render` directly: direct invocation bypasses Python-side
framework hashing, sandboxing and WAV checks. `offline.py` is the intended entry.
The source/build paths are checkout-relative; native framework operation is
intentionally not cross-platform. Linux compile support is not a Linux engine.

## Source map and tests

- `flex-render.cpp`: independent host-side lifecycle, provider buffers, constant
  time map, symbol binding and bounded float-PCM renderer. It calls an
  undocumented version-specific ABI; it does not implement Apple's algorithms.
- `build.py`: compiler, dependency identity and local sandbox preflight.
- `offline.py`: bounded PCM16 WAV conversion and native-child supervision.
- `test_renderer.py`: lifecycle, pitch/channel checks and refusal controls.
- `test_modes.py`: mode/rate/channel/short-source/silence matrix, timing and pitch
  checks, transient validation, output non-overwrite and native refusal tests.
- `test_build.py`: portable installation-path configuration check.

Tests synthesize all audio locally. Test receipts are not reference music or
proof of perceptual quality. Keep native-execution requirements distinct from
compile-only/configuration checks.

## REAPER boundary

The separate reusable ExtraShifter provider experiment is planned for
<https://github.com/jamiethemorris/reaper-extrashifter>. It demonstrates an
**undocumented reserved loading hook** and a unity-only adapter, not a completed
Polyphonic engine integration. This repository does not import or install that
provider, modify a REAPER bundle, launch a DAW, or implement the future engine
integration. See `LICENSING.md` before reuse or publication.
