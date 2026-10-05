# Nuxt source map regression

`nuxt_4_5_2_index.json` is the source-map field prepared by the actual packed
CloseYourIt CLI 0.29.5 from the Nuxt 4.5.2 certification application's build.
It contains mappings and names only, without source contents or credentials.

- Original generated file: `FpMw82Qr.js.map`, 2,448 bytes.
- Original map SHA-256: `e252ef588ff1cdf6734f3b5591a45bdfd2c51b8f6c641aca3a7206a487aff5fe`.
- CLI-prepared upload body SHA-256: `a7654e559eaa4c964bf61ff2821a1e707bf5d8534b544d180497c23b8dfd8976`.
- Provenance: CYRA-965, real failed run `9650000000000002`; independent rebuild
  matched the map hash in that run's emitted application inventory.
- Node 24.21.0 `SourceMap.findEntry` independently resolves generated (0,520)
  to original (21,4) and (0,633) to (22,70), with `_cache` in both cases.
  Coordinates in this note are zero-based; event readback is one-based.

Both positions contain a named and an unnamed mapping to the same original
position. There are 156 input segments and 154 unambiguous coalesced positions.
