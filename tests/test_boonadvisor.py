"""
Offline harness for BoonAdvisor.

Runs the REAL mod sources in Lua 5.2 (the version Hades uses) against the REAL
TraitData.lua and LootData.lua. Only per-run state (CurrentRun) and the engine's
text/UI calls are stubbed; the duo graph, trait table, curse effects and all
scoring logic under test are genuine.

It cannot validate rendering or placement -- that needs the game.
"""
import io, re, sys, os, json

try:
    from lupa import lua52
except ImportError:
    sys.exit("This suite needs lupa (Lua 5.2):  pip install lupa")


def find_game():
    """Locate Hades/Content. Override with the HADES_PATH env var."""
    def content_candidates(root):
        if root.rstrip("\\/").endswith("Content"):
            return [root]
        return [
            os.path.join(root, "Content"),
            os.path.join(root, "Game.macOS.app", "Contents", "Resources", "Content"),
        ]

    env = os.environ.get("HADES_PATH")
    if env:
        for cand in content_candidates(env):
            if os.path.isfile(os.path.join(cand, "Scripts", "RoomManager.lua")):
                return cand
    home = os.path.expanduser("~")
    roots = [
        r"C:\Program Files (x86)\Steam\steamapps\common\Hades",
        r"C:\Program Files\Steam\steamapps\common\Hades",
        os.path.join(home, ".steam/steam/steamapps/common/Hades"),
        os.path.join(home, ".local/share/Steam/steamapps/common/Hades"),
        os.path.join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Hades"),
        os.path.join(home, "Library/Application Support/Steam/steamapps/common/Hades"),
    ]
    for r in roots:
        for cand in content_candidates(r):
            if os.path.isfile(os.path.join(cand, "Scripts", "RoomManager.lua")):
                return cand
    sys.exit("Could not find Hades. Set HADES_PATH to your install folder.")


GAME = find_game()
# Test the sources in this repo, not whatever happens to be installed.
MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod")

lua = lua52.LuaRuntime(unpack_returned_tuples=True)
G = lua.globals()
FAILURES = []


def check(cond, msg):
    print("   [%s] %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        FAILURES.append(msg)


# --- display names, so reasons read like the game ---------------------------
names, cur = {}, None
for line in io.open(os.path.join(GAME, "Game", "Text", "en", "HelpText.en.sjson"),
                    encoding="utf-8", errors="replace"):
    m = re.search(r'^\s*Id\s*=\s*"([^"]+)"', line)
    if m:
        cur = m.group(1); continue
    m = re.search(r'^\s*DisplayName\s*=\s*"([^"]*)"', line)
    if m and cur:
        names.setdefault(cur, m.group(1)); cur = None
lua.execute("__names = {}")
_t = G["__names"]
for k, v in names.items():
    _t[k] = v


def load(path):
    src = io.open(path, encoding="utf-8", errors="surrogateescape").read()
    fn = lua.eval("function(s, n) return load(s, n) end")(src, path)
    if fn is None:
        print("SYNTAX ERROR in %s" % path)
        sys.exit(1)
    fn()


# Auto-vivify unknown globals so the game's data files load standalone.
lua.execute("""
    __auto = {}
    __auto.__index = function(t, k)
        local v = setmetatable({}, __auto); rawset(t, k, v); return v end
    __auto.__call = function() return setmetatable({}, __auto) end
    setmetatable(_G, __auto)
""")
for f in ("TraitData.lua", "LootData.lua", "MetaUpgradeData.lua"):
    load(os.path.join(GAME, "Scripts", f))
# From here an undefined global must read as nil, as it would in the game,
# or every nil-guard under test is void.
lua.execute("setmetatable(_G, nil)")

lua.execute("""
function TableLength(t) local n=0 if t==nil then return 0 end
    for _ in pairs(t) do n=n+1 end return n end
function Contains(t,v) if t==nil then return false end
    for _,x in pairs(t) do if x==v then return true end end return false end
function IsEmpty(t) return t==nil or next(t)==nil end
function DebugPrint(a) end
CurrentRun = { Hero = { Traits = {}, IsDead = false, Health = 100, MaxHealth = 100 },
               Money = 500, CurrentRoom = {} }
GameState = { Cosmetics = {}, CosmeticsAdded = {}, MetaUpgradesSelected = {},
              KeepsakeChambers = {} }
function HeroHasTrait(n)
    for _,t in pairs(CurrentRun.Hero.Traits) do if t.Name==n then return true end end
    return false end
function GetTraitNameCount(u,n) local c=0
    for _,t in pairs(u.Traits) do if t.Name==n then c=c+1 end end return c end
-- The Pom offers a random subset of your non-temporary god boons.
function GetAllUpgradeableGodTraits()
    local out = {}
    for _, t in pairs(CurrentRun.Hero.Traits) do
        if TraitData[t.Name] ~= nil and TraitData[t.Name].God ~= nil then
            out[t.Name] = true
        end
    end
    return out
end
-- Deterministic tests feed this stand-in the same kind of copied loot that the
-- real mod sends to Hades' SetTraitsOnLoot. The private RNG installed by the
-- advisor controls every choice made here.
function SetTraitsOnLoot(loot, args)
    local excluded = {}
    for _, name in pairs(args and args.ExclusionNames or {}) do
        excluded[name] = true
    end
    local pool = {}
    if loot.RerollPool ~= nil then
        for _, option in ipairs(loot.RerollPool) do
            if not excluded[option.ItemName] then
                local copy = {}
                for key, value in pairs(option) do copy[key] = value end
                table.insert(pool, copy)
            end
        end
    elseif loot.Name == "StackUpgrade" then
        for name, _ in pairs(GetAllUpgradeableGodTraits()) do
            if not excluded[name] and IsGameStateEligible(CurrentRun, TraitData[name]) then
                table.insert(pool, { ItemName=name, Type="Trait", Rarity="Common" })
            end
        end
    else
        local defaults = {
            { ItemName="AthenaRushTrait", Type="Trait" },
            { ItemName="ZeusWeaponTrait", Type="Trait" },
            { ItemName="PoseidonShoutTrait", Type="Trait" },
            { ItemName="ArtemisWeaponTrait", Type="Trait" },
        }
        for _, option in ipairs(defaults) do
            if not excluded[option.ItemName] then table.insert(pool, option) end
        end
    end
    loot.UpgradeOptions = {}
    while #loot.UpgradeOptions < 3 and #pool > 0 do
        local option = RemoveRandomValue(pool)
        if option.Rarity == nil then
            local chances = loot.RarityChances or {}
            if RandomChance(chances.Epic or 0) then
                option.Rarity = "Epic"
            elseif RandomChance(chances.Rare or 0) then
                option.Rarity = "Rare"
            else
                option.Rarity = "Common"
            end
        end
        table.insert(loot.UpgradeOptions, option)
    end
    loot.BlockReroll = #pool == 0 and #loot.UpgradeOptions == 0
end
__ineligibleTrait = nil
function IsGameStateEligible(run, data)
    return __ineligibleTrait == nil or data ~= TraitData[__ineligibleTrait]
end
function CalcNumLootChoices() return 3 end
function GetTraitTooltipTitle(t) return t and t.Name or nil end
function HasDisplayName(a) return __names[a.Text] ~= nil end
function GetDisplayName(a) return __names[a.Text] end
function GetRunDepth(r) return __depth or 10 end
__meta = nil
function IsMetaUpgradeSelected(n) return n == __meta end
function SetBuild(list)
    CurrentRun.Hero.Traits = {}
    for _,n in ipairs(list) do table.insert(CurrentRun.Hero.Traits, {Name=n}) end
end
__boxes = {}
function CreateTextBox(a) table.insert(__boxes, a) end
ScreenAnchors = { ChoiceScreen = { Components = {
    PurchaseButton1={Id=101}, PurchaseButton2={Id=102}, PurchaseButton3={Id=103} }}}
__vanilla = { boon=0, door=0, sell=0 }
function CreateBoonLootButtons(l, r) __vanilla.boon = __vanilla.boon + 1 end
function CreateSellButtons() __vanilla.sell = __vanilla.sell + 1 end
function CreateKeepsakeIcon(c, a)
    local key = "UpgradeToggle" .. tostring(a.Index) .. (a.KeyAppend or "")
    c[key] = c[key] or { Id=3000 + a.Index, Data=a.UpgradeData }
end
function SetCursorFrame(b) end
function CloseUpgradeScreen(s, b) __vanilla.keepsakeClose = true end
function CreateDoorRewardPreview(d) __vanilla.door = __vanilla.door + 1 end
function AssignRoomToExitDoor(d, r) end
function SpawnStoreItemInWorld(i, k) end
__stock = {}
function SpawnStoreItemsInWorld()
    CurrentRun.CurrentRoom.Store = { SpawnedStoreItems = {} }
    for i, it in ipairs(__stock) do
        table.insert(CurrentRun.CurrentRoom.Store.SpawnedStoreItems,
                     { ObjectId = 900 + i, Cost = it.Cost })
        SpawnStoreItemInWorld(it.Data, i)
    end
end
function HasHeroTraitValue(n) return false end
__heat = 0
function GetTotalSpentShrinePoints() return __heat end
function GetEquippedWeapon() return __weapon end
__weapon = "BowWeapon"
-- Rarity roll inputs, mirroring HeroData/RoomManager.
CurrentRun.Hero.BoonData = { RareChance = 0.10, EpicChance = 0.05,
                             LegendaryChance = 0.12, ReplaceChance = 0.10 }
CurrentRun.Hero.HermesData = { RareChance = 0.06, EpicChance = 0.03 }
RerollCosts = { Boon = 1, Hammer = -1, ReuseIncrement = 1 }
__metaCounts = {}
function GetNumMetaUpgrades(n) return __metaCounts[n] or 0 end
function CalculateHealingMultiplier()
    local ranks = GetNumMetaUpgrades("HealingReductionShrineUpgrade") or 0
    local change = MetaUpgradeData.HealingReductionShrineUpgrade.ChangeValue
    return math.max(0, 1 - ranks * (change - 1))
end
__rarityBonusTraits = {}
function GetHeroTraitValues(n)
    if n == "RarityBonus" then return __rarityBonusTraits end
    return {}
end
SaveIgnores = { debug=true, _G=true, table=true, string=true, math=true,
                TraitData=true, LootData=true }
function Import(p)
    local f = p:match("([^/]+)$")
    assert(loadfile(__modpath .. __pathsep .. f))()
end
""")
G["__modpath"] = MOD
G["__pathsep"] = os.sep
load(os.path.join(MOD, "BoonAdvisor.lua"))
# The sampling oracle is test tooling, not part of the mod. Prove the mod does
# not ship it, then load it for the differential checks below.
MOD_SHIPS_ORACLE = (lua.eval("BoonAdvisor.SimulateReroll") is not None
                    or lua.eval("BoonAdvisor.SimulateInitialOffer") is not None
                    or G["BoonAdvisor"]["Config"]["AllowLiveSimulationFallback"] is not None)
load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "oracle.lua"))
DEFAULT_REROLL_SAMPLES = G["BoonAdvisor"]["Config"]["RerollSimulationSamples"]
DEFAULT_DOOR_SAMPLES = G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"]
G["BoonAdvisor"]["Config"]["RerollSimulationSamples"] = 96
G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"] = 0
print("loaded mod (%d archetypes)\n" % len(lua.eval("BoonAdvisor.Ratings.Archetypes")))

score = lua.eval("BoonAdvisor.ScoreOption")
scoredoor = lua.eval("BoonAdvisor.ScoreDoor")
scoreheal = lua.eval("BoonAdvisor.ScoreHealthDoor")
finalize = lua.eval("BoonAdvisor.Finalize")
rankfor = lua.eval("BoonAdvisor.RankFor")
setbuild = lua.eval("SetBuild")
mklist = lua.eval("function(...) return {...} end")
traitdata = lua.eval("TraitData")

# The equipped weapon follows the aspect in the build. Pinning every build to
# the bow made the hit-class terms evaluate non-bow aspects with bow cadence.
ASPECT_WEAPON = {
    "SwordBaseUpgradeTrait": "SwordWeapon", "SwordCriticalParryTrait": "SwordWeapon",
    "DislodgeAmmoTrait": "SwordWeapon", "SwordConsecrationTrait": "SwordWeapon",
    "SpearBaseUpgradeTrait": "SpearWeapon", "SpearTeleportTrait": "SpearWeapon",
    "SpearWeaveTrait": "SpearWeapon", "SpearSpinTravel": "SpearWeapon",
    "ShieldBaseUpgradeTrait": "ShieldWeapon", "ShieldRushBonusProjectileTrait": "ShieldWeapon",
    "ShieldTwoShieldTrait": "ShieldWeapon", "ShieldLoadAmmoTrait": "ShieldWeapon",
    "BowBaseUpgradeTrait": "BowWeapon", "BowMarkHomingTrait": "BowWeapon",
    "BowLoadAmmoTrait": "BowWeapon", "BowBondTrait": "BowWeapon",
    "FistBaseUpgradeTrait": "FistWeapon", "FistVacuumTrait": "FistWeapon",
    "FistWeaveTrait": "FistWeapon", "FistDetonateTrait": "FistWeapon",
    "GunBaseUpgradeTrait": "GunWeapon", "GunGrenadeSelfEmpowerTrait": "GunWeapon",
    "GunManualReloadTrait": "GunWeapon", "GunLoadedGrenadeTrait": "GunWeapon",
}


_weapon_from_aspect = False


def build(*traits):
    global _weapon_from_aspect
    setbuild(mklist(*traits))
    aspect = next((t for t in traits if t in ASPECT_WEAPON), None)
    if aspect is not None:
        G["__weapon"] = ASPECT_WEAPON[aspect]
        _weapon_from_aspect = True
    elif _weapon_from_aspect:
        # A build without an aspect returns to the bow default; a weapon a
        # test set by hand (__weapon = ...) is left alone.
        G["__weapon"] = "BowWeapon"
        _weapon_from_aspect = False


def boon(name, rarity="Common", typ="Trait", **kw):
    return score(lua.table(ItemName=name, Rarity=rarity, Type=typ, **kw), lua.table())


def pom(name, stack=1):
    loot = lua.table(Name="StackUpgrade", StackNum=stack, ObjectId=701)
    return score(lua.table(ItemName=name, Rarity="Common", Type="Trait"), loot)


def door(rtype, loot=None, **kwargs):
    room = lua.table(ChosenRewardType=rtype, ForceLootName=loot)
    for key, value in kwargs.items():
        room[key] = value
    s, why = scoredoor(room)
    v = int(finalize(s))
    return v, rankfor(v), why


def healing():
    s, why = scoreheal()
    v = int(finalize(s))
    return v, rankfor(v), why


###########################################################################
# EVERY game key the mod quotes must exist. An invented name does not error in
# Lua -- it silently never matches, which is how the Mirror awareness sat dead
# for hours. This scans the mod sources rather than a curated list, so a new
# invented key cannot slip in unnoticed.
print("=== every game key the mod quotes is real ===")
import glob
mod_src = ""
for _f in glob.glob(os.path.join(MOD, "*.lua")):
    mod_src += io.open(_f, encoding="utf-8", errors="replace").read()
meta_src = io.open(os.path.join(GAME, "Scripts", "MetaUpgradeData.lua"),
                   encoding="utf-8", errors="replace").read()
upgrade_keys = sorted(set(re.findall(r'"([A-Za-z]+(?:Shrine|Meta)Upgrade)"', mod_src)))
missing_keys = [k for k in upgrade_keys
                if not re.search(r"^\t" + k + r"\s*=", meta_src, re.M)]
check(not missing_keys,
      "all %d Mirror/Pact keys exist in MetaUpgradeData%s"
      % (len(upgrade_keys), "" if not missing_keys else " -- MISSING %s" % missing_keys))

# Same for effect names used to classify status curses.
effect_keys = sorted(set(lua.eval("BoonAdvisor.CurseEffects").keys()))
td_src = io.open(os.path.join(GAME, "Scripts", "TraitData.lua"), encoding="utf-8", errors="replace").read()
missing_fx = [k for k in effect_keys if ('EffectName = "%s"' % k) not in td_src]
check(not missing_fx,
      "all %d curse effect names appear in TraitData%s"
      % (len(effect_keys), "" if not missing_fx else " -- MISSING %s" % missing_fx))

print("\n=== every rating name is a real trait ===")
for table_name in ("Base", "Hammers", "AspectAffinity", "PomValue",
                   "AspectHitClass", "AspectTraitMod"):
    keys = list(lua.eval("BoonAdvisor.Ratings.%s" % table_name).keys())
    missing = [k for k in keys if traitdata[k] is None]
    check(not missing, "%s: %d keys, all real%s"
          % (table_name, len(keys), "" if not missing else " MISSING %s" % missing))
for shrine_name, hammer_table in lua.eval(
        "BoonAdvisor.Ratings.PactConditionalHammers").items():
    missing = [k for k in hammer_table.keys() if traitdata[k] is None]
    check(not missing, "Pact hammer modifiers for %s are all real%s"
          % (shrine_name, "" if not missing else " MISSING %s" % missing))
for shrine_name, boon_table in lua.eval(
        "BoonAdvisor.Ratings.PactConditionalBoons").items():
    missing = [k for k in boon_table.keys() if traitdata[k] is None]
    check(not missing, "Pact boon modifiers for %s are all real%s"
          % (shrine_name, "" if not missing else " MISSING %s" % missing))

objective_tags = lua.eval("BoonAdvisor.Ratings.ObjectiveTags")
bad_objective_traits = []
for tag_name in objective_tags.keys():
    bad_objective_traits.extend(
        "%s.%s" % (tag_name, name) for name in objective_tags[tag_name].keys()
        if traitdata[name] is None)
profiles = G["BoonAdvisor"]["Config"]["ObjectiveProfiles"]
for profile_name in profiles.keys():
    bonuses = profiles[profile_name]["KeepsakeBonus"]
    if bonuses is not None:
        bad_objective_traits.extend(
            "%s.KeepsakeBonus.%s" % (profile_name, name)
            for name in bonuses.keys() if traitdata[name] is None)
check(not bad_objective_traits,
      "objective profile trait names are real%s" %
      ("" if not bad_objective_traits else " MISSING %s" % bad_objective_traits))

arch = lua.eval("BoonAdvisor.Ratings.Archetypes")
bad = []
for i in range(1, len(arch) + 1):
    a = arch[i]
    for key in ("Aspect", "Payoff"):
        if a[key] is not None and traitdata[a[key]] is None:
            bad.append("%s.%s=%s" % (a["Name"], key, a[key]))
    core = a["Core"]
    for j in range(1, len(core) + 1):
        if traitdata[core[j]] is None:
            bad.append("%s.Core=%s" % (a["Name"], core[j]))
    foundation = a["Foundation"]
    if foundation is not None:
        for j in range(1, len(foundation) + 1):
            if traitdata[foundation[j]] is None:
                bad.append("%s.Foundation=%s" % (a["Name"], foundation[j]))
check(not bad, "Archetypes: all names real%s" % ("" if not bad else " BAD %s" % bad))

pairing_bad = []
for pairing in lua.eval("BoonAdvisor.Ratings.Pairings").values():
    for side in ("A", "B"):
        for name in pairing[side].values():
            if traitdata[name] is None:
                pairing_bad.append(name)
check(not pairing_bad, "mechanical pairing names are real%s" %
      ("" if not pairing_bad else " -- MISSING %s" % pairing_bad))

aspect_trait_bad = []
for aspect, bonuses in lua.eval("BoonAdvisor.Ratings.AspectTraitMod").items():
    for name in bonuses.keys():
        if traitdata[name] is None:
            aspect_trait_bad.append("%s->%s" % (aspect, name))
check(not aspect_trait_bad, "aspect-specific boon interactions use real traits%s" %
      ("" if not aspect_trait_bad else " -- MISSING %s" % aspect_trait_bad))

# Duplicate keys in a Lua literal silently overwrite the earlier value. Catch
# that source-level error because inspecting the loaded table cannot.
ratings_source = io.open(os.path.join(MOD, "BA_Ratings.lua"),
                         encoding="utf-8", errors="replace").read()
base_source = ratings_source.split("BoonAdvisor.Ratings.Base =", 1)[1].split(
    "-- A boon can be excellent", 1)[0]
