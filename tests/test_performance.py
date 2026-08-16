"""Deterministic performance regressions for live advisor hot paths.

Wall-clock checks catch gross slowdowns, while generator and scoring call
budgets remain stable across different machines and are the primary guard.
"""

from __future__ import print_function

import contextlib
import io
import os
import runpy
import statistics
import time


HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "test_boonadvisor.py")

# Reuse the complete Lua 5.2/game-data harness without duplicating hundreds of
# stubs. Its output is suppressed on success; when the core suite fails (it
# raises SystemExit), replay the captured output so the [FAIL] lines that
# explain the exit are not swallowed with the buffer.
_core_output = io.StringIO()
try:
    with contextlib.redirect_stdout(_core_output):
        harness = runpy.run_path(CORE)
except BaseException:
    print(_core_output.getvalue(), end="")
    raise

lua = harness["lua"]
G = harness["G"]
build = harness["build"]
advisor = G["BoonAdvisor"]


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("[ok] %s" % message)


lua.execute("""
__performanceSetTraitsCalls = 0
__performanceOriginalSetTraitsOnLoot = SetTraitsOnLoot
__performanceOriginalGetEligibleUpgrades = GetEligibleUpgrades
function SetTraitsOnLoot(...)
    __performanceSetTraitsCalls = __performanceSetTraitsCalls + 1
    return __performanceOriginalSetTraitsOnLoot(...)
end
function __performanceSmallGetEligibleUpgrades(existing, lootData, upgradeChoiceData)
    return {
        { ItemName="AthenaRushTrait", Type="Trait" },
        { ItemName="ZeusWeaponTrait", Type="Trait" },
        { ItemName="PoseidonShoutTrait", Type="Trait" },
        { ItemName="ArtemisWeaponTrait", Type="Trait" },
    }
end
GetEligibleUpgrades = __performanceSmallGetEligibleUpgrades
__meta = BoonAdvisor.MetaKeys.RerollPanel
CurrentRun.NumRerolls = 3
CurrentRun.CurrentRoom = {}
BoonAdvisor.Config.LogPicks = false
""")

regular_pool = lua.table_from([
    lua.table(ItemName="AthenaRushTrait", Type="Trait"),
    lua.table(ItemName="ZeusWeaponTrait", Type="Trait"),
    lua.table(ItemName="PoseidonShoutTrait", Type="Trait"),
    lua.table(ItemName="ArtemisWeaponTrait", Type="Trait"),
])
regular_loot = lua.table(
    Name="ZeusUpgrade",
    ObjectId=9101,
    RarityChances=lua.table(Rare=0.10, Epic=0.05),
    RerollPool=regular_pool,
    UpgradeOptions=lua.table_from([
        lua.table(ItemName="ChamberGoldTrait", Type="Trait", Rarity="Common"),
        lua.table(ItemName="FallbackMoneyDrop", Type="Consumable", Rarity="Common"),
    ]),
)

build()
evaluate = lua.eval("BoonAdvisor.EvaluateReroll")
advisor["LastRerollEvaluation"] = None
regular = evaluate(regular_loot, 48)
check(regular["Method"] == "exact", "ordinary boon rerolls use exact probability math")
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "ordinary boon screens rebuild zero simulated loot screens")

# Cold evaluations clear the memoized result each time. This cap is generous
# enough for slower CI machines; the structural zero-generator assertion above
# is the portable performance contract.
durations = []
for _ in range(40):
    advisor["LastRerollEvaluation"] = None
    advisor["InvalidateForecastCache"]()
    started = time.perf_counter()
    evaluate(regular_loot, 48)
    durations.append(time.perf_counter() - started)

median_ms = statistics.median(durations) * 1000
p95_ms = sorted(durations)[int(len(durations) * 0.95) - 1] * 1000
check(median_ms < 10, "cold boon forecast median stays below 10 ms (%.2f ms)" % median_ms)
check(p95_ms < 25, "cold boon forecast p95 stays below 25 ms (%.2f ms)" % p95_ms)

