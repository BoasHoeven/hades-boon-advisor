"""
For each of the 24 aspects: does the scoring model steer toward its configured
archetype?

Method: equip only that aspect, then score the archetype's Core/Payoff boons
alongside a control set of unrelated boons. The build boons should outrank the
controls. This is an internal-consistency regression check; it does not prove
that the configured archetype is objectively the community's best build.
"""
import io, os

src = io.open(os.path.join(os.path.dirname(__file__), "test_boonadvisor.py"),
              encoding="utf-8").read()
exec(src.split("###########################################################################")[0])

arch = lua.eval("BoonAdvisor.Ratings.Archetypes")
# Controls must be genuinely mediocre. The first version used Athena's and
# Poseidon's Aid, which stopped being neutral the moment the Calls were
# re-rated -- Poseidon's Aid at 86 beat an aspect's own build and looked like a
# model failure when it was a stale control.
CONTROLS = ["ChamberGoldTrait", "TrapDamageTrait", "EnemyDamageTrait"]

failures = []
print("%-28s %-22s %s" % ("aspect", "top build pick", "verdict"))
print("-" * 78)

for i in range(1, len(arch) + 1):
    a = arch[i]
    aspect = a["Aspect"]
    if aspect is None:
        continue
    aspect_disp = names.get(aspect, aspect)

    build(aspect)
    core = a["Core"]
    build_names = [core[j] for j in range(1, len(core) + 1)]
    if a["Payoff"] is not None:
        build_names.append(a["Payoff"])

    scored = []
    for n in build_names:
        r = boon(n)
        scored.append((r["Score"], n, r["Reason"]))
    ctrl = []
    for n in CONTROLS:
        r = boon(n)
        ctrl.append((r["Score"], n))

    scored.sort(reverse=True)
    best_build = scored[0]
    best_ctrl = max(ctrl)

    ok = best_build[0] > best_ctrl[0]
    verdict = "ok" if ok else "FAIL (control %s=%d wins)" % (
        names.get(best_ctrl[1], best_ctrl[1]), best_ctrl[0])
    if not ok:
        failures.append((aspect_disp, a["Name"], verdict))

    print("%-28s %-22s %s" % (
        aspect_disp[:27],
        "%s=%d" % (names.get(best_build[1], best_build[1])[:15], best_build[0]),
        verdict))

print()
if failures:
    print("ASPECT CONFIGURATIONS THAT FAIL THEIR CONTROL: %d" % len(failures))
    for d, n, v in failures:
        print("   %-26s %-24s %s" % (d, n, v))
    sys.exit(1)
else:
    print("All aspect builds outrank the controls.")
