-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Game = require 'Game'
local Space = require 'Space'
local Format = require 'Format'
local Lang = require 'Lang'
local utils = require "libs.utils"

local lc = Lang.GetResource("core");
local lui = Lang.GetResource("ui-core");

local ui = require 'pigui'

local getBodyIcon = require 'pigui.modules.flight-ui.body-icons'

local colors = ui.theme.colors
local icons = ui.theme.icons
local styles = ui.theme.styles
local Vector2 = _G.Vector2

local style = ui.rescaleUI {
	iconSize = Vector2(18,18),
	bodyIconSize = Vector2(14,14),
	buttonSize = Vector2(24,24)
}

-- Reusable widget to list the static contents of a system.
-- Intended to be used by flight-ui as a list of nav targets,
-- and the system info view as a list of bodies in-system

---@class SystemOverviewWidget
---@field New fun(): SystemOverviewWidget
local SystemOverviewWidget = utils.class('ui.SystemOverviewWidget')

function SystemOverviewWidget:Constructor()
	self.shouldDisplayPlayerDistance = false
	self.shouldSortByPlayerDistance = false
	self.shouldShowStations = false
	self.shouldShowMoons = false
	self.shouldAllowShips = false
	self.shouldShowShips = true
	self.focusSearchResults = false
	self.visible = false
	self.filterText = ""
	self.size = Vector2(0, 0)
	self.buttonSize = nil
end

local function getEntryDistanceToPlayer(entry)
	if not entry or not Game.player then return math.huge end
	if entry.isShip then
		if entry.dockedStation and entry.dockedStation:exists() then
			return entry.dockedStation:DistanceTo(Game.player)
		elseif entry.body and entry.body:exists() then
			return entry.body:DistanceTo(Game.player)
		end
		return math.huge
	end
	return entry.body and entry.body:DistanceTo(Game.player) or math.huge
end

local function sortByPlayerDistance(a,b)
	return getEntryDistanceToPlayer(a) < getEntryDistanceToPlayer(b)
end

local function sortBySystemDistance(a,b)
	if a.isShip and b.isShip then
		return getEntryDistanceToPlayer(a) < getEntryDistanceToPlayer(b)
	elseif a.isShip ~= b.isShip then
		return not a.isShip
	end
	return (a.systemBody.periapsis + a.systemBody.apoapsis) < (b.systemBody.periapsis + b.systemBody.apoapsis)
end

local function make_result(systemBody, label, isSelected, parent)
	return {
		systemBody = systemBody,
		body = systemBody.body,
		parent = parent,
		label = label,
		children = {},
		visible = true,
		children_visible = isSelected,
		selected = isSelected,
		has_space_stations = false,
		has_ground_stations = false,
		has_moons = false,
		has_ships = false,
		has_hidden_ships = false,
	}
end

-- Returns a table of entries.
-- Each entry will have { children_visible = true } if they are a parent of, or are a selected object
-- Entries that are excluded by the current filter will have { visible = false }
---@return table @ information about a given SystemBody
local function calculateEntry(systemBody, parent, selected, filter, sbodyToEntry)
	local result = nil
	local isSelected = selected[systemBody] or (systemBody.body and selected[systemBody.body]) or false

	result = make_result(systemBody, systemBody.name, isSelected, parent)
	result.visible = isSelected or filter(systemBody)
	if sbodyToEntry then
		sbodyToEntry[systemBody] = result
	end

	-- Set show-flags on the direct parent of this body
	if systemBody.isSpaceStation then
		parent.has_space_stations = true
	elseif systemBody.isGroundStation then
		parent.has_ground_stations = true
	elseif systemBody.isMoon then
		parent.has_moons = true
	end

	for _, child in pairs(systemBody.children or {}) do
		table.insert(result.children, calculateEntry(child, result, selected, filter, sbodyToEntry))
	end

	-- propagate children_visible and visible upwards
	if parent then
		if result.visible then parent.visible = true end
		if result.children_visible then parent.children_visible = true end
	end

	return result
end

function SystemOverviewWidget:onBodySelected(sBody, body)
	-- override me
