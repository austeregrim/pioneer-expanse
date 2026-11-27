-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local ui = require 'pigui'
local lui = Lang.GetResource("ui-core")
local msgbox = require 'pigui.libs.message-box'
local Character = require 'Character'
local Commodities = require 'Commodities'
local Equipment = require 'Equipment'
local FlightLog = require 'modules.FlightLog.FlightLog'
local ModalWindow = require 'pigui.libs.modal-win'
local ModelSkin = require 'SceneGraph.ModelSkin'
local ShipDef = require "ShipDef"
local SystemPath = require 'SystemPath'
local PlayerState = require 'PlayerState'

local Defs = require 'pigui.modules.new-game-window.defs'
local Layout = require 'pigui.modules.new-game-window.layout'
local Recovery = require 'pigui.modules.new-game-window.recovery'
local StartVariants = require 'pigui.modules.new-game-window.start-variants'
local FlightLogParam = require 'pigui.modules.new-game-window.flight-log'
local ShipParam = require 'pigui.modules.new-game-window.ship'
local LocationParam = require 'pigui.modules.new-game-window.location'
local Widgets = require 'pigui.modules.new-game-window.widgets'
local Game = require 'Game'

local CUSTOM_START_BUDGET = 115000
local CUSTOM_START_SHIPS = {
	"xylophis",
	"lunarshuttle",
	"bowfin",
	"pumpkinseed",
	"coronatrix",
	"molamola",
	"wave",
	"sinonatrix",
}

local allegianceCombo = { items = {}, selected = 0 }
local roleCombo = { items = {}, actions = {}, selected = 0 }
local startMode = "PREDEFINED" -- "PREDEFINED" | "CUSTOM_BUDGET" | "DEBUG_UNLOCK"

