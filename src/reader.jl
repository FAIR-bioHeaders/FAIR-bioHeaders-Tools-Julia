# The header metadata reader: the YAML subset FAIR-bioHeaders headers use, read the way
# FORMAT.md defines it (rules R8, R11, R12, R13) rather than delegated to a general YAML
# library. docs/CAPABILITY.md records the measurement behind this: YAML.jl 0.4.17 accepts
# duplicate keys, anchors, aliases, merge keys and explicit tags (invalid under R8 and
# R12), resolves plain scalars by a mix of YAML 1.1 and 1.2 rules, returns Date and
# DateTime for date-shaped plain scalars that R12 keeps as strings, throws a Julia
# ArgumentError on `0o17`, `0b101` and `2026-13-45`, and does not fold a single line break
# in a multi-line flow scalar, so it reads a wrapped `documentation:` value differently
# from every other family reader.

"""
    HeaderError(rule, message, line)

A header that breaks a parsing rule. `rule` names the FORMAT.md, FHP.md or FHGFF3.md rule.
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

# YAML 1.1 as PyYAML resolves it, plus the single-letter y/N booleans that rule R12 names.
const _11_NULL = r"\A(?:~|null|Null|NULL|)\z"
const _11_BOOL =
    r"\A(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF|y|Y|n|N)\z"
const _11_INT =
    r"\A(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z"
const _11_FLOAT =
    r"\A(?:[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+][0-9]+)?|[-+]?\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z"
const _11_TIMESTAMP =
    r"\A[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?)?)?\z"

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
    occursin(_11_TIMESTAMP, value) && return "str"
    occursin(_11_INT, value) && return "int"
    occursin(_11_FLOAT, value) && return "float"
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
        parsed = tryparse(Int, digits; base = base)
        parsed === nothing && throw(HeaderError("R12", "cannot read the plain integer $(repr(text))", line))
        return sign * parsed
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
            tryparse(Float64, replace(s, r"\A\+" => ""))
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

"Expand the escapes of a double-quoted YAML scalar, including the `\\x3E` and `\\x40` form
that rule R11 requires writers to use for `>` and `@` in FASTA headers."
function unescape_double(text::AbstractString, line::Int)
    chars = collect(String(text))
    out = IOBuffer()
    i = 1
    while i <= length(chars)
        c = chars[i]
        c != '\\' && (print(out, c); i += 1; continue)
        i += 1
        i > length(chars) && throw(HeaderError("R12", "a double-quoted scalar ends in a backslash", line))
        e = chars[i]
        i += 1
        if e in ('x', 'u', 'U')
            k = e == 'x' ? 2 : e == 'u' ? 4 : 8
            hex = ""
            for _ in 1:k
                i <= length(chars) || throw(HeaderError("R12", "a truncated \\\\$(e) escape", line))
                hex *= chars[i]; i += 1
            end
            code = tryparse(UInt32, hex; base = 16)
            code === nothing && throw(HeaderError("R12", "an invalid \\\\$(e) escape $(repr(hex))", line))
            print(out, Char(code))
        elseif e == 'n'
            print(out, '\n')
        elseif e == 't'
            print(out, '\t')
        elseif e == 'r'
            print(out, '\r')
        elseif e == 'b'
            print(out, '\b')
        elseif e == 'f'
            print(out, '\f')
        elseif e == 'v'
            print(out, '\v')
        elseif e == '0'
            print(out, '\0')
        elseif e == 'a'
            print(out, '\a')
        elseif e == 'e'
            print(out, '\e')
        elseif e == ' '
            print(out, ' ')
        elseif e == '"'
            print(out, '"')
        elseif e == '/'
            print(out, '/')
        elseif e == '\\'
            print(out, '\\')
        elseif e == '\n'
            continue                                    # an escaped break adds nothing
        else
            throw(HeaderError("R12", "unknown escape \\\\$(e) in a double-quoted scalar", line))
        end
    end
    return String(take!(out))
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

"A folded block scalar: single breaks become spaces, blank lines keep the count minus one."
function fold_block(lines::Vector{String})
    isempty(lines) && return ""
    fold_lines(filter(l -> !isempty(l), lines))    # only correct when there are no blanks
end

# --------------------------------------------------------------------------------------
# Block structure
# --------------------------------------------------------------------------------------

struct _Line
    indent::Int
    text::String       # after the indentation, without the terminator
    number::Int        # 1-based index into `_Reader.lines`
end

struct _Reader
    lines::Vector{_Line}
    warnings::Vector{String}
end

function _scan(text::AbstractString, first_line::Int)
    out = _Line[]
    for (i, raw) in enumerate(split(text, "\n"))
        stripped = lstrip(c -> c == ' ' || c == '\t', raw)
        indent = length(raw) - length(stripped)
        push!(out, _Line(indent, String(stripped), i))
    end
    return out
end

_is_blank(l::_Line) = isempty(l.text) || startswith(l.text, "#")
_is_entry(l::_Line) = startswith(l.text, "- ") || l.text == "-"

function _skip(r::_Reader, i::Int)
    while i <= length(r.lines) && _is_blank(r.lines[i])
        i += 1
    end
    return i
end

_peek(r::_Reader, i::Int) = (j = _skip(r, i); j <= length(r.lines) ? r.lines[j] : nothing)

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
    read_fhr_header(text; first_line = 1) -> FHRHeader

Parse the metadata block of a header: block mappings and sequences, plain, single-quoted,
double-quoted and block scalars, and the flow collections an extension value may hold.
Rejects duplicate keys, anchors, aliases and merge keys (R8), explicit tags and plain
scalars that YAML 1.1 and YAML 1.2 disagree on (R12), and non-finite numbers (R13).
Characters YAML treats as line breaks are rejected (R6).
"""
function read_fhr_header(text::AbstractString; first_line::Int = 1)
    for c in text
        c in YAML_ONLY_BREAKS && throw(HeaderError("R6",
            "an FHR header line contains U+0085, U+2028 or U+2029, which YAML reads as a line break",
            first_line))
    end
    r = _Reader(_scan(text, first_line), String[])
    i = _skip(r, 1)
    i > length(r.lines) && return FHRHeader(Dict{String, Any}(), r.warnings)
    node, i = _read_block(r, i, r.lines[i].indent)
    node isa AbstractDict || throw(HeaderError("R12", "the metadata block is not a mapping", first_line))
    j = _skip(r, i)
    j <= length(r.lines) && throw(HeaderError("R12", "unexpected content $(repr(r.lines[j].text))", r.lines[j].number))
    metadata = Dict{String, Any}()
    for (k, v) in node
        metadata[String(k)] = v
    end
    return FHRHeader(metadata, r.warnings)
