# The shared conformance vectors as the acceptance test.
#
# Reads FAIR-bioHeaders-Specification `conformance/manifest.json` and applies the
# protocol its README states: for a valid vector, accept the file, compute its checksum
# and read the pinned metadata values; for an invalid vector, reject it. Nothing here
# invents a second suite. See docs/CONFORMANCE.md for what this pass could and could not
# decide.
using JSON

const FORMAT_KIND = Dict("fasta" => "fasta", "gfa" => "gfa", "fhp-fasta" => "fhp-fasta",
                         "fhgff3" => "fhgff3")

"Formats this runner can decide: the four sequence formats. JSON-LD and microdata need a
JSON-LD processor and an HTML microdata extractor, which this package does not implement."
runnable_formats() = collect(keys(FORMAT_KIND))

struct VectorOutcome
    id::String
    format::String
    expected::String
    decided::Bool          # false when this implementation has no layer for the rule
    passed::Bool
    detail::String
end

function Base.show(io::IO, o::VectorOutcome)
    print(io, o.decided ? (o.passed ? "PASS " : "FAIL ") : "SKIP ", o.id, " [", o.format,
          "] expected ", o.expected, isempty(o.detail) ? "" : ": ", o.detail)
end

"""
    run_conformance(suite; formats = runnable_formats(), only_compressed = false)

Run the manifest's vectors from `suite` (a directory holding `manifest.json`, `valid/` and
`invalid/`). Returns one `VectorOutcome` per vector. Compressed vectors are skipped with a
reason: this package does not yet decompress gzip or BGZF in Julia, and rule R1 hashes the
decompressed bytes.
"""
function run_conformance(suite::AbstractString; formats = runnable_formats())
    manifest = JSON.parsefile(joinpath(suite, "manifest.json"))
    outcomes = VectorOutcome[]
    for v in manifest["vectors"]
        fmt = v["format"]
        if !(fmt in formats)
            push!(outcomes, VectorOutcome(v["id"], fmt, v["expected"], false, false,
                                          "format $(fmt) is outside this runner"))
            continue
        end
        if isone(v["compressed"]) || v["compressed"] === true
            push!(outcomes, VectorOutcome(v["id"], fmt, v["expected"], false, false,
                                          "compressed input: no gzip/BGZF reader in this package yet (rule R1)"))
            continue
        end
        push!(outcomes, run_vector(suite, v))
    end
    return outcomes
end

function run_vector(suite::AbstractString, v::AbstractDict)
    path = joinpath(suite, v["file"])
    kind = FORMAT_KIND[v["format"]]
    rule = get(v, "rule", nothing)
    result = verify_file(path; kind = kind)
    if v["expected"] == "valid"
        detail = String[]
        result.ok || push!(detail, join(result.errors, "; "))
        if !isnothing(v["checksum"]) && something(result.computed, "") != v["checksum"]
            push!(detail, "checksum $(something(result.computed, "none")) != manifest $(v["checksum"])")
        end
        md = something(result.metadata, Dict{String, Any}())
        for (k, want) in get(v, "metadata", Dict{String, Any}())
            have = get(md, String(k), :absent)
            have === :absent && (push!(detail, "metadata.$(k) missing"); continue)
            json_equal(have, want) || push!(detail, "metadata.$(k): got $(JSON.json(have)) want $(JSON.json(want))")
        end
        return VectorOutcome(v["id"], v["format"], "valid", true, isempty(detail), join(detail, "; "))
    end
    # Invalid: reject it, or report the rule as outside the implemented layers.
    if rule !== nothing && !(rule in implemented_rules())
        return VectorOutcome(v["id"], v["format"], "invalid", false, false,
                             "rule $(rule) is outside the implemented layers")
    end
    if something(result.not_checked, String[]) |> !isempty
        # V4: "unsupported-version" is the required outcome for those vectors.
        want = get(v, "result", nothing)
        if want === "unsupported-version"
            return VectorOutcome(v["id"], v["format"], "invalid", true, true, "unsupported-version")
        end
        return VectorOutcome(v["id"], v["format"], "invalid", true, false,
                             "not checked: " * join(result.not_checked, "; "))
    end
    return VectorOutcome(v["id"], v["format"], "invalid", true, !result.ok,
                         result.ok ? "accepted, but the file breaks rule $(rule)" : join(first.(result.errors), "; "))
end

"The FORMAT.md and per-type rules this implementation can decide. Anything else is
reported as undecided rather than passed."
implemented_rules() = Set(["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R10", "R11", "R12", "R13",
                           "R15", "P1", "P2", "G1", "G2", "G3", "V1", "V2", "V3", "V4", "V5", "V6"])

"JSON equality as the vectors define it: numbers compare by value, types never convert."
function json_equal(have, want)
    if want isa Real
        return have isa Real && Float64(have) == Float64(want)
    elseif want isa AbstractString
        return have isa AbstractString && String(have) == String(want)
    elseif want isa Bool
        return have isa Bool && have == want
    elseif want === nothing
        return have === nothing
    elseif want isa AbstractVector
        have isa AbstractVector && length(have) == length(want) || return false
        return all(json_equal(h, w) for (h, w) in zip(have, want))
    elseif want isa AbstractDict
        have isa AbstractDict || return false
        all(haskey(have, String(k)) for k in keys(want)) || return false
        all(string(k) in string.(keys(have)) for k in keys(have)) || return false
        return all(json_equal(get(have, String(k), nothing), w) for (k, w) in want)
    end
    return have == want
end

"""
    summarise(outcomes) -> Dict{String, Dict{String, Int}}

Per-format pass / fail / undecided counts, so a report never has to add them up by hand.
"""
function summarise(outcomes)
    per = Dict{String, Dict{String, Int}}()
    for o in outcomes
        f = get!(per, o.format) do
            Dict("pass" => 0, "fail" => 0, "undecided" => 0, "total" => 0)
        end
        f["total"] += 1
        if !o.decided
            f["undecided"] += 1
        else
            o.passed ? (f["pass"] += 1) : (f["fail"] += 1)
        end
    end
    return per
end
