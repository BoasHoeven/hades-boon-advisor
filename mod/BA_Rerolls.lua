-- BoonAdvisor - context-aware Fated Persuasion advice.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local function copyValue( value, seen )
	if type( value ) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end
	local result = {}
	seen[value] = result
	for key, child in pairs( value ) do
		result[copyValue( key, seen )] = copyValue( child, seen )
	end
	return result
end

local function sortedKeys( source )
	local keys = {}
	for key, _ in pairs( source or {} ) do
		table.insert( keys, key )
	end
	table.sort( keys, function( a, b )
		if type( a ) == type( b ) and ( type( a ) == "number" or type( a ) == "string" ) then
			return a < b
		end
		return tostring( a ) < tostring( b )
	end )
	return keys
end

local function signatureSeed( signature )
	local seed = 1729
	for index = 1, string.len( signature ) do
		seed = ( seed * 131 + string.byte( signature, index ) ) % 2147483647
	end
	if seed <= 0 then seed = 1 end
	return seed
end

-- SetTraitsOnLoot owns the authoritative offer rules but normally consumes the
-- run's random stream. Temporarily substitute a private generator while it
-- works on copied loot data, then restore every global before returning.
local function withIsolatedRandom( seed, callback )
	local oldRandomChance = RandomChance
	local oldGetRandomValue = GetRandomValue
	local oldRemoveRandomValue = RemoveRandomValue
	local state = seed

	local function nextUnit()
		state = ( state * 48271 ) % 2147483647
		return state / 2147483647
	end

	local function randomEntry( source )
		local keys = sortedKeys( source )
		if IsEmpty( keys ) then return nil, nil end
		local index = math.floor( nextUnit() * TableLength( keys ) ) + 1
		if index > TableLength( keys ) then index = TableLength( keys ) end
		local key = keys[index]
		return source[key], key
	end

	RandomChance = function( chance )
		if chance == nil or chance <= 0 then return false end
		if chance >= 1 then return true end
		return nextUnit() < chance
	end
	GetRandomValue = function( source )
		local value = randomEntry( source )
		return value
	end
	RemoveRandomValue = function( source )
		local value, key = randomEntry( source )
		if key == nil then return nil end
		if type( key ) == "number" and key >= 1 and key <= TableLength( source ) then
			table.remove( source, key )
		else
			source[key] = nil
		end
		return value
	end

	local ok, result = pcall( callback )
	RandomChance = oldRandomChance
	GetRandomValue = oldGetRandomValue
	RemoveRandomValue = oldRemoveRandomValue
	if not ok then
		if DebugPrint ~= nil then
			DebugPrint({ LogOnly = true,
				Text = "[BoonAdvisor] reroll simulation failed: " .. tostring( result ) })
		end
		return nil
	end
	return result
end

local function currentChoiceNames( lootData )
	local names = {}
	for _, option in pairs( lootData.UpgradeOptions or {} ) do
		if option.ItemName ~= nil then
			table.insert( names, option.ItemName )
		end
	end
	return names
end

local function currentBuildSignature()
	local parts = {}
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		table.insert( parts, tostring( trait.Name ) .. "@"
			.. tostring( trait.Rarity or "-") )
	end
	table.sort( parts )
	return table.concat( parts, "," )
end

local function scoringContextSignature( lootData )
	local run = CurrentRun or {}
	local hero = run.Hero or {}
	local room = run.CurrentRoom or {}
	local parts = {
		"hp=" .. tostring( hero.Health ),
		"max=" .. tostring( hero.MaxHealth ),
		"gold=" .. tostring( run.Money ),
		"room=" .. tostring( room.Name ),
		"slam=" .. tostring( room.WallSlamMultiplier ),
		"depth=" .. tostring( run.RunDepthCache ),
		"dd=" .. tostring( BoonAdvisor.LastStandsRemaining ~= nil
			and BoonAdvisor.LastStandsRemaining() or "-" ),
	}

	local chances = lootData.RarityChances or {}
	for _, rarity in ipairs({ "Rare", "Epic", "Heroic", "Legendary" }) do
		table.insert( parts, rarity .. "=" .. tostring( chances[rarity] ) )
	end

	-- Pact ranks and Mirror side selections can both change option scores.
	if GetNumMetaUpgrades ~= nil and MetaUpgradeData ~= nil then
		for _, key in ipairs( sortedKeys( MetaUpgradeData ) ) do
			local success, count = pcall( GetNumMetaUpgrades, key )
			if success and type( count ) == "number" and count ~= 0 then
				table.insert( parts, "meta:" .. tostring( key ) .. "=" .. count )
			end
		end
	end
	if GameState ~= nil and type( GameState.MetaUpgradesSelected ) == "table" then
		local selected = {}
		for _, key in pairs( GameState.MetaUpgradesSelected ) do
			table.insert( selected, tostring( key ) )
		end
		table.sort( selected )
		table.insert( parts, "selected=" .. table.concat( selected, "," ) )
	end
	return table.concat( parts, ";" )
end

