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

# The ref is kept whole, like the reference toolkit's `(.+?)`: a multi-segment ref such as
# `refs/heads/main` or `refs/tags/v0.4.0` is a FAIR-bioHeaders citation of an unsupported
# version (V4), not a non-citation that falls to V5.
const _RAW = r"\Ahttps://raw\.githubusercontent\.com/FAIR-bioHeaders/(?:FHR|FAIR-bioHeaders)-Specification/(.+?)/(fhr|fhp|fhgff3)\.json\z"
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
    canonical = canonical_checksum_findings(metadata)
    if type == "FHT" && ref == "draft"
        append!(canonical, _fht_completeness_findings(metadata))
    end
    text = JSON.json(_validatable(metadata))
    v = contract_validator(type, ref)
    isvalid(v, text) && return canonical
    collector = ResultsCollector(Detailed)
    evaluate(v, text, collector)
    out = copy(canonical)
    for row in results(collector)
        row.is_match && continue
        push!(out, "$(type) $(ref) ($(basename(path))): $(row.message) at $(row.document_evaluation_location)")
    end
    isempty(out) && push!(out, "$(type) $(ref) ($(basename(path))): the record does not conform")
    return out
end

# FHT C1 cross-field arithmetic is defined by the pinned owning contract prose;
# standard JSON Schema cannot express this sum. Missing/ill-typed counts are left
# to schema validation. Integral floats have JSON Schema integer semantics, while
# Bool (an Integer subtype in Julia) is never a count. BigInt avoids wraparound.
function _fht_completeness_findings(metadata::AbstractDict)
    counts = get(metadata, "completeness", nothing)
    counts isa AbstractDict || return String[]
    components = ("completeSingle", "completeDuplicated", "fragmented", "missing")
    integer(x) = !(x isa Bool) && (x isa Integer ||
                 (x isa AbstractFloat && isfinite(x) && isinteger(x)))
    all(k -> haskey(counts, k) && integer(counts[k]), (components..., "total")) ||
        return String[]
    observed = sum(BigInt(counts[k]) for k in components)
    total = BigInt(counts["total"])
    observed == total && return String[]
    return ["C1: completeness component counts must sum to total (sum $(observed), total $(total))"]
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

"The schemes rule R14 accepts for a `format: uri` value, compared without regard to case."
const LINK_SCHEMES = ("http", "https", "ftp", "urn", "doi", "info")
"Of those, the URL schemes, which also need `//` and a host."
const URL_SCHEMES = ("http", "https", "ftp")

# The characters that end a URI-shaped value (RFC 3987 section 4.1): Unicode whitespace,
# C0 and C1 controls, DEL, and the bidirectional formatting characters.
_uri_forbidden(c::Char) = isspace(c) || c == '\u2028' || c == '\u2029' || c <= '\x1f' ||
    ('\x7f' <= c <= '\x9f') || c == '\u200e' || c == '\u200f' || ('\u202a' <= c <= '\u202e') ||
    ('\u2066' <= c <= '\u2069')

"The lower-case scheme of a URI-shaped value (an ASCII scheme, `:`, then no forbidden character), else `nothing`."
function uri_scheme(value::AbstractString)
    isvalid(value) || return nothing
    m = match(r"\A([A-Za-z][A-Za-z0-9+.\-]*):", value)
    m === nothing && return nothing
    rest = SubString(value, ncodeunits(m.match) + 1)
    (isempty(rest) || any(_uri_forbidden, rest)) && return nothing
    return lowercase(m.captures[1])
end

"""
    link_problem(value) -> String | nothing

Why `value` is not an R14 link, worded as the reference toolkit words it, or `nothing`.
"""
function link_problem(value::AbstractString)
    scheme = uri_scheme(value)
    scheme === nothing && return "is not an absolute URI"
    rest = SubString(value, length(scheme) + 2)
    if scheme in URL_SCHEMES
        startswith(rest, "//") && length(rest) > 2 && rest[3] != '/' && return nothing
        return "is not an absolute $(scheme) URL"
    end
    scheme in LINK_SCHEMES && return nothing
    return "uses the URI scheme '$(scheme)'"