local ALLEGIANCES = {
	{
		id        = "solfed",
		name      = "Solar Federation (Sol — Mars High Orbit | Core Worlds, 0 ly)",
		faction   = "Solar Federation",
		location  = SystemPath.New(0, 0, 0, 0, 20), -- Mars High Orbit, Sol
		desc      = "STARTING FACTION: Solar Federation (Sol System — Mars High Orbit Station | 0 ly)\nThe historical cradle of humanity and administrative core of Federal space. Features dense orbital infrastructure, established commodities markets, and strict SolFed Military & Police patrols. Ideal for commanders who prefer high-security core worlds and reliable commercial trade routes.",
		loadoutSummary = "REGIONAL OUTFITTING (SolFed): Precision 1MW/Dual-1MW Beam Lasers, Target Scanners, and Autopilot Mk 2 avionics for Federal security compliance.",
		logPrefix = "Commissioned at Mars High Orbit Station (Sol) under Solar Federation registry.",
		trimColor = Color('3A7BD5'),
		loadoutOverrides = {
			trader    = { weapon_s2_1 = "laser.beamlaser_1mw", utility_s1_3 = "misc.target_scanner" },
			miner     = { computer_1 = "misc.autopilot_mk2", utility_s1_1 = "misc.target_scanner" },
			explorer  = { weapon_s2_1 = "laser.beamlaser_1mw", utility_s2_1 = "misc.target_scanner" },
			mercenary = { computer_1 = "misc.autopilot_mk2", laser_front_s2 = "laser.beamlaser_dual_1mw" },
		},
	},
	{
		id        = "ciw",
		name      = "Commonwealth of Independent Worlds (Eridani Commercial Center | ~10 ly)",
		faction   = "Commonwealth of Independent Worlds",
		location  = SystemPath.New(1, -1, -1, 0, 8), -- Eridani Commercial Center, Epsilon Eridani
		desc      = "STARTING FACTION: Commonwealth of Independent Worlds (Epsilon Eridani — Eridani Commercial Center | ~10 ly from Sol)\nA prosperous democratic confederation of core and mid-frontier systems. Eridani Commercial Center is a bustling orbital hub above New Hope with open trade laws, advanced shipyard drydocks, and balanced Confederal Police security.",
		loadoutSummary = "REGIONAL OUTFITTING (CIW): Dual 1MW Pulse Cannons, Supercruise-capable Autopilot Mk 2 avionics, Target Scanners, and Trade Computer integration.",
		logPrefix = "Commissioned at Eridani Commercial Center (Epsilon Eridani) within the Commonwealth of Independent Worlds.",
		trimColor = Color('2ECC71'),
		loadoutOverrides = {
			trader    = { computer = "misc.autopilot_mk2", utility_s1_3 = "misc.target_scanner" },
			miner     = { computer_1 = "misc.autopilot_mk2", utility_s1_1 = "misc.ecm_basic" },
			explorer  = { weapon_s2_1 = "laser.pulsecannon_dual_1mw", computer_3 = "misc.trade_computer" },
			mercenary = { computer_1 = "misc.autopilot_mk2", laser_front_s2 = "laser.pulsecannon_dual_1mw" },
		},
	},
	{
		id        = "haber",
		name      = "Haber Corporation (Zekonbur — Gaillard Orbital Platform | ~20 ly)",
		faction   = "Haber Corporation",
		location  = SystemPath.New(4, -9, -17, 0, 5), -- Gaillard Orbital Platform, Zekonbur
		desc      = "STARTING FACTION: Haber Corporation (Zekonbur System — Gaillard Orbital Platform | ~20 ly from Sol)\nA heavily industrialized corporate conglomerate governed by a board of directors. Corporate orbital platforms prioritize mineral processing, heavy manufacturing, and private corporate security enforcement.",
		loadoutSummary = "REGIONAL OUTFITTING (Haber): Upgraded Improved Thrusters for industrial acceleration, 2MW heavy Pulse Cannons, dual Miner Shielding, Target Scanner, and Subsystem Targeting Computer.",
		logPrefix = "Cleared from Gaillard Orbital Platform (Zekonbur) under Haber Corporation charter.",
		trimColor = Color('E67E22'),
		loadoutOverrides = {
			trader    = { weapon_s2_1 = "laser.pulsecannon_2mw", thruster = "thruster.improved_s2" },
			miner     = { shield_s1_2 = "shield.basic_s1", thruster = "thruster.improved_s1" },
			explorer  = { weapon_s2_1 = "laser.pulsecannon_2mw", utility_s2_1 = "misc.target_scanner" },
			mercenary = { computer_2 = "misc.subsystem_targeting_computer", thruster = "thruster.improved_s2" },
		},
	},
	{
		id        = "independent",
		name      = "Independent Frontier (Barnard's Star — Orbital | ~6 ly)",
		faction   = "Independent",
		location  = SystemPath.New(-1, 0, 0, 0, 16), -- System Administration Resting, Barnard's Star
		desc      = "STARTING FACTION: Independent Frontier (Barnard's Star — System Admin. Resting | ~6 ly from Sol)\nAn autonomous orbital frontier station surrounded by resource-rich asteroid bodies and close jump corridors to Sol. Suited for freelance couriers, prospectors, and independent operators outside superpower bureaucracy.",
		loadoutSummary = "REGIONAL OUTFITTING (Independent): Sublight Sensor Arrays, Scan Detectors, Wake Tracer, Hypercloud Analyzer, and Fuel Scoop readiness for self-reliant ops.",
		logPrefix = "Departing System Administration Resting orbital station (Barnard's Star) as an independent commander.",
		trimColor = Color('D4AC0D'),
		loadoutOverrides = {
			trader    = { fuel_scoop_s1 = "misc.fuel_scoop_s1", utility_s1_3 = "misc.scan_detector" },
			miner     = { utility_s1_1 = "misc.scan_detector", sensor = "sensor.sublight_array_1" },
			explorer  = { utility_s2_1 = "misc.hypercloud_analyzer", sensor = "sensor.sublight_array_1" },
			mercenary = { utility_s1_1 = "misc.wake_tracer", sensor = "sensor.sublight_array_1" },
		},
	},
	{
		id        = "rim_commonwealth",
		name      = "Rim Commonwealth (Orthethio — van der Linden Orbital | ~37 ly)",
		faction   = "Rim Commonwealth",
		location  = SystemPath.New(-2, -26, -26, 0, 8), -- van der Linden Orbital, Orthethio
		desc      = "STARTING FACTION: Rim Commonwealth (Orthethio System — van der Linden Orbital | ~37 ly from Sol)\nA thriving Rim territory confederation with extensive orbital commerce and frontier trade networks. Distant from Core politics, Orthethio features bustling commodity depots, orbital staging platforms, and active Alliance Security.",
		loadoutSummary = "REGIONAL OUTFITTING (Rim Commonwealth): Defensive ECM suites, Scan Detectors, Interdiction Nullifier protection, and expanded auxiliary cargo/surface survey gear.",
		logPrefix = "Commissioned at van der Linden Orbital (Orthethio) in Rim Commonwealth space.",
		trimColor = Color('8E44AD'),
		loadoutOverrides = {
			trader    = { utility_s1_3 = "misc.ecm_basic", utility_s1_4 = "misc.scan_detector" },
			miner     = { utility_s1_1 = "misc.planetscanner", utility_s1_2 = "misc.scan_detector" },
			explorer  = { utility_s2_1 = "misc.ecm_basic", cabin_s1_2 = "misc.cabin_hold_s1" },
			mercenary = { computer_2 = "misc.interdiction_nullifier", utility_s1_1 = "misc.scan_detector" },
		},
	},
	{
		id        = "druello_pirates",
		name      = "Druello Pirates (Anvisium — Karlsen Orbital Haven | ~61 ly)",
		faction   = "Druello Pirates",
		location  = SystemPath.New(-57, 9, -21, 2, 6), -- Karlsen Orbital Haven, Anvisium
		desc      = "STARTING FACTION: Druello Pirates (Anvisium System — Karlsen Orbital Haven | ~61 ly from Sol)\nA lawless deep-space pirate enclave established by Captain Oren Druello, a defector SolFed naval commander. Far outside the reach of Core authorities, this orbital haven offers illicit black market trade, untaxed equipment outfitting, and lucrative privateering contracts for outlaws and mercenaries.",
		loadoutSummary = "REGIONAL OUTFITTING (Druello Pirates): Concealed Smuggler Cargo Racks, Scan Detectors, FSD Interdictor, Wake Tracer, and mixed Beam/Dual-Pulse pirate weaponry.",
		logPrefix = "Departing Karlsen Orbital Haven (Anvisium) under the Druello Pirate black flag.",
		trimColor = Color('C0392B'),
		loadoutOverrides = {
			trader    = { cabin_s1_1 = "misc.cabin_smuggler_hold_s1", utility_s1_3 = "misc.scan_detector", weapon_s2_1 = "laser.pulsecannon_dual_1mw" },
			miner     = { cabin_s1_1 = "misc.cabin_smuggler_hold_s1", utility_s1_1 = "misc.scan_detector", computer_2 = "misc.fsd_interdictor_1" },
			explorer  = { weapon_s2_1 = "laser.beamlaser_1mw", utility_s2_1 = "misc.scan_detector", cabin_s1_2 = "misc.cabin_smuggler_hold_s1" },
			mercenary = { laser_front_s2 = "laser.pulsecannon_dual_1mw", weapon_left_s1 = "laser.beamlaser_1mw", weapon_right_s1 = "laser.beamlaser_1mw", utility_s1_1 = "misc.wake_tracer" },
		},
	},
	{
		id        = "free_systems",
		name      = "Free Systems (Torashay — Orbital Gateway | ~81 ly)",
		faction   = "Free Systems",
		location  = SystemPath.New(-18, -56, -56, 0, 5), -- Torashay Orbital Gateway, Torashay
		desc      = "STARTING FACTION: Free Systems (Torashay System — Torashay Orbital Gateway | ~81 ly from Sol)\nA fiercely sovereign league of frontier systems located over 80 light years from Sol. Known for raw ore extraction, rugged orbital staging platforms, and open borders with the deep unexplored expanse.",
		loadoutSummary = "REGIONAL OUTFITTING (Free Systems): Hypercloud Analyzers for deep-frontier wake tracking, Subsystem Targeting Computer, heavy 2MW/Dual Pulse Cannons, and dual Miner shields.",
		logPrefix = "Cleared from Torashay Orbital Gateway (Torashay) on the outer Free Systems frontier.",
		trimColor = Color('16A085'),
		loadoutOverrides = {
			trader    = { weapon_s2_1 = "laser.pulsecannon_2mw", utility_s1_3 = "misc.hypercloud_analyzer" },
			miner     = { utility_s1_1 = "misc.planetscanner", shield_s1_2 = "shield.basic_s1" },
			explorer  = { weapon_s2_1 = "laser.pulsecannon_dual_1mw", utility_s2_1 = "misc.hypercloud_analyzer" },
			mercenary = { utility_s1_1 = "misc.hypercloud_analyzer", computer_2 = "misc.subsystem_targeting_computer" },
		},
	},
	{
		id        = "obsidian_worlds",
		name      = "Obsidian Worlds (Hagildrorn — Meyer Anchorage | ~86 ly)",
		faction   = "Obsidian Worlds",
		location  = SystemPath.New(-60, -44, -44, 0, 13), -- Meyer Anchorage, Hagildrorn
		desc      = "STARTING FACTION: Obsidian Worlds (Hagildrorn System — Meyer Anchorage | ~86 ly from Sol)\nA remote, heavily fortified sector perched on the edge of charted space ~86 light years from Sol. Known for stark extraction facilities, autonomous defense syndicates, and high bounties on perimeter threats.",
		loadoutSummary = "REGIONAL OUTFITTING (Obsidian Worlds): Standard Sublight Sensor Array across all hulls, Subsystem Targeting Computers, Beam Laser optics, and Miner ECM.",
		logPrefix = "Departing Meyer Anchorage (Hagildrorn) in the deep Obsidian Worlds rim.",
		trimColor = Color('5D6D7E'),
		loadoutOverrides = {
			trader    = { sensor = "sensor.sublight_array_1", weapon_s2_1 = "laser.beamlaser_1mw" },
			miner     = { sensor = "sensor.sublight_array_1", utility_s1_1 = "misc.ecm_basic" },
			explorer  = { sensor = "sensor.sublight_array_1", computer_3 = "misc.subsystem_targeting_computer" },
			mercenary = { sensor = "sensor.sublight_array_1", computer_2 = "misc.subsystem_targeting_computer", laser_front_s2 = "laser.beamlaser_dual_1mw" },
		},
	},
	{
		id        = "tolisian",
		name      = "Tolisian Scientific Community (Torisay — Ruiz Gateway | ~79 ly)",
		faction   = "Tolisian Scientific Community",
		location  = SystemPath.New(4, -1, 9, 0, 13), -- Ruiz Gateway, Torisay
		desc      = "STARTING FACTION: Tolisian Scientific Community (Torisay System — Ruiz Gateway | ~79 ly from Sol)\nAn enclave of prosperous technocratic worlds governed by an elite scientific council in the outer positive-Z sector. Tolisians outlaw aggressive weaponry and enforce strict human rights, favoring defensive deterrence, long-range telemetry, and peaceful orbital research.",
		loadoutSummary = "REGIONAL OUTFITTING (Tolisian): High-precision Sublight Sensor Arrays, Autopilot Mk 2 flight computers, Interdiction Nullifier defense, Orbital/Surface survey optics, and Dual Beam Lasers.",
		logPrefix = "Cleared from Ruiz Gateway (Torisay) under Tolisian Scientific Community charter.",
		trimColor = Color('9B59B6'),
		loadoutOverrides = {
			trader    = { utility_s1_3 = "misc.planetscanner", computer = "misc.autopilot_mk2", sensor = "sensor.sublight_array_1" },
			miner     = { utility_s1_1 = "misc.orbitscanner", computer_1 = "misc.autopilot_mk2", sensor = "sensor.sublight_array_1" },
			explorer  = { sensor = "sensor.sublight_array_1", computer_3 = "misc.trade_computer", utility_s2_1 = "misc.hypercloud_analyzer" },
			mercenary = { computer_2 = "misc.interdiction_nullifier", sensor = "sensor.sublight_array_1", laser_front_s2 = "laser.beamlaser_dual_1mw" },
		},
	},
	{
		id        = "blood_expanse",
		name      = "Blood Expanse (Nikunito — Medina Industrial Center | ~260 ly)",
		faction   = "Blood Expanse",
		location  = SystemPath.New(22, -17, -17, 1, 15), -- Medina Industrial Center, Nikunito
		desc      = "STARTING FACTION: Blood Expanse (Nikunito System — Medina Industrial Center | ~260 ly from Sol)\nA vast, heavily industrialized outer collective far across the +X frontier. Forged around deep-core ore refineries and relentless freight quotas, Expanse shipyards turn out over-engineered workhorse vessels built to haul heavy loads and survive frontier ambushes.",
		loadoutSummary = "REGIONAL OUTFITTING (Blood Expanse): Auxiliary Cargo Racks on Traders/Miners, heavy 2MW Pulse Cannons, dual Miner shields, and Improved S2/S3 Thrusters.",
		logPrefix = "Launched from Medina Industrial Center (Nikunito) deep within the Blood Expanse.",
		trimColor = Color('922B21'),
		loadoutOverrides = {
			trader    = { cabin_s1_2 = "misc.cabin_hold_s1", weapon_s2_1 = "laser.pulsecannon_2mw" },
			miner     = { shield_s1_2 = "shield.basic_s1", cabin_s1_2 = "misc.cabin_hold_s1" },
			explorer  = { weapon_s2_1 = "laser.pulsecannon_2mw", thruster = "thruster.improved_s3" },
			mercenary = { thruster = "thruster.improved_s2", utility_s1_1 = "misc.scan_detector" },
		},
	},
	{
		id        = "stellar_union",
		name      = "Stellar Union (Gligril — Davanzati Residence | ~377 ly)",
		faction   = "Stellar Union",
		location  = SystemPath.New(44, 12, 12, 1, 3), -- Davanzati Residence, Gligril
		desc      = "STARTING FACTION: Stellar Union (Gligril System — Davanzati Residence | ~377 ly from Sol)\nA distant, militarized frontier stratocracy on the far +X/+Y/+Z rim nearly 380 light years from Earth. Patrolled by the Union Battle Flight and Stellar Prefecture, local starports outfit civilian and mercenary hulls alike with tactical targeting avionics, ECM, and pursuit sensors.",
		loadoutSummary = "REGIONAL OUTFITTING (Stellar Union): Subsystem Targeting Computers, ECM suites, Target Scanners, Wake Tracer pursuit telemetry, and mixed Dual-Pulse / Beam batteries.",
		logPrefix = "Deployed from Davanzati Residence (Gligril) under Stellar Union Prefecture clearance.",
		trimColor = Color('2980B9'),
		loadoutOverrides = {
			trader    = { weapon_s2_1 = "laser.pulsecannon_dual_1mw", utility_s1_3 = "misc.target_scanner", utility_s1_4 = "misc.ecm_basic" },
			miner     = { utility_s1_1 = "misc.target_scanner", utility_s1_2 = "misc.ecm_basic" },
			explorer  = { weapon_s2_1 = "laser.beamlaser_1mw", computer_3 = "misc.subsystem_targeting_computer", utility_s2_1 = "misc.target_scanner" },
			mercenary = { computer_2 = "misc.subsystem_targeting_computer", utility_s1_1 = "misc.wake_tracer", laser_front_s2 = "laser.pulsecannon_dual_1mw", weapon_left_s1 = "laser.beamlaser_1mw", weapon_right_s1 = "laser.beamlaser_1mw" },
		},
	},
}

