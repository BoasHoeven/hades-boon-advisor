--[[
	Offline sampling oracle for the differential tests.

	This file is NOT part of the mod. The harness loads it after the mod so
	the exact forecasts in BA_Forecast can be checked against a high-sample
	simulation that drives the game's own SetTraitsOnLoot on copied loot with
	a private random generator. Nothing in the shipped mod calls anything
	defined here.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.Config.RerollSimulationSamples =
	BoonAdvisor.Config.RerollSimulationSamples or 512
BoonAdvisor.Config.DoorOfferSimulationSamples =
	BoonAdvisor.Config.DoorOfferSimulationSamples or 512

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

-- High-sample copied-generator oracle for door forecasts.
function BoonAdvisor.SimulateInitialOffer( lootData, contextKey )
	if lootData == nil or SetTraitsOnLoot == nil or BoonAdvisor.ScoreOption == nil then
		return nil
	end
	local sampleCount = BoonAdvisor.Config.DoorOfferSimulationSamples or 0
	if sampleCount <= 0 then return nil end
	if sampleCount < 24 then sampleCount = 24 end

	local signature = "initial|" .. BoonAdvisor.RerollSignature( lootData, 0 )
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
-- replacement, rarity, and transforming-trait branches.
function BoonAdvisor.SimulateReroll( lootData, currentBest, sampleOverride )
	if lootData == nil or SetTraitsOnLoot == nil or BoonAdvisor.ScoreOption == nil then
		return nil
	end
	local choiceNames = currentChoiceNames( lootData )
	if IsEmpty( choiceNames ) then return nil end

	local signature = BoonAdvisor.RerollSignature( lootData, currentBest )
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

-- The oracle caches by signature like the live forecaster; clear it together.
local vanillaInvalidate = BoonAdvisor.InvalidateForecastCache
function BoonAdvisor.InvalidateForecastCache()
	BoonAdvisor.InitialOfferCache = nil
	if vanillaInvalidate ~= nil then return vanillaInvalidate() end
end
