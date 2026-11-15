-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Table = require 'pigui.libs.table'
local InfoView = require 'pigui.views.info-view'
local Lang = require 'Lang'
local FlightLog = require 'modules.FlightLog.FlightLog'
local FlightLogExporter = require 'modules.FlightLog.FlightLogExporter'
local Color = _G.Color
local Vector2 = _G.Vector2

local pionillium = ui.fonts.pionillium
local icons = ui.theme.icons
local colors = ui.theme.colors

local l = Lang.GetResource("ui-core")

local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(14, 3),
	itemInnerSpacing = Vector2(6, 3),
	rowVerticalSpacing = Vector2(0, 3),
	controlSpacing = Vector2(6, 6),
	clearButtonWidth = 64,
	filterPillHeight = 22,
}, Vector2(1920, 1080))

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local earliestFirst = false
local exportHtml = true
local filterCategory = "ALL"
local searchText = ""
local selectedLogIndex = nil
local entering_text = false

local function getEntryTime(entry)
	if entry.time then return entry.formatDate(entry.time) end
	if entry.arrtime then return entry.formatDate(entry.arrtime) end
	if entry.deptime then return entry.formatDate(entry.deptime) end
	return ""
end

local function getEntryTitle(entry)
	local eType = entry:GetType()
	if eType == "System" then
		return entry.systemp and ui.Format.SystemPath(entry.systemp) or entry:GetLocalizedName()
	elseif eType == "Station" then
		if entry.systemp and entry.systemp:IsBodyPath() then
			local system = entry.systemp:GetStarSystem()
			local body = system:GetBodyByPath(entry.systemp)
			if body then return body.name end
		end
		return entry.systemp and ui.Format.SystemPath(entry.systemp) or entry:GetLocalizedName()
	elseif eType == "Custom" then
		if entry.entry and entry.entry ~= "" then
			return entry.entry
		elseif entry.location and entry.location[1] then
			return entry.composeLocationString(entry.location)
		else
			return entry:GetLocalizedName()
		end
	end
	return entry:GetLocalizedName()
end

local function getEntryCategoryBadge(eType)
	if eType == "System" then
		return "[SYSTEM]", colors.uiPrimaryLight
	elseif eType == "Station" then
		return "[STATION]", colors.econProfit
	elseif eType == "Custom" then
		return "[CAPTAIN'S LOG]", colors.maneuver
	end
	return "[" .. string.upper(eType) .. "]", colors.fontDim
end

local function getEntryIcon(eType)
	if eType == "System" then
		return icons.navigation_hyperspace or icons.system_map or icons.distance
	elseif eType == "Station" then
		return icons.comms or icons.bbs or icons.docking
	elseif eType == "Custom" then
		return icons.bookmark or icons.pencil
	end
	return icons.bookmark
end

local function renderFilterBar()
	ui.horizontalGroup(function()
		local pillLabels = {
			{ id = "ALL", label = "All Logs" },
			{ id = "System", label = l.LOG_SYSTEM or "Systems" },
			{ id = "Station", label = l.LOG_STATION or "Stations" },
			{ id = "Custom", label = l.LOG_CUSTOM or "Captain's Entries" },
		}

		for _, cat in ipairs(pillLabels) do
			local selected = (filterCategory == cat.id)
			local btnVariant = selected and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button(cat.label .. "##filterPill_" .. cat.id, Vector2(0, 0), btnVariant) then
				filterCategory = cat.id
			end
			ui.sameLine(0, widgetSizes.controlSpacing.x)
		end

		local sortLabel = earliestFirst and (l.LOG_EARLIEST_FIRST or "Earliest First") or "Latest First"
		if ui.button(sortLabel .. "##sortOrderBtn", Vector2(0, 0)) then
			earliestFirst = not earliestFirst
		end

		ui.sameLine(0, widgetSizes.controlSpacing.x)

		if ui.button((l.LOG_EXPORT or "Export") .. "##exportBtn", Vector2(0, 0)) then
			local incSet = { System = true, Custom = true, Station = true }
			FlightLogExporter.Export(incSet, earliestFirst, true, exportHtml)
		end
	end)

	ui.spacing()

	-- Quick Search Bar & Add Custom Log Entry
	ui.horizontalGroup(function()
		ui.icon(icons.search_lens, Vector2(ui.getTextLineHeight()), colors.fontDim)
		ui.sameLine(0, widgetSizes.itemInnerSpacing.x)
		ui.pushItemWidth(ui.getContentRegion().x - widgetSizes.clearButtonWidth - widgetSizes.controlSpacing.x)
		local val, changed = ui.inputText("##logSearch", searchText, "Search flight logs or enter query...", {})
		ui.popItemWidth()
		if changed then searchText = val end

		ui.sameLine(0, widgetSizes.controlSpacing.x)
		if ui.button("Clear##clearLogSearch", Vector2(widgetSizes.clearButtonWidth, 0)) then
			searchText = ""
		end
	end)

	ui.spacing()

	-- New entry row
	ui.horizontalGroup(function()
		ui.icon(icons.pencil, Vector2(ui.getTextLineHeight()), colors.uiPrimaryLight)
		ui.sameLine(0, widgetSizes.itemInnerSpacing.x)
		ui.pushItemWidth(-1)
		local text, entered = ui.inputText("##newLogEntry", "", "New entry: type note and press Enter to save to log...", {"EnterReturnsTrue"})
		ui.popItemWidth()
		if entered and text ~= "" then
			FlightLog.MakeCustomEntry(text)
		end
	end)