local CAREER_ROLES = {
	{
		id       = "trader",
		name     = "Trader / Hauler (Sinonatrix)",
		shipType = "sinonatrix",
		money    = 1000,
		desc     = "CAREER BUILDOUT: Commercial Trader & Merchant Hauler\nOutfitted with a medium OPLI Sinonatrix freighter (32t total cargo capacity with auxiliary rack), Class 2 Hyperdrive, Class 2 Shielding, 1MW Pulse Cannon, Autopilot, Trade Computer, and Atmospheric Shielding S2, plus 1,000 Cr working capital for immediate commodity trading.",
		logRole  = "Vessel outfitted for commercial freight and interstellar commodity trade.",
		equipment = {
			computer       = "misc.autopilot",
			computer_2     = "misc.trade_computer",
			weapon_s2_1    = "laser.pulsecannon_1mw",
			shield_s2_1    = "shield.basic_s2",
			sensor         = "sensor.radar",
			hull_1         = "hull.atmospheric_shielding_s2",
			hyperdrive     = "hyperspace.hyperdrive_2",
			thruster       = "thruster.default_s2",
			cabin_s1_1     = "misc.cabin_hold_s1",
		},
		cargo   = {},
		pattern = 1,
		colors  = { Color('1C2833'), Color('ABB2B9'), Color('3A7BD5') },
	},
	{
		id       = "miner",
		name     = "Miner / Prospector (Coronatrix)",
		shipType = "coronatrix",
		money    = 600,
		desc     = "CAREER BUILDOUT: Asteroid Miner & Prospector\nEquipped with an agile OPLI Coronatrix hull mounting a heavy 5MW Mining Cannon, Cargo Scoop for ore recovery, Fuel Scoop for deep-field refueling, Class 2 Hyperdrive, Trade Computer, Autopilot, and an Auxiliary Cargo Rack in the internal storage compartment (24t total cargo space).",
		logRole  = "Vessel configured for asteroid extraction and mineral prospecting.",
		equipment = {
			[1]            = "misc.cargo_scoop",
			computer_1     = "misc.autopilot",
			computer_2     = "misc.trade_computer",
			laser_front_s2 = "laser.miningcannon_5mw",
			shield_s1_1    = "shield.basic_s1",
			fuel_scoop_s1  = "misc.fuel_scoop_s1",
			sensor         = "sensor.radar",
			hull_1         = "hull.atmospheric_shielding_s1",
			hyperdrive     = "hyperspace.hyperdrive_2",
			thruster       = "thruster.default_s1",
			cabin_s1_1     = "misc.cabin_hold_s1",
		},
		cargo   = {},
		pattern = 2,
		colors  = { Color('2C3E50'), Color('D35400'), Color('F39C12') },
	},
	{
		id       = "explorer",
		name     = "Explorer / Pathfinder (Skipjack)",
		shipType = "skipjack",
		money    = 600,
		desc     = "CAREER BUILDOUT: Deep-Space Explorer & Survey Vessel\nOutfitted with a sleek Kaluri Skipjack long-range exploration ship featuring a pressurized Passenger Cabin (living quarters) in the internal storage compartment, long-range Class 2 Hyperdrive, Fuel Scoop for stellar refueling, Orbital & Surface Planet Scanners for survey contracts, Autopilot Mk 2 (Supercruise Assist), FSD Interdiction Nullifier defense device, and Class 2 Shielding.",
		logRole  = "Vessel equipped with orbital/surface survey scanners, Supercruise Assist, Interdiction Nullifier, fuel scoop, and living quarters for deep-space exploration.",
		equipment = {
			computer           = "misc.autopilot_mk2",
			computer_2         = "misc.interdiction_nullifier",
			weapon_s2_1        = "laser.pulsecannon_1mw",
			shield_s2          = "shield.basic_s2",
			utility_s1_1       = "misc.orbitscanner",
			utility_s1_2       = "misc.planetscanner",
			fuel_scoop_s1_left = "misc.fuel_scoop_s1",
			sensor             = "sensor.radar",
			hull_1             = "hull.atmospheric_shielding_s2",
			hyperdrive         = "hyperspace.hyperdrive_2",
			thruster           = "thruster.default_s3",
			cabin_s1_1         = "misc.cabin_s1",
		},
		cargo   = {},
		pattern = 1,
		colors  = { Color('1B2631'), Color('EAECEE'), Color('48C9B0') },
	},
	{
		id       = "mercenary",
		name     = "Mercenary / Escort (Wave)",
		shipType = "wave",
		money    = 500,
		desc     = "CAREER BUILDOUT: Tactical Mercenary & Combat Escort\nCombat-heavy Auronox Wave medium fighter armed with a heavy 2MW center Pulse Cannon, dual 1MW wing Pulse Cannons, dual S2 Shield Generators, Laser Cooling Booster, Target Scanner, Basic ECM, FSD Interdictor, Autopilot, and Class 2 Hyperdrive.",
		logRole  = "Vessel armed and shielded for combat escort, bounty hunting, and interdiction operations.",
		equipment = {
			[1]            = "misc.laser_cooling_booster",
			computer_1     = "misc.autopilot",
			computer_2     = "misc.fsd_interdictor_1",
			laser_front_s2 = "laser.pulsecannon_2mw",
			weapon_left_s1 = "laser.pulsecannon_1mw",
			weapon_right_s1= "laser.pulsecannon_1mw",
			shield_s2_1    = "shield.basic_s2",
			shield_s2_2    = "shield.basic_s2",
			utility_s1_1   = "misc.target_scanner",
			utility_s1_2   = "misc.ecm_basic",
			sensor         = "sensor.radar",
			hull_1         = "hull.atmospheric_shielding_s2",
			hyperdrive     = "hyperspace.hyperdrive_2",
			thruster       = "thruster.default_s2",
		},
		cargo   = {},
		pattern = 1,
		colors  = { Color('17202A'), Color('7B241C'), Color('E74C3C') },
	},
}

