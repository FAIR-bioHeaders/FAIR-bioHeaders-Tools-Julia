# FAIR-bioHeaders-Tools-Julia

A Julia reader and verifier for [FAIR-bioHeaders](https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification)
metadata headers: FHR (reference genome FASTA/GFA), FHP (protein FASTA) and FHGFF3 (GFF3
annotation). It is the Julia sibling of the Python toolkit `fair-bioheaders`
([FAIR-bioHeaders-Tools](https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Tools)); the
rules live in the specification repository and this package implements its reader side.

Status: **development only**. The package is not registered in the Julia General registry
and has no released version. The contract copies under `schemas/` are byte-for-byte copies
of [FAIR-bioHeaders-Specification](https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification)
release **v0.6.0** (contract versions FHR 2.1, FHP 1.2, FHGFF3 1.2), each recorded with its
SHA-256 in `schemas/provenance.json`.

FHT and FHGM first entered this package through a development-only V7 lane,
before the family published their released forms. The family has since moved: as of specification **v0.7.0** (released 2026-11-20) FHT 1.0 is
a released contract with a registry row and a w3id URL, and specification **v0.8.0**
publishes FHGM 0.1 as a *native model contract* (`model-contracts/fhgm/0.1/`) — still
not a header type, so it has no file-bound `schemaVersion` and no header-registry row.
**This package has not been promoted to either released form and claims no support for
them**: it still recognises neither type by default — a citation of either falls to
rule V5 like any unknown value — and reads the pinned draft bytes only through the
explicit per-call rule-V7 opt-in (`drafts = true`), warning on every record. Released
FHT support here requires a deliberate, dated dependency/pin change; until then treat
the draft wording as *this build's* state and the v0.7.0/v0.8.0 wording as the
family's. See `docs/CAPABILITY-MATRIX.md`.

