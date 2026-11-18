#!/usr/bin/env julia
# Draft-lane evidence: run the development suites of the two draft types through this
# library's rule-V7 lane, natively, and report what each vector says.
#
# This is **not** acceptance, and it never will be. Acceptance is FAIR-bioHeaders-
# Specification's shared suite - the 291 vectors, reported by `test/runtests.jl` and the
# CI receipt - and FHT and FHGM have no part in it because no release registers them
# (rule V7). Nothing here is vendored either: the runner reads checkouts of the owning
# repositories that the caller points at, and labels every line as draft.
#
# Before it scores anything the runner enforces both pins, through the same code the
# library itself uses:
#
# * the CONTRACT pin: `check_contract_pin` - the checked-out draft bytes must digest to
#   `drafts/provenance.json`'s recorded sha256;
# * the SUITE pin: `check_suite_pin` - the suite manifest must digest to the recorded
#   `suiteManifestSha256` at the recorded `suiteCommit`, hold the recorded byte count
#   and list the recorded vector count. A suite that does not verify is REFUSED, not
#   scored: an evidence table naming a revision nobody checked is how a draft claim
#   goes quietly stale.
#
# Division of labour, one owner per concern:
#
# | concern | owner | gating |
# | --- | --- | --- |
# | are the contract bytes in this checkout the bytes the pin names? | `scripts/draft_pins.jl --check-contract` | yes, inside the labelled draft job |
# | is the suite about to be executed the suite the pin names? | this runner, through `check_suite_pin` | yes: a mismatch refuses the run and nothing is scored |
# | does the owning repository's live default branch still publish those bytes? | `scripts/draft_pin_freshness.jl` | no: advisory, because a draft legitimately moves |
#
#     julia --project=. scripts/draft_vectors.jl --fht /path/to/FHT-Specification \
#         --fhgm /path/to/FHGM-Specification [--receipt draft-lane.properties] [--verbose]
#
# Exit status:
#   0  every runnable draft vector agreed with this build's lane;
#   1  at least one disagreed, or a count guard fired (zero ran, an undeclared skip, a
#      manifest whose vector count differs from the registry's claim);
#   2  an argument is unusable or a supplied suite is not the suite this build pins.
#
# A vector whose rejection depends on a rule this build declares not-supported-yet
# (FHGM K4, which needs the GFF3 feature layer) is reported not-run with that reason,
# never as a pass and never as a failure of a check this library does not run. FHT
# vectors have no such escape: every one of them must be scored.

using FAIRBioHeaders
using JSON
using SHA
using Base64

const VERBOSE = "--verbose" in ARGS

# --------------------------------------------------------------------------------------
# arguments
# --------------------------------------------------------------------------------------

function parse_args(argv)
    fht, fhgm, receipt = nothing, nothing, nothing
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--fht"; fht = abspath(argv[i += 1])
        elseif a == "--fhgm"; fhgm = abspath(argv[i += 1])
        elseif a == "--receipt"; receipt = argv[i += 1]
        elseif a == "--verbose"; # taken above
        else
            println(stderr, "unknown argument: $(a)"); exit(2)
        end
        i += 1
    end
    return (fht = fht, fhgm = fhgm, receipt = receipt)
end

# --------------------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------------------

"""
Resolve a suite-relative path inside the reach a suite is allowed; `nothing` when it
escapes. A `..` segment is permitted exactly when the resolved target stays inside the
guard: the FHGM manifest legitimately names bytes one level up from its suite directory
(`../examples/...` inside `development/`), and refusing the segment itself would refuse
the suite. Absolute paths are refused, and so is anything that lands outside the guard
- the same containment discipline as the sibling JavaScript runner.
"""
function resolve_within(from::AbstractString, guard::AbstractString, path)
    (path isa AbstractString && !isempty(path) && !isabspath(path)) || return nothing
    target = normpath(joinpath(from, path))
    g = normpath(guard)
    (target == g || startswith(target, g * '/')) || return nothing
    return target
end

"Where a suite's paths resolve from, and how far they may reach. FHT resolves inside
`conformance/`; the FHGM suite resolves from `development/conformance/` and its manifest
names bytes one level up, under `development/examples/`, so its reach is `development/`."
function layout_for(type::AbstractString, repo_path::AbstractString)
    if type == "FHT"
        suite = joinpath(repo_path, "conformance")
        return (type = type, suite = suite, manifest = joinpath(suite, "manifest.json"),
                base = suite, guard = suite)
    end
    suite = joinpath(repo_path, "development", "conformance")
    return (type = type, suite = suite, manifest = joinpath(suite, "manifest.json"),
            base = suite, guard = joinpath(repo_path, "development"))
