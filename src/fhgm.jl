# FHGM model-level checks - draft lane only, and separate by construction.
#
# FHGM is not a header type. Its records ride inside an FHGFF3 header under the
# `x-fhgm-models` extension key (docs/FORMAT.md R15), the file keeps its released
# FHGFF3 citation and is routed by V1 to V3, and the file checksum covers every record
# byte like any other header byte (R3). A record itself carries no `schema`, no
# `schemaVersion` and no `checksum`, so rule V7 selects only the contract and the
# checks applied to the records - never the type of the file.
#
# Two consequences shape this module:
#
# 1. a verdict here never changes the FHGFF3 result. The caller gets a separate block
#    (`FhgmVerdict`), so a draft outcome cannot be mistaken for, or blended into, a
#    released-contract outcome; and
# 2. B1 is a precondition, not an FHGM rule: the released base schema and the
#    exact-byte checksum must already hold before any model verdict exists. When the
#    caller says the base did not hold, this module reports `not-checked` rather than
#    inventing a verdict on top of a file that is not a sound FHGFF3 file at all.
#
# Implemented, from the draft rule text FHGM-Specification records in
# `development/conformance/manifest.json` (pinned by commit and digest in
# `drafts/provenance.json`):
#
# * K1 transport: the header states a `schemaVersion` that admits extension fields -
#   1.1 or later, per R15 - and carries one or more records under the single top-level
#   `x-fhgm-models` key. `overlay = true` additionally applies the pinned transport
#   overlay, which binds citation and version together: as re-pinned on 2026-11-15 it
#   admits the v0.5.0 FHGFF3 citation only with `schemaVersion` "1.1", and the v0.6.0
#   citation only with "1.2" - two closed branches, no fallback - so a header whose
#   citation and stated version contradict each other passes the R15 reading and is
#   refused by the overlay. That pairing is the upstream checker's own rule
#   (FHGM-Specification PR #17), so it stays opt-in here rather than the default.
# * K2 record shape: every record validates against the pinned record contract (draft
#   2020-12, `assert_format = true`), whose required set is modelId, modelVersion,
#   featureId and reference.
# * K3 uniqueness: modelId is unique within one snapshot; a shared id is reported as
#   ambiguous and rejects that snapshot - the current one or a supplied predecessor.
# * K5 reference agreement: a record reference shares at least one comparable form with
#   the file's genome link and never contradicts it.
# * K6 predecessor verdicts: resolvable, unresolvable or ambiguous, against explicitly
#   supplied prior snapshots only. Nothing is resolved from a file this library was not
#   handed, and a resolvable pointer asserts no curator acceptance.
#
# Not implemented, and reported rather than skipped:
#
# * K4 feature-target resolution: a featureId must resolve, percent-decoded, to exactly
#   one local gene row, which means reading the GFF3 feature layer. This library reads
#   the FHGFF3 header and nothing below it: feature lines, SO terms and biology belong
#   to gff3-validator. `rules["K4"]` is `"not-supported-yet"`, and a caller that has
#   the feature layer from elsewhere can pass `gene_ids` to close the check itself.

struct FhgmVerdict
    "checked | not-checked | absent: absent when the header carries no records at all."
    status::String
    valid::Bool
    errors::Vector{String}
    warnings::Vector{String}
    records::Vector{Dict{String, Any}}
    "what each rule contributed to this reading (pass / reject / absent / skipped / not-supported-yet / none / resolvable)"
    rules::Dict{String, String}
    "the pinned contract this verdict was reached against: repository, commit, sha256."
    contract::Dict{String, Any}
end

function Base.show(io::IO, v::FhgmVerdict)
    println(io, "FHGM draft verdict [", v.status, "]: ", v.valid ? "records conform" : "records do not conform")
    println(io, "  contract: ", v.contract["repository"], " ", v.contract["commit"],
            " sha256 ", v.contract["sha256"], " (unreleased draft, rule V7)")
    for e in v.errors;   println(io, "  error: ", e); end
    for w in v.warnings; println(io, "  warning: ", w); end
end

"The R15 extension key the draft transports records under."
const MODELS_KEY = "x-fhgm-models"

"Rule ids the draft names, including the one this build does not run."
const FHGM_RULES = ("B1", "K1", "K2", "K3", "K4", "K5", "K6")