base_keys = re.findall(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*=", base_source, re.M)
duplicate_base = sorted({name for name in base_keys if base_keys.count(name) > 1})
check(not duplicate_base, "Base rating literal has no duplicate keys%s" %
      ("" if not duplicate_base else " -- DUPLICATE %s" % duplicate_base))

linked = lua.eval("BoonAdvisor.GetLinkedIndex()")
linked_kinds = {"Duo": [], "Legendary": [], "Upgrade": []}
for i in range(1, len(linked) + 1):
    linked_kinds[linked[i]["Kind"]].append(linked[i]["Name"])
missing_linked_ratings = [name for kind in ("Duo", "Legendary", "Upgrade")
                          for name in linked_kinds[kind]
                          if lua.eval("BoonAdvisor.Ratings.Base")[name] is None]
check(len(linked_kinds["Duo"]) == 28 and len(linked_kinds["Legendary"]) == 11,
      "inheritance classifies all 28 Duo and 11 Legendary boons")
check(not missing_linked_ratings,
      "every Duo, Legendary, and gated upgrade has an explicit value%s" %
      ("" if not missing_linked_ratings else " -- MISSING %s" % missing_linked_ratings))

base_ratings = lua.eval("BoonAdvisor.Ratings.Base")
lootdata = lua.eval("LootData")
unrated_direct_passives = []
for loot_name in ("ZeusUpgrade", "PoseidonUpgrade", "AthenaUpgrade",
                  "AphroditeUpgrade", "AresUpgrade", "ArtemisUpgrade",
                  "DionysusUpgrade", "DemeterUpgrade", "HermesUpgrade"):
    direct = lootdata[loot_name]["Traits"]
    if direct is None:
        continue
    for i in range(1, len(direct) + 1):
        name = direct[i]
        if traitdata[name]["Slot"] is None and base_ratings[name] is None:
            unrated_direct_passives.append(name)
check(not unrated_direct_passives,
      "every directly offered non-slot god boon has an explicit value%s" %
      ("" if not unrated_direct_passives
       else " -- MISSING %s" % sorted(set(unrated_direct_passives))))

# A valid payoff name is not enough: each prerequisite group for that payoff
# must be represented in the archetype's Core. This catches routes that can
# score a duo/legendary highly while steering toward boons that cannot unlock it.
payoff_requirements = {}
for i in range(1, len(linked) + 1):
    entry = linked[i]
    sets = entry["Sets"]
    payoff_requirements[entry["Name"]] = [
        {sets[j][k] for k in range(1, len(sets[j]) + 1)}
        for j in range(1, len(sets) + 1)
    ]
unreachable = []
for i in range(1, len(arch) + 1):
    a = arch[i]
    payoff = a["Payoff"]
    if payoff is None:
        continue
    core = a["Core"]
    core_names = {core[j] for j in range(1, len(core) + 1)}
    requirements = payoff_requirements.get(payoff)
    if not requirements or any(not (core_names & group) for group in requirements):
        unreachable.append("%s -> %s" % (a["Name"], payoff))
check(not unreachable,
      "every archetype payoff is reachable from its Core%s"
      % ("" if not unreachable else " -- BAD %s" % unreachable))

ham = lua.eval("BoonAdvisor.Ratings.HammerAspectMod")
bad = []
for aspect in list(ham.keys()):
    if traitdata[aspect] is None:
        bad.append(aspect)
    for h in list(ham[aspect].keys()):
        if traitdata[h] is None:
            bad.append("%s->%s" % (aspect, h))
check(not bad, "HammerAspectMod: all names real%s" % ("" if not bad else " BAD %s" % bad))

hammer_pairing_bad = []
for pairing in lua.eval("BoonAdvisor.Ratings.HammerPairings").values():
    for key in ("A", "B"):
        if traitdata[pairing[key]] is None:
            hammer_pairing_bad.append(pairing[key])
check(not hammer_pairing_bad, "hammer pairing names are real%s" %
      ("" if not hammer_pairing_bad else " BAD %s" % hammer_pairing_bad))

aspects = {n: d for n, d in names.items()
           if d.startswith("Aspect of") and traitdata[n] is not None
           and not n.endswith("_Max")}
covered = set()
for i in range(1, len(arch) + 1):
    if arch[i]["Aspect"] is not None:
        covered.add(arch[i]["Aspect"])
missing = sorted(set(aspects) - covered)
check(not missing, "all %d aspects steered by an archetype%s"
      % (len(aspects), "" if not missing else " -- missing %s" % missing))

###########################################################################
print("\n=== core scoring ===")
build()
rows = {n: boon(n) for n in ("AthenaRushTrait", "ZeusWeaponTrait", "PoseidonShoutTrait")}
check(max(rows.items(), key=lambda kv: kv[1]["Score"])[0] == "AthenaRushTrait",
      "Divine Dash tops a fresh run")
ladder = [boon("ZeusWeaponTrait", r)["Score"] for r in ("Common", "Rare", "Epic", "Heroic")]
check(all(a < b for a, b in zip(ladder, ladder[1:])), "rarity ladder rises %s" % ladder)

check(base_ratings["PoseidonRushTrait"] >= 84
      and base_ratings["DionysusRangedTrait"] > base_ratings["DemeterRangedTrait"]
      and base_ratings["ZeusRangedTrait"] >= 70,
      "core dash and cast values match the audited balance ordering")
check(base_ratings["ZeusShoutTrait"] > base_ratings["PoseidonShoutTrait"]
      and base_ratings["DionysusShoutTrait"] > base_ratings["PoseidonShoutTrait"]
      and base_ratings["AphroditeShoutTrait"] > base_ratings["PoseidonShoutTrait"],
      "Calls favor strong one-bar damage and Aphrodite's boss burst")

base = boon("RetaliateWeaponTrait")
build("ZeusWeaponTrait", "AresWeaponTrait")
duo = boon("RetaliateWeaponTrait")
check("Vengeful Mood" in duo["Reason"] and duo["Score"] > base["Score"],
      "duo completion detected and scored higher (%d -> %d)" % (base["Score"], duo["Score"]))
build()
check("enables" not in base["Reason"], "no phantom duo on an empty build")

check(lua.eval("BoonAdvisor.KindOf")("FishingTrait") == "Legendary",
      "Huge Catch is classified as Legendary, not as a Duo")
huge_common = boon("FishingTrait", "Common")["RawScore"]
huge_legendary = boon("FishingTrait", "Legendary")["RawScore"]
check(abs(huge_common - huge_legendary) < 0.001,
      "fixed-rarity boons do not receive a second Legendary rarity bonus")

linked_scale = lua.eval("BoonAdvisor.LinkedValueScale")
check(linked_scale("TriggerCurseTrait") > linked_scale("AmmoBoltTrait"),
      "Merciful End completion is worth more than Lightning Rod completion")

build("GunGrenadeSelfEmpowerTrait", "ZeusWeaponTrait")
false_core = lua.eval("BoonAdvisor.ArchetypeBonus")(
    "AphroditeSecondaryTrait", None)[0]
real_core = lua.eval("BoonAdvisor.ArchetypeBonus")(
    "ZeusBonusBoltTrait", None)[0]
check(false_core == 0 and real_core > 0,
      "an archetype core bonus requires a real payoff prerequisite")

build("ZeusWeaponTrait")
pairing_gain = lua.eval("BoonAdvisor.MechanicalPairingBonus")(
    "ZeusLightningDebuff", None)[0]
check(pairing_gain > 0, "mechanical boon pairings add value outside Duo gates")

build("TriggerCurseTrait")
merciful_dash = lua.eval("BoonAdvisor.MechanicalPairingBonus")(
    "AthenaRushTrait", None)[0]
check(merciful_dash > 0, "Divine Dash gains value as a Merciful End trigger")

aspect_trait_bonus = lua.eval("BoonAdvisor.AspectTraitBonus")
build("FistBaseUpgradeTrait")
fist_chill = aspect_trait_bonus("DemeterWeaponTrait")[0]
build("BowMarkHomingTrait")
chiron_hangover = aspect_trait_bonus("DionysusSecondaryTrait")[0]
build("SwordBaseUpgradeTrait")
normal_sword_thunder_dash = aspect_trait_bonus("ZeusRushTrait")[0]
build("SwordConsecrationTrait")
arthur_thunder_dash = aspect_trait_bonus("ZeusRushTrait")[0]
check(fist_chill > 0 and chiron_hangover > 0,
      "fists Chill and Chiron Hangover receive their mechanical aspect value")
check(normal_sword_thunder_dash < arthur_thunder_dash,
      "Thunder Dash is penalized on dash-strike swords but not Arthur")

build("ZeusLightningDebuff", "AthenaRushTrait")
check(pom("ZeusLightningDebuff")["RawScore"] > pom("AthenaRushTrait")["RawScore"],
      "Pom scoring values marginal damage gain over non-scaling utility")

lua.execute("__weapon = 'FistWeapon'")
build()
fast_zeus = lua.eval("BoonAdvisor.HitStyleBonus")("ZeusWeaponTrait")[0]
fast_aphro = lua.eval("BoonAdvisor.HitStyleBonus")("AphroditeWeaponTrait")[0]
lua.execute("__weapon = 'GunWeapon'")
build("GunManualReloadTrait")
slow_zeus = lua.eval("BoonAdvisor.HitStyleBonus")("ZeusWeaponTrait")[0]
slow_aphro = lua.eval("BoonAdvisor.HitStyleBonus")("AphroditeWeaponTrait")[0]
check(fast_zeus > fast_aphro and slow_aphro > slow_zeus,
      "fast slots favor on-hit damage while Hestia favors large multipliers")
lua.execute("__weapon = 'BowWeapon'")
build()

check(finalize(120) > finalize(105) > finalize(95)
      and finalize(120) < 99,
      "top-end compression preserves ordering without flattening to 99")

###########################################################################
print("\n=== status curses / Mirror ===")
curse_of = lua.eval("BoonAdvisor.CurseTypeOf")
for t, want in (("AphroditeWeaponTrait", "Weak"), ("AresWeaponTrait", "Doom"),
                ("DionysusWeaponTrait", "Hangover"), ("DemeterWeaponTrait", "Chill"),
                ("ZeusLightningDebuff", "Jolted"), ("SlipperyTrait", "Ruptured"),
                ("AthenaBackstabDebuffTrait", "Exposed")):
    check(curse_of(t) == want, "%s applies %s" % (names.get(t, t), want))

# The Mirror keys must exist in MetaUpgradeData. Passing a name that matches
# nothing makes IsMetaUpgradeSelected silently always-false, which is exactly
# what happened with "EffectVulnerability"/"GodEnhancement".
meta_data = lua.eval("MetaUpgradeData")
keys = lua.eval("BoonAdvisor.MetaKeys")
for label in ("PrivilegedStatus", "FamilyFavorite"):
    k = keys[label]
    check(meta_data[k] is not None,
          "Mirror key %s = %r exists in MetaUpgradeData" % (label, k))

lua.execute("__meta = BoonAdvisor.MetaKeys.PrivilegedStatus")
build("AphroditeWeaponTrait")
new_curse, same_curse = boon("AresSecondaryTrait"), boon("AphroditeSecondaryTrait")
check("Privileged Status" in new_curse["Reason"]
      and new_curse["Score"] > same_curse["Score"],
      "2nd distinct curse beats more of the same (%d vs %d)"
      % (new_curse["Score"], same_curse["Score"]))
lua.execute("__meta = BoonAdvisor.MetaKeys.FamilyFavorite")
check("Family Favorite" in boon("PoseidonSecondaryTrait")["Reason"],
      "Family Favorite steers to new gods")
lua.execute("__meta = nil")

###########################################################################
print("\n=== replacement offers (ReplaceChance 0.10) ===")
# GetReplacementTraits offers a boon from this god that takes over a filled
# slot, at GetUpgradedRarity(existing) -- one tier above what you hold.
# Value is therefore (new at new rarity) - (old at old rarity).
build("ZeusWeaponTrait")


def swap(new, old, new_rarity, old_rarity):
    r = score(lua.table(ItemName=new, Rarity=new_rarity, Type="Trait",
                        TraitToReplace=old, OldRarity=old_rarity), lua.table())
    return r["Score"], r["Rank"], r["Reason"]


# Athena's attack (80) replacing Zeus' attack (68), Common -> Rare: clear gain.
up = swap("AthenaWeaponTrait", "ZeusWeaponTrait", "Rare", "Common")
# The reverse: a weaker boon taking over a strong one.
build("AthenaWeaponTrait")
down = swap("PoseidonWeaponTrait", "AthenaWeaponTrait", "Rare", "Common")
print("   Divine Strike(Rare) over Lightning Strike(Common): %s %d  %s" % (up[1], up[0], up[2]))
print("   Tempest Strike(Rare) over Divine Strike(Common):   %s %d  %s" % (down[1], down[0], down[2]))
check(up[0] > down[0], "a swap that gains value outranks one that loses it")
check("upgrade" in up[2], "a genuine upgrade is described as one (%r)" % up[2])
check("enables" not in down[2],
      "a replacement does not use the discarded boon to invent a duo (%r)" % down[2])
check("costs you" in down[2], "a losing swap says what it costs (%r)" % down[2])

# Replacing a prerequisite must remove the gated-boon progress it supplied.
build("DionysusSecondaryTrait", "AphroditeWeaponTrait")
synergy_loss, synergy_loss_reason = lua.eval("BoonAdvisor.EvaluateSynergy")(
    "ZeusWeaponTrait", "AphroditeWeaponTrait")
check(synergy_loss < 0 and "closes" in synergy_loss_reason["Text"],
      "a swap prices lost duo access (%s %.1f)"
      % (synergy_loss_reason["Text"], synergy_loss))

# The same applies to a known build core, not just the raw duo graph.
build("BowMarkHomingTrait", "DionysusSecondaryTrait")
breaks_chiron = swap("PoseidonSecondaryTrait", "DionysusSecondaryTrait",
                     "Rare", "Common")
check("breaks the Chiron Hangover build" in breaks_chiron[2],
      "a replacement reports when it removes an archetype core (%r)"
      % breaks_chiron[2])

# Mirror coverage must also be evaluated after removing the displaced boon.
# Weak -> Doom still leaves one curse, and Aphrodite -> Ares still leaves one
# god, so neither swap creates breadth.
lua.execute("__meta = BoonAdvisor.MetaKeys.PrivilegedStatus")
build("AphroditeWeaponTrait")
curse_swap = swap("AresWeaponTrait", "AphroditeWeaponTrait", "Rare", "Common")
check("triggers Privileged Status" not in curse_swap[2],
      "a status replacement does not count both sides of the swap")
lua.execute("__meta = BoonAdvisor.MetaKeys.FamilyFavorite")
god_swap = swap("AresWeaponTrait", "AphroditeWeaponTrait", "Rare", "Common")
check("Family Favorite +damage" not in god_swap[2],
      "a god replacement does not create phantom Family Favorite breadth")
lua.execute("__meta = nil")

# The free rarity tier must be worth something: same pair, with and without a
# tier gain. (Higher tiers give smaller increments by design, so comparing
# Heroic-over-Epic to Rare-over-Common tests the rarity CURVE, not this.)
build("ZeusWeaponTrait")
tier_gain = swap("AthenaWeaponTrait", "ZeusWeaponTrait", "Rare", "Common")
no_gain = swap("AthenaWeaponTrait", "ZeusWeaponTrait", "Common", "Common")
check(tier_gain[0] > no_gain[0],
      "arriving a tier higher is worth more than arriving level (%d vs %d)"
      % (no_gain[0], tier_gain[0]))

# A replacement must NOT also take the flat same-slot penalty. Assert that
# structurally: moving the SlotExchange weight must move a plain same-slot
# offer but leave a swap's score untouched, so the penalty cannot be charged
# on top of the swap accounting no matter what the weights are tuned to.
build("ZeusWeaponTrait")
as_swap = swap("AthenaWeaponTrait", "ZeusWeaponTrait", "Rare", "Common")[0]
plain = score(lua.table(ItemName="AthenaWeaponTrait", Rarity="Rare", Type="Trait"),
              lua.table())["Score"]
check(as_swap != plain, "a swap is scored differently from a plain offer (%d vs %d)"
      % (as_swap, plain))
lua.execute("__slotExchange = BoonAdvisor.Config.Weights.SlotExchange"
            "; BoonAdvisor.Config.Weights.SlotExchange = __slotExchange - 40")
swap_shifted = swap("AthenaWeaponTrait", "ZeusWeaponTrait", "Rare", "Common")[0]
plain_shifted = score(lua.table(ItemName="AthenaWeaponTrait", Rarity="Rare",
                                Type="Trait"), lua.table())["Score"]
lua.execute("BoonAdvisor.Config.Weights.SlotExchange = __slotExchange")
check(swap_shifted == as_swap,
      "a swap does not take the flat same-slot penalty (%d vs %d)"
      % (as_swap, swap_shifted))
check(plain_shifted != plain,
      "a plain same-slot offer does take the flat penalty (%d vs %d)"
      % (plain, plain_shifted))

print("\n=== opportunity cost: boon exclusions ===")
idx = lua.eval("BoonAdvisor.GetExclusionIndex()")
n_blockers = len(list(idx.keys()))
total_rules = sum(len(idx[k]) for k in list(idx.keys()))
print("   %d traits block something; %d rules total" % (n_blockers, total_rules))
check(total_rules >= 100,
      "the exclusion index found the RequiredFalse* rules (%d)" % total_rules)

# Find a real case: a candidate whose lockout is collateral (different slot).
pen = lua.eval("BoonAdvisor.ExclusionPenalty")
build()
examples = []
for name in list(idx.keys()):
    if traitdata[name] is None:
        continue
    p, why = pen(name)
    if why is not None:
        examples.append((name, int(p), why))
examples.sort(key=lambda e: e[1])
for name, p, why in examples[:5]:
    print("   %-30s %+d  %s" % (names.get(name, name), p, why))
check(examples, "at least one real lockout is detected and explained")
check(all(p < 0 for _, p, _ in examples), "lockouts are scored as a cost")

check(not any(why.replace("locks out ", "") == names.get(n, n)
              for n, _, why in examples),
      "no self-referential lockouts (X locks out X)")

# Same-slot exclusions must not be charged: the slot economy already prices them.
disp_to_name = {}
for n in list(idx.keys()):
    disp_to_name.setdefault(names.get(n, n), n)
same_slot = []
for name, p, why in examples:
    blocked_disp = why.replace("locks out ", "")
    blocked = disp_to_name.get(blocked_disp)
    if blocked and traitdata[name] and traitdata[blocked]:
        if (traitdata[name]["Slot"] is not None
                and traitdata[name]["Slot"] == traitdata[blocked]["Slot"]):
            same_slot.append((name, blocked))
check(not same_slot, "no same-slot exclusion is charged as a loss%s"
      % ("" if not same_slot else " -- got %s" % same_slot[:3]))

# Holding every blocked boon already means there is nothing left to lose. Some
# candidates have several equally valuable casualties, so holding only the one
# named in the explanation makes this check depend on Lua table iteration order.
victim_name, p_before, why_before = examples[0]
blocked_names = [idx[victim_name][i] for i in range(1, len(idx[victim_name]) + 1)]
build(*blocked_names)
p_after, why_after = pen(victim_name)
build()
print("   holding blocked pool first: %+d -> %+d" % (p_before, int(p_after)))
check(p_after == 0,
      "penalty disappears once every casualty is already held (%+d -> %+d)"
      % (p_before, int(p_after)))

# Hammers exclude each other, and the hammer screen must say so.
print("   -- hammer lockouts --")
build("BowBaseUpgradeTrait")


def hammer(name):
    r = score(lua.table(ItemName=name, Rarity="Common", Type="Trait"),
              lua.table(Name="WeaponUpgrade"))
    return r["Score"], r["Reason"]


flurry = hammer("BowTapFireTrait")        # Flurry Shot: locks out Perfect Shot
chain = hammer("BowChainShotTrait")       # Chain Shot: no comparable lockout
print("   Flurry Shot: %d  %s" % flurry)
print("   Chain Shot:  %d  %s" % chain)
check("locks out" in flurry[1],
      "a hammer that blocks a top hammer says so (%r)" % flurry[1])

score_hammer = lua.eval("BoonAdvisor.ScoreHammer")
build("FistBaseUpgradeTrait")
fist_hammers = {name: score_hammer(name)[0] for name in
                ("FistDashAttackHealthBufferTrait", "FistChargeSpecialTrait",
                 "FistSpecialLandTrait")}
check(fist_hammers["FistDashAttackHealthBufferTrait"]
      > fist_hammers["FistChargeSpecialTrait"]
      > fist_hammers["FistSpecialLandTrait"],
      "fists rank Breaching Cross above Flying Cutter above Quake Cutter")

build("GunBaseUpgradeTrait")
check(score_hammer("GunGrenadeDropTrait")[0] > score_hammer("GunHomingBulletTrait")[0]
      and score_hammer("GunSlowGrenade")[0] > score_hammer("GunHomingBulletTrait")[0],
      "rail ranks Hazard Bomb and Targeting System above Seeking Fire")
plain_delta = score_hammer("GunInfiniteAmmoTrait")[0]
build("GunGrenadeSelfEmpowerTrait")
eris_delta = score_hammer("GunInfiniteAmmoTrait")[0]
check(eris_delta > plain_delta, "Delta Chamber gains its Eris-specific value")

build("BowBaseUpgradeTrait")
check(score_hammer("BowDoubleShotTrait")[0] > score_hammer("BowChainShotTrait")[0]
      and score_hammer("BowBondBoostTrait")[0] < score_hammer("BowChainShotTrait")[0],
      "bow ranks Twin Shot high and Repulse Shot low")
plain_triple = score_hammer("BowTripleShotTrait")[0]
build("BowBondTrait")
check(score_hammer("BowTripleShotTrait")[0] > plain_triple
      and score_hammer("BowCloseAttackTrait")[0] > 80,
      "Rama rewards Triple Shot and Point-Blank Shot")

build("ShieldRushBonusProjectileTrait")
chaos_dread = score_hammer("ShieldThrowFastTrait")[0]
build("ShieldBaseUpgradeTrait")
plain_dread = score_hammer("ShieldThrowFastTrait")[0]
check(score_hammer("ShieldRushProjectileTrait")[0] > plain_dread
      and chaos_dread < plain_dread,
      "shield ranks Charged Shot high and penalizes Dread Flight on Chaos")
plain_minotaur = score_hammer("ShieldPerfectRushTrait")[0]
build("ShieldBaseUpgradeTrait", "ShieldChargeHealthBufferTrait")
paired_minotaur = score_hammer("ShieldPerfectRushTrait")[0]
check(paired_minotaur > plain_minotaur,
      "Breaching Rush raises the value of its Minotaur Rush pairing")

build("SpearBaseUpgradeTrait")
check(score_hammer("SpearAutoAttack")[0] > score_hammer("SpearAttackPhalanxTrait")[0]
      and score_hammer("SpearThrowExplode")[0] > score_hammer("SpearAttackPhalanxTrait")[0],
      "spear ranks Flurry Jab and Exploding Launcher above Triple Jab")
plain_skewer = score_hammer("SpearThrowElectiveCharge")[0]
build("SpearSpinTravel")
check(score_hammer("SpearThrowElectiveCharge")[0] > plain_skewer,
      "Charged Skewer gains its Guan Yu run-winner bonus")

build("SwordBaseUpgradeTrait")
plain_shadow = score_hammer("SwordBackstabTrait")[0]
check(score_hammer("SwordDoubleDashAttackTrait")[0] > 84,
      "Double Edge is a top sword hammer")
build("SwordConsecrationTrait")
check(score_hammer("SwordBackstabTrait")[0] > plain_shadow,
      "Shadow Slash gains its Arthur-specific value")
build()

# A lockout only costs you something you could actually have had.
build()
fresh_hades = boon("HadesShoutTrait")
build("ZeusWeaponTrait", "HermesWeaponTrait")   # now chasing Smoldering Air
chasing_hades = boon("HadesShoutTrait")
build()
print("   Hades' Aid: fresh %d (%s) | chasing the duo %d (%s)"
      % (fresh_hades["Score"], fresh_hades["Reason"],
         chasing_hades["Score"], chasing_hades["Reason"]))
check("locks out" not in fresh_hades["Reason"],
      "no lockout penalty for a duo the run cannot reach")
check("locks out" in chasing_hades["Reason"],
      "the lockout is charged once the duo is genuinely in play")
check(fresh_hades["Score"] > chasing_hades["Score"],
      "and it costs real points when it matters (%d vs %d)"
      % (fresh_hades["Score"], chasing_hades["Score"]))

print("\n=== keepsake advisor (scored against your aspect) ===")
sk = lua.eval("BoonAdvisor.ScoreKeepsake")
KS = ["ForceAresBoonTrait", "ForceAthenaBoonTrait", "ForceZeusBoonTrait",
      "ForceDionysusBoonTrait", "ForceAphroditeBoonTrait",
      "ForceDemeterBoonTrait", "FastClearDodgeBonusTrait", "MegaRubbleTrait"]


def rack(label, *held):
    build(*held)
    rows = []
    for k in KS:
        s, why = sk(k)
        v = int(finalize(s))
        rows.append((v, names.get(k, k), why))
    print("   -- %s --" % label)
    for v, n, why in sorted(rows, reverse=True):
        print("      %3d  %-22s %s" % (v, n, why))
    return {n: v for v, n, why in rows}


chiron = rack("Aspect of Chiron, nothing held", "BowMarkHomingTrait")
check(chiron["Overflowing Cup"] > chiron["Thunder Signet"],
      "on Chiron the Dionysus keepsake beats an irrelevant god (%d vs %d)"
      % (chiron["Overflowing Cup"], chiron["Thunder Signet"]))
check(chiron["Overflowing Cup"] > chiron["Abandoned Shackle"],
      "and beats a low-value generic keepsake")

# It must track build progress: once Drunken Flourish is held, it should point
# at the next Dionysus contribution rather than naming the boon already owned.
before_reason = sk("ForceDionysusBoonTrait")[1]
build("BowMarkHomingTrait", "DionysusSecondaryTrait")
after_reason = sk("ForceDionysusBoonTrait")[1]
print("      reason before: %s" % before_reason)
print("      reason after:  %s" % after_reason)
check("Drunken Flourish" in before_reason,
      "it names the build's first need while missing (%r)" % before_reason)
check("Drunken Flourish" not in after_reason,
      "and stops naming it once held (%r)" % after_reason)

# A god the build has no use for must rank below one it needs.
build("BowMarkHomingTrait")
check(sk("ForceDionysusBoonTrait")[0] > sk("ForceDemeterBoonTrait")[0],
      "a needed god outranks an unneeded one")

# Duos appear in both gods' LinkedUpgrades pools. Keepsake attribution must not
# depend on whichever table pairs() happened to visit first.
offered_by = lua.eval("BoonAdvisor.TraitOfferedByGod")
low_tolerance = "DionysusAphroditeStackIncreaseTrait"
check(offered_by(low_tolerance, "DionysusUpgrade")
      and offered_by(low_tolerance, "AphroditeUpgrade"),
      "a duo payoff is attributed to both contributing gods")

# A different aspect should want a different god.
arthur = rack("Aspect of Arthur", "SwordConsecrationTrait")
check(arthur["Owl Pendant"] > arthur["Thunder Signet"],
      "on Arthur the Athena keepsake outranks Zeus (%d vs %d)"
      % (arthur["Thunder Signet"], arthur["Owl Pendant"]))

print("\n=== contextual keepsake rack ===")
lua.execute("""
__allKeepsakes = {
    "MaxHealthKeepsakeTrait", "DirectionalArmorTrait",
    "BackstabAlphaStrikeTrait", "PerfectClearDamageBonusTrait",
    "ShopDurationTrait", "BonusMoneyTrait", "LowHealthDamageTrait",
    "DistanceDamageTrait", "LifeOnUrnTrait", "ReincarnationTrait",
    "ForceZeusBoonTrait", "ForcePoseidonBoonTrait", "ForceAthenaBoonTrait",
    "ForceAphroditeBoonTrait", "ForceAresBoonTrait", "ForceArtemisBoonTrait",
    "ForceDionysusBoonTrait", "FastClearDodgeBonusTrait",
    "ForceDemeterBoonTrait", "ChaosBoonTrait", "VanillaTrait",
    "ShieldBossTrait", "ShieldAfterHitTrait", "ChamberStackTrait",
    "HadesShoutKeepsake",
}
__availableKeepsakes = {}
for _, name in ipairs(__allKeepsakes) do
    table.insert(__availableKeepsakes, { Gift=name, Unlocked=true })
end
CurrentRun.CurrentRoom = { Name="RoomPreRun", RoomSetName="Home",
    KeepsakeFreeSwap=true }
CurrentRun.BlockedKeepsakes = {}
CurrentRun.Hero.Health = 100
CurrentRun.Hero.MaxHealth = 100
CurrentRun.Hero.LastStands = {}
CurrentRun.Money = 0
GameState.LastAwardTrait = nil
""")
build("BowMarkHomingTrait")
evaluate_keepsakes = lua.eval("BoonAdvisor.EvaluateKeepsakeRack")
fresh_rack = evaluate_keepsakes(G["__availableKeepsakes"])
check(len(list(fresh_rack["Results"].keys())) == 25,
      "all 25 real keepsakes receive contextual scores")
check(sum(1 for name in fresh_rack["Results"].keys()
          if fresh_rack["Results"][name]["IsBest"]) == 1,
      "the rack has exactly one best recommendation")
check(fresh_rack["BestName"] is not None,
      "the best recommendation is an unlocked, selectable keepsake")

# The force is a one-use effect. Keeping the god item afterward retains only
# its rarity bonus and must be worth less than an unused copy.
lua.execute("""
CurrentRun.CurrentRoom = { Name="A_PostBoss01", RoomSetName="Tartarus" }
GameState.LastAwardTrait = "ForceDionysusBoonTrait"
""")
build("BowMarkHomingTrait", "ForceDionysusBoonTrait")
unused_force = sk("ForceDionysusBoonTrait")[0]
lua.execute("""
for _, trait in pairs(CurrentRun.Hero.Traits) do
    if trait.Name == "ForceDionysusBoonTrait" then trait.Uses = 0 end
end
""")
spent_force, spent_reason = sk("ForceDionysusBoonTrait")
check(spent_force < unused_force and "rarity bonus only" in spent_reason,
      "a consumed god force is devalued without pretending its rarity vanished")
check(unused_force - spent_force >= 15,
      "a consumed god keepsake no longer receives guaranteed route-target value")

# Coin Purse pays when selected, but the current purse has already paid.
lua.execute("""
CurrentRun.CurrentRoom = { Name="RoomPreRun", RoomSetName="Home",
    KeepsakeFreeSwap=true }
GameState.LastAwardTrait = nil
""")
build("BowMarkHomingTrait")
fresh_purse = sk("BonusMoneyTrait")[0]
lua.execute("""
CurrentRun.CurrentRoom = { Name="A_PostBoss01", RoomSetName="Tartarus" }
GameState.LastAwardTrait = "BonusMoneyTrait"
""")
build("BowMarkHomingTrait", "BonusMoneyTrait")
claimed_purse, claimed_reason = sk("BonusMoneyTrait")
check(claimed_purse < fresh_purse and "already claimed" in claimed_reason,
      "Coin Purse recommends switching away after its gold has paid out")

# Butterfly and Plume stacks disappear when switched away. Existing value is
# therefore included, while a fresh late-run stacker loses future value.
lua.execute("""
CurrentRun.CurrentRoom = { Name="A_PostBoss01", RoomSetName="Tartarus" }
CurrentRun.RoomHistory = {}
CurrentRun.BlockedKeepsakes = {}
CurrentRun.Hero.LastStands = { {}, {}, {} }
GameState.LastAwardTrait = "PerfectClearDamageBonusTrait"
""")
build("BowMarkHomingTrait", "PerfectClearDamageBonusTrait")
lua.execute("""
for _, trait in pairs(CurrentRun.Hero.Traits) do
    if trait.Name == "PerfectClearDamageBonusTrait" then
        trait.AccumulatedDamageBonus = 1.35
    end
end
""")
stacked_rack = evaluate_keepsakes(G["__availableKeepsakes"])
check(stacked_rack["BestName"] == "PerfectClearDamageBonusTrait",
      "a strong existing Butterfly stack is protected from a bad switch")
check("KEEP:" in lua.eval("BoonAdvisor.KeepsakeGuidance")(
          "PerfectClearDamageBonusTrait",
          stacked_rack["Results"]["PerfectClearDamageBonusTrait"], stacked_rack),
      "the selected optimal keepsake is labelled KEEP")
check("KEEP:" in lua.eval("BoonAdvisor.KeepsakeGuidance")(
          "PerfectClearDamageBonusTrait",
          stacked_rack["Results"]["PerfectClearDamageBonusTrait"], stacked_rack,
          "PerfectClearDamageBonusTrait"),
      "hover guidance follows the keepsake currently selected in the rack")

# A fresh stacker uses this run's real clear performance, tempered by a prior,
# instead of assuming every player succeeds at the same fixed rate.
lua.execute("""
GameState.LastAwardTrait = "MaxHealthKeepsakeTrait"
CurrentRun.RoomHistory = {
    { Encounter={ EncounterType="Default", ClearTime=18,
        FastClearThreshold=30, PlayerTookDamage=false } },
    { Encounter={ EncounterType="Default", ClearTime=20,
        FastClearThreshold=30, PlayerTookDamage=false } },
    { Encounter={ EncounterType="Default", ClearTime=22,
        FastClearThreshold=30, PlayerTookDamage=false } },
    { Encounter={ EncounterType="Default", ClearTime=24,
        FastClearThreshold=30, PlayerTookDamage=false } },
}
""")
build("BowMarkHomingTrait", "MaxHealthKeepsakeTrait")
clean_context = lua.eval("BoonAdvisor.KeepsakeContext")()
clean_butterfly = sk("PerfectClearDamageBonusTrait", clean_context)[0]
clean_plume = sk("FastClearDodgeBonusTrait", clean_context)[0]
lua.execute("""
for _, room in pairs(CurrentRun.RoomHistory) do
    room.Encounter.ClearTime = 50
    room.Encounter.PlayerTookDamage = true
end
""")
rough_context = lua.eval("BoonAdvisor.KeepsakeContext")()
check(clean_butterfly > sk("PerfectClearDamageBonusTrait", rough_context)[0]
      and clean_plume > sk("FastClearDodgeBonusTrait", rough_context)[0],
      "Butterfly and Plume forecast stacks from this run's actual clears")

# Survival state can reverse the recommendation late in a run.
lua.execute("""
CurrentRun.CurrentRoom = { Name="C_PostBoss01", RoomSetName="Elysium" }
CurrentRun.Hero.Health = 25
CurrentRun.Hero.MaxHealth = 150
CurrentRun.Hero.LastStands = {}
GameState.LastAwardTrait = "BonusMoneyTrait"
""")
build("BowMarkHomingTrait", "BonusMoneyTrait")
survival_rack = evaluate_keepsakes(G["__availableKeepsakes"])
check(survival_rack["Results"]["ReincarnationTrait"]["RawScore"]
      > survival_rack["Results"]["BonusMoneyTrait"]["RawScore"],
      "at low HP with no Defiances, Tooth beats an already-paid Coin Purse")
check("SWITCH TO" in lua.eval("BoonAdvisor.KeepsakeGuidance")(
          "BonusMoneyTrait", survival_rack["Results"]["BonusMoneyTrait"],
          survival_rack),
      "the current inferior keepsake names the recommended switch")

# The Tooth's own Last Stand is not mistaken for an independent Defiance when
# valuing whether to keep it.
lua.execute("""
CurrentRun.Hero.LastStands = {
    { Name="DeathDefiance" }, { Name="ReincarnationTrait" }
}
GameState.LastAwardTrait = "ReincarnationTrait"
""")
build("BowMarkHomingTrait", "ReincarnationTrait")
tooth_context = lua.eval("BoonAdvisor.KeepsakeContext")()
check(tooth_context["Defiances"] == 2 and tooth_context["BaseDefiances"] == 1,
      "Tooth scoring separates its extra life from other Defiances")

# Unequipping Hades' keepsake removes Hades' Aid. A replacement god keepsake
# therefore evaluates its Calls against the newly empty slot.
lua.execute("""
__oldZeusCallRating = BoonAdvisor.Ratings.Base.ZeusShoutTrait
BoonAdvisor.Ratings.Base.ZeusShoutTrait = 120
GameState.LastAwardTrait = "HadesShoutKeepsake"
""")
build("BowMarkHomingTrait", "HadesShoutKeepsake", "HadesShoutTrait")
hades_switch_zeus = sk("ForceZeusBoonTrait")[0]
lua.execute("GameState.LastAwardTrait = 'MaxHealthKeepsakeTrait'")
build("BowMarkHomingTrait", "MaxHealthKeepsakeTrait", "AresShoutTrait")
real_call_zeus = sk("ForceZeusBoonTrait")[0]
lua.execute("BoonAdvisor.Ratings.Base.ZeusShoutTrait = __oldZeusCallRating")
check(hades_switch_zeus > real_call_zeus,
      "switching from Hades correctly exposes an empty Call slot")

# Hades' keepsake and earlier biome keepsakes obey the same restrictions as
# vanilla, so an impossible option can never receive the star.
lua.execute("""
CurrentRun.BlockedKeepsakes = { "ForceDionysusBoonTrait" }
""")
build("BowMarkHomingTrait", "AresShoutTrait")
blocked_rack = evaluate_keepsakes(G["__availableKeepsakes"])
check(not blocked_rack["Results"]["ForceDionysusBoonTrait"]["Selectable"]
      and blocked_rack["BestName"] != "ForceDionysusBoonTrait",
      "a previously used keepsake cannot receive the best marker")
check(not blocked_rack["Results"]["HadesShoutKeepsake"]["Selectable"],
      "Hades' keepsake cannot be recommended over an existing Call")

# The House rack can still share the completed run object. Its old one-use and
# blocked state must not leak into the next escape.
lua.execute("""
CurrentRun.CurrentRoom = { Name="RoomPreRun", RoomSetName="Home",
    KeepsakeFreeSwap=true }
CurrentRun.RoomHistory = {}
CurrentRun.BlockedKeepsakes = { "ForceDionysusBoonTrait" }
CurrentRun.Hero.Health = 1
CurrentRun.Hero.MaxHealth = 150
CurrentRun.Hero.LastStands = {}
CurrentRun.Money = 999
GameState.LastAwardTrait = "ForceDionysusBoonTrait"
""")
build("BowMarkHomingTrait", "ForceDionysusBoonTrait", "AresShoutTrait")
lua.execute("""
for _, trait in pairs(CurrentRun.Hero.Traits) do
    if trait.Name == "ForceDionysusBoonTrait" then trait.Uses = 0 end
end
""")
next_run_rack = evaluate_keepsakes(G["__availableKeepsakes"])
check(next_run_rack["Results"]["ForceDionysusBoonTrait"]["Selectable"]
      and "rarity bonus only" not in
          next_run_rack["Results"]["ForceDionysusBoonTrait"]["Reason"],
      "the House rack resets last run's consumed and blocked god keepsake")
check(next_run_rack["Results"]["HadesShoutKeepsake"]["Selectable"],
      "the House rack ignores the previous run's stale Call")
check(next_run_rack["Context"]["HealthFraction"] == 1
      and next_run_rack["Context"]["Money"] == 0,
      "the House rack starts the next escape at full health and fresh gold")

# Pom Blossom is valued to the next rack, where the player can reconsider it.
lua.execute("""
CurrentRun.BlockedKeepsakes = {}
CurrentRun.CurrentRoom = { Name="RoomPreRun", RoomSetName="Home",
    KeepsakeFreeSwap=true }
GameState.LastAwardTrait = nil
""")
build("BowMarkHomingTrait")
early_pom = sk("ChamberStackTrait")[0]
lua.execute("CurrentRun.CurrentRoom = { Name='A_PostBoss01', RoomSetName='Tartarus' }")
asphodel_pom = sk("ChamberStackTrait")[0]
check(early_pom > asphodel_pom,
      "Pom Blossom accounts for the encounters remaining before the next rack")

lua.execute("CurrentRun.CurrentRoom = { Name='RoomPreRun', RoomSetName='Home', KeepsakeFreeSwap=true }")
build("SwordBaseUpgradeTrait")
plain_shackle = sk("VanillaTrait")[0]
build("SwordConsecrationTrait")
heavy_shackle, heavy_shackle_reason = sk("VanillaTrait")
check(heavy_shackle > plain_shackle and "base damage" in heavy_shackle_reason,
      "Shattered Shackle recognizes heavy base-damage aspects")

# The same number of free levels is better when those levels can hit a strong
# build core instead of only a deeply diminished filler boon.
lua.execute("CurrentRun.CurrentRoom = { Name='B_PostBoss01', RoomSetName='Asphodel' }")
build("BowMarkHomingTrait", "DionysusSecondaryTrait")
core_target_pom, core_target_reason = sk("ChamberStackTrait")
build("BowMarkHomingTrait", "DionysusDoorHealTrait")
stale_target_pom = sk("ChamberStackTrait")[0]
check(core_target_pom > stale_target_pom and "Drunken Flourish" in core_target_reason,
      "Pom Blossom values the actual owned boons and their diminishing returns")

# Marginal ties retain the current keepsake; only a meaningful gain switches.
lua.execute("""
__originalScoreKeepsake = BoonAdvisor.ScoreKeepsake
function BoonAdvisor.ScoreKeepsake(name, context)
    if name == "MaxHealthKeepsakeTrait" then return 70, "current" end
    if name == "DirectionalArmorTrait" then return __tieAlternative, "alternative" end
    return __originalScoreKeepsake(name, context)
end
__tieRack = {
    { Gift="MaxHealthKeepsakeTrait", Unlocked=true },
    { Gift="DirectionalArmorTrait", Unlocked=true },
}
GameState.LastAwardTrait = "MaxHealthKeepsakeTrait"
__tieAlternative = 72
__keptTie = BoonAdvisor.EvaluateKeepsakeRack(__tieRack)
__tieAlternative = 74
__switchedGain = BoonAdvisor.EvaluateKeepsakeRack(__tieRack)
BoonAdvisor.ScoreKeepsake = __originalScoreKeepsake
""")
check(lua.eval("__keptTie.BestName") == "MaxHealthKeepsakeTrait",
      "a marginal score difference does not recommend needless switching")
check(lua.eval("__switchedGain.BestName") == "DirectionalArmorTrait",
      "a meaningful score gain does recommend switching")

# The full rack is evaluated once before the first badge, then reused by all
# 25 icons and by hover detail. This is the live frame-time contract.
lua.execute("""
CurrentRun.CurrentRoom = { Name="A_PostBoss01", RoomSetName="Tartarus" }
CurrentRun.BlockedKeepsakes = {}
GameState.LastAwardTrait = "MaxHealthKeepsakeTrait"
UIData = { AwardMenu = { AvailableKeepsakeTraits = __availableKeepsakes } }
ScreenAnchors.AwardMenuScreen = { Components = {} }
BoonAdvisor.KeepsakeEvaluationScreen = nil
BoonAdvisor.LastKeepsakeEvaluation = nil
__keepsakeScoreCalls = 0
__originalScoreKeepsake = BoonAdvisor.ScoreKeepsake
function BoonAdvisor.ScoreKeepsake(...)
    __keepsakeScoreCalls = __keepsakeScoreCalls + 1
    return __originalScoreKeepsake(...)
end
__boxes = {}
for index, upgrade in ipairs(__availableKeepsakes) do
    CreateKeepsakeIcon(ScreenAnchors.AwardMenuScreen.Components,
        { Index=index, UpgradeData=upgrade, X=100, Y=100 })
end
BoonAdvisor.PrepareKeepsakeRack()
BoonAdvisor.ScoreKeepsake = __originalScoreKeepsake
""")
check(lua.eval("__keepsakeScoreCalls") == 25,
      "opening and drawing the rack scores each keepsake exactly once")
check(sum(1 for box in G["__boxes"].values()
          if str(box["LuaValue"]["BALine"]).startswith("*")) == 1,
      "the keepsake grid draws exactly one best marker")

print("\n=== keepsake and rarity boost ===")
build("ForceZeusBoonTrait")
kg = lua.eval("BoonAdvisor.KeepsakeGod")()
check(kg == "ZeusUpgrade", "a god keepsake is detected (%s)" % kg)
zeus_door = door("Boon", "ZeusUpgrade")
build()
zeus_plain = door("Boon", "ZeusUpgrade")
print("   Zeus door with keepsake: %d (%s) | without: %d" %
      (zeus_door[0], zeus_door[2], zeus_plain[0]))
check(zeus_door[0] == zeus_plain[0],
      "forcing a visible god door adds no sunk-cost bonus")

print("\n=== expected rarity (Mirror talents, keepsakes, room overrides) ===")
build()
lua.execute("__metaCounts = {}; __rarityBonusTraits = {}")
plain_r = door("Boon", "ZeusUpgrade")[0]

# The four rarity Mirror talents, at full investment.
lua.execute("""__metaCounts = { RareBoonDropMetaUpgrade = 40,
    EpicBoonDropMetaUpgrade = 20, EpicHeroicBoonMetaUpgrade = 10,
    DuoRarityBoonDropMetaUpgrade = 10 }""")
mirror_r = door("Boon", "ZeusUpgrade")[0]

# A keepsake's RarityBonus, gated on its own god.
lua.execute("""__metaCounts = {}
__rarityBonusTraits = { { RequiredGod = "ZeusUpgrade", RareBonus = 0.5, EpicBonus = 0.2 } }""")
keepsake_raw = scoredoor(lua.table(ChosenRewardType="Boon", ForceLootName="ZeusUpgrade"))[0]
keepsake_r = door("Boon", "ZeusUpgrade")[0]
other_god_raw = scoredoor(lua.table(ChosenRewardType="Boon", ForceLootName="AresUpgrade"))[0]
other_god_r = door("Boon", "AresUpgrade")[0]

# A destination room that overrides rarity outright (several do: RareChance 0.90).
lua.execute("__rarityBonusTraits = {}")
room_r = door("Boon", "ZeusUpgrade", BoonRaritiesOverride=lua.table(
    RareChance=0.90, EpicChance=0.25))[0]

print("   plain: %d | rarity Mirror talents: %d | keepsake god: %d (other god %d) | boosted room: %d"
      % (plain_r, mirror_r, keepsake_r, other_god_r, room_r))
check(mirror_r > plain_r, "the 4 rarity Mirror talents raise a boon door")
check(keepsake_raw > other_god_raw,
	  "a keepsake's RarityBonus lifts only its own god (%.2f vs %.2f)"
	  % (keepsake_raw, other_god_raw))
check(room_r > plain_r, "a room-level rarity override is picked up")

# These rolls are mutually exclusive in SetTraitsOnLoot. With both raw chances
# at 100%, Epic wins first and Rare must add nothing on top.
lua.execute("""CurrentRun.Hero.BoonData = { RareChance = 1, EpicChance = 1 }
__metaCounts = {}; __rarityBonusTraits = {}""")
exclusive_rarity = lua.eval("BoonAdvisor.ExpectedRarityBonus")("ZeusUpgrade", False)
epic_only = (G["BoonAdvisor"]["Config"]["Weights"]["Rarity"]["Epic"]
             * G["BoonAdvisor"]["Config"]["Doors"]["RarityExpectationScale"])
check(abs(exclusive_rarity - epic_only) < 0.001,
      "rarity expectation follows first-success roll order (%.2f)" % exclusive_rarity)
lua.execute("""CurrentRun.Hero.BoonData = { RareChance = 0.10, EpicChance = 0.05,
    LegendaryChance = 0.12, ReplaceChance = 0.10 }""")

print("\n=== Death Defiances soften risk ===")
lua.execute("CurrentRun.Hero.MaxHealth = 150; CurrentRun.Hero.Health = 50")
lua.execute("CurrentRun.Hero.LastStands = 0")
no_def = door("Devotion")
lua.execute("CurrentRun.Hero.LastStands = 2")
two_def = door("Devotion")
lua.execute("CurrentRun.Hero.LastStands = 0; CurrentRun.Hero.Health = 150")
print("   Trial at 33%% hp -- 0 Defiances: %d (%s) | 2 Defiances: %d"
      % (no_def[0], no_def[2], two_def[0]))
check(two_def[0] > no_def[0],
      "Death Defiances make a risky room more acceptable (%d vs %d)"
      % (no_def[0], two_def[0]))
check("Death Defiance" in no_def[2],
      "with none left, the risk is called out (%r)" % no_def[2])

print("\n=== Pact of Punishment (Heat) ===")
build()
lua.execute("CurrentRun.Hero.MaxHealth = 150; CurrentRun.Hero.Health = 75")
lua.execute("__metaCounts = {}")
heart = door("Health")
heat0 = healing()
lua.execute("__metaCounts = { HealingReductionShrineUpgrade = 1 }")
heart_under_pact = door("Health")
heal_cut = healing()
healing_by_rank = [heal_cut[0]]
for rank in (2, 3, 4):
    lua.execute("__metaCounts = { HealingReductionShrineUpgrade = %d }" % rank)
    healing_by_rank.append(healing()[0])
zero_heal_reason = healing()[2]
lua.execute("""__metaCounts = { EnemyHealthShrineUpgrade = 2,
    EnemyDamageShrineUpgrade = 2, EnemyEliteShrineUpgrade = 1 }""")
dangerous = healing()
lua.execute("__metaCounts = {}")
print("   Centaur Heart: %d (%s) | pure heal: %d | reduced: %d (%s) | danger: %d"
      % (heart[0], heart[2], heat0[0], heal_cut[0], heal_cut[2], dangerous[0]))
check(heart[2] == "+25 max health",
      "a Health door is identified as a Centaur Heart (%r)" % heart[2])
check(heart_under_pact[0] == heart[0],
      "healing reduction does not devalue permanent max health")
lua.execute("CurrentRun.Hero.Health = CurrentRun.Hero.MaxHealth")
check(door("Health")[0] == heart[0],
      "a Centaur Heart remains valuable at full health")
lua.execute("CurrentRun.Hero.Health = 75")
check(heal_cut[0] < heat0[0],
      "healing reduction lowers pure healing (%d -> %d)" % (heat0[0], heal_cut[0]))
check("75% healing" in heal_cut[2],
      "and says so (%r)" % heal_cut[2])
check(all(a > b for a, b in zip([heat0[0]] + healing_by_rank,
                                healing_by_rank))
      and healing_by_rank[-1] == 1,
      "all four Pact ranks scale healing 100/75/50/25/0 (%s)"
      % ([heat0[0]] + healing_by_rank))
check("0 health" in zero_heal_reason,
      "rank four explicitly reports zero restoration (%r)" % zero_heal_reason)
check(dangerous[0] > heat0[0],
      "danger modifiers raise survival value (%d -> %d)" % (heat0[0], dangerous[0]))

print("\n=== Pact changes which boon is best ===")
build()
lua.execute("__metaCounts = {}")
foot_off = boon("TrapDamageTrait")
speed_off = boon("MoveSpeedTrait")
lua.execute("__metaCounts = { TrapDamageShrineUpgrade = 1 }")
foot_on = boon("TrapDamageTrait")
lua.execute("__metaCounts = { BiomeSpeedShrineUpgrade = 1 }")
speed_on = boon("MoveSpeedTrait")
lua.execute("__metaCounts = {}")
print("   Sure Footing:  %d -> %d  (%s)" % (foot_off["Score"], foot_on["Score"], foot_on["Reason"]))
print("   Hermes speed:  %d -> %d  (%s)" % (speed_off["Score"], speed_on["Score"], speed_on["Reason"]))
check(foot_on["Score"] > foot_off["Score"],
      "Sure Footing gains value when traps hit hard")
check("traps" in foot_on["Reason"], "and says why (%r)" % foot_on["Reason"])
check(speed_on["Score"] > speed_off["Score"],
      "speed boons gain value under the biome timer")

# Pact pressure is weighted by mechanical impact rather than treating every
# rank as equal. Hard Labor's +20% incoming damage matters more than one rank
# of Calisthenics Program's +15% enemy health.
lua.execute("__metaCounts = { EnemyDamageShrineUpgrade = 1 }")
hard_labor_danger = lua.eval("BoonAdvisor.DangerLevel")()
hard_labor_dash = boon("AthenaRushTrait")["RawScore"]
hard_labor_heart = door("Health")[0]
lua.execute("__metaCounts = { EnemyHealthShrineUpgrade = 1 }")
enemy_health_danger = lua.eval("BoonAdvisor.DangerLevel")()
lua.execute("__metaCounts = {}")
plain_dash = boon("AthenaRushTrait")["RawScore"]
plain_heart = door("Health")[0]
check(hard_labor_danger > enemy_health_danger,
      "Pact danger weights Hard Labor above equal-rank enemy health")
check(hard_labor_dash > plain_dash and hard_labor_heart > plain_heart,
      "active combat pressure raises defensive boons and permanent max health")

# Tight Deadline uses both rank and the live biome bank. Its route advice
# favours combat-free rooms and discounts the longer Trial encounter.
lua.execute("CurrentRun.BiomeTime = 300; __metaCounts = { BiomeSpeedShrineUpgrade = 1 }")
deadline_rank1 = boon("MoveSpeedTrait")["RawScore"]
lua.execute("__metaCounts = { BiomeSpeedShrineUpgrade = 3 }")
deadline_rank3 = boon("MoveSpeedTrait")["RawScore"]
story_under_deadline = door(None)
trial_under_deadline = door("Devotion")[0]
lua.execute("CurrentRun.BiomeTime = 60")
deadline_urgent = boon("MoveSpeedTrait")["RawScore"]
lua.execute("CurrentRun.BiomeTime = nil; __metaCounts = {}")
trial_without_deadline = door("Devotion")[0]
check(deadline_rank3 > deadline_rank1 and deadline_urgent > deadline_rank3,
      "Tight Deadline scales with rank and remaining biome time")
check("timer pauses" in story_under_deadline[2],
      "Tight Deadline recognizes a story room's timer block")
check(trial_under_deadline < trial_without_deadline,
      "Tight Deadline discounts the longer Trial encounter")

# Damage Control consumes one shield per damage instance. Independent arrows
# and multi-hit hammers therefore gain value without changing ordinary runs.
lua.execute("__metaCounts = {}")
support_off = boon("ArtemisSupportingFireTrait")["RawScore"]
volley_off = lua.eval("BoonAdvisor.ScoreHammer")("BowSecondaryBarrageTrait")[0]
lua.execute("__metaCounts = { EnemyShieldShrineUpgrade = 2 }")
support_on = boon("ArtemisSupportingFireTrait")["RawScore"]
volley_on = lua.eval("BoonAdvisor.ScoreHammer")("BowSecondaryBarrageTrait")[0]
lua.execute("__metaCounts = {}")
check(support_on > support_off and volley_on > volley_off,
      "Damage Control raises independent-hit boons and multi-hit hammers")
lua.execute("__metaCounts = { EnemySpeedShrineUpgrade = 2 }")
chill_under_speed = boon("DemeterSecondaryTrait")["RawScore"]
lua.execute("__metaCounts = {}")
chill_plain = boon("DemeterSecondaryTrait")["RawScore"]
lua.execute("__metaCounts = { EnemyCountShrineUpgrade = 3 }")
chain_under_count = boon("ZeusSecondaryTrait")["RawScore"]
lua.execute("__metaCounts = {}")
chain_plain = boon("ZeusSecondaryTrait")["RawScore"]
lua.execute("__metaCounts = { EnemyEliteShrineUpgrade = 2 }")
breaching_under_elites = lua.eval("BoonAdvisor.ScoreHammer")(
    "BowPenetrationTrait")[0]
lua.execute("__metaCounts = {}")
breaching_plain = lua.eval("BoonAdvisor.ScoreHammer")(
    "BowPenetrationTrait")[0]
check(chill_under_speed > chill_plain,
      "Forced Overtime raises the value of enemy slows")
check(chain_under_count > chain_plain,
      "Jury Summons raises the value of explicit area and chaining effects")
check(breaching_under_elites > breaching_plain,
      "Benefits Package raises the value of armor-breaking hammers")

# Calisthenics Program and similar clear-burden conditions should prioritize
# proven build completion, not inflate unrelated damage choices.
build("BowMarkHomingTrait")
lua.execute("__metaCounts = {}")
chiron_core_plain = boon("DionysusSecondaryTrait")["RawScore"]
unrelated_plain = boon("DemeterRangedTrait")["RawScore"]
lua.execute("__metaCounts = { EnemyHealthShrineUpgrade = 2 }")
chiron_core_health = boon("DionysusSecondaryTrait")["RawScore"]
unrelated_health = boon("DemeterRangedTrait")["RawScore"]
lua.execute("__metaCounts = {}")
check(chiron_core_health > chiron_core_plain,
      "Calisthenics Program prioritizes completing a proven damage build")
check(abs(unrelated_health - unrelated_plain) < 0.001,
      "clear-pressure heat does not inflate unrelated offensive boons")

# Routine Inspection can null a selected Mirror row. The advisor must follow
# the active cache, not continue awarding the selection's disabled effect.
lua.execute("__meta = BoonAdvisor.MetaKeys.PrivilegedStatus; CurrentRun.MetaUpgradeCache = nil")
build("AphroditeWeaponTrait")
mirror_active = boon("AresSecondaryTrait")["RawScore"]
lua.execute("CurrentRun.MetaUpgradeCache = {}; __metaCounts = {}")
mirror_disabled = boon("AresSecondaryTrait")["RawScore"]
lua.execute("CurrentRun.MetaUpgradeCache = nil; __meta = nil")
check(mirror_active > mirror_disabled,
      "Routine Inspection removes bonuses from disabled Mirror talents")

# Underworld Customs uses the Pool of Purging. The score is action-oriented:
# higher means safer to sell, so a filler must beat Chiron's build core.
build("BowMarkHomingTrait", "DionysusSecondaryTrait", "ChamberGoldTrait")
purge_core = lua.eval("BoonAdvisor.ScorePurgeTrait")(
    "DionysusSecondaryTrait")
purge_filler = lua.eval("BoonAdvisor.ScorePurgeTrait")("ChamberGoldTrait")
check(purge_filler["RawScore"] > purge_core["RawScore"],
      "Underworld Customs protects build cores when choosing a purge")
check("Chiron" in purge_core["Reason"],
      "the purge warning names the build it protects")
lua.execute("""
__boxes = {}
ScreenAnchors.SellTraitScreen = { Components = {
    PurchaseButton1 = { Id = 501, UpgradeName = "DionysusSecondaryTrait" },
    PurchaseButton2 = { Id = 502, UpgradeName = "AresWeaponTrait" },
    PurchaseButton3 = { Id = 503, UpgradeName = "ChamberGoldTrait" },
} }
CreateSellButtons()
""")
purge_badges = {
    box["Id"]: box["LuaValue"]["BALine"]
    for box in G["__boxes"].values()
    if box["LuaValue"] is not None and "SELL" in box["LuaValue"]["BALine"]
}
check(G["__vanilla"]["sell"] == 1 and "* SELL" in purge_badges[503]
      and "* SELL" not in purge_badges[501],
      "purge overlay follows each rendered button's trait, not table order")
build()

# Darkness rewards are worth less when Darkness is capped.
dark_off = door("MetaPoints")
lua.execute("__metaCounts = { MetaPointCapShrineUpgrade = 1 }")
dark_on = door("MetaPoints")
lua.execute("__metaCounts = {}")
print("   darkness door: %d -> %d  (%s)" % (dark_off[0], dark_on[0], dark_on[2]))
check(dark_on[0] < dark_off[0], "a Darkness cap devalues Darkness rewards")

print("\n=== reroll advice ===")
check(not MOD_SHIPS_ORACLE
	  and DEFAULT_REROLL_SAMPLES >= 256 and DEFAULT_DOOR_SAMPLES >= 256,
	  "the sampling oracle is test tooling (tests/oracle.lua), not shipped in the mod")
G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"] = 48
fresh_offer = lua.eval("BoonAdvisor.SimulateInitialOffer")(
    lua.table(Name="ZeusUpgrade",
              RarityChances=lua.table(Rare=0.10, Epic=0.05)),
    "test-door")
check(fresh_offer is not None and fresh_offer["Samples"] == 48
      and fresh_offer["ExpectedScore"] > 0,
      "fresh door forecasts run through the isolated vanilla offer generator")
G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"] = 0

build()
lua.execute("""
__boxes = {}
__meta = BoonAdvisor.MetaKeys.RerollPanel
CurrentRun.NumRerolls = 2
CreateBoonLootButtons({ Name = "ZeusUpgrade", ObjectId = 700, UpgradeOptions = {
    { ItemName = "ChamberGoldTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "FallbackMoneyDrop", Rarity = "Common", Type = "Consumable" },
}}, false)
""")
weak = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
lua.execute("""
__boxes = {}
CurrentRun.NumRerolls = 0
CreateBoonLootButtons({ Name = "ZeusUpgrade", ObjectId = 700, UpgradeOptions = {
    { ItemName = "ChamberGoldTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "FallbackMoneyDrop", Rarity = "Common", Type = "Consumable" },
}}, false)
""")
none_left = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
lua.execute("""
__boxes = {}
__meta = nil
CurrentRun.NumRerolls = 2
CreateBoonLootButtons({ Name = "ZeusUpgrade", ObjectId = 700, UpgradeOptions = {
    { ItemName = "ChamberGoldTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
no_mirror = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
print("   with rerolls: %s" % [t for t in weak if t.startswith("*")])
check(any("reroll?" in t for t in weak),
      "a weak screen with a reroll available suggests rerolling")
check(not any("reroll?" in t for t in none_left),
      "no reroll suggestion when none are left")
check(not any("reroll?" in t for t in no_mirror),
      "dice alone do not enable rerolls without Fated Persuasion")

# Pom rerolls must compare the current screen with the actual owned-boon pool.
# A fixed absolute threshold used to recommend rerolling forever even when all
# remaining targets were equally stale.
lua.execute("""
__meta = BoonAdvisor.MetaKeys.RerollPanel
CurrentRun.NumRerolls = 3
CurrentRun.CurrentRoom = {}
SetBuild({ "ArtemisShoutTrait", "ArtemisShoutTrait", "ArtemisShoutTrait",
    "AresShoutTrait", "AresShoutTrait", "AresShoutTrait",
    "PoseidonShoutTrait", "PoseidonShoutTrait", "PoseidonShoutTrait" })
""")
stale_loot = lua.table(Name="StackUpgrade", StackNum=1, ObjectId=701,
                       UpgradeOptions=lua.table_from([
                           lua.table(ItemName="ArtemisShoutTrait", Type="Trait", Rarity="Common"),
                           lua.table(ItemName="AresShoutTrait", Type="Trait", Rarity="Common"),
                           lua.table(ItemName="PoseidonShoutTrait", Type="Trait", Rarity="Common"),
                       ]))
stale_best = max(pom("ArtemisShoutTrait")["RawScore"],
                 pom("AresShoutTrait")["RawScore"],
                 pom("PoseidonShoutTrait")["RawScore"])
stale_reroll = lua.eval("BoonAdvisor.ShouldSuggestReroll")(stale_loot, stale_best)
check(not stale_reroll,
      "a uniformly stale Pom pool does not waste another reroll")

lua.execute("""
SetBuild({ "BowMarkHomingTrait", "DionysusSecondaryTrait",
    "ArtemisShoutTrait", "ArtemisShoutTrait", "ArtemisShoutTrait",
    "AresShoutTrait", "AresShoutTrait", "AresShoutTrait",
    "PoseidonShoutTrait", "PoseidonShoutTrait", "PoseidonShoutTrait" })
""")
weak_visible_best = max(pom("ArtemisShoutTrait")["RawScore"],
                        pom("AresShoutTrait")["RawScore"],
                        pom("PoseidonShoutTrait")["RawScore"])
better_pool_reroll = lua.eval("BoonAdvisor.ShouldSuggestReroll")(
    stale_loot, weak_visible_best)
check(better_pool_reroll,
      "a Pom reroll is suggested when the owned pool has a materially better target")

# The vanilla reroll excludes one random displayed item, not the whole screen.
# With exactly four eligible targets the unseen fourth target is guaranteed,
# while two of the three displayed targets return.
exact_eval = lua.eval("BoonAdvisor.EvaluateReroll")(stale_loot, weak_visible_best)
check(exact_eval["ImprovementChance"] == 1,
      "the exact four-target Pom pool always reaches the unseen build target")

# Sweet Nectar's PomLevelBonus has already been folded into StackNum by the
# vanilla screen. The reroll simulation must preserve it on every copied offer.
one_level_loot = lua.table(Name="StackUpgrade", StackNum=1, ObjectId=702,
                           UpgradeOptions=stale_loot["UpgradeOptions"])
two_level_loot = lua.table(Name="StackUpgrade", StackNum=2, ObjectId=703,
                           UpgradeOptions=stale_loot["UpgradeOptions"])
one_level_ev = lua.eval("BoonAdvisor.SimulateReroll")(one_level_loot, 0)["ExpectedScore"]
two_level_ev = lua.eval("BoonAdvisor.SimulateReroll")(two_level_loot, 0)["ExpectedScore"]
check(two_level_ev > one_level_ev,
      "Sweet Nectar raises the simulated value of every rerolled Pom offer")

# Ordinary boon advice uses the generated legal pool and actual rerolled
# rarities, not the old fixed score cutoff.
build()
regular_pool = lua.table_from([
    lua.table(ItemName="AthenaRushTrait", Type="Trait"),
    lua.table(ItemName="ZeusWeaponTrait", Type="Trait"),
    lua.table(ItemName="PoseidonShoutTrait", Type="Trait"),
    lua.table(ItemName="ArtemisWeaponTrait", Type="Trait"),
])
regular_loot = lua.table(Name="ZeusUpgrade", ObjectId=704,
                         RarityChances=lua.table(Rare=0, Epic=0),
                         RerollPool=regular_pool,
                         UpgradeOptions=lua.table_from([
                             lua.table(ItemName="ChamberGoldTrait", Type="Trait", Rarity="Common"),
                             lua.table(ItemName="FallbackMoneyDrop", Type="Consumable", Rarity="Common"),
                         ]))
regular_current = max(boon("ChamberGoldTrait")["RawScore"],
                      boon("FallbackMoneyDrop", typ="Consumable")["RawScore"])
regular_eval = lua.eval("BoonAdvisor.EvaluateReroll")(regular_loot, regular_current)
check(regular_eval["Available"] and regular_eval["Method"] == "exact"
      and regular_eval["Samples"] == 0,
	  "ordinary boon rerolls use deterministic probability math")
check(regular_eval["Suggested"],
      "a materially stronger ordinary-boon pool produces a reroll recommendation")

strong_current = boon("AthenaRushTrait")["RawScore"]
strong_loot = lua.table(Name="ZeusUpgrade", ObjectId=705,
                        RarityChances=lua.table(Rare=0, Epic=0),
                        RerollPool=regular_pool,
                        UpgradeOptions=lua.table_from([
                            lua.table(ItemName="AthenaRushTrait", Type="Trait", Rarity="Common"),
                            lua.table(ItemName="ZeusWeaponTrait", Type="Trait", Rarity="Common"),
                            lua.table(ItemName="PoseidonShoutTrait", Type="Trait", Rarity="Common"),
                        ]))
check(not lua.eval("BoonAdvisor.EvaluateReroll")(strong_loot, strong_current)["Suggested"],
      "a strong current choice is kept when the same pool is unlikely to improve it")

# The generator assigns future rarity before scoring. An Epic-only reroll pool
# must therefore have a higher expected value than the same Common-only pool.
common_loot = lua.table(Name="ZeusUpgrade", ObjectId=706,
                        RarityChances=lua.table(Rare=0, Epic=0),
                        RerollPool=regular_pool,
                        UpgradeOptions=regular_loot["UpgradeOptions"])
epic_loot = lua.table(Name="ZeusUpgrade", ObjectId=707,
                      RarityChances=lua.table(Rare=0, Epic=1),
                      RerollPool=regular_pool,
                      UpgradeOptions=regular_loot["UpgradeOptions"])
common_ev = lua.eval("BoonAdvisor.ForecastRerollOffer")(common_loot, 0)["ExpectedScore"]
epic_ev = lua.eval("BoonAdvisor.ForecastRerollOffer")(epic_loot, 0)["ExpectedScore"]
check(epic_ev > common_ev,
      "future rarity rolls are included in reroll expected value")

# The cache key must include those chances. The same panel can change when a
# rarity effect is gained without changing the visible choices.
cache_loot = lua.table(Name="ZeusUpgrade", ObjectId=706,
                       RarityChances=lua.table(Rare=0, Epic=0),
                       RerollPool=regular_pool,
                       UpgradeOptions=regular_loot["UpgradeOptions"])
cached_common = lua.eval("BoonAdvisor.EvaluateReroll")(cache_loot, 0)
cache_loot["RarityChances"]["Epic"] = 1
cached_epic = lua.eval("BoonAdvisor.EvaluateReroll")(cache_loot, 0)
check(cached_common["Signature"] != cached_epic["Signature"]
      and cached_epic["ExpectedScore"] > cached_common["ExpectedScore"],
      "reroll cache invalidates when rarity chances change")

# Approval Process blocks random generated options after SetTraitsOnLoot.
# Simulating that final visibility step must reduce the value of the same pool.
approval_loot_3 = lua.table(Name="ZeusUpgrade", ObjectId=708,
                            RarityChances=lua.table(Rare=0, Epic=0),
                            RerollPool=regular_pool,
                            UpgradeOptions=regular_loot["UpgradeOptions"])
lua.execute("function CalcNumLootChoices() return 3 end")
three_visible = lua.eval("BoonAdvisor.ForecastRerollOffer")(approval_loot_3, 0)["ExpectedScore"]
approval_loot_1 = lua.table(Name="ZeusUpgrade", ObjectId=709,
                            RarityChances=lua.table(Rare=0, Epic=0),
                            RerollPool=regular_pool,
                            UpgradeOptions=regular_loot["UpgradeOptions"])
lua.execute("function CalcNumLootChoices() return 1 end")
one_visible = lua.eval("BoonAdvisor.ForecastRerollOffer")(approval_loot_1, 0)["ExpectedScore"]
lua.execute("function CalcNumLootChoices() return 3 end")
check(three_visible > one_visible,
      "Approval Process lowers reroll expected value")

# Chaos uses the same reroll entry point but generates blessing/curse pairs.
# The copied offer must retain SecondaryItemName so both halves are scored.
chaos_pool = lua.table_from([
    lua.table(ItemName="ChaosBlessingMeleeTrait", SecondaryItemName="ChaosCursePrimaryAttackTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingMaxHealthTrait", SecondaryItemName="ChaosCurseNoMoneyTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingBoonRarityTrait", SecondaryItemName="ChaosCurseDamageTrait",
              Type="TransformingTrait"),
    lua.table(ItemName="ChaosBlessingMoneyTrait", SecondaryItemName="ChaosCurseSecondaryAttackTrait",
              Type="TransformingTrait"),
])
chaos_loot = lua.table(Name="TrialUpgrade", ObjectId=711,
                       RerollPool=chaos_pool,
                       UpgradeOptions=lua.table_from([
                           chaos_pool[1], chaos_pool[2], chaos_pool[3],
                       ]))
chaos_best = max(score(chaos_pool[i], chaos_loot)["RawScore"] for i in range(1, 4))
chaos_eval = lua.eval("BoonAdvisor.EvaluateReroll")(chaos_loot, chaos_best)
check(chaos_eval["Available"] and chaos_eval["Method"] == "exact-chaos"
	  and chaos_eval["Samples"] == 0,
	  "Chaos rerolls deterministically evaluate blessing and curse pairs")
chaos_common = score(lua.table(ItemName="ChaosBlessingMeleeTrait",
                               SecondaryItemName="ChaosCursePrimaryAttackTrait",
                               Type="TransformingTrait", Rarity="Common"), chaos_loot)
chaos_epic = score(lua.table(ItemName="ChaosBlessingMeleeTrait",
                             SecondaryItemName="ChaosCursePrimaryAttackTrait",
                             Type="TransformingTrait", Rarity="Epic"), chaos_loot)
check(chaos_epic["Score"] > chaos_common["Score"],
      "Chaos blessing rarity affects its rating")

# Reusing the panel costs additional dice and spending the last die is held to
# a higher standard even when the generated pool itself is unchanged.
CurrentRun = G["CurrentRun"]
CurrentRun["CurrentRoom"] = lua.table(SpentRerolls=lua.table_from({704: 1}))
CurrentRun["NumRerolls"] = 3
costly_eval = lua.eval("BoonAdvisor.EvaluateReroll")(regular_loot, regular_current)
check(costly_eval["Cost"] == 2 and costly_eval["RequiredGain"] == 10,
      "a repeated reroll costs two dice and requires four more expected points")
CurrentRun["CurrentRoom"] = lua.table()
CurrentRun["NumRerolls"] = 1
last_die_loot = lua.table(Name="ZeusUpgrade", ObjectId=710,
                          RarityChances=lua.table(Rare=0, Epic=0),
                          RerollPool=regular_pool,
                          UpgradeOptions=regular_loot["UpgradeOptions"])
last_die_eval = lua.eval("BoonAdvisor.EvaluateReroll")(last_die_loot, regular_current)
check(last_die_eval["RequiredGain"] == 8,
      "spending the final die requires an additional two expected points")

# The private simulation must never leave its RNG replacements installed.
lua.execute("__chanceBefore = RandomChance; __getBefore = GetRandomValue; __removeBefore = RemoveRandomValue")
lua.eval("BoonAdvisor.SimulateReroll")(last_die_loot, regular_current)
check(lua.eval("RandomChance == __chanceBefore and GetRandomValue == __getBefore and RemoveRandomValue == __removeBefore"),
      "reroll simulation restores every game RNG function")
lua.execute("CurrentRun.NumRerolls = 0; __meta = nil")

print("\n=== risk tolerance / armour / duo-rarity talent ===")
# All four Mirror keys must be real, not invented.
keys2 = lua.eval("BoonAdvisor.MetaKeys")
for label in ("PrivilegedStatus", "FamilyFavorite", "DuoRarity", "ExtraChance"):
    check(meta_data[keys2[label]] is not None,
          "Mirror key %s = %r is real" % (label, keys2[label]))

# Death Defiances make risky doors less frightening.
lua.execute("CurrentRun.Hero.MaxHealth = 150; CurrentRun.Hero.Health = 60")
lua.execute("CurrentRun.Hero.LastStands = {}")
build()
no_dd = door("Devotion")[0]
gate_no_dd = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=30))[0]
lua.execute("CurrentRun.Hero.LastStands = { {}, {} }")
two_dd = door("Devotion")[0]
gate_two_dd = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=30))[0]
lua.execute("CurrentRun.Hero.LastStands = {}")
print("   Trial at 40%% hp:      0 defiances %d  |  2 defiances %d" % (no_dd, two_dd))
print("   Chaos gate (30 hp):   0 defiances %d  |  2 defiances %d"
      % (int(gate_no_dd), int(gate_two_dd)))
check(two_dd > no_dd, "Death Defiances make the Trial less risky (%d -> %d)" % (no_dd, two_dd))
check(gate_two_dd > gate_no_dd, "and the Chaos gate cheaper in real terms")

# The duo-rarity talent raises the value of chasing duos.
lua.execute("function GetNumMetaUpgrades(n) return 0 end")
plain_factor = lua.eval("BoonAdvisor.DuoPursuitFactor")()
lua.execute("function GetNumMetaUpgrades(n) return 10 end")
boosted_factor = lua.eval("BoonAdvisor.DuoPursuitFactor")()
lua.execute("function GetNumMetaUpgrades(n) return 0 end")
check(boosted_factor > plain_factor,
      "duo pursuit scales with the Mirror talent (%.2f -> %.2f)"
      % (plain_factor, boosted_factor))

# Approval Process reduces visible choices and makes a specific duo less
# reliable to force, even when the underlying pool is unchanged.
lua.execute("function CalcNumLootChoices() return 3 end")
three_choices = lua.eval("BoonAdvisor.DuoPursuitFactor")()
lua.execute("function CalcNumLootChoices() return 1 end")
one_choice = lua.eval("BoonAdvisor.DuoPursuitFactor")()
lua.execute("function CalcNumLootChoices() return 3 end")
check(one_choice < three_choices,
      "Approval Process lowers duo-pursuit value (%.2f -> %.2f)"
      % (three_choices, one_choice))

print("\n=== rarity Mirror talents actually fire ===")
lua.execute("""
CurrentRun.Hero.BoonData = { RareChance = 0.10, EpicChance = 0.05 }
__metalevels = 0
function GetNumMetaUpgrades(n) return __metalevels end
function GetHeroTraitValues(n) return {} end
""")
build()
erb = lua.eval("BoonAdvisor.ExpectedRarityBonus")
base_rar = erb("ZeusUpgrade")
lua.execute("__metalevels = 40")  # max investment in the rarity talents
maxed_rar = erb("ZeusUpgrade")
lua.execute("__metalevels = 0")
print("   expected-rarity points: 0 invested %.2f | maxed %.2f" % (base_rar, maxed_rar))
check(maxed_rar > base_rar,
      "RareBoonDrop/EpicBoonDrop/EpicHeroicBoon raise expected rarity (%.2f -> %.2f)"
      % (base_rar, maxed_rar))

# A keepsake's god-gated RarityBonus must apply to that god only.
lua.execute("""
function GetHeroTraitValues(n)
    if n == "RarityBonus" then
        return { { RequiredGod = "ZeusUpgrade", RareBonus = 0.5, EpicBonus = 0.3 } }
    end
    return {}
end
""")
zeus_rar = erb("ZeusUpgrade")
other_rar = erb("AresUpgrade")
lua.execute("function GetHeroTraitValues(n) return {} end")
check(zeus_rar > other_rar,
      "a keepsake's RarityBonus applies to its own god only (%.2f vs %.2f)"
      % (zeus_rar, other_rar))

# Mirror selection, screen blocking and escalating per-object cost all govern
# whether the vanilla boon screen exposes an affordable reroll.
can_reroll = lua.eval("BoonAdvisor.CanRerollLoot")
reroll_loot = lua.table(Name="ZeusUpgrade", ObjectId=701, BlockReroll=False)
lua.execute("""
__meta = BoonAdvisor.MetaKeys.RerollPanel
CurrentRun.NumRerolls = 1
CurrentRun.CurrentRoom.SpentRerolls = {}
""")
check(can_reroll(reroll_loot), "Fated Persuasion plus one die enables a boon reroll")
reroll_loot["BlockReroll"] = True
check(not can_reroll(reroll_loot), "a screen's BlockReroll flag is respected")
reroll_loot["BlockReroll"] = False
lua.execute("CurrentRun.CurrentRoom.SpentRerolls[701] = 1")
check(not can_reroll(reroll_loot),
      "the escalating reroll cost is checked against remaining dice")
hammer_loot = lua.table(Name="WeaponUpgrade", ObjectId=702, BlockReroll=False)
check(not can_reroll(hammer_loot), "the game's disabled hammer reroll remains unavailable")
lua.execute("CurrentRun.CurrentRoom.SpentRerolls = nil; CurrentRun.NumRerolls = 0; __meta = nil")

# Legendary/Duo chance matters only when this god has an eligible gated boon.
lua.execute("CurrentRun.Hero.BoonData.LegendaryChance = 0.12")
legendary_rar = erb("ZeusUpgrade", True)
ordinary_rar = erb("ZeusUpgrade", False)
check(legendary_rar > ordinary_rar,
      "LegendaryChance contributes only for a pool with an eligible gated boon")

print("\n=== pick logging (validation channel) ===")
lua.execute("""
__log = {}
function DebugPrint(a) table.insert(__log, tostring(a.Text)) end
function HandleUpgradeChoiceSelection(s, b)
    __picked = true
    if b ~= nil and b.Data ~= nil and b.Data.Name ~= nil then
        table.insert(CurrentRun.Hero.Traits, { Name = b.Data.Name })
    end
end
""")
lua.execute("BoonAdvisor.Installed = nil")
load(os.path.join(MOD, "BoonAdvisor.lua"))
G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"] = 0
lua.execute("function CreateTextBox(a) table.insert(__boxes, a) end")

# Off by default: no log spam for players who never enable it.
lua.execute("BoonAdvisor.Config.LogPicks = false; __log = {}; __boxes = {}")
build()
lua.execute("""
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "AthenaRushTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ZeusWeaponTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
check(len(G["__log"]) == 0, "logging is silent when disabled")

# Test the channel that actually ships: a file. The mod writes to disk and only
# falls back to DebugPrint, so asserting on the DebugPrint stub would pass even
# if nothing were ever written -- which is precisely how this shipped dead once.
import os as _os
_logfile = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                         "picklog_test.log")
if _os.path.exists(_logfile):
    _os.remove(_logfile)
lua.execute("BoonAdvisor.Config.LogPicks = true; __log = {}; __boxes = {}")
lua.execute("BoonAdvisor.Config.LogFilePath = [[%s]]" % _logfile.replace("\\", "\\\\"))
lua.execute("""
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "AthenaRushTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ZeusWeaponTrait", Rarity = "Common", Type = "Trait" } }}, false)
HandleUpgradeChoiceSelection({}, { Data = { Name = "ZeusWeaponTrait" } })
CurrentRun.Money = 30
CurrentRun.CurrentRoom = {}
__shopDoor = { ObjectId = 801, Room = { ChosenRewardType = "Shop" } }
__healthDoor = { ObjectId = 802, Room = { ChosenRewardType = "Health" } }
BoonAdvisor.DoorCandidateRoom = CurrentRun.CurrentRoom
BoonAdvisor.DoorCandidates = { [801] = __shopDoor, [802] = __healthDoor }
BoonAdvisor.LogDoorChoice(__healthDoor)
CurrentRun.CurrentRoom.Name = "A_Combat05"
CurrentRun.CurrentRoom.Encounter = { Name = "GeneratedA", EncounterType = "Default",
    ClearTime = 31.4, PlayerTookDamage = true }
DamageRecord = { Thug = 12, Wretch = 7 }
BoonAdvisor.LogRoomOutcome(CurrentRun, __healthDoor)
DamageRecord = nil
CurrentRun.DamageRecord = { Thug = 12, Wretch = 7, Megaera = 40 }
LastKilledByUnitName = "Megaera"
GameState.LastAwardTrait = "ShieldBossTrait"
BoonAdvisor.LastKeepsakeEvaluation =
    BoonAdvisor.EvaluateKeepsakeRack(__availableKeepsakes)
BoonAdvisor.LogKeepsakeChoice(GameState.LastAwardTrait)
CurrentRun.Cleared = true
CurrentRun.GameplayTime = 1234
CurrentRun.EndingRoomName = "D_Boss01"
BoonAdvisor.LogRunEnd(CurrentRun)
""")
check(lua.eval("BoonAdvisor.LogChannel") == "file",
      "picks are written to a file, not just DebugPrint (channel=%s)"
      % lua.eval("BoonAdvisor.LogChannel"))
logged = []
if _os.path.exists(_logfile):
    logged = [l.strip() for l in io.open(_logfile, encoding="utf-8") if l.strip()]
    _os.remove(_logfile)
lua.execute("BoonAdvisor.Config.LogFilePath = nil")
for line in logged:
    print("   %s" % line)
lua.execute("BoonAdvisor.Config.LogPicks = false")
check(any("[offer]" in l for l in logged), "the offer and its scores are logged")
check(any("weapon=" in l and "hp=" in l and "loot=ZeusUpgrade" in l for l in logged),
      "offer logs include enough run context to audit the decision")
check(any("*AthenaRushTrait=" in l for l in logged), "the recommendation is marked")
check(any("[took" in l and "taken=ZeusWeaponTrait" in l and "kind=boon" in l
          and "margin=" in l and "recommended=AthenaRushTrait" in l for l in logged),
      "the pick actually taken is logged with its kind and margin")
check(any("[offer]" in l and "base=" in l and "slot=" in l for l in logged),
      "offer lines carry the per-term score breakdown")
check(any("[room ]" in l and "damage_taken=" in l and "clear=" in l for l in logged),
      "leaving a room logs the room outcome")
check(any("[run-end]" in l and "killer=" in l and "damage_taken=" in l for l in logged),
      "run summaries name the killer and total damage taken")
check(any("[door ]" in l and "gold=30" in l and "took=Health" in l
          and "*Health=70" in l for l in logged),
      "door telemetry records the purse, recommendation, alternatives, and choice")
check(any("[keep ]" in l and "took=ShieldBossTrait" in l
          and "recommended=" in l and "stage=" in l for l in logged),
      "optional telemetry records the keepsake recommendation and choice")
check(any("[run-end]" in l and "result=clear" in l and "time=1234" in l
          and "build=" in l for l in logged),
      "run telemetry ends with an outcome, time, and final build")
check(G["__picked"] is True, "the selection hook still calls through to vanilla")

# In game, telemetry must leave the active UI frame before touching disk. The
# no-thread test harness above retains a synchronous fallback for tooling.
_async_logfile = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                               "picklog_async_test.log")
if _os.path.exists(_async_logfile):
    _os.remove(_async_logfile)
