# FAIRBioHeaders.jl test suite.
#
# Everything runs inside one outer testset so the receipt below can see the finished
# results of every inner set.
#
# Layer 1 is self-contained: the byte rules (R1-R7, R10, G1), the header reader
# (R8, R11, R12, R13), contract selection (V1-V6), format assertions, the R14 scheme
# warnings, the bundled-schema audit and the rule-V7 draft lane machinery (pinned-byte
# enforcement with mutation controls, lane-off byte-identity, FHGM model checks), on
# records and files built inside the test. The draft SUITES are not run here; they run
# only in the labelled CI job through scripts/draft_vectors.jl and never join the 291.
#
# Layer 2 is the acceptance gate: the 291 shared conformance vectors of
# FAIR-bioHeaders-Specification release v0.6.0 (conformance/manifest.json).
# The suite is NOT vendored here; it is located through the environment variable
# FAIRBIOHEADERS_CONFORMANCE (a checkout of FAIR-bioHeaders-Specification at tag
# v0.6.0) or a test/conformance directory. When the variable is set but names no
# suite, that is a missing fixture and the run errors; only a completely unset
# variable (a local rule-only run) skips the layer, with a stated reason.
# CI provides the released tag, never main, and asserts the receipt written below.
#
# The receipt (FAIRBIOHEADERS_RECEIPT=path) states what actually ran: vector counts,
# the compressed-vector decision count, the audit finding counts (released bundle and
# draft pins) and the assertion tally read out of Test's own result tree. A missing or
# short receipt fails CI; so do failed, errored or broken assertions and an assertion
# count below the floor.

using FAIRBioHeaders
using SHA
using Base64
using JSON
using CodecZlib
using Test

# 32 zero bytes in canonical padded base64: a shape-valid checksum value.
const HELPER_B64 = "A"^42 * "A="

"Byte equality of two files. Every mutation control in this suite first proves the
mutation is real with this: a guard tested against bytes it could not distinguish from
the originals proves nothing (a control that cannot fail is decoration)."
function cmp_similar(a::AbstractString, b::AbstractString)
    read(a) == read(b)
end

# What the conformance and audit layers measured, recorded as they ran; the receipt
# refuses to write `unknown` for any of it, so a layer that died halfway shows up.
const STATE = Dict{String, Any}()

