# File-level reading and verification.

"""
    VerifyResult

`ok` is true only when the file parsed, its checksum matched the bytes it covers, its header
type suits its container and — unless validation was declined — its metadata conformed to
the contract its own `schema` value selects. A record citing a contract this build does not
bundle (rule V4) is not ok: `not_checked` names the unsupported version, so it never reads
as a pass. `fhgm` is `nothing` unless the rule-V7 draft lane was opened and
the file is an FHGFF3 reading: it then holds the separate [`FhgmVerdict`](@ref), which
never alters `ok` or `errors` (rule B1 reports beside the released result).
"""
struct VerifyResult
    path::String
    kind::String
    ok::Bool
    stated::Union{String, Nothing}
    computed::Union{String, Nothing}
    metadata::Union{Dict{String, Any}, Nothing}
    errors::Vector{String}
    warnings::Vector{String}
    not_checked::Vector{String}
    fhgm::Union{Any, Nothing}
end

"Positional construction without the draft field: the lane-off shape is unchanged."
function VerifyResult(path::AbstractString, kind::AbstractString, ok::Bool,
                      stated::Union{String, Nothing}, computed::Union{String, Nothing},
                      metadata::Union{Dict{String, Any}, Nothing},
                      errors::Vector{String}, warnings::Vector{String}, not_checked::Vector{String})
    VerifyResult(String(path), kind, ok, stated, computed, metadata, errors, warnings, not_checked, nothing)
end

function Base.show(io::IO, r::VerifyResult)
    status = r.ok ? "valid" :
             (isempty(r.errors) && _unsupported(r) ? "not valid: unsupported schema version (rule V4)" : "invalid")
    println(io, r.path, " [", r.kind, "]: ", status)
    if r.computed !== nothing
        println(io, "  checksum: ", r.computed,
                r.stated == r.computed ? " (matches the file)" : " (the file states $(r.stated))")
    end
    for e in r.errors
        println(io, "  error: ", e)
    end
    for w in r.warnings
        println(io, "  warning: ", w)
    end
    for n in r.not_checked
        println(io, "  not checked: ", n)
    end
    if r.fhgm !== nothing
        println(io, "  --- FHGM draft verdict (rule V7 lane; separate from the released result above) ---")
        show(io, r.fhgm)
    end
end

_unsupported(r::VerifyResult) = any(n -> occursin("unsupported schema version", n), r.not_checked)

"The header kind of a file name, by extension; `nothing` when the name says nothing."
function kind_of(path::AbstractString)
    p = lowercase(path)
    endswith(p, ".gz") && (p = p[1:end - 3])
    (occursin(".fhgff3.gff3", p) || endswith(p, ".gff3")) && return "fhgff3"
    endswith(p, ".gfa") && return "gfa"
    occursin(".fhp.fasta", p) && return "fhp-fasta"
    (endswith(p, ".fasta") || endswith(p, ".fa") || endswith(p, ".fna")) && return "fasta"
    return nothing
end

"""
    read_fhr_file(data, kind) -> FHRHeader

Read the header block of one file: the leading FHR lines (R10), their encoding (R6, R7),
the version directive of an FHGFF3 file (G1) and the metadata block (R8, R11, R12, R13).
Rule R11 is a writer recommendation: a header line holding a raw `>` or `@` stays valid and
is reported in `warnings`.
"""
read_fhr_file(data::Vector{UInt8}, kind::AbstractString) = header_of_scan(scan_header(data, kind))

"""
    read_fhr_file(path; kind = nothing) -> FHRHeader

The file-reading half of [`verify_file`](@ref), for callers that want the metadata and the
R11 warnings without contract validation. The file is streamed, never read whole.
"""
function read_fhr_file(path::AbstractString; kind::Union{Nothing, AbstractString} = nothing)
    k = kind === nothing ? kind_of(path) : String(kind)
    k === nothing && throw(ArgumentError("cannot tell the header kind from $(repr(path)); pass kind"))
    return header_of_scan(open(io -> scan_header(io, k), path))
end

