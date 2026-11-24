-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Table = require 'pigui.libs.table'
local InfoView = require 'pigui.views.info-view'
local Lang = require 'Lang'
local Format = require 'Format'
local FlightLog = require 'modules.FlightLog.FlightLog'
local FlightLogExporter = require 'modules.FlightLog.FlightLogExporter'
local PlayerState = require 'PlayerState'
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

local function getBookmarkForPath(path)
	if not path then return nil, nil end
	local ok, sysPath = pcall(function() return path:SystemOnly() end)
	if not ok or not sysPath then return nil, nil end
	local bookmarks = PlayerState.GetBookmarks()
	for id, b in pairs(bookmarks) do
		if b.path and b.path:IsSameSystem(sysPath) then
			return id, b
		end
	end
	return nil, nil
end

local function toggleBookmarkForPath(path, title)
	if not path then return end
	local id, b = getBookmarkForPath(path)
	if id then
		if b and b.isHome then
			return
		end
		PlayerState.RemoveBookmark(id)
	else
		local ok, sysPath = pcall(function() return path:SystemOnly() end)
		if not ok or not sysPath then return end
		local sys = sysPath:GetStarSystem()
		local note = title or (sys and sys.shortDescription) or "Commander's Log Bookmark"
		PlayerState.AddBookmark(sysPath, { note = note })
	end
end

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
	elseif eType == "Transaction" then
		return entry.title or entry:GetLocalizedName()
	end
	return entry:GetLocalizedName()
end

local function getEntryCategoryBadge(eType, entry)
	if eType == "System" then
		return "[SYSTEM]", colors.uiPrimaryLight
	elseif eType == "Station" then
		return "[STATION]", colors.econProfit
	elseif eType == "Custom" then
		return "[COMMANDER'S LOG]", colors.maneuver
	elseif eType == "Transaction" then
		local cat = entry and entry.category
		local catBadge = cat and ("[" .. cat .. "]") or "[FINANCIAL]"
		local catColor = colors.uiPrimaryLight
		if cat == "SHIP_LOSS" then
			catColor = colors.alertRed or colors.danger
		elseif cat == "INCARCERATION" then
			catColor = colors.alertOrange or colors.alertYellow
		elseif cat == "INTERDICTION" then
			catColor = colors.alertYellow
		elseif cat == "TAX" then
			catColor = colors.alertYellow
		elseif cat == "SHIP" or cat == "INSURANCE" then
			catColor = colors.uiPrimaryLight
		elseif entry and entry.amount and entry.amount >= 0 then
			catColor = colors.econProfit
		else
			catColor = colors.alertYellow
		end
		return catBadge, catColor
	end
	return "[" .. string.upper(eType) .. "]", colors.fontDim
end

local function getEntryIcon(eType, entry)
	if eType == "System" then
		return icons.navigation_hyperspace or icons.system_map or icons.distance
	elseif eType == "Station" then
		return icons.comms or icons.bbs or icons.docking
	elseif eType == "Custom" then
		return icons.bookmark or icons.pencil
	elseif eType == "Transaction" then
		local cat = entry and entry.category
		if cat == "SHIP_LOSS" then
			return icons.retrograde or icons.alert1
		elseif cat == "INCARCERATION" then
			return icons.shield or icons.docking
		elseif cat == "INTERDICTION" then
			return icons.combattarget or icons.maneuver
		elseif cat == "SHIP" or cat == "INSURANCE" then
			return icons.ship_cargo or icons.bbs
		end
		return icons.cash or icons.bbs or icons.info
	end
	return icons.bookmark
end

