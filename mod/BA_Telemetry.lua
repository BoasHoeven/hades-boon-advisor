-- BoonAdvisor - local decision and run telemetry.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local function telemetryEnabled()
	return BoonAdvisor.Config ~= nil and BoonAdvisor.Config.LogPicks
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
	for doorId, exitDoor in pairs( BoonAdvisor.DoorCandidates or {} ) do
		if BoonAdvisor.IsDoorAdvisorVisible( exitDoor ) then
			local cached = BoonAdvisor.LastDoorEvaluations ~= nil
				and BoonAdvisor.LastDoorEvaluations[doorId] or nil
			local score = cached ~= nil and cached.RawScore
				or BoonAdvisor.ScoreDoorCandidate( exitDoor )
			local blockReason = cached ~= nil and cached.BlockReason
				or BoonAdvisor.DoorBlockReason( exitDoor )
			local flags = ""
			if doorId == chosenDoor.ObjectId then flags = flags .. ">" end
			if doorId == bestId then flags = flags .. "*" end
			local text = flags .. doorName( exitDoor ) .. "="
				.. math.floor( BoonAdvisor.Finalize( score ) )
			if blockReason ~= nil then text = text .. "[" .. blockReason .. "]" end
			table.insert( entries, text )
		end
	end
	table.sort( entries )
	BoonAdvisor.LogLine( "[door ] " .. BoonAdvisor.LogContext()
		.. " took=" .. doorName( chosenDoor )
		.. " | " .. table.concat( entries, " | " )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
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
		if item.ObjectId == chosenObjectId then chosenName = name end
		table.insert( entries, { ObjectId = item.ObjectId, Name = name,
			Score = score, Affordable = affordable, Cost = item.Cost or 0 } )
	end

	if chosenName == "Unknown" then return end
	BoonAdvisor.LoggedShopChoices[chosenObjectId] = true
	local parts = {}
	for _, entry in ipairs( entries ) do
		local flags = ""
		if entry.ObjectId == chosenObjectId then flags = flags .. ">" end
		if entry.ObjectId == bestObjectId then flags = flags .. "*" end
		local availability = entry.Affordable and "" or "[unaffordable]"
		table.insert( parts, flags .. entry.Name .. "=" .. entry.Score
			.. "@" .. entry.Cost .. availability )
	end
	table.sort( parts )
	BoonAdvisor.LogLine( "[shop ] " .. BoonAdvisor.LogContext()
		.. " took=" .. chosenName
		.. " | " .. table.concat( parts, " | " )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogStoryChoice( choiceKey )
	if not telemetryEnabled()
		or BoonAdvisor.StoryChoiceGroupByKey[choiceKey] == nil then return end
	local result = BoonAdvisor.ScoreStoryChoice( choiceKey )
	local best = BoonAdvisor.BestStoryChoiceKey( choiceKey )
	if result == nil then return end
	BoonAdvisor.LogLine( "[story] " .. BoonAdvisor.LogContext()
		.. " took=" .. choiceKey
		.. " score=" .. result.Score .. "(" .. result.Rank .. ")"
		.. " recommended=" .. tostring( best )
		.. " followed=" .. tostring( best == choiceKey )
		.. " | build=" .. BoonAdvisor.BuildSnapshot() )
end

function BoonAdvisor.LogKeepsakeChoice( chosenName )
	if not telemetryEnabled() or chosenName == nil then return end
	local evaluation = BoonAdvisor.LastKeepsakeEvaluation
	if evaluation == nil or evaluation.Results == nil then return end
	local entries = {}
	for name, result in pairs( evaluation.Results ) do
		if result.Selectable then
			local flags = ""
			if name == chosenName then flags = flags .. ">" end
			if name == evaluation.BestName then flags = flags .. "*" end
			table.insert( entries, flags .. name .. "="
				.. math.floor( result.FinalScore ) )
		end
	end
	table.sort( entries )
	BoonAdvisor.LogLine( "[keep ] " .. BoonAdvisor.LogContext()
		.. " from=" .. tostring( evaluation.CurrentName )
		.. " took=" .. chosenName
		.. " recommended=" .. tostring( evaluation.BestName )
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
		.. " | build=" .. BoonAdvisor.BuildSnapshot( run ) )
end

function BoonAdvisor.LogRunEnd( run )
	if not telemetryEnabled() or run == nil
		or BoonAdvisor.LastRunEndLogged == run then return end
	BoonAdvisor.LastRunEndLogged = run
	local result = run.Cleared and "clear" or "death"
	local room = run.EndingRoomName
		or ( run.CurrentRoom ~= nil and run.CurrentRoom.Name ) or "?"
	BoonAdvisor.LogLine( "[run-end] " .. BoonAdvisor.LogContext( run )
		.. " result=" .. result
		.. " time=" .. tostring( math.floor( run.GameplayTime or 0 ) )
		.. " room=" .. tostring( room )
		.. " | build=" .. BoonAdvisor.BuildSnapshot( run ) )
end
