# Contract selection and validation: docs/SCHEMA-VERSIONS.md rules V1-V6 and rule R14
# of FAIR-bioHeaders-Specification release v0.6.0.
#
# Validation is delegated to CorvusJsonSchema, which implements draft 2020-12 and is the
# only registered Julia validator measured to enforce the released contracts (see
# docs/CAPABILITY.md): JSONSchema.jl 1.6.0 ignores `format`, `minContains`, `maxContains`
# and `$ref` siblings, and falsely rejects a legal FHGFF3 genome link.
# `assert_format = true` is required: the contracts declare draft 2020-12, where `format`
# is an annotation unless the reader asserts it, and this family asserts `date` and `uri`.
using CorvusJsonSchema
using JSON

const SCHEMA_DIR = normpath(joinpath(dirname(@__FILE__), "..", "schemas"))

"Raised when a citation names a contract this package does not bundle (rule V4)."
struct UnsupportedContract <: Exception
    value::String
    header_type::String
    have::Vector{String}
end

function Base.showerror(io::IO, e::UnsupportedContract)
    print(io, e.header_type, ": unsupported schema version: ", e.value,
          " (this tool has ", e.header_type, " schemas for ", join(e.have, ", "), ")")
end

const TYPES = Dict("fhr" => "FHR", "fhp" => "FHP", "fhgff3" => "FHGFF3")

"The releases whose contract copies this package bundles, and the file of each type."
bundled_contracts() = JSON.parsefile(joinpath(SCHEMA_DIR, "registry.json"))

const REGISTRY = bundled_contracts()

const _RAW = r"\Ahttps://raw\.githubusercontent\.com/FAIR-bioHeaders/(?:FHR|FAIR-bioHeaders)-Specification/([^/]+)/((?:fhr|fhp|fhgff3))\.json\z"
const _W3ID = r"\Ahttps://w3id\.org/fair-bioheaders/(fhr|fhp|fhgff3)/(v[0-9]+\.[0-9]+\.[0-9]+)/?\z"

"Parse a `schema` citation into `(type, ref)`; `nothing` when no rule V1-V3 form matches."
function parse_citation(value)
    value isa AbstractString || return nothing
    m = match(_RAW, String(value))
    m !== nothing && return (TYPES[m.captures[2]], String(m.captures[1]))
    m = match(_W3ID, String(value))
    m !== nothing && return (TYPES[m.captures[1]], String(m.captures[2]))
    return nothing
end

supported(t::AbstractString) = String[collect(get(REGISTRY["supported"], t, String[]))...]

"""
    select_contract(schema_value, schema_version = nothing; drafts = false)

Resolve a record's `schema` citation to `(type, ref, path)`:

* V1: the raw-main URL of a type's file selects this package's current copy of it;
* V2, V3: a release tag in a raw URL, or a w3id URL, selects that release's copy;
* V4: any other ref, or a release without that type, gives `UnsupportedContract` — the
  record is not checked against another schema;
* V5: any other value is FHR, checked against the current FHR schema;
* V6: an FHR record citing raw-main `fhr.json` whose `schemaVersion` is the number 1
  (not the string `"1"`, not a boolean) is read against the bundled v0.3.1 schema; it is
  deprecated, not invalid, and `v6_warning` words the notice;
* V7 (only with `drafts = true`): the raw-main citation of the owning development
  repository of a pinned draft selects that draft's PINNED bytes, reported as
  `("FHT", "draft", <drafts/fht-draft.json>)`. The lane is never implied; with
  `drafts = false` (the default) this function behaves exactly as it did before the
  lane existed. A release-shaped URL for a draft — a w3id URL or a release-tag URL for
  a type the shared registry does not list — is not a draft citation and stays V5 with
  the lane open or shut. FHGM is not a header type: its contract is applied to records
  inside an FHGFF3 header (`src/fhgm.jl`), never selected as a file contract, so its
  citation falls to V5 even with the lane open.
"""
function select_contract(schema_value, schema_version = nothing; drafts::Bool = false)
    parsed = parse_citation(schema_value)
    if parsed === nothing
        draft_lane_of(schema_value; drafts = drafts) !== nothing &&
            return ("FHT", "draft", _draft_path("FHT"))
        return ("FHR", "main", _path("FHR", "main"))
    end
    type, ref = parsed
    if ref == "main"
        type == "FHR" && _is_number_one(schema_version) &&
            return ("FHR", REGISTRY["fhr1"]["release"], _path("FHR", REGISTRY["fhr1"]["release"]))
        return (type, "main", _path(type, "main"))
    end
    entry = get(REGISTRY["files"], ref, nothing)
    (entry === nothing || !haskey(entry, type)) &&
        throw(UnsupportedContract(String(schema_value), type, supported(type)))
    return (type, ref, _path(type, ref))
