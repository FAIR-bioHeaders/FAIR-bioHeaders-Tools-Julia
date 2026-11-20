# The YAML reader behind `read_fhr_header`.
#
# FORMAT.md R12 asks that every YAML library read a header the same way, so this reader
# follows the one the reference toolkit uses: the scanner and parser below are a direct
# port of PyYAML 6.0's pure-Python `yaml.scanner` and `yaml.parser` (MIT licence, see
# LICENSE section 3), with the same token and event rules, so a header PyYAML accepts is
# accepted here, a header PyYAML rejects is rejected here, and scalars fold, chomp and
# unescape the same way. The composer at the end applies the FHR rules the toolkit
# applies on top of PyYAML's SafeLoader: no anchors, aliases, tags or merge keys (R8,
# R12), plain scalars typed by the YAML 1.2 core schema and rejected where YAML 1.1 reads
# them differently (R12), finite numbers only (R13), string keys only, no duplicate keys
# (R8), and the size limits of FORMAT.md (at most 20,000 nodes nested at most 64 deep).
#
# Nothing here recurses on the input except the composer, which stops at depth 64, so
# hostile nesting ends in a HeaderError, never a StackOverflowError.

const MAX_YAML_NODES = 20_000
const MAX_YAML_DEPTH = 64

const _Z = "\0 \t\r\n\u85  "           # end of a token: NUL, blank or break
const _ZNOTAB = "\0 \r\n\u85  "        # the same without tab
const _BRK = "\r\n\u85  "
const _BRK0 = "\0\r\n\u85  "

struct _YTok
    kind::Symbol
    value::String
    handle::Union{Nothing, String}      # tags: the handle; directives: unused
    plain::Bool
    style::Char                         # scalars: '\0' plain, '\'', '"', '|', '>'
    line::Int                           # 0-based line in the YAML text
    major::Int                          # %YAML directive version
    minor::Int
    tagpairs::Union{Nothing, Tuple{String, String}}   # %TAG handle and prefix
end

_ytok(kind::Symbol, line::Int; value = "", handle = nothing, plain = false, style = '\0',
      major = 0, minor = 0, tagpairs = nothing) =
    _YTok(kind, value, handle, plain, style, line, major, minor, tagpairs)

mutable struct _SimpleKey
    token_number::Int
    required::Bool
    index::Int
    line::Int
    column::Int
end

mutable struct _YScanner
    buf::Vector{Char}
    ptr::Int
    index::Int
    line::Int
    column::Int
    done::Bool
    flow_level::Int
    tokens::Vector{_YTok}
    tokens_taken::Int
    indent::Int
    indents::Vector{Int}
    allow_simple_key::Bool
    possible::Dict{Int, _SimpleKey}
    line_numbers::Union{Nothing, Vector{Int}}
end

"The file line of 0-based YAML line `l`, when the caller supplied the mapping."
function _file_line(line_numbers, l::Int)
    line_numbers === nothing && return l + 1
    return 1 <= l + 1 <= length(line_numbers) ? line_numbers[l + 1] :
           (isempty(line_numbers) ? l + 1 : last(line_numbers))
end

_yerr(s::_YScanner, msg::AbstractString; rule = "R12", line = s.line) =
    throw(HeaderError(rule, msg, _file_line(s.line_numbers, line)))

# PyYAML's Reader rejects these code points before scanning.
_printable(c::Char) = c == '\t' || c == '\n' || c == '\r' || ('\x20' <= c <= '\x7e') ||
    c == '\u85' || ('\ua0' <= c <= '퟿') || ('' <= c <= '�') ||
    ('\U10000' <= c <= '\U10ffff')

function _YScanner(text::AbstractString, line_numbers)
    buf = Char[]
    sizehint!(buf, ncodeunits(text) + 1)
    line = 0
    for c in text
        if !isvalid(c)
            throw(HeaderError("R6", "an FHR header line is not valid UTF-8", _file_line(line_numbers, line)))
        end
        _printable(c) || throw(HeaderError("R12",
            "the header holds the character $(repr(c)), which YAML does not allow", _file_line(line_numbers, line)))
        c == '\n' && (line += 1)
        push!(buf, c)
    end
    push!(buf, '\0')
    s = _YScanner(buf, 1, 0, 0, 0, false, 0, _YTok[], 0, -1, Int[], true,
                  Dict{Int, _SimpleKey}(), line_numbers)
    push!(s.tokens, _ytok(:stream_start, 0))
    return s
end

@inline _pk(s::_YScanner, i::Int = 0) = (j = s.ptr + i; j <= length(s.buf) ? s.buf[j] : '\0')
_prefix(s::_YScanner, n::Int) = String(s.buf[s.ptr:min(s.ptr + n - 1, length(s.buf))])

function _fwd!(s::_YScanner, n::Int = 1)
    for _ in 1:n
        ch = s.buf[s.ptr]
        s.ptr += 1
        s.index += 1
        if ch == '\n' || ch == '\u85' || ch == ' ' || ch == ' ' ||
           (ch == '\r' && _pk(s) != '\n')
            s.line += 1
            s.column = 0
        elseif ch != '﻿'
            s.column += 1
        end
    end
end

# --- token queue -----------------------------------------------------------------------

function _check_token(s::_YScanner, kinds::Symbol...)
    while _need_more(s)
        _fetch_more!(s)
    end
    isempty(s.tokens) && return false
    isempty(kinds) && return true
    return s.tokens[1].kind in kinds
end

function _peek_token(s::_YScanner)
    while _need_more(s)
        _fetch_more!(s)
    end
    return isempty(s.tokens) ? nothing : s.tokens[1]
end

function _get_token(s::_YScanner)
    while _need_more(s)
        _fetch_more!(s)
    end
    isempty(s.tokens) && return nothing
    s.tokens_taken += 1
    return popfirst!(s.tokens)
end

function _need_more(s::_YScanner)
    s.done && return false
    isempty(s.tokens) && return true
    _stale_keys!(s)
    return _next_possible_key(s) == s.tokens_taken
end