# Exercise the full vanilla-style ordinary path too: static priority slots,
# linked rules, rarity-first selection and replacement chance.
actual_ordinary = lua.table(
    Name="ZeusUpgrade", ObjectId=9105,
    RarityChances=lua.table(Rare=0.10, Epic=0.05, Legendary=0.12),
)
advisor["InvalidateForecastCache"]()
lua.execute("__performanceSetTraitsCalls = 0")
started = time.perf_counter()
ordinary_live = advisor["ForecastInitialOffer"](actual_ordinary, "ordinary-performance")
ordinary_live_ms = (time.perf_counter() - started) * 1000
check(ordinary_live["Method"] == "exact",
      "ordinary god offers include deterministic vanilla priority rules")
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "ordinary god-door forecasting calls no simulated generator")
check(ordinary_live_ms < 25,
      "cold full ordinary forecast stays below 25 ms (%.2f ms)" % ordinary_live_ms)

# A real boon menu reroll forecast evaluates the full Olympian pool once for
# each visible card. The old four-entry fixture above could not expose stalls
# caused by repeated pool construction or context signatures.
actual_ordinary["UpgradeOptions"] = lua.table_from([
    lua.table(ItemName="ZeusWeaponTrait", Type="Trait", Rarity="Common"),
    lua.table(ItemName="ZeusSecondaryTrait", Type="Trait", Rarity="Rare"),
    lua.table(ItemName="ZeusShoutTrait", Type="Trait", Rarity="Epic"),
])
advisor["LastRerollEvaluation"] = None
advisor["InvalidateForecastCache"]()
started = time.perf_counter()
actual_reroll = evaluate(actual_ordinary, 72)
actual_reroll_ms = (time.perf_counter() - started) * 1000
check(actual_reroll["Method"] == "exact",
      "full Olympian menu rerolls use exact probability math")
print("[info] cold full-menu reroll forecast %.2f ms" % actual_reroll_ms)

# In game, exact reroll advice is deferred after the vanilla menu and grades
# are visible, then its three exclusion cases are distributed across frames.
# This structural assertion is more portable than a tiny wall-clock threshold.
lua.execute("""
__performanceForecastCalls = 0
__performanceWaitCalls = 0
__performanceNextComponent = 9500
__performanceQueuedThread = nil
__performanceOriginalForecastRerollPool = BoonAdvisor.ForecastRerollPool
function BoonAdvisor.ForecastRerollPool(...)
    __performanceForecastCalls = __performanceForecastCalls + 1
    return __performanceOriginalForecastRerollPool(...)
end
function CreateScreenComponent(args)
    __performanceNextComponent = __performanceNextComponent + 1
    return { Id = __performanceNextComponent }
end
function Attach(args) end
function DestroyTextBox(args) end
function Destroy(args) end
function wait(duration)
    __performanceWaitCalls = __performanceWaitCalls + 1
end
function thread(fn, args)
    __performanceQueuedThread = { Fn = fn, Args = args }
end
__boxes = {}
BoonAdvisor.LastRerollEvaluation = nil
BoonAdvisor.InvalidateForecastCache()
""")
started = time.perf_counter()
lua.eval("CreateBoonLootButtons")(actual_ordinary, False)
menu_open_ms = (time.perf_counter() - started) * 1000
check(lua.eval("__performanceForecastCalls") == 0,
      "boon menu opening performs no exact reroll forecast")
check(lua.eval("__performanceQueuedThread") is not None,
      "exact reroll advice is queued after the menu opens")
queued = lua.eval("__performanceQueuedThread")
queued["Fn"](queued["Args"])
check(lua.eval("__performanceForecastCalls") == 1,
      "the deferred worker still computes the exact forecast")
check(lua.eval("__performanceWaitCalls") >= 3,
      "full god rerolls yield before and between exclusion cases")
print("[info] synchronous advisor menu work %.2f ms" % menu_open_ms)

