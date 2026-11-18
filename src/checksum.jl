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

# Python's bytes.strip() whitespace, less the line terminators a line never holds.
_is_blank_byte(b::UInt8) = b == 0x20 || b == 0x09 || b == 0x0b || b == 0x0c

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
                # A line of spaces and tabs is blank, as the toolkit reads it.
                all(_is_blank_byte, view(data, content)) || return i
            elseif kind == "fhgff3" && _starts(data, content, "##FASTA")
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

# --------------------------------------------------------------------------------------
# One streaming pass: header block, checksum and limits (R1-R5, R7, R10, G1)
# --------------------------------------------------------------------------------------
#
# A FASTA or GFA file can be many gigabytes, so the verifier reads it once, in chunks, and
# holds only the header lines (at most 1 MiB of them). Every other byte goes straight into
# the digest. The root checksum line is only known once the header block has ended (a
# later, shallower header line can change the root indentation), so the scan keeps two
# digests the way the reference toolkit does: one over every byte, and one copied just
# before the single candidate line and updated with everything after it.

"Readers may refuse a header block larger than 1 MiB or longer than 10,000 lines (FORMAT.md)."
const MAX_HEADER_BYTES = 2^20
const MAX_HEADER_LINES = 10_000

mutable struct HeaderScan
    kind::String
    prefix::Vector{UInt8}
    header::Vector{Tuple{Int, Vector{UInt8}, Vector{UInt8}}}   # (file line, content, terminator)
    late::Vector{Int}                 # file lines of FHR lines after the data section (R10)
    first_line::Vector{UInt8}         # FHGFF3: line 1, for the G1 check
    root_indent::Union{Nothing, Int}
    matches::Int
    candidate::Int                    # index into `header` of the root checksum line
    digest::Union{Nothing, SHA2_512_256_CTX}
    excluded::Union{Nothing, SHA2_512_256_CTX}
    computed::Union{Nothing, String}
    # line state
    in_block::Bool
    line::Int
    mode::Symbol                      # :start, :header, :pass, :blank, :line1
    buf::Vector{UInt8}                # the undecided start of a line, a header line or line 1
    term::Vector{UInt8}
    after_cr::Bool
    header_bytes::Int
    started::Bool
end

function HeaderScan(kind::AbstractString)
    haskey(PREFIX, kind) || throw(ArgumentError(
        "unknown header kind $(repr(kind)); expected one of $(join(keys(PREFIX), ", "))"))
    HeaderScan(String(kind), Vector{UInt8}(codeunits(PREFIX[kind])),
               Tuple{Int, Vector{UInt8}, Vector{UInt8}}[], Int[], UInt8[], nothing, 0, 0,
               SHA2_512_256_CTX(), nothing, nothing, true, 1, :start, UInt8[], UInt8[], false, 0, false)
end

@inline function _hash!(st::HeaderScan, bytes)
    st.digest === nothing || SHA.update!(st.digest, bytes)
    st.excluded === nothing || SHA.update!(st.excluded, bytes)
end

_bytes_start(b::AbstractVector{UInt8}, p) = length(b) >= length(p) && view(b, 1:length(p)) == p

"How many bytes of a line decide what it is."
function _decide_len(st::HeaderScan)
    n = length(st.prefix)
    st.kind == "fhgff3" && (n = max(n, 7))           # ##FASTA
    st.line == 1 && (n = max(n, 3))                  # a byte order mark
    return n
end

function _end_block!(st::HeaderScan)
    st.in_block || return
    st.in_block = false
    st.digest = nothing                              # only the excluded digest can be used now
    st.matches == 1 || (st.excluded = nothing)
end

"Decide the current line from the bytes in `st.buf` (all of them when `ended`)."
function _classify!(st::HeaderScan)
    b = st.buf
    if st.line == 1 && !st.started
        st.started = true
        st.kind != "fhgff3" && _bytes_start(b, UInt8[0xef, 0xbb, 0xbf]) &&
            throw(HeaderError("R7", "the file begins with a UTF-8 byte order mark", 1))
    end
    if !st.in_block
        if _bytes_start(b, st.prefix)
            length(st.late) < 16 && push!(st.late, st.line)
        end
        st.mode = :pass
    elseif st.kind == "fhgff3" && st.line == 1
        st.mode = :line1                             # the version directive (G1), never a header line
        return
    elseif _bytes_start(b, st.prefix)
        st.mode = :header
        return
    elseif st.kind in ("fasta", "fhp-fasta")
        !isempty(b) && b[1] == UInt8('>') && _end_block!(st)
        st.mode = :pass
    elseif st.kind == "fhgff3" && _bytes_start(b, codeunits("##FASTA"))
        _end_block!(st)                              # the block ends at ##FASTA (G1)
        st.mode = :pass
    elseif !isempty(b) && b[1] == UInt8('#')
        st.mode = :pass
    else
        st.mode = :blank                             # a record line unless it is all blanks
        _hash!(st, b)
        any(!_is_blank_byte, b) && _end_block!(st)
        empty!(st.buf)
        return
    end
    _hash!(st, b)
    empty!(st.buf)
