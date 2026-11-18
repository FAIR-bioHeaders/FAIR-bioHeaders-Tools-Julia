# Supplemental differential: load each YAML text with the reference toolkit (bioheaders.load_yaml
# and its record checks) and write the outcome per text. Usage: py_yaml.py CASES.json OUT.json
import json, sys
import bioheaders as b, re
SUR = re.compile('[\ud800-\udfff]')
def fix(v):
    if isinstance(v, str): return SUR.sub(lambda m: '<U+%04X>' % ord(m.group()), v)
    if isinstance(v, list): return [fix(x) for x in v]
    if isinstance(v, dict): return {fix(k): fix(x) for k, x in v.items()}
    return v
def norm(v):
    return json.loads(json.dumps(v, allow_nan=True))
cases = json.load(open(sys.argv[1]))
out = []
for t in cases:
    try:
        d = b.load_yaml(t)
        f = b.fhr()
        f._input(d)
        out.append({"ok": True, "v": json.dumps(fix(f.__dict__), sort_keys=True, ensure_ascii=True)})
    except RecursionError:
        out.append({"ok": False, "e": "recursion"})
    except Exception as e:
        out.append({"ok": False, "e": (type(e).__name__ + ": " + str(e).replace("\n", " "))[:150]})
json.dump(out, open(sys.argv[2], "w"))
