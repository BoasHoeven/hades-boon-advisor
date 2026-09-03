# Hades reward mechanics, as implemented in the game's own scripts

Everything below was read out of `Content/Scripts/*.lua` in this install, with
file:line citations so it can be re-checked. Where a claim is community
knowledge rather than something I read in the code, it is marked **[wiki]**.
Where it is a judgement call, it is marked **[opinion]**.

This document exists because several of BoonAdvisor's early scoring rules were
built on assumptions that turned out to be wrong. Those are listed at the end.

---

## 1. One code path feeds many screens

`OpenUpgradeChoiceMenu(lootData)` → `CreateBoonLootButtons(lootData)`
(`UpgradeChoice.lua:2`, `:83`) renders **every** "Choose One" screen:

| Screen | `lootData.Name` |
| --- | --- |
| God boons | `ZeusUpgrade`, `AresUpgrade`, … (9 gods incl. `HermesUpgrade`) |
| Chaos | `TrialUpgrade` |
| Pom of Power | `StackUpgrade` |
| Daedalus Hammer | `WeaponUpgrade` |

There are exactly 12 such entries in `LootData.lua`. Anything hooking this
function sees all of them, so a scorer that only understands god boons will
silently mis-rate hammers, Poms and Chaos.

The number of options is `CalcNumLootChoices() = 3 - ReducedLootChoicesShrineUpgrade`
(`TraitScripts.lua:1538`). Options beyond that count are still built but
**blocked**. `CreateBoonLootButtons` marks the extras via `blockedIndexes`
(`UpgradeChoice.lua:111-117`), which is why a locked option can appear on screen.

## 2. What each offer looks like

`lootData.UpgradeOptions` is a list of
`{ ItemName, Type, Rarity, TraitToReplace, OldRarity }`.

- `Type` is `"Trait"`, `"Consumable"` or `"TransformingTrait"` (Chaos).
- For Chaos, `ItemName` is the **blessing** and `SecondaryItemName` the
  **curse** (`UpgradeChoice.lua:238-240`).
- `TraitToReplace` is set when the offer would overwrite an existing boon.

Options are sorted Attack → Special → Cast → Dash → Call before display
(`UpgradeChoice.lua:120-140`), so option order matches button order.

## 3. Slots

`TraitData[name].Slot` is one of `Melee`, `Secondary`, `Ranged`, `Rush`,
`Shout` internally, and shown to players as **Attack, Special, Cast,
Dash, Call**. The `UpgradeChoiceMenu_<Slot>` keys the vanilla code builds do
not exist in the shipped text, so there is nothing to look up; the mapping has
to be supplied.

**Not every boon has a slot.** Many are slotless additions. Artemis' crit
bonus and Clean Kill, Zeus' Double Strike, all the "upgrade" boons. A god whose
slot boons are all taken can still offer these, so "all slots full" does *not*
mean "you would have to replace something".

## 4. Rarity

`TraitData[name].RarityLevels` holds `Common / Rare / Epic / Heroic` with
`MinMultiplier`/`MaxMultiplier` pairs; the actual roll is
`RandomFloat(min, max)` (`TraitScripts.lua:265`). Duo and legendary boons have
no ordinary rarity levels; they are fixed.

## 5. Duo and legendary prerequisites: the synergy graph

`LootData[<god>].LinkedUpgrades` is the authoritative prerequisite table. Each
entry is either:

- `OneOf = { … }`: hold **any one** of these. Cheap; most god upgrade boons
  use this (e.g. Static Discharge needs any one Zeus boon).
- `OneFromEachSet = { {…}, {…} }`: hold **one from every set**. This is what
  a duo boon looks like, and the sets span different gods.

`GetEligibleTraitUpgrades` (`UpgradeChoice.lua:768`) applies exactly this test.
Reading it at runtime means duo detection needs no hardcoded list and survives
patches. There are ~72 gated boons, of which ~34 are multi-set duos.

Being *eligible* is not the same as being *offered*; eligibility only puts a
boon in the pool.

## 6. Pom of Power

**It does not heal, and it does not let you choose freely.**

From `GetEligibleUpgrades` (`UpgradeChoice.lua:834`):

```lua
if lootData.StackOnly then
    GetAllUpgradeableGodTraits()   -- every non-temporary god boon you hold
```

`GetAllUpgradeableGodTraits` (`TraitScripts.lua:1483`) returns hero traits where
`trait.RemainingUses == nil` (i.e. not temporary) and `IsGodTrait(name)`.
The screen then shows `CalcNumLootChoices()`, normally **3**, drawn from that
pool, and you pick one. **[wiki]** confirms: "pick between three randomly
chosen Boons".

