# Declared reference audit

The adapter reads the current native provenance/registry files at execution time;
`authority-revisions.json` records dereferenced published tag commits separately
from native historical annotated-tag object IDs. Neither source files nor pins
are rewritten. The shared checker is reused at the immutable source/digest in
`checker.json`; bootstrap verifies Git HEAD, immutable blob, digest and symlink
boundaries, and runs those bytes from an isolated private snapshot.

Run `python3 scripts/audit_declared_references.py --checker-root CHECKER`.
`--checkout OWNER/REPO=PATH` supplies offline Git authorities. Online findings
are advisory and include negative probe controls. Missing metadata is not FRESH;
bootstrap/network errors produce QUERY_FAILED, and workflow artifacts are retained.
Strict engine controls use independent temporary Git authorities, never current
moving drafts. Draft results are not acceptance, curator review or publication.

The generated inventory explicitly lists coverage gaps. Source/suite pins remain
separate. Full external suite payload completeness is not asserted from a manifest
pin. Actual native draft semantics and final accepted 93/92 suites remain separate
from these historical reference comparisons; no automatic refresh is performed.

The native schema provenance names `versionsRegistryFile` but records no digest
for that copied registry. It is enumerated as an incomplete recorded reference
and reports ABSENT rather than inventing a measurement or treating local bytes
as independent authority. The native schema audit remains a separate check.