local function composeStartVariant(allegianceIdx, roleIdx)
	local allegiance = ALLEGIANCES[allegianceIdx] or ALLEGIANCES[1]
	local role = CAREER_ROLES[roleIdx] or CAREER_ROLES[1]
	local colors = {
		role.colors[1],
		role.colors[2],
		allegiance.trimColor or role.colors[3],
	}
	local equipment = table.deepcopy(role.equipment)
	local overrides = allegiance.loadoutOverrides and allegiance.loadoutOverrides[role.id]
	if overrides then
		for slot, itemId in pairs(overrides) do
			equipment[slot] = itemId
		end
	end
	local desc = allegiance.desc
	if allegiance.loadoutSummary then
		desc = desc .. "\n" .. allegiance.loadoutSummary
	end
	desc = desc .. "\n\n" .. role.desc
	return {
		name      = allegiance.name .. " — " .. role.name,
		desc      = desc,
		location  = allegiance.location,
		faction   = allegiance.faction,
		logmsg    = allegiance.logPrefix .. " " .. role.logRole,
		shipType  = role.shipType,
		money     = role.money,
		equipment = equipment,
		cargo     = table.deepcopy(role.cargo),
		pattern   = role.pattern,
		colors    = colors,
	}
end

-- Register all Allegiance x Career Role combinations in StartVariants for compatibility
for aIdx = 1, #ALLEGIANCES do
	for rIdx = 1, #CAREER_ROLES do
		StartVariants.register(composeStartVariant(aIdx, rIdx))
	end
