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

-- Canonical commercial corporations for general un-roled business clients
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
		svg = "corp_logistics",
		org = "ASTRA INTERSTELLAR LOGISTICS",
		border = Color(86, 204, 242, 205),
	},
}

local ROLE_PROFILES = {
	pilots_federation = {
		svg = "pilots_federation",
		org = "PILOTS FEDERATION",
		border = Color(216, 166, 56, 215),
	},
	civilian = {
		svg = "civilian_citizen",
		org = "PRIVATE CITIZEN",
		border = Color(165, 190, 220, 210),
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
	starport = {
		svg = "authority_starport",
		org = "STARPORT AUTHORITY",
		border = Color(92, 225, 230, 215),
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
	logistics = {
		svg = "corp_logistics",
		org = "ASTRA INTERSTELLAR LOGISTICS",
		border = Color(86, 204, 242, 215),
	},
	broker = {
		svg = "corp_opli",
		org = "COMMERCIAL EXCHANGE",
		border = Color(0, 210, 255, 215),
	},
	haber = {
		svg = "faction_haber",
		org = "HABER CORPORATION",
		border = Color(255, 71, 87, 215),
	},
	opli = {
		svg = "corp_opli",
		org = "OMNI-PRODUCT LATTICE (OPLI)",
		border = Color(0, 210, 255, 215),
	},
	kaluri = {
		svg = "corp_kaluri",
		org = "KALURI HEAVY INDUSTRIES",
		border = Color(56, 239, 125, 215),
	},
	mandarava = {
		svg = "corp_mandarava",
		org = "MANDARAVA-CSEPEL",
		border = Color(253, 203, 110, 215),
	},
	albr = {
		svg = "corp_albr",
		org = "ALBR AEROSPACE",
		border = Color(255, 121, 63, 215),
	},
	auronox = {
		svg = "corp_auronox",
		org = "AURONOX CORPORATION",
		border = Color(243, 156, 18, 215),
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
	journalist = {
		svg = "corp_news",
		org = "INDEPENDENT PRESS",
		border = Color(72, 219, 251, 215),
	},
	solfed_intel = {
		svg = "faction_solfed",
		org = "SOLFED NAVAL INTELLIGENCE",
		border = Color(78, 164, 255, 215),
	},
}

local TITLE_TEXT_COLOR = Color(185, 205, 230, 240)
local ORG_BANNER_BG = Color(6, 10, 16, 225)
local CARD_BG = Color(9, 11, 24, 255)

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
			orgFont = style.orgFont or nil,
			nameFont = style.nameFont or orbiteer.heading,
			titleFont = style.titleFont or pionillium.details,
		}
	}

	local hasSubtitle = (character.title ~= nil) or true
	piguiFace.style.charInfoHeight = math.ceil(
		piguiFace.style.nameFont.size + (hasSubtitle and (piguiFace.style.titleFont.size + 6) or 0)
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

	-- 2. Explicit faction or role tag on Character (set by BBS / comms modules)
	local explicitFactionProfile = char.factionName and resolveSystemFactionProfile({ name = char.factionName }) or factionProfile
	if char.role == "police" then
		local policeOrg = char.org and string.upper(char.org)
			or ((sysFaction and sysFaction.policeName and #sysFaction.policeName > 0) and string.upper(sysFaction.policeName))
			or "SYSTEM CONSTABULARY"
		return {
			svg = "authority_police",
			org = policeOrg,
			border = Color(212, 160, 36, 215),
		}
	elseif char.role == "military" then
		local milOrg = char.org and string.upper(char.org)
			or ((sysFaction and sysFaction.militaryName and #sysFaction.militaryName > 0) and string.upper(sysFaction.militaryName))
			or (explicitFactionProfile and explicitFactionProfile.org or "SECTOR DEFENSE COMMAND")
		return {
			svg = explicitFactionProfile and explicitFactionProfile.svg or "corp_mercenary",
			org = milOrg,
			border = explicitFactionProfile and explicitFactionProfile.border or Color(255, 82, 82, 215),
		}
	elseif char.role == "government" then
		if explicitFactionProfile then
			return {
				svg = explicitFactionProfile.svg,
				org = char.org and string.upper(char.org) or explicitFactionProfile.org,
				border = explicitFactionProfile.border,
			}
		end
		return {
			svg = "authority_starport",
			org = char.org and string.upper(char.org) or "SYSTEM ADMINISTRATION",
			border = Color(92, 225, 230, 215),
		}
	elseif char.role and ROLE_PROFILES[char.role] then
		local p = ROLE_PROFILES[char.role]
		if char.org then
			return { svg = p.svg, org = string.upper(char.org), border = p.border }
		end
		return p
	elseif char.factionName and explicitFactionProfile then
		return {
			svg = explicitFactionProfile.svg,
			org = char.org and string.upper(char.org) or explicitFactionProfile.org,
			border = explicitFactionProfile.border,
		}
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

	-- 3.5 Universal Cartographics / Planetary Survey
	if string.find(titleUpper, "CARTOGRAPH") or string.find(titleUpper, "SURVEY") or char.role == "cartography" then
		return {
			svg = "corp_science",
			org = "UNIVERSAL CARTOGRAPHICS",
			border = Color(72, 219, 251, 215),
		}
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
	elseif string.find(titleUpper, "CREW") or string.find(titleUpper, "PILOT") or string.find(titleUpper, "NAVIGATOR") or string.find(titleUpper, "CAPTAIN") then
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

local function wrapOrgLines(text, maxWidth)
	if ui.calcTextSize(text).x <= maxWidth then
		return { text }
	end
	local lines = {}
	local current = ""
	for word in string.gmatch(text, "%S+") do
		local candidate = (current == "") and word or (current .. " " .. word)
		if current ~= "" and ui.calcTextSize(candidate).x > maxWidth then
			lines[#lines + 1] = current
			current = word
		else
			current = candidate
		end
	end
	if current ~= "" then
		lines[#lines + 1] = current
	end
	return lines
end

function PiGuiFace:renderFaceDisplay ()
	local lastPos = ui.getCursorPos()
	local screenPos = ui.getCursorScreenPos()
	local avail = ui.getContentRegion()
	local cardW, cardH
	if self.style.size then
		cardW = math.max(48, avail.x > 48 and math.min(self.style.size.x, avail.x) or self.style.size.x)
		cardH = math.max(48, self.style.size.y)
	else
		local s = math.max(48, math.min(avail.x, avail.y))
		cardW, cardH = s, s
	end

	local profile = self:resolveLogoProfile()
	local tex = getLogoTexture(profile.svg)

	-- Reserve space in ImGui layout
	ui.dummy(Vector2(cardW, cardH))

	local tl = screenPos
	local br = screenPos + Vector2(cardW, cardH)

	-- Card background matching SVG radial outer edge
	ui.addRectFilled(tl, br, CARD_BG, 3, ui.RoundCornersAll)

	-- Top organization header strip on cards >= 110px (never overlaps the logo)
	local bannerH = 0
	if cardW >= 110 and profile.org then
		local padX = 8
		local padY = 6
		local maxTextW = math.max(20, cardW - padX * 2)
		local orgFont = self.style.orgFont or (cardW >= 220 and pionillium.medium or pionillium.details)
		if orgFont.size > pionillium.details.size then
			ui.withFont(orgFont.name, orgFont.size, function()
				if ui.calcTextSize(profile.org).x > maxTextW then
					orgFont = pionillium.details
				end
			end)
		end

		ui.withFont(orgFont.name, orgFont.size, function()
			local lines = wrapOrgLines(profile.org, maxTextW)
			local lineH = ui.getTextLineHeight()
			bannerH = math.ceil(#lines * lineH + padY * 2)
			ui.addRectFilled(tl, tl + Vector2(cardW, bannerH), ORG_BANNER_BG, 3, ui.RoundCornersTop)
			for i, line in ipairs(lines) do
				local textSize = ui.calcTextSize(line)
				local textPos = tl + Vector2(math.max(padX, (cardW - textSize.x) * 0.5), padY + (i - 1) * lineH)
				ui.addText(textPos, profile.border, line)
			end
		end)
	end

	-- Character / Contact Nameplate Banner at bottom (never overlaps the logo)
	local infoHeight = (self.style.showCharInfo and cardW >= 110) and math.min(self.style.charInfoHeight, cardH * 0.34) or 0

	-- Center 1:1 SVG logo inside the open middle region between header and footer
	local midH = math.max(16, cardH - bannerH - infoHeight)
	local innerPad = (cardW >= 110) and math.max(4, math.floor(cardW * 0.03)) or 0
	local logoSize = math.max(16, math.min(cardW - innerPad * 2, midH - innerPad * 2))
	local logoTL = Vector2(
		tl.x + (cardW - logoSize) * 0.5,
		tl.y + bannerH + (midH - logoSize) * 0.5
	)
	ui.addImage(tex, logoTL, logoTL + Vector2(logoSize, logoSize), Vector2(0.0, 0.0), Vector2(1.0, 1.0), colors.white)

	if self.style.showCharInfo and infoHeight > 0 then
		ui.setCursorPos(lastPos + Vector2(0.0, cardH - infoHeight))
		local styles = {WindowPadding = self.style.charInfoPadding, ItemSpacing = Vector2(4, 2)}

		ui.withStyleColorsAndVars({ChildBg = self.style.charInfoBgColor}, styles, function ()
			ui.child("PlayerInfoDetails", Vector2(cardW, infoHeight), charInfoFlags, useWindowPadding, function ()
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
