--[[
	BoonAdvisor - Pool of Purging advisor.

	Underworld Customs forces one sale after each biome. The safest sale is not
	necessarily the boon with the lowest static tier: losing a build core, a duo
	prerequisite, Mirror coverage, rarity, or invested levels can be much worse.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

function BoonAdvisor.PurgeProtectionValue( traitName )
	local weights = BoonAdvisor.Config.Weights
	local trait = BoonAdvisor.OwnedTraitData( traitName )
	local base = BoonAdvisor.Ratings.Base[traitName]
	if base == nil then
		base = BoonAdvisor.Ratings.CategoryDefaults[BoonAdvisor.KindOf( traitName )]
			or weights.DefaultBase
	end

	local protection = base
	if trait ~= nil and trait.Rarity ~= nil then
		protection = protection + ( weights.Rarity[trait.Rarity] or 0 )
	end

	local level = 1
	if GetTraitNameCount ~= nil and CurrentRun ~= nil and CurrentRun.Hero ~= nil then
		level = math.max( 1, GetTraitNameCount( CurrentRun.Hero, traitName ) or 1 )
	end
	protection = protection + ( level - 1 )
		* ( BoonAdvisor.Config.Purge.LevelProtection or 0 )

	local buildBonus, buildName = BoonAdvisor.PomBuildBonus( traitName )
	protection = protection + buildBonus

	-- Evaluate the run after removing this boon. A deliberately nonexistent
	-- candidate contributes nothing; only the lost prerequisite is measured.
	local synergy, synergyReason = BoonAdvisor.EvaluateSynergy(
		"BoonAdvisorPurgeRemoval", traitName )
	if synergy < 0 then protection = protection - synergy end
	local mirror, mirrorReason = BoonAdvisor.MetaBonus(
		"BoonAdvisorPurgeRemoval", traitName )
	if mirror < 0 then protection = protection - mirror end
	protection = protection + BoonAdvisor.PactSurvivalBonus( traitName )

	local reason = "least build impact"
	if buildName ~= nil then
		reason = "protects the " .. buildName .. " build"
	elseif synergyReason ~= nil and synergyReason.Text ~= nil and synergy < 0 then
		reason = synergyReason.Text:gsub( "swap closes", "needed for" )
	elseif mirrorReason ~= nil and mirror < 0 then
		reason = mirrorReason:gsub( "swap ", "" )
	elseif level > 1 then
		reason = "level " .. level .. " investment"
	end
	return protection, reason
end

-- A high score means a good boon to SELL, keeping the meaning of the star and
-- S-to-D ladder consistent: the marked option is the action to take.
function BoonAdvisor.ScorePurgeTrait( traitName )
	local protection, reason = BoonAdvisor.PurgeProtectionValue( traitName )
	local raw = ( BoonAdvisor.Config.Purge.ScoreCeiling or 105 ) - protection
	local score = math.floor( BoonAdvisor.Finalize( raw ) + 0.5 )
	local rank, color = BoonAdvisor.RankFor( score )
	return {
		TraitName = traitName,
		Protection = protection,
		RawScore = raw,
		Score = score,
		Rank = rank,
		Color = color,
		Reason = reason,
	}
end

function BoonAdvisor.DrawPurgeOverlay()
	local config = BoonAdvisor.Config.Purge
	if not BoonAdvisor.Config.Enabled or not config.Enabled then return end
	local screen = ScreenAnchors ~= nil and ScreenAnchors.SellTraitScreen or nil
	if screen == nil or screen.Components == nil then return end

	local results = {}
	local bestIndex = nil
	-- Vanilla rebuilds SellOptions through an unordered trait-name table before
	-- creating the three buttons. Read UpgradeName from the actual button so a
	-- rating can never drift onto a different boon.
	for index = 1, 3 do
		local button = screen.Components["PurchaseButton" .. tostring( index )]
		if button ~= nil and button.UpgradeName ~= nil then
			local result = BoonAdvisor.ScorePurgeTrait( button.UpgradeName )
			results[index] = result
			if bestIndex == nil or result.RawScore > results[bestIndex].RawScore then
				bestIndex = index
			end
		end
	end

	local draw = BoonAdvisor.Vanilla_CreateTextBox or CreateTextBox
	local layout = config.Layout
	for index, result in pairs( results ) do
		local button = screen.Components["PurchaseButton" .. tostring( index )]
		if button ~= nil and button.Id ~= nil then
			local badge = "SELL  " .. result.Rank .. " " .. result.Score
			local color = result.Color
			if index == bestIndex then
				badge = "* " .. badge
				color = BoonAdvisor.Config.BestPickColor
			end
			draw({
				Id = button.Id, Text = "{$TempTextData.BALine}",
				LuaKey = "TempTextData", LuaValue = { BALine = badge },
				FontSize = layout.RankFontSize,
				OffsetX = layout.RankOffsetX, OffsetY = layout.RankOffsetY,
				Width = layout.TextWidth, Color = color,
				Font = "AlegreyaSansSCBold", Justification = "Right",
				ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 },
				ShadowOffset = { 0, 2 }, OutlineThickness = 1,
				OutlineColor = { 0, 0, 0, 1 },
			})
			if config.ShowReason and BoonAdvisor.ShouldShowReason()
				and result.Reason ~= nil then
				draw({
					Id = button.Id, Text = "{$TempTextData.BALine}",
					LuaKey = "TempTextData", LuaValue = { BALine = result.Reason },
					FontSize = layout.ReasonFontSize,
					OffsetX = layout.ReasonOffsetX, OffsetY = layout.ReasonOffsetY,
					Width = layout.ReasonTextWidth, Color = config.ReasonColor,
					Font = "AlegreyaSansSCRegular", Justification = "Right",
					ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 },
					ShadowOffset = { 0, 1 },
				})
			end
		end
	end
end
