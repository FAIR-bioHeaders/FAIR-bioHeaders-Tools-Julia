# Provenance of this document

This is a capability study measured on **2026-11-14** on **one macOS/arm64 host**
(macOS 14, arm64) with **Julia 1.13.2** (CorvusJsonSchema 0.1.4, JSON 1.13.4,
JSONSchema 1.6.0, YAML 0.4.x) and **Python 3.15** with the released
**fair-bioheaders 0.11.0** (jsonschema 4.26.0) as the oracle, against the released
v0.6.0 contract bytes. It is **not** a claim about a released FAIR-bioHeaders Julia
library: none is registered and none existed when the study was written.

The first pass at these measurements was made by an earlier agent run whose code was
salvaged uncommitted into this repository; the decision-critical claims below were
**re-run independently for this document** (fresh scripts, fresh outputs), and where
the record distinguishes the two, the earlier artifacts (digest probes, validator
matrix, YAML checks) are retained in the federation's working materials under
`issue-review/library-capability/2026-11-14-Julia/`. Every figure below is a
single-host measurement.

---

# Capability study — Julia for FAIR-bioHeaders (E0) and shared-vector results (E2)

Inputs are the **released v0.6.0 contract bytes** (spec tag `v0.6.0` → main commit
`0ae18b0`), fetched fresh from the tag and verified by SHA-256 before use:

| file | sha256 (first 16) |
| --- | --- |
| `fhr.json` | `694ab5afaf8c3743` |
| `fhp.json` | `92a0b3cbcfe69939` |
| `fhgff3.json` | `1942be4cefc8b3a2` |

All three declare `"$schema": "https://json-schema.org/draft/2020-12/schema"` (read
from the tag bytes, not from documentation). Registry (`schemas/versions.json` at
`v0.6.0`, `preRelease: null`): **FHR 2.1, FHP 1.2, FHGFF3 1.2**. FHT and FHGM are
drafts and take no part in this study (rule V7).

## Verdict

Julia is **feasible with two library-level choices and one library to avoid**:

1. **Checksum layer — solved by the standard library.** `SHA.SHA2_512_256_CTX` is
   byte-equal to the released toolkit's `hashlib.new("sha512_256")` and to
   `openssl dgst -sha512-256` (E0a below). Unlike the sibling R study, no external
   dependency or system CLI is needed.
2. **Schema layer — CorvusJsonSchema, with a mandatory flag.** With
   `assert_format = true`, CorvusJsonSchema 0.1.4 matched the released-toolkit oracle
   on **19/19** probes, including every version-gated `if`/`then` conditional, in both
   directions. Its *default* mode silently ignores `format` (3 probes) — the flag is
   load-bearing. `JSONSchema.jl` 1.6.0 is **rejected**: it silently ignores `format`
   (3 probes) and falsely rejects the legal FHGFF3 `annotates` genome link (1 probe),
   and it reports rejections by throwing `FieldError` rather than a usable result.
3. **YAML layer — read it locally.** YAML.jl diverges from the family rules in ways
   the reader cannot post-check (E0c below), so the metadata block is parsed by this
   package's own rule-driven reader.

## E0(a) — is the Julia stdlib digest byte-equal to the released toolkit?

Four independent computations of the SHA-512/256 digest of the exact R3-covered
bytes (every line with its terminator except the root checksum line and its
terminator): the checksum stated inside each released example file, Python
`hashlib.new("sha512_256")` over the coverage (a fresh baseline script), a fresh
Julia stdlib-only script written from docs/FORMAT.md independently of this package,
and this package's `header_checksum`:

| v0.6.0 example file | stated in file / hashlib / Julia stdlib (independent script) / this package |
| --- | --- |
| `examples/example.fhr.fasta` | all four `oVOUoqUJJWHHGe7JlwNErSs9Yvx32ujIOyaM+DDTK3s=` |
| `examples/example.fhr.gfa` | all four `vNCZUY1mbTuo5nE3ut8KGx0oExSfzqLp8np/gYTvPcM=` |
| `examples/fhp/example.fhp.fasta` | all four `pX6x2pY4LP/gR9L8yFEJm9GQH5RuqTC1GvPmQHTQf5g=` |
| `examples/fhgff3/annotation.fhgff3.gff3` | all four `klX9RfPwnG2Rfta9kG5S4N2CdBPqrNjcZbqiLHo6WHo=` |

(The FHGFF3 case also checks the root-indent rule: that file carries a nested
`genomeReference.checksum` two columns deeper, and all paths pick the same root
line. The released toolkit CLI reports `FHR metadata is valid.` on
`example.fhr.fasta`.)

Raw-primitive probe on `abc`:
`53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23` =
`UwSOJoGUHvmbLim3a0x9q+TC0MY0/G1G4OLxMQfnryM=` from Julia `SHA`, Python `hashlib`
(`sha512_256`) and `openssl dgst -sha512-256` alike. This probe is pinned in
`test/runtests.jl`.

**Result: E0a passes natively.** No C dependency, no CLI shelling out.

## E0(b) — does draft/2020-12 validation actually fire on the released contracts?

19 probes were built against the released example headers (bases:
`examples/minimal.fhr.json`, `examples/fhp/minimal-predicted.fhp.json`,
`examples/fhgff3/minimal-reference.fhgff3.json`, and the `annotates`-form header of
`examples/fhgff3/annotation.fhgff3.gff3`). The **oracle is the released
fair-bioheaders 0.11.0's own validator** (`Draft202012Validator` + `FormatChecker`)
against the tag bytes; the oracle agreed with the rule text on 19/19.

Classification: OK = engine matches the oracle; **SILENT-IGNORE** = oracle rejects,
engine accepts (the dangerous class); **FALSE-REJECT** = oracle accepts, engine
rejects.

| probe (contract, mutation) | oracle | Corvus shipped path (`assert_format=true`) | Corvus default | JSONSchema.jl 1.6.0 |
| --- | --- | --- | --- | --- |
| fhr-baseline | valid | OK | OK | OK |
| fhr x-key @ 2.1 | valid | OK | OK | OK |
| **fhr x-key @ 2.0 (gate)** | invalid | **OK** | OK | OK |
| fhr 2.0 no x-key (control) | valid | OK | OK | OK |
| fhr dateCreated `2026-13-45` | invalid | **OK** | SILENT-IGNORE | SILENT-IGNORE |
| fhr relatedLink `not a uri` | invalid | **OK** | SILENT-IGNORE | SILENT-IGNORE |
| fhr unknown key | invalid | OK | OK | OK |
| fhp-baseline @ 1.2 | valid | OK | OK | OK |
| **fhp dotted BUSCO @ 1.2** | valid | **OK** | OK | OK |
| **fhp dotted BUSCO @ 1.1 (gate)** | invalid | **OK** | OK | OK |
| fhp undotted BUSCO @ 1.1 (control) | valid | OK | OK | OK |
| fhp x-key @ 1.0 (gate) | invalid | OK | OK | OK |
| fhp x-key @ 1.2 | valid | OK | OK | OK |
| fhp dateCreated `13/05/2026` | invalid | OK | SILENT-IGNORE | SILENT-IGNORE |
| fhgff3 reference form | valid | OK | OK | OK |
| **fhgff3 annotates form** | valid | **OK** | OK | **FALSE-REJECT** |
| fhgff3 two annotates links | invalid | OK | OK | OK |
| fhgff3 no genome link | invalid | OK | OK | OK |
| fhgff3 x-key @ 1.0 (gate) | invalid | OK | OK | OK |
| **TALLY** | | **19 OK / 0 / 0** | 16 OK / 3 SILENT-IGNORE | 15 OK / 3 SILENT-IGNORE / 1 FALSE-REJECT |