# A late-run build unlocks more linked choices. The previous tiny fixture hid
# an ordered-path explosion that took hundreds of milliseconds in Lua even
# though the work was deferred. Keep both the exact result and the chunked
# execution under regression coverage.
rich_traits = [
    "RoomRewardMaxHealthTrait", "ImprovedPomTrait", "AthenaSecondaryTrait",
    "ForcePoseidonBoonTrait", "AphroditeWeakenTrait", "CastBackstabTrait",
    "PoseidonRushTrait", "AresRangedTrait", "HermesSecondaryTrait",
    "PoseidonShoutTrait", "BonusDashTrait", "StatusImmunityTrait",
    "BowCloseAttackTrait", "CharmTrait", "AphroditeWeaponTrait",
    "AphroditeRetaliateTrait", "BowMarkHomingTrait", "SkellyAssistTrait",
    "ChaosBlessingRangedTrait", "IncreasedDamageTrait",
]
build(*rich_traits)
lua.execute("""
GetEligibleUpgrades = __performanceOriginalGetEligibleUpgrades
CurrentRun.NumRerolls = 4
CurrentRun.Money = 178
__performanceWaitCalls = 0
BoonAdvisor.LastRerollEvaluation = nil
BoonAdvisor.InvalidateForecastCache()
""")
rich_loot = lua.table(
    Name="PoseidonUpgrade", ObjectId=9111,
    RarityChances=lua.table(Rare=0.20, Epic=0.10),
    UpgradeOptions=lua.table_from([
        lua.table(ItemName="PoseidonWeaponTrait", Type="Trait", Rarity="Common"),
        lua.table(ItemName="PoseidonSecondaryTrait", Type="Trait", Rarity="Rare"),
        lua.table(ItemName="PoseidonShoutTrait", Type="Trait", Rarity="Epic"),
    ]),
)
started = time.perf_counter()
rich_result = evaluate(rich_loot, 72, lua.table(
    YieldBetweenScenarios=True, YieldWithinScenarios=True, YieldDuration=0.01))
rich_ms = (time.perf_counter() - started) * 1000
check(abs(rich_result["ExpectedScore"] - 83.2521576017) < 0.000001,
      "memoized late-run forecast preserves the exact expected score")
check(rich_ms < 100,
      "late-run exact reroll forecast stays below 100 ms total (%.2f ms)" % rich_ms)
check(lua.eval("__performanceWaitCalls") >= 6,
      "late-run forecast is split into frame-safe chunks")
print("[info] late-run exact reroll %.2f ms across %d yields" %
      (rich_ms, lua.eval("__performanceWaitCalls")))
build()
lua.execute("""
GetEligibleUpgrades = __performanceSmallGetEligibleUpgrades
CurrentRun.Money = 500
BoonAdvisor.LastRerollEvaluation = nil
BoonAdvisor.InvalidateForecastCache()
""")

# A closed or rerolled menu invalidates its worker before any forecast or draw.
lua.execute("__performanceQueuedThread = nil")
lua.eval("CreateBoonLootButtons")(actual_ordinary, False)
stale = lua.eval("__performanceQueuedThread")
calls_before_stale = lua.eval("__performanceForecastCalls")
advisor["BoonOverlayGeneration"] = advisor["BoonOverlayGeneration"] + 1
stale["Fn"](stale["Args"])
check(lua.eval("__performanceForecastCalls") == calls_before_stale,
      "a stale boon-menu worker cancels before forecasting")

# Poms already have a small owned-boon pool and were not reported as hitching.
# Keep their complete advice synchronous instead of delaying every menu type.
build("DionysusSecondaryTrait", "ArtemisShoutTrait",
      "AresShoutTrait", "PoseidonShoutTrait")
inline_pom = lua.table(
    Name="StackUpgrade", StackNum=1, ObjectId=9110,
    UpgradeOptions=lua.table_from([
        lua.table(ItemName="DionysusSecondaryTrait", Type="Trait"),
        lua.table(ItemName="ArtemisShoutTrait", Type="Trait"),
        lua.table(ItemName="AresShoutTrait", Type="Trait"),
    ]),
)
lua.execute("__performanceQueuedThread = nil")
calls_before_pom = lua.eval("__performanceForecastCalls")
lua.eval("CreateBoonLootButtons")(inline_pom, False)
check(lua.eval("__performanceQueuedThread") is None,
      "Pom advice remains immediate")
