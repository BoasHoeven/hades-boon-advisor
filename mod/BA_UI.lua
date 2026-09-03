--[[
	BoonAdvisor - overlay rendering.

	Text is attached to the existing boon buttons rather than created as new
	screen components, so the game's own DestroyBoonLootButtons tears our
	overlay down with it. That keeps rerolls and screen closes clean with no
	bookkeeping on our side.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

--[[
	Log run context, what was offered, what it scored, what this mod recommended,
	and what was actually taken. This makes decisions auditable; a future run-end
	hook is still needed before the file can relate picks to clears or times.

	DebugPrint alone is NOT a usable channel. In the release build its output
	never reaches Hades.log: the launcher runs with /VerboseScriptLogging=false,
	and `verboseLogging` in Main.lua only gates coroutine hooks, not printing.
	An earlier version of this file logged solely through DebugPrint and was
	therefore dead on arrival -- worse than no logging, because it looked like
	evidence was being gathered when nothing was written.

	Lua's io and os do exist here (both are listed in Main.lua's SaveIgnores,
	which only names globals that are present), so lines go straight to a file
	beside your saves. DebugPrint is kept as a fallback, and LogChannel records
	which one actually worked so it can be verified rather than assumed.
]]
function BoonAdvisor.LogPath()
	if BoonAdvisor.Config.LogFilePath ~= nil then
		return BoonAdvisor.Config.LogFilePath
	end
	if os == nil or os.getenv == nil then
		return nil
	end
	local home = os.getenv( "USERPROFILE" )
	if home ~= nil and home ~= "" then
		return home .. "\\Documents\\Saved Games\\Hades\\BoonAdvisor-runs.log"
	end
	home = os.getenv( "HOME" )
	if home ~= nil and home ~= "" then
		return home .. "/BoonAdvisor-runs.log"
	end
	return nil
end

function BoonAdvisor.FlushLogQueue()
	local delay = BoonAdvisor.Config ~= nil
		and BoonAdvisor.Config.LogFlushDelay or 0
	if wait ~= nil and delay ~= nil and delay > 0 then
		wait( delay )
	end

	local lines = BoonAdvisor.LogQueue or {}
	BoonAdvisor.LogQueue = {}
	BoonAdvisor.LogFlushQueued = false
	if IsEmpty( lines ) then return end

	if io ~= nil and io.open ~= nil then
		local path = BoonAdvisor.LogPath()
		if path ~= nil then
			local wrote = false
			pcall( function()
				local handle = io.open( path, "a" )
				if handle ~= nil then
					for _, line in ipairs( lines ) do
						handle:write( line, "\n" )
					end
					handle:close()
					wrote = true
				end
			end )
			if wrote then
				BoonAdvisor.LogChannel = "file"
				return
			end
		end
	end
	if DebugPrint ~= nil then
		BoonAdvisor.LogChannel = BoonAdvisor.LogChannel or "debugprint"
		for _, line in ipairs( lines ) do
			DebugPrint({ LogOnly = true, Text = line })
		end
	end
end

function BoonAdvisor.LogLine( text )
	BoonAdvisor.LogQueue = BoonAdvisor.LogQueue or {}
	table.insert( BoonAdvisor.LogQueue, text )
	if BoonAdvisor.LogFlushQueued then return end

	-- Disk I/O never runs in the boon/door event that produced the line. A
	-- short coroutine delay also combines adjacent offer and choice events into
	-- one open/write/close operation.
	if thread ~= nil then
		BoonAdvisor.LogFlushQueued = true
		BoonAdvisor.LogChannel = BoonAdvisor.LogChannel or "queued"
		thread( BoonAdvisor.FlushLogQueue )
	else
		BoonAdvisor.FlushLogQueue()
	end
end

function BoonAdvisor.PerformanceLogPath()
	if BoonAdvisor.Config.PerformanceLogFilePath ~= nil then
		return BoonAdvisor.Config.PerformanceLogFilePath
	end
	if os == nil or os.getenv == nil then return nil end
	local home = os.getenv( "USERPROFILE" )
	if home ~= nil and home ~= "" then
		return home .. "\\Documents\\Saved Games\\Hades\\BoonAdvisor-perf.log"
	end
	home = os.getenv( "HOME" )
	if home ~= nil and home ~= "" then return home .. "/BoonAdvisor-perf.log" end
	return nil
end

function BoonAdvisor.PerfNow()
	if GetTime ~= nil then
		local success, value = pcall( GetTime, {} )
		if success and type( value ) == "number" then return value end
	end
	return type( _worldTime ) == "number" and _worldTime or 0
end

function BoonAdvisor.StartPerfSession( phase, lootData )
	if BoonAdvisor.Config == nil or not BoonAdvisor.Config.PerformanceMonitor then
		return nil
	end
	return {
		Phase = phase,
		LootName = lootData ~= nil and lootData.Name or "?",
		Options = lootData ~= nil and TableLength( lootData.UpgradeOptions or {} ) or 0,
		Start = BoonAdvisor.PerfNow(),
		Marks = {},
		VanillaTextBoxes = 0,
		OverlayTextBoxes = 0,
		DeferredTextBoxes = 0,
	}
end

function BoonAdvisor.PerfStart( session )
	if session == nil then return nil end
	return BoonAdvisor.PerfNow()
end

function BoonAdvisor.PerfLap( session, label, started )
	if session == nil or started == nil then return end
	local elapsed = ( BoonAdvisor.PerfNow() - started ) * 1000
	table.insert( session.Marks, { Label = label, Milliseconds = elapsed } )
end

function BoonAdvisor.WritePerfSession( session )
	if session == nil then return end
	local total = ( BoonAdvisor.PerfNow() - session.Start ) * 1000
	local parts = {
		"[perf] phase=" .. tostring( session.Phase ),
		"loot=" .. tostring( session.LootName ),
		"options=" .. tostring( session.Options ),
	}
	for _, mark in ipairs( session.Marks ) do
		table.insert( parts, tostring( mark.Label ) .. "="
			.. tostring( math.floor( mark.Milliseconds * 100 + 0.5 ) / 100 ) .. "ms" )
	end
	table.insert( parts, "total=" .. tostring(
		math.floor( total * 100 + 0.5 ) / 100 ) .. "ms" )
	table.insert( parts, "textboxes=" .. tostring( session.VanillaTextBoxes )
		.. "/" .. tostring( session.OverlayTextBoxes )
		.. "/" .. tostring( session.DeferredTextBoxes ) )

	local path = BoonAdvisor.PerformanceLogPath()
	if path == nil or io == nil or io.open == nil then return end
	pcall( function()
		local handle = io.open( path, "a" )
		if handle ~= nil then
			handle:write( table.concat( parts, " | " ), "\n" )
			handle:close()
		end
	end )
end

function BoonAdvisor.LogContext( run )
	run = run or CurrentRun
	local hero = run ~= nil and run.Hero or nil
	if hero == nil then
		return "context=unavailable"
	end
	local weapon = hero.WeaponName or hero.Weapon or "?"
	if GetEquippedWeapon ~= nil then
		weapon = GetEquippedWeapon() or weapon
	end
	local aspect = BoonAdvisor.CurrentAspect() or "base"
	local biome = BoonAdvisor.CurrentBiome() or "?"
	local depth = GetRunDepth ~= nil and ( GetRunDepth( run ) or 0 ) or 0
	local heat = run.ShrinePointsCache or 0
	if GetTotalSpentShrinePoints ~= nil then
		heat = GetTotalSpentShrinePoints() or heat
	end
	local defiances = BoonAdvisor.LastStandsRemaining()
	return "run=" .. tostring( BoonAdvisor.RunNumber ~= nil and BoonAdvisor.RunNumber() or "?" )
		.. " objective=" .. tostring( BoonAdvisor.ActiveObjectiveName ~= nil
			and BoonAdvisor.ActiveObjectiveName() or "Balanced" )
		.. " weapon=" .. tostring( weapon )
		.. " aspect=" .. tostring( aspect )
		.. " biome=" .. tostring( biome )
		.. " depth=" .. tostring( depth )
		.. " heat=" .. tostring( heat )
		.. " hp=" .. tostring( math.floor( hero.Health or 0 ) )
		.. "/" .. tostring( math.floor( hero.MaxHealth or 0 ) )
		.. " dd=" .. tostring( defiances )
		.. " gold=" .. tostring( math.floor( run.Money or 0 ) )
		.. " rerolls=" .. tostring( run.NumRerolls or 0 )
end

-- What kind of screen a loot table opens, for the pick log.
function BoonAdvisor.OfferKind( lootData )
	local name = lootData ~= nil and lootData.Name or nil
	if name == "StackUpgrade" then return "pom" end
	if name == "WeaponUpgrade" then return "hammer" end
	if name == "TrialUpgrade" then return "chaos" end
	return "boon"
end

-- Quote a free-text field so the analyzer can read past its spaces.
function BoonAdvisor.LogQuote( text )
	return '"' .. tostring( text or "" ):gsub( '"', "'" ) .. '"'
end

local function formatRaw( value )
	if type( value ) ~= "number" then return "?" end
	return tostring( math.floor( value * 10 + 0.5 ) / 10 )
end

function BoonAdvisor.LogOffer( lootData, options, results, bestIndex, rerollEvaluation, extra )
	extra = extra or {}
	local lootName = lootData ~= nil and lootData.Name or "?"
	local bestResult = results[bestIndex]
	local scores = {}
	local unclamped = {}
	for index, result in ipairs( results ) do
		local itemData = options[index]
		if itemData ~= nil and itemData.ItemName ~= nil then
			scores[itemData.ItemName] = result.RawScore
			unclamped[itemData.ItemName] = result.Unclamped or result.RawScore
		end
	end
	-- The choice hook needs this even when logging is off: the margin and
	-- the recommendation are what make a [took] line stand alone.
	BoonAdvisor.LastOfferLog = {
		LootName = lootName,
		Kind = BoonAdvisor.OfferKind( lootData ),
		RecommendedName = options[bestIndex] ~= nil and options[bestIndex].ItemName or nil,
		BestScore = bestResult ~= nil and bestResult.RawScore or 0,
		BestReason = bestResult ~= nil and bestResult.Reason or nil,
		SecondScore = extra.SecondScore,
		Margin = extra.Margin,
		Verdict = extra.Verdict,
		Scores = scores,
		Unclamped = unclamped,
		RerollSuggested = rerollEvaluation ~= nil and rerollEvaluation.Suggested or false,
		RerollEvaluation = rerollEvaluation,
	}
	if not BoonAdvisor.Config.LogPicks then
		return
	end
	rerollEvaluation = rerollEvaluation or ( bestResult ~= nil
		and BoonAdvisor.EvaluateReroll( lootData, bestResult.RawScore ) )
		or { Suggested = false, Available = false }
	local parts = {}
	for index, result in ipairs( results ) do
		local itemData = options[index]
		local marker = ""
		if index == bestIndex then
			marker = "*"
		end
		local text = marker .. tostring( itemData.ItemName )
			.. "=" .. math.floor( result.Score ) .. "(" .. result.Rank .. ")"
		if itemData.SecondaryItemName ~= nil then
			text = text .. "/" .. tostring( itemData.SecondaryItemName )
		end
		local terms = BoonAdvisor.FormatTerms ~= nil
			and BoonAdvisor.FormatTerms( result.Terms ) or ""
		if terms ~= "" then text = text .. " " .. terms end
		table.insert( parts, text )
	end
	local rerollText = "reroll=unavailable"
	if rerollEvaluation.Available then
		rerollText = "reroll=" .. ( rerollEvaluation.Suggested and "yes" or "no" )
			.. " expected=" .. tostring( math.floor( rerollEvaluation.ExpectedScore ) )
			.. " gain=" .. tostring( math.floor( rerollEvaluation.Gain ) )
			.. " chance=" .. tostring( math.floor(
				rerollEvaluation.ImprovementChance * 100 + 0.5 ) ) .. "%"
			.. " cost=" .. tostring( rerollEvaluation.Cost )
	end
	local summary = "kind=" .. BoonAdvisor.LastOfferLog.Kind
		.. " margin=" .. tostring( extra.Margin or 0 )
		.. " reason=" .. BoonAdvisor.LogQuote( BoonAdvisor.LastOfferLog.BestReason )
	if extra.Verdict ~= nil then
		summary = summary .. " verdict=" .. tostring( extra.Verdict )
	end
	BoonAdvisor.LogLine( "[offer] " .. BoonAdvisor.LogContext()
		.. " loot=" .. tostring( lootName )
		.. " | " .. table.concat( parts, " | " )
		.. " | " .. summary
		.. " | " .. rerollText
		.. " | build=" .. ( BoonAdvisor.BuildSnapshot ~= nil
			and BoonAdvisor.BuildSnapshot() or "unavailable" ) )
end

function BoonAdvisor.LogChoice( screen, button )
	if not BoonAdvisor.Config.LogPicks then
		return
	end
	local data = button ~= nil and button.Data or nil
	local chosen = data ~= nil and data.Name or "?"
	local offer = BoonAdvisor.LastOfferLog or {}
	local recommended = offer.RecommendedName
	local takenScore = offer.Scores ~= nil and offer.Scores[chosen] or nil
	local bestScore = offer.BestScore
	-- score= and best= are what the player saw; margin= is the model's own
	-- pre-knee gap, which is what makes an overrule evidence or noise.
	local margin = nil
	if offer.Unclamped ~= nil and recommended ~= nil
		and offer.Unclamped[chosen] ~= nil and offer.Unclamped[recommended] ~= nil then
		margin = offer.Unclamped[recommended] - offer.Unclamped[chosen]
	elseif takenScore ~= nil and bestScore ~= nil then
		margin = bestScore - takenScore
	end
	BoonAdvisor.LogLine( "[took ] " .. BoonAdvisor.LogContext()
		.. " kind=" .. tostring( offer.Kind or "boon" )
		.. " loot=" .. tostring( offer.LootName or "?" )
		.. " taken=" .. tostring( chosen )
		.. " score=" .. formatRaw( takenScore )
		.. " recommended=" .. tostring( recommended or "?" )
		.. " best=" .. formatRaw( bestScore )
		.. " margin=" .. formatRaw( margin )
		.. " followed=" .. tostring( chosen == recommended )
		.. " reason=" .. BoonAdvisor.LogQuote( offer.BestReason ) )
end

-- Dynamic strings go through the engine's substitution path; a raw Lua string
-- in Text would be looked up as a localization key instead of displayed.
function BoonAdvisor.ShouldShowReason()
	if not BoonAdvisor.Config.HideEnglishReasonsInOtherLanguages or GetLanguage == nil then
		return true
	end
	return GetLanguage({}) == "en"
end

function BoonAdvisor.DrawLine( buttonId, text, color, fontSize, offsetX, offsetY, font, width )
	CreateTextBox({
		Id = buttonId,
		Text = "{$TempTextData.BALine}",
		LuaKey = "TempTextData",
		LuaValue = { BALine = text },
		FontSize = fontSize,
		OffsetX = offsetX,
		OffsetY = offsetY,
		Color = color,
		Font = font,
		Justification = "Right",
		Width = width,
		ShadowBlur = 0,
		ShadowColor = { 0, 0, 0, 1 },
		ShadowOffset = { 0, 2 },
		OutlineThickness = 2,
		OutlineColor = { 0, 0, 0, 1 },
	})
end

-- "* S  95  +14  reroll?": the star, the grade, how far ahead it is, and the
-- optional reroll suffix. The deferred reroll pass redraws the whole line
-- through this same function, so the suffix never replaces the margin.
local function boonBadgeText( result, isBest, rerollEvaluation, margin )
	local text = result.Rank .. "  " .. result.Score
	if isBest then
		text = "* " .. text
		if margin ~= nil and BoonAdvisor.Config.ShowBestMargin then
			text = text .. "  +" .. tostring( margin )
		end
		if rerollEvaluation ~= nil and rerollEvaluation.Suggested then
			text = text .. "  reroll?"
		end
	end
	return text
end

function BoonAdvisor.DrawBoonBadge( components, index, button, option, result,
	isBest, rerollEvaluation, useReplaceableAnchor, margin )
	local layout = BoonAdvisor.Config.Layout
	local badgeColor = isBest and BoonAdvisor.Config.BestPickColor or result.Color
	local rarityKey = option.Rarity
	local traitData = option.ItemName ~= nil and TraitData[option.ItemName] or nil
	if rarityKey == "Legendary" and traitData ~= nil and traitData.IsDuoBoon then
		rarityKey = "Duo"
	end
	local badgeOffsetX = layout.BadgeOffsetX
	if layout.BadgeRarityShiftX ~= nil then
		badgeOffsetX = badgeOffsetX + ( layout.BadgeRarityShiftX[rarityKey] or 0 )
	end

	local textId = button.Id
	local offsetX = badgeOffsetX
	local offsetY = layout.BadgeOffsetY
	if useReplaceableAnchor and CreateScreenComponent ~= nil and Attach ~= nil then
		local key = "BoonAdvisorBadge" .. tostring( index )
		local anchor = components[key]
		if anchor == nil then
			anchor = CreateScreenComponent({ Name = "BlankObstacle", Group = "Combat_Menu" })
			components[key] = anchor
			if anchor ~= nil and anchor.Id ~= nil then
				Attach({ Id = anchor.Id, DestinationId = button.Id,
					OffsetX = badgeOffsetX, OffsetY = layout.BadgeOffsetY })
			end
		end
		if anchor ~= nil and anchor.Id ~= nil then
			textId = anchor.Id
			offsetX = 0
			offsetY = 0
			if DestroyTextBox ~= nil then DestroyTextBox({ Id = textId }) end
		end
	end

	BoonAdvisor.DrawLine( textId,
		boonBadgeText( result, isBest, rerollEvaluation, margin ), badgeColor,
		layout.BadgeFontSize, offsetX, offsetY,
		"AlegreyaSansSCBold", layout.BadgeTextWidth )
end

function BoonAdvisor.ClearBoonOverlayAnchors( components )
	for key, component in pairs( components or {} ) do
		if type( key ) == "string" and key:find( "^BoonAdvisorBadge" ) ~= nil then
			if component ~= nil and component.Id ~= nil then
				if DestroyTextBox ~= nil then DestroyTextBox({ Id = component.Id }) end
				if Destroy ~= nil then Destroy({ Id = component.Id }) end
			end
			components[key] = nil
		end
	end
end

local function deferredOverlayIsCurrent( args )
	local screen = ScreenAnchors ~= nil and ScreenAnchors.ChoiceScreen or nil
	return args ~= nil and BoonAdvisor.BoonOverlayGeneration == args.Generation
		and screen == args.Screen and screen ~= nil and screen.Components == args.Components
		and args.Components["PurchaseButton" .. tostring( args.Index )] == args.Button
end

function BoonAdvisor.FinishDeferredBoonReroll( args )
	-- Vanilla has already drawn the menu and the advisor has already drawn its
	-- grades. Forecast only the optional reroll suffix after that opening frame.
	wait( 0.01 )
	if not deferredOverlayIsCurrent( args ) then return end
	local perfSession = BoonAdvisor.StartPerfSession( "deferred-reroll", args.LootData )
	BoonAdvisor.ActivePerfSession = perfSession
	BoonAdvisor.ActivePerfStage = "deferred"
	local phaseStart = BoonAdvisor.PerfStart( perfSession )
	local evaluation = BoonAdvisor.EvaluateReroll( args.LootData,
		args.Result.RawScore, { YieldBetweenScenarios = true,
			YieldWithinScenarios = true, YieldDuration = 0.01,
			PerfSession = perfSession } )
	BoonAdvisor.PerfLap( perfSession, "evaluate_total", phaseStart )
	if not deferredOverlayIsCurrent( args ) then
		BoonAdvisor.ActivePerfSession = nil
		BoonAdvisor.ActivePerfStage = nil
		BoonAdvisor.WritePerfSession( perfSession )
		return
	end
	if BoonAdvisor.LastOfferLog ~= nil then
		BoonAdvisor.LastOfferLog.RerollSuggested = evaluation.Suggested
		BoonAdvisor.LastOfferLog.RerollEvaluation = evaluation
	end
	if evaluation.Suggested then
		phaseStart = BoonAdvisor.PerfStart( perfSession )
		BoonAdvisor.DrawBoonBadge( args.Components, args.Index, args.Button,
			args.Option, args.Result, true, evaluation, true, args.Margin )
		BoonAdvisor.PerfLap( perfSession, "suffix_draw", phaseStart )
	end
	BoonAdvisor.ActivePerfSession = nil
	BoonAdvisor.ActivePerfStage = nil
	BoonAdvisor.WritePerfSession( perfSession )
end

-- The deferred reroll continuation runs inside a game coroutine, outside every
-- SafeCall on the hook path; an unprotected error there would surface in the
-- engine's scheduler instead of the mod's log.
function BoonAdvisor.SafeFinishDeferredBoonReroll( args )
	BoonAdvisor.SafeCall( BoonAdvisor.FinishDeferredBoonReroll, args )
	BoonAdvisor.ActivePerfSession = nil
	BoonAdvisor.ActivePerfStage = nil
end

--[[
	"None of these." A boon screen can be declined: close it and leave the
	boon on the floor. That is the right call when the run already holds
	boons from GodPoolSoftCap gods, this god is new, and nothing on screen
	is worth diluting the duo paths for. Returns "skip" or nil.
]]
function BoonAdvisor.OfferVerdict( lootData, bestResult )
	local config = BoonAdvisor.Config
	if bestResult == nil or lootData == nil or lootData.Name == nil then return nil end
	if BoonAdvisor.OfferKind( lootData ) ~= "boon" then return nil end
	if BoonAdvisor.GodPoolPenalty == nil then return nil end
	local _, atCap = BoonAdvisor.GodPoolPenalty( lootData.Name )
	if atCap and bestResult.Score < ( config.WeakPickThreshold or 0 ) then
		return "skip"
	end
	return nil
end

function BoonAdvisor.DrawOverlay( lootData, perfSession )
	local config = BoonAdvisor.Config
	if not config.Enabled then
		return
	end

	local screen = ScreenAnchors ~= nil and ScreenAnchors.ChoiceScreen or nil
	if screen == nil or screen.Components == nil then
		return
	end

	local components = screen.Components
	local options = lootData ~= nil and lootData.UpgradeOptions or nil
	if options == nil or IsEmpty( options ) then
		return
	end

	-- Screens we have no ratings for (the hammer screen shares this code path).
	if lootData.Name ~= nil and config.SkipLootNames[lootData.Name] then
		return
	end
	-- Score every option first so the best one can be highlighted.
	local results = {}
	local bestIndex = nil
	local secondIndex = nil
	local phaseStart = BoonAdvisor.PerfStart( perfSession )
	for index, itemData in ipairs( options ) do
		local result = BoonAdvisor.ScoreOption( itemData, lootData )
		results[index] = result
		-- Compare the unrounded score: two options can both display 88.
		if not itemData.Blocked then
			if bestIndex == nil or result.RawScore > results[bestIndex].RawScore then
				secondIndex = bestIndex
				bestIndex = index
			elseif secondIndex == nil or result.RawScore > results[secondIndex].RawScore then
				secondIndex = index
			end
		end
		if config.Debug and DebugPrint ~= nil then
			DebugPrint({ Text = "[BoonAdvisor] " .. tostring( itemData.ItemName )
				.. " = " .. result.Score .. " (" .. result.Rank .. ") " .. result.Reason })
		end
	end
	BoonAdvisor.PerfLap( perfSession, "score_options", phaseStart )

	-- How far the star is ahead, before the soft knee compresses the top end:
	-- "+1" is a coin flip the player may overrule freely, "+14" is not.
	local margin = nil
	if bestIndex ~= nil and secondIndex ~= nil then
		margin = math.floor( ( results[bestIndex].Unclamped or results[bestIndex].RawScore )
			- ( results[secondIndex].Unclamped or results[secondIndex].RawScore ) + 0.5 )
	end
	local verdict = bestIndex ~= nil
		and BoonAdvisor.OfferVerdict( lootData, results[bestIndex] ) or nil
	if verdict == "skip" then
		results[bestIndex].Reason = "none of these: weak, and a new god for a full pool"
	end

	-- A full god reroll forecast is exact but can take a frame in the game's Lua
	-- runtime. Draw the grades immediately and spread its three exclusion cases
	-- across later frames. Telemetry mode remains synchronous so its offer line
	-- is complete before a very fast player can make a selection.
	local rerollEvaluation = { Suggested = false, Available = false }
	local bestButton = bestIndex ~= nil
		and components["PurchaseButton" .. tostring( bestIndex )] or nil
	local fullGodForecast = lootData.Name ~= "StackUpgrade"
		and lootData.Name ~= "TrialUpgrade" and lootData.Name ~= "WeaponUpgrade"
	phaseStart = BoonAdvisor.PerfStart( perfSession )
	local deferReroll = bestIndex ~= nil and bestButton ~= nil
		and bestButton.Id ~= nil and fullGodForecast and not config.LogPicks
		and thread ~= nil and wait ~= nil and CreateScreenComponent ~= nil
		and Attach ~= nil and DestroyTextBox ~= nil
		and BoonAdvisor.CanRerollLoot( lootData )
	BoonAdvisor.PerfLap( perfSession, "reroll_gate", phaseStart )
	if bestIndex ~= nil and not deferReroll then
		phaseStart = BoonAdvisor.PerfStart( perfSession )
		rerollEvaluation = BoonAdvisor.EvaluateReroll(
			lootData, results[bestIndex].RawScore )
		BoonAdvisor.PerfLap( perfSession, "reroll_sync", phaseStart )
	end
	phaseStart = BoonAdvisor.PerfStart( perfSession )
	BoonAdvisor.LogOffer( lootData, options, results, bestIndex, rerollEvaluation, {
		Margin = margin,
		SecondScore = secondIndex ~= nil and results[secondIndex].RawScore or nil,
		Verdict = verdict,
	} )
	BoonAdvisor.PerfLap( perfSession, "offer_log", phaseStart )

	local layout = config.Layout
	for index, result in ipairs( results ) do
		local button = components["PurchaseButton" .. index]
		local option = options[index]
		if button ~= nil and button.Id ~= nil and option ~= nil and not option.Blocked then
			phaseStart = BoonAdvisor.PerfStart( perfSession )
			BoonAdvisor.DrawBoonBadge( components, index, button, option, result,
				index == bestIndex, rerollEvaluation,
				deferReroll and index == bestIndex,
				index == bestIndex and margin or nil )
			BoonAdvisor.PerfLap( perfSession, "badge_" .. tostring( index ), phaseStart )

			if config.ShowReason and BoonAdvisor.ShouldShowReason() and result.Reason ~= nil then
				-- Replacement offers carry a vanilla "Will Replace" row that
				-- would otherwise sit on top of the reason.
				local reasonY = layout.ReasonOffsetY
				local reasonX = layout.ReasonOffsetX
				if options[index] ~= nil and options[index].TraitToReplace ~= nil then
					reasonY = layout.ExchangeReasonOffsetY
					reasonX = layout.ExchangeReasonOffsetX or reasonX
				end
				phaseStart = BoonAdvisor.PerfStart( perfSession )
				BoonAdvisor.DrawLine( button.Id, result.Reason, config.ReasonColor,
					layout.ReasonFontSize, reasonX, reasonY,
					"AlegreyaSansSCRegular", layout.ReasonTextWidth )
				BoonAdvisor.PerfLap( perfSession, "reason_" .. tostring( index ), phaseStart )
			end
		end
	end

	if deferReroll then
		phaseStart = BoonAdvisor.PerfStart( perfSession )
		thread( BoonAdvisor.SafeFinishDeferredBoonReroll, {
			Generation = BoonAdvisor.BoonOverlayGeneration,
			Screen = screen,
			Components = components,
			Index = bestIndex,
			Button = bestButton,
			Option = options[bestIndex],
			Result = results[bestIndex],
			LootData = lootData,
			Margin = margin,
		} )
		BoonAdvisor.PerfLap( perfSession, "schedule_reroll", phaseStart )
	end
end