The deliberate 2026-11-20 PR19 CI repair refreshes the development-lane FHT
contract/suite and FHGM suite pins. It adds the owning FHT C1 BUSCO sum check
when all component counts and total are supplied. Default selection and the
released v0.6.0 registry stay unchanged; this refresh is not a promotion to
released FHT or native FHGM support. See [development evidence](docs/CONFORMANCE.md#development-suites-are-separate-evidence-not-this-ledger).

## What it does

* `verify_file(path)` — reads the header block, verifies the SHA-512/256 checksum of the
  exact bytes it covers (rule R3; gzip/BGZF input is decompressed first, because R1 hashes
  the decompressed bytes), parses the YAML metadata block under the family's
  portability rules (R8, R11, R12, R13), validates the record against the JSON Schema
  contract its own `schema` citation selects (V1–V6, draft 2020-12 with `date`/`uri`
  format assertions) and reports R14 link-scheme warnings.
* `header_checksum`, `read_fhr_file`, `read_fhr_header`, `validate_record`,
  `select_contract` — the same layers separately.
* `run_conformance(dir)` — applies the shared 291-vector conformance suite of the
  specification release; see `docs/CONFORMANCE.md` for what this run decides and skips.

The digest is Julia standard library (`SHA.SHA2_512_256`) and is byte-equal to the released
Python toolkit's `hashlib` digest; the measurement is recorded in
[`docs/CAPABILITY.md`](docs/CAPABILITY.md). Contract validation is delegated to
[CorvusJsonSchema.jl](https://github.com/saminlive/CorvusJsonSchema.jl)
(Apache-2.0) with `assert_format = true`; the same study records why `JSONSchema.jl` is not
used.

## Requirements

**Julia 1.12 or later** — a hard prerequisite, not a preference: the SHA-512/256
digest this package verifies with is the stdlib `SHA.SHA2_512_256_CTX` API, which
does not exist on Julia 1.10/1.11 (measured: stdlib SHA 0.7.0 lacks it and it cannot
be supplied from the registry). `Project.toml` declares `julia = "1.12"`; do not
work around it. Development is tested on Julia 1.13.2 (measured 2026-11-20).
Dependencies are declared with bounds in `Project.toml` (`CorvusJsonSchema` for
draft-2020-12 validation, `CodecZlib`/`TranscodingStreams` for gzip/BGZF input);
`Pkg.instantiate()` resolves them.

## Install (development)

Nothing is published: no General registration (probed against
`JuliaRegistries/General` again on 2026-11-20: not present) and no GitHub Release
for this repository. Add it straight from the repository — this works today against
`main`:

```julia
import Pkg
Pkg.add(url = "https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Tools-Julia")
```

or, from a checkout:

```julia
] develop /path/to/this/repo
```

A source `add`/`develop` tracks whatever `main` holds at clone time; it is not a
release and not a frozen artifact. For reproducibility, record the commit you
installed.

## Use

```julia
using FAIRBioHeaders
r = verify_file("genome.fhr.fasta")
r.ok          # true only when bytes, header rules and contract all conform
r.computed    # base64 SHA-512/256 the file must state
println(r)    # errors, warnings and what was not checked, per rule
```

`verify_file(path; kind = nothing, validate = true, drafts = false)` returns a
`VerifyResult` with fields `path`, `kind` (`"fasta"`, `"fhp-fasta"`, `"gfa"` or
`"fhgff3"`, from the file name with any `.gz` stripped), `ok`,
`stated` / `computed` (checksums; `stated === nothing` when the file carries no
checksum line), `metadata` (parsed header, or `nothing` when none was found),
`errors`, `warnings` and `not_checked`. Options:

* `kind` — override the name-based guess (`verify_file(p, kind = "gff3")`); when
  the name is ambiguous and no `kind` is passed, `ok` is `false` with an
  explanatory error rather than a guess.
* `validate = false` — stop after the byte/header layers: the checksum and YAML
  portability verdicts still stand, the contract decision is reported in
  `not_checked` instead of silently implied.
* `drafts = true` — open the rule-V7 lane per call (see the draft paragraph
  above): pinned FHT bytes are re-digest-checked against
  `drafts/provenance.json` on load, records carry the V7 warning, and FHGM
  records riding in an FHGFF3 header get a separate `r.fhgm` verdict that never
  alters the released result. With the default `false`, none of that runs.

gzip and BGZF inputs (`.gz`) are decompressed transparently because R1 hashes the
decompressed bytes; a truncated stream is reported as an error, never as an
empty file. Whole-buffer helpers `decompress_gzip` and `read_file_bytes` have no decompressed
size cap: call them only when you trust the expanded size to fit memory, rather
than inferring safety from the compressed file size. Prefer `verify_file` for
streaming verification of large or untrusted files. Streaming bounds retained
memory; it does not impose a total processing-time or input-size budget.

The layered functions (`scan_lines`, `header_checksum`,
`read_fhr_header`, `select_contract`, `validate_record`, …) expose the same
pipeline one rule at a time; `docs/CAPABILITY-MATRIX.md` is the type × operation
table, including the named holes.

A header is created and its checksum computed by the Python toolkit
(`bioheaders combine`), never by hand and never by this package: it is a reader and
verifier. After any byte change to a header, recombine with the toolkit.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

`Pkg.test` runs the self-contained rule tests and the native bundled-schema audit
(`audit_bundled_schemas`) plus, when `FAIRBIOHEADERS_CONFORMANCE` points at a checkout
of the specification at tag `v0.6.0`, the shared conformance vectors (the CI workflow
does exactly that; shared vectors are taken from releases, never main). Setting that
variable at a directory with no suite is a fixture error and fails; only leaving it
unset (a local rule-only run) skips the vector layer, and it says so. With
`FAIRBIOHEADERS_RECEIPT=path` the run writes a receipt of the counts it measured
(vectors decided/passed/failed, compressed-vector decisions, audit findings, assertion
tally), and CI asserts every number in it — a green build with a missing or short
receipt fails the job. The Python toolkit is never part of this path; the released
toolkit and the old Python audit run only in a separate, explicitly supplemental
`differential` job, which compares this package with fair-bioheaders 0.12.0 verdict by
verdict on the vectors and released examples, and reading by reading on generated YAML
(`scripts/differential/`).

## License and provenance

MPL-2.0 for this repository's own material, with the family's historical USDA-ARS
public-domain notice handled in [`LICENSE`](LICENSE) (this repository holds no such
material directly; the vendored contract copies travel with the specification
repository's terms, recorded per file in `schemas/provenance.json`).

Historical-corpus accounting (retired predicates and canonical counterparts) is documented in [docs/CONFORMANCE.md](docs/CONFORMANCE.md#retired-predicate-accounting-2026-11-19).