end

"Read the collection that starts at index `i`, whose lines sit at column `indent`."
function _read_block(r::_Reader, i::Int, indent::Int)
    line = r.lines[i]
    _is_entry(line) && return _read_sequence(r, i, indent)
    (line.text == "?" || startswith(line.text, "? ")) &&
        throw(HeaderError("R8", "explicit mapping keys are not allowed in FHR metadata", line.number))
    return _read_mapping(r, i, indent)
end

function _read_sequence(r::_Reader, i::Int, indent::Int)
    out = Any[]
    while true
        j = _skip(r, i)
        (j > length(r.lines) || r.lines[j].indent != indent || !_is_entry(r.lines[j])) && break
        line = r.lines[j]
        rest = line.text == "-" ? "" : String(SubString(line.text, 3))
        # Rewrite the entry in place: its content becomes a line two columns deeper, so a
        # `- name: Adam Wright` entry parses as a mapping that starts on that line.
        r.lines[j] = _Line(indent + 2, String(strip(rest)), line.number)
        i = j
        nxt = r.lines[j]
        if isempty(nxt.text) || startswith(nxt.text, "#")
            below = _skip(r, j + 1)
            if below <= length(r.lines) && r.lines[below].indent > indent
                value, i = _read_block(r, below, r.lines[below].indent)
            else
                value, i = nothing, j + 1
            end
        elseif _split_key(nxt.text) !== nothing || startswith(nxt.text, "- ")
            value, i = _read_block(r, j, nxt.indent)
        else
            value, i = _read_scalar(r, j + 1, indent, nxt.text, line)
        end
        push!(out, value)
    end
    return out, i
end

function _read_mapping(r::_Reader, i::Int, indent::Int)
    out = Dict{String, Any}()
    while true
        j = _skip(r, i)
        if j > length(r.lines)
            break
        end
        line = r.lines[j]
        line.indent < indent && break
        line.indent > indent && throw(HeaderError("R12",
            "unexpected indentation before $(repr(line.text))", line.number))
        _is_entry(line) && break
        kv = _split_key(line.text)
        kv === nothing && throw(HeaderError("R12",
            "expected a mapping key, found $(repr(line.text))", line.number))
        key, rest = kv
        name = _key_name(key, line.number)
        haskey(out, name) && throw(HeaderError("R8", "duplicate mapping key $(repr(name))", line.number))
        out[name], i = _read_value(r, j + 1, line.indent, rest, line)
    end
    return out, i
