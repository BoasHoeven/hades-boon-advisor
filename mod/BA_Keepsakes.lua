--[[
	BoonAdvisor - keepsake advisor.

	A god keepsake steers its next offer and rarity. Utility keepsakes depend on
	the run state: stage, aspect, health, Death Defiances, gold, accumulated
	stacks, filled slots, and whether a one-use effect has already paid out.

	Hooked into CreateKeepsakeIcon (AwardMenuScripts.lua:347), which is called
	once per keepsake on the rack.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

function BoonAdvisor.IsKeepsakeTraitData( traitData )
	if traitData == nil then
		return false
	end
	if traitData.Slot ~= nil then
		return traitData.Slot == "Keepsake"
	end
	for _, parentName in ipairs( traitData.InheritFrom or {} ) do
		if parentName == "GiftTrait" then
			return true
		end
		if parentName == "AssistTrait" then
			return false
		end
		if BoonAdvisor.IsKeepsakeTraitData( TraitData[parentName] ) then
			return true
		end
	end
	return false
end

-- A duo is present in both contributing gods' LinkedUpgrades tables. Checking
-- the pool directly avoids assigning it to whichever god pairs() visited first.
function BoonAdvisor.TraitOfferedByGod( traitName, lootName )
	local traitData = TraitData[traitName]
	if traitData ~= nil and traitData.God ~= nil then
		return traitData.God .. "Upgrade" == lootName
	end
	local lootInfo = LootData[lootName]
	return lootInfo ~= nil and type( lootInfo.LinkedUpgrades ) == "table"
		and lootInfo.LinkedUpgrades[traitName] ~= nil
end

local function clamp( value, minimum, maximum )
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function currentKeepsakeTrait( traitName )
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		if trait.Name == traitName then return trait end
	end
	return nil
end

local function keepsakeLevel( traitName )
	if GetKeepsakeLevel ~= nil then
		local success, level = pcall( GetKeepsakeLevel, traitName )
		if success and type( level ) == "number" then return level end
	end
	local chambers = GameState ~= nil and GameState.KeepsakeChambers ~= nil
		and GameState.KeepsakeChambers[traitName] or 0
	if chambers >= 75 then return 3 end
	if chambers >= 25 then return 2 end
	return 1
end

local function levelMultiplier( traitName )
	local data = TraitData[traitName]
	local levels = data ~= nil and data.RarityLevels or nil
	if levels == nil then return 1 end
	local common = levels.Common ~= nil and levels.Common.Multiplier or 1
	local level = keepsakeLevel( traitName )
	local rarity = level == 3 and "Epic" or level == 2 and "Rare" or "Common"
	local multiplier = levels[rarity] ~= nil and levels[rarity].Multiplier or common
	if type( multiplier ) ~= "number" or type( common ) ~= "number" or common == 0 then
		return 1
	end
	return multiplier / common
end

local function currentWeapon()
	if GetEquippedWeapon ~= nil then
		local success, weapon = pcall( GetEquippedWeapon )
		if success and weapon ~= nil then return weapon end
	end
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	return hero ~= nil and ( hero.WeaponName or hero.Weapon ) or nil
end

local function hasBlockedKeepsake( traitName )
	return CurrentRun ~= nil and Contains( CurrentRun.BlockedKeepsakes or {}, traitName )
end

local function hasLastStand( name )
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	local lastStands = hero ~= nil and hero.LastStands or nil
	if type( lastStands ) ~= "table" then return false end
	for _, lastStand in pairs( lastStands ) do
		if lastStand.Name == name then return true end
	end
	return false
end

-- Butterfly and Plume are only as good as the player's current run is at
-- satisfying their conditions. A small Bayesian prior prevents one unusually
-- good or bad chamber from swinging the recommendation.
local function stackingSuccessRates( run, preRun )
	local scores = BoonAdvisor.Config.Keepsakes.Scores
	local butterflyPrior = scores.ButterflyFuturePerRoom
	local plumePrior = scores.PlumeFuturePerRoom
	if preRun then return butterflyPrior, plumePrior end

	local attempts, perfect, fast = 0, 0, 0
	for _, room in pairs( run.RoomHistory or {} ) do
		local encounter = room.Encounter
		if encounter ~= nil and not room.BlockClearRewards
			and encounter.EncounterType ~= "NonCombat"
			and type( encounter.ClearTime ) == "number" then
			attempts = attempts + 1
			if encounter.PlayerTookDamage == false then perfect = perfect + 1 end
			local threshold = encounter.FastClearThreshold or 30
			if encounter.ClearTime < threshold then fast = fast + 1 end
		end
	end
	local priorRooms = scores.StackRatePriorRooms
	return ( butterflyPrior * priorRooms + perfect ) / ( priorRooms + attempts ),
		( plumePrior * priorRooms + fast ) / ( priorRooms + attempts )
end

function BoonAdvisor.KeepsakeContext()
	local run = CurrentRun or {}
	local room = run.CurrentRoom or {}
	local hero = run.Hero or {}
	local name = room.Name or ""
	local biome = room.RoomSetName or "Tartarus"
	local deathRoomName = CurrentDeathAreaRoom ~= nil and CurrentDeathAreaRoom.Name or nil
	local preRun = name == "RoomPreRun" or deathRoomName == "RoomPreRun"
		or biome == "Home"
	local stage, rooms, bossWeight, chaosGates, expectedWells = biome, 10, 0.5, 0.5, 1.5

	if preRun then
		stage, rooms, bossWeight, chaosGates, expectedWells = "Tartarus", 13, 0.35, 1.2, 1.5
	elseif name == "A_PostBoss01" then
		stage, rooms, bossWeight, chaosGates, expectedWells = "Asphodel", 8, 0.50, 0.6, 2
	elseif name == "B_PostBoss01" then
		stage, rooms, bossWeight, chaosGates, expectedWells = "Elysium", 10, 0.82, 0.4, 2
	elseif name == "C_PostBoss01" or biome == "Styx" then
		stage, rooms, bossWeight, chaosGates, expectedWells = "Styx", 12, 1.00, 0, 2
	elseif GetRunDepth ~= nil then
		local depth = GetRunDepth( run ) or 1
		rooms = math.max( 5, 13 - depth )
		if biome == "Elysium" then bossWeight, chaosGates = 0.82, 1 end
		if biome == "Asphodel" then bossWeight, chaosGates = 0.50, 2 end
	end

	local currentName = GameState ~= nil and GameState.LastAwardTrait or nil
	local maximum = hero.MaxHealth or 100
	local healthFraction = maximum > 0 and ( hero.Health or maximum ) / maximum or 1
	local defiances = BoonAdvisor.LastStandsRemaining()
	local baseDefiances = defiances
	if not preRun and currentName == "ReincarnationTrait"
		and hasLastStand( "ReincarnationTrait" ) then
		baseDefiances = math.max( 0, defiances - 1 )
	end
	local money = run.Money or 0
	if preRun then
		healthFraction = 1
		money = 0
		if BoonAdvisor.MetaUpgradeActive ~= nil
			and BoonAdvisor.MetaUpgradeActive( "ExtraChanceMetaUpgrade" ) then
			defiances = GetNumMetaUpgrades ~= nil
				and ( GetNumMetaUpgrades( "ExtraChanceMetaUpgrade" ) or 0 ) or 0
		elseif BoonAdvisor.MetaUpgradeActive ~= nil
			and BoonAdvisor.MetaUpgradeActive( "ExtraChanceReplenishMetaUpgrade" ) then
			defiances = 1
		else
			defiances = 0
		end
		baseDefiances = defiances
	end
	local butterflyRate, plumeRate = stackingSuccessRates( run, preRun )
	return {
		PreRun = preRun,
		Stage = stage,
		RemainingRooms = rooms,
		BossWeight = bossWeight,
		ChaosGates = chaosGates,
		ExpectedWells = expectedWells,
		HealthFraction = clamp( healthFraction, 0, 1 ),
		Defiances = defiances,
		BaseDefiances = baseDefiances,
		Danger = BoonAdvisor.DangerLevel(),
		Money = money,
		ButterflySuccessRate = butterflyRate,
		PlumeSuccessRate = plumeRate,
		CurrentName = currentName,
		FreeSwap = room.KeepsakeFreeSwap == true
			or ( CurrentDeathAreaRoom ~= nil and CurrentDeathAreaRoom.KeepsakeFreeSwap == true ),
		Weapon = currentWeapon(),
	}
end

local function objectiveKeepsakeBonus( traitName )
	return ( BoonAdvisor.ObjectiveProfile().KeepsakeBonus or {} )[traitName] or 0
end

-- Pick one coherent, currently legal route target. Counting every missing
-- member of every aspect route inflated gods that happened to occur in more
-- route definitions, even when those routes were mutually exclusive.
local function godBuildNeed( forced, candidates )
	local bestValue, bestName = 0, nil
	local objective = BoonAdvisor.ActiveObjectiveName()
	local multiplier = BoonAdvisor.ObjectiveProfile().ArchetypeMultiplier or 1
	for _, archetype in ipairs( BoonAdvisor.Ratings.Archetypes ) do
		local live = archetype.Aspect ~= nil and HeroHasTrait( archetype.Aspect )
			or archetype.Aspect == nil and BoonAdvisor.HeroHasAnyOf( archetype.Core )
		if live then
			local members = {}
			for _, name in ipairs( archetype.Core ) do table.insert( members, name ) end
			if archetype.Payoff ~= nil then table.insert( members, archetype.Payoff ) end
			for _, name in ipairs( members ) do
				if candidates[name] and not HeroHasTrait( name )
					and BoonAdvisor.TraitOfferedByGod( name, forced ) then
					local value = archetype.Payoff == name
						and ( archetype.PayoffBonus or BoonAdvisor.Config.Weights.ArchetypePayoff )
						or ( archetype.CoreBonus or BoonAdvisor.Config.Weights.ArchetypeCore )
					value = value * multiplier + ( archetype.ObjectiveBonus ~= nil
						and ( archetype.ObjectiveBonus[objective] or 0 ) or 0 )
					if value > bestValue then bestValue, bestName = value, name end
				end
			end
		end
	end
	return bestValue, bestName
end

-- Keepsake racks contain eight god items. Running the full boon scorer over
-- every member of all eight pools is accurate but needlessly repeats the most
-- expensive exclusion graph work in one frame. This compact scorer preserves
-- the terms that actually distinguish a forced god here: legal eligibility,
-- boon baseline, open slots, aspect affinity, Pact effects, biome knockback,
-- and Mirror status/god breadth. Route-specific value is added separately.
local function prospectiveSlotFilled( slot, context, candidateKeepsake )
	if slot ~= "Shout" or context == nil
		or context.CurrentName ~= "HadesShoutKeepsake"
		or candidateKeepsake == "HadesShoutKeepsake" then
		return BoonAdvisor.SlotFilled( slot )
	end
	-- Hades' Aid is removed when its keepsake is switched out. Preserve a real
	-- Call if another mod or edge case has put one alongside it.
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		if trait.Slot == slot and trait.Name ~= "HadesShoutTrait" then return true end
	end
	return false
end

local function keepsakeCandidateScore( traitName, context, candidateKeepsake )
	local weights = BoonAdvisor.Config.Weights
	local score = BoonAdvisor.Ratings.Base[traitName]
	if score == nil then
		score = BoonAdvisor.Ratings.CategoryDefaults[BoonAdvisor.KindOf( traitName )]
			or weights.DefaultBase
	end
	local data = TraitData[traitName]
	local slot = data ~= nil and data.Slot or nil
	if slot ~= nil then
		score = score + ( prospectiveSlotFilled( slot, context, candidateKeepsake )
			and weights.SlotExchange or weights.EmptySlot )
			+ BoonAdvisor.AspectBonus( slot )
	end
	local pact = BoonAdvisor.PactBonus( traitName )
	local slam = BoonAdvisor.KnockbackBonus( traitName )
	local mirror = BoonAdvisor.MetaBonus( traitName )
	return score + pact + slam + mirror
end

local function godCandidateValue( forced, context, candidateKeepsake )
	if BoonAdvisor.GetGodCandidateTraits == nil then return 60, nil, {} end
	local values, candidates, bestName, bestValue = {}, {}, nil, nil
	for _, traitName in ipairs( BoonAdvisor.GetGodCandidateTraits( forced ) or {} ) do
		local value = keepsakeCandidateScore( traitName, context, candidateKeepsake )
		candidates[traitName] = true
		table.insert( values, value )
		if bestValue == nil or value > bestValue then
			bestName, bestValue = traitName, value
		end
	end
	if IsEmpty( values ) then return 55, nil, candidates end
	local choices = CalcNumLootChoices ~= nil and ( CalcNumLootChoices() or 3 ) or 3
	choices = math.max( 1, math.min( choices, TableLength( values ) ) )
	return BoonAdvisor.ExpectedBestOfK( values, choices ), bestName, candidates
end

local function scoreGodKeepsake( traitName, traitData, context )
	local config = BoonAdvisor.Config.Keepsakes
	local forced = traitData.ForceBoonName
	local offerValue, offerBest, candidates = godCandidateValue( forced, context, traitName )
	local routeValue, routeTarget = godBuildNeed( forced, candidates )
	local equipped = currentKeepsakeTrait( traitName )
	local forceAvailable = context.PreRun or equipped == nil
		or equipped.Uses == nil or equipped.Uses > 0
	-- Once the one-use force is gone, a desired route target is no longer a
	-- reason to keep the item: the god is not guaranteed to appear. Its live
	-- rarity bonus still has value if that god returns naturally.
	if not forceAvailable then routeValue, routeTarget = 0, nil end
	local score = config.GodBase
		+ ( offerValue - config.GodOfferBaseline ) * config.GodOfferWeight
		+ routeValue * config.GodRouteWeight
		+ ( keepsakeLevel( traitName ) - 1 ) * config.GodRankBonus
	if not forceAvailable then
		score = score - config.GodSpentPenalty + config.GodRarityOnlyBonus
	end
	local reason
	if routeTarget ~= nil and forceAvailable then
		reason = "targets this god for " .. BoonAdvisor.TraitDisplayName( routeTarget )
	elseif not forceAvailable then
		reason = "god already forced; rarity bonus only"
	else
		reason = offerBest ~= nil and "best likely offer: "
			.. BoonAdvisor.TraitDisplayName( offerBest ) or "no useful legal offers"
		score = score - config.UnwantedPenalty
	end
	return score, reason
end

local function stackingScore( traitName, context )
	local scores = BoonAdvisor.Config.Keepsakes.Scores
	local trait = currentKeepsakeTrait( traitName )
	local accumulated = 0
	if not context.PreRun and traitName == "FastClearDodgeBonusTrait" and trait ~= nil then
		accumulated = ( trait.AccumulatedDodgeBonus or 0 ) * 100
	elseif not context.PreRun and traitName == "PerfectClearDamageBonusTrait" and trait ~= nil then
		accumulated = math.max( 0, ( trait.AccumulatedDamageBonus or 1 ) - 1 ) * 100
	end
	local futurePerRoom = traitName == "FastClearDodgeBonusTrait"
		and context.PlumeSuccessRate or context.ButterflySuccessRate
	local future = context.RemainingRooms * futurePerRoom * levelMultiplier( traitName )
	local score = scores.StackingBase + accumulated * scores.StackingExistingScale + future
	local reason
	if accumulated > 0 then
		reason = string.format( "keep %.0f%% stacked bonus", accumulated )
	elseif context.RemainingRooms >= 10 then
		reason = string.format( "about %.0f future successful encounters",
			context.RemainingRooms * futurePerRoom )
	else
		reason = "limited encounters left to stack"
	end
	return score, reason
end

local function pomBlossomTargets()
	if BoonAdvisor.GetPomCandidates == nil or BoonAdvisor.ScorePom == nil then
		return nil, nil, 0
	end
	local candidates = BoonAdvisor.GetPomCandidates(
		LootData ~= nil and LootData.StackUpgrade or nil )
	if IsEmpty( candidates ) then return nil, nil, 0 end
	local total, bestName, bestValue = 0, nil, nil
	for _, traitName in ipairs( candidates ) do
		local value = BoonAdvisor.ScorePom( traitName, nil )
		total = total + value
		if bestValue == nil or value > bestValue then
			bestName, bestValue = traitName, value
		end
	end
	return total / TableLength( candidates ), bestName, TableLength( candidates )
end

local function scoreUtilityKeepsake( traitName, context )
	local scores = BoonAdvisor.Config.Keepsakes.Scores
	local level = keepsakeLevel( traitName )
	local factor = levelMultiplier( traitName )
	local rankBonus = ( level - 1 ) * 4
	local missingHealth = 1 - context.HealthFraction
	local score, reason

	if traitName == "MaxHealthKeepsakeTrait" then
		local health = math.floor( 25 * factor + 0.5 )
		score = scores.MaxHealthBase + ( health / 25 ) * scores.MaxHealthPer25
			+ missingHealth * scores.LowHealthUrgency + context.Danger
		reason = "+" .. health .. " health; safer at "
			.. math.floor( context.HealthFraction * 100 ) .. "% HP"
	elseif traitName == "DirectionalArmorTrait" then
		score = scores.DefenseBase + rankBonus + context.Danger * 1.5
		reason = context.Danger > 0 and "front defense for this Heat" or "steady frontal defense"
	elseif traitName == "BackstabAlphaStrikeTrait" then
		local melee = context.Weapon == "SwordWeapon" or context.Weapon == "FistWeapon"
		score = scores.DamageBase + rankBonus + ( melee and 6 or 1 )
		reason = melee and "fits close-range attacks" or "situational first-hit damage"
	elseif traitName == "PerfectClearDamageBonusTrait"
		or traitName == "FastClearDodgeBonusTrait" then
		score, reason = stackingScore( traitName, context )
	elseif traitName == "ShopDurationTrait" then
		score = scores.HourglassBase + rankBonus
			+ context.ExpectedWells * scores.HourglassPerExpectedWell
			+ math.min( 4, context.Money / 75 )
		local duration = math.floor( 4 * factor + 0.5 )
		reason = "adds " .. duration .. " encounters to future Well items"
	elseif traitName == "BonusMoneyTrait" then
		local claimed = currentKeepsakeTrait( traitName ) ~= nil and not context.FreeSwap
		if claimed then
			score, reason = scores.MoneyAlreadyClaimed, "gold already claimed; switch away"
		else
			local amount = math.floor( 100 * factor + 0.5 )
			score = scores.MoneyBase + math.min( scores.MoneyCap,
				amount / 25 * scores.MoneyPer25 )
			reason = "+" .. amount .. " gold immediately"
		end
	elseif traitName == "LowHealthDamageTrait" then
		score = scores.DamageBase + rankBonus + missingHealth * scores.LowHealthUrgency
			+ context.BossWeight * 4
		reason = context.HealthFraction <= 0.35 and "damage bonus active now"
			or "boss damage when below 35% HP"
	elseif traitName == "DistanceDamageTrait" then
		local affinity = BoonAdvisor.AspectBonus( "Ranged" )
		local ranged = affinity >= 8 or context.Weapon == "BowWeapon" or context.Weapon == "GunWeapon"
		score = scores.DamageBase + rankBonus + ( ranged and scores.RangedAspectBonus or 0 )
		reason = ranged and "fits your ranged damage plan" or "only works at long range"
	elseif traitName == "LifeOnUrnTrait" then
		local healingMultiplier = BoonAdvisor.HealingMultiplier ~= nil
			and BoonAdvisor.HealingMultiplier() or 1
		if healingMultiplier <= 0 then
			score, reason = 1, "urns restore 0 health at this Heat"
		else
			score = ( 48 + rankBonus + missingHealth * scores.UrnLowHealthBonus
				+ math.min( 5, context.RemainingRooms * 0.15 ) ) * healingMultiplier
			reason = missingHealth > 0.35 and "urn healing can stabilize rooms"
				or "small, random healing"
		end
	elseif traitName == "ReincarnationTrait" then
		local spent = not context.PreRun and currentKeepsakeTrait( traitName ) ~= nil
			and not hasLastStand( "ReincarnationTrait" )
		if spent then
			score, reason = 30, "extra life already spent; switch away"
		else
			local heal = math.floor( 50 * factor + 0.5 )
			local otherDefiances = context.BaseDefiances or context.Defiances
			score = 66 + rankBonus + ( otherDefiances == 0 and scores.ToothNoDefianceBonus or 0 )
				+ math.max( 0, 2 - otherDefiances ) * scores.ToothMissingDefianceBonus
			reason = otherDefiances == 0 and "no other Death Defiances; restores " .. heal
				or "adds a " .. heal .. " HP extra life"
		end
	elseif traitName == "VanillaTrait" then
		local empty = context.PreRun and 3 or 0
		if not context.PreRun then
			for _, slot in ipairs({ "Melee", "Secondary", "Ranged" }) do
				if not BoonAdvisor.SlotFilled( slot ) then empty = empty + 1 end
			end
		end
		score = scores.DamageBase + empty * scores.ShackleEmptySlotBonus
			- ( 3 - empty ) * scores.ShackleFilledSlotPenalty + rankBonus
		reason = empty > 0 and empty .. " unbooned core slot(s) gain damage"
			or "all three core slots are filled"
	elseif traitName == "ShieldBossTrait" then
		score = scores.DefenseBase + rankBonus + context.BossWeight * scores.AcornBossBonus
			+ context.Danger * scores.AcornDangerBonus
		local hits = math.floor( 3 * factor + 0.5 )
		reason = context.Stage == "Styx" and "blocks " .. hits .. " final-boss hits"
			or "blocks " .. hits .. " boss hits in " .. context.Stage
	elseif traitName == "ShieldAfterHitTrait" then
		score = scores.DefenseBase + rankBonus + missingHealth * scores.SpearpointLowHealthBonus
			+ context.Danger
		reason = missingHealth > 0.45 and "prevents follow-up damage at low HP"
			or "blocks damage after each hit"
	elseif traitName == "ChamberStackTrait" then
		local interval = level == 3 and 4 or level == 2 and 5 or 6
		local trait = currentKeepsakeTrait( traitName )
		local progress = not context.PreRun and trait ~= nil
			and ( trait.CurrentRoom or 0 ) or 0
		local expected = math.floor( ( context.RemainingRooms + progress ) / interval )
		local targetValue, bestTarget = pomBlossomTargets()
		score = scores.PomBase + expected * scores.PomPerExpectedLevel
		if targetValue ~= nil then
			score = score + expected * ( targetValue - scores.PomTargetBaseline )
				* scores.PomTargetWeight
			reason = expected > 0 and "about " .. expected .. " random level(s); best target: "
				.. BoonAdvisor.TraitDisplayName( bestTarget )
				or "not enough rooms for another level"
		elseif context.PreRun then
			reason = "about " .. expected .. " free levels after you find boons"
		else
			score = score - scores.PomEmptyPenalty
			reason = "no boon can gain a level yet"
		end
	elseif traitName == "HadesShoutKeepsake" then
		if not context.PreRun and BoonAdvisor.SlotFilled( "Shout" )
			and not HeroHasTrait( "HadesShoutTrait" ) then
			score = scores.DamageBase - scores.HadesExistingCallPenalty
			reason = "blocked by your current Call"
		else
			local filled = not context.PreRun and BoonAdvisor.SlotFilled( "Shout" )
			score = scores.DamageBase + rankBonus + context.BossWeight * 8
				+ ( filled and 0 or scores.HadesEmptyCallBonus )
			reason = filled and "keeps Hades' Aid"
				or "fills empty Call with Hades' Aid"
		end
	elseif traitName == "ChaosBoonTrait" then
		if context.ChaosGates > 0 then
			score = scores.ChaosBase + math.min( scores.ChaosGateCap,
				context.ChaosGates * scores.ChaosPerGate ) + rankBonus
			reason = "free entry and better Chaos rarity"
		else
			score, reason = scores.ChaosNoGateScore, "no normal Chaos gates remain"
		end
	else
		score, reason = scores.UnratedBase, "limited value for this run"
	end
	return score, reason
end

-- Score one keepsake against the state at this rack. No simulation or UI work
-- occurs here, and the complete rack is cached before any badge is drawn.
function BoonAdvisor.ScoreKeepsake( traitName, context )
	local traitData = TraitData[traitName]
	if not BoonAdvisor.IsKeepsakeTraitData( traitData ) then return nil, nil end
	context = context or BoonAdvisor.KeepsakeContext()
	local score, reason
	if traitData.ForceBoonName ~= nil then
		score, reason = scoreGodKeepsake( traitName, traitData, context )
	else
		score, reason = scoreUtilityKeepsake( traitName, context )
	end
	return score + objectiveKeepsakeBonus( traitName ), reason
end

function BoonAdvisor.IsKeepsakeSelectable( traitName, context )
	context = context or BoonAdvisor.KeepsakeContext()
	if not context.PreRun and hasBlockedKeepsake( traitName ) then return false end
	if not context.PreRun and traitName == "HadesShoutKeepsake"
		and BoonAdvisor.SlotFilled( "Shout" )
		and not HeroHasTrait( "HadesShoutTrait" ) then return false end
	return true
end

function BoonAdvisor.EvaluateKeepsakeRack( available )
	local context = BoonAdvisor.KeepsakeContext()
	local evaluations = {}
	local current = GameState ~= nil and GameState.LastAwardTrait or nil
	local bestName, bestRaw = nil, nil
	for _, upgrade in ipairs( available or {} ) do
		local name = upgrade.Gift
		if upgrade.Unlocked == true and name ~= nil
			and BoonAdvisor.IsKeepsakeTraitData( TraitData[name] ) then
			local raw, reason = BoonAdvisor.ScoreKeepsake( name, context )
			local finalized = BoonAdvisor.Finalize( raw )
			evaluations[name] = { RawScore = raw, FinalScore = finalized, Reason = reason,
				Selectable = BoonAdvisor.IsKeepsakeSelectable( name, context ) }
			if evaluations[name].Selectable and ( bestRaw == nil or raw > bestRaw ) then
				bestName, bestRaw = name, raw
			end
		end
	end

	local currentResult = current ~= nil and evaluations[current] or nil
	if currentResult ~= nil and currentResult.Selectable and bestRaw ~= nil
		and evaluations[bestName].FinalScore - currentResult.FinalScore
			< BoonAdvisor.Config.Keepsakes.SwitchThreshold then
		bestName, bestRaw = current, currentResult.RawScore
	end
	for name, result in pairs( evaluations ) do
		result.IsBest = name == bestName
		result.GainOverCurrent = currentResult ~= nil
			and result.FinalScore - currentResult.FinalScore or nil
	end
	return { Context = context, Results = evaluations, BestName = bestName,
		BestScore = bestRaw, CurrentName = current,
		BestFinalScore = bestName ~= nil and evaluations[bestName].FinalScore or nil,
		CurrentScore = currentResult ~= nil and currentResult.RawScore or nil,
		CurrentFinalScore = currentResult ~= nil and currentResult.FinalScore or nil }
end

function BoonAdvisor.PrepareKeepsakeRack()
	local screen = ScreenAnchors ~= nil and ScreenAnchors.AwardMenuScreen or nil
	if screen == nil then return nil end
	if BoonAdvisor.KeepsakeEvaluationScreen ~= screen then
		BoonAdvisor.KeepsakeEvaluationScreen = screen
		local available = UIData ~= nil and UIData.AwardMenu ~= nil
			and UIData.AwardMenu.AvailableKeepsakeTraits or {}
		BoonAdvisor.LastKeepsakeEvaluation = BoonAdvisor.EvaluateKeepsakeRack( available )
	end
	return BoonAdvisor.LastKeepsakeEvaluation
end

function BoonAdvisor.KeepsakeGuidance( traitName, result, evaluation, selectedName )
	if result == nil then return nil end
	selectedName = selectedName or evaluation.CurrentName
	local selectedResult = selectedName ~= nil and evaluation.Results[selectedName] or nil
	if result.IsBest then
		if traitName == selectedName then return "KEEP: " .. result.Reason end
		local gain = selectedResult ~= nil
			and math.floor( result.FinalScore - selectedResult.FinalScore + 0.5 ) or nil
		return ( gain ~= nil and "SWITCH +" .. gain .. ": " or "BEST: " ) .. result.Reason
	end
	if traitName == selectedName and evaluation.BestName ~= nil then
		local gain = math.floor( ( evaluation.BestFinalScore - result.FinalScore ) + 0.5 )
		return "SWITCH TO " .. BoonAdvisor.TraitDisplayName( evaluation.BestName )
			.. " (+" .. gain .. ")"
	end
	return result.Reason
end

function BoonAdvisor.UpdateKeepsakeDetail( button )
	local screen = ScreenAnchors ~= nil and ScreenAnchors.AwardMenuScreen or nil
	local components = screen ~= nil and screen.Components or nil
	if components == nil then
		return
	end

	local detail = components.BoonAdvisorKeepsakeDetail
	if detail == nil and CreateScreenComponent ~= nil then
		detail = CreateScreenComponent({
			Name = "BlankObstacle",
			Group = "Combat_Menu_TraitTray",
		})
		components.BoonAdvisorKeepsakeDetail = detail
		if detail ~= nil and detail.Id ~= nil and components.InfoBackground ~= nil
			and components.InfoBackground.Id ~= nil and Attach ~= nil then
			Attach({
				Id = detail.Id,
				DestinationId = components.InfoBackground.Id,
				OffsetY = BoonAdvisor.Config.Keepsakes.Layout.DetailOffsetY,
			})
		end
	end
	if detail == nil or detail.Id == nil then
		return
	end
	if DestroyTextBox ~= nil then
		DestroyTextBox({ Id = detail.Id })
	end
	if button == nil or button.BoonAdvisorKeepsakeScore == nil then
		return
	end

	local layout = BoonAdvisor.Config.Keepsakes.Layout
	local showEnglish = BoonAdvisor.ShouldShowReason()
	local labelColor = Color ~= nil and Color.White or { 1, 1, 1, 1 }
	local reasonColor = Color ~= nil and Color.SubTitle or BoonAdvisor.Config.ReasonColor
	if showEnglish then
		CreateTextBox({
			Id = detail.Id,
			Text = "{$TempTextData.BALine}",
			LuaKey = "TempTextData",
			LuaValue = { BALine = "BUILD FIT" },
			FontSize = layout.DetailLabelFontSize,
			OffsetX = layout.DetailLabelOffsetX,
			OffsetY = layout.DetailLabelOffsetY,
			Color = labelColor,
			Font = "AlegreyaSansSCBold",
			Justification = "Left",
			Width = 110,
			ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
			OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
		})
	end
	CreateTextBox({
		Id = detail.Id,
		Text = "{$TempTextData.BALine}",
		LuaKey = "TempTextData",
		LuaValue = { BALine = button.BoonAdvisorKeepsakeRank
			.. "  " .. button.BoonAdvisorKeepsakeScore },
		FontSize = layout.DetailRankFontSize,
		OffsetX = showEnglish and layout.DetailValueOffsetX or layout.DetailLabelOffsetX,
		OffsetY = showEnglish and layout.DetailValueOffsetY or layout.DetailLabelOffsetY,
		Color = button.BoonAdvisorKeepsakeColor,
		Font = "AlegreyaSansSCBold",
		Justification = "Left",
		Width = 100,
		ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
		OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
	})
	local reason = button.BoonAdvisorKeepsakeReason
	local evaluation = BoonAdvisor.LastKeepsakeEvaluation
	if evaluation ~= nil and button.BoonAdvisorKeepsakeTrait ~= nil then
		local liveResult = evaluation.Results[button.BoonAdvisorKeepsakeTrait]
		reason = BoonAdvisor.KeepsakeGuidance( button.BoonAdvisorKeepsakeTrait,
			liveResult, evaluation,
			GameState ~= nil and GameState.LastAwardTrait or nil )
	end
	if showEnglish and reason ~= nil then
		CreateTextBox({
			Id = detail.Id,
			Text = "{$TempTextData.BALine}",
			LuaKey = "TempTextData",
			LuaValue = { BALine = reason },
			FontSize = layout.DetailReasonFontSize,
			OffsetY = layout.DetailReasonOffsetY,
			Color = reasonColor,
			Font = "CrimsonTextItalic",
			Justification = "Left",
			Width = layout.DetailWidth,
			ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
			OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
		})
	end
end

function BoonAdvisor.DrawKeepsakeOverlay( components, args )
	local config = BoonAdvisor.Config
	if not config.Enabled or not config.Keepsakes.Enabled then
		return
	end
	if components == nil or args == nil or args.UpgradeData == nil
		or args.UpgradeData.Unlocked ~= true then
		return
	end

	local traitName = args.UpgradeData.Gift
	if traitName == nil then
		return
	end
	local traitData = TraitData[traitName]
	if not BoonAdvisor.IsKeepsakeTraitData( traitData ) then
		return
	end

	local buttonKey = "UpgradeToggle" .. tostring( args.Index ) .. ( args.KeyAppend or "" )
	local button = components[buttonKey]
	if button == nil or button.Id == nil then
		return
	end

	local evaluation = BoonAdvisor.PrepareKeepsakeRack()
	local result = evaluation ~= nil and evaluation.Results[traitName] or nil
	if result == nil then
		return
	end
	local score = math.floor( result.FinalScore )
	local rank, color = BoonAdvisor.RankFor( score )
	button.BoonAdvisorKeepsakeScore = score
	button.BoonAdvisorKeepsakeTrait = traitName
	button.BoonAdvisorKeepsakeRank = rank
	button.BoonAdvisorKeepsakeColor = color
	button.BoonAdvisorKeepsakeReason = BoonAdvisor.KeepsakeGuidance(
		traitName, result, evaluation )
	button.BoonAdvisorKeepsakeIsBest = result.IsBest

	local layout = config.Keepsakes.Layout
	local textId = button.Id
	if CreateScreenComponent ~= nil then
		local badgeKey = buttonKey .. "BoonAdvisorRank"
		components[badgeKey] = CreateScreenComponent({
			Name = "BlankObstacle",
			X = ( args.X or 0 ) + layout.RankOffsetX,
			Y = ( args.Y or 0 ) + layout.RankOffsetY,
			Group = "Combat_Menu_TraitTray",
		})
		if components[badgeKey] ~= nil and components[badgeKey].Id ~= nil then
			textId = components[badgeKey].Id
		end
	end
	CreateTextBox({
		Id = textId,
		Text = "{$TempTextData.BALine}",
		LuaKey = "TempTextData",
		LuaValue = { BALine = ( result.IsBest and config.Keepsakes.BestMarker or "" ) .. rank },
		FontSize = layout.RankFontSize,
		OffsetX = textId == button.Id and layout.RankOffsetX or 0,
		OffsetY = textId == button.Id and layout.RankOffsetY or 0,
		Color = color,
		Font = "AlegreyaSansSCBold",
		Justification = "Center",
		Width = layout.TextWidth,
		ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
		OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
	})
end