end

function SystemOverviewWidget:onBodyDoubleClicked(sBody, body)
	-- override me
end

function SystemOverviewWidget:onBodyContextMenu(sBody, body)
	-- override me
end

-- Render a row for an entry in the system overview
function SystemOverviewWidget:renderEntry(entry, indent)
	local sbody = entry.systemBody ---@type SystemBody?
	local label = entry.label or "UNKNOWN"
	local id
	local icon
	local iconColor = colors.font

	if entry.isShip then
		local ship = entry.body
		id = "##ship_" .. label .. "_" .. tostring(ship)
		icon = getBodyIcon(ship, false)
		if Game.player then
			if ship == Game.player:GetCombatTarget() then
				iconColor = colors.combatTarget
			elseif ship == Game.player:GetNavTarget() then
				iconColor = colors.navTarget
			end
		end
	else
		-- Handle the case where there is more than one body with the same name (e.g. New Hope in Epsilon Eridani)
		id = "##" .. label .. "#" .. sbody.path.bodyIndex
		icon = getBodyIcon(sbody)
	end

	ui.dummy(Vector2(style.iconSize.x * indent / 2.0, style.iconSize.y))
	ui.sameLine()
	ui.icon(icon, style.iconSize, iconColor)
	ui.sameLine()

	local pos = ui.getCursorPos()
	if ui.selectable(id, entry.selected, {"SpanAllColumns"}, Vector2(0, style.iconSize.y)) then
		self:onBodySelected(sbody, entry.body)
	end
	if ui.isItemHovered() and ui.isMouseDoubleClicked(0) then
		self:onBodyDoubleClicked(sbody, entry.body)
	end
	if ui.isItemHovered() and ui.isMouseClicked(1) then
		self:onBodyContextMenu(sbody, entry.body)
	end

	ui.setCursorPos(pos)
	ui.alignTextToLineHeight(style.iconSize.y)
	if entry.isShip and entry.isDebugOnly then
		ui.withFont(ui.fonts.pionillium_italic.medium, function()
			ui.text(label)
		end)
	else
		ui.text(label)
	end
	ui.sameLine()

	if not entry.isShip then
		if entry.has_moons then
			ui.icon(icons.moon, style.bodyIconSize, colors.font)
			ui.sameLine(0,0.01)
		end
		if entry.has_ground_stations then
			ui.icon(icons.starport, style.bodyIconSize, colors.font)
			ui.sameLine(0,0.01)
		end
		if entry.has_space_stations then
			ui.icon(icons.spacestation, style.bodyIconSize, colors.font)
			ui.sameLine(0,0.01)
		end
		if (entry.has_ships or entry.has_hidden_ships) and self.shouldAllowShips and (not self.shouldShowShips or entry.has_hidden_ships or not entry.children_visible) then
			ui.icon(icons.ship, style.bodyIconSize, colors.font)
			ui.sameLine(0,0.01)
		end
	end

	ui.nextColumn()
	ui.dummy(Vector2(0, style.iconSize.y))
	ui.sameLine()
	ui.alignTextToLineHeight(style.iconSize.y)

	local distance
	if entry.isShip then
		distance = getEntryDistanceToPlayer(entry)
	elseif entry.body and self.shouldDisplayPlayerDistance then
		distance = entry.body:DistanceTo(Game.player)
	else
		distance = (sbody.apoapsis + sbody.periapsis) / 2.0
	end
	ui.text(Format.Distance(distance))
	ui.nextColumn()
end

function SystemOverviewWidget:showEntry(entry, indent, sortFunction)
	if entry.isShip or (entry.systemBody and entry.systemBody.type ~= 'GRAVPOINT') then
		self:renderEntry(entry, indent)
	end

	local isVisible = entry.children_visible and not self.focusSearchResults
	table.sort(entry.children, sortFunction)
	for _, v in pairs(entry.children) do
		if v.visible or isVisible then
			self:showEntry(v, indent + 1, sortFunction)
		end
	end
end