end

const _CONTRACT_JSON = Dict{String, Any}()
_contract_json(path::AbstractString) = get!(() -> JSON.parsefile(path), _CONTRACT_JSON, path)

function _resolve_ref(schema, root)
    seen = Set{String}()
    while schema isa AbstractDict && haskey(schema, "\$ref")
        ref = schema["\$ref"]
        (ref isa AbstractString && startswith(ref, "#/") && !(ref in seen)) || break
        push!(seen, ref)
        target = root
        for part in split(ref[3:end], "/")
            target = target[replace(replace(part, "~1" => "/"), "~0" => "~")]
        end
        schema = target
    end
    return schema
end

# Every string the contract marks `format: uri`, found the way the toolkit finds them:
# through `$ref`, `allOf`/`anyOf`/`oneOf`, declared `properties` and `items`. Values the
# contract does not declare (extension `x-` values, for one) are not links.
function _uri_values!(found, value, schema, path::AbstractString, root)
    schema = _resolve_ref(schema, root)
    schema isa AbstractDict || return found
    get(schema, "format", nothing) == "uri" && value isa AbstractString && push!(found, (path, value))
    for keyword in ("allOf", "anyOf", "oneOf")
        for branch in get(schema, keyword, ())
            _uri_values!(found, value, branch, path, root)
        end
    end
    if value isa AbstractDict
        props = get(schema, "properties", nothing)
        if props isa AbstractDict
            for (k, item) in value
                haskey(props, k) || continue
                _uri_values!(found, item, props[k], isempty(path) ? String(k) : "$(path).$(k)", root)
            end
        end
    elseif value isa AbstractVector && get(schema, "items", nothing) isa AbstractDict
        for (i, item) in enumerate(value)
            _uri_values!(found, item, schema["items"], "$(path)[$(i - 1)]", root)
        end
    end
    return found
end

"""
    link_scheme_warnings(metadata; drafts = false) -> Vector{String}

Rule R14: a value whose contract marks it `format: uri` should be an `http` or `https`
URL; `ftp` URLs and `urn:`, `doi:` and `info:` identifiers are accepted too. Schemes are
compared without regard to case; `http`, `https` and `ftp` need `//` and a host; and a
value holding whitespace, a control character or a bidirectional formatting character
has no accepted scheme. Anything else, such as `javascript:`, is reported here. R14 warns:
such a record stays valid, so this never appears among the findings of
[`validate_record`](@ref). The values checked are those the record's own contract
declares; a record whose citation is unsupported (V4) gets no R14 warnings.
"""
function link_scheme_warnings(metadata::AbstractDict; drafts::Bool = false)
    _, _, path = try
        select_contract(get(metadata, "schema", nothing), get(metadata, "schemaVersion", nothing); drafts = drafts)
    catch e
        e isa UnsupportedContract && return String[]
        rethrow()
    end
    schema = endswith(path, ".json") && isfile(path) ? _contract_json(path) : nothing
    schema === nothing && return String[]
    found = Tuple{String, String}[]
    _uri_values!(found, metadata, schema, "", schema)
    out = String[]
    for (p, v) in found
        problem = link_problem(v)
        problem === nothing && continue
        push!(out, "$(p) $(problem); links should use http or https " *
                   "(accepted: $(join(LINK_SCHEMES, ", ")); docs/FORMAT.md R14)")
    end
    return unique!(out)
end

# R4 applies to standard checksum slots independently of frozen schema regexes.
# Arbitrary extension payloads are opaque and are never recursively inspected.
function canonical_checksum_findings(metadata::AbstractDict)
    out = String[]
    function check(value, location)
        value isa AbstractString && !occursin(CANONICAL_B64, value) &&
            push!(out, "R4: $(location) is not canonical SHA-512/256 base64")
    end
    check(get(metadata, "checksum", nothing), "/checksum")
    parents = get(metadata, "derivedFrom", nothing)
    if parents isa AbstractVector
        for (index, parent) in enumerate(parents)
            parent isa AbstractDict && check(get(parent, "checksum", nothing), "/derivedFrom/$(index - 1)/checksum")
        end
    end
    return out
end
