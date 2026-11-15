# The rule-V7 draft lane: what it recognises, and what it refuses to be.
#
# V7 lets a reader *recognise* an unreleased draft contract, and only where the user
# explicitly chose that lane. The requirements this module implements:
#
# * the lane is never the default: with no `drafts = true`, nothing here runs and a
#   draft citation stays "any other value" under V5, which is the behaviour this
#   library had before the lane existed (test/runtests.jl holds the byte-identity
#   checks, and the CI receipt the 291-vector ledger against);
# * the draft bytes are vendored and pinned the way the family pins a copied tree:
#   the commit of the development repository that owns the type and the SHA-256 of
#   the exact bytes, recorded in `drafts/provenance.json` and re-verified the first
#   time a draft is loaded, so selection can never run against a moving `main`;
# * two revisions are pinned per draft and they are different claims: `commit` pins
#   the contract bytes this module compiles, and `suiteCommit` plus
#   `suiteManifestSha256` pin the development conformance suite whose manifest
#   `scripts/draft_vectors.jl` executes. Both are surfaced (`draft_entry`,
#   `draft_suite_pin`) and the suite pair is enforced by `check_suite_pin`, which the
#   runner calls before scoring anything: a pin nothing reads is documentation, not
#   a control;
# * every record read through the lane carries a loud warning naming the draft, its
#   commit and its digest, and saying the result is not a released-contract result;
# * a draft takes no release form. Nothing here has a release tag, a w3id URL or a
#   row in the shared `schemas/versions.json`, and a release-shaped URL for a type
#   the registry does not list stays V5 even with the lane open.
#
# FHGM needs one more distinction: it is not a header type at all. An FHGM record
# carries no `schema` field; the records ride inside an FHGFF3 header under the
# `x-fhgm-models` extension key, the file is routed by its own FHGFF3 citation under
# V1 to V3, and the FHGM lane selects only the contract and the checks applied to
# those records (`src/fhgm.jl`).

const DRAFT_DIR = normpath(joinpath(dirname(@__FILE__), "..", "drafts"))

# The registry is read lazily and cached: the default (lane-off) reading path must not
# touch this directory at all, so importing the package can never depend on it. A
# missing registry is still a loud failure at the first lane use or at
# `verify_draft_bytes` - which `test/runtests.jl` calls on every run.
const _DRAFT_REG = Ref{Any}(nothing)

"Determine the draft registry as written in `drafts/provenance.json` (cached; not read at all unless a draft is requested)."
function draft_registry()
    _DRAFT_REG[] === nothing || return _DRAFT_REG[]
    path = joinpath(DRAFT_DIR, "provenance.json")
    isfile(path) || throw(HeaderError("V7", "drafts/provenance.json is missing from this build; " *
                                            "the draft lane cannot load (rule V7)", 0))
    _DRAFT_REG[] = JSON.parsefile(path)
    return _DRAFT_REG[]
end

"The type ids that have a pinned draft in this build, in registry order."
function draft_types()
    reg = draft_registry()
    return Tuple(String(k) for k in keys(get(reg, "drafts", Dict{String, Any}())))
end

"""
    draft_suite_pin(type) -> NamedTuple | nothing

The suite pin this build states for a draft: `stated` when commit, manifest path and
manifest digest are all present, `partial` when some but not all are present (a
registry defect, never an absence), and the recorded values themselves. Surfaced rather
than left in the JSON because a pin nothing reads is documentation, not a control:
`scripts/draft_vectors.jl` refuses to score a suite that does not verify against this
pin, and `test/runtests.jl` proves that refusal fires on a one-byte mutation.
"""
function draft_suite_pin(type::AbstractString)
    row = get(get(draft_registry(), "drafts", Dict{String, Any}()), String(type), nothing)
    row === nothing && return nothing
    fields = ("suiteCommit", "suiteManifest", "suiteManifestSha256")
    present = [f for f in fields if get(row, f, nothing) !== nothing]
    return (type = String(type),
            repository = String(get(row, "repository", "")),
            stated = length(present) == length(fields),
            partial = 0 < length(present) < length(fields),
            commit = get(row, "suiteCommit", nothing),
            manifest = get(row, "suiteManifest", nothing),
            sha256 = get(row, "suiteManifestSha256", nothing),
            bytes = get(row, "suiteManifestBytes", nothing),
            vectors = get(row, "suiteVectors", nothing),
            rules = get(row, "suiteRules", nothing))
