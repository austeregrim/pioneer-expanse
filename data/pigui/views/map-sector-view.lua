-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Event = require 'Event'
local Format = require 'Format'
local SystemPath = require 'SystemPath'
local ShipDef = require 'ShipDef'
local hyperJumpPlanner = require 'pigui.modules.hyperjump-planner'
local systemEconView = require 'pigui.modules.system-econ-view'.New()
local PlayerState    = require 'PlayerState'
local FactionStanding = require 'FactionStanding'

local BookmarkView = require 'pigui.modules.sidebar.bookmarks'

local Lang = require 'Lang'
local lc = Lang.GetResource("core");
local lui = Lang.GetResource("ui-core");

local Vector2 = _G.Vector2
local Color = _G.Color

local ui = require 'pigui'
local Sidebar = require 'pigui.libs.sidebar'

local Serializer = require 'Serializer'

local player = nil ---@type Player

local colors = ui.theme.colors
local icons = ui.theme.icons

local orbiteer = ui.fonts.orbiteer
local pionillium = ui.fonts.pionillium

local font = ui.fonts.pionillium.medlarge
local smallfont = ui.fonts.pionillium.medium

local sidebarStyle = require 'pigui.styles'.sidebar

local frameStyle = ui.Style:clone {
	colors = {
		Header = colors.FrameBg,
		HeaderActive = colors.FrameBgActive,
		HeaderHovered = colors.FrameBgHovered,
	},
	vars = {}
}

local childFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders', 'AutoResizeY' }

-- all colors, used in this module
local svColor = {
	LABEL_HIGHLIGHT = colors.sectorMapLabelHighlight,
	LABEL_SHADE = colors.sectorMapLabelShade,
	FONT = colors.font,
	UNKNOWN = colors.unknown,
}

local settings =
{
	draw_vertical_lines=false,
	draw_out_range_labels=false,
	draw_uninhabited_labels=true,
	draw_uncharted_overlay=false,
	draw_conflict_overlay=false,
	visible_sphere_scale=0.75,
	automatic_system_selection=true
}

local function syncConflictIntel(map)
	if not map then return end
	map:ClearConflictSystems()

	local categoryTypeMap = {
		FRONTLINE = 1,
		HUMANITARIAN = 2,
		MARKET = 3,
		POLITICS = 4,
	}

	-- 1. Direct active crisis nodes from MacroGalaxyEngine
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	if okMacro and MacroEngine and MacroEngine.GetActiveCrises then
		for _, c in ipairs(MacroEngine.GetActiveCrises()) do
			if c.system and c.system ~= "" then
				local t = categoryTypeMap[c.category] or 4
				map:SetConflictSystem(c.system, t)
			end
		end
	end

	-- 2. InterCast wire dispatches
	local okInter, InterCast = pcall(require, 'modules.InterCast.InterCast')
	if okInter and InterCast then
		local articles = InterCast.GetArticles("ALL")
		if articles then
			for i = #articles, 1, -1 do
				local art = articles[i]
				if art.system and art.system ~= "" then
					local t = categoryTypeMap[art.category] or 4
					map:SetConflictSystem(art.system, t)
				end
			end
		end
	end
end

local loaded_data = nil
local ui_visible = true

local leftSidebar = Sidebar.New("SectorMapLeft")
local rightSidebar = Sidebar.New("SectorMapRight", "right")

local function textIcon(icon, tooltip)
	ui.text(ui.get_icon_glyph(icon))
	if tooltip then ui.setItemTooltip(tooltip) end
	ui.sameLine()
end

local function bannerText(pos, text, color)
	local s = ui.calcTextSize(text)

	local padding = ui.theme.styles.ButtonPadding
	s.y = s.y + padding.y * 2
	local max = pos + Vector2(s.x + s.y * 2, s.y)

	local x1 = Vector2(pos.x + s.y, pos.y + s.y)
	local x2 = Vector2(pos.x + s.y, pos.y)
	local x3 = Vector2(pos.x + s.y + s.x, pos.y + s.y)
	local x4 = Vector2(pos.x + s.y + s.x, pos.y)

	ui.addRectFaded(pos, x1, color, 0.0, ui.RoundCornersLeft)
	ui.addRectFilled(x2, x3, color, 0.0, ui.RoundCornersNone)
	ui.addRectFaded(x4, max, color, 0.0, ui.RoundCornersRight)

	ui.setCursorScreenPos(Vector2(x2.x, x2.y + padding.y))
	ui.text(text)
	ui.sameLine(0, 0)
	ui.dummy(Vector2(s.y, s.y))
end

local sectorView
if Game then
	sectorView = Game.sectorView
	hyperJumpPlanner.setSectorView(sectorView)
end -- for hot-reload

local hyperspaceDetailsCache = {}

local onGameStart = function ()
	-- connect to class SectorView
	sectorView = Game.sectorView
	-- connect hyper jump planner to class SectorView
	hyperJumpPlanner.setSectorView(sectorView)
	-- reset hyperspace details cache on new game
	hyperspaceDetailsCache = {}

	-- apply any data loaded earlier
	if loaded_data then
		if loaded_data.jump_targets then
			for _, target in pairs( loaded_data.jump_targets) do
				sectorView:AddToRoute(target)
			end
		end
		if loaded_data.settings then
			settings = loaded_data.settings
		end
		loaded_data = nil
	end

	-- update visibility states
	sectorView:SetAutomaticSystemSelection(settings.automatic_system_selection)
	sectorView:SetDrawOutRangeLabels(settings.draw_out_range_labels)
	sectorView:GetMap():SetDrawUninhabitedLabels(settings.draw_uninhabited_labels)
	sectorView:GetMap():SetDrawVerticalLines(settings.draw_vertical_lines)
	sectorView:GetMap():SetDrawUnchartedOverlay(settings.draw_uncharted_overlay or false)
	sectorView:GetMap():SetDrawConflictOverlay(settings.draw_conflict_overlay or false)
	if settings.draw_conflict_overlay then
		syncConflictIntel(sectorView:GetMap())
	end
	sectorView:GetMap():SetVisibleSphereScale(settings.visible_sphere_scale or 0.75)
	sectorView:GetMap():SetLabelParams("sector-map", font.size, 2.0, svColor.LABEL_HIGHLIGHT, svColor.LABEL_SHADE)

	-- allow hyperjump planner to register its events:
	hyperJumpPlanner.onGameStart()

	-- Reset hyperspace cache when ship equipment changes
	Game.player:GetComponent('EquipSet'):AddListener(function (op, equip, slot)
		hyperspaceDetailsCache = {}
	end)