check(lua.eval("__performanceForecastCalls") == calls_before_pom + 1,
      "Pom rerolls still complete synchronously from their small pool")
build()
lua.execute("""
BoonAdvisor.ForecastRerollPool = __performanceOriginalForecastRerollPool
thread = nil
wait = nil
CreateScreenComponent = nil
Attach = nil
DestroyTextBox = nil
Destroy = nil
""")

# Trial gods are fixed before the exit preview. Ranking one performs exactly
# two deterministic god forecasts, then repeated door refreshes reuse both.
trial_room = lua.table(
    ChosenRewardType="Devotion", RoomSetName="Elysium",
    Encounter=lua.table(LootAName="ArtemisUpgrade",
                        LootBName="DionysusUpgrade"))
advisor["InvalidateForecastCache"]()
lua.execute("__performanceSetTraitsCalls = 0")
started = time.perf_counter()
advisor["ScoreDevotionDoor"](trial_room)
trial_ms = (time.perf_counter() - started) * 1000
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "known Trial doors forecast both gods without simulated screens")
check(trial_ms < 40,
      "cold two-god Trial forecast stays below 40 ms (%.2f ms)" % trial_ms)
hits_before = advisor["ForecastStats"]["Hits"] or 0
advisor["ScoreDevotionDoor"](trial_room)
hits_after = advisor["ForecastStats"]["Hits"] or 0
check(hits_after >= hits_before + 2,
      "repeated Trial scoring reuses both god forecasts")

# Retain the slower authoritative Monte Carlo implementation as an offline
# differential oracle. It is never called by live recommendations.
simulate = lua.eval("BoonAdvisor.SimulateReroll")
lua.execute("__performanceSetTraitsCalls = 0")
started = time.perf_counter()
simulated = simulate(regular_loot, 48, 512)
simulation_ms = (time.perf_counter() - started) * 1000
check(lua.eval("__performanceSetTraitsCalls") == 512,
	  "accuracy oracle performs the expected 512 simulated screens")
ordinary_delta = abs(regular["ExpectedScore"] - simulated["ExpectedScore"])
print("[info] ordinary exact %.2f, oracle %.2f" %
      (regular["ExpectedScore"], simulated["ExpectedScore"]))
check(ordinary_delta < 2,
	  "exact forecast agrees with the high-sample simulation oracle (delta %.2f)"
	  % ordinary_delta)

# Forecasts are memoized within an unchanged build and invalidated when the
# build changes. This keeps repeated door refreshes effectively free without
# ever returning a result scored for old boons.
advisor["InvalidateForecastCache"]()
first_cached = advisor["ForecastExactOffer"](
    regular_loot, lua.table(Mode="cache-test", CurrentBest=48))
second_cached = advisor["ForecastExactOffer"](
    regular_loot, lua.table(Mode="cache-test", CurrentBest=48))
check(not first_cached["CacheHit"] and second_cached["CacheHit"],
      "unchanged build state reuses the deterministic forecast cache")
build("ZeusWeaponTrait")
after_build = advisor["ForecastExactOffer"](
    regular_loot, lua.table(Mode="cache-test", CurrentBest=48))
check(not after_build["CacheHit"],
      "acquiring a boon invalidates cached forecasts")
build()

# Pom rerolls are exactly enumerable from the player's upgradeable boons.
build("DionysusSecondaryTrait", "ArtemisShoutTrait",
      "AresShoutTrait", "PoseidonShoutTrait")