end

local logTable = Table.New("FlightLogTable", false, {
	columnCount = 1,
	iterator = ipairs,
	initTable = function(self)
		ui.setColumnWidth(0, self.style.size.x)
	end,
	renderItem = function(self, item, key)
		if key == 1 then
			ui.dummy(Vector2(0, 0))
		end

		local entry = item.entry
		local isSelected = (selectedLogIndex == item.idx)
		local textColor = isSelected and colors.uiPrimaryLight or colors.font
		local region = ui.getContentRegion()
		local eType = entry:GetType()

		ui.icon(getEntryIcon(eType), Vector2(ui.getTextLineHeight()), textColor)
		ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

		ui.withStyleColorsAndVars({ Text = textColor }, { ItemSpacing = widgetSizes.rowVerticalSpacing }, function()
			-- Line 1: Log Title in pionillium.heading
			ui.withFont(pionillium.heading, function()
				ui.text(item.title)
			end)

			-- Line 2: Details Metadata (Date/Time, System Path / Category Badge)
			ui.withFont(pionillium.details, function()
				local textHeight = ui.getTextLineHeight()
				local iconSize = Vector2(textHeight)

				ui.icon(icons.clock, iconSize, textColor)
				ui.sameLine()
				ui.text(item.timeStr ~= "" and item.timeStr or "---")

				if entry.systemp then
					ui.sameLine()
					ui.icon(icons.distance, iconSize, textColor)
					ui.sameLine()
					ui.text(ui.Format.SystemPath(entry.systemp))
				end

				local catBadge, catColor = getEntryCategoryBadge(eType)
				local catW = ui.calcTextSize(catBadge).x
				if region.x > catW then
					ui.sameLine(region.x - catW)
					ui.textColored(catColor, catBadge)
				end
			end)

			-- Line 3: Summary text preview
			ui.withFont(pionillium.body, function()
				local preview = entry.entry or ""
				if preview == "" and eType == "Custom" and entry.location and entry.location[1] then
					preview = entry.composeLocationString(entry.location)
				elseif preview == "" and eType == "Station" and entry.systemp then
					preview = entry:GetLocalizedName() .. " - " .. ui.Format.SystemPath(entry.systemp)
				elseif preview == "" and eType == "System" and entry.systemp then
					preview = entry:GetLocalizedName() .. " - " .. ui.Format.SystemPath(entry.systemp)
				end
				ui.text(preview)
				ui.dummy(widgetSizes.rowVerticalSpacing)
			end)
			ui.nextColumn()
		end)

		return isSelected and colors.tableSelection or colors.tableHighlight
	end,
	onClickItem = function(self, item, key)
		selectedLogIndex = item.idx
	end,
})

