# Security policy

This package is a reader/verifier of untrusted files. Parsing robustness (a crafted
header that crashes, hangs or misreports validity) and checksum-subversion surface
(bytes that should break R3 coverage but do not) are in scope. Contract validation is
delegated to CorvusJsonSchema; engine defects that change verdicts are in scope here as
well, and the probe matrix in `docs/CAPABILITY.md` is how a candidate engine is judged.

Report suspected vulnerabilities privately, including affected version/commit,
reproduction steps, impact, and any safe proof of concept. Avoid posting credentials,
private genome data, or exploit details in a public issue. Maintainers should
acknowledge receipt, assess severity, coordinate a fix and disclosure, and credit the
reporter with consent. Correctness issues without security impact can use ordinary
issues.

## Private reporting channel

Email [molik@fhref.org](mailto:molik@fhref.org) for both the specification and the
family tools. Identify the affected repository and version. This is the
maintainer-confirmed reporting address; do not assume GitHub private vulnerability
reporting is enabled.

Coordinate disclosure privately with the maintainers. No guaranteed response deadline
is stated. If a report involves David Molik, contact
[Adam Wright](mailto:wright@fhref.org) directly. If it involves Adam Wright, use
David's address above. Do not copy a maintainer involved in the report; use an
uninvolved reviewer for escalation.