"The rule this build does not run, and why, for the capability matrix."
fhgm_not_supported() = Dict("K4" => Dict(
    "status" => "not-supported-yet",
    "reason" => "K4 resolves a record featureId, percent-decoded, to exactly one local " *
                "gene row, which needs the GFF3 feature layer; this library reads the " *
                "FHGFF3 header and nothing below it, so feature lines belong to gff3-validator"))

"The rules this build runs, for the capability matrix."
fhgm_rule_coverage() = Dict("implemented" => ["B1", "K1", "K2", "K3", "K5", "K6"],
                            "notSupported" => fhgm_not_supported())

const _PRECEDENCE = Dict("resolvable" => "resolvable", "unresolvable" => "unresolvable",
                         "ambiguous" => "ambiguous")

_isa_dict(v)::Bool = v isa AbstractDict

"""
    admits_extension_fields(v) -> Bool

`docs/FORMAT.md` R15 admits extension fields from FHGFF3 1.1. A `MAJOR.MINOR` string is
compared on both halves as numbers; anything unparseable admits none.
"""
function admits_extension_fields(v)
    v isa AbstractString || return false
    m = match(r"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z", String(v))
    m === nothing && return false
    major, minor = parse(Int, m.captures[1]), parse(Int, m.captures[2])
    return major > 1 || (major == 1 && minor >= 1)
end

# The comparable reference forms of a genome link. Two forms exist: an FHR-family
# parent checksum, and an assembly accession with the supplied SeqCol digest. A form
# the link does not state is absent, never a wildcard.
function _reference_forms(holder, kind::AbstractString)
    forms = Dict{String, Any}()
    _isa_dict(holder) || return forms
    reference = _isa_dict(get(holder, "genomeReference", nothing)) ? holder["genomeReference"] : nothing
    if reference !== nothing
        haskey(reference, "accession") && (forms["accession"] = reference["accession"])
        haskey(reference, "seqcol_id") && (forms["seqcol_id"] = reference["seqcol_id"])
    end
    if kind == "header"
        dfs = get(holder, "derivedFrom", nothing)
        if dfs isa AbstractVector
            for raw in dfs
                parent = _isa_dict(raw) ? raw : Dict{String, Any}()
                if get(parent, "headerType", nothing) == "FHR" &&
                   get(parent, "relationship", nothing) == "annotates" &&
                   haskey(parent, "checksum")
                    forms["fhrChecksum"] = parent["checksum"]
                end
            end
        end
        return forms
    end
    haskey(holder, "annotates") && (forms["fhrChecksum"] = holder["annotates"])
    return forms
end

_shared_forms(l, r) = collect(intersect(keys(l), keys(r)))
_conflicts(l, r) = any(k -> l[k] != r[k], _shared_forms(l, r))
_comparable(l, r) = !isempty(_shared_forms(l, r)) && !_conflicts(l, r)

function _describe_value(v)
    v isa AbstractVector && return "an array of $(length(v))"
    v === nothing && return "null"
    v isa AbstractDict && return "an object"
    return "a $(typeof(v))"
end

# Percent-decode a featureId the way a GFF3 `ID=` value is decoded. A malformed escape
# is left as written rather than throwing: the identifier is data, and K4 compares it
# to whatever the file actually carries.
function decode_feature_id(v)
    v isa AbstractString || return ""
    s = replace(String(v), "+" => "%2B")
    out = try
        Base.unescape_string(s)
    catch
        nothing
    end
    out isa AbstractString ? String(out) : String(v)
end

# Compiled draft-schema validators, keyed by (role, digest): the digest is part of the
# key so a re-pin can never reuse a validator compiled from other bytes. (contracts.jl
# keeps the released validators under its own `_VALIDATORS`.)
const _DRAFT_VALIDATORS = Dict{String, Any}()

"Validate one record (or header) against a draft document compiled once per digest."
function _draft_violations(doc_cache_key::AbstractString, loader, instance)
    v = get!(_DRAFT_VALIDATORS, doc_cache_key) do
        compile_schema(JSON.json(loader()); assert_format = true)
    end
    text = JSON.json(instance)
    isvalid(v, text) && return String[]
    collector = ResultsCollector(Detailed)
    evaluate(v, text, collector)
    msgs = String[]
    for row in results(collector)
        row.is_match && continue
        push!(msgs, row.message)
    end
    isempty(msgs) && push!(msgs, "the record does not conform")
    return msgs