local function renderDetailsPanel(activeItem)
	if not activeItem or not activeItem.entry then
		ui.withFont(pionillium.details, function()
			local lineH = ui.getTextLineHeight()
			ui.icon(icons.bookmark, Vector2(lineH), colors.fontDim)
			ui.sameLine()
			ui.textColored(colors.fontDim, "Flight Log Standby")
		end)
		ui.separator()
		ui.spacing()
		ui.textColored(colors.fontDim, "Select an entry from the flight history ledger to inspect navigation records.")
		return
	end

	local entry = activeItem.entry
	local eType = entry:GetType()
	local catBadge, catColor = getEntryCategoryBadge(eType)

	-- Header line
	ui.withFont(pionillium.details, function()
		ui.textColored(catColor, catBadge)
		ui.sameLine()
		ui.textColored(colors.fontDim, "Record #" .. tostring(activeItem.idx) .. "  |  Origin: " .. (entry.systemp and ui.Format.SystemPath(entry.systemp) or "Unknown"))
	end)

	ui.spacing()

	-- Large Headline
	ui.withFont(pionillium.heading, function()
		ui.text(activeItem.title)
	end)

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Telemetry Data Pairs
	ui.withFont(pionillium.body, function()
		local pairs = entry:GetDataPairs(earliestFirst)
		for _, pair in ipairs(pairs) do
			if pair[1] and pair[2] then
				ui.textColored(colors.fontDim, string.gsub(pair[1], ":", "") .. ":")
				ui.sameLine()
				ui.text(pair[2])
			end
		end
	end)

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Custom User Note / Annotation
	ui.withFont(pionillium.heading, function()
		ui.textColored(colors.uiPrimaryLight, l.ENTRY or "CAPTAIN'S LOG ENTRY:")
	end)
	ui.spacing()

	if entry:CanHaveEntry() then
		if entering_text == activeItem.idx then
			ui.pushItemWidth(-1)
			local updated, done = ui.inputText("##editEntry_" .. activeItem.idx, entry:GetEntry(), {"EnterReturnsTrue"})
			ui.popItemWidth()
			if done then
				entry:UpdateEntry(updated)
				entering_text = false
			end
			ui.spacing()
			if ui.button("Save Entry##saveEntryBtn", Vector2(0, 0)) then
				entry:UpdateEntry(updated)
				entering_text = false
			end
		else
			local note = entry:GetEntry()
			if note and note ~= "" then
				ui.withFont(pionillium.body, function()
					ui.textWrapped(note)
				end)
			else
				ui.textColored(colors.fontDim, "No supplementary notes attached to this record.")
			end
			ui.spacing()
			if ui.button((l.EDIT or "Edit Note") .. "##editNoteBtn", Vector2(0, 0)) then
				entering_text = activeItem.idx
			end
		end
	end

	-- Deletion action
	if entry:CanBeRemoved() then
		ui.spacing()
		ui.separator()
		ui.spacing()
		if ui.button((l.REMOVE or "Remove Record") .. "##delEntryBtn", Vector2(0, 0), ui.theme.buttonColors.danger) then
			FlightLog:RemoveEntry(entry)
			selectedLogIndex = nil
			entering_text = false
		end
	end
end

local function drawScreen()
	local allEntries = {}
	local incSet = { System = true, Custom = true, Station = true }
	local idx = 0
	for entry in FlightLog:GetLogEntries(incSet, nil, earliestFirst) do
		idx = idx + 1
		local eType = entry:GetType()
		if filterCategory == "ALL" or filterCategory == eType then
			local title = getEntryTitle(entry)
			local timeStr = getEntryTime(entry)
			local note = entry:GetEntry()
			local match = true
			if searchText ~= "" then
				local query = string.lower(searchText)
				match = string.find(string.lower(title or ""), query, 1, true)
					or string.find(string.lower(timeStr or ""), query, 1, true)
					or string.find(string.lower(note or ""), query, 1, true)
			end
			if match then
				table.insert(allEntries, {
					idx = idx,
					entry = entry,
					title = title,
					timeStr = timeStr,
				})
			end
		end
	end

	-- Auto-select first if none selected or selection invalid
	if #allEntries > 0 then
		local found = false
		for _, item in ipairs(allEntries) do
			if item.idx == selectedLogIndex then
				found = true
				break
			end
		end
		if not found then
			selectedLogIndex = allEntries[1].idx
		end
	else
		selectedLogIndex = nil
	end

	local activeItem = nil
	for _, item in ipairs(allEntries) do
		if item.idx == selectedLogIndex then
			activeItem = item
			break
		end
	end

	local region = ui.getContentRegion()
	local leftWidth = region.x * 0.45

	-- Left Column: BBS/News matching 45% filter bar & log list
	ui.child("FlightLogListLeft", Vector2(leftWidth, 0), function()
		renderFilterBar()
		ui.spacing()
		logTable.style.size = Vector2(ui.getContentRegion().x, 0)
		logTable.items = allEntries
		logTable.selectedItem = activeItem
		logTable:render()
	end)

	ui.sameLine()

	-- Right Column: Report Page details
	ui.child("FlightLogDetailsRight", Vector2(0, 0), nil, commsChildFlags, function()
		renderDetailsPanel(activeItem)
	end)
end

InfoView:registerView({
	id = "captainsLog",
	name = l.FLIGHT_LOG,
	icon = ui.theme.icons.bookmark,
	showView = true,
	draw = drawScreen,
	refresh = function() end,
	debugReload = function()
		package.reimport('pigui.libs.table')
		package.reimport()
	end,
})
