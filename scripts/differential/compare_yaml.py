# Supplemental differential: compare the per-text outcomes of py_yaml.py and yaml_cases.jl.
# Usage: compare_yaml.py CASES.json PY.json JL.json [MAX_SHOWN]; exits 1 on any difference.
import json, sys
cases = json.load(open(sys.argv[1])); py = json.load(open(sys.argv[2])); jl = json.load(open(sys.argv[3]))
def canon(s):
    # type-aware: keep int vs float distinct
    def walk(v):
        if isinstance(v, bool): return ('b', v)
        if isinstance(v, int): return ('i', v)
        if isinstance(v, float): return ('f', v)
        if isinstance(v, list): return ('l', [walk(x) for x in v])
        if isinstance(v, dict): return ('d', sorted((k, walk(x)) for k, x in v.items()))
        return ('o', v)
    return walk(json.loads(s))
bad = 0
for i, (t, p, j) in enumerate(zip(cases, py, jl)):
    same = p['ok'] == j['ok'] and (not p['ok'] or canon(p['v']) == canon(j['v']))
    if not same:
        bad += 1
        if bad <= int(sys.argv[4] if len(sys.argv) > 4 else 40):
            print(f"#{i} {t[:120]!r}\n   py: {p.get('v') or p.get('e')}\n   jl: {j.get('v') or j.get('e')}")
print(f"differences: {bad} of {len(cases)} YAML texts ({sum(p['ok'] for p in py)} accepted by the toolkit)")
sys.exit(1 if bad else 0)
