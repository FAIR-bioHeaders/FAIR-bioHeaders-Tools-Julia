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

## Development suites are separate evidence, not this ledger

The explicit rule-V7 lane reads development contracts and does not adopt the
family's subsequently published FHT/native FHGM selection forms. The deliberate
2026-11-20 PR19 CI repair pins FHT `fht.json` at last-touch `eb6c36d3` and its
93-vector suite at `e6ba1c73`; FHGM's record contract and transport overlay remain
unchanged, while its 92-vector suite is pinned at `e8e26d7c`. Full commits,
SHA-256 and byte counts are in `drafts/provenance.json`. Source contents-API blobs
were base64-decoded and cross-checked against content-addressed Git objects;
JSON rendering or HTTP content-length was not used to measure source bytes.

```sh
git clone https://github.com/FAIR-bioHeaders/FHT-Specification /tmp/fht
git -C /tmp/fht checkout --detach e6ba1c737c9caddc53b99a4a107825d7a16a4765
git clone https://github.com/FAIR-bioHeaders/FHGM-Specification /tmp/fhgm
git -C /tmp/fhgm checkout --detach e8e26d7cb9024b83e474045291f56a46e57a1ecf
julia --project=. scripts/draft_vectors.jl --fht /tmp/fht --fhgm /tmp/fhgm
```

Measured on Julia1.13.2: FHT **93 pass /0 fail /0 not-run**; FHGM
**74 pass /0 fail /18 not-run of92**. The runner does not parse the GFF3 feature
layer: cases naming K4 or explicitly requiring gene-row resolution remain
not-run, including valid cases. Caller-supplied decoded gene IDs can enable K4
through the API; this suite run does not claim feature parsing. A partial model
pass never establishes a gene target or biological derivation.

The refreshed FHT suite exposed two invalid BUSCO count sums accepted by the
previous reader. The C1 check now compares all four component counts with total
when all five are supplied as integers, including integral JSON numbers such as
2.0; it excludes booleans, leaves absent/ill-typed counts to schema validation,
and uses exact arithmetic without machine-integer overflow. This predicate
applies only to explicitly selected FHT development records. The four earlier
FHT promotion candidates have an owning `expectationReviews` disposition
`accepted-file-identity-only` (D3, 2026-11-19); that proves exact parent-file
identity, not biological derivation. Consumer test success is not their review.

Both contract and suite pins are enforced independently; a mismatched manifest
refuses scoring. One-byte and missing-path controls remain. The live-main
freshness report remains advisory, never an automatic refresh or an acceptance
gate. No development vector enters the frozen291/228/63 ledger. Historical
2026-11-18 measurements (FHT82/82, FHGM51/0/11-of62) and prior pins remain in
parent `d5aa9a5f82d744178dfa1ddeb6ede2bc0925a606`.

## Retired predicate accounting (2026-11-19)

What "the historical corpus is preserved" means concretely for the D9
canonical-parent retirements (moved verbatim in substance from the README,
restructured for readers; no numbers changed):

* The immutable historical payload is checked against its crosswalk digest, and
  every native canonical counterpart is checked against its replacement digest,
  before either is evaluated — bytes that do not match their record are never
  scored.
* The **39 retired invalid** native cases execute their canonical counterpart
  for the original predicate: the rejection is re-proved on the replacement
  bytes, not inherited.
* The **30 historical valid** cases retain the explicit D9/R4 rejection check
  *and* separately require the canonical counterpart to validate; both
  directions are asserted.
* Totals distinguished: **159** original unchanged predicates, **39** canonical
  invalid predicates and **30** old R4 checks, with **69** canonical counterpart
  predicates independently checked alongside them.
* The **9** crosswalk cases that live in JSON-LD/microdata serializations
  remain outside native coverage — this package reads header bytes, not HTML
  metadata or JSON-LD documents.