end

# --------------------------------------------------------------------------------------
# shared helpers
# --------------------------------------------------------------------------------------

json_equal(have, want) = FAIRBioHeaders.json_equal(have, want)

function bytes_of(path::AbstractString)
    read(path)
end

"""
    self_checksum_state(raw, container) -> String

The state of a file's own root checksum line, as the FHT suite's `selfChecksum` field
defines it: `matches`, `broken`, or `unreachable` when the line cannot be located or
compared at all. The fast path is this library's byte layer; when it raises (an R2/R4/R5
defect, or a header the byte layer will not parse) the line is located directly, so a
file doomed by another rule still gets its checksum line judged - the suite records
that distinction on purpose (passing a vector by failing the comparison is not
evidence).
"""
function self_checksum_state(raw::Vector{UInt8}, container::AbstractString)::String
    data = try
        FAIRBioHeaders.is_gzip(raw) ? FAIRBioHeaders.decompress_gzip(raw) : raw
    catch
        return "unreachable"
    end
    fast = try
        r = FAIRBioHeaders.header_checksum(data, container)
        # R10: an FHR line at or after the data section (including the second block of a
        # concatenated file) means the root checksum line cannot be identified - the
        # family's byte layer refuses such a file, and the suite records its
        # selfChecksum as `unreachable`, never as the digest of whichever line happened
        # to be scanned first.
        isempty(r.late) || return "unreachable"
        return r.stated == r.computed ? "matches" : "broken"
    catch e
        e isa ArgumentError || e isa HeaderError || rethrow()
        nothing
    end
    # Manual location, independent of the byte layer's verdicts.
    lines = FAIRBioHeaders.scan_lines(data)
    prefix = FAIRBioHeaders.PREFIX[container]
    content = String[]
    for (c, _) in lines
        line = String(data[c])
        startswith(line, prefix) || continue
        body = line[nextind(line, lastindex(prefix)):end]
        (all(isspace, body) || occursin(r"\A[ \t]*(#|%)", body)) && continue
        push!(content, body)
    end
    isempty(content) && return "unreachable"
    indent(line) = length(line) - length(lstrip(c -> c == ' ' || c == '\t', line))
    root = minimum(indent.(content))
    candidates = Int[]
    for (i, (c, t)) in enumerate(lines)
        line = String(data[c])
        startswith(line, prefix) || continue
        body = line[nextind(line, lastindex(prefix)):end]
        indent(body) == root && occursin(r"\Achecksum[ \t]*:", body) && push!(candidates, i)
    end
    length(candidates) == 1 || return "unreachable"
    i = only(candidates)
    body = String(data[lines[i][1]])
    m = match(Regex("\\A" * Regex(prefix).pattern * "[ \\t]*checksum[ \\t]*:[ \\t]*(.+?)[ \\t]*\\z"), body)
    m === nothing && return "unreachable"
    value = String(m.captures[1])
    if length(value) > 1 && ((startswith(value, '"') && endswith(value, '"')) ||
                             (startswith(value, '\'') && endswith(value, '\'')))
        value = value[2:end - 1]
    end
    occursin(FAIRBioHeaders.CANONICAL_B64, value) || return "unreachable"
    ctx = SHA.SHA2_512_256_CTX()
    for (j, (c, t)) in enumerate(lines)
        j == i && continue
        SHA.update!(ctx, data[c])
        SHA.update!(ctx, data[t])
    end
    computed = base64encode(SHA.digest!(ctx))
    return computed == value ? "matches" : "broken"
end

"Container of a parent file by its stated headerType (the checksum rule is per container)."
function container_of_parent(header_type)
    header_type == "FHGFF3" && return "fhgff3"
    header_type in ("FHR", "FHP", "FHT") && return "fasta"
    return nothing
end

# --------------------------------------------------------------------------------------
# FHT vectors
# --------------------------------------------------------------------------------------