end

-- synchronize parameter views with updated values
local function updateParams()
	for _, tab in ipairs(Layout.Tabs) do
		if tab.updateParams then tab:updateParams() end
	end
end

local isHardcore = false

local function setStartVariant(variant)
	for _, param in ipairs(Layout.UpdateOrder) do
		param:fromStartVariant(variant)
	end
end

local function startGame(gameParams)

	-- space, ship in dock / orbit
	local startTime = gameParams.time
	if startTime < 0 then
		startTime = util.standardGameStartTime()
	end
	Game.StartGame(gameParams.location.path, startTime, gameParams.ship.type)
	if Game.SetHardcore then
		Game.SetHardcore(isHardcore)
	end
	local player = Game.player

	PlayerState.SetMoney(gameParams.player.money)

	player:SetLabel(gameParams.ship.label)
	player:SetShipName(gameParams.ship.name)

	local pattern = gameParams.ship.model.pattern
	if pattern > 0 then
		player:SetPattern(gameParams.ship.model.pattern - 1)
	end
	local colors = gameParams.ship.model.colors
	local shipDef = ShipDef[gameParams.ship.type]
	local skin = ModelSkin.New()
	skin:SetColors({ primary = colors[1], secondary = colors[2], trim = colors[3] })
	skin:SetDecal(shipDef.manufacturer)
	skin:SetLabel(gameParams.ship.label)
	player:SetSkin(skin)

	-- setup player character
	local PlayerCharacter = gameParams.player.char
	PlayerCharacter.reputation = gameParams.player.reputation
	PlayerCharacter.killcount = gameParams.player.kills
	-- Gave the player a missions table (for Misssions.lua)
	PlayerCharacter.missions = {}
	-- Insert the player character into the persistent character
	-- table.  Player won't be ennumerated with NPCs, because player
	-- is not numerically keyed.
	Character.persistent = { player = PlayerCharacter }
	-- Enroll the player in their own crew
	player:Enroll(PlayerCharacter)

	-- Generate crew for the starting ship
	for _, member in ipairs(gameParams.crew) do
		member.contract.payday = startTime + 604800 -- in a week
		member.contract.outstanding = 0
		player:Enroll(member)
	end

	local equipSet = player:GetComponent("EquipSet")
	player:UpdateEquipStats()

	-- slotless
	for _, item in ipairs(gameParams.ship.equipment) do
		local proto = Equipment.Get(item)
		if not equipSet:Install(proto:Instance()) then
			logWarning("Couldn't install equipment item {} in misc. cargo space" % { proto:GetName() })
		end
	end

	local function installEquipment(nodes, prefix)
		for slot, node in pairs(nodes) do

			local item

			if type(node) == 'table' then
				item = node.id
				assert(item)
			else
				item = node
			end

			if prefix then
				slot = prefix .. slot
			end

			local proto = Equipment.Get(item)
			if type(slot) == "string" then
				local slotHandle = equipSet:GetSlotHandle(slot)
				if slotHandle then
					local inst = proto:Instance()

					if inst.SpecializeForShip then inst:SpecializeForShip(equipSet.config) end

					if slotHandle.count then
						inst:SetCount(slotHandle.count)
					end

					if not equipSet:Install(inst, slotHandle) then
						logWarning("Couldn't install equipment item {} into slot {}" % { inst:GetName(), slot })
					end
				end

				if type(node) == 'table' then
					installEquipment(node.slots, slot .. "##")
				end
			end
		end
	end
	installEquipment(gameParams.ship.equipment)

	---@type CargoManager
	local cargoMgr = player:GetComponent('CargoManager')
	for id, amount in pairs(gameParams.ship.cargo) do
		cargoMgr:AddCommodity(Commodities[id], amount)
	end

	local drive = player:GetInstalledHyperdrive()
	if drive then
		drive:SetFuel(player, drive:GetMaxFuel())
	end

	-- Force initial residency at the starting station with 42 days remaining on the 90-day lock
	-- (only for predefined allegiance starts; Custom Start begins stateless with no residency)
	if startMode == "PREDEFINED" then
		local startStation = player:GetDockedWith()
		if startStation then
			local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
			if okTax and TaxAuthority and TaxAuthority.SetInitialResidency then
				TaxAuthority.SetInitialResidency(startStation, 42)
			end
		end
	end

	for _, entry in ipairs(gameParams.flightlog.Custom) do
		if FlightLog.InsertCustomEntry(entry) then
			-- ok then
		elseif entry.entry then
			-- allow a custom log entry containing only text
			-- because when starting a new game we only have text
			FlightLog.MakeCustomEntry(entry.entry)
		else
			logWarning("Wrong entry for the custom flight log")
		end
	end

	for _, entry in ipairs(gameParams.flightlog.System) do
		if not FlightLog.InsertSystemEntry(entry) then
			logWarning("Wrong entry for the system flight log")
		end
	end

	for _, entry in ipairs(gameParams.flightlog.Station) do
		if not FlightLog.InsertStationEntry(entry) then
			logWarning("Wrong entry for the station flight log")
		end
	end
	FlightLog.OrganizeEntries()

	if gameParams.autoExec then
		gameParams.autoExec()
	end
