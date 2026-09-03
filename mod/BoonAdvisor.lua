--[[
	BoonAdvisor - an in-game boon pick advisor for Hades.

	Scores the boons offered on the upgrade choice screen against your current
	build and draws a rank badge plus a one-line reason on each option.

	Installed by a single Import line appended to Content/Scripts/RoomManager.lua.
	To uninstall, remove that line (or restore RoomManager.lua.BoonAdvisorBackup).
]]

--[[
	Keep this global out of the save file.

	Main.lua's Save() walks every entry of _G and serializes anything not
	listed in SaveIgnores. It skips functions, but only at the top level: a
	global *table* is serialized whole, and luabins dies with
	"can't save: unsupported type detected" the moment it reaches a function
	nested inside one. Since BoonAdvisor is a table full of functions, it must
	be excluded or the game cannot save at a room transition.

	This must run before any save, hence before anything else in this file.

	Main.lua owns SaveIgnores. If this file were to load first, our key would be
	wiped when Main.lua reassigns the table, so the load order is recorded below
	and reported to the log rather than assumed.
]]
local saveIgnoresPreexisted = ( SaveIgnores ~= nil )
if SaveIgnores == nil then
	SaveIgnores = {}
end
SaveIgnores["BoonAdvisor"] = true

Import "../Mods/BoonAdvisor/BA_Config.lua"
Import "../Mods/BoonAdvisor/BA_Ratings.lua"
Import "../Mods/BoonAdvisor/BA_Engine.lua"
Import "../Mods/BoonAdvisor/BA_Exclusions.lua"
Import "../Mods/BoonAdvisor/BA_Purge.lua"
Import "../Mods/BoonAdvisor/BA_Forecast.lua"
Import "../Mods/BoonAdvisor/BA_Doors.lua"
Import "../Mods/BoonAdvisor/BA_Well.lua"
Import "../Mods/BoonAdvisor/BA_Rerolls.lua"
Import "../Mods/BoonAdvisor/BA_UI.lua"
Import "../Mods/BoonAdvisor/BA_Keepsakes.lua"
Import "../Mods/BoonAdvisor/BA_Story.lua"
Import "../Mods/BoonAdvisor/BA_Telemetry.lua"

BoonAdvisor.Version = "1.14.0"

-- Never let a scoring bug take down a run: the vanilla screen is already built
-- by the time we draw, so swallowing our own errors leaves the game playable.
-- Returns the wrapped call's first result, or nil when it failed, so callers
-- that branch on a helper's return value stay protected too.
function BoonAdvisor.SafeCall( fn, arg, arg2 )
	if pcall ~= nil then
		local success, result = pcall( fn, arg, arg2 )
		if not success then
			if DebugPrint ~= nil then
				DebugPrint({ LogOnly = true, Text = "[BoonAdvisor] error: " .. tostring( result ) })
			end
			return nil
		end
		return result
	else
		return fn( arg, arg2 )
	end
end

function BoonAdvisor.SafeDrawOverlay( lootData, perfSession )
	if pcall ~= nil then
		local success, err = pcall( BoonAdvisor.DrawOverlay, lootData, perfSession )
		if not success and DebugPrint ~= nil then
			DebugPrint({ LogOnly = true, Text = "[BoonAdvisor] error: " .. tostring( err ) })
		end
	else
		BoonAdvisor.DrawOverlay( lootData, perfSession )
	end
end

-- The combat hooks below (gold, healing, max health, Death Defiance) fire
-- constantly; only a cleared room with rated doors has anything to refresh.
local function doorsAwaitingRefresh()
	return CurrentRun ~= nil
		and BoonAdvisor.DoorCandidateRoom == CurrentRun.CurrentRoom
		and not IsEmpty( BoonAdvisor.DoorCandidates or {} )
end