function run_fht_vector(vector::AbstractDict, layout)
    id = vector["id"]
    path = resolve_within(layout.base, layout.guard, vector["file"])
    (path === nothing || !isfile(path)) &&
        return (id = id, outcome = "not-run", problems = String[], note = "unreadable path $(vector["file"])")
    raw = bytes_of(path)
    pl = get(vector, "parentLink", nothing)
    rows = pl isa AbstractVector ? pl : []
    r = verify_file(path; kind = "fasta", drafts = true)
    problems = String[]

    reached = r.metadata !== nothing
    cit = reached ? get(r.metadata, "schema", nothing) : nothing
    in_lane = reached && draft_lane_of(cit; drafts = true) !== nothing
    warned = any(occursin("unreleased draft", w) for w in r.warnings)
    if reached
        if in_lane
            warned || push!(problems, "a record read through the lane must carry the V7 draft warning, and this one does not")
        else
            warned && push!(problems, "the reading did not select the draft, yet the draft warning is present: the lane reached a record it should not have")
        end
    end

    # C3: judge the parent links the record states, against parent bytes the suite supplies.
    verdicts = Dict{String, String}()
    lane_valid = r.ok
    if reached && !isempty(rows)
        derived = get(r.metadata, "derivedFrom", nothing)
        derived = derived isa AbstractVector ? derived : Any[]
        checked_fail = false
        for (i, want) in enumerate(rows)
            idx = i - 1
            link = i <= length(derived) && derived[i] isa AbstractDict ? derived[i] : nothing
            if link === nothing
                push!(problems, "parentLink[$(idx)]: the record states no derivedFrom entry to judge")
                continue
            end
            stated = get(link, "checksum", nothing)
            pfile = get(want, "file", nothing)   # JSON null -> nothing: no parent supplied
            verdict = "unchecked"
            if stated isa AbstractString && pfile isa AbstractString
                ppath = resolve_within(layout.base, layout.guard, pfile)
                container = container_of_parent(get(link, "headerType", nothing))
                if ppath === nothing || !isfile(ppath) || container === nothing
                    verdict = "unchecked"
                else
                    computed = try
                        FAIRBioHeaders.header_checksum(bytes_of(ppath), container).computed
                    catch
                        nothing
                    end
                    verdict = computed === nothing ? "unchecked" :
                              (String(computed) == String(stated) ? "checked-pass" : "checked-fail")
                end
            end
            verdicts[string(idx)] = verdict
            want_result = get(want, "result", nothing)
            want_result isa AbstractString && verdict != want_result &&
                push!(problems, "parentLink[$(idx)]: expected $(want_result), got $(verdict)")
            verdict == "checked-fail" && (checked_fail = true)
        end
        checked_fail && (lane_valid = false)   # a checked-fail link drives the rejection
        if !isempty(rows) && all(get(rw, "result", nothing) == "unchecked" for rw in rows)
            r.ok || push!(problems, "an unchecked link must not reject the record: " * join(r.errors, "; "))
        end
    end

    if vector["expected"] == "valid"
        lane_valid || push!(problems, "expected valid, got: " * join(r.errors, "; "))
    elseif lane_valid
        push!(problems, "expected invalid ($(something(get(vector, "rule", nothing),
              join(get(vector, "rules", Any[]), "+")))), got valid")
    end

    cs = get(vector, "checksum", nothing)
    if cs isa AbstractString && r.computed !== nothing && String(r.computed) != String(cs)
        push!(problems, "expected checksum $(cs), computed $(r.computed)")
    end
    for (k, want) in get(vector, "metadata", Dict{String, Any}())
        have = reached ? get(r.metadata, String(k), :absent) : :absent
        have === :absent && (push!(problems, "metadata.$(k) missing"); continue)
        json_equal(have, want) || push!(problems, "metadata.$(k): got $(JSON.json(have)) want $(JSON.json(want))")
    end
    for needle in get(vector, "warnings", Any[])
        # Every warning names its rule (the R14 wording follows the reference toolkit's).
        hit = any(occursin(Regex("\\b" * String(needle) * "\\b"), w) for w in r.warnings)
        hit || push!(problems, "expected a warning naming $(needle)")
    end
    sc = get(vector, "selfChecksum", nothing)
    if sc isa AbstractString
        got = self_checksum_state(raw, "fasta")
        got != sc && push!(problems, "selfChecksum: expected $(sc), got $(got)")
    end
    return (id = id, outcome = isempty(problems) ? "pass" : "fail", problems = problems,
            note = reached ? (in_lane ? "V7 lane" : "released path") : "rejected before selection")
end

# --------------------------------------------------------------------------------------
# FHGM vectors
# --------------------------------------------------------------------------------------

