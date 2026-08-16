-- BoonAdvisor - deterministic offer forecasting.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local TOTAL_CHOICES = 3
local CHAOS_CURSE_REMOVE_CHANCE = 0.70

local function tableCount( source )
	local count = 0
	for _, _ in pairs( source or {} ) do count = count + 1 end
	return count
end

local function copyOption( source )
	local result = {}
	for key, value in pairs( source or {} ) do result[key] = value end
	return result
end

local function copyArray( source )
	local result = {}
	for _, value in ipairs( source or {} ) do table.insert( result, value ) end
	return result
end

local function sortedKeys( source )
	local keys = {}
	for key, _ in pairs( source or {} ) do table.insert( keys, key ) end
	table.sort( keys, function( left, right ) return tostring( left ) < tostring( right ) end )
	return keys
end

local function clampChance( value )
	value = type( value ) == "number" and value or 0
	if value < 0 then return 0 end
	if value > 1 then return 1 end
	return value
end

local function chanceFor( lootData, rarity )
	if lootData ~= nil and lootData.ForceCommon then return 0 end
	return clampChance( lootData ~= nil and lootData.RarityChances ~= nil
		and lootData.RarityChances[rarity] or 0 )
end

local function isEligible( data, stripRequirements )
	if data == nil then return false end
	if stripRequirements or IsGameStateEligible == nil then return true end
	local success, eligible = pcall( IsGameStateEligible, CurrentRun, data )
	return success and eligible
end

local function heroHasTrait( traitName )
	local prepared = BoonAdvisor.ForecastHeroTraitNames
	if prepared ~= nil then return prepared[traitName] == true end
	return BoonAdvisor.HeroHasTrait( traitName )
end

local function visibleChoiceCount( optionCount )
	local count = TOTAL_CHOICES
	if CalcNumLootChoices ~= nil then count = CalcNumLootChoices() or count end
	if count < 1 then count = 1 end
	if count > optionCount then count = optionCount end
	return count
end

local function rarityLevelsFor( option )
	local data = option ~= nil and option.Type == "Consumable"
		and ConsumableData ~= nil and ConsumableData[option.ItemName]
		or TraitData ~= nil and option ~= nil and TraitData[option.ItemName]
	local levels = data ~= nil and data.RarityLevels or nil
	if levels == nil then return { Common = true } end
	return levels
end

local function optionKey( option )
	return table.concat({
		tostring( option ~= nil and option.ItemName ),
		tostring( option ~= nil and option.SecondaryItemName ),
		tostring( option ~= nil and option.TraitToReplace ),
		tostring( option ~= nil and option.OldRarity ),
	}, ":" )
end

local function scoreOptionAtRarity( option, rarity, lootData, scoreCache )
	local key = optionKey( option ) .. "@" .. tostring( rarity )
	if scoreCache[key] ~= nil then return scoreCache[key] end
	local candidate = copyOption( option )
	candidate.Rarity = rarity
	local previous = BoonAdvisor.ForecastHeroTraitNamesActive
	BoonAdvisor.ForecastHeroTraitNamesActive = true
	local success, result = pcall( BoonAdvisor.ScoreOption, candidate, lootData )
	BoonAdvisor.ForecastHeroTraitNamesActive = previous
	if not success then error( result ) end
	scoreCache[key] = result.RawScore
	return result.RawScore
end

local function currentBuildSignature()
	local parts = {}
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		table.insert( parts, table.concat({
			tostring( trait.Name ),
			tostring( trait.Rarity or "-" ),
			tostring( trait.Level or trait.StackNum or "-" ),
		}, "@" ) )
	end
	table.sort( parts )
	return table.concat( parts, "," )
end

local function scoringContextSignature( lootData )
	local run = CurrentRun or {}
	local hero = run.Hero or {}
	local room = run.CurrentRoom or {}
	local parts = {
		"build=" .. currentBuildSignature(),
		"hp=" .. tostring( hero.Health ),
		"max=" .. tostring( hero.MaxHealth ),
		"gold=" .. tostring( run.Money ),
		"room=" .. tostring( room.Name ),
		"slam=" .. tostring( room.WallSlamMultiplier ),
		"depth=" .. tostring( run.RunDepthCache ),
		"rerolls=" .. tostring( run.NumRerolls ),
		"objective=" .. tostring( BoonAdvisor.Config ~= nil
			and BoonAdvisor.Config.Objective or "Balanced" ),
		"visible=" .. tostring( visibleChoiceCount( TOTAL_CHOICES ) ),
	}
	if BoonAdvisor.LastStandsRemaining ~= nil then
		table.insert( parts, "dd=" .. tostring( BoonAdvisor.LastStandsRemaining() ) )
	end
	for _, rarity in ipairs({ "Rare", "Epic", "Heroic", "Legendary" }) do
		table.insert( parts, rarity .. "=" .. tostring( lootData ~= nil
			and lootData.RarityChances ~= nil and lootData.RarityChances[rarity] ) )
	end
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

local function poolFingerprint( pool )
	local parts = {}
	for _, option in ipairs( pool or {} ) do
		table.insert( parts, optionKey( option ) .. "@" .. tostring( option.Rarity ) )
	end
	table.sort( parts )
	return table.concat( parts, "," )
end

function BoonAdvisor.BuildOfferIndex()
	if BoonAdvisor.OfferIndex ~= nil then return BoonAdvisor.OfferIndex end
	local index = {}
	for lootName, data in pairs( LootData or {} ) do
		if type( data ) == "table" then
			local entry = {
				Source = data,
				PriorityUpgrades = copyArray( data.PriorityUpgrades ),
				PermanentTraits = copyArray( data.PermanentTraits ),
				TemporaryTraits = copyArray( data.TemporaryTraits ),
				TransformingTraits = data.TransformingTraits == true,
				Candidates = {},
				Linked = {},
			}
			local seen = {}
			for _, list in ipairs({ data.WeaponUpgrades, data.Traits, data.PriorityUpgrades }) do
				for _, traitName in ipairs( list or {} ) do
					if not seen[traitName] then
						seen[traitName] = true
						table.insert( entry.Candidates, traitName )
					end
				end
			end
			for _, traitName in ipairs( sortedKeys( data.LinkedUpgrades ) ) do
				entry.Linked[traitName] = data.LinkedUpgrades[traitName]
				if not seen[traitName] then
					seen[traitName] = true
					table.insert( entry.Candidates, traitName )
				end
			end
			index[lootName] = entry
		end
	end
	BoonAdvisor.OfferIndex = index
	return index
end

local function ensureForecastCache()
	local epoch = currentBuildSignature()
	if BoonAdvisor.ForecastCacheEpoch ~= epoch then
		BoonAdvisor.ForecastCacheEpoch = epoch
		BoonAdvisor.ForecastCache = {}
		BoonAdvisor.ForecastCacheOrder = {}
		BoonAdvisor.ForecastHeroTraitNames = {}
		local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
		for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
			if trait.Name ~= nil then
				BoonAdvisor.ForecastHeroTraitNames[trait.Name] = true
			end
		end
		BoonAdvisor.LastRerollEvaluation = nil
		BoonAdvisor.ForecastStats = BoonAdvisor.ForecastStats or { Hits = 0, Misses = 0 }
		BoonAdvisor.ForecastStats.Invalidations =
			( BoonAdvisor.ForecastStats.Invalidations or 0 ) + 1
	elseif BoonAdvisor.ForecastHeroTraitNames == nil then
		BoonAdvisor.ForecastHeroTraitNames = {}
		local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
		for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
			if trait.Name ~= nil then
				BoonAdvisor.ForecastHeroTraitNames[trait.Name] = true
			end
		end
	end
	BoonAdvisor.ForecastCache = BoonAdvisor.ForecastCache or {}
	BoonAdvisor.ForecastCacheOrder = BoonAdvisor.ForecastCacheOrder or {}
	BoonAdvisor.ForecastStats = BoonAdvisor.ForecastStats or { Hits = 0, Misses = 0 }
