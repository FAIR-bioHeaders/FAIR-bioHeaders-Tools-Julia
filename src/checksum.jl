# The byte layer: FAIR-bioHeaders FORMAT.md rules R1-R5, R6, R7, R10 and the FHGFF3
# block end (docs/FHGFF3.md G1).
#
# Rules are cited from FAIR-bioHeaders-Specification release v0.6.0
# (docs/FORMAT.md, docs/FHGFF3.md). The digest is SHA-512/256 from the Julia standard
# library `SHA` module, encoded as standard padded base64 (R4); docs/CAPABILITY.md
# records the measurement that makes this byte-identical to the released Python toolkit.

const PREFIX = Dict("fasta" => ";~", "fhp-fasta" => ";~", "gfa" => "#~", "fhgff3" => "#~")

const YAML_ONLY_BREAKS = ('', ' ', ' ')

"R4: 43 canonical base64 characters and the padding `=`, 32 bytes with zero unused bits."
const CANONICAL_B64 = r"\A[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=\z"

"""
    scan_lines(data) -> Vector{Tuple{UnitRange{Int}, UnitRange{Int}}}

Split bytes into `(content, terminator)` ranges without normalizing anything. A line ends
at LF, at CRLF, or at a CR that is not followed by LF, and the terminator belongs to the
line (R1).
"""
function scan_lines(data::Vector{UInt8})
    lines = Tuple{UnitRange{Int}, UnitRange{Int}}[]
    i, n = 1, length(data)
    while i <= n
        j = i
        while j <= n && data[j] != 0x0a && data[j] != 0x0d
            j += 1
        end
        content = i:(j - 1)
        if j > n
            push!(lines, (content, n + 1:n))          # a final line with no terminator
            break
        elseif data[j] == 0x0a
            push!(lines, (content, j:j))
            i = j + 1
        elseif j + 1 <= n && data[j + 1] == 0x0a
            push!(lines, (content, j:j + 1))          # CRLF
            i = j + 2
        else
            push!(lines, (content, j:j))              # a lone CR
            i = j + 1
        end
    end
    return lines
end

@inline function _starts(data::Vector{UInt8}, content::UnitRange{Int}, text::AbstractString)
    p = codeunits(text)
    return length(content) >= length(p) &&
           view(data, first(content):(first(content) + length(p) - 1)) == p
end

"The byte index where the data section starts, or `nothing` when the file is all header."
function data_start_index(data::Vector{UInt8}, lines, kind::AbstractString)
    for (i, (content, _)) in enumerate(lines)
        i == 1 && kind == "fhgff3" && continue        # line 1 is the version directive (G1)
        isempty(content) && continue
        b = data[first(content)]
        if kind in ("fasta", "fhp-fasta")
            b == UInt8('>') && return i
        elseif kind in ("gfa", "fhgff3")
            if b != UInt8('#')
                return i
            elseif kind == "fhgff3" && occursin(r"\A##FASTA[ \t]*\z", String(view(data, content)))
                return i                        # the FHGFF3 block ends at ##FASTA (rule G1)
            end
            continue                            # `#` comments, not including a terminated block
        end
    end
    return nothing
end

"""
    header_block(data, lines, kind) -> (indices, late)

The indices of the lines that form the leading header block, and the indices of any FHR
line that appears at or after the first record or feature line. Such a line makes the file
invalid: it is neither ignored nor merged (R10), including one from a concatenated file.
"""
function header_block(data::Vector{UInt8}, lines, kind::AbstractString)
    prefix = PREFIX[kind]
    start = data_start_index(data, lines, kind)
    stop = start === nothing ? length(lines) + 1 : start
    p = codeunits(prefix)
    indices, late = Int[], Int[]
    for (i, (content, _)) in enumerate(lines)
        _starts(data, content, prefix) || continue
        push!(i < stop ? indices : late, i)
    end
    return indices, late
end

"""
    checksum_line(data, lines, indices, kind) -> index | nothing | missing

The index of the single root-level checksum line among the header `indices`: `nothing`
when there is none and `missing` when there is more than one (R2). Spaces may appear
before the key only to match the root indentation of the other header lines, so a nested
`checksum:` property stays covered by the digest.
"""
function checksum_line(data::Vector{UInt8}, lines, indices, kind::AbstractString)
    prefix = codeunits(PREFIX[kind])
    root_indent, found, matches = nothing, nothing, 0
    for i in indices
        content = lines[i][1]
        length(content) <= length(prefix) && continue
        meta = String(data[(first(content) + length(prefix)):last(content)])
        all(isspace, meta) && continue
        stripped = lstrip(c -> c == ' ' || c == '\t', meta)
        startswith(stripped, '#') && continue
        occursin(r"\A(?:%|---(?:[ \t]|\z)|\.\.\.(?:[ \t]|\z))", stripped) && continue
        indent = length(meta) - length(stripped)
        if root_indent === nothing || indent < root_indent
            root_indent, matches, found = indent, 0, nothing
        end
        if indent == root_indent && occursin(r"\Achecksum[ \t]*:", stripped)
            matches += 1
            found = i
        end
    end
    return matches == 1 ? found : (matches == 0 ? nothing : missing)
