--[[
	BoonAdvisor - Well of Charon advisor.

	The Well is not a shop room: UseWellShop opens a screen whose buttons are
	built by CreateStoreButtons (StoreScripts.lua) from
	CurrentRun.CurrentRoom.Store.StoreOptions. The SpawnStoreItemInWorld hooks
	that cover Charon's shop never run for it, so until v1.14 the Well items
	rated in Config.Shop.WellItems were never drawn anywhere. This draws a
	badge on each purchase button after vanilla builds the screen, and again
	after a purchase (the remaining stock is re-ranked against the new purse
	and build; unchanged badges are left alone).

	Vanilla hangs the item description off the purchase button itself, so the
	badge lives on its own anchor, registered in the screen's Components so
	CloseScreen tears it down with everything else.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

local MAX_WELL_BUTTONS = 6

local function wellScreen()
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	local store = room ~= nil and room.Store or nil
	return store ~= nil and store.Screen or nil
end

-- Score one Well button. Cost handling mirrors DrawShopOverlay so the Well
-- and Charon's shop mean the same thing by "B 70".
function BoonAdvisor.ScoreWellButton( data, money )
	local shop = BoonAdvisor.Config.Shop
	local score, reason = BoonAdvisor.ScoreShopItem({
		Name = data.Name, Type = data.Type, HealthCost = data.HealthCost,
	})
	local affordable = true
	local cost = data.Cost
	if data.HealthCost ~= nil then
		local health = CurrentRun ~= nil and CurrentRun.Hero ~= nil
			and ( CurrentRun.Hero.Health or 0 ) or 0
		if health <= data.HealthCost then
			affordable = false
			reason = "not enough health"
		end
	end
	if cost ~= nil and cost > 0 and money ~= nil then
		if cost > money then
			affordable = false
			score = score - shop.UnaffordablePenalty
			reason = "need " .. ( cost - money ) .. " more gold"
		else
			score = score - ( shop.CostWeight * ( cost / money ) )
		end
	end
	return BoonAdvisor.Finalize( score ), reason, affordable
end

-- Every live purchase button with its rating; bestIndex marks the buy.
function BoonAdvisor.EvaluateWellButtons()
	local screen = wellScreen()
	local components = screen ~= nil and screen.Components or nil
	if components == nil then return nil end
	local money = CurrentRun ~= nil and CurrentRun.Money or nil
	local results = {}
	local bestIndex, bestScore, secondScore = nil, nil, nil
	for index = 1, MAX_WELL_BUTTONS do
		local button = components["PurchaseButton" .. tostring( index )]
		local data = button ~= nil and button.Data or nil
		if button ~= nil and button.Id ~= nil and data ~= nil and data.Name ~= nil then
			local score, reason, affordable = BoonAdvisor.ScoreWellButton( data, money )
			results[index] = { Index = index, Button = button, Name = data.Name,
				Cost = data.Cost or 0, Score = score, Reason = reason,
				Affordable = affordable }
			if affordable then
				if bestScore == nil or score > bestScore then
					secondScore = bestScore
					bestScore = score
					bestIndex = index
				elseif secondScore == nil or score > secondScore then
					secondScore = score
				end
			end
		end
	end
	local margin = nil
	if bestScore ~= nil and secondScore ~= nil then
		margin = math.floor( bestScore ) - math.floor( secondScore )
	end
	return results, bestIndex, margin
end

local function clearWellAnchor( components, key )
	local anchor = components[key]
	if anchor == nil then return end
	if anchor.Id ~= nil then
		if DestroyTextBox ~= nil then DestroyTextBox({ Id = anchor.Id }) end
		if Destroy ~= nil then Destroy({ Id = anchor.Id }) end
	end
	components[key] = nil
end

function BoonAdvisor.DrawWellOverlay()
	local config = BoonAdvisor.Config
	local well = config.Well
	if not config.Enabled or well == nil or not well.Enabled then return end
	local screen = wellScreen()
	local components = screen ~= nil and screen.Components or nil
	-- ShowStoreScreen sets KeepOpen; CloseStoreScreen clears it and destroys
	-- every component, including our anchors. Never draw onto a closed screen.
	if components == nil or screen.KeepOpen == false then return end
	local results, bestIndex, margin = BoonAdvisor.EvaluateWellButtons()
	if results == nil then return end

	local layout = well.Layout
	local showReason = well.ShowReason and BoonAdvisor.ShouldShowReason()
	local draw = BoonAdvisor.Vanilla_CreateTextBox or CreateTextBox
	for index = 1, MAX_WELL_BUTTONS do
		local key = "BoonAdvisorWell" .. tostring( index )
		local result = results[index]
		if result == nil then
			-- Bought, or never offered: drop any badge left behind.
			clearWellAnchor( components, key )
		else
			local button = result.Button
			local score = math.floor( result.Score )
			local rank, color = BoonAdvisor.RankFor( score )
			local badge = rank .. "  " .. score
			if index == bestIndex then
				badge = "* " .. badge
				if config.ShowBestMargin and margin ~= nil then
					badge = badge .. "  +" .. margin
				end
				color = config.BestPickColor
			end
			local reason = showReason and result.Reason or ""
			local drawKey = table.concat({ badge, reason, tostring( button.Id ),
				tostring( color[1] ), tostring( color[2] ), tostring( color[3] ) }, "|" )
			local anchor = components[key]
			if anchor ~= nil and anchor.Id == nil then
				components[key] = nil
				anchor = nil
			end
			if anchor == nil or anchor.BoonAdvisorDrawKey ~= drawKey then
				local anchorId
				if anchor ~= nil then
					anchorId = anchor.Id
					if DestroyTextBox ~= nil then DestroyTextBox({ Id = anchorId }) end
					-- A store reroll rebuilds the buttons under new ids.
					if anchor.BoonAdvisorButtonId ~= button.Id and Attach ~= nil then
						Attach({ Id = anchorId, DestinationId = button.Id })
					end
				elseif CreateScreenComponent ~= nil and Attach ~= nil then
					anchor = CreateScreenComponent({
						Name = "BlankObstacle", Group = "Combat_Menu" })
					if anchor ~= nil and anchor.Id ~= nil then
						Attach({ Id = anchor.Id, DestinationId = button.Id })
						components[key] = anchor
						anchorId = anchor.Id
					else
						anchor = nil
					end
				end
				if anchor == nil then
					-- No screen components (offline harness): draw on the
					-- button and accept that a redraw cannot clear it.
					anchor = { Id = button.Id }
					anchorId = button.Id
					components[key] = anchor
				end
				anchor.BoonAdvisorDrawKey = drawKey
				anchor.BoonAdvisorButtonId = button.Id
				draw({
					Id = anchorId, Text = "{$TempTextData.BALine}",
					LuaKey = "TempTextData", LuaValue = { BALine = badge },
					FontSize = layout.RankFontSize,
					OffsetX = layout.RankOffsetX, OffsetY = layout.RankOffsetY,
					Width = layout.TextWidth, Color = color,
					Font = "AlegreyaSansSCBold", Justification = "Right",
					ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 },
					ShadowOffset = { 0, 2 }, OutlineThickness = 1,
					OutlineColor = { 0, 0, 0, 1 },
				})
				if showReason and result.Reason ~= nil then
					draw({
						Id = anchorId, Text = "{$TempTextData.BALine}",
						LuaKey = "TempTextData", LuaValue = { BALine = result.Reason },
						FontSize = layout.ReasonFontSize,
						OffsetX = layout.ReasonOffsetX, OffsetY = layout.ReasonOffsetY,
						Width = layout.ReasonTextWidth, Color = well.ReasonColor,
						Font = "AlegreyaSansSCRegular", Justification = "Right",
						ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 },
						ShadowOffset = { 0, 1 },
					})
				end
			end
		end
	end
end
