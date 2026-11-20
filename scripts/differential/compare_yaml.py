# Supplemental differential: compare the per-text outcomes of py_yaml.py and yaml_cases.jl.
# Usage: compare_yaml.py CASES.json PY.json JL.json [MAX_SHOWN]; exits 1 on any difference.
import json, sys, hashlib
from pathlib import Path
import yaml

def policy_delta(text, python, julia):
    # Classify by the YAML lexer, not a text-prefix regex: quoted/scalar text
    # containing %YAML or --- is not a directive or document token.
    if not python['ok'] or julia['ok'] or not julia.get('e','').startswith('R12:'):
        return False
    if 'YAML directives and document-start markers are forbidden' not in julia.get('e',''):
        return False
    try:
        return any(isinstance(token,(yaml.tokens.DirectiveToken,yaml.tokens.DocumentStartToken)) for token in yaml.scan(text))
    except yaml.YAMLError:
        return False

if len(sys.argv)>1 and sys.argv[1]=='--self-test':
    p={'ok':True}; j={'ok':False,'e':'R12: YAML directives and document-start markers are forbidden'}
    assert policy_delta('%YAML 1.2\n---\na: 1\n',p,j)
    assert policy_delta('---\na: 1\n',p,j)
    assert not policy_delta('a: "%YAML 1.2"\n',p,j)
    assert not policy_delta('a: "---"\n',p,j)
    assert not policy_delta('a: 1\n',p,j)
    assert not policy_delta('---\na: 1\n',p,{'ok':False,'e':'unrelated infrastructure error'})
    assert not policy_delta('---\na: 1\n',{'ok':False},j)
    assert not policy_delta('---\na: 1\n',p,{'ok':True})
    print('D10 differential classifier: 8 controls passed')
    sys.exit(0)

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
assert cases and len(cases)==len(py)==len(jl), 'empty/truncated differential input'
controls=json.load(open(Path(__file__).with_name('expected-policy-cases.json')))['cases']
required={case['text']:case['id'] for case in controls}
assert set(required)<=set(cases), 'named D10 control texts missing'
seen=set()
policy=0
bad = 0
for i, (t, p, j) in enumerate(zip(cases, py, jl)):
    same = p['ok'] == j['ok'] and (not p['ok'] or canon(p['v']) == canon(j['v']))
    if policy_delta(t,p,j):
        policy+=1
        if t in required: seen.add(required[t])
        print(f"EXPECTED D10-R12 #{i} sha256={hashlib.sha256(t.encode()).hexdigest()}")
        continue
    if not same:
        bad += 1
        if bad <= int(sys.argv[4] if len(sys.argv) > 4 else 40):
            print(f"#{i} {t[:120]!r}\n   py: {p.get('v') or p.get('e')}\n   jl: {j.get('v') or j.get('e')}")
assert seen==set(required.values()), f'named D10 deltas not observed: {set(required.values())-seen}'
print(f"unexplained differences: {bad} of {len(cases)} YAML texts; {policy} explicit D10-R12 deltas ({sum(p['ok'] for p in py)} accepted by frozen toolkit)")
sys.exit(1 if bad else 0)
