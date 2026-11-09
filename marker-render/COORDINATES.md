# Coordinate contract — schema 2

## Basis and reproducible coverage

Official API reference: <https://www.reaper.fm/sdk/reascript/reascripthelp.html>.
Marker/scalar and ordinary-envelope observations below were made with REAPER
7.84/macOS-arm64. They describe metadata behavior, not audio acceptance or a
complete SDK contract. No SDK header or private probe output is needed to build.

`tests/test_schema2.lua`, `tests/test_action.lua` (capture-only) and
`tests/test_usability.lua` reproduce the coordinate/rounding assertions with fake
host state. `tests/test_processing_copy.lua` checks ordinary point/metadata copy
and refusal controls through synthetic API seams. These tests do not reproduce
the native-host probes; see README for the bootstrap and separate native test.

## Raw map, then one rounding

Let `R` be source sample rate, `q > 0` finite base take playrate, `L` item duration, `o` source offset, `p_i` raw `GetTakeStretchMarker` position and `s_i` its source coordinate, all seconds.

```text
t_i = p_i / q                # item-relative destination seconds
s_i                         # absolute original-source seconds; no offset addition
```

Native cursor insertion at elapsed 1.25 returns raw position .625 at rate .5, or 2.5 at rate 2. There is no project-position subtraction. Original WAV PCM is read directly, never an already-stretched accessor.

Infer the **raw** absolute source coordinate `S(t)` at item boundaries `t=0,L`:

- No markers: `S(t) = o + q*t`.
- Before first marker: `S(t) = s_first + q*(t - t_first)`.
- After last marker: `S(t) = s_last + q*(t - t_last)`.
- Between bracketing zero-slope markers: linear interpolation of their raw `(t,s)` coordinates.

Only then round each absolute source/destination coordinate with `floor(seconds*R + 0.5)`. Never round raw `p` before dividing by `q`, or interpolate already-rounded coordinates to infer boundaries. Source coordinates are rounded once before subtracting rounded crop start. These rules avoid a second rounding or nonunity crop error.

```text
crop_start = round(S(0)*R)
crop_end   = round(S(L)*R)
output_frames = round(L*R)
job point i = [round(s_i*R)-crop_start, round(t_i*R)]
```

Keep rounded interior markers plus `[0,0]` and `[crop_end-crop_start,output_frames]`. Outside markers still determine boundary interpolation. Raw and rounded user coordinates must strictly increase. Every resulting segment must have positive source/destination extent and destination/source ratio 0.25–4. Refuse collisions, extrapolated overrun, padding or wrap; never move/delete/rewrite user markers. Raw original item chunk stays verbatim for pre-import edit detection.

Native nonunity example: offset 1, item length 4, rate .5, raw markers `(.5,1.75),(1.5,3.25)` imply item times 1 and 3, and raw source boundaries 1.25 and 3.75. Rate 2 with raw markers `(2,3.25),(6,7.75)` implies source boundaries 1.25 and 9.75. The outer source slope is `q`, not always unity.

Harmless LOOP remains untouched only when the complete raw/rounded mapped interval is inside the real bare WAV. Sections/reverse/parent sources remain refused. Python validates the actual WAV extent. Duration/file caps are removed; RIFF32/integer/memory/disk admission still applies. Lua retains at most 1024 user/internal points.

## Editable envelopes are a separate time domain

The second native probe establishes that **ordinary take-envelope API time and serialized PT time are item-relative seconds, unscaled**, at both rates .5 and 2 with source offset 1. Native insertion at project cursor `item_position+1.25` gives API time 1.25 for Volume, Pan and ReaEQ parameter envelopes. Evaluations match copied rate-1 envelopes at the same elapsed item times.

Therefore copy point time **unchanged**; do not divide/multiply by base rate, add source offset or subtract project position. Copy value, shape, tension and selected state; retain envelope metadata/scaling via state with distinct GUID, then rebuild points from API values. Raw fader-scaled volume PT serialization alone can differ from API values, so API readback is mandatory. Original envelope state/API values are checked after the minimal built-in construction; failure rolls back rather than silently altering them. Rollback repairs captured ordinary envelope API values on every preexisting take and verifies their count, order and active identity, rather than trusting raw chunk equality.

Only ordinary Volume/Pan/FX-parameter points are supported. Pitch/Mute envelopes, automation items, nested/pooled states, containers and active modulation/links explicitly refuse pending separate evidence. Admission covers every preexisting take, including inactive ones. Offline FX also explicitly refuse without being loaded/toggled. For ordinary FX envelopes, the measured global `mod.active` flag may be 0 or 1 only when all measured LFO/ACS/link source flags are disabled; a complete all-absent flag state is separately admitted. Partial, malformed, enabled-source or changed copied states refuse.

## Native map and import

`source_analysis::derive` analyzes cropped PCM. `Piecewise::prepare` unions source cuts with non-collinear user breaks, maps cuts to destination frames and rejects collapsed intervals. Collinear points are removed linearly; lookup is logarithmic. The existing 48-byte Range ABI, continuous engine, silent initialization/public reset and Complex-enabled factory are unchanged.

Schema-2 job supplies the saved project's absolute existing normalized non-symlink Audio directory. Exact ten-line receipt names `<Audio>/FlexTime-<nonce>.wav`; Lua checks version, nonce, format, frame count, identity and exact expected path. The final take uses rate1/offset0/pitch0/no markers with processing copied **after**, not baked into the rendered WAV.

Portable map checks use fake host state; they are not new native timing/pitch
measurements. The separate `tests/test_lua_schema2.py` exercises real helper/native
rate-0.5/2 output on the exact pinned installation, but its import/copy seam is
still synthetic. Narrow real REAPER action/copy gates passed at base rates .5
and 2, plus a separate two-original-take native rollback with retained WAV and
synthetic helper reuse; see README for scope and earlier failed attempts. This
focused subset does not reproduce historical long-output checks or resolve the
prior Logic 12.4 short 0.25-ratio pitch-tolerance failure on Logic 13.
