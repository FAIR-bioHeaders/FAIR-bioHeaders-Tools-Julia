# Transparent gzip/BGZF input (rule R1).
#
# docs/FORMAT.md R1 defines the checksum coverage as "the exact bytes of the (decompressed)
# file": a `.gz` FH* file carries the same checksum as its uncompressed form, and gzip members
# concatenate (BGZF is gzip whose blocks are separate members, so a multi-member reader is
# also a BGZF reader). This layer therefore decides decompression by the two-byte gzip magic,
# never by the file name, and hands the rest of the package the decompressed bytes.
#
# The decompressor is `CodecZlib` (MIT), which wraps the zlib C library through the
# `Zlib_jll` BinaryBuilder wrapper (zlib license; wrapper MIT). That is the one compiled
# dependency boundary in this package and it is deliberately narrow: `decompress_gzip` below
# is the only function that touches it, the acceptance vectors decide the result end to end,
# and docs/CAPABILITY.md records why. The pure-Julia alternative `Inflate` (0.1.5) was
# measured on the released suite: its `inflate_gzip` stops at the first member, so it
# decompresses plain single-member gzip correctly but returns 96 of 581 bytes for
# `valid/fasta-bgzf.fhr.fasta.gz` and truncates every multi-member vector. zlib reads all
# thirteen compressed vectors (11 shared + 2 FHT draft) byte-exactly; that measurement is
# the acceptance gate for this boundary.

using CodecZlib
using TranscodingStreams: NoopStream, unread

"The two-byte gzip magic (RFC 1952). A file starting with it is read as gzip members."
const GZIP_MAGIC = (0x1f, 0x8b)

"is `data` a gzip stream (so R1 hashes its decompressed bytes)?"
function is_gzip(data::Union{Vector{UInt8}, AbstractVector{UInt8}})
    return length(data) >= 2 && data[1] == GZIP_MAGIC[1] && data[2] == GZIP_MAGIC[2]
end

const _CHUNK = 1 << 16

"""
    foreach_chunk(f, io; bufsize = 64 KiB)

Call `f(buffer, n)` for each successive chunk of the bytes R1 hashes: the bytes of `io`, or,
when they start with the gzip magic, their decompressed bytes. Gzip members are read one
at a time (plain gzip, multi-member gzip and BGZF alike), so memory stays bounded by the
buffers whatever the file size. Like Python's `gzip` module, which the reference toolkit
reads with, zero bytes after a member are padding and are skipped; anything else after a
member must be another member. A corrupt or truncated stream, or trailing bytes that are
not a member, raise `HeaderError("R1", ...)`.

One deliberate difference: zlib checks the optional gzip header CRC (FHCRC) and rejects a
member whose header CRC is wrong; Python's `gzip` skips that field without checking it.
Such a file is corrupt, so this reader keeps zlib's check (docs/CAPABILITY.md E0(d)).
"""
function foreach_chunk(f, io::IO; bufsize::Int = _CHUNK)
    raw = NoopStream(io)
    buf = Vector{UInt8}(undef, bufsize)
    head = read(raw, 2)
    unread(raw, head)
    if !is_gzip(head)
        while !eof(raw)
            n = readbytes!(raw, buf, bufsize)
            n > 0 && f(buf, n)
        end
        return nothing
    end
    try
        while true
            z = GzipDecompressorStream(raw; stop_on_end = true)
            while !eof(z)
                n = readbytes!(z, buf, bufsize)
                n > 0 && f(buf, n)
            end
            close(z)
            while !eof(raw) && peek(raw, UInt8) == 0x00     # zero padding between or after members
                read(raw, UInt8)
            end
            eof(raw) && break
            next = read(raw, 2)
            is_gzip(next) || throw(HeaderError("R1",
                "the gzip (or BGZF) stream is followed by bytes that are not a gzip member", 1))
            unread(raw, next)
        end
    catch e
        e isa HeaderError && rethrow()
        throw(HeaderError("R1", "the gzip (or BGZF) stream does not decompress: " *
                                sprint(showerror, e), 1))
    end
    return nothing
end

"""
    decompress_gzip(data) -> Vector{UInt8}

Inflate every gzip member of `data` (plain gzip, multi-member gzip and BGZF alike — zlib
reads the FEXTRA/BC subfield and the empty BGZF terminator as ordinary gzip), skipping zero
padding after a member as Python's `gzip` does. A corrupt stream raises
`HeaderError("R1", ...)` naming the underlying failure: truncated or mangled compressed
input is a byte-layer error, never a silent empty result.

This helper materializes the entire decompressed result and has no output-size cap.
Use it only when the caller trusts the input's decompressed size to fit memory;
compressed file size alone does not establish that. Use [`verify_file`](@ref)
instead for streaming verification of large or untrusted inputs.
"""
function decompress_gzip(data::AbstractVector{UInt8})
    is_gzip(data) || throw(HeaderError("R1", "the data does not start with the gzip magic", 1))
    out = IOBuffer()
    foreach_chunk(IOBuffer(Vector{UInt8}(data))) do chunk, n
        write(out, view(chunk, 1:n))
    end
    return take!(out)
end

"""
    read_file_bytes(path) -> Vector{UInt8}

The bytes rule R1 hashes: the file's content, transparently decompressed when it carries the
gzip magic. Uncompressed files are returned byte-for-byte as stored. This reads the whole
file into memory, without a decompressed-size cap. Use it only for inputs whose
decompressed size the caller trusts to fit memory; a small compressed file may
expand substantially. [`verify_file`](@ref) streams instead and is the preferred
verification path for large or untrusted inputs.
"""
function read_file_bytes(path::AbstractString)
    raw = read(path)
    return is_gzip(raw) ? decompress_gzip(raw) : raw
end
