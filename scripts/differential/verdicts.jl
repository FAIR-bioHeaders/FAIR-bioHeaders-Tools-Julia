# Supplemental differential, NOT acceptance: compare this package's verdict on every file
# of a corpus with the reference toolkit's (`fhr-fasta-validate`, `fhr-gfa-validate`,
# `fhr-gff3-validate` from fair-bioheaders on PATH). Exits 1 on any disagreement.
#
#   julia --project=. scripts/differential/verdicts.jl SUITE_DIR [EXTRA_FILE_OR_DIR ...]
#
# SUITE_DIR is a conformance directory (manifest.json); its FASTA, GFA, FHP and FHGFF3
# vectors are compared. Extra paths add files whose kind is told by their name.
using FAIRBioHeaders, JSON

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
diff = 0
for (path, kind) in files
    jl = julia_verdict(path, kind)
    py, text = python_verdict(path, kind)
    if jl != py
        global diff += 1
        lines = filter(!isempty, split(strip(text), '\n'))
        println("DIFFERENT ", path, " [", kind, "]: julia ", jl, ", python ", py,
                isempty(lines) ? "" : " (" * first(last(lines), 160) * ")")
    end
end
println(length(files) - diff, " of ", length(files), " files: the same verdict as the reference toolkit")
exit(diff == 0 ? 0 : 1)
