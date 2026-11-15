# Capability matrix: type × operation × serialization × contract version

Status date: **2026-11-15** (rule-V7 draft lane added; earlier date 2026-11-14
covered the native-CI release-only build). This is the honest capability statement of
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
| `draft lane` | implemented only behind the explicit rule-V7 opt-in (`drafts = true`), reading digest-pinned unreleased bytes under `drafts/`, warning on every record; **never a support claim and never the default** |

Anything not marked `yes` is not claimed as released-contract support, and a
`draft lane` mark claims only opt-in reading of unreleased, digest-pinned bytes.
`docs/CONFORMANCE.md` carries the 291-vector accounting; the CI receipt
(`receipt-test.properties`) states the same counts from the run that produced them.
Draft evidence comes from the separate, labelled `draft-lane` job and never enters
the 291.

## 1. Type × operation

| operation | FHR | FHP | FHGFF3 | FHT | FHGM |
| --- | --- | --- | --- | --- | --- |
| read the embedded header block | yes | yes | yes | draft lane (`;~` FASTA block like FHR; issue #2; no released contract exists and none is claimed) | no - not a file-bound header type; FHGM records ride inside an FHGFF3 header under `x-fhgm-models` |
| verify the SHA-512/256 checksum over exact bytes (R1-R5) | yes | yes | yes | draft lane (all 66 pinned FHT suite vectors exercise this byte layer) | n/a - integrity of an FHGM-carrying file is the enclosing FHGFF3 header's checksum, which is `yes` above |
| select the contract (rules V1-V6) | yes | yes | yes | draft lane: the owning repository's raw-main citation selects the pinned bytes with `drafts = true`; a release-shaped URL (w3id or tag) for FHT stays V5 with the lane open or shut | n/a - FHGM records carry no `schema` field; the file is routed by its FHGFF3 citation |
| validate against the contract (draft/2020-12, formats bound) | yes | yes | yes | draft lane (against the pinned `drafts/fht-draft.json`, digest re-verified on load) | draft lane, partial: B1 and K1, K2, K3, K5, K6 implemented in `src/fhgm.jl`; **K4 `not-supported-yet`** - resolving a `featureId` needs the GFF3 feature layer, which belongs to `gff3-validator`; reason in §4.2 |
| rule R11 record-marker warning | yes | yes | n/a (GFF3 lines are not FASTA) | draft lane | no |
| rule R14 link-scheme warning | yes | yes | yes | draft lane | draft lane (per-record scheme warnings for `uri`/`*Url` slots in `src/fhgm.jl`) |
| rule R15 extension fields | yes (2.1+) | yes (1.1+) | yes (1.1+) | draft lane (the FHT contract gates `x-` keys itself) | `x-fhgm-models` is *transport*, admitted by FHGFF3's R15 gate; under `drafts = true` the records are read as FHGM models instead of staying uninterpreted metadata |
| parent-link verdicts (`derivedFrom[].checksum`) | no - not implemented for the released types | no | no | draft lane, runner-side: C3 (checked-pass / checked-fail / unchecked against supplied parent bytes) is judged by `scripts/draft_vectors.jl` and reported as draft evidence; it is not a package API and no released type gets it | no |
| write / combine a header | no - this library never writes; use `bioheaders combine` | no | no | no | no |
| strip a header | no | no | no | no | no |
| convert between serializations | no | no | no | no | no |
| GFF3 feature-line validation (syntax, SO, biology) | n/a | n/a | no - belongs to `gff3-validator`; FHGFF3 vectors here pass on header/placement/link/checksum grounds only | n/a | no - and this is the named reason K4 is `not-supported-yet` |
| assess / rubric / conformance reporting | no | no | no | no | no |

## 2. Type × serialization (input side; this library has no output side)

| serialization | FHR | FHP | FHGFF3 | FHT | FHGM |
| --- | --- | --- | --- | --- | --- |
| FASTA `;~` block, exact bytes (LF, CRLF, lone CR) | yes | yes | n/a | draft lane | n/a |
| GFA `#~` block | yes | n/a | n/a | no - the draft suite defines `fht-fasta` only; inventing GFA draft fixtures here would author expectations the owning repository has not stated | n/a |
| GFF3 `#~` block after `##gff-version 3` | no - FHR is FASTA/GFA | n/a | yes | n/a | draft lane (the FHGM-carrying file is an FHGFF3 file; the released reading routes and checks it, the lane adds the model verdict beside it) |
| gzip and multi-member BGZF transport (R1, decompressed digest) | yes | yes | yes | draft lane (the suite's gzip and BGZF vectors pass through the same `src/gzip.jl` boundary) | n/a (no compressed FHGM vector exists in the pinned suite) |
| header YAML → JSON value model (R8/R12/R13, strict local reader) | yes | yes | yes | draft lane | draft lane (the enclosing header goes through the released reader; `x-fhgm-models` arrives as nested values like any other key) |
| JSON metadata record (contract validation alone) | yes, `validate_record` | yes | yes | draft lane (`validate_record(md; drafts = true)`) | draft lane (`check_fhgm_models`, K2 through the pinned record contract) |
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
| FHT | none - **no released contract** (rule V7: no schemaVersion, no registry row, no w3id, no support claim). `drafts/fht-draft.json` is a digest-pinned *draft*, not a bundled contract: it appears in no `registry.json` or `versions.json`, and is read only through the opt-in lane | none - `main` is never consulted at run time | the V7 default-off regression tests; lane selection/warning tests; 66/66 vectors of the pinned FHT-Specification suite at suite `24d3b033`, contract `226f923c` |
| FHGM | none - **no released contract, and not a header type**: records ride inside an FHGFF3 header under `x-fhgm-models`; `drafts/fhgm-model-draft.json` + transport overlay are digest-pinned drafts under the same discipline | none | 26 pass / 0 fail / 5 not-run (`K4`) of the 31 pinned FHGM-Specification suite vectors at `ac3d37b3`; see §4.2 |

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
2. **FHGM: draft lane only, and one named hole (K4).** FHGM is not a header type.
   Its records ride inside an FHGFF3 header under the `x-fhgm-models` extension key
   (FORMAT.md R15), and the draft's acceptance model is its own model-level checker -
   rules K1-K6 with the boundary B1. `src/fhgm.jl` implements B1 (a precondition, not
   a rule: no verdict exists on a file whose released header or exact-byte checksum
   does not hold), K1 (transport on the published R15 reading - extension fields from
   FHGFF3 1.1; `overlay = true` additionally applies the pinned draft's narrower
   v0.5.0 transport pin, as the upstream checker does), K2 (every record against the
   pinned record contract), K3 (modelId uniqueness, reported as ambiguous), K5
   (record-reference agreement with the file's genome link) and K6 (predecessor
   resolution against explicitly supplied prior snapshots only). **K4 is
   `not-supported-yet`**: resolving a `featureId` percent-decoded to exactly one local
   gene row needs the GFF3 feature layer, which this library does not read (it belongs
   to `gff3-validator`). A caller that supplies `gene_ids` can close K4 itself; the
   draft-suite runner does not, and the five K4-dependent vectors of the pinned suite
   are reported not-run with that reason - never as passes. The same boundary is what
   the sibling JavaScript library declares; the Java library goes further and reads
   the feature rows, which is a difference we record rather than hide.
3. **GFA containers for a future FHT lane: out of the draft suite by
   definition.** Reason: the FHT draft suite defines `fht-fasta` only; inventing
   GFA draft fixtures here would mean authoring normative expectations the
   owning repository has not stated.
4. **Writer, stripper, converter, `faidx`, `assess`, directive cross-checks
   (`#!genome-build`): out of scope by family design.** Header creation belongs
   to `fair-bioheaders` (Python); this is a reader and verifier
   (AGENTS.md, "Scope of the package").
5. **FHT/FHGM "draft lane" cells are one lane, not five, and none of them is a
   support claim.** The rule-V7 opt-in lane landed on 2026-11-15: `drafts = true`
   per call (`select_contract`, `validate_record`, `verify_file`), pinned bytes under
   `drafts/` with their own `drafts/provenance.json`, a loud warning on every record
   read through it, and the two development suites executed only in the separate,
   labelled `draft-lane` CI job. Still absent, and enforced by `audit_bundled_schemas`
   plus tests: any FHT/FHGM row in `schemas/registry.json` or `versions.json`, any
   `schemaVersion`, w3id URL, release tag or support claim, and any draft vector in
   the shared 291. C3 parent-link verdicts exist only runner-side for the FHT draft
   suite, not as a package API (§1).

## 5. How to read a count in this repository

* Released-contract acceptance: **228 of 291** shared v0.6.0 vectors decided,
  all passing; the 63 remainder are declared not-run with reason 1 above
  (`docs/CONFORMANCE.md`).
* Draft evidence (separate, labelled, never added to the 291, never a support
  claim): FHT **66 pass / 0 fail / 0 not-run of 66** at suite `24d3b033`; FHGM
  **26 pass / 0 fail / 5 not-run of 31** at suite `ac3d37b3`, the five being
  exactly the K4-dependent vectors of reason 2 above. Measured locally on
  2026-11-15 (macOS/arm64, Julia 1.13.2, this tree); the CI `draft-lane` job
  re-derives the same numbers on Linux and additionally enforces the case-control
  of the suite-pin guard, which a case-insensitive filesystem cannot prove.
* Every gap is a named row here with its reason. A missing capability is
  reported as missing; nothing is inferred from the package's function names or
  from the reference toolkit's coverage.