pom_loot = lua.table(
    Name="StackUpgrade", StackNum=2, ObjectId=9102,
    UpgradeOptions=lua.table_from([
        lua.table(ItemName="ArtemisShoutTrait", Type="Trait"),
        lua.table(ItemName="AresShoutTrait", Type="Trait"),
        lua.table(ItemName="PoseidonShoutTrait", Type="Trait"),
    ]),
)
lua.execute("__performanceSetTraitsCalls = 0")
advisor["LastRerollEvaluation"] = None
pom = evaluate(pom_loot, 40)
check(pom["Method"] == "exact", "Pom rerolls use exact owned-boon probabilities")
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "Pom screens rebuild zero simulated loot screens")

# Even custom Chaos pair pools are deterministic and never invoke the live
# generator.
chaos_pool = lua.table_from([
    lua.table(ItemName="ChaosBlessingMeleeTrait",
              SecondaryItemName="ChaosCursePrimaryAttackTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingMaxHealthTrait",
              SecondaryItemName="ChaosCurseNoMoneyTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingBoonRarityTrait",
              SecondaryItemName="ChaosCurseDamageTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingMoneyTrait",
              SecondaryItemName="ChaosCurseSecondaryAttackTrait",
              Type="TransformingTrait"),
])
chaos_loot = lua.table(
    Name="TrialUpgrade", ObjectId=9103, RerollPool=chaos_pool,
    UpgradeOptions=lua.table_from([chaos_pool[1], chaos_pool[2], chaos_pool[3]]),
)
lua.execute("__performanceSetTraitsCalls = 0")
advisor["LastRerollEvaluation"] = None
chaos = evaluate(chaos_loot, 60)
check(chaos["Method"] == "exact-chaos", "Chaos rerolls use exact pair probabilities")
check(lua.eval("__performanceSetTraitsCalls") == 0,
	  "Chaos rerolls rebuild zero simulated loot screens")

# The real Chaos generator draws distinct blessings while each curse is
# removed from its pool 70% of the time. The advisor integrates that correlated
# process algebraically; this is the path used by an actual Chaos screen.
actual_chaos = lua.table(
    Name="TrialUpgrade", ObjectId=9104,
    RarityChances=lua.table(Rare=0.15, Epic=0.08),
)
build()
advisor["InvalidateForecastCache"]()
lua.execute("__performanceSetTraitsCalls = 0")
started = time.perf_counter()
chaos_exact = advisor["ForecastInitialOffer"](actual_chaos, "chaos-performance")
chaos_ms = (time.perf_counter() - started) * 1000
check(chaos_exact["Method"] == "exact-chaos",
      "the vanilla Chaos curse correlation is integrated exactly")
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "vanilla Chaos forecasting calls no simulated generator")
check(chaos_ms < 25,
      "cold exact Chaos forecast stays below 25 ms (%.2f ms)" % chaos_ms)

