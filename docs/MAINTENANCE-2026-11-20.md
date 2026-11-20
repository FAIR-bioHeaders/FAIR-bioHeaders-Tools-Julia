# Round 16 maintenance review — 2026-11-20

Agents prepare and repair PRs; humans merge them. Independent review provenance,
exact tested heads, scanner receipts and detailed finding dispositions belong in
the PR discussion and Round 16 evidence packet. No contract, fixture, provenance
pin, golden expectation, release or supported-format expansion is part of this
maintenance change.

The separate B run supplied the inherited policy and human documentation commits
(user-described Qwen; exact author model/provider not observed). The follow-up
author is Codex (GPT-6; routing variant not exposed). Existing worktrees and old
branches were preserved when the follow-up moved to an isolated branch.

## Scope and results

The native suite ran with the exact existing v0.6.0 corpus: 364 assertions passed,
zero failed, errored or broken. Its receipt accounts for all 291 vectors: 228
embedded-header cases decided, 63 JSON-LD/microdata cases explicitly unsupported,
69 canonical counterpart observations passed. The original run without the corpus
reported one broken assertion and is retained as incomplete evidence.

A clean project installed the exact previously documented source revision and
ran the public API on plain/gzip inputs and a one-byte sequence mutation: both
positive checksums matched; the mutation produced an R3 rejection. The package
remains unregistered and source-installed; no published Julia package is claimed.

Gitleaks history found two public synthetic-accession literals, verified against
actual historical source. An oversized configured-Qwen source review repeatedly
lost its transport and supplied no completed report; it is NOT credited as review.
A smaller complete authored-runtime packet with source digests was prepared for
independent model review. Review outcome and subsequent fixes belong in the PR
record. Julia dependency-advisory database coverage was not established by this
run; native acceptance, source review and workflow/history scans have different
scopes and do not close that gap.