-- Guard against double-wrapping if the scripts are reloaded in place.
if not BoonAdvisor.Installed then
	BoonAdvisor.Installed = true
	BoonAdvisor.Vanilla_CreateTextBox = BoonAdvisor.Vanilla_CreateTextBox or CreateTextBox

	function CreateTextBox( args )
		local perfSession = BoonAdvisor.ActivePerfSession
		if perfSession ~= nil then
			local key = BoonAdvisor.ActivePerfStage == "vanilla" and "VanillaTextBoxes"
				or BoonAdvisor.ActivePerfStage == "deferred" and "DeferredTextBoxes"
				or "OverlayTextBoxes"
			perfSession[key] = ( perfSession[key] or 0 ) + 1
		end
		local result = BoonAdvisor.Vanilla_CreateTextBox( args )
		-- CreateTextBox is used throughout combat and every menu. Only enter the
		-- protected story-choice path for the handful of keys the advisor owns.
		if type( args ) == "table" and args.Id ~= nil
			and type( BoonAdvisor.StoryChoiceGroupByKey ) == "table"
			and BoonAdvisor.StoryChoiceGroupByKey[args.Text] ~= nil then
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.HandleStoryChoiceTextBox( args )
			end )
		end
		return result
	end

	BoonAdvisor.Vanilla_CreateBoonLootButtons = BoonAdvisor.Vanilla_CreateBoonLootButtons or CreateBoonLootButtons

	function CreateBoonLootButtons( lootData, reroll )
		BoonAdvisor.BoonOverlayGeneration = ( BoonAdvisor.BoonOverlayGeneration or 0 ) + 1
		-- Perf bookkeeping runs before vanilla builds the screen, so it must
		-- never be the reason the screen fails to build.
		local perfSession, phaseStart
		BoonAdvisor.SafeCall( function()
			perfSession = BoonAdvisor.StartPerfSession( "open", lootData )
			phaseStart = BoonAdvisor.PerfStart( perfSession )
		end )
		BoonAdvisor.ActivePerfSession = perfSession
		BoonAdvisor.ActivePerfStage = "vanilla"
		BoonAdvisor.Vanilla_CreateBoonLootButtons( lootData, reroll )
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.PerfLap( perfSession, "vanilla", phaseStart )
			phaseStart = BoonAdvisor.PerfStart( perfSession )
		end )
		BoonAdvisor.ActivePerfStage = "overlay"
		BoonAdvisor.SafeDrawOverlay( lootData, perfSession )
		BoonAdvisor.ActivePerfSession = nil
		BoonAdvisor.ActivePerfStage = nil
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.PerfLap( perfSession, "overlay_total", phaseStart )
			BoonAdvisor.WritePerfSession( perfSession )
		end )
	end

	-- Replaceable badge anchors let deferred reroll advice update one label
	-- without redrawing or covering vanilla text. Remove them with the screen.
	BoonAdvisor.Vanilla_DestroyBoonLootButtons =
		BoonAdvisor.Vanilla_DestroyBoonLootButtons or DestroyBoonLootButtons

	if BoonAdvisor.Vanilla_DestroyBoonLootButtons ~= nil then
		function DestroyBoonLootButtons( lootData )
			BoonAdvisor.BoonOverlayGeneration =
				( BoonAdvisor.BoonOverlayGeneration or 0 ) + 1
			-- Runs before the vanilla destroy: an unprotected error here would
			-- leave the choice screen stuck open.
			BoonAdvisor.SafeCall( function()
				local screen = ScreenAnchors ~= nil and ScreenAnchors.ChoiceScreen or nil
				if screen ~= nil then
					BoonAdvisor.ClearBoonOverlayAnchors( screen.Components )
				end
			end )
			return BoonAdvisor.Vanilla_DestroyBoonLootButtons( lootData )
		end
	end

	-- Record what was actually taken, paired with the contextual offer entry in
	-- the optional pick log.
	BoonAdvisor.Vanilla_HandleUpgradeChoiceSelection =
		BoonAdvisor.Vanilla_HandleUpgradeChoiceSelection or HandleUpgradeChoiceSelection

	function HandleUpgradeChoiceSelection( screen, button )
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.LogChoice( screen, button )
		end )
		local result = BoonAdvisor.Vanilla_HandleUpgradeChoiceSelection( screen, button )
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
		end )
		BoonAdvisor.SafeCall( function()
			if CurrentRun ~= nil and BoonAdvisor.ShopItemRoom == CurrentRun.CurrentRoom then
				BoonAdvisor.DrawShopOverlay()
			end
		end )
		return result
	end

	BoonAdvisor.Vanilla_RerollBoonLoot =
		BoonAdvisor.Vanilla_RerollBoonLoot or RerollBoonLoot

	if BoonAdvisor.Vanilla_RerollBoonLoot ~= nil then
		function RerollBoonLoot( lootData )
			BoonAdvisor.SafeCall( BoonAdvisor.LogReroll, lootData or CurrentLootData )
			return BoonAdvisor.Vanilla_RerollBoonLoot( lootData )
		end
	end

	-- Keepsake rack: one call per keepsake shown.
	BoonAdvisor.Vanilla_CreateKeepsakeIcon =
		BoonAdvisor.Vanilla_CreateKeepsakeIcon or CreateKeepsakeIcon

	function CreateKeepsakeIcon( components, args )
		local result = BoonAdvisor.Vanilla_CreateKeepsakeIcon( components, args )
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.DrawKeepsakeOverlay( components, args )
		end )
		return result
	end

	-- Vanilla destroys text attached to a keepsake button when it is hovered.
	-- Keep the grid rank independent and update the detail panel after vanilla.
	BoonAdvisor.Vanilla_SetCursorFrame = BoonAdvisor.Vanilla_SetCursorFrame or SetCursorFrame

	if BoonAdvisor.Vanilla_SetCursorFrame ~= nil then
		function SetCursorFrame( button )
			local result = BoonAdvisor.Vanilla_SetCursorFrame( button )
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.UpdateKeepsakeDetail( button )
			end )
			return result
		end
	end

	BoonAdvisor.Vanilla_CloseUpgradeScreen =
		BoonAdvisor.Vanilla_CloseUpgradeScreen or CloseUpgradeScreen

	if BoonAdvisor.Vanilla_CloseUpgradeScreen ~= nil then
		function CloseUpgradeScreen( screen, button )
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.LogKeepsakeChoice(
					GameState ~= nil and GameState.LastAwardTrait or nil )
			end )
			local result = BoonAdvisor.Vanilla_CloseUpgradeScreen( screen, button )
			BoonAdvisor.KeepsakeEvaluationScreen = nil
			BoonAdvisor.LastKeepsakeEvaluation = nil
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
			end )
			return result
		end
	end

	-- Pool of Purging, including the mandatory Underworld Customs sale.
	BoonAdvisor.Vanilla_CreateSellButtons =
		BoonAdvisor.Vanilla_CreateSellButtons or CreateSellButtons

	if BoonAdvisor.Vanilla_CreateSellButtons ~= nil then
		function CreateSellButtons()
			local result = BoonAdvisor.Vanilla_CreateSellButtons()
			BoonAdvisor.SafeCall( BoonAdvisor.DrawPurgeOverlay )
			return result
		end
	end

	-- Door reward previews: one call per exit door as the room is cleared.
	BoonAdvisor.Vanilla_CreateDoorRewardPreview = BoonAdvisor.Vanilla_CreateDoorRewardPreview or CreateDoorRewardPreview

	function CreateDoorRewardPreview( exitDoor )
		BoonAdvisor.Vanilla_CreateDoorRewardPreview( exitDoor )
		BoonAdvisor.SafeCall( BoonAdvisor.RegisterDoor, exitDoor )
		BoonAdvisor.SafeCall( BoonAdvisor.QueueDoorOverlayRefresh )
	end

	--[[
		The Chaos gate never reaches the hook above.

		CreateDoorRewardPreview is only called in a loop over the normal exit
		doors (RoomManager: "for index, door in ipairs( exitDoorsIPairs )").
		The secret door is spawned in a separate branch that calls
		AssignRoomToExitDoor and nothing else -- so the gate got no rank no
		matter what was done inside the preview hook.

		AssignRoomToExitDoor runs for every door, and by the time it is called
		the secret door already has its HealthCost, which is what identifies it.
	]]
	BoonAdvisor.Vanilla_AssignRoomToExitDoor = BoonAdvisor.Vanilla_AssignRoomToExitDoor or AssignRoomToExitDoor

	function AssignRoomToExitDoor( door, room )
		BoonAdvisor.Vanilla_AssignRoomToExitDoor( door, room )
		BoonAdvisor.SafeCall( BoonAdvisor.RegisterDoor, door )
		if door ~= nil and door.HealthCost ~= nil then
			BoonAdvisor.SafeCall( BoonAdvisor.QueueDoorOverlayRefresh )
		end
	end

	BoonAdvisor.Vanilla_LeaveRoom = BoonAdvisor.Vanilla_LeaveRoom or LeaveRoom

	if BoonAdvisor.Vanilla_LeaveRoom ~= nil then
		function LeaveRoom( currentRun, door )
			-- Both lines describe the room being left, so they must be written
			-- before vanilla swaps CurrentRoom for the next one.
			BoonAdvisor.SafeCall( BoonAdvisor.LogDoorChoice, door )
			BoonAdvisor.SafeCall( BoonAdvisor.LogRoomOutcome, currentRun, door )
			return BoonAdvisor.Vanilla_LeaveRoom( currentRun, door )
		end
	end

	--[[
		Charon's shop. SpawnStoreItemInWorld keeps the spawned item in a local
		and returns nothing, so the item being placed is stashed here and the
		ObjectId read back off Store.SpawnedStoreItems, which vanilla appends
		to as its last act.
	]]
	BoonAdvisor.Vanilla_SpawnStoreItemInWorld = BoonAdvisor.Vanilla_SpawnStoreItemInWorld or SpawnStoreItemInWorld

	function SpawnStoreItemInWorld( itemData, kitId )
		local result = BoonAdvisor.Vanilla_SpawnStoreItemInWorld( itemData, kitId )
		BoonAdvisor.SafeCall( BoonAdvisor.RecordShopItem, itemData )
		return result
	end

	-- Drawn only once the whole shop has spawned, so the stock can be ranked
	-- against itself and the best buy marked.
	BoonAdvisor.Vanilla_SpawnStoreItemsInWorld = BoonAdvisor.Vanilla_SpawnStoreItemsInWorld or SpawnStoreItemsInWorld

	function SpawnStoreItemsInWorld()
		BoonAdvisor.ShopItems = nil
		BoonAdvisor.ShopItemRoom = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
		BoonAdvisor.Vanilla_SpawnStoreItemsInWorld()
		BoonAdvisor.SafeCall( BoonAdvisor.DrawShopOverlay )
	end

	BoonAdvisor.Vanilla_AttemptRerollStoreItemInWorld =
		BoonAdvisor.Vanilla_AttemptRerollStoreItemInWorld or AttemptRerollStoreItemInWorld

	function AttemptRerollStoreItemInWorld( run, item )
		if item ~= nil then
			BoonAdvisor.SafeCall( BoonAdvisor.RemoveShopItem, item.ObjectId )
		end
		local result = BoonAdvisor.Vanilla_AttemptRerollStoreItemInWorld( run, item )
		BoonAdvisor.SafeCall( BoonAdvisor.DrawShopOverlay )
		return result
	end

	--[[
		The Well of Charon is a screen, not a room of items: UseWellShop ->
		StartUpStore -> ShowStoreScreen -> CreateStoreButtons builds one
		purchase button per StoreOptions entry. Nothing above runs for it.
	]]
	BoonAdvisor.Vanilla_CreateStoreButtons =
		BoonAdvisor.Vanilla_CreateStoreButtons or CreateStoreButtons

	if BoonAdvisor.Vanilla_CreateStoreButtons ~= nil then
		function CreateStoreButtons()
			local result = BoonAdvisor.Vanilla_CreateStoreButtons()
			BoonAdvisor.SafeCall( BoonAdvisor.DrawWellOverlay )
			return result
		end
	end

	BoonAdvisor.Vanilla_HandleStorePurchase =
		BoonAdvisor.Vanilla_HandleStorePurchase or HandleStorePurchase

	if BoonAdvisor.Vanilla_HandleStorePurchase ~= nil then
		function HandleStorePurchase( screen, button )
			-- The button is destroyed by the purchase; log it while it exists.
			BoonAdvisor.SafeCall( BoonAdvisor.LogWellChoice, button )
			local result = BoonAdvisor.Vanilla_HandleStorePurchase( screen, button )
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
			end )
			BoonAdvisor.SafeCall( BoonAdvisor.DrawWellOverlay )
			return result
		end
	end

	BoonAdvisor.Vanilla_HandleLootPickup = BoonAdvisor.Vanilla_HandleLootPickup or HandleLootPickup

	function HandleLootPickup( currentRun, loot )
		if loot ~= nil then
			BoonAdvisor.SafeCall( BoonAdvisor.LogShopChoice, loot.ObjectId )
		end
		local removed = loot ~= nil
			and BoonAdvisor.SafeCall( BoonAdvisor.RemoveShopItem, loot.ObjectId )
		local result = BoonAdvisor.Vanilla_HandleLootPickup( currentRun, loot )
		if removed then BoonAdvisor.SafeCall( BoonAdvisor.DrawShopOverlay ) end
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
		end )
		return result
	end

	BoonAdvisor.Vanilla_PurchaseConsumableItem =
		BoonAdvisor.Vanilla_PurchaseConsumableItem or PurchaseConsumableItem

	function PurchaseConsumableItem( currentRun, consumableItem, args )
		if consumableItem ~= nil then
			BoonAdvisor.SafeCall( BoonAdvisor.LogShopChoice, consumableItem.ObjectId )
		end
		local removed = consumableItem ~= nil
			and BoonAdvisor.SafeCall( BoonAdvisor.RemoveShopItem, consumableItem.ObjectId )
		local result = BoonAdvisor.Vanilla_PurchaseConsumableItem( currentRun, consumableItem, args )
		if removed then
			BoonAdvisor.SafeCall( BoonAdvisor.DrawShopOverlay )
		end
		BoonAdvisor.SafeCall( function()
			BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
		end )
		return result
	end

	BoonAdvisor.Vanilla_HandleSellChoiceSelection =
		BoonAdvisor.Vanilla_HandleSellChoiceSelection or HandleSellChoiceSelection
	if BoonAdvisor.Vanilla_HandleSellChoiceSelection ~= nil then
		function HandleSellChoiceSelection( screen, button )
			-- Logged first: vanilla removes the boon and destroys the button.
			BoonAdvisor.SafeCall( BoonAdvisor.LogPurgeChoice, screen, button )
			local result = BoonAdvisor.Vanilla_HandleSellChoiceSelection( screen, button )
			BoonAdvisor.SafeCall( function()
				BoonAdvisor.MarkRunStateDirty({ BuildChanged = true })
			end )
			return result
		end
	end

	BoonAdvisor.Vanilla_AddMoney = BoonAdvisor.Vanilla_AddMoney or AddMoney
	if BoonAdvisor.Vanilla_AddMoney ~= nil then
		function AddMoney( amount, source )
			local result = BoonAdvisor.Vanilla_AddMoney( amount, source )
			if doorsAwaitingRefresh() then
				BoonAdvisor.SafeCall( BoonAdvisor.MarkRunStateDirty )
			end
			return result
		end
	end

	BoonAdvisor.Vanilla_SpendMoney = BoonAdvisor.Vanilla_SpendMoney or SpendMoney
	if BoonAdvisor.Vanilla_SpendMoney ~= nil then
		function SpendMoney( amount, source )
			local result = BoonAdvisor.Vanilla_SpendMoney( amount, source )
			if doorsAwaitingRefresh() then
				BoonAdvisor.SafeCall( BoonAdvisor.MarkRunStateDirty )
			end
			return result
		end
	end

	BoonAdvisor.Vanilla_AddMaxHealth = BoonAdvisor.Vanilla_AddMaxHealth or AddMaxHealth
	if BoonAdvisor.Vanilla_AddMaxHealth ~= nil then
		function AddMaxHealth( healthGained, source, args )
			local result = BoonAdvisor.Vanilla_AddMaxHealth( healthGained, source, args )
			if doorsAwaitingRefresh() then
				BoonAdvisor.SafeCall( BoonAdvisor.MarkRunStateDirty )
			end
			return result
		end
	end

	BoonAdvisor.Vanilla_AddLastStand = BoonAdvisor.Vanilla_AddLastStand or AddLastStand
	if BoonAdvisor.Vanilla_AddLastStand ~= nil then
		function AddLastStand( args )
			local result = BoonAdvisor.Vanilla_AddLastStand( args )
			if doorsAwaitingRefresh() then
				BoonAdvisor.SafeCall( BoonAdvisor.MarkRunStateDirty )
			end
			return result
		end
	end

	BoonAdvisor.Vanilla_Heal = BoonAdvisor.Vanilla_Heal or Heal
	if BoonAdvisor.Vanilla_Heal ~= nil then
		function Heal( victim, triggerArgs )
			local result = BoonAdvisor.Vanilla_Heal( victim, triggerArgs )
			if CurrentRun ~= nil and victim == CurrentRun.Hero and doorsAwaitingRefresh() then
				BoonAdvisor.SafeCall( BoonAdvisor.MarkRunStateDirty )
			end
			return result
		end
	end

	BoonAdvisor.Vanilla_PlayTextLine = BoonAdvisor.Vanilla_PlayTextLine or PlayTextLine

	if BoonAdvisor.Vanilla_PlayTextLine ~= nil then
		function PlayTextLine( screen, textLines, prevLine, parentLine, source )
			if textLines ~= nil and textLines.ChoiceText ~= nil then
				BoonAdvisor.SafeCall( BoonAdvisor.LogStoryChoice, textLines.ChoiceText )
			end
			return BoonAdvisor.Vanilla_PlayTextLine(
				screen, textLines, prevLine, parentLine, source )
		end
	end

	BoonAdvisor.Vanilla_RecordRunStats =
		BoonAdvisor.Vanilla_RecordRunStats or RecordRunStats

	if BoonAdvisor.Vanilla_RecordRunStats ~= nil then
		function RecordRunStats()
			local result = BoonAdvisor.Vanilla_RecordRunStats()
			BoonAdvisor.SafeCall( BoonAdvisor.LogRunEnd, CurrentRun )
			return result
		end
	end

	BoonAdvisor.Vanilla_StartNewRun = BoonAdvisor.Vanilla_StartNewRun or StartNewRun

	if BoonAdvisor.Vanilla_StartNewRun ~= nil then
		function StartNewRun( prevRun, args )
			local result = BoonAdvisor.Vanilla_StartNewRun( prevRun, args )
			BoonAdvisor.SafeCall( BoonAdvisor.InvalidateForecastCache )
			BoonAdvisor.SafeCall( BoonAdvisor.LogRunStart, result or CurrentRun )
			return result
		end
	end

	--[[
		With pick logging on, stamp the log at load.

		This is not decoration: it is the only way to find out whether Hades'
		Lua sandbox actually exposes io.open. That cannot be settled offline,
		because a desktop Lua always has io -- so the offline suite proves the
		code is correct, not that the channel exists in the game. Either this
		line appears in BoonAdvisor-runs.log after one launch, or the file
		logger is unavailable and LogChannel will say "debugprint".

		The ratings fingerprint separates sessions played with different
		tunings, so the analyzer never averages old and new weights together.
	]]
	if BoonAdvisor.Config.LogPicks then
		BoonAdvisor.LogLine( "" )
		BoonAdvisor.LogLine( "=== BoonAdvisor v" .. BoonAdvisor.Version
			.. " objective=" .. tostring( BoonAdvisor.ActiveObjectiveName() )
			.. " ratings=" .. tostring( BoonAdvisor.SafeCall( BoonAdvisor.ConfigFingerprint ) or "?" )
			.. " channel=" .. tostring( BoonAdvisor.LogChannel or "none" )
			.. " saveignores=" .. tostring( saveIgnoresPreexisted ) .. " ===" )
		BoonAdvisor.SafeCall( BoonAdvisor.LogRunStart, CurrentRun )
	end

	if DebugPrint ~= nil then
		DebugPrint({ LogOnly = true, Text = "[BoonAdvisor] v" .. BoonAdvisor.Version
			.. " loaded; SaveIgnores pre-existed = " .. tostring( saveIgnoresPreexisted )
			.. "; registered = " .. tostring( SaveIgnores["BoonAdvisor"] ) })
	end
end
