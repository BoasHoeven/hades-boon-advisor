-- BoonAdvisor - run-aware scoring for Sisyphus, Eurydice, and Patroclus.

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.StoryChoiceGroups =
{
	Sisyphus =
	{
		"ChoiceText_Healing",
		"ChoiceText_Darkness",
		"ChoiceText_Money",
	},
	Eurydice =
	{
		"ChoiceText_BuffSlottedBoonRarity",
		"ChoiceText_BuffMegaPom",
		"ChoiceText_BuffFutureBoonRarity",
	},
	Patroclus =
	{
		"ChoiceText_BuffExtraChance",
		"ChoiceText_BuffExtraChanceReplenish",
		"ChoiceText_BuffHealing",
		"ChoiceText_BuffWeapon",
	},
}

BoonAdvisor.StoryChoiceGroupByKey = {}
for groupName, keys in pairs( BoonAdvisor.StoryChoiceGroups ) do
	for _, key in ipairs( keys ) do
		BoonAdvisor.StoryChoiceGroupByKey[key] = groupName
	end
end

local nextRarity =
{
	Common = "Rare",
	Rare = "Epic",
	Epic = "Heroic",
}

local function clamp( value, minimum, maximum )
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function rounded( value )
	return math.floor( value + 0.5 )
end

local function heroData()
	return CurrentRun ~= nil and CurrentRun.Hero or nil
end

local function healthState()
	local hero = heroData()
	if hero == nil or hero.MaxHealth == nil or hero.MaxHealth <= 0 then
		return 0, 0, 0
	end
	local missing = math.max( 0, hero.MaxHealth - ( hero.Health or hero.MaxHealth ) )
	return missing, hero.MaxHealth, clamp( missing / hero.MaxHealth, 0, 1 )
end

local function safeNumberCall( default, fn, ... )
	if fn == nil then return default end
	if pcall == nil then
		local value = fn( ... )
		if type( value ) == "number" then return value end
		return default
	end
	local success, value = pcall( fn, ... )
	if success and type( value ) == "number" then
		return value
	end
	return default
end

local function isGodTraitName( traitName, args )
	if traitName == nil then return false end
	if IsGodTrait ~= nil then
		local success, result = pcall( IsGodTrait, traitName, args )
		if success then return result end
	end
	local data = TraitData[traitName]
	return data ~= nil and ( data.God ~= nil
		or BoonAdvisor.Ratings.Base[traitName] ~= nil )
end

local function gameStateEligible( traitName )
	if IsGameStateEligible == nil then return true end
	local data = TraitData[traitName]
	if data == nil then return false end
	local success, eligible = pcall( IsGameStateEligible, CurrentRun, data )
	return not success or eligible
end

local function uniqueHeroTraits( predicate )
	local hero = heroData()
	local result = {}
	local seen = {}
	if hero == nil or type( hero.Traits ) ~= "table" then
		return result
	end
	for _, trait in pairs( hero.Traits ) do
		local name = trait.Name
		if name ~= nil and not seen[name] and predicate( trait ) then
			seen[name] = true
			table.insert( result, trait )
		end
	end
	return result
end

local function scoreSisyphusHealing()
	local config = BoonAdvisor.Config.StoryChoices.Sisyphus
	local missing, maxHealth, missingFraction = healthState()
	local healingMultiplier = safeNumberCall( 1, CalculateHealingMultiplier )
	if BoonAdvisor.HealingMultiplier ~= nil then
		healingMultiplier = BoonAdvisor.HealingMultiplier()
	end
	if healingMultiplier <= 0 then
		return 1, "Restores 0 health at this Heat"
	end
	local healAmount = math.max( 0, rounded( 130 * healingMultiplier ) )
	local coverage = 1
	if missing > 0 then
		coverage = math.min( 1, healAmount / missing )
	end
	local score = config.HealBase
		+ config.HealUrgency * missingFraction * ( 0.65 + 0.35 * coverage )
	local reason
	if missing <= 0 then
		reason = "Already at full health"
	elseif maxHealth > 0 then
		reason = "Heals " .. math.min( rounded( missing ), healAmount )
			.. " of " .. rounded( missing ) .. " missing health"
	else
		reason = "Restores up to " .. healAmount .. " health"
	end
	return score, reason
end