function SystemOverviewWidget:drawControlButtons()
	local buttonSize = self.buttonSize or styles.MainButtonSize

	if self.shouldDisplayPlayerDistance then
		if ui.iconButton("sort_by_dist", icons.distance, lui.TOGGLE_OVERVIEW_SORT_BY_PLAYER_DISTANCE, self.shouldSortByPlayerDistance, buttonSize) then
			self.shouldSortByPlayerDistance = not self.shouldSortByPlayerDistance
		end
		ui.sameLine()
	end

	if ui.iconButton("show_moons", icons.moon, lui.TOGGLE_OVERVIEW_SHOW_MOONS, self.shouldShowMoons, buttonSize) then
		self.shouldShowMoons = not self.shouldShowMoons
	end
	ui.sameLine()
	if ui.iconButton("show_stations", icons.filter_stations, lui.TOGGLE_OVERVIEW_SHOW_STATIONS, self.shouldShowStations, buttonSize) then
		self.shouldShowStations = not self.shouldShowStations
	end
	if self.shouldAllowShips then
		ui.sameLine()
		if ui.iconButton("show_ships", icons.ship, "Toggle Ships in Overview", self.shouldShowShips, buttonSize) then
			self.shouldShowShips = not self.shouldShowShips
		end
	end
end

function SystemOverviewWidget:displaySearch()
	local filterText = ui.inputText("##FilterText", self.filterText, "Filter bodies or stations...", {})
	self.filterText = filterText
	self.focusSearchResults = filterText and filterText ~= ""

	ui.sameLine()
	ui.icon(icons.filter_bodies, style.buttonSize, colors.frame, lui.OVERVIEW_NAME_FILTER)
end

function SystemOverviewWidget:displaySidebarControls()
	local spacing = styles.ItemInnerSpacing
	local numButtons = 2 + (self.shouldDisplayPlayerDistance and 1 or 0) + (self.shouldAllowShips and 1 or 0)
	local button_width = (ui.getLineHeight() + spacing.x) * numButtons - spacing.x

	local pos = ui.getCursorPos() + Vector2(ui.getContentRegion().x - button_width, 0)
	self.buttonSize = Vector2(ui.getLineHeight())

	ui.setCursorPos(pos)
	ui.withStyleVars({ ItemSpacing = spacing }, function()
		ui.withFont(ui.fonts.pionillium.medium, function()
			self:drawControlButtons()
		end)
	end)
end

local function findNearestStationChild(parentSBody, ship)
	if not parentSBody or not parentSBody.children then return nil end
	local bestStation = nil
	local bestDist = 50000 -- 50 km surface/local station grouping radius
	for _, child in pairs(parentSBody.children) do
		if child.isStation then
			local stBody = child.body or child.physicsBody
			if stBody and stBody:exists() then
				local d = ship:DistanceTo(stBody)
				if d < bestDist then
					bestDist = d
					bestStation = child
				end
			end
		end
	end
	return bestStation
end

local function resolveShipParentEntry(ship, tree, sbodyToEntry)
	local dockedStation = (ship.IsDocked and ship:IsDocked()) and ship:GetDockedWith() or nil
	if dockedStation and dockedStation:exists() and dockedStation.GetSystemBody then
		local stSBody = dockedStation:GetSystemBody()
		if stSBody and sbodyToEntry[stSBody] then
			return sbodyToEntry[stSBody], dockedStation
		end
	end

	local fb = ship.frameBody
	if fb and fb:exists() and fb.GetSystemBody then
		local fbSBody = fb:GetSystemBody()
		if fbSBody then
			if fb:IsStation() and sbodyToEntry[fbSBody] then
				return sbodyToEntry[fbSBody], nil
			end
			local nearStation = findNearestStationChild(fbSBody, ship)
			if nearStation and sbodyToEntry[nearStation] then
				return sbodyToEntry[nearStation], nil
			end
			if sbodyToEntry[fbSBody] then
				return sbodyToEntry[fbSBody], nil
			end
		end
	end

	return tree, nil
end

