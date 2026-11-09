# Source provenance and external dependencies

The Lua action, Python supervisor/build/test sources and C++ host-side adapters
are project wrapper code. They load separately installed proprietary Logic
frameworks; they do not implement Apple's onset analysis or Polyphonic DSP.
No vendor implementation source, binary, SDK header, disassembly/decompilation
export, copied application or private media is included.

`source_analysis.hpp` carries forward the project's earlier bounded source-onset
analysis adapter and per-invocation owned-file cleanup. `native.cpp` carries
forward its source-provider ABI, exported-symbol lookup, silent initialization /
public reset and continuous render loop. `piecewise.hpp` extends the range-provider
convention with the user-marker/analyzed-cut union. These runtime files are
self-contained with C++/macOS system headers; no sibling adapter tree is required.

**The Logic 13 `CFileRef` lifecycle sequence is reverse-engineered interoperability
code**, derived from observed native callers/destruction rather than a published
SDK or an independently designed vendor ABI. Its 0x88-byte storage, native
None/copy/Set/cache/Init calls and long-string cleanup convention are specific to
the pinned ARM64 build. Native exports retain cache/shared ownership; this is
not an independently implemented analyzer or a claim to Apple's source. Other
versions require fresh ABI/lifetime validation, not a substituted hash.

The action calls documented REAPER ReaScript APIs, including native take-FX copy;
API reference: <https://www.reaper.fm/sdk/reascript/reascripthelp.html>.
No copied REAPER SDK header or SDK-derived license grant is asserted. Coordinate
and envelope-time observations are described in [COORDINATES.md](COORDINATES.md);
metadata probes and fake-host tests do not establish audio or general-host safety.
The separately measured native action/copy and rollback gates are narrowly scoped
in README; they do not establish arbitrary third-party FX compatibility.

## Required installed frameworks

The action targets **Logic Pro 13.0 (7801), ARM64**, dynamically loading from
`/Applications/Logic Pro.app/Contents/Frameworks`. Universal-file SHA-256 pins:

| Framework | SHA-256 |
|---|---|
| MADSP | `debcb14d002a70694077bde72e7a7f17a89f0f21e223be365fd3cb290564f7da` |
| MAMusicAnalysis | `208be62acb634fc42a728a476806ed3bfbc9527009dd5c56507728841e29f196` |
| MAFiles | `287db4300302ae90c2a29b4b5ba27a69c097403574d6ad21d0ee6f0597698bfe` |

These differ from the **Logic 12.4** dependency of the repository-root standalone
wrapper. Short lifecycle and synthetic audio checks motivated the Logic 13
adapter. Narrow REAPER 7.84 native action/copy gates passed at rates .5 and 2,
with a separate retained-WAV rollback gate; offline FX remain unsupported. No
vendor-reference render equivalence, general FX certification or legal permission
is implied by these measurements.

Tests generate synthetic sine/noise/onset media locally. Generated media,
builds/manifests and private diagnostics are excluded from publication.

## Rights

No open-source license has been selected for the original project code. Public
availability is not a blanket MIT or other grant. Proprietary dependencies retain
their own rights and licenses; supply your own normally installed and authorized
copy. Technical feasibility is separate from permission for external execution,
redistribution or commercial deployment. See [../LICENSING.md](../LICENSING.md).
Apple, Logic Pro and REAPER identify their respective products; no affiliation or
endorsement is claimed.