"The metadata of a scanned file, with the R10, G1, R6 and YAML rules applied."
function header_of_scan(scan::HeaderScan)
    kind = scan.kind
    isempty(scan.header) && throw(HeaderError("R10", "the file has no header block", 1))
    isempty(scan.late) || throw(HeaderError("R10", "an FHR line follows the data section", first(scan.late)))
    if kind == "fhgff3"
        text = isvalid(String, scan.first_line) ? String(copy(scan.first_line)) : ""
        occursin(r"\A##gff-version 3(\.[0-9]+\.[0-9]+)?[ \t]*\z", text) ||
            throw(HeaderError("G1", "line 1 must be ##gff-version 3 or ##gff-version 3.MINOR.PATCH, found $(repr(text))", 1))
    end
    for (line, content, _) in scan.header
        # `String(bytes)` never throws, so ask directly: overlong forms and surrogates fail too.
        isvalid(String, content) || throw(HeaderError("R6", "an FHR header line is not valid UTF-8", line))
        any(c -> c in YAML_ONLY_BREAKS, String(copy(content))) &&
            throw(HeaderError("R6", "an FHR header line contains U+0085, U+2028 or U+2029, " *
                                    "which YAML reads as a line break", line))
    end
    text, numbers = header_yaml(scan)
    header = read_fhr_header(text; line_numbers = numbers)
    warnings = String[]
    if kind in ("fasta", "fhp-fasta")
        for (line, content, _) in scan.header
            any(b -> b == UInt8('>') || b == UInt8('@'), content) && push!(warnings,
                "line $(line) holds a raw '>' or '@' (rule R11); writers escape them as \\x3E and \\x40")
        end
    end
    return FHRHeader(header.metadata, append!(warnings, header.warnings))
end

"""
    checksum_line_findings(scan, metadata) -> Vector{String}

The reference toolkit's last check on the checksum line: read alone as YAML it must be
exactly `{checksum: <value>}`, and that value must be the record's `checksum`. A line that
matches the R5 shape but sits inside a multi-line quoted scalar or flow collection fails
it, because the record's `checksum` is then something else or nothing.
"""
function checksum_line_findings(scan::HeaderScan, metadata::AbstractDict)
    scan.matches == 1 || return String[]
    content = scan.header[scan.candidate][2]
    alone = try
        isvalid(String, content) ?
            read_fhr_header(String(content[(length(scan.prefix) + 1):end])).metadata : nothing
    catch e
        e isa HeaderError || rethrow()
        nothing
    end
    ok = alone isa AbstractDict && collect(keys(alone)) == ["checksum"] &&
         alone["checksum"] isa AbstractString && !isempty(alone["checksum"]) &&
         get(metadata, "checksum", nothing) == alone["checksum"]
    ok && return String[]
    return ["the checksum line must hold the record's complete checksum value as a single-line " *
            "scalar (rule R5): read alone it is not the record's checksum"]
end

"""
Header types each container may carry (FORMAT.md: FHR in FASTA and GFA, FHP in FASTA,
FHGFF3 in GFF3). The FHT draft rides FASTA only, and only through the opt-in V7 lane.
"""
const ALLOWED_TYPES = Dict("fasta" => ("FHR", "FHP"), "fhp-fasta" => ("FHR", "FHP"),
                           "gfa" => ("FHR",), "fhgff3" => ("FHGFF3",))

const _CONTAINER_NAME = Dict("fasta" => "FASTA", "fhp-fasta" => "FASTA", "gfa" => "GFA", "fhgff3" => "GFF3")

"The header type a record's `schema` names: FHP, FHGFF3, FHT (draft lane only) or, by rule V5, FHR."
function header_type_of(metadata::AbstractDict; drafts::Bool = false)
    value = get(metadata, "schema", nothing)
    parsed = parse_citation(value)
    parsed !== nothing && return parsed[1]
    draft_lane_of(value; drafts = drafts) !== nothing && return "FHT"
    return "FHR"
end

"""
    container_findings(metadata, kind; drafts = false) -> Vector{String}

A header whose type does not match its container makes the file invalid even when its
checksum matches (FORMAT.md): FHR in FASTA or GFA, FHP in FASTA, FHGFF3 in GFF3.
"""
function container_findings(metadata::AbstractDict, kind::AbstractString; drafts::Bool = false)
    family = header_type_of(metadata; drafts = drafts)
    allowed = ALLOWED_TYPES[kind]
    drafts && kind in ("fasta", "fhp-fasta") && (allowed = (allowed..., "FHT"))
    family in allowed && return String[]
    return ["$(family) metadata is incompatible with $(_CONTAINER_NAME[kind]); expected " *
            "$(join(allowed, " or ")) metadata (FORMAT.md: each header type has its containers)"]
