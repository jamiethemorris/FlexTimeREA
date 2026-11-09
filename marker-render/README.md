# Offline stretch-marker render for REAPER

Experimental source-only action for **Logic Pro 13.0 (7801), ARM64**. This is
separate from the repository-root standalone wrapper, which targets **Logic
12.4**. Their framework pins, analysis interfaces and builds are not interchangeable.
Changing a hash alone is not ABI validation.

**Narrow native-host gates have passed on REAPER 7.84/macOS ARM64:** real
helper/action renders at base rates 0.5 and 2 published project-local Audio WAVs
and copied signed gain/pan, an online bypassed ReaEQ and ordinary Volume/Pan/FX
envelopes while preserving the original take. A separate final native rollback
test restored both original takes' API points, order, count and active identity;
it reused a verified prior WAV through an explicit synthetic helper seam, with
no new DSP call. Existing Audio returned native mkdir status 0 and was accepted.
Owned test tabs closed and preexisting tabs were verified unchanged. Earlier
multi-case attempts failed at offline-FX inspection and then existing-directory
admission; those failures are retained, not relabeled as whole-suite passes.
Offline FX now explicitly refuse. These focused gates are not general plug-in,
realtime or normal-project certification. Start with synthetic audio in a
disposable saved project; no listening or vendor-reference equivalence is claimed.

## What the action does

Save a named REAPER project, stop transport, activate the original audio take,
select exactly that one item, and run
`Render selected take with Logic Polyphonic.lua` from REAPER's action list.
Keep the wrapper and the other runtime files together in this directory.

The action reads the original WAV and sends its stretch-marker map to a separate
Python/native process using the installed Polyphonic engine, with Complex enabled.
One continuous engine handles the map, not independently stretched/crossfaded
segments. On verified helper success it publishes a new file exclusively at:

```text
<saved-project-directory>/Audio/FlexTime-<job-nonce>.wav
```

Lua checks the exact version-2 receipt, expected Audio path, metadata, full-file
size/FNV and unchanged project/selection/item/source before adding a new take.
It does not import diagnostic `runs/.../result.wav`. The new take uses rate 1,
offset 0, pitch 0 and no stretch markers, avoiding double timing. The original
take/markers remain available; activate the original again before re-rendering.
Undo removes the new take, **not** the WAV.

### Editable processing is copied, not baked

- Signed take gain (including polarity), pan and pan law copy to the new take.
- Ordinary non-container take FX use `TakeFX_CopyToTake`, with parameter,
  bypass, online-state, channel-count and distinct-identity readback checks.
  Offline FX are refused before introspection, helper execution or mutation;
  the action never loads/toggles them to inspect their state.
- Ordinary Volume, Pan and FX-parameter envelope points copy with unchanged
  item-relative times, value, shape, tension, selection and envelope state.
  GUIDs remain distinct; built-in construction is restricted to the new take.
- Automation items, pooled/nested/unknown envelopes, FX containers, active
  modulation/LFO/ACS/parameter links, built-in Pitch/Mute envelopes and spectral
  edits are refused, not silently dropped. Original processing is rechecked.
- Admission snapshots **every preexisting take**, including inactive takes, so
  unsupported processing on any original take refuses before rendering.
- Copy/import failure attempts item-state rollback and repairs captured ordinary
  envelope API values on all originals; unverified rollback is reported explicitly.
  Portable fault-injection tests remain distinct from the narrow native gate above.

Item-level fades/gain/position and downstream track/routing/master processing
remain in place. Copying FX does not render their processed sound into the WAV.
Arbitrary third-party plug-in state copying has not received live-host acceptance;
the native copy gate used the built-in ReaEQ, not a general FX matrix.

## Requirements and limits

Native execution requires ARM64 macOS, a normally installed and authorized Logic
13.0 (7801) at `/Applications/Logic Pro.app`, its exact three framework hashes in
`render.py` / [ATTRIBUTION.md](ATTRIBUTION.md), `/usr/bin/python3`,
`/usr/bin/sandbox-exec`, Apple clang++, and REAPER with the required ReaScript APIs.
No Python packages or REAPER SDK headers are required. The action uses REAPER's
embedded Lua; the standalone test commands additionally require Lua/luac 5.3+.

Bare PCM16/24/32 or float32 WAV, mono/stereo, 44.1/48 kHz is admitted. Unsupported
RIFF headers, RF64/extensible/compressed files, source sections/reverse/subprojects,
padding and actual looping refuse. A harmless LOOP flag stays unchanged when the
whole mapped span lies inside the source. Positive finite base rates require
pitch 0 and preserve-pitch enabled. Marker slopes must be zero. Channel/stretch
overrides, all-takes-play and locked items refuse. See [COORDINATES.md](COORDINATES.md).

Every local destination/source duration ratio must be 0.25–4. **Admission is not
a quality guarantee:** a prior Logic 12.4 short 0.25-ratio diagnostic failed a
2-Hz pitch tolerance; it has not been re-proven or resolved on Logic 13. No
Logic-reference null test or perceptual equivalence is claimed.
The Lua map limit is 1024 user/job points. There is no arbitrary 30/60-second
or fixed-MiB cap; RIFF32/integer/map bounds, memory and disk admission still apply.
Only the requested crop is decoded/checked for finite samples; full-file identity
is streamed. Memory admission is an estimate, not a hard RSS/VM ceiling or reservation.