end

"""
    draft_entry(type) -> NamedTuple | nothing

The pinned registry entry in reading shape: contract bytes and their pin, the suite
pin pair beside it, and `release_tag`/`w3id`/`registry_row` fixed at `nothing` - a
draft has none, by rule. `nothing` for a type this build pins no draft of.
"""
function draft_entry(type::AbstractString)
    row = get(get(draft_registry(), "drafts", Dict{String, Any}()), String(type), nothing)
    row === nothing && return nothing
    pin = draft_suite_pin(type)
    nt = (type = String(type),
          status = String(get(row, "status", "draft")),
          citation = String(get(row, "citation", "")),
          repository = String(get(row, "repository", "")),
          repository_url = String(get(row, "repositoryUrl", "")),
          commit = String(get(row, "commit", "")),
          sha256 = String(get(row, "sha256", "")),
          file = String(get(row, "file", "")),
          path = joinpath(DRAFT_DIR, String(get(row, "file", ""))),
          source_path = String(get(row, "sourcePath", "")),
          bytes = get(row, "bytes", nothing),
          release_tag = nothing,
          w3id = nothing,
          registry_row = nothing,
          suite_commit = pin.commit,
          suite_manifest = pin.manifest,
          suite_manifest_sha256 = pin.sha256,
          suite_manifest_bytes = pin.bytes,
          suite_vectors = pin.vectors,
          suite_rules = pin.rules,
          overlay = _overlay_of(row))
    return nt
end

function _overlay_of(row::AbstractDict)
    o = get(row, "transportOverlay", nothing)
    o === nothing && return nothing
    return (status = "draft",
            citation = String(get(o, "citation", "")),
            commit = String(get(o, "commit", "")),
            sha256 = String(get(o, "sha256", "")),
            file = String(get(o, "file", "")),
            path = joinpath(DRAFT_DIR, String(get(o, "file", ""))),
            source_path = String(get(o, "sourcePath", "")),
            bytes = get(o, "bytes", nothing),
            release_tag = nothing, w3id = nothing, registry_row = nothing)
end

"""
    citation_index() -> Dict{String, String}

The V7 citation a record may use to reach a draft: the raw-main URL of the owning
development repository, and nothing else. Maps citation URL to type id.
"""
function citation_index()
    idx = Dict{String, String}()
    for t in draft_types()
        e = draft_entry(t)
        e !== nothing && !isempty(e.citation) && (idx[e.citation] = t)
    end
    return idx
end

"""
    draft_lane_of(schema_value; drafts::Bool) -> entry | nothing

The pinned draft a record's `schema` citation selects *when the caller opened the
lane*, else `nothing`. Only FHT selects a file contract: FHGM is not a header type, so
its citation is deliberately absent from this routing even with the lane open (a file
citing it stays "any other value" under V5). A release-shaped URL for either type is
never a draft citation - it does not occur in `citation_index`.
"""
function draft_lane_of(schema_value; drafts::Bool = false)
    drafts || return nothing
    schema_value isa AbstractString || return nothing
    get(citation_index(), String(schema_value), nothing) == "FHT" || return nothing
    return draft_entry("FHT")
end

"""
    draft_warning(entry) -> String

The warning V7 requires on every record read through the lane. It names the citation,
the pinned commit and the digest of the bytes actually read, and says the result is not
a released-contract result.
"""
function draft_warning(entry::NamedTuple)
    return string(entry.type) * ": warning: schema " * entry.citation * " is an unreleased draft " *
           "(commit " * entry.commit * ", sha256 " * entry.sha256 * " of those bytes); " *
           "read against that pinned draft, not a released schema"