function _next_possible_key(s::_YScanner)
    m = nothing
    for k in values(s.possible)
        (m === nothing || k.token_number < m) && (m = k.token_number)
    end
    return m
end

function _stale_keys!(s::_YScanner)
    for level in collect(keys(s.possible))
        key = s.possible[level]
        if key.line != s.line || s.index - key.index > 1024
            key.required && _yerr(s, "could not find the expected ':' of a simple key"; line = key.line)
            delete!(s.possible, level)
        end
    end
end

function _save_key!(s::_YScanner)
    required = s.flow_level == 0 && s.indent == s.column
    if s.allow_simple_key
        _remove_key!(s)
        s.possible[s.flow_level] = _SimpleKey(s.tokens_taken + length(s.tokens), required,
                                              s.index, s.line, s.column)
    end
end

function _remove_key!(s::_YScanner)
    if haskey(s.possible, s.flow_level)
        key = s.possible[s.flow_level]
        key.required && _yerr(s, "could not find the expected ':' of a simple key"; line = key.line)
        delete!(s.possible, s.flow_level)
    end
end

function _unwind!(s::_YScanner, column::Int)
    s.flow_level > 0 && return
    while s.indent > column
        s.indent = pop!(s.indents)
        push!(s.tokens, _ytok(:block_end, s.line))
    end
end

function _add_indent!(s::_YScanner, column::Int)
    if s.indent < column
        push!(s.indents, s.indent)
        s.indent = column
        return true
    end
    return false
end

# --- fetchers ---------------------------------------------------------------------------

function _fetch_more!(s::_YScanner)
    _scan_to_next_token!(s)
    _stale_keys!(s)
    _unwind!(s, s.column)
    ch = _pk(s)
    ch == '\0' && return _fetch_stream_end!(s)
    ch == '%' && s.column == 0 && return _fetch_directive!(s)
    ch == '-' && _check_doc(s, "---") && return _fetch_doc!(s, :document_start)
    ch == '.' && _check_doc(s, "...") && return _fetch_doc!(s, :document_end)
    ch == '[' && return _fetch_flow_start!(s, :flow_sequence_start)
    ch == '{' && return _fetch_flow_start!(s, :flow_mapping_start)
    ch == ']' && return _fetch_flow_end!(s, :flow_sequence_end)
    ch == '}' && return _fetch_flow_end!(s, :flow_mapping_end)
    ch == ',' && return _fetch_flow_entry!(s)
    ch == '-' && _pk(s, 1) in _Z && return _fetch_block_entry!(s)
    ch == '?' && (s.flow_level > 0 || _pk(s, 1) in _Z) && return _fetch_key!(s)
    ch == ':' && (s.flow_level > 0 || _pk(s, 1) in _Z) && return _fetch_value!(s)
    ch == '*' && return _fetch_anchor!(s, :alias)
    ch == '&' && return _fetch_anchor!(s, :anchor)
    ch == '!' && return _fetch_tag!(s)
    ch == '|' && s.flow_level == 0 && return _fetch_block_scalar!(s, '|')
    ch == '>' && s.flow_level == 0 && return _fetch_block_scalar!(s, '>')
    ch == '\'' && return _fetch_flow_scalar!(s, '\'')
    ch == '"' && return _fetch_flow_scalar!(s, '"')
    _check_plain(s) && return _fetch_plain!(s)
    _yerr(s, "found the character $(repr(ch)), which cannot start any YAML token")
end

_check_doc(s::_YScanner, marker::String) =
    s.column == 0 && _prefix(s, 3) == marker && _pk(s, 3) in _Z

function _check_plain(s::_YScanner)
    ch = _pk(s)
    return !(ch in "\0 \t\r\n\u85  -?:,[]{}#&*!|>'\"%@`") ||
           (!(_pk(s, 1) in _Z) && (ch == '-' || (s.flow_level == 0 && ch in "?:")))
end

function _fetch_stream_end!(s::_YScanner)
    _unwind!(s, -1)
    _remove_key!(s)
    s.allow_simple_key = false
    empty!(s.possible)
    push!(s.tokens, _ytok(:stream_end, s.line))
    s.done = true
end

function _fetch_directive!(s::_YScanner)
    _unwind!(s, -1)
    _remove_key!(s)
    s.allow_simple_key = false
    push!(s.tokens, _scan_directive!(s))
end

function _fetch_doc!(s::_YScanner, kind::Symbol)
    _unwind!(s, -1)
    _remove_key!(s)
    s.allow_simple_key = false
    line = s.line
    _fwd!(s, 3)
    push!(s.tokens, _ytok(kind, line))
end

function _fetch_flow_start!(s::_YScanner, kind::Symbol)
    _save_key!(s)
    s.flow_level += 1
    s.allow_simple_key = true
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(kind, line))
end

function _fetch_flow_end!(s::_YScanner, kind::Symbol)
    _remove_key!(s)
    s.flow_level -= 1
    s.allow_simple_key = false
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(kind, line))
end

function _fetch_flow_entry!(s::_YScanner)
    s.allow_simple_key = true
    _remove_key!(s)
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(:flow_entry, line))
end

function _fetch_block_entry!(s::_YScanner)
    if s.flow_level == 0
        s.allow_simple_key || _yerr(s, "a block sequence entry is not allowed here")
        _add_indent!(s, s.column) && push!(s.tokens, _ytok(:block_sequence_start, s.line))
    end
    s.allow_simple_key = true
    _remove_key!(s)
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(:block_entry, line))
end

function _fetch_key!(s::_YScanner)
    if s.flow_level == 0
        s.allow_simple_key || _yerr(s, "a mapping key is not allowed here")
        _add_indent!(s, s.column) && push!(s.tokens, _ytok(:block_mapping_start, s.line))
    end
    s.allow_simple_key = s.flow_level == 0
    _remove_key!(s)
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(:key, line))
end