Gate evidence (why "fired" is visible, not assumed): the 1.1 dotted-BUSCO rejection
names `/completeness/lineageDataset` with the *version-specific* pattern
`^[a-z0-9_]+_odb[0-9]+$`, while the same record at 1.2 passes the root pattern that
allows dots; the 2.0 x-key rejection is reported through the `not` composition of the
`propertyNames` gate; format rejections read `Expected an ISO8601 Date string.` and
`Expected an absolute URI.`

An earlier construct-level matrix (26 synthetic construct probes: `$defs`, `$ref`
siblings, `propertyNames`, `contains`+`min/maxContains`, `dependentRequired`,
`prefixItems`, `$anchor`, `unevaluatedProperties`, if/then forms) was run in the first
pass and recorded in the working-materials artifacts; the same asymmetries appear
there. This document's own numbers are the 19-probe release-bytes matrix above.

**Result: E0b passes with CorvusJsonSchema 0.1.x and `assert_format = true`; that
exact option is what the package compiles every bundled contract with. JSONSchema.jl
must not be substituted** — its `annotates` false-rejection would reject valid
FHGFF3 files, and its silent format ignores would pass invalid dates and URIs —
the same failure class that disqualified the sibling R repo's default engine.

## E0(c) — can YAML.jl read the metadata block?

Fresh run, `YAML.load(IOBuffer(text))` (note: `YAML.load(String)` treats the argument
as a *file path*) versus this package's reader:

| probe | YAML.jl 0.4.x | required by R8/R12/R13 | this package |
| --- | --- | --- | --- |
| duplicate key `a: 1 / a: 2` | accepts (last wins, logs error) | reject (R8) | rejects (R8) |
| anchor + alias | accepts | reject (R8) | rejects (R8) |
| merge key `<<:` | merges silently | reject (R8) | rejects (R8) |
| explicit tag `!!str 5` | accepts as `"5"` | reject (R12) | rejects (R12) |
| `yes: on` | loads (`"yes" => "on"`) | reject (R12, 1.1/1.2 disagree) | rejects (R12) |
| `a: 0b101` | throws ArgumentError | reject (R12) | rejects (R12) |
| `a: 2026-13-45` | throws ArgumentError | keep as string (R12) | keeps string |
| `a: 2026-05-13` | returns a Date-typed value | keep as string (R12) | keeps string |
| `a: 1:30` | loads `"1:30"` | reject (R12, 1.1 sexagesimal) | rejects (R12) |
| `a: .inf` | returns `Inf` | reject (R13) | rejects (R13) |
| `a: 0755` | returns `493` (1.1 octal!) | reject (R12) | rejects (R12) |
| `documentation: one` + `  two` | folds to `"one\ntwo"` | fold to `"one two"` | folds to `"one two"` |

YAML.jl accepts things the format forbids, rejects (by crashing) things the format
keeps, mistypes plain scalars against YAML 1.2 core, and folds a single line break
differently from every other family reader. **Result: the strict local reader is
required**, and its rule behaviour is pinned in `test/runtests.jl`.

## E0(d) — decompressing gzip/BGZF input (rule R1), measured 2026-11-14

Rule R1 hashes the **decompressed** bytes, so a reader that cannot inflate gzip cannot
decide the suite's 11 compressed vectors (and the FHT draft suite's 2). Julia has no
gzip in the standard library, so the candidate was the ecosystem's `CodecZlib`. The
pure-Julia alternative `Inflate` was probed too, because it would avoid any compiled
dependency. Both were run over the released bytes on this host (Julia 1.13.2):