end

# Digest-verification state: paths confirmed against the registry since this process
# loaded. `verify_draft_bytes` always re-reads the bytes it is pointed at, so the cache
# can never hide drift from the test or CI guard.
const _VERIFIED = Set{String}()
const _DRAFT_CACHE = Dict{String, Any}()

"Confirm the bytes at `path` still match the digest `want` recorded for them; return the digest found."
function _assert_digest(path::AbstractString, want::AbstractString, label::AbstractString,
                       dir::AbstractString)
    key = dir * "\0" * label * "\0" * want
    isfile(path) || throw(HeaderError("V7", "the pinned draft file $(label) is missing from " *
                                     "this build (rule V7)", 0))
    digest = sha256_hex(read(path))
    digest == want || throw(HeaderError("V7", "the pinned draft $(label) does not match its " *
                                   "recorded provenance: sha256 $(digest), expected $(want); " *
                                   "the draft moved and this build was not re-pinned (rule V7)", 0))
    push!(_VERIFIED, key)
    return digest
end

"""
    load_draft(type, part::AbstractString = "contract"; dir::AbstractString = DRAFT_DIR)

The parsed JSON Schema document of a pinned draft (for FHGM, `part = "overlay"` selects
the transport overlay), re-digested against the registry on first load of each path.
A file that no longer matches its recorded digest raises rather than being read: V7
says a reader "says so instead of quietly choosing a newer draft". The parsed document
is cached per (type, part, digest).
"""
function load_draft(type::AbstractString, part::AbstractString = "contract"; dir::AbstractString = DRAFT_DIR)
    entry = draft_entry(type)
    entry === nothing && return nothing
    target = part == "overlay" ? something(entry.overlay, (;)) : entry
    isempty(String(get(target, :file, ""))) && return nothing
    path = joinpath(dir, String(target.file))
    _assert_digest(path, String(target.sha256), "$(dir)/$(target.file)", dir)
    key = string(type, "@", part, "@", target.sha256, "@", dir)
    haskey(_DRAFT_CACHE, key) && return _DRAFT_CACHE[key]
    doc = JSON.parsefile(path)
    _DRAFT_CACHE[key] = doc
    return doc
end

"""
    verify_draft_bytes([dir]) -> Vector{String}

Re-digest every file the registry pins against the digest recorded for it, and check
the recorded byte counts. Returns one finding per defect and an empty vector when the
pinned bytes are intact. This is the code-side consumer of `drafts/provenance.json`:
`test/runtests.jl` calls it on every run and records the finding count in the CI
receipt (`draftPinFindings=0`), CI labels
it, and the negative control in the tests shows it fires on a one-byte mutation. The
optional `dir` exists so the guard can be exercised on a copy without touching the
vendored tree.
"""
function verify_draft_bytes(dir::AbstractString = DRAFT_DIR)
    findings = String[]
    regfile = joinpath(dir, "provenance.json")
    isfile(regfile) || return ["provenance.json is missing from $(dir) (rule V7)"]
    reg = JSON.parsefile(regfile)
    rows = get(reg, "drafts", Dict{String, Any}())
    for type in sort(collect(keys(rows)))
        row = rows[type]
        specs = Tuple{String, AbstractDict}[(type, row)]
        haskey(row, "transportOverlay") && push!(specs, ("$(type)/transportOverlay", row["transportOverlay"]))
        for (label, s) in specs
            get(s, "file", nothing) === nothing && (push!(findings, "$(label): registry row names no file"); continue)
            path = joinpath(dir, String(s["file"]))
            isfile(path) || (push!(findings, "$(label): pinned file $(s["file"]) is missing from $(dir)"); continue)
            bytes = read(path)
            got = bytes2hex(SHA.sha256(bytes))
            want = get(s, "sha256", nothing)
            got == want || push!(findings, "$(label): $(s["file"]): sha256 $(got) != provenance $(want)")
            nb = get(s, "bytes", nothing)
            nb === nothing || length(bytes) == nb ||
                push!(findings, "$(label): $(s["file"]): $(length(bytes)) bytes != provenance $(nb)")
            for key in ("releaseTag", "w3id", "registryRow")
                if haskey(s, key) && s[key] !== nothing
                    push!(findings, "V7 violation: $(label) states $(key) = $(json_repr(s[key])); a draft takes no release form")
                end
            end
        end
    end
    return findings