local function scoreSisyphusMoney()
	local config = BoonAdvisor.Config.StoryChoices.Sisyphus
	local multiplier = 1
	if GetTotalHeroTraitValue ~= nil then
		multiplier = safeNumberCall( 1, GetTotalHeroTraitValue,
			"MoneyMultiplier", { IsMultiplier = true } )
	end
	local amount = rounded( 108 * multiplier )
	local money = CurrentRun ~= nil and ( CurrentRun.Money or 0 ) or 0
	local lowMoney = clamp( ( 150 - money ) / 150, 0, 1 )
	return config.MoneyBase + config.LowMoneyBonus * lowMoney,
		"About " .. amount .. " Obols"
end

local function scoreSisyphusDarkness()
	local config = BoonAdvisor.Config.StoryChoices.Sisyphus
	local amountMultiplier = safeNumberCall( 1, CalculateMetaPointMultiplier )
	local amount = math.max( 0, rounded( 55 * amountMultiplier ) )
	local score = config.DarknessBase
	if GetNumMetaUpgrades ~= nil
		and ( GetNumMetaUpgrades( "MetaPointCapShrineUpgrade" ) or 0 ) > 0 then
		score = score * BoonAdvisor.Config.Doors.DarknessCappedFactor
	end

	local healMultiplier = 0
	if GetTotalHeroTraitValue ~= nil then
		healMultiplier = healMultiplier + safeNumberCall( 0,
			GetTotalHeroTraitValue, "MetaPointHealMultiplier" )
	end
	if GetTotalMetaUpgradeChangeValue ~= nil then
		healMultiplier = healMultiplier + math.max( 0,
			safeNumberCall( 1, GetTotalMetaUpgradeChangeValue,
				"DarknessHealMetaUpgrade" ) - 1 )
	end
	healMultiplier = healMultiplier * safeNumberCall( 1, CalculateHealingMultiplier )

	local missing, maxHealth = healthState()
	local healing = math.min( missing, rounded( amount * healMultiplier ) )
	if maxHealth > 0 and healing > 0 then
		score = score + config.DarknessHealWeight * ( healing / maxHealth )
		return score, "About " .. amount .. " Darkness and " .. healing .. " health"
	end
	return score, "About " .. amount .. " Darkness"
end

local function rarityCandidates()
	return uniqueHeroTraits( function( trait )
		-- AddRarityToTraits uses ForShop=true, which includes Hermes boons.
		if not isGodTraitName( trait.Name, { ForShop = true } ) or trait.Rarity == nil then
			return false
		end
		local upgraded = nextRarity[trait.Rarity]
		local data = TraitData[trait.Name]
		local levels = trait.RarityLevels or ( data ~= nil and data.RarityLevels )
		return upgraded ~= nil and type( levels ) == "table" and levels[upgraded] ~= nil
	end )
end

local function pomCandidates()
	return uniqueHeroTraits( function( trait )
		return isGodTraitName( trait.Name ) and gameStateEligible( trait.Name )
	end )
end

local function scoreEurydiceRarity()
	local config = BoonAdvisor.Config.StoryChoices.Eurydice
	local candidates = rarityCandidates()
	local count = TableLength( candidates )
	if count == 0 then
		return config.EmptyScore, "No boon can gain rarity"
	end

	local totalDelta = 0
	local weights = BoonAdvisor.Config.Weights.Rarity
	for _, trait in ipairs( candidates ) do
		local upgraded = nextRarity[trait.Rarity]
		totalDelta = totalDelta
			+ math.max( 0, ( weights[upgraded] or 0 ) - ( weights[trait.Rarity] or 0 ) )
	end
	local affected = math.min( 2, count )
	local expectedDelta = ( totalDelta / count ) * affected
	local score = config.RarityBase + expectedDelta * config.RarityDeltaScale
	return score, "Raises " .. affected .. " of " .. count .. " eligible boons"
end

local function scoreEurydicePom()
	local config = BoonAdvisor.Config.StoryChoices.Eurydice
	local candidates = pomCandidates()
	local count = TableLength( candidates )
	if count == 0 then
		return config.EmptyScore, "No boon can gain a level"
	end

	local totalValue = 0
	for _, trait in ipairs( candidates ) do
		totalValue = totalValue + BoonAdvisor.ScorePom( trait.Name, nil )
	end
	local affected = math.min( 4, count )
	local averageValue = totalValue / count
	local score = config.PomBase + averageValue * config.PomValueScale
		+ affected * config.PomCountBonus
	return score, "Levels " .. affected .. " of " .. count .. " eligible boons"
end

local function scoreEurydiceFutureRarity()
	local config = BoonAdvisor.Config.StoryChoices.Eurydice
	local count = TableLength( pomCandidates() )
	local sparseAdjustment = clamp( config.SparseReference - count,
		-config.SparsePenaltyCap, config.SparseBonusCap )
	local score = config.FutureRarityBase + sparseAdjustment * config.SparseWeight
	return score, "Raises rarity of the next 3 boons"
