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

FHT and FHGM have **no released contract** (rule V7 of `docs/SCHEMA-VERSIONS.md` keeps a
draft out of every release form): by default this package recognises neither type — a
citation of either falls to rule V5 like any unknown value — and no `schemaVersion` or
w3id claim exists for either anywhere in the repository. An explicit, per-call rule-V7
opt-in (`drafts = true`) reads the *pinned* draft bytes under `drafts/`, warning on every
record; see `docs/CAPABILITY-MATRIX.md`.

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

## Install (development)

```julia
import Pkg
Pkg.add(url = "https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Tools-Julia")   # after the first maintainer merge
```

or, from a checkout:

```julia
] develop /path/to/this/repo
```

## Use

```julia
using FAIRBioHeaders
r = verify_file("genome.fhr.fasta")
r.ok          # true only when bytes, header rules and contract all conform
r.computed    # base64 SHA-512/256 the file must state
println(r)    # errors, warnings and what was not checked, per rule
```

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

Retired predicate evidence: the immutable historical payload is checked against its crosswalk digest, and every native canonical counterpart is checked against its replacement digest before evaluation. The 39 retired invalid native cases execute their canonical counterpart for the original predicate. The 30 historical valid cases retain the explicit D9/R4 rejection check and separately require the canonical counterpart to validate. Thus 159 original unchanged predicates, 39 canonical invalid predicates, and 30 old R4 checks are distinguished; 69 canonical counterpart predicates are independently checked. The 9 crosswalk cases in JSON-LD/microdata remain outside native coverage.