end

# R14 over a single record. The record contract has no root to walk for declarations
# the way a file header has, so the URI-bearing slots are the ones the draft names.
function _record_link_scheme_warnings(record)
    warns = String[]
    for (path, value) in _walk_strings(record, "")
        (occursin(r"(^|\.)uri\$|Url\$", path)) || continue
        (value isa AbstractString && !isempty(value) && link_problem(value) !== nothing) || continue
        push!(warns, "R14 warning: $(path) is \"$(value)\", which has no link scheme " *
                     "docs/FORMAT.md R14 accepts (http, https, ftp, urn:, doi:, info:)")
    end
    return warns
end

function _walk_strings(value, prefix::AbstractString)
    value isa AbstractString && return [(prefix, value)]
    if value isa AbstractVector
        return collect(Iterators.flatten(_walk_strings(item, "$(prefix)[$(i)]")
                                         for (i, item) in enumerate(value)))
    end
    if _isa_dict(value)
        return collect(Iterators.flatten(_walk_strings(v, isempty(prefix) ? string(k) : "$(prefix).$(k)")
                                         for (k, v) in value))
    end
    return Tuple{String, Any}[]
end

"""
    _check_snapshot(header; overlay, label, gene_ids) -> NamedTuple

Run the snapshot-level rules (K1, K2, K3, K5) over one FHGFF3 header. This is the unit
both the current file and every supplied predecessor go through, which is what makes a
rejected predecessor a defect in the reading, not a foundation for one.
"""
function _check_snapshot(header; overlay::Bool = false, label::AbstractString = "current", gene_ids = nothing)
    entry = draft_entry("FHGM")
    rules = Dict("K1" => "pass", "K2" => "pass", "K3" => "pass",
                 "K4" => gene_ids === nothing ? "not-checked" : "pass", "K5" => "pass")
    errors, warnings, records = String[], String[], Dict{String, Any}[]
    by_model_id = Dict{String, Any}()

    stated = get(header, "schemaVersion", nothing)
    if !admits_extension_fields(stated)
        rules["K1"] = "reject"
        push!(errors, "$(label) K1: the header states schemaVersion $(JSON.json(stated)), and " *
                      "docs/FORMAT.md R15 admits extension fields only from FHGFF3 1.1, so no x- " *
                      "key - and no FHGM record - is transportable here")
    end
    models = get(header, MODELS_KEY, nothing)
    if models === nothing
        # No records: everything is reported absent, exactly the shape JS and Java use.
        return (valid = true, errors = errors, warnings = warnings, records = records,
                by_model_id = by_model_id,
                rules = Dict("K1" => "absent", "K2" => "absent", "K3" => "absent",
                             "K4" => "absent", "K5" => "absent"))
    end
    if !(models isa AbstractVector) || isempty(models) || any(!(_isa_dict(m)) for m in models)
        rules["K1"] = "reject"
        push!(errors, "$(label) K1: $(MODELS_KEY) must be a single top-level array holding one or " *
                      "more records, found $(_describe_value(models))")
        return (valid = false, errors = errors, warnings = warnings, records = records,
                by_model_id = by_model_id,
                rules = Dict("K1" => "reject", "K2" => "skipped", "K3" => "skipped",
                             "K4" => "skipped", "K5" => "skipped"))
    end

    if overlay
        ov = load_draft("FHGM", "overlay")
        ov === nothing && throw(HeaderError("V7", "the pinned FHGM transport overlay is unavailable " *
                                             "(rule V7)", 0))
        msgs = _draft_violations("FHGM/overlay/$(draft_entry("FHGM").overlay.sha256)",
                                 () -> load_draft("FHGM", "overlay"), header)
        if !isempty(msgs)
            rules["K1"] = "reject"
            for m in msgs
                push!(errors, "$(label) K1 overlay: the header does not satisfy the pinned transport " *
                              "overlay: $(m)")
            end
        end
    end
    if rules["K1"] == "reject"
        # With no transport there is no record set to judge: the rest is reported as
        # skipped rather than silently passing an untransportable file.
        return (valid = false, errors = errors, warnings = warnings, records = records,
                by_model_id = by_model_id,
                rules = Dict("K1" => "reject", "K2" => "skipped", "K3" => "skipped",
                             "K4" => "skipped", "K5" => "skipped"))
    end

    file_forms = _reference_forms(header, "header")
    gene_rows = gene_ids === nothing ? nothing : Set(String.(gene_ids))

    for (idx, raw) in enumerate(models)
        _isa_dict(raw) || continue   # K1 already refused a non-record entry
        i = idx - 1                  # records are 0-indexed in messages, like the family
        msgs = _draft_violations("FHGM/contract/$(entry.sha256)",
                                 () -> load_draft("FHGM", "contract"), raw)
        record_errors = ["$(label) K2 record $(i): $(MODELS_KEY)[$(i)] does not satisfy the pinned " *
                         "record contract: $(m)" for m in msgs]
        isempty(record_errors) || (rules["K2"] = "reject")
        record_warnings = isempty(record_errors) ? _record_link_scheme_warnings(raw) : String[]
        append!(errors, record_errors)
        append!(warnings, record_warnings)

        result = Dict{String, Any}(
            "index" => i,
            "modelId" => get(raw, "modelId", nothing),
            "modelVersion" => get(raw, "modelVersion", nothing),
            "featureId" => get(raw, "featureId", nothing),
            "valid" => isempty(record_errors),
            "errors" => record_errors,
            "warnings" => record_warnings,
            "predecessor" => nothing,
            "featureTarget" => nothing,
        )

        if gene_rows !== nothing && isempty(record_errors)
            decoded = decode_feature_id(result["featureId"])
            if !(decoded in gene_rows)
                rules["K4"] = "reject"
                result["featureTarget"] = Dict("verdict" => "reject",
                                               "detail" => "no local gene row carries the decoded ID " *
                                                           "$(JSON.json(decoded))")
                push!(errors, "$(label) K4 record $(i): its featureId must target one local gene row, " *
                              "and $(JSON.json(result["featureId"])) matches none")
            else
                result["featureTarget"] = Dict("verdict" => "pass", "detail" => "one local gene row")
            end
        end

        record_forms = _reference_forms(get(raw, "reference", nothing), "record")
        if _conflicts(record_forms, file_forms)
            rules["K5"] = "reject"
            push!(errors, "$(label) K5 record $(i): its reference contradicts the file genome link on " *
                          join(_shared_forms(record_forms, file_forms), ", "))
        elseif !_comparable(record_forms, file_forms)
            rules["K5"] = "reject"
            push!(errors, "$(label) K5 record $(i): has no reference form comparable with the file " *
                          "genome link (the file states $( isempty(keys(file_forms)) ? "nothing" : join(keys(file_forms), ", ")); " *
                          "the record states $( isempty(keys(record_forms)) ? "nothing" : join(keys(record_forms), ", ")))")
        end

        mid = result["modelId"]
        if mid isa AbstractString
            if haskey(by_model_id, String(mid))
                rules["K3"] = "reject"
                push!(errors, "$(label) K3: Ambiguous model ID $(JSON.json(mid)): more than one record " *
                              "in this snapshot shares it, so the identity a pointer needs is unselectable")
            else
                by_model_id[String(mid)] = raw
            end
        end
        push!(records, result)
    end
    return (valid = isempty(errors), errors = errors, warnings = warnings, records = records,
            by_model_id = by_model_id, rules = rules)