const K4_REASON = "K4 resolves a featureId against the GFF3 feature layer, which this " *
                  "library does not read; a rejection that depends on K4 cannot be scored here"

function run_fhgm_vector(vector::AbstractDict, layout)
    id = vector["id"]
    cited = Any[]
    get(vector, "rule", nothing) isa AbstractString && push!(cited, vector["rule"])
    for x in get(vector, "rules", Any[])
        x isa AbstractString && push!(cited, x)
    end
    layers = get(vector, "layers", Dict{String, Any}())
    reason = get(vector, "reason", nothing)
    if "K4" in cited || (get(layers, "model", nothing) == "reject" &&
                         reason isa AbstractString && occursin("gene row", reason))
        return (id = id, outcome = "not-run", problems = String[],
                note = "not-supported-yet: $(K4_REASON)")
    end
    path = resolve_within(layout.base, layout.guard, vector["file"])
    (path === nothing || !isfile(path)) &&
        return (id = id, outcome = "not-run", problems = String[], note = "unreadable path $(vector["file"])")

    predecessors = Any[]
    ctx = get(vector, "context", nothing)
    if ctx isa AbstractDict
        for prior in get(ctx, "predecessors", Any[])
            pp = resolve_within(layout.base, layout.guard, prior)
            (pp === nothing || !isfile(pp)) && continue   # not supplied: K6 leaves the claim unresolvable
            ph = try
                read_fhr_file(FAIRBioHeaders.read_file_bytes(pp), "fhgff3")
            catch
                continue
            end
            chk = get(ph.metadata, "checksum", nothing)
            chk isa AbstractString && push!(predecessors, (checksum = String(chk), header = ph.metadata))
        end
    end

    r = verify_file(path; kind = "fhgff3")     # the released reading; drafts stay closed here
    md = r.metadata
    md isa AbstractDict || return (id = id, outcome = "fail",
                                   problems = ["the file does not parse to an FHGFF3 header"], note = "unreadable header")
    contract_findings = validate_record(md)    # layers.base: the released contract over the header, apart from the checksum
    base_sound = isempty(contract_findings) &&
                 !(any(occursin("unsupported schema version", f) for f in contract_findings))
    checksum_ok = r.computed !== nothing && r.stated == r.computed
    v = check_fhgm_models(md; base_ok = base_sound && checksum_ok && r.ok, predecessors = predecessors)

    problems = String[]
    lb = get(layers, "base", nothing); lc = get(layers, "checksum", nothing); lm = get(layers, "model", nothing)
    lc == "verify" && !checksum_ok && push!(problems, "layers.checksum says verify, the recomputation disagrees: " * join(r.errors, "; "))
    lc == "stale" && checksum_ok && push!(problems, "layers.checksum says stale, the recomputation agrees")
    lb == "accept" && !base_sound && push!(problems, "layers.base says accept, the released FHGFF3 contract rejects the header: " * join(contract_findings, "; "))
    lb == "reject" && base_sound && push!(problems, "layers.base says reject, the released FHGFF3 contract accepted the header")
    if lm == "pass" && !(v.valid || v.status == "absent")
        push!(problems, "layers.model says pass, the draft checker rejected: " * join(v.errors, "; "))
    end
    if lm == "reject"
        if v.valid && r.ok
            push!(problems, "layers.model says reject ($(something(reason, ""))), nothing rejected this file")
        elseif get(vector, "rule", nothing) isa AbstractString
            # The recorded `reason` is the upstream checker's own message text, not a
            # norm this library is asked to reproduce; the comparable claim is the rule
            # id, so the finding must name the same rule.
            text = join(r.errors, "\n") * "\n" * join(contract_findings, "\n") * "\n" * join(v.errors, "\n")
            rule = String(vector["rule"])
            attributed = occursin(rule, text) ||
                         (rule == "B1" && (v.status == "not-checked" || !checksum_ok || !base_sound))
            attributed || push!(problems, "rejected, but no finding attributes the rejection to $(rule): " *
                                replace(text, "\n" => " | ")[1:min(end, 240)])
        end
    end
    # The lane's own discipline, independent of any single vector: a draft verdict never
    # changes the released FHGFF3 result, and never travels without its warning.
    if v.status == "checked" && !any(occursin("unreleased draft", w) for w in v.warnings)
        push!(problems, "the FHGM verdict travelled without the V7 draft warning")
    end
    note = "base=$(base_sound ? "accept" : "reject"),checksum=$(checksum_ok ? "verify" : "stale"),model=" *
           (v.status == "checked" ? (v.valid ? "pass" : "reject") : v.status)
    return (id = id, outcome = isempty(problems) ? "pass" : "fail", problems = problems, note = note)
