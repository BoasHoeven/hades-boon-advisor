-- BoonAdvisor - context-aware Fated Persuasion advice.
--
-- Live advice is deterministic: BA_Forecast integrates the game's own offer
-- rules exactly. The sampling oracle that once lived here now ships only with
-- the test suite (tests/oracle.lua); it exists to check the exact math, never
-- to run in the game.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

-- One string per (screen, build, context) so a reroll verdict can be cached
-- until anything it depended on changes. Shared with the offline oracle.
function BoonAdvisor.RerollSignature( lootData, currentBest )
	local parts = {
		tostring( lootData.Name ),
		tostring( lootData.StackNum or 1 ),
		tostring( currentBest ),
		tostring( CurrentRun ~= nil and CurrentRun.NumRerolls or 0 ),
		BoonAdvisor.CurrentBuildSignature(),
		BoonAdvisor.ScoringContextSignature( lootData ),
	}
	for _, option in pairs( lootData.UpgradeOptions or {} ) do
		table.insert( parts, table.concat({
			tostring( option.ItemName ),
			tostring( option.SecondaryItemName ),
			tostring( option.Rarity ),
			tostring( option.TraitToReplace ),
			tostring( option.OldRarity ),
			tostring( option.Blocked ),
		}, ":" ) )
	end
	return table.concat( parts, "|" )
end

-- Mirror, screen block, escalating room cost, and remaining dice must all
-- agree before the vanilla UI exposes an affordable reroll.
function BoonAdvisor.RerollCost( lootData )
	if CurrentRun == nil or lootData == nil or IsMetaUpgradeSelected == nil
		or not IsMetaUpgradeSelected( BoonAdvisor.MetaKeys.RerollPanel )
		or lootData.BlockReroll then
		return nil
	end
	if RerollCosts == nil then return nil end
	local cost = lootData.Name == "WeaponUpgrade"
		and RerollCosts.Hammer or RerollCosts.Boon
	if cost == nil or cost <= 0 then return nil end
	local room = CurrentRun.CurrentRoom
	if room ~= nil and room.SpentRerolls ~= nil and lootData.ObjectId ~= nil then
		cost = cost + ( room.SpentRerolls[lootData.ObjectId] or 0 )
	end
	return cost
end

function BoonAdvisor.CanRerollLoot( lootData )
	local cost = BoonAdvisor.RerollCost( lootData )
	return cost ~= nil and ( CurrentRun.NumRerolls or 0 ) >= cost
end

function BoonAdvisor.EvaluateReroll( lootData, currentBest, args )
	args = args or {}
	local config = BoonAdvisor.Config
	if not config.SuggestReroll or not BoonAdvisor.CanRerollLoot( lootData ) then
		return { Suggested = false, Available = false }
	end
	local signature = BoonAdvisor.RerollSignature( lootData, currentBest )
	local cached = BoonAdvisor.LastRerollEvaluation
	if cached ~= nil and cached.Signature == signature then
		return cached
	end

	local forecast = BoonAdvisor.ForecastRerollOffer ~= nil
		and BoonAdvisor.ForecastRerollOffer( lootData, currentBest, args ) or nil
	if forecast == nil then
		local result = { Suggested = false, Available = false, Signature = signature }
		BoonAdvisor.LastRerollEvaluation = result
		return result
	end
	forecast.Signature = signature

	local cost = BoonAdvisor.RerollCost( lootData ) or 1
	local requiredGain = config.RerollMinExpectedGain
		+ math.max( 0, cost - 1 ) * config.RerollCostPenalty
	local remaining = CurrentRun ~= nil and ( CurrentRun.NumRerolls or 0 ) or 0
	if remaining <= cost then
		requiredGain = requiredGain + config.RerollLastDiePenalty
	end

	forecast.Available = true
	forecast.CurrentScore = currentBest
	forecast.Gain = forecast.ExpectedScore - currentBest
	forecast.Cost = cost
	forecast.RequiredGain = requiredGain
	forecast.Suggested = forecast.Gain >= requiredGain
		and forecast.ImprovementChance >= config.RerollMinImprovementChance
	BoonAdvisor.LastRerollEvaluation = forecast
	return forecast
end

function BoonAdvisor.ShouldSuggestReroll( lootData, currentBest )
	return BoonAdvisor.EvaluateReroll( lootData, currentBest ).Suggested
end
