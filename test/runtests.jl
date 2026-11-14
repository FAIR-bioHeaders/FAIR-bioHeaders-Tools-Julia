# FAIRBioHeaders.jl test suite.
#
# Layer 1 is self-contained: the byte rules (R1-R7, R10, G1), the header reader
# (R8, R11, R12, R13), contract selection (V1-V6), format assertions and the R14
# scheme warnings, on records and files built inside the test.
#
# Layer 2 is the acceptance gate: the 291 shared conformance vectors of
# FAIR-bioHeaders-Specification release v0.6.0 (conformance/manifest.json).
# The suite is NOT vendored here; it is located through the environment variable
# FAIRBIOHEADERS_CONFORMANCE (a checkout of FAIR-bioHeaders-Specification at tag
# v0.6.0) or a test/conformance directory, and skipped with a stated reason when
# absent. CI provides the released tag, never main.

using FAIRBioHeaders
using SHA
using Base64
using JSON
using CodecZlib
using Test

# 32 zero bytes in canonical padded base64: a shape-valid checksum value.
const HELPER_B64 = "A"^42 * "A="

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
        # V7: FHT and FHGM are drafts with no released contract. A citation of either
        # falls to V5 exactly as any other value, and no draft schema is bundled.
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
    end
end

@testset "shared conformance vectors (v0.6.0, 291 vectors)" begin
    candidates = [get(ENV, "FAIRBIOHEADERS_CONFORMANCE", ""), joinpath(@__DIR__, "conformance")]
    suite = ""
    for c in candidates
        !isempty(c) && isfile(joinpath(c, "manifest.json")) && (suite = c; break)
    end
    if isempty(suite)
        @test_skip "conformance suite not found: set FAIRBIOHEADERS_CONFORMANCE to a " *
                   "checkout of FAIR-bioHeaders-Specification at tag v0.6.0"
    else
        outcomes = run_conformance(suite)
        per = summarise(outcomes)
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
                      if v["compressed"] === true || isone(v["compressed"])]
        @test length(compressed) == 11
        undec = filter(o -> !o.decided, outcomes)
        @test !any(o.id in compressed for o in undec)
        @info "conformance per format" per
    end
end