lua.execute("BoonAdvisor.Config.LogFilePath = [[%s]]"
            % _async_logfile.replace("\\", "\\\\"))
lua.execute("""
__queuedTelemetryThread = nil
function wait(duration) __telemetryWait = duration end
function thread(fn, args) __queuedTelemetryThread = { Fn=fn, Args=args } end
BoonAdvisor.LogLine("[async] frame-safe")
""")
check(lua.eval("__queuedTelemetryThread") is not None
      and not _os.path.exists(_async_logfile),
      "enabled telemetry performs no disk I/O in the active UI frame")
lua.execute("__queuedTelemetryThread.Fn(__queuedTelemetryThread.Args)")
async_logged = []
if _os.path.exists(_async_logfile):
    async_logged = [l.strip() for l in io.open(_async_logfile, encoding="utf-8")
                    if l.strip()]
    _os.remove(_async_logfile)
check("[async] frame-safe" in async_logged,
      "deferred telemetry flushes the queued event")
lua.execute("thread = nil; wait = nil; BoonAdvisor.Config.LogFilePath = nil")
lua.execute("""
CurrentRun.Cleared = nil
CurrentRun.GameplayTime = 0
CurrentRun.Money = 500
CurrentRun.EndingRoomName = nil
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
""")

print("\n=== wall slams scale by biome ===")
# Combat.lua:860 multiplies collision damage by the room's WallSlamMultiplier:
# Tartarus none, Asphodel 1.5, Elysium 2.0, Styx 2.5.
build()
kb = {}
for mult, biome in ((None, "Tartarus"), (1.5, "Asphodel"),
                    (2.0, "Elysium"), (2.5, "Styx")):
    lua.execute("CurrentRun.CurrentRoom.WallSlamMultiplier = %s"
                % ("nil" if mult is None else mult))
    r = boon("PoseidonWeaponTrait")
    kb[biome] = (r["Score"], r["Reason"])
    print("   %-9s %3d  %s" % (biome, r["Score"], r["Reason"]))