function _fetch_value!(s::_YScanner)
    if haskey(s.possible, s.flow_level)
        key = pop!(s.possible, s.flow_level)
        at = key.token_number - s.tokens_taken + 1
        insert!(s.tokens, at, _ytok(:key, key.line))
        if s.flow_level == 0 && _add_indent!(s, key.column)
            insert!(s.tokens, at, _ytok(:block_mapping_start, key.line))
        end
        s.allow_simple_key = false
    else
        if s.flow_level == 0
            s.allow_simple_key || _yerr(s, "a mapping value is not allowed here")
            _add_indent!(s, s.column) && push!(s.tokens, _ytok(:block_mapping_start, s.line))
        end
        s.allow_simple_key = s.flow_level == 0
        _remove_key!(s)
    end
    line = s.line
    _fwd!(s)
    push!(s.tokens, _ytok(:value, line))
end

function _fetch_anchor!(s::_YScanner, kind::Symbol)
    _save_key!(s)
    s.allow_simple_key = false
    push!(s.tokens, _scan_anchor!(s, kind))
end

function _fetch_tag!(s::_YScanner)
    _save_key!(s)
    s.allow_simple_key = false
    push!(s.tokens, _scan_tag!(s))
end

function _fetch_block_scalar!(s::_YScanner, style::Char)
    s.allow_simple_key = true
    _remove_key!(s)
    push!(s.tokens, _scan_block_scalar!(s, style))
end

function _fetch_flow_scalar!(s::_YScanner, style::Char)
    _save_key!(s)
    s.allow_simple_key = false
    push!(s.tokens, _scan_flow_scalar!(s, style))
end

function _fetch_plain!(s::_YScanner)
    _save_key!(s)
    s.allow_simple_key = false
    push!(s.tokens, _scan_plain!(s))
end

# --- scanners ---------------------------------------------------------------------------

function _scan_to_next_token!(s::_YScanner)
    s.index == 0 && _pk(s) == '﻿' && _fwd!(s)
    while true
        while _pk(s) == ' '
            _fwd!(s)
        end
        if _pk(s) == '#'
            while !(_pk(s) in _BRK0)
                _fwd!(s)
            end
        end
        if !isempty(_scan_line_break!(s))
            s.flow_level == 0 && (s.allow_simple_key = true)
        else
            break
        end
    end
end

function _scan_line_break!(s::_YScanner)
    ch = _pk(s)
    if ch in "\r\n\u85"
        _prefix(s, 2) == "\r\n" ? _fwd!(s, 2) : _fwd!(s)
        return "\n"
    elseif ch in "  "
        _fwd!(s)
        return string(ch)
    end
    return ""
end

_is_word(ch::Char) = ('0' <= ch <= '9') || ('A' <= ch <= 'Z') || ('a' <= ch <= 'z') || ch == '-' || ch == '_'

function _scan_directive!(s::_YScanner)
    line = s.line
    _fwd!(s)
    n = 0
    while _is_word(_pk(s, n))
        n += 1
    end
    n == 0 && _yerr(s, "a directive needs a name")
    name = _prefix(s, n)
    _fwd!(s, n)
    _pk(s) in _ZNOTAB || _yerr(s, "unexpected $(repr(_pk(s))) after the directive name")
    tok = if name == "YAML"
        while _pk(s) == ' '
            _fwd!(s)
        end
        major = _scan_directive_number!(s)
        _pk(s) == '.' || _yerr(s, "expected a digit or '.' in the %YAML directive")
        _fwd!(s)
        minor = _scan_directive_number!(s)
        _pk(s) in _ZNOTAB || _yerr(s, "expected a digit or ' ' in the %YAML directive")
        _ytok(:directive, line; value = name, major = major, minor = minor)
    elseif name == "TAG"
        while _pk(s) == ' '
            _fwd!(s)
        end
        handle = _scan_tag_handle!(s)
        _pk(s) == ' ' || _yerr(s, "expected ' ' in the %TAG directive")
        while _pk(s) == ' '
            _fwd!(s)
        end
        prefix = _scan_tag_uri!(s)
        _pk(s) in _ZNOTAB || _yerr(s, "expected ' ' in the %TAG directive")
        _ytok(:directive, line; value = name, tagpairs = (handle, prefix))
    else
        while !(_pk(s) in _BRK0)
            _fwd!(s)
        end
        _ytok(:directive, line; value = name)
    end
    while _pk(s) == ' '
        _fwd!(s)
    end
    if _pk(s) == '#'
        while !(_pk(s) in _BRK0)
            _fwd!(s)
        end
    end
    _pk(s) in _BRK0 || _yerr(s, "expected a comment or a line break after the directive")
    _scan_line_break!(s)
    return tok
end

function _scan_directive_number!(s::_YScanner)
    isdigit(_pk(s)) || _yerr(s, "expected a digit in the %YAML directive")
    n = 0
    while '0' <= _pk(s, n) <= '9'
        n += 1
    end
    v = parse(BigInt, _prefix(s, n))
    _fwd!(s, n)
    return v > typemax(Int) ? typemax(Int) : Int(v)
end

function _scan_anchor!(s::_YScanner, kind::Symbol)
    line = s.line
    _fwd!(s)
    n = 0
    while _is_word(_pk(s, n))
        n += 1
    end
    n == 0 && _yerr(s, "an anchor or alias needs a name"; rule = "R8")
    value = _prefix(s, n)
    _fwd!(s, n)
    _pk(s) in "\0 \t\r\n\u85  ?:,]}%@`" ||
        _yerr(s, "unexpected $(repr(_pk(s))) after an anchor or alias"; rule = "R8")
    return _ytok(kind, line; value = value)
end

function _scan_tag!(s::_YScanner)
    line = s.line
    ch = _pk(s, 1)
    if ch == '<'
        handle = nothing
        _fwd!(s, 2)
        suffix = _scan_tag_uri!(s)
        _pk(s) == '>' || _yerr(s, "expected '>' to close a verbatim tag")
        _fwd!(s)
    elseif ch in _Z
        handle = nothing
        suffix = "!"
        _fwd!(s)
    else
        n = 1
        use_handle = false
        while !(ch in _ZNOTAB)
            if ch == '!'
                use_handle = true
                break
            end
            n += 1
            ch = _pk(s, n)
        end
        if use_handle
            handle = _scan_tag_handle!(s)
        else
            handle = "!"
            _fwd!(s)
        end
        suffix = _scan_tag_uri!(s)
    end
    _pk(s) in _ZNOTAB || _yerr(s, "expected ' ' after a tag")
    return _ytok(:tag, line; value = suffix, handle = handle)