"one-shot SHA-512/256 via the CTX API, which exists on every supported SHA stdlib
version (SHA.jl's `sha2_512_256(bytes)` convenience export only arrived later)"
function sha512_256_bytes(bytes)::Vector{UInt8}
    ctx = SHA2_512_256_CTX()
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end

function base_record()
    Dict{String, Any}(
        "schema" => "https://w3id.org/fair-bioheaders/fhr/v0.6.0",
        "schemaVersion" => "2.1",
        "genome" => "Synthetic test genome",
        "taxon" => Dict("name" => "Homo sapiens"),
        "version" => "1.0.0",
        "metadataAuthor" => Any[Dict("name" => "Test metadata author")],
        "assemblyAuthor" => Any[Dict("name" => "Test assembly author")],
        "dateCreated" => "2026-01-01",
        "masking" => "unknown",
        "checksum" => HELPER_B64,
    )
end

function fhp_record()
    Dict{String, Any}(
        "schema" => "https://w3id.org/fair-bioheaders/fhp/v0.6.0",
        "schemaVersion" => "1.2",
        "proteome" => "Synthetic test proteome",
        "sourceType" => "predicted",
        "taxon" => Dict("name" => "Drosophila melanogaster"),
        "version" => "1.0.0",
        "metadataAuthor" => Any[Dict("name" => "Test metadata author")],
        "dateCreated" => "2026-01-01",
        "checksum" => HELPER_B64,
    )
end

function fhg_record()
    Dict{String, Any}(
        "schema" => "https://w3id.org/fair-bioheaders/fhgff3/v0.6.0",
        "schemaVersion" => "1.2",
        "annotation" => "Synthetic test annotation",
        "taxon" => Dict("name" => "Homo sapiens"),
        "version" => "1.0.0",
        "metadataAuthor" => Any[Dict("name" => "Test metadata author")],
        "dateCreated" => "2026-01-01",
        "checksum" => HELPER_B64,
        "genomeReference" => Dict("accession" => "SYNTHETIC_ASSEMBLY.1",
                                  "seqcol_id" => "S"^32),
    )
end

"""Build a file: header lines from `meta` (each prefixed), then the root checksum
line computed over the R3-covered bytes (everything except that line and its
terminator), then `data`. Returns the file text and the digest it states."""
function build_file(meta::Vector{String}, data::String; prefix = ";~")
    lines = [prefix * m for m in meta]
    append!(lines, String.(data_parts(data)))
    covered = join(lines, "\n") * "\n"
    digest = base64encode(sha512_256_bytes(Vector{UInt8}(covered)))
    insert!(lines, length(meta) + 1, prefix * "checksum: " * digest)   # last header line
    return join(lines, "\n") * "\n", digest
end

data_parts(data::AbstractString) = split(chomp(data), "\n")

"Header lines for a record: each value written as JSON, which YAML reads as a flow value."
record_meta(d::AbstractDict) = String[k * ": " * JSON.json(v) for (k, v) in sort!(collect(d); by = first) if k != "checksum"]

"""Like `build_file`, but the checksum line goes between `before` and `after` header lines,
so a test can place it where it is not the record's checksum."""
function build_split(before::Vector{String}, after::Vector{String}, data::String; prefix = ";~")
    head = [prefix * m for m in vcat(before, after)]
    body = String.(data_parts(data))
    covered = join(vcat(head, body), "\n") * "\n"
    digest = base64encode(sha512_256_bytes(Vector{UInt8}(covered)))
    lines = vcat([prefix * m for m in before], [prefix * "checksum: " * digest],
                 [prefix * m for m in after], body)
    return join(lines, "\n") * "\n", digest
end

function write_temp(text; suffix = "")
    path = tempname() * suffix
    write(path, text)
    return path
end

# --------------------------------------------------------------------------------------
# Test-result introspection for the receipt. Types are matched by name because the set
# of Test result types has varied across Julia lines (there is no `Test.Skip` on 1.13);
# anything unrecognised counts into `other`, so a renamed type shows up in the receipt
# instead of silently vanishing from the tally.
# --------------------------------------------------------------------------------------

function tally_assertions(ts)
    # DefaultTestSet keeps only the non-pass results in `results` and counts the passes
    # in `n_passed`; skipped tests arrive as Broken records.
    c = Dict("pass" => ts.n_passed, "fail" => 0, "error" => 0, "broken" => 0, "other" => 0)
    for r in ts.results
        name = String(nameof(typeof(r)))
        if name == "DefaultTestSet"
            s = tally_assertions(r)
            for k in keys(c); c[k] += s[k]; end
        elseif name == "Fail"; c["fail"] += 1
        elseif name == "Error"; c["error"] += 1
        elseif name == "Broken"; c["broken"] += 1
        else; c["other"] += 1
        end
    end
    return c
end

const RECEIPT_KEYS = [
    "conformanceSuiteUsed", "suiteVectors", "vectorsDecided", "vectorsPassed",
    "vectorsFailed", "vectorsUndecided", "compressedVectorsDecided",
    "jsonldUndecided", "microdataUndecided", "schemaAuditFindings",
    "draftPinFindings",
]

function write_receipt(ts)
    path = get(ENV, "FAIRBIOHEADERS_RECEIPT", "")
    isempty(path) && return nothing
    t = tally_assertions(ts)
    lines = String[
        "tool=FAIRBioHeaders.jl",
        "juliaVersion=$(VERSION)",
        "assertionsPassed=$(t["pass"])",
        "assertionsFailed=$(t["fail"])",
        "assertionsErrored=$(t["error"])",
        "assertionsBroken=$(t["broken"])",
        "assertionsOther=$(t["other"])",
    ]
    for k in RECEIPT_KEYS
        push!(lines, "$(k)=$(get(STATE, k, "absent"))")
    end
    mkpath(dirname(abspath(path)))
    write(path, join(lines, "\n") * "\n")
    return nothing
end

@testset "FAIRBioHeaders" begin

@testset "byte layer (R1-R7, R10, G1)" begin
    @testset "digest primitive (SHA-512/256, R4)" begin
        # NIST-published SHA-512/256("abc"); matches Python hashlib and openssl on this host.
        @test bytes2hex(sha512_256_bytes(b"abc")) ==
              "53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23"
        @test base64encode(sha512_256_bytes(b"abc")) == "UwSOJoGUHvmbLim3a0x9q+TC0MY0/G1G4OLxMQfnryM="
    end

    @testset "scan_lines terminators (R1)" begin
        data = Vector{UInt8}("a\r\nb\rc\nd\n")
        ls = FAIRBioHeaders.scan_lines(data)
        @test [String(data[c]) for (c, _) in ls] == ["a", "b", "c", "d"]
        @test [length(t) for (_, t) in ls] == [2, 1, 1, 1]     # CRLF keeps both bytes (R1)
        lone = FAIRBioHeaders.scan_lines(Vector{UInt8}("x"))    # final line, no terminator
        @test length(lone) == 1 && isempty(lone[1][2])
    end

    @testset "round trip and coverage (R2-R5)" begin
        meta = ["schema: https://w3id.org/fair-bioheaders/fhr/v0.6.0", "schemaVersion: '2.1'",
                "genome: Synthetic", "taxon:", "  name: Homo sapiens", "version: 1.0.0",
                "metadataAuthor:", "- name: A Tester", "assemblyAuthor:", "- name: A Tester",
                "dateCreated: '2026-01-01'", "masking: unknown"]
        text, digest = build_file(meta, ">ctg1\nACGT\n")
        r = header_checksum(Vector{UInt8}(text), "fasta")
        @test r.stated == digest && r.computed == digest
        # one changed sequence byte breaks the match: the coverage is real
        rb = header_checksum(Vector{UInt8}(replace(text, "ACGT" => "ACGA")), "fasta")
        @test rb.stated != rb.computed
        # a second root checksum line inside the header is rejected (R2)
        two = replace(text, ";~masking: unknown\n" => ";~masking: unknown\n;~checksum: $HELPER_B64\n")
        @test_throws ArgumentError header_checksum(Vector{UInt8}(two), "fasta")
        # a nested `checksum:` key stays inside the digest: it is not the root line
        nmeta = vcat(meta, ["note:", "  checksum: $HELPER_B64"])
        ntext, ndigest = build_file(nmeta, ">ctg1\nACGT\n")
        rn = header_checksum(Vector{UInt8}(ntext), "fasta")
        @test rn.stated == ndigest && rn.computed == ndigest
        # a tab after the value breaks the R5 shape, so there is no checksum line at all
        @test_throws ArgumentError header_checksum(
            Vector{UInt8}(";~checksum: $HELPER_B64\t\n>ctg1\nA\n"), "fasta")
        # non-canonical padded base64 is rejected (R4: the unused last 4 bits must be zero)
        @test_throws ArgumentError header_checksum(
            Vector{UInt8}(";~checksum: $("A"^42)B=\n>ctg1\nA\n"), "fasta")
        # a missing value (folded onto the next line) is not a checksum line (R5)
        @test_throws ArgumentError header_checksum(
            Vector{UInt8}(";~checksum:\n  $HELPER_B64\n>ctg1\nA\n"), "fasta")
    end

    @testset "BOM, late lines and the FHGFF3 block end (R7, R10, G1)" begin
        text, _ = build_file(["genome: Synthetic"], ">ctg1\nACGT\n")
        @test_throws HeaderError read_fhr_file(vcat([0xef, 0xbb, 0xbf], Vector{UInt8}(text)), "fasta")
        @test_throws HeaderError read_fhr_file(Vector{UInt8}(text * ";~genome: late\n"), "fasta")
        gff = build_file(["annotation: test"], "ctg1\t.\tregion\t1\t10\t.\t+\t.\tID=ctg1\n";
                         prefix = "#~")
        ok_gff = "##gff-version 3\n" * gff[1]
        @test read_fhr_file(Vector{UInt8}(ok_gff), "fhgff3").metadata["annotation"] == "test"
        # a #~ line after ##FASTA is invalid even before the first sequence line (G1)
        late_fasta = "##gff-version 3\n#~checksum: $HELPER_B64\n##FASTA\n#~late: yes\n>ctg1\nACGT\n"
        @test_throws HeaderError read_fhr_file(Vector{UInt8}(late_fasta), "fhgff3")
        @test_throws HeaderError read_fhr_file(
            Vector{UInt8}("##gff-version 3.1\n#~checksum: $HELPER_B64\nctg1\n"), "fhgff3")
    end

    @testset "gzip and BGZF input (R1: the digest covers decompressed bytes)" begin
        # A self-contained fixture: the same text compressed and uncompressed must verify to
        # the same checksum — rule R1 says the hash is over the decompressed bytes.
        meta = ["schema: https://w3id.org/fair-bioheaders/fhp/v0.6.0",
                "schemaVersion: '1.2'", "proteome: Synthetic",
                "sourceType: predicted", "taxon:", "  name: Synthetic organism",
                "version: 1.0.0", "metadataAuthor:", "- name: A Tester",
                "dateCreated: '2026-01-01'"]
        text, digest = build_file(meta, ">p1\nMKV\n>p2\nMLA\n")
        plain = tempname() * ".fhp.fasta"
        gz = tempname() * ".fhp.fasta.gz"
        write(plain, text)
        write(gz, transcode(GzipCompressor, Vector{UInt8}(text)))
        rp = verify_file(plain)
        rg = verify_file(gz)
        @test rp.ok && rg.ok
        @test rp.computed == digest && rg.computed == digest   # the .gz carries the plain digest
        @test is_gzip(read(gz)) && !is_gzip(read(plain))
        # detection is by magic, not by file name: the same bytes under a bare name still read
        bare = tempname()
        cp(gz, bare)
        @test verify_file(bare; kind = "fhp-fasta").computed == digest
        rm(bare)
        # multi-member gzip: concatenated members are one stream (this is also what a BGZF
        # file is, block by block; the released suite's BGZF vectors decide that shape too)
        whole = Vector{UInt8}(text)
        half = div(length(whole), 2)
        members = transcode(GzipCompressor, whole[1:half])
        append!(members, transcode(GzipCompressor, whole[half + 1:end]))
        mm = tempname() * ".fhp.fasta.gz"
        write(mm, members)
        @test decompress_gzip(members) == whole
        @test verify_file(mm; kind = "fhp-fasta").computed == digest
        rm(mm)
        # a truncated stream is an R1 byte-layer error, never a silent empty result
        cut = members[1:div(length(members), 2)]
        @test_throws HeaderError decompress_gzip(cut)
        # a tampered member body either fails CRC or changes the decompressed bytes, so the
        # recomputed digest no longer matches what the file states: the file reads invalid
        bad = copy(members)
        bad[end - 30] = xor(bad[end - 30], 0x01)
        badgz = tempname() * ".fhp.fasta.gz"
        write(badgz, bad)
        rb = try
            verify_file(badgz)
        catch e
            e isa HeaderError ? nothing : rethrow()
        end
        @test rb === nothing || !rb.ok
        rm(badgz)
        rm(plain); rm(gz)
    end
end

@testset "verifier: containers, checksum line, V4, limits, streaming" begin
    gff_data = "ctg1\t.\tregion\t1\t10\t.\t+\t.\tID=ctg1\n"
    @testset "each header type in its own containers only" begin
        for (rec, kind, ok) in [(base_record(), "fasta", true), (base_record(), "gfa", true),
                                (fhp_record(), "fasta", true), (fhp_record(), "fhp-fasta", true),
                                (fhg_record(), "fhgff3", true),
                                (fhg_record(), "fasta", false), (fhg_record(), "gfa", false),
                                (fhp_record(), "gfa", false), (fhp_record(), "fhgff3", false),
                                (base_record(), "fhgff3", false)]
            prefix = kind in ("gfa", "fhgff3") ? "#~" : ";~"
            data = kind == "fasta" || kind == "fhp-fasta" ? ">c\nACGT\n" : kind == "gfa" ? "S\t1\tACGT\n" : gff_data
            text, digest = build_file(record_meta(rec), data; prefix = prefix)
            if kind == "fhgff3"                  # line 1 is covered too: restate the digest
                text = "##gff-version 3\n" * text
                fixed = scan_header(Vector{UInt8}(text), kind).computed
                text, digest = replace(text, digest => fixed), fixed
            end
            r = verify_file(write_temp(text); kind = kind)
            @test r.ok == ok
            ok || @test any(occursin("incompatible with", e) for e in r.errors)
            @test r.computed == digest
        end
        @test container_findings(Dict("schema" => "https://w3id.org/fair-bioheaders/fhp/v0.6.0"), "gfa") ==
              ["FHP metadata is incompatible with GFA; expected FHR metadata (FORMAT.md: each header type has its containers)"]
        @test isempty(container_findings(Dict("schema" => "anything else"), "gfa"))   # V5: FHR
    end
    @testset "the checksum line read alone is the record's checksum" begin
        meta = record_meta(base_record())
        for (open_, close_) in [("x-note: \"start", "end\""), ("x-note: 'start", "end'"), ("x-note: {a: 1,", "}")]
            text, _ = build_split(vcat(meta, [open_]), [close_, "\"checksum\": $HELPER_B64"], ">c\nA\n")
            r = verify_file(write_temp(text); kind = "fasta")
            @test !r.ok
            @test any(occursin("single-line scalar (rule R5)", e) for e in r.errors)
            @test r.stated == r.computed                  # the digest itself matches: only R5 catches it
        end
        text, _ = build_split(meta[1:2], meta[3:end], ">c\nA\n")   # anywhere in the block is fine
        @test verify_file(write_temp(text); kind = "fasta").ok
    end
    @testset "an unsupported version is not valid (V4)" begin
        for cite in ["https://w3id.org/fair-bioheaders/fhr/v0.2.0",
                     "https://raw.githubusercontent.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification/refs/heads/main/fhr.json",
                     "https://raw.githubusercontent.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification/refs/tags/v0.4.0/fhr.json"]
            rec = base_record()
            rec["schema"] = cite
            text, _ = build_file(record_meta(rec), ">c\nA\n")
            r = verify_file(write_temp(text); kind = "fasta")
            @test !r.ok && isempty(r.errors)
            @test any(occursin("unsupported schema version", n) for n in r.not_checked)
            shown = sprint(show, r)
            @test occursin("unsupported schema version (rule V4)", shown) && !occursin("]: valid", shown)
            @test_throws UnsupportedContract select_contract(cite)
        end
        @test parse_citation("https://raw.githubusercontent.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification/refs/heads/main/fhr.json") ==
              ("FHR", "refs/heads/main")
    end
    @testset "R6: header lines must be valid UTF-8" begin
        for bad in (UInt8[0xc0, 0x80], UInt8[0xed, 0xa0, 0x80], UInt8[0xff])   # overlong, surrogate, stray
            bytes = vcat(Vector{UInt8}(";~genome: x"), bad, Vector{UInt8}("\n;~checksum: $HELPER_B64\n>c\nA\n"))
            e = try read_fhr_file(bytes, "fasta"); nothing catch err; err end
            @test e isa HeaderError && e.rule == "R6"
        end
    end
    @testset "limits: 1 MiB and 10,000 header lines" begin
        lines(n) = vcat(["genome: x"], fill("# c", n - 2))
        text, _ = build_file(lines(10_000), ">c\nA\n")         # 10,000 lines with the checksum line
        @test length(scan_header(Vector{UInt8}(text), "fasta").header) == 10_000
        text, _ = build_file(lines(10_001), ">c\nA\n")
        e = try scan_header(Vector{UInt8}(text), "fasta"); nothing catch err; err end
        @test e isa HeaderError && e.rule == "limits"
        text, _ = build_file(["genome: " * "x"^(2^20)], ">c\nA\n")
        r = verify_file(write_temp(text); kind = "fasta")
        @test !r.ok && any(occursin("1 MiB", e) for e in r.errors)
        # a large data section is not a header: no limit applies to it
        text, digest = build_file(["genome: x"], ">c\n" * "ACGT"^(2^19) * "\n")
        @test verify_file(write_temp(text); kind = "fasta").computed == digest
    end
    @testset "streaming: any chunking gives the same result, memory stays bounded" begin
        text, digest = build_file(record_meta(base_record()), ">c\r\nAC\rGT\r\n>d\nAAA\n")
        text = replace(text, "\n;~" => "\r\n;~")                 # CRLF header lines too
        bytes = Vector{UInt8}(text)
        want = scan_header(bytes, "fasta")
        for sz in (1, 2, 3, 5, 7, 64)
            st = FAIRBioHeaders.HeaderScan("fasta")
            for i in 1:sz:length(bytes)
                FAIRBioHeaders._feed!(st, bytes[i:min(i + sz - 1, end)])
            end
            FAIRBioHeaders._finish!(st)
            @test st.computed == want.computed && length(st.header) == length(want.header)
        end
        @test want.computed == header_checksum(bytes, "fasta").computed
        big = tempname() * ".fhr.fasta"
        open(big, "w") do io
            meta, _ = build_file(record_meta(base_record()), ">c\nA\n")
            write(io, replace(meta, r">c\nA\n\z" => ""))
            write(io, ">c\n")
            line = "ACGT"^20 * "\n"
            for _ in 1:400_000                                   # about 32 MiB of sequence
                write(io, line)
            end
        end
        verify_file(big)                                         # compile first
        bytes_allocated = @allocated verify_file(big)
        @test bytes_allocated < 16 * 2^20                        # far below the file size
        @test filesize(big) > 30 * 2^20
        rm(big)
    end
    @testset "gzip: zero padding as Python's gzip reads it; FHCRC still checked" begin
        text, digest = build_file(record_meta(base_record()), ">c\nA\n")
        gz = transcode(GzipCompressor, Vector{UInt8}(text))
        r = verify_file(write_temp(vcat(gz, zeros(UInt8, 512)); suffix = ".fhr.fasta.gz"))
        @test r.ok && r.computed == digest
        mm = vcat(gz, zeros(UInt8, 7), transcode(GzipCompressor, UInt8[]))   # padding between members
        @test decompress_gzip(mm) == Vector{UInt8}(text)
        r = verify_file(write_temp(vcat(gz, Vector{UInt8}("trailing garbage")); suffix = ".fhr.fasta.gz"))
        @test !r.ok && any(startswith(e, "R1") for e in r.errors)
        # zlib checks the optional header CRC (Python's gzip skips it): a wrong one is R1
        fhcrc = vcat(gz[1:3], [gz[4] | 0x02], gz[5:10], UInt8[0x00, 0x00], gz[11:end])
        r = verify_file(write_temp(fhcrc; suffix = ".fhr.fasta.gz"))
        @test !r.ok && any(occursin("header crc", lowercase(e)) for e in r.errors)
    end
    @testset "GFA: blank lines may hold spaces; a byte order mark is R7" begin
        text, digest = build_file(["genome: x", "  "], "S\t1\tACGT\n"; prefix = "#~")
        text = replace(text, "#~genome: x\n" => "#~genome: x\n \t \n")    # whitespace-only line
        r = verify_file(write_temp(text); kind = "gfa")
        @test isempty(r.errors) || !any(occursin("R10", e) for e in r.errors)
        @test isempty(scan_header(Vector{UInt8}(text), "gfa").late)
        bom = vcat(UInt8[0xef, 0xbb, 0xbf], Vector{UInt8}(text))
        r = verify_file(write_temp(bom); kind = "gfa")
        @test !r.ok && any(startswith(e, "R7") for e in r.errors)
    end
end

@testset "header reader (R8, R11, R12, R13)" begin
    @testset "R8 structural bans" begin
        @test_throws HeaderError read_fhr_header("a: 1\na: 2\n")
        @test_throws HeaderError read_fhr_header("a: &x 1\nb: *x\n")
        @test_throws HeaderError read_fhr_header("base: &b {x: 1}\nchild:\n  <<: *b\n")
    end
    @testset "R12 portable scalars" begin
        @test_throws HeaderError read_fhr_header("a: !!str 5\n")            # explicit tag
        @test_throws HeaderError read_fhr_header("yes: on\n")               # 1.1/1.2 disagree
        @test_throws HeaderError read_fhr_header("a: 0b101\n")
        @test_throws HeaderError read_fhr_header("a: 0755\n")               # 1.1 reads octal
        @test_throws HeaderError read_fhr_header("a: 1:30\n")               # sexagesimal
        h = read_fhr_header("a: 2026-05-13\n")                              # date-shaped stays a string
        @test h.metadata["a"] == "2026-05-13"
        @test read_fhr_header("a: 2026-13-45\n").metadata["a"] == "2026-13-45"  # kept as written
    end
    @testset "R13 finiteness" begin
        @test_throws HeaderError read_fhr_header("a: .inf\n")
        @test_throws HeaderError read_fhr_header("a: .nan\n")
    end
    @testset "folding, quoting, block scalars" begin
        @test read_fhr_header("documentation: one\n  two\n").metadata["documentation"] == "one two"
        @test read_fhr_header("a: \"x\\x3Ey\"\n").metadata["a"] == "x>y"     # R11 escapes
        @test read_fhr_header("a: \"\\u00e9\"\n").metadata["a"] == "é"
        @test read_fhr_header("a: 'it''s'\n").metadata["a"] == "it's"
        @test read_fhr_header("a: |\n  l1\n  l2\n").metadata["a"] == "l1\nl2\n"
        @test read_fhr_header("a: |-\n  l1\n  l2\n").metadata["a"] == "l1\nl2"
        @test read_fhr_header("a: >\n  l1\n  l2\n").metadata["a"] == "l1 l2\n"
        @test read_fhr_header("a: [1, \"x\"]\n").metadata["a"] == Any[1, "x"]
        @test_throws HeaderError read_fhr_header("a: [1,\n")
    end
    # Every expectation below was taken from the reference toolkit (fair-bioheaders 0.12.0,
    # PyYAML 6.0 SafeLoader with the FHR rules): this reader must read a header exactly as
    # that one does, accepting what it accepts and rejecting what it rejects.
    @testset "multi-line scalars keep every character (toolkit-written wrapping)" begin
        # bioheaders' own YAML writer wraps long values at 80 columns: a quoted scalar
        # continues on an indented line, and a double-quoted one ends a line with `\`
        # and starts the next with `\ ` (an escaped space) to keep the space exactly.
        sq = "assemblyProtocol: 'Protocol: assembled with Hi-C reads from the Arima kit, scaffolded\n" *
             "  with YaHS and curated by hand in PretextView over several days of work'\n"
        @test read_fhr_header(sq).metadata["assemblyProtocol"] ==
              "Protocol: assembled with Hi-C reads from the Arima kit, scaffolded with YaHS " *
              "and curated by hand in PretextView over several days of work"
        @test read_fhr_header("a: 'Protocol: assembled with\n  Hi-C reads'\n").metadata["a"] ==
              "Protocol: assembled with Hi-C reads"
        dq = "x-note: \"A value with \\x3E and \\x40 characters that must be escaped in FASTA headers and\\\n" *
             "  \\ wraps across several lines because it is long enough\"\n"
        @test read_fhr_header(dq).metadata["x-note"] ==
              "A value with > and @ characters that must be escaped in FASTA headers and " *
              "wraps across several lines because it is long enough"
        @test read_fhr_header("a: \"Hi-C\n  reads\"\n").metadata["a"] == "Hi-C reads"
        @test read_fhr_header("a: \"l1\\\n  l2\"\n").metadata["a"] == "l1l2"        # `\` joins lines
        @test read_fhr_header("a: 'p1\n\n  p2'\n").metadata["a"] == "p1\np2"        # blank line = break
        @test read_fhr_header("a: plain\n  continued\n   more\n").metadata["a"] == "plain continued more"
        sqit = "x-sq: 'it''s a long single quoted value: with a colon and enough words to wrap past\n" *
               "  eighty columns for sure'\n"
        @test read_fhr_header(sqit).metadata["x-sq"] ==
              "it's a long single quoted value: with a colon and enough words to wrap past eighty columns for sure"
        # the same through a file: header lines, prefix and all
        text, _ = build_file(["schema: https://w3id.org/fair-bioheaders/fhr/v0.6.0",
                              "assemblyProtocol: 'Protocol: assembled with", "  Hi-C reads'"], ">c\nA\n")
        @test read_fhr_file(Vector{UInt8}(text), "fasta").metadata["assemblyProtocol"] ==
              "Protocol: assembled with Hi-C reads"
    end
    @testset "flow collections as YAML reads them" begin
        @test read_fhr_header("x: {a: 1}\n").metadata["x"] == Dict("a" => 1)
        @test read_fhr_header("x: {a: [1, 2], b: {c: d}}\n").metadata["x"] ==
              Dict("a" => Any[1, 2], "b" => Dict("c" => "d"))
        @test read_fhr_header("x: [a: 1]\n").metadata["x"] == Any[Dict("a" => 1)]   # single-pair mapping
        @test read_fhr_header("x: [a: 1, b]\n").metadata["x"] == Any[Dict("a" => 1), "b"]
        @test read_fhr_header("x: [http://x.org/a]\n").metadata["x"] == Any["http://x.org/a"]
        @test_throws HeaderError read_fhr_header("x: [http://x.org/a?b=c]\n")   # `?` ends a flow plain scalar
        @test read_fhr_header("x: {a:1}\n").metadata["x"] == Dict("a:1" => nothing)
        @test read_fhr_header("x: [1,\n  2]\n").metadata["x"] == Any[1, 2]          # multi-line flow
        @test read_fhr_header("x: {b: 1,\n  c: 2}\n").metadata["x"] == Dict("b" => 1, "c" => 2)
        @test read_fhr_header("x: [1, 2,]\n").metadata["x"] == Any[1, 2]
    end
    @testset "what PyYAML rejects is rejected" begin
        for bad in ["a: [&x 1]\n", "a: [*x]\n", "a: {b: !!int 1}\n", "a: [!!str 1]\n",  # inside flow
                    "a: @x\n", "a: `x\n", "a: %x\n",                                     # reserved starts
                    "\ta: 1\n", "a:\n\t- 1\n", "a: b\tc\n",                              # tabs
                    "? [a]\n: 1\n", "[a]: 1\n", "{a: 1}: 2\n",                           # complex keys
                    "x-a: <<\n", "a: [<<]\n", "<<: {a: 1}\n",                            # merge
                    "a: =\n", "a: -.5\n", "a: +.5\n",                                    # YAML 1.1 value / floats
                    "1: a\n", "null: a\n", "a: {1: b}\n",                                # non-string keys
                    "a: 1\n---\nb: 2\n", "- 1\n- 2\n", "just a string\n",                # not one mapping
                    "%YAML 2.0\n---\na: 1\n", "a: \"\\q\"\n", "a: \"\\U00110000\"\n"]
            @test_throws HeaderError read_fhr_header(bad)
        end
        @test read_fhr_header("a: .5\n").metadata["a"] == 0.5         # unsigned is a float in both
        @test read_fhr_header("a: '-.5'\n").metadata["a"] == "-.5"
        @test read_fhr_header("a: x%\n").metadata["a"] == "x%"
        @test read_fhr_header("a: \"=\"\n").metadata["a"] == "="
    end
    @testset "what PyYAML accepts is accepted" begin
        big = read_fhr_header("a: 123456789012345678901234567890\nb: -9223372036854775809\nc: 9223372036854775807\n").metadata
        @test big["a"] == parse(BigInt, "123456789012345678901234567890")
        @test big["b"] == parse(BigInt, "-9223372036854775809")
        @test big["c"] === typemax(Int)
        @test_throws HeaderError read_fhr_header("---\na: 1\n") # adopted D10/R12
        @test_throws HeaderError read_fhr_header("--- \na: 1\n...\n") # adopted D10/R12
        @test_throws HeaderError read_fhr_header("%YAML 1.1\n---\na: 1\n") # adopted D10/R12
        @test_throws HeaderError read_fhr_header("%YAML 1.2\n---\na: 1\n") # adopted D10/R12
        @test_throws HeaderError read_fhr_header("%TAG ! tag:example.com,2000:\n---\na: 1\n") # adopted D10/R12
        @test_throws HeaderError read_fhr_header("%TAG ! tag:example.com,2000:\n---\na: !x 1\n")  # used: a tag
        @test read_fhr_header("? a\n: 1\n").metadata == Dict("a" => 1)          # explicit key
        @test read_fhr_header("? a\n").metadata == Dict("a" => nothing)
        @test read_fhr_header("a: \"x\\N\\_\\L\\Py\"\n").metadata["a"] == "x\u85\ua0\u2028\u2029y"
        @test read_fhr_header("a: \"\\/\\e\\ \\\"\"\n").metadata["a"] == "/\e \""
        @test unescape_double("x\\x3Ey\\N") == "x>y\u85"
        # block scalars keep relative indentation; an empty clipped block is ""
        @test read_fhr_header("a: |\n  l1\n   l2\n").metadata["a"] == "l1\n l2\n"
        @test read_fhr_header("a: >\n  f1\n  f2\n\n  f3\n   indented\n  back\n").metadata["a"] ==
              "f1 f2\nf3\n indented\nback\n"
        @test read_fhr_header("a: |\nb: 1\n").metadata == Dict("a" => "", "b" => 1)
        @test read_fhr_header("a: |-\n").metadata["a"] == ""
        @test read_fhr_header("a: |+\n  t\n\nb: 1\n").metadata["a"] == "t\n\n"
        @test read_fhr_header("a: |2\n   two\n").metadata["a"] == " two\n"
        @test read_fhr_header("\ufeffa: 1\n").metadata == Dict("a" => 1)        # BOM opening the YAML
    end
    @testset "limits: 64 levels, 20,000 nodes, never a stack overflow" begin
        nest(d) = "a: " * "["^d * "]"^d * "\n"
        @test read_fhr_header(nest(63)).metadata["a"] isa Vector   # 64 levels with the root mapping
        @test_throws HeaderError read_fhr_header(nest(64))
        e = try read_fhr_header("a: " * "["^500_000 * "\n"); nothing catch err; err end
        @test e isa HeaderError && e.rule == "limits"
        blocks = join([" "^i * "k:" for i in 0:199], "\n") * " 1\n"
        e = try read_fhr_header(blocks); nothing catch err; err end
        @test e isa HeaderError && e.rule == "limits"
        @test length(read_fhr_header("a: [" * join(fill("1", 19_997), ", ") * "]\n").metadata["a"]) == 19_997
        @test_throws HeaderError read_fhr_header("a: [" * join(fill("1", 19_998), ", ") * "]\n")
    end
    @testset "R11 raw > or @ warns but stays valid" begin
        text, _ = build_file(["description: \"a > b\""], ">ctg1\nACGT\n")
        h = read_fhr_file(Vector{UInt8}(text), "fasta")
        @test any(occursin("R11", w) for w in h.warnings)
    end
end

@testset "contracts (V1-V6, R14, format assertions)" begin
    @testset "selection" begin
        @test select_contract("https://w3id.org/fair-bioheaders/fhr/v0.6.0")[1:2] == ("FHR", "v0.6.0")
        @test select_contract("https://raw.githubusercontent.com/FAIR-bioHeaders/" *
                              "FAIR-bioHeaders-Specification/main/fhp.json")[1:2] == ("FHP", "main")
        @test select_contract("not a citation")[1:2] == ("FHR", "main")       # V5 fallback
        @test_throws UnsupportedContract select_contract("https://w3id.org/fair-bioheaders/fhr/v0.2.0")
        @test_throws UnsupportedContract select_contract("https://w3id.org/fair-bioheaders/fhgff3/v0.3.0")
        # V7, lane CLOSED (the default): FHT and FHGM citations fall to V5 exactly as
        # any other value - the outcome this repository produced before the lane
        # existed - and no draft appears in the released bundle or registry. The
        # drafts live separately under drafts/ and are read only by explicit opt-in
        # (see the "draft lane" testset).
        @test select_contract("https://w3id.org/fair-bioheaders/fht/v0.7.0")[1:2] == ("FHR", "main")
        reg = bundled_contracts()
        @test !any(haskey(get(reg["files"], rel, Dict()), "FHT") for rel in keys(reg["files"]))
        @test !any(occursin.("fht", readdir(joinpath(@__DIR__, "..", "schemas"); join = true)))
        # V6: the number 1 with a raw-main fhr.json citation selects the bundled v0.3.1
        type, ref, path = select_contract("https://raw.githubusercontent.com/FAIR-bioHeaders/" *
                                          "FHR-Specification/main/fhr.json", 1)
        @test (type, ref) == ("FHR", "v0.3.1")
        @test occursin("v0.3.1", path)
        @test select_contract("https://raw.githubusercontent.com/FAIR-bioHeaders/" *
                              "FHR-Specification/main/fhr.json", "1")[2] == "main"  # string "1" is not the number 1
    end

    @testset "baselines conform" begin
        @test validate_record(base_record()) == String[]
        @test validate_record(fhp_record()) == String[]
        @test validate_record(fhg_record()) == String[]
    end

    @testset "version-gated conditionals fire (draft/2020-12 if/then)" begin
        r20 = base_record(); r20["schemaVersion"] = "2.0"; r20["x-note"] = "kept"
        @test !isempty(validate_record(r20))                 # 2.0 forbids x- keys
        r20c = base_record(); r20c["schemaVersion"] = "2.0"
        @test validate_record(r20c) == String[]              # control: 2.0 without x- is fine
        r21 = base_record(); r21["x-note"] = "kept"
        @test validate_record(r21) == String[]               # 2.1 allows x- keys

        comp = Dict{String, Any}("lineageDataset" => "diptera_odb12.2", "completeDuplicated" => 10,
                                 "completeSingle" => 80, "fragmented" => 5, "missing" => 5, "total" => 100)
        p11 = fhp_record(); p11["schemaVersion"] = "1.1"; p11["completeness"] = comp
        f = validate_record(p11)
        @test !isempty(f) && any(occursin("lineageDataset", m) for m in f)   # 1.1 forbids dotted
        p11c = deepcopy(p11); p11c["completeness"]["lineageDataset"] = "diptera_odb12"
        @test validate_record(p11c) == String[]                               # undotted at 1.1 is fine
        p12 = fhp_record(); p12["completeness"] = comp
        @test validate_record(p12) == String[]                                # 1.2 allows dotted
        p10 = fhp_record(); p10["schemaVersion"] = "1.0"; p10["x-note"] = "k"
        @test !isempty(validate_record(p10))                                  # 1.0 forbids x- keys
    end

    @testset "format assertions bind (assert_format = true)" begin
        d = base_record(); d["dateCreated"] = "2026-13-45"
        @test !isempty(validate_record(d))
        u = base_record(); u["relatedLink"] = Any["not a uri"]
        @test !isempty(validate_record(u))
        ok = base_record(); ok["relatedLink"] = Any["https://example.org/a"]
        @test validate_record(ok) == String[]
    end

    @testset "R14 scheme warnings" begin
        w = link_scheme_warnings(Dict{String, Any}("relatedLink" => Any["javascript:alert(1)"]))
        @test length(w) == 1
        @test isempty(link_scheme_warnings(Dict{String, Any}("relatedLink" => Any["https://x.example"])))
        # Each expectation is the reference toolkit's own output for the same record.
        tail = "; links should use http or https (accepted: http, https, ftp, urn, doi, info; docs/FORMAT.md R14)"
        rec(extra) = merge(Dict{String, Any}("schema" => "https://w3id.org/fair-bioheaders/fhr/v0.6.0",
                                              "schemaVersion" => "2.1"), Dict{String, Any}(extra))
        for (extra, want) in [
                ("relatedLink" => Any["HTTPS://example.org"], String[]),                # case-insensitive
                ("relatedLink" => Any["DOI:10.1/x"], String[]),
                ("relatedLink" => Any["ftp://h/x", "urn:x:y"], String[]),
                ("relatedLink" => Any["http://"], ["relatedLink[0] is not an absolute http URL" * tail]),
                ("relatedLink" => Any["http:///x"], ["relatedLink[0] is not an absolute http URL" * tail]),
                ("relatedLink" => Any["https://a b"], ["relatedLink[0] is not an absolute URI" * tail]),
                ("relatedLink" => Any["https://a\u202eb"], ["relatedLink[0] is not an absolute URI" * tail]),
                ("relatedLink" => Any["https://a\x01b"], ["relatedLink[0] is not an absolute URI" * tail]),
                ("relatedLink" => Any["https://a\u00a0b"], ["relatedLink[0] is not an absolute URI" * tail]),
                ("relatedLink" => Any["https://a\u2028b"], ["relatedLink[0] is not an absolute URI" * tail]),
                ("relatedLink" => Any["javascript:alert(1)"], ["relatedLink[0] uses the URI scheme 'javascript'" * tail]),
                ("taxon" => Dict{String, Any}("name" => "H", "uri" => "file:///etc"),
                 ["taxon.uri uses the URI scheme 'file'" * tail]),
                ("assemblyProtocol" => "protocols/a.md", ["assemblyProtocol is not an absolute URI" * tail]),
                ("x-link" => "javascript:alert(1)", String[]),                          # x- values are not links
                ("x-o" => Dict{String, Any}("uri" => "javascript:1"), String[]),
                ("schema" => "https://w3id.org/fair-bioheaders/fhr/v0.2.0", String[])]   # V4: nothing checked
            @test link_scheme_warnings(rec([extra])) == want
        end
    end
end

@testset "conformance runner checks" begin
    je = FAIRBioHeaders.json_equal
    @test !je(1, true) && !je(true, 1) && !je(0, false) && je(true, true) && je(1, 1.0)
    @test je(Dict("a" => 1), Dict("a" => 1))
    @test !je(Dict("a" => 1, "b" => 2), Dict("a" => 1))           # an extra key is a difference
    @test !je(Dict("a" => 1), Dict("a" => 1, "b" => 2))
    r(errors) = (errors = errors, warnings = String[], not_checked = String[], ok = false)
    @test FAIRBioHeaders.breaks_rule(r(["R8: line 3: duplicate mapping key \"a\""]), "R8")
    @test !FAIRBioHeaders.breaks_rule(r(["R8: line 3: duplicate mapping key \"a\""]), "R12")
    @test FAIRBioHeaders.breaks_rule(r(["no root-level checksum line (rule R2)"]), "R2")
    @test FAIRBioHeaders.breaks_rule(r(["FHR v0.6.0 (fhr.json): The value was expected to match at /x"]), "R15")
    @test !FAIRBioHeaders.breaks_rule(r(["R12: line 1: syntax"]), "R15")   # a contract rule needs a contract finding
    @test FAIRBioHeaders.breaks_rule(r(["the stated checksum does not match the bytes it covers (rule R3): x"]), "R1")
    @test !FAIRBioHeaders.breaks_rule(r(["R1 is not R10"]), "R10")
    # a vector rejected for some other reason does not pass
    dir = mktempdir()
    mkpath(joinpath(dir, "invalid")); mkpath(joinpath(dir, "valid"))
    text, _ = build_file(["genome: a", "genome: b"], ">c\nA\n")
    write(joinpath(dir, "invalid", "dup.fhr.fasta"), text)
    v = Dict{String, Any}("id" => "dup", "file" => "invalid/dup.fhr.fasta", "format" => "fasta",
                          "expected" => "invalid", "rule" => "R12")
    @test !FAIRBioHeaders.run_vector(dir, v).passed
    v["rule"] = "R8"
    @test FAIRBioHeaders.run_vector(dir, v).passed
    # a valid vector that lists an R14 warning needs one
    text, digest = build_file(record_meta(merge(base_record(), Dict{String, Any}("relatedLink" => Any["javascript:x"]))), ">c\nA\n")
    write(joinpath(dir, "valid", "w.fhr.fasta"), text)
    w = Dict{String, Any}("id" => "w", "file" => "valid/w.fhr.fasta", "format" => "fasta", "expected" => "valid",
                          "checksum" => digest, "warnings" => ["R14"])
    @test FAIRBioHeaders.run_vector(dir, w).passed
    text, digest = build_file(record_meta(base_record()), ">c\nA\n")
    write(joinpath(dir, "valid", "w.fhr.fasta"), text)
    w["checksum"] = digest
    o = FAIRBioHeaders.run_vector(dir, w)
    @test !o.passed && occursin("no R14 warning", o.detail)
end

@testset "bundled schema audit (native)" begin
    # The audit is the Julia counterpart of the old scripts/check_bundled_schemas.py
    # check, which now runs only in the supplemental differential job: the primary
    # acceptance path must not need Python to prove its own bundle is sound.
    findings = audit_bundled_schemas()
    STATE["schemaAuditFindings"] = length(findings)
    for f in findings; println("audit: ", f); end
    @test isempty(findings)

    # The negative control: an audit that always returns nothing is no guard. Work on
    # a throwaway copy of schemas/ and make the audit report each defect class.
    src = normpath(joinpath(@__DIR__, "..", "schemas"))
    tmp = mktempdir()
    dst = joinpath(tmp, "schemas")
    cp(src, dst)
    p = joinpath(dst, "current", "fhr.json")
    write(p, read(p, String) * " ")                      # byte drift, still parseable
    write(joinpath(dst, "stray.json"), "{}\n")           # JSON not in provenance.json
    reg = JSON.parsefile(joinpath(dst, "registry.json"))
    reg["files"]["v0.6.0"]["FHT"] = "v0.6.0/fhr.json"    # a draft taking a release form
    write(joinpath(dst, "registry.json"), JSON.json(reg))
    rm(joinpath(dst, "v0.3.0", "fhr.json"))              # a listed file that is gone
    fs = audit_bundled_schemas(dst)
    @test any(occursin("current/fhr.json: sha256", f) for f in fs)
    @test any(occursin("stray.json", f) for f in fs)
    @test any(occursin("V7 violation: draft type row under v0.6.0", f) for f in fs)
    @test any(occursin("v0.3.0/fhr.json", f) && occursin("missing", f) for f in fs)
    rm(tmp; recursive = true)
end

@testset "draft lane (V7, opt-in)" begin
    # Everything the lane touches, without the network: the registry is read and
    # ENFORCED here (a pin nothing consumes is documentation, not a control), the
    # default path is re-proved unchanged, and each guard is shown capable of
    # failing. The draft SUITES are not run here - they run only in the separate,
    # labelled CI job through scripts/draft_vectors.jl and never join the 291.
    FHT_CITATION = "https://raw.githubusercontent.com/FAIR-bioHeaders/FHT-Specification/main/fht.json"
    FHGM_CITATION = "https://raw.githubusercontent.com/FAIR-bioHeaders/FHGM-Specification/" *
                    "main/development/model/fhgm-model.schema.json"

    @testset "pinned bytes are consumed, not just recorded" begin
        # The code-side audit of drafts/provenance.json: every vendored file must
        # digest to its recorded sha256, this run, or the whole suite fails.
        findings = verify_draft_bytes()
        STATE["draftPinFindings"] = length(findings)
        for f in findings; println("draft audit: ", f); end
        @test isempty(findings)

        # The negative control: the guard above must be able to fail. Work on a
        # throwaway copy of drafts/.
        tmp = mktempdir()
        dst = joinpath(tmp, "drafts")
        cp(normpath(joinpath(@__DIR__, "..", "drafts")), dst)
        p = joinpath(dst, "fht-draft.json")
        write(p, read(p, String) * " ")                 # one trailing byte
        @test !cmp_similar(p, joinpath(@__DIR__, "..", "drafts", "fht-draft.json"))  # mutation is real
        fs = verify_draft_bytes(dst)
        @test any(occursin("FHT", f) && occursin("sha256", f) for f in fs)
        # load_draft must REFUSE the tampered bytes, not compile them.
        @test_throws HeaderError load_draft("FHT"; dir = dst)
        rm(joinpath(dst, "fhgm-transport-draft.json"))
        fs2 = verify_draft_bytes(dst)
        @test any(occursin("missing", f) for f in fs2)
        # a draft acquiring a release shape in the registry is a V7 violation finding
        prov = JSON.parsefile(joinpath(dst, "provenance.json"))
        prov["drafts"]["FHT"]["w3id"] = "https://w3id.org/fair-bioheaders/fht/v0.7.0"
        write(joinpath(dst, "provenance.json"), JSON.json(prov))
        cp(normpath(joinpath(@__DIR__, "..", "drafts", "fht-draft.json")), joinpath(dst, "fht-draft.json"); force = true)
        fs3 = verify_draft_bytes(dst)
        @test any(occursin("V7 violation", f) && occursin("w3id", f) for f in fs3)
        rm(tmp; recursive = true)
    end

    @testset "the default path is unchanged (lane off)" begin
        # A draft citation with the lane closed is "any other value" under V5: the
        # exact tuples this repository returned before the lane existed.
        @test select_contract(FHT_CITATION)[1:2] == ("FHR", "main")
        @test select_contract("https://w3id.org/fair-bioheaders/fht/v0.7.0")[1:2] == ("FHR", "main")
        @test select_contract(FHGM_CITATION)[1:2] == ("FHR", "main")
        @test draft_lane_of(FHT_CITATION; drafts = false) === nothing
        # the shared ledger knows nothing of the drafts
        @test !("fht-fasta" in runnable_formats())
        @test !("C1" in implemented_rules()) && !("K2" in implemented_rules())
    end

    @testset "lane on: selection, warning, and no release form" begin
        type, ref, path = select_contract(FHT_CITATION, nothing; drafts = true)
        @test (type, ref) == ("FHT", "draft")
        @test occursin("drafts", path)
        # Release-form citations stay V5 even with the lane open: the lane grants
        # recognition of pinned bytes, never a release shape.
        @test select_contract("https://w3id.org/fair-bioheaders/fht/v0.7.0", nothing; drafts = true)[1:2] == ("FHR", "main")
        @test select_contract("https://raw.githubusercontent.com/FAIR-bioHeaders/FHT-Specification/v0.7.0/fht.json",
                              nothing; drafts = true)[1:2] == ("FHR", "main")
        # FHGM is not a header type: its citation never selects a file contract.
        @test select_contract(FHGM_CITATION, nothing; drafts = true)[1:2] == ("FHR", "main")
        e = draft_entry("FHT")
        @test e.release_tag === nothing && e.w3id === nothing && e.registry_row === nothing
        w = draft_warning(e)
        @test occursin("unreleased draft", w) && occursin(e.commit, w) && occursin(e.sha256, w)
    end

    @testset "lane file reading (synthetic FHT record)" begin
        meta = ["schema: $FHT_CITATION", "schemaVersion: '1.0'",
                "transcriptome: Synthetic test transcriptome", "assemblyType: de novo",
                "taxon:", "  name: Homo sapiens", "version: 1.0.0",
                "metadataAuthor:", "- name: Test metadata author", "dateCreated: '2026-01-01'"]
        text, _ = build_file(meta, ">tr1\nACGU\n")
        path = tempname() * ".fht.fasta"
        write(path, text)
        r_off = verify_file(path)                       # default: the pre-lane outcome
        @test !r_off.ok
        @test !any(occursin("unreleased draft", w) for w in r_off.warnings)
        r_on = verify_file(path; drafts = true)         # lane: read against the pinned bytes
        @test r_on.ok
        @test any(occursin("unreleased draft", w) && occursin("FHT", w) for w in r_on.warnings)
        @test r_on.computed == r_off.computed           # the byte layer did not move
        # a record that violates the DRAFT contract is rejected through the lane:
        # the pinned fht.json admits schemaVersion "1.0" only.
        md2 = deepcopy(r_on.metadata); md2["schemaVersion"] = "2.0"
        @test !isempty(validate_record(md2; drafts = true))
        @test isempty(validate_record(r_on.metadata; drafts = true))
        rm(path)
    end

    @testset "suite pin enforced by the runner's guard" begin
        # The real registry states complete suite pins for both drafts.
        for t in draft_types()
            pin = draft_suite_pin(t)
            @test pin.stated && !pin.partial
            @test occursin(r"\A[0-9a-f]{64}\z", pin.sha256)
            @test occursin(r"\A[0-9a-f]{40}\z", pin.commit)
        end
        @test draft_suite_pin("FHT").vectors == 82 && draft_suite_pin("FHGM").vectors == 62
        # The guard, exercised both ways on synthetic pins and manifests: verified,
        # drift on one byte (byte-verified mutation), missing manifest, escaping path.
        good = (type = "CTRL", repository = "x", stated = true, partial = false,
                commit = "0"^40, manifest = "conformance/manifest.json",
                sha256 = "", bytes = nothing, vectors = 1, rules = nothing)
        tmp = mktempdir()
        mkdir(joinpath(tmp, "conformance"))
        mpath = joinpath(tmp, "conformance", "manifest.json")
        write(mpath, JSON.json(Dict("vectors" => Any[Dict("id" => "a")])))
        good = (good..., sha256 = FAIRBioHeaders.sha256_hex(read(mpath)))
        @test FAIRBioHeaders.check_suite_against(good, tmp).state == "verified"
        moved = read(mpath, String) * "x"
        @test moved != read(mpath, String)              # the control is not a no-op
        write(mpath, moved)
        res = FAIRBioHeaders.check_suite_against(good, tmp)
        @test res.state == "drift"
        rm(mpath)
        @test FAIRBioHeaders.check_suite_against(good, tmp).state == "absent"
        escaping = (good..., manifest = "../outside/manifest.json")
        @test FAIRBioHeaders.check_suite_against(escaping, tmp).state == "absent"
        partial = (type = "CTRL", repository = "x", stated = false, partial = true,
                   commit = "0"^40, manifest = "conformance/manifest.json", sha256 = nothing,
                   bytes = nothing, vectors = nothing, rules = nothing)
        @test FAIRBioHeaders.check_suite_against(partial, tmp).state == "partial"
        unpinned = (type = "CTRL", repository = "x", stated = false, partial = false,
                    commit = nothing, manifest = nothing, sha256 = nothing, bytes = nothing,
                    vectors = nothing, rules = nothing)
        @test FAIRBioHeaders.check_suite_against(unpinned, tmp).state == "unpinned"
        # count drift: digest matches, the recorded vector count does not
        write(mpath, JSON.json(Dict("vectors" => Any[Dict("id" => "a"), Dict("id" => "b")])))
        many = (good..., sha256 = FAIRBioHeaders.sha256_hex(read(mpath)))
        @test FAIRBioHeaders.check_suite_against(many, tmp).state == "drift"
        rm(tmp; recursive = true)
        # contract-pin check on the real vendored bytes vs a synthetic checkout
        tmp2 = mktempdir()
        mkpath(joinpath(tmp2, "development", "model"))
        e = draft_entry("FHGM")
        cp(e.path, joinpath(tmp2, e.source_path))
        cp(e.overlay.path, joinpath(tmp2, e.overlay.source_path))
        @test check_contract_pin("FHGM", tmp2).state == "verified"
        bad_path = joinpath(tmp2, e.source_path)
        write(bad_path, read(bad_path, String) * " ")
        @test !cmp_similar(bad_path, e.path)
        @test check_contract_pin("FHGM", tmp2).state == "drift"
        rm(tmp2; recursive = true)
    end

    @testset "FHGM model-level checks (draft lane only)" begin
        base = Dict{String, Any}(
            "schema" => "https://w3id.org/fair-bioheaders/fhgff3/v0.5.0", "schemaVersion" => "1.1",
            "annotation" => "Synthetic", "taxon" => Dict("name" => "Drosophila melanogaster"),
            "version" => "1.0.0", "metadataAuthor" => Any[Dict("name" => "A Tester")],
            "dateCreated" => "2026-01-01", "checksum" => HELPER_B64,
            "genomeReference" => Dict("accession" => "SYNTH.1", "seqcol_id" => "S"^32),
            "x-fhgm-models" => Any[Dict("modelId" => "model-1", "modelVersion" => "v1",
                                        "featureId" => "FBgn0000001",
                                        "reference" => Dict("genomeReference" =>
                                            Dict("accession" => "SYNTH.1", "seqcol_id" => "S"^32)))])
        v = check_fhgm_models(base)
        @test v.status == "checked" && v.valid
        @test any(occursin("unreleased draft", w) for w in v.warnings)
        @test v.rules["K4"] == "not-supported-yet"
        @test v.contract["commit"] == draft_entry("FHGM").commit
        dup = deepcopy(base); push!(dup["x-fhgm-models"], deepcopy(base["x-fhgm-models"][1]))
        v2 = check_fhgm_models(dup)
        @test !v2.valid && v2.rules["K3"] == "reject" && any(occursin("Ambiguous model ID", e2) for e2 in v2.errors)
        nfc = deepcopy(base)
        nfc["x-fhgm-models"][1]["modelId"] = "model-café"
        twin = deepcopy(nfc["x-fhgm-models"][1]); twin["modelId"] = "model-cafe\u0301"
        push!(nfc["x-fhgm-models"], twin)
        @test check_fhgm_models(nfc).rules["K3"] == "reject"
        invalid_duplicate = deepcopy(nfc)
        invalid_duplicate["x-fhgm-models"][2]["modelVersion"] = 4
        invalid_verdict = check_fhgm_models(invalid_duplicate)
        @test invalid_verdict.rules["K2"] == "reject"
        @test invalid_verdict.rules["K3"] == "skipped"
        @test check_fhgm_models(nfc).rules["K5"] == "skipped"
        distinct = deepcopy(nfc); distinct["x-fhgm-models"][2]["modelId"] = "model-Café"
        @test check_fhgm_models(distinct).valid
        compatibility = deepcopy(nfc); compatibility["x-fhgm-models"][1]["modelId"] = "model-1"
        compatibility["x-fhgm-models"][2]["modelId"] = "model-①"
        @test check_fhgm_models(compatibility).valid # NFC, not compatibility folding
        for bad_citation in ("https://raw.githubusercontent.com/FAIR-bioHeaders/FAIR-bioHeaders-Specification/main/fhgff3.json",
                             "https://w3id.org/fair-bioheaders/fhgff3/v9.9.9", nothing,
                             "https://w3id.org/fair-bioheaders/fhr/v0.6.0")
            bad = deepcopy(base); bad["schema"] = bad_citation
            @test check_fhgm_models(bad).rules["K1"] == "reject"
        end
        for branch in load_draft("FHGM", "overlay")["anyOf"], citation in branch["properties"]["schema"]["enum"]
            allowed = deepcopy(base); allowed["schema"] = citation
            @test check_fhgm_models(allowed).rules["K1"] == "pass"
        end
        conflict = deepcopy(base)
        conflict["x-fhgm-models"][1]["reference"] = Dict("genomeReference" => Dict("accession" => "OTHER.1", "seqcol_id" => "T"^32))
        v3 = check_fhgm_models(conflict)
        @test v3.rules["K5"] == "reject" && any(occursin("contradicts", e3) for e3 in v3.errors)
        nocmp = deepcopy(base)
        nocmp["x-fhgm-models"][1]["reference"] = Dict("annotates" => "B"^43 * "=")
        @test check_fhgm_models(nocmp).rules["K5"] == "reject"
        empty = deepcopy(base); empty["x-fhgm-models"] = Any[]
        ve = check_fhgm_models(empty)
        @test !ve.valid && ve.rules["K1"] == "reject"
        for malformed in (nothing, 3, "record", Any[], Any[nothing], Any[3], Any[Any[]])
            bad = deepcopy(base); bad["x-fhgm-models"] = malformed
            if malformed === nothing
                @test check_fhgm_models(bad).status == "absent"
            else
                @test check_fhgm_models(bad).rules["K1"] == "reject"
            end
        end
        no_models = deepcopy(base); delete!(no_models, "x-fhgm-models")
        no_models["schema"] = "not a carrier"
        @test check_fhgm_models(no_models).status == "absent"
        @test isempty(check_fhgm_models(no_models).errors)
        v10 = deepcopy(base); v10["schemaVersion"] = "1.0"
        @test check_fhgm_models(v10).rules["K1"] == "reject"
        @test check_fhgm_models(base; base_ok = false).status == "not-checked"
        # The R15 reading and the pinned overlay differ exactly as the registry says.
        # Re-pinned 2026-11-15, the overlay admits EITHER released FHGFF3 identity as a
        # CLOSED citation/version pair (v0.5.0 with "1.1", v0.6.0 with "1.2"); what it
        # newly refuses - and R15 alone does not - is a header whose citation and stated
        # version contradict each other.
        v12 = deepcopy(base); v12["schema"] = "https://w3id.org/fair-bioheaders/fhgff3/v0.6.0"; v12["schemaVersion"] = "1.2"
        @test check_fhgm_models(v12).rules["K1"] == "pass"
        @test check_fhgm_models(v12; overlay = true).rules["K1"] == "pass"   # consistent 0.6.0/1.2 pair: admissible since the 2026-11-15 overlay
        @test check_fhgm_models(base; overlay = true).rules["K1"] == "pass"  # consistent 0.5.0/1.1 pair (base cites v0.5.0 with schemaVersion 1.1)
        mixed = deepcopy(base); mixed["schemaVersion"] = "1.2"               # v0.5.0 citation claiming 1.2
        @test check_fhgm_models(mixed).rules["K1"] == "pass"                 # R15 alone admits it (1.2 >= 1.1)
        @test check_fhgm_models(mixed; overlay = true).rules["K1"] == "reject"
        mixed2 = deepcopy(v12); mixed2["schemaVersion"] = "1.1"              # v0.6.0 citation claiming 1.1
        @test check_fhgm_models(mixed2; overlay = true).rules["K1"] == "pass" # cited v0.6.0 admits1.1 per the owning draft
        # K6 against a supplied predecessor: resolvable, and unresolvable when withheld
        prior = deepcopy(base); prior["checksum"] = "C"^42 * "A="
        rev = deepcopy(base)
        rev["x-fhgm-models"][1]["modelVersion"] = "v2"
        rev["x-fhgm-models"][1]["predecessor"] = Dict("annotationChecksum" => prior["checksum"],
                                                      "modelId" => "model-1", "modelVersion" => "v1")
        @test check_fhgm_models(rev).rules["K6"] == "reject"          # history withheld
        vk6 = check_fhgm_models(rev; predecessors = Any[(checksum = prior["checksum"], header = prior)])
        @test vk6.valid && vk6.rules["K6"] == "resolvable"
        @test vk6.records[1]["predecessor"]["verdict"] == "resolvable"
        # the verdict block never joins the released result: separate by construction
        cov = fhgm_rule_coverage()
        @test "K4" in keys(cov["notSupported"]) && length(cov["implemented"]) == 6
    end
end

@testset "shared conformance vectors (v0.6.0, 291 vectors)" begin
    env = get(ENV, "FAIRBIOHEADERS_CONFORMANCE", "")
    candidates = [env, joinpath(@__DIR__, "conformance")]
    suite = ""
    for c in candidates
        !isempty(c) && isfile(joinpath(c, "manifest.json")) && (suite = c; break)
    end
    if isempty(suite) && !isempty(env)
        # A named fixture that is not there is an error, never a skip: CI always
        # names the suite, so a missing checkout cannot pass unnoticed.
        error("FAIRBIOHEADERS_CONFORMANCE points at $(env) but no manifest.json is there: " *
              "the acceptance fixture (FAIR-bioHeaders-Specification at tag v0.6.0) is missing")
    elseif isempty(suite)
        STATE["conformanceSuiteUsed"] = "false"
        @test_skip "conformance suite not found: set FAIRBIOHEADERS_CONFORMANCE to a " *
                   "checkout of FAIR-bioHeaders-Specification at tag v0.6.0"
    else
        STATE["conformanceSuiteUsed"] = "true"
        outcomes = run_conformance(suite)
        per = summarise(outcomes)
        STATE["suiteVectors"] = length(outcomes)
        STATE["vectorsDecided"] = count(o -> o.decided, outcomes)
        STATE["vectorsPassed"] = sum(o -> o.decided && o.passed, outcomes)
        STATE["vectorsFailed"] = sum(o -> o.decided && !o.passed, outcomes)
        STATE["vectorsUndecided"] = count(o -> !o.decided, outcomes)
        STATE["compressedVectorsDecided"] = let m = JSON.parsefile(joinpath(suite, "manifest.json"))
            ids = [v["id"] for v in m["vectors"] if v["compressed"] === true || v["compressed"] == 1]
            count(o -> o.id in ids && o.decided, outcomes)
        end
        STATE["jsonldUndecided"] = per["jsonld"]["undecided"]
        STATE["microdataUndecided"] = per["microdata"]["undecided"]
        @test length(outcomes) == 291
        @test per["fasta"]["total"] == 98 && per["gfa"]["total"] == 56 &&
              per["fhp-fasta"]["total"] == 36 && per["fhgff3"]["total"] == 38 &&
              per["jsonld"]["total"] == 37 && per["microdata"]["total"] == 26
        fails = filter(o -> o.decided && !o.passed, outcomes)
        for f in fails; println(f); end
        @test isempty(fails)
        @test sum(d["fail"] for (_, d) in per) == 0
        @test count(o -> o.decided, outcomes) == 228     # 291 minus 37 jsonld and 26 microdata
        @test sum(d["pass"] for (_, d) in per) == 228
        # the 11 gzip/BGZF vectors are decided, not skipped (rule R1, decompressed input)
        compressed = [v["id"] for v in JSON.parsefile(joinpath(suite, "manifest.json"))["vectors"]
                      if v["compressed"] === true || v["compressed"] == 1]
        @test length(compressed) == 11
        undec = filter(o -> !o.decided, outcomes)
        @test !any(o.id in compressed for o in undec)
        # the undecided set is exactly the two named serialisation layers, by id count
        @test Set(o.format for o in undec) == Set(["jsonld", "microdata"])
        @info "conformance per format" per
    end
end

write_receipt(Test.get_testset())

end