end

# --------------------------------------------------------------------------------------
# suites
# --------------------------------------------------------------------------------------

const refusals = String[]
const pin_refusals = String[]   # contract/suite pin failures: exit 2, nothing scored

function run_suite(type::AbstractString, repo_path::AbstractString)
    entry = draft_entry(type)
    layout = layout_for(type, repo_path)
    println("\n=== $(type) draft suite ===")

    # The contract bytes this run compiles are the vendored drafts/$(entry.file), whose
    # digest src/drafts.jl re-verifies on every load; CI confirms those vendored bytes
    # against the upstream pinned commit separately (scripts/draft_pins.jl
    # --check-contract). The checkout below is at the SUITE revision, which is a
    # different claim, checked here.
    spin = check_suite_pin(type, repo_path)
    println("suite pin:    $(spin.message)")
    if spin.state == "unpinned"
        # The sibling JavaScript runner runs such a suite and labels it UNPINNED. This
        # build refuses instead: a stricter posture than the family minimum, chosen
        # because both drafts DO state suite pins here, so an absent pin can only mean
        # the registry was edited - exactly the accident an evidence run should not
        # paper over (rule V7).
        println("suite:        REFUSED - the registry states no suite revision for $(type); evidence without a named revision is not reported (rule V7)")
        push!(pin_refusals, "$(type): suite UNPINNED")
        return (pass = 0, fail = 0, notRun = 0, refused = true, unpinned = true, total = 0, notRunIds = String[])
    elseif spin.state != "verified"
        push!(pin_refusals, "$(type): suite pin $(spin.state)")
        println("suite:        REFUSED - this is not the suite the pin names; nothing is scored")
        return (pass = 0, fail = 0, notRun = 0, refused = true, unpinned = false, total = 0, notRunIds = String[])
    else
        # The guard and the reader must look at the same file, or the verified manifest
        # is not the one being scored.
        if normpath(spin.path) != normpath(layout.manifest)
            push!(pin_refusals, "$(type): verified manifest is not the manifest this runner reads")
            println("suite:        REFUSED - the verified manifest ($(spin.path)) is not the one being scored ($(layout.manifest))")
            return (pass = 0, fail = 0, notRun = 0, refused = true, unpinned = false, total = 0, notRunIds = String[])
        end
    end
    if !isfile(layout.manifest)
        println("$(type): no manifest.json at $(layout.manifest) - not run, nothing claimed")
        return (pass = 0, fail = 0, notRun = 0, refused = false, unpinned = false, total = 0, notRunIds = String[])
    end
    manifest = JSON.parsefile(layout.manifest)
    vectors = manifest["vectors"]
    println("manifest vectors: $(length(vectors)) (a draft suite, separate from the shared 291)")
    if entry.suite_vectors !== nothing && length(vectors) != entry.suite_vectors
        push!(pin_refusals, "$(type): manifest lists $(length(vectors)) vectors, the registry names $(entry.suite_vectors)")
        println("suite:        REFUSED - vector count $(length(vectors)) != pinned $(entry.suite_vectors); nothing is scored")
        return (pass = 0, fail = 0, notRun = 0, refused = true, unpinned = false, total = length(vectors), notRunIds = String[])
    end
    pass = fail = not_run = 0
    failures, skipped, not_run_ids = String[], String[], String[]
    for vector in vectors
        result = type == "FHT" ? run_fht_vector(vector, layout) : run_fhgm_vector(vector, layout)
        VERBOSE && println("  ", rpad(result.outcome, 7), " ", rpad(vector["id"], 46), " ", result.note)
        if result.outcome == "pass"
            pass += 1
        elseif result.outcome == "not-run"
            not_run += 1
            push!(not_run_ids, vector["id"])
            push!(skipped, "  not-run $(vector["id"]) [$(type)]: $(result.note)")
        else
            fail += 1
            push!(failures, "  $(vector["id"]) [$(type)] $(vector["expected"]) ($(result.note))\n    " * join(result.problems, "\n    "))
        end
    end
    for s in skipped; println(s); end
    for f in failures; println(f); end
    println("$(type) draft vectors: $(pass) pass, $(fail) fail, $(not_run) not-run of $(length(vectors)) (labelled draft, NOT acceptance; the shared 291 ledger is untouched)")
    # Guards, same discipline as the released runner: a run where nothing ran is a
    # failure, and so is any not-run outside the single declared hole (FHGM K4).
    if length(vectors) == 0 || pass + fail == 0
        push!(refusals, "$(type): zero vectors ran")
    end
    if type == "FHT" && not_run != 0
        push!(refusals, "$(type): $(not_run) vectors not run; the FHT lane declares no not-supported-yet rule")
    end
    if type == "FHGM" && not_run != 0
        # the declared hole is exactly the K4-dependent vectors
        declared = String[]
        for v in vectors
            cited = String[]
            get(v, "rule", nothing) isa AbstractString && push!(cited, String(v["rule"]))
            for x in get(v, "rules", Any[])
                x isa AbstractString && push!(cited, String(x))
            end
            lay = get(v, "layers", Dict{String, Any}())
            rsn = get(v, "reason", "")
            if "K4" in cited || (get(lay, "model", nothing) == "reject" &&
                                 rsn isa AbstractString && occursin("gene row", String(rsn)))
                push!(declared, v["id"])
            end
        end
        extra = setdiff(not_run_ids, declared)
        isempty(extra) || push!(refusals, "$(type): vectors not run without a declared reason: $(join(extra, ", "))")
    end
    return (pass = pass, fail = fail, notRun = not_run, refused = false,
            unpinned = false, total = length(vectors), notRunIds = not_run_ids)