end

local function scorePatroclusDefiance()
	local config = BoonAdvisor.Config.StoryChoices.Patroclus
	local hero = heroData()
	local maximum = hero ~= nil and ( hero.MaxLastStands or 0 ) or 0
	if maximum <= 0 and GetNumMetaUpgrades ~= nil then
		maximum = GetNumMetaUpgrades( BoonAdvisor.MetaKeys.ExtraChance ) or 0
	end
	local remaining = BoonAdvisor.LastStandsRemaining()
	local missing = math.max( 0, maximum - remaining )
	if missing == 0 then
		return config.DefianceBase, "Death Defiances are full"
	end
	local noun = missing == 1 and "Death Defiance" or "Death Defiances"
	return config.DefianceBase + config.PerMissingDefiance * missing,
		"Restores " .. missing .. " " .. noun
end

local function scorePatroclusStubborn()
	local config = BoonAdvisor.Config.StoryChoices.Patroclus
	local danger = BoonAdvisor.DangerLevel ~= nil and BoonAdvisor.DangerLevel() or 0
	return config.StubbornBase + config.DangerBonus * danger,
		"50% revival for 15 encounters"
end

local function scorePatroclusHealing()
	local config = BoonAdvisor.Config.StoryChoices.Patroclus
	local healingMultiplier = BoonAdvisor.HealingMultiplier ~= nil
		and BoonAdvisor.HealingMultiplier() or 1
	if healingMultiplier <= 0 then
		return 1, "Restores 0 health at this Heat"
	end
	local _, _, missingFraction = healthState()
	local score = config.DoorHealBase + config.DoorHealUrgency * missingFraction
	local danger = BoonAdvisor.DangerLevel ~= nil and BoonAdvisor.DangerLevel() or 0
	score = score + config.DangerBonus * danger
	score = score * healingMultiplier
	if healingMultiplier < 1 then
		return score, math.floor( 30 * healingMultiplier + 0.5 )
			.. "% healing for 5 chambers"
	end
	return score, "30% healing for 5 chambers"
end

local function scorePatroclusWeapon()
	local config = BoonAdvisor.Config.StoryChoices.Patroclus
	local score = config.WeaponBase
	local reason = "+60% weapon damage, 10 encounters"
	local aspect = BoonAdvisor.CurrentAspect()
	local affinity = aspect ~= nil and BoonAdvisor.Ratings.AspectAffinity[aspect] or nil
	if affinity ~= nil and affinity.Ranged ~= nil
		and affinity.Melee == nil and affinity.Secondary == nil then
		score = score - config.CastAspectPenalty
		reason = "Weak for this Cast-focused aspect"
	end
	return score, reason
end

function BoonAdvisor.StoryChoiceEligible( choiceKey )
	if choiceKey == "ChoiceText_BuffExtraChance" then
		return BoonAdvisor.MetaUpgradeActive ~= nil
			and BoonAdvisor.MetaUpgradeActive( "ExtraChanceMetaUpgrade" )
	end
	if choiceKey == "ChoiceText_BuffExtraChanceReplenish" then
		return BoonAdvisor.MetaUpgradeActive ~= nil
			and BoonAdvisor.MetaUpgradeActive( "ExtraChanceReplenishMetaUpgrade" )
	end
	return BoonAdvisor.StoryChoiceGroupByKey[choiceKey] ~= nil
end

function BoonAdvisor.ScoreStoryChoiceRaw( choiceKey )
	if choiceKey == "ChoiceText_Healing" then return scoreSisyphusHealing() end
	if choiceKey == "ChoiceText_Darkness" then return scoreSisyphusDarkness() end
	if choiceKey == "ChoiceText_Money" then return scoreSisyphusMoney() end
	if choiceKey == "ChoiceText_BuffSlottedBoonRarity" then return scoreEurydiceRarity() end
	if choiceKey == "ChoiceText_BuffMegaPom" then return scoreEurydicePom() end
	if choiceKey == "ChoiceText_BuffFutureBoonRarity" then return scoreEurydiceFutureRarity() end
	if choiceKey == "ChoiceText_BuffExtraChance" then return scorePatroclusDefiance() end
	if choiceKey == "ChoiceText_BuffExtraChanceReplenish" then return scorePatroclusStubborn() end
	if choiceKey == "ChoiceText_BuffHealing" then return scorePatroclusHealing() end
	if choiceKey == "ChoiceText_BuffWeapon" then return scorePatroclusWeapon() end
	return nil, nil
