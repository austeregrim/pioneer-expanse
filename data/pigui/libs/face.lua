-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Game = require 'Game'
local Rand = require 'Rand'
local Character = require 'Character'

local l = require 'Lang'.GetResource("ui-core")
local ui = require 'pigui'
local Vector2 = _G.Vector2
local Color = _G.Color

local colors = ui.theme.colors
local icons = ui.theme.icons
local orbiteer = ui.fonts.orbiteer
local pionillium = ui.fonts.pionillium
local noSavedSettings = ui.WindowFlags {"NoSavedSettings"}
local useWindowPadding = ui.ChildFlags { 'AlwaysUseWindowPadding' }
local charInfoFlags = ui.WindowFlags { "NoScrollbar", "NoSavedSettings", "NoScrollWithMouse"}

local ensureCharacter = function (character)
	if not (character and (type(character)=='table') and getmetatable(character) and (getmetatable(character).class == 'Character'))
	then
		return Character.New(character)
	end

	return character
end

local function rerollFaceDesc(oldDesc, rand)
	rand = rand or Engine.rand
	return {
		FEATURE_SPECIES = rand:Integer() % 2^31,
		FEATURE_RACE = rand:Integer() % 2^31,
		FEATURE_GENDER = oldDesc and oldDesc.FEATURE_GENDER or 0,
		FEATURE_HEAD = rand:Integer() % 2^31,
		FEATURE_EYES = rand:Integer() % 2^31,
		FEATURE_NOSE = rand:Integer() % 2^31,
		FEATURE_MOUTH = rand:Integer() % 2^31,
		FEATURE_HAIRSTYLE = rand:Integer() % 2^31,
		FEATURE_ACCESSORIES = rand:Integer() % 4 == 0 and rand:Integer() % 2^31 or 0,
		FEATURE_CLOTHES = rand:Integer() % 2^31,
		FEATURE_ARMOUR = oldDesc and oldDesc.FEATURE_ARMOUR or 0,
	}
end

-- Lazy-loaded high-resolution SVG corporate, faction, and authority logos
local logoTextures = {}
local function getLogoTexture(svgName)
	if not logoTextures[svgName] then
		logoTextures[svgName] = ui.loadTextureFromSVG(
			ui.dataDirPath({"icons", "logos", svgName .. ".svg"}),
			512, 512
		)
	end
	return logoTextures[svgName]
end

local FACTION_LOGOS = {
	["Solar Federation"] = {
		svg = "faction_solfed",
		org = "SOLAR FEDERATION",
		border = Color(78, 164, 255, 215),
	},
	["Commonwealth of Independent Worlds"] = {
		svg = "faction_commonwealth",
		org = "COMMONWEALTH OF WORLDS",
		border = Color(70, 224, 154, 215),
	},
	["Haber Corporation"] = {
		svg = "faction_haber",
		org = "HABER CORPORATION",
		border = Color(255, 71, 87, 215),
	},
	["Independent"] = {
		svg = "faction_independent",
		org = "INDEPENDENT FRONTIER",
		border = Color(255, 209, 102, 215),
	},
	["Druello Pirates"] = {
		svg = "faction_pirate",
		org = "DRUELLO PIRATES",
		border = Color(255, 77, 77, 215),
	},
}

-- Resolve any of the 104 factions in data/factions/ (4 core superpowers + 100 outer-rim factions)
local function resolveSystemFactionProfile(faction)
	if not faction or not faction.name then return nil end
	if FACTION_LOGOS[faction.name] then
		return FACTION_LOGOS[faction.name]
	end

	local nameUpper = string.upper(faction.name)
	local c = faction.colour
	local borderCol = c
		and Color(math.min(255, math.floor(c.r * 255)), math.min(255, math.floor(c.g * 255)), math.min(255, math.floor(c.b * 255)), 215)
		or Color(200, 210, 225, 210)

	local svg = "faction_independent"
	if string.find(nameUpper, "PIRATE") or string.find(nameUpper, "HORDE") or string.find(nameUpper, "BLOOD") then
		svg = "faction_pirate"
	elseif string.find(nameUpper, "EMPIRE") or string.find(nameUpper, "KINGDOM") then
		svg = "faction_empire"
	elseif string.find(nameUpper, "COMMONWEALTH") or string.find(nameUpper, "REPUBLIC") or string.find(nameUpper, "UNION") or string.find(nameUpper, "COUNCIL") then
		svg = "faction_commonwealth"
	elseif string.find(nameUpper, "ALLIANCE") or string.find(nameUpper, "LEAGUE") or string.find(nameUpper, "FEDERATION") then
		svg = "faction_solfed"
	end

	return {
		svg = svg,
		org = nameUpper,
		border = borderCol,
	}
