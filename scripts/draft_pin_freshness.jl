#!/usr/bin/env julia
# Draft-pin freshness: are the revisions this build pinned still what the owning
# repository publishes on its default branch?
#
# Advisory, and it gates nothing. The lane reads the vendored bytes under `drafts/`,
# whose SHA-256 `src/drafts.jl` re-verifies on every load, so a moved upstream changes
# nothing about what this library does. What it changes is whether this repository's
# description of the draft is still current - which is a thing to notice on a schedule,
# not a thing to block released-contract acceptance with. Nothing here re-pins
# anything: re-pinning is the deliberate act `CONTRIBUTING.md` describes (bytes,
# commit, digest and prose in one dated commit).
#
#     julia --project=. scripts/draft_pin_freshness.jl
#
# This is not `scripts/draft_pins.jl --check-contract`, and both are needed. That one
# reads a local checkout of the owning repository at the PINNED commit and confirms
# those bytes are the bytes the pin names. This one asks the different question - what
# does the default branch hold NOW - and answers it over HTTPS.
#
# Exit status:
#   0  every pinned target matches live raw main, so the pins are current;
#   1  at least one target has moved: re-pin deliberately. The readings this build
#      reports are still valid evidence about the bytes they name;
#   2  a check was unusable - the local copies do not match their own recorded digests,
#      a probe came back redirected or without a clean status, or a probe CONTROL
#      failed - so no target is called current or drifted.
#
# Three details are not incidental:
#
# - the local copies are digested first. If `drafts/*.json` no longer equal the digests
#   `drafts/provenance.json` states, every expectation below is meaningless, and saying
#   "unusable" beats producing a confident answer;
# - a nonsense path is fetched from each repository FIRST and must return 404. Without
#   that, a portal page or a soft-200 error document would produce a digest that
#   differs from the pin, and the drift would be an artefact of a broken check rather
#   than a fact about the draft;
# - redirects are NOT followed. A digest taken after following a redirect describes
#   whatever the redirect landed on, not the URL this build cites, which is how a
#   renamed repository could make a dead citation look alive.
#
# The transport is `curl` shelled out from Julia: Julia's standard library has no HTTP
# client, and this script deliberately adds no dependency. It lives under `scripts/`,
# runs only in its own labelled advisory CI job, and gates nothing - the native
# acceptance path (`src/`, `test/runtests.jl`) remains pure Julia.

using FAIRBioHeaders
using SHA

const RAW_MAIN_SEGMENT = "/main/"
const CONTROL_FILE = "no-such-file-draft-pin-freshness-control.json"
const TMP = mktempdir()

"""
    pin_targets() -> Vector{NamedTuple}

Every digest this build states, as a live raw-main URL to probe plus what it expects:
each type's contract file, the FHGM transport overlay, and each type's suite manifest.
"""
function pin_targets()
    targets = NamedTuple[]
    for type in draft_types()
        e = draft_entry(type)
        push!(targets, (type = type, part = "contract", repository = e.repository,
                        path = e.source_path, url = e.citation, expected = e.sha256,
                        commit = e.commit, bytes = e.bytes))
        if e.suite_manifest !== nothing && e.suite_manifest_sha256 !== nothing
            url = "https://raw.githubusercontent.com/FAIR-bioHeaders/" * e.repository *
                  RAW_MAIN_SEGMENT * String(e.suite_manifest)
            push!(targets, (type = type, part = "suite-manifest", repository = e.repository,
                            path = String(e.suite_manifest), url = url,
                            expected = String(e.suite_manifest_sha256),
                            commit = something(e.suite_commit, e.commit),
                            bytes = e.suite_manifest_bytes))
        end
        if e.overlay !== nothing
            push!(targets, (type = type, part = "overlay", repository = e.repository,
                            path = String(e.overlay.source_path), url = String(e.overlay.citation),
                            expected = String(e.overlay.sha256), commit = String(e.overlay.commit),
                            bytes = e.overlay.bytes))
        end
    end
    return targets
end

"Fetch without following redirects; return (status, body-file, redirect-target)."
function probe(url::AbstractString, dest::AbstractString)
    out = read(`curl -s -o $(dest) -w "%{http_code} %{size_download} %{redirect_url}" $(url)`, String)
    parts = split(out, ' ')
    status = tryparse(Int, String(parts[1]))
    redirect = length(parts) >= 3 ? join(parts[3:end], " ") : ""
    return status, redirect
end

function main()
    # 1. Local integrity before any external claim.
    local_findings = verify_draft_bytes()
    if !isempty(local_findings)
        for f in local_findings; println(stderr, "LOCAL: $f"); end
        println(stderr, "unusable: the vendored draft bytes do not match their own recorded digests, so no expectation below is meaningful")
        exit(2)
    end
    # 2. Per-repository 404 control, before anything is judged.
    repos = unique([t.repository for t in pin_targets()])
    for repo in repos
        ctrl = joinpath(TMP, "ctrl-$(repo).txt")
        status, redirect = probe("https://raw.githubusercontent.com/FAIR-bioHeaders/$(repo)$(RAW_MAIN_SEGMENT)$(CONTROL_FILE)", ctrl)
        if status !== 404
            println(stderr, "unusable: the 404 control for $(repo) answered $(status)$(isempty(redirect) ? "" : " redirect -> $(redirect)") instead of 404; this host cannot be trusted for digests")
            exit(2)
        end
        println("control  $(repo): 404 as it must be (the probes below can distinguish present from absent)")
    end
    # 3. Probe every pinned target against live raw main.
    drifted = 0
    for t in pin_targets()
        dest = joinpath(TMP, "$(t.type)-$(t.part).bin")
        status, redirect = probe(t.url, dest)
        if status === nothing || status != 200 || !isempty(redirect)
            println(stderr, "unusable: $(t.type)/$(t.part) live-main probe returned $(something(status, "no status"))$(isempty(redirect) ? "" : " redirect -> $(redirect)"); a digest of anything but a clean 200 describes nothing")
            exit(2)
        end
        bytes = read(dest)
        actual = bytes2hex(SHA.sha256(bytes))
        size_note = "$(length(bytes)) B"
        if t.bytes !== nothing && length(bytes) != t.bytes
            size_note = "$(length(bytes)) B (recorded $(t.bytes) B)"
        end
        if actual == t.expected
            println("MATCH    $(t.type)/$(t.part): live main digests to the pin ($(size_note)); pinned at $(t.commit)")
        else
            drifted += 1
            println("DRIFT    $(t.type)/$(t.part): live main is $(actual) ($(size_note)), this build pins $(t.expected) (commit $(t.commit)). Re-pin deliberately (issue #2); readings made through the lane remain evidence about the bytes they name.")
        end
    end
    if drifted > 0
        println("$(drifted) pinned target(s) are no longer what the owning repository's main publishes. This job reports; it never re-pins.")
        exit(1)
    end
    println("all pinned draft targets are current against live raw main")
    exit(0)
end

main()