end

# One predecessor claim, judged against explicitly supplied prior snapshots only.
function _resolve_predecessor(model, pointer, header, predecessors)
    snapshot = get(pointer, "annotationChecksum", nothing)
    model_id = get(model, "modelId", nothing)
    (snapshot isa AbstractString && snapshot != get(header, "checksum", nothing) &&
     haskey(predecessors, String(snapshot))) ||
        return (verdict = _PRECEDENCE["unresolvable"],
                detail = "the predecessor snapshot is the current file or was not supplied")
    get(pointer, "modelId", nothing) == model_id ||
        return (verdict = _PRECEDENCE["unresolvable"],
                detail = "the pointer names another model ID $(JSON.json(get(pointer, "modelId", nothing)))")
    prior_snapshot = predecessors[String(snapshot)]
    prior = get(prior_snapshot.by_model_id, String(model_id), nothing)
    prior === nothing &&
        return (verdict = _PRECEDENCE["unresolvable"],
                detail = "the predecessor snapshot has no model $(JSON.json(model_id))")
    get(prior, "modelVersion", nothing) == get(pointer, "modelVersion", nothing) ||
        return (verdict = _PRECEDENCE["unresolvable"],
                detail = "the predecessor records version $(JSON.json(get(prior, "modelVersion", nothing)))" *
                         ", not $(JSON.json(get(pointer, "modelVersion", nothing)))")
    get(prior, "modelVersion", nothing) == get(model, "modelVersion", nothing) &&
        return (verdict = _PRECEDENCE["unresolvable"],
                detail = "the revision reuses the predecessor model version")
    for (checksum, other) in predecessors
        checksum == snapshot && continue
        other_model = get(other.by_model_id, String(model_id), nothing)
        _isa_dict(other_model) || continue
        other_pointer = _isa_dict(get(other_model, "predecessor", nothing)) ? other_model["predecessor"] : nothing
        if other_pointer !== nothing &&
           get(other_pointer, "annotationChecksum", nothing) == snapshot &&
           get(other_pointer, "modelId", nothing) == model_id &&
           get(other_pointer, "modelVersion", nothing) == get(pointer, "modelVersion", nothing) &&
           get(other_model, "modelVersion", nothing) != get(prior, "modelVersion", nothing) &&
           _comparable(_reference_forms(other.header, "header"), _reference_forms(prior_snapshot.header, "header")) &&
           _comparable(_reference_forms(get(other_model, "reference", nothing), "record"),
                       _reference_forms(get(prior, "reference", nothing), "record"))
            return (verdict = _PRECEDENCE["ambiguous"],
                    detail = "the pointed record already has a recorded successor in supplied snapshot " *
                             "$(first(string(checksum), 8))...")
        end
    end
    _comparable(_reference_forms(header, "header"), _reference_forms(prior_snapshot.header, "header")) ||
        return (verdict = _PRECEDENCE["unresolvable"], detail = "no matching assembly link with the predecessor snapshot")
    _comparable(_reference_forms(get(model, "reference", nothing), "record"),
                _reference_forms(get(prior, "reference", nothing), "record")) ||
        return (verdict = _PRECEDENCE["unresolvable"], detail = "no matching record reference with the predecessor record")
    return (verdict = _PRECEDENCE["resolvable"],
            detail = "predecessor $(first(string(snapshot), 8))... version $(JSON.json(get(pointer, "modelVersion", nothing)))")