end

function BoonAdvisor.InvalidateForecastCache()
	BoonAdvisor.ForecastCacheEpoch = nil
	BoonAdvisor.ForecastCache = nil
	BoonAdvisor.ForecastCacheOrder = nil
	BoonAdvisor.InitialOfferCache = nil
	BoonAdvisor.LastRerollEvaluation = nil
	BoonAdvisor.ForecastHeroTraitNames = nil
end

local function cachedForecast( signature )
	ensureForecastCache()
	local cached = BoonAdvisor.ForecastCache[signature]
	if cached == nil then
		BoonAdvisor.ForecastStats.Misses = ( BoonAdvisor.ForecastStats.Misses or 0 ) + 1
		return nil
	end
	BoonAdvisor.ForecastStats.Hits = ( BoonAdvisor.ForecastStats.Hits or 0 ) + 1
	local result = copyOption( cached )
	result.CacheHit = true
	return result
end

local function storeForecast( signature, result )
	ensureForecastCache()
	if BoonAdvisor.ForecastCache[signature] == nil then
		table.insert( BoonAdvisor.ForecastCacheOrder, signature )
	end
	BoonAdvisor.ForecastCache[signature] = copyOption( result )
	local limit = BoonAdvisor.Config.ForecastCacheEntries or 96
	while tableCount( BoonAdvisor.ForecastCacheOrder ) > limit do
		local oldest = table.remove( BoonAdvisor.ForecastCacheOrder, 1 )
		BoonAdvisor.ForecastCache[oldest] = nil
	end
	return result
end

local function staticChoiceData( lootData )
	local entry = lootData ~= nil and BoonAdvisor.OfferIndex ~= nil
		and BoonAdvisor.OfferIndex[lootData.Name] or nil
	if entry ~= nil then return entry.Source end
	return lootData ~= nil and LootData ~= nil and LootData[lootData.Name] or nil
end

local function fallbackEligiblePool( lootData, choiceData )
	local pool = {}
	local seen = {}
	local occupiedGodSlots = {}
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		local data = TraitData ~= nil and TraitData[trait.Name] or nil
		local slot = trait.Slot or ( data ~= nil and data.Slot )
		if data ~= nil and data.God ~= nil and slot ~= nil then occupiedGodSlots[slot] = true end
	end
	local function add( itemName, itemType, checkSlot )
		if itemName == nil or seen[itemName] then return end
		local data = itemType == "Consumable" and ConsumableData ~= nil
			and ConsumableData[itemName] or TraitData[itemName]
		if data == nil or heroHasTrait( itemName ) or not isEligible( data, lootData.StripRequirements ) then
			return
		end
		if checkSlot and data.Slot ~= nil and occupiedGodSlots[data.Slot] then return end
		seen[itemName] = true
		table.insert( pool, { ItemName = itemName, Type = itemType } )
	end
	for _, name in ipairs( choiceData ~= nil and choiceData.WeaponUpgrades or {} ) do
		add( name, "Trait", true )
	end
	for _, name in ipairs( choiceData ~= nil and choiceData.Traits or {} ) do
		add( name, "Trait", false )
	end
	for _, name in ipairs( sortedKeys( choiceData ~= nil and choiceData.LinkedUpgrades ) ) do
		local requirement = choiceData.LinkedUpgrades[name]
		if BoonAdvisor.LinkedRequirementMet == nil
			or BoonAdvisor.LinkedRequirementMet( requirement ) then
			add( name, "Trait", false )
		end
	end
	for _, name in ipairs( choiceData ~= nil and choiceData.Consumables or {} ) do
		add( name, "Consumable", false )
	end
	return pool
end

local function eligiblePool( lootData )
	local pool = {}
	if type( lootData.RerollPool ) == "table" then
		for _, option in ipairs( lootData.RerollPool ) do
			table.insert( pool, copyOption( option ) )
		end
		return pool, true
	end
	if lootData.StackOnly or lootData.Name == "StackUpgrade" then
		if GetAllUpgradeableGodTraits == nil then return pool, false end
		for traitName, _ in pairs( GetAllUpgradeableGodTraits() or {} ) do
			local data = TraitData ~= nil and TraitData[traitName] or nil
			if isEligible( data, false ) then
				table.insert( pool, { ItemName = traitName, Type = "Trait" } )
			end
		end
		return pool, false
	end
	local choiceData = staticChoiceData( lootData )
	if choiceData ~= nil and choiceData.TransformingTraits then
		for _, permanentName in ipairs( choiceData.PermanentTraits or {} ) do
			if isEligible( TraitData[permanentName], false ) then
				for _, temporaryName in ipairs( choiceData.TemporaryTraits or {} ) do
					if isEligible( TraitData[temporaryName], false ) then
						table.insert( pool, { ItemName = permanentName,
							SecondaryItemName = temporaryName, Type = "TransformingTrait" } )
					end
				end
			end
		end
		return pool, false
	end
	if GetEligibleUpgrades ~= nil and choiceData ~= nil then
		local success, eligible = pcall( GetEligibleUpgrades, {}, lootData, choiceData )
		if success and type( eligible ) == "table" then
			for _, option in ipairs( eligible ) do table.insert( pool, copyOption( option ) ) end
			return pool, false
		end
	end
	return fallbackEligiblePool( lootData, choiceData or lootData ), false
end

local function removeNamedOptions( options, excluded )
	local result = {}
	for _, option in ipairs( options or {} ) do
		if not excluded[option.ItemName] then table.insert( result, copyOption( option ) ) end
	end
	return result
end

local function removeCandidateAt( candidates, selectedIndex )
	local result = {}
	for index, candidate in ipairs( candidates ) do
		if index ~= selectedIndex then table.insert( result, candidate ) end
	end
	return result
end

local function removeCandidateNames( candidates, selected )
	local removed = {}
	for _, option in ipairs( selected or {} ) do removed[option.ItemName] = true end
	local result = {}
	for _, candidate in ipairs( candidates or {} ) do
		if not removed[candidate.ItemName] then table.insert( result, candidate ) end
	end
	return result
end

local function combinations( values, count )
	local output = {}
	local chosen = {}
	local function visit( startIndex )
		if tableCount( chosen ) == count then
			table.insert( output, copyArray( chosen ) )
			return
		end
		for index = startIndex, tableCount( values ) do
			table.insert( chosen, values[index] )
			visit( index + 1 )
			table.remove( chosen )
		end
	end
	if count == 0 then return { {} } end
	visit( 1 )
	return output
end

local function occupiedSlots()
	local occupied = {}
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		local data = TraitData ~= nil and TraitData[trait.Name] or nil
		local slot = trait.Slot or ( data ~= nil and data.Slot )
		if slot ~= nil then occupied[slot] = true end
	end
	return occupied
end