end

"""
    _split_key(text) -> (key, rest) | nothing

Split `key: rest` at the first `:` that ends a key: outside quotes, followed by a space or
the end of the line. `nothing` means the text is not a mapping entry.
"""
function _split_key(text::AbstractString)
    s = String(text)
    (startswith(s, "&") || startswith(s, "*") || startswith(s, "!")) &&
        throw(HeaderError("R8", "YAML anchors, aliases and explicit tags are not allowed in FHR metadata", 0))
    chars = collect(s)
    q = nothing
    i = 1
    while i <= length(chars)
        c = chars[i]
        if q !== nothing
            if q == '"' && c == '\\'
                i += 2
                continue
            end
            if c == q
                q = nothing
            end
            i += 1
            continue
        end
        c in ('"', '\'') && (q = c; i += 1; continue)
        if c == ':' && (i == length(chars) || chars[i + 1] in (' ', '\t'))
            return (strip(join(chars[1:(i - 1)])), strip(join(chars[(i + 1):end])))
        end
        c == '#' && i > 1 && chars[i - 1] in (' ', '\t') && return nothing
        i += 1
    end
    return nothing
end

"`<<` is a merge key and is invalid whatever follows it (R8)."
function _key_name(key::AbstractString, line::Int)
    s = strip(key)
    startswith(s, "<<") && throw(HeaderError("R8", "YAML merge keys are not allowed in FHR metadata", line))
    startswith(s, "? ") && throw(HeaderError("R8", "explicit mapping keys are not allowed in FHR metadata", line))
    length(s) >= 2 && first(s) == '"' && last(s) == '"' && return unescape_double(s[2:end - 1], line)
    length(s) >= 2 && first(s) == '\'' && last(s) == '\'' && return replace(s[2:end - 1], "''" => "'")
    (startswith(s, "!") || startswith(s, "&") || startswith(s, "*")) &&
        throw(HeaderError("R8", "YAML anchors, aliases and explicit tags are not allowed in FHR metadata", line))
    return s
end

"Read the value part of `key: ...`."
function _read_value(r::_Reader, i::Int, indent::Int, rest::AbstractString, line::_Line)
    body = strip(rest)
    if isempty(body) || startswith(body, "#")
        j = _skip(r, i)
        if j <= length(r.lines) && r.lines[j].indent > indent
            return _read_block(r, j, r.lines[j].indent)
        elseif j <= length(r.lines) && r.lines[j].indent == indent && _is_entry(r.lines[j])
            # A block sequence may sit at the same column as its key.
            return _read_sequence(r, j, indent)
        end
        return nothing, i
    end
    return _read_scalar(r, i, indent, body, line)
end

"Read a scalar that begins on one line; a plain or quoted scalar may continue below it."
function _read_scalar(r::_Reader, i::Int, indent::Int, body::AbstractString, line::_Line)
    c = first(body)
    (c == '&' || c == '*') &&
        throw(HeaderError("R8", "YAML anchors and aliases are not allowed in FHR metadata", line.number))
    c == '!' && throw(HeaderError("R12", "explicit YAML tags are not allowed in FHR metadata", line.number))
    (c == '|' || c == '>') && return _read_block_scalar(r, i, indent, body, line)
    (c == '"' || c == '\'') && return _read_quoted(r, i, indent, body, line)
    (c == '[' || c == '{') && return _read_flow_scalar(r, i, body, line)
    parts = String[_strip_comment(body)]
    while true
        k, blank = _next_content(r, i)
        k === nothing && break
        l = r.lines[k]
        (l.indent > indent && _split_key(l.text) === nothing && !_is_entry(l)) || break
        push!(parts, blank > 0 ? repeat("", blank) : String(_strip_comment(l.text)))
        i = k + 1
    end
    return plain_value(fold_lines(parts), line.number), i
end

"The next non-blank line index and the number of blank lines before it."
function _next_content(r::_Reader, i::Int)
    blank = 0
    k = i
    while k <= length(r.lines) && isempty(r.lines[k].text)
        k += 1
        blank += 1
    end
    k > length(r.lines) && return (nothing, blank)
    startswith(r.lines[k].text, "#") && return (nothing, blank)
    return (k, blank)