end

function _draft_path(type::AbstractString)
    e = draft_entry(type)
    e === nothing && throw(HeaderError("V7", "this build pins no draft of type $(type) (rule V7)", 0))
    # load_draft re-verifies the vendored digest against drafts/provenance.json and
    # raises on a mismatch: the pin is enforced at every selection, not just recorded.
    load_draft(type)
    return e.path
end

"The V6 number test: JSON and YAML read `1` and `1.0` as the number 1."
function _is_number_one(v)
    v isa Bool && return false
    v isa Integer && return v == 1
    v isa AbstractFloat && return v == 1.0
    return false
end

"The deprecation notice for a record the V6 rule applies to."
function v6_warning()
    rel = REGISTRY["fhr1"]["release"]
    return "schemaVersion 1 via the raw-main schema URL is read as FHR 1 ($(rel)); " *
           "cite https://w3id.org/fair-bioheaders/fhr/$(rel) or move to schemaVersion \"2.0\""
end

function _path(type::AbstractString, ref::AbstractString)
    entry = get(REGISTRY["files"], ref, nothing)
    entry === nothing && throw(UnsupportedContract(ref, type, supported(type)))
    file = get(entry, type, nothing)
    file === nothing && throw(UnsupportedContract(ref, type, supported(type)))
    path = normpath(joinpath(SCHEMA_DIR, file))
    isfile(path) || error("bundled contract $(file) is missing from $(SCHEMA_DIR)")
    return path
end

const _VALIDATORS = Dict{String, Any}()

"Compile a bundled contract once; `assert_format = true` is what makes `date` and `uri` bind."
function contract_validator(type::AbstractString, ref::AbstractString)
    key = if ref == "draft"
        # The digest belongs in the cache key: a re-pin must never be served a validator
        # compiled from the previous bytes within the same process.
        e = draft_entry(type)
        e === nothing && throw(HeaderError("V7", "this build pins no draft of type $(type) (rule V7)", 0))
        ref * "/" * type * "/" * e.sha256
    else
        ref * "/" * type
    end
    haskey(_VALIDATORS, key) && return _VALIDATORS[key]
    text = if ref == "draft"
        # The lane's bytes: load_draft re-verifies the digest against the registry and
        # raises before returning anything that does not match its pin (rule V7).
        JSON.json(load_draft(type))
    else
        read(_path(type, ref), String)
    end
    v = compile_schema(text; assert_format = true)
    _VALIDATORS[key] = v
    return v
end