end

local NewGameWindow = {}

local function putByPath(tbl, path, value)
	local ref, last
	for token in string.gmatch(path, "[^.]+") do
		if not tbl[token] then tbl[token] = {} end
		ref = tbl
		last = token
		tbl = tbl[token]
	end
	ref[last] = value
end

local function drawBottomButtons()
	ui.separator()
	if ui.button(lui.START_GAME) then
		local errors = {}
		local msg = ""
		for _, param in ipairs(Layout.UpdateOrder) do
			if not param:isValid() then
				table.insert(errors, param.name)
			end
		end
		if #errors == 0 then
			local gameParams = {}
			for _, param in ipairs(Layout.UpdateOrder) do
				putByPath(gameParams, param.path, param.value)
			end
			startGame(gameParams)
			NewGameWindow:close()
		else
			msg = lui.SOME_PARAMETERS_ARE_NOT_OK
			for _, v in ipairs(errors) do
				msg = msg .. '\n - ' .. tostring(v)
			end
			msgbox.OK(msg)
		end
	end
	ui.sameLine()
	if ui.button(lui.CLOSE) then
		NewGameWindow:close()
	end
	ui.sameLine(0, 24)
	local changed, checked = ui.checkbox("Hardcore Mode (Permadeath / No Insurance)", isHardcore)
	if changed then
		isHardcore = checked
	end
