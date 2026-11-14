# File-level reading and verification.

"""
    VerifyResult

`ok` is true only when the file parsed, its checksum matched the bytes it covers and —
unless validation was declined — its metadata conformed to the contract its own `schema`
value selects. `not_checked` records what was *not* checked, so an unsupported citation
never reads as a pass.
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
end

function Base.show(io::IO, r::VerifyResult)
    println(io, r.path, " [", r.kind, "]: ", r.ok ? "valid" : "invalid")
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
end

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
    read_fhr_file(path, kind) -> FHRHeader

Read the header block of one file: the leading FHR lines (R10), their encoding (R6, R7),
the version directive of an FHGFF3 file (G1) and the metadata block (R8, R11, R12, R13).
Rule R11 is a writer recommendation: a header line holding a raw `>` or `@` stays valid and
is reported in `warnings`.
"""
function read_fhr_file(data::Vector{UInt8}, kind::AbstractString)
    haskey(PREFIX, kind) || throw(ArgumentError("unknown header kind $(repr(kind))"))
    check_byte_order_mark(data, kind)
    lines = scan_lines(data)
    kind == "fhgff3" && check_gff3_version(lines, data)
    indices, late = header_block(data, lines, kind)
    isempty(indices) && throw(HeaderError("R10", "the file has no header block", 1))
    isempty(late) || throw(HeaderError("R10", "an FHR line follows the data section", first(late)))
    check_header_encoding(data, lines, indices)
    text = header_text(data, lines, indices, kind)
    header = read_fhr_header(text; first_line = first(indices))
    warnings = String[]
    if kind in ("fasta", "fhp-fasta")
        for i in indices
            body = String(data[lines[i][1]])
            any(c -> c == '>' || c == '@', body) && push!(warnings,
                "line $(i) holds a raw '>' or '@' (rule R11); writers escape them as \\x3E and \\x40")
        end
    end
    return FHRHeader(header.metadata, append!(warnings, header.warnings))
end

"""
    read_fhr_file(path; kind = nothing) -> FHRHeader

The file-reading half of [`verify_file`](@ref), for callers that want the metadata and the
R11 warnings without contract validation.
"""
function read_fhr_file(path::AbstractString; kind::Union{Nothing, AbstractString} = nothing)
    k = kind === nothing ? kind_of(path) : String(kind)
    k === nothing && throw(ArgumentError("cannot tell the header kind from $(repr(path)); pass kind"))
    return read_fhr_file(read_file_bytes(path), k)
end

"""
    verify_file(path; kind = nothing, validate = true) -> VerifyResult

Check one file end to end: gzip/BGZF input is decompressed first (R1 hashes the
decompressed bytes), then header block and checksum line (R2, R5), checksum coverage and
value (R1-R4), encoding (R6, R7), placement (R10, G1), metadata rules (R8, R11, R12, R13),
then the contract the record selects for itself (V1-V6) with its `format` assertions, and
the R14 link-scheme warnings.

A rule V4 citation is reported under `not_checked`: the file was not checked against a
different schema, which is what V4 requires.
"""
function verify_file(path::AbstractString; kind::Union{Nothing, AbstractString} = nothing,
                     validate::Bool = true)
    k = kind === nothing ? kind_of(path) : String(kind)
    k === nothing && return VerifyResult(path, "?", false, nothing, nothing, nothing,
        ["cannot tell the header kind from the file name; pass kind"], String[], String[])
    errors, warnings, not_checked = String[], String[], String[]
    stated = computed = nothing
    metadata = nothing
    try
        data = read_file_bytes(path)
        r = header_checksum(data, k)
        stated, computed = r.stated, r.computed
        stated == computed || push!(errors,
            "the stated checksum does not match the bytes it covers (rule R3): stated $(stated), computed $(computed)")
        header = read_fhr_file(data, k)
        metadata = header.metadata
        append!(warnings, header.warnings)
        if validate
            version = get(metadata, "schemaVersion", nothing)
            findings = validate_record(metadata, get(metadata, "schema", nothing), version)
            if !isempty(findings) && occursin("unsupported schema version", first(findings))
                push!(not_checked, first(findings))
            else
                append!(errors, findings)
            end
            append!(warnings, link_scheme_warnings(metadata))
            if _is_number_one(version) && get(metadata, "schema", "") isa AbstractString &&
               occursin(r"/main/fhr\.json\z", String(get(metadata, "schema", "")))
                push!(warnings, v6_warning())
            end
        else
            push!(not_checked, "contract validation (validate = false)")
        end
    catch e
        if e isa HeaderError
            push!(errors, sprint(showerror, e))
        elseif e isa UnsupportedContract
            push!(not_checked, sprint(showerror, e))
        else
            push!(errors, string(typeof(e)) * ": " * string(e))
        end
    end
    return VerifyResult(path, k, isempty(errors), stated, computed, metadata, errors, warnings, not_checked)
end
