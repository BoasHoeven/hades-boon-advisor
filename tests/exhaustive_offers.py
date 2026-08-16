"""Exhaustively score the installed game's offer pool for every aspect.

The advisor assigns a deterministic scalar score to each option. Scoring every
legal candidate therefore covers the winner of every possible three-option
screen without materializing millions of equivalent triplets. This uses the
installed LootData, TraitData, duo/legendary gates, and exclusion rules.
"""
import io
import math
import os
import statistics
import sys

src = io.open(os.path.join(os.path.dirname(__file__), "test_boonadvisor.py"),
              encoding="utf-8").read()
exec(src.split("###########################################################################")[0])

loot = lua.eval("LootData")
trait_data = lua.eval("TraitData")
linked = lua.eval("BoonAdvisor.GetLinkedIndex()")
archetypes = lua.eval("BoonAdvisor.Ratings.Archetypes")
hammers = lua.eval("BoonAdvisor.Ratings.Hammers")
config = G["BoonAdvisor"]["Config"]


def sequence(value):
    if value is None:
        return []
    return [value[i] for i in range(1, len(value) + 1)]


requirements = {}
for i in range(1, len(linked) + 1):
    entry = linked[i]
    requirements[entry["Name"]] = [
        set(sequence(entry["Sets"][j]))
        for j in range(1, len(entry["Sets"]) + 1)
    ]


def trait_gate_met(name, held):
    data = trait_data[name]
    if data is None:
        return False
    sets = requirements.get(name)
    if sets and not all(group & held for group in sets):
        return False
    required = data["RequiredTrait"]
    if required is not None and required not in held:
        return False
    required_all = set(sequence(data["RequiredTraits"]))
    if required_all and not required_all.issubset(held):
        return False
    required_one = set(sequence(data["RequiredOneOfTraits"]))
    if required_one and not required_one.intersection(held):
        return False
    blocked = set(sequence(data["RequiredFalseTraits"]))
    blocked_one = data["RequiredFalseTrait"]
    if blocked_one is not None:
        blocked.add(blocked_one)
    return not blocked.intersection(held)


gods = ["ZeusUpgrade", "PoseidonUpgrade", "AthenaUpgrade", "AresUpgrade",
        "AphroditeUpgrade", "ArtemisUpgrade", "DionysusUpgrade",
        "DemeterUpgrade", "HermesUpgrade"]
boon_pool = []
for god in gods:
    data = loot[god]
    for field in ("WeaponUpgrades", "Traits"):
        boon_pool.extend(sequence(data[field]))
    upgrades = data["LinkedUpgrades"]
    if upgrades is not None:
        boon_pool.extend(list(upgrades.keys()))
boon_pool = sorted(set(name for name in boon_pool if trait_data[name] is not None))

aspect_routes = {}
for i in range(1, len(archetypes) + 1):
    route = archetypes[i]
    aspect = route["Aspect"]
    if aspect is None:
        continue
    members = set(sequence(route["Core"]))
    if route["Payoff"] is not None:
        members.add(route["Payoff"])
    aspect_routes.setdefault(aspect, set()).update(members)

weapon_aspects = {
    "Sword": {"SwordBaseUpgradeTrait", "SwordCriticalParryTrait",
              "DislodgeAmmoTrait", "SwordConsecrationTrait"},
    "Spear": {"SpearBaseUpgradeTrait", "SpearTeleportTrait",
              "SpearWeaveTrait", "SpearSpinTravel"},
    "Shield": {"ShieldBaseUpgradeTrait", "ShieldRushBonusProjectileTrait",
               "ShieldTwoShieldTrait", "ShieldLoadAmmoTrait"},
    "Bow": {"BowBaseUpgradeTrait", "BowMarkHomingTrait",
            "BowLoadAmmoTrait", "BowBondTrait"},
    "Fist": {"FistBaseUpgradeTrait", "FistVacuumTrait",
             "FistWeaveTrait", "FistDetonateTrait"},
    "Gun": {"GunBaseUpgradeTrait", "GunGrenadeSelfEmpowerTrait",
            "GunManualReloadTrait", "GunLoadedGrenadeTrait"},
}


def weapon_for(aspect):
    return next(prefix for prefix, aspects in weapon_aspects.items()
                if aspect in aspects)


failures = []
candidate_total = 0
triplet_total = 0
profile_total = 0

print("%-27s %6s %13s %14s" %
      ("aspect", "legal", "triplet sets", "best route rank"))
print("-" * 68)

if len(aspect_routes) != 24:
    failures.append("expected 24 aspects, found %d" % len(aspect_routes))

for aspect in sorted(aspect_routes):
    held = {aspect}
    legal = [name for name in boon_pool if trait_gate_met(name, held)]
    route_legal = aspect_routes[aspect].intersection(legal)
    if not route_legal:
        failures.append("%s has no legal configured route choice" % aspect)
        continue

    balanced_scores = None
    for objective in ("Balanced", "Speed", "HighHeat"):
        config["Objective"] = objective
        build(aspect)
        scores = [(boon(name)["RawScore"], name) for name in legal]
        if any(value < 0 or value > 99 for value, _ in scores):
            failures.append("%s/%s produced an out-of-range score" %
                            (aspect, objective))
        probe = scores[:min(12, len(scores))]
        repeated = [(boon(name)["RawScore"], name) for _, name in probe]
        if any(abs(a[0] - b[0]) > 0.0001 for a, b in zip(probe, repeated)):
            failures.append("%s/%s is not deterministic" % (aspect, objective))
        if objective == "Balanced":
            balanced_scores = scores
        profile_total += len(scores)

    values = [value for value, _ in balanced_scores]
    route_best = max(value for value, name in balanced_scores
                     if name in route_legal)
    rank = 1 + sum(value > route_best for value in values)
    if route_best < statistics.median(values):
        failures.append("%s route choices fall below the offer-pool median" % aspect)

    prefix = weapon_for(aspect)
    weapon_hammers = [name for name in hammers.keys()
                      if str(name).startswith(prefix)]
    if not weapon_hammers:
        failures.append("%s has no hammer pool" % aspect)
    else:
        build(aspect)
        for name in weapon_hammers:
            result = score(lua.table(ItemName=name, Rarity="Common", Type="Trait"),
                           lua.table(Name="WeaponUpgrade"))
            if result["RawScore"] < 0 or result["RawScore"] > 99:
                failures.append("%s hammer %s is out of range" % (aspect, name))

    candidate_total += len(legal)
    triplet_total += math.comb(len(legal), 3)
    print("%-27s %6d %13d %8d / %-4d" %
          (aspect, len(legal), math.comb(len(legal), 3), rank, len(legal)))

config["Objective"] = "Balanced"
build()
print("\nScored %d aspect/candidate pairs across three objectives (%d evaluations)." %
      (candidate_total, profile_total))
print("That total ordering covers %d possible three-option screens." % triplet_total)

if failures:
    print("\nFAILED %d check(s):" % len(failures))
    for failure in failures:
        print("  - " + failure)
    sys.exit(1)
print("All 24 aspects passed exhaustive offer-pool checks.")