end

function BoonAdvisor.ScoreStoryChoice( choiceKey )
	local rawScore, reason = BoonAdvisor.ScoreStoryChoiceRaw( choiceKey )
	if rawScore == nil then return nil end
	local objectiveBonuses = BoonAdvisor.ObjectiveProfile().StoryBonus or {}
	rawScore = rawScore + ( objectiveBonuses[choiceKey] or 0 )
	local finalized = BoonAdvisor.Finalize( rawScore )
	local score = rounded( finalized )
	local rank, color = BoonAdvisor.RankFor( score )
	return {
		Key = choiceKey,
		RawScore = finalized,
		Score = score,
		Rank = rank,
		Color = color,
		Reason = reason,
	}
end

function BoonAdvisor.BestStoryChoiceKey( choiceKey )
	local groupName = BoonAdvisor.StoryChoiceGroupByKey[choiceKey]
	local keys = groupName ~= nil and BoonAdvisor.StoryChoiceGroups[groupName] or nil
	local bestKey = nil
	local bestScore = nil
	if keys == nil then return nil end
	for _, key in ipairs( keys ) do
		if BoonAdvisor.StoryChoiceEligible( key ) then
			local result = BoonAdvisor.ScoreStoryChoice( key )
			if result ~= nil and ( bestScore == nil or result.RawScore > bestScore ) then
				bestKey = key
				bestScore = result.RawScore
			end
		end
	end
	return bestKey
end

local function drawStoryLine( buttonId, text, color, fontSize, offsetX, offsetY,
	font, width, outlineThickness, verticalJustification )
	local draw = BoonAdvisor.Vanilla_CreateTextBox or CreateTextBox
	local shadowColor = { 0, 0, 0, 0 }
	local shadowOffset = { 0, 0 }
	if outlineThickness > 0 then
		shadowColor = { 0, 0, 0, 1 }
		shadowOffset = { 0, 2 }
	end
	draw({
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
		VerticalJustification = verticalJustification or "Center",
		Width = width,
		ShadowBlur = 0,
		ShadowColor = shadowColor,
		ShadowOffset = shadowOffset,
		OutlineThickness = outlineThickness,
		OutlineColor = { 0, 0, 0, 1 },
	})
end

local function isFirstVisibleStoryChoice( choiceKey )
	local groupName = BoonAdvisor.StoryChoiceGroupByKey[choiceKey]
	local keys = groupName ~= nil and BoonAdvisor.StoryChoiceGroups[groupName] or nil
	if keys == nil then return false end
	for _, key in ipairs( keys ) do
		if BoonAdvisor.StoryChoiceEligible( key ) then
			return key == choiceKey
		end
	end
	return false
end

function BoonAdvisor.DrawStoryChoiceOverlay( buttonId, choiceKey )
	local config = BoonAdvisor.Config.StoryChoices
	if not BoonAdvisor.Config.Enabled or not config.Enabled or buttonId == nil then
		return
	end
	local result = BoonAdvisor.ScoreStoryChoice( choiceKey )
	if result == nil then return end

	local badge = result.Rank .. "  " .. result.Score
	local color = result.Color
	if BoonAdvisor.BestStoryChoiceKey( choiceKey ) == choiceKey then
		badge = "* " .. badge
		color = BoonAdvisor.Config.BestPickColor
	end
	local layout = config.Layout
	if isFirstVisibleStoryChoice( choiceKey ) then
		drawStoryLine( buttonId, "BUILD FIT", config.LabelColor,
			layout.LabelFontSize, layout.LabelOffsetX, layout.LabelOffsetY,
			"AlegreyaSansSCExtraBold", layout.LabelWidth, 0 )
	end
	drawStoryLine( buttonId, badge, color, layout.RankFontSize,
		layout.RankOffsetX, layout.RankOffsetY, "AlegreyaSansSCBold",
		layout.TextWidth, 1 )
	if config.ShowReason and BoonAdvisor.ShouldShowReason() and result.Reason ~= nil then
		drawStoryLine( buttonId, result.Reason, config.ReasonColor,
			layout.ReasonFontSize, layout.ReasonOffsetX, layout.ReasonOffsetY,
			"AlegreyaSansSCBold", layout.ReasonWidth, 0, "Top" )
	end
end

function BoonAdvisor.HandleStoryChoiceTextBox( args )
	if type( args ) ~= "table" or args.Id == nil
		or BoonAdvisor.StoryChoiceGroupByKey[args.Text] == nil then
		return
	end
	BoonAdvisor.DrawStoryChoiceOverlay( args.Id, args.Text )
end
