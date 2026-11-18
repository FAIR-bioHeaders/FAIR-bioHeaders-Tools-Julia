# Read each YAML text of a JSON array with read_fhr_header and write the outcome per text
# (supplemental differential; compare_yaml.py compares it with the reference toolkit).
using FAIRBioHeaders, JSON
fixs(s::AbstractString) = isvalid(s) ? s :
    join(isvalid(c) ? string(c) : "<U+" * uppercase(string(UInt32(codepoint(c)), base = 16, pad = 4)) * ">" for c in s)
fixv(v::AbstractString) = fixs(v)
fixv(v::AbstractVector) = Any[fixv(x) for x in v]
fixv(v::AbstractDict) = Dict{String, Any}(fixs(k) => fixv(x) for (k, x) in v)
fixv(v) = v
out = Any[]
for t in JSON.parsefile(ARGS[1])
    try
        push!(out, Dict("ok" => true, "v" => JSON.json(fixv(read_fhr_header(t).metadata))))
    catch e
        push!(out, Dict("ok" => false, "e" => first(sprint(showerror, e), 150)))
    end
end
open(io -> JSON.json(io, out), ARGS[2], "w")