end

function _scan_tag_handle!(s::_YScanner)
    _pk(s) == '!' || _yerr(s, "expected '!' to start a tag handle")
    n = 1
    ch = _pk(s, n)
    if ch != ' '
        while _is_word(ch)
            n += 1
            ch = _pk(s, n)
        end
        if ch != '!'
            _fwd!(s, n)
            _yerr(s, "expected '!' to end a tag handle")
        end
        n += 1
    end
    value = _prefix(s, n)
    _fwd!(s, n)
    return value
end

function _scan_tag_uri!(s::_YScanner)
    out = IOBuffer()
    n = 0
    ch = _pk(s, n)
    while _is_word(ch) || ch in ";/?:@&=+\$,.!~*'()[]%"
        if ch == '%'
            print(out, _prefix(s, n))
            _fwd!(s, n)
            n = 0
            print(out, _scan_uri_escapes!(s))
        else
            n += 1
        end
        ch = _pk(s, n)
    end
    if n > 0
        print(out, _prefix(s, n))
        _fwd!(s, n)
    end
    value = String(take!(out))
    isempty(value) && _yerr(s, "expected a tag URI")
    return value
end

function _scan_uri_escapes!(s::_YScanner)
    codes = UInt8[]
    while _pk(s) == '%'
        _fwd!(s)
        for k in 0:1
            isxdigit(_pk(s, k)) || _yerr(s, "expected a URI escape of 2 hexadecimal digits")
        end
        push!(codes, parse(UInt8, _prefix(s, 2); base = 16))
        _fwd!(s, 2)
    end
    isvalid(String, codes) || _yerr(s, "a URI escape is not valid UTF-8")
    return String(codes)
end

function _scan_block_scalar!(s::_YScanner, style::Char)
    folded = style == '>'
    chunks = IOBuffer()
    line = s.line
    _fwd!(s)
    # indicators
    chomping = 0                      # 0 clip, 1 keep (+), -1 strip (-)
    increment = 0
    ch = _pk(s)
    if ch in "+-"
        chomping = ch == '+' ? 1 : -1
        _fwd!(s)
        ch = _pk(s)
        if isdigit(ch)
            increment = ch - '0'
            increment == 0 && _yerr(s, "a block scalar indentation indicator must be 1-9")
            _fwd!(s)
        end
    elseif isdigit(ch)
        increment = ch - '0'
        increment == 0 && _yerr(s, "a block scalar indentation indicator must be 1-9")
        _fwd!(s)
        ch = _pk(s)
        if ch in "+-"
            chomping = ch == '+' ? 1 : -1
            _fwd!(s)
        end
    end
    _pk(s) in _ZNOTAB || _yerr(s, "expected chomping or indentation indicators after $(style)")
    # the rest of the indicator line
    while _pk(s) == ' '
        _fwd!(s)
    end
    if _pk(s) == '#'
        while !(_pk(s) in _BRK0)
            _fwd!(s)
        end
    end
    _pk(s) in _BRK0 || _yerr(s, "expected a comment or a line break after a block scalar indicator")
    _scan_line_break!(s)

    min_indent = max(s.indent + 1, 1)
    if increment == 0
        breaks = String[]
        max_indent = 0
        while _pk(s) in " \r\n\u85  "
            if _pk(s) != ' '
                push!(breaks, _scan_line_break!(s))
            else
                _fwd!(s)
                s.column > max_indent && (max_indent = s.column)
            end
        end
        indent = max(min_indent, max_indent)
    else
        indent = min_indent + increment - 1
        breaks = _scan_block_breaks!(s, indent)
    end
    line_break = ""
    while s.column == indent && _pk(s) != '\0'
        foreach(b -> print(chunks, b), breaks)
        leading_non_space = !(_pk(s) in " \t")
        n = 0
        while !(_pk(s, n) in _BRK0)
            n += 1
        end
        print(chunks, _prefix(s, n))
        _fwd!(s, n)
        line_break = _scan_line_break!(s)
        breaks = _scan_block_breaks!(s, indent)
        if s.column == indent && _pk(s) != '\0'
            if folded && line_break == "\n" && leading_non_space && !(_pk(s) in " \t")
                isempty(breaks) && print(chunks, ' ')
            else
                print(chunks, line_break)
            end
        else
            break
        end
    end
    chomping != -1 && print(chunks, line_break)
    chomping == 1 && foreach(b -> print(chunks, b), breaks)
    return _ytok(:scalar, line; value = String(take!(chunks)), plain = false, style = style)
end

function _scan_block_breaks!(s::_YScanner, indent::Int)
    chunks = String[]
    while s.column < indent && _pk(s) == ' '
        _fwd!(s)
    end
    while _pk(s) in _BRK
        push!(chunks, _scan_line_break!(s))
        while s.column < indent && _pk(s) == ' '
            _fwd!(s)
        end
    end
    return chunks
end

const _ESCAPES = Dict{Char, Char}(
    '0' => '\0', 'a' => '\a', 'b' => '\b', 't' => '\t', '\t' => '\t', 'n' => '\n',
    'v' => '\v', 'f' => '\f', 'r' => '\r', 'e' => '\e', ' ' => ' ', '"' => '"',
    '\\' => '\\', '/' => '/', 'N' => '\u85', '_' => '\ua0', 'L' => ' ',
    'P' => ' ')
const _ESCAPE_CODES = Dict{Char, Int}('x' => 2, 'u' => 4, 'U' => 8)

function _scan_flow_scalar!(s::_YScanner, style::Char)
    double = style == '"'
    chunks = IOBuffer()
    line = s.line
    quote_char = _pk(s)
    _fwd!(s)
    _scan_flow_non_spaces!(s, chunks, double)
    while _pk(s) != quote_char
        _scan_flow_spaces!(s, chunks)
        _scan_flow_non_spaces!(s, chunks, double)
    end
    _fwd!(s)
    return _ytok(:scalar, line; value = String(take!(chunks)), plain = false, style = style)
