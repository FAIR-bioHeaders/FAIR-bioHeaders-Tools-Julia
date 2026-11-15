# Contributing

Start with an issue describing the use case or failure and a small reproducible
example. Submit a focused branch/PR. Link related work in
[FAIR-bioHeaders-Specification](https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification)
when a change spans repositories. Do not include private genome data, credentials, or
unrelated formatting in fixtures.

This package reads and verifies; it does not write headers or checksums. Behavior that
a header *consumer* must show is defined by the specification (`docs/FORMAT.md`,
`docs/FHP.md`, `docs/FHGFF3.md`, `docs/SCHEMA-VERSIONS.md`) — cite the rule (R1-R15,
P1-P2, G1-G3, V1-V7) in the change description. A change to what a contract accepts is
a schema-contract change and belongs to the specification repository's own cycle, not
to a PR here.

## Setup and checks

From this checkout (Julia 1.12+; CI runs 1.12 and 1.x — the SHA-512/256 stdlib API
exists from 1.12, see `docs/CAPABILITY.md`):

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'   # includes the native
#   bundled-schema audit (src/audit.jl); the old python3 audit
#   (scripts/check_bundled_schemas.py) survives only as the supplemental CI differential,
#   never as the acceptance path.
```

Acceptance runs against the shared conformance vectors, taken from the specification
at the **released tag**, never main:

```sh
git clone --branch v0.6.0 --depth 1 \
  https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification /tmp/spec
FAIRBIOHEADERS_CONFORMANCE=/tmp/spec/conformance \
  julia --project=. -e 'using Pkg; Pkg.test()'
```

When a vector cannot be decided here (JSON-LD, microdata), report it as undecided with
its reason; do not convert an undecided vector into a pass and do not claim family parity
from a partial run. Compressed (gzip/BGZF) input is decided natively (`src/gzip.jl`).

## Bundled contracts

`schemas/` holds frozen, byte-for-byte copies of released contracts. Refreshing them is
an explicit change: update the copies and `schemas/provenance.json` together (sha256,
git blob, source tag/path per file), keep `registry.json` consistent with the
specification's `schemas/versions.json`, and record which release was fetched. FHT and FHGM are drafts (rule V7) and take no registry row, released schema file,
`schemaVersion` or w3id claim here; `schemas/` stays a directory of released contracts
only. The pinned draft bytes live separately under `drafts/` with their own
`drafts/provenance.json` (see AGENTS.md, "Rule V7"): changing them means bytes, commit,
digests and prose in one deliberate commit, never an automated refresh.

David and Adam are the maintainers and jointly hold schema and release authority
([GOVERNANCE](https://github.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification/blob/main/GOVERNANCE.md)).
Merging PRs, tagging releases and registering the package with the Julia General
registry are maintainer actions. Follow the SECURITY policy for sensitive findings.
