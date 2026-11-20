# MPL-2.0. Supplementary shared runtime corpus; separate from released 291.
using FAIRBioHeaders, JSON, SHA
length(ARGS) == 1 || error("name the exact reader-policy corpus directory")
root = realpath(ARGS[1])
manifest = JSON.parsefile(joinpath(root, "cases.json"))
length(manifest["cases"]) == 64 || error("unexpected corpus count")
probe = JSON.parsefile(joinpath(root,manifest["cases"][1]["file"]))
probe["x-probe"] = Dict("checksum" => "B"^43 * "=")
isempty(validate_record(probe)) || error("an arbitrary extension checksum must remain opaque")
failed = 0
for case in manifest["cases"]
    file = joinpath(root, case["file"])
    bytes2hex(sha256(read(file))) == case["sha256"] || error("corpus bytes differ: " * case["id"])
    valid = try
        if case["operation"] == "metadata"
            record = get(case, "serialization", "json") == "yaml" ?
                read_fhr_header(read(file, String)).metadata : JSON.parsefile(file)
            isempty(validate_record(record))
        else
            verify_file(file; kind = case["format"]).ok
        end
    catch e
        if e isa FAIRBioHeaders.HeaderError || e isa FAIRBioHeaders.UnsupportedContract
            false
        else
            rethrow()
        end
    end
    ok = valid == (case["expected"] == "valid")
    println(case["id"], ok ? " PASS" : " FAIL")
    global failed += !ok
end
println("reader-policy: compared=64 failed=$(failed) not-run=0")
failed == 0 || exit(1)

carriers = run_conformance(dirname(root))
ran = count(r -> r.decided, carriers)
bad = count(r -> r.decided && !r.passed, carriers)
not_run = count(r -> !r.decided, carriers)
println("current carriers: compared=$(ran) failed=$(bad) not-run=$(not_run) (JSON-LD/microdata unsupported)")
for result in carriers
    result.decided && !result.passed && println(result)
end
ran == 254 && bad == 0 && not_run == 65 || exit(1)