end

function _scan_flow_non_spaces!(s::_YScanner, chunks::IOBuffer, double::Bool)
    while true
        n = 0
        while !(_pk(s, n) in "'\"\\\0 \t\r\n\u85  ")
            n += 1
        end
        if n > 0
            print(chunks, _prefix(s, n))
            _fwd!(s, n)
        end
        ch = _pk(s)
        if !double && ch == '\'' && _pk(s, 1) == '\''
            print(chunks, '\'')
            _fwd!(s, 2)
        elseif (double && ch == '\'') || (!double && ch in "\"\\")
            print(chunks, ch)
            _fwd!(s)
        elseif double && ch == '\\'
            _fwd!(s)
            ch = _pk(s)
            if haskey(_ESCAPES, ch)
                print(chunks, _ESCAPES[ch])
                _fwd!(s)
            elseif haskey(_ESCAPE_CODES, ch)
                len = _ESCAPE_CODES[ch]
                _fwd!(s)
                for k in 0:(len - 1)
                    isxdigit(_pk(s, k)) || _yerr(s,
                        "expected an escape of $(len) hexadecimal digits in a double-quoted scalar")
                end
                code = parse(UInt32, _prefix(s, len); base = 16)
                code > 0x10ffff && _yerr(s, "the escape \\$(ch)$(_prefix(s, len)) is not a Unicode code point")
                print(chunks, Char(code))
                _fwd!(s, len)
            elseif ch in _BRK
                _scan_line_break!(s)
                _scan_flow_breaks!(s, chunks)
            else
                _yerr(s, "unknown escape \\$(ch) in a double-quoted scalar")
            end
        else
            return
        end
    end
end

function _scan_flow_spaces!(s::_YScanner, chunks::IOBuffer)
    n = 0
    while _pk(s, n) in " \t"
        n += 1
    end
    whitespaces = _prefix(s, n)
    _fwd!(s, n)
    ch = _pk(s)
    if ch == '\0'
        _yerr(s, "a quoted scalar is not closed")
    elseif ch in _BRK
        line_break = _scan_line_break!(s)
        breaks = IOBuffer()
        _scan_flow_breaks!(s, breaks)
        b = String(take!(breaks))
        if line_break != "\n"
            print(chunks, line_break)
        elseif isempty(b)
            print(chunks, ' ')
        end
        print(chunks, b)
    else
        print(chunks, whitespaces)
    end
end

function _scan_flow_breaks!(s::_YScanner, chunks::IOBuffer)
    while true
        p = _prefix(s, 3)
        (p == "---" || p == "...") && _pk(s, 3) in _Z &&
            _yerr(s, "a document separator inside a quoted scalar")
        while _pk(s) in " \t"
            _fwd!(s)
        end
        if _pk(s) in _BRK
            print(chunks, _scan_line_break!(s))
        else
            return
        end
    end
end

function _scan_plain!(s::_YScanner)
    chunks = IOBuffer()
    line = s.line
    indent = s.indent + 1
    spaces = ""
    while true
        n = 0
        _pk(s) == '#' && break
        while true
            ch = _pk(s, n)
            if ch in _Z ||
               (ch == ':' && (_pk(s, n + 1) in _Z || (s.flow_level > 0 && _pk(s, n + 1) in ",[]{}"))) ||
               (s.flow_level > 0 && ch in ",?[]{}")
                break
            end
            n += 1
        end
        n == 0 && break
        s.allow_simple_key = false
        print(chunks, spaces)
        print(chunks, _prefix(s, n))
        _fwd!(s, n)
        sp = _scan_plain_spaces!(s)
        (sp === nothing || isempty(sp) || _pk(s) == '#' ||
         (s.flow_level == 0 && s.column < indent)) && break
        spaces = sp
    end
    return _ytok(:scalar, line; value = String(take!(chunks)), plain = true)
end

# `nothing` where PyYAML returns None (a document marker ends the scalar).
function _scan_plain_spaces!(s::_YScanner)
    n = 0
    while _pk(s, n) == ' '
        n += 1
    end
    whitespaces = _prefix(s, n)
    _fwd!(s, n)
    ch = _pk(s)
    if ch in _BRK
        line_break = _scan_line_break!(s)
        s.allow_simple_key = true
        p = _prefix(s, 3)
        (p == "---" || p == "...") && _pk(s, 3) in _Z && return nothing
        breaks = IOBuffer()
        while _pk(s) in " \r\n\u85  "
            if _pk(s) == ' '
                _fwd!(s)
            else
                print(breaks, _scan_line_break!(s))
                p = _prefix(s, 3)
                (p == "---" || p == "...") && _pk(s, 3) in _Z && return nothing
            end
        end
        b = String(take!(breaks))
        out = IOBuffer()
        if line_break != "\n"
            print(out, line_break)
        elseif isempty(b)
            print(out, ' ')
        end
        print(out, b)
        return String(take!(out))
    end
    return whitespaces
end

# --------------------------------------------------------------------------------------
# Parser: PyYAML's state machine, events instead of tokens
# --------------------------------------------------------------------------------------

struct _YEv
    kind::Symbol           # :stream_start, :stream_end, :document_start, :document_end,
                           # :alias, :scalar, :sequence_start, :sequence_end,
                           # :mapping_start, :mapping_end
    anchor::Union{Nothing, String}
    tag::Union{Nothing, String}
    plain::Bool            # an untagged plain scalar: resolved by the implicit rules
    value::String
    line::Int
end

_yev(kind, line; anchor = nothing, tag = nothing, plain = false, value = "") =
    _YEv(kind, anchor, tag, plain, value, line)

mutable struct _YParser
    s::_YScanner
    current::Union{Nothing, _YEv}
    state::Symbol
    states::Vector{Symbol}
    tag_handles::Dict{String, String}
    yaml_version::Union{Nothing, Tuple{Int, Int}}
end

const _DEFAULT_TAGS = Dict("!" => "!", "!!" => "tag:yaml.org,2002:")

