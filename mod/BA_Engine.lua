--[[
	BoonAdvisor - scoring engine.

	Combines a hand-authored tier baseline (BA_Ratings) with facts read live
	from the running game:

	  * LootData[*].LinkedUpgrades - the real duo/legendary prerequisite graph,
	    so "this pick enables Sea Storm" is derived from game data rather than
	    a hardcoded list that would rot on the next patch.
	  * CurrentRun.Hero.Traits    - what the build already has.
	  * TraitData[*].Slot         - slot economy.
	  * The offered rarity.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.LinkedIndex = nil
BoonAdvisor.NameCache = {}

---------------------------------------------------------------------------
-- Data access
---------------------------------------------------------------------------

-- Resolve a trait's localized display name to a plain Lua string.
function BoonAdvisor.TraitDisplayName( traitName )
	if BoonAdvisor.NameCache[traitName] ~= nil then
		return BoonAdvisor.NameCache[traitName]
	end

	local resolved = traitName
	local traitData = TraitData[traitName]
	local key = traitName
	if traitData ~= nil and GetTraitTooltipTitle ~= nil then
		key = GetTraitTooltipTitle( traitData ) or traitName
	end
	if HasDisplayName ~= nil and not HasDisplayName({ Text = key }) then
		key = traitName
	end
	if GetDisplayName ~= nil and HasDisplayName ~= nil and HasDisplayName({ Text = key }) then
		resolved = GetDisplayName({ Text = key }) or traitName
	end

	BoonAdvisor.NameCache[traitName] = resolved
	return resolved
end

--[[
	Player-facing slot names. TraitData uses internal names (Rush, Ranged) that
	no player would recognise, and the UpgradeChoiceMenu_<Slot> keys the vanilla
	code builds are not present in the shipped text, so there is nothing to
	look up. English only; other languages fall back to the internal name.
]]
BoonAdvisor.SlotNames =
{
	Melee     = "Attack",
	Secondary = "Special",
	Ranged    = "Cast",
	Rush      = "Dash",
	Shout     = "Call",
}

function BoonAdvisor.SlotDisplayName( slot )
	return BoonAdvisor.SlotNames[slot] or tostring( slot )
end

--[[
	Flatten every LinkedUpgrades block in LootData into a list of
	{ Name, Kind, Sets } where Sets is a list of prerequisite groups and the
	requirement is "hold at least one trait from every group".

	OneOf becomes a single group; OneFromEachSet becomes one group per set.
	A boon gated behind two or more groups is a duo. Duos are listed under both
	contributing gods, so entries are de-duplicated by trait name.
]]
function BoonAdvisor.BuildLinkedIndex()
	local index = {}
	local seen = {}

	for lootName, lootInfo in pairs( LootData ) do
		if type( lootInfo ) == "table" and type( lootInfo.LinkedUpgrades ) == "table" then
			for traitName, requirement in pairs( lootInfo.LinkedUpgrades ) do
				if seen[traitName] == nil and type( requirement ) == "table" then
					local sets = nil

					if type( requirement.OneFromEachSet ) == "table" and TableLength( requirement.OneFromEachSet ) > 0 then
						sets = requirement.OneFromEachSet
					elseif type( requirement.OneOf ) == "table" and TableLength( requirement.OneOf ) > 0 then
						sets = { requirement.OneOf }
					end

					if sets ~= nil then
						seen[traitName] = true

						local kind = "Upgrade"
						if TableLength( sets ) >= 2 then
							kind = "Duo"
						else
							local traitData = TraitData[traitName]
							if traitData ~= nil and type( traitData.RarityLevels ) == "table"
								and traitData.RarityLevels.Legendary ~= nil then
								kind = "Legendary"
							end
						end

						table.insert( index, { Name = traitName, Kind = kind, Sets = sets } )
					end
				end
			end
		end
	end

	return index
end

function BoonAdvisor.GetLinkedIndex()
	if BoonAdvisor.LinkedIndex == nil then
		BoonAdvisor.LinkedIndex = BoonAdvisor.BuildLinkedIndex()
	end
	return BoonAdvisor.LinkedIndex
end

function BoonAdvisor.HeroHasTrait( traitName )
	local prepared = BoonAdvisor.ForecastHeroTraitNames
	if BoonAdvisor.ForecastHeroTraitNamesActive and prepared ~= nil then
		return prepared[traitName] == true
	end
	if HeroHasTrait ~= nil then return HeroHasTrait( traitName ) end
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	for _, trait in pairs( hero ~= nil and hero.Traits or {} ) do
		if trait.Name == traitName then return true end
	end
	return false
end

-- Kind of an offered boon, if it is itself a gated (duo/legendary) boon.
function BoonAdvisor.KindOf( traitName )
	for _, entry in ipairs( BoonAdvisor.GetLinkedIndex() ) do
		if entry.Name == traitName then
			return entry.Kind
		end
	end
	return nil
end

function BoonAdvisor.HeroHasAnyOf( traitNames, ignoredTraitName )
	for _, traitName in ipairs( traitNames ) do
		if traitName ~= ignoredTraitName and BoonAdvisor.HeroHasTrait( traitName ) then
			return true
		end
	end
	return false
end

-- Match UpgradeChoice.GetEligibleTraitUpgrades: linked boons become offerable
-- only after every dependency group has at least one owned trait.
function BoonAdvisor.LinkedRequirementMet( requirement )
	if type( requirement ) ~= "table" then
		return false
	end
	if type( requirement.OneOf ) == "table" then
		return BoonAdvisor.HeroHasAnyOf( requirement.OneOf )
	end
	if type( requirement.OneFromEachSet ) == "table" then
		for _, set in ipairs( requirement.OneFromEachSet ) do
			if not BoonAdvisor.HeroHasAnyOf( set ) then
				return false
			end
		end
		return true
	end
	return false
end

function BoonAdvisor.SlotFilled( slot )
	if slot == nil or CurrentRun == nil or CurrentRun.Hero == nil then
		return false
	end
	for _, trait in pairs( CurrentRun.Hero.Traits ) do
		local traitData = TraitData[trait.Name]
		if traitData ~= nil and traitData.Slot == slot then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Scoring terms
---------------------------------------------------------------------------

--[[
	How much closer does taking `candidateName` bring us to gated boons?

	Contributions are pooled rather than summed outright: the largest counts in
	full and the rest at SecondaryFactor. A boon that lightly nudges a dozen
	single-set gates must not outrank one that actually completes a duo.

	Returns the point total and the single most interesting reason.
]]
function BoonAdvisor.EvaluateSynergy( candidateName, replacedTraitName )
	local weights = BoonAdvisor.Config.Weights
	local contributions = {}
	local best = nil

	local function note( priority, magnitude, text )
		if best == nil or priority > best.Priority
			or ( priority == best.Priority and magnitude > best.Magnitude ) then
			best = { Priority = priority, Magnitude = magnitude, Text = text }
		end
	end

	for _, entry in ipairs( BoonAdvisor.GetLinkedIndex() ) do
		-- Already owned, or the candidate is the gated boon itself: nothing to advance.
		local alreadyOwned = entry.Name ~= replacedTraitName
			and BoonAdvisor.HeroHasTrait( entry.Name )
		if entry.Name ~= candidateName and not alreadyOwned then
			local setCount = TableLength( entry.Sets )
			local satisfiedBefore = 0
			local satisfiedAfter = 0
			for _, set in ipairs( entry.Sets ) do
				if BoonAdvisor.HeroHasAnyOf( set ) then
					satisfiedBefore = satisfiedBefore + 1
				end
				if BoonAdvisor.HeroHasAnyOf( set, replacedTraitName ) then
					satisfiedAfter = satisfiedAfter + 1
				elseif Contains( set, candidateName ) then
					satisfiedAfter = satisfiedAfter + 1
				end
			end

			if satisfiedAfter ~= satisfiedBefore then
				local displayName = BoonAdvisor.TraitDisplayName( entry.Name )
				local isDuo = ( entry.Kind == "Duo" )

				if satisfiedAfter > satisfiedBefore and satisfiedAfter >= setCount then
					if isDuo then
						table.insert( contributions, weights.DuoComplete )
						note( 4, weights.DuoComplete, "enables " .. displayName )
					else
						table.insert( contributions, weights.UpgradeGate )
						note( 1, weights.UpgradeGate, "opens " .. displayName )
					end
				elseif satisfiedAfter > satisfiedBefore and isDuo and satisfiedBefore >= 1 then
					--[[
						Partial progress only counts once the run is already
						invested in this duo. Otherwise every boon on an empty
						build "advances" a dozen duos to 1/2, which inflates
						every score equally and says nothing useful.
					]]
					table.insert( contributions, weights.DuoProgress )
					note( 3, weights.DuoProgress,
						displayName .. " " .. satisfiedAfter .. "/" .. setCount )
				elseif satisfiedAfter < satisfiedBefore and satisfiedBefore >= setCount then
					local loss = isDuo and weights.DuoComplete or weights.UpgradeGate
					table.insert( contributions, -loss )
					note( isDuo and 4 or 2, loss, "swap closes " .. displayName )
				end
			end
		end
	end

	-- Pool gains and losses independently so replacing one prerequisite cannot
	-- be hidden by a long list of small positive gates.
	local positiveTotal, positiveLargest = 0, 0
	local negativeTotal, negativeLargest = 0, 0
	for _, value in ipairs( contributions ) do
		if value >= 0 then
			positiveTotal = positiveTotal + value
			if value > positiveLargest then positiveLargest = value end
		else
			local magnitude = -value
			negativeTotal = negativeTotal + magnitude
			if magnitude > negativeLargest then negativeLargest = magnitude end
		end
	end
	local positive = positiveLargest
		+ ( positiveTotal - positiveLargest ) * weights.SecondaryFactor
	local negative = negativeLargest
		+ ( negativeTotal - negativeLargest ) * weights.SecondaryFactor
	local total = positive - negative

	if total > weights.MaxSynergy then
		total = weights.MaxSynergy
	elseif total < -weights.MaxSynergy then
		total = -weights.MaxSynergy
	end

	return total, best
end

--[[
	Status Curses, read from the game's own effect data.

	This matters because of the Mirror. "Privileged Status"
	(VulnerabilityEffectBonusMetaUpgrade)
	grants bonus damage against foes carrying 2 or more DIFFERENT status curses,
	so a build wants breadth of curses, not more of the same one. Its B-side,
	"Family Favorite" (GodEnhancementMetaUpgrade), instead pays per distinct Olympian, so
	that build wants breadth of gods.

	They pull in opposite directions, and which one the player selected is
	knowable at runtime -- so the advice can follow their actual Mirror.

	The mapping below covers all seven status curses that count toward
	Privileged Status. Each is identified by the effect the trait applies, so
	membership is derived from TraitData rather than hardcoded per boon.
]]
-- Mirror talent keys, as they appear in MetaUpgradeData (asserted by tests).
BoonAdvisor.MetaKeys =
{
	PrivilegedStatus = "VulnerabilityEffectBonusMetaUpgrade",
	FamilyFavorite   = "GodEnhancementMetaUpgrade",
	DuoRarity        = "DuoRarityBoonDropMetaUpgrade",
	ExtraChance      = "ExtraChanceMetaUpgrade",
	RerollPanel      = "RerollPanelMetaUpgrade",
}

BoonAdvisor.CurseEffects =
{
	ReduceDamageOutput           = "Weak",     -- Aphrodite
	DelayedDamage                = "Doom",     -- Ares
	DamageOverTime               = "Hangover", -- Dionysus
	DemeterSlow                  = "Chill",    -- Demeter
	ZeusAttackPenalty            = "Jolted",   -- Zeus: Static Discharge
	DamageOverDistance           = "Ruptured", -- Poseidon: Razor Shoals
	AthenaBackstabVulnerability  = "Exposed",  -- Athena: Blinding Flash
}

BoonAdvisor.CurseCache = {}

-- Walk a trait's data looking for a curse-applying effect.
local function findCurse( value, depth, seen )
	if depth > 6 or type( value ) ~= "table" then
		return nil
	end
	seen = seen or {}
	if seen[value] then
		return nil
	end
	seen[value] = true

	for key, inner in pairs( value ) do
		if key == "EffectName" and type( inner ) == "string" then
			local curse = BoonAdvisor.CurseEffects[inner]
			if curse ~= nil then
				return curse
			end
		elseif type( inner ) == "table" then
			local found = findCurse( inner, depth + 1, seen )
			if found ~= nil then
				return found
			end
		end
	end
	return nil
end

function BoonAdvisor.CurseTypeOf( traitName )
	if BoonAdvisor.CurseCache[traitName] ~= nil then
		local cached = BoonAdvisor.CurseCache[traitName]
		if cached == false then return nil end
		return cached
	end

	local curse = findCurse( TraitData[traitName], 1 )
	BoonAdvisor.CurseCache[traitName] = curse or false
	return curse
end

-- Distinct curses and gods the run already covers.
function BoonAdvisor.RunCoverage( ignoredTraitName )
	local curses, gods = {}, {}
	local curseCount, godCount = 0, 0
	if CurrentRun == nil or CurrentRun.Hero == nil then
		return curses, curseCount, gods, godCount
	end

	for _, trait in pairs( CurrentRun.Hero.Traits ) do
		local name = trait.Name
		if name ~= nil and name ~= ignoredTraitName then
			local curse = BoonAdvisor.CurseTypeOf( name )
			if curse ~= nil and not curses[curse] then
				curses[curse] = true
				curseCount = curseCount + 1
			end
			local traitData = TraitData[name]
			local god = traitData ~= nil and traitData.God or nil
			if god ~= nil and not gods[god] then
				gods[god] = true
				godCount = godCount + 1
			end
		end
	end
	return curses, curseCount, gods, godCount
end

--[[
	Follow the player's Mirror choice. Returns bonus, reason.
]]
function BoonAdvisor.MetaBonus( traitName, replacedTraitName )
	if IsMetaUpgradeSelected == nil and GetNumMetaUpgrades == nil then
		return 0, nil
	end
	local weights = BoonAdvisor.Config.Weights
	local currentCurses, currentCurseCount, currentGods, currentGodCount =
		BoonAdvisor.RunCoverage()
	local finalCurses, finalCurseCount, finalGods, finalGodCount =
		BoonAdvisor.RunCoverage( replacedTraitName )

	--[[
		These are MetaUpgradeData keys, which IsMetaUpgradeSelected matches
		against GameState.MetaUpgradesSelected (MetaUpgrades.lua:1989).

		They are NOT the names on the icons: Privileged Status is
		VulnerabilityEffectBonusMetaUpgrade (its icon is merely called
		MirrorIcon_EffectVulnerability). An earlier version passed
		"EffectVulnerability" and "GodEnhancement", which match nothing, so all
		Mirror awareness was silently dead -- and the test suite missed it
		because it stubbed IsMetaUpgradeSelected with those same wrong names.
		The suite now asserts both keys exist in MetaUpgradeData.
	]]
	if BoonAdvisor.MetaUpgradeActive( BoonAdvisor.MetaKeys.PrivilegedStatus ) then
		local curse = BoonAdvisor.CurseTypeOf( traitName )
		if curse ~= nil and not finalCurses[curse] then
			finalCurses[curse] = true
			finalCurseCount = finalCurseCount + 1
		end
		local function curseCoverageValue( count )
			if count >= 2 then
				return weights.PrivilegedStatusFirst + weights.PrivilegedStatusOn
			elseif count == 1 then
				return weights.PrivilegedStatusFirst
			end
			return 0
		end
		local delta = curseCoverageValue( finalCurseCount )
			- curseCoverageValue( currentCurseCount )
		if delta > 0 and currentCurseCount < 2 and finalCurseCount >= 2 then
			return delta, "adds " .. tostring( curse ) .. ": triggers Privileged Status"
		elseif delta > 0 then
			return delta, "first status curse (" .. tostring( curse ) .. ")"
		elseif delta < 0 then
			return delta, "swap drops Privileged Status"
		end
	elseif BoonAdvisor.MetaUpgradeActive( BoonAdvisor.MetaKeys.FamilyFavorite ) then
		local traitData = TraitData[traitName]
		local god = traitData ~= nil and traitData.God or nil
		if god ~= nil and not finalGods[god] then
			finalGods[god] = true
			finalGodCount = finalGodCount + 1
		end
		local delta = ( finalGodCount - currentGodCount ) * weights.FamilyFavorite
		if delta > 0 then
			return delta, "new god: Family Favorite +damage"
		elseif delta < 0 then
			return delta, "swap loses a Family Favorite god"
		end
	end

	return 0, nil
end

-- IsMetaUpgradeSelected only reports the green/red side chosen at the Mirror.
-- Routine Inspection can null that row for the run. Prefer the game's active
-- check so a disabled Privileged Status or Family Favorite receives no credit.
function BoonAdvisor.MetaUpgradeActive( upgradeName )
	if IsMetaUpgradeActive ~= nil then
		local success, active = pcall( IsMetaUpgradeActive, upgradeName )
		if success then return active == true end
	end
	if CurrentRun ~= nil and CurrentRun.MetaUpgradeCache ~= nil
		and GetNumMetaUpgrades ~= nil then
		return ( GetNumMetaUpgrades( upgradeName ) or 0 ) > 0
	end
	if GetNumMetaUpgrades ~= nil
		and ( GetNumMetaUpgrades( upgradeName ) or 0 ) > 0 then
		return true
	end
	return IsMetaUpgradeSelected ~= nil
		and IsMetaUpgradeSelected( upgradeName ) or false
end

--[[
	Does this pick belong to a known strong build we are already on track for?

	Returns bonus, reason. Only archetypes that are plausible for the current
	run count -- see the note on Ratings.Archetypes -- so this steers a build
	that is already forming rather than proposing one at random.
]]
function BoonAdvisor.ActiveObjectiveName()
	local profiles = BoonAdvisor.Config.ObjectiveProfiles or {}
	local name = BoonAdvisor.Config.Objective or "Balanced"
	if profiles[name] == nil then return "Balanced" end
	return name
end

function BoonAdvisor.ObjectiveProfile()
	local profiles = BoonAdvisor.Config.ObjectiveProfiles or {}
	return profiles[BoonAdvisor.ActiveObjectiveName()] or profiles.Balanced or {}
end

function BoonAdvisor.ObjectiveTraitBonus( traitName )
	local tags = BoonAdvisor.Ratings.ObjectiveTags or {}
	local bonuses = BoonAdvisor.ObjectiveProfile().TraitTagBonus or {}
	local total = 0
	for tagName, traitSet in pairs( tags ) do
		if traitSet[traitName] then
			total = total + ( bonuses[tagName] or 0 )
		end
	end
	return total
end

function BoonAdvisor.ObjectiveRiskMultiplier()
	return BoonAdvisor.ObjectiveProfile().RiskMultiplier or 1
end

function BoonAdvisor.ObjectiveDoorBonus( rewardType )
	return ( BoonAdvisor.ObjectiveProfile().DoorBonus or {} )[rewardType] or 0
end

function BoonAdvisor.PactSurvivalBonus( traitName )
	local survival = BoonAdvisor.Ratings.ObjectiveTags ~= nil
		and BoonAdvisor.Ratings.ObjectiveTags.Survival or nil
	if survival == nil or not survival[traitName]
		or BoonAdvisor.DangerLevel == nil then
		return 0
	end
	local config = BoonAdvisor.Config.Pact or {}
	return math.min( config.SurvivalBonusCap or 0,
		BoonAdvisor.DangerLevel() * ( config.SurvivalBonusPerDanger or 0 ) )
end

function BoonAdvisor.PactDoorBonus( rewardType )
	if BoonAdvisor.TimerPressure == nil then return 0 end
	local config = BoonAdvisor.Config.Pact or {}
	return ( ( config.TimerDoorBonus or {} )[rewardType] or 0 )
		* BoonAdvisor.TimerPressure()
end

function BoonAdvisor.ArchetypeMultiplier()
	local multiplier = BoonAdvisor.ObjectiveProfile().ArchetypeMultiplier or 1
	if BoonAdvisor.PactClearMultiplier ~= nil then
		multiplier = multiplier * BoonAdvisor.PactClearMultiplier()
	end
	return multiplier
end

function BoonAdvisor.ArchetypeBonus( traitName, replacedTraitName )
	local weights = BoonAdvisor.Config.Weights
	local objectiveName = BoonAdvisor.ActiveObjectiveName()
	local multiplier = BoonAdvisor.ArchetypeMultiplier()
	local bestScore = 0
	local bestReason = nil

	for _, archetype in ipairs( BoonAdvisor.Ratings.Archetypes ) do
		local liveBefore = false
		local liveAfter = false
		local hasRetainedCore = false
		if archetype.Aspect ~= nil then
			liveBefore = BoonAdvisor.HeroHasTrait( archetype.Aspect )
			liveAfter = liveBefore
			hasRetainedCore = liveBefore
		else
			liveBefore = BoonAdvisor.HeroHasAnyOf( archetype.Core )
			hasRetainedCore = BoonAdvisor.HeroHasAnyOf(
				archetype.Core, replacedTraitName )
			liveAfter = hasRetainedCore
				or ( liveBefore and Contains( archetype.Core, traitName ) )
		end

		local objectiveBonus = archetype.ObjectiveBonus ~= nil
			and ( archetype.ObjectiveBonus[objectiveName] or 0 ) or 0
		local candidateValue = 0
		if liveAfter then
			if archetype.Payoff == traitName then
				candidateValue = ( archetype.PayoffBonus or weights.ArchetypePayoff )
					* multiplier + objectiveBonus
			elseif Contains( archetype.Core, traitName )
				and not BoonAdvisor.HeroHasTrait( traitName ) then
				candidateValue = ( archetype.CoreBonus or weights.ArchetypeCore )
					* multiplier + objectiveBonus
			end
		end

		local replacedValue = 0
		if replacedTraitName ~= nil and liveBefore and hasRetainedCore then
			if archetype.Payoff == replacedTraitName then
				replacedValue = ( archetype.PayoffBonus or weights.ArchetypePayoff )
					* multiplier + objectiveBonus
			elseif Contains( archetype.Core, replacedTraitName ) then
				replacedValue = ( archetype.CoreBonus or weights.ArchetypeCore )
					* multiplier + objectiveBonus
			end
		end

		local delta = candidateValue - replacedValue
		if math.abs( delta ) > math.abs( bestScore ) then
			bestScore = delta
			if delta < 0 then
				bestReason = "breaks the " .. archetype.Name .. " build"
			elseif archetype.Payoff == traitName then
				bestReason = "completes the " .. archetype.Name .. " build"
			else
				bestReason = "core of the " .. archetype.Name .. " build"
			end
		end
	end

	return bestScore, bestReason
end

--[[
	Knockback scales with the biome.

	Combat.lua:860 multiplies collision damage by CurrentRun.CurrentRoom.
	WallSlamMultiplier, which is set per biome: none in Tartarus, 1.5 in
	Asphodel, 2.0 in Elysium, 2.5 in Styx. A wall slam in Styx therefore does
	2.5x what the same slam does in Tartarus, so knockback boons are genuinely
	worth more the deeper the run is -- this is read from the live room rather
	than assumed from depth.
]]
function BoonAdvisor.KnockbackBonus( traitName )
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	local slamMultiplier = room ~= nil and room.WallSlamMultiplier or 1.0
	if slamMultiplier <= 1.0 then
		return 0, nil
	end
	if not BoonAdvisor.Ratings.KnockbackTraits[traitName] then
		return 0, nil
	end
	local weights = BoonAdvisor.Config.Weights
	local bonus = weights.KnockbackPerSlamMultiplier * ( slamMultiplier - 1.0 )
	return bonus, "wall slams hit " .. slamMultiplier .. "x here"
end

--[[
	Boons whose value the active Pact changes (see Ratings.PactConditionalBoons).
	Returns bonus, reason.
]]
function BoonAdvisor.PactBonus( traitName )
	if GetNumMetaUpgrades == nil then
		return 0, nil
	end
	local total = 0
	local reason = nil
	local reasonMagnitude = 0
	for shrineName, boons in pairs( BoonAdvisor.Ratings.PactConditionalBoons ) do
		local bonus = boons[traitName]
		local ranks = GetNumMetaUpgrades( shrineName ) or 0
		if bonus ~= nil and ranks > 0 then
			local contribution = bonus * ranks
			local candidateReason = nil
			if shrineName == "TrapDamageShrineUpgrade" then
				candidateReason = "traps hit hard this run"
			elseif shrineName == "EnemyShieldShrineUpgrade" then
				candidateReason = "extra hits break Damage Control"
			elseif shrineName == "BiomeSpeedShrineUpgrade" then
				local pressure = BoonAdvisor.TimerPressure ~= nil
					and BoonAdvisor.TimerPressure() or ranks
				contribution = bonus * pressure
				candidateReason = "the biome timer rewards speed"
			elseif shrineName == "EnemySpeedShrineUpgrade" then
				candidateReason = "slows foes under Forced Overtime"
			elseif shrineName == "EnemyCountShrineUpgrade" then
				candidateReason = "area damage clears Jury Summons"
			end
			total = total + contribution
			if candidateReason ~= nil and contribution > reasonMagnitude then
				reason = candidateReason
				reasonMagnitude = contribution
			end
		end
	end
	return total, reason
end

function BoonAdvisor.PactHammerBonus( traitName )
	if GetNumMetaUpgrades == nil then return 0, nil end
	local tableByShrine = BoonAdvisor.Ratings.PactConditionalHammers or {}
	local total = 0
	local reason = nil
	local reasonMagnitude = 0
	for shrineName, hammers in pairs( tableByShrine ) do
		local ranks = GetNumMetaUpgrades( shrineName ) or 0
		if ranks > 0 and hammers[traitName] ~= nil then
			local contribution = hammers[traitName] * ranks
			total = total + contribution
			local candidateReason = shrineName == "EnemyShieldShrineUpgrade"
				and "extra hits break Damage Control"
				or shrineName == "EnemyEliteShrineUpgrade"
				and "breaks dangerous armored foes"
				or "area damage clears Jury Summons"
			if contribution > reasonMagnitude then
				reason = candidateReason
				reasonMagnitude = contribution
			end
		end
	end
	if total > 0 then return total, reason end
	return 0, nil
end

--[[
	How much risk the run can currently absorb.

	Returns a 0..1 factor. Death Defiances are extra lives
	(CurrentRun.Hero.LastStands), so a run holding two of them can take a
	dangerous room far more comfortably than one on its last legs. Used to
	temper the risk priced into the Trial and the Chaos gate.
]]
function BoonAdvisor.RiskTolerance()
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	if hero == nil then
		return 0
	end
	local defiances = 0
	if BoonAdvisor.LastStandsRemaining ~= nil then
		defiances = BoonAdvisor.LastStandsRemaining()
	elseif type( hero.LastStands ) == "table" then
		defiances = TableLength( hero.LastStands )
	else
		defiances = hero.LastStands or 0
	end
	local tolerance = defiances * BoonAdvisor.Config.Weights.RiskPerDeathDefiance
	if tolerance > 1 then
		tolerance = 1
	end
	return tolerance
end

-- The biome we are currently in, e.g. "Tartarus", "Elysium", "Styx".
function BoonAdvisor.CurrentBiome()
	local room = CurrentRun ~= nil and CurrentRun.CurrentRoom or nil
	return room ~= nil and room.RoomSetName or nil
end

--[[
	There is deliberately no armour bonus here.

	I added one, then checked: "armour" in Hades is HeavyArmor, an ELITE
	attribute (EnemyData.lua:158) whose entire effect is
	HealthMultiplier = 1.5 -- more health, not damage resistance -- and it is
	applied per elite, not per biome. So there is no biome where foes are
	uniformly armoured, and no per-boon interaction worth scoring.

	The feature was reverted rather than shipped. Kept as a note so the same
	wrong assumption is not made a third time.
]]

--[[
	Investing in the duo-rarity Mirror talent makes duos likelier to appear,
	so chasing one is a better bet. Scales with how much is invested.
]]
function BoonAdvisor.DuoPursuitFactor()
	local factor = 1
	if GetNumMetaUpgrades ~= nil then
		local levels = GetNumMetaUpgrades( BoonAdvisor.MetaKeys.DuoRarity ) or 0
		factor = factor + ( levels * BoonAdvisor.Config.Weights.DuoRarityPerLevel )
	end

	-- Approval Process removes one visible choice per rank. With only one of
	-- three generated choices visible, forcing a particular duo is materially
	-- less reliable, so scale pursuit by the actual choice count.
	local choices = 3
	if CalcNumLootChoices ~= nil then
		choices = CalcNumLootChoices() or choices
	elseif GetNumMetaUpgrades ~= nil then
		choices = choices - ( GetNumMetaUpgrades( "ReducedLootChoicesShrineUpgrade" ) or 0 )
	end
	if choices < 1 then choices = 1 end
	if choices > 3 then choices = 3 end
	return factor * ( choices / 3 )
end

function BoonAdvisor.AspectBonus( slot )
	if slot == nil then
		return 0
	end
	for aspectTrait, slotBonuses in pairs( BoonAdvisor.Ratings.AspectAffinity ) do
		if BoonAdvisor.HeroHasTrait( aspectTrait ) then
			return slotBonuses[slot] or 0
		end
	end
	return 0
end

--[[
	Bring a raw score onto the displayed 0-99 scale: compress the top end so
	strong picks stay distinguishable, then clamp. Shared by the boon screen
	and the door advisor so both mean the same thing by "A 84".
]]
function BoonAdvisor.Finalize( score )
	local config = BoonAdvisor.Config
	if score > config.SoftKnee then
		score = config.SoftKnee + ( score - config.SoftKnee ) * config.SoftKneeFactor
	end
	if score < 1 then score = 1 end
	if score > 99 then score = 99 end
	return score
end

-- Rank letter and colour for a finalized score.
function BoonAdvisor.RankFor( score )
	local config = BoonAdvisor.Config
	local thresholds = config.RankThresholds
	for _, threshold in ipairs( thresholds ) do
		if score >= threshold.Min then
			return threshold.Rank, threshold.Color
		end
	end
	local last = thresholds[TableLength( thresholds )]
	return last.Rank, last.Color
end

---------------------------------------------------------------------------
-- Hammers and Chaos
---------------------------------------------------------------------------

-- The aspect the player is carrying, or nil on a base aspect / unknown weapon.
function BoonAdvisor.CurrentAspect()
	for aspectTrait, _ in pairs( BoonAdvisor.Ratings.HammerAspectMod ) do
		if BoonAdvisor.HeroHasTrait( aspectTrait ) then
			return aspectTrait
		end
	end
	return nil
end

--[[
	Daedalus hammers. A flat tier list is not enough here: the same hammer can
	be excellent or actively bad depending on the aspect, so an aspect-specific
	delta is applied on top and reported as the reason.
]]
function BoonAdvisor.ScoreHammer( traitName )
	local base = BoonAdvisor.Ratings.Hammers[traitName]
	local reason = nil

	if base == nil then
		-- An unrated hammer: say so rather than inventing a number.
		return BoonAdvisor.Config.Weights.DefaultBase, "unrated hammer"
	end

	local aspect = BoonAdvisor.CurrentAspect()
	if aspect ~= nil then
		local delta = BoonAdvisor.Ratings.HammerAspectMod[aspect][traitName]
		if delta ~= nil and delta ~= 0 then
			base = base + delta
			local aspectName = BoonAdvisor.TraitDisplayName( aspect )
			if delta > 0 then
				reason = "strong on " .. aspectName
			else
				reason = "weak on " .. aspectName
			end
		end
	end

	local pactBonus, pactReason = BoonAdvisor.PactHammerBonus( traitName )
	base = base + pactBonus
	if pactReason ~= nil and reason == nil then
		reason = pactReason
	end

	if reason == nil then
		if base >= 78 then
			reason = "top-tier hammer"
		elseif base >= 68 then
			reason = "solid hammer"
		else
			reason = "situational"
		end
	end

	return base, reason
end

--[[
	Pom of Power. A Pom levels a boon you already hold, so the "slot is taken"
	penalty that applies to boon offers is exactly wrong here -- holding the
	boon is the precondition, not a drawback.

	What actually matters is diminishing returns. Hades front-loads Pom levels:
	in the observed case Thunder Dash Lv1 -> Lv2 gained +8 bolt damage while
	Lightning Strike Lv3 -> Lv4 gained +2. So value is the boon's own strength
	minus a penalty per level already stacked.
]]
function BoonAdvisor.GetPomCandidates( lootData )
	local candidates = {}
	local seen = {}
	local stackData = lootData
	if stackData == nil and LootData ~= nil then
		stackData = LootData.StackUpgrade
	end

	local function addCandidate( traitName )
		if traitName == nil or seen[traitName] or TraitData[traitName] == nil then
			return
		end
		local eligible = stackData == nil or stackData.StripRequirements
			or IsGameStateEligible == nil
			or IsGameStateEligible( CurrentRun, TraitData[traitName] )
		if eligible then
			seen[traitName] = true
			table.insert( candidates, traitName )
		end
	end

	if GetAllUpgradeableGodTraits ~= nil then
		for traitName, _ in pairs( GetAllUpgradeableGodTraits() ) do
			addCandidate( traitName )
		end
	elseif CurrentRun ~= nil and CurrentRun.Hero ~= nil
		and type( CurrentRun.Hero.Traits ) == "table" then
		for _, trait in pairs( CurrentRun.Hero.Traits ) do
			if trait.RemainingUses == nil
				and ( IsGodTrait == nil or IsGodTrait( trait.Name ) ) then
				addCandidate( trait.Name )
			end
		end
	end

	return candidates
end

function BoonAdvisor.OwnedTraitData( traitName )
	local hero = CurrentRun ~= nil and CurrentRun.Hero or nil
	if hero == nil or type( hero.Traits ) ~= "table" then
		return nil
	end
	local fallback = nil
	for _, trait in pairs( hero.Traits ) do
		if trait.Name == traitName then
			fallback = fallback or trait
			if trait.Rarity ~= nil then
				return trait
			end
		end
	end
	return fallback
end

-- Value an additional level in the build that actually owns the boon. The
-- normal archetype helper intentionally ignores already-owned core boons,
-- which is correct for new offers but exactly wrong for Pom targets.
function BoonAdvisor.PomBuildBonus( traitName )
	local traitData = TraitData[traitName]
	local bonus = BoonAdvisor.AspectBonus( traitData ~= nil and traitData.Slot or nil )
	bonus = bonus + BoonAdvisor.ObjectiveTraitBonus( traitName )
	local bestArchetypeBonus = 0
	local bestArchetypeName = nil

	for _, archetype in ipairs( BoonAdvisor.Ratings.Archetypes ) do
		local live
		if archetype.Aspect ~= nil then
			live = BoonAdvisor.HeroHasTrait( archetype.Aspect )
		else
			live = BoonAdvisor.HeroHasAnyOf( archetype.Core )
		end

		if live then
			local objectiveName = BoonAdvisor.ActiveObjectiveName()
			local objectiveBonus = archetype.ObjectiveBonus ~= nil
				and ( archetype.ObjectiveBonus[objectiveName] or 0 ) or 0
			local multiplier = BoonAdvisor.ArchetypeMultiplier()
			local candidateBonus = 0
			if archetype.Payoff == traitName then
				candidateBonus = ( archetype.PayoffBonus
					or BoonAdvisor.Config.Weights.ArchetypePayoff ) * multiplier
					+ objectiveBonus
			elseif Contains( archetype.Core, traitName ) then
				candidateBonus = ( archetype.CoreBonus
					or BoonAdvisor.Config.Weights.ArchetypeCore ) * multiplier
					+ objectiveBonus
			end
			if candidateBonus > bestArchetypeBonus then
				bestArchetypeBonus = candidateBonus
				bestArchetypeName = archetype.Name
			end
		end
	end

	return bonus + bestArchetypeBonus, bestArchetypeName
end

local function findPomCurveOverride( value, depth, seen )
	if type( value ) ~= "table" or depth > 7 then return nil, nil end
	seen = seen or {}
	if seen[value] then return nil, nil end
	seen[value] = true

	if type( value.IdenticalMultiplier ) == "table"
		and type( value.IdenticalMultiplier.DiminishingReturnsMultiplier ) == "number" then
		return value.IdenticalMultiplier.DiminishingReturnsMultiplier,
			type( value.MinMultiplier ) == "number" and value.MinMultiplier or nil
	end
	for _, child in pairs( value ) do
		if type( child ) == "table" then
			local diminishing, minimum = findPomCurveOverride( child, depth + 1, seen )
			if diminishing ~= nil then return diminishing, minimum end
		end
	end
	return nil, nil
end

function BoonAdvisor.PomCurveForTrait( traitName )
	local weights = BoonAdvisor.Config.Weights
	local diminishing, minimum = findPomCurveOverride( TraitData[traitName], 1 )
	return diminishing or weights.PomDiminishing,
		minimum or weights.PomMinMultiplier
end

function BoonAdvisor.ScorePom( traitName, lootData )
	local base = BoonAdvisor.Ratings.Base[traitName]
	if base == nil then
		local kind = BoonAdvisor.KindOf( traitName )
		base = BoonAdvisor.Ratings.CategoryDefaults[kind]
			or BoonAdvisor.Config.Weights.DefaultBase
	end

	local level = 1
	if GetTraitNameCount ~= nil and CurrentRun ~= nil and CurrentRun.Hero ~= nil then
		level = GetTraitNameCount( CurrentRun.Hero, traitName ) or 1
	end
	if level < 1 then
		level = 1
	end

	local levels = 1
	if lootData ~= nil and lootData.StackNum ~= nil and lootData.StackNum > 0 then
		levels = lootData.StackNum
	end

	local ownedTrait = BoonAdvisor.OwnedTraitData( traitName )
	local weights = BoonAdvisor.Config.Weights
	if ownedTrait ~= nil and ownedTrait.Rarity ~= nil then
		base = base + ( weights.Rarity[ownedTrait.Rarity] or 0 )
			* weights.PomRarityFactor
	end
	local buildBonus, buildName = BoonAdvisor.PomBuildBonus( traitName )
	base = base + buildBonus
	local diminishing, minimum = BoonAdvisor.PomCurveForTrait( traitName )

	--[[
		The game's own diminishing-returns curve, from TraitScripts:

			totalDiminishingMultiplier = diminishing ^ (i - 1)
			if totalMultiplier < minMultiplier then totalMultiplier = minMultiplier end

		with TraitMultiplierData.DefaultDiminishingReturnsMultiplier = 0.7 and
		DefaultMinMultiplier = 0.1. So each further level is worth 70% of the
		last, never dropping below a tenth -- geometric decay with a floor, not
		the flat per-level penalty an earlier version of this used, which had
		no floor and went on subtracting forever.
	]]
	local marginal = 0
	for addedLevel = 0, levels - 1 do
		local levelMultiplier = math.pow(
			diminishing, level - 1 + addedLevel )
		if levelMultiplier < minimum then
			levelMultiplier = minimum
		end
		marginal = marginal + levelMultiplier
	end
	local score = base * marginal

	local reason
	if buildName ~= nil then
		reason = buildName .. " core, Lv." .. level
	elseif level == 1 then
		reason = "Lv.1, biggest jump"
	elseif level >= 4 then
		reason = "Lv." .. level .. ", worth little now"
	elseif level >= 3 then
		reason = "Lv." .. level .. ", diminishing"
	else
		reason = "Lv." .. level .. " to " .. ( level + levels )
	end

	return score, reason
end

--[[
	Chaos boons carry a blessing (ItemName) and a curse (SecondaryItemName).
	Price both halves, and let the blessing gain value when it scales with a
	slot the run has already filled -- extra Cast charges matter far more once
	there is a Cast worth firing.
]]
function BoonAdvisor.ScoreChaos( itemData )
	local ratings = BoonAdvisor.Ratings
	local blessing = itemData.ItemName
	local curse = itemData.SecondaryItemName

	local score = ratings.ChaosBlessings[blessing]
		or ratings.CategoryDefaults.Chaos
		or BoonAdvisor.Config.Weights.DefaultBase
	-- Chaos rarity scales the permanent blessing (Rare 1.5x, Epic 2x) while
	-- the temporary curse does not have rarity levels.
	score = score + ( BoonAdvisor.Config.Weights.Rarity[itemData.Rarity] or 0 )
	local reason = nil

	local slot = ratings.ChaosBlessingSlots[blessing]
	if slot ~= nil and BoonAdvisor.SlotFilled( slot ) then
		score = score + 10
		reason = "boosts your " .. BoonAdvisor.SlotDisplayName( slot )
	end

	if curse ~= nil then
		score = score - ( ratings.ChaosCurses[curse] or 8 )
	end

	if reason == nil then
		if score >= 70 then
			reason = "strong blessing"
		elseif score >= 55 then
			reason = "fair trade"
		else
			reason = "weak payoff"
		end
	end

	return score, reason
end

---------------------------------------------------------------------------
-- Top level
---------------------------------------------------------------------------

--[[
	Score one offered option. Returns:
	  { Score = 0..99, Rank = "S".."D", Color = {...}, Reason = string }
]]
function BoonAdvisor.ScoreOption( itemData, lootData )
	local config = BoonAdvisor.Config
	local weights = config.Weights
	local traitName = itemData.ItemName

	local score = weights.DefaultBase
	local reason = nil

	local isHammer = ( lootData ~= nil and lootData.Name == "WeaponUpgrade" )

	local isPom = ( lootData ~= nil and lootData.Name == "StackUpgrade" )

	if isHammer then
		score, reason = BoonAdvisor.ScoreHammer( traitName )
		--[[
			Hammers exclude each other: 42 of them block at least one other,
			and the casualty is sometimes the weapon's best (Spread Fire locks
			out Delta Chamber). This branch used to skip the shared context
			entirely, so those forfeits were invisible on the hammer screen.
		]]
		local hammerExclusion, hammerExclusionReason = BoonAdvisor.ExclusionPenalty( traitName )
		score = score + hammerExclusion
		if hammerExclusionReason ~= nil then
			reason = hammerExclusionReason
		end
	elseif isPom then
		score, reason = BoonAdvisor.ScorePom( traitName, lootData )
	elseif itemData.Type == "TransformingTrait" then
		score, reason = BoonAdvisor.ScoreChaos( itemData )
	elseif itemData.Type ~= "Trait" then
		score = BoonAdvisor.Ratings.CategoryDefaults.Consumable or weights.DefaultBase
	else
		-- Tier baseline, falling back to the category default for gated boons.
		local base = BoonAdvisor.Ratings.Base[traitName]
		if base == nil then
			local kind = BoonAdvisor.KindOf( traitName )
			base = BoonAdvisor.Ratings.CategoryDefaults[kind] or weights.DefaultBase
		end
		score = base

		-- Rarity nudge.
		score = score + ( weights.Rarity[itemData.Rarity] or 0 )

		-- Slot economy.
		local reasonPriority = 0
		local traitData = TraitData[traitName]
		local slot = traitData ~= nil and traitData.Slot or nil

		--[[
			Replacement offers are a swap, so their value is a DIFFERENCE.

			With ReplaceChance (0.10) the game turns one of the three options
			into a replacement built by GetReplacementTraits: a boon from this
			god that takes over a slot you have filled, arriving at
			GetUpgradedRarity(existing) -- exactly one tier above what you
			currently hold there. (No tier exists above Heroic, so a Heroic
			boon can never be replaced this way.)

			Scoring it as "the new boon, minus a flat penalty" was wrong twice
			over: it ignored the free rarity tier, and it ignored how good the
			boon being discarded was. What actually matters is
			(new at its rarity) - (old at its rarity), anchored at a neutral
			baseline so the result still lands on the 0-100 scale.
		]]
		if itemData.TraitToReplace ~= nil then
			local oldName = itemData.TraitToReplace
			local oldBase = BoonAdvisor.Ratings.Base[oldName]
			if oldBase == nil then
				local oldKind = BoonAdvisor.KindOf( oldName )
				oldBase = BoonAdvisor.Ratings.CategoryDefaults[oldKind] or weights.DefaultBase
			end

			local newValue = base + ( weights.Rarity[itemData.Rarity] or 0 )
			local oldValue = oldBase + ( weights.Rarity[itemData.OldRarity] or 0 )
			score = weights.DefaultBase + ( newValue - oldValue )

			if newValue > oldValue then
				reason = "upgrade to " .. tostring( itemData.Rarity )
					.. ", drops " .. BoonAdvisor.TraitDisplayName( oldName )
			else
				reason = "costs you " .. BoonAdvisor.TraitDisplayName( oldName )
			end
			reasonPriority = 2

			if slot ~= nil then
				score = score + BoonAdvisor.AspectBonus( slot )
			end
		elseif slot ~= nil then
			if BoonAdvisor.SlotFilled( slot ) then
				score = score + weights.SlotExchange
				reason = "replaces your " .. BoonAdvisor.SlotDisplayName( slot )
				reasonPriority = 2
			else
				score = score + weights.EmptySlot
				reason = "fills empty " .. BoonAdvisor.SlotDisplayName( slot )
				reasonPriority = 2
			end
			score = score + BoonAdvisor.AspectBonus( slot )
		end

		-- Live synergy. Only a more interesting finding displaces the slot note:
		-- "opens <some cheap gate>" is less useful than "fills empty Dash".
		local synergyScore, synergyReason = BoonAdvisor.EvaluateSynergy(
			traitName, itemData.TraitToReplace )
		-- Duos are a better bet when the Mirror makes them likelier to appear.
		synergyScore = synergyScore * BoonAdvisor.DuoPursuitFactor()
		score = score + synergyScore
		if synergyReason ~= nil and synergyReason.Priority > reasonPriority then
			reason = synergyReason.Text
			reasonPriority = synergyReason.Priority
		end

		-- The active Pact can change what a boon is worth.
		local pactScore, pactReason = BoonAdvisor.PactBonus( traitName )
		score = score + pactScore
		if pactReason ~= nil and reasonPriority < 3 then
			reason = pactReason
		end

		-- Active combat pressure values defensive boons even when the player is
		-- using Balanced mode. HighHeat remains an additional preference, not a
		-- substitute for reading the actual Pact.
		local pactSurvival = BoonAdvisor.PactSurvivalBonus( traitName )
		if itemData.TraitToReplace ~= nil then
			pactSurvival = pactSurvival
				- BoonAdvisor.PactSurvivalBonus( itemData.TraitToReplace )
		end
		score = score + pactSurvival

		-- Knockback is worth more in biomes with a wall-slam multiplier.
		local slamScore, slamReason = BoonAdvisor.KnockbackBonus( traitName )
		score = score + slamScore
		if slamReason ~= nil and reasonPriority < 2 then
			reason = slamReason
		end


		-- Follow the Mirror: curse breadth, or god breadth.
		local metaScore, metaReason = BoonAdvisor.MetaBonus(
			traitName, itemData.TraitToReplace )
		score = score + metaScore
		if metaReason ~= nil then
			reason = metaReason
		end

		-- A selected run goal adjusts only traits with explicit tags. For a
		-- replacement, compare the new and old traits instead of awarding the
		-- bonus while silently discarding an equally relevant boon.
		local objectiveScore = BoonAdvisor.ObjectiveTraitBonus( traitName )
		if itemData.TraitToReplace ~= nil then
			objectiveScore = objectiveScore
				- BoonAdvisor.ObjectiveTraitBonus( itemData.TraitToReplace )
		end
		score = score + objectiveScore

		-- Steering toward a known strong build outranks every other note.
		local archetypeScore, archetypeReason = BoonAdvisor.ArchetypeBonus(
			traitName, itemData.TraitToReplace )
		score = score + archetypeScore
		if archetypeReason ~= nil then
			reason = archetypeReason
		end

		--[[
			Opportunity cost, applied last. What a pick locks out is the one
			thing worth knowing even when everything else says take it, so this
			reason wins outright when it fires.
		]]
		local exclusionScore, exclusionReason = BoonAdvisor.ExclusionPenalty( traitName )
		score = score + exclusionScore
		if exclusionReason ~= nil then
			reason = exclusionReason
		end
	end

	-- Lasting Consequences changes ordinary healing multiplicatively. At rank
	-- four these choices have no effect at all, regardless of rarity or build
	-- bonuses, so they must never beat a functioning option on the screen.
	if BoonAdvisor.Ratings.HealingOnlyChoices[traitName]
		and BoonAdvisor.HealingMultiplier ~= nil then
		local healingMultiplier = BoonAdvisor.HealingMultiplier()
		if healingMultiplier <= 0 then
			score = 1
			reason = "restores 0 health at this Heat"
		elseif healingMultiplier < 1 then
			score = score * healingMultiplier
			reason = math.floor( healingMultiplier * 100 + 0.5 )
				.. "% effective at this Heat"
		end
	end

	score = BoonAdvisor.Finalize( score )
	local rank, color = BoonAdvisor.RankFor( score )

	if reason == nil then
		if score >= 75 then
			reason = "strong on its own"
		elseif score >= 60 then
			reason = "solid pick"
		else
			reason = "filler"
		end
	end

	-- RawScore keeps the pre-rounding value so the overlay can break ties
	-- between options that both round to, say, 88.
	return { Score = math.floor( score ), RawScore = score,
		Rank = rank, Color = color, Reason = reason }
end