check(kb["Styx"][0] > kb["Tartarus"][0],
      "Poseidon knockback is worth more in Styx than Tartarus (%d vs %d)"
      % (kb["Tartarus"][0], kb["Styx"][0]))
check(kb["Elysium"][0] > kb["Asphodel"][0], "and more in Elysium than Asphodel")
# A non-knockback boon must be unaffected by the biome.
lua.execute("CurrentRun.CurrentRoom.WallSlamMultiplier = 2.5")
styx_other = boon("AthenaRushTrait")["Score"]
lua.execute("CurrentRun.CurrentRoom.WallSlamMultiplier = nil")
tart_other = boon("AthenaRushTrait")["Score"]
check(styx_other == tart_other,
      "a non-knockback boon is unaffected by wall-slam scaling (%d vs %d)"
      % (tart_other, styx_other))

print("\n=== Aspect of Chiron (Hangover) ===")
build("BowMarkHomingTrait", "DionysusSecondaryTrait", "AphroditeWeaponTrait")
low_tolerance = boon("DionysusAphroditeStackIncreaseTrait")
build("BowMarkHomingTrait")
core = boon("DionysusSecondaryTrait")
build("BowBaseUpgradeTrait")
core_nochiron = boon("DionysusSecondaryTrait")
print("   Low Tolerance on Chiron:     %d  %s" % (low_tolerance["Score"], low_tolerance["Reason"]))
print("   Drunken Flourish on Chiron:  %d  %s" % (core["Score"], core["Reason"]))
print("   Drunken Flourish, base bow:  %d  %s" % (core_nochiron["Score"], core_nochiron["Reason"]))
check("Chiron" in low_tolerance["Reason"], "Low Tolerance is flagged as the Chiron payoff")
check("Chiron" in core["Reason"], "Drunken Flourish is flagged as Chiron core")
check(core["Score"] > core_nochiron["Score"],
      "Drunken Flourish is worth more on Chiron than the base bow")

