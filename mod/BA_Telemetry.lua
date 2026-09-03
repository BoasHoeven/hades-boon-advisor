-- BoonAdvisor - local decision and run telemetry.
--
-- Every line is "[tag  ] <context> key=value ... | option | option | build=".
-- Free-text values are quoted. Trait names are the game's internal names so
-- tools/analyze_runs.py can join offers, choices, and builds regardless of
-- the game language.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local function telemetryEnabled()
	return BoonAdvisor.Config ~= nil and BoonAdvisor.Config.LogPicks
end

local function quote( text )
	if BoonAdvisor.LogQuote ~= nil then return BoonAdvisor.LogQuote( text ) end
	return '"' .. tostring( text or "" ) .. '"'
end

function BoonAdvisor.RunNumber()
	if GameState ~= nil and type( GameState.RunHistory ) == "table" then
		return TableLength( GameState.RunHistory ) + 1
	end
	return "?"
end

function BoonAdvisor.BuildSnapshot( run )
	run = run or CurrentRun
	local hero = run ~= nil and run.Hero or nil
	if hero == nil or type( hero.Traits ) ~= "table" then
		return "none"
	end

	local entries = {}
	local byName = {}
	for _, trait in pairs( hero.Traits ) do
		local name = trait.Name
		local data = name ~= nil and TraitData[name] or nil
		if name ~= nil and trait.RemainingUses == nil
			and ( data == nil or data.Slot ~= "Keepsake" ) then
			local entry = byName[name]
			if entry == nil then
				entry = { Name = name, Count = 0, Rarity = trait.Rarity }
				byName[name] = entry
				table.insert( entries, entry )
			end
			entry.Count = entry.Count + 1
			entry.Rarity = entry.Rarity or trait.Rarity
		end
	end

	table.sort( entries, function( a, b ) return a.Name < b.Name end )
	local parts = {}
	for _, entry in ipairs( entries ) do
		local text = entry.Name
		if entry.Rarity ~= nil then
			text = text .. "@" .. tostring( entry.Rarity )
		end
		if entry.Count > 1 then
			text = text .. "x" .. entry.Count
		end
		table.insert( parts, text )
	end
	if IsEmpty( parts ) then return "none" end
	return table.concat( parts, "," )
end

--[[
	A short hash of everything the scores depend on that is not run state:
	the tuning weights and every ratings table. It stamps each session so the
	analyzer never mixes lines produced by two different tunings.
]]
local function serialize( value, out, seen )
	local kind = type( value )
	if kind == "table" then
		seen = seen or {}
		if seen[value] then table.insert( out, "<cycle>" ) return end
		seen[value] = true
		local keys = {}
		for key, _ in pairs( value ) do table.insert( keys, key ) end
		table.sort( keys, function( a, b ) return tostring( a ) < tostring( b ) end )
		table.insert( out, "{" )
		for _, key in ipairs( keys ) do
			table.insert( out, tostring( key ) .. "=" )
			serialize( value[key], out, seen )
			table.insert( out, ";" )
		end
		table.insert( out, "}" )
	elseif kind == "function" then
		table.insert( out, "<fn>" )
	else
		table.insert( out, tostring( value ) )
	end
end

function BoonAdvisor.ConfigFingerprint()
	if BoonAdvisor.ConfigFingerprintCache ~= nil then
		return BoonAdvisor.ConfigFingerprintCache
	end
	local out = {}
	serialize( BoonAdvisor.Config ~= nil and BoonAdvisor.Config.Weights or {}, out )
	serialize( BoonAdvisor.Config ~= nil and BoonAdvisor.Config.Doors or {}, out )
	serialize( BoonAdvisor.Ratings or {}, out )
	local text = table.concat( out )
	local hash = 2166136261
	for index = 1, string.len( text ) do
		hash = ( ( hash * 16777619 ) % 4294967296 + string.byte( text, index ) ) % 4294967296
	end
	BoonAdvisor.ConfigFingerprintCache = string.format( "%08x", hash )
	return BoonAdvisor.ConfigFingerprintCache
end

local function doorName( exitDoor )
	if BoonAdvisor.IsChaosGate( exitDoor ) then return "ChaosGate" end
	local room = exitDoor ~= nil and exitDoor.Room or nil
	if room == nil then return "Unknown" end
	return room.ForceLootName or room.ChosenRewardType or room.Name or "Story"
end

