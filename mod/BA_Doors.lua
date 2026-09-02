--[[
	BoonAdvisor - door reward advisor.

	Scores the reward behind each exit door and prints a compact rank above it,
	so the choice is made before you walk through.

	This hooks CreateDoorRewardPreview, which the game calls once per exit door
	when the room is cleared. Advisor text uses its own attached anchor so it can
	be safely replaced after rerolls without touching vanilla text or graphics.

	Boon doors are scored by running the *same* synergy engine the boon screen
	uses over every eligible boon that god could offer, then calculating the
	expected best result from the number of visible choices. That means a door
	does not pretend the best boon in the god's entire pool is guaranteed.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local function safeNumberCall( default, fn, ... )
	if fn == nil then return default end
	local success, value = pcall( fn, ... )
	if success and type( value ) == "number" then return value end
	return default
end

local function hasRunProgressUpgrade( name )
	if GameState == nil then return false end
	return ( GameState.Cosmetics ~= nil and GameState.Cosmetics[name] )
		or ( GameState.CosmeticsAdded ~= nil and GameState.CosmeticsAdded[name] )
		or false
end

local olympianLootNames =
{
	ZeusUpgrade = true,
	PoseidonUpgrade = true,
	AthenaUpgrade = true,
	AphroditeUpgrade = true,
	AresUpgrade = true,
	ArtemisUpgrade = true,
	DionysusUpgrade = true,
	DemeterUpgrade = true,
}

local function normalizeGodName( god )
	if type( god ) ~= "string" then return nil end
	if olympianLootNames[god] then return god end
	local lootName = god .. "Upgrade"
	if olympianLootNames[lootName] then return lootName end
	return nil
end

function BoonAdvisor.GodForTrait( traitName )
	if BoonAdvisor.TraitGodIndex == nil then
		BoonAdvisor.TraitGodIndex = {}
		local linkedOwners = {}
		for lootName, _ in pairs( olympianLootNames ) do
			local loot = LootData[lootName]
			for _, list in ipairs({ loot ~= nil and loot.WeaponUpgrades or nil,
				loot ~= nil and loot.Traits or nil }) do
				for _, name in ipairs( type( list ) == "table" and list or {} ) do
					BoonAdvisor.TraitGodIndex[name] = lootName
				end
			end
			for name, _ in pairs( loot ~= nil and loot.LinkedUpgrades or {} ) do
				linkedOwners[name] = linkedOwners[name] or {}
				linkedOwners[name][lootName] = true
			end
		end
		for name, owners in pairs( linkedOwners ) do
			if BoonAdvisor.TraitGodIndex[name] == nil and TableLength( owners ) == 1 then
				BoonAdvisor.TraitGodIndex[name] = next( owners )
			end
		end
	end
	return BoonAdvisor.TraitGodIndex[traitName]
end

local function totalTraitValue( name, default, args )
	return safeNumberCall( default, GetTotalHeroTraitValue, name, args )
end

local function roomRewardOverride( room, rewardName, key )
	if room == nil then return nil end
	local overrides = room.RewardConsumableOverrides or room.RewardOverrides
	if type( overrides ) ~= "table" then return nil end
	if type( overrides.ValidRewardNames ) == "table"
		and not Contains( overrides.ValidRewardNames, rewardName ) then
		return nil
	end
	return overrides[key]
end

function BoonAdvisor.CreateWorldTextAnchor( ownerId )
	if ownerId == nil then
		return nil, false
	end
	if SpawnObstacle == nil then
		return ownerId, false
	end

	local anchorId = SpawnObstacle({
		Name = "BlankObstacle",
		Group = "Standing",
		DestinationId = ownerId,
	})
	if anchorId == nil or anchorId == 0 then
		return ownerId, false
	end
	if Attach ~= nil then
		Attach({ Id = anchorId, DestinationId = ownerId })
	end
	if SetThingProperty ~= nil then
		SetThingProperty({ Property = "SortMode", Value = "FromParent", DestinationId = anchorId })
	end
	return anchorId, true
end

function BoonAdvisor.ClearWorldTextAnchor( owner, idKey, ownedKey )
	if owner == nil then
		return
	end
	if owner[ownedKey] and owner[idKey] ~= nil and Destroy ~= nil then
		Destroy({ Id = owner[idKey] })
	end
	owner[idKey] = nil
	owner[ownedKey] = nil
end

--[[
	Every boon this god could still offer us.

	Eligibility is delegated to the game's own IsGameStateEligible rather than
	reimplemented. TraitData gates offers on around thirty different fields --
	242 RequiredWeapon rules alone, plus RequiredTrait, RequiredGodLoot,
	RequiredBiome, RequiredMaxHealthFraction, RequiredMaxLastStands,
	RequiredMinCompletedRuns, RequiredFalseTraits and more. Listing every boon a
	god owns and ignoring all of that produced claims like "this door leads to
	Sea Storm" for boons the run could not actually be offered.

	One call gets every rule right, and stays right if the game changes.
]]
function BoonAdvisor.GetGodCandidateTraits( lootName, args )
	args = args or {}
	local lootInfo = LootData[lootName]
	local candidates = {}
	local seen = {}
	if lootInfo == nil then
		return candidates
	end

	local function addCandidate( traitName )
		if traitName == nil or seen[traitName] or HeroHasTrait( traitName ) then
			return
		end
		if args.ExcludeDuo and BoonAdvisor.KindOf( traitName ) == "Duo" then
			return
		end
		local traitData = TraitData[traitName]
		local eligible = traitData ~= nil
		if eligible and IsGameStateEligible ~= nil then
			eligible = IsGameStateEligible( CurrentRun, traitData )
		end
		if eligible then
			seen[traitName] = true
			table.insert( candidates, traitName )
		end
	end

	local weaponUpgrades = lootInfo.WeaponUpgrades
	if type( weaponUpgrades ) == "table" then
		if GetEligibleWeaponTraits ~= nil and args.IgnoreOccupiedTrait == nil then
			weaponUpgrades = GetEligibleWeaponTraits( weaponUpgrades )
		end
		for _, traitName in ipairs( weaponUpgrades ) do
			local slot = TraitData[traitName] ~= nil and TraitData[traitName].Slot or nil
			if ( GetEligibleWeaponTraits ~= nil and args.IgnoreOccupiedTrait == nil )
				or slot == nil
				or not BoonAdvisor.SlotFilled( slot, args.IgnoreOccupiedTrait ) then
				addCandidate( traitName )
			end
		end
	end
	if type( lootInfo.Traits ) == "table" then
		for _, traitName in ipairs( lootInfo.Traits ) do
			addCandidate( traitName )
		end
	end

	-- UpgradeChoice.GetEligibleTraitUpgrades appends linked upgrades only when
	-- their OneOf / OneFromEachSet dependency is currently satisfied.
	if type( lootInfo.LinkedUpgrades ) == "table" then
		for traitName, requirement in pairs( lootInfo.LinkedUpgrades ) do
			if BoonAdvisor.LinkedRequirementMet( requirement ) then
				addCandidate( traitName )
			end
		end
	end
	return candidates
end

-- A god door offers K random choices, where Approval Process can reduce K.
-- Score every currently eligible boon with the normal engine, then value the
-- door as the expected best of those K draws rather than the single best boon
-- in the entire pool.
function BoonAdvisor.ScoreGodDoor( lootName, args )
	args = args or {}
	local doors = BoonAdvisor.Config.Doors
	local candidates = BoonAdvisor.GetGodCandidateTraits( lootName, args )
	if IsEmpty( candidates ) then
		return doors.BoonBase, "no eligible boons found"
	end

	local values = {}
	local bestName, bestResult = nil, nil
	local hasLegendaryCandidate = false
	for _, traitName in ipairs( candidates ) do
		local result = BoonAdvisor.ScoreOption(
			{ ItemName = traitName, Rarity = "Common", Type = "Trait" },
			{ Name = lootName } )
		table.insert( values, result.RawScore )
		if bestResult == nil or result.RawScore > bestResult.RawScore then
			bestName = traitName
			bestResult = result
		end
		local kind = BoonAdvisor.KindOf( traitName )
		if kind == "Duo" or kind == "Legendary" then
			hasLegendaryCandidate = true
		end
	end

	local k = 3
	if CalcNumLootChoices ~= nil then
		k = CalcNumLootChoices() or k
	elseif GetNumMetaUpgrades ~= nil then
		k = k - ( GetNumMetaUpgrades( "ReducedLootChoicesShrineUpgrade" ) or 0 )
	end
	if k < 1 then k = 1 end
	if k > TableLength( values ) then k = TableLength( values ) end

	local score = nil
	if BoonAdvisor.ForecastInitialOffer ~= nil and LootData[lootName] ~= nil then
		local template = {}
		for key, value in pairs( LootData[lootName] ) do template[key] = value end
		template.Name = lootName
		template.RarityChances = BoonAdvisor.RarityRollChances( lootName, args.Room )
		local contextKey = args.Room ~= nil and args.Room.Name or nil
		local forecast = BoonAdvisor.ForecastInitialOffer( template, contextKey,
			{ ExcludeDuo = args.ExcludeDuo, YieldWork = args.YieldWork } )
		if forecast ~= nil then score = forecast.ExpectedScore end
	end
	local forecasted = score ~= nil
	if score == nil then score = BoonAdvisor.ExpectedBestOfK( values, k ) end
	local reason
	if BoonAdvisor.KindOf( bestName ) ~= nil then
		reason = "can offer " .. BoonAdvisor.TraitDisplayName( bestName )
	elseif TableLength( values ) > k then
		reason = k .. " of " .. TableLength( values ) .. ", best: "
			.. BoonAdvisor.TraitDisplayName( bestName )
	else
		reason = bestResult.Reason
	end

	--[[
		Expected rarity, computed from the game's own inputs: base chances,
		room overrides, the four rarity Mirror talents, and every RarityBonus
		trait gated on this god (which is how a keepsake lifts its own god).
		This supersedes the flat keepsake/boost guesses that were here before.
	]]
	if not forecasted then
		score = score + BoonAdvisor.ExpectedRarityBonus(
			lootName, hasLegendaryCandidate, args.Room )
	end

	local god = normalizeGodName( lootName )
	if god ~= nil then
		local ownedGods = {}
		for _, trait in pairs( CurrentRun ~= nil and CurrentRun.Hero ~= nil
			and CurrentRun.Hero.Traits or {} ) do
			local traitGod = normalizeGodName( trait.God )
				or BoonAdvisor.GodForTrait( trait.Name )
			if traitGod ~= nil then ownedGods[traitGod] = true end
		end
		if not ownedGods[god] then
			local count = TableLength( ownedGods )
			if count >= doors.GodPoolSoftCap then
				local penalty = math.min( doors.GodPoolPenaltyCap,
					( count - doors.GodPoolSoftCap + 1 ) * doors.GodPoolPenaltyPerGod )
				score = score - penalty
				reason = "widens an already full god pool"
			end
		end
	end

	return score, reason
end

function BoonAdvisor.ScoreMaxHealthDoor( room )
	local amount = 25
	if ConsumableData ~= nil and ConsumableData.RoomRewardMaxHealthDrop ~= nil
		and type( ConsumableData.RoomRewardMaxHealthDrop.AddMaxHealth ) == "number" then
		amount = ConsumableData.RoomRewardMaxHealthDrop.AddMaxHealth
	end
	local override = roomRewardOverride(
		room, "RoomRewardMaxHealthDrop", "AddMaxHealth" )
	if type( override ) == "number" then amount = override end
	amount = math.floor( amount * totalTraitValue(
		"HealthRewardBonus", 1, { IsMultiplier = true } ) + 0.5 )
	local doors = BoonAdvisor.Config.Doors
	local bonusAmount = math.max( 0, amount - 25 )
	local score = doors.MaxHealthBase + bonusAmount * doors.MaxHealthBonusPointWeight
	local record = CurrentRun ~= nil and CurrentRun.ConsumableRecord or nil
	local hearts = record ~= nil and ( record.RoomRewardMaxHealthDrop or 0 ) or 0
	if hearts > doors.HeartDiminishAfter then
		score = score - ( hearts - doors.HeartDiminishAfter )
			* doors.HeartDiminishPerPickup
	end
	local depth = GetRunDepth ~= nil and CurrentRun ~= nil
		and ( GetRunDepth( CurrentRun ) or 0 )
		or ( CurrentRun ~= nil and CurrentRun.RunDepthCache or 0 )
	if depth >= 32 then score = score - doors.HeartLateRunPenalty end
	local pact = BoonAdvisor.Config.Pact or {}
	if BoonAdvisor.DangerLevel ~= nil then
		score = score + math.min( pact.MaxHealthBonusCap or 0,
			BoonAdvisor.DangerLevel() * ( pact.MaxHealthBonusPerDanger or 0 ) )
	end
	local reason = "+" .. amount .. " max health"
	if depth >= 32 then reason = reason .. "; late in the run" end
	return score, reason
end

-- Pure healing from Charon's stock. Centaur Heart doors use the permanent
-- max-health scorer above and must not be devalued merely because HP is full.
function BoonAdvisor.ScoreHealthDoor()
	local doors = BoonAdvisor.Config.Doors
	local healingMultiplier = BoonAdvisor.HealingMultiplier ~= nil
		and BoonAdvisor.HealingMultiplier() or 1
	if healingMultiplier <= 0 then
		return 1, "restores 0 health at this Heat"
	end
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	if hero == nil or hero.MaxHealth == nil or hero.MaxHealth <= 0 then
		return doors.HealthBase * healingMultiplier, "restores health"
	end

	local missingFraction = 1.0 - ( ( hero.Health or hero.MaxHealth ) / hero.MaxHealth )
	if missingFraction < 0 then missingFraction = 0 end
	if missingFraction > 1 then missingFraction = 1 end

	local score = doors.HealthBase + ( doors.HealthUrgency * missingFraction )

	-- Healing is scarcer and hits land harder deeper in a run.
	if GetRunDepth ~= nil and CurrentRun ~= nil then
		local depth = GetRunDepth( CurrentRun ) or 0
		local depthFraction = depth / doors.DepthReference
		if depthFraction > 1 then depthFraction = 1 end
		score = score + ( doors.HealthDepthBonus * depthFraction )
	end

	-- Danger raises the value of every point restored, but cannot make a heal
	-- valuable after Lasting Consequences has reduced that restoration to zero.
	score = score + ( doors.DangerHealthBonus * BoonAdvisor.DangerLevel() )
	score = score * healingMultiplier

	local percent = math.floor( missingFraction * 100 + 0.5 )

	local reason
	if healingMultiplier < 1 then
		local effective = math.floor( healingMultiplier * 100 + 0.5 )
		reason = effective .. "% healing; down " .. percent .. "% health"
		return score, reason
	elseif healingMultiplier > 1 then
		local effective = math.floor( healingMultiplier * 100 + 0.5 )
		reason = effective .. "% healing; down " .. percent .. "% health"
		return score, reason
	end
	if percent >= 50 then
		reason = "you are down " .. percent .. "% health"
	elseif percent >= 20 then
		reason = "down " .. percent .. "% health"
	else
		reason = "near full health"
	end
	return score, reason
end

-- A hammer offers a random subset of the upgrades currently legal for this
-- weapon/aspect. Value that actual pool instead of applying a flat penalty
-- merely because the run already holds one hammer.
function BoonAdvisor.ScoreHammerDoor()
	local doors = BoonAdvisor.Config.Doors
	local hammerLoot = LootData ~= nil and LootData.WeaponUpgrade or nil
	if hammerLoot == nil or type( hammerLoot.Traits ) ~= "table" then
		return doors.HammerBase, "Daedalus Hammer"
	end

	-- Vanilla GetEligibleWeaponTraits (UpgradeChoice.lua:696) also removes
	-- hammers whose slot is occupied by a god boon of the same slot; a door
	-- forecast over hammers the game cannot offer overstates the door.
	local occupiedSlots = {}
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		if trait.God ~= nil and trait.Slot ~= nil then
			occupiedSlots[trait.Slot] = true
		end
	end

	local values = {}
	local bestName, bestValue = nil, nil
	for _, traitName in pairs( hammerLoot.Traits ) do
		local slot = TraitData ~= nil and TraitData[traitName] ~= nil
			and TraitData[traitName].Slot or nil
		local eligible = not HeroHasTrait( traitName )
			and ( slot == nil or not occupiedSlots[slot] )
			and ( IsGameStateEligible == nil
				or IsGameStateEligible( CurrentRun, TraitData[traitName] ) )
		if eligible then
			local result = BoonAdvisor.ScoreOption(
				{ ItemName = traitName, Type = "Trait", Rarity = "Common" },
				{ Name = "WeaponUpgrade" } )
			table.insert( values, result.RawScore )
			if bestValue == nil or result.RawScore > bestValue then
				bestName = traitName
				bestValue = result.RawScore
			end
		end
	end
	if IsEmpty( values ) then
		return doors.HammerBase, "no eligible hammers found"
	end

	local k = CalcNumLootChoices ~= nil and ( CalcNumLootChoices() or 3 ) or 3
	if k < 1 then k = 1 end
	if k > TableLength( values ) then k = TableLength( values ) end
	local score = BoonAdvisor.ExpectedBestOfK( values, k )
	local reason = k .. " of " .. TableLength( values ) .. ", best: "
		.. BoonAdvisor.TraitDisplayName( bestName )
	return score, reason
end

--[[
	A Pom door.

	IMPORTANT: a Pom does NOT let you level whatever you like. The screen
	offers a RANDOM subset of the boons you already hold and you pick one of
	those. From the game's own code:

	  GetEligibleUpgrades -> if lootData.StackOnly then
	      GetAllUpgradeableGodTraits()        -- every non-temporary god boon
	  CalcNumLootChoices() = 3 - ReducedLootChoicesShrineUpgrade

	So the honest valuation is the EXPECTED BEST OF K RANDOM DRAWS from your
	upgradeable boons, not the best one you own. Scoring it as the maximum --
	as an earlier version did -- systematically overrated every Pom door,
	because it assumed an option that may well not be offered.

	For values sorted high to low, the probability that v[i] is the best in a
	sample of k drawn from n without replacement is C(n-i, k-1) / C(n, k).
]]
local function choose( n, k )
	if k < 0 or k > n then
		return 0
	end
	local result = 1
	for i = 1, k do
		result = result * ( n - k + i ) / i
	end
	return result
end

function BoonAdvisor.ExpectedBestOfK( values, k )
	if values == nil or IsEmpty( values ) then
		return 0
	end
	table.sort( values, function( a, b ) return a > b end )
	local n = TableLength( values )
	if k > n then k = n end
	if k < 1 then k = 1 end

	local total = choose( n, k )
	if total <= 0 then
		return values[1]
	end
	local expected = 0
	for i = 1, n do
		local ways = choose( n - i, k - 1 )
		if ways > 0 then
			expected = expected + values[i] * ( ways / total )
		end
	end
	return expected
end

function BoonAdvisor.ScorePomDoor( room )
	local doors = BoonAdvisor.Config.Doors
	if CurrentRun == nil or CurrentRun.Hero == nil then
		return doors.Types.StackUpgrade, "pom of power"
	end

	local stackData = LootData ~= nil and LootData.StackUpgrade or nil
	local candidates = BoonAdvisor.GetPomCandidates( stackData )

	if IsEmpty( candidates ) then
		return doors.Types.StackUpgrade, "nothing to level yet"
	end

	local values = {}
	local bestValue, bestName = nil, nil
	local stackNum = room ~= nil and room.StackNumOverride or 1
	if type( stackNum ) ~= "number" or stackNum < 1 then stackNum = 1 end
	local pomLoot = { Name = "StackUpgrade", StackNum = stackNum }
	for _, traitName in ipairs( candidates ) do
		local value = BoonAdvisor.ScorePom( traitName, pomLoot )
		table.insert( values, value )
		if bestValue == nil or value > bestValue then
			bestValue = value
			bestName = traitName
		end
	end
	local n = TableLength( values )
	local k = 3
	if CalcNumLootChoices ~= nil then
		k = CalcNumLootChoices() or 3
	end
	if k > n then k = n end
	if k < 1 then k = 1 end

	local expected = BoonAdvisor.ExpectedBestOfK( values, k )

	--[[
		Report the best target so the note is useful, but say plainly that it
		is not guaranteed to be offered -- otherwise "levels Divine Dash" reads
		as a promise the game does not make.
	]]
	local reason
	if n <= k then
		reason = ( stackNum > 1 and ( "+" .. stackNum .. " levels: " ) or "levels " )
			.. BoonAdvisor.TraitDisplayName( bestName )
	else
		reason = k .. " of your " .. n .. " boons, best: "
			.. BoonAdvisor.TraitDisplayName( bestName )
	end

	return expected, reason
end

--[[
	Trial of the Gods (reward type "Devotion"). It grants TWO boons.

	Traced through the code, the sequence is:

	  1. StartDevotionTest (RoomEvents.lua:1669) spawns two boons from two gods
	     and waits on the boon menu -- you take ONE.
	  2. The refused god arms the enemies for that encounter:
	     AddEnemyUpgrade( alternateLootData.Name ), sometimes plus a room weapon.
	  3. On clearing, the room reward is (RoomEvents.lua:1469):
	         GiveLoot({ ForceLootName = currentEncounter.SpurnedGodName,
	                    ExchangeOnlyFromLootName = currentEncounter.ChosenGodName })
	     -- a second, ordinary boon offer from the god you refused.

	ExchangeOnlyFromLootName looks like it would restrict that to swaps, but it
	is only ever assigned (RoomManager.lua:2845) and never read anywhere in the
	scripts, so it has no effect: the end reward is a normal boon.

	Two boons for one room is well above an ordinary boon door. The price is a
	harder fight, so the value still falls as health falls.
]]
function BoonAdvisor.ScoreDevotionDoor( room, refreshArgs )
	local doors = BoonAdvisor.Config.Doors
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil

	local missing = 0
	if hero ~= nil and hero.MaxHealth ~= nil and hero.MaxHealth > 0 then
		missing = 1 - ( ( hero.Health or hero.MaxHealth ) / hero.MaxHealth )
		if missing < 0 then missing = 0 end
		if missing > 1 then missing = 1 end
	end

	--[[
		Death Defiances offset the risk. ExtraChanceMetaUpgrade buys these, and
		a dangerous encounter at low health is a very different proposition
		with two spare lives than with none, so the health penalty is reduced
		per Defiance held rather than treating every run as equally fragile.
	]]
	local defiances = BoonAdvisor.LastStandsRemaining()
	-- RiskTolerance already accounts for every remaining Death Defiance. Do
	-- not apply a second relief multiplier here.
	local minimumRisk = ( BoonAdvisor.Config.Pact or {} ).DevotionMinimumRisk or 0
	local pactRisk = BoonAdvisor.PactRiskMultiplier ~= nil
		and BoonAdvisor.PactRiskMultiplier() or 1
	-- The Trial's extra danger should not devalue it on a zero-Heat run. Once
	-- the Pact makes encounters harsher, retain a small risk floor even at full
	-- health rather than pretending the fight is free.
	local exposure = missing
	if pactRisk > 1 then
		exposure = math.max( minimumRisk, exposure )
	end
	local risk = doors.DevotionRisk * exposure
		* ( 1 - BoonAdvisor.RiskTolerance() )
		* BoonAdvisor.ObjectiveRiskMultiplier() * pactRisk

	local score = doors.DevotionBase
	local encounter = room ~= nil and room.Encounter or nil
	local lootA = encounter ~= nil and encounter.LootAName or nil
	local lootB = encounter ~= nil and encounter.LootBName or nil
	local knownGods = lootA ~= nil and lootB ~= nil and LootData ~= nil
		and LootData[lootA] ~= nil
		and LootData[lootB] ~= nil and lootA ~= lootB
	if knownGods then
		local args = { Room = room, ExcludeDuo = true,
			YieldWork = refreshArgs ~= nil and refreshArgs.YieldWork or nil }
		local scoreA = BoonAdvisor.ScoreGodDoor( lootA, args )
		local scoreB = BoonAdvisor.ScoreGodDoor( lootB, args )
		local best = math.max( scoreA, scoreB )
		local second = math.min( scoreA, scoreB )
		score = best + second * ( doors.DevotionSecondBoonWeight or 0.42 )
	end
	score = score - risk

	local reason = "2 boons: 1 now, 1 from the god you refuse"
	if knownGods then
		local godA = tostring( lootA ):gsub( "Upgrade$", "" )
		local godB = tostring( lootB ):gsub( "Upgrade$", "" )
		reason = "2 boons: " .. godA .. " + " .. godB
		if missing >= 0.45 and defiances == 0 then
			reason = godA .. " + " .. godB .. "; risky, no Death Defiance"
		elseif missing >= 0.45 then
			reason = godA .. " + " .. godB .. "; risky fight"
		end
	elseif missing >= 0.45 and defiances == 0 then
		reason = "2 boons, but risky with no Death Defiance"
	elseif missing >= 0.45 then
		reason = "2 boons, enemies gain the one you refuse"
	end
	return score, reason
end

local function shopPriceMultiplier()
	local multiplier = 1
	if GetNumMetaUpgrades ~= nil and MetaUpgradeData ~= nil
		and MetaUpgradeData.ShopPricesShrineUpgrade ~= nil then
		local ranks = GetNumMetaUpgrades( "ShopPricesShrineUpgrade" ) or 0
		local change = MetaUpgradeData.ShopPricesShrineUpgrade.ChangeValue or 1
		multiplier = multiplier * ( 1 + ranks * ( change - 1 ) )
	end
	return multiplier * totalTraitValue(
		"StoreCostMultiplier", 1, { IsMultiplier = true } )
end

function BoonAdvisor.ScoreShopDoor()
	local doors = BoonAdvisor.Config.Doors
	local money = CurrentRun ~= nil and ( CurrentRun.Money or 0 ) or 0
	local multiplier = shopPriceMultiplier()
	for _, tier in ipairs( doors.ShopDoorScores ) do
		local threshold = math.floor( tier.MinMoney * multiplier + 0.5 )
		if money >= threshold then
			return tier.Score, money .. " Obols; " .. tier.Reason
		end
	end
	return doors.Types.Shop, money .. " Obols"
end

function BoonAdvisor.ScoreMoneyDoor( room )
	local doors = BoonAdvisor.Config.Doors
	if HasHeroTraitValue ~= nil and HasHeroTraitValue( "BlockMoney" ) then
		return 20, "Chaos curse blocks gold"
	end

	local amount = 100
	if ConsumableData ~= nil and ConsumableData.RoomRewardMoneyDrop ~= nil
		and type( ConsumableData.RoomRewardMoneyDrop.DropMoney ) == "number" then
		amount = ConsumableData.RoomRewardMoneyDrop.DropMoney
	end
	local override = roomRewardOverride(
		room, "RoomRewardMoneyDrop", "DropMoney" )
	if type( override ) == "number" then amount = override end
	local moneyMultiplier = totalTraitValue(
		"MoneyMultiplier", 1, { IsMultiplier = true } )
	local rewardMultiplier = totalTraitValue(
		"MoneyRewardBonus", 1, { IsMultiplier = true } )
	amount = math.floor( amount * ( 1 + ( moneyMultiplier - 1 )
		+ ( rewardMultiplier - 1 ) ) + 0.5 )

	local money = CurrentRun ~= nil and ( CurrentRun.Money or 0 ) or 0
	local need = 1 - math.min( 1, money / doors.MoneyTarget )
	local score = doors.MoneyBase + doors.MoneyLowBonus * need
	local depth = GetRunDepth ~= nil and CurrentRun ~= nil
		and ( GetRunDepth( CurrentRun ) or 0 )
		or ( CurrentRun ~= nil and CurrentRun.RunDepthCache or 0 )
	local latePenalty = 0
	if depth >= doors.MoneyLateDepth then
		latePenalty = doors.MoneyLatePenalty * ( 1 - need )
		score = score - latePenalty
	end
	local reason = "+" .. amount .. " Obols; " .. money .. " now"
	if latePenalty > 0 then reason = reason .. "; fewer shops remain" end
	return score, reason
end

function BoonAdvisor.ScoreGemDoor()
	local doors = BoonAdvisor.Config.Doors
	local score = doors.Types.Gems
	local reasons = { "gems" }
	if hasRunProgressUpgrade( "GemDropRunProgress" )
		and not ( HasHeroTraitValue ~= nil and HasHeroTraitValue( "BlockMoney" ) ) then
		local moneyMultiplier = totalTraitValue(
			"MoneyMultiplier", 1, { IsMultiplier = true } )
		local rewardMultiplier = totalTraitValue(
			"MoneyRewardBonus", 1, { IsMultiplier = true } )
		local amount = math.floor( 20 * ( 1 + ( moneyMultiplier - 1 )
			+ ( rewardMultiplier - 1 ) ) + 0.5 )
		score = score + amount * doors.ResourceMoneyPointWeight
		table.insert( reasons, "+" .. amount .. " Obols" )
	end
	return score, table.concat( reasons, ", " )
end

local function averagePomValue()
	local candidates = BoonAdvisor.GetPomCandidates(
		LootData ~= nil and LootData.StackUpgrade or nil )
	if IsEmpty( candidates ) then return nil end
	local total = 0
	for _, traitName in ipairs( candidates ) do
		total = total + BoonAdvisor.ScorePom( traitName, nil )
	end
	return total / TableLength( candidates )
end

function BoonAdvisor.ScoreGiftDoor()
	local doors = BoonAdvisor.Config.Doors
	local score = doors.Types.Gift
	local reasons = { "nectar" }

	if hasRunProgressUpgrade( "GiftDropRunProgress" ) then
		local pomValue = averagePomValue()
		if pomValue ~= nil then
			score = score + pomValue * doors.NectarPomValueScale
			table.insert( reasons, "+1 random boon level" )
		end
	end

	local maxHealth = totalTraitValue( "GiftPointHealthMultiplier", 0 )
	if maxHealth > 0 then
		score = score + maxHealth * doors.MaxHealthBonusPointWeight
		table.insert( reasons, "+" .. math.floor( maxHealth + 0.5 ) .. " max health" )
	end
	return score, table.concat( reasons, ", " )
end

function BoonAdvisor.ScoreLockKeyDoor()
	local doors = BoonAdvisor.Config.Doors
	local score = doors.Types.LockKey
	local grantsReroll = hasRunProgressUpgrade( "LockKeyDropRunProgress" )
	local rerollsActive = IsMetaUpgradeSelected ~= nil
		and ( IsMetaUpgradeSelected( "RerollPanelMetaUpgrade" )
			or IsMetaUpgradeSelected( "RerollMetaUpgrade" ) )
	if grantsReroll and rerollsActive then
		score = score + doors.KeyRerollBonus
		return score, "key + 1 reroll"
	end
	return score, "key"
end

function BoonAdvisor.ScoreDarknessDoor()
	local doors = BoonAdvisor.Config.Doors
	local score = doors.Types.MetaPoints
	local amount = 10
	if ConsumableData ~= nil and ConsumableData.RoomRewardMetaPointDrop ~= nil
		and ConsumableData.RoomRewardMetaPointDrop.AddResources ~= nil
		and type( ConsumableData.RoomRewardMetaPointDrop.AddResources.MetaPoints ) == "number" then
		amount = ConsumableData.RoomRewardMetaPointDrop.AddResources.MetaPoints
	end
	amount = amount * safeNumberCall( 1, CalculateMetaPointMultiplier )
		* totalTraitValue( "MetapointRewardBonus", 1, { IsMultiplier = true } )
	amount = math.floor( amount + 0.5 )

	local reasons = { amount .. " darkness" }
	if GetNumMetaUpgrades ~= nil
		and ( GetNumMetaUpgrades( "MetaPointCapShrineUpgrade" ) or 0 ) > 0 then
		score = score * doors.DarknessCappedFactor
		table.insert( reasons, "capped this run" )
	end

	if hasRunProgressUpgrade( "RoomRewardMetaPointDropRunProgress" ) then
		local maxHealth = math.floor( 5 * totalTraitValue(
			"HealthRewardBonus", 1, { IsMultiplier = true } ) + 0.5 )
		score = score + doors.DarknessMaxHealthBonus
			+ math.max( 0, maxHealth - 5 ) * doors.MaxHealthBonusPointWeight
		table.insert( reasons, "+" .. maxHealth .. " max health" )
	end

	local healMultiplier = totalTraitValue( "MetaPointHealMultiplier", 0 )
	if GetTotalMetaUpgradeChangeValue ~= nil then
		healMultiplier = healMultiplier + math.max( 0,
			safeNumberCall( 1, GetTotalMetaUpgradeChangeValue,
				"DarknessHealMetaUpgrade" ) - 1 )
	end
	if healMultiplier > 0 and CurrentRun ~= nil and CurrentRun.Hero ~= nil then
		healMultiplier = healMultiplier * safeNumberCall( 1, CalculateHealingMultiplier )
			* totalTraitValue( "MaxHealthMultiplier", 1, { IsMultiplier = true } )
		local hero = CurrentRun.Hero
		local missing = math.max( 0, ( hero.MaxHealth or 0 ) - ( hero.Health or 0 ) )
		local healing = math.min( missing, math.floor( amount * healMultiplier + 0.5 ) )
		if healing > 0 and ( hero.MaxHealth or 0 ) > 0 then
			score = score + doors.HealthUrgency * ( healing / hero.MaxHealth )
			table.insert( reasons, "+" .. healing .. " health" )
		end
	end
	return score, table.concat( reasons, ", " )
end

function BoonAdvisor.ScoreStoryDoor( room )
	local roomSet = room ~= nil and room.RoomSetName or nil
	local groupByRoomSet =
	{
		Tartarus = "Sisyphus",
		Asphodel = "Eurydice",
		Elysium = "Patroclus",
	}
	local groupName = groupByRoomSet[roomSet]
	local choices = groupName ~= nil
		and BoonAdvisor.StoryChoiceGroups ~= nil
		and BoonAdvisor.StoryChoiceGroups[groupName] or nil
	if choices == nil or BoonAdvisor.ScoreStoryChoiceRaw == nil then
		return BoonAdvisor.Config.Doors.Types.Story, "story room"
	end
	local bestScore, bestReason = nil, nil
	local bonuses = BoonAdvisor.ObjectiveProfile().StoryBonus or {}
	for _, choiceKey in ipairs( choices ) do
		if BoonAdvisor.StoryChoiceEligible( choiceKey ) then
			local score, reason = BoonAdvisor.ScoreStoryChoiceRaw( choiceKey )
			if score ~= nil then
				score = score + ( bonuses[choiceKey] or 0 )
				if bestScore == nil or score > bestScore then
					bestScore, bestReason = score, reason
				end
			end
		end
	end
	return bestScore or BoonAdvisor.Config.Doors.Types.Story,
		bestReason or "story room"
end

-- Score one door. Returns score, reason.
local function scoreDoorBase( room, refreshArgs )
	local doors = BoonAdvisor.Config.Doors
	local rewardType = room.ChosenRewardType

	if rewardType == nil then
		return BoonAdvisor.ScoreStoryDoor( room )
	end
	if rewardType == "Story" then
		return BoonAdvisor.ScoreStoryDoor( room )
	end

	if rewardType == "Boon" and room.ForceLootName ~= nil then
		return BoonAdvisor.ScoreGodDoor( room.ForceLootName,
			{ Room = room, YieldWork = refreshArgs ~= nil and refreshArgs.YieldWork or nil } )
	end
	if rewardType == "HermesUpgrade" then
		return BoonAdvisor.ScoreGodDoor( "HermesUpgrade",
			{ Room = room, YieldWork = refreshArgs ~= nil and refreshArgs.YieldWork or nil } )
	end
	if rewardType == "Health" then
		return BoonAdvisor.ScoreMaxHealthDoor( room )
	end
	if rewardType == "WeaponUpgrade" then
		return BoonAdvisor.ScoreHammerDoor()
	end
	if rewardType == "StackUpgrade" then
		return BoonAdvisor.ScorePomDoor( room )
	end
	if rewardType == "Devotion" then
		return BoonAdvisor.ScoreDevotionDoor( room, refreshArgs )
	end
	if rewardType == "Shop" then
		return BoonAdvisor.ScoreShopDoor()
	end
	if rewardType == "Money" then
		return BoonAdvisor.ScoreMoneyDoor( room )
	end
	if rewardType == "Gift" then
		return BoonAdvisor.ScoreGiftDoor()
	end
	if rewardType == "LockKey" then
		return BoonAdvisor.ScoreLockKeyDoor()
	end
	if rewardType == "Gems" then
		return BoonAdvisor.ScoreGemDoor()
	end
	if rewardType == "MetaPoints" then
		return BoonAdvisor.ScoreDarknessDoor()
	end

	-- Types entries are plain scores; the label comes from Labels.
	local entry = doors.Types[rewardType]
	if entry == nil then
		entry = doors.Types.Default
	end

	return entry, BoonAdvisor.RewardLabel( rewardType )
end

function BoonAdvisor.ScoreDoor( room, refreshArgs )
	local score, reason = scoreDoorBase( room, refreshArgs )
	local rewardType = room.ChosenRewardType or "Story"
	score = score + BoonAdvisor.ObjectiveDoorBonus( rewardType )
		+ BoonAdvisor.PactDoorBonus( rewardType )

	local timerPressure = BoonAdvisor.TimerPressure ~= nil
		and BoonAdvisor.TimerPressure() or 0
	if timerPressure > 0 then
		if rewardType == "Story" then
			reason = "timer pauses in this story room"
		elseif rewardType == "Shop" then
			reason = reason .. "; no combat"
		elseif rewardType == "Devotion" and timerPressure >= 1 then
			reason = reason .. "; slower under timer"
		end
	end

	local overrides = room.RewardOverrides or room.RewardConsumableOverrides
	if type( overrides ) == "table" and overrides.MakeHardEncounter then
		local baseRisk = ( BoonAdvisor.Config.Pact or {} ).HardEncounterBaseRisk or 0
		local pactRisk = BoonAdvisor.PactRiskMultiplier ~= nil
			and BoonAdvisor.PactRiskMultiplier() or 1
		score = score - baseRisk * pactRisk
	end
	return score, reason
end

function BoonAdvisor.RewardLabel( rewardType )
	return BoonAdvisor.Config.Doors.Labels[rewardType] or tostring( rewardType )
end

---------------------------------------------------------------------------
-- Charon's shop
---------------------------------------------------------------------------

function BoonAdvisor.ScoreBlindBoxLoot()
	local shop = BoonAdvisor.Config.Shop
	local fallback = shop.Items.BlindBoxLoot or shop.ConsumableDefault
	if GetEligibleLootNames == nil then
		return fallback, "random god boon"
	end

	local lootNames = GetEligibleLootNames()
	if IsEmpty( lootNames ) then
		return fallback, "random god boon"
	end

	local total = 0
	local count = 0
	for _, lootName in pairs( lootNames ) do
		if LootData[lootName] ~= nil then
			local score = BoonAdvisor.ScoreGodDoor( lootName )
			total = total + score
			count = count + 1
		end
	end

	if count == 0 then
		return fallback, "random god boon"
	end

	return total / count, "random boon from " .. count .. " eligible gods"
end

-- Shop stock uses the same contextual scoring paths as room rewards.
function BoonAdvisor.ScoreShopItem( itemData )
	local shop = BoonAdvisor.Config.Shop
	local name = itemData.Name or itemData.ItemName

	-- Shop boons store the actual god in Args.ForceLootName.
	if itemData.Type == "Boon" and itemData.Args ~= nil then
		local godLootName = itemData.Args.ForceLootName or itemData.Args.Name
		if godLootName ~= nil then
			return BoonAdvisor.ScoreGodDoor( godLootName )
		end
	end
	if name == "BlindBoxLoot" then
		return BoonAdvisor.ScoreBlindBoxLoot()
	end

	-- Items whose value depends on the run, not on a fixed tier.
	if name == "WeaponUpgradeDrop" or name == "ChaosWeaponUpgrade" then
		return BoonAdvisor.ScoreHammerDoor()
	end
	if name == "StackUpgradeDrop" or name == "StoreRewardRandomStack" then
		return BoonAdvisor.ScorePomDoor()
	end
	if name == "EmptyMaxHealthDrop" then
		return BoonAdvisor.ScoreMaxHealthDoor()
	end
	if name == "DamageSelfDrop" then
		local health = CurrentRun ~= nil and CurrentRun.Hero ~= nil
			and ( CurrentRun.Hero.Health or 0 ) or 0
		local cost = itemData.HealthCost or 30
		if health <= cost then return 1, "not enough health" end
		local fraction = health > 0 and cost / health or 1
		local money = CurrentRun ~= nil and ( CurrentRun.Money or 0 ) or 0
		local moneyNeed = 1 - math.min( 1, money / BoonAdvisor.Config.Doors.MoneyTarget )
		local score = 42 + 10 * moneyNeed - 30 * fraction
			* BoonAdvisor.ObjectiveRiskMultiplier()
		return score, "trades " .. cost .. " health for gold"
	end
	if shop.HealthConsumables[name] then
		return BoonAdvisor.ScoreHealthDoor()
	end
	if shop.HealthTraits[name] then
		return BoonAdvisor.ScoreHealthDoor()
	end

	local wellValue = shop.WellItems[name]
	if wellValue ~= nil then
		local slotByItem =
		{
			TemporaryImprovedWeaponTrait = "Melee",
			TemporaryMoreAmmoTrait = "Ranged",
			TemporaryImprovedRangedTrait = "Ranged",
			TemporaryImprovedSecondaryTrait = "Secondary",
		}
		local slot = slotByItem[name]
		if slot ~= nil then wellValue = wellValue + BoonAdvisor.AspectBonus( slot ) end
		if name == "TemporaryMoveSpeedTrait" and BoonAdvisor.TimerPressure ~= nil then
			wellValue = wellValue + 6 * BoonAdvisor.TimerPressure()
		end
		local timed =
		{
			TemporaryImprovedWeaponTrait = true,
			TemporaryMoreAmmoTrait = true,
			TemporaryImprovedRangedTrait = true,
			TemporaryMoveSpeedTrait = true,
			TemporaryBoonRarityTrait = true,
			TemporaryArmorDamageTrait = true,
			TemporaryAlphaStrikeTrait = true,
			TemporaryBackstabTrait = true,
			TemporaryImprovedSecondaryTrait = true,
			TemporaryImprovedTrapDamageTrait = true,
			TemporaryPreloadSuperGenerationTrait = true,
			TemporaryBlockExplodingChariotsTrait = true,
		}
		local depth = GetRunDepth ~= nil and CurrentRun ~= nil
			and ( GetRunDepth( CurrentRun ) or 0 )
			or ( CurrentRun ~= nil and CurrentRun.RunDepthCache or 0 )
		local reason = "useful for upcoming encounters"
		if timed[name] and depth >= shop.WellLateDepth then
			wellValue = wellValue - shop.WellLatePenalty
			reason = "fewer encounters remain"
		elseif slot ~= nil and BoonAdvisor.AspectBonus( slot ) > 0 then
			reason = "boosts your build's main slot"
		end
		return wellValue, reason
	end

	local entry = shop.Items[name]
	if entry ~= nil then
		return entry, BoonAdvisor.RewardLabel( name )
	end

	-- Unknown stock: say it is unrated rather than inventing a tier for it.
	return shop.ConsumableDefault, "unrated: " .. tostring( name )
end

--[[
	Draw the whole shop at once, after every item has spawned.

	Doing this per item made each one an isolated number, so a shop of ordinary
	stock read as a row of Ds with nothing to choose between. Scoring the set
	together means the best buy can be marked, which is the actual question.
]]
function BoonAdvisor.DrawShopOverlay()
	local config = BoonAdvisor.Config
	if not config.Enabled or not config.Shop.Enabled then
		return
	end

	local items = BoonAdvisor.ShopItems
	if items == nil or IsEmpty( items ) then
		return
	end
	if BoonAdvisor.ShopItemRoom ~= nil
		and ( CurrentRun == nil or BoonAdvisor.ShopItemRoom ~= CurrentRun.CurrentRoom ) then
		return
	end

	local money = CurrentRun ~= nil and CurrentRun.Money or nil
	local bestIndex, bestScore = nil, nil

	for index, item in ipairs( items ) do
		local score, reason = BoonAdvisor.ScoreShopItem( item.ItemData )
		local affordable = true

		-- Price is a tiebreaker, not the headline: an ordinary boon should not
		-- collapse to a D merely because it is priced normally.
		local cost = item.Cost
		if cost ~= nil and cost > 0 and money ~= nil then
			if cost > money then
				affordable = false
				score = score - config.Shop.UnaffordablePenalty
				reason = "need " .. ( cost - money ) .. " more gold"
			else
				score = score - ( config.Shop.CostWeight * ( cost / money ) )
			end
		end

		item.Score = BoonAdvisor.Finalize( score )
		item.Reason = reason
		item.Affordable = affordable

		if affordable and ( bestScore == nil or item.Score > bestScore ) then
			bestScore = item.Score
			bestIndex = index
		end
	end

	local layout = config.Shop.Layout
	for index, item in ipairs( items ) do
		BoonAdvisor.ClearWorldTextAnchor( item, "OverlayAnchorId", "OwnsOverlayAnchor" )
		local anchorId, ownsAnchor = BoonAdvisor.CreateWorldTextAnchor( item.ObjectId )
		item.OverlayAnchorId = anchorId
		item.OwnsOverlayAnchor = ownsAnchor

		local score = math.floor( item.Score )
		local rank, color = BoonAdvisor.RankFor( score )
		local badge = rank .. "  " .. score
		if index == bestIndex then
			badge = "* " .. badge
			color = config.BestPickColor
		end

		CreateTextBox({
			Id = anchorId,
			Text = "{$TempTextData.BALine}",
			LuaKey = "TempTextData",
			LuaValue = { BALine = badge },
			FontSize = layout.RankFontSize,
			OffsetY = layout.RankOffsetY,
			Color = color,
			Font = "AlegreyaSansSCBold",
			Justification = "Center",
			Width = layout.TextWidth,
			ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
			OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
		})

		if config.Shop.ShowReason and BoonAdvisor.ShouldShowReason() and item.Reason ~= nil then
			CreateTextBox({
				Id = anchorId,
				Text = "{$TempTextData.BALine}",
				LuaKey = "TempTextData",
				LuaValue = { BALine = item.Reason },
				FontSize = layout.ReasonFontSize,
				OffsetY = layout.ReasonOffsetY,
				Color = config.ReasonColor,
				Font = "AlegreyaSansSCRegular",
				Justification = "Center",
				Width = layout.TextWidth,
				ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
				OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
			})
		end
	end

end

-- Record one spawned item; drawing happens once the whole shop exists.
function BoonAdvisor.RecordShopItem( itemData )
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	local store = room ~= nil and room.Store or nil
	if store == nil or IsEmpty( store.SpawnedStoreItems ) or itemData == nil then
		return
	end

	local entry = store.SpawnedStoreItems[TableLength( store.SpawnedStoreItems )]
	if entry == nil or entry.ObjectId == nil then
		return
	end

	BoonAdvisor.ShopItems = BoonAdvisor.ShopItems or {}
	BoonAdvisor.ShopItemRoom = room
	for _, item in ipairs( BoonAdvisor.ShopItems ) do
		if item.ObjectId == entry.ObjectId then
			item.Cost = entry.Cost
			item.ItemData = itemData
			return
		end
	end
	table.insert( BoonAdvisor.ShopItems, {
		ObjectId = entry.ObjectId,
		Cost = entry.Cost,
		ItemData = itemData,
	})
end

function BoonAdvisor.RemoveShopItem( objectId )
	if objectId == nil or BoonAdvisor.ShopItems == nil then
		return false
	end
	for index = #BoonAdvisor.ShopItems, 1, -1 do
		local item = BoonAdvisor.ShopItems[index]
		if item.ObjectId == objectId then
			BoonAdvisor.ClearWorldTextAnchor( item, "OverlayAnchorId", "OwnsOverlayAnchor" )
			table.remove( BoonAdvisor.ShopItems, index )
			return true
		end
	end
	return false
end

--[[
	The Chaos gate. It is a SecretDoor obstacle, and ObstacleData.SecretDoor
	sets HideRewardPreview, so vanilla returns before creating DoorIconId --
	which is why the gate had no rank at all. There is nothing to attach to,
	so the text anchors to the door object itself.

	Its reward is always a Chaos boon; what varies is the health it charges,
	which is only meaningful relative to the health you currently have.
]]
function BoonAdvisor.IsChaosGate( exitDoor )
	return exitDoor ~= nil and exitDoor.HealthCost ~= nil
end

function BoonAdvisor.ScoreChaosGate( exitDoor )
	local doors = BoonAdvisor.Config.Doors
	local cost = exitDoor.HealthCost or 0
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	local health = hero ~= nil and hero.Health or nil

	if health == nil or health <= 0 then
		return doors.ChaosGateBase, "costs " .. cost .. " health"
	end

	local fraction = cost / health
	if fraction > 1 then fraction = 1 end
	-- Death Defiances are a buffer, so the health price stings less.
	local risk = ( 1 - BoonAdvisor.RiskTolerance() )
		* BoonAdvisor.ObjectiveRiskMultiplier()
		* ( BoonAdvisor.PactRiskMultiplier ~= nil
			and BoonAdvisor.PactRiskMultiplier() or 1 )
	local score = doors.ChaosGateBase
		+ BoonAdvisor.ExpectedRarityBonus( "TrialUpgrade", false, exitDoor.Room )
		- ( doors.ChaosGateCostWeight * fraction * risk )
	local depth = GetRunDepth ~= nil and CurrentRun ~= nil
		and ( GetRunDepth( CurrentRun ) or 0 )
		or ( CurrentRun ~= nil and CurrentRun.RunDepthCache or 0 )
	if depth <= doors.ChaosEarlyDepth then
		score = score + doors.ChaosEarlyBonus
	elseif depth >= doors.ChaosLateDepth then
		score = score - doors.ChaosLatePenalty
	end
	local untilBoss = BoonAdvisor.EncountersUntilNextBoss ~= nil
		and BoonAdvisor.EncountersUntilNextBoss() or nil
	if untilBoss ~= nil and untilBoss <= doors.ChaosBossProximity then
		score = score - doors.ChaosBossPenalty
	end

	local reason
	if untilBoss ~= nil and untilBoss <= doors.ChaosBossProximity then
		reason = "curse may reach the boss"
	elseif depth >= doors.ChaosLateDepth then
		reason = "less run remains for the Chaos blessing"
	elseif fraction >= 0.4 then
		reason = "costs " .. cost .. " of your " .. math.floor( health ) .. " health"
	else
		reason = "costs " .. cost .. " health"
	end
	return score, reason
end

local function doorRewardSignature( exitDoor )
	local room = exitDoor ~= nil and exitDoor.Room or nil
	local encounter = room ~= nil and room.Encounter or nil
	return table.concat({
		tostring( room ),
		tostring( room ~= nil and room.ChosenRewardType ),
		tostring( room ~= nil and room.ForceLootName ),
		tostring( encounter ~= nil and encounter.LootAName ),
		tostring( encounter ~= nil and encounter.LootBName ),
		tostring( exitDoor ~= nil and exitDoor.HealthCost ),
		tostring( exitDoor ~= nil and exitDoor.ShrinePointReq ),
		tostring( exitDoor ~= nil and exitDoor.Cost ),
	}, "|" )
end

function BoonAdvisor.RegisterDoor( exitDoor )
	if exitDoor == nil or exitDoor.ObjectId == nil then
		return
	end
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	if BoonAdvisor.DoorCandidateRoom ~= room then
		BoonAdvisor.DoorCandidateRoom = room
		BoonAdvisor.DoorCandidates = {}
	end
	BoonAdvisor.DoorCandidates = BoonAdvisor.DoorCandidates or {}
	local signature = doorRewardSignature( exitDoor )
	if BoonAdvisor.DoorCandidates[exitDoor.ObjectId] == exitDoor
		and exitDoor.BoonAdvisorRewardSignature == signature then
		return
	end
	BoonAdvisor.DoorCandidates[exitDoor.ObjectId] = exitDoor
	exitDoor.BoonAdvisorRewardSignature = signature
	-- A newly registered exit changes both the comparison set and the best-door
	-- marker. Cached evaluations are valid only for the previous set. The epoch
	-- also tells any yielding collection in flight to discard its result.
	BoonAdvisor.DoorRegistrationEpoch = ( BoonAdvisor.DoorRegistrationEpoch or 0 ) + 1
	BoonAdvisor.LastDoorEvaluations = nil
	BoonAdvisor.LastBestDoorObjectId = nil
	BoonAdvisor.LastDoorEvaluationRoom = nil
end

function BoonAdvisor.MarkRunStateDirty( args )
	args = args or {}
	if args.BuildChanged and BoonAdvisor.InvalidateForecastCache ~= nil then
		BoonAdvisor.InvalidateForecastCache()
	end
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	if room == nil or BoonAdvisor.DoorCandidateRoom ~= room
		or IsEmpty( BoonAdvisor.DoorCandidates or {} ) then
		return
	end
	BoonAdvisor.DoorContextEpoch = ( BoonAdvisor.DoorContextEpoch or 0 ) + 1
	BoonAdvisor.LastDoorEvaluations = nil
	BoonAdvisor.LastBestDoorObjectId = nil
	BoonAdvisor.LastDoorEvaluationRoom = nil
	BoonAdvisor.QueueDoorOverlayRefresh()
end

function BoonAdvisor.IsDoorAdvisorVisible( exitDoor )
	if exitDoor == nil or exitDoor.Room == nil then
		return false
	end
	if BoonAdvisor.IsChaosGate( exitDoor ) then
		return true
	end
	if exitDoor.HideRewardPreview or exitDoor.Room.HideRewardPreview then
		return false
	end
	if HasHeroTraitValue ~= nil and HasHeroTraitValue( "HiddenRoomReward" ) then
		return false
	end
	return true
end

function BoonAdvisor.ScoreDoorCandidate( exitDoor, refreshArgs )
	if BoonAdvisor.IsChaosGate( exitDoor ) then
		return BoonAdvisor.ScoreChaosGate( exitDoor )
	end
	return BoonAdvisor.ScoreDoor( exitDoor.Room, refreshArgs )
end

function BoonAdvisor.DoorBlockReason( exitDoor )
	if exitDoor == nil then
		return "unavailable"
	end

	local failedRequirement
	if type( CheckSpecialDoorRequirement ) == "function" then
		failedRequirement = CheckSpecialDoorRequirement( exitDoor )
	else
		local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
		if exitDoor.HealthCost ~= nil and hero ~= nil and hero.Health <= exitDoor.HealthCost then
			failedRequirement = "ExitBlockedByHealthReq"
		elseif exitDoor.ShrinePointReq ~= nil and type( GetTotalSpentShrinePoints ) == "function"
			and GetTotalSpentShrinePoints() < exitDoor.ShrinePointReq then
			failedRequirement = "ExitBlockedByShrinePointReq"
		elseif exitDoor.Cost ~= nil and CurrentRun ~= nil and CurrentRun.Money < exitDoor.Cost then
			failedRequirement = "ExitBlockedByMoneyReq"
		end
	end

	if failedRequirement == "ExitBlockedByShrinePointReq" then
		return "requires " .. tostring( exitDoor.ShrinePointReq ) .. " heat"
	elseif failedRequirement == "ExitBlockedByHealthReq" then
		return "needs more than " .. tostring( exitDoor.HealthCost ) .. " health"
	elseif failedRequirement == "ExitBlockedByMoneyReq" then
		return "requires " .. tostring( exitDoor.Cost ) .. " gold"
	elseif failedRequirement ~= nil then
		return "unavailable"
	end

	return nil
end

function BoonAdvisor.CollectDoorEvaluations( refreshArgs )
	local evaluations = {}
	local bestId, bestScore = nil, nil
	-- Snapshot the candidate set before the first yield: RegisterDoor can add
	-- a door (the Chaos gate spawns after the ordinary exits) while this
	-- coroutine is suspended, and inserting a new key into a table that is
	-- being traversed with next() is undefined behavior in Lua. A door added
	-- mid-collection bumps the epoch and queues its own refresh.
	local startRoom = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	local startEpoch = BoonAdvisor.DoorRegistrationEpoch or 0
	local startContextEpoch = BoonAdvisor.DoorContextEpoch or 0
	local snapshot = {}
	for doorId, exitDoor in pairs( BoonAdvisor.DoorCandidates or {} ) do
		table.insert( snapshot, { Id = doorId, Door = exitDoor } )
	end
	for _, entry in ipairs( snapshot ) do
		local doorId, exitDoor = entry.Id, entry.Door
		if BoonAdvisor.IsDoorAdvisorVisible( exitDoor ) then
			local score, reason = BoonAdvisor.ScoreDoorCandidate( exitDoor, refreshArgs )
			local blockReason = BoonAdvisor.DoorBlockReason( exitDoor )
			if score ~= nil then
				evaluations[doorId] = {
					RawScore = score,
					Reason = blockReason or reason,
					BlockReason = blockReason,
				}
				if blockReason == nil and ( bestScore == nil or score > bestScore ) then
					bestScore = score
					bestId = doorId
				end
			end
			if refreshArgs ~= nil and refreshArgs.YieldBetweenDoors and wait ~= nil then
				wait( refreshArgs.YieldDuration or 0.01 )
			end
		end
	end
	-- Publish only when nothing moved while yielded. A collection that ends in
	-- a different room, or after a registration invalidated the cache, must
	-- not overwrite the fresher state with scores for doors that are gone.
	local endRoom = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	local fresh = endRoom == startRoom
		and ( BoonAdvisor.DoorRegistrationEpoch or 0 ) == startEpoch
		and ( BoonAdvisor.DoorContextEpoch or 0 ) == startContextEpoch
	if fresh then
		BoonAdvisor.LastDoorEvaluations = evaluations
		BoonAdvisor.LastBestDoorObjectId = bestId
		BoonAdvisor.LastDoorEvaluationRoom = startRoom
	end
	return evaluations, bestId, fresh
end

function BoonAdvisor.BestDoorObjectId()
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	if BoonAdvisor.LastDoorEvaluations ~= nil
		and BoonAdvisor.LastDoorEvaluationRoom == room then
		return BoonAdvisor.LastBestDoorObjectId
	end
	local _, bestId = BoonAdvisor.CollectDoorEvaluations()
	return bestId
end

function BoonAdvisor.ClearDoorOverlay( exitDoor )
	BoonAdvisor.ClearWorldTextAnchor( exitDoor, "BoonAdvisorAnchorId", "BoonAdvisorOwnsAnchor" )
	exitDoor.BoonAdvisorDrawn = nil
end

function BoonAdvisor.DrawDoorOverlay( exitDoor, bestDoorId, evaluation )
	local config = BoonAdvisor.Config
	if not config.Enabled or not config.Doors.Enabled then
		return
	end
	if exitDoor == nil then
		return
	end
	BoonAdvisor.RegisterDoor( exitDoor )
	BoonAdvisor.ClearDoorOverlay( exitDoor )
	if not BoonAdvisor.IsDoorAdvisorVisible( exitDoor ) then
		return
	end

	local isChaosGate = BoonAdvisor.IsChaosGate( exitDoor )
	local ownerId = exitDoor.DoorIconId
	local offsetShift = 0
	if ownerId == nil then
		if not isChaosGate then
			return
		end
		-- No reward icon (Chaos gate): hang the text off the door itself.
		ownerId = exitDoor.ObjectId
		offsetShift = config.Doors.Layout.NoIconOffsetY
	end
	if ownerId == nil then
		return
	end

	if evaluation == nil then
		local score, reason = BoonAdvisor.ScoreDoorCandidate( exitDoor )
		local blockReason = BoonAdvisor.DoorBlockReason( exitDoor )
		if score ~= nil then
			evaluation = {
				RawScore = score,
				Reason = blockReason or reason,
				BlockReason = blockReason,
			}
		end
	end
	if evaluation == nil then
		return
	end
	local score = evaluation.RawScore
	local reason = evaluation.Reason
	-- Same finalizer as the boon screen, so "A 84" means the same thing here.
	score = math.floor( BoonAdvisor.Finalize( score ) )
	local rank, color = BoonAdvisor.RankFor( score )

	local badge = rank .. "  " .. score
	if bestDoorId == nil then
		bestDoorId = BoonAdvisor.BestDoorObjectId()
	end
	if exitDoor.ObjectId ~= nil and exitDoor.ObjectId == bestDoorId then
		badge = "* " .. badge
		color = config.BestPickColor
	end

	local layout = config.Doors.Layout
	local anchorId, ownsAnchor = BoonAdvisor.CreateWorldTextAnchor( ownerId )
	exitDoor.BoonAdvisorAnchorId = anchorId
	exitDoor.BoonAdvisorOwnsAnchor = ownsAnchor
	CreateTextBox({
		Id = anchorId,
		Text = "{$TempTextData.BALine}",
		LuaKey = "TempTextData",
		LuaValue = { BALine = badge },
		FontSize = layout.RankFontSize,
		OffsetY = layout.RankOffsetY + offsetShift,
		Color = color,
		Font = "AlegreyaSansSCBold",
		Justification = "Center",
		Width = layout.TextWidth,
		ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
		OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
	})

	if config.Doors.ShowReason and BoonAdvisor.ShouldShowReason() and reason ~= nil then
		CreateTextBox({
			Id = anchorId,
			Text = "{$TempTextData.BALine}",
			LuaKey = "TempTextData",
			LuaValue = { BALine = reason },
			FontSize = layout.ReasonFontSize,
			OffsetY = layout.ReasonOffsetY + offsetShift,
			Color = config.ReasonColor,
			Font = "AlegreyaSansSCRegular",
			Justification = "Center",
			Width = layout.TextWidth,
			ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 2 },
			OutlineThickness = 2, OutlineColor = { 0, 0, 0, 1 },
		})
	end
end

function BoonAdvisor.RefreshDoorOverlays( refreshArgs )
	-- Score each exit once. Previously the best-door pass scored every exit and
	-- the drawing pass immediately scored every exit again.
	refreshArgs = refreshArgs or {}
	local workSinceYield = 0
	if refreshArgs.YieldWithinForecasts then
		refreshArgs.YieldWork = function()
			workSinceYield = workSinceYield + 1
			local limit = BoonAdvisor.Config.RerollForecastWorkPerFrame or 256
			if workSinceYield >= limit and wait ~= nil then
				workSinceYield = 0
				wait( refreshArgs.YieldDuration or 0.01 )
			end
		end
	end
	local evaluations, bestDoorId, fresh = BoonAdvisor.CollectDoorEvaluations( refreshArgs )
	if fresh == false then
		-- The run moved on mid-collection; the refresh that superseded this
		-- one draws the current room's doors.
		return
	end
	for doorId, exitDoor in pairs( BoonAdvisor.DoorCandidates or {} ) do
		BoonAdvisor.DrawDoorOverlay( exitDoor, bestDoorId, evaluations[doorId] )
	end
end

function BoonAdvisor.FinishQueuedDoorRefresh( args )
	wait( BoonAdvisor.Config.Doors.RefreshDelay or 0.20 )
	if args == nil or BoonAdvisor.DoorRefreshQueuedRoom ~= args.Room then return end
	if CurrentRun == nil or CurrentRun.CurrentRoom ~= args.Room then
		BoonAdvisor.DoorRefreshQueuedRoom = nil
		return
	end
	local generation = BoonAdvisor.DoorRefreshGeneration or 0
	BoonAdvisor.RefreshDoorOverlays({
		YieldWithinForecasts = true,
		YieldBetweenDoors = true,
		YieldDuration = 0.01,
	})
	if BoonAdvisor.DoorRefreshQueuedRoom ~= args.Room then return end
	if generation ~= ( BoonAdvisor.DoorRefreshGeneration or 0 ) then
		thread( BoonAdvisor.SafeFinishQueuedDoorRefresh, { Room = args.Room } )
		return
	end
	BoonAdvisor.DoorRefreshQueuedRoom = nil
end

function BoonAdvisor.QueueDoorOverlayRefresh()
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	BoonAdvisor.DoorRefreshGeneration = ( BoonAdvisor.DoorRefreshGeneration or 0 ) + 1
	if thread == nil or wait == nil then
		BoonAdvisor.RefreshDoorOverlays()
		return
	end
	if BoonAdvisor.DoorRefreshQueuedRoom == room then return end
	BoonAdvisor.DoorRefreshQueuedRoom = room
	thread( BoonAdvisor.SafeFinishQueuedDoorRefresh, { Room = room } )
end

-- The deferred refresh runs inside a game coroutine, outside every SafeCall
-- on the hook path; an unprotected error here would surface in the engine's
-- scheduler instead of the mod's log.
function BoonAdvisor.SafeFinishQueuedDoorRefresh( args )
	BoonAdvisor.SafeCall( BoonAdvisor.FinishQueuedDoorRefresh, args )
end