_YParser(s::_YScanner) = _YParser(s, nothing, :stream_start, Symbol[], copy(_DEFAULT_TAGS), nothing)

_perr(p::_YParser, msg::AbstractString, tok) =
    throw(HeaderError("R12", msg, _file_line(p.s.line_numbers, tok === nothing ? p.s.line : tok.line)))

function _peek_event(p::_YParser)
    if p.current === nothing && p.state !== :none
        p.current = _parse_state!(p, p.state)
    end
    return p.current
end

function _get_event(p::_YParser)
    ev = _peek_event(p)
    p.current = nothing
    return ev
end

_check_event(p::_YParser, kind::Symbol) = (ev = _peek_event(p); ev !== nothing && ev.kind == kind)

function _parse_state!(p::_YParser, st::Symbol)
    st === :stream_start && return _parse_stream_start!(p)
    st === :implicit_document_start && return _parse_implicit_document_start!(p)
    st === :document_start && return _parse_document_start!(p)
    st === :document_end && return _parse_document_end!(p)
    st === :document_content && return _parse_document_content!(p)
    st === :block_node && return _parse_node!(p, true, false)
    st === :block_sequence_first_entry && return (_get_token(p.s); _parse_block_sequence_entry!(p))
    st === :block_sequence_entry && return _parse_block_sequence_entry!(p)
    st === :indentless_sequence_entry && return _parse_indentless_sequence_entry!(p)
    st === :block_mapping_first_key && return (_get_token(p.s); _parse_block_mapping_key!(p))
    st === :block_mapping_key && return _parse_block_mapping_key!(p)
    st === :block_mapping_value && return _parse_block_mapping_value!(p)
    st === :flow_sequence_first_entry && return (_get_token(p.s); _parse_flow_sequence_entry!(p, true))
    st === :flow_sequence_entry && return _parse_flow_sequence_entry!(p, false)
    st === :flow_sequence_entry_mapping_key && return _parse_flow_sequence_entry_mapping_key!(p)
    st === :flow_sequence_entry_mapping_value && return _parse_flow_sequence_entry_mapping_value!(p)
    st === :flow_sequence_entry_mapping_end && return _parse_flow_sequence_entry_mapping_end!(p)
    st === :flow_mapping_first_key && return (_get_token(p.s); _parse_flow_mapping_key!(p, true))
    st === :flow_mapping_key && return _parse_flow_mapping_key!(p, false)
    st === :flow_mapping_value && return _parse_flow_mapping_value!(p)
    st === :flow_mapping_empty_value && return _parse_flow_mapping_empty_value!(p)
    error("unknown YAML parser state $(st)")
end

function _parse_stream_start!(p::_YParser)
    tok = _get_token(p.s)
    p.state = :implicit_document_start
    return _yev(:stream_start, tok.line)
end

function _parse_implicit_document_start!(p::_YParser)
    if !_check_token(p.s, :directive, :document_start, :stream_end)
        p.tag_handles = copy(_DEFAULT_TAGS)
        tok = _peek_token(p.s)
        push!(p.states, :document_end)
        p.state = :block_node
        return _yev(:document_start, tok.line)
    end
    return _parse_document_start!(p)
end

function _parse_document_start!(p::_YParser)
    while _check_token(p.s, :document_end)
        _get_token(p.s)
    end
    if !_check_token(p.s, :stream_end)
        tok = _peek_token(p.s)
        _perr(p, "YAML directives and document-start markers are forbidden (R12)", tok)
        _process_directives!(p)
        _check_token(p.s, :document_start) ||
            _perr(p, "expected '---' after the directives", _peek_token(p.s))
        _get_token(p.s)
        push!(p.states, :document_end)
        p.state = :document_content
        return _yev(:document_start, tok.line)
    end
    tok = _get_token(p.s)
    p.state = :none
    return _yev(:stream_end, tok.line)
end

function _parse_document_end!(p::_YParser)
    tok = _peek_token(p.s)
    _check_token(p.s, :document_end) && _get_token(p.s)
    p.state = :document_start
    return _yev(:document_end, tok.line)
end

function _parse_document_content!(p::_YParser)
    if _check_token(p.s, :directive, :document_start, :document_end, :stream_end)
        tok = _peek_token(p.s)
        p.state = pop!(p.states)
        return _empty_scalar(tok.line)
    end
    return _parse_node!(p, true, false)
end

function _process_directives!(p::_YParser)
    p.yaml_version = nothing
    p.tag_handles = Dict{String, String}()
    while _check_token(p.s, :directive)
        tok = _get_token(p.s)
        if tok.value == "YAML"
            p.yaml_version === nothing || _perr(p, "a duplicate %YAML directive", tok)
            tok.major == 1 || _perr(p, "an incompatible YAML document (version 1.* is required)", tok)
            p.yaml_version = (tok.major, tok.minor)
        elseif tok.value == "TAG"
            handle, prefix = tok.tagpairs
            haskey(p.tag_handles, handle) && _perr(p, "a duplicate tag handle $(repr(handle))", tok)
            p.tag_handles[handle] = prefix
        end
    end
    for (k, v) in _DEFAULT_TAGS
        haskey(p.tag_handles, k) || (p.tag_handles[k] = v)
    end
end

_empty_scalar(line::Int) = _yev(:scalar, line; plain = true, value = "")