| input | `CodecZlib 0.7.9` (`transcode(GzipDecompressor, …)`) | `Inflate 0.1.5` (`inflate_gzip`) |
| --- | --- | --- |
| single-member gzip (7 vectors: fasta/gfa/fhp/fhgff3 gzip, the tampered vector, `fht-fasta-gzip`) | all decompressed | all decompressed, byte-equal to CodecZlib |
| multi-member gzip (`fasta-gzip-multimember`, `gfa-gzip-multimember`) | decompressed | **truncated** (496 of 581 bytes — stops after the first member, no error) |
| BGZF (`fasta-bgzf` and 4 more, plus `fht-fasta-bgzf`) | decompressed | **truncated** (96 of 581 bytes — first block only, no error) |

`Inflate`'s failure mode is silent truncation, which is the worst possible class for a
checksum reader: a truncated inflate is a different byte sequence, so any verdict it
supports is an artifact of where decompression stopped. It is **not usable here**.

`CodecZlib 0.7.9` reads all 13 compressed vectors (11 shared + 2 FHT draft) and the
whole compressed vector set then decides and passes (docs/CONFORMANCE.md). Its cost is
one compiled boundary: `CodecZlib` (MIT, pure Julia) → `TranscodingStreams` (MIT) →
`Zlib_jll` (BinaryBuilder build of the zlib C library, zlib license; wrapper MIT — the
same zlib Julia's own `Pkg` transports tarballs with). The boundary is isolated to
`decompress_gzip` in `src/gzip.jl`, is entered only on the two-byte gzip magic (never
by file-name inference), and its behaviour — magic detection, multi-member and BGZF
concatenation, truncated-stream rejection — is pinned by a self-contained testset in
`test/runtests.jl` on top of the shared vectors.

**Result: `CodecZlib` is the accepted dependency; the compiled-boundary rationale and
its isolation are above. `Inflate` must not be substituted.**

## Julia version floor: measured, not copied

`julia = "1.10"` was the salvaged declaration and is **wrong for this package**: the
SHA-512/256 API is absent from the SHA stdlib of the older lines, verified by running the
binaries directly on 2026-11-14:

| Julia | stdlib SHA | `SHA2_512_256_CTX` / `sha2_512_256` |
| --- | --- | --- |
| 1.10.13 | 0.7.0 | absent / absent |
| 1.11.9 | 0.7.0 | absent / absent |
| 1.12.0 | 0.7.0 | **present** / present |
| 1.12.7 | 0.7.0 | present / present |
| 1.13.2 | 1.0.0 | present / present |

The stdlib cannot be overridden from the registry (shared UUID), so the floor is
`julia = "1.12"`, and the CI matrix runs 1.12 and 1.x. The full suite (71 assertions +
217 decided vectors) passes on 1.12.7 and 1.13.2 on this host.

## Licence-tooling probe (Project.toml)

`license = "MPL-2.0"` (bare SPDX string) + a `LICENSE` whose first lines are a prose
notice. Evidence, run 2026-11-14:

* `Pkg.TOML.tryparsefile("Project.toml")` parses; RegistryCI's
  `meets_project_toml_check` (AutoMerge/src/guidelines.jl, fetched from master)
  requires only `uuid`, `name`, `version` and parses nothing else — the `license`
  field itself is never SPDX-validated by the registry.
* RegistryCI's license guideline (`guideline_version_has_osi_license`) runs
  `LicenseCheck.find_licenses(pkgdir)` over the **file contents**; run locally it
  returns `LICENSE found=["MPL-2.0","MPL-2.0"] osi=(true, true)` on this tree.
* stdlib deps need no `[compat]` (`_AUTOMERGE_REQUIRE_STDLIB_COMPAT = false`), though
  `Base64`/`SHA` are pinned anyway.

Julia therefore has no analogue of the sibling R repo's `MPL-2.0 | file LICENSE`
requirement; the bare string plus the MPL-2.0 body in LICENSE is the measured-correct
form. (GitHub's own licence classifier may still report `NOASSERTION` for a
notice-before-body LICENSE, as it does for the spec and Tools repositories; that is
expected, not a defect.)
