"""
Compare BoonAdvisor's hand-authored ratings against structural evidence from
the game's own data, to surface:

  * hidden gems  - low rating but high duo reach and no lockout cost
  * overrated    - high rating but little reach and a real lockout cost

Reach alone is not power, so this is a shortlist for judgement, not a verdict.
"""
import io, os, sys

src = io.open(os.path.join(os.path.dirname(__file__), "test_boonadvisor.py"),
              encoding="utf-8").read()
exec(src.split("###########################################################################")[0])

idx = lua.eval("BoonAdvisor.GetLinkedIndex()")
base = lua.eval("BoonAdvisor.Ratings.Base")
pen = lua.eval("BoonAdvisor.ExclusionPenalty")
build()

# duo reach per trait
reach = {}
for i in range(1, len(idx) + 1):
    e = idx[i]
    if e["Kind"] != "Duo":
        continue
    sets = e["Sets"]
    for k in range(1, len(sets) + 1):
        st = sets[k]
        for j in range(1, len(st) + 1):
            reach[st[j]] = reach.get(st[j], 0) + 1

rated = sorted(set(base.keys()))
rows = []
for name in rated:
    r = base[name]
    d = reach.get(name, 0)
    p, why = pen(name)
    rows.append((name, r, d, int(p), why))

print("=== HIDDEN GEMS: rated <= 70 but feed >= 5 duos, no lockout ===")
gems = [x for x in rows if x[1] <= 70 and x[2] >= 5 and x[3] == 0]
gems.sort(key=lambda x: (-x[2], x[1]))
for n, r, d, p, why in gems:
    print("   rate %-3s  %d duos  %-26s" % (r, d, names.get(n, n)))
if not gems:
    print("   (none)")

print("\n=== POSSIBLY OVERRATED: rated >= 74 but <= 2 duos AND a real lockout ===")
over = [x for x in rows if x[1] >= 74 and x[2] <= 2 and x[3] < 0]
over.sort(key=lambda x: (x[2], -x[1]))
for n, r, d, p, why in over:
    print("   rate %-3s  %d duos  %-26s  %+d %s" % (r, d, names.get(n, n), p, why))
if not over:
    print("   (none)")

print("\n=== BIGGEST LOCKOUT COSTS among rated boons ===")
costly = sorted([x for x in rows if x[3] < 0], key=lambda x: x[3])[:8]
for n, r, d, p, why in costly:
    print("   %-26s rate %-3s  %+d  %s" % (names.get(n, n), r, p, why))

print("\n=== TOP DUO HUBS overall, with my rating ===")
hubs = sorted(reach.items(), key=lambda kv: -kv[1])[:14]
for n, d in hubs:
    r = base[n] if base[n] else "unrated"
    print("   %2d duos  rate %-8s %s" % (d, r, names.get(n, n)))