end

json_repr(v) = JSON.json(v)

"""
    check_suite_pin(type, repo_path) -> NamedTuple

Verify a checkout of the owning repository against the suite pin the registry states:
the manifest at the pinned path must digest to `suiteManifestSha256`, hold the recorded
byte count, and list exactly `suiteVectors` vectors. States one of `verified`, `drift`,
`absent`, `partial`, `unpinned`, `bad-pin`. `scripts/draft_vectors.jl` calls this and
refuses to score anything that is not `verified`; the tests exercise `drift` on a
one-byte mutation and `absent` on a missing manifest.

Nothing here fetches, and nothing here re-pins: a drift is a report, and re-pinning is
the deliberate act `CONTRIBUTING.md` describes.
"""
function check_suite_pin(type::AbstractString, repo_path::AbstractString)
    pin = draft_suite_pin(type)
    pin === nothing && return (type = String(type), state = "bad-pin",
                               message = "$(type): this build pins no draft named $(type)",
                               path = nothing, expected = nothing, actual = nothing)
    return check_suite_against(pin, repo_path)
end

"""
    check_suite_against(pin, repo_path) -> NamedTuple

`check_suite_pin` with the pin handed in instead of read from the registry: that is how
both directions of the comparison - a manifest whose bytes match the pin, and one
character off - are exercised in `test/runtests.jl` without editing the registry or
touching the vendored tree. The runner's guard is the wrapper above; this is the same
code path, never a second copy of the logic.
"""
function check_suite_against(pin::NamedTuple, repo_path::AbstractString)
    type = pin.type
    if pin.partial
        return (type = String(type), state = "partial",
                message = "$(type): drafts/provenance.json states an incomplete suite pin " *
                          "(commit $(something(pin.commit, "none")), manifest $(something(pin.manifest, "none")), " *
                          "sha256 $(something(pin.sha256, "none"))); a pin must state its commit, its manifest " *
                          "and its digest together, because a subset of them checks nothing",
                path = nothing, expected = pin.sha256, actual = nothing)
    end
    if !pin.stated
        return (type = String(type), state = "unpinned",
                message = "$(type): no suite pin is stated, so nothing here can say which " *
                          "revision of the $(pin.repository) development suite a run scored; the contract " *
                          "pin still holds, the suite revision is unknown",
                path = nothing, expected = nothing, actual = nothing)
    end
    manifest = String(pin.manifest)
    (isempty(manifest) || isabspath(manifest) || occursin("\\", manifest) ||
     any(part -> part == "..", split(manifest, '/'))) &&
        return (type = String(type), state = "absent",
                message = "$(type): the pinned manifest path $(repr(pin.manifest)) is empty or escapes " *
                          "the checkout, and is refused rather than followed",
                path = nothing, expected = pin.sha256, actual = nothing)
    target = normpath(joinpath(repo_path, manifest))
    root = normpath(repo_path)
    startswith(target, root * '/') ||
        return (type = String(type), state = "absent",
                message = "$(type): the pinned manifest path $(repr(pin.manifest)) resolves outside " *
                          "the checkout and is refused",
                path = nothing, expected = pin.sha256, actual = nothing)
    isfile(target) ||
        return (type = String(type), state = "absent",
                message = "$(type): $(target) holds no $(pin.manifest); this checkout cannot be the " *
                          "suite pinned at $(pin.commit)",
                path = target, expected = pin.sha256, actual = nothing)
    bytes = read(target)
    actual = bytes2hex(SHA.sha256(bytes))
    if actual != pin.sha256
        return (type = String(type), state = "drift",
                message = "$(type): the suite manifest at $(target) digests to $(actual), while " *
                          "drafts/provenance.json records $(pin.sha256) for $(pin.repository) " *
                          "$(pin.commit) ($(pin.manifest)); this is not the suite this build's draft " *
                          "evidence names, so nothing is scored against it (rule V7)",
                path = target, expected = pin.sha256, actual = actual)
    end
    if pin.bytes !== nothing && length(bytes) != pin.bytes
        return (type = String(type), state = "drift",
                message = "$(type): the manifest digest matches but it holds $(length(bytes)) bytes " *
                          "while drafts/provenance.json records $(pin.bytes) for $(pin.commit)",
                path = target, expected = pin.sha256, actual = actual)
    end
    manifest_doc = JSON.parsefile(target)
    vectors = get(manifest_doc, "vectors", nothing)
    if pin.vectors !== nothing
        (vectors isa AbstractVector && length(vectors) == pin.vectors) ||
            return (type = String(type), state = "drift",
                    message = "$(type): the manifest digest matches but it holds " *
                              "$(vectors isa AbstractVector ? length(vectors) : 0) vectors while " *
                              "drafts/provenance.json records $(pin.vectors) for $(pin.commit); the " *
                              "registry's count claim and its digest claim cannot both be true",
                    path = target, expected = pin.sha256, actual = actual)
    end
    return (type = String(type), state = "verified",
            message = "$(type): suite manifest verified - $(pin.repository) $(pin.commit), " *
                      "$(pin.manifest)" * (pin.vectors === nothing ? "" : ", $(pin.vectors) vectors") *
                      ", sha256 $(actual)",
            path = target, expected = pin.sha256, actual = actual)