# Install a faithful test-only Chaos generator and compare the exact result to
# a large isolated simulation. This oracle is intentionally expensive and is
# never reachable from live UI hooks.
lua.execute("""
__performanceBaseSetTraitsOnLoot = __performanceOriginalSetTraitsOnLoot
function SetTraitsOnLoot(loot, args)
    __performanceSetTraitsCalls = __performanceSetTraitsCalls + 1
    if loot.Name == "ZeusUpgrade" and loot.RerollPool == nil then
        local options = {}
        for _, name in ipairs(LootData.ZeusUpgrade.PriorityUpgrades) do
            if IsGameStateEligible(CurrentRun, TraitData[name])
                and not HeroHasTrait(name) then
                table.insert(options, { ItemName=name, Type="Trait" })
            end
        end
        while #options > 3 do RemoveRandomValue(options) end
        for _, option in ipairs(options) do
            local levels = TraitData[option.ItemName].RarityLevels or {}
            if levels.Legendary and RandomChance(loot.RarityChances.Legendary or 0) then
                option.Rarity = "Legendary"
            elseif levels.Epic and RandomChance(loot.RarityChances.Heroic or 0) then
                option.Rarity = "Heroic"
            elseif levels.Epic and RandomChance(loot.RarityChances.Epic or 0) then
                option.Rarity = "Epic"
            elseif levels.Rare and RandomChance(loot.RarityChances.Rare or 0) then
                option.Rarity = "Rare"
            else option.Rarity = "Common" end
        end
        loot.UpgradeOptions = options
        return
    end
    if loot.Name ~= "TrialUpgrade" or loot.RerollPool ~= nil then
        return __performanceBaseSetTraitsOnLoot(loot, args)
    end
    local data = LootData.TrialUpgrade
    local permanent = {}
    local temporary = {}
    for _, name in ipairs(data.PermanentTraits) do
        if IsGameStateEligible(CurrentRun, TraitData[name]) then table.insert(permanent, name) end
    end
    for _, name in ipairs(data.TemporaryTraits) do
        if IsGameStateEligible(CurrentRun, TraitData[name]) then table.insert(temporary, name) end
    end
    loot.UpgradeOptions = {}
    while #loot.UpgradeOptions < 3 do
        local blessing = RemoveRandomValue(permanent)
        local curse
        if RandomChance(0.7) then curse = RemoveRandomValue(temporary)
        else curse = GetRandomValue(temporary) end
        local rarity
        if TraitData[blessing].RarityLevels
            and TableLength(TraitData[blessing].RarityLevels) == 1 then
            for key, _ in pairs(TraitData[blessing].RarityLevels) do rarity = key end
        elseif RandomChance(loot.RarityChances.Epic or 0) then rarity = "Epic"
        elseif RandomChance(loot.RarityChances.Rare or 0) then rarity = "Rare"
        else rarity = "Common" end
        table.insert(loot.UpgradeOptions, { ItemName=blessing,
            SecondaryItemName=curse, Type="TransformingTrait", Rarity=rarity })
    end
end
BoonAdvisor.InitialOfferCache = nil
BoonAdvisor.Config.DoorOfferSimulationSamples = 2048
__performanceSetTraitsCalls = 0
""")
ordinary_oracle = advisor["SimulateInitialOffer"](actual_ordinary, "ordinary-oracle")
check(lua.eval("__performanceSetTraitsCalls") == 2048,
      "ordinary differential oracle performs 2048 isolated priority screens")
ordinary_priority_delta = abs(
    ordinary_live["ExpectedScore"] - ordinary_oracle["ExpectedScore"])
print("[info] ordinary priority exact %.2f, oracle %.2f" %
      (ordinary_live["ExpectedScore"], ordinary_oracle["ExpectedScore"]))
check(ordinary_priority_delta < 1.5,
	  "exact ordinary priority forecast agrees with its high-sample oracle (delta %.2f)"
	  % ordinary_priority_delta)
lua.execute("BoonAdvisor.InitialOfferCache = nil; __performanceSetTraitsCalls = 0")
chaos_oracle = advisor["SimulateInitialOffer"](actual_chaos, "chaos-oracle")
check(lua.eval("__performanceSetTraitsCalls") == 2048,
      "Chaos differential oracle performs 2048 isolated screens")
check(abs(chaos_exact["ExpectedScore"] - chaos_oracle["ExpectedScore"]) < 1.5,
      "exact Chaos forecast agrees with its high-sample oracle")

# Approval Process exposes one or two uniformly selected entries from the same
# generated Chaos triple. Validate both algebraic branches as well.
for visible_choices in (1, 2):
    lua.execute("function CalcNumLootChoices() return %d end" % visible_choices)
    advisor["InvalidateForecastCache"]()
    exact_visible = advisor["ForecastInitialOffer"](
        actual_chaos, "chaos-exact-%d" % visible_choices)
    lua.execute("BoonAdvisor.InitialOfferCache = nil; __performanceSetTraitsCalls = 0")
    oracle_visible = advisor["SimulateInitialOffer"](
        actual_chaos, "chaos-oracle-%d" % visible_choices)
    check(abs(exact_visible["ExpectedScore"] - oracle_visible["ExpectedScore"]) < 1.5,
          "exact Chaos forecast matches Approval Process at %d choice(s)"
          % visible_choices)