end

# --------------------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------------------

args = parse_args(ARGS)
if args.fht === nothing || args.fhgm === nothing
    println(stderr, "usage: julia --project=. scripts/draft_vectors.jl --fht DIR --fhgm DIR [--receipt PATH] [--verbose]")
    println(stderr, "nothing is reported as passed, because a full run needs both suites")
    exit(2)
end
for (t, dir) in (("FHT", args.fht), ("FHGM", args.fhgm))
    if !isdir(dir)
        println(stderr, "$(t) checkout not found at $(dir)")
        exit(2)
    end
end

results = Dict("FHT" => run_suite("FHT", args.fht), "FHGM" => run_suite("FHGM", args.fhgm))

if !isempty(pin_refusals)
    println(stderr, "draft-lane run refused: " * join(pin_refusals, "; ") * " (exit 2: nothing was scored)")
    exit(2)
end
if !isempty(refusals)
    println(stderr, "draft-lane guard failed: " * join(refusals, "; "))
    exit(1)
end
total_fail = results["FHT"].fail + results["FHGM"].fail
if total_fail > 0
    println(stderr, "$(total_fail) draft vector(s) disagreed with this build's lane")
    exit(1)
end

if args.receipt !== nothing
    e_fht, e_fhgm = draft_entry("FHT"), draft_entry("FHGM")
    open(args.receipt, "w") do io
        println(io, "lane=draft-not-acceptance")
        println(io, "sharedLedgerTouched=false")
        println(io, "fhtContractCommit=$(e_fht.commit)")
        println(io, "fhtContractSha256=$(e_fht.sha256)")
        println(io, "fhtSuiteCommit=$(e_fht.suite_commit)")
        println(io, "fhtSuiteManifestSha256=$(e_fht.suite_manifest_sha256)")
        println(io, "fhtVectors=$(results["FHT"].total)")
        println(io, "fhtPass=$(results["FHT"].pass)")
        println(io, "fhtFail=0")
        println(io, "fhtNotRun=$(results["FHT"].notRun)")
        println(io, "fhgmContractCommit=$(e_fhgm.commit)")
        println(io, "fhgmContractSha256=$(e_fhgm.sha256)")
        println(io, "fhgmSuiteCommit=$(e_fhgm.suite_commit)")
        println(io, "fhgmSuiteManifestSha256=$(e_fhgm.suite_manifest_sha256)")
        println(io, "fhgmVectors=$(results["FHGM"].total)")
        println(io, "fhgmPass=$(results["FHGM"].pass)")
        println(io, "fhgmFail=0")
        println(io, "fhgmNotRun=$(results["FHGM"].notRun)")
        println(io, "fhgmNotRunIds=$(join(results["FHGM"].notRunIds, ","))")
        println(io, "fhgmNotRunRule=K4")
    end
    println("receipt written: $(args.receipt) (draft evidence; the 291-vector shared ledger belongs to the acceptance job alone)")
end
println("draft lane behaved on every vector it can score; K4 stays declared not-supported-yet")
exit(0)