# Chiron wants special hammers, not Perfect Shot.
build("BowMarkHomingTrait")
hammers = {}
for h in ("BowSecondaryBarrageTrait", "BowConsecutiveBarrageTrait", "BowPowerShotTrait"):
    s, why = lua.eval("BoonAdvisor.ScoreHammer")(h)
    hammers[h] = (int(finalize(s)), why)
    print("   %-28s %d  %s" % (names.get(h, h), hammers[h][0], why))
check(hammers["BowSecondaryBarrageTrait"][0] > hammers["BowPowerShotTrait"][0],
      "on Chiron, volley hammers beat Perfect Shot")

###########################################################################
print("\n=== god doors: slotless offers ===")
# Artemis has slotless boons (crit bonus, Clean Kill), so a full slot board
# must not be reported as "would swap".
build("ArtemisWeaponTrait", "ArtemisSecondaryTrait", "ArtemisRangedTrait",
      "ArtemisRushTrait", "ArtemisShoutTrait")
v, r, why = door("Boon", "ArtemisUpgrade")
print("   Artemis door, all slots full: %s %d  %s" % (r, v, why))
check("would swap" not in why, "a god with slotless boons is not called a swap")

hermes_door = door("HermesUpgrade")
check(hermes_door[2] != "Hermes boon",
      "a Hermes door is scored from its eligible boon pool (%r)" % hermes_door[2])

