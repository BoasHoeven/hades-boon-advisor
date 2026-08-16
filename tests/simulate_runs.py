"""
Does following the advice actually assemble a strong build?

Simulates runs: each boon room offers 3 eligible boons from a random god, the
model's top pick is always taken, and we see what build emerges -- how many
duo paths become unlocked, and whether it lands on the aspect's configured
archetype.

Limits worth stating: the offer generator is an approximation of the game's
(random god, 3 eligible boons, no rarity roll), and "duo paths unlocked" counts
prerequisites satisfied, not duos actually rolled and offered. So this measures
whether the ADVICE converges on strong structures, not a win rate.
"""
import io, os, random, sys
from collections import Counter

src = io.open(os.path.join(os.path.dirname(__file__), "test_boonadvisor.py"),
              encoding="utf-8").read()
exec(src.split("###########################################################################")[0])

GODS = ["ZeusUpgrade", "AresUpgrade", "ArtemisUpgrade", "AphroditeUpgrade",
        "DionysusUpgrade", "AthenaUpgrade", "PoseidonUpgrade", "DemeterUpgrade"]
loot = lua.eval("LootData")
idx = lua.eval("BoonAdvisor.GetLinkedIndex()")
arch = lua.eval("BoonAdvisor.Ratings.Archetypes")
traitdata = lua.eval("TraitData")

# god -> its offerable boons
pool = {}
for g in GODS:
    li = loot[g]
    names_ = []
    for key in ("WeaponUpgrades", "Traits"):
        l = li[key]
        if l:
            for i in range(1, len(l) + 1):
                names_.append(l[i])
    lu = li["LinkedUpgrades"]
    if lu:
        for k in list(lu.keys()):
            names_.append(k)
    pool[g] = [n for n in dict.fromkeys(names_) if traitdata[n] is not None]

# linked boon -> prerequisite sets; duo -> prerequisite sets
requirements = {}
duos = {}
for i in range(1, len(idx) + 1):
    e = idx[i]
    sets = e["Sets"]
    parsed = [[sets[k][j] for j in range(1, len(sets[k]) + 1)]
              for k in range(1, len(sets) + 1)]
    requirements[e["Name"]] = parsed
    if e["Kind"] == "Duo":
        duos[e["Name"]] = parsed

arch_by_aspect = {}
for i in range(1, len(arch) + 1):
    a = arch[i]
    if a["Aspect"] is None:
        continue
    core = a["Core"]
    members = set(core[j] for j in range(1, len(core) + 1))
    if a["Payoff"]:
        members.add(a["Payoff"])
    arch_by_aspect.setdefault(a["Aspect"], []).append((a["Name"], members))


def duo_paths_unlocked(held):
    n = 0
    for name, sets in duos.items():
        if all(any(t in held for t in s) for s in sets):
            n += 1
    return n


def eligible_linked(name, held):
    """Match the game's OneOf / OneFromEachSet gate for linked upgrades."""
    sets = requirements.get(name)
    return sets is None or all(any(t in held for t in group) for group in sets)


def run_once(aspect, rooms, rng, pick_best=True):
    held = [aspect]
    build(*held)
    for _ in range(rooms):
        g = rng.choice(GODS)
        cands = [c for c in pool[g]
                 if c not in held and eligible_linked(c, set(held))]
        if len(cands) < 3:
            continue
        offer = rng.sample(cands, 3)
        scored = []
        for c in offer:
            r = boon(c)
            scored.append((r["Score"], c))
        if pick_best:
            chosen = max(scored)[1]
        else:
            chosen = rng.choice(offer)          # control: pick at random
        held.append(chosen)
        build(*held)
    return held


def summarise(aspect, held):
    d = duo_paths_unlocked(set(held))
    best_name, best_hits = None, 0
    for name, members in arch_by_aspect.get(aspect, []):
        hits = len(members & set(held))
        if hits > best_hits:
            best_name, best_hits = name, hits
    return d, best_name, best_hits


ROOMS = 12
TRIALS = 6
rng = random.Random(20260805)

print("Following the advice for %d boon rooms, %d trials per aspect\n" % (ROOMS, TRIALS))
print("%-26s %-14s %-14s %s" % ("aspect", "paths (advice)", "paths (random)", "archetype hits"))
print("-" * 78)

tot_advice, tot_random = [], []
for aspect in sorted(arch_by_aspect):
    a_d, r_d, hits_list, names_seen = [], [], [], Counter()
    for t in range(TRIALS):
        held = run_once(aspect, ROOMS, random.Random(1000 + t))
        d, an, hits = summarise(aspect, held)
        a_d.append(d); hits_list.append(hits)
        if an:
            names_seen[an] += 1
        held_r = run_once(aspect, ROOMS, random.Random(1000 + t), pick_best=False)
        r_d.append(summarise(aspect, held_r)[0])
    tot_advice += a_d; tot_random += r_d
    top = names_seen.most_common(1)
    print("%-26s %-14s %-14s %s" % (
        names.get(aspect, aspect)[:25],
        "%.1f" % (sum(a_d) / len(a_d)),
        "%.1f" % (sum(r_d) / len(r_d)),
        "%.1f/%s" % (sum(hits_list) / len(hits_list), top[0][0] if top else "-")))

print()
print("MEAN duo paths unlocked -- advice %.2f vs random %.2f  (%.0f%% better)" % (
    sum(tot_advice) / len(tot_advice), sum(tot_random) / len(tot_random),
    100 * (sum(tot_advice) / max(sum(tot_random), 1) - 1)))
