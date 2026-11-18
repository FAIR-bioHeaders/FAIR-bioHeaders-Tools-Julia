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
  git -C /tmp/fht checkout --detach 86438f21c3a17a58334c97aed4955be1a2393522
git clone https://github.com/FAIR-bioHeaders/FHGM-Specification /tmp/fhgm && \
  git -C /tmp/fhgm checkout --detach 06176262f9824f26d974a15d8feeebde1fbeb0a8
julia --project=. scripts/draft_vectors.jl --fht /tmp/fht --fhgm /tmp/fhgm
```

Each detached commit above is the pinned files' last-touch commit, verified 2026-11-18
to resolve upstream and to carry the contract, overlay and manifest bytes whose
digests `drafts/provenance.json` records (a clone at that commit reproduces every
pinned digest byte-identically).

Both suites are pinned twice over — contract bytes and suite manifest, each by commit
plus SHA-256 in `drafts/provenance.json` — and the runner refuses to score anything
whose manifest digest differs from the pin (exit 2, nothing reported as passed).
Measured locally on 2026-11-18 (Julia 1.13.2) at the round-13 re-pinned revisions:
FHT **82/82 pass**; FHGM **51 pass, 0 fail, 11 not-run of 62** (exactly the suite's
11 K4-citing vectors, 3 valid and 8 invalid; the split is this library's own —
Julia declares K4 `not-supported-yet` and reports `pass / not-run` proportions that
differ from the JavaScript and Java libraries). These are draft implementation
observations, not adoption or release of contract expectations. Three limitations
travel with these numbers and cannot be seen in a digest diff or a vector count:
(1) the pinned FHGM bytes include FHGM#29's **widening of `layers.model` semantics** —
a `pass` now also asserts trimmed invisible-character-free text, RFC 3986 links with
a real host, non-blank deposits, NFC-unique identifiers and a root-level gene target,
so this pass is not the same claim as a pass under the 2026-11-15 bytes;
(2) **K4 abstention is unresolved upstream** (FHGM#22/#27/#28, FAIR-bioHeaders-Specification#241
open; JS#11 documents the unfalsifiable-`pass` shape) — the 51/0/11 is an honest hole,
not a settled semantics; (3) **4 FHT vectors are `candidate-unreviewed`** promotion
candidates, scored as stated by the suite and not presented as reviewed.
Before the native corrections the new suite found two FHGM
failures: `carrier-cites-raw-main` and `model-ids-equal-under-nfc`. The earlier
2026-11-15 pins observed FHT 72/72 and FHGM 35/0/8-of-43; their historical
measurements remain in commit `cfbab3d8ee028734f521ae0f0252629a246b0cbd`.
These numbers never enter the 291/228/63 released ledger and convey no released
FHT/FHGM support. Rule V7, adoption and publication gates stay unchanged.