local function priorityStates( traitNames, lootData )
	local candidates = {}
	local hasPriority = false
	local occupied = occupiedSlots()
	for _, traitName in ipairs( traitNames or {} ) do
		local data = TraitData ~= nil and TraitData[traitName] or nil
		if data ~= nil and isEligible( data, lootData.StripRequirements ) then
			if not heroHasTrait( traitName ) and not occupied[data.Slot] then
				table.insert( candidates, { ItemName = traitName, Type = "Trait" } )
			else
				hasPriority = true
			end
		end
	end
	if hasPriority then
		if tableCount( candidates ) == 0 then return { { Options = {}, Probability = 1 } } end
		local states = {}
		for _, candidate in ipairs( candidates ) do
			table.insert( states, { Options = { candidate },
				Probability = 1 / tableCount( candidates ) } )
		end
		return states
	end
	if tableCount( candidates ) <= TOTAL_CHOICES then
		return { { Options = candidates, Probability = 1 } }
	end
	local subsets = combinations( candidates, TOTAL_CHOICES )
	local states = {}
	for _, subset in ipairs( subsets ) do
		table.insert( states, { Options = subset, Probability = 1 / tableCount( subsets ) } )
	end
	return states
end

local function upgradedRarity( rarity )
	if GetUpgradedRarity ~= nil then return GetUpgradedRarity( rarity ) end
	return ({ Common = "Rare", Rare = "Epic", Epic = "Heroic" })[rarity]
end

local function replacementOptions( traitNames )
	local options = {}
	local occupied = {}
	local ranks = { Common = 1, Rare = 2, Epic = 3, Heroic = 4, Legendary = 5 }
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		local data = TraitData ~= nil and TraitData[trait.Name] or nil
		local slot = trait.Slot or ( data ~= nil and data.Slot )
		if slot ~= nil then
			local existing = occupied[slot]
			if existing == nil then
				existing = { TraitName = trait.Name, Rarity = trait.Rarity or "Common" }
				occupied[slot] = existing
			elseif ( ranks[trait.Rarity or "Common"] or 1 )
				> ( ranks[existing.Rarity or "Common"] or 1 ) then
				existing.Rarity = trait.Rarity or "Common"
			end
		end
	end
	for _, traitName in ipairs( traitNames or {} ) do
		local data = TraitData ~= nil and TraitData[traitName] or nil
		local old = data ~= nil and occupied[data.Slot] or nil
		local rarity = old ~= nil and upgradedRarity( old.Rarity ) or nil
		if data ~= nil and old ~= nil and rarity ~= nil and not heroHasTrait( traitName )
			and isEligible( data, false ) then
			table.insert( options, {
				ItemName = traitName, Type = "Trait", Rarity = rarity,
				TraitToReplace = old.TraitName, OldRarity = old.Rarity,
			} )
		end
	end
	return options
end

local function removeName( names, target )
	local result = {}
	for _, name in ipairs( names or {} ) do
		if name ~= target then table.insert( result, name ) end
	end
	return result
end

local function linkedPriorityTraits( lootData, choiceData )
	if GetPriorityDependentTraits ~= nil then
		local success, linked = pcall( GetPriorityDependentTraits, lootData )
		if success and type( linked ) == "table" then return linked end
	end
	local output = {}
	for _, traitName in ipairs( sortedKeys( choiceData ~= nil and choiceData.LinkedUpgrades ) ) do
		local requirement = choiceData.LinkedUpgrades[traitName]
		if requirement.PriorityChance ~= nil and not heroHasTrait( traitName )
			and ( BoonAdvisor.LinkedRequirementMet == nil
				or BoonAdvisor.LinkedRequirementMet( requirement ) ) then
			table.insert( output, { TraitName = traitName,
				PriorityChance = requirement.PriorityChance } )
		end
	end
	return output
end

local function branchLinkedPriorities( state, linked, index, output )
	if tableCount( state.Options ) >= TOTAL_CHOICES or index > tableCount( linked ) then
		table.insert( output, state )
		return
	end
	local entry = linked[index]
	local chance = clampChance( entry.PriorityChance )
	if chance < 1 then
		branchLinkedPriorities({
			Options = copyArray( state.Options ),
			ChosenPriority = copyArray( state.ChosenPriority ),
			Probability = state.Probability * ( 1 - chance ),
		}, linked, index + 1, output )
	end
	if chance > 0 then
		local options = copyArray( state.Options )
		table.insert( options, { ItemName = entry.TraitName, Type = "Trait" } )
		branchLinkedPriorities({
			Options = options,
			ChosenPriority = copyArray( state.ChosenPriority ),
			Probability = state.Probability * chance,
		}, linked, index + 1, output )
	end
end

local function initialStates( lootData, excluded )
	local choiceData = staticChoiceData( lootData ) or lootData
	local priorityNames = copyArray( lootData.PriorityUpgrades or choiceData.PriorityUpgrades )
	local forceNames = nil
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	if room ~= nil and room.ForceLootTableFirstRun ~= nil and GetCompletedRuns ~= nil then
		local success, runs = pcall( GetCompletedRuns )
		if success and runs == 0 then forceNames = room.ForceLootTableFirstRun end
	end
	local normalStates = priorityStates( forceNames or priorityNames, lootData )
	for _, state in ipairs( normalStates ) do state.ChosenPriority = copyArray( priorityNames ) end

	if forceNames == nil then
		local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
		local boonData = hero ~= nil and hero.BoonData or nil
		local replaceChance = boonData ~= nil and clampChance( boonData.ReplaceChance ) or 0
		local canReplace = replaceChance > 0 and not lootData.ForceCommon
		if canReplace and boonData.GameStateRequirements ~= nil then
			canReplace = isEligible( boonData.GameStateRequirements, false )
		end
		local replacements = canReplace and replacementOptions( priorityNames ) or {}
		if tableCount( replacements ) > 0 then
			for _, state in ipairs( normalStates ) do
				state.Probability = state.Probability * ( 1 - replaceChance )
			end
			for _, option in ipairs( replacements ) do
				table.insert( normalStates, {
					Options = { option },
					ChosenPriority = removeName( priorityNames, option.ItemName ),
					Probability = replaceChance / tableCount( replacements ),
				} )
			end
		end
	end

	local linked = linkedPriorityTraits( lootData, choiceData )
	local linkedStates = {}
	for _, state in ipairs( normalStates ) do
		branchLinkedPriorities( state, linked, 1, linkedStates )
	end
	for _, state in ipairs( linkedStates ) do
		state.Options = removeNamedOptions( state.Options, excluded )
	end
	return linkedStates
end

local function priorityRarityOutcomes( option, lootData )
	if option.Rarity ~= nil then return { { Rarity = option.Rarity, Probability = 1 } } end
	local levels = rarityLevelsFor( option )
	local remaining = 1
	local outcomes = {}
	local function roll( rarity, allowed )
		if not allowed then return end
		local chance = chanceFor( lootData, rarity )
		if chance > 0 then
			table.insert( outcomes, { Rarity = rarity, Probability = remaining * chance } )
		end
		remaining = remaining * ( 1 - chance )
	end
	roll( "Legendary", levels.Legendary ~= nil )
	-- SetTraitsOnLoot intentionally checks Epic support for priority Heroics.
	roll( "Heroic", levels.Epic ~= nil )
	roll( "Epic", levels.Epic ~= nil )
	roll( "Rare", levels.Rare ~= nil )
	table.insert( outcomes, { Rarity = "Common", Probability = remaining } )
	return outcomes
end

local function assignPriorityRarities( options, index, probability, output, lootData )
	if index > tableCount( options ) then
		table.insert( output, { Options = copyArray( options ), Probability = probability } )
		return
	end
	local original = options[index]
	for _, outcome in ipairs( priorityRarityOutcomes( original, lootData ) ) do
		local candidate = copyOption( original )
		candidate.Rarity = outcome.Rarity
		options[index] = candidate
		assignPriorityRarities( options, index + 1,
			probability * outcome.Probability, output, lootData )
	end
	options[index] = original
end