end

local function hasNameInArray(param, array)
	for _, v in pairs(array) do
		if v.name == param.name then return true end
	end
end

local function unlockAll()
	startMode = "DEBUG_UNLOCK"
	ShipParam.Equip.budgetTotal = false
	ShipParam.Type:setAllowedShips(nil, false)
	Layout.setLock(false)
	FlightLogParam.value.Custom = {{ entry = "Custom start of the game - for the purpose of debugging or cheat." }}
end

local function applyCustomBudgetStart()
	startMode = "CUSTOM_BUDGET"
	ShipParam.Type:setAllowedShips(CUSTOM_START_SHIPS, true)
	ShipParam.Equip.budgetTotal = CUSTOM_START_BUDGET
	setStartVariant({
		name      = "Custom Start — Independent Budget",
		desc      = "CUSTOM START (INDEPENDENT BUDGET — 115,000 Cr)\nChoose any basic starter hull on the Ship tab, purchase your own equipment loadout within budget (unspent credits become starting cash), and select your starting system or station on the Location tab.\n\nRESIDENCY: Stateless / Unregistered (no home station residency assigned at start).",
		location  = SystemPath.New(-1, 0, 0, 0, 16), -- Barnard's Star orbital default; freely changeable
		logmsg    = "Departing on an independent custom charter with no faction residency.",
		shipType  = "coronatrix",
		money     = 0,
		equipment = {
			computer_1 = "misc.autopilot",
			sensor     = "sensor.radar",
			hyperdrive = "hyperspace.hyperdrive_1",
			thruster   = "thruster.default_s1",
		},
		cargo     = {},
		pattern   = 1,
		colors    = { Color('2C3E50'), Color('ABB2B9'), Color('D4AC0D') },
	})
	ShipParam.Type.lock = false
	ShipParam.Equip.lock = false
	ShipParam.Model.lock = false
	LocationParam.lock = false
end

-- wait a few frames, and then calculate the static layout (updateLayout)
local initFrames = 2

local function applySelectedStartProfile()
	local action = roleCombo.actions[roleCombo.selected + 1]
	if action == 'DO_UNLOCK' then
		unlockAll()
	elseif action == 'CUSTOM_BUDGET' then
		applyCustomBudgetStart()
	else
		startMode = "PREDEFINED"
		ShipParam.Equip.budgetTotal = false
		ShipParam.Type:setAllowedShips(nil, false)
		setStartVariant(composeStartVariant(allegianceCombo.selected + 1, roleCombo.selected + 1))
	end
	updateParams()
end