end

function _content!(st::HeaderScan, bytes::AbstractVector{UInt8})
    isempty(bytes) && return
    if st.mode === :start
        need = _decide_len(st) - length(st.buf)
        if length(bytes) < need
            append!(st.buf, bytes)
            return
        end
        append!(st.buf, view(bytes, 1:need))
        _classify!(st)
        bytes = view(bytes, (need + 1):length(bytes))
        isempty(bytes) && return
    end
    if st.mode === :header
        st.header_bytes += length(bytes)
        st.header_bytes > MAX_HEADER_BYTES && throw(HeaderError("limits",
            "the FHR header lines exceed the $(MAX_HEADER_BYTES ÷ 2^20) MiB size limit", st.line))
        append!(st.buf, bytes)
    elseif st.mode === :line1
        length(st.buf) + length(bytes) > MAX_HEADER_BYTES && throw(HeaderError("G1",
            "line 1 is too long to be a ##gff-version line", 1))
        append!(st.buf, bytes)
    elseif st.mode === :blank
        _hash!(st, bytes)
        st.in_block && any(!_is_blank_byte, bytes) && _end_block!(st)
    else
        _hash!(st, bytes)
    end
end

function _end_line!(st::HeaderScan)
    st.mode === :start && _classify!(st)
    if st.mode === :header
        st.header_bytes += length(st.term)
        st.header_bytes > MAX_HEADER_BYTES && throw(HeaderError("limits",
            "the FHR header lines exceed the $(MAX_HEADER_BYTES ÷ 2^20) MiB size limit", st.line))
        length(st.header) >= MAX_HEADER_LINES && throw(HeaderError("limits",
            "the FHR header lines exceed the $(MAX_HEADER_LINES) line limit", st.line))
        _header_line!(st, copy(st.buf), copy(st.term))
    elseif st.mode === :line1
        st.first_line = copy(st.buf)
        _hash!(st, st.buf)
        _hash!(st, st.term)
    else
        _hash!(st, st.term)
    end
    empty!(st.buf)
    empty!(st.term)
    st.mode = :start
    st.line += 1
end

const _DIRECTIVE_LIKE = r"\A(?:%|---(?:[ \t]|\z)|\.\.\.(?:[ \t]|\z))"

function _header_line!(st::HeaderScan, content::Vector{UInt8}, term::Vector{UInt8})
    push!(st.header, (st.line, content, term))
    meta = view(content, (length(st.prefix) + 1):length(content))
    first_nonblank = findfirst(b -> b != 0x20 && b != 0x09, meta)
    if any(!_is_blank_byte, meta) && first_nonblank !== nothing && meta[first_nonblank] != UInt8('#') &&
       !occursin(_DIRECTIVE_LIKE, String(meta[first_nonblank:end]))
        indent = first_nonblank - 1
        if st.root_indent === nothing || indent < st.root_indent
            st.root_indent, st.matches, st.excluded = indent, 0, nothing
        end
        if indent == st.root_indent && occursin(r"\Achecksum[ \t]*:", String(meta[first_nonblank:end]))
            st.matches += 1
            st.candidate = length(st.header)
            st.excluded = st.matches == 1 && st.digest !== nothing ? copy(st.digest) : nothing
            st.digest === nothing || (SHA.update!(st.digest, content); SHA.update!(st.digest, term))
            return
        end
    end
    _hash!(st, content)
    _hash!(st, term)
end

"Feed bytes `chunk[1:n]` to the scan."
function _feed!(st::HeaderScan, chunk::AbstractVector{UInt8}, n::Int = length(chunk))
    i = 1
    while i <= n
        if st.after_cr
            st.after_cr = false
            if chunk[i] == 0x0a
                push!(st.term, 0x0a)
                i += 1
            end
            _end_line!(st)
            continue
        end
        j = i
        @inbounds while j <= n && chunk[j] != 0x0a && chunk[j] != 0x0d
            j += 1
        end
        j > i && _content!(st, view(chunk, i:(j - 1)))
        j > n && break
        push!(st.term, chunk[j])
        if chunk[j] == 0x0a
            _end_line!(st)
        else
            st.after_cr = true                       # CR: a following LF belongs to it
        end
        i = j + 1
    end
end