local function rarityBucket( candidates, rarity )
	local output = {}
	for index, candidate in ipairs( candidates ) do
		local levels = rarityLevelsFor( candidate )
		if levels[rarity] ~= nil then table.insert( output, index ) end
	end
	return output
end

local function drawTransitions( candidates, lootData )
	local transitions = {}
	local remaining = 1
	for _, rarity in ipairs({ "Legendary", "Heroic", "Epic", "Rare" }) do
		local bucket = rarityBucket( candidates, rarity )
		if tableCount( bucket ) > 0 then
			local chance = chanceFor( lootData, rarity )
			if chance > 0 then
				for _, candidateIndex in ipairs( bucket ) do
					table.insert( transitions, { Index = candidateIndex, Rarity = rarity,
						Probability = remaining * chance / tableCount( bucket ) } )
				end
			end
			remaining = remaining * ( 1 - chance )
		end
	end
	local common = rarityBucket( candidates, "Common" )
	if tableCount( common ) > 0 then
		for _, candidateIndex in ipairs( common ) do
			table.insert( transitions, { Index = candidateIndex, Rarity = "Common",
				Probability = remaining / tableCount( common ) } )
		end
	elseif remaining > 0 then
		table.insert( transitions, { Probability = remaining } )
	end
	return transitions
end

local function visibleMetrics( options, lootData, currentBest, meaningful, scoreCache )
	local count = visibleChoiceCount( tableCount( options ) )
	if count <= 0 then return nil, nil end
	local subsets = combinations( options, count )
	local expected, improved = 0, 0
	local target = currentBest ~= nil and currentBest + meaningful or nil
	for _, subset in ipairs( subsets ) do
		local best = nil
		for _, option in ipairs( subset ) do
			local value = scoreOptionAtRarity( option, option.Rarity or "Common",
				lootData, scoreCache )
			if best == nil or value > best then best = value end
		end
		expected = expected + best
		if target ~= nil and best >= target then improved = improved + 1 end
	end
	return expected / tableCount( subsets ), improved / tableCount( subsets )
end

local function fallbackDraw( candidates, lootData )
	for _, rarity in ipairs({ "Rare", "Epic", "Heroic", "Legendary", "Common" }) do
		local bucket = rarityBucket( candidates, rarity )
		local enabled = rarity == "Common" or lootData.RarityChances ~= nil
			and lootData.RarityChances[rarity] ~= nil
		if enabled and tableCount( bucket ) > 0 then
			local transitions = {}
			for _, candidateIndex in ipairs( bucket ) do
				table.insert( transitions, { Index = candidateIndex, Rarity = rarity,
					Probability = 1 / tableCount( bucket ) } )
			end
			return transitions
		end
	end
	return {}
end

