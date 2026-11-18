# The header metadata reader: FAIR-bioHeaders headers are YAML, read the way FORMAT.md
# defines it (rules R8, R11, R12, R13). The YAML itself is read by `src/yaml.jl`, a port of
# the PyYAML scanner and parser the reference toolkit uses, so a header reads the same way
# here as there (R12 asks that every YAML library agree). docs/CAPABILITY.md records why the
# Julia `YAML` package is not used: YAML.jl 0.4.17 accepts duplicate keys, anchors, aliases,
# merge keys and explicit tags (invalid under R8 and R12), resolves plain scalars by a mix of
# YAML 1.1 and 1.2 rules, returns Date and DateTime for date-shaped plain scalars that R12
# keeps as strings, throws a Julia ArgumentError on `0o17`, `0b101` and `2026-13-45`, and does
# not fold a single line break in a multi-line flow scalar.

"""
    HeaderError(rule, message, line)

A header that breaks a parsing rule. `rule` names the FORMAT.md, FHP.md or FHGFF3.md rule,
or `limits` for the input limits FORMAT.md allows readers to apply.
"""
struct HeaderError <: Exception
    rule::String
    message::String
    line::Int
end

Base.showerror(io::IO, e::HeaderError) = print(io, e.rule, ": line ", e.line, ": ", e.message)

# --------------------------------------------------------------------------------------
# Plain-scalar typing: YAML 1.2 core, with the YAML 1.1 comparison rule R12 requires
# --------------------------------------------------------------------------------------

const _CORE_NULL = r"\A(?:~|null|Null|NULL|)\z"
const _CORE_BOOL = r"\A(?:true|True|TRUE|false|False|FALSE)\z"
const _CORE_INT = r"\A(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)\z"
const _CORE_FLOAT =
    r"\A(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z"

# YAML 1.1 exactly as PyYAML's resolver reads it (yaml/resolver.py), plus the single-letter
# y/N booleans that rule R12 names. Note the second float form: `.5` is a YAML 1.1 float but
# `-.5` and `+.5` are not, so those two are strings in YAML 1.1 and floats in YAML 1.2 (R12).
const _11_NULL = r"\A(?:~|null|Null|NULL|)\z"
const _11_BOOL =
    r"\A(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF|y|Y|n|N)\z"
const _11_INT =
    r"\A(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z"
const _11_FLOAT =
    r"\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z"
const _11_TIMESTAMP =
    r"\A(?:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?)\z"
const _11_MERGE = r"\A<<\z"
const _11_VALUE = r"\A=\z"

"YAML 1.2 core tag of a plain scalar: `null`, `bool`, `int`, `float` or `str`."
function yaml12_tag(value::AbstractString)
    occursin(_CORE_NULL, value) && return "null"
    occursin(_CORE_BOOL, value) && return "bool"
    occursin(_CORE_INT, value) && return "int"
    occursin(_CORE_FLOAT, value) && return "float"
    return "str"
end

"YAML 1.1 tag of a plain scalar. Dates and times come back as `str`, which is how rule R12
keeps them: a plain scalar that looks like a date is a string, exactly as written."
function yaml11_tag(value::AbstractString)
    occursin(_11_NULL, value) && return "null"
    occursin(_11_BOOL, value) && return "bool"
    occursin(_11_FLOAT, value) && return "float"
    occursin(_11_INT, value) && return "int"
    occursin(_11_TIMESTAMP, value) && return "str"
    occursin(_11_MERGE, value) && return "merge"
    occursin(_11_VALUE, value) && return "value"     # YAML 1.1's `=`, which no loader constructs
    return "str"
end

"""
    portable_plain_tag(value) -> String | nothing

The YAML 1.2 core tag of a plain scalar, or `nothing` when YAML 1.1 and YAML 1.2 read it
as different values (R12) — including a leading-zero integer, which YAML 1.1 reads as octal.
"""
function portable_plain_tag(value::AbstractString)
    t12, t11 = yaml12_tag(value), yaml11_tag(value)
    t11 == t12 || return nothing
    if t12 == "int"
        digits = lstrip(c -> c == '+' || c == '-', value)
        length(digits) > 1 && digits[1] == '0' && digits[2] ∉ ('x', 'X') && return nothing
    end
    return t12
end