end

function _read_flow_scalar(r::_Reader, i::Int, body::AbstractString, line::_Line)
    value, pos = _flow_value(body, 1, line.number)
    tail = strip(SubString(body, pos))
    _tail_ok(tail) || throw(HeaderError("R12", "unexpected text after a flow collection", line.number))
    return value, i
end

_tail_ok(tail::AbstractString) = (s = strip(tail); isempty(s) || startswith(s, "#"))

"`#` begins a comment only at the start of a line or after a space, and never in a quote."
function _strip_comment(text::AbstractString)
    chars = collect(String(text))
    q = nothing
    for i in eachindex(chars)
        c = chars[i]
        if q !== nothing
            q == '"' && c == '\\' && (i += 1)
            c == q && (q = nothing)
            continue
        end
        c in ('"', '\'') && (q = c; continue)
        c == '#' && (i == 1 || chars[i - 1] in (' ', '\t')) && return strip(join(chars[1:(i - 1)]))
    end
    return String(text)
end

"Read a single- or double-quoted scalar, continuing over the lines it spans."
function _read_quoted(r::_Reader, i::Int, indent::Int, body::AbstractString, line::_Line)
    q = first(body)
    parts, tail, i = _collect_quoted(r, i, indent, body, q, line)
    _tail_ok(tail) || throw(HeaderError("R12", "unexpected text $(repr(tail)) after a quoted scalar", line.number))
    if q == '\''
        return replace(fold_lines(parts), "''" => "'"), i
    end
    return unescape_double(fold_lines(parts), line.number), i
end

"""
    _collect_quoted(r, i, indent, body, q, line) -> (parts, tail, next_index)

Return the quoted scalar's text as physical line segments (so the caller can fold them),
the text that followed the closing quote, and the next unread line index. A quoted scalar
continues while its quote is open; the continuation lines are taken as they come, because
an indentation change inside a quoted scalar is content, not structure.
"""
function _collect_quoted(r::_Reader, i::Int, indent::Int, body::AbstractString, q::Char, line::_Line)
    parts = String[]
    text = String(body)
    while true
        closed, content, after = _scan_quote(text, q)
        if closed
            push!(parts, content)
            return (parts, after, i)
        end
        push!(parts, content)
        i > length(r.lines) && throw(HeaderError("R12", "an unterminated quoted scalar", line.number))
        text = String(r.lines[i].text)
        i += 1
    end
end

"Split `text` at the closing quote: `(closed, content, remainder)`."
function _scan_quote(text::AbstractString, q::Char)
    chars = collect(text)
    out = Char[]
    i = 2                                    # past the opening quote
    while i <= length(chars)
        c = chars[i]
        if q == '"' && c == '\\'
            push!(out, c)
            i + 1 <= length(chars) && push!(out, chars[i + 1])
            i += 2
            continue
        end
        if c == q
            if q == '\'' && i < length(chars) && chars[i + 1] == '\''
                push!(out, '\'')
                i += 2
                continue
            end
            return (true, String(out), String(join(chars[(i + 1):end])))
        end
        push!(out, c)
        i += 1
    end
    return (false, String(out), "")
end

function _read_block_scalar(r::_Reader, i::Int, indent::Int, header::AbstractString, line::_Line)
    style = first(header)
    chomp = 'c'
    explicit = 0
    for c in String(SubString(header, 2))
        c == '-' && (chomp = 's'; continue)
        c == '+' && (chomp = 'f'; continue)
        isdigit(c) && (explicit = parse(Int, c); continue)
        c == '#' && break
        throw(HeaderError("R12", "cannot read the block scalar header $(repr(header))", line.number))
    end
    collected = String[]
    block_indent = explicit > 0 ? indent + explicit : nothing
    while i <= length(r.lines)
        l = r.lines[i]
        if isempty(l.text)
            push!(collected, "")
            i += 1
            continue
        end
        keep = block_indent === nothing ? l.indent > indent : l.indent >= block_indent
        keep || break
        block_indent === nothing && (block_indent = l.indent)
        push!(collected, String(l.text))
        i += 1
    end
    trailing = false
    while !isempty(collected) && isempty(collected[end])
        pop!(collected)
        trailing = true
    end
    body = if style == '>'
        out = IOBuffer()
        blanks = 0
        print(out, isempty(collected) ? "" : collected[1])
        for l in collected[2:end]
            isempty(l) && (blanks += 1; continue)
            print(out, blanks > 0 ? "\n"^blanks : " ")
            blanks = 0
            print(out, l)
        end
        String(take!(out))
    else
        join(collected, "\n")
    end
    chomp == 's' || (body *= "\n")
    chomp == 'f' && trailing && (body *= "\n")
    return body, i
