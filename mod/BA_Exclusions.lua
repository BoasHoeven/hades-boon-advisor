--[[
	BoonAdvisor - opportunity cost.

	A boon is only offered if you do NOT already hold the traits listed in its
	RequiredFalseTrait / RequiredFalseTraits (checked by IsGameStateEligible,
	RunManager.lua:3065). TraitData contains ~171 such rules, so taking a boon
	can permanently remove others from your pool for the rest of the run.

	Nothing else in this mod modelled that: it would happily recommend a pick
	that quietly forfeits something better. This file builds the reverse index
	-- "what does taking T lock out?" -- from TraitData at runtime, the same way
	the duo graph is read from LootData, so it stays correct across patches.

	Slot conflicts are deliberately NOT counted as losses. You can only hold one
	Cast boon anyway, so the mutual exclusions between Cast variants are not an
	extra cost; the slot economy already prices that. Only collateral losses --
	a blocked boon in a different slot, or a slotless one -- count here.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.ExclusionIndex = nil

-- Collect the RequiredFalse* entries for one trait, from either location.
local function collectBlockers( traitData, out )
	if type( traitData ) ~= "table" then
		return
	end
	local sources = { traitData, traitData.GameStateRequirements }
	for _, source in ipairs( sources ) do
		if type( source ) == "table" then
			if type( source.RequiredFalseTrait ) == "string" then
				table.insert( out, source.RequiredFalseTrait )
			end
			if type( source.RequiredFalseTraits ) == "table" then
				for _, name in ipairs( source.RequiredFalseTraits ) do
					if type( name ) == "string" then
						table.insert( out, name )
					end
				end
			end
		end
	end
end

--[[
	blocks[T] = { X, ... } -- holding T makes each X ineligible.
]]
function BoonAdvisor.BuildExclusionIndex()
	local blocks = {}

	for traitName, traitData in pairs( TraitData ) do
		local blockers = {}
		collectBlockers( traitData, blockers )
		for _, blockerName in ipairs( blockers ) do
			--[[
				Skip self-references. Several traits list their own name --
				an upgrade guarding against being granted twice -- and reading
				those as a lockout produced nonsense like
				"Hunting Blades locks out Hunting Blades".
			]]
			if blockerName ~= traitName then
				if blocks[blockerName] == nil then
					blocks[blockerName] = {}
				end
				-- De-duplicate: a name can appear in both the top-level list
				-- and GameStateRequirements.
				local alreadyListed = false
				for _, existing in ipairs( blocks[blockerName] ) do
					if existing == traitName then
						alreadyListed = true
						break
					end
				end
				if not alreadyListed then
					table.insert( blocks[blockerName], traitName )
				end
			end
		end
	end

	return blocks
end

function BoonAdvisor.GetExclusionIndex()
	if BoonAdvisor.ExclusionIndex == nil then
		BoonAdvisor.ExclusionIndex = BoonAdvisor.BuildExclusionIndex()
	end
	return BoonAdvisor.ExclusionIndex
end

-- What a blocked boon is worth losing, on the same scale as the ratings.
local function lostValue( traitName )
	local ratings = BoonAdvisor.Ratings
	local base = ratings.Base[traitName]
	if base ~= nil then
		return base
	end
	--[[
		Hammers exclude each other heavily -- 42 of them lock out at least one
		other hammer, and some of those casualties are the best in the weapon's
		pool (Spread Fire blocks Delta Chamber; Flurry Shot blocks Perfect
		Shot). Without this lookup those losses were invisible, because the
		hammer ratings live in their own table.
	]]
	local hammer = ratings.Hammers[traitName]
	if hammer ~= nil then
		return hammer
	end
	local kind = BoonAdvisor.KindOf( traitName )
	if kind ~= nil then
		return ratings.CategoryDefaults[kind] or BoonAdvisor.Config.Weights.DefaultBase
	end
	return nil
end

--[[
	Is this boon something the run could plausibly still get?

	An ungated boon always counts. A gated one (duo/legendary) counts only once
	the run satisfies at least one of its prerequisite sets -- i.e. you are
	actually on track for it. Losing a duo you have made no progress toward is
	not a loss.
]]
function BoonAdvisor.IsReachable( traitName )
	for _, entry in ipairs( BoonAdvisor.GetLinkedIndex() ) do
		if entry.Name == traitName then
			for _, set in ipairs( entry.Sets ) do
				if BoonAdvisor.HeroHasAnyOf( set ) then
					return true
				end
			end
			return false
		end
	end
	-- Not a gated boon: it can be offered on its own merits.
	return true
end

--[[
	Penalty for what taking `candidateName` would lock out.
	Returns penalty (<= 0), reason.
]]
function BoonAdvisor.ExclusionPenalty( candidateName )
	local weights = BoonAdvisor.Config.Weights
	local blocked = BoonAdvisor.GetExclusionIndex()[candidateName]
	if blocked == nil then
		return 0, nil
	end

	local candidateData = TraitData[candidateName]
	local candidateSlot = candidateData ~= nil and candidateData.Slot or nil

	local worstName, worstValue = nil, nil
	local duoBlocked = false

	for _, blockedName in ipairs( blocked ) do
		if not BoonAdvisor.HeroHasTrait( blockedName ) then
			local blockedData = TraitData[blockedName]
			local blockedSlot = blockedData ~= nil and blockedData.Slot or nil

			-- Same-slot exclusions are already priced by the slot economy.
			local collateral = ( blockedSlot == nil or blockedSlot ~= candidateSlot )

			--[[
				Only charge for losing something you could actually have had.

				A gated boon you have made no progress toward was never on the
				table, so forfeiting it costs nothing. Without this, Hades' Aid
				was docked 20 points on a fresh run for "locking out Smoldering
				Air" -- a duo needing both Zeus and Hermes boons that the run
				had no claim on. Same phantom-progress error as crediting duo
				progress on an empty build.
			]]
			if collateral and BoonAdvisor.IsReachable( blockedName ) then
				local value = lostValue( blockedName )
				if value ~= nil and ( worstValue == nil or value > worstValue ) then
					worstValue = value
					worstName = blockedName
					duoBlocked = ( BoonAdvisor.KindOf( blockedName ) == "Duo" )
				end
			end
		end
	end

	if worstName == nil then
		return 0, nil
	end

	--[[
		Only a genuinely good loss is worth mentioning. Below the threshold the
		blocked boon is filler and saying "blocks X" would be noise -- and would
		wrongly discourage picks whose only casualty is something weak.
	]]
	if worstValue < weights.ExclusionMinValue then
		return 0, nil
	end

	local penalty = weights.ExclusionWeight * ( worstValue / 100 )
	if duoBlocked then
		penalty = penalty * weights.ExclusionDuoFactor
	end

	return -penalty, "locks out " .. BoonAdvisor.TraitDisplayName( worstName )
end

---------------------------------------------------------------------------
-- Keepsakes and rarity boosts
---------------------------------------------------------------------------

--[[
	A god keepsake (e.g. ForceZeusBoonTrait) carries ForceBoonName = "<God>Upgrade"
	and a RarityBonus gated on RequiredGod, so while it is equipped that god's
	boons both appear and roll better. Worth steering toward.
]]
function BoonAdvisor.KeepsakeGod()
	if CurrentRun == nil or CurrentRun.Hero == nil then
		return nil
	end
	for _, trait in pairs( CurrentRun.Hero.Traits ) do
		local traitData = TraitData[trait.Name]
		if traitData ~= nil and traitData.ForceBoonName ~= nil then
			return traitData.ForceBoonName
		end
	end
	return nil
end

-- Is a temporary rarity boost active (Chaos gate / shrine effects)?
function BoonAdvisor.HasRarityBoost()
	if HasHeroTraitValue ~= nil and HasHeroTraitValue( "BoonRarityBonus" ) then
		return true
	end
	return BoonAdvisor.HeroHasTrait( "SuperTemporaryBoonRarityTrait" )
end

--[[
	Expected rarity of a god's next offer, computed the way the game computes it
	(RoomManager.lua:2722-2765) rather than approximated:

	    base chances from Hero.BoonData (or HermesData for Hermes)
	  + room BoonRaritiesOverride, if the room sets one
	  + Mirror talents: RareBoonDrop, EpicBoonDrop, EpicHeroicBoon,
	    DuoRarityBoonDrop
	  + every RarityBonus trait whose RequiredGod matches (this is how god
	    keepsakes raise their own god's rarity)

	Returns a score contribution on the same scale as Weights.Rarity, so a god
	who is currently likely to roll Epic is worth more than one who is not.
	This replaces the earlier flat "keepsake +8 / boost +6" guesses.
]]
function BoonAdvisor.RarityRollChances( lootName, roomOverride )
	if CurrentRun == nil or CurrentRun.Hero == nil then
		return { Rare = 0, Epic = 0, Heroic = 0, Legendary = 0 }
	end

	local sourceTable = CurrentRun.Hero.BoonData
	if lootName == "HermesUpgrade" then
		sourceTable = CurrentRun.Hero.HermesData or sourceTable
	end
	if sourceTable == nil then
		return { Rare = 0, Epic = 0, Heroic = 0, Legendary = 0 }
	end

	local rare = sourceTable.RareChance or 0
	local epic = sourceTable.EpicChance or 0
	local heroic = sourceTable.HeroicChance or 0
	local legendary = sourceTable.LegendaryChance or 0

	local room = roomOverride or CurrentRun.CurrentRoom
	if room ~= nil and room.BoonRaritiesOverride ~= nil then
		rare = room.BoonRaritiesOverride.RareChance or rare
		epic = room.BoonRaritiesOverride.EpicChance or epic
		heroic = room.BoonRaritiesOverride.HeroicChance or heroic
		legendary = room.BoonRaritiesOverride.LegendaryChance or legendary
	end

	if GetNumMetaUpgrades ~= nil and MetaUpgradeData ~= nil then
		local function boost( key )
			local data = MetaUpgradeData[key]
			if data == nil or data.ChangeValue == nil then
				return 0
			end
			return GetNumMetaUpgrades( key ) * ( data.ChangeValue - 1 )
		end
		rare = rare + boost( "RareBoonDropMetaUpgrade" )
		epic = epic + boost( "EpicBoonDropMetaUpgrade" ) + boost( "EpicHeroicBoonMetaUpgrade" )
		heroic = heroic + boost( "EpicHeroicBoonMetaUpgrade" )
		legendary = legendary + boost( "DuoRarityBoonDropMetaUpgrade" )
	end

	-- RarityBonus traits, gated on god where they declare one (keepsakes).
	if GetHeroTraitValues ~= nil then
		for _, bonusData in pairs( GetHeroTraitValues( "RarityBonus" ) ) do
			if bonusData.RequiredGod == nil or bonusData.RequiredGod == lootName then
				rare = rare + ( bonusData.RareBonus or 0 )
				epic = epic + ( bonusData.EpicBonus or 0 )
				heroic = heroic + ( bonusData.HeroicBonus or 0 )
				legendary = legendary + ( bonusData.LegendaryBonus or 0 )
			end
		end
	end
	return {
		Rare = rare,
		Epic = epic,
		Heroic = heroic,
		Legendary = legendary,
	}
end

function BoonAdvisor.ExpectedRarityBonus( lootName, includeLegendary, roomOverride )
	local chances = BoonAdvisor.RarityRollChances( lootName, roomOverride )
	local rare = chances.Rare
	local epic = chances.Epic
	local heroic = chances.Heroic
	local legendary = chances.Legendary


	-- SetTraitsOnLoot rolls these in order and stops at the first success:
	-- Legendary, Heroic, Epic, Rare, then Common. Treating every raw chance as
	-- an independent final probability double-counts the same offer.
	local function chance( value )
		if value < 0 then return 0 end
		if value > 1 then return 1 end
		return value
	end
	legendary = includeLegendary and chance( legendary ) or 0
	heroic = chance( heroic )
	epic = chance( epic )
	rare = chance( rare )

	local remaining = 1
	local legendaryProbability = remaining * legendary
	remaining = remaining - legendaryProbability
	local heroicProbability = remaining * heroic
	remaining = remaining - heroicProbability
	local epicProbability = remaining * epic
	remaining = remaining - epicProbability
	local rareProbability = remaining * rare

	local weights = BoonAdvisor.Config.Weights
	local expected = rareProbability * ( weights.Rarity.Rare or 0 )
		+ epicProbability * ( weights.Rarity.Epic or 0 )
		+ heroicProbability * ( weights.Rarity.Heroic or 0 )
		+ legendaryProbability * ( weights.Rarity.Legendary or 0 )

	return expected * BoonAdvisor.Config.Doors.RarityExpectationScale
end

-- Match MetaUpgrades.CalculateHealingMultiplier. Calling the game's function
-- also includes Nourished Soul and any other live healing modifiers; the
-- fallback keeps offline tools and unusual load orders correct for the Pact.
function BoonAdvisor.HealingMultiplier()
	if CalculateHealingMultiplier ~= nil then
		local success, value = pcall( CalculateHealingMultiplier )
		if success and type( value ) == "number" then
			return math.max( 0, value )
		end
	end
	if GetNumMetaUpgrades == nil then return 1 end
	local ranks = GetNumMetaUpgrades( "HealingReductionShrineUpgrade" ) or 0
	local change = 1.25
	if MetaUpgradeData ~= nil
		and MetaUpgradeData.HealingReductionShrineUpgrade ~= nil
		and type( MetaUpgradeData.HealingReductionShrineUpgrade.ChangeValue ) == "number" then
		change = MetaUpgradeData.HealingReductionShrineUpgrade.ChangeValue
	end
	return math.max( 0, 1 - ranks * ( change - 1 ) )
end

function BoonAdvisor.HealingReduced()
	return GetNumMetaUpgrades ~= nil
		and ( GetNumMetaUpgrades( "HealingReductionShrineUpgrade" ) or 0 ) > 0
end

function BoonAdvisor.HealingNullified()
	return BoonAdvisor.HealingMultiplier() <= 0
end

-- Weighted pressure from the active Pact. Heat cost is not a useful proxy:
-- five Hard Labor ranks double incoming damage, while Extreme Measures only
-- changes bosses. The configured weights preserve that distinction.
function BoonAdvisor.DangerLevel()
	if GetNumMetaUpgrades == nil then
		return 0
	end
	local total = 0
	local weights = BoonAdvisor.Config.Pact ~= nil
		and BoonAdvisor.Config.Pact.DangerWeights or {}
	for name, weight in pairs( weights ) do
		total = total + ( GetNumMetaUpgrades( name ) or 0 ) * weight
	end
	return total
end

function BoonAdvisor.PactRiskMultiplier()
	local config = BoonAdvisor.Config.Pact or {}
	local multiplier = 1 + BoonAdvisor.DangerLevel()
		* ( config.RiskPerDanger or 0 )
	return math.min( config.RiskMultiplierCap or multiplier, multiplier )
end

-- Pact conditions that add enemies, health, armor, or shields increase the
-- value of completing the build's proven damage plan. This deliberately does
-- not buff generic damage choices: only archetype core and payoff pieces use
-- the multiplier.
function BoonAdvisor.PactClearMultiplier()
	if GetNumMetaUpgrades == nil then
		return 1
	end
	local config = BoonAdvisor.Config.Pact or {}
	local extra = 0
	for name, weight in pairs( config.ClearWeights or {} ) do
		extra = extra + ( GetNumMetaUpgrades( name ) or 0 ) * weight
	end
	if BoonAdvisor.TimerPressure ~= nil then
		extra = extra + BoonAdvisor.TimerPressure()
			* ( config.TimerArchetypeScale or 0 )
	end
	return math.min( config.ClearMultiplierCap or ( 1 + extra ), 1 + extra )
end

-- Tight Deadline pressure is rank-aware and reads the live time bank. This is
-- constant-time and safe to call while opening a choice screen.
function BoonAdvisor.TimerPressure()
	if GetNumMetaUpgrades == nil then return 0 end
	local ranks = GetNumMetaUpgrades( "BiomeSpeedShrineUpgrade" ) or 0
	if ranks <= 0 then return 0 end
	local config = BoonAdvisor.Config.Pact or {}
	local factors = config.TimerRankFactors or {}
	local pressure = factors[ranks] or factors[TableLength( factors )] or 1
	local time = CurrentRun ~= nil and CurrentRun.BiomeTime or nil
	if type( time ) == "number" and time <= 0 then
		pressure = pressure + ( config.TimerExpiredBonus or 0 )
	elseif type( time ) == "number"
		and time <= ( config.TimerCriticalSeconds or 0 ) then
		pressure = pressure + ( config.TimerCriticalBonus or 0 )
	elseif type( time ) == "number"
		and time <= ( config.TimerLowSeconds or 0 ) then
		pressure = pressure + ( config.TimerLowBonus or 0 )
	end
	return pressure
end

--[[
	Death Defiances remaining. ExtraChanceMetaUpgrade buys these, and how many
	are left is the honest measure of how much risk a run can absorb -- a Trial
	or a Chaos gate at low health is far less dangerous with two spare lives.
]]
function BoonAdvisor.LastStandsRemaining()
	if CurrentRun == nil or CurrentRun.Hero == nil then
		return 0
	end
	local hero = CurrentRun.Hero
	if type( hero.LastStands ) == "table" then
		return TableLength( hero.LastStands )
	end
	return hero.LastStands or 0
end