function BoonAdvisor.LogDoorChoice( chosenDoor )
	if not telemetryEnabled() or chosenDoor == nil then return end
	local bestId = BoonAdvisor.BestDoorObjectId()
	local entries = {}
	local bestScore, takenScore = nil, nil
	for doorId, exitDoor in pairs( BoonAdvisor.DoorCandidates or {} ) do
		if BoonAdvisor.IsDoorAdvisorVisible( exitDoor ) then
			local cached = BoonAdvisor.LastDoorEvaluations ~= nil
				and BoonAdvisor.LastDoorEvaluations[doorId] or nil
			local score = cached ~= nil and cached.RawScore
				or BoonAdvisor.ScoreDoorCandidate( exitDoor )
			local blockReason = cached ~= nil and cached.BlockReason
				or BoonAdvisor.DoorBlockReason( exitDoor )
			local shown = math.floor( BoonAdvisor.Finalize( score ) )
			local flags = ""
			if doorId == chosenDoor.ObjectId then
				flags = flags .. ">"
				takenScore = shown
			end
			if doorId == bestId then
				flags = flags .. "*"
				bestScore = shown
			end
			local text = flags .. doorName( exitDoor ) .. "=" .. shown
			if blockReason ~= nil then text = text .. "[" .. blockReason .. "]" end
			table.insert( entries, text )
		end
	end
	table.sort( entries )
	local margin = ( bestScore ~= nil and takenScore ~= nil )
		and ( bestScore - takenScore ) or "?"
	BoonAdvisor.LogLine( "[door ] " .. BoonAdvisor.LogContext()
		.. " took=" .. doorName( chosenDoor )
		.. " margin=" .. tostring( margin )
		.. " followed=" .. tostring( bestId ~= nil and chosenDoor.ObjectId == bestId )
		.. " reroll=" .. tostring( BoonAdvisor.LastDoorRerollAdvised == true )
		.. " | " .. table.concat( entries, " | " )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

--[[
	One line per room, written as the room is left. This is the finest
	outcome the log records: with it a few runs become a few hundred samples
	of "what happened in the rooms after each decision". Every field comes
	from state the game already tracks (RoomManager, Combat).
]]
function BoonAdvisor.LogRoomOutcome( run, door )
	if not telemetryEnabled() then return end
	run = run or CurrentRun
	local room = run ~= nil and run.CurrentRoom or nil
	if room == nil then return end
	local encounter = room.Encounter or {}
	local damage = 0
	for _, amount in pairs( type( DamageRecord ) == "table" and DamageRecord or {} ) do
		if type( amount ) == "number" then damage = damage + amount end
	end
	local clearTime = encounter.ClearTime
	local timer = run.ActiveBiomeTimer and run.BiomeTime or nil
	BoonAdvisor.LogLine( "[room ] " .. BoonAdvisor.LogContext( run )
		.. " room=" .. tostring( room.Name or "?" )
		.. " encounter=" .. tostring( encounter.Name or "none" )
		.. " type=" .. tostring( encounter.EncounterType or "?" )
		.. " clear=" .. ( type( clearTime ) == "number"
			and tostring( math.floor( clearTime * 10 + 0.5 ) / 10 ) or "-" )
		.. " damage_taken=" .. tostring( math.floor( damage + 0.5 ) )
		.. " hit=" .. tostring( encounter.PlayerTookDamage == true )
		.. " timer=" .. ( type( timer ) == "number"
			and tostring( math.floor( timer ) ) or "-" )
		.. " next=" .. tostring( door ~= nil and doorName( door ) or "?" ) )
end

local function scoredShopItem( item, money )
	local score, reason = BoonAdvisor.ScoreShopItem( item.ItemData )
	local affordable = true
	local cost = item.Cost
	if cost ~= nil and cost > 0 and money ~= nil then
		if cost > money then
			affordable = false
			score = score - BoonAdvisor.Config.Shop.UnaffordablePenalty
			reason = "need " .. ( cost - money ) .. " more gold"
		else
			score = score - ( BoonAdvisor.Config.Shop.CostWeight * ( cost / money ) )
		end
	end
	return math.floor( BoonAdvisor.Finalize( score ) ), affordable, reason
end

local function logStockLine( tag, chosenName, entries, chosenId, bestId )
	local parts = {}
	local bestScore, takenScore = nil, nil
	for _, entry in ipairs( entries ) do
		local flags = ""
		if entry.ObjectId == chosenId then
			flags = flags .. ">"
			takenScore = entry.Score
		end
		if entry.ObjectId == bestId then
			flags = flags .. "*"
			bestScore = entry.Score
		end
		local availability = entry.Affordable and "" or "[unaffordable]"
		table.insert( parts, flags .. entry.Name .. "=" .. entry.Score
			.. "@" .. entry.Cost .. availability )
	end
	table.sort( parts )
	local margin = ( bestScore ~= nil and takenScore ~= nil )
		and ( bestScore - takenScore ) or "?"
	BoonAdvisor.LogLine( tag .. BoonAdvisor.LogContext()
		.. " took=" .. tostring( chosenName )
		.. " margin=" .. tostring( margin )
		.. " followed=" .. tostring( bestId ~= nil and chosenId == bestId )
		.. " | " .. table.concat( parts, " | " )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogShopChoice( chosenObjectId )
	if not telemetryEnabled() or chosenObjectId == nil
		or BoonAdvisor.ShopItems == nil then return end
	BoonAdvisor.LoggedShopChoices = BoonAdvisor.LoggedShopChoices or {}
	if BoonAdvisor.LoggedShopChoices[chosenObjectId] then return end

	local money = CurrentRun ~= nil and CurrentRun.Money or nil
	local entries = {}
	local bestObjectId, bestScore = nil, nil
	local chosenName = "Unknown"
	for _, item in ipairs( BoonAdvisor.ShopItems ) do
		local score, affordable = scoredShopItem( item, money )
		if affordable and ( bestScore == nil or score > bestScore ) then
			bestScore = score
			bestObjectId = item.ObjectId
		end
		local name = item.ItemData ~= nil and item.ItemData.Name or "Unknown"
		if item.ItemData ~= nil and item.ItemData.Args ~= nil
			and item.ItemData.Args.ForceLootName ~= nil then
			name = name .. ":" .. tostring( item.ItemData.Args.ForceLootName )
		end
		if item.ObjectId == chosenObjectId then chosenName = name end
		table.insert( entries, { ObjectId = item.ObjectId, Name = name,
			Score = score, Affordable = affordable, Cost = item.Cost or 0 } )
	end

	if chosenName == "Unknown" then return end
	BoonAdvisor.LoggedShopChoices[chosenObjectId] = true
	logStockLine( "[shop ] ", chosenName, entries, chosenObjectId, bestObjectId )
end

-- Well of Charon purchase. Called before vanilla destroys the button, and
-- only for a purchase vanilla will accept.
function BoonAdvisor.LogWellChoice( button )
	if not telemetryEnabled() or button == nil or button.Data == nil then return end
	local data = button.Data
	local money = CurrentRun ~= nil and CurrentRun.Money or nil
	if data.Cost ~= nil and money ~= nil and money < data.Cost then return end
	local health = CurrentRun ~= nil and CurrentRun.Hero ~= nil
		and CurrentRun.Hero.Health or nil
	if data.HealthCost ~= nil and health ~= nil and health <= data.HealthCost then return end
	local results, bestIndex = BoonAdvisor.EvaluateWellButtons()
	if results == nil then return end
	local entries = {}
	for index, result in pairs( results ) do
		table.insert( entries, { ObjectId = index, Name = result.Name,
			Score = math.floor( result.Score ), Affordable = result.Affordable,
			Cost = result.Cost } )
	end
	logStockLine( "[well ] ", data.Name, entries, button.Index, bestIndex )
end

-- Pool of Purging sale. Called before vanilla removes the boon.
function BoonAdvisor.LogPurgeChoice( screen, button )
	if not telemetryEnabled() or button == nil or button.UpgradeName == nil then return end
	local components = screen ~= nil and screen.Components or nil
	if components == nil then return end
	local entries = {}
	local bestIndex, bestRaw = nil, nil
	local chosenIndex = nil
	for index = 1, 3 do
		local candidate = components["PurchaseButton" .. tostring( index )]
		if candidate ~= nil and candidate.UpgradeName ~= nil then
			local result = BoonAdvisor.ScorePurgeTrait( candidate.UpgradeName )
			if bestRaw == nil or result.RawScore > bestRaw then
				bestRaw = result.RawScore
				bestIndex = index
			end
			if candidate == button or candidate.UpgradeName == button.UpgradeName then
				chosenIndex = index
			end
			table.insert( entries, { ObjectId = index, Name = candidate.UpgradeName,
				Score = result.Score, Affordable = true, Cost = candidate.Value or 0 } )
		end
	end
	if chosenIndex == nil then return end
	logStockLine( "[purge] ", button.UpgradeName, entries, chosenIndex, bestIndex )
end

function BoonAdvisor.LogStoryChoice( choiceKey )
	if not telemetryEnabled()
		or BoonAdvisor.StoryChoiceGroupByKey[choiceKey] == nil then return end
	local result = BoonAdvisor.ScoreStoryChoice( choiceKey )
	local best = BoonAdvisor.BestStoryChoiceKey( choiceKey )
	if result == nil then return end
	local bestResult = best ~= nil and best ~= choiceKey
		and BoonAdvisor.ScoreStoryChoice( best ) or result
	local margin = bestResult ~= nil and ( bestResult.Score - result.Score ) or 0
	BoonAdvisor.LogLine( "[story] " .. BoonAdvisor.LogContext()
		.. " took=" .. choiceKey
		.. " score=" .. result.Score .. "(" .. result.Rank .. ")"
		.. " recommended=" .. tostring( best )
		.. " margin=" .. tostring( margin )
		.. " followed=" .. tostring( best == choiceKey )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogKeepsakeChoice( chosenName )
	if not telemetryEnabled() or chosenName == nil then return end
	local evaluation = BoonAdvisor.LastKeepsakeEvaluation
	if evaluation == nil or evaluation.Results == nil then return end
	local entries = {}
	local bestScore, takenScore = nil, nil
	for name, result in pairs( evaluation.Results ) do
		if result.Selectable then
			local flags = ""
			local shown = math.floor( result.FinalScore )
			if name == chosenName then
				flags = flags .. ">"
				takenScore = shown
			end
			if name == evaluation.BestName then
				flags = flags .. "*"
				bestScore = shown
			end
			table.insert( entries, flags .. name .. "=" .. shown )
		end
	end
	table.sort( entries )
	local margin = ( bestScore ~= nil and takenScore ~= nil )
		and ( bestScore - takenScore ) or "?"
	BoonAdvisor.LogLine( "[keep ] " .. BoonAdvisor.LogContext()
		.. " from=" .. tostring( evaluation.CurrentName )
		.. " took=" .. chosenName
		.. " recommended=" .. tostring( evaluation.BestName )
		.. " margin=" .. tostring( margin )
		.. " followed=" .. tostring( evaluation.BestName == chosenName )
		.. " stage=" .. tostring( evaluation.Context.Stage )
		.. " | " .. table.concat( entries, " | " )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogReroll( lootData )
	if not telemetryEnabled() then return end
	lootData = lootData or CurrentLootData
	local offer = BoonAdvisor.LastOfferLog
	local bestScore = offer ~= nil and offer.BestScore or 0
	local advised = offer ~= nil and offer.RerollSuggested or false
	local evaluation = offer ~= nil and offer.RerollEvaluation or nil
	local detail = ""
	if evaluation ~= nil and evaluation.Available then
		detail = " expected=" .. tostring( math.floor( evaluation.ExpectedScore ) )
			.. " gain=" .. tostring( math.floor( evaluation.Gain ) )
			.. " chance=" .. tostring( math.floor(
				evaluation.ImprovementChance * 100 + 0.5 ) ) .. "%"
			.. " cost=" .. tostring( evaluation.Cost )
	end
	BoonAdvisor.LogLine( "[reroll] " .. BoonAdvisor.LogContext()
		.. " loot=" .. tostring( lootData ~= nil and lootData.Name or "?" )
		.. " advised=" .. tostring( advised )
		.. " followed=" .. tostring( advised == true )
		.. " best=" .. tostring( math.floor( bestScore ) )
		.. detail
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogRunStart( run )
	if not telemetryEnabled() or run == nil
		or BoonAdvisor.LastRunStartLogged == run then return end
	BoonAdvisor.LastRunStartLogged = run
	BoonAdvisor.LoggedShopChoices = {}
	BoonAdvisor.LogLine( "[run-start] " .. BoonAdvisor.LogContext( run )
		.. " ratings=" .. BoonAdvisor.ConfigFingerprint()
		.. " | build=" .. BoonAdvisor.BuildSnapshot( run ) )
end

function BoonAdvisor.LogRunEnd( run )
	if not telemetryEnabled() or run == nil
		or BoonAdvisor.LastRunEndLogged == run then return end
	BoonAdvisor.LastRunEndLogged = run
	local result = run.Cleared and "clear" or "death"
	local room = run.EndingRoomName
		or ( run.CurrentRoom ~= nil and run.CurrentRoom.Name ) or "?"
	local damage = 0
	for _, amount in pairs( type( run.DamageRecord ) == "table" and run.DamageRecord or {} ) do
		if type( amount ) == "number" then damage = damage + amount end
	end
	local killer = "-"
	if not run.Cleared and LastKilledByUnitName ~= nil then
		killer = tostring( LastKilledByUnitName )
	end
	BoonAdvisor.LogLine( "[run-end] " .. BoonAdvisor.LogContext( run )
		.. " result=" .. result
		.. " time=" .. tostring( math.floor( run.GameplayTime or 0 ) )
		.. " room=" .. tostring( room )
		.. " killer=" .. killer
		.. " damage_taken=" .. tostring( math.floor( damage + 0.5 ) )
		.. " | build=" .. BoonAdvisor.BuildSnapshot( run ) )
end
