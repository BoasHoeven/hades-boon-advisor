--[[
	BoonAdvisor - configuration and tuning weights.

	Everything the overlay's behaviour depends on lives here so it can be tuned
	without touching the engine. Values are additive points on a 0-100 scale
	where 50 is an unremarkable boon.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.Config =
{
	-----------------------------------------------------------------------
	-- The three settings most players might want to change.
	-----------------------------------------------------------------------

	-- What "best" means for this run. "Balanced" is the all-purpose default.
	-- "Speed" favours proven fast routes and combat-free rooms; "HighHeat"
	-- values safety more heavily. Unknown values fall back to Balanced.
	Objective = "Balanced",

	-- Show the one-line "why" under each rank badge.
	ShowReason = true,

	--[[
		Pick logging, for validating the advice against real runs.

		When on, the mod records recommendations, actual choices, rerolls, doors,
		shops, Well and purge sales, story-room choices, one line per room
		cleared, and a summary when each run ends. tools/analyze_runs.py turns
		the file into a per-decision report.

		Lines are written to a file beside your saves:

		    Documents\Saved Games\Hades\BoonAdvisor-runs.log   (Windows)
		    $HOME/BoonAdvisor-runs.log                          (Linux/macOS)

		An earlier version claimed Hades' Lua has no file I/O and routed this
		through DebugPrint instead. That was wrong twice over: io and os are
		present (both are listed in Main.lua's SaveIgnores, which only names
		globals that exist), and DebugPrint output does NOT reach Hades.log in
		the release build -- the launcher passes /VerboseScriptLogging=false,
		and `verboseLogging` gates coroutine hooks rather than printing. So the
		logging was writing nowhere while appearing to work.

		Set LogFilePath to write somewhere else.
	]]
	LogPicks = false,
	LogFilePath = nil,

	-----------------------------------------------------------------------
	-- Everything below is tuning. You probably do not need to touch it.
	-----------------------------------------------------------------------

	-- Master switch. Set false to leave every screen untouched.
	Enabled = true,

	-- Print "+N" after the starred badge: the raw margin over the runner-up,
	-- so a coin flip (+1) reads differently from a landslide (+14).
	ShowBestMargin = true,

	-- Suggest rerolling only when the exact legal offer distribution predicts a
	-- worthwhile improvement often enough to justify the cost.
	SuggestReroll = true,
	-- Deferred exact forecasts yield after this many memoized states.
	RerollForecastWorkPerFrame = 256,
	ForecastCacheEntries = 96,
	RerollMinExpectedGain = 6,
	RerollMinImprovementChance = 0.50,
	RerollMeaningfulImprovement = 1,
	RerollCostPenalty = 4,
	RerollLastDiePenalty = 2,

	-- "None of these": when the run already holds boons from GodPoolSoftCap
	-- gods, this god is new, and the best boon on screen finalizes below this
	-- score, the star's reason says that walking away is fine.
	WeakPickThreshold = 60,

	-- Print scoring breakdowns to the debug console.
	Debug = false,

	-- Temporary local diagnostics. When enabled, one compact timing line per
	-- boon-menu phase is appended to the platform log path. Disabled for releases.
	PerformanceMonitor = false,
	PerformanceLogFilePath = nil,

	-- Batch nearby telemetry events and write them after the active UI frame.
	LogFlushDelay = 0.03,

	ObjectiveProfiles =
	{
		Balanced =
		{
			ArchetypeMultiplier = 1.00,
			RiskMultiplier = 1.00,
			TraitTagBonus = { Speed = 0, Survival = 0 },
			DoorBonus = {},
			KeepsakeBonus = {},
			StoryBonus = {},
		},
		Speed =
		{
			ArchetypeMultiplier = 1.15,
			RiskMultiplier = 0.80,
			TraitTagBonus = { Speed = 7, Survival = 0 },
			DoorBonus =
			{
				Story = 18,
				Shop = 10,
				Devotion = 4,
				HermesUpgrade = 4,
				WeaponUpgrade = 3,
			},
			KeepsakeBonus =
			{
				FastClearDodgeBonusTrait = 6,
				PerfectClearDamageBonusTrait = 3,
			},
			StoryBonus =
			{
				ChoiceText_BuffWeapon = 7,
				ChoiceText_BuffMegaPom = 3,
			},
		},
		HighHeat =
		{
			ArchetypeMultiplier = 1.00,
			RiskMultiplier = 1.25,
			TraitTagBonus = { Speed = 2, Survival = 8 },
			DoorBonus =
			{
				Story = 6,
				Health = 8,
				Shop = 4,
			},
			KeepsakeBonus =
			{
				ReincarnationTrait = 8,
				ShieldBossTrait = 8,
				ShieldAfterHitTrait = 6,
				MaxHealthKeepsakeTrait = 5,
				DirectionalArmorTrait = 4,
			},
			StoryBonus =
			{
				ChoiceText_BuffExtraChance = 10,
				ChoiceText_BuffExtraChanceReplenish = 10,
				ChoiceText_BuffHealing = 6,
				ChoiceText_Healing = 4,
			},
		},
	},

	-- Pact effects that change recommendation value, not merely difficulty.
	-- The danger weights approximate the relative pressure each rank adds. They
	-- are intentionally separate from Heat cost: one point of Hard Labor does
	-- not affect a run in the same way as one point of Extreme Measures.
	Pact =
	{
		DangerWeights =
		{
			EnemyDamageShrineUpgrade = 1.60,
			EnemySpeedShrineUpgrade = 1.35,
			EnemyEliteShrineUpgrade = 1.20,
			MinibossCountShrineUpgrade = 1.20,
			NoInvulnerabilityShrineUpgrade = 1.50,
			TrapDamageShrineUpgrade = 1.00,
			EnemyCountShrineUpgrade = 0.80,
			EnemyHealthShrineUpgrade = 0.75,
			EnemyShieldShrineUpgrade = 0.65,
			BossDifficultyShrineUpgrade = 0.45,
			HealingReductionShrineUpgrade = 0.40,
		},
		RiskPerDanger = 0.03,
		RiskMultiplierCap = 1.55,
		SurvivalBonusPerDanger = 0.65,
		SurvivalBonusCap = 9,
		MaxHealthBonusPerDanger = 0.75,
		MaxHealthBonusCap = 10,
		ClearWeights =
		{
			EnemyHealthShrineUpgrade = 0.06,
			EnemyCountShrineUpgrade = 0.04,
			EnemyShieldShrineUpgrade = 0.03,
			EnemyEliteShrineUpgrade = 0.025,
			MinibossCountShrineUpgrade = 0.02,
			BossDifficultyShrineUpgrade = 0.015,
		},
		ClearMultiplierCap = 1.30,

		-- Tight Deadline ranks allow 9, 7, and 5 minutes per biome. The live
		-- timer adds urgency only after the initial biome budget has fallen.
		TimerRankFactors = { 0.75, 1.00, 1.30 },
		TimerLowSeconds = 150,
		TimerCriticalSeconds = 75,
		TimerLowBonus = 0.20,
		TimerCriticalBonus = 0.45,
		TimerExpiredBonus = 0.70,
		TimerArchetypeScale = 0.08,
		TimerDoorBonus =
		{
			Story = 8,
			Shop = 5,
			HermesUpgrade = 3,
			Devotion = -5,
		},

		-- A Trial is dangerous even at full health, and blue-laurel rooms use a
		-- harder encounter. Pact pressure scales both costs.
		DevotionMinimumRisk = 0.12,
		HardEncounterBaseRisk = 4,
	},

	--[[
		Screens this mod has no opinion on. The hammer screen reuses the very
		same CreateBoonLootButtons as boons, so without this the overlay would
		score weapon upgrades against the boon ratings -- which contain no
		hammers -- and label every one of them a 50/filler. Saying nothing
		beats saying something false.
	]]
	SkipLootNames =
	{
		-- (Hammers are rated in BA_Ratings.Hammers, so WeaponUpgrade is no
		-- longer skipped. Add a loot name here to silence its screen.)
	},

	Purge =
	{
		Enabled = true,
		ShowReason = true,
		ScoreCeiling = 105,
		LevelProtection = 4,
		ReasonColor = { 0.31, 0.16, 0.10, 1.0 },
		Layout =
		{
			RankFontSize = 21,
			RankOffsetX = 300,
			RankOffsetY = -64,
			TextWidth = 250,
			ReasonFontSize = 15,
			ReasonOffsetX = 300,
			ReasonOffsetY = 30,
			ReasonTextWidth = 360,
		},
	},

	--[[
		Overlay placement, relative to each boon button's anchor.

		The badge sits on the title line, right-justified just left of the
		vanilla rarity label (which is right-justified at X 395). That strip is
		empty on every card. The rows below it are not: the description block
		starts at Y -30 and its stat lines run to about Y +45, and replacement
		offers draw a "Will Replace" row with an icon out at X ~362 / Y ~+65.
		Both of those overlapped earlier placements.
	]]
	Layout =
	{
		BadgeOffsetX = 310,
		BadgeOffsetY = -55,
		BadgeFontSize = 30,
		BadgeTextWidth = 230,
		BadgeRarityShiftX =
		{
			Heroic = -48,
			Legendary = -116,
		},
		ReasonOffsetX = 395,
		ReasonOffsetY = 72,
		ReasonFontSize = 20,
		ReasonTextWidth = 620,
		-- Replacement offers need the reason pushed below the exchange row.
		ExchangeReasonOffsetX = 270,
		ExchangeReasonOffsetY = 96,
	},

	-- Avoid mixing English advice into a game running in another language.
	-- Ratings remain visible; translated reasons can be added independently.
	HideEnglishReasonsInOtherLanguages = true,

	Weights =
	{
		-- Baseline for a boon with no entry in the ratings table.
		DefaultBase = 50,

		-- Taking this was the last prerequisite for a duo boon.
		DuoComplete = 22,
		--[[
			Intrinsic Duo value scales the completion/progress term:
			scale = 0.5 + (rating - Neutral) / Range, clamped below. With the
			old 60/30 a 70-rated utility duo such as Lightning Rod still kept
			0.83 of the +22; at 76/20 it keeps 0.2, while Merciful End (94)
			and Sea Storm (92) still pin to the maximum.
		]]
		DuoValueNeutral = 76,
		DuoValueRange = 20,
		DuoValueMinScale = 0.25,
		DuoValueMaxScale = 1.20,
		-- A duo or legendary actually on screen is a one-time offer; a core
		-- boon comes back next god room. Flat credit for the scarcity.
		GatedOfferBonus = 12,
		-- Taking this satisfies one more prerequisite set of a duo.
		DuoProgress = 6,
		--[[
			Taking this opens a single-set gate. These are cheap: "Static
			Discharge" only asks for any one Zeus boon, so satisfying one is
			nothing like assembling a duo and must not be priced as if it were.
		]]
		UpgradeGate = 3,
		-- Contributions after the best one count for less, otherwise a boon
		-- that nudges a dozen gates outscores one that completes a real duo.
		SecondaryFactor = 0.3,
		-- Ceiling on total synergy.
		MaxSynergy = 26,

		-- Slot economy: an empty slot is worth more than an overwrite.
		EmptySlot = 8,
		SlotExchange = -6,

		--[[
			Pom stacking, taken from the game rather than guessed:
			TraitMultiplierData.DefaultDiminishingReturnsMultiplier = 0.7 and
			DefaultMinMultiplier = 0.1 in TraitData.lua. Each further level is
			worth 70% of the previous one, with a floor at a tenth.
		]]
		PomDiminishing = 0.7,
		PomMinMultiplier = 0.1,
		-- Existing rarity increases the numerical gain from another level, but
		-- build role and diminishing returns remain the dominant terms.
		PomRarityFactor = 0.5,

		-- Per point of WallSlamMultiplier above 1.0 (Styx = 2.5 -> +18).
		KnockbackPerSlamMultiplier = 12,

		--[[
			Opportunity cost. Taking a boon can permanently remove others from
			the pool (RequiredFalseTraits, ~171 rules). Weight is deliberately
			moderate: a lockout is a real cost but a possibility forgone, not a
			loss already suffered, and the blocked boon might never have been
			offered anyway.
		]]
		ExclusionWeight = 16,
		ExclusionDuoFactor = 1.5,  -- blocking a duo hurts more
		ExclusionMinValue = 66,    -- below this the casualty is filler; stay quiet

		--[[
			Risk tolerance. Each Death Defiance in reserve is an extra life, so
			a run holding two can take a dangerous room far more comfortably.
			Used to temper the risk priced into the Trial and the Chaos gate.
		]]
		RiskPerDeathDefiance = 0.25,

		-- Per level of DuoRarityBoonDropMetaUpgrade: duos are likelier to
		-- appear, so chasing one is a better bet.
		DuoRarityPerLevel = 0.03,

		-- Steering toward a known strong build (see Ratings.Archetypes).
		ArchetypeCore = 12,
		ArchetypePayoff = 20,
		-- An aspect-gated route pays only this fraction of its core bonus
		-- until the run holds one of its core boons. The first pick is still
		-- steered, but a route the run walked past cannot outvote the one it
		-- is actually building (Chiron: Hangover versus Merciful End).
		ArchetypeUncommittedScale = 0.6,

		-- Boss preparation: within this many encounters of the biome boss,
		-- survival-tagged boons and survival Chaos blessings gain up to this
		-- much, growing as the boss gets closer.
		BossPrepProximity = 3,
		BossPrepSurvivalBonus = 6,

		--[[
			Mirror-aware bonuses. Reaching a 2nd distinct status curse switches
			Privileged Status on for the whole run, which is a step change
			rather than an increment -- hence the large value.
		]]
		PrivilegedStatusOn = 22,
		PrivilegedStatusFirst = 10,
		FamilyFavorite = 10,

		-- Rarity is already reflected in the boon's numbers, so this is a
		-- modest nudge rather than the dominant term.
		Rarity =
		{
			Common = 0,
			Rare = 5,
			Epic = 10,
			Heroic = 14,
			Legendary = 18,
		},
	},

	--[[
		Soft knee. Strong boons accumulate several bonuses at once and would
		otherwise all pin to the ceiling, flattening exactly the distinctions
		the overlay exists to show. Above the knee, extra points are
		compressed; the transform is monotonic, so ordering is preserved.
	]]
	SoftKnee = 88,
	-- Exponential headroom preserves visible separation between elite picks
	-- without allowing the display to grow beyond two digits.
	SoftKneeSpan = 18,

	-- Rank letter cutoffs, highest first.
	RankThresholds =
	{
		{ Min = 85, Rank = "S", Color = { 255, 208, 92,  255 } },
		{ Min = 75, Rank = "A", Color = { 156, 226, 140, 255 } },
		{ Min = 65, Rank = "B", Color = { 150, 200, 235, 255 } },
		{ Min = 55, Rank = "C", Color = { 190, 190, 190, 255 } },
		{ Min = -999, Rank = "D", Color = { 150, 140, 140, 255 } },
	},

	--[[
		Door reward advisor. Doors are scored on the same 0-100 scale as boons,
		but a door is worth what lies behind it. A god door uses the expected
		best of its visible eligible choices, while survival rewards account for
		the run state.
	]]
	Doors =
	{
		Enabled = true,
		ShowReason = true,
		RefreshDelay = 0.20,

		Layout =
		{
			RankFontSize = 24,
			RankOffsetY = -52,
			ReasonFontSize = 15,
			ReasonOffsetY = -32,
			-- The Chaos gate has no reward icon, so its text hangs off the
			-- door itself and must be lifted clear of it.
			NoIconOffsetY = -110,
			-- The two Trial of the Gods pickups: text hangs off the boon orb.
			TrialRankOffsetY = -140,
			TrialReasonOffsetY = -120,
			-- Without an explicit width the engine clips world text: reasons
			-- were rendering as "NEW BOO" and running under the door laurel.
			TextWidth = 460,
		},

		BoonBase = 66,

		--[[
			Converts expected-rarity points into door score. The raw figure is
			a probability-weighted sum of the Weights.Rarity values, so it is
			small; this scales it into a meaningful but non-dominant term.
		]]
		RarityExpectationScale = 1.6,

		-- Weighted Pact danger makes survival worth more. Pure heals are scaled
		-- by the game's live healing multiplier.
		DangerHealthBonus = 1.5,
		-- MetaPointCapShrineUpgrade caps banked Darkness for the run.
		DarknessCappedFactor = 0.7,

		-- Chaos gate: always a Chaos boon, priced in health.
		ChaosGateBase = 72,
		ChaosGateCostWeight = 60,
		ChaosBossProximity = 4,
		ChaosBossPenalty = 9,
		ChaosEarlyDepth = 12,
		ChaosEarlyBonus = 5,
		ChaosLateDepth = 32,
		ChaosLatePenalty = 5,

		--[[
			Trial of the Gods: TWO boons -- one chosen up front, one from the
			refused god after the fight (RoomEvents.lua:1469). That is double
			an ordinary boon room, so it starts well above BoonBase; the harder
			encounter is priced through DevotionRisk as health drops.
		]]
		DevotionBase = 94,
		DevotionRisk = 44,
		-- Keep the best god at full value, then credit the second guaranteed
		-- boon at a discounted rate. 0.42 preserves the old neutral value:
		-- 66 + (66 * 0.42) is approximately the 94-point fallback above.
		DevotionSecondBoonWeight = 0.42,
		--[[
			The god you refuse arms the enemies for that fight
			(AddEnemyUpgrade in StartDevotionTest). Ares' blade rifts and Zeus'
			chain lightning hurt far more than Athena's deflect, so the Trial
			pays a cost for the god the advisor expects you to spurn -- the
			lower-scored of the two. Scaled by Pact risk like DevotionRisk.
		]]
		TrialSpurnedRisk =
		{
			AresUpgrade      = 6,
			ZeusUpgrade      = 5,
			DemeterUpgrade   = 5,
			DionysusUpgrade  = 4,
			ArtemisUpgrade   = 4,
			PoseidonUpgrade  = 3,
			AphroditeUpgrade = 3,
			AthenaUpgrade    = 2,
		},

		--[[
			Fated Authority (RerollMetaUpgrade) rerolls one door's reward.
			The star gets a "reroll?" suffix when a die is left, at least one
			exit can be rerolled, and every exit the run can enter finalizes
			below the biome's usual door value -- i.e. when the whole offer is
			poor, not merely when one door is.
		]]
		RerollAdvice =
		{
			Enabled = true,
			Default = 62,
			Tartarus = 62,
			Asphodel = 64,
			Elysium = 64,
			Styx = 56,
		},

		-- A Centaur Heart permanently adds max health; it is not ordinary healing.
		MaxHealthBase = 70,
		MaxHealthBonusPointWeight = 0.7,
		HeartDiminishAfter = 4,
		HeartDiminishPerPickup = 3,
		HeartLateRunPenalty = 8,

		-- Pure healing is used by Charon's healing stock.
		HealthBase = 46,
		HealthUrgency = 44, -- full swing between full health and near-death
		-- Health is scarcer and hits land harder the deeper you go.
		HealthDepthBonus = 14,
		DepthReference = 40, -- roughly a full run, Tartarus through Styx

		HammerBase = 84,

		-- Shop doors are only valuable when the purse can buy the stock inside.
		-- Thresholds are base prices and are adjusted for Pact/keepsake modifiers.
		ShopDoorScores =
		{
			{ MinMoney = 200, Score = 72, Reason = "can afford any normal stock" },
			{ MinMoney = 150, Score = 67, Reason = "can afford a boon" },
			{ MinMoney = 125, Score = 61, Reason = "can afford a Heart or mystery boon" },
			{ MinMoney = 100, Score = 55, Reason = "can afford a Pom" },
			{ MinMoney = 50,  Score = 43, Reason = "can only afford cheap stock" },
			{ MinMoney = 0,   Score = 30, Reason = "cannot afford normal stock" },
		},

		-- Resource-room context and House Contractor run-progress upgrades.
		MoneyBase = 50,
		MoneyLowBonus = 15,
		MoneyTarget = 200,
		MoneyLateDepth = 35,
		MoneyLatePenalty = 6,
		KeyRerollBonus = 18,
		NectarPomValueScale = 0.22,
		DarknessMaxHealthBonus = 6,
		ResourceMoneyPointWeight = 0.3,
		GodPoolSoftCap = 3,
		GodPoolPenaltyPerGod = 4,
		GodPoolPenaltyCap = 8,

		--[[
			Flat tiers, for rewards whose value does not depend on the run.
			Spread deliberately: when several of these land in one room the
			ranks should still differ rather than reading as three C's.
			Anything that *does* depend on the run (boons, health, hammers,
			poms) is scored above and ignores this table.
		]]
		Types =
		{
			Default       = 55,
			Story         = 50,
			Shop          = 63,
			HermesUpgrade = 68,
			Devotion      = 66,
			Gift          = 57,
			LockKey       = 49,
			Gems          = 47,
			MetaPoints    = 45,
			Money         = 41,
			StackUpgrade  = 62, -- fallback only; see ScorePomDoor
			Trial         = 60,
		},

		-- Player-facing names for the reward types.
		Labels =
		{
			Shop          = "Charon's shop",
			HermesUpgrade = "Hermes boon",
			Devotion      = "devotion",
			Gift          = "nectar",
			LockKey       = "key",
			Gems          = "gems",
			MetaPoints    = "darkness",
			Money         = "gold",
			StackUpgrade  = "pom of power",
			Trial         = "chaos",

			-- Shop stock arrives under its consumable drop name.
			MoneyDrop        = "gold",
			SuperGiftDrop              = "ambrosia: not for this run",
			LastStandDrop              = "extra life",
			RoomRewardMaxHealthDrop    = "max health",
			HermesUpgradeDrop          = "Hermes boon",
			RandomLoot                 = "boon",
			BlindBoxLoot               = "mystery box",
			StoreTrialUpgradeDrop      = "chaos boon",
			StoreRewardMetaPointDrop   = "darkness",
			StoreRewardLockKeyDrop     = "key",
			StoreRewardGemDrop         = "gems",
			StoreRewardConsolationDrop = "consolation",
			MetaPointDrop    = "darkness",
			GiftDrop         = "nectar",
			LockKeyDrop      = "key",
			TrialUpgradeDrop = "chaos boon",
			HealthDrop       = "health",
			MaxHealthDrop    = "max health",
		},
	},

	--[[
		Charon's shop. Stock is scored with the same engine as doors, so a boon
		on sale can report the duo it would unlock rather than a flat number.
	]]
	Shop =
	{
		Enabled = true,
		ShowReason = true,

		Layout =
		{
			RankFontSize = 22,
			RankOffsetY = -128,
			ReasonFontSize = 15,
			ReasonOffsetY = -108,
			TextWidth = 460,
		},

		ConsumableDefault = 52,

		--[[
			Price is a tiebreaker, not the headline. An earlier version weighted
			it at 26, which dropped every normally-priced item in a shop to a D
			whenever the purse was thin -- technically "value per obol", but
			useless as advice, since you are choosing between these items and
			not against saving.
		]]
		CostWeight = 8,
		UnaffordablePenalty = 14,

		-- Fixed tiers for stock whose value does not depend on the run.
		-- Names come from StoreData; anything missing is reported as unrated.
		Items =
		{
			HermesUpgradeDrop          = 68,
			RandomLoot                 = 66,
			StoreTrialUpgradeDrop      = 60,
			BlindBoxLoot               = 60,
			GiftDrop                   = 57,
			StoreRewardLockKeyDrop     = 49,
			StoreRewardGemDrop         = 47,
			StoreRewardMetaPointDrop   = 45,
			StoreRewardConsolationDrop = 44,
			LastStandDrop              = 88, -- an extra life is worth the gold
			SuperGiftDrop              = 30, -- ambrosia: House currency only
			-- Centaur Heart: permanent max health, good whatever your current
			-- health, so it is a flat tier rather than urgency-scaled.
			RoomRewardMaxHealthDrop    = 70,
		},

		-- Pure healing, priced by how hurt you are.
		-- The store uses the RoomReward* names, not the bare HealthDrop ones.
		HealthConsumables =
		{
			RoomRewardHealDrop = true,
			HealDropRange = true,
			HealDropMinor = true,
		},

		-- Well items whose only payoff is ordinary healing. Last Stand healing
		-- is intentionally absent because revival health bypasses the Pact.
		HealthTraits =
		{
			TemporaryDoorHealTrait = true,
			TemporaryWeaponLifeOnKillTrait = true,
		},

		-- Well of Charon effects. These are deliberately separate from ordinary
		-- shop stock because their duration and run timing determine their value.
		WellItems =
		{
			TemporaryImprovedWeaponTrait = 76,
			TemporaryMoreAmmoTrait = 72,
			TemporaryImprovedRangedTrait = 72,
			TemporaryMoveSpeedTrait = 62,
			TemporaryBoonRarityTrait = 82,
			TemporaryArmorDamageTrait = 76,
			TemporaryAlphaStrikeTrait = 64,
			TemporaryBackstabTrait = 62,
			TemporaryImprovedSecondaryTrait = 74,
			TemporaryImprovedTrapDamageTrait = 52,
			TemporaryPreloadSuperGenerationTrait = 64,
			TemporaryForcedSecretDoorTrait = 78,
			TemporaryForcedChallengeSwitchTrait = 58,
			TemporaryForcedFishingPointTrait = 34,
			TemporaryBlockExplodingChariotsTrait = 56,
			TemporaryLastStandHealTrait = 70,
			RandomStoreItem = 48,
			KeepsakeChargeDrop = 34,
			MetaDropRange = 42,
			GemDropRange = 40,
		},
		WellLateDepth = 28,
		WellLatePenalty = 8,

		Consumables =
		{
			MetaPointDrop = 48,
			MoneyDrop = 45,
			GiftDrop = 58,
			LockKeyDrop = 50,
			TrialUpgradeDrop = 60,
			-- Ambrosia: gifting currency for the House. Does nothing for the
			-- run in progress, so it must not compete with a boon.
			SuperGiftDrop = 30,
			LastStandDrop = 88, -- an extra life is worth almost any price
		},
	},

	--[[
		Well of Charon. The Well is a screen built by CreateStoreButtons, not
		a room of items, so it has its own hook and layout (BA_Well.lua). The
		items themselves are rated in Shop.WellItems above. The badge sits on
		the purchase card's title row, right-justified left of the price,
		the same placement the Pool of Purging uses on its sell buttons.
	]]
	Well =
	{
		Enabled = true,
		ShowReason = true,
		ReasonColor = { 0.31, 0.16, 0.10, 1.0 },
		Layout =
		{
			RankFontSize = 21,
			RankOffsetX = 300,
			RankOffsetY = -64,
			TextWidth = 250,
			ReasonFontSize = 15,
			ReasonOffsetX = 300,
			ReasonOffsetY = 30,
			ReasonTextWidth = 360,
		},
	},

	--[[
		Keepsake rack. A god keepsake forces that god's next room and raises its
		boon rarity, so its worth is entirely a function of what your build
		still needs -- which is why it is scored dynamically rather than tiered.
	]]
	Keepsakes =
	{
		Enabled = true,
		Layout =
		{
			RankFontSize = 19,
			RankOffsetX = 44,
			RankOffsetY = 42,
			TextWidth = 32,
			DetailOffsetY = 545,
			DetailWidth = 450,
			DetailLabelOffsetX = 170,
			DetailLabelOffsetY = -1,
			DetailValueOffsetX = 285,
			DetailValueOffsetY = -4,
			DetailReasonOffsetY = -50,
			DetailLabelFontSize = 18,
			DetailRankFontSize = 20,
			DetailReasonFontSize = 16,
		},
		GodBase = 56,
		GodOfferBaseline = 60,
		GodOfferWeight = 0.45,
		GodRouteWeight = 0.65,
		GodRankBonus = 3,
		UnwantedPenalty = 8,
		GodSpentPenalty = 15,
		GodRarityOnlyBonus = 3,
		SwitchThreshold = 3,
		BestMarker = "*",
		Scores =
		{
			MaxHealthBase = 59,
			MaxHealthPer25 = 7,
			DefenseBase = 58,
			DamageBase = 57,
			StackingBase = 52,
			StackingExistingScale = 1.0,
			PlumeFuturePerRoom = 0.50,
			ButterflyFuturePerRoom = 0.30,
			StackRatePriorRooms = 4,
			MoneyBase = 62,
			MoneyPer25 = 2.5,
			MoneyCap = 12,
			MoneyAlreadyClaimed = 28,
			HourglassBase = 50,
			HourglassPerExpectedWell = 4,
			PomBase = 50,
			PomPerExpectedLevel = 4,
			PomTargetBaseline = 60,
			PomTargetWeight = 0.24,
			PomEmptyPenalty = 10,
			ChaosBase = 56,
			ChaosPerGate = 8,
			ChaosGateCap = 16,
			ChaosNoGateScore = 38,
			AcornBossBonus = 17,
			AcornDangerBonus = 1.5,
			ToothMissingDefianceBonus = 8,
			ToothNoDefianceBonus = 8,
			SpearpointLowHealthBonus = 9,
			LowHealthUrgency = 10,
			RangedAspectBonus = 9,
			ShackleEmptySlotBonus = 8,
			ShackleFilledSlotPenalty = 7,
			ShackleHeavyAspectBonus = 10,
			HadesEmptyCallBonus = 14,
			HadesExistingCallPenalty = 30,
			UrnLowHealthBonus = 7,
			UnratedBase = 48,
		},
	},

	StoryChoices =
	{
		Enabled = true,
		ShowReason = true,
		Layout =
		{
			-- One column header, then a compact two-line block per choice.
			LabelFontSize = 14,
			LabelOffsetX = 650,
			LabelOffsetY = -40,
			LabelWidth = 300,
			RankFontSize = 20,
			RankOffsetX = 650,
			RankOffsetY = -8,
			ReasonFontSize = 13,
			ReasonOffsetX = 650,
			ReasonOffsetY = 13,
			TextWidth = 150,
			ReasonWidth = 300,
		},
		-- The same warm ink used by the vanilla choice text on this parchment.
		LabelColor = { 102, 37, 22, 255 },
		ReasonColor = { 102, 37, 22, 255 },
		Sisyphus =
		{
			HealBase = 38,
			HealUrgency = 52,
			MoneyBase = 72,
			LowMoneyBonus = 8,
			DarknessBase = 44,
			DarknessHealWeight = 35,
		},
		Eurydice =
		{
			EmptyScore = 35,
			RarityBase = 60,
			RarityDeltaScale = 2.4,
			PomBase = 54,
			PomValueScale = 0.22,
			PomCountBonus = 3.5,
			FutureRarityBase = 82,
			SparseReference = 6,
			SparseWeight = 1.2,
			SparseBonusCap = 5,
			SparsePenaltyCap = 4,
		},
		Patroclus =
		{
			DefianceBase = 46,
			PerMissingDefiance = 40,
			StubbornBase = 82,
			DoorHealBase = 64,
			DoorHealUrgency = 26,
			WeaponBase = 80,
			CastAspectPenalty = 12,
			DangerBonus = 1.5,
		},
	},

	-- Colour for the highest-scoring option on screen.
	BestPickColor = { 255, 208, 92, 255 },
	ReasonColor = { 170, 170, 160, 255 },
}
