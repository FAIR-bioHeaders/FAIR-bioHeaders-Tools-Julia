# Agent instructions

## Repository identity and current state

This is **FAIR-bioHeaders-Tools-Julia**, one of the four per-language library
repositories of the FAIR-bioHeaders family. It is **not** one of the six
specification repositories that carry the shared family AGENTS.md, and it holds
no part of the shared guidance text; the "in step" convention described in
FAIR-bioHeaders-Specification's AGENTS.md (byte-identity retired by maintainer
decision on 2026-11-14) does not apply to this file, and nothing here should be
compared against those repositories for identity.

Authoritative neighbours:

| Repository | Role relative to this one |
| --- | --- |
| FAIR-bioHeaders-Specification | The rules (docs/FORMAT.md, FHP.md, FHGFF3.md, SCHEMA-VERSIONS.md), the released contracts and the shared conformance vectors. |
| FAIR-bioHeaders-Tools | The reference implementation (`fair-bioheaders`, Python). Writers of headers and checksums. |

Current state: development only. The remote `main` has no released version and the
package is not registered in the Julia General registry; registration, tagging and
release are maintainer actions. The bundled contracts in `schemas/` are frozen
copies of specification tag **v0.6.0** (FHR 2.1, FHP 1.2, FHGFF3 1.2) with
per-file SHA-256 in `schemas/provenance.json`; refresh them only as an explicit,
provenance-updating change, and re-verify `current/` against the live raw bytes of
the owning release/main when auditing — a stale pin once passed unnoticed in this
family, so check by hash, not by file name.

## Scope of the package

Reader/verifier only: parse a `;~`/`#~` header block, verify the SHA-512/256
checksum over the bytes R3 defines, type the YAML under R8/R11/R12/R13, and
validate the record against the contract its own `schema` citation selects (V1–V6).
It must not write headers, recompute-and-rewrite checksums, or repair files — the
Python toolkit owns creation. Supporting an already released field or rule in a
consumer is implementation work; any change to what a contract *accepts* is a
schema-contract change and belongs to FAIR-bioHeaders-Specification's cycle, not to
a PR here.

Rule V7: FHT and FHGM are drafts with **no released contract**. No `schemaVersion`, no
w3id URL, no registry row and no support claim for either — in code, tests, docs or
prose. By default a citation of either falls to V5 like any other unknown value (the
regression tests pinning this behaviour stay, lane open or shut). This repository
implements the V7 *opt-in* lane (maintainer direction of 2026-11-14,
FAIR-bioHeaders-Specification#211 round 10; the sibling JavaScript, Java and R
libraries have theirs — this file's earlier "no draft lane" scope decision is
superseded deliberately, not silently): `drafts = true` per call reads the pinned bytes
under `drafts/`, re-digesting against `drafts/provenance.json` on every load; every
record read that way carries the V7 warning; the two development suites run only in the
separate labelled `draft-lane` CI job and never join the shared 291. Two pins per type
are enforced, not just recorded: the contract bytes (`commit`/`sha256`, checked by
`scripts/draft_pins.jl --check-contract`) and the suite revision
(`suiteCommit`/`suiteManifestSha256`, checked by `check_suite_pin` — the runner refuses
to score a suite that does not verify, and `test/runtests.jl` proves the refusal on a
one-byte mutation). FHGM is not a header type and must never be modelled as one. The
draft-pin freshness job is advisory (`continue-on-error`) and nothing re-pins
automatically: re-pinning is a deliberate, dated commit changing bytes, commit, digest
and prose together.

## Hard technical constraints (measured, see docs/CAPABILITY.md)

* The contracts declare **JSON Schema draft/2020-12**. The validation engine here is
  `CorvusJsonSchema` with `assert_format = true`. Do not switch to `JSONSchema.jl`:
  1.6.0 was measured to silently ignore `format`, and to falsely reject the legal
  FHGFF3 `annotates` link form. Any engine change must reproduce the conditional-
  firing matrix in docs/CAPABILITY.md against the released bytes first.
* The digest is **SHA-512/256**, base64 with padding whose last 4 bits are zero
  (R4). Julia stdlib `SHA.SHA2_512_256_CTX` is byte-equal to the released toolkit;
  keep it that way and keep the NIST probe in the test suite. The API exists only
  from Julia **1.12** (measured: 1.10/1.11 stdlib SHA 0.7.0 lack it and cannot be
  overridden from the registry), which is why `julia = "1.12"`; do not lower it.
* Julia gotchas that bit this tree once: `$ref` inside a triple-quoted docstring
  is string interpolation (escape it as `\$ref`); `String(::Vector{UInt8})` steals
  the array's buffer; `parse(Int, ...; raise = false)` does not exist for integers
  on any 1.x and the Float64 `raise = false` route broke on 1.13; JSON 1.14 returns
  `JSON.Object`, so annotate against `AbstractDict`, not `Dict`.

## Acceptance

The shared **291 conformance vectors** at specification tag v0.6.0 are the gate —
never a new per-language suite. `test/runtests.jl` takes them from
`FAIRBIOHEADERS_CONFORMANCE`; CI checks out the released tag, never main. Report
per-format pass counts and name skipped vectors with their reason (gzip/BGZF input
is decided natively through the documented `CodecZlib` boundary, docs/CAPABILITY.md
E0(d); only the JSON-LD and microdata bindings are out of scope here and reported as
undecided, not as passed). From this decision: local
`julia --project=. -e 'using Pkg; Pkg.test()'` — which includes the native
bundled-schema audit (`audit_bundled_schemas`, `src/audit.jl`); the former
`python3 scripts/check_bundled_schemas.py` audit remains only as the supplemental
CI differential and is no longer the primary path (issue #3: the acceptance job
runs without Python).

## Licensing

MPL-2.0 for this repository's own material, expressed by the LICENSE file, which
also carries the family's historical USDA-ARS public-domain transition text without
claiming this repository contains such material. A blanket public-domain
dedication is not available to any family repository. Vendored copies under
`schemas/` travel with the specification's terms. Julia takes the bare SPDX string
(`license = "MPL-2.0"` in Project.toml) — unlike the sibling R repository there is
no `| file LICENSE` form; RegistryCI validates license *contents* via
LicenseCheck, and both were measured to pass (docs/CAPABILITY.md). Keep third-party
notices for dependencies in LICENSE section 3 when dependencies change.

## Working conventions

Fetch before asserting; checkouts lag in both directions. Plain technical prose in
branch/commit/PR text. Never invent a digest, version, DOI, license string or test
count; report failures verbatim. Do not merge PRs, tag releases, submit to the
Julia registry or push to main without maintainer action.