# Linked boons must enter door pools only after their actual game-data
# prerequisites are met. Sea Storm is listed in both contributing god pools.
get_candidates = lua.eval("BoonAdvisor.GetGodCandidateTraits")
build()
zeus_fresh_lua = get_candidates("ZeusUpgrade")
zeus_fresh = {zeus_fresh_lua[i] for i in range(1, len(zeus_fresh_lua) + 1)}
build("ZeusWeaponTrait", "PoseidonRushTrait")
zeus_dash_lua = get_candidates("ZeusUpgrade")
zeus_dash = {zeus_dash_lua[i] for i in range(1, len(zeus_dash_lua) + 1)}
build("ZeusWeaponTrait", "PoseidonSecondaryTrait")
zeus_ready_lua = get_candidates("ZeusUpgrade")
poseidon_ready_lua = get_candidates("PoseidonUpgrade")
zeus_ready = {zeus_ready_lua[i] for i in range(1, len(zeus_ready_lua) + 1)}
poseidon_ready = {poseidon_ready_lua[i] for i in range(1, len(poseidon_ready_lua) + 1)}
check("ImpactBoltTrait" not in zeus_fresh,
      "Sea Storm is absent from a god door before its prerequisites")
check("ImpactBoltTrait" not in zeus_dash,
      "Tidal Dash can trigger Sea Storm but does not unlock the duo")
check("ImpactBoltTrait" in zeus_ready and "ImpactBoltTrait" in poseidon_ready,
      "Sea Storm enters both contributing god pools once unlocked")

# A god door is an expected offer, not a guarantee of the best boon in the
# entire pool; Approval Process must therefore lower the door's value.
build()
lua.execute("function CalcNumLootChoices() return 3 end")
three_choice_door = door("Boon", "ZeusUpgrade")[0]
lua.execute("function CalcNumLootChoices() return 1 end")
one_choice_door = door("Boon", "ZeusUpgrade")[0]
lua.execute("function CalcNumLootChoices() return 3 end")
check(three_choice_door > one_choice_door,
      "Approval Process lowers expected god-door quality (%d -> %d)"
      % (three_choice_door, one_choice_door))

print("\n=== resource and shop doors ===")
build("ZeusWeaponTrait")
lua.execute("""GameState.Cosmetics = {}; GameState.CosmeticsAdded = {}
CurrentRun.Money = 30; __meta = nil""")
poor_shop = door("Shop")
heart_at_poor_shop = door("Health")
lua.execute("CurrentRun.Money = 250")
funded_shop = door("Shop")
check(poor_shop[0] < heart_at_poor_shop[0] and funded_shop[0] > poor_shop[0],
      "shop value follows actual buying power (%d -> %d)" %
      (poor_shop[0], funded_shop[0]))
check("cannot afford" in poor_shop[2],
      "a 30-Obol shop explains the affordability problem")

plain_key = door("LockKey")
plain_nectar = door("Gift")
plain_darkness = door("MetaPoints")
plain_gems = door("Gems")
lua.execute("""GameState.Cosmetics = {
    LockKeyDropRunProgress = false,
    GiftDropRunProgress = false,
    RoomRewardMetaPointDropRunProgress = false,
    GemDropRunProgress = false }
GameState.CosmeticsAdded = {
    LockKeyDropRunProgress = false,
    GiftDropRunProgress = false,
    RoomRewardMetaPointDropRunProgress = false,
    GemDropRunProgress = false }
__meta = BoonAdvisor.MetaKeys.RerollPanel""")
locked_key = door("LockKey")
locked_nectar = door("Gift")
locked_darkness = door("MetaPoints")
locked_gems = door("Gems")
check(locked_key[0] == plain_key[0] and locked_nectar[0] == plain_nectar[0]
      and locked_darkness[0] == plain_darkness[0]
      and locked_gems[0] == plain_gems[0],
      "locked Contractor upgrades do not add run-progress value")
lua.execute("""GameState.Cosmetics = {
    LockKeyDropRunProgress = true,
    GiftDropRunProgress = true,
    RoomRewardMetaPointDropRunProgress = true,
    GemDropRunProgress = true }
__meta = BoonAdvisor.MetaKeys.RerollPanel""")
progress_key = door("LockKey")
progress_nectar = door("Gift")
progress_darkness = door("MetaPoints")
progress_gems = door("Gems")
check(progress_key[0] > plain_key[0] and "+ 1 reroll" in progress_key[2],
      "the Key Contractor upgrade adds its run reroll")
check(progress_nectar[0] > plain_nectar[0] and "random boon level" in progress_nectar[2],
      "the Nectar Contractor upgrade adds its random Pom")
check(progress_darkness[0] > plain_darkness[0] and "+5 max health" in progress_darkness[2],
      "the Darkness Contractor upgrade adds its 5 max health")
check(progress_gems[0] > plain_gems[0] and "+20 Obols" in progress_gems[2],
      "the Gemstone Contractor upgrade adds its 20 Obols")

lua.execute("""GameState.Cosmetics = {}
GameState.CosmeticsAdded = {
    LockKeyDropRunProgress = true,
    GiftDropRunProgress = true,
    RoomRewardMetaPointDropRunProgress = true,
    GemDropRunProgress = true }""")
check(door("LockKey")[0] == progress_key[0]
      and door("Gift")[0] == progress_nectar[0]
      and door("MetaPoints")[0] == progress_darkness[0]
      and door("Gems")[0] == progress_gems[0],
      "migrated saves retain purchased Contractor upgrade value")

# Infernal Gate rooms override the normal room reward rather than creating a
# separate reward type: 50 health, 200 Obols, two Pom levels, and high rarity.
elite_overrides = lua.table(AddMaxHealth=50, DropMoney=200)
elite_heart = door("Health", RewardConsumableOverrides=elite_overrides)
elite_money = door("Money", RewardConsumableOverrides=elite_overrides)
normal_heart = door("Health")
normal_money = door("Money")
check(elite_heart[0] > normal_heart[0] and "+50 max health" in elite_heart[2],
      "an Infernal Gate Heart uses its doubled reward")
check("+200 Obols" in elite_money[2] and elite_money[0] == normal_money[0],
      "an Infernal Gate gold room reports its doubled payout")

build("ZeusWeaponTrait")
normal_pom_door = door("StackUpgrade")
elite_pom_door = door("StackUpgrade", StackNumOverride=2)
check(elite_pom_door[0] > normal_pom_door[0] and "+2 levels" in elite_pom_door[2],
      "an Infernal Gate Pom values both levels")

elite_rarity = lua.table(RareChance=0.90, EpicChance=0.25,
                         LegendaryChance=0.10)
normal_boon_door = door("Boon", "ZeusUpgrade")
elite_boon_door = door("Boon", "ZeusUpgrade",
                       BoonRaritiesOverride=elite_rarity)
check(elite_boon_door[0] > normal_boon_door[0],
      "an Infernal Gate boon reads the destination room rarity")

lua.execute("CurrentRun.ConsumableRecord = {}; __depth = 10")
early_heart = lua.eval("BoonAdvisor.ScoreMaxHealthDoor")(lua.table())[0]
lua.execute("CurrentRun.ConsumableRecord.RoomRewardMaxHealthDrop = 8; __depth = 35")
late_heart = lua.eval("BoonAdvisor.ScoreMaxHealthDoor")(lua.table())[0]
check(early_heart > late_heart,
      "Centaur Hearts diminish after repeated pickups and late in the run")

story_raw, story_reason = lua.eval("BoonAdvisor.ScoreStoryDoor")(
    lua.table(RoomSetName="Asphodel"))
check(story_raw > G["BoonAdvisor"]["Config"]["Doors"]["Types"]["Story"]
      and story_reason != "story room",
      "story doors use the best live Eurydice choice instead of a flat tier")

lua.execute("NPCData = { NPC_Sisyphus_01 = { MoneyMin=200, MoneyMax=220, MetaPointMin=80, MetaPointMax=100 } }")
sisy_money = lua.eval("BoonAdvisor.ScoreStoryChoiceRaw")("ChoiceText_Money")[1]
check("210" in sisy_money,
      "Sisyphus values are read from NPCData instead of hardcoded")
lua.execute("NPCData = nil")

well_score, well_reason = lua.eval("BoonAdvisor.ScoreShopItem")(
    lua.table(Name="TemporaryImprovedWeaponTrait", Type="Consumable"))
check(well_score > 0 and "unrated" not in well_reason,
      "known Well of Charon items receive contextual ratings")

well_names = list(G["BoonAdvisor"]["Config"]["Shop"]["WellItems"].keys())
well_names.extend(["TemporaryDoorHealTrait", "TemporaryWeaponLifeOnKillTrait",
                   "EmptyMaxHealthDrop", "DamageSelfDrop"])
lua.execute("CurrentRun.Hero.Health = 100; CurrentRun.Hero.MaxHealth = 100")
unrated_well = []
for name in well_names:
    _, reason = lua.eval("BoonAdvisor.ScoreShopItem")(
        lua.table(Name=name, Type="Trait", HealthCost=25))
    if "unrated" in reason:
        unrated_well.append(name)
check(not unrated_well, "every Well of Charon item has an explicit scoring path%s" %
      ("" if not unrated_well else " -- MISSING %s" % unrated_well))

lua.execute("__depth = 5; CurrentRun.CurrentRoom = { RoomSetName='Tartarus' }; CurrentRun.BiomeDepthCache = 2")
early_gate = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=20))[0]
lua.execute("__depth = 35; CurrentRun.CurrentRoom = { RoomSetName='Styx' }; CurrentRun.BiomeDepthCache = nil")
late_gate, late_gate_reason = lua.eval("BoonAdvisor.ScoreChaosGate")(
    lua.table(HealthCost=20))
check(early_gate > late_gate and "less run remains" in late_gate_reason,
      "Chaos gates lose value when little run remains for the blessing")

lua.execute("CurrentRun.Money = 250; __depth = 10")
early_money = lua.eval("BoonAdvisor.ScoreMoneyDoor")(lua.table())[0]
lua.execute("__depth = 38")
late_money, late_money_reason = lua.eval("BoonAdvisor.ScoreMoneyDoor")(lua.table())
check(early_money > late_money and "fewer shops" in late_money_reason,
      "gold rooms account for the shorter late-run spending window")

lua.execute("""
CurrentRun.CurrentRoom = { RoomSetName='Elysium' }
CurrentRun.BiomeDepthCache = 2
""")
far_chaos = lua.eval("BoonAdvisor.ScoreChaos")(lua.table(
    ItemName="ChaosBlessingMeleeTrait",
    SecondaryItemName="ChaosCursePrimaryAttackTrait", Rarity="Common"))[0]
lua.execute("CurrentRun.BiomeDepthCache = 8")
near_chaos, near_reason = lua.eval("BoonAdvisor.ScoreChaos")(lua.table(
    ItemName="ChaosBlessingMeleeTrait",
    SecondaryItemName="ChaosCursePrimaryAttackTrait", Rarity="Common"))
check(near_chaos < far_chaos and "boss" in near_reason,
      "Chaos curses are discounted when they can remain active at the boss")

build("ZeusLightningDebuff", "AresLongCurseTrait",
      "DionysusPoisonPowerTrait", "DemeterRangedBonusTrait")
crowded_god_score, crowded_god_reason = lua.eval("BoonAdvisor.ScoreGodDoor")(
    "PoseidonUpgrade", lua.table())
check("full god pool" in crowded_god_reason,
      "new gods are discounted after the run's god pool is already broad")

lua.execute("""
CurrentRun.CurrentRoom = { Name='A_StateRefresh', RoomSetName='Tartarus' }
CurrentRun.Money = 30
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
__refreshShopDoor = { ObjectId=8101, DoorIconId=9101,
    Room={ ChosenRewardType='Shop' } }
__refreshHeartDoor = { ObjectId=8102, DoorIconId=9102,
    Room={ ChosenRewardType='Health' } }
BoonAdvisor.RegisterDoor(__refreshShopDoor)
BoonAdvisor.RegisterDoor(__refreshHeartDoor)
BoonAdvisor.RefreshDoorOverlays()
__poorBestDoor = BoonAdvisor.LastBestDoorObjectId
CurrentRun.Money = 250
BoonAdvisor.MarkRunStateDirty()
__fundedBestDoor = BoonAdvisor.LastBestDoorObjectId
""")
check(lua.eval("__poorBestDoor") == 8102 and lua.eval("__fundedBestDoor") == 8101,
      "door advice refreshes when the purse changes after exits appear")

lua.execute("""GameState.Cosmetics = {}; __meta = nil
CurrentRun.Money = 500; CurrentRun.ConsumableRecord = {}; __depth = 20
CurrentRun.BiomeDepthCache = nil
BoonAdvisor.DoorCandidateRoom = nil; BoonAdvisor.DoorCandidates = {}""")

###########################################################################
print("\n=== pom vs trial of the gods ===")
lua.execute("CurrentRun.Hero.MaxHealth = 150; __depth = 20")

build("ZeusWeaponTrait", "AthenaRushTrait")
lua.execute("__ineligibleTrait = 'AthenaRushTrait'")
pom_candidates_lua = lua.eval("BoonAdvisor.GetPomCandidates")(G["LootData"]["StackUpgrade"])
pom_candidates = {pom_candidates_lua[i] for i in range(1, len(pom_candidates_lua) + 1)}
check("ZeusWeaponTrait" in pom_candidates and "AthenaRushTrait" not in pom_candidates,
      "Pom forecasts use the same eligibility filter as the game")
lua.execute("__ineligibleTrait = nil")

# Pom targets use the live aspect/build, current rarity, current level, and
# multi-level reward size rather than only a global boon tier.
build("DionysusSecondaryTrait")
plain_special = pom("DionysusSecondaryTrait")
build("BowMarkHomingTrait", "DionysusSecondaryTrait")
chiron_special = pom("DionysusSecondaryTrait")
check(chiron_special["Score"] > plain_special["Score"],
      "Chiron raises the value of levelling its core Special")
check("Chiron Hangover" in chiron_special["Reason"],
      "the Pom explains the active build context (%r)" % chiron_special["Reason"])

lua.execute("CurrentRun.Hero.Traits = { { Name = 'ZeusWeaponTrait', Rarity = 'Common' } }")
common_pom = pom("ZeusWeaponTrait")
lua.execute("CurrentRun.Hero.Traits = { { Name = 'ZeusWeaponTrait', Rarity = 'Epic' } }")
epic_pom = pom("ZeusWeaponTrait")
check(epic_pom["Score"] > common_pom["Score"],
      "existing boon rarity informs Pom value")
check(pom("ZeusWeaponTrait", stack=2)["Score"] > epic_pom["Score"],
      "a multi-level Pom values every granted level")
door_heal_curve = lua.eval("BoonAdvisor.PomCurveForTrait")("DoorHealTrait")
check(abs(door_heal_curve[0] - 0.4) < 0.001,
      "Pom scoring reads Door Heal's custom 0.4 diminishing curve")

print("   %-30s %-10s %s" % ("scenario", "pom", "trial"))
for hp, hl in ((150, "full hp"), (90, "60% hp"), (50, "33% hp")):
    for b, bl in ((["ArtemisWeaponTrait"], "Lv.1 boon"),
                  (["ArtemisWeaponTrait"] * 4, "Lv.4 boon")):
        build(*b)
        lua.execute("CurrentRun.Hero.Health = %d" % hp)
        p, pr, _ = door("StackUpgrade")
        t, tr, _ = door("Devotion")
        print("   %-30s %-10s %s" % ("%s, %s" % (hl, bl), "%s %d" % (pr, p), "%s %d" % (tr, t)))
build("ArtemisWeaponTrait")
lua.execute("CurrentRun.Hero.Health = 150")
pom_fresh = door("StackUpgrade")[0]
trial_full = door("Devotion")[0]
build(*(["ArtemisWeaponTrait"] * 4))
pom_stale = door("StackUpgrade")[0]
check(trial_full > pom_stale,
      "a Trial at full health beats a stale pom (%d vs %d)" % (trial_full, pom_stale))
# A Trial yields TWO boons, so at healthy HP it must outrank an ORDINARY boon
# door. The comparison must be against a door with no duo lead -- a door that
# completes a specific duo you need can rightly beat two generic boons.
build()
lua.execute("CurrentRun.Hero.Health = 150")
one_boon = door("Boon", "PoseidonUpgrade")[0]
two_boons = door("Devotion")[0]
check(two_boons > one_boon,
      "a Trial (2 boons) outranks a single boon door at full health (%d vs %d)"
      % (two_boons, one_boon))

# SetupRoomReward chooses both gods before AssignRoomToExitDoor and the door
# preview. A known Trial must therefore value the two real god pools rather
# than falling back to a generic two-boon constant.
known_trial_room = lua.table(
    ChosenRewardType="Devotion",
    Encounter=lua.table(LootAName="ArtemisUpgrade",
                        LootBName="DionysusUpgrade"))
known_trial_raw, known_trial_reason = scoredoor(known_trial_room)
known_trial = int(finalize(known_trial_raw))
artemis_door = door("Boon", "ArtemisUpgrade")
check(known_trial > artemis_door[0],
      "Artemis + Dionysus Trial beats the single Artemis door (%d vs %d)"
      % (known_trial, artemis_door[0]))
check("Artemis + Dionysus" in known_trial_reason,
      "known Trial reason names both generated gods (%r)" % known_trial_reason)

