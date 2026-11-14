# The bundled-contract audit, natively.

"""
    audit_bundled_schemas([dir]) -> Vector{String}

Offline audit of the contracts vendored under `schemas/`, the Julia counterpart of the
one-line check this repository used to run through Python (kept as a supplemental
differential in CI). It verifies, without network access:

1. every file listed in `provenance.json` matches its recorded SHA-256 on disk;
2. every path in `registry.json` exists, and every JSON file under `schemas/` is
   accounted for in `provenance.json` — no undocumented schema can enter the bundle;
3. rule V7: no FHT or FHGM row, path or release-form entry appears in the registry or
   the provenance records (drafts take no release form; prose stating the absence is
   fine, a type key is not);
4. every recorded contract declares the dialect `provenance.json` says it declares, and
   the v0.5.0/v0.6.0/current copies declare JSON Schema draft/2020-12.

Returns one finding per problem, empty when the bundle is sound.
"""
function audit_bundled_schemas(dir::AbstractString = SCHEMA_DIR)
    failures = String[]
    provfile = joinpath(dir, "provenance.json")
    isfile(provfile) || return ["provenance.json is missing from $(dir)"]
    prov = JSON.parsefile(provfile)
    files = get(prov, "files", Dict{String, Any}())

    for rel in sort(collect(keys(files)))
        path = joinpath(dir, rel)
        isfile(path) || (push!(failures, "provenance lists $(rel) but the file is missing"); continue)
        got = sha256_hex(read(path))
        want = get(files[rel], "sha256", nothing)
        got == want || push!(failures, "$(rel): sha256 $(got) != provenance $(want)")
    end

    regfile = joinpath(dir, "registry.json")
    isfile(regfile) || (push!(failures, "registry.json is missing from $(dir)"); return failures)
    reg = JSON.parsefile(regfile)
    listed = String[]
    for entry in values(get(reg, "files", Dict{String, Any}()))
        entry isa AbstractDict || continue
        for rel in values(entry)
            push!(listed, String(rel))
            isfile(joinpath(dir, String(rel))) ||
                push!(failures, "registry.json lists $(rel) but the file is missing")
        end
    end
    bundled_json = String[]
    for (root, _, names) in walkdir(dir)
        for n in names
            endswith(n, ".json") || continue
            rel = relpath(joinpath(root, n), dir)
            occursin(r"\A(?:provenance|registry|versions)", rel) || push!(bundled_json, rel)
        end
    end
    for rel in sort(setdiff(bundled_json, keys(files)))
        push!(failures, "$(rel) is bundled but recorded neither in provenance.json")
    end

    # Rule V7, release forms: no draft type may hold a registry row, a supported entry,
    # a provenance headerType or a path. Prose describing the absence is not a finding.
    for rel in sort(union(collect(keys(files)), listed))
        low = lowercase(rel)
        (occursin("fht", low) || occursin("fhgm", low)) &&
            push!(failures, "V7 violation: draft type in bundled path $(rel)")
    end
    for field in ("files", "schemaVersions", "releases")
        for (ref, row) in get(reg, field, Dict{String, Any}())
            row isa AbstractDict || continue
            for k in ("FHT", "FHGM")
                k in keys(row) && push!(failures, "V7 violation: draft type row under $(ref) in registry.json")
            end
        end
    end
    for t in setdiff(keys(get(reg, "supported", Dict{String, Any}())), ("FHR", "FHP", "FHGFF3"))
        push!(failures, "V7 violation: unsupported header type $(t) in registry.json supported list")
    end
    for (rel, meta) in files
        get(meta, "headerType", "") in ("FHT", "FHGM") &&
            push!(failures, "V7 violation: provenance records headerType for draft $(rel)")
    end

    for rel in sort(collect(keys(files)))
        endswith(rel, ".json") || continue
        isfile(joinpath(dir, rel)) || continue
        doc = JSON.parsefile(joinpath(dir, rel))
        declared = get(doc, "\$schema", "")
        want = get(files[rel], "declaredDialect", nothing)
        declared == want ||
            push!(failures, "$(rel): \$schema $(repr(declared)) != provenance declaredDialect")
        parts = splitpath(rel)
        parent = length(parts) >= 2 ? parts[end - 1] : ""
        if parent in ("v0.5.0", "v0.6.0", "current") &&
           declared != "https://json-schema.org/draft/2020-12/schema"
            push!(failures, "$(rel): expected draft/2020-12, found $(repr(declared))")
        end
    end
    return failures
end

"Padded-hex SHA-256 of `bytes` (stdlib `SHA`)."
function sha256_hex(bytes::AbstractVector{UInt8})
    bytes2hex(SHA.sha256(bytes))
end