end

-- Canonical Pioneer megacorporations & commercial/tactical guilds for general mission clients
local CORP_POOL = {
	{
		svg = "corp_kaluri",
		org = "KALURI HEAVY INDUSTRIES",
		border = Color(56, 239, 125, 205),
	},
	{
		svg = "corp_mandarava",
		org = "MANDARAVA-CSEPEL",
		border = Color(253, 203, 110, 205),
	},
	{
		svg = "corp_opli",
		org = "OMNI-PRODUCT LATTICE (OPLI)",
		border = Color(0, 210, 255, 205),
	},
	{
		svg = "corp_auronox",
		org = "AURONOX CORPORATION",
		border = Color(243, 156, 18, 205),
	},
	{
		svg = "corp_albr",
		org = "ALBR AEROSPACE",
		border = Color(255, 121, 63, 205),
	},
	{
		svg = "faction_haber",
		org = "HABER CORPORATION",
		border = Color(255, 71, 87, 205),
	},
	{
		svg = "corp_logistics",
		org = "ASTRA INTERSTELLAR LOGISTICS",
		border = Color(86, 204, 242, 205),
	},
	{
		svg = "corp_mining",
		org = "DEEP CORE EXTRACTION GUILD",
		border = Color(246, 185, 59, 205),
	},
	{
		svg = "corp_mercenary",
		org = "VANGUARD TACTICAL SECURITY",
		border = Color(255, 82, 82, 205),
	},
	{
		svg = "corp_science",
		org = "UNIVERSAL CARTOGRAPHICS",
		border = Color(100, 255, 218, 205),
	},
	{
		svg = "corp_syndicate",
		org = "OUTER RIM SYNDICATE",
		border = Color(224, 86, 253, 205),
	},
	{
		svg = "authority_starport",
		org = "ORBITAL PORT AUTHORITY",
		border = Color(92, 225, 230, 205),
	},
}

local ROLE_PROFILES = {
	pilots_federation = {
		svg = "pilots_federation",
		org = "PILOTS FEDERATION",
		border = Color(216, 166, 56, 215),
	},
	crew = {
		svg = "pilots_federation",
		org = "PILOTS FEDERATION — CREW",
		border = Color(216, 166, 56, 215),
	},
	engineering = {
		svg = "authority_engineering",
		org = "ORBITAL ENGINEERING CORPS",
		border = Color(255, 159, 67, 215),
	},
	rescue = {
		svg = "corp_rescue",
		org = "INTERSTELLAR SEARCH & RESCUE",
		border = Color(255, 107, 107, 215),
	},
	science = {
		svg = "corp_science",
		org = "UNIVERSAL CARTOGRAPHICS",
		border = Color(100, 255, 218, 215),
	},
	syndicate = {
		svg = "corp_syndicate",
		org = "COVERT OPERATIONS SYNDICATE",
		border = Color(224, 86, 253, 215),
	},
	mercenary = {
		svg = "corp_mercenary",
		org = "VANGUARD TACTICAL SECURITY",
		border = Color(255, 82, 82, 215),
	},
	mining = {
		svg = "corp_mining",
		org = "DEEP CORE EXTRACTION GUILD",
		border = Color(246, 185, 59, 215),
	},
	fuel_coop = {
		svg = "corp_fuel",
		org = "PILOTS' FUEL CO-OPERATIVE",
		border = Color(0, 242, 254, 215),
	},
	news = {
		svg = "corp_news",
		org = "GALACTIC NEWS NETWORK",
		border = Color(72, 219, 251, 215),
	},
	solfed_intel = {
		svg = "faction_solfed",
		org = "SOLFED NAVAL INTELLIGENCE",
		border = Color(78, 164, 255, 215),
	},
}

local TITLE_TEXT_COLOR = Color(185, 205, 230, 240)
local ORG_BANNER_BG = Color(6, 10, 16, 215)

local PiGuiFace = {}