# Duo boons are the one quality restriction in a Trial:
# TraitData.SynergyTrait.RequiredFalseRewardType == "Devotion".
build("AphroditeWeaponTrait", "ArtemisSecondaryTrait")
normal_candidates = lua.eval("BoonAdvisor.GetGodCandidateTraits")(
    "ArtemisUpgrade", lua.table())
trial_candidates = lua.eval("BoonAdvisor.GetGodCandidateTraits")(
    "ArtemisUpgrade", lua.table(ExcludeDuo=True))
contains_name = lua.eval("function(t, n) for _, v in ipairs(t) do "
                         "if v == n then return true end end return false end")
build("PoseidonRushTrait")
athena_with_dash_filled = lua.eval("BoonAdvisor.GetGodCandidateTraits")(
    "AthenaUpgrade", lua.table())
check(not contains_name(athena_with_dash_filled, "AthenaRushTrait"),
      "god-door forecasts exclude occupied core slots")

check(contains_name(normal_candidates, "HeartsickCritDamageTrait"),
      "ordinary Artemis doors can offer eligible Duo boons")
check(not contains_name(trial_candidates, "HeartsickCritDamageTrait"),
      "Trial god forecasts exclude Duo boons")

lua.execute("CurrentRun.Hero.Health = 40")
check(door("Devotion")[0] < two_boons, "the Trial still loses value when hurt")
check(pom_fresh > pom_stale, "a fresh pom target beats a stacked one")

# A Pom offers a RANDOM subset, so holding one excellent scaling target among
# many utility targets must not score as if that target were guaranteed.
build("ZeusWeaponTrait")
only_best = door("StackUpgrade")
build("ZeusWeaponTrait", "AthenaRushTrait", "DionysusRushTrait",
      "ArtemisRushTrait", "ZeusRushTrait", "AphroditeRushTrait",
      "AresRushTrait", "PoseidonRushTrait")
buried = door("StackUpgrade")
print("   only Lightning Strike held:   %s %d  %s" % (only_best[1], only_best[0], only_best[2]))
print("   Lightning Strike among 7 utility targets: %s %d  %s" % (buried[1], buried[0], buried[2]))
check(only_best[0] > buried[0],
      "a great pom target buried in a big pool is worth less (%d vs %d)"
      % (only_best[0], buried[0]))
check("of your" in buried[2],
      "the note admits only a subset is offered (%r)" % buried[2])

###########################################################################
print("\n=== chaos gate reaches the overlay ===")
lua.execute("""
__boxes = {}
CurrentRun.Hero.Health = 100
AssignRoomToExitDoor({ ObjectId = 555, HealthCost = 20, HideRewardPreview = true,
    Room = { ChosenRewardType = nil } }, {})
""")
gate = G["__boxes"]
check(len(gate) == 2, "the Chaos gate is drawn via AssignRoomToExitDoor (got %d)" % len(gate))
if len(gate) >= 1:
    check(gate[1]["Id"] == 555, "gate text anchors to the door object")
    print("   drew: %s" % [gate[i]["LuaValue"]["BALine"] for i in range(1, len(gate) + 1)])
    check(all(gate[i]["Width"] for i in range(1, len(gate) + 1)),
          "world text sets an explicit Width so it is not clipped")

# A normal door must not be double-drawn by both hooks.
lua.execute("""
__boxes = {}
__d = { ObjectId = 777, DoorIconId = 1777, Room = { ChosenRewardType = "Money" } }
AssignRoomToExitDoor(__d, __d.Room)
CreateDoorRewardPreview(__d)
""")
door_lines = [G["__boxes"][i]["Id"] for i in range(1, len(G["__boxes"]) + 1)]
check(door_lines.count(1777) == 2,
      "a normal door is drawn exactly once (got %d lines)" % door_lines.count(1777))
check(door_lines.count(555) <= 2,
      "the Chaos gate is redrawn at most once when a second door changes its margin")
lua.execute("__boxes = {}; CreateDoorRewardPreview(__d)")
check(len(G["__boxes"]) == 0,
      "a refresh that changes nothing draws nothing (no flicker)")

# Infernal Gates are spawned even when the run has too little Heat. They may
# still show their score, but an option the player cannot enter must never get
# the best-pick marker.
lua.execute("""
__boxes = {}
__heat = 0
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
CurrentRun.CurrentRoom = {}
__infernal = { ObjectId = 778, DoorIconId = 1778, ShrinePointReq = 5,
    Room = { ChosenRewardType = "Boon", ForceLootName = "ZeusUpgrade" } }
__gold = { ObjectId = 779, DoorIconId = 1779,
    Room = { ChosenRewardType = "Money" } }
BoonAdvisor.RegisterDoor(__infernal)
BoonAdvisor.RegisterDoor(__gold)
__scoreDoorCalls = 0
__oldScoreDoorCandidate = BoonAdvisor.ScoreDoorCandidate
function BoonAdvisor.ScoreDoorCandidate(exitDoor)
    __scoreDoorCalls = __scoreDoorCalls + 1
    return __oldScoreDoorCandidate(exitDoor)
end
BoonAdvisor.RefreshDoorOverlays()
BoonAdvisor.ScoreDoorCandidate = __oldScoreDoorCandidate
""")
door_lines = [(G["__boxes"][i]["Id"], G["__boxes"][i]["LuaValue"]["BALine"])
              for i in range(1, len(G["__boxes"]) + 1)]
check(not any(line.startswith("*") for oid, line in door_lines if oid == 1778),
      "an unusable Infernal Gate is excluded from the best-pick marker")
check((1778, "requires 5 heat") in door_lines,
      "an unusable Infernal Gate explains its Heat requirement")
check(len([line for _, line in door_lines if line.startswith("*")]) == 1,
      "the best usable exit is still marked")
check(lua.eval("__scoreDoorCalls") == 2,
      "a door refresh scores each visible exit once (got %d calls)" %
      lua.eval("__scoreDoorCalls"))

lua.execute("""
__boxes = {}
__heat = 5
BoonAdvisor.RefreshDoorOverlays()
""")
eligible_lines = [G["__boxes"][i]["LuaValue"]["BALine"]
                  for i in range(1, len(G["__boxes"]) + 1)]
check("requires 5 heat" not in eligible_lines,
      "an eligible Infernal Gate is scored normally")

lua.execute("""
__boxes = {}
CurrentRun.Hero.Health = 20
BoonAdvisor.DoorCandidates = {}
__chaosBlocked = { ObjectId = 780, HealthCost = 20, HideRewardPreview = true,
    Room = { ChosenRewardType = nil } }
BoonAdvisor.RegisterDoor(__chaosBlocked)
BoonAdvisor.RegisterDoor(__gold)
BoonAdvisor.RefreshDoorOverlays()
""")
blocked_chaos_lines = [(G["__boxes"][i]["Id"], G["__boxes"][i]["LuaValue"]["BALine"])
                       for i in range(1, len(G["__boxes"]) + 1)]
check(not any(line.startswith("*") for oid, line in blocked_chaos_lines if oid == 780),
      "a lethal Chaos Gate is excluded from the best-pick marker")
check((780, "needs more than 20 health") in blocked_chaos_lines,
      "a lethal Chaos Gate explains why it is unavailable")
lua.execute("CurrentRun.Hero.Health = 100")

###########################################################################
print("\n=== boon screen overlay ===")
build()
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "AthenaRushTrait",    Rarity = "Common", Type = "Trait" },
    { ItemName = "PoseidonShoutTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ZeusWeaponTrait",    Rarity = "Rare",   Type = "Trait" },
}}, false)
""")
bx = G["__boxes"]
lines = [(bx[i]["Id"], bx[i]["LuaValue"]["BALine"]) for i in range(1, len(bx) + 1)]
for oid, t in lines:
    print("   id=%s  %s" % (oid, t))
check(G["__vanilla"]["boon"] >= 1, "the boon hook calls through to vanilla")
check(len(lines) == 6, "a badge and a reason per option (got %d)" % len(lines))
check(sorted(set(o for o, _ in lines)) == [101, 102, 103], "lines hit the 3 buttons")
starred = [t for _, t in lines if t.startswith("*")]
check(len(starred) == 1, "exactly one best pick marked (got %d)" % len(starred))

# Replacement offers must clear the vanilla "Will Replace" row.
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "ZeusSecondaryTrait", Rarity = "Epic", Type = "Trait",
      TraitToReplace = "ArtemisSecondaryTrait", OldRarity = "Rare" } }}, false)
""")
ex = G["__boxes"]
ys = [ex[i]["OffsetY"] for i in range(1, len(ex) + 1)]
check(max(ys) >= 90, "on a replacement offer the reason clears the exchange row %s" % ys)

###########################################################################
print("\n=== story-room choices ===")
storyscore = lua.eval("BoonAdvisor.ScoreStoryChoice")
lua.execute("""
function IsGodTrait(name, args)
    local data = TraitData[name]
    if data == nil or data.God == nil then return false end
    if data.God == "Hermes" then return args ~= nil and args.ForShop == true end
    return true
end
TraitData.MoveSpeedTrait.God = "Hermes"
CurrentRun.Hero.Traits = { {
    Name = "MoveSpeedTrait",
    Rarity = "Common",
    RarityLevels = TraitData.MoveSpeedTrait.RarityLevels,
} }
""")
hermes_rarity = storyscore("ChoiceText_BuffSlottedBoonRarity")
check("1 of 1 eligible" in hermes_rarity["Reason"],
      "Ambrosia Delight includes Hermes exactly as AddRarityToTraits does "
      f"({hermes_rarity['Reason']!r})")
lua.execute("""
CurrentRun.Hero.MaxLastStands = 3
CurrentRun.Hero.LastStands = { {}, {}, {} }
""")
full_defiance = storyscore("ChoiceText_BuffExtraChance")
lua.execute("CurrentRun.Hero.LastStands = { {} }")
missing_defiance = storyscore("ChoiceText_BuffExtraChance")
check(missing_defiance["Score"] > full_defiance["Score"],
      "Kiss of Styx rises when Death Defiances are missing (%d -> %d)"
      % (full_defiance["Score"], missing_defiance["Score"]))
check("Restores 2 Death Defiances" == missing_defiance["Reason"],
      "the explanation reports the exact number restored")

build("ShieldLoadAmmoTrait")
lua.execute("__meta = 'ExtraChanceMetaUpgrade'; __boxes = {}")
lua.eval("BoonAdvisor.DrawStoryChoiceOverlay")(777, "ChoiceText_BuffExtraChance")
story_boxes = G["__boxes"]
story_lines = [story_boxes[i]["LuaValue"]["BALine"]
               for i in range(1, len(story_boxes) + 1)]
check(len(story_boxes) == 3,
      "the first story option draws one column label, grade, and reason")
check("BUILD FIT" in story_lines,
      "the story rating column has a neutral BUILD FIT header")
reason_box = story_boxes[len(story_boxes)]
reason_color = reason_box["Color"]
check([reason_color[i] for i in range(1, 5)] == [102, 37, 22, 255],
      "supporting text uses the vanilla parchment ink colour")
check(reason_box["VerticalJustification"] == "Top"
      and reason_box["FontSize"] <= 13 and reason_box["Width"] <= 300,
      "story reasons stay on a compact baseline below the option name")

build()
lua.execute("__boxes = {}")
lua.eval("BoonAdvisor.DrawStoryChoiceOverlay")(777, "ChoiceText_BuffWeapon")
later_story_boxes = G["__boxes"]
later_story_lines = [later_story_boxes[i]["LuaValue"]["BALine"]
                     for i in range(1, len(later_story_boxes) + 1)]
check(len(later_story_boxes) == 2 and "BUILD FIT" not in later_story_lines,
      "the BUILD FIT header is not repeated over every story option")
check(later_story_boxes[len(later_story_boxes)]["LuaValue"]["BALine"]
      == "+60% weapon damage, 10 encounters",
      "the longest Patroclus reason fits the right-side column")
lua.execute("__meta = nil; CurrentRun.Hero.MaxLastStands = nil; CurrentRun.Hero.LastStands = nil")

###########################################################################
print("\n=== charon's shop ===")
build("ZeusWeaponTrait", "DemeterRangedTrait")
score_shop_item = lua.eval("BoonAdvisor.ScoreShopItem")
lua.execute("__metalevels = 4; CurrentRun.Hero.Health = 1")
zero_shop_heal = score_shop_item(lua.table(
    Name="RoomRewardHealDrop", Type="Consumable"))
zero_well_heal = score_shop_item(lua.table(
    Name="TemporaryDoorHealTrait", Type="Trait"))
check(int(finalize(zero_shop_heal[0])) == 1 and "0 health" in zero_shop_heal[1],
      "a shop heal that restores zero is the minimum D 1")
check(int(finalize(zero_well_heal[0])) == 1,
      "healing-only Well effects also fall to D 1 at rank four")
zero_nourished = boon("HealingPotencyDrop", typ="Consumable")
zero_after_party = boon("DoorHealTrait")
check(zero_nourished["Score"] == 1 and zero_after_party["Score"] == 1,
      "healing-only boon choices fall to D 1 at rank four")
zero_sisyphus = lua.eval("BoonAdvisor.ScoreStoryChoice")("ChoiceText_Healing")
zero_hydralite = lua.eval("BoonAdvisor.ScoreStoryChoice")("ChoiceText_BuffHealing")
check(zero_sisyphus["Score"] == 1 and zero_hydralite["Score"] == 1,
      "Sisyphus healing and Hydralite fall to D 1 at rank four")
check(int(finalize(score_shop_item(lua.table(
          Name="LastStandDrop", Type="Consumable"))[0])) > 1
      and boon("FountainDamageBonusTrait")["Score"] > 1,
      "revivals and Strong Drink keep their non-healing value")
lua.execute("__metalevels = 0; CurrentRun.Hero.Health = 75")
lua.execute("""
__boxes = {}
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
CurrentRun.Money = 163
__stock = {
    { Cost = 150, Data = { Name = "RandomLoot", Type = "Boon",
        Args = { ForceLootName = "AphroditeUpgrade" } } },
    { Cost = 150, Data = { Name = "RandomLoot", Type = "Boon",
        Args = { ForceLootName = "HermesUpgrade" } } },
    { Cost = 50,  Data = { Name = "RoomRewardHealDrop", Type = "Consumable" } },
    { Cost = 1200, Data = { Name = "SuperGiftDrop", Type = "Consumable" } },
}
SpawnStoreItemsInWorld()
""")
sb = G["__boxes"]
srows = [(sb[i]["Id"], sb[i]["LuaValue"]["BALine"]) for i in range(1, len(sb) + 1)]
for oid, t in srows:
    print("   id=%s  %s" % (oid, t))
check(not any("item" == t or "consumable" == t for _, t in srows),
      "no generic placeholder labels")
check(any(t.startswith("*") for _, t in srows), "the best affordable buy is marked")
check(any("more gold" in t for _, t in srows), "unaffordable stock says what it needs")

lua.execute("""
__boxes = {}
HandleUpgradeChoiceSelection({}, { Data = { Name = "AphroditeWeaponTrait" } })
""")
sb = G["__boxes"]
redrawn = [(sb[i]["Id"], sb[i]["LuaValue"]["BALine"]) for i in range(1, len(sb) + 1)]
for oid, t in redrawn:
    print("   redrawn id=%s  %s" % (oid, t))
check(any(oid == 901 for oid, _ in redrawn) and 0 < len(redrawn) < 8,
      "remaining shop stock is rescored after a purchased boon is applied, "
      "and only the badges that changed are redrawn (%d lines)" % len(redrawn))

lua.execute("""
__boxes = {}
CurrentRun.CurrentRoom = {}
HandleUpgradeChoiceSelection({}, { Data = { Name = "ZeusSecondaryTrait" } })
""")
check(len(G["__boxes"]) == 0,
      "shop overlays cannot redraw from stale state in a later room")

###########################################################################
print("\n=== recommendation objectives and documented build benchmarks ===")
config = G["BoonAdvisor"]["Config"]

build()
config["Objective"] = "Balanced"
balanced_speed_trait = boon("MoveSpeedTrait")["RawScore"]
balanced_survival_trait = boon("AthenaRushTrait")["RawScore"]
balanced_story = door(None)[0]
balanced_health = door("Health")[0]
balanced_gate = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=30))[0]
balanced_plume = lua.eval("BoonAdvisor.ScoreKeepsake")(
    "FastClearDodgeBonusTrait")[0]
balanced_tooth = lua.eval("BoonAdvisor.ScoreKeepsake")(
    "ReincarnationTrait")[0]
balanced_weapon_story = lua.eval("BoonAdvisor.ScoreStoryChoice")(
    "ChoiceText_BuffWeapon")["RawScore"]

config["Objective"] = "Speed"
speed_trait = boon("MoveSpeedTrait")["RawScore"]
speed_story = door(None)[0]
speed_gate = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=30))[0]
speed_plume = lua.eval("BoonAdvisor.ScoreKeepsake")(
    "FastClearDodgeBonusTrait")[0]
speed_weapon_story = lua.eval("BoonAdvisor.ScoreStoryChoice")(
    "ChoiceText_BuffWeapon")["RawScore"]

config["Objective"] = "HighHeat"
high_heat_survival_trait = boon("AthenaRushTrait")["RawScore"]
high_heat_health = door("Health")[0]
high_heat_gate = lua.eval("BoonAdvisor.ScoreChaosGate")(lua.table(HealthCost=30))[0]
high_heat_tooth = lua.eval("BoonAdvisor.ScoreKeepsake")(
    "ReincarnationTrait")[0]

check(speed_trait > balanced_speed_trait,
      "Speed gives an explicit boost to speed traits")
check(speed_story > balanced_story,
      "Speed values combat-free story chambers more highly")
check(speed_plume > balanced_plume and speed_weapon_story > balanced_weapon_story,
      "Speed also affects keepsake and story-room decisions")
check(speed_gate > balanced_gate > high_heat_gate,
      "risk pricing changes in the intended direction for Speed and HighHeat")
check(high_heat_survival_trait > balanced_survival_trait,
      "HighHeat gives an explicit boost to defensive boons")
check(high_heat_health > balanced_health,
      "HighHeat values permanent max health more highly")
check(high_heat_tooth > balanced_tooth,
      "HighHeat increases the value of defensive keepsakes")

config["Objective"] = "not-a-profile"
check(lua.eval("BoonAdvisor.ActiveObjectiveName")() == "Balanced",
      "an invalid objective safely falls back to Balanced")
config["Objective"] = "Balanced"

benchmark_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "build_benchmarks.json")
with io.open(benchmark_path, encoding="utf-8") as benchmark_file:
    benchmarks = json.load(benchmark_file)

benchmark_names = []
benchmark_failures = []
for route in benchmarks["routes"]:
    names_to_check = [route["aspect"]]
    for field in ("required", "required_any", "support_any", "hammers"):
        names_to_check.extend(route.get(field, []))
    if route.get("payoff"):
        names_to_check.append(route["payoff"])
    missing = [name for name in names_to_check if traitdata[name] is None]
    if missing:
        benchmark_failures.append("%s missing %s" % (route["id"], missing))
        continue

    config["Objective"] = route["objective"]
    starting = [route["aspect"]]
    route_candidates = route.get("required", []) + route.get("required_any", [])
    build(*starting)
    route_scores = [boon(name)["Score"] for name in route_candidates]
    if route_scores and max(route_scores) <= boon("ChamberGoldTrait")["Score"]:
        benchmark_failures.append("%s does not beat filler" % route["id"])

    held = starting + route.get("required", []) + route.get("support_any", [])
    if route.get("required_any"):
        held.append(route["required_any"][0])
    build(*held)
    if route.get("payoff"):
        payoff_result = boon(route["payoff"])
        if "completes" not in payoff_result["Reason"] and payoff_result["Score"] < 80:
            benchmark_failures.append("%s payoff is not recognized" % route["id"])

    for hammer_name in route.get("hammers", []):
        hammer_score = hammer(hammer_name)[0]
        if hammer_score < 65:
            benchmark_failures.append("%s hammer %s scores %d" %
                                      (route["id"], hammer_name, hammer_score))
    benchmark_names.append(route["id"])

config["Objective"] = "Balanced"
build()
check(not benchmark_failures,
      "%d documented routes contain real, positively steered game choices%s" %
      (len(benchmark_names), "" if not benchmark_failures
       else " -- " + "; ".join(benchmark_failures)))

build("BowLoadAmmoTrait")
config["Objective"] = "Balanced"
hera_balanced = boon("AphroditeRangedTrait")["RawScore"]
config["Objective"] = "Speed"
hera_speed = boon("AphroditeRangedTrait")["RawScore"]
check(hera_speed > hera_balanced,
      "Speed strengthens the documented Hera Crush Shot route")

build("SpearTeleportTrait")
flurry_jab = hammer("SpearAutoAttack")[0]
triple_jab = hammer("SpearAttackPhalanxTrait")[0]
check(flurry_jab > triple_jab,
      "Achilles correctly prefers Flurry Jab over Triple Jab")
config["Objective"] = "Balanced"
build()

