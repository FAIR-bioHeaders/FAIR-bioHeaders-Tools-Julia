# Conformance run (Julia reader, specification v0.6.0 vectors)

Acceptance for this package is the shared suite: FAIR-bioHeaders-Specification
release **v0.6.0** `conformance/manifest.json`, **291 vectors**
(119 valid / 172 invalid). Nothing here is a Julia-only suite; the protocol is the
one the suite's own README states, implemented in `src/conformance.jl`.

Run (the suite is checked out at the released tag, never main):

```sh
git clone --branch v0.6.0 --depth 1 \
  https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification /tmp/spec
FAIRBIOHEADERS_CONFORMANCE=/tmp/spec/conformance \
  julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

With `FAIRBIOHEADERS_RECEIPT=<file>` the same run additionally writes the machine-
readable counts CI asserts on (see `README.md`, "Tests"); setting
`FAIRBIOHEADERS_CONFORMANCE` at a directory that holds no `manifest.json` is a missing
fixture and fails the run rather than skipping it.

## Result measured 2026-11-14 (macOS/arm64, Julia 1.13.2, this tree, with native gzip/BGZF input)

| format | pass | fail | undecided | total |
| --- | --- | --- | --- | --- |
| fasta | 98 | 0 | 0 | 98 |
| gfa | 56 | 0 | 0 | 56 |
| fhp-fasta | 36 | 0 | 0 | 36 |
| fhgff3 | 38 | 0 | 0 | 38 |
| jsonld | 0 | 0 | 37 | 37 |
| microdata | 0 | 0 | 26 | 26 |
| **total** | **228** | **0** | **63** | **291** |

An earlier run of the same tree without the gzip/BGZF layer (commits `eaf0f56`+`d6d4512`)
measured **217 / 0 / 74**: the 11 compressed vectors were reported undecided for lack of a
decompressor. They are decided here by `src/gzip.jl` (rule R1 hashes the decompressed
bytes), so the four sequence formats are now fully decided: 98+56+36+38 = 228.

Every decided vector passed, including the one this pass initially failed:
`fhgff3-header-after-fasta` (a `#~` line after `##FASTA`, rule G1) was **accepted**
by the salvaged code because its block-end scan skipped `##FASTA` as a comment; the
scan now ends the FHGFF3 header block at the `##FASTA` line as docs/FHGFF3.md G1
defines, and the vector rejects.

## What this reader does not decide, and why (named)

* **jsonld (37 vectors)** and **microdata (26 vectors)**: these check the JSON-LD
  serialisation and the HTML microdata binding, which need a JSON-LD processor and
  an HTML microdata extractor. This package implements neither; the sibling R and
  JavaScript studies skip the same layers for the same reason. The vectors are
  reported `undecided`, never passed.

The 11 compressed vectors (`fasta-gzip`, `fasta-bgzf`, `fasta-gzip-multimember`,
`fasta-gzip-sequence-tampered`, `gfa-gzip`, `gfa-bgzf`, `gfa-gzip-multimember`,
`fhp-fasta-gzip`, `fhp-fasta-bgzf`, `fhgff3-gzip`, `fhgff3-bgzf`) are no longer on
this list: `src/gzip.jl` decompresses gzip, multi-member gzip and BGZF in Julia
(through the `CodecZlib`/`Zlib_jll` dependency boundary documented in
`docs/CAPABILITY.md`) and rule R1 hashes the decompressed bytes, so each is now
decided like the uncompressed vectors.

Skips are decided by the runner and printed per vector (`decided = false`);
`summarise(outcomes)` produces the table above from a live run, and
`test/runtests.jl` asserts zero decided failures, the expected totals and that no
compressed vector remains undecided.

## Parity statement, bounded

228/228 decided vectors pass on the four sequence formats (FHR FASTA + GFA, FHP,
FHGFF3), uncompressed and compressed alike, on one host at one tag. That is the
whole claim: it is not a family-parity claim (63 shared vectors are undecided here),
and it says nothing about `bioheaders` writer behaviour, JSON-LD or microdata output.

## Draft suites are separate evidence, not this ledger

The rule-V7 lane (docs/CAPABILITY-MATRIX.md) additionally runs the development
suites of the two *draft* types — FHT-Specification `conformance/` (82 vectors,
rules C1-C3) at the pinned suite commit, and FHGM-Specification
`development/conformance/` (62 vectors, rules K1-K6/B1) at its pinned suite commit —
in a separate, labelled CI job (`draft-lane`) and through a local script:

```sh
git clone https://github.com/FAIR-bioHeaders/FHT-Specification /tmp/fht && \
  git -C /tmp/fht checkout --detach 0311ddacbf7559d4160054d23db6fd06898f45a9
git clone https://github.com/FAIR-bioHeaders/FHGM-Specification /tmp/fhgm && \
  git -C /tmp/fhgm checkout --detach b1a82f82f8a2d4a5f5e78240edaa05c6bd9222d8
julia --project=. scripts/draft_vectors.jl --fht /tmp/fht --fhgm /tmp/fhgm
```

Both suites are pinned twice over — contract bytes and suite manifest, each by commit
plus SHA-256 in `drafts/provenance.json` — and the runner refuses to score anything
whose manifest digest differs from the pin (exit 2, nothing reported as passed).
Measured locally on 2026-11-18 after the deliberate dated refresh: FHT **82/82
pass**; FHGM **51 pass, 0 fail, 11 not-run** (exactly the suite's K4-dependent
vectors). These are draft implementation observations, not adoption or release of
contract expectations. Before the native corrections the new suite found two FHGM
failures: `carrier-cites-raw-main` and `model-ids-equal-under-nfc`. The earlier
2026-11-15 pins observed FHT 72/72 and FHGM 35/0/8-of-43; their historical
measurements remain in commit `cfbab3d8ee028734f521ae0f0252629a246b0cbd`.
These numbers never enter the 291/228/63 released ledger and convey no released
FHT/FHGM support. Rule V7, adoption and publication gates stay unchanged.
