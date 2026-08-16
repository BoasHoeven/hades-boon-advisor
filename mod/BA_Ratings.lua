--[[
	BoonAdvisor - tier baseline.

	Hand-authored strength ratings on a 0-100 scale, before any run context is
	applied. 50 = unremarkable. These are opinions; the live synergy, slot and
	rarity terms in BA_Engine adjust them for your actual run.

	Only boons worth an opinion are listed. Anything absent falls back to
	Config.Weights.DefaultBase, and duo/legendary boons fall back to the
	category defaults below, so an unlisted boon is never mis-ranked as bad.

	Display names are given in comments; the keys are the game's internal
	trait names as they appear in TraitData.lua.
]]

if BoonAdvisor == nil then
	BoonAdvisor = {}
end

BoonAdvisor.Ratings = {}

-- Fallbacks by category, used when a boon has no explicit rating below.
BoonAdvisor.Ratings.CategoryDefaults =
{
	Duo = 86,
	Legendary = 80,
	Upgrade = 66, -- same-god boons gated behind a prerequisite
	Consumable = 48,
	Chaos = 58,
}

-- Choices whose entire run payoff is ordinary healing. These are overridden
-- by the live healing multiplier after normal context scoring. Strong Drink
-- is deliberately excluded because its permanent damage bonus still works.
BoonAdvisor.Ratings.HealingOnlyChoices =
{
	DoorHealTrait = true,       -- After Party
	HealingPotencyTrait = true, -- Nourished Soul, processed-trait form
	HealingPotencyDrop = true,  -- Nourished Soul, boon-screen form
}