function _parse_node!(p::_YParser, block::Bool, indentless::Bool)
    s = p.s
    if _check_token(s, :alias)
        tok = _get_token(s)
        p.state = pop!(p.states)
        return _yev(:alias, tok.line; anchor = tok.value)
    end
    anchor = nothing
    tag = nothing
    handle = nothing
    tagged = false
    line = _peek_token(s).line
    if _check_token(s, :anchor)
        anchor = _get_token(s).value
        if _check_token(s, :tag)
            t = _get_token(s)
            tagged, handle, tag = true, t.handle, t.value
        end
    elseif _check_token(s, :tag)
        t = _get_token(s)
        tagged, handle, tag = true, t.handle, t.value
        _check_token(s, :anchor) && (anchor = _get_token(s).value)
    end
    if tagged
        if handle !== nothing
            haskey(p.tag_handles, handle) || _perr(p, "an undefined tag handle $(repr(handle))", _peek_token(s))
            tag = p.tag_handles[handle] * tag
        end
    end
    if indentless && _check_token(s, :block_entry)
        p.state = :indentless_sequence_entry
        return _yev(:sequence_start, line; anchor = anchor, tag = tag)
    end
    if _check_token(s, :scalar)
        tok = _get_token(s)
        p.state = pop!(p.states)
        # PyYAML resolves an untagged plain scalar, or one tagged with the bare `!`,
        # by the implicit rules; every other scalar is a string unless tagged.
        return _yev(:scalar, tok.line; anchor = anchor, tag = tag,
                    plain = (tok.plain && !tagged) || tag == "!", value = tok.value)
    elseif _check_token(s, :flow_sequence_start)
        p.state = :flow_sequence_first_entry
        return _yev(:sequence_start, line; anchor = anchor, tag = tag)
    elseif _check_token(s, :flow_mapping_start)
        p.state = :flow_mapping_first_key
        return _yev(:mapping_start, line; anchor = anchor, tag = tag)
    elseif block && _check_token(s, :block_sequence_start)
        p.state = :block_sequence_first_entry
        return _yev(:sequence_start, line; anchor = anchor, tag = tag)
    elseif block && _check_token(s, :block_mapping_start)
        p.state = :block_mapping_first_key
        return _yev(:mapping_start, line; anchor = anchor, tag = tag)
    elseif anchor !== nothing || tagged
        p.state = pop!(p.states)
        return _yev(:scalar, line; anchor = anchor, tag = tag, plain = !tagged || tag == "!", value = "")
    end
    tok = _peek_token(s)
    _perr(p, "expected a YAML node, found $(_token_name(tok.kind))", tok)
end

_token_name(k::Symbol) = replace(string(k), "_" => " ")

function _parse_block_sequence_entry!(p::_YParser)
    s = p.s
    if _check_token(s, :block_entry)
        tok = _get_token(s)
        if !_check_token(s, :block_entry, :block_end)
            push!(p.states, :block_sequence_entry)
            return _parse_node!(p, true, false)
        end
        p.state = :block_sequence_entry
        return _empty_scalar(tok.line)
    end
    _check_token(s, :block_end) ||
        _perr(p, "expected the end of a block sequence, found $(_token_name(_peek_token(s).kind))", _peek_token(s))
    tok = _get_token(s)
    p.state = pop!(p.states)
    return _yev(:sequence_end, tok.line)
end

function _parse_indentless_sequence_entry!(p::_YParser)
    s = p.s
    if _check_token(s, :block_entry)
        tok = _get_token(s)
        if !_check_token(s, :block_entry, :key, :value, :block_end)
            push!(p.states, :indentless_sequence_entry)
            return _parse_node!(p, true, false)
        end
        p.state = :indentless_sequence_entry
        return _empty_scalar(tok.line)
    end
    tok = _peek_token(s)
    p.state = pop!(p.states)
    return _yev(:sequence_end, tok.line)
end

function _parse_block_mapping_key!(p::_YParser)
    s = p.s
    if _check_token(s, :key)
        tok = _get_token(s)
        if !_check_token(s, :key, :value, :block_end)
            push!(p.states, :block_mapping_value)
            return _parse_node!(p, true, true)
        end
        p.state = :block_mapping_value
        return _empty_scalar(tok.line)
    end
    _check_token(s, :block_end) ||
        _perr(p, "expected the end of a block mapping, found $(_token_name(_peek_token(s).kind))", _peek_token(s))
    tok = _get_token(s)
    p.state = pop!(p.states)
    return _yev(:mapping_end, tok.line)
end

function _parse_block_mapping_value!(p::_YParser)
    s = p.s
    if _check_token(s, :value)
        tok = _get_token(s)
        if !_check_token(s, :key, :value, :block_end)
            push!(p.states, :block_mapping_key)
            return _parse_node!(p, true, true)
        end
        p.state = :block_mapping_key
        return _empty_scalar(tok.line)
    end
    p.state = :block_mapping_key
    return _empty_scalar(_peek_token(s).line)
end

function _parse_flow_sequence_entry!(p::_YParser, first::Bool)
    s = p.s
    if !_check_token(s, :flow_sequence_end)
        if !first
            _check_token(s, :flow_entry) ||
                _perr(p, "expected ',' or ']' in a flow sequence, found $(_token_name(_peek_token(s).kind))", _peek_token(s))
            _get_token(s)
        end
        if _check_token(s, :key)
            tok = _peek_token(s)
            p.state = :flow_sequence_entry_mapping_key
            return _yev(:mapping_start, tok.line)
        elseif !_check_token(s, :flow_sequence_end)
            push!(p.states, :flow_sequence_entry)
            return _parse_node!(p, false, false)
        end
    end
    tok = _get_token(s)
    p.state = pop!(p.states)
    return _yev(:sequence_end, tok.line)
end

function _parse_flow_sequence_entry_mapping_key!(p::_YParser)
    s = p.s
    tok = _get_token(s)
    if !_check_token(s, :value, :flow_entry, :flow_sequence_end)
        push!(p.states, :flow_sequence_entry_mapping_value)
        return _parse_node!(p, false, false)
    end
    p.state = :flow_sequence_entry_mapping_value
    return _empty_scalar(tok.line)
end

function _parse_flow_sequence_entry_mapping_value!(p::_YParser)
    s = p.s
    if _check_token(s, :value)
        tok = _get_token(s)
        if !_check_token(s, :flow_entry, :flow_sequence_end)
            push!(p.states, :flow_sequence_entry_mapping_end)
            return _parse_node!(p, false, false)
        end
        p.state = :flow_sequence_entry_mapping_end
        return _empty_scalar(tok.line)
    end
    p.state = :flow_sequence_entry_mapping_end
    return _empty_scalar(_peek_token(s).line)
end

