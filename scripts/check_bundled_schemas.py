#!/usr/bin/env python3
"""Offline audit of the bundled contracts in schemas/.

1. Every file listed in provenance.json matches its recorded SHA-256 on disk.
2. Every path in registry.json exists; every JSON file under schemas/ is accounted
   for in provenance.json (no undocumented schema can enter the bundle).
3. No FHT or FHGM row, path or schema file appears anywhere (rule V7: drafts take
   no release form).
4. provenance.json records the declared dialect of every contract; the released
   v0.5.0/v0.6.0 copies must declare JSON Schema draft/2020-12.

Exits non-zero with the full list on any failure. Standard library only.
"""
import hashlib
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schemas")
failures = []

prov_path = os.path.join(ROOT, "provenance.json")
prov = json.load(open(prov_path))
files = prov["files"]

for rel, meta in sorted(files.items()):
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        failures.append(f"provenance lists {rel} but the file is missing")
        continue
    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if got != meta["sha256"]:
        failures.append(f"{rel}: sha256 {got} != provenance {meta['sha256']}")

reg = json.load(open(os.path.join(ROOT, "registry.json")))
listed = set()
for entry in reg["files"].values():
    for rel in entry.values():
        listed.add(rel)
        if not os.path.isfile(os.path.join(ROOT, rel)):
            failures.append(f"registry.json lists {rel} but the file is missing")
extra = set()
for dirpath, _, names in os.walk(ROOT):
    for n in names:
        rel = os.path.relpath(os.path.join(dirpath, n), ROOT)
        if rel.endswith(".json") and not rel.startswith(("provenance", "registry", "versions")):
            extra.add(rel)
for rel in sorted(extra - set(files)):
    failures.append(f"{rel} is bundled but recorded neither in provenance.json")

for rel in sorted(set(files) | listed):
    low = rel.lower()
    if "fht" in low or "fhgm" in low:
        failures.append(f"V7 violation: draft type in bundled path {rel}")

# Structural check only: prose that STATES the absence of FHT/FHGM is fine; a type
# key, release row or supported entry naming them is a V7 violation.
for rel_dict in (reg["files"], reg.get("schemaVersions", {}), reg.get("releases", {})):
    for ref, row in rel_dict.items():
        keys = set(row.keys()) if isinstance(row, dict) else set()
        if keys & {"FHT", "FHGM"}:
            failures.append(f"V7 violation: draft type row under {ref} in registry.json")
if set(reg.get("supported", {}).keys()) - {"FHR", "FHP", "FHGFF3"}:
    failures.append("V7 violation: unsupported header type in registry.json supported list")
for rel, meta in files.items():
    if meta.get("headerType") in ("FHT", "FHGM"):
        failures.append(f"V7 violation: provenance records headerType for draft {rel}")

for rel in sorted(set(files)):
    low = rel.lower()
    if not low.endswith(".json"):
        continue
    meta = files[rel]
    doc = json.load(open(os.path.join(ROOT, rel)))
    declared = doc.get("$schema", "")
    if declared != meta.get("declaredDialect"):
        failures.append(f"{rel}: $schema {declared!r} != provenance declaredDialect")
    if low.split("/")[-2] in ("v0.5.0", "v0.6.0", "current") and declared != \
            "https://json-schema.org/draft/2020-12/schema":
        failures.append(f"{rel}: expected draft/2020-12, found {declared!r}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    print(f"FAILED: {len(failures)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"OK: {len(files)} bundled files verified against provenance.json and registry.json")