"Read a portable plain scalar as its YAML 1.2 core value (R12); reject non-finite numbers (R13)."
function plain_value(text::AbstractString, line::Int)
    tag = portable_plain_tag(text)
    tag === nothing && throw(HeaderError("R12",
        "the plain YAML value $(repr(text)) is read differently by YAML 1.1 and YAML 1.2 readers; quote it", line))
    tag == "null" && return nothing
    tag == "bool" && return occursin(r"\A(?:true|True|TRUE)\z", text)
    if tag == "int"
        s = replace(text, "_" => "")
        m = match(r"\A([-+]?)(?:0x([0-9a-fA-F]+)|0o([0-7]+)|([0-9]+))\z", s)
        m === nothing && throw(HeaderError("R12", "cannot read the plain integer $(repr(text))", line))
        sign = m.captures[1] == "-" ? -1 : 1
        digits = something(m.captures[2], m.captures[3], m.captures[4])
        base = m.captures[2] !== nothing ? 16 : m.captures[3] !== nothing ? 8 : 10
        # Like Python's int, an integer wider than Int64 is read exactly (as a BigInt).
        parsed = something(tryparse(Int, digits; base = base), tryparse(BigInt, digits; base = base), missing)
        parsed === missing && throw(HeaderError("R12", "cannot read the plain integer $(repr(text))", line))
        parsed = sign * parsed
        parsed isa BigInt && typemin(Int) <= parsed <= typemax(Int) && (parsed = Int(parsed))
        return parsed
    end
    if tag == "float"
        s = replace(text, "_" => "")
        f = if occursin(r"\A\.(?:inf|Inf|INF)\z", s)
            Inf
        elseif occursin(r"\A-\.(?:inf|Inf|INF)\z", s)
            -Inf
        elseif occursin(r"\A\.(?:nan|NaN|NAN)\z", s)
            NaN
        else
            t = replace(s, r"\A\+" => "")
            # tryparse gives `nothing` on overflow; Python's float gives inf, which R13 rejects.
            something(tryparse(Float64, t), Float64(parse(BigFloat, t)))
        end
        (f isa Float64 && isfinite(f)) || throw(HeaderError("R13",
            "the numeric metadata value $(repr(text)) is not a finite number", line))
        return f
    end
    return String(text)
end

# --------------------------------------------------------------------------------------
# Quoted scalars and folding
# --------------------------------------------------------------------------------------

"""
    unescape_double(text, line = 0)

Expand the escapes of a double-quoted YAML scalar body (without the quotes), as PyYAML does:
the `\\x3E` and `\\x40` form that rule R11 requires writers to use for `>` and `@` in FASTA
headers, `\\u` and `\\U`, the single-character escapes including `\\N`, `\\_`, `\\L` and
`\\P`, and an escaped line break, which joins the lines.
"""
function unescape_double(text::AbstractString, line::Int = 0)
    v = _load_yaml("\"" * String(text) * "\"")
    return v isa String ? v : throw(HeaderError("R12", "cannot read the double-quoted scalar", line))
end

"Fold continuation lines the way YAML does: one break becomes a space, n become n-1 breaks."
function fold_lines(parts::Vector{String})
    length(parts) == 1 && return only(parts)
    out = IOBuffer()
    print(out, parts[1])
    blanks = 0
    for p in parts[2:end]
        if isempty(p)
            blanks += 1
            continue
        end
        print(out, blanks > 0 ? "\n"^blanks : " ")
        blanks = 0
        print(out, p)
    end
    print(out, "\n"^blanks)
    return String(take!(out))
end

# --------------------------------------------------------------------------------------
# Headers
# --------------------------------------------------------------------------------------

"""
    FHRHeader

`metadata` is the parsed mapping with YAML 1.2 core types; `warnings` holds the non-fatal
findings (rules R11 and R14).
"""
struct FHRHeader
    metadata::Dict{String, Any}
    warnings::Vector{String}
end

metadata_of(h::FHRHeader) = h.metadata

"""
    read_fhr_header(text; first_line = 1, line_numbers = nothing) -> FHRHeader

Parse the metadata block of a header (the header lines without their prefix, joined by
`\\n`) as the reference toolkit does: PyYAML's YAML reading (`src/yaml.jl`) with the FHR
rules on top. Rejects duplicate keys, anchors, aliases and merge keys (R8), explicit tags and
plain scalars that YAML 1.1 and YAML 1.2 disagree on (R12), non-finite numbers (R13), keys
that are not strings, a metadata block that is not a mapping, and input beyond the limits
of FORMAT.md (20,000 YAML nodes, 64 levels of nesting). Characters YAML treats as line
breaks are rejected (R6). `line_numbers[k]` is the file line of the k-th header line, used
in error messages; without it lines are counted from `first_line`.
"""
function read_fhr_header(text::AbstractString; first_line::Int = 1,
                         line_numbers::Union{Nothing, AbstractVector{<:Integer}} = nothing)
    lines = line_numbers === nothing ? nothing : Vector{Int}(line_numbers)
    if lines === nothing && first_line != 1
        lines = collect(first_line:(first_line + count(==('\n'), text)))
    end
    for (k, l) in enumerate(split(text, '\n'))
        any(c -> c in YAML_ONLY_BREAKS, l) && throw(HeaderError("R6",
            "an FHR header line contains U+0085, U+2028 or U+2029, which YAML reads as a line break",
            _file_line(lines, k - 1)))
    end
    node = _load_yaml(text, lines)
    node isa AbstractDict || throw(HeaderError("R12",
        "the metadata block is not a YAML mapping (FHR metadata is an object with string keys)",
        _file_line(lines, 0)))
    return FHRHeader(node, String[])
end
