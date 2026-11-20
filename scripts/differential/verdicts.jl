# Supplemental differential, NOT acceptance: compare this package's verdict on every file
# of a corpus with the reference toolkit's (`fhr-fasta-validate`, `fhr-gfa-validate`,
# `fhr-gff3-validate` from fair-bioheaders on PATH). Exits 1 on any disagreement.
#
#   julia --project=. scripts/differential/verdicts.jl SUITE_DIR [EXTRA_FILE_OR_DIR ...]
#
# SUITE_DIR is a conformance directory (manifest.json); its FASTA, GFA, FHP and FHGFF3
# vectors are compared. Extra paths add files whose kind is told by their name.
using FAIRBioHeaders, JSON, SHA

const PY = Dict("fasta" => "fhr-fasta-validate", "fhp-fasta" => "fhr-fasta-validate",
                "gfa" => "fhr-gfa-validate", "fhgff3" => "fhr-gff3-validate")

function julia_verdict(path, kind)
    r = verify_file(path; kind = kind)
    r.ok && return "valid"
    isempty(r.errors) && any(n -> occursin("unsupported schema version", n), r.not_checked) &&
        return "unsupported-version"
    return "invalid"
end

function python_verdict(path, kind)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(`$(PY[kind]) $path`); stdout = out, stderr = out))
    text = String(take!(out))
    p.exitcode == 0 && return "valid", text
    occursin("unsupported schema version", lowercase(text)) && return "unsupported-version", text
    return "invalid", text
end

files = Tuple{String, String}[]
suite = ARGS[1]
for v in JSON.parsefile(joinpath(suite, "manifest.json"))["vectors"]
    haskey(PY, v["format"]) && push!(files, (joinpath(suite, v["file"]), v["format"]))
end
for extra in ARGS[2:end]
    for p in (isdir(extra) ? [joinpath(r, f) for (r, _, fs) in walkdir(extra) for f in fs] : [extra])
        k = kind_of(p)
        k === nothing || push!(files, (p, k))
    end
end
# The oracle is intentionally frozen at toolkit0.12.0. D9 changes precisely
# these30 old positive parent cases. Bind exceptions to IDs AND immutable bytes,
# require Julia's exact R4 parent finding, and count them separately from agreement.
retired = JSON.parsefile(joinpath(@__DIR__, "..", "..", "references", "retirement-crosswalk.json"))["cases"]
positive_retirements = Dict(normpath(joinpath(suite,c["file"])) => c for c in retired if c["expected"] == "valid")
policy_deltas = 0
seen_policy = Set{String}()
diff = 0
for (path, kind) in files
    jl = julia_verdict(path, kind)
    py, text = python_verdict(path, kind)
    if haskey(positive_retirements,normpath(path))
        retired_case = positive_retirements[normpath(path)]
        bytes2hex(sha256(read(path))) == retired_case["oldSha256"] || error("historical policy bytes differ: " * retired_case["id"])
        result = verify_file(path; kind = kind)
        precise_r4 = !isempty(result.errors) && all(e -> startswith(e,"R4: /derivedFrom/") && occursin("canonical",e),result.errors)
        if jl == "invalid" && py == "valid" && precise_r4
            global policy_deltas += 1
            push!(seen_policy,retired_case["id"])
            println("EXPECTED D9-R4 ",retired_case["id"]," sha256=",retired_case["oldSha256"],": Julia invalid; frozen0.12.0 oracle valid")
            continue
        end
        println("MISSING expected D9-R4 delta for ",retired_case["id"],": julia=",jl,", python=",py)
        global diff += 1
        continue
    end
    if jl != py
        global diff += 1
        lines = filter(!isempty, split(strip(text), '\n'))
        println("DIFFERENT ", path, " [", kind, "]: julia ", jl, ", python ", py,
                isempty(lines) ? "" : " (" * first(last(lines), 160) * ")")
    end
end
println(length(files) - diff - policy_deltas, " of ", length(files), " files: same verdict; ",policy_deltas," explicit D9-R4 policy deltas; ",diff," unexplained differences")
length(seen_policy) == 30 || error("expected all30 named historical D9-R4 deltas, measured " * string(length(seen_policy)))
exit(diff == 0 ? 0 : 1)