local function forecastOrdinaryScenario( lootData, pool, excludedName, currentBest,
	sharedScoreCache, yieldWork )
	local excluded = {}
	if excludedName ~= nil then excluded[excludedName] = true end
	local candidates = removeNamedOptions( pool, excluded )
	local seeds = initialStates( lootData, excluded )
	local scoreCache = sharedScoreCache or {}
	local meaningful = BoonAdvisor.Config.RerollMeaningfulImprovement or 1
	local expectedTotal, improvementTotal, probabilityTotal = 0, 0, 0

	if visibleChoiceCount( TOTAL_CHOICES ) == TOTAL_CHOICES then
		local candidateIds = {}
		for index, candidate in ipairs( candidates ) do candidateIds[candidate] = index end

		local function remainingKey( remaining )
			local parts = {}
			for _, candidate in ipairs( remaining or {} ) do
				table.insert( parts, tostring( candidateIds[candidate] or optionKey( candidate ) ) )
			end
			return table.concat( parts, "," )
		end

		local function namesKey( names )
			return table.concat( names or {}, "," )
		end

		local function stateKey( count, best, remaining, names, attempts )
			return table.concat({ tostring( count ), tostring( best ),
				remainingKey( remaining ), namesKey( names ), tostring( attempts ) }, "|" )
		end

		local function addDistribution( target, source, weight )
			for score, probability in pairs( source or {} ) do
				target[score] = ( target[score] or 0 ) + probability * weight
			end
		end

		local replacementCache = {}
		local function cachedReplacements( names )
			local key = namesKey( names )
			if replacementCache[key] == nil then
				replacementCache[key] = replacementOptions( names )
			end
			return replacementCache[key]
		end

		local fillMemo = {}
		local replacementMemo = {}
		local fallbackMemo = {}
		local solveFill, solveReplacements, solveFallback

		solveFallback = function( count, best, remaining )
			if yieldWork ~= nil then yieldWork() end
			local key = stateKey( count, best, remaining, nil, "fallback" )
			if fallbackMemo[key] ~= nil then return fallbackMemo[key] end
			local distribution = {}
			if count >= TOTAL_CHOICES then
				if best ~= nil then distribution[best] = 1 end
				fallbackMemo[key] = distribution
				return distribution
			end
			local transitions = fallbackDraw( remaining, lootData )
			if tableCount( transitions ) == 0 then
				if best ~= nil then distribution[best] = 1 end
				fallbackMemo[key] = distribution
				return distribution
			end
			for _, transition in ipairs( transitions ) do
				local option = remaining[transition.Index]
				local value = scoreOptionAtRarity( option, transition.Rarity,
					lootData, scoreCache )
				addDistribution( distribution,
					solveFallback( count + 1,
						best == nil and value or math.max( best, value ),
						removeCandidateAt( remaining, transition.Index ) ),
					transition.Probability )
			end
			fallbackMemo[key] = distribution
			return distribution
		end

		solveReplacements = function( count, best, names, remaining )
			if yieldWork ~= nil then yieldWork() end
			local key = stateKey( count, best, remaining, names, "replace" )
			if replacementMemo[key] ~= nil then return replacementMemo[key] end
			if count >= TOTAL_CHOICES or tableCount( names ) == 0 then
				local distribution = solveFallback( count, best, remaining )
				replacementMemo[key] = distribution
				return distribution
			end
			local available = cachedReplacements( names )
			if tableCount( available ) == 0 then
				local distribution = solveFallback( count, best, remaining )
				replacementMemo[key] = distribution
				return distribution
			end
			local distribution = {}
			for _, option in ipairs( available ) do
				local value = scoreOptionAtRarity( option, option.Rarity or "Common",
					lootData, scoreCache )
				addDistribution( distribution,
					solveReplacements( count + 1,
						best == nil and value or math.max( best, value ),
						removeName( names, option.ItemName ),
						removeCandidateNames( remaining, { option } ) ),
					1 / tableCount( available ) )
			end
			replacementMemo[key] = distribution
			return distribution
		end

		solveFill = function( count, best, remaining, attempts, chosenPriority )
			if yieldWork ~= nil then yieldWork() end
			local key = stateKey( count, best, remaining, chosenPriority, attempts )
			if fillMemo[key] ~= nil then return fillMemo[key] end
			if attempts <= 0 or count >= TOTAL_CHOICES then
				local distribution = solveReplacements(
					count, best, chosenPriority, remaining )
				fillMemo[key] = distribution
				return distribution
			end
			local transitions = drawTransitions( remaining, lootData )
			if tableCount( transitions ) == 0 then
				local distribution = solveReplacements(
					count, best, chosenPriority, remaining )
				fillMemo[key] = distribution
				return distribution
			end
			local distribution = {}
			for _, transition in ipairs( transitions ) do
				if transition.Index == nil then
					addDistribution( distribution,
						solveFill( count, best, remaining, attempts - 1,
							chosenPriority ), transition.Probability )
				else
					local option = remaining[transition.Index]
					local value = scoreOptionAtRarity( option, transition.Rarity,
						lootData, scoreCache )
					addDistribution( distribution,
						solveFill( count + 1,
							best == nil and value or math.max( best, value ),
							removeCandidateAt( remaining, transition.Index ),
							attempts - 1, chosenPriority ), transition.Probability )
				end
			end
			fillMemo[key] = distribution
			return distribution
		end

		local finalDistribution = {}
		for _, seed in ipairs( seeds ) do
			local rarityStates = {}
			assignPriorityRarities( copyArray( seed.Options ), 1,
				seed.Probability, rarityStates, lootData )
			for _, rarityState in ipairs( rarityStates ) do
				local best = nil
				for _, option in ipairs( rarityState.Options ) do
					local value = scoreOptionAtRarity( option, option.Rarity or "Common",
						lootData, scoreCache )
					best = best == nil and value or math.max( best, value )
				end
				local remaining = removeCandidateNames( candidates, rarityState.Options )
				addDistribution( finalDistribution,
					solveFill( tableCount( rarityState.Options ), best, remaining,
						TOTAL_CHOICES - tableCount( rarityState.Options ),
						seed.ChosenPriority ), rarityState.Probability )
			end
		end

		local target = currentBest ~= nil and currentBest + meaningful or nil
		for score, probability in pairs( finalDistribution ) do
			expectedTotal = expectedTotal + score * probability
			if target ~= nil and score >= target then
				improvementTotal = improvementTotal + probability
			end
			probabilityTotal = probabilityTotal + probability
		end
		if probabilityTotal <= 0 then return nil end
		return {
			ExpectedScore = expectedTotal / probabilityTotal,
			ImprovementChance = improvementTotal / probabilityTotal,
			OutcomeProbability = probabilityTotal,
			Candidates = tableCount( pool ),
		}
	end

	local function finish( options, remaining, chosenPriority, probability )
		local function fallback( finalOptions, finalRemaining, finalProbability )
			if yieldWork ~= nil then yieldWork() end
			if tableCount( finalOptions ) >= TOTAL_CHOICES then
				local expected, improved = visibleMetrics( finalOptions, lootData,
					currentBest, meaningful, scoreCache )
				if expected ~= nil then
					expectedTotal = expectedTotal + expected * finalProbability
					improvementTotal = improvementTotal + improved * finalProbability
					probabilityTotal = probabilityTotal + finalProbability
				end
				return
			end
			local transitions = fallbackDraw( finalRemaining, lootData )
			if tableCount( transitions ) == 0 then
				local expected, improved = visibleMetrics( finalOptions, lootData,
					currentBest, meaningful, scoreCache )
				if expected ~= nil then
					expectedTotal = expectedTotal + expected * finalProbability
					improvementTotal = improvementTotal + improved * finalProbability
					probabilityTotal = probabilityTotal + finalProbability
				end
				return
			end
			for _, transition in ipairs( transitions ) do
				local option = copyOption( finalRemaining[transition.Index] )
				option.Rarity = transition.Rarity
				local nextOptions = copyArray( finalOptions )
				table.insert( nextOptions, option )
				fallback( nextOptions, removeCandidateAt( finalRemaining, transition.Index ),
					finalProbability * transition.Probability )
			end
		end

		local function replacements( finalOptions, names, finalRemaining, finalProbability )
			if yieldWork ~= nil then yieldWork() end
			if tableCount( finalOptions ) >= TOTAL_CHOICES or tableCount( names ) == 0 then
				fallback( finalOptions, finalRemaining, finalProbability )
				return
			end
			local available = replacementOptions( names )
			if tableCount( available ) == 0 then
				fallback( finalOptions, finalRemaining, finalProbability )
				return
			end
			for _, option in ipairs( available ) do
				local nextOptions = copyArray( finalOptions )
				table.insert( nextOptions, option )
				replacements( nextOptions, removeName( names, option.ItemName ),
					removeCandidateNames( finalRemaining, { option } ),
					finalProbability / tableCount( available ) )
			end
		end
		replacements( options, chosenPriority, remaining, probability )
	end

	local function fill( options, remaining, attempts, chosenPriority, probability )
		if yieldWork ~= nil then yieldWork() end
		if attempts <= 0 or tableCount( options ) >= TOTAL_CHOICES then
			finish( options, remaining, chosenPriority, probability )
			return
		end
		local transitions = drawTransitions( remaining, lootData )
		if tableCount( transitions ) == 0 then
			finish( options, remaining, chosenPriority, probability )
			return
		end
		for _, transition in ipairs( transitions ) do
			if transition.Index == nil then
				fill( options, remaining, attempts - 1, chosenPriority,
					probability * transition.Probability )
			else
				local option = copyOption( remaining[transition.Index] )
				option.Rarity = transition.Rarity
				local nextOptions = copyArray( options )
				table.insert( nextOptions, option )
				fill( nextOptions, removeCandidateAt( remaining, transition.Index ),
					attempts - 1, chosenPriority,
					probability * transition.Probability )
			end
		end
	end

	for _, seed in ipairs( seeds ) do
		local rarityStates = {}
		assignPriorityRarities( copyArray( seed.Options ), 1,
			seed.Probability, rarityStates, lootData )
		for _, rarityState in ipairs( rarityStates ) do
			local remaining = removeCandidateNames( candidates, rarityState.Options )
			fill( rarityState.Options, remaining,
				TOTAL_CHOICES - tableCount( rarityState.Options ),
				seed.ChosenPriority, rarityState.Probability )
		end
	end
	if probabilityTotal <= 0 then return nil end
	return {
		ExpectedScore = expectedTotal / probabilityTotal,
		ImprovementChance = improvementTotal / probabilityTotal,
		OutcomeProbability = probabilityTotal,
		Candidates = tableCount( pool ),
	}
end

local function standardScoreDistribution( option, lootData, scoreCache )
	if option.Rarity ~= nil then
		return { { Score = scoreOptionAtRarity( option, option.Rarity, lootData, scoreCache ),
			Probability = 1 } }
	end
	local outcomes = priorityRarityOutcomes( option, lootData )
	local distribution = {}
	for _, outcome in ipairs( outcomes ) do
		table.insert( distribution, {
			Score = scoreOptionAtRarity( option, outcome.Rarity, lootData, scoreCache ),
			Probability = outcome.Probability,
		} )
	end
	return distribution
end

local function subsetMetrics( subset, distributions, currentBest, meaningful )
	local expected, improved = 0, 0
	local target = currentBest ~= nil and currentBest + meaningful or nil
	local function visit( index, probability, best )
		if index > tableCount( subset ) then
			expected = expected + best * probability
			if target ~= nil and best >= target then improved = improved + probability end
			return
		end
		for _, outcome in ipairs( distributions[subset[index]] ) do
			visit( index + 1, probability * outcome.Probability,
				best == nil and outcome.Score or math.max( best, outcome.Score ) )
		end
	end
	visit( 1, 1, nil )
	return expected, improved
end

local function forecastUniformPool( lootData, pool, excludedName, currentBest, method )
	local excluded = {}
	if excludedName ~= nil then excluded[excludedName] = true end
	local candidates = removeNamedOptions( pool, excluded )
	local count = visibleChoiceCount( math.min( TOTAL_CHOICES, tableCount( candidates ) ) )
	if count <= 0 then return nil end
	local subsets = combinations( candidates, count )
	local distributions = {}
	local scoreCache = {}
	for _, option in ipairs( candidates ) do
		distributions[option] = standardScoreDistribution( option, lootData, scoreCache )
	end
	local expected, improved = 0, 0
	local meaningful = BoonAdvisor.Config.RerollMeaningfulImprovement or 1
	for _, subset in ipairs( subsets ) do
		local subsetExpected, subsetImproved = subsetMetrics(
			subset, distributions, currentBest, meaningful )
		expected = expected + subsetExpected
		improved = improved + subsetImproved
	end
	return {
		ExpectedScore = expected / tableCount( subsets ),
		ImprovementChance = improved / tableCount( subsets ),
		OutcomeProbability = 1,
		Candidates = tableCount( candidates ),
		Method = method or "exact",
	}
