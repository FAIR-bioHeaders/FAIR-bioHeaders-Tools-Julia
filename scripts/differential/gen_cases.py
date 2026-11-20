# Supplemental differential: generate YAML texts (curated edge cases from curated.txt, random
# strings over YAML indicator characters, random nested documents).
# Usage: gen_cases.py OUT.json SEED [N_RANDOM] [N_DOCS]
import json, random, sys, os
random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
cases = [case["text"] for case in json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "expected-policy-cases.json")))["cases"]]
# 1. curated
cur = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'curated.txt')).read().replace('<BOM>', '\ufeff').split('\n')
# split curated by blank-line-free entries: treat each "case" as lines grouped until next top-level 'a:'/'x:' is ambiguous; simpler: also add single lines and pairs
for i in range(len(cur)):
    cases.append(cur[i])
    for k in (2, 3, 4, 6):
        cases.append("\n".join(cur[i:i+k]))
# 2. random strings over YAML-significant alphabet
alpha = list("ab:  \n-[]{},'\"\\#|>?&*!\t1.%@`<=x~+0e") + ["\n  ", "\n- ", ": ", "- ", "  ", "x-", "\\x3E", "\\n", "'a'", '"b"', "[1, 2]", "{a: b}", "|\n  ", ">\n  ", "---\n", "...\n", "? ", "\n? "]
for _ in range(int(sys.argv[3]) if len(sys.argv) > 3 else 6000):
    n = random.randint(1, 25)
    s = "".join(random.choice(alpha) for _ in range(n))
    cases.append(random.choice(["", "k: ", "k:\n  ", "k:\n- ", "- ", "k: [", "k: {", "k: '", 'k: "', "k: |\n  ", "k: >\n  "]) + s)
# 3. structured random documents
def scalar(flow=False):
    r = random.random()
    words = ["a", "b c", "1", "-.5", "0.5", "1e+3", "yes", "true", "null", "~", "x: y", "a#b", "a #b", "2026-01-01", "http://x", "a,b", "[x]", "'q'", "", "日本", "x\ty", "@a", "07", "0x1f", "1_0", "+1", ".inf"]
    w = random.choice(words)
    if r < 0.4: return w
    if r < 0.6: return "'" + w.replace("'", "''") + "'"
    if r < 0.8: return '"' + w.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return w + random.choice(["", " ", "  # c"])
def node(ind, depth):
    r = random.random()
    pad = " " * ind
    if depth > 3 or r < 0.4:
        return " " + scalar()
    if r < 0.55:
        items = ", ".join(scalar(True) for _ in range(random.randint(0, 3)))
        return " [" + items + random.choice(["]", ",]", "\n" + pad + "  ]"])
    if r < 0.65:
        items = ", ".join(f"{scalar(True)}: {scalar(True)}" for _ in range(random.randint(0, 3)))
        return " {" + items + "}"
    if r < 0.8:
        step = random.choice([0, 2, 1, 3])
        lines = [""]
        for _ in range(random.randint(1, 3)):
            lines.append(pad + " " * step + "-" + node(ind + step + 2, depth + 1))
        return "\n".join(lines)
    step = random.choice([2, 1, 4])
    lines = [""]
    for _ in range(random.randint(1, 3)):
        lines.append(pad + " " * step + random.choice(["a", "b", "c", "x-k", "'q'", '"d"']) + ":" + node(ind + step, depth + 1))
    if random.random() < 0.15:
        lines.append(pad + " " * step + random.choice(["|", ">", "|-", ">+"]) )
    return "\n".join(lines)
for _ in range(int(sys.argv[4]) if len(sys.argv) > 4 else 4000):
    doc = []
    for _ in range(random.randint(1, 4)):
        doc.append(random.choice(["a", "b", "c", "x-k", "schema"]) + ":" + node(0, 0))
    t = "\n".join(doc)
    if random.random() < 0.1:
        t = t.replace("\n", "\n\n", 1)
    if random.random() < 0.05:
        t = "---\n" + t
    cases.append(t)
json.dump(cases, open(sys.argv[1], "w"))
print(len(cases))
