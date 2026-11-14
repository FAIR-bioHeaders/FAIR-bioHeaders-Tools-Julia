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

## Result measured 2026-11-14 (macOS/arm64, Julia 1.13.2, this tree)

| format | pass | fail | undecided | total |
| --- | --- | --- | --- | --- |
| fasta | 94 | 0 | 4 | 98 |
| gfa | 53 | 0 | 3 | 56 |
| fhp-fasta | 34 | 0 | 2 | 36 |
| fhgff3 | 36 | 0 | 2 | 38 |
| jsonld | 0 | 0 | 37 | 37 |
| microdata | 0 | 0 | 26 | 26 |
| **total** | **217** | **0** | **74** | **291** |

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
* **11 compressed vectors**: `fasta-gzip`, `fasta-bgzf`, `fasta-gzip-multimember`,
  `fasta-gzip-sequence-tampered`, `gfa-gzip`, `gfa-bgzf`, `gfa-gzip-multimember`,
  `fhp-fasta-gzip`, `fhp-fasta-bgzf`, `fhgff3-gzip`, `fhgff3-bgzf`. Rule R1 hashes
  the decompressed bytes; this package does not yet decompress gzip/BGZF in Julia,
  so each is reported `undecided` with that reason by `run_conformance`.

Skips are decided by the runner and printed per vector (`decided = false`);
`summarise(outcomes)` produces the table above from a live run, and
`test/runtests.jl` asserts zero decided failures and the expected totals.

## Parity statement, bounded

217/217 decided vectors pass on the four sequence formats (FHR FASTA + GFA, FHP,
FHGFF3) on one host at one tag. That is the whole claim: it is not a family-parity
claim (69 shared vectors are undecided here), and it says nothing about
`bioheaders` writer behaviour, JSON-LD or microdata output.