NewGameWindow = ModalWindow.New("New Game", function()

	ui.withFont(Defs.mainFont, function()

		ui.alignTextToFramePadding()
		if NewGameWindow.mode == 'RECOVER' then
			ui.text(lui.RECOVER_SAVEGAME)
		else
			local comboWidth = math.floor(Defs.winSize.x * 0.38)
			ui.text((lui.ALLEGIANCE or "Allegiance") .. ":")
			ui.sameLine()
			ui.nextItemWidth(comboWidth)
			if startMode == "CUSTOM_BUDGET" then
				Widgets.combo(true, "##allegiance_select", 0, { "Independent / Select on Location Tab (No Residency)" })
			else
				local changedAllegiance, retAllegiance = ui.combo("##allegiance_select", allegianceCombo.selected, allegianceCombo.items)
				if changedAllegiance then
					allegianceCombo.selected = retAllegiance
					applySelectedStartProfile()
				end
			end

			ui.sameLine(0, ui.getItemSpacing().x * 2)
			ui.text("Career Role:")
			ui.sameLine()
			ui.nextItemWidth(comboWidth)
			local changedRole, retRole = ui.combo("##role_select", roleCombo.selected, roleCombo.items)
			if changedRole then
				roleCombo.selected = retRole
				applySelectedStartProfile()
			end
		end

		ui.separator()

		if ui.beginTabBar("Tabs") then
			if initFrames > 0 then
				if initFrames == 1 then
					-- consider the height of bottom buttons
					drawBottomButtons()
					-- at this point getContentRegion() exactly returns the size of the available space
					Layout.updateLayout(ui.getContentRegion())
					updateParams()
				end
				initFrames = initFrames - 1
			else
				for _, tab in ipairs(Layout.Tabs) do
					if ui.beginTabItem(tab.TabName) then
						tab:draw()
						ui.endTabItem()
					end
				end
			end
			ui.endTabBar()
		end

		drawBottomButtons()
	end)
end, function (_, drawPopupFn)
	ui.setNextWindowSize(Defs.winSize, 'Always')
	ui.setNextWindowPosCenter('Always')
	ui.withStyleColors({ PopupBg = ui.theme.colors.modalBackground }, drawPopupFn)
end)

function NewGameWindow.restoreSaveGame(selectedSave)
	local saveGame = Recovery.loadDoc(selectedSave)
	if type(saveGame) == 'table' then

		local paramErrors = {}

		local report = lui.ATTEMPTING_TO_RECOVER_GAME_PROGRESS_FROM_SAVE_X:interp{ save = selectedSave }
		-- first variant as default value
		setStartVariant(composeStartVariant(1, 1))
		-- except for clearing the log
		FlightLogParam:fromStartVariant({})
		report = report .. "\n\n" .. string.format(lui.FILE_SAVEGAME_VERSION, tostring(saveGame.version))
		report = report .. "\n" .. string.format(lui.CURRENT_SAVEGAME_VERSION, tostring(Game.CurrentSaveVersion()))
		for _, param in ipairs(Layout.UpdateOrder) do
			local paramErrorString = param:fromSaveGame(saveGame)
			-- could not be restored - we will give the
			-- player the opportunity to edit it himself
			if paramErrorString then
				table.insert(paramErrors, { name = param.name, string = paramErrorString })
				param.lock = false
			else
				param.lock = true
			end
		end
		updateParams()
		for _, param in ipairs(Layout.UpdateOrder) do
			if not param:isValid() and not hasNameInArray(param, paramErrors)  then
				table.insert(paramErrors, { name = param.name, string = lui.RECOVERED_BUT_NOT_VALID })
				param.lock = false
			end
		end
		if #paramErrors > 0 then
			table.sort(paramErrors, function(x1, x2) return x1.name < x2.name end)
			report = report .. "\n\n" .. lui.THERE_WERE_ERRORS_IN_RECOVERY .. "\n"
			for _, err in ipairs(paramErrors) do
				report = report .. "\n" .. err.name .. ": " .. err.string
			end
			report = report .. "\n\n" .. lui.UNSUCCESSFULLY_RECOVERED_PARAMETERS_ARE_NOW_UNLOCKED_PLEASE_SET_THEM_MANUALLY
		else
			report = report .. "\n\n" .. lui.ALL_PARAMETERS_WERE_RECOVERED_SUCCESSFULLY
		end
		return true, report
	else
		assert(type(saveGame) == 'string')
		local errorString = saveGame
		return false, lui.AN_ERROR_HAS_OCCURRED .. '\n' .. errorString
	end
end

function NewGameWindow:buildProfileCombo()
	allegianceCombo.items = {}
	for _, a in ipairs(ALLEGIANCES) do
		table.insert(allegianceCombo.items, a.name)
	end

	roleCombo.items = {}
	roleCombo.actions = {}
	for _, r in ipairs(CAREER_ROLES) do
		table.insert(roleCombo.items, r.name)
	end
	table.insert(roleCombo.items, "Custom Start (Independent Budget)")
	roleCombo.actions[#roleCombo.items] = 'CUSTOM_BUDGET'
	if self.debugMode then
		table.insert(roleCombo.items, "Custom Start (Unlocked)")
		roleCombo.actions[#roleCombo.items] = 'DO_UNLOCK'
	end
end

function NewGameWindow:setDebugMode(value)
	self.debugMode = value
	self:buildProfileCombo()
end

NewGameWindow:setDebugMode(false)

local firstOpen = true
function NewGameWindow:open()
	if (firstOpen or not self.debugMode) and self.mode ~= 'RECOVER' then
		firstOpen = false
		startMode = "PREDEFINED"
		ShipParam.Equip.budgetTotal = false
		ShipParam.Type:setAllowedShips(nil, false)
		allegianceCombo.selected = 0
		roleCombo.selected = 0
		setStartVariant(composeStartVariant(1, 1))
		updateParams()
	end
	if self.debugMode then
		roleCombo.selected = #roleCombo.items - 1
		unlockAll()
	end
	ModalWindow.open(self)
end

return NewGameWindow