end

local function getHyperspaceDetails(path)
	local p = path.sectorX .. "/" .. path.sectorY .. "/" .. path.sectorZ .. "/" .. path.systemIndex
	local it = hyperspaceDetailsCache[p]
	if not it then
		local pObj = player or Game.player
		local jumpStatus, distance, fuelRequired, duration
		if pObj then
			jumpStatus, distance, fuelRequired, duration = pObj:GetHyperspaceDetails(path)
		else
			jumpStatus = "NO_DRIVE"
			distance = 0
			fuelRequired = 0
			duration = 0
		end
		it = {
			jumpStatus = jumpStatus or "OUT_OF_RANGE",
			distance = distance or 0,
			fuelRequired = fuelRequired or 0,
			duration = duration or 0,
			path = path
		}
		hyperspaceDetailsCache[p] = it
	end
	return it
end

local statusIcons = {
	OK = { icon = icons.route_destination },
	DRIVE_ACTIVE = { icon = icons.ship },
	CURRENT_SYSTEM = { icon = icons.navtarget },
	INSUFFICIENT_FUEL = { icon = icons.fuel },
	OUT_OF_RANGE = { icon = icons.alert_generic },
	NO_DRIVE = { icon = icons.hyperspace_off },
	SAFETY_LOCKOUT = { icon = icons.alert_generic },
	OBSCURED = { icon = icons.alert_generic }
}

local function draw_jump_status(item)
	local statusEntry = statusIcons[item.jumpStatus] or statusIcons.OUT_OF_RANGE
	local statusText = lui[item.jumpStatus] or item.jumpStatus or ""
	textIcon(statusEntry.icon, statusText)
	ui.text(string.format("%.2f%s  %s %.1f%s  %s %s",
		item.distance or 0, lc.UNIT_LY or "ly",
		ui.get_icon_glyph(icons.fuel), item.fuelRequired or 0, lc.UNIT_TONNES or "t",
		ui.get_icon_glyph(icons.clock), ui.Format.Duration(item.duration or 0, 2)))
end

local function calc_star_dist(star)
	local dist = 0.0
	while star do
		dist = dist + ((star.apoapsis or 0) + (star.periapsis or 0)) / 2
		star = star.parent
	end
	return dist
end

local function drawSearchResults(systempaths)
	local data = {}
	for _,path in pairs(systempaths or {}) do table.insert(data, getHyperspaceDetails(path)) end

	ui.child("search_results", function ()
		table.sort(data, function(a,b)
			return (a.distance or 0) < (b.distance or 0)
		end)
		for i, item in pairs(data) do
			local system = item.path:GetStarSystem()
			if system then
				if ui.selectable(system.name .. "##" .. i, false, {}) then
					sectorView:SwitchToPath(item.path)
				end
				ui.sameLine()
				ui.withFont(smallfont, function() draw_jump_status(item) end)
			end
		end
	end)
end

---@param jumpables SystemBody[]
---@param path SystemPath
local function drawJumpableList(jumpables, path)
	if ui.beginTable("#Jumpables", 3) then
		ui.tableSetupColumn("Name", "WidthStretch")
		ui.tableSetupColumn("Distance", "WidthFixed")
		ui.tableSetupColumn("Select", "WidthFixed")

		---@type SystemPath[]
		local routes = sectorView:GetRoute()
		local index = nil

		for i, route in ipairs(routes) do
			if route:IsSameSystem(path) then
				index = i
				break
			end
		end

		for i, star in ipairs(jumpables) do
			ui.tableNextRow()
			ui.tableNextColumn()

			textIcon(icons.sun)
			ui.text(star.name)

			local is_active_route = index and routes[index] == star.path

			if is_active_route then
				ui.sameLine(0, ui.theme.styles.ItemInnerSpacing.x)

				ui.withTooltip(lui.BODY_IN_ROUTE, function()
					textIcon(icons.route_destination)
				end)
			end

			ui.tableNextColumn()
			local dist = calc_star_dist(star)
			if dist > 0 then
				ui.text(Format.Distance(dist))
			end

			ui.tableNextColumn()

			local iconSize = Vector2(ui.getTextLineHeight())

			ui.withStyleVars({ ItemSpacing = ui.theme.styles.ItemInnerSpacing }, function()

				if ui.iconButton("Bookmark" .. i, icons.bookmark, lui.ADD_BOOKMARK, nil, iconSize) then
					PlayerState.AddBookmark(star.path, { note = star.astroDescription })
				end

				ui.sameLine()

				local routeIcon = is_active_route and icons.map_checkmark or index and icons.map_selectsystem or icons.plus
				local tooltip = is_active_route and lui.REMOVE_JUMP or index and lui.SET_JUMP_TARGET or lui.ADD_JUMP

				if ui.iconButton("Select" .. i, routeIcon, tooltip, nil, iconSize, ui.theme.styles.InlineIconPadding) then
					if is_active_route then
						hyperJumpPlanner.removeJump(index)
					elseif index then
						hyperJumpPlanner.updateInRoute(star.path)
					else
						hyperJumpPlanner.addJump(star.path)
					end
				end

			end)

		end

		ui.endTable()
	end
end