end

# --------------------------------------------------------------------------------------
# Flow collections: an extension value may hold any JSON value (R15)
# --------------------------------------------------------------------------------------

"Read one flow value from `text` at byte position `pos`; return `(value, next position)`."
function _flow_value(text::AbstractString, pos::Int, line::Int)
    pos = _flow_skip(text, pos)
    pos > ncodeunits(text) && throw(HeaderError("R12", "a flow collection ends early", line))
    c = text[pos]
    c == '[' && return _flow_seq(text, pos, line)
    c == '{' && return _flow_map(text, pos, line)
    (c == '"' || c == '\'') && return _flow_str(text, pos, line)
    return _flow_plain(text, pos, line)
end

function _flow_skip(text::AbstractString, pos::Int)
    while pos <= ncodeunits(text) && (text[pos] == ' ' || text[pos] == '\t')
        pos = nextind(text, pos)
    end
    return pos
end

function _flow_seq(text::AbstractString, pos::Int, line::Int)
    out = Any[]
    pos = nextind(text, pos)                       # past [
    while true
        pos = _flow_skip(text, pos)
        pos > ncodeunits(text) && throw(HeaderError("R12", "an unterminated flow sequence", line))
        text[pos] == ']' && return (out, nextind(text, pos))
        value, pos = _flow_value(text, pos, line)
        push!(out, value)
        pos = _flow_skip(text, pos)
        if pos <= ncodeunits(text) && text[pos] == ','
            pos = nextind(text, pos)
            continue
        end
        pos <= ncodeunits(text) && text[pos] == ']' && return (out, nextind(text, pos))
        throw(HeaderError("R12", "expected , or ] in a flow sequence", line))
    end
end

function _flow_map(text::AbstractString, pos::Int, line::Int)
    out = Dict{String, Any}()
    pos = nextind(text, pos)                       # past {
    while true
        pos = _flow_skip(text, pos)
        pos > ncodeunits(text) && throw(HeaderError("R12", "an unterminated flow mapping", line))
        text[pos] == '}' && return (out, nextind(text, pos))
        key, pos = _flow_value(text, pos, line)
        pos = _flow_skip(text, pos)
        (pos <= ncodeunits(text) && text[pos] == ':') ||
            throw(HeaderError("R12", "expected : in a flow mapping", line))
        value, pos = _flow_value(text, nextind(text, pos), line)
        name = string(key)
        haskey(out, name) && throw(HeaderError("R8", "duplicate mapping key $(repr(name))", line))
        out[name] = value
        pos = _flow_skip(text, pos)
        if pos <= ncodeunits(text) && text[pos] == ','
            pos = nextind(text, pos)
            continue
        end
        pos <= ncodeunits(text) && text[pos] == '}' && return (out, nextind(text, pos))
        throw(HeaderError("R12", "expected , or } in a flow mapping", line))
    end
end

function _flow_str(text::AbstractString, pos::Int, line::Int)
    q = text[pos]
    out = Char[]
    pos = nextind(text, pos)
    while pos <= ncodeunits(text)
        c = text[pos]
        if q == '"' && c == '\\'
            push!(out, c)
            np = nextind(text, pos)
            np <= ncodeunits(text) && push!(out, text[np])
            pos = nextind(text, np)
            continue
        end
        if c == q
            pos = nextind(text, pos)
            s = String(out)
            return (q == '"' ? unescape_double(s, line) : replace(s, "''" => "'"), pos)
        end
        push!(out, c)
        pos = nextind(text, pos)
    end
    throw(HeaderError("R12", "an unterminated quoted scalar in a flow collection", line))
end

function _flow_plain(text::AbstractString, pos::Int, line::Int)
    out = Char[]
    while pos <= ncodeunits(text) && !(text[pos] in (',', ']', '}'))
        push!(out, text[pos])
        pos = nextind(text, pos)
    end
    return (plain_value(strip(String(out)), line), pos)
end