local function renderFilterBar()
	ui.horizontalGroup(function()
		local pillLabels = {
			{ id = "ALL", label = "All Logs" },
			{ id = "Transaction", label = "Operations & Events" },
			{ id = "System", label = l.LOG_SYSTEM or "Systems" },
			{ id = "Station", label = l.LOG_STATION or "Stations" },
			{ id = "Custom", label = l.LOG_CUSTOM or "Commander's Entries" },
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
			local incSet = { System = true, Custom = true, Station = true, Transaction = true }
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

		ui.icon(getEntryIcon(eType, entry), Vector2(ui.getTextLineHeight()), textColor)
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

					local bId = getBookmarkForPath(entry.systemp)
					local bmTooltip = bId and "Bookmarked in Sector Map (Click to remove)" or "Bookmark system in Sector Map"
					ui.sameLine(nil, 6)
					if ui.iconButton("##bmListBtn_" .. tostring(item.idx), icons.bookmark, bmTooltip, bId ~= nil, Vector2(textHeight, textHeight), Vector2(1, 1)) then
						toggleBookmarkForPath(entry.systemp, item.title)
					end
				end

				local catBadge, catColor = getEntryCategoryBadge(eType, entry)
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
				elseif preview == "" and eType == "Transaction" then
					local amtStr = (entry.amount and entry.amount >= 0 and "+" or "") .. Format.Money(entry.amount or 0)
					local stStr = (entry.stationName and entry.stationName ~= "") and (" @ " .. entry.stationName) or ""
					preview = string.format("Amount: %s%s | Balance: %s", amtStr, stStr, Format.Money(entry.balance or 0))
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
			ui.textColored(colors.fontDim, "Commander's Log Standby")
		end)
		ui.separator()
		ui.spacing()
		ui.textColored(colors.fontDim, "Select an entry from the ledger to inspect flight and transaction records.")
		return
	end

	local entry = activeItem.entry
	local eType = entry:GetType()
	local catBadge, catColor = getEntryCategoryBadge(eType, entry)

	-- Header line
	ui.withFont(pionillium.details, function()
		ui.textColored(catColor, catBadge)
		ui.sameLine()
		ui.textColored(colors.fontDim, "Record #" .. tostring(activeItem.idx) .. "  |  Origin: " .. (entry.systemp and ui.Format.SystemPath(entry.systemp) or "Unknown"))
		if entry.systemp then
			local bId = getBookmarkForPath(entry.systemp)
			local bmTooltip = bId and "Bookmarked in Sector Map (Click to remove)" or "Bookmark system in Sector Map"
			ui.sameLine(nil, 8)
			if ui.iconButton("##bmDetailsOrigin", icons.bookmark, bmTooltip, bId ~= nil, Vector2(ui.getTextLineHeight() + 2, ui.getTextLineHeight() + 2), Vector2(2, 2)) then
				toggleBookmarkForPath(entry.systemp, activeItem.title)
			end
		end
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
		for pIdx, pair in ipairs(pairs) do
			if pair[1] and pair[2] then
				ui.textColored(colors.fontDim, string.gsub(pair[1], ":", "") .. ":")
				ui.sameLine()
				ui.text(pair[2])
				if entry.systemp and (string.find(pair[1], "System") or string.find(pair[1], "Station") or string.find(pair[1], "Facility") or string.find(pair[1], "Location")) then
					local bId = getBookmarkForPath(entry.systemp)
					local bmTooltip = bId and "Bookmarked in Sector Map (Click to remove)" or "Bookmark system in Sector Map"
					ui.sameLine(nil, 6)
					if ui.iconButton("##bmPairBtn_" .. tostring(pIdx), icons.bookmark, bmTooltip, bId ~= nil, Vector2(ui.getTextLineHeight(), ui.getTextLineHeight()), Vector2(1, 1)) then
						toggleBookmarkForPath(entry.systemp, activeItem.title)
					end
				end
			end
		end
	end)

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Custom User Note / Annotation
	ui.withFont(pionillium.heading, function()
		ui.textColored(colors.uiPrimaryLight, l.ENTRY or "COMMANDER'S LOG ENTRY:")
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
			if entry.systemp then
				ui.sameLine(nil, 8)
				local bId = getBookmarkForPath(entry.systemp)
				local bmLabel = bId and "Remove Sector Map Bookmark" or "Bookmark System in Sector Map"
				local bmStyle = bId and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
				if ui.button(bmLabel .. "##bmDedicatedAction", Vector2(0, 0), bmStyle) then
					toggleBookmarkForPath(entry.systemp, activeItem.title)
				end
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
	local incSet = { System = true, Custom = true, Station = true, Transaction = true }
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
	ui.child("FlightLogListLeft", Vector2(leftWidth, 0), nil, commsChildFlags, function()
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