end

"""
    check_contract_pin(type, repo_path; dir = DRAFT_DIR) -> NamedTuple

Verify that a checkout of the owning repository still holds the contract bytes this
build pins (the FHGM transport overlay is checked with the same discipline). This
answers a different question from [`check_suite_pin`](@ref): that one asks whether a
suite is the suite the registry names; this one asks whether the vendored bytes and the
checkout bytes are the same pinned revision. Exit codes of the CLI wrapper
`scripts/draft_pins.jl`: 0 all verified, 1 drift, 2 unusable arguments.
"""
function check_contract_pin(type::AbstractString, repo_path::AbstractString)
    entry = draft_entry(type)
    entry === nothing && return (type = String(type), state = "bad-pin",
                                 message = "$(type): this build pins no draft named $(type)")
    results = Tuple{String, String}[]
    drift = 0
    rows = [(String(entry.file), String(entry.source_path), String(entry.sha256))]
    entry.overlay !== nothing &&
        push!(rows, (String(entry.overlay.file), String(entry.overlay.source_path), String(entry.overlay.sha256)))
    for (file, src, want) in rows
        path = joinpath(repo_path, src)
        if !isfile(path)
            drift += 1
            push!(results, (file, "missing"))
            continue
        end
        actual = bytes2hex(SHA.sha256(read(path)))
        same = actual == want
        drift += same ? 0 : 1
        push!(results, (file, same ? "MATCH" : "DRIFT"))
    end
    state = drift == 0 ? "verified" : "drift"
    message = "$(type): contract bytes at $(repo_path): " *
              join(("$(f) $(v)" for (f, v) in results), "; ") *
              (drift == 0 ? " (pinned at $(entry.commit))" : " - the lane would read something other than what it names (rule V7)")
    return (type = String(type), state = state, message = message)
end

"""
    draft_support() -> Vector{NamedTuple}

The lane this build can open, in the words a caller should print: type, citation,
pinned commit and digest, status `draft`. It states the pin and states equally that
none of it is a released contract.
"""
function draft_support()
    return [(type = e.type, citation = e.citation, commit = e.commit, sha256 = e.sha256,
             status = e.status) for e in (draft_entry(t) for t in draft_types()) if e !== nothing]
end
