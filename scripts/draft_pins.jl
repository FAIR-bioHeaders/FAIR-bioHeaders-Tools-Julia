#!/usr/bin/env julia
# CI glue for the draft-lane jobs: read the pins this build carries from
# drafts/provenance.json (through src/drafts.jl, the same code the lane itself runs),
# and check checked-out bytes against them.
#
#     julia --project=. scripts/draft_pins.jl --github-output
#     julia --project=. scripts/draft_pins.jl --check-contract .upstream/FHT-Specification FHT
#     julia --project=. scripts/draft_pins.jl --check-suite   .upstream/FHT-Specification FHT
#
# `--check-contract` compares the contract (and, for FHGM, the transport overlay) files
# at the given checkout against the pinned digest and exits 1 on drift.
# `--check-suite` runs `FAIRBioHeaders.check_suite_pin` against the checkout: only
# `verified` exits 0. Neither flag fetches anything and neither cares which branch the
# checkout is on: the job checks out the pinned commit, and this confirms it.
#
# Exit status: 0 confirmed, 1 drift or a stated pin that the checkout does not satisfy,
# 2 unusable arguments.

using FAIRBioHeaders
using JSON

function github_output()
    lines = String[]
    for type in draft_types()
        e = draft_entry(type)
        key = lowercase(String(type))
        push!(lines, "$(key)-commit=$(e.commit)")
        push!(lines, "$(key)-repo=$(e.repository)")
        push!(lines, "$(key)-path=$(e.source_path)")
        push!(lines, "$(key)-sha256=$(e.sha256)")
        push!(lines, "$(key)-suite-commit=$(something(e.suite_commit, ""))")
        push!(lines, "$(key)-suite-manifest=$(something(e.suite_manifest, ""))")
        push!(lines, "$(key)-suite-sha256=$(something(e.suite_manifest_sha256, ""))")
    end
    println.(lines)
    out = get(ENV, "GITHUB_OUTPUT", "")
    !isempty(out) && open(out, "a") do io
        println(io, join(lines, "\n"))
    end
    return 0
end

if length(ARGS) < 1
    println(stderr, "usage: draft_pins.jl --github-output | --check-contract <dir> <TYPE> | --check-suite <dir> <TYPE>")
    exit(2)
end
flag = ARGS[1]
if flag == "--github-output"
    exit(github_output())
elseif flag == "--check-contract" || flag == "--check-suite"
    length(ARGS) == 3 || (println(stderr, "$flag wants <checkout-dir> <TYPE>"); exit(2))
    dir, type = ARGS[2], ARGS[3]
    type in draft_types() || (println(stderr, "this build pins no draft named $(type)"); exit(2))
    res = flag == "--check-contract" ? check_contract_pin(type, dir) : check_suite_pin(type, dir)
    println(res.message)
    exit(res.state == "verified" ? 0 : 1)
else
    println(stderr, "unknown flag $(flag)")
    exit(2)
end
