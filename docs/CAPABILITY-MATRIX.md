# Capability matrix: type × operation × serialization × contract version

Status date: **2026-11-14**. This is the honest capability statement of
`FAIRBioHeaders.jl`. It exists so that a gap is a named row rather than an
inference, and so that no summary of "supports FHR, FHP, FHGFF3, FHT and FHGM"
can be read into this library: **the five-type family is not five types of
support here.** Cell vocabulary:

| mark | meaning |
| --- | --- |
| `yes` | implemented, and covered by a named test or vector set in this repository |
| `partial` | implemented for a stated subset; the remainder is named in the row |
| `no` | not implemented - the reason follows, and it is a real hole, not a formality |
| `n/a` | the cell is not a thing this library could do (why it says so) |

Anything not marked `yes` is not claimed. `docs/CONFORMANCE.md` carries the
291-vector accounting; the CI receipt (`receipt-test.properties`) states the same
counts from the run that produced them.

## 1. Type × operation

| operation | FHR | FHP | FHGFF3 | FHT | FHGM |
| --- | --- | --- | --- | --- | --- |
| read the embedded header block | yes | yes | yes | no yet - draft, rule V7; no released contract exists to support (issue #2 tracks the pinned opt-in lane) | no - not a file-bound header type; FHGM records ride inside an FHGFF3 header under `x-fhgm-models` |
| verify the SHA-512/256 checksum over exact bytes (R1-R5) | yes | yes | yes | no yet (same lane) | n/a - integrity of an FHGM-carrying file is the enclosing FHGFF3 header's checksum, which is `yes` above |
| select the contract (rules V1-V6) | yes | yes | yes | no yet; today a FHT citation falls to V5 like any unknown value, which IS implemented and pinned by a regression test | n/a - FHGM records carry no `schema` field; the file is routed by its FHGFF3 citation |
| validate against the contract (draft/2020-12, formats bound) | yes | yes | yes | no yet (same lane) | no - the model-level checker (rules K1-K6) is not implemented; see §4.2 |
| rule R11 record-marker warning | yes | yes | n/a (GFF3 lines are not FASTA) | no yet (same lane) | no |
| rule R14 link-scheme warning | yes | yes | yes | no yet (same lane) | no |
| rule R15 extension fields | yes (2.1+) | yes (1.1+) | yes (1.1+) | no yet (same lane) | n/a - `x-fhgm-models` is *transport*, admitted by FHGFF3 1.1's R15; this library keeps it as uninterpreted metadata |
| parent-link verdicts (`derivedFrom[].checksum`) | no - not implemented for the released types | no | no | no yet (the draft suite's C3 vectors need it; same lane) | no |
| write / combine a header | no - this library never writes; use `bioheaders combine` | no | no | no | no |
| strip a header | no | no | no | no | no |
| convert between serializations | no | no | no | no | no |
| GFF3 feature-line validation (syntax, SO, biology) | n/a | n/a | no - belongs to `gff3-validator`; FHGFF3 vectors here pass on header/placement/link/checksum grounds only | n/a | no |
| assess / rubric / conformance reporting | no | no | no | no | no |

## 2. Type × serialization (input side; this library has no output side)

| serialization | FHR | FHP | FHGFF3 | FHT | FHGM |
| --- | --- | --- | --- | --- | --- |
| FASTA `;~` block, exact bytes (LF, CRLF, lone CR) | yes | yes | n/a | no yet (same lane) | n/a |
| GFA `#~` block | yes | n/a | n/a | no - the draft suite defines `fht-fasta` only | n/a |
| GFF3 `#~` block after `##gff-version 3` | no - FHR is FASTA/GFA | n/a | yes | n/a | no |
| gzip and multi-member BGZF transport (R1, decompressed digest) | yes | yes | yes | no yet (same lane; the reader itself would serve it) | no |
| header YAML → JSON value model (R8/R12/R13, strict local reader) | yes | yes | yes | no yet (same lane) | no |
| JSON metadata record (contract validation alone) | yes, `validate_record` | yes | yes | no yet (same lane) | no |
| JSON-LD (docs/JSONLD.md J1-J9) | no | no | no | no | n/a |
| HTML microdata (docs/MICRODATA.md M1-M5) | no | no | no | no | n/a |
| schema.org export | no | no | no | no | no |

## 3. Contract-version coverage

`yes` = a bundled, digest-pinned copy exists and selection resolves to it
(rule V4 reports anything else as unsupported-version). Every copy is
re-digest-checked against `schemas/provenance.json` on every test run
(`audit_bundled_schemas`, native).

| type | contract versions bundled | current (`main`) copy | evidence |
| --- | --- | --- | --- |
| FHR | `1` (v0.3.0/v0.3.1), `2.0` (v0.4.0-v0.4.2), `2.1` (v0.5.0/v0.6.0) | `current/fhr.json` = v0.6.0 bytes (= v0.5.0) | 98 `fasta` vectors (incl. the rule V6 FHR 1 paths), selection tests |
| FHP | `1.0` (v0.4.0-v0.4.2), `1.1` (v0.5.0), `1.2` (v0.6.0) | `current/fhp.json` | 36 `fhp-fasta` vectors, version-gated conditional tests |
| FHGFF3 | `1.0` (v0.4.0-v0.4.2), `1.1` (v0.5.0), `1.2` (v0.6.0) | `current/fhgff3.json` | 38 `fhgff3` vectors, `annotates`-form tests |
| FHT | none - **no released contract** (rule V7: no schemaVersion, no registry row, no w3id, no bundled schema, no support claim) | none | the V7 regression test: a FHT citation falls to V5 exactly as any unknown value |
| FHGM | none - **no released contract, and not a header type** | none | see §4.2 |

Releases `v0.4.1`/`v0.4.2` repeat the `v0.4.0` bytes and `v0.6.0`'s `fhr.json`
repeats `v0.5.0`'s: release identity and byte identity are recorded as separate
axes in `schemas/provenance.json`.

## 4. Named holes, with reasons

1. **JSON-LD (37 shared vectors) and HTML microdata (26 shared vectors): not
   decided.** Reason: the bindings (docs/JSONLD.md J1-J9, docs/MICRODATA.md
   M1-M5) need a JSON-LD processor and an HTML microdata extractor; this package
   implements neither. `run_conformance` reports them `undecided` by name, never
   passed, and the CI receipt pins the 63 count so a silent disappearance is a
   failure too. The sibling R and JavaScript studies skip the same layers.
2. **FHGM: no support of any kind in this build.** Reason, precisely: FHGM is
   not a header type. Its records ride inside an FHGFF3 header under the
   `x-fhgm-models` extension key (FORMAT.md R15), and the draft's acceptance
   model is its own model-level checker - rules K1-K6 (transport, record shape,
   model-ID uniqueness, `featureId` resolution against the GFF3 feature layer,
   record-reference agreement with the file's genome link, and predecessor
   resolution against supplied prior snapshots). Only K2 is a pure JSON Schema
   evaluation; K1 and K3-K6 need the GFF3 feature layer and cross-file history,
   which this library does not read. Bundling the draft bytes and evaluating the
   schema half alone would report passes while skipping the rules that make the
   draft worth checking, so the whole lane is declared absent until it can be
   ported natively (issue #2).
3. **GFA containers for a future FHT lane: out of the draft suite by
   definition.** Reason: the FHT draft suite defines `fht-fasta` only; inventing
   GFA draft fixtures here would mean authoring normative expectations the
   owning repository has not stated.
4. **Writer, stripper, converter, `faidx`, `assess`, directive cross-checks
   (`#!genome-build`): out of scope by family design.** Header creation belongs
   to `fair-bioheaders` (Python); this is a reader and verifier
   (AGENTS.md, "Scope of the package").
5. **FHT/FHGM "no yet" cells are one lane, not five.** When the rule V7 opt-in
   lane lands, the type-level reading, checksum, selection, validation and
   transport cells become `yes (draft lane)` together; until then no FHT or FHGM
   row, URL, schemaVersion or support claim exists anywhere in this repository,
   enforced by `audit_bundled_schemas` and a regression test.

## 5. How to read a count in this repository

* Released-contract acceptance: **228 of 291** shared v0.6.0 vectors decided,
  all passing; the 63 remainder are declared not-run with reason 1 above
  (`docs/CONFORMANCE.md`).
* Draft evidence (when the lane lands): reported separately, never added to the
  291, never a support claim.
* Every gap is a named row here with its reason. A missing capability is
  reported as missing; nothing is inferred from the package's function names or
  from the reference toolkit's coverage.