lua.execute("function CalcNumLootChoices() return 3 end")

# With fewer eligible curses than built options the pool runs dry mid-screen
# and vanilla hands the remaining options no curse at all. The exact model
# enumerates that draw tree; hold it to the same oracle agreement, and make
# sure the result is a real number (the old closed form divided by zero here).
lua.execute("__chaosFullTemporary = LootData.TrialUpgrade.TemporaryTraits")
for pool_size in (1, 2):
    lua.execute(
        'LootData.TrialUpgrade.TemporaryTraits = { "ChaosCurseDamageTrait"%s }'
        % (', "ChaosCursePrimaryAttackTrait"' if pool_size == 2 else ""))
    advisor["InvalidateForecastCache"]()
    exact_small = advisor["ForecastInitialOffer"](
        actual_chaos, "chaos-small-%d" % pool_size)
    finite = (exact_small is not None
              and exact_small["ExpectedScore"] == exact_small["ExpectedScore"])
    check(finite, "a %d-curse Chaos pool yields a finite exact forecast" % pool_size)
    lua.execute("BoonAdvisor.InitialOfferCache = nil; __performanceSetTraitsCalls = 0")
    oracle_small = advisor["SimulateInitialOffer"](
        actual_chaos, "chaos-small-oracle-%d" % pool_size)
    if finite and oracle_small is not None:
        check(abs(exact_small["ExpectedScore"] - oracle_small["ExpectedScore"]) < 1.5,
              "exact Chaos forecast matches its oracle with a %d-curse pool"
              % pool_size)
lua.execute("LootData.TrialUpgrade.TemporaryTraits = __chaosFullTemporary")
advisor["InvalidateForecastCache"]()

# A refresh must never score an exit once for comparison and again for drawing.
lua.execute("""
__performanceDoorScoreCalls = 0
__performanceOriginalScoreDoorCandidate = BoonAdvisor.ScoreDoorCandidate
function BoonAdvisor.ScoreDoorCandidate(exitDoor)
    __performanceDoorScoreCalls = __performanceDoorScoreCalls + 1
    return __performanceOriginalScoreDoorCandidate(exitDoor)
end
CurrentRun.CurrentRoom = {}
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
BoonAdvisor.RegisterDoor({ ObjectId = 9201, DoorIconId = 9301,
    Room = { ChosenRewardType = "Money" } })
BoonAdvisor.RegisterDoor({ ObjectId = 9202, DoorIconId = 9302,
    Room = { ChosenRewardType = "Health" } })
BoonAdvisor.RefreshDoorOverlays()
BoonAdvisor.ScoreDoorCandidate = __performanceOriginalScoreDoorCandidate
""")
check(lua.eval("__performanceDoorScoreCalls") == 2,
      "door refresh scores each of two exits exactly once")

# RoomManager creates every preview in one tight loop. The live hook must
# coalesce those callbacks, otherwise the first door is rescored and redrawn
# when each later preview appears.
lua.execute("""
__performanceDoorRefreshCalls = 0
__performanceQueuedDoorThread = nil
__performanceOriginalRefreshDoorOverlays = BoonAdvisor.RefreshDoorOverlays
function BoonAdvisor.RefreshDoorOverlays(...)
    __performanceDoorRefreshCalls = __performanceDoorRefreshCalls + 1
    return __performanceOriginalRefreshDoorOverlays(...)
end
function wait(duration) end
function thread(fn, args)
    if fn == BoonAdvisor.SafeFinishQueuedDoorRefresh
        or fn == BoonAdvisor.FinishQueuedDoorRefresh then
        __performanceQueuedDoorThread = { Fn=fn, Args=args }
    else
        fn(args)
    end
end
CurrentRun.CurrentRoom = {}
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
__roomClearDoorA = { ObjectId=9211, DoorIconId=9311,
    Room={ ChosenRewardType="Money" } }
__roomClearDoorB = { ObjectId=9212, DoorIconId=9312,
    Room={ ChosenRewardType="Health" } }
AssignRoomToExitDoor(__roomClearDoorA, __roomClearDoorA.Room)
AssignRoomToExitDoor(__roomClearDoorB, __roomClearDoorB.Room)
CreateDoorRewardPreview(__roomClearDoorA)
CreateDoorRewardPreview(__roomClearDoorB)
""")
check(lua.eval("__performanceQueuedDoorThread") is not None,
      "room-clear door previews queue one deferred refresh")