function _parse_flow_sequence_entry_mapping_end!(p::_YParser)
    p.state = :flow_sequence_entry
    return _yev(:mapping_end, _peek_token(p.s).line)
end

function _parse_flow_mapping_key!(p::_YParser, first::Bool)
    s = p.s
    if !_check_token(s, :flow_mapping_end)
        if !first
            _check_token(s, :flow_entry) ||
                _perr(p, "expected ',' or '}' in a flow mapping, found $(_token_name(_peek_token(s).kind))", _peek_token(s))
            _get_token(s)
        end
        if _check_token(s, :key)
            tok = _get_token(s)
            if !_check_token(s, :value, :flow_entry, :flow_mapping_end)
                push!(p.states, :flow_mapping_value)
                return _parse_node!(p, false, false)
            end
            p.state = :flow_mapping_value
            return _empty_scalar(tok.line)
        elseif !_check_token(s, :flow_mapping_end)
            push!(p.states, :flow_mapping_empty_value)
            return _parse_node!(p, false, false)
        end
    end
    tok = _get_token(s)
    p.state = pop!(p.states)
    return _yev(:mapping_end, tok.line)
end

function _parse_flow_mapping_value!(p::_YParser)
    s = p.s
    if _check_token(s, :value)
        tok = _get_token(s)
        if !_check_token(s, :flow_entry, :flow_mapping_end)
            push!(p.states, :flow_mapping_key)
            return _parse_node!(p, false, false)
        end
        p.state = :flow_mapping_key
        return _empty_scalar(tok.line)
    end
    p.state = :flow_mapping_key
    return _empty_scalar(_peek_token(s).line)
end

function _parse_flow_mapping_empty_value!(p::_YParser)
    p.state = :flow_mapping_key
    return _empty_scalar(_peek_token(p.s).line)
end

# --------------------------------------------------------------------------------------
# Composer and constructor, with the FHR rules
# --------------------------------------------------------------------------------------

mutable struct _YComposer
    p::_YParser
    nodes::Int
end

_cline(c::_YComposer, ev::_YEv) = _file_line(c.p.s.line_numbers, ev.line)

"A complex (sequence or mapping) key, which no JSON object can hold."
struct _ComplexKey end

function _compose_node!(c::_YComposer, depth::Int)
    c.nodes += 1
    ev = _peek_event(c.p)
    c.nodes > MAX_YAML_NODES && throw(HeaderError("limits",
        "the metadata holds more than $(MAX_YAML_NODES) YAML nodes", _cline(c, ev)))
    depth >= MAX_YAML_DEPTH && throw(HeaderError("limits",
        "the metadata is nested more than $(MAX_YAML_DEPTH) levels deep", _cline(c, ev)))
    (ev.kind === :alias || ev.anchor !== nothing) && throw(HeaderError("R8",
        "YAML anchors and aliases are not allowed in FHR metadata", _cline(c, ev)))
    ev.tag !== nothing && throw(HeaderError("R12",
        "YAML tags such as $(ev.tag) are not allowed in FHR metadata", _cline(c, ev)))
    if ev.kind === :scalar
        _get_event(c.p)
        return _construct_scalar(c, ev)
    elseif ev.kind === :sequence_start
        _get_event(c.p)
        out = Any[]
        while !_check_event(c.p, :sequence_end)
            iev = _peek_event(c.p)
            item = _compose_node!(c, depth + 1)
            item isa _MergeKey && throw(HeaderError("R8",
                "a plain << is a YAML merge key, which FHR metadata does not allow; quote it", _cline(c, iev)))
            push!(out, item)
        end
        _get_event(c.p)
        return out
    elseif ev.kind === :mapping_start
        _get_event(c.p)
        out = Dict{String, Any}()
        while !_check_event(c.p, :mapping_end)
            kev = _peek_event(c.p)
            key = _compose_node!(c, depth + 1)
            value = _compose_node!(c, depth + 1)
            key isa _MergeKey && throw(HeaderError("R8",
                "YAML merge keys are not allowed in FHR metadata", _cline(c, kev)))
            (key isa AbstractVector || key isa AbstractDict) && throw(HeaderError("R8",
                "a mapping key must be a string, not a YAML sequence or mapping", _cline(c, kev)))
            key isa String || throw(HeaderError("R8",
                "FHR metadata keys must be strings; found $(repr(key))", _cline(c, kev)))
            haskey(out, key) && throw(HeaderError("R8", "duplicate mapping key $(repr(key))", _cline(c, kev)))
            value isa _MergeKey && throw(HeaderError("R8",
                "a plain << is a YAML merge key, which FHR metadata does not allow; quote it", _cline(c, kev)))
            out[key] = value
        end
        _get_event(c.p)
        return out
    end
    throw(HeaderError("R12", "unexpected YAML event $(ev.kind)", _cline(c, ev)))
end

"A plain `<<`: YAML 1.1 reads it as a merge key wherever it appears (R8)."
struct _MergeKey end

function _construct_scalar(c::_YComposer, ev::_YEv)
    ev.plain || return ev.value
    ev.value == "<<" && return _MergeKey()
    return plain_value(ev.value, _cline(c, ev))
end

"""
    _load_yaml(text, line_numbers) -> Any

Read one YAML document the way the reference toolkit's loader does (PyYAML SafeLoader with
the FHR rules). `nothing` for an empty stream.
"""
function _load_yaml(text::AbstractString, line_numbers = nothing)
    s = _YScanner(text, line_numbers)
    p = _YParser(s)
    c = _YComposer(p, 0)
    _get_event(p)                                       # stream start
    doc = nothing
    if !_check_event(p, :stream_end)
        _get_event(p)                                   # document start
        doc = _compose_node!(c, 0)
        _get_event(p)                                   # document end
    end
    if !_check_event(p, :stream_end)
        ev = _get_event(p)
        throw(HeaderError("R12", "the header holds more than one YAML document", _cline(c, ev)))
    end
    _get_event(p)
    doc isa _MergeKey && throw(HeaderError("R8",
        "a plain << is a YAML merge key, which FHR metadata does not allow; quote it", _file_line(line_numbers, 0)))
    return doc
end