function _finish!(st::HeaderScan)
    if st.after_cr || st.mode !== :start || !isempty(st.buf)
        st.after_cr = false
        _end_line!(st)
    end
    _end_block!(st)
    st.computed = st.matches == 1 && st.excluded !== nothing ?
                  base64encode(SHA.digest!(st.excluded)) : nothing
    return st
end

"""
    scan_header(io, kind) -> HeaderScan

Read `io` once, in chunks, decompressing gzip/BGZF input (R1), and return its header
lines, the FHR lines that follow the data section (R10), and the SHA-512/256 digest of
every byte except the single root checksum line (R3), or `nothing` when there is not
exactly one. Throws `HeaderError` for a byte order mark (R7), a corrupt gzip stream (R1)
and a header block beyond the FORMAT.md limits (1 MiB, 10,000 lines). Memory stays
bounded by the header block, whatever the file size.
"""
function scan_header(io::IO, kind::AbstractString)
    st = HeaderScan(kind)
    foreach_chunk(io) do chunk, n
        _feed!(st, chunk, n)
    end
    return _finish!(st)
end

scan_header(data::AbstractVector{UInt8}, kind::AbstractString) = scan_header(IOBuffer(data), kind)

"The YAML text of a scan's header lines, and the file line of each."
function header_yaml(scan::HeaderScan)
    p = length(scan.prefix)
    text = join((String(c[(p + 1):end]) for (_, c, _) in scan.header), "\n")
    return text, Int[l for (l, _, _) in scan.header]
end

"""
    header_checksum(data, kind) -> (stated, computed, index, header, late, lines)

`computed` is base64 SHA-512/256 over the exact bytes except the root checksum line and
its terminator (R1-R4); `stated` is the value the file carries; `index` is the file line
of the checksum line and `header` the file lines of the header block. Throws
`ArgumentError` when the file does not hold exactly one checksum line, or when that line
breaks R5 or R4, and `HeaderError` for a byte order mark (R7) or a header block beyond the
FORMAT.md limits.
"""
function header_checksum(data::Vector{UInt8}, kind::AbstractString)
    scan = scan_header(data, kind)
    stated = stated_checksum(scan)
    return (stated = stated, computed = scan.computed, index = scan.header[scan.candidate][1],
            header = Int[l for (l, _, _) in scan.header], late = scan.late, lines = scan_lines(data))
end

"""
    stated_checksum(scan) -> String

The value on the scan's single root checksum line. Throws `ArgumentError` naming the
rule when there is no such line or more than one (R2), when the line holds anything but
the value (R5), or when the value is not canonical padded base64 (R4).
"""
function stated_checksum(scan::HeaderScan)
    scan.matches == 0 && throw(ArgumentError("no root-level checksum line (rule R2)"))
    scan.matches > 1 && throw(ArgumentError("more than one root-level checksum line (rule R2)"))
    content = scan.header[scan.candidate][2]
    stated = isvalid(String, content) ? checksum_value(String(copy(content)), scan.kind) : nothing   # String() would take the buffer
    # Anything but 44 base64 characters ending in `=` (a block scalar indicator, a value cut
    # short or continued on the next line) means the line holds something other than the
    # value (R5); the right shape with nonzero unused bits is a non-canonical value (R4).
    (stated === nothing || !occursin(r"\A[A-Za-z0-9+/]{43}=\z", stated)) &&
        throw(ArgumentError("the checksum line must hold the 44-character value and nothing else (rule R5)"))
    occursin(CANONICAL_B64, stated) ||
        throw(ArgumentError("the checksum value is not canonical padded base64 (rule R4)"))
    return stated
end

function header_checksum(path::AbstractString, kind::AbstractString)
    scan = open(io -> scan_header(io, kind), path)
    stated = stated_checksum(scan)
    return (stated = stated, computed = scan.computed, index = scan.header[scan.candidate][1],
            header = Int[l for (l, _, _) in scan.header], late = scan.late, lines = nothing)
end

"""
    check_header_encoding(data, lines, indices)

Rule R6: header lines are UTF-8 and hold no U+0085, U+2028 or U+2029, which YAML reads as
line breaks. Bytes outside the header lines are not decoded. Rule R7 is checked by
[`check_byte_order_mark`](@ref).
"""
function check_header_encoding(data::Vector{UInt8}, lines, indices)
    for i in indices
        bytes = data[lines[i][1]]
        # Decode strictly. `String(bytes)` never throws (it keeps invalid sequences as
        # they are), so the check has to ask: overlong forms and surrogates fail it too.
        isvalid(String, bytes) || throw(HeaderError("R6", "an FHR header line is not valid UTF-8", i))
        for c in String(bytes)
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