end

const _CHECKSUM_TAIL = " *checksum *: +(\"([^\"]*)\"|'([^']*)'|(\\S+)) *\\z"

"""
    checksum_value(text, kind) -> String | nothing

The value on a checksum line, or `nothing` when the line holds anything other than the
root indentation, the unquoted key `checksum`, a colon, one or more spaces, the 44-character
value plain or quoted, and optional trailing spaces (R5). A tab, a YAML comment, an explicit
tag, a block scalar indicator, or a value continued on the next line is not a checksum line.
"""
function checksum_value(text::AbstractString, kind::AbstractString)
    pattern = "\\A" * Regex(PREFIX[kind]).pattern * _CHECKSUM_TAIL
    m = match(Regex(pattern), text)
    m === nothing && return nothing
    return String(something(m.captures[2], m.captures[3], m.captures[4]))
end

"""
    header_checksum(data, kind) -> (stated, computed, index, header, late, lines)

`computed` is base64 SHA-512/256 over the exact bytes except the root checksum line and
its terminator (R1-R4); `stated` is the value the file carries. Throws `ArgumentError` when
the file does not hold exactly one checksum line, or when that line breaks R5 or R4.
"""
function header_checksum(data::Vector{UInt8}, kind::AbstractString)
    haskey(PREFIX, kind) || throw(ArgumentError(
        "unknown header kind $(repr(kind)); expected one of $(join(keys(PREFIX), ", "))"))
    lines = scan_lines(data)
    indices, late = header_block(data, lines, kind)
    idx = checksum_line(data, lines, indices, kind)
    idx === nothing && throw(ArgumentError("no root-level checksum line (rule R2)"))
    idx === missing && throw(ArgumentError("more than one root-level checksum line (rule R2)"))
    stated = checksum_value(String(data[lines[idx][1]]), kind)
    stated === nothing && throw(ArgumentError("the checksum line holds more than the value (rule R5)"))
    occursin(CANONICAL_B64, stated) ||
        throw(ArgumentError("the checksum value is not canonical padded base64 (rule R4)"))
    ctx = SHA2_512_256_CTX()
    for (i, (content, terminator)) in enumerate(lines)
        i == idx && continue                          # R3: the line and its terminator
        SHA.update!(ctx, data[content])
        SHA.update!(ctx, data[terminator])
    end
    return (stated = stated, computed = base64encode(SHA.digest!(ctx)), index = idx,
            header = indices, late = late, lines = lines)
end

header_checksum(path::AbstractString, kind::AbstractString) = header_checksum(read(path), kind)

"""
    check_header_encoding(data, lines, indices)

Rule R6: header lines are UTF-8 and hold no U+0085, U+2028 or U+2029, which YAML reads as
line breaks. Bytes outside the header lines are not decoded. Rule R7 is checked by
[`check_byte_order_mark`](@ref).
"""
function check_header_encoding(data::Vector{UInt8}, lines, indices)
    for i in indices
        bytes = data[lines[i][1]]
        # Decode strictly: an invalid sequence means the line is not UTF-8.
        s = try
            String(bytes)
        catch
            throw(HeaderError("R6", "an FHR header line is not valid UTF-8", i))
        end
        for c in s
            c in YAML_ONLY_BREAKS &&
                throw(HeaderError("R6", "an FHR header line contains U+0085, U+2028 or U+2029, " *
                                        "which YAML reads as a line break", i))
        end
    end
    return nothing
end

"The YAML text of the header block: each FHR line with its prefix and terminator removed."
function header_text(data::Vector{UInt8}, lines, indices, kind::AbstractString)
    prefix = codeunits(PREFIX[kind])
    out = String[]
    for i in indices
        content = lines[i][1]
        body = length(content) < length(prefix) ? UInt8[] : data[(first(content) + length(prefix)):last(content)]
        push!(out, String(body))
    end
    return join(out, "\n")
end

"Rule R7: a FASTA or GFA file must not begin with a UTF-8 byte order mark."
function check_byte_order_mark(data::Vector{UInt8}, kind::AbstractString)
    kind == "fhgff3" && return nothing        # GFF3 keeps the G1 shape check instead
    length(data) >= 3 && data[1] == 0xef && data[2] == 0xbb && data[3] == 0xbf &&
        throw(HeaderError("R7", "the file begins with a UTF-8 byte order mark", 1))
    return nothing
end

"Rule G1: line 1 of an FHGFF3 file is `##gff-version 3` or `##gff-version 3.MINOR.PATCH`."
function check_gff3_version(lines, data::Vector{UInt8})
    isempty(lines) && throw(HeaderError("G1", "the file is empty", 1))
    content = lines[1][1]
    text = isempty(content) ? "" : String(data[content])
    occursin(r"\A##gff-version 3(\.[0-9]+\.[0-9]+)?[ \t]*\z", text) ||
        throw(HeaderError("G1", "line 1 must be ##gff-version 3 or ##gff-version 3.MINOR.PATCH, found $(repr(text))", 1))
    return nothing
end
