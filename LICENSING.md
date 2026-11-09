# Source and dependency rights

This publication candidate contains host-side wrapper, build and synthetic-test
sources. It does not contain Apple binaries, DSP implementation source,
disassembly/decompilation exports, or licensed music. ABI names and layouts are
interoperability information, not a vendor SDK or a promise of supported use.

The `marker-render/` action includes a narrowly reverse-engineered Logic 13
`CFileRef` lifecycle sequence derived from observed native callers/destruction.
It is not a published vendor SDK or an independently designed vendor ABI; no
claim of ownership or broad license over Apple's implementation is made. See
`marker-render/ATTRIBUTION.md` for provenance and exact dependency pins. The
repository-root standalone wrapper targets Logic 12.4; the action targets Logic
13.0 (7801), ARM64. These version-specific adapters are not interchangeable.

**No open-source license has been selected for the original project code.**
Public source availability alone is not a broad grant to copy, modify or
redistribute it. The project owner must choose an explicit license if that is
intended. No blanket MIT or other grant is asserted here, especially not over
Apple software or recovered proprietary implementation.

Logic Pro and its frameworks remain proprietary and subject to their own
licenses and applicable law. Users must supply their own normally installed,
authorized copy. Technical interoperability does not establish legal permission
for external execution, redistribution or commercial use. No authorization,
copy-protection, signing or OS security bypass is included. Obtain appropriate
licensing/interoperability review before distributing or deploying this wrapper.

Apple, Logic Pro and REAPER names identify their respective products; this
project is not affiliated with or endorsed by their vendors.