function PiGuiFace.New (character, style, drawButtons)
	character = ensureCharacter(character)
	style = style or {}
	character.faceDescription = character.faceDescription or rerollFaceDesc({
		FEATURE_GENDER = character.female and 1 or 0,
		FEATURE_ARMOUR = character.armour and 1 or 0,
	}, Rand.New(tostring(character.seed) .. "-face"))

	local piguiFace = {
		character = character,
		drawButtons = false, -- Facegen customization sliders disabled
		style = {
			size = style.size or nil,
			itemSpacing = style.itemSpacing or ui.rescaleUI(Vector2(5, 8), Vector2(1920, 1080)),
			showCharInfo = style.showCharInfo == nil and true or style.showCharInfo,
			charInfoPadding = style.charInfoPadding or ui.rescaleUI(Vector2(10, 6), Vector2(1920, 1080)),
			charInfoBgColor = style.bgColor or Color(8, 11, 16, 230),
			nameFont = style.nameFont or orbiteer.heading,
			titleFont = style.titleFont or pionillium.details,
		}
	}

	piguiFace.style.charInfoHeight = math.ceil(
		piguiFace.style.nameFont.size + (character.title and (piguiFace.style.titleFont.size + 4) or 0)
		+ piguiFace.style.charInfoPadding.y * 2
	)

	setmetatable(piguiFace, {
		__index = PiGuiFace,
		class = "UI.PiGuiFace",
	})

	return piguiFace
end

local font = ui.fonts.pionillium.medium
local iconSize = ui.theme.styles.MainButtonSize
local buttonSize = iconSize
local facegenSpacing = Vector2(font.size * 0.3, font.size * 0.3)
local facegenSize = Vector2(0, (buttonSize.y + facegenSpacing.y) * 5 - facegenSpacing.y)

function PiGuiFace:renderFaceGenButtons()
	-- Disabled: procedural facegen sliders removed
end

function PiGuiFace:render()
	self:renderFaceDisplay()
end

function PiGuiFace.getFaceGenButtonsSize()
	return facegenSize
end

