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
    run_conformance(suite; formats = runnable_formats())

Run the manifest's vectors from `suite` (a directory holding `manifest.json`, `valid/` and
`invalid/`). Returns one `VectorOutcome` per vector. Compressed vectors are decided like the
rest: `verify_file` decompresses gzip/BGZF input and rule R1 hashes the decompressed bytes.
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
        # D9: old manifest bytes remain immutable; new R4 expectation is tied
        # to the exact historical bytes and explicitly labelled in the result.
        crosswalk = JSON.parsefile(joinpath(@__DIR__, "..", "references", "retirement-crosswalk.json"))
        retired = filter(x -> x["id"] == v["id"], crosswalk["cases"])
        if !isempty(retired) && v["expected"] == "valid"
            bytes2hex(SHA.sha256(read(joinpath(suite, v["file"])))) == only(retired)["oldSha256"] ||
                error("retired source bytes differ: " * v["id"])
            v = Dict{String, Any}(v)
            v["expected"] = "invalid"
            v["rule"] = "R4"
        end
        push!(outcomes, run_vector(suite, v))
    end
    return outcomes
end

# Rules that only the contract can break: an invalid vector citing one of them must be
# rejected by contract validation (or, for the container rule, by the container check), not
# by an accident of another layer.
const CONTRACT_RULES = Set(["R15", "V1", "V2", "V3", "V5", "V6", "P1", "P2", "G2", "G3"])

"Whether `message` is a contract finding (it names the type and contract it was checked against)."
is_contract_finding(message::AbstractString) =
    occursin(r"\A(?:FHR|FHP|FHGFF3|FHT) \S+ \([^)]*\.json\): ", message) ||
    occursin("incompatible with", message)

"Whether `message` reports rule `rule`: `R8: line 3: ...`, `... (rule R2)` and the like."
reports_rule(message::AbstractString, rule::AbstractString) =
    occursin(Regex("(?:\\A|\\(rule )" * rule * "(?:\\b|:)"), message)

"""
    breaks_rule(result, rule) -> Bool

Whether a rejected file was rejected for the rule its vector names. A contract rule must
come back as a contract finding; any other rule must be named by a finding. Rule R1 (the
digest covers the exact decompressed bytes) and the digest half of R4 (SHA-512/256, not
SHA-256 or truncated SHA-512) show up as the R3 mismatch they cause, so for those two an
R3 mismatch counts too.
"""
function breaks_rule(result, rule::AbstractString)
    rule == "R17" && return any(m -> occursin("metadata is incompatible with", m), result.errors)
    rule in CONTRACT_RULES && return any(is_contract_finding, result.errors)
    any(m -> reports_rule(m, rule), result.errors) && return true
    rule in ("R1", "R4") && return any(m -> reports_rule(m, "R3"), result.errors)
    return false
end

function run_vector(suite::AbstractString, v::AbstractDict)
    path = joinpath(suite, v["file"])
    kind = FORMAT_KIND[v["format"]]
    rule = get(v, "rule", nothing)
    result = verify_file(path; kind = kind)
    if v["expected"] == "valid"
        detail = String[]
        result.ok || push!(detail, join(vcat(result.errors, result.not_checked), "; "))
        if !isnothing(v["checksum"]) && something(result.computed, "") != v["checksum"]
            push!(detail, "checksum $(something(result.computed, "none")) != manifest $(v["checksum"])")
        end
        md = something(result.metadata, Dict{String, Any}())
        for (k, want) in get(v, "metadata", Dict{String, Any}())
            have = get(md, String(k), :absent)
            have === :absent && (push!(detail, "metadata.$(k) missing"); continue)
            json_equal(have, want) || push!(detail, "metadata.$(k): got $(JSON.json(have)) want $(JSON.json(want))")
        end
        # A valid vector may list rules a validator must warn under (R14).
        for w in get(v, "warnings", String[])
            any(m -> occursin(Regex("\\b" * w * "\\b"), m), result.warnings) ||
                push!(detail, "no $(w) warning")
        end
        return VectorOutcome(v["id"], v["format"], "valid", true, isempty(detail), join(detail, "; "))
    end
    # Invalid: reject it for the rule it breaks, or report the rule as outside the layers.
    if rule !== nothing && !(rule in implemented_rules())
        return VectorOutcome(v["id"], v["format"], "invalid", false, false,
                             "rule $(rule) is outside the implemented layers")
    end
    want = get(v, "result", nothing)
    if want == "unsupported-version"
        # V4: the required outcome is "not checked against another schema", nothing else.
        unsupported = any(n -> occursin("unsupported schema version", n), result.not_checked)
        ok = unsupported && isempty(result.errors) && !result.ok
        return VectorOutcome(v["id"], v["format"], "invalid", true, ok,
                             ok ? "unsupported-version" : "expected unsupported-version, got " *
                             join(vcat(result.errors, result.not_checked), "; "))
    end
    if !isempty(result.not_checked)
        return VectorOutcome(v["id"], v["format"], "invalid", true, false,
                             "not checked: " * join(result.not_checked, "; "))
    end
    result.ok && return VectorOutcome(v["id"], v["format"], "invalid", true, false,
                                      "accepted, but the file breaks rule $(rule)")
    hit = rule === nothing || breaks_rule(result, rule)
    return VectorOutcome(v["id"], v["format"], "invalid", true, hit,
                         (hit ? "" : "rejected, but not for rule $(rule): ") * join(result.errors, "; "))
end

"The FORMAT.md and per-type rules this implementation can decide. Anything else is
reported as undecided rather than passed."
implemented_rules() = Set(["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R10", "R11", "R12", "R13",
                           "R14", "R15", "R17", "P1", "P2", "G1", "G2", "G3", "V1", "V2", "V3", "V4", "V5", "V6"])

"JSON equality as the vectors define it: numbers compare by value, types never convert.
`true` is not the number 1, so booleans are told apart before numbers."
function json_equal(have, want)
    if want isa Bool || have isa Bool
        return want isa Bool && have isa Bool && have == want
    elseif want isa Real
        return have isa Real && have == want
    elseif want isa AbstractString
        return have isa AbstractString && String(have) == String(want)
    elseif want === nothing
        return have === nothing
    elseif want isa AbstractVector
        have isa AbstractVector && length(have) == length(want) || return false
        return all(json_equal(h, w) for (h, w) in zip(have, want))
    elseif want isa AbstractDict
        have isa AbstractDict || return false
        hk = Set(String(k) for k in keys(have))
        wk = Set(String(k) for k in keys(want))
        hk == wk || return false                   # the same keys, none missing, none extra
        return all(json_equal(have[k], want[k]) for k in keys(want))
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