`ExecProcess` waits synchronously: no responsive Cancel/progress or hard
whole-supervisor preemption is claimed. Native allowances and Lua's wait scale
with workload. The native sandbox denies network/fork and restricts reads/writes;
only Python publishes into Audio. This is not a comprehensive security guarantee.
FNV detects ordinary local edits, not hostile tampering. Python also checks
SHA-256; Lua checks the SHA receipt field's format, not an independent SHA digest.
Runs retain private path-bearing jobs/diagnostics, and valid Audio files can remain
after import refusal. Failure cleanup is best effort for proven owned files;
crash-atomic cleanup and hostile filesystem race protection are not claimed.

## Fresh build

From this directory:

```sh
python3 build.py build-logic13-1
```

`render.py` selects exactly `build-logic13-1/native`. Builds refuse overwrite.
The analysis directory is compiled as an absolute path: **rebuild after moving
the checkout**. Compilation alone does not load or validate the installed DSP.
Do not invoke the native executable directly: that bypasses the supervisor's
framework checks, sandbox and admission. Never publish local builds/manifests.

## Reproducible focused tests

These commands generate only synthetic media and use fake REAPER state. They do
not launch a DAW or load Logic. From this directory, with Python 3 and Lua/luac:

```sh
python3 tests/generate_fixture.py
lua tests/test_action.lua "$PWD" capture-only
lua tests/test_schema2.lua "$PWD"
lua tests/test_receipt2.lua "$PWD"
lua tests/test_processing_copy.lua "$PWD"
lua tests/test_envelope_scope.lua "$PWD"
lua tests/test_modulation_admission.lua "$PWD"
lua tests/test_offline_fx.lua "$PWD"
lua tests/test_existing_audio.lua "$PWD" FreshPortable1Existing
lua tests/test_copy_rollback.lua "$PWD" FreshPortable1
lua tests/test_usability.lua "$PWD"
lua tests/test_guards.lua "$PWD" capture-only
lua tests/test_fingerprint.lua "$PWD" FreshPortable1
luac -p ./*.lua tests/*.lua
```

Choose a fresh ASCII-alphanumeric prefix instead of `FreshPortable1` for each
repeat: tests preserve existing jobs and evidence rather than overwrite them.
The generator creates a deterministic four-second 48-kHz mono PCM16 sine WAV,
refuses to overwrite differing content, and creates the ignored evidence/Audio
directories. The fake project's existing named-file seam is this WAV, **not**
a real REAPER project. Rollback tests use explicit synthetic receipts, not DSP.
The fingerprint test retains a synthetic 36,864,044-byte sparse file.

After building on the exact supported installation, the separate native test is:

```sh
python3 tests/generate_fixture.py
python3 tests/test_lua_schema2.py FreshNative1
```

It repeats portable checks, synthesizes its own onset/tone source, then runs two
real helper/native renders at base rates 0.5 and 2. It checks dimensions,
finite/canaries, landmark timing, pitch, output hashes and timeout-formula agreement;
import/copy/rollback still use a fake host. Use a fresh prefix for each invocation.
This native test is not a live-host acceptance test. Historical broader matrices
and long-source measurements are not reproduced by this focused subset. Public
package verification results are summarized below; generated evidence stays local.

## Package verification

The public source revision was exercised as follows (no DAW launch for these checks):

- A fresh source-only export, without existing media/builds/evidence, passed every
  portable command above, including the new envelope-scope, modulation, offline-FX,
  existing-Audio and multi-original rollback controls plus Lua syntax checks.
- `python3 build.py build-public-final1` compiled cleanly with `-Werror` at a fresh
  path. The preserved `build-logic13-1` executable and all three compiled-source
  hashes matched its original local build manifest; no existing build was replaced.
- `python3 tests/test_lua_schema2.py PublicFinalNative1` passed from this public
  tree using that verified fixed-path runtime. Both real native renders produced
  192,000 mono frames at 48 kHz; maximum measured landmark error was about 5 ms
  and measured stable-tone pitch was 439.999 Hz in each. Finite samples/canaries,
  SHA-256, unchanged source and workload timeout agreement passed. Copy/attachment
  failure controls reused verified output through explicit synthetic helper seams.

Generated binaries, manifests, WAVs and receipts remain local and ignored. These
checks do not expand the separately reported native-host or audio-quality scope.

## Source and rights

Runtime closure: the action wrapper, `marker_render.lua`, `render.py`, `build.py`,
`native.cpp`, `piecewise.hpp` and `source_analysis.hpp`. Only these sources,
README/coordinate/attribution documents and the listed synthetic test sources
belong in this package. No sibling adapter checkout or private evidence tree is
required. Do not publish `build*/`, `runs/`, `evidence/`, generated Audio/WAVs,
user projects/media, vendor frameworks, copied apps or private receipts.

No open-source license has been selected. See [../LICENSING.md](../LICENSING.md)
and [ATTRIBUTION.md](ATTRIBUTION.md). This wrapper is interoperability research,
not an Apple SDK, a reimplementation of the DSP, or vendor-supported integration.