end

local function chaosRarityDistribution( permanentName, temporaryName, lootData, scoreCache )
	local option = { ItemName = permanentName, SecondaryItemName = temporaryName,
		Type = "TransformingTrait" }
	local levels = TraitData[permanentName] ~= nil
		and TraitData[permanentName].RarityLevels or nil
	if levels ~= nil and tableCount( levels ) == 1 then
		local rarity = sortedKeys( levels )[1]
		return { { Score = scoreOptionAtRarity( option, rarity, lootData, scoreCache ),
			Probability = 1 } }
	end
	local epic = chanceFor( lootData, "Epic" )
	local rare = ( 1 - epic ) * chanceFor( lootData, "Rare" )
	return {
		{ Score = scoreOptionAtRarity( option, "Epic", lootData, scoreCache ),
			Probability = epic },
		{ Score = scoreOptionAtRarity( option, "Rare", lootData, scoreCache ),
			Probability = rare },
		{ Score = scoreOptionAtRarity( option, "Common", lootData, scoreCache ),
			Probability = 1 - epic - rare },
	}
end

--[[
	Vanilla always builds TOTAL_CHOICES Chaos options (GetTotalLootChoices) with
	draw-then-70%-remove curse draws (SetTransformingTraitsOnLoot). When the
	eligible curse pool holds fewer curses than that, the pool can run dry
	mid-screen, and RemoveRandomValue/GetRandomValue on the empty pool hand the
	remaining options no curse at all. The closed-form position algebra in
	chaosExactForecast assumes the pool never empties, so pools smaller than
	TOTAL_CHOICES are integrated by enumerating the (tiny) draw tree instead.
	Index 0 stands for "no curse" throughout.
]]
local NO_CURSE = 0

local function chaosCurseSequences( poolSize, drawCount )
	local results = {}
	local function step( pool, sequence, probability )
		if #sequence == drawCount then
			local curses = {}
			for index, curseIndex in ipairs( sequence ) do curses[index] = curseIndex end
			table.insert( results, { Probability = probability, Curses = curses } )
			return
		end
		if #pool == 0 then
			table.insert( sequence, NO_CURSE )
			step( pool, sequence, probability )
			table.remove( sequence )
			return
		end
		for position = 1, #pool do
			local drawn = probability / #pool
			table.insert( sequence, pool[position] )
			local remaining = {}
			for other = 1, #pool do
				if other ~= position then table.insert( remaining, pool[other] ) end
			end
			step( remaining, sequence, drawn * CHAOS_CURSE_REMOVE_CHANCE )
			step( pool, sequence, drawn * ( 1 - CHAOS_CURSE_REMOVE_CHANCE ) )
			table.remove( sequence )
		end
	end
	local pool = {}
	for index = 1, poolSize do pool[index] = index end
	step( pool, {}, 1 )
	return results
end

-- The visible options are a uniformly random size-`visible` subset of the
-- built options (CreateBoonLootButtons removes CalcNumLootChoices indexes
-- from blockedIndexes at random), the same averaging the closed forms use.
local function positionSubsets( total, size )
	local subsets = {}
	if size <= 1 then
		for a = 1, total do table.insert( subsets, { a } ) end
	elseif size == 2 then
		for a = 1, total do
			for b = a + 1, total do table.insert( subsets, { a, b } ) end
		end
	else
		local all = {}
		for a = 1, total do table.insert( all, a ) end
		table.insert( subsets, all )
	end
	return subsets
end