"""
    validate_record(metadata[, schema_value, schema_version]; drafts = false) -> Vector{String}

Check a record against the contract its own `schema` value selects. The result holds one
description per finding and is empty when the record conforms. A rule V4 citation appears
as the unsupported-version message, so callers can tell "not checked" from "checked and
rejected". `drafts = true` opens the rule-V7 lane for a record citing a pinned draft
(`select_contract` states the conditions); with the default `drafts = false` the result
is exactly what it was before the lane existed.
"""
function validate_record(metadata::AbstractDict, schema_value = nothing, schema_version = nothing;
                         drafts::Bool = false)
    value = schema_value === nothing ? get(metadata, "schema", nothing) : schema_value
    version = schema_version === nothing ? get(metadata, "schemaVersion", nothing) : schema_version
    type, ref, path = try
        select_contract(value, version; drafts = drafts)
    catch e
        e isa UnsupportedContract && return [sprint(showerror, e)]
        rethrow()
    end
    text = JSON.json(_validatable(metadata))
    v = contract_validator(type, ref)
    isvalid(v, text) && return String[]
    collector = ResultsCollector(Detailed)
    evaluate(v, text, collector)
    out = String[]
    for row in results(collector)
        row.is_match && continue
        push!(out, "$(type) $(ref) ($(basename(path))): $(row.message) at $(row.document_evaluation_location)")
    end
    isempty(out) && push!(out, "$(type) $(ref) ($(basename(path))): the record does not conform")
    return out
end

# A double-quoted YAML scalar may hold a lone surrogate (`"\\ud800"`): PyYAML reads it and
# the reference toolkit validates the record, but no JSON text and no JSON Schema engine here
# can carry one. For validation only, each such code point stands in as U+FFFD, which counts
# as one character for `maxLength` and, like a surrogate, matches no pattern, format or enum
# of the released contracts. The metadata itself keeps the value as read.
_validatable(s::AbstractString) = isvalid(s) ? s : map(c -> isvalid(c) ? c : '\ufffd', String(s))
_validatable(v::AbstractVector) = Any[_validatable(x) for x in v]
_validatable(d::AbstractDict) = Dict{String, Any}(_validatable(String(k)) => _validatable(x) for (k, x) in d)
_validatable(x) = x

# --------------------------------------------------------------------------------------
# Rule R14: link schemes
# --------------------------------------------------------------------------------------

"The schemes rule R14 accepts for a `format: uri` value."
const ACCEPTED_SCHEMES = ("http://", "https://", "ftp://", "urn:", "doi:", "info:")

# The keys the released contracts mark `format: uri` (docs/SCHEMA-VERSIONS.md,
# "Link schemes"): single-valued fields plus the `uri`/`url` of a nested object.
const _URI_KEYS = Set(["uri", "url", "relatedLink", "assemblyProtocol", "predictionProtocol",
                       "annotationProtocol", "schema"])

"""
    link_scheme_warnings(metadata) -> Vector{String}

Rule R14: a `format: uri` value should use `http` or `https`; `ftp`, `urn:`, `doi:` and
`info:` are accepted too. Any other scheme, such as `javascript:`, is reported here.
R14 warns: such a record stays valid, so this never appears among the findings of
[`validate_record`](@ref).
"""
function link_scheme_warnings(metadata::AbstractDict)
    found = String[]
    _schemes!(found, metadata, "")
    unique!(found)
end

function _schemes!(out, value::AbstractDict, path::AbstractString)
    for (k, v) in value
        p = isempty(path) ? string(k) : path * "." * string(k)
        _scheme_check!(out, string(k), v, p)
        v isa AbstractDict && _schemes!(out, v, p)
        if v isa AbstractVector
            for (i, item) in enumerate(v)
                item isa AbstractDict && _schemes!(out, item, "$(p)[$(i)]")
                item isa AbstractString && string(k) == "relatedLink" &&
                    _scheme_check!(out, string(k), item, "$(p)[$(i)]")
            end
        end
    end
    return out
end

function _scheme_check!(out, key::AbstractString, value, path::AbstractString)
    key in _URI_KEYS || return out
    value isa AbstractString || return out
    isempty(value) && return out
    any(s -> startswith(value, s), ACCEPTED_SCHEMES) && return out
    push!(out, "$(path) is not an http, https, ftp, urn, doi or info link: $(repr(value))")
    return out
end