###########################################################################
print("\n=== save safety ===")
lua.execute("""
function __nested(t, trace, d, seen)
    if d > 8 or type(t) ~= "table" then return nil end
    seen = seen or {}; if seen[t] then return nil end; seen[t] = true
    for k, v in pairs(t) do
        local ty, where = type(v), trace .. "." .. tostring(k)
        if ty == "function" or ty == "userdata" or ty == "thread" then return where end
        if ty == "table" then local f = __nested(v, where, d+1, seen)
            if f then return f end end
    end
    return nil
end
function __unsaveable()
    local bad = {}
    for k, v in pairs(_G) do
        if v ~= nil and not SaveIgnores[k] and type(v) == "table" then
            local f = __nested(v, tostring(k), 1)
            if f then table.insert(bad, f) end
        end
    end
    return bad
end
""")
check(G["SaveIgnores"]["BoonAdvisor"] is True, "BoonAdvisor registers in SaveIgnores")
bad = lua.eval("__unsaveable()")
mine = [bad[i] for i in range(1, len(bad) + 1) if str(bad[i]).startswith("BoonAdvisor")]
check(not mine, "no BoonAdvisor global would break Save()%s" % ("" if not mine else " %s" % mine))
lua.execute("__canary = { a = { fn = function() end } }")
b2 = lua.eval("__unsaveable()")
caught = any(str(b2[i]).startswith("__canary") for i in range(1, len(b2) + 1))
lua.execute("__canary = nil")
check(caught, "the save check actually detects a nested function")

###########################################################################
print("\n=== v1.14: build progress, scarcity, cadence, boss preparation ===")
lua.execute("CurrentRun.CurrentRoom = {}; CurrentRun.BiomeDepthCache = nil; CurrentRun.Money = 500")
lua.execute("CurrentRun.Hero.Health = 100; CurrentRun.Hero.MaxHealth = 100")

# D2: on Chiron with Curse of Pain and Divine Dash, Merciful End on the Ares
# screen used to lose to Heartbreak Strike because the Hangover route paid
# its full core bonus from the aspect alone.
build("BowMarkHomingTrait", "AresSecondaryTrait", "AthenaRushTrait")
merciful = score(lua.table(ItemName="TriggerCurseTrait", Rarity="Legendary", Type="Trait"),
                 lua.table(Name="AresUpgrade"))
heartbreak = score(lua.table(ItemName="AphroditeWeaponTrait", Rarity="Common", Type="Trait"),
                   lua.table(Name="AphroditeUpgrade"))
check(merciful["Unclamped"] > heartbreak["Unclamped"] + 8,
      "a duo the run built toward outranks a plain core boon on Chiron (%.1f vs %.1f)"
      % (merciful["Unclamped"], heartbreak["Unclamped"]))
check(merciful["Terms"]["scarcity"] == 12 and heartbreak["Terms"]["scarcity"] is None,
      "duo and legendary offers carry the scarcity credit, ordinary boons do not")
archetype_bonus = lua.eval("BoonAdvisor.ArchetypeBonus")
build("BowMarkHomingTrait")
uncommitted = archetype_bonus("AphroditeWeaponTrait")[0]
build("BowMarkHomingTrait", "DionysusSecondaryTrait")
committed = archetype_bonus("AphroditeWeaponTrait")[0]
check(0 < uncommitted < committed,
      "an aspect route pays its full core bonus only once a core boon is held (%.1f -> %.1f)"
      % (uncommitted, committed))

# D3: a utility duo keeps little of the completion bonus.
linked_scale = lua.eval("BoonAdvisor.LinkedValueScale")
check(linked_scale("AmmoBoltTrait") <= 0.3 and linked_scale("TriggerCurseTrait") >= 1.0,
      "Lightning Rod keeps %.2f of the completion bonus, Merciful End %.2f"
      % (linked_scale("AmmoBoltTrait"), linked_scale("TriggerCurseTrait")))

# D4: the Zagreus fists opener no longer outvotes the hit class.
build("FistBaseUpgradeTrait")
fists = {name: boon(name) for name in
         ("ZeusWeaponTrait", "DemeterWeaponTrait", "AphroditeWeaponTrait")}
check(all((r["Terms"]["archetype"] or 0) < 6 for r in fists.values())
      and fists["ZeusWeaponTrait"]["Terms"]["hit"] == 10
      and fists["ZeusWeaponTrait"]["Score"] > fists["AphroditeWeaponTrait"]["Score"] - 2,
      "the fists opener steers lightly and cadence carries Lightning Strike (%s)"
      % {k[:-11]: v["Score"] for k, v in fists.items()})

# E1: hammers that change a move's cadence change its hit class.
build("SpearBaseUpgradeTrait")
plain_spear = boon("ZeusWeaponTrait")["Terms"]["hit"] or 0
build("SpearBaseUpgradeTrait", "SpearAutoAttack")
flurry_spear = boon("ZeusWeaponTrait")["Terms"]["hit"] or 0
check(plain_spear == 0 and flurry_spear > 0,
      "Flurry Jab turns the spear attack into a fast slot for Lightning Strike (%d -> %d)"
      % (plain_spear, flurry_spear))
build("GunBaseUpgradeTrait", "GunShotgunTrait")
check((boon("AphroditeWeaponTrait")["Terms"]["hit"] or 0) > 0,
      "Spread Fire makes the rail attack a slow slot that suits Heartbreak Strike")
hammer_classes = list(lua.eval("BoonAdvisor.Ratings.HammerHitClass").keys())
check(all(traitdata[name] is not None for name in hammer_classes),
      "every hammer in HammerHitClass is a real trait (%d)" % len(hammer_classes))

# E5: the boss is close, so survival is worth more.
build()
lua.execute("CurrentRun.CurrentRoom = { RoomSetName = 'Elysium' }; CurrentRun.BiomeDepthCache = 8")
near_boss = boon("AthenaRushTrait")["Terms"]["boss"] or 0
near_max_health = score(lua.table(ItemName="ChaosBlessingMaxHealthTrait",
                                  SecondaryItemName="ChaosCurseNoMoneyTrait",
                                  Type="TransformingTrait", Rarity="Common"),
                        lua.table(Name="TrialUpgrade"))["RawScore"]
near_money = score(lua.table(ItemName="ChaosBlessingMoneyTrait",
                             SecondaryItemName="ChaosCurseNoMoneyTrait",
                             Type="TransformingTrait", Rarity="Common"),
                   lua.table(Name="TrialUpgrade"))["RawScore"]
lua.execute("CurrentRun.BiomeDepthCache = 2")
far_boss = boon("AthenaRushTrait")["Terms"]["boss"] or 0
far_max_health = score(lua.table(ItemName="ChaosBlessingMaxHealthTrait",
                                 SecondaryItemName="ChaosCurseNoMoneyTrait",
                                 Type="TransformingTrait", Rarity="Common"),
                       lua.table(Name="TrialUpgrade"))["RawScore"]
far_money = score(lua.table(ItemName="ChaosBlessingMoneyTrait",
                            SecondaryItemName="ChaosCurseNoMoneyTrait",
                            Type="TransformingTrait", Rarity="Common"),
                  lua.table(Name="TrialUpgrade"))["RawScore"]
check(near_boss > 0 and far_boss == 0,
      "survival boons gain value in the rooms before the boss (+%.1f near, +%.1f far)"
      % (near_boss, far_boss))
check((near_max_health - far_max_health) > (near_money - far_money),
      "a survival Chaos blessing gains more than a gold blessing as the boss nears")
lua.execute("CurrentRun.CurrentRoom = {}; CurrentRun.BiomeDepthCache = nil")

# E4: the Trial charges for the god you refuse.
build("AphroditeWeaponTrait")
trial_room = lua.table(ChosenRewardType="Devotion",
                       Encounter=lua.table(LootAName="AresUpgrade", LootBName="AthenaUpgrade"))
spurned_costed = scoredoor(trial_room)[0]
spurned_table = G["BoonAdvisor"]["Config"]["Doors"]["TrialSpurnedRisk"]
G["BoonAdvisor"]["Config"]["Doors"]["TrialSpurnedRisk"] = lua.table()
spurned_free = scoredoor(trial_room)[0]
G["BoonAdvisor"]["Config"]["Doors"]["TrialSpurnedRisk"] = spurned_table
check(spurned_costed < spurned_free,
      "a Trial pays for the powers the refused god gives the enemies (%.1f vs %.1f)"
      % (spurned_costed, spurned_free))

# E3: "none of these" when a new god's screen is weak and the pool is full.
build("ZeusWeaponTrait", "AresSecondaryTrait", "ArtemisRushTrait")
offer_verdict = lua.eval("BoonAdvisor.OfferVerdict")
check(offer_verdict(lua.table(Name="DemeterUpgrade"), lua.table(Score=50)) == "skip"
      and offer_verdict(lua.table(Name="DemeterUpgrade"), lua.table(Score=80)) is None
      and offer_verdict(lua.table(Name="ZeusUpgrade"), lua.table(Score=50)) is None
      and offer_verdict(lua.table(Name="StackUpgrade"), lua.table(Score=50)) is None,
      "a weak screen from a new god on a full pool gets the 'none of these' verdict")
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "DemeterUpgrade", UpgradeOptions = {
    { ItemName = "TrapDamageTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ChamberGoldTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
verdict_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(any(t.startswith("none of these") for t in verdict_lines),
      "the star's reason says walking away is fine (%r)" % verdict_lines)
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "TrapDamageTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ChamberGoldTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
verdict_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(not any(t.startswith("none of these") for t in verdict_lines),
      "a god already in the build never gets the verdict, however weak the screen")

# C2: the starred badge shows the margin over the runner-up.
build()
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "AthenaRushTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ZeusWeaponTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
badge_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
starred = [t for t in badge_lines if t.startswith("*")]
check(len(starred) == 1 and re.match(r"^\* [SABCD]  \d+  \+\d+$", starred[0]) is not None,
      "the starred badge carries the margin over the runner-up (%r)" % starred)
G["BoonAdvisor"]["Config"]["ShowBestMargin"] = False
lua.execute("""
__boxes = {}
CreateBoonLootButtons({ Name = "ZeusUpgrade", UpgradeOptions = {
    { ItemName = "AthenaRushTrait", Rarity = "Common", Type = "Trait" },
    { ItemName = "ZeusWeaponTrait", Rarity = "Common", Type = "Trait" } }}, false)
""")
plain_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(not any("+" in t for t in plain_lines if t.startswith("*")),
      "ShowBestMargin = false hides the margin")
G["BoonAdvisor"]["Config"]["ShowBestMargin"] = True

# H5: sessions are stamped with a fingerprint of the tuning.
fingerprint = lua.eval("BoonAdvisor.ConfigFingerprint")
first = fingerprint()
lua.execute("BoonAdvisor.ConfigFingerprintCache = nil; BoonAdvisor.Config.Weights.EmptySlot = 9")
second = fingerprint()
lua.execute("BoonAdvisor.ConfigFingerprintCache = nil; BoonAdvisor.Config.Weights.EmptySlot = 8")
check(re.match(r"^[0-9a-f]{8}$", first) is not None and first != second
      and fingerprint() == first,
      "the ratings fingerprint is short, stable, and changes with a weight (%s)" % first)

###########################################################################
print("\n=== v1.14: doors refresh once, advise rerolls, and the Well is rated ===")
# A3: a shower of coins queues one refresh that waits for the last coin.
lua.execute("""
__refreshes = 0
__originalRefresh = BoonAdvisor.RefreshDoorOverlays
BoonAdvisor.RefreshDoorOverlays = function(args) __refreshes = __refreshes + 1 end
__threads = {}
function thread(fn, args) table.insert(__threads, { Fn = fn, Args = args }) end
__waits = 0
function wait(duration)
    __waits = __waits + 1
    -- Two more coins land while the first delay is running.
    if __waits <= 2 then
        BoonAdvisor.DoorRefreshGeneration = BoonAdvisor.DoorRefreshGeneration + 1
    end
end
BoonAdvisor.DoorRefreshQueuedRoom = nil
CurrentRun.CurrentRoom = {}
for _ = 1, 5 do BoonAdvisor.QueueDoorOverlayRefresh() end
""")
check(len(G["__threads"]) == 1, "five coins queue a single refresh coroutine")
lua.execute("__threads[1].Fn(__threads[1].Args)")
check(lua.eval("__refreshes") == 1 and lua.eval("__waits") == 3,
      "the refresh runs once, after the delay in which no further coin landed "
      "(%d refreshes, %d waits)" % (lua.eval("__refreshes"), lua.eval("__waits")))
lua.execute("""
BoonAdvisor.RefreshDoorOverlays = __originalRefresh
thread = nil; wait = nil
""")

# E2: Fated Authority advice when every enterable exit is poor.
lua.execute("""
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
CurrentRun.CurrentRoom = { RoomSetName = "Tartarus" }
CurrentRun.NumRerolls = 1
CurrentRun.Money = 500
__weakGold = { ObjectId = 811, DoorIconId = 1811, CanBeRerolled = true,
    Room = { ChosenRewardType = "Money" } }
__weakGems = { ObjectId = 812, DoorIconId = 1812, CanBeRerolled = true,
    Room = { ChosenRewardType = "Gems" } }
BoonAdvisor.RegisterDoor(__weakGold)
BoonAdvisor.RegisterDoor(__weakGems)
__boxes = {}
BoonAdvisor.RefreshDoorOverlays()
""")
reroll_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(any(t.startswith("*") and t.endswith("reroll?") for t in reroll_lines),
      "two poor exits with a die left get the reroll suffix on the star (%r)" % reroll_lines)
lua.execute("""
__hammer = { ObjectId = 813, DoorIconId = 1813, CanBeRerolled = true,
    Room = { ChosenRewardType = "WeaponUpgrade" } }
BoonAdvisor.RegisterDoor(__hammer)
__boxes = {}
BoonAdvisor.RefreshDoorOverlays()
""")
reroll_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(not any("reroll?" in t for t in reroll_lines),
      "a strong exit removes the reroll advice")
lua.execute("""
CurrentRun.NumRerolls = 0
BoonAdvisor.DoorCandidates = { [811] = __weakGold, [812] = __weakGems }
BoonAdvisor.DoorRegistrationEpoch = (BoonAdvisor.DoorRegistrationEpoch or 0) + 1
BoonAdvisor.LastDoorEvaluations = nil
__boxes = {}
BoonAdvisor.RefreshDoorOverlays()
""")
reroll_lines = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(not any("reroll?" in t for t in reroll_lines),
      "no die left, no reroll advice")
lua.execute("""
BoonAdvisor.DoorCandidateRoom = nil
BoonAdvisor.DoorCandidates = {}
CurrentRun.CurrentRoom = {}
""")

# D1: the Well of Charon is a screen built by CreateStoreButtons.
lua.execute("""
__wellPurchases = 0
function CreateStoreButtons()
    local components = CurrentRun.CurrentRoom.Store.Screen.Components
    for index, data in ipairs(CurrentRun.CurrentRoom.Store.StoreOptions) do
        components["PurchaseButton" .. index] = { Id = 1200 + index, Data = data, Index = index }
    end
end
function HandleStorePurchase(screen, button)
    __wellPurchases = __wellPurchases + 1
    CurrentRun.Money = CurrentRun.Money - button.Data.Cost
    screen.Components["PurchaseButton" .. button.Index] = nil
end
BoonAdvisor.Installed = nil
""")
load(os.path.join(MOD, "BoonAdvisor.lua"))
load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "oracle.lua"))
G["BoonAdvisor"]["Config"]["DoorOfferSimulationSamples"] = 0
lua.execute("function CreateTextBox(a) table.insert(__boxes, a) end")
build("ZeusWeaponTrait")
lua.execute("""
__boxes = {}
CurrentRun.Money = 200
CurrentRun.CurrentRoom.Store = { Screen = { Components = {} }, StoreOptions = {
    { Name = "TemporaryImprovedWeaponTrait", Type = "Trait", Cost = 60 },
    { Name = "TemporaryDoorHealTrait", Type = "Trait", Cost = 50 },
    { Name = "KeepsakeChargeDrop", Type = "Consumable", Cost = 20 },
} }
CreateStoreButtons()
""")
wb = G["__boxes"]
well_rows = [(wb[i]["Id"], wb[i]["LuaValue"]["BALine"]) for i in range(1, len(wb) + 1)]
for oid, t in well_rows:
    print("   well id=%s  %s" % (oid, t))
well_badges = [t for oid, t in well_rows if re.match(r"^(\* )?[SABCD]  \d+", t)]
check(len(well_badges) == 3 and sorted(oid for oid, _ in well_rows)[0] == 1201,
      "the Well draws one badge per purchase button (%d)" % len(well_badges))
check(sum(1 for t in well_badges if t.startswith("*")) == 1,
      "exactly one Well item is starred")
check(any("Improved" not in t and "unrated" not in t for _, t in well_rows),
      "Well items are rated from Shop.WellItems, not reported as unrated")
lua.execute("""
__boxes = {}
HandleStorePurchase(CurrentRun.CurrentRoom.Store.Screen, CurrentRun.CurrentRoom.Store.Screen.Components.PurchaseButton1)
""")
check(lua.eval("__wellPurchases") == 1
      and G["CurrentRun"]["CurrentRoom"]["Store"]["Screen"]["Components"]["BoonAdvisorWell1"] is None,
      "a purchase calls through to vanilla and drops the sold item's badge")
check(any(G["__boxes"][i]["Id"] in (1202, 1203) for i in range(1, len(G["__boxes"]) + 1)),
      "the remaining Well stock is re-ranked after a purchase")

# H4: Well purchases and purge sales are logged like shop purchases.
_well_logfile = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                              "picklog_well_test.log")
if _os.path.exists(_well_logfile):
    _os.remove(_well_logfile)
lua.execute("BoonAdvisor.Config.LogPicks = true")
lua.execute("BoonAdvisor.Config.LogFilePath = [[%s]]" % _well_logfile.replace("\\", "\\\\"))
lua.execute("""
CurrentRun.Money = 200
CurrentRun.CurrentRoom.Store = { Screen = { Components = {} }, StoreOptions = {
    { Name = "TemporaryImprovedWeaponTrait", Type = "Trait", Cost = 60 },
    { Name = "KeepsakeChargeDrop", Type = "Consumable", Cost = 20 },
} }
CreateStoreButtons()
HandleStorePurchase(CurrentRun.CurrentRoom.Store.Screen, CurrentRun.CurrentRoom.Store.Screen.Components.PurchaseButton2)
ScreenAnchors.SellTraitScreen = { Components = {
    PurchaseButton1 = { Id = 501, UpgradeName = "ZeusWeaponTrait", Value = 60 },
    PurchaseButton2 = { Id = 502, UpgradeName = "ChamberGoldTrait", Value = 60 } } }
SetBuild({ "ZeusWeaponTrait", "ChamberGoldTrait" })
function HandleSellChoiceSelection(screen, button) end
BoonAdvisor.Vanilla_HandleSellChoiceSelection = HandleSellChoiceSelection
BoonAdvisor.LogPurgeChoice(ScreenAnchors.SellTraitScreen, ScreenAnchors.SellTraitScreen.Components.PurchaseButton1)
ScreenAnchors.SellTraitScreen = nil
""")
lua.execute("BoonAdvisor.Config.LogPicks = false; BoonAdvisor.Config.LogFilePath = nil")
well_logged = []
if _os.path.exists(_well_logfile):
    well_logged = [l.strip() for l in io.open(_well_logfile, encoding="utf-8") if l.strip()]
    _os.remove(_well_logfile)
for line in well_logged:
    print("   %s" % line)
check(any(l.startswith("[well ]") and "took=KeepsakeChargeDrop" in l and "margin=" in l
          and ">" in l for l in well_logged),
      "a Well purchase is logged with every option, the star and the margin")
check(any(l.startswith("[purge]") and "took=ZeusWeaponTrait" in l and "*" in l
          for l in well_logged),
      "a purge sale is logged with every option and the star")
lua.execute("CurrentRun.CurrentRoom = {}; CurrentRun.Money = 500")

# C4: in a non-English game the keepsake guidance stays off, like the reasons.
lua.execute("""
function GetLanguage(a) return "de" end
function CreateScreenComponent(args) __nextComponent = (__nextComponent or 5000) + 1; return { Id = __nextComponent } end
function Attach(args) end
ScreenAnchors.AwardMenuScreen = { Components = { InfoBackground = { Id = 4000 } } }
__keepsakeButton = { Id = 3001, BoonAdvisorKeepsakeScore = 70, BoonAdvisorKeepsakeRank = "B",
    BoonAdvisorKeepsakeColor = { 1, 1, 1, 1 }, BoonAdvisorKeepsakeTrait = "ShieldBossTrait",
    BoonAdvisorKeepsakeReason = "KEEP: a boss is coming" }
BoonAdvisor.LastKeepsakeEvaluation = nil
__boxes = {}
BoonAdvisor.UpdateKeepsakeDetail(__keepsakeButton)
""")
foreign = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(foreign and not any("KEEP" in t or "SWITCH" in t or "BUILD FIT" in t for t in foreign),
      "a non-English game sees the keepsake grade but no English guidance (%r)" % foreign)
lua.execute("""
function GetLanguage(a) return "en" end
__boxes = {}
BoonAdvisor.UpdateKeepsakeDetail(__keepsakeButton)
""")
english = [G["__boxes"][i]["LuaValue"]["BALine"] for i in range(1, len(G["__boxes"]) + 1)]
check(any("KEEP" in t for t in english), "an English game sees the KEEP / SWITCH guidance")
lua.execute("""
GetLanguage = nil; CreateScreenComponent = nil; Attach = nil
ScreenAnchors.AwardMenuScreen = nil
""")

print()
if FAILURES:
    print("FAILED %d check(s)" % len(FAILURES))
    sys.exit(1)
print("all checks passed")