-- Helper to draw the Contextual Macro Galactic Navigation & Faction Dossier
local function drawMacroGalacticDossier()
	local map = sectorView:GetMap()
	local playerPosLy = map:GetPlayerPositionLy()
	local focusPosLy = map:GetPositionLy()
	local corePosLy = map:GetGalacticCorePositionLy()
	local distSol = playerPosLy:length()
	local distCore = (playerPosLy - corePosLy):length()
	local focusDistCore = (focusPosLy - corePosLy):length()

	sidebarStyle:push()

	ui.separatorText("GALACTIC ASTROMETRY")

	ui.withFont(pionillium.details, function()
		textIcon(icons.ship, "Ship Galactic Coordinates (Sol Origin)")
		ui.text(string.format("Ship XYZ: (%.0f, %.0f, %.0f) ly", playerPosLy.x, playerPosLy.y, playerPosLy.z))

		textIcon(icons.sun, "Distance from Sol (Humanity Birthplace)")
		ui.text(string.format("Sol Distance: %.1f ly", distSol))

		textIcon(icons.galaxy_map, "Distance to Galactic Center (Sagittarius A*)")
		ui.text(string.format("Core Distance: %.0f ly", distCore))

		textIcon(icons.maneuver, "Current Viewport Focus Coordinates")
		ui.text(string.format("Focus XYZ: (%.0f, %.0f, %.0f) ly  [%.0f ly to Core]",
			focusPosLy.x, focusPosLy.y, focusPosLy.z, focusDistCore))
	end)

	ui.spacing()
	ui.separatorText("QUICK NAVIGATION")

	ui.withFont(pionillium.details, function()
		local btnW = (ui.getContentRegion().x - ui.theme.styles.ItemSpacing.x * 2) / 3
		local btnSz = Vector2(btnW, 0)
		if ui.button("Ship", btnSz) then
			sectorView:SwitchToPath(sectorView:GetCurrentSystemPath())
		end
		ui.sameLine()
		if ui.button("Sol (0,0,0)", btnSz) then
			map:GotoSol()
		end
		ui.sameLine()
		if ui.button("Galactic Core", btnSz) then
			map:GotoGalacticCore()
			if map:GetMacroZoom() < 800.0 then
				map:SetMacroZoom(1800.0)
			end
		end

		if ui.button("Local Sector", btnSz) then
			map:SetMacroZoom(2.5)
		end
		ui.sameLine()
		if ui.button("Human Bubble", btnSz) then
			map:GotoSol()
			map:SetMacroZoom(85.0)
		end
		ui.sameLine()
		if ui.button("Full Galaxy", btnSz) then
			map:GotoGalacticCore()
			map:SetMacroZoom(9500.0)
		end
	end)

	ui.spacing()
	ui.separatorText("TERRITORIAL DOSSIER")

	local activeFaction = map:GetSelectedFaction() or map:GetFactionAtCenter()
	if activeFaction then
		local fcol = Color(activeFaction.colour.r, activeFaction.colour.g, activeFaction.colour.b)
		ui.withFont(orbiteer.body, function()
			ui.textColored(fcol, activeFaction.name)
		end)

		if activeFaction.descriptionShort and #activeFaction.descriptionShort > 0 then
			ui.withFont(pionillium.details, function()
				ui.textWrapped(activeFaction.descriptionShort)
			end)
		end

		ui.spacing()

		ui.withFont(pionillium.details, function()
			if activeFaction.hasHomeworld then
				local hw = activeFaction.homeworld
				local hwSys = hw:GetStarSystem()
				textIcon(icons.starport, "Capital System")
				ui.text(string.format("Capital: %s (%d, %d, %d)", hwSys.name, hw.sectorX, hw.sectorY, hw.sectorZ))

				textIcon(icons.route_dist, "Territorial Claim Radius")
				ui.text(string.format("Influence Radius: %.1f ly", activeFaction.radius))
			else
				textIcon(icons.galaxy_map, "Unclaimed / Independent Frontier")
				ui.text("Unaligned / Independent Frontier Space")
			end

			if activeFaction.foundingDate then
				textIcon(icons.clock, "Founding Year")
				ui.text(string.format("Established: %.0f CE", activeFaction.foundingDate))
			end

			if activeFaction.militaryName and #activeFaction.militaryName > 0 then
				textIcon(icons.shield, "Military Wing")
				ui.text("Military: " .. activeFaction.militaryName)
			end

			if activeFaction.policeName and #activeFaction.policeName > 0 then
				textIcon(icons.gavel, "Law Enforcement")
				ui.text("Security: " .. activeFaction.policeName)
			end

			local standing = FactionStanding.GetInfo(activeFaction)
			local pct = math.floor((standing.mult - 1.0) * 100 + 0.5)
			local modStr = pct == 0 and "Standard Pay" or string.format("%+d%% Contract Pay", pct)
			textIcon(icons.comms, "Faction Standing")
			ui.text(string.format("Standing: %s (%+d) — %s", standing.label, standing.score, modStr))
		end)

		if activeFaction.description and #activeFaction.description > 0 then
			ui.spacing()
			ui.withFont(pionillium.details, function()
				ui.setNextWindowSizeConstraints(Vector2(0), Vector2(-1, ui.getTextLineHeight() * 5 + ui.getWindowPadding().y * 2))
				ui.child("##factionDescription", Vector2(0), nil, childFlags, function()
					ui.textWrapped(activeFaction.description)
				end)
			end)
		end

		if activeFaction.hasHomeworld then
			ui.spacing()
			if ui.button("Center & Select Capital System", Vector2(ui.getContentRegion().x, 0)) then
				sectorView:SwitchToPath(activeFaction.homeworld)
				map:GotoSystemPath(activeFaction.homeworld)
				if map:GetMacroZoom() > 25.0 then
					map:SetMacroZoom(12.0)
				end
			end
		end
	else
		ui.withFont(pionillium.details, function()
			ui.textWrapped("Deep Uncharted Galactic Space. Click inside any faction territory in the Human Bubble to inspect its dossier, or click anywhere on the galactic disc to pan the camera.")
		end)
	end

	sidebarStyle:pop()
end