-- Sum of prod_i q[blessing_i][curses[i]] over ordered tuples of distinct
-- blessings, via inclusion-exclusion, keeping the blessing side O(#blessings).
-- Symmetric in the curse entries.
local function distinctBlessingSum( q, permanentCount, curses )
	if #curses == 1 then
		local sum1 = 0
		for b = 1, permanentCount do sum1 = sum1 + q[b][curses[1]] end
		return sum1
	end
	if #curses == 2 then
		local sum1, sum2, dot12 = 0, 0, 0
		for b = 1, permanentCount do
			local x, y = q[b][curses[1]], q[b][curses[2]]
			sum1, sum2, dot12 = sum1 + x, sum2 + y, dot12 + x * y
		end
		return sum1 * sum2 - dot12
	end
	local sum1, sum2, sum3 = 0, 0, 0
	local dot12, dot13, dot23, triple = 0, 0, 0, 0
	for b = 1, permanentCount do
		local x, y, z = q[b][curses[1]], q[b][curses[2]], q[b][curses[3]]
		sum1, sum2, sum3 = sum1 + x, sum2 + y, sum3 + z
		dot12, dot13, dot23 = dot12 + x * y, dot13 + x * z, dot23 + y * z
		triple = triple + x * y * z
	end
	return sum1 * sum2 * sum3 - dot12 * sum3 - dot13 * sum2 - dot23 * sum1
		+ 2 * triple
end

local function chaosExactForecast( lootData, currentBest )
	local choiceData = staticChoiceData( lootData ) or lootData
	local permanent = {}
	local temporary = {}
	for _, traitName in ipairs( choiceData.PermanentTraits or {} ) do
		if isEligible( TraitData[traitName], false ) then table.insert( permanent, traitName ) end
	end
	for _, traitName in ipairs( choiceData.TemporaryTraits or {} ) do
		if isEligible( TraitData[traitName], false ) then table.insert( temporary, traitName ) end
	end
	if tableCount( permanent ) < TOTAL_CHOICES or tableCount( temporary ) == 0 then return nil end

	local visible = visibleChoiceCount( TOTAL_CHOICES )
	local permanentCount = tableCount( permanent )
	local temporaryCount = tableCount( temporary )
	local smallPool = temporaryCount < TOTAL_CHOICES

	local scoreCache = {}
	local distributions = {}
	local support = {}
	for permanentIndex, permanentName in ipairs( permanent ) do
		distributions[permanentIndex] = {}
		for temporaryIndex, temporaryName in ipairs( temporary ) do
			local distribution = chaosRarityDistribution(
				permanentName, temporaryName, lootData, scoreCache )
			distributions[permanentIndex][temporaryIndex] = distribution
			for _, outcome in ipairs( distribution ) do support[outcome.Score] = true end
		end
		if smallPool then
			local distribution = chaosRarityDistribution(
				permanentName, nil, lootData, scoreCache )
			distributions[permanentIndex][NO_CURSE] = distribution
			for _, outcome in ipairs( distribution ) do support[outcome.Score] = true end
		end
	end

	-- Weighted curse tuples for the small-pool enumeration: every draw
	-- sequence crossed with every visible subset, merged by (sorted) tuple.
	local curseTuples = nil
	local orderedBlessingTuples = nil
	if smallPool then
		curseTuples = {}
		local merged = {}
		local subsets = positionSubsets( TOTAL_CHOICES, visible )
		local subsetWeight = 1 / #subsets
		for _, sequence in ipairs( chaosCurseSequences( temporaryCount, TOTAL_CHOICES ) ) do
			for _, subset in ipairs( subsets ) do
				local curses = {}
				for index, position in ipairs( subset ) do
					curses[index] = sequence.Curses[position]
				end
				table.sort( curses )
				local key = table.concat( curses, ":" )
				local entry = merged[key]
				if entry == nil then
					entry = { Probability = 0, Curses = curses }
					merged[key] = entry
					table.insert( curseTuples, entry )
				end
				entry.Probability = entry.Probability
					+ sequence.Probability * subsetWeight
			end
		end
		orderedBlessingTuples = 1
		for index = 0, visible - 1 do
			orderedBlessingTuples = orderedBlessingTuples * ( permanentCount - index )
		end
	end

	local function cdf( limit, strict )
		-- Collapse the three rarity outcomes into one CDF value per blessing and
		-- curse pair once. The screen calculation below then becomes small matrix
		-- arithmetic rather than millions of repeated table walks.
		local function chanceBelow( distribution )
			local chance = 0
			for _, outcome in ipairs( distribution ) do
				if strict and outcome.Score < limit
					or not strict and outcome.Score <= limit then
					chance = chance + outcome.Probability
				end
			end
			return chance
		end
		local q = {}
		local sums = {}
		for permanentIndex = 1, permanentCount do
			q[permanentIndex] = {}
			for temporaryIndex = 1, tableCount( temporary ) do
				local chance = chanceBelow( distributions[permanentIndex][temporaryIndex] )
				q[permanentIndex][temporaryIndex] = chance
				sums[temporaryIndex] = ( sums[temporaryIndex] or 0 ) + chance
			end
			if smallPool then
				q[permanentIndex][NO_CURSE] =
					chanceBelow( distributions[permanentIndex][NO_CURSE] )
			end
		end
		if smallPool then
			local total = 0
			for _, entry in ipairs( curseTuples ) do
				total = total + entry.Probability
					* distinctBlessingSum( q, permanentCount, entry.Curses )
			end
			total = total / orderedBlessingTuples
			if total < 0 then return 0 end
			if total > 1 then return 1 end
			return total
		end
		local dots = {}
		local sumS = 0
		for temporaryIndex = 1, temporaryCount do sumS = sumS + sums[temporaryIndex] end
		local sumD = 0
		for temporary1 = 1, tableCount( temporary ) do
			dots[temporary1] = {}
			for temporary2 = 1, tableCount( temporary ) do
				local dot = 0
				for permanentIndex = 1, permanentCount do
					dot = dot + q[permanentIndex][temporary1]
						* q[permanentIndex][temporary2]
				end
				dots[temporary1][temporary2] = dot
				sumD = sumD + dot
			end
		end

		local total
		if visible == 1 then
			-- Every position is marginally uniform over blessings and curses.
			total = sumS / ( permanentCount * temporaryCount )
		elseif visible == 2 then
			local sameNumerator = 0
			for temporaryIndex = 1, temporaryCount do
				sameNumerator = sameNumerator + sums[temporaryIndex] ^ 2
					- dots[temporaryIndex][temporaryIndex]
			end
			local allNumerator = sumS ^ 2 - sumD
			local differentNumerator = allNumerator - sameNumerator
			local keep = 1 - CHAOS_CURSE_REMOVE_CHANCE
			local same12 = keep / temporaryCount
			local same23 = keep * ( keep / temporaryCount
				+ CHAOS_CURSE_REMOVE_CHANCE / ( temporaryCount - 1 ) )
			local same13 = keep * (
				keep / ( temporaryCount * temporaryCount )
				+ ( temporaryCount - 1 ) / temporaryCount * (
					keep / temporaryCount
					+ CHAOS_CURSE_REMOVE_CHANCE / ( temporaryCount - 1 ) ) )
			local sameChance = ( same12 + same13 + same23 ) / 3
			local pairDenominator = permanentCount * ( permanentCount - 1 )
			total = ( sameChance / temporaryCount * sameNumerator
				+ ( 1 - sameChance ) / ( temporaryCount * ( temporaryCount - 1 ) )
					* differentNumerator ) / pairDenominator
		else
			-- The curse sequence has only five symmetry classes: aaa, aab,
			-- aba, abb and abc. Sum each class algebraically instead of walking
			-- every blessing/curse triple for every possible score threshold.
			local rowCube, rowSquareTimesSum = 0, 0
			local diagonalTriple = 0
			for permanentIndex = 1, permanentCount do
				local rowSum, rowSquare = 0, 0
				for temporaryIndex = 1, temporaryCount do
					local value = q[permanentIndex][temporaryIndex]
					rowSum = rowSum + value
					rowSquare = rowSquare + value * value
					diagonalTriple = diagonalTriple + value * value * value
				end
				rowCube = rowCube + rowSum ^ 3
				rowSquareTimesSum = rowSquareTimesSum + rowSquare * rowSum
			end
			local diagonalNumerator = 0
			local sumSquares, sumDiagonalDots, weightedDots = 0, 0, 0
			for temporary1 = 1, temporaryCount do
				local sumDotRow = 0
				for temporary2 = 1, temporaryCount do
					sumDotRow = sumDotRow + dots[temporary1][temporary2]
				end
				sumSquares = sumSquares + sums[temporary1] ^ 2
				sumDiagonalDots = sumDiagonalDots + dots[temporary1][temporary1]
				weightedDots = weightedDots + sums[temporary1] * sumDotRow
				diagonalNumerator = diagonalNumerator
					+ sums[temporary1] ^ 3
					- 3 * dots[temporary1][temporary1] * sums[temporary1]
			end
			diagonalNumerator = diagonalNumerator + 2 * diagonalTriple
			local repeatedAllNumerator = sumSquares * sumS
				- sumDiagonalDots * sumS - 2 * weightedDots
				+ 2 * rowSquareTimesSum
			local repeatedNumerator = repeatedAllNumerator - diagonalNumerator
			local allNumerator = sumS ^ 3 - 3 * sumD * sumS + 2 * rowCube
			local distinctNumerator = allNumerator - diagonalNumerator
				- 3 * repeatedNumerator

			local remove = CHAOS_CURSE_REMOVE_CHANCE
			local keep = 1 - remove
			local count = temporaryCount
			local aaa = keep * keep / ( count ^ 3 )
			local aab = keep / ( count ^ 2 )
				* ( keep / count + remove / ( count - 1 ) )
			local aba = aab
			local abb = keep * keep / ( count ^ 3 )
				+ remove * keep / ( count * ( count - 1 ) ^ 2 )
			local abc = 1 / count * (
				keep * keep / ( count ^ 2 )
				+ keep * remove / ( count * ( count - 1 ) )
				+ remove * keep / ( ( count - 1 ) ^ 2 )
				+ remove * remove / ( ( count - 1 ) * ( count - 2 ) ) )
			local permanentDenominator = permanentCount * ( permanentCount - 1 )
				* ( permanentCount - 2 )
			total = ( aaa * diagonalNumerator
				+ ( aab + aba + abb ) * repeatedNumerator
				+ abc * distinctNumerator ) / permanentDenominator
		end
		if total < 0 then return 0 end
		if total > 1 then return 1 end
		return total
	end

	local scores = {}
	for value, _ in pairs( support ) do table.insert( scores, value ) end
	table.sort( scores )
	local expected, previous = 0, 0
	for _, value in ipairs( scores ) do
		local cumulative = cdf( value, false )
		expected = expected + value * ( cumulative - previous )
		previous = cumulative
	end
	local meaningful = BoonAdvisor.Config.RerollMeaningfulImprovement or 1
	local target = currentBest ~= nil and currentBest + meaningful or nil
	return {
		ExpectedScore = expected,
		ImprovementChance = target ~= nil and 1 - cdf( target, true ) or 0,
		OutcomeProbability = previous,
		Candidates = permanentCount * tableCount( temporary ),
		Method = "exact-chaos",
	}
end

local function isTransformingPool( lootData, pool )
	local choiceData = staticChoiceData( lootData )
	if choiceData ~= nil and choiceData.TransformingTraits then return true end
	for _, option in ipairs( pool or {} ) do
		if option.Type == "TransformingTrait" or option.SecondaryItemName ~= nil then return true end
	end
	return false
end

local function forecastSignature( lootData, pool, mode, currentBest, exclusions,
	contextKey, preparedContext, preparedPoolFingerprint )
	local parts = {
		"v2", tostring( mode ), tostring( lootData.Name ),
		"stack=" .. tostring( lootData.StackNum or 1 ),
		"best=" .. tostring( currentBest ),
		"context=" .. tostring( contextKey ),
		preparedContext or scoringContextSignature( lootData ),
		preparedPoolFingerprint or poolFingerprint( pool ),
	}
	for _, name in ipairs( exclusions or {} ) do table.insert( parts, "exclude=" .. tostring( name ) ) end
	for _, option in pairs( lootData.UpgradeOptions or {} ) do
		table.insert( parts, "shown=" .. optionKey( option ) .. "@"
			.. tostring( option.Rarity ) .. ":" .. tostring( option.Blocked ) )
	end
	return table.concat( parts, "|" )
end

function BoonAdvisor.ForecastExactOffer( lootData, args )
	args = args or {}
	if lootData == nil or BoonAdvisor.ScoreOption == nil then return nil end
	BoonAdvisor.BuildOfferIndex()
	ensureForecastCache()
	local pool, customPool
	if args.PreparedPool ~= nil then
		pool = args.PreparedPool
		customPool = args.PreparedCustomPool == true
	else
		pool, customPool = eligiblePool( lootData )
	end
	if args.ExcludeDuo then
		local filtered = {}
		for _, option in ipairs( pool ) do
			if BoonAdvisor.KindOf == nil
				or BoonAdvisor.KindOf( option.ItemName ) ~= "Duo" then
				table.insert( filtered, option )
			end
		end
		pool = filtered
	end
	if tableCount( pool ) == 0 then return nil end
	local exclusions = copyArray( args.ExclusionNames )
	local signature = forecastSignature( lootData, pool, args.Mode or "initial",
		args.CurrentBest, exclusions, args.ContextKey,
		args.PreparedContext, args.PreparedPoolFingerprint )
	local cached = cachedForecast( signature )
	if cached ~= nil then return cached end

	local transforming = isTransformingPool( lootData, pool )
	local result
	if transforming and not customPool then
		result = chaosExactForecast( lootData, args.CurrentBest )
	elseif customPool then
		local excluded = transforming and nil or exclusions[1]
		result = forecastUniformPool( lootData, pool, excluded,
			args.CurrentBest, transforming and "exact-chaos" or "exact" )
	else
		result = forecastOrdinaryScenario( lootData, pool, exclusions[1],
			args.CurrentBest, args.ScoreCache, args.YieldWork )
		if result ~= nil then result.Method = "exact" end
	end
	if result == nil then return nil end
	result.Samples = 0
	result.Signature = signature
	result.CacheHit = false
	return storeForecast( signature, result )
end

function BoonAdvisor.ForecastInitialOffer( lootData, contextKey, args )
	args = args or {}
	return BoonAdvisor.ForecastExactOffer( lootData,
		{ Mode = "initial", ContextKey = contextKey,
			ExcludeDuo = args.ExcludeDuo, YieldWork = args.YieldWork } )
end

function BoonAdvisor.ForecastRerollOffer( lootData, currentBest, args )
	args = args or {}
	ensureForecastCache()
	local choiceNames = {}
	for _, option in pairs( lootData ~= nil and lootData.UpgradeOptions or {} ) do
		if option.ItemName ~= nil then table.insert( choiceNames, option.ItemName ) end
	end
	if tableCount( choiceNames ) == 0 then choiceNames = { false } end
	local perfStarted = BoonAdvisor.PerfStart ~= nil
		and BoonAdvisor.PerfStart( args.PerfSession ) or nil
	local pool, customPool = eligiblePool( lootData )
	if BoonAdvisor.PerfLap ~= nil then
		BoonAdvisor.PerfLap( args.PerfSession, "eligible_pool", perfStarted )
	end
	local transforming = isTransformingPool( lootData, pool )
	if transforming then choiceNames = { false } end
	-- Every exclusion scenario shares the same build, rarity context and legal
	-- pool. Preparing those once also lets all scenarios reuse option scores.
	perfStarted = BoonAdvisor.PerfStart ~= nil
		and BoonAdvisor.PerfStart( args.PerfSession ) or nil
	local preparedContext = scoringContextSignature( lootData )
	if BoonAdvisor.PerfLap ~= nil then
		BoonAdvisor.PerfLap( args.PerfSession, "context_signature", perfStarted )
	end
	perfStarted = BoonAdvisor.PerfStart ~= nil
		and BoonAdvisor.PerfStart( args.PerfSession ) or nil
	local preparedPoolFingerprint = poolFingerprint( pool )
	if BoonAdvisor.PerfLap ~= nil then
		BoonAdvisor.PerfLap( args.PerfSession, "pool_fingerprint", perfStarted )
	end
	local scoreCache = {}
	local workSinceYield = 0
	local function yieldWork()
		if not args.YieldWithinScenarios or wait == nil then return end
		workSinceYield = workSinceYield + 1
		local limit = BoonAdvisor.Config.RerollForecastWorkPerFrame or 256
		if workSinceYield >= limit then
			workSinceYield = 0
			wait( args.YieldDuration or 0.01 )
		end
	end
	local expected, improved, scenarios, candidates = 0, 0, 0, 0
	local method = transforming and "exact-chaos" or "exact"
	for choiceIndex, excludedName in ipairs( choiceNames ) do
		local exclusions = excludedName ~= false and { excludedName } or {}
		perfStarted = BoonAdvisor.PerfStart ~= nil
			and BoonAdvisor.PerfStart( args.PerfSession ) or nil
		local result = BoonAdvisor.ForecastExactOffer( lootData, {
			Mode = "reroll", CurrentBest = currentBest, ExclusionNames = exclusions,
			PreparedPool = pool, PreparedCustomPool = customPool,
			PreparedContext = preparedContext,
			PreparedPoolFingerprint = preparedPoolFingerprint,
			ScoreCache = scoreCache,
			YieldWork = yieldWork,
		} )
		if BoonAdvisor.PerfLap ~= nil then
			BoonAdvisor.PerfLap( args.PerfSession,
				"scenario_" .. tostring( choiceIndex ), perfStarted )
		end
		if result ~= nil then
			expected = expected + result.ExpectedScore
			improved = improved + result.ImprovementChance
			candidates = math.max( candidates, result.Candidates or 0 )
			method = result.Method or method
			scenarios = scenarios + 1
		end
		-- In the live boon menu each exclusion is independent. Let the game draw
		-- a frame between them so exact advice never blocks the opening animation.
		if args.YieldBetweenScenarios and wait ~= nil
			and choiceIndex < tableCount( choiceNames ) then
			wait( args.YieldDuration or 0.01 )
		end
	end
	if scenarios == 0 then return nil end
	return {
		ExpectedScore = expected / scenarios,
		ImprovementChance = improved / scenarios,
		Samples = 0,
		Candidates = candidates,
		Method = method,
	}
end

BoonAdvisor.BuildOfferIndex()