function PiGuiFace:resolveLogoProfile()
	local char = self.character
	local sysFaction = (Game.system and Game.system.faction) and Game.system.faction or nil
	local factionProfile = resolveSystemFactionProfile(sysFaction)

	-- 1. Player Commander always displays the Pilots Federation crest
	if char.player then
		return ROLE_PROFILES.pilots_federation
	end

	-- 2. Explicit role tag on Character (set by BBS / comms modules)
	if char.role and ROLE_PROFILES[char.role] then
		local p = ROLE_PROFILES[char.role]
		if char.org then
			return { svg = p.svg, org = string.upper(char.org), border = p.border }
		end
		return p
	end

	local titleUpper = string.upper(char.title or "")

	-- 3. Fuel Clubs (Federal, Commonwealth, Haber, Independent Co-op)
	if string.find(titleUpper, "FUEL") or string.find(titleUpper, "PROPELLANT") then
		if string.find(titleUpper, "FEDERAL") then
			return { svg = "faction_solfed", org = "FEDERAL FUEL FOUNDATION", border = FACTION_LOGOS["Solar Federation"].border }
		elseif string.find(titleUpper, "COMMONWEALTH") then
			return { svg = "faction_commonwealth", org = "COMMONWEALTH FUEL UNION", border = FACTION_LOGOS["Commonwealth of Independent Worlds"].border }
		elseif string.find(titleUpper, "HABER") then
			return { svg = "faction_haber", org = "HABER PROPELLANT DIVISION", border = FACTION_LOGOS["Haber Corporation"].border }
		else
			return ROLE_PROFILES.fuel_coop
		end
	end

	-- 4. System Law Enforcement / Police Constable / Detective
	if string.find(titleUpper, "POLICE") or string.find(titleUpper, "CONSTABLE") or string.find(titleUpper, "LAW") or string.find(titleUpper, "DETECTIVE") then
		local policeOrg = (sysFaction and sysFaction.policeName and #sysFaction.policeName > 0)
			and string.upper(sysFaction.policeName)
			or "SYSTEM CONSTABULARY"
		return {
			svg = "authority_police",
			org = policeOrg,
			border = Color(212, 160, 36, 215),
		}
	end

	-- 5. Military / Naval / Fleet Intelligence Agent
	if string.find(titleUpper, "MILITARY") or string.find(titleUpper, "NAVAL") or string.find(titleUpper, "FLEET") or string.find(titleUpper, "AGENT") then
		local milOrg = (sysFaction and sysFaction.militaryName and #sysFaction.militaryName > 0)
			and string.upper(sysFaction.militaryName)
			or (factionProfile and factionProfile.org or "SECTOR DEFENSE COMMAND")
		return {
			svg = factionProfile and factionProfile.svg or "corp_mercenary",
			org = milOrg,
			border = factionProfile and factionProfile.border or Color(255, 82, 82, 215),
		}
	end

	-- 6. Shipyard, Hyperdrive Servicing & Orbital Engineering
	if string.find(titleUpper, "MECHANIC") or string.find(titleUpper, "REPAIR") or string.find(titleUpper, "ENGINEER") or string.find(titleUpper, "SERVIC") or string.find(titleUpper, "MAINTENANCE") or string.find(titleUpper, "ENGINES") then
		return ROLE_PROFILES.engineering
	end

	-- 7. Search & Rescue / Emergency Control
	if string.find(titleUpper, "RESCUE") or string.find(titleUpper, "EMERGENCY") then
		return ROLE_PROFILES.rescue
	end

	-- 8. Station Manager / Harbour Control (uses governing Faction crest for all 104 factions, or Starport Authority)
	if string.find(titleUpper, "STATION") or string.find(titleUpper, "HARBOUR") or string.find(titleUpper, "CONTROL") or string.find(titleUpper, "MANAGER") then
		if factionProfile then
			return factionProfile
		end
		return {
			svg = "authority_starport",
			org = "STARPORT AUTHORITY",
			border = Color(92, 225, 230, 215),
		}
	end

	-- 9. Commander / Ship Crew
	if string.find(titleUpper, "COMMANDER") then
		return ROLE_PROFILES.pilots_federation
	elseif string.find(titleUpper, "CREW") or string.find(titleUpper, "PILOT") or string.find(titleUpper, "NAVIGATOR") then
		return ROLE_PROFILES.crew
	end

	-- 10. Deterministic Corporate / Manufacturer / Syndicate / Faction emblem for BBS clients and contacts
	local seedVal = tonumber(char.seed) or 0
	if seedVal == 0 and char.name then
		for i = 1, #char.name do
			seedVal = (seedVal * 31 + string.byte(char.name, i)) % 1000003
		end
	end
	local absSeed = math.abs(math.floor(seedVal))

	-- Include governing faction contracts alongside the 12 canonical corporations & guilds
	if factionProfile and (absSeed % 6 == 0) then
		return factionProfile
	end

	local idx = (absSeed % #CORP_POOL) + 1
	return CORP_POOL[idx]
end

function PiGuiFace:renderFaceDisplay ()
	local lastPos = ui.getCursorPos()
	local screenPos = ui.getCursorScreenPos()
	local region = self.style.size or ui.getContentRegion()
	local size = math.max(48, math.min(region.x, region.y))

	local profile = self:resolveLogoProfile()
	local tex = getLogoTexture(profile.svg)

	-- Reserve space in ImGui layout
	ui.dummy(Vector2(size, size))

	local tl = screenPos
	local br = screenPos + Vector2(size, size)

	-- Render high-resolution SVG corporate / faction logo
	ui.addImage(tex, tl, br, Vector2(0.0, 0.0), Vector2(1.0, 1.0), colors.white)

	-- Top organization header strip on cards >= 110px
	if size >= 110 and profile.org then
		local orgFont = pionillium.tiny
		local bannerH = math.ceil(orgFont.size + 8)
		ui.addRectFilled(tl, tl + Vector2(size, bannerH), ORG_BANNER_BG, 3, ui.RoundCornersTop)
		ui.withFont(orgFont.name, orgFont.size, function()
			local textSize = ui.calcTextSize(profile.org)
			local textPos = tl + Vector2(math.max(4, (size - textSize.x) * 0.5), (bannerH - textSize.y) * 0.5)
			ui.addText(textPos, profile.border, profile.org)
		end)
	end

	-- Character / Contact Nameplate Banner at bottom
	local infoHeight = (self.style.showCharInfo and size >= 110) and math.min(self.style.charInfoHeight, size * 0.28) or 0
	if self.style.showCharInfo and infoHeight > 0 then
		ui.setCursorPos(lastPos + Vector2(0.0, size - infoHeight))
		local styles = {WindowPadding = self.style.charInfoPadding, ItemSpacing = Vector2(4, 2)}

		ui.withStyleColorsAndVars({ChildBg = self.style.charInfoBgColor}, styles, function ()
			ui.child("PlayerInfoDetails", Vector2(size, infoHeight), charInfoFlags, useWindowPadding, function ()
				ui.withFont(self.style.nameFont.name, self.style.nameFont.size, function()
					ui.textColored(colors.white, self.character.name)
				end)

				local subtitle = self.character.title or profile.org
				if subtitle then
					ui.withFont(self.style.titleFont.name, self.style.titleFont.size, function()
						ui.textColored(TITLE_TEXT_COLOR, string.upper(subtitle))
					end)
				end
			end)
		end)
	end

	-- Crisp outer border tinted to the faction/corporate emblem
	ui.addRect(tl, br, profile.border, 3, ui.RoundCornersAll, 1.5)
end

return PiGuiFace