-- System Information bar (Contextually adapts to Macro Galactic View when zoomed out)
---@type UI.Sidebar.Module
local infoView = {
	active = true,
	icon = icons.info,
	tooltip = lui.SYSTEM_INFORMATION,

	drawTitle = function(self)
		local map = sectorView:GetMap()
		if map:GetMacroAlpha() >= 0.45 then
			ui.text("Galactic Overview")
			return
		end

		local iconSize = Vector2(ui.getButtonHeight())
		local path = sectorView:GetSelectedSystemPath() ---@type SystemPath

		ui.text(lui.SYSTEM_INFORMATION or "System Information")
		ui.sameLine(ui.getContentRegion().x - iconSize.x * 2, 0)

		local padding = ui.theme.styles.ItemInnerSpacing

		ui.withStyleVars({ ItemSpacing = Vector2(0, 0) }, function()
			ui.horizontalGroup(function()

				if ui.iconButton("bookmark", icons.bookmark, lui.ADD_BOOKMARK, nil, iconSize, padding) then
					PlayerState.AddBookmark(path:SystemOnly(), { note = path:GetStarSystem().shortDescription })
				end

				if ui.iconButton("focus", icons.maneuver, lui.CENTER_ON_SYSTEM, nil, iconSize, padding) then
					sectorView:GetMap():GotoSystemPath(path)
				end

			end)
		end)

	end,

	drawBody = function(self)
		local map = sectorView:GetMap()
		if map:GetMacroAlpha() >= 0.45 then
			drawMacroGalacticDossier()
			return
		end

		local path = sectorView:GetSelectedSystemPath()
		if not path then return end

		local sys = path:GetStarSystem()
		if sys then
			ui.withFont(ui.fonts.pionillium.small, function()
				ui.textColored(colors.fontDim, sys.name)
			end)
			ui.separator()
			ui.spacing()
		end

		sidebarStyle:push()

		---@type StarSystem
		local system = path:GetStarSystem()
		local current = sectorView:GetCurrentSystemPath()

		-- number of stars
		local numstarsText = {
			-- don't ask for the astro description of a gravpoint
			system.numberOfStars == 1 and system.rootSystemBody.astroDescription or "",
			lc.BINARY_SYSTEM,
			lc.TRIPLE_SYSTEM,
			lc.QUADRUPLE_SYSTEM,
			[0] = lui.AN_ERROR_HAS_OCCURRED
		}

		local securityIdx = math.ceil(system.lawlessness * 5)
		securityIdx = math.max(1, securityIdx)

		ui.textWrapped(system.shortDescription)

		if #system.other_names > 0 then
			ui.withFont(pionillium.details, function()
				ui.textWrapped(lui.KNOWN_AS .. ": " .. table.concat(system.other_names, ", ") .. ".")
			end)
		end

		local description = system.longDescription

		ui.withFont(pionillium.details, function()
			frameStyle:withStyle(function()

				if #description > 0 and ui.collapsingHeader(lui.MORE_INFO) then

					ui.setNextWindowSizeConstraints(Vector2(0), Vector2(-1, ui.getTextLineHeight() * 6 + ui.getWindowPadding().y * 2))
					ui.child("##longDescription", Vector2(0), nil, childFlags, function()
						ui.textWrapped(description)
					end)

				end

			end)
		end)

		-- InterCast Crisis & Conflict Intel Dossier
		local okInter, InterCast = pcall(require, 'modules.InterCast.InterCast')
		if okInter and InterCast then
			local sysArticles = {}
			local allArticles = InterCast.GetArticles("ALL")
			if allArticles then
				for _, art in ipairs(allArticles) do
					if art.system and string.lower(art.system) == string.lower(system.name) then
						table.insert(sysArticles, art)
					end
				end
			end
			if #sysArticles > 0 then
				local topArt = sysArticles[1]
				local catCol = colors.alertYellow
				if topArt.category == "FRONTLINE" then
					catCol = Color(255, 65, 65, 255)
				elseif topArt.category == "HUMANITARIAN" then
					catCol = Color(55, 220, 255, 255)
				elseif topArt.category == "MARKET" then
					catCol = Color(255, 185, 30, 255)
				elseif topArt.category == "POLITICS" then
					catCol = Color(215, 90, 255, 255)
				end

				ui.separatorText("INTERCAST CRISIS DISPATCH")
				ui.withFont(pionillium.details, function()
					if topArt.urgent then
						ui.textColored(Color(255, 50, 50, 255), "⚠ FLASH ADVISORY: ACTIVE HAZARD ZONE")
					end
					ui.textColored(catCol, string.format("[%s INTEL]  %s", topArt.category, topArt.date))
					ui.textWrapped(topArt.headline)
					ui.textColored(Color(190, 190, 190, 225), topArt.summary)
				end)
			end
		end

		ui.separatorText(lui.SYSTEM_INFORMATION)

		ui.withFont(pionillium.details, function()

			textIcon(icons.maneuver)
			ui.text(lc.SECTOR_X_Y_Z % path)

			ui.withTooltip(lui.SYSTEM_FACTION, function()
				textIcon(icons.gavel, lui.FACTION)
				ui.text(system.faction.name)
			end)

			ui.withTooltip(lui.SYSTEM_SECURITY_TOOLTIP, function()
				textIcon(icons.shield)
				local color = (securityIdx == 5 and colors.alertRed) or (securityIdx == 4) and colors.alertYellow or colors.font
				ui.textColored(color, lui["SYSTEM_SECURITY_" .. securityIdx])
			end)

			ui.withTooltip(lui.SYSTEM_NUM_STARS, function()
				textIcon(icons.galaxy_map)
				ui.text(numstarsText[system.numberOfStars])
			end)

			ui.withTooltip(lc.GOVERNMENT_TYPE, function()
				textIcon(icons.language)
				ui.textWrapped(system.govDescription)
			end)

			ui.withTooltip(lc.ECONOMY_TYPE, function()
				textIcon(icons.money)
				ui.textWrapped(system.econDescription)
			end)

			local pop = system.population -- population in billion
			local popText
			if pop == 0.0 then
				popText = lc.NO_REGISTERED_INHABITANTS
			elseif pop < 1 / 1000.0 then
				popText = lc.A_FEW_THOUSAND
			else
				popText = ui.Format.NumberAbbv(pop * 1e9)
			end

			ui.withTooltip(lc.POPULATION, function()
				textIcon(icons.personal)
				ui.text(popText)
			end)

			textIcon(icons.starport)
			ui.text(lc.STARPORTS .. ": " .. system.numberOfStations)

		end)

		ui.separatorText(lui.HYPERJUMP_ROUTING)

		ui.withFont(pionillium.details, function()

			if not path:IsSameSystem(current) then

				ui.alignTextToFramePadding()
				draw_jump_status(getHyperspaceDetails(path))

				local padding = ui.theme.styles.FramePadding
				local size = ui.calcTextSize(lui.AUTO_ROUTE).x + padding.x * 2

				ui.sameLine(ui.getContentRegion().x - size, 0.0)

				if ui.button(lui.AUTO_ROUTE, Vector2(0, 0), nil, nil, padding) then
					hyperJumpPlanner.autoRoute(current, path, autoRouteMaxJumpDist, autoRouteFindFuelStar)
				end

			end

		end)

		-- star list
		local stars = system:GetJumpable()
		local maxNumStars = math.min(#stars, 4)

		local rowHeight = ui.getTextLineHeight() + 2 * 2 -- CellPadding * 2
		local listSize = Vector2(0.0, rowHeight * maxNumStars + ui.getWindowPadding().y * 2)

		ui.child("##JumpList", listSize, nil, childFlags, function()
			drawJumpableList(stars, path)
		end)

		sidebarStyle:pop()

	end
}

-- Search bar module
---@type UI.Sidebar.Module
local searchBar = {
	title = lc.SEARCH or "Search",
	searchText = "",
	systemPaths = nil, ---@type table?
	icon = icons.search_lens,
	tooltip = lc.SEARCH or "Search",
	exclusive = true,

	drawTitle = function(self)
		ui.text(lc.SEARCH or "Search")
	end,

	drawBody = function(self)
		ui.withFont(pionillium.body, function()
			local clearBtnWidth = self.searchText ~= "" and ui.rescaleUI(28) or 0
			local inputWidth = ui.getContentRegion().x - (clearBtnWidth > 0 and (clearBtnWidth + ui.theme.styles.ItemSpacing.x) or 0)
			ui.nextItemWidth(inputWidth)
			local newText, changed = ui.inputText("##searchText", self.searchText, "Enter system name...", {})
			if newText ~= self.searchText then
				self:updateSearch(newText, false)
			end
			if clearBtnWidth > 0 then
				ui.sameLine()
				if ui.button("X##clearSearch", Vector2(clearBtnWidth, ui.getFrameHeight())) then
					self:updateSearch("", false)
				end
			end
		end)
		ui.spacing()

		if self.searchText == "" then
			ui.textColored(colors.fontDim, "Type a system name to begin searching...")
		elseif not self.systemPaths or #self.systemPaths == 0 then
			ui.text(lc.NOT_FOUND or "Not Found")
		else
			drawSearchResults(self.systemPaths)
		end
	end,

	---@param search string
	---@param go boolean
	updateSearch = function(self, search, go)

		if go and search ~= "" then
			local path = SystemPath.ParseString(search)

			if path then
				sectorView:GetMap():GotoSectorPath(path)
			end
		end

		if search ~= self.searchText then
			self.searchText = search
			self.systemPaths = nil

			if search ~= "" then
				self.systemPaths = sectorView:GetMap():SearchNearbyStarSystemsByName(search)
			end
		end

	end
}

-- Economy view module
---@type UI.Sidebar.Module
local econView = {
	icon = icons.money,
	tooltip = lui.ECONOMY_TRADE,
	exclusive = true,
	mode = "normal",
	drawTitle = function(self)
		ui.text(lui.ECONOMY_TRADE)
		if ui.altHeld() or self.mode == "debug" then
			local buttonSize = Vector2(ui.getButtonHeight())
			ui.sameLine(ui.getContentRegion().x - buttonSize.x, 0)

			if ui.iconButton("DEBUG", icons.alert1, "Debug Mode", nil, buttonSize) then
				self.mode = self.mode == "debug" and "normal" or "debug"
			end
		end
	end,
	drawBody = function(self)
		local selectedPath = sectorView:GetSelectedSystemPath()
		local currentPath = sectorView:GetCurrentSystemPath()

		if self.mode == "normal" then
			systemEconView:drawSystemComparison(selectedPath:GetStarSystem(), currentPath:GetStarSystem())
		elseif self.mode == "debug" then
			systemEconView:drawSystemFinder()
		end
	end
}

local autoRouteMaxJumpDist = nil
local autoRouteFindFuelStar = false

local function drawRouteList(route)
	if ui.beginTable("##RouteList", 4) then
		ui.tableSetupColumn("Index", "WidthFixed")
		ui.tableSetupColumn("Name", "WidthStretch")
		ui.tableSetupColumn("Distance", "WidthFixed")
		ui.tableSetupColumn("Fuel", "WidthFixed")

		local active = hyperJumpPlanner.getSelectedJump()

		for i, jump in ipairs(route) do
			ui.tableNextRow()
			ui.tableNextColumn()

			local clicked = ui.selectable("##Test" .. i, i == active, { "SpanAllColumns", "AllowDoubleClick" })
			ui.sameLine(0, ui.theme.styles.ItemInnerSpacing.x)

			if clicked then
				sectorView:SetSelectedPath(jump.path)
				hyperJumpPlanner.setSelectedJump(i)
			end

			if clicked and ui.isMouseDoubleClicked(0) then
				sectorView:GetMap():GotoSystemPath(jump.path)
			end

			ui.text(i)
			ui.tableNextColumn()

			local driveMax = self.driveMaxFuel or 0.0
			local tankMax = self.tankMaxFuel or 0.0
			local totalMax = self.totalMaxCapacity or 0.0

			if jump.status == "OK" then
				ui.withStyleColors({ Text = colors.alertGreen or colors.font }, function()
					ui.textAligned(ui.get_icon_glyph(icons.map_checkmark), 0.0)
				end)
				ui.setItemTooltip(string.format("Jump OK: %s t fuel\nDrive Cache remaining: %.1f / %.1f t\nMain Tank remaining: %.1f / %.1f t",
					ui.Format.Number(jump.fuel, 1), jump.driveFuelRemaining or 0, driveMax, jump.tankFuelRemaining or 0, tankMax))
			elseif jump.status == "ENGINE_REFUEL" then
				-- Orange refuel icon: Hyperdrive reservoir requires internal transfer from main tank
				ui.withStyleColors({ Text = Color(255, 160, 40, 255) }, function()
					ui.textAligned(ui.get_icon_glyph(icons.fuel), 0.0)
				end)
				ui.setItemTooltip(string.format("ENGINE REFUEL NEEDED (%s t)\nHyperdrive cache depleted; transfers from main tank.\nMain Tank remaining: %.1f / %.1f t\n(Tank Max: %.1f t)",
					ui.Format.Number(jump.fuel, 1), jump.tankFuelRemaining or 0, tankMax, tankMax))
			else
				-- Red refuel icon: Total onboard fuel tank capacity exhausted (needs scoopable star or station)
				ui.withStyleColors({ Text = colors.alertRed }, function()
					ui.textAligned(ui.get_icon_glyph(icons.fuel), 0.0)
				end)
				ui.setItemTooltip(string.format("OUT OF FUEL (Needs %.1f t)\nTotal onboard fuel (Tank Max: %.1f t) fully depleted!\nRefuel at star/station required.",
					jump.fuel, totalMax))
			end

			ui.sameLine()

			ui.textColored(colors.font, jump.path:GetSystemBody().name)
			ui.tableNextColumn()

			ui.withFont(pionillium.details, function()
				ui.text(ui.get_icon_glyph(icons.route_dist) .. ui.Format.Number(jump.distance, 2) .. " " .. lc.UNIT_LY)
				ui.tableNextColumn()
				ui.text(ui.get_icon_glyph(icons.fuel) .. ui.Format.Number(jump.fuel, 1) .. " " .. lc.UNIT_TONNES)
			end)
		end

		ui.endTable()
	end
end

-- Route Planner UI
---@type UI.Sidebar.Module
local routeView = {
	icon = icons.route,
	tooltip = lui.HYPERJUMP_ROUTE,
	title = lui.ROUTE_INFO,
	active = true,

	driveFuel = 0.0,
	driveMaxFuel = 0.0,
	tankFuel = 0.0,
	tankMaxFuel = 0.0,
	totalTankFuel = 0.0,
	totalMaxCapacity = 0.0,
	refresh = function(self)
		local engine = Game.player:GetInstalledHyperdrive()
		local shipDef = ShipDef and ShipDef[Game.player.shipId]
		local fuelTankSize = shipDef and shipDef.fuelTankMass or (Game.player:GetShipType() and Game.player:GetShipType().fuelTankMass or 0)
		self.driveFuel = engine and engine.storedFuel or 0.0
		self.driveMaxFuel = engine and engine:GetMaxFuel() or 0.0
		self.tankFuel = Game.player.fuelMassLeft or (fuelTankSize * (Game.player.fuel or 0) / 100)
		self.tankMaxFuel = fuelTankSize or 0.0
		self.totalTankFuel = self.driveFuel + self.tankFuel
		self.totalMaxCapacity = self.driveMaxFuel + self.tankMaxFuel
	end,

	drawBody = function(self)
		local route = hyperJumpPlanner.getJumpRouteList()
		---@type SystemPath?
		local current = sectorView:GetCurrentSystemPath()
		if not current then return end

		sidebarStyle:push()

		local fuel, duration, distance = hyperJumpPlanner.getRouteStats()

		ui.withFont(pionillium.details, function()

		textIcon(icons.navtarget, lui.CURRENT_SYSTEM)
		if current then
			if ui.selectable(ui.Format.SystemPath(current)) then
				sectorView:SwitchToPath(current)
			end
		else
			ui.text("---")
		end

		textIcon(icons.route_destination, lui.FINAL_TARGET)
		if #route > 0 then
			local destination = route[#route]

			if ui.selectable(ui.Format.SystemPath(destination.path)) then
				sectorView:SwitchToPath(destination.path)
			end
		else
			ui.text("---")
		end

		textIcon(icons.fuel, lui.REQUIRED_FUEL)
		ui.horizontalGroup(function()
			ui.text(ui.Format.Mass(fuel * 1000, 1))

			ui.text("[")

			textIcon(icons.hull, lui.CURRENT_FUEL)
			ui.text(string.format("%.1f / %.1f t (Drive %.1f/%.1ft | Tank %.1f/%.1ft)",
				self.totalTankFuel, self.totalMaxCapacity,
				self.driveFuel, self.driveMaxFuel,
				self.tankFuel, self.tankMaxFuel))

			ui.text("]")
		end)

		textIcon(icons.eta, lui.TOTAL_DURATION)
		ui.text(ui.Format.Duration(duration, 2))

		ui.sameLine()

		textIcon(icons.route_dist, lui.TOTAL_DISTANCE)
		ui.text(ui.Format.Number(distance, 2) .. " " .. lc.UNIT_LY)

		end)

		ui.spacing()

		-- Auto-Route Settings Section
		ui.separatorText("Auto-Route Settings")
		local engine = Game.player:GetInstalledHyperdrive()
		local maxRange = engine and engine:GetMaximumRange(Game.player) or 30.0
		if not autoRouteMaxJumpDist or autoRouteMaxJumpDist > maxRange then
			autoRouteMaxJumpDist = maxRange
		end

		ui.withFont(pionillium.details, function()
			ui.text(string.format("Max Jump Distance: %.1f ly", autoRouteMaxJumpDist))
			local newMaxJump, changedSlider = ui.sliderFloat("##maxJumpSlider", autoRouteMaxJumpDist, 1.0, maxRange, "%.1f ly")
			if changedSlider then
				autoRouteMaxJumpDist = newMaxJump
			end

			local changedFuelStar, newFuelStar = ui.checkbox("Find Fuel Star (Scoopable)##findFuelStarChk", autoRouteFindFuelStar)
			if changedFuelStar then
				autoRouteFindFuelStar = newFuelStar
			end

			if #route > 0 and current and route[#route] then
				ui.spacing()
				if ui.button("Recalculate Route##recalcRouteBtn", Vector2(ui.getContentRegion().x, 24)) then
					hyperJumpPlanner.autoRoute(current, route[#route].path, autoRouteMaxJumpDist, autoRouteFindFuelStar)
				end
			end
		end)

		ui.spacing()

		ui.separatorText(lui.ROUTE_JUMPS)

		local jumpIndex = hyperJumpPlanner.getSelectedJump()

		ui.horizontalGroup(function()

			if ui.iconButton("ViewSystem", icons.view_internal, lui.CENTER_ON_SYSTEM) then
				if route[jumpIndex] then
					sectorView:SwitchToPath(route[jumpIndex].path)
					sectorView:GetMap():GotoSystemPath(route[jumpIndex].path)
				end
			end

			if ui.iconButton("MoveUp", icons.chevron_up, lui.MOVE_UP) then
				if route[jumpIndex] then
					hyperJumpPlanner.moveItemUp(jumpIndex)
				end
			end

			if ui.iconButton("MoveDown", icons.chevron_down, lui.MOVE_DOWN) then
				if route[jumpIndex] then
					hyperJumpPlanner.moveItemDown(jumpIndex)
				end
			end

			if ui.iconButton("Remove", icons.cross, lui.REMOVE_JUMP) then
				if route[jumpIndex] then
					hyperJumpPlanner.removeJump(jumpIndex)
				end
			end

		end)

		local padding = ui.getWindowPadding()
		ui.setNextWindowSizeConstraints(Vector2(0), Vector2(-1, (ui.getTextLineHeight() + 4) * 8 + padding.y * 2))

		ui.child("##routeJumps", Vector2(0, 0), nil, childFlags, function()

			ui.withStyleVars({ ItemSpacing = Vector2(4, 4) }, function()
				drawRouteList(route)
			end)

		end)

		sidebarStyle:pop()

	end
}

---@type UI.Sidebar.Module
local factionView = {
	icon = icons.shield,
	tooltip = lui.FACTIONS,
	title = lui.FACTIONS,
	drawBody = function(self)
		sidebarStyle:push()

		local map = sectorView:GetMap()
		local isMacro = map:GetVoronoiAlpha() > 0.25
		local factions = isMacro and map:GetAllMajorFactions() or map:GetFactions()

		if isMacro then
			ui.withFont(pionillium.details, function()
				ui.textWrapped("Toggle faction visibility or click a faction to inspect its territory and center on its capital world:")
			end)
			ui.spacing()
		end

		ui.setNextWindowSizeConstraints(Vector2(0), Vector2(-1, ui.getTextLineHeight() * 16 + ui.getWindowPadding().y * 2))
		ui.child("##factionsList", Vector2(0), nil, childFlags, function()
			for _, f in pairs(factions) do
				local changed, value
				local fcol = Color(f.faction.colour.r, f.faction.colour.g, f.faction.colour.b)
				ui.withStyleColors({ Text = fcol }, function()
					changed, value = ui.checkbox("##vis_" .. f.faction.name, f.visible)
					ui.sameLine()
					if ui.selectable(f.faction.name, map:GetSelectedFaction() == f.faction) then
						map:SetSelectedFaction(f.faction)
						if f.faction.hasHomeworld then
							map:GotoSystemPath(f.faction.homeworld)
						end
					end
				end)
				if changed then
					map:SetFactionVisible(f.faction, value)
				end
			end
		end)

		sidebarStyle:pop()
	end
}

---@type UI.Sidebar.Module
local optionView = {
	icon = icons.settings,
	tooltip = lui.SETTINGS,
	title = lui.SETTINGS,
	drawBody = function(self)
		sidebarStyle:push()

		local changed
		changed, settings.draw_vertical_lines = ui.checkbox(lc.DRAW_VERTICAL_LINES, settings.draw_vertical_lines)
		if changed then
			sectorView:GetMap():SetDrawVerticalLines(settings.draw_vertical_lines)
		end
		changed, settings.draw_out_range_labels = ui.checkbox(lc.DRAW_OUT_RANGE_LABELS, settings.draw_out_range_labels)
		if changed then
			sectorView:SetDrawOutRangeLabels(settings.draw_out_range_labels)
		end
		changed, settings.draw_uninhabited_labels = ui.checkbox(lc.DRAW_UNINHABITED_LABELS, settings.draw_uninhabited_labels)
		if changed then
			sectorView:GetMap():SetDrawUninhabitedLabels(settings.draw_uninhabited_labels)
		end
		changed, settings.automatic_system_selection = ui.checkbox(lc.AUTOMATIC_SYSTEM_SELECTION, settings.automatic_system_selection)
		if changed then
			sectorView:SetAutomaticSystemSelection(settings.automatic_system_selection)
		end
		changed, settings.draw_uncharted_overlay = ui.checkbox("Mark Charted Systems", settings.draw_uncharted_overlay or false)
		if changed then
			sectorView:GetMap():SetDrawUnchartedOverlay(settings.draw_uncharted_overlay)
		end
		if settings.draw_uncharted_overlay then
			ui.textColored(Color(75, 255, 145, 255), "  ◆ Green: Discovered by You")
			ui.textColored(Color(55, 215, 255, 255), "  ◆ Cyan: Pre-charted")
			ui.textColored(Color(160, 160, 160, 220), "    Uncharted: Unmarked Star")
		end

		changed, settings.draw_conflict_overlay = ui.checkbox("Conflict & Crisis Intel Overlay", settings.draw_conflict_overlay or false)
		if changed then
			sectorView:GetMap():SetDrawConflictOverlay(settings.draw_conflict_overlay)
			if settings.draw_conflict_overlay then
				syncConflictIntel(sectorView:GetMap())
			end
		end
		if settings.draw_conflict_overlay then
			ui.textColored(Color(255, 65, 65, 255), "  ◈ Red: Frontline Combat / Blockade")
			ui.textColored(Color(45, 215, 255, 255), "  ◈ Cyan: Humanitarian Relief / Outbreak")
			ui.textColored(Color(255, 185, 30, 255), "  ◈ Amber: Market Embargo / Deficit")
			ui.textColored(Color(210, 80, 255, 255), "  ◈ Purple: Political Unrest / Summit")
		end

		ui.spacing()
		local sphereLabels = { "Compact (56 ly)", "Medium (80 ly)", "Standard (104 ly)", "Maximum (136 ly)" }
		local currentSphereIdx = 2
		local curScale = settings.visible_sphere_scale or 0.75
		if curScale <= 0.40 then currentSphereIdx = 0
		elseif curScale <= 0.60 then currentSphereIdx = 1
		elseif curScale <= 0.85 then currentSphereIdx = 2
		else currentSphereIdx = 3 end

		ui.text("Visible Star Sphere Radius:")
		local sphereChanged, newSphereIdx = ui.combo("##VisibleSphereSize", currentSphereIdx, sphereLabels)
		if sphereChanged then
			local scaleMap = { [0] = 0.35, [1] = 0.55, [2] = 0.75, [3] = 1.0 }
			settings.visible_sphere_scale = scaleMap[newSphereIdx] or 0.75
			sectorView:GetMap():SetVisibleSphereScale(settings.visible_sphere_scale)
		end

		sidebarStyle:pop()
	end
}

local bookmarkView = BookmarkView.New()

table.insert(leftSidebar.modules, infoView)
table.insert(leftSidebar.modules, econView)
table.insert(leftSidebar.modules, factionView)
table.insert(leftSidebar.modules, optionView)

table.insert(rightSidebar.modules, routeView)
table.insert(rightSidebar.modules, searchBar)
table.insert(rightSidebar.modules, bookmarkView)

-- Renders the current system & Macro Galactic Position Info Banner
local function drawCurrentSystemName()
	local window_offset_y = ui.theme.styles.MainButtonSize.y + ui.getWindowPadding().y * 2 + ui.theme.styles.ItemSpacing.y
	ui.setNextWindowPos(Vector2(ui.screenWidth / 2, window_offset_y), "Always", Vector2(0.5, 0))

	local map = sectorView:GetMap()
	local vorAlpha = map:GetVoronoiAlpha()

	ui.window("##CurrentSystem", { "NoDecoration", "NoMove", "NoBackground", "AlwaysAutoResize" }, function()
		local path = sectorView:GetCurrentSystemPath()
		local playerPosLy = map:GetPlayerPositionLy()
		local corePosLy = map:GetGalacticCorePositionLy()
		local distSol = playerPosLy:length()
		local distCore = (playerPosLy - corePosLy):length()
		local activeFaction = map:GetSelectedFaction() or map:GetFactionAtCenter() or map:GetFactionAtPlayer()
		local territoryName = activeFaction and activeFaction.name or "Uncharted Space"

		if vorAlpha < 0.25 then
			ui.withFont(orbiteer.body, function()
				bannerText(ui.getCursorScreenPos(),
					ui.get_icon_glyph(icons.navtarget) .. " " .. ui.Format.SystemPath(path) ..
					string.format("   |   Sol: %.1f ly   |   %s", distSol, territoryName),
					colors.lightBlackBackground)
			end)
		else
			local focusPosLy = map:GetPositionLy()
			local headerLine = string.format(
				"%s %s   |   GALACTIC XYZ: (%.0f, %.0f, %.0f) ly   |   SOL: %.0f ly   |   SAGITTARIUS A*: %.0f ly",
				ui.get_icon_glyph(icons.galaxy_map),
				ui.Format.SystemPath(path),
				playerPosLy.x, playerPosLy.y, playerPosLy.z,
				distSol, distCore
			)
			ui.withFont(orbiteer.body, function()
				bannerText(ui.getCursorScreenPos(), headerLine, colors.lightBlackBackground)
			end)

			local subLine = string.format(
				"TERRITORY: %s   |   FOCUS XYZ: (%.0f, %.0f, %.0f) ly   |   SCALE: %.0f ly",
				territoryName,
				focusPosLy.x, focusPosLy.y, focusPosLy.z,
				map:GetMacroZoom() * 10.0
			)
			ui.withFont(pionillium.details, function()
				bannerText(ui.getCursorScreenPos(), subLine, colors.lightBlackBackground)
			end)
		end
	end)
end

local wnd_pivot_bottom = Vector2(0.5, 1.0)
local button_wnd_flags = ui.WindowFlags { "NoTitleBar", "NoMove", "AlwaysAutoResize", "NoScrollbar" }

local function drawEdgeButtons()

	local windowPos = Vector2(ui.screenWidth / 2, ui.screenHeight)
	ui.setNextWindowPos(windowPos, "Always", wnd_pivot_bottom)
	local map = sectorView:GetMap()

	ui.window("##EdgeButtons", button_wnd_flags, function()
		ui.horizontalGroup(function()

			-- view control buttons
			if ui.mainMenuButton(icons.navtarget, lui.CENTER_ON_CURRENT_SYSTEM) then
				sectorView:SwitchToPath(sectorView:GetCurrentSystemPath())
			end

			if ui.mainMenuButton(icons.sun, "Center on Sol (0, 0, 0)") then
				map:GotoSol()
			end

			if ui.mainMenuButton(icons.galaxy_map, "Toggle Macro Galactic Overview / Sagittarius A*") then
				if map:GetMacroAlpha() < 0.5 then
					map:GotoGalacticCore()
					map:SetMacroZoom(9500.0)
					if not leftSidebar.active and not infoView.active then
						leftSidebar:MakeActive(infoView)
					end
				else
					sectorView:SwitchToPath(sectorView:GetCurrentSystemPath())
					map:SetMacroZoom(2.5)
				end
			end

			if ui.mainMenuButton(icons.reset_view, lui.RESET_ORIENTATION_AND_ZOOM) then
				sectorView:ResetView()
			end

			ui.mainMenuButton(icons.rotate_view, lui.ROTATE_VIEW)
			sectorView:GetMap():SetRotateMode(ui.isItemActive())

			ui.mainMenuButton(icons.search_lens, lui.ZOOM)
			sectorView:GetMap():SetZoomMode(ui.isItemActive())

			local target = player:GetHyperspaceTarget()
			local fs = player:GetFlightState()
			local cooldown = player.GetSupercruiseCooldown and player:GetSupercruiseCooldown() or 0
			local canJump = player:IsHyperjumpAllowed() and target and (fs == "FLYING" or fs == "SUPERCRUISE") and player:CanHyperjumpTo(target) and cooldown <= 0.05

			if not canJump then
				local tip = (cooldown > 0.05) and string.format("FSD Cooldown Active (%.1fs)", cooldown) or lui.HUD_BUTTON_HYPERDRIVE_DISABLED
				ui.mainMenuButton(icons.hyperspace, tip, ui.theme.buttonColors.disabled)
			elseif player:IsHyperspaceActive() then
				if ui.mainMenuButton(icons.hyperspace, lc.HYPERSPACE_JUMP_ABORT, ui.theme.buttonColors.selected) then
					player:AbortHyperjump()
				end
			else
				if ui.mainMenuButton(icons.hyperspace, lc.HYPERSPACE_JUMP_ENGAGE) then
					player:HyperjumpTo(target)
				end
			end

		end)
	end)

end

local function refreshData()
	leftSidebar:Refresh()
	rightSidebar:Refresh()
	hyperJumpPlanner.updateRouteList()
end

ui.registerHandler("SectorView", function(delta_t, refresh)
	player = Game.player

	if refresh then
		-- Always show system info when entering SectorView, if we can. This helps the player find the hyperspace routing.
		if not leftSidebar.active and not infoView.active then
			leftSidebar:MakeActive(infoView)
		end

		refreshData()
	end

	drawCurrentSystemName()

	ui.withFont(pionillium.body, function()
		leftSidebar:Draw()
		rightSidebar:Draw()

		ui.withStyleColors({
			WindowBg = colors.lightBlackBackground
		}, function()
			drawEdgeButtons()
		end)
	end)


	if ui.isKeyReleased(ui.keys.tab) then
		ui_visible = not ui_visible
		-- FIXME: label visibility is logically inverted from the parameter
		sectorView:GetMap():SetLabelsVisibility(not ui_visible)
	end

	if ui.escapeKeyReleased() then
		Game.SetView("WorldView")
	end

	if ui.ctrlHeld() and ui.isKeyReleased(ui.keys.delete) then
		package.reimport('pigui.modules.system-econ-view')
		bookmarkView:debugReload()
		package.reimport('pigui.modules.hyperjump-planner')
		package.reimport()
	end
end)

Event.Register("onGameStart", onGameStart)
Event.Register("onEnterSystem", function(ship)
	hyperJumpPlanner.onEnterSystem(ship)
	hyperspaceDetailsCache = {}
	-- We don't need to reset UI state after a jump, but we do need to reload
	-- data about the new system we just entered.
	refreshData()
end)

-- reset cached data
Event.Register("onGameEnd", function()
	leftSidebar:Reset()
	searchBar.searchText = ""
	searchBar.systemPaths = nil

	hyperJumpPlanner.onGameEnd()
end)

Event.Register("onShipTypeChanged", function(ship, ...)
	if ship:IsPlayer() then hyperspaceDetailsCache = {} end
end)


local serialize = function ()

	local data =
	{
		version = 1,
		jump_targets = {},
		settings = settings
	}

	for _, jump_sys in ipairs(sectorView:GetRoute()) do
		table.insert( data.jump_targets, jump_sys )
	end

	return data
end

local unserialize = function (data)
	loaded_data = data
end

Serializer:Register("HyperJumpPlanner", serialize, unserialize)


return {}