local function rerollSignature( lootData, currentBest )
	local parts = {
		tostring( lootData.Name ),
		tostring( lootData.StackNum or 1 ),
		tostring( currentBest ),
		tostring( CurrentRun ~= nil and CurrentRun.NumRerolls or 0 ),
		currentBuildSignature(),
		scoringContextSignature( lootData ),
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

local function visibleChoiceCount( optionCount )
	local count = 3
	if CalcNumLootChoices ~= nil then
		count = CalcNumLootChoices() or count
	end
	if count < 1 then count = 1 end
	if count > optionCount then count = optionCount end
	return count
end

local function bestVisibleScore( generatedLoot )
	local options = generatedLoot.UpgradeOptions or {}
	local indexes = {}
	for index, _ in ipairs( options ) do
		table.insert( indexes, index )
	end
	local count = visibleChoiceCount( TableLength( indexes ) )
	local best = nil
	for _ = 1, count do
		local index = RemoveRandomValue( indexes )
		local option = index ~= nil and options[index] or nil
		if option ~= nil then
			local result = BoonAdvisor.ScoreOption( option, generatedLoot )
			if best == nil or result.RawScore > best then
				best = result.RawScore
			end
		end
	end
	return best
end

-- Compatibility entry point for integrations that used the earlier pool
-- forecaster. Live advice now delegates to the deterministic offer engine.
function BoonAdvisor.ForecastRerollPool( lootData, currentBest, args )
	if BoonAdvisor.ForecastRerollOffer == nil then return nil end
	return BoonAdvisor.ForecastRerollOffer( lootData, currentBest, args )
end

-- High-sample copied-generator oracle for offline differential tests. Live
-- doors and rerolls never call this function.
function BoonAdvisor.SimulateInitialOffer( lootData, contextKey )
	if lootData == nil or SetTraitsOnLoot == nil or BoonAdvisor.ScoreOption == nil then
		return nil
	end
	local sampleCount = BoonAdvisor.Config.DoorOfferSimulationSamples or 0
	if sampleCount <= 0 then return nil end
	if sampleCount < 24 then sampleCount = 24 end

	local signature = "initial|" .. rerollSignature( lootData, 0 )
		.. "|" .. tostring( contextKey or "") .. "|samples=" .. sampleCount
	BoonAdvisor.InitialOfferCache = BoonAdvisor.InitialOfferCache or {}
	local cached = BoonAdvisor.InitialOfferCache[signature]
	if cached ~= nil then return cached end

	local result = withIsolatedRandom( signatureSeed( signature ), function()
		local total = 0
		local samples = 0
		for _ = 1, sampleCount do
			local generated = copyValue( lootData )
			generated.UpgradeOptions = nil
			generated.BlockReroll = nil
			generated.Rarity = nil
			SetTraitsOnLoot( generated )
			local best = bestVisibleScore( generated )
			if best ~= nil then
				total = total + best
				samples = samples + 1
			end
		end
		if samples == 0 then return nil end
		return { ExpectedScore = total / samples, Samples = samples,
			Signature = signature }
	end )
	if result ~= nil then BoonAdvisor.InitialOfferCache[signature] = result end
	return result
end

-- Reproduce RerollBoonLoot on copies. This deliberately calls the game's own
-- SetTraitsOnLoot instead of reconstructing its many priority, eligibility,
-- replacement, rarity, and transforming-trait branches in the mod.
function BoonAdvisor.SimulateReroll( lootData, currentBest, sampleOverride )
	if lootData == nil or SetTraitsOnLoot == nil or BoonAdvisor.ScoreOption == nil then
		return nil
	end
	local choiceNames = currentChoiceNames( lootData )
	if IsEmpty( choiceNames ) then return nil end

	local signature = rerollSignature( lootData, currentBest )
	local sampleCount = sampleOverride
		or BoonAdvisor.Config.RerollSimulationSamples or 192
	if sampleCount < 24 then sampleCount = 24 end
	local meaningful = BoonAdvisor.Config.RerollMeaningfulImprovement or 1

	return withIsolatedRandom( signatureSeed( signature ), function()
		local total = 0
		local improvements = 0
		local samples = 0
		for _ = 1, sampleCount do
			local generated = copyValue( lootData )
			generated.UpgradeOptions = nil
			generated.BlockReroll = nil
			generated.Rarity = nil

			-- Vanilla excludes one random option from the current screen. It does
			-- not exclude all three, so two current choices may return.
			local excluded = GetRandomValue( choiceNames )
			SetTraitsOnLoot( generated, { ExclusionNames = { excluded } } )
			local best = bestVisibleScore( generated )
			if best ~= nil then
				total = total + best
				samples = samples + 1
				if best >= currentBest + meaningful then
					improvements = improvements + 1
				end
			end
		end
		if samples == 0 then return nil end
		return {
			ExpectedScore = total / samples,
			ImprovementChance = improvements / samples,
			Samples = samples,
			Signature = signature,
		}
	end )
end

function BoonAdvisor.EvaluateReroll( lootData, currentBest, args )
	args = args or {}
	local config = BoonAdvisor.Config
	if not config.SuggestReroll or not BoonAdvisor.CanRerollLoot( lootData ) then
		return { Suggested = false, Available = false }
	end
	local signature = rerollSignature( lootData, currentBest )
	local cached = BoonAdvisor.LastRerollEvaluation
	if cached ~= nil and cached.Signature == signature then
		return cached
	end

	local forecast = BoonAdvisor.ForecastRerollPool( lootData, currentBest, args )
	if forecast == nil and config.AllowLiveSimulationFallback then
		forecast = BoonAdvisor.SimulateReroll( lootData, currentBest,
			config.RerollSimulationSamples or 512 )
		if forecast ~= nil then forecast.Method = "simulation" end
	end
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

-- Kept as a compatibility helper for configs or integrations that called the
-- old Pom-only forecast directly.
function BoonAdvisor.ExpectedPomRerollScore( lootData )
	local best = nil
	for _, option in pairs( lootData ~= nil and lootData.UpgradeOptions or {} ) do
		if not option.Blocked then
			local result = BoonAdvisor.ScoreOption( option, lootData )
			if best == nil or result.RawScore > best then best = result.RawScore end
		end
	end
	if best == nil then return nil end
	local result = BoonAdvisor.EvaluateReroll( lootData, best )
	return result.Available and result.ExpectedScore or nil
end
