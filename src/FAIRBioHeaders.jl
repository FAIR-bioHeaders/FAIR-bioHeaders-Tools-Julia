"""
FAIRBioHeaders: read and verify FAIR-bioHeaders metadata in Julia.

FHR, FHP and FHGFF3 files carry a YAML metadata header inside the data file, covered by a
SHA-512/256 checksum of the file's exact bytes and validated against a per-type JSON Schema
contract. The rules belong to FAIR-bioHeaders-Specification (docs/FORMAT.md, docs/FHP.md,
docs/FHGFF3.md, docs/SCHEMA-VERSIONS.md); this package implements its reader side for Julia,
against release v0.6.0 of those contracts.

What is native here and what is delegated:

* the checksum and the header byte rules are Julia standard library only (`SHA`'s
  `SHA2_512_256_CTX` plus `Base64`) — see `docs/CAPABILITY.md` for the digest-equality
  measurement against the released Python toolkit;
* gzip and BGZF input is decompressed before hashing (rule R1 hashes the decompressed bytes)
  through `CodecZlib`, the package's only compiled-dependency boundary; `src/gzip.jl` isolates
  it and `docs/CAPABILITY.md` records the measurement that decides it;
* the metadata block is read by this package's own strict reader (`src/reader.jl`), because
  the Julia `YAML` package diverges from rules R8, R12 and R13 and from the family's folding
  behaviour, also recorded in `docs/CAPABILITY.md`;
* contract validation is delegated to `CorvusJsonSchema` with `assert_format = true`, the
  only registered Julia validator measured to enforce draft 2020-12 correctly on these
  contracts. `JSONSchema.jl` is not used: it silently ignores `format`, `minContains`,
  `maxContains` and `\$ref` siblings, and falsely rejects a legal FHGFF3 genome link.

FHT and FHGM have no released contract (rule V7 keeps a draft out of every release form),
so by default this package recognizes neither: no `schemaVersion`, w3id URL, registry row
or support claim exists for either, and a citation of either falls to rule V5 like any
other value. The explicit rule-V7 draft lane (`drafts = true` per call, `src/drafts.jl`)
is opt-in and never the default: it reads the *pinned* draft bytes vendored under
`drafts/` (re-digested against `drafts/provenance.json` on every load), warns on every
record read through it, and reports the draft suites separately from the shared 291
vectors. Opening the lane grants no release form.

```julia
julia> using FAIRBioHeaders
julia> verify_file("genome.fhr.fa")
```
"""
module FAIRBioHeaders

using Base64
using JSON
using SHA

include("checksum.jl")
include("reader.jl")
include("yaml.jl")
include("gzip.jl")
include("drafts.jl")
include("contracts.jl")
include("fhgm.jl")
include("verify.jl")
include("audit.jl")
include("conformance.jl")

export
    # byte layer
    scan_lines, header_checksum, checksum_value, header_block, checksum_line, PREFIX, kind_of,
    scan_header, HeaderScan, stated_checksum, MAX_HEADER_BYTES, MAX_HEADER_LINES,
    # gzip / BGZF input (rule R1: the digest covers the decompressed bytes)
    is_gzip, decompress_gzip, read_file_bytes, foreach_chunk,
    # metadata
    read_fhr_header, read_fhr_file, FHRHeader, metadata_of, HeaderError,
    portable_plain_tag, yaml11_tag, yaml12_tag, unescape_double, fold_lines,
    # contracts
    bundled_contracts, select_contract, parse_citation, validate_record, contract_validator,
    UnsupportedContract, supported, v6_warning, link_scheme_warnings,
    # rule V7 draft lane (opt-in; nothing here runs by default)
    draft_registry, draft_types, draft_entry, draft_suite_pin, citation_index, draft_lane_of,
    draft_warning, draft_support, load_draft, verify_draft_bytes, check_suite_pin,
    check_contract_pin,
    # FHGM model-level checks (draft lane only; separate from the FHGFF3 result)
    FhgmVerdict, check_fhgm_models, admits_extension_fields, fhgm_rule_coverage,
    fhgm_not_supported, MODELS_KEY,
    # bundle audit
    audit_bundled_schemas,
    # files and the shared vectors
    verify_file, VerifyResult, container_findings, header_type_of, checksum_line_findings,
    ALLOWED_TYPES, run_conformance, summarise, VectorOutcome,
    implemented_rules, runnable_formats

end # module