end

"""
    check_fhgm_models(header; base_ok = true, overlay = false, predecessors = [], gene_ids = nothing) -> FhgmVerdict

Run the implemented FHGM model-level checks over one parsed FHGFF3 header. Draft lane
only: with the lane closed this function is never reached from `verify_file`, and the
verdict it returns never joins the released-contract errors of any reading.

* `base_ok`: the caller's released FHGFF3 verdict, schema and checksum together. B1:
  without a base that holds there is no FHGM verdict, only `not-checked`;
* `overlay`: also apply the pinned transport overlay, the way the upstream draft
  checker does (as re-pinned 2026-11-15 it pairs citation with version - v0.5.0 with
  "1.1", v0.6.0 with "1.2", as two closed branches - so a contradictory pairing the
  published R15 reading admits is refused here);
* `predecessors`: prior snapshots K6 may resolve against, each
  `(checksum = ..., header = ...)`; each is itself run through K1-K3 and K5 before any
  pointer is judged against it;
* `gene_ids`: the decoded `ID` of every local gene row, from a caller that took the
  feature layer elsewhere; with it K4 runs, without it K4 is reported
  `not-supported-yet`.
"""
function check_fhgm_models(header; base_ok::Bool = true, overlay::Bool = false,
                           predecessors = Any[], gene_ids = nothing)
    entry = draft_entry("FHGM")
    entry === nothing && throw(HeaderError("V7", "this build pins no FHGM draft contract (rule V7)", 0))
    contract = Dict("type" => "FHGM", "status" => "draft", "repository" => entry.repository,
                    "citation" => entry.citation, "commit" => entry.commit,
                    "sha256" => entry.sha256, "file" => entry.file)
    skipped = Dict(k => (k == "K4" ? fhgm_not_supported()["K4"]["status"] : "skipped")
                   for k in FHGM_RULES)
    if !_isa_dict(header)
        return FhgmVerdict("not-checked", false,
                           ["B1: there is no parsed FHGFF3 header to read records out of"],
                           String[], Dict{String, Any}[], _with(skipped, "B1" => "reject"), contract)
    end
    if !base_ok
        return FhgmVerdict("not-checked", false,
                           ["B1: the released FHGFF3 header or its exact-byte checksum did not hold, " *
                            "so no FHGM verdict exists for this file"],
                           String[], Dict{String, Any}[], _with(skipped, "B1" => "reject"), contract)
    end

    own = _check_snapshot(header; overlay = overlay, label = "current", gene_ids = gene_ids)
    errors = copy(own.errors)
    warnings = String[draft_warning(entry); own.warnings]
    rules = Dict{String, String}(own.rules)
    rules["B1"] = "pass"
    rules["K4"] == "not-checked" && (rules["K4"] = fhgm_not_supported()["K4"]["status"])

    if own.rules["K1"] == "absent"
        for k in ("K2", "K3", "K5", "K6"); rules[k] = "absent"; end
        return FhgmVerdict("absent", true, errors, String[], Dict{String, Any}[], rules, contract)
    end

    # Supplied predecessors go through the same snapshot rules before any pointer is
    # judged against them: an ambiguous or malformed history is a defect in the reading,
    # not a foundation for one.
    resolved = Dict{String, Any}()
    for supplied in predecessors
        ph = _supplied_field(supplied, :header, "header")
        _isa_dict(ph) || continue
        checksum = _supplied_field(supplied, :checksum, "checksum")
        checksum = checksum isa AbstractString ? checksum :
                   (get(ph, "checksum", nothing) isa AbstractString ? ph["checksum"] : nothing)
        checksum === nothing && continue
        prior = _check_snapshot(ph; overlay = overlay,
                                label = "predecessor $(first(string(checksum), 8))...", gene_ids = nothing)
        if !prior.valid && prior.rules["K1"] != "absent"
            append!(errors, prior.errors)
            for (rule, verdict) in prior.rules
                verdict == "reject" && (rules[rule] = "reject")
            end
            continue
        end
        resolved[String(checksum)] = (header = ph, by_model_id = prior.by_model_id)
    end

    any_claim = false
    models = get(header, MODELS_KEY, Any[])
    if models isa AbstractVector
        for record in own.records
            rawm = getindex(models, record["index"] + 1)
            _isa_dict(rawm) || continue
            pointer = get(rawm, "predecessor", nothing)
            _isa_dict(pointer) || continue
            any_claim = true
            verdict = _resolve_predecessor(rawm, pointer, header, resolved)
            record["predecessor"] = Dict("verdict" => verdict.verdict, "detail" => verdict.detail)
            if verdict.verdict == _PRECEDENCE["resolvable"]
                get(rules, "K6", "pass") == "reject" || (rules["K6"] = _PRECEDENCE["resolvable"])
            else
                rules["K6"] = "reject"
                push!(errors, verdict.verdict == _PRECEDENCE["ambiguous"] ?
                      "current K6 record $(record["index"]): Ambiguous model ID - $(verdict.detail)" :
                      "current K6 record $(record["index"]): predecessor is $(verdict.verdict) - $(verdict.detail)")
            end
        end
    end
    any_claim || (rules["K6"] = "none")

    return FhgmVerdict("checked", isempty(errors), errors, warnings, own.records, rules, contract)
end

_with(d::Dict, kv) = (d[kv.first] = kv.second; d)

"A supplied predecessor may arrive as a Dict or as a NamedTuple; read one field from either."
function _supplied_field(obj, k_sym::Symbol, k_str::AbstractString)
    _isa_dict(obj) && return get(obj, String(k_str), nothing)
    obj isa NamedTuple && haskey(obj, k_sym) && return getproperty(obj, k_sym)
    return nothing
end