function SystemOverviewWidget:display(system, root, selected)
	root = root or system.rootSystemBody

	local sortFunction = self.shouldSortByPlayerDistance and sortByPlayerDistance or sortBySystemDistance

	local filterText = self.filterText
	local filterFunction = function(systemBody)
		-- only plain text matches, no regexes
		if filterText ~= "" and filterText ~= nil and not string.find(systemBody.name:lower(), filterText:lower(), 1, true) then
			return false
		end
		if not (self.shouldShowMoons or self.focusSearchResults) and systemBody.isMoon then
			return false
		elseif not (self.shouldShowStations or self.focusSearchResults) and systemBody.isStation then
			return false
		end
		return true
	end

	ui.child("spaceTargets", self.size, function()
		local sbodyToEntry = {}
		local tree = calculateEntry(root, nil, selected, filterFunction, sbodyToEntry)

		if tree and self.shouldAllowShips and Game and Game.system and system == Game.system and Game.player and not Game.InHyperspace() then
			local player = Game.player
			local debugShowAll = Engine.GetDebugShowAllShips and Engine.GetDebugShowAllShips() or false
			local filterLower = (filterText and filterText ~= "") and filterText:lower() or nil

			for _, ship in ipairs(Space.GetBodies("Ship")) do
				if ship and ship ~= player and ship:exists() then
					local naturallyVisible = player.CanSeeShip and player:CanSeeShip(ship) or false
					if naturallyVisible or debugShowAll then
						local isDebugOnly = not naturallyVisible
						local label = ship:GetLabel() or "SHIP"
						if not isDebugOnly and player.CanIdentify and not player:CanIdentify(ship) then
							label = (ship:GetFlightState() == "SUPERCRUISE") and "UNIDENTIFIED LIGHT" or "UNIDENTIFIED"
						end
						local isSelected = selected[ship] or false
						local matchesFilter = (not filterLower) or (string.find(label:lower(), filterLower, 1, true) ~= nil)
						local shipVisible = isSelected or (matchesFilter and (self.shouldShowShips or self.focusSearchResults))

						local parentEntry, dockedStation = resolveShipParentEntry(ship, tree, sbodyToEntry)
						parentEntry.has_ships = true
						local anc = parentEntry
						while anc and not anc.visible do
							anc = anc.parent
							if anc then
								anc.has_hidden_ships = true
							end
						end

						if shipVisible then
							if isSelected or self.focusSearchResults then
								local p = parentEntry
								while p do
									p.visible = true
									p = p.parent
								end
							end

							local shipEntry = {
								isShip = true,
								ship = ship,
								body = ship,
								dockedStation = dockedStation,
								label = label,
								isDebugOnly = isDebugOnly,
								parent = parentEntry,
								children = {},
								visible = true,
								children_visible = isSelected,
								selected = isSelected,
							}
							table.insert(parentEntry.children, shipEntry)
						end
					end
				end
			end
		end

		if tree then
			ui.columns(2, "spaceTargetColumnsOn", false) -- no border
			ui.setColumnOffset(1, ui.getWindowSize().x * 0.66)
			self:showEntry(tree, 0, sortFunction)
			ui.columns(1, "spaceTargetColumnsOff", false) -- no border
			ui.radialMenu("systemoverviewspacetargets")
		else
			ui.text(lui.NO_FILTER_MATCHES)
		end
	end)
end

function SystemOverviewWidget:displaySidebarTitle(system)
	local spacing = styles.ItemInnerSpacing
	local numButtons = 2 + (self.shouldDisplayPlayerDistance and 1 or 0) + (self.shouldAllowShips and 1 or 0)
	local button_width = (ui.getLineHeight() + spacing.x) * numButtons - spacing.x

	local pos = ui.getCursorPos() + Vector2(ui.getContentRegion().x - button_width, 0)
	self.buttonSize = Vector2(ui.getLineHeight())

	if system then
		ui.text(system.name)

		ui.setCursorPos(pos)
		ui.withStyleVars({ ItemSpacing = spacing }, function()
			ui.withFont(ui.fonts.pionillium.medium, function()
				self:drawControlButtons()
			end)
		end)
	else
		ui.text(lc.HYPERSPACE)
	end
end

return SystemOverviewWidget
