#!/usr/bin/env python3
"""Assert the cascade against a known-answer corpus. Exit 1 on any mistake."""
import json, sqlite3, collections, sys
from pathlib import Path

CORPUS = Path(sys.argv[1])
CAT = Path.home() / 'Library/Application Support/PhotoMerge/catalog.sqlite'
truth = json.loads((CORPUS / '_truth.json').read_text())

got = collections.defaultdict(set)
for cid, name in sqlite3.connect(CAT).execute(
        "SELECT m.cluster_id, f.rel_path FROM member m JOIN file f ON f.id=m.file_id"):
    got[cid].add(name)
n2c = {n: cid for cid, ns in got.items() for n in ns}

fails = []
for fam in truth['groups']:
    members = fam['group']
    cids = {n2c.get(m) for m in members}
    if len(cids) != 1 or None in cids:
        fails.append(f"{fam['kind']}: not merged — {members}")
    else:
        extra = got[cids.pop()] - set(members)
        if extra:
            fails.append(f"{fam['kind']}: {members[0]} absorbed {sorted(extra)}")
for s in truth['singles']:
    cid = n2c.get(s)
    if cid is not None and len(got[cid]) > 1:
        fails.append(f"single {s} merged with {sorted(got[cid] - {s})}")

merged = len(truth['groups']) - sum(1 for f in fails if 'not merged' in f or 'absorbed' in f)
apart  = len(truth['singles']) - sum(1 for f in fails if f.startswith('single'))
print(f"  families merged correctly : {merged}/{len(truth['groups'])}")
print(f"  singles kept apart        : {apart}/{len(truth['singles'])}")
print(f"  clusters                  : {len(got)} (expected {len(truth['groups']) + len(truth['singles'])})")
for f in fails[:10]:
    print("  FAIL " + f)
sys.exit(1 if fails else 0)