Consequences for valuation: holding one excellent Pom target among many
mediocre ones is worth much less than holding it alone, because it may simply
not be offered. The honest value is the *expected best of k draws*, not the max.

### Stacking curve

`TraitScripts.lua:398-404`:

```lua
totalDiminishingMultiplier = diminishing ^ (i - 1)
totalMultiplier = (1 + IdenticalMultiplier.Value) * totalDiminishingMultiplier
if totalMultiplier < minMultiplier then totalMultiplier = minMultiplier end
```

with `TraitMultiplierData.DefaultDiminishingReturnsMultiplier = 0.7` and
`DefaultMinMultiplier = 0.1` (`TraitData.lua:6-11`).

So each further level is worth **70% of the previous one, floored at 10%**:
geometric decay with a floor, matching **[wiki]** ("the first 2 or 3 have the
greatest effect… the drop off has a floor").

A Pom can grant more than one level: `lootData.StackNum` is incremented by
`GetTotalHeroTraitValue("PomLevelBonus")` (`UpgradeChoice.lua:98`).

### Reroll evaluation

`RerollBoonLoot` (`UpgradeChoice.lua:589`) excludes one randomly selected
option from the current screen, then calls `SetTraitsOnLoot` again. It does not
exclude the entire current offer, so two choices can return.

The advisor pre-indexes the static loot relationships once, asks the game's
eligibility functions for the current legal pool, and evaluates the remaining
branches with deterministic probability math. This includes priority boons,
replacement chance, linked-priority rolls, rarity order, reroll exclusions,
Pom eligibility, and Approval Process.

Chaos is handled separately. Its distinct blessing draws and correlated curse
draws, including the 70% chance to remove a curse from the remaining pool, are
integrated algebraically. No live recommendation calls `SetTraitsOnLoot` or
consumes the run's random stream.

A reroll is recommended only when the exact expected value clears the
configured minimum gain and the probability of improvement is high enough.
Repeated rerolls and spending the final die require a larger gain. Results are
cached by build and run state, then invalidated when the build changes.

## 7. Trial of the Gods (reward type `Devotion`): **two boons**

Full sequence, traced through the code:

Before the exit door is displayed, `SetupRoomReward` (`RunManager.lua:497-511`)
creates the Devotion encounter and stores the two selected gods in
`room.Encounter.LootAName` and `LootBName`. The advisor can therefore forecast
both real god pools while ranking the door. It keeps the stronger expected
offer at full value, credits the second guaranteed boon at a discounted value,
and then subtracts the live health and Death Defiance risk.

**1. Two boons spawn, you take one.** `StartDevotionTest` (`RoomEvents.lua:1669`)
spawns `lootA` and `lootB` from two different gods and waits on the boon menu.

**2. The refused god arms the enemies** for that encounter
(`RoomEvents.lua:1703-1713`):

```lua
currentEncounter.ChosenGodName  = chosenLootName
currentEncounter.SpurnedGodName = alternateLootData.Name
AddEnemyUpgrade( alternateLootData.Name, CurrentRun )
currentEncounter.RemoveUpgradeOnEnd = alternateLootData.Name
```

Sometimes it also adds `SpawnPassiveRoomWeapons`. The buff is removed when the
encounter ends (`RoomManager.lua:2570`).

**3. On clearing, a SECOND boon is granted from the god you refused**
(`RoomEvents.lua:1469`):

```lua
elseif rewardType == "Devotion" then
    reward = GiveLoot({ ForceLootName = currentEncounter.SpurnedGodName,
                        ExchangeOnlyFromLootName = currentEncounter.ChosenGodName, ... })
```

`ExchangeOnlyFromLootName` *looks* like it would restrict that reward to
swapping out the boon you chose. **It does not.** The field is assigned onto the
loot (`RoomManager.lua:2845`) and then **never read anywhere in the scripts**;
verified by a case-insensitive search of `Content/Scripts`. So the end reward is
an ordinary boon offer from the spurned god.

**Net effect: one Trial room yields two boons, one from each of the two gods**,
in exchange for an encounter where the enemies carry the refused god's powers.
They use the normal rarity path, but Duo boons are excluded because
`SynergyTrait.RequiredFalseRewardType` is `Devotion`. Ordinary Legendary boons
remain eligible.
That is double an ordinary boon room, which makes it one of the strongest doors
in the game. The cost is survival risk, not reward.

Availability: requires 2 gods met this run
(`RequiredInteractedGodsThisRun = 2`), depth 5-34, at least 2 exits, not Styx,
and 15 rooms since the last one (`LootData.lua:20953`).

## 7a. Rarity

Ladder (`UpgradeChoice.lua:600`): `Common → Rare → Epic → Heroic → Legendary`.

`GetUpgradedRarity` (`UpgradeChoice.lua:610`) steps Common→Rare, Rare→Epic,
Epic→Heroic. Note there is **no Heroic→Legendary step**; Legendary is not
reachable by upgrading.

Roll chances live in `HeroData.lua:148` under `BoonData`:

| Field | Value |
| --- | --- |
| `RareChance` | 0.10 |
| `EpicChance` | 0.05 |
| `LegendaryChance` | 0.12 |
| `ReplaceChance` | 0.10 |

Hermes boons roll worse (`HermesData`: 0.06 / 0.03 / 0.01), and Poms force
Common with no rarity override (`StackData`: `ForceCommon = true`,
`AllowRarityOverride = false`), which is why a Pom offer never shows a rarity.

`SetTraitsOnLoot` checks Legendary, Heroic, Epic, and Rare in that order and
stops at the first successful roll (`TraitScripts.lua:1680-1693`). The raw
chances are therefore not independent final probabilities. Duo and Legendary
traits also exist only in the Legendary rarity table, so merely being eligible
does not make one as likely as an ordinary boon. Door forecasts evaluate the
same branches directly and calculate the expected best visible choice. This
preserves the game's priority, replacement, rarity, eligibility, and Approval
Process rules without sampling or advancing the run's real random stream. The
copied-generator simulator remains only as a high-sample differential oracle
in the offline test suite.

## 7b. Replacement offers: "another god takes over one of your boons"

This is the mechanic behind an offer that says **"Will Replace: &lt;your boon&gt;"**.

**When it happens.** In `SetTraitsOnLoot` (`TraitScripts.lua:1559`):

```lua
elseif IsGameStateEligible( CurrentRun, CurrentRun.Hero.BoonData.GameStateRequirements)
       and RandomChance( CurrentRun.Hero.BoonData.ReplaceChance )
       and not lootData.ForceCommon then
    upgradeOptions = GetReplacementTraits( lootData.PriorityUpgrades )
end
```

- `ReplaceChance` = **0.10** (`HeroData.lua:157`), a 10% roll per boon loot.
- Gated on `BoonData.GameStateRequirements`, which needs
  `RequiredMinCompletedRuns = 2`, so it does not appear in your first runs.
- `not lootData.ForceCommon` excludes Poms (`StackData.ForceCommon = true`).

**What it builds.** `GetReplacementTraits` (`UpgradeChoice.lua:667`):

1. Walks your traits and records, per slot, the occupying boon **and the
   highest rarity in that slot**.
2. Keeps candidates from this god that are eligible, not already held, whose
   slot you have filled, and where `GetUpgradedRarity(that slot's rarity)` is
   not nil.
3. Returns **one** of them at random:

```lua
{ ItemName = traitName, Type = "Trait",
  TraitToReplace = occupiedSlots[slot].TraitName,
  OldRarity      = occupiedSlots[slot].Rarity,
  Rarity         = GetUpgradedRarity(occupiedSlots[slot].Rarity) }
```

**Key consequences**

- The new boon arrives **exactly one rarity tier above** the one it displaces.
  Replace a Rare and you are handed an Epic.
- Because `GetUpgradedRarity` has no entry above Heroic, a **Heroic boon can
  never be replaced** this way; that slot is safe.
- It occupies **one of the three options**, not the whole screen: the remaining
  slots are filled normally by `GetEligibleUpgrades` (`TraitScripts.lua:1598`).
- It is only ever offered for a slot you have **already filled**; it cannot
  take an empty slot.

**How it should be valued [opinion, derived from the above]:** the offer is a
*swap*, so its worth is a difference: (new boon at its granted rarity) minus
(old boon at its current rarity), not the new boon minus a flat penalty. A
free rarity tier often makes the swap worthwhile even when the incoming boon is
slightly weaker in the abstract; conversely, handing away an excellent boon for
a mediocre one is bad regardless of the tier bump.

## 8. Chaos gate

The Chaos gate is **not an exit door**; it is a `SecretDoor` obstacle
(`ObstacleData.lua:2366`) spawned in its own branch (`RoomManager.lua:5597-5612`),
which calls `AssignRoomToExitDoor` and nothing else.

`CreateDoorRewardPreview` is only called in a loop over the normal exit doors
(`RoomManager.lua:4930`), so **the gate never passes through it**. `SecretDoor`
also sets `HideRewardPreview = true`, meaning even if the preview did run it
would return before creating `DoorIconId`.

Its cost is health: `secretDoor.HealthCost = GetSecretDoorCost()`, based on
`SecretDoorCostBase` (20) and `SecretDoorCostDepthScalar` (0.2) from
`HeroData.lua:74`.

## 9. Charon's shop

- `SpawnStoreItemsInWorld()` (`StoreScripts.lua:396`) builds the stock, then
  calls `SpawnStoreItemInWorld(itemData, kitId)` per item.
- The singular function keeps its item in a **local and returns nothing**; the
  spawned id is appended to `CurrentRun.CurrentRoom.Store.SpawnedStoreItems`
  as its last act (`StoreScripts.lua:455`).
- **A shop boon carries its god in `itemData.Args.ForceLootName`, not
  `Args.Name`** (`StoreScripts.lua:140`), and its `Name` is the generic
  `"RandomLoot"`. Reading the wrong field makes every shop boon look like an
  unidentifiable item.
- Real stock names are enumerable from `StoreData.lua`: `WeaponUpgradeDrop`,
  `HermesUpgradeDrop`, `StackUpgradeDrop`, `RoomRewardHealDrop`,
  `RoomRewardMaxHealthDrop`, `StoreRewardMetaPointDrop`, `StoreRewardLockKeyDrop`,
  `StoreRewardGemDrop`, `GiftDrop`, `BlindBoxLoot`, `RandomLoot`,
  `StoreTrialUpgradeDrop`, `ChaosWeaponUpgrade`, `StoreRewardConsolationDrop`,
  `StoreRewardRandomStack`.
- `SuperGiftDrop` (Ambrosia) costs 1100 base (`ConsumableData.lua:287`) and does
  nothing for the run in progress; it is House gifting currency.

## 9a. The damage formula: the most important rule in the game

`Combat.lua:394-675`. Two accumulators are built and multiplied at the end:

```lua
local damageReductionMultipliers = 1
local damageMultipliers = 1.0
...
local addDamageMultiplier = function( data, multiplier )
    if multiplier >= 1.0 then
        if data.Multiplicative then
            damageReductionMultipliers = damageReductionMultipliers * multiplier
        else
            damageMultipliers = damageMultipliers + multiplier - 1     -- ADDITIVE
        end
    else
        if data.Additive then
            damageMultipliers = damageMultipliers + multiplier - 1
        else
            damageReductionMultipliers = damageReductionMultipliers * multiplier  -- MULTIPLICATIVE
        end
    end
end
...
return damageMultipliers * damageReductionMultipliers
```

So:

> **final = (1 + Σ(buff − 1)) × Π(reductions)**

- **Damage buffs (≥ 1.0) are ADDITIVE by default.** Only those explicitly
  flagged `Multiplicative` multiply. Ten +10% buffs give +100%, not ×2.59.
- **Damage reductions (< 1.0) are MULTIPLICATIVE by default.** Only those
  flagged `Additive` add.

Consequences worth building around **[opinion, derived from the above]**:

- Stacking many small "+x% damage" sources has *linearly* diminishing relative
  value. The tenth one adds the same absolute amount as the first, on a bigger
  base, so its *proportional* contribution shrinks.
- Sources flagged `Multiplicative` are disproportionately strong because they
  multiply the whole additive pile.
- Defensive layers **stack multiplicatively**, which is why several modest
  reductions (Weak, armour-type effects, dodge) compound into very large
  survivability, and why Aphrodite's Weak is rated so highly by every guide.

Set `ConfigOptionCache.LogCombatMultipliers` to have the game print each
multiplier and its name as it is applied (`Combat.lua:398`, `:673`); this is the
authoritative way to check any specific interaction.

## 9b. Wall slams, and how they scale with the biome

When the attacker is an obstacle (i.e. a foe was knocked into terrain), damage
is scaled by a **per-biome** multiplier (`Combat.lua:860`):

```lua
if triggerArgs.AttackerIsObstacle and CurrentRun.CurrentRoom.WallSlamMultiplier then
    triggerArgs.DamageAmount = triggerArgs.DamageAmount * CurrentRun.CurrentRoom.WallSlamMultiplier
end
```

| Biome | `WallSlamMultiplier` | Source |
| --- | --- | --- |
| Tartarus | *(none; 1.0)* | no entry in `RoomDataTartarus.lua` |
| Asphodel | **1.5** | `RoomDataAsphodel.lua:93` |
| Elysium | **2.0** | `RoomDataElysium.lua:71` |
| Styx | **2.5** | `RoomDataStyx.lua:89` |

So knockback builds get **stronger the deeper you go**. A wall slam in Styx
does 2.5× what the same slam does in Tartarus. This is a concrete,
code-verified reason to value Poseidon knockback more highly later in a run.

Separately, `CheckWallSlamPowers` (`Powers.lua:55`) fires every weapon in
`CurrentRun.Hero.OnSlamWeapons` when a slam lands. Poseidon's **Breaking Wave**
(`SlamExplosionTrait`) and `SlamStunTrait` add `PoseidonCollisionBlast` there
(`TraitData.lua:4894`, `:4939`), which is extra damage *on top of* the scaled
slam damage.

Note the guard: the slam-power hook ignores damage whose source is an enemy or
an effect, so it only triggers on genuine collision damage.

## 9c. Critical hits

Crit magnitude is **engine-side, not in Lua**. The scripts only ever set it via
the weapon method `SetCritBonus` (`Powers.lua:930-993`), passing an amount and a
crit bonus; the multiplier itself lives in the native weapon data. So the exact
crit multiplier cannot be quoted from these scripts; treat any specific figure
as **[wiki]** rather than verified here.

What *is* visible in Lua:

- `triggerArgs.IsCrit` marks a hit as critical (`Combat.lua`).
- `sourceWeaponData.ForceCrit` forces one (`Combat.lua:864-868`); this is how
  guaranteed-crit effects work.
- `CritChance` appears on 13 traits in `TraitData.lua`; Artemis is the main
  source.
- Aspect of Nemesis grants a post-parry crit window via
  `AddLimitedWeaponBonus({ AsCrit = true, EffectName = "SwordPostParryCritical", ... })`
  (`Powers.lua:7-13`).

## 9d. Backstabs and deflect

- **Backstab** is implemented as an incoming-damage modifier effect,
  `AthenaBackstabVulnerability`, applied and cleared in `Combat.lua:3582-3596`.
  It is a *vulnerability on the victim*, not a flat attacker bonus, so it
  composes through the same additive/multiplicative rule above.
- **Deflect** shows up as `ProjectileDeflectedMultiplier` in the incoming
  modifier list (`Combat.lua:446`); deflected projectiles carry their own
  damage multiplier.
- **Boss damage** has its own hook, `BossDamageMultiplier` (`Combat.lua:449`),
  so "vs bosses" effects are a distinct category.
- `ProjectileAdditiveDamageMultiplier` (`Combat.lua:426`) is added straight into
  the additive pile.

## 9e. Health buffers

Before health is subtracted, `ProcessHealthBuffer( victim, triggerArgs )` runs
(`Combat.lua:878`). If it reports the damage as absorbed, health is untouched.
This is the mechanism behind shielding/armour-style effects on the player.

## 9f. Boon exclusions: what a pick costs you later

`IsGameStateEligible` (`RunManager.lua:3065`) refuses to offer a boon if you
already hold anything in its `RequiredFalseTrait` / `RequiredFalseTraits`:

```lua
if requirements.RequiredFalseTrait ~= nil and HeroHasTrait( requirements.RequiredFalseTrait ) then
    return false
end
```

`TraitData.lua` carries ~171 such declarations. Inverting them gives **92
traits that lock something out, across 222 distinct rules** (self-references
excluded; several traits list their own name as a guard against being granted
twice, which is not a lockout).

These are real forks in a run, not bookkeeping. Examples read from the data:

| Taking this… | …removes this from your pool |
| --- | --- |
| Freezing Vortex | Hunting Blades |
| Hunting Blades | Freezing Vortex |
| Aspect of Beowulf | Hunting Blades |
| Trippy Shot | Parting Shot |
| Aspect of Hera | Curse of Drowning |

Note the first two: the two strongest Ares-Cast duos are **mutually
exclusive**, so committing to one forfeits the other for the rest of the run.

Two things must be true of any scoring that uses this **[opinion]**:

1. **Same-slot exclusions are not an extra cost.** You can only hold one Cast
   boon anyway, so the mutual exclusions among Cast variants are already priced
   by the slot economy; charging them again double-counts.
2. **Nothing is lost if you already hold the casualty.** The penalty must
   disappear once the blocked boon is yours.

## 9g. Keepsakes and rarity boosts

A god keepsake (e.g. `ForceZeusBoonTrait`, `TraitData.lua:19260`) carries:

```lua
ForceBoonName = "ZeusUpgrade",
Uses = 1,
RarityBonus = { RequiredGod = "ZeusUpgrade", ... },
```

So while equipped it both **forces that god to appear** and **raises that god's
boon rarity**. Keepsake-forcing is therefore how a build guarantees its
linchpin boon rather than hoping for it.

Once that god is already visible on a door, the force has done its job. It is
not an additional benefit of choosing that door, and the force is only spent
when the boon is actually created (`RoomManager.lua:2654-2659`). The advisor
therefore values the keepsake's live rarity bonus but adds no sunk-cost bonus
to a visible door.

The rack recommendation is recalculated from the live run state. God keepsakes
use the game's eligible offer pool plus the strongest missing target in the
active aspect/build route. Utility keepsakes use their actual one-use,
accumulated, or remaining-region state. Pom Blossom also values the actual
upgradeable boons and their diminishing-return curves, rather than only
counting future activations. Butterfly and Plume forecast future stacks from
the player's damage-free and fast-clear rate in the current run, blended with
a conservative four-room prior. In particular, the advisor distinguishes an
unused god force from its rarity-only state, an unclaimed Coin Purse from one
that already paid, and a live Butterfly or Plume stack from a fresh one.
Blocked keepsakes and Hades' Sigil with an existing Call cannot receive the
best marker.

The current keepsake wins differences below the configured switch threshold,
so the advisor does not discard stacks or lock an item merely to gain a point
or two. All 25 keepsakes are evaluated once when the rack opens. The result is
cached for every badge and hover; no loot screen is generated or simulated in
this path.

Temporary rarity boosts exist too: `AddSuperRarityBoost()`
(`TraitScripts.lua:2380`) grants `SuperTemporaryBoonRarityTrait`, and loot can
carry a `RarityBoosted` flag (`Interactables.lua:740`). While one is active,
every boon offer rolls better.

Heat interacts here as well: each rank of `ReducedLootChoicesShrineUpgrade`
subtracts from `CalcNumLootChoices()`, reducing the normal three choices to two
or one. The advisor uses that live choice count for duo pursuit, Pom doors, and
god doors.

## 9h. Offer gating: do not reimplement it

`TraitData` gates whether a boon can be offered on roughly thirty different
fields. Counted across `TraitData.lua` + `LootData.lua`:

| Field | Count | Meaning |
| --- | --- | --- |
| `RequiredWeapon` | 242 | only with certain weapons |
| `RequiredFalseTraits` | 111 | blocked if you hold any of these |
| `RequiredGodLoot` | 80 | needs a boon from that god |
| `RequiredTrait` | 74 | needs a specific trait |
| `RequiredFalseTrait` | 70 | blocked by one trait |
| `RequiredMaxHealthFraction` | 59 | only below a health threshold |
| `RequiredMaxLastStands` | 56 | depends on Death Defiances left |
| `RequiredInactiveMetaUpgrade` | 23 | depends on Mirror choices |
| `RequiredLootChoices` | 22 | depends on how many options you get |
| `RequiredMinCompletedRuns` | 20 | save-progress gated |
| `RequiredBiome` | 15 | region gated |

The lesson: **never enumerate "all boons a god owns" and assume they can be
offered.** Call the game's own checker instead:

```lua
IsGameStateEligible( CurrentRun, TraitData[traitName] )
```

This applies every one of these rules and keeps working if the game changes.
Doing this by hand produced claims like "this door leads to Sea Storm" for boons
the run could never have been offered.

## 9i. Mirror talent keys are not the names on the icons

`IsMetaUpgradeSelected(name)` (`MetaUpgrades.lua:1989`) is a membership test
against `GameState.MetaUpgradesSelected`, which holds **`MetaUpgradeData` keys**:

| Talent (as shown in game) | Key to pass |
| --- | --- |
| Privileged Status | `VulnerabilityEffectBonusMetaUpgrade` |
| Family Favorite | `GodEnhancementMetaUpgrade` |

Note the trap: Privileged Status's *icon* is `MirrorIcon_EffectVulnerability`,
so "EffectVulnerability" looks like the right key and is not. Passing a name
that matches nothing does not error; `Contains` simply returns false forever,
so the feature silently never fires.

The advisor also reads the four rarity talents, God's Legacy, remaining Death
Defiances, Fated Persuasion, and Approval Process where those mechanics affect
rarity, risk, rerolls, or the number of visible choices.

## 10. Status Curses and the Mirror

A Status Curse is "a temporary debilitating effect inflicted by the Olympian
gods" (`HelpText`, id `Status`). The seven player-applied curses map to effect
names found inside trait data:

| Effect name | Curse | God |
| --- | --- | --- |
| `ReduceDamageOutput` | Weak | Aphrodite |
| `DelayedDamage` | Doom | Ares |
| `DamageOverTime` | Hangover | Dionysus |
| `DemeterSlow` | Chill | Demeter |
| `ZeusAttackPenalty` | Jolted | Zeus |
| `DamageOverDistance` | Ruptured | Poseidon |
| `AthenaBackstabVulnerability` | Exposed | Athena |

Two Mirror talents pull in **opposite directions**:

- **Privileged Status** (`VulnerabilityEffectBonusMetaUpgrade`): bonus damage vs foes with
  **2+ different** status curses. Wants curse breadth.
- **Family Favorite** (`GodEnhancementMetaUpgrade`): bonus damage per **distinct
  Olympian** whose boons you hold. Wants god breadth.

Which one is active is queryable: `IsMetaUpgradeSelected(name)`
(`MetaUpgrades.lua:1989`). These are run-wide damage multipliers, so they
outweigh most individual boon differences. **[opinion]**

## 11. Daedalus Hammers

The pool is `LootData.WeaponUpgrade.Traits`: 12 per weapon plus
aspect-specific extras (`LootData.lua:20042`). Aspects live in
`WeaponUpgradeData.lua` and are ordinary traits, so `HeroHasTrait` identifies
the one being carried.

`GetEligibleWeaponTraits` (`UpgradeChoice.lua:696`) removes hammers whose slot
is already occupied by a god boon of the same slot.

## 11a. Contractor reward upgrades and Infernal Gates

Four House Contractor upgrades add run value to ordinary resource rooms:

| Upgrade | Added run reward | Source |
| --- | --- | --- |
| `LockKeyDropRunProgress` | 1 reroll | `ConsumableData.lua:460-470` |
| `GiftDropRunProgress` | 1 level on a random eligible boon | `ConsumableData.lua:225-232` |
| `RoomRewardMetaPointDropRunProgress` | 5 max health | `ConsumableData.lua:1199-1209` |
| `GemDropRunProgress` | 20 Obols | `ConsumableData.lua:1355-1366` |

The reward type shown on a door remains Key, Nectar, Darkness, or Gemstones,
so these bonuses have to be inferred from `GameState.CosmeticsAdded` rather
than from a different door icon.

Infernal Gate rooms override normal rewards in place (`RoomData.lua:321-331`):
boons use 90% Rare and 25% Epic base chances, Poms grant two levels, Hearts
grant 50 max health, and gold rooms grant 200 Obols. These are destination-room
properties, not properties of the room the player is leaving. Door scoring
therefore reads the assigned room's overrides.

## 11b. Recommendation objectives

The game state does not say whether the player wants a safe clear, a personal
best, or a high-Heat clear. BoonAdvisor therefore exposes an explicit
`Objective` setting instead of guessing intent:

| Objective | Scoring change |
| --- | --- |
| `Balanced` | General clear consistency; preserves the default model |
| `Speed` | Stronger route commitment, speed boons, free rooms, and lower risk cost |
| `HighHeat` | Defensive boons, max health, and higher risk cost |

All profiles still read the active aspect, held traits, Mirror talents, Pact
conditions, health, gold, Death Defiances, biome, and legal offer pool. The
profile is an additional preference, not a replacement for live context.

Historical save analysis can compare final builds with outcomes and times, but
the save does not retain the offers shown at each choice. Exact recommendation
follow rates require `BoonAdvisor-runs.log`.

## 12. The save trap (why a mod can crash the game minutes after loading)

`Save()` (`Main.lua:1008`) walks **every global in `_G`** and serializes
anything not listed in `SaveIgnores`. It skips functions, but only at the
**top level**. A global *table* is serialized whole, and `luabins` aborts the
moment it reaches a function nested inside one:

```
Main.lua:1035: can't save: unsupported type detected
```

This fires at the next room transition, not at load, so the game boots cleanly
and dies later. Any mod global holding functions must register itself:

```lua
SaveIgnores["YourModTable"] = true
```

## 13. Where overlays can attach

- Boon screen: text attaches to `components["PurchaseButton"..i]`; it is destroyed
  with the buttons, so no cleanup needed.
- Doors: `exitDoor.DoorIconId`, created by `CreateDoorRewardPreview`. Absent for
  the Chaos gate; fall back to `exitDoor.ObjectId`.
- World objects: `CreateTextBox({ Id = <obstacleId>, … })` works
  (`Interactables.lua:959`), **but world text needs an explicit `Width`** or it
  is clipped mid-word.
- Dynamic strings must go through substitution
  (`Text = "{$TempTextData.X}"`, `LuaKey`/`LuaValue`); a raw Lua string in
  `Text` is treated as a localization key.

---

## Corrections to earlier assumptions in this mod

Recorded so the same mistakes are not repeated:

1. **"A Pom lets you level your best boon."** Wrong: 3 random draws from your
   held boons. Fixed to expected-best-of-k.
2. **"Pom levels decay linearly."** Wrong: geometric ×0.7 with a 0.1 floor.
3. **"A Trial of the Gods gives one boon."** Wrong: it gives **two**: one
   chosen up front, one from the refused god after the fight
   (`RoomEvents.lua:1469`). I got this wrong twice: first claiming two, then
   "correcting" myself to one after reading only `StartDevotionTest` and not
   the room-reward path. `ExchangeOnlyFromLootName` looked like it constrained
   the second reward, but it is never read.
4. **"The Chaos gate goes through `CreateDoorRewardPreview`."** Wrong: it is a
   `SecretDoor` reached only via `AssignRoomToExitDoor`.
5. **"A shop boon's god is in `Args.Name`."** Wrong: `Args.ForceLootName`.
6. **"All slots full means any boon replaces something."** Wrong: slotless
   boons exist.
7. **Invented trait names** (`SwordCastTrait`, `GunGrenadeSelfDamageTrait`).
   A wrong key is not an error in Lua; it silently never matches. Every name in
   this mod's tables is now asserted against `TraitData` by the test suite.

## 14. Screens and terms added in v1.14

### 14a. The Well of Charon is a screen, not a room of items

Charon's shop rooms spawn their stock into the world through
`SpawnStoreItemsInWorld` / `SpawnStoreItemInWorld` (StoreScripts.lua). The
Well is different: `UseWellShop` (Interactables.lua:436) calls `StartUpStore`,
which fills `CurrentRun.CurrentRoom.Store.StoreOptions` from
`StoreData.RoomShop` and opens a screen whose purchase buttons are built by
`CreateStoreButtons` (StoreScripts.lua:561). Each button carries the processed
item in `components["PurchaseButton"..i].Data`, with `Name`, `Type`, `Cost`
and, for Broker deals, `HealthCost`. `HandleStorePurchase` (StoreScripts.lua:835)
spends the gold, removes the entry from `StoreOptions` and destroys that
button; `RerollStore` destroys every button and rebuilds them.

The vanilla description text is attached to the purchase button itself, so
the advisor's badge lives on its own `BlankObstacle` anchor, registered in
`Screen.Components` as `BoonAdvisorWell<i>` so `CloseStoreScreen`'s
`CloseScreen( GetAllIds( components ) )` destroys it with the rest.

### 14b. Hammers change hit cadence

`Ratings.WeaponHitClass` and `Ratings.AspectHitClass` describe how often the
Attack and Special hit, which decides whether flat on-hit boons (Zeus,
Dionysus) or big multipliers (Aphrodite, Artemis) fit a slot. Several hammers
rebuild the move: Flurry Jab (`SpearAutoAttack`) makes the spear a rapid jab,
Flurry Shot (`BowTapFireTrait`) makes the bow rapid-fire, Spread Fire
(`GunShotgunTrait`) turns the rail's bullet stream into a few heavy pellets,
Cluster Bomb (`GunGrenadeClusterTrait`) splits the bomb into many small ones.
`Ratings.HammerHitClass` lists these and `CurrentHitClass` consults a held
hammer before the aspect and weapon tables.

### 14c. Trial of the Gods: the refused god fights you

`StartDevotionTest` (RoomEvents.lua:1669) calls
`AddEnemyUpgrade( alternateLootData.Name )` for the god you did not pick and,
when `EnemyData[<God>RoomWeapon]` exists, spawns that god's room weapon. The
danger differs a lot by god (Ares blade rifts and Zeus chain lightning versus
Athena deflect), so `Config.Doors.TrialSpurnedRisk` charges the Trial for the
god the advisor expects you to refuse: the lower-scored of the two.

Inside the room the two pickups come from `GiveLoot` -> `CreateLoot`
(RoomManager.lua:2831), which returns the loot table with its `ObjectId` and
the god's loot `Name`. The mod hooks `CreateLoot`, and once both pickups of
the current Devotion room exist it badges each orb with
`boon(X) now + DevotionSecondBoonWeight * boon(Y) later - TrialSpurnedRisk[Y]`
and stars the god to open. Opening either orb calls `CreateBoonLootButtons`
with that loot, which is where the choice is logged as `[trial]` and the
badges are removed (vanilla destroys both orbs right after).

### 14d. Fated Authority

`AssignRoomToExitDoor` (RoomManager.lua:4984) marks a door `CanBeRerolled`
when `IsMetaUpgradeSelected( "RerollMetaUpgrade" )` and the door allows it;
`AttemptRerollDoor` (Interactables.lua:1356) then replaces that one door's
reward with `ChooseRoomReward`, excluding the rewards already offered. The
advisor suggests a reroll only when a die is left, some exit can be
rerolled, and no enterable exit reaches the biome's usual door value
(`Config.Doors.RerollAdvice`).

### 14e. Room outcomes the game already records

With `LogPicks` on, one `[room ]` line is written from the `LeaveRoom` hook,
before vanilla swaps `CurrentRoom`. Its fields come from state vanilla keeps
for its own purposes: `Encounter.ClearTime` (RoomManager.lua:2563),
`Encounter.PlayerTookDamage` (Combat.lua:1188), the global per-room
`DamageRecord` keyed by attacker name (Combat.lua:1209, reset in `StartRoom`),
`CurrentRun.BiomeTime` when the Tight Deadline timer is active, and the hero's
health. `[run-end]` adds `LastKilledByUnitName` (DeathLoop.lua:31) and the
sum of `CurrentRun.DamageRecord`.
