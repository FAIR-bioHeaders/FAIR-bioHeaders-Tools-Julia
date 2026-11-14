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

"The two-byte gzip magic (RFC 1952). A file starting with it is read as gzip members."
const GZIP_MAGIC = (0x1f, 0x8b)

"is `data` a gzip stream (so R1 hashes its decompressed bytes)?"
function is_gzip(data::Union{Vector{UInt8}, AbstractVector{UInt8}})
    return length(data) >= 2 && data[1] == GZIP_MAGIC[1] && data[2] == GZIP_MAGIC[2]
end

"""
    decompress_gzip(data) -> Vector{UInt8}

Inflate every concatenated gzip member of `data` (plain gzip, multi-member gzip and BGZF
alike — zlib reads the FEXTRA/BC subfield and the empty BGZF terminator as ordinary gzip).
A corrupt stream raises `HeaderError("R1", ...)` naming the underlying failure: truncated or
mangled compressed input is a byte-layer error, never a silent empty result.
"""
function decompress_gzip(data::AbstractVector{UInt8})
    try
        return Vector{UInt8}(transcode(GzipDecompressor, data))
    catch e
        throw(HeaderError("R1", "the gzip (or BGZF) stream does not decompress: " *
                                string(e), 1))
    end
end

"""
    read_file_bytes(path) -> Vector{UInt8}

The bytes rule R1 hashes: the file's content, transparently decompressed when it carries the
gzip magic. Uncompressed files are returned byte-for-byte as stored.
"""
function read_file_bytes(path::AbstractString)
    raw = read(path)
    return is_gzip(raw) ? decompress_gzip(raw) : raw
end