BoonAdvisor.Ratings.Base =
{
	---------------------------------------------------------------------
	-- Attack (Melee)
	---------------------------------------------------------------------
	AthenaWeaponTrait          = 80, -- Divine Strike
	DemeterWeaponTrait         = 78, -- Frost Strike
	-- Weak is roughly a 30% damage reduction on anything it touches, which is
	-- the best defensive layer in the game; every per-aspect guide surveyed
	-- opens with "take the Aphrodite attack".
	AphroditeWeaponTrait       = 84, -- Heartbreak Strike
	ArtemisWeaponTrait         = 72, -- Deadly Strike
	AresWeaponTrait            = 72, -- Curse of Agony
	DionysusWeaponTrait        = 70, -- Drunken Strike
	ZeusWeaponTrait            = 68, -- Lightning Strike
	PoseidonWeaponTrait        = 66, -- Tempest Strike

	---------------------------------------------------------------------
	-- Special (Secondary)
	---------------------------------------------------------------------
	AthenaSecondaryTrait       = 78, -- Divine Flourish
	DemeterSecondaryTrait      = 76, -- Frost Flourish
	AphroditeSecondaryTrait    = 74, -- Heartbreak Flourish
	AresSecondaryTrait         = 74, -- Curse of Pain
	ArtemisSecondaryTrait      = 72, -- Deadly Flourish
	ZeusSecondaryTrait         = 70, -- Thunder Flourish
	PoseidonSecondaryTrait     = 68, -- Tempest Flourish
	DionysusSecondaryTrait     = 68, -- Drunken Flourish

	---------------------------------------------------------------------
	-- Cast (Ranged)
	---------------------------------------------------------------------
	DemeterRangedTrait         = 82, -- Crystal Beam
	ArtemisRangedTrait         = 74, -- True Shot
	DionysusRangedTrait        = 72, -- Trippy Shot
	AresRangedTrait            = 70, -- Slicing Shot
	AphroditeRangedTrait       = 66, -- Crush Shot
	--[[
		Flood Shot, raised 64 -> 76 on structural evidence, against the usual
		mid-tier community read:

		  * It feeds EIGHT duos -- the most of any Cast, and tied for the most
		    of any boon in the game (Sea Storm, Mirage Shot, Curse of Drowning,
		    Blizzard Shot, Unshakable Mettle, Sweet Nectar, Exclusive Access,
		    Second Wave). Crystal Beam, rated highest here at 82, feeds three.
		  * It locks out NOTHING. Slicing Shot and Crystal Beam each forfeit
		    Exit Wounds; Trippy Shot forfeits Parting Shot. Flood Shot's duo
		    reach is free.
		  * It is a knockback Cast, and knockback damage is multiplied per
		    biome -- 1.5x Asphodel, 2.0x Elysium, 2.5x Styx (MECHANICS.md 9b) --
		    so it scales into exactly the part of a run that kills you.

		Caveat kept deliberately: reach is potential, not realised power. Eight
		mediocre duos are worth less than one great one, and this has not been
		validated in play.
	]]
	PoseidonRangedTrait        = 76, -- Flood Shot
	ZeusRangedTrait            = 62, -- Electric Shot
	AthenaRangedTrait          = 60, -- Phalanx Shot

	--[[
		Shield-of-Chaos "Flare" cast variants. Three were missing and fell to
		the default 50 -- including Flood Flare, which the Beowulf guides name
		explicitly and which feeds 6 duos. Rated in line with their base-cast
		counterparts, with Flood Flare raised for the reasons in the Poseidon
		note below.
	]]
	ShieldLoadAmmo_PoseidonRangedTrait  = 76, -- Flood Flare
	ShieldLoadAmmo_DemeterRangedTrait   = 78, -- Icy Flare
	ShieldLoadAmmo_ArtemisRangedTrait   = 72, -- Hunter's Flare
	ShieldLoadAmmo_AresRangedTrait      = 70, -- Slicing Flare
	ShieldLoadAmmo_DionysusRangedTrait  = 70, -- Trippy Flare
	ShieldLoadAmmo_AphroditeRangedTrait = 66, -- Passion Flare
	ShieldLoadAmmo_ZeusRangedTrait      = 62, -- Thunder Flare
	ShieldLoadAmmo_AthenaRangedTrait    = 60, -- Phalanx Flare

	---------------------------------------------------------------------
	-- Dash (Rush)
	---------------------------------------------------------------------
	AthenaRushTrait            = 92, -- Divine Dash: deflect, the run-defining pick
	PoseidonRushTrait          = 74, -- Tidal Dash
	DemeterRushTrait           = 70, -- Mistral Dash
	AresRushTrait              = 70, -- Blade Dash
	AphroditeRushTrait         = 68, -- Passion Dash
	ZeusRushTrait              = 66, -- Thunder Dash
	ArtemisRushTrait           = 64, -- Hunter Dash
	DionysusRushTrait          = 62, -- Drunken Dash

	---------------------------------------------------------------------
	-- Call (Shout)
	---------------------------------------------------------------------
	--[[
		Calls, re-rated after a systematic error. I had every one of them at
		55-66 on a blanket assumption that Calls are weak. Two independent
		sources and the game's own tooltips say otherwise, and the reason is
		mechanical: FOUR Calls grant outright Invulnerability, which under the
		damage model (reductions are multiplicative; invulnerability negates)
		is the strongest defensive effect available.

		Tooltip text, verbatim from HelpText:
		  Poseidon  "surge into foes while Invulnerable"
		  Athena    "briefly makes you Invulnerable and Deflect all attacks"
		  Ares      "turns you into an Invulnerable BladeRift"
		  Hades     "turn Invisible" + stealth damage bonus  (rated above)
		  Demeter   "winter vortex ... inflicting Chill"
		  Dionysus  "inflicts Poison on foes all around you"
		  Aphrodite "seeking projectile that inflicts Charm"
		  Artemis   "fires a seeking arrow with <n>% Crit chance"
		  Zeus      "lightning rapidly strike nearby foes"

		Sources call Poseidon's Aid "by far the best Call in the game", and
		note Athena's can reach ~20 seconds of invulnerability once pommed.
		Demeter's and Dionysus' also apply Status Curses, which the Privileged
		Status logic credits separately.
	]]
	PoseidonShoutTrait         = 86, -- Poseidon's Aid: invulnerable surge
	AthenaShoutTrait           = 84, -- Athena's Aid: invulnerable + deflect all
	AresShoutTrait             = 78, -- Ares' Aid: invulnerable Blade Rift
	DemeterShoutTrait          = 74, -- Demeter's Aid: Chill vortex
	AphroditeShoutTrait        = 72, -- Aphrodite's Aid: Charm
	DionysusShoutTrait         = 70, -- Dionysus' Aid: Hangover AoE
	ArtemisShoutTrait          = 70, -- Artemis' Aid: seeking crit arrow
	ZeusShoutTrait             = 68, -- Zeus' Aid: lightning
	--[[
		Hades' Aid, corrected 55 -> 84. I had it as the WORST Call in the game;
		it is generally held to be the best, and the game's own text agrees:

		  "Your Wrath briefly makes you turn Invisible.
		   Stealth Damage Bonus: ... / EXWrath: Turn Greater Invisible instead"

		That is a large damage bonus AND an escape, on the same Call.

		BUT it is never offered on a boon screen. It comes from the keepsake
		HadesShoutKeepsake (TraitData.lua:18144, a GiftTrait); KeepsakeScripts
		removes the trait when the keepsake is swapped out. The HadesUpgrade
		entry in LootData is DebugOnly with empty Traits/WeaponUpgrades -- it
		exists only for the Wrath portrait and voice lines, not as a loot pool.

		So this number is inert for pick advice: the boon cannot appear as an
		option. What actually matters, and already works, is that holding it
		fills the Call slot (Slot = "Shout") and forfeits Smoldering Air, which
		lists HadesShoutTrait in RequiredFalseTraits (TraitData.lua:36171).

		I originally justified raising it with "if it is on screen it should be
		near the top" -- which was wrong, because it is never on screen.

		Note it forfeits Smoldering Air -- that duo lists HadesShoutTrait in its
		RequiredFalseTraits (TraitData.lua:36171) -- which the exclusion term
		already prices in.
	]]
	HadesShoutTrait            = 84, -- Hades' Aid

	---------------------------------------------------------------------
	-- Non-slot god boons (passives and retaliates)
	---------------------------------------------------------------------
	RetaliateWeaponTrait       = 68, -- Heaven's Vengeance
	AthenaRetaliateTrait       = 70, -- Holy Shield
	AphroditeRetaliateTrait    = 64, -- Wave of Despair retaliate
	DemeterRetaliateTrait      = 66, -- Frozen Touch
	AresRetaliateTrait         = 66, -- Blood Frenzy
	IncreasedDamageTrait       = 74, -- Ares damage bonus
	CritBonusTrait             = 72, -- Artemis critical bonus
	EnemyDamageTrait           = 60, -- Athena enemy damage reduction
	TrapDamageTrait            = 58, -- Athena trap damage
	MoveSpeedTrait             = 62, -- Hermes move speed
	BonusDashTrait             = 82, -- Greater Evasion / extra dash
	DodgeChanceTrait           = 74, -- Hermes dodge
	RushSpeedBoostTrait        = 66, -- Hermes dash speed
	RapidCastTrait             = 70, -- Hermes cast speed
	AmmoReloadTrait            = 68, -- Hermes cast reload
	SuperGenerationTrait       = 62, -- Call generation

	-- Hermes (his screen offers only these, so leaving them unrated meant a
	-- whole god's screen scored as flat filler)
	HermesWeaponTrait          = 76, -- attack speed
	HermesSecondaryTrait       = 70, -- special speed
	RushRallyTrait             = 66,
	AmmoReclaimTrait           = 64,
	RegeneratingSuperTrait     = 62,
	HermesShoutDodge           = 60,
	ChamberGoldTrait           = 48, -- gold, not power

	---------------------------------------------------------------------
	-- Notable duos (override the category default)
	---------------------------------------------------------------------
	ImpactBoltTrait            = 92, -- Sea Storm
	AresHomingTrait            = 92, -- Hunting Blades
	JoltDurationTrait          = 90, -- Cold Fusion
	StationaryRiftTrait        = 90, -- Freezing Vortex
	CurseSickTrait             = 88, -- Curse of Longing
	TriggerCurseTrait          = 86, -- Merciful End
	LightningCloudTrait        = 86, -- Scintillating Feast
	AmmoBoltTrait              = 84, -- Lightning Rod
	PoisonCritVulnerabilityTrait = 84, -- Splitting Headache
	AutoRetaliateTrait         = 78, -- Vengeful Mood
	MarkedDropGoldTrait        = 72, -- Wanted Dead

	---------------------------------------------------------------------
	-- Notable same-god upgrade / legendary boons
	---------------------------------------------------------------------
	ZeusChargedBoltTrait       = 88, -- Splitting Bolt
	AresLongCurseTrait         = 78, -- Impending Doom
	AresLoadCurseTrait         = 82, -- Dire Misfortune
	ArtemisCriticalTrait       = 76, -- Clean Kill
	CritVulnerabilityTrait     = 74, -- Hunter's Mark
	AphroditeWeakenTrait       = 74, -- Sweet Surrender
	MoreAmmoTrait              = 72, -- Fully Loaded
	ZeusBonusBoltTrait         = 72, -- Double Strike
	AphroditePotencyTrait      = 70, -- Broken Resolve
}

--[[
	Boons whose value rides on knocking foes into terrain. Wall-slam damage is
	multiplied per biome (see MECHANICS.md 9b), so these gain value with depth.
	Poseidon is the knockback god; SlamStunTrait and SlamExplosionTrait add
	PoseidonCollisionBlast on slam (TraitData.lua:4894, :4939).
]]
--[[
	Boons whose worth depends on the Pact of Punishment.

	Most Heat modifiers change how a fight plays, not which reward is better.
	These change a boon or hammer's relative value, so they are read from the
	run's actual Heat rather than ignored:

	  TrapDamageShrineUpgrade  - traps hit harder, so Sure Footing (resist trap
	                             damage) goes from filler to genuinely useful.
	  BiomeSpeedShrineUpgrade  - a biome timer means clearing fast matters, so
	                             Hermes' speed boons gain value.
	  EnemyShieldShrineUpgrade - each enemy ignores its first one or two hits,
	                             so extra independent hits gain value.
	  MetaPointCapShrineUpgrade- caps Darkness, devaluing Darkness rewards
	                             (handled on the door/shop side).
]]
BoonAdvisor.Ratings.PactConditionalBoons =
{
	TrapDamageShrineUpgrade =
	{
		TrapDamageTrait = 26, -- Sure Footing
	},
	BiomeSpeedShrineUpgrade =
	{
		MoveSpeedTrait      = 12,
		RushSpeedBoostTrait = 10,
		HermesWeaponTrait   = 10, -- attack speed clears rooms faster
		HermesSecondaryTrait = 10,
		BonusDashTrait      = 8,
		RapidCastTrait      = 8,
	},
	EnemyShieldShrineUpgrade =
	{
		-- Support Fire is an independent projectile triggered by attacks,
		-- Specials, and Casts, making it reliable shield removal on any weapon.
		ArtemisSupportingFireTrait = 7,
	},
	EnemySpeedShrineUpgrade =
	{
		-- Chill reduces enemy animation speed and Numbing Sensation slows foes
		-- carrying Hangover, directly offsetting Forced Overtime.
		DemeterWeaponTrait = 3,
		DemeterSecondaryTrait = 3,
		DemeterRangedTrait = 3,
		DemeterRushTrait = 3,
		DemeterShoutTrait = 3,
		ShieldLoadAmmo_DemeterRangedTrait = 3,
		DionysusSlowTrait = 5,
	},
	EnemyCountShrineUpgrade =
	{
		-- Explicit area and chaining effects clear the extra Jury Summons bodies
		-- without assigning a generic bonus to every damage boon.
		ZeusSecondaryTrait = 2,
		ZeusRushTrait = 2,
		ZeusRangedTrait = 2,
		PoseidonRushTrait = 2,
		AresRushTrait = 2,
		AresRangedTrait = 2,
		DionysusRangedTrait = 2,
		DemeterShoutTrait = 2,
		SlamExplosionTrait = 2,
		ImpactBoltTrait = 2,
		LightningCloudTrait = 2,
	},
}

-- Multi-hit hammers become more valuable when every enemy starts with one or
-- two hit shields. These bonuses remain modest because their ordinary damage
-- and aspect interactions are already represented by the main hammer tables.
BoonAdvisor.Ratings.PactConditionalHammers =
{
	EnemyShieldShrineUpgrade =
	{
		SwordTwoComboTrait = 4,
		SwordSecondaryDoubleAttackTrait = 3,
		SwordDoubleDashAttackTrait = 3,
		BowDoubleShotTrait = 3,
		BowSecondaryBarrageTrait = 5,
		BowTripleShotTrait = 4,
		BowConsecutiveBarrageTrait = 4,
		ShieldThrowFastTrait = 3,
		ShieldThrowRushTrait = 3,
		SpearAutoAttack = 4,
		SpearDashMultiStrike = 4,
		SpearAttackPhalanxTrait = 4,
		GunMinigunTrait = 4,
		GunShotgunTrait = 4,
		GunGrenadeFastTrait = 4,
		GunInfiniteAmmoTrait = 4,
		FistDoubleDashSpecialTrait = 3,
		FistConsecutiveAttackTrait = 4,
	},
	EnemyEliteShrineUpgrade =
	{
		-- Every weapon has one Breaching/Piercing hammer whose explicit purpose
		-- is bonus damage to Armor.
		SwordHealthBufferDamageTrait = 4,
		BowPenetrationTrait = 4,
		ShieldChargeHealthBufferTrait = 4,
		SpearThrowPenetrate = 4,
		GunArmorPenerationTrait = 4,
		FistDashAttackHealthBufferTrait = 4,
	},
	EnemyCountShrineUpgrade =
	{
		SwordSecondaryAreaDamageTrait = 2,
		SwordThrustWaveTrait = 2,
		BowTripleShotTrait = 2,
		BowPenetrationTrait = 2,
		BowChainShotTrait = 2,
		ShieldThrowCatchExplode = 2,
		SpearThrowExplode = 2,
		SpearThrowBounce = 2,
		SpearAttackPhalanxTrait = 2,
		GunGrenadeFastTrait = 2,
		GunGrenadeClusterTrait = 2,
		FistDoubleDashSpecialTrait = 2,
		FistSpecialLandTrait = 2,
	},
}

BoonAdvisor.Ratings.KnockbackTraits =
{
	PoseidonWeaponTrait    = true, -- Tempest Strike
	PoseidonSecondaryTrait = true, -- Tempest Flourish
	PoseidonRushTrait      = true, -- Tidal Dash
	PoseidonRangedTrait    = true, -- Flood Shot
	PoseidonShoutTrait     = true, -- Poseidon's Aid
	SlamExplosionTrait     = true, -- Breaking Wave
	SlamStunTrait          = true,
	ImpactBoltTrait        = true, -- Sea Storm: lightning on knockback
}

--[[
	Known strong build archetypes.

	The synergy engine can see that a boon leads to *a* duo, but it has no
	opinion about which destinations are actually worth steering towards.
	These are the combinations the community consistently rates highest, so a
	pick that is part of one gets pushed.

	  Aspect  - if set, only counts while carrying that aspect
	  Core    - the boons the build is made of
	  Payoff  - the duo/legendary it is aiming at

	An archetype only activates once it is plausible: an aspect-gated one needs
	that aspect, and an open one needs at least one Core boon already held.
	Without that guard every boon would look like the start of some build.
]]
BoonAdvisor.Ratings.Archetypes =
{
	---------------------------------------------------------------------
	-- Stygian Blade
	---------------------------------------------------------------------
	{
		-- Arthur's 80/200-base-damage swings want a large percentage modifier.
		Name = "Arthur heavy attack",
		Aspect = "SwordConsecrationTrait",       -- Aspect of Arthur
		Core = { "AphroditeWeaponTrait", "AthenaWeaponTrait",
			"DemeterWeaponTrait", "ArtemisWeaponTrait" },
		CoreBonus = 16,
	},
	{
		Name = "Nemesis crit",
		Aspect = "SwordCriticalParryTrait",      -- Aspect of Nemesis
		Core = { "ArtemisWeaponTrait", "CritBonusTrait", "ArtemisSecondaryTrait" },
		Payoff = "ArtemisCriticalTrait",         -- Clean Kill
	},
	{
		Name = "Poseidon-blade Hunting Blades",
		Aspect = "DislodgeAmmoTrait",            -- Aspect of Poseidon (sword)
		Core = { "AresRangedTrait", "ArtemisWeaponTrait", "ArtemisSecondaryTrait",
			"ArtemisRushTrait", "ArtemisShoutTrait" },
		Payoff = "AresHomingTrait",              -- Hunting Blades
		CoreBonus = 16,
	},

	--[[
		Base (Zagreus) aspects have no gimmick to build around, so these are
		the general-purpose openers the per-weapon guides recommend rather than
		a specific combo: Weak for defence, plus whatever that weapon leans on.
	]]
	{
		Name = "sword opener",
		Aspect = "SwordBaseUpgradeTrait",
		Core = { "ArtemisWeaponTrait", "AphroditeWeaponTrait" },
	},
	{
		Name = "shield opener",
		Aspect = "ShieldBaseUpgradeTrait",
		Core = { "AphroditeWeaponTrait", "DionysusWeaponTrait" },
	},
	{
		Name = "spear opener",
		Aspect = "SpearBaseUpgradeTrait",
		Core = { "AphroditeWeaponTrait", "ArtemisWeaponTrait" },
	},
	{
		-- The fists apply Chill faster than any other weapon.
		Name = "fists Chill",
		Aspect = "FistBaseUpgradeTrait",
		Core = { "DemeterWeaponTrait", "AphroditeWeaponTrait" },
	},
	{
		-- Dionysus' cask fog lines up with the rail's special.
		Name = "rail fog",
		Aspect = "GunBaseUpgradeTrait",
		Core = { "DionysusRangedTrait", "AphroditeWeaponTrait" },
	},

	---------------------------------------------------------------------
	-- Heart-Seeking Bow
	---------------------------------------------------------------------
	-- Chiron applies a full Hangover stack with one homing special volley.
	{
		Name = "Chiron Hangover",
		Aspect = "BowMarkHomingTrait",           -- Aspect of Chiron
		Core = { "DionysusSecondaryTrait", "AphroditeWeaponTrait" },
		Payoff = "DionysusAphroditeStackIncreaseTrait", -- Low Tolerance
		CoreBonus = 18,
	},
	-- Merciful End needs Athena on Attack or Special to unlock; Divine Dash is
	-- the fast trigger after the duo is acquired, not an unlock by itself.
	{
		Name = "Chiron Merciful End",
		Aspect = "BowMarkHomingTrait",
		Core = { "AresSecondaryTrait", "AthenaWeaponTrait", "AthenaRushTrait" },
		Payoff = "TriggerCurseTrait",            -- Merciful End
	},
	{
		Name = "Hera fog",
		Aspect = "BowLoadAmmoTrait",             -- Aspect of Hera
		Core = { "DionysusRangedTrait", "ZeusRushTrait", "ZeusShoutTrait" },
		Payoff = "LightningCloudTrait",          -- Scintillating Feast
		CoreBonus = 16,
	},
	{
		-- The fast Hera route loads Crush Shot into the Attack and uses any
		-- valid Artemis and Poseidon duo prerequisite to reach Mirage Shot.
		Name = "Hera Crush Shot Mirage",
		Aspect = "BowLoadAmmoTrait",
		Core = { "AphroditeRangedTrait",
			"ArtemisWeaponTrait", "ArtemisSecondaryTrait", "ArtemisRangedTrait",
			"ArtemisShoutTrait", "PoseidonWeaponTrait", "PoseidonSecondaryTrait",
			"PoseidonRangedTrait", "PoseidonRushTrait", "PoseidonShoutTrait" },
		Payoff = "ArtemisBonusProjectileTrait", -- Mirage Shot
		CoreBonus = 18,
		ObjectiveBonus = { Speed = 6 },
	},
	{
		Name = "Rama lightning",
		Aspect = "BowBondTrait",                 -- Aspect of Rama
		Core = { "ZeusSecondaryTrait", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait",         -- Splitting Bolt
		CoreBonus = 16,
	},
	{
		Name = "Bow crit",
		Aspect = "BowBaseUpgradeTrait",          -- Aspect of Zagreus (bow)
		Core = { "ArtemisWeaponTrait", "AphroditeSecondaryTrait" },
		Payoff = "HeartsickCritDamageTrait",     -- Heart Rend
	},

	---------------------------------------------------------------------
	-- Shield of Chaos
	---------------------------------------------------------------------
	{
		Name = "Beowulf Mirage Shot",
		Aspect = "ShieldLoadAmmoTrait",          -- Aspect of Beowulf
		Core = { "ShieldLoadAmmo_PoseidonRangedTrait", "ArtemisWeaponTrait" },
		Payoff = "ArtemisBonusProjectileTrait",  -- Mirage Shot
		CoreBonus = 18,
	},
	{
		Name = "Zeus-shield special",
		Aspect = "ShieldTwoShieldTrait",         -- Aspect of Zeus (shield)
		Core = { "ZeusSecondaryTrait", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait",         -- Splitting Bolt
		CoreBonus = 18,
	},
	{
		Name = "Chaos-shield rush",
		Aspect = "ShieldRushBonusProjectileTrait", -- Aspect of Chaos
		Core = { "AphroditeWeaponTrait", "PoseidonRushTrait" },
	},

	---------------------------------------------------------------------
	-- Eternal Spear
	---------------------------------------------------------------------
	{
		Name = "Achilles Hunting Blades",
		Aspect = "SpearTeleportTrait",           -- Aspect of Achilles
		Core = { "AresRangedTrait", "ArtemisWeaponTrait", "ArtemisSecondaryTrait",
			"ArtemisRushTrait", "ArtemisShoutTrait" },
		Payoff = "AresHomingTrait",              -- Hunting Blades
		CoreBonus = 16,
	},
	{
		-- The non-cast speed route uses Flurry Jab with a high-frequency Attack.
		-- Tidal Dash supplies room clear while Zeus support leads to Splitting Bolt.
		Name = "Achilles Flurry lightning",
		Aspect = "SpearTeleportTrait",
		Core = { "ZeusWeaponTrait", "ArtemisWeaponTrait", "PoseidonRushTrait",
			"ZeusBonusBounceTrait", "ZeusBoltAoETrait", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait", -- Splitting Bolt
		CoreBonus = 16,
		ObjectiveBonus = { Speed = 6 },
	},
	{
		Name = "Guan Yu special",
		Aspect = "SpearSpinTravel",              -- Aspect of Guan Yu
		Core = { "AphroditeSecondaryTrait", "ArtemisSecondaryTrait",
			"AthenaWeaponTrait" },
		CoreBonus = 16,
	},
	{
		Name = "Hades-spear spin",
		Aspect = "SpearWeaveTrait",              -- Aspect of Hades
		Core = { "AphroditeWeaponTrait", "DemeterWeaponTrait" },
	},

	---------------------------------------------------------------------
	-- Twin Fists
	---------------------------------------------------------------------
	{
		Name = "Demeter-fists Merciful End",
		Aspect = "FistWeaveTrait",               -- Aspect of Demeter (fists)
		Core = { "AresWeaponTrait", "AthenaSecondaryTrait", "AthenaRushTrait" },
		Payoff = "TriggerCurseTrait",            -- Merciful End
		CoreBonus = 18,
	},
	{
		Name = "Talos magnet",
		Aspect = "FistVacuumTrait",              -- Aspect of Talos
		Core = { "AphroditeWeaponTrait", "DemeterWeaponTrait" },
	},
	{
		Name = "Gilgamesh melee",
		Aspect = "FistDetonateTrait",            -- Aspect of Gilgamesh
		Core = { "AphroditeWeaponTrait", "DionysusWeaponTrait" },
	},

	---------------------------------------------------------------------
	-- Adamant Rail
	---------------------------------------------------------------------
	{
		Name = "Eris lightning",
		Aspect = "GunGrenadeSelfEmpowerTrait",   -- Aspect of Eris
		Core = { "ZeusWeaponTrait", "PoseidonRushTrait", "AphroditeSecondaryTrait",
			"ArtemisSecondaryTrait", "ZeusLightningDebuff", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait",         -- Splitting Bolt
		CoreBonus = 18,
	},
	{
		Name = "Hestia heavy shot",
		Aspect = "GunManualReloadTrait",         -- Aspect of Hestia
		Core = { "AphroditeWeaponTrait", "ArtemisWeaponTrait" },
		CoreBonus = 16,
	},
	{
		Name = "Lucifer lightning",
		Aspect = "GunLoadedGrenadeTrait",        -- Aspect of Lucifer
		Core = { "ZeusWeaponTrait", "AphroditeSecondaryTrait",
			"ArtemisSecondaryTrait", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait",         -- Splitting Bolt
		CoreBonus = 16,
	},
	--[[
		The most consistently praised build in the game, and weapon-agnostic
		because it runs off the Cast. Ares' Slicing Shot plus ANY Artemis boon
		opens Hunting Blades -- not just the Artemis cast, which is what an
		earlier version of this table wrongly required.
	]]
	{
		Name = "Hunting Blades",
		Core = { "AresRangedTrait", "ArtemisWeaponTrait", "ArtemisSecondaryTrait",
			"ArtemisRushTrait", "ArtemisShoutTrait", "ArtemisRangedTrait" },
		Payoff = "AresHomingTrait",              -- Hunting Blades
	},
	{
		Name = "Sea Storm",
		-- Tidal Dash can trigger Sea Storm after it is acquired, but LootData
		-- deliberately excludes it from the Poseidon half of the unlock.
		Core = { "PoseidonWeaponTrait", "PoseidonSecondaryTrait", "PoseidonRangedTrait",
			"ShieldLoadAmmo_PoseidonRangedTrait", "PoseidonShoutTrait",
			"ZeusWeaponTrait", "ZeusSecondaryTrait", "ZeusRangedTrait",
			"ShieldLoadAmmo_ZeusRangedTrait", "ZeusRushTrait", "ZeusShoutTrait" },
		Payoff = "ImpactBoltTrait",              -- Sea Storm
	},
	{
		Name = "Splitting Bolt",
		Core = { "ZeusBonusBounceTrait", "ZeusBoltAoETrait", "ZeusBonusBoltTrait" },
		Payoff = "ZeusChargedBoltTrait",         -- Splitting Bolt
	},
	{
		Name = "Hangover crit",
		Core = { "DionysusWeaponTrait", "DionysusSecondaryTrait", "DionysusRushTrait",
			"DionysusShoutTrait", "ArtemisWeaponTrait", "ArtemisSecondaryTrait",
			"ArtemisRangedTrait", "ArtemisShoutTrait" },
		Payoff = "PoisonCritVulnerabilityTrait", -- Splitting Headache
	},
}

--[[
	Daedalus hammers, keyed by internal trait name (display name in comments).
	The game only ever offers hammers for the weapon you are carrying, so all
	six weapons can live in one table without colliding.
]]
BoonAdvisor.Ratings.Hammers =
{
	-- Stygian Blade
	SwordTwoComboTrait              = 66, -- Flurry Slash
	SwordSecondaryAreaDamageTrait   = 76, -- Super Nova
	SwordHeavySecondStrikeTrait     = 78, -- World Splitter
	SwordThrustWaveTrait            = 82, -- Piercing Wave
	SwordSecondaryDoubleAttackTrait = 84, -- Double Nova
	SwordHealthBufferDamageTrait    = 62, -- Breaching Slash
	SwordDoubleDashAttackTrait      = 80, -- Double Edge: repeatedly called the best sword hammer
	SwordCriticalTrait              = 70, -- Cruel Thrust
	SwordBackstabTrait              = 60, -- Shadow Slash
	SwordCursedLifeStealTrait       = 58, -- Cursed Slash
	SwordGoldDamageTrait            = 56, -- Hoarding Slash
	SwordBlinkTrait                 = 72, -- Dash Nova

	-- Coronacht
	BowDoubleShotTrait              = 72, -- Twin Shot
	BowLongRangeDamageTrait         = 62, -- Sniper Shot: only at range
	BowSlowChargeDamageTrait        = 70, -- Explosive Shot
	BowTapFireTrait                 = 78, -- Flurry Shot
	BowPenetrationTrait             = 68, -- Piercing Volley
	BowPowerShotTrait               = 84, -- Perfect Shot
	BowSecondaryBarrageTrait        = 74, -- Relentless Volley
	BowTripleShotTrait              = 76, -- Triple Shot
	BowSecondaryFocusedFireTrait    = 70, -- Charged Volley
	BowChainShotTrait               = 72, -- Chain Shot
	BowCloseAttackTrait             = 74, -- Point-Blank Shot
	BowConsecutiveBarrageTrait      = 72, -- Concentrated Volley

	-- Shield of Chaos
	ShieldDashAOETrait              = 66, -- Dashing Wallop
	ShieldRushProjectileTrait       = 70, -- Charged Shot
	ShieldThrowFastTrait            = 82, -- Dread Flight
	ShieldThrowCatchExplode         = 76, -- Explosive Return
	ShieldChargeHealthBufferTrait   = 64, -- Breaching Rush
	ShieldChargeSpeedTrait          = 62, -- Sudden Rush
	ShieldBashDamageTrait           = 72, -- Pulverizing Blow
	ShieldPerfectRushTrait          = 74, -- Minotaur Rush
	ShieldThrowElectiveCharge       = 68, -- Charged Flight
	ShieldThrowEmpowerTrait         = 78, -- Empowering Flight
	ShieldBlockEmpowerTrait         = 80, -- Ferocious Guard: the shield's standout hammer
	ShieldThrowRushTrait            = 74, -- Dashing Flight

	-- Varatha
	SpearReachAttack                = 66, -- Extending Jab
	SpearAutoAttack                 = 76, -- Flurry Jab
	SpearThrowExplode               = 74, -- Exploding Launcher
	SpearThrowBounce                = 70, -- Chain Skewer
	SpearThrowPenetrate             = 68, -- Breaching Skewer
	SpearThrowCritical              = 78, -- Vicious Skewer
	SpearSpinDamageRadius           = 72, -- Massive Spin
	SpearSpinChargeLevelTime        = 74, -- Quick Spin
	SpearDashMultiStrike            = 66, -- Serrated Point
	SpearThrowElectiveCharge        = 70, -- Charged Skewer
	SpearSpinChargeAreaDamageTrait  = 72, -- Flaring Spin
	SpearAttackPhalanxTrait         = 80, -- Triple Jab

	-- Exagryph
	GunSlowGrenade                  = 62, -- Targeting System
	GunMinigunTrait                 = 74, -- Flurry Fire
	GunShotgunTrait                 = 76, -- Spread Fire
	GunExplodingSecondaryTrait      = 78, -- Rocket Bomb
	GunGrenadeFastTrait             = 74, -- Triple Bomb
	GunArmorPenerationTrait         = 66, -- Piercing Fire
	GunInfiniteAmmoTrait            = 84, -- Delta Chamber
	GunGrenadeClusterTrait          = 84, -- Cluster Bomb: the rail's best hammer
	GunGrenadeDropTrait             = 64, -- Hazard Bomb
	GunHeavyBulletTrait             = 72, -- Explosive Fire
	GunChainShotTrait               = 68, -- Ricochet Fire
	GunHomingBulletTrait            = 70, -- Seeking Fire

	-- Malphon
	FistReachAttackTrait            = 68, -- Long Knuckle
	FistDashAttackHealthBufferTrait = 64, -- Breaching Cross
	FistTeleportSpecialTrait        = 70, -- Rush Kick
	FistDoubleDashSpecialTrait      = 74, -- Explosive Upper
	FistChargeSpecialTrait          = 76, -- Flying Cutter
	FistKillTrait                   = 66, -- Draining Cutter
	FistSpecialLandTrait            = 72, -- Quake Cutter
	FistAttackFinisherTrait         = 74, -- Rolling Knuckle
	FistConsecutiveAttackTrait      = 78, -- Concentrated Knuckle
	FistSpecialFireballTrait        = 72, -- Kinetic Launcher
	FistAttackDefenseTrait          = 70, -- Colossus Knuckle
	FistHeavyAttackTrait            = 66, -- Heavy Knuckle

	-- Aspect-specific hammers: only offered when you hold that aspect.
	SpearSpinTravelDurationTrait    = 78, -- Winged Serpent
	SwordConsecrationBoostTrait     = 82, -- Greater Consecration
	BowBondBoostTrait               = 76, -- Repulse Shot
	ShieldLoadAmmoBoostTrait        = 80,
	FistDetonateBoostTrait          = 78,
	GunLoadedGrenadeBoostTrait      = 78,
	GunLoadedGrenadeLaserTrait      = 80,
	GunLoadedGrenadeSpeedTrait      = 72,
	GunLoadedGrenadeWideTrait       = 74,
	GunLoadedGrenadeInfiniteAmmoTrait = 82,
}

--[[
	Aspect x hammer interactions -- the reason a flat hammer tier list is not
	enough. Keyed by aspect trait, then hammer trait, as an additive delta.

	Example: Aspect of Hera loads your Cast into your bow, so hammers that add
	arrows fire more Casts and get much better; on Aspect of Chiron, which
	rebuilds the Special, the volley hammers are what matter.
]]
BoonAdvisor.Ratings.HammerAspectMod =
{
	BowLoadAmmoTrait = -- Aspect of Hera: more arrows means more Casts
	{
		BowDoubleShotTrait = 10,
		BowTripleShotTrait = 12,
		BowTapFireTrait    = 8,
		BowPowerShotTrait  = -6,
	},
	BowMarkHomingTrait = -- Aspect of Chiron: the Special carries the run
	{
		BowSecondaryBarrageTrait     = 12,
		BowConsecutiveBarrageTrait   = 12,
		BowSecondaryFocusedFireTrait = 10,
		BowPowerShotTrait            = -8,
	},
	BowBondTrait = -- Aspect of Rama
	{
		BowSecondaryBarrageTrait   = 10,
		BowConsecutiveBarrageTrait = 8,
	},
	ShieldTwoShieldTrait = -- Aspect of Zeus: the Special is everything
	{
		ShieldThrowFastTrait    = 12,
		ShieldThrowEmpowerTrait = 12,
		ShieldThrowRushTrait    = 10,
		ShieldBashDamageTrait   = -6,
	},
	ShieldLoadAmmoTrait = -- Aspect of Beowulf: Cast-driven, Bull Rush focused
	{
		ShieldRushProjectileTrait       = 16, -- Charged Shot: speed route staple
		ShieldPerfectRushTrait        = 12,
		ShieldChargeHealthBufferTrait = 8,
		ShieldThrowFastTrait          = -10,
	},
	SpearTeleportTrait = -- Aspect of Achilles: Flurry Jab drives the fast route
	{
		SpearAutoAttack = 26,
		SpearAttackPhalanxTrait = 6,
	},
	--[[
		Guan Yu barely functions without its spin hammers -- Quick Spin and
		Massive Spin together are what make the aspect work, so they are
		weighted far above a normal aspect preference.
	]]
	SpearSpinTravel = -- Aspect of Guan Yu
	{
		SpearSpinChargeLevelTime       = 18, -- Quick Spin: near-essential
		SpearSpinDamageRadius          = 16, -- Massive Spin
		SpearSpinChargeAreaDamageTrait = 10,
		SpearThrowExplode              = -6,
	},
	SpearWeaveTrait = -- Aspect of Hades: wants Exploding Launcher
	{
		SpearThrowExplode = 12,
	},
	SwordCriticalParryTrait = -- Aspect of Nemesis: crit-centric
	{
		SwordCriticalTrait         = 12,
		SwordDoubleDashAttackTrait = 8,
	},
	GunGrenadeSelfEmpowerTrait = -- Aspect of Eris
	{
		GunGrenadeClusterTrait     = 10,
		GunExplodingSecondaryTrait = 8,
	},
	SwordConsecrationTrait = -- Aspect of Arthur: slow, heavy attacks
	{
		SwordSecondaryAreaDamageTrait   = 12, -- Super Nova: the Arthur pick
		SwordHeavySecondStrikeTrait     = 10,
		SwordThrustWaveTrait            = 8,
		SwordTwoComboTrait              = -8,
		SwordSecondaryDoubleAttackTrait = -6,
	},
	GunLoadedGrenadeTrait = -- Aspect of Lucifer
	{
		GunInfiniteAmmoTrait       = 8,
		GunExplodingSecondaryTrait = -10,
		GunGrenadeClusterTrait     = -10,
	},
	FistDetonateTrait = -- Aspect of Gilgamesh
	{
		FistConsecutiveAttackTrait = 10,
		FistAttackFinisherTrait    = 8,
	},
}

-- Small, goal-specific nudges. These never create a build by themselves;
-- archetypes and live synergy remain the dominant signals.
BoonAdvisor.Ratings.ObjectiveTags =
{
	Speed =
	{
		MoveSpeedTrait = true,
		RushSpeedBoostTrait = true,
		RushRallyTrait = true,
		RapidCastTrait = true,
		AmmoReloadTrait = true,
		BonusDashTrait = true,
		PoseidonRushTrait = true,
	},
	Survival =
	{
		AthenaWeaponTrait = true,
		AthenaSecondaryTrait = true,
		AthenaRushTrait = true,
		AthenaRangedTrait = true,
		AthenaShoutTrait = true,
		AthenaRetaliateTrait = true,
		EnemyDamageTrait = true,
		TrapDamageTrait = true,
		LastStandHealTrait = true,
		LastStandDurationTrait = true,
		DodgeChanceTrait = true,
		RushRallyTrait = true,
		AphroditeWeaponTrait = true,
		AphroditeSecondaryTrait = true,
		AphroditeRangedTrait = true,
		AphroditeRushTrait = true,
		AphroditePotencyTrait = true,
	},
}

--[[
	Chaos boons. The offer carries the blessing as ItemName and the curse as
	SecondaryItemName, so both halves can be priced: blessing value minus how
	painful the curse is while it lasts.
]]
BoonAdvisor.Ratings.ChaosBlessings =
{
	ChaosBlessingExtraChanceTrait = 88, -- +1 Death Defiance
	ChaosBlessingAmmoTrait        = 76, -- +1 Cast charge
	ChaosBlessingBoonRarityTrait  = 76, -- boons more likely Rare or better
	ChaosBlessingMeleeTrait       = 74, -- Attack damage
	ChaosBlessingSecondaryTrait   = 72, -- Special damage
	ChaosBlessingRangedTrait      = 70, -- Cast damage
	ChaosBlessingMaxHealthTrait   = 70, -- max life
	ChaosBlessingDashAttackTrait  = 66, -- Dash-Strike damage
	ChaosBlessingAlphaStrikeTrait = 64,
	ChaosBlessingBackstabTrait    = 58,
	ChaosBlessingMetapointTrait   = 52, -- Darkness
	ChaosBlessingMoneyTrait       = 48, -- Obols
}

-- Blessings that scale with a slot: worth more once that slot is filled.
BoonAdvisor.Ratings.ChaosBlessingSlots =
{
	ChaosBlessingAmmoTrait       = "Ranged",
	ChaosBlessingRangedTrait     = "Ranged",
	ChaosBlessingMeleeTrait      = "Melee",
	ChaosBlessingSecondaryTrait  = "Secondary",
}

-- How much the curse half hurts while it is active (subtracted).
BoonAdvisor.Ratings.ChaosCurses =
{
	ChaosCurseDeathWeaponTrait     = 14,
	ChaosCursePrimaryAttackTrait   = 12,
	ChaosCurseDamageTrait          = 12,
	ChaosCurseHealthTrait          = 10,
	ChaosCurseSpawnTrait           = 10,
	ChaosCurseDashRangeTrait       = 10,
	ChaosCurseSecondaryAttackTrait = 8,
	ChaosCurseCastAttackTrait      = 8,
	ChaosCurseAmmoUseDelayTrait    = 8,
	ChaosCurseMoveSpeedTrait       = 8,
	ChaosCurseTrapDamageTrait      = 6,
	ChaosCurseNoMoneyTrait         = 5,
	ChaosCurseHiddenRoomReward     = 4,
}

--[[
	Aspect affinity: additive bonus per slot for aspects that lean on a slot.
	Keyed by the aspect's internal trait name; detected by scanning the hero's
	traits, so an unknown or unlisted aspect simply contributes nothing.

	Every key here must be a real trait name in TraitData -- an invented key is
	not an error, it simply never matches, and the bonus silently never applies.
	These are the game's actual aspect trait names, verified against TraitData;
	the test suite asserts each one still exists.

	Base ("Aspect of Zagreus") upgrades are deliberately absent: they are
	neutral and should not bias any slot.
]]
BoonAdvisor.Ratings.AspectAffinity =
{
	-- Cast-centric: the cast is the damage engine, so cast boons matter most.
	BowLoadAmmoTrait               = { Ranged = 12 }, -- Aspect of Hera
	ShieldLoadAmmoTrait            = { Ranged = 12 }, -- Aspect of Beowulf

	-- Special-centric aspects.
	ShieldTwoShieldTrait           = { Secondary = 10 }, -- Aspect of Zeus
	BowMarkHomingTrait             = { Secondary = 10 }, -- Aspect of Chiron
	SpearSpinTravel                = { Secondary = 10 }, -- Aspect of Guan Yu
	BowBondTrait                   = { Secondary = 8  }, -- Aspect of Rama
	ShieldRushBonusProjectileTrait = { Secondary = 6  }, -- Aspect of Chaos
	FistWeaveTrait                 = { Melee = 6, Secondary = 8 }, -- Aspect of Demeter
	GunLoadedGrenadeTrait          = { Melee = 8, Secondary = 6 }, -- Aspect of Lucifer

	-- Attack-centric aspects.
	SwordConsecrationTrait         = { Melee = 8 }, -- Aspect of Arthur
	GunManualReloadTrait           = { Melee = 12 }, -- Aspect of Hestia
	GunGrenadeSelfEmpowerTrait     = { Melee = 10, Secondary = 4 }, -- Aspect of Eris
	SpearWeaveTrait                = { Melee = 8 }, -- Aspect of Hades
	FistDetonateTrait              = { Melee = 8 }, -- Aspect of Gilgamesh
	SwordCriticalParryTrait        = { Melee = 6 }, -- Aspect of Nemesis
	FistVacuumTrait                = { Melee = 6 }, -- Aspect of Talos

	-- Cast-centric aspects whose old entries incorrectly rewarded their setup
	-- move (Achilles Special / Poseidon Sword Attack) instead of the damage.
	SpearTeleportTrait             = { Ranged = 12 }, -- Aspect of Achilles
	DislodgeAmmoTrait              = { Ranged = 12 }, -- Aspect of Poseidon
}