check(lua.eval("__performanceDoorRefreshCalls") == 0,
      "door advice does no synchronous room-clear refresh")
queued_door = lua.eval("__performanceQueuedDoorThread")
queued_door["Fn"](queued_door["Args"])
check(lua.eval("__performanceDoorRefreshCalls") == 1,
      "all room-clear door previews are handled by one refresh")
check(advisor["LastDoorEvaluations"] is not None,
      "drawing registered doors preserves the completed evaluation cache")
lua.execute("""
BoonAdvisor.RefreshDoorOverlays = __performanceOriginalRefreshDoorOverlays
thread = nil
wait = nil
""")

# Keepsake recommendations inspect all 25 items, including eight actual god
# pools, once when the rack opens. They never invoke loot generation and every
# icon/hover reuses that completed rack evaluation.
lua.execute("""
CurrentRun.CurrentRoom = { Name="B_PostBoss01", RoomSetName="Asphodel" }
CurrentRun.BlockedKeepsakes = {}
CurrentRun.Hero.Health = 90
CurrentRun.Hero.MaxHealth = 150
CurrentRun.Hero.LastStands = { {}, {} }
CurrentRun.Money = 180
GameState.LastAwardTrait = "ForceDionysusBoonTrait"
SetBuild({ "BowMarkHomingTrait", "ForceDionysusBoonTrait",
    "DionysusSecondaryTrait", "AphroditeWeaponTrait" })
for _, trait in pairs(CurrentRun.Hero.Traits) do
    if trait.Name == "ForceDionysusBoonTrait" then trait.Uses = 0 end
end
__performanceSetTraitsCalls = 0
__performanceKeepsakeOptionCalls = 0
__performanceOriginalScoreOption = BoonAdvisor.ScoreOption
function BoonAdvisor.ScoreOption(...)
    __performanceKeepsakeOptionCalls = __performanceKeepsakeOptionCalls + 1
    return __performanceOriginalScoreOption(...)
end
""")
keepsake_durations = []
for _ in range(80):
    started = time.perf_counter()
    advisor["EvaluateKeepsakeRack"](G["__availableKeepsakes"])
    keepsake_durations.append(time.perf_counter() - started)
keepsake_option_calls = lua.eval("__performanceKeepsakeOptionCalls")
lua.execute("BoonAdvisor.ScoreOption = __performanceOriginalScoreOption")
keepsake_median_ms = statistics.median(keepsake_durations) * 1000
keepsake_p95_ms = sorted(keepsake_durations)[
    int(len(keepsake_durations) * 0.95) - 1] * 1000
check(lua.eval("__performanceSetTraitsCalls") == 0,
      "keepsake evaluation generates zero simulated loot screens")
check(keepsake_option_calls < 140 * len(keepsake_durations),
      "keepsake god-pool work stays within a fixed linear call budget")
check(keepsake_median_ms < 5,
      "cold 25-item keepsake rack median stays below 5 ms (%.2f ms)"
      % keepsake_median_ms)
check(keepsake_p95_ms < 12,
      "cold 25-item keepsake rack p95 stays below 12 ms (%.2f ms)"
      % keepsake_p95_ms)
check(not advisor["Config"]["LogPicks"], "disk telemetry remains off by default")

print("performance checks passed (ordinary median %.2f ms, p95 %.2f ms; "
	  "Trial %.2f ms; Chaos %.2f ms; keepsakes %.2f ms; "
	  "512-screen oracle %.2f ms)" %
	  (median_ms, p95_ms, trial_ms, chaos_ms, keepsake_median_ms, simulation_ms))