end

"""
    verify_file(path; kind = nothing, validate = true, drafts = false) -> VerifyResult

Check one file end to end: gzip/BGZF input is decompressed first (R1 hashes the
decompressed bytes), then header block and checksum line (R2, R5), checksum coverage and
value (R1-R4), encoding (R6, R7), placement (R10, G1), metadata rules (R8, R11, R12, R13),
then the contract the record selects for itself (V1-V6) with its `format` assertions, and
the R14 link-scheme warnings.

A rule V4 citation is reported under `not_checked` and makes `ok` false: the file was not
checked against a different schema, which is what V4 requires, so it is not reported valid.
The file is read once, in chunks: memory stays bounded by the header block (at most 1 MiB)
whatever the size of the file.

`drafts = true` opens the rule-V7 lane: an FHT record citing its owning repository's
raw-main URL is read against the pinned draft bytes (the digest is re-verified against
`drafts/provenance.json` first, and a mismatch raises), the V7 draft warning travels
with every such record, and for FHGFF3 readings the nested `x-fhgm-models` records get a
separate [`FhgmVerdict`](@ref) in `result.fhgm` that never alters the released result
(B1). With the default `drafts = false` nothing in this paragraph runs: the result is
byte-for-byte what it was before the lane existed.
"""
function verify_file(path::AbstractString; kind::Union{Nothing, AbstractString} = nothing,
                     validate::Bool = true, drafts::Bool = false)
    k = kind === nothing ? kind_of(path) : String(kind)
    k === nothing && return VerifyResult(path, "?", false, nothing, nothing, nothing,
        ["cannot tell the header kind from the file name; pass kind"], String[], String[])
    errors, warnings, not_checked = String[], String[], String[]
    stated = computed = nothing
    metadata = nothing
    fhgm = nothing
    try
        scan = open(io -> scan_header(io, k), path)          # one streaming pass (R1-R5, R7, R10)
        computed = scan.computed
        try
            stated = stated_checksum(scan)
        catch e
            e isa ArgumentError || rethrow()
            push!(errors, e.msg)
        end
        stated !== nothing && computed !== nothing && stated != computed && push!(errors,
            "the stated checksum does not match the bytes it covers (rule R3): stated $(stated), computed $(computed)")
        header = header_of_scan(scan)
        metadata = header.metadata
        append!(warnings, header.warnings)
        stated !== nothing && append!(errors, checksum_line_findings(scan, metadata))
        if validate
            version = get(metadata, "schemaVersion", nothing)
            findings = validate_record(metadata, get(metadata, "schema", nothing), version; drafts = drafts)
            if !isempty(findings) && occursin("unsupported schema version", first(findings))
                push!(not_checked, first(findings))
            else
                append!(errors, findings)
                append!(errors, container_findings(metadata, k; drafts = drafts))
            end
            append!(warnings, link_scheme_warnings(metadata))
            if _is_number_one(version) && parse_citation(get(metadata, "schema", nothing)) == ("FHR", "main")
                push!(warnings, v6_warning())
            end
            if drafts
                lane = draft_lane_of(get(metadata, "schema", nothing); drafts = true)
                lane !== nothing && push!(warnings, draft_warning(lane))
                if k == "fhgff3" && MODELS_KEY in keys(metadata)
                    # The lane's FHGM reading: separate by construction. The released
                    # verdict above is its B1 precondition, never its consequence.
                    base_ok = isempty(errors) && isempty(not_checked)
                    fhgm = check_fhgm_models(metadata; base_ok = base_ok)
                    append!(warnings, setdiff(fhgm.warnings, warnings))
                end
            end
        else
            push!(errors, container_findings(metadata, k)...)
            push!(not_checked, "contract validation (validate = false)")
        end
    catch e
        if e isa HeaderError
            push!(errors, sprint(showerror, e))
        elseif e isa UnsupportedContract
            push!(not_checked, sprint(showerror, e))
        else
            push!(errors, string(typeof(e)) * ": " * sprint(showerror, e))
        end
    end
    # A record citing a contract this build does not bundle (V4) was not checked, so it is
    # not valid: `ok` says so, and `not_checked` says why (README "Use").
    unsupported = any(n -> occursin("unsupported schema version", n), not_checked)
    return VerifyResult(path, k, isempty(errors) && !unsupported, stated, computed, metadata,
                        errors, warnings, not_checked, fhgm)
end
