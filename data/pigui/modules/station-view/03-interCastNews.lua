-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game        = require 'Game'
local ui          = require 'pigui'
local StationView = require 'pigui.views.station-view'
local InterCast   = require 'modules.InterCast.InterCast'
local Table       = require 'pigui.libs.table'
local Format      = require 'Format'
local Rand        = require 'Rand'
local Character   = require 'Character'
local PiGuiFace   = require 'pigui.libs.face'

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)
local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(14, 3),
	itemInnerSpacing = Vector2(6, 3),
	rowVerticalSpacing = Vector2(0, 3),
	controlSpacing = Vector2(6, 6),
	clearButtonWidth = 64,
	faceSize = Vector2(320, 360),
}, Vector2(1920, 1080))

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local selectedCategory = "ALL"
local selectedArticleId = nil
local searchText = ""
local face = nil
local lastFaceArticleId = nil

local CATEGORIES = {
	{ id = "ALL", label = "ALL NEWS" },
	{ id = "FRONTLINE", label = "FRONTLINE" },
	{ id = "HUMANITARIAN", label = "HUMANITARIAN" },
	{ id = "MARKET", label = "MARKET WATCH" },
	{ id = "POLITICS", label = "POLITICS" },
}

local function getCategoryColor(cat)
	if cat == "FRONTLINE" then
		return colors.alertRed
	elseif cat == "HUMANITARIAN" then
		return colors.uiPrimaryLight
	elseif cat == "MARKET" then
		return colors.econProfit
	elseif cat == "POLITICS" then
		return colors.white
	end
	return colors.fontDim
end

local function updateFace(art)
	if not art then return end
	if face and lastFaceArticleId == art.id then return end

	lastFaceArticleId = art.id
	local station = Game.player and Game.player:GetDockedWith()
	local seed = (station and station.seed or "news") .. "-" .. (art.bureau or "bureau")
	local rand = Rand.New(seed)
	face = PiGuiFace.New(
		Character.New({
			name = art.bureau,
			title = "CORRESPONDENT",
			org = "INTERCAST WIRE SERVICE",
			role = "journalist"
		}, rand),
		{ itemSpacing = widgetSizes.itemSpacing }
	)
end

local newsTable = Table.New("NewsDispatchTable", false, {
	columnCount = 1,
	iterator = ipairs,
	initTable = function(self)
		ui.setColumnWidth(0, self.style.size.x)
	end,
	renderItem = function(self, art, key)
		if key == 1 then
			ui.dummy(Vector2(0, 0))
		end

		local isSelected = (selectedArticleId == art.id)
		local textColor = isSelected and colors.uiPrimaryLight or colors.font
		local region = ui.getContentRegion()

		ui.icon(icons.comms, Vector2(ui.getTextLineHeight()), textColor)
		ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

		ui.withStyleColorsAndVars({ Text = textColor }, { ItemSpacing = widgetSizes.rowVerticalSpacing }, function()
			-- Line 1: Headline in pionillium.heading (tight single line, no wrap, matching BBS)
			ui.withFont(pionillium.heading, function()
				ui.text(art.headline)
			end)

			-- Line 2: Details metadata (clock icon + date, location icon + system, category badge)
			ui.withFont(pionillium.details, function()
				local textHeight = ui.getTextLineHeight()
				local iconSize = Vector2(textHeight)

				ui.icon(icons.clock, iconSize, textColor)
				ui.sameLine()
				ui.text(art.date)

				ui.sameLine()
				ui.icon(icons.distance, iconSize, textColor)
				ui.sameLine()
				ui.text(art.system)

				local catColor = getCategoryColor(art.category)
				local catText = "[" .. art.category .. "]"
				if art.urgent then catText = "[FLASH] " .. catText end
				local catW = ui.calcTextSize(catText).x
				if region.x > catW then
					ui.sameLine(region.x - catW)
					ui.textColored(catColor, catText)
				end
			end)

			-- Line 3: Summary lead in pionillium.body (tight single line, no wrap, matching BBS)
			ui.withFont(pionillium.body, function()
				ui.text(art.summary)
				ui.dummy(widgetSizes.rowVerticalSpacing)
			end)
			ui.nextColumn()
		end)

		return isSelected and colors.tableSelection or colors.tableHighlight
	end,
	onClickItem = function(self, item, key)
		selectedArticleId = item.id
	end,
})

local function renderFilterBar()
	ui.withStyleVars({ ItemSpacing = widgetSizes.controlSpacing }, function()
		local iconSize = Vector2(ui.getTextLineHeight())
		ui.icon(icons.search_lens, iconSize, colors.fontDim)
		ui.sameLine()

		local hasSearch = searchText and searchText ~= ""
		local inputWidth = ui.getContentRegion().x - (hasSearch and (widgetSizes.clearButtonWidth + widgetSizes.controlSpacing.x) or 0)
		ui.pushItemWidth(math.max(80, inputWidth))
		local updatedText, changed = ui.inputText("##newsSearch", searchText, "Search bulletins...", {})
		ui.popItemWidth()
		if changed then
			searchText = updatedText
			newsTable.scrollReset = true
		end

		if hasSearch then
			ui.sameLine()
			if ui.button("Clear", Vector2(widgetSizes.clearButtonWidth, 0)) then
				searchText = ""
				newsTable.scrollReset = true
			end
		end

		for i, cat in ipairs(CATEGORIES) do
			if i > 1 then
				ui.sameLine()
			end
			local selected = (selectedCategory == cat.id)
			local btnVariant = selected and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button(cat.label, Vector2(0, 0), btnVariant) then
				if selectedCategory ~= cat.id then
					selectedCategory = cat.id
					selectedArticleId = nil
					newsTable.scrollReset = true
				end
			end
		end
	end)
end

local function drawInterCastNews()
	ui.withFont(pionillium.body, function()
		local region = ui.getContentRegion()
		local leftWidth = region.x * 0.45 -- Exact BBS 45% / 55% panel ratio

		-- Fetch and filter articles
		local allArticles = InterCast.GetArticles(selectedCategory)
		local filteredArticles = {}
		local query = searchText and string.lower(searchText) or ""
		for _, art in ipairs(allArticles) do
			if query == ""
				or string.find(string.lower(art.headline or ""), query, 1, true)
				or string.find(string.lower(art.summary or ""), query, 1, true)
				or string.find(string.lower(art.bureau or ""), query, 1, true)
			then
				table.insert(filteredArticles, art)
			end
		end

		-- Default selection
		if #filteredArticles > 0 then
			local found = false
			for _, art in ipairs(filteredArticles) do
				if art.id == selectedArticleId then
					found = true
					break
				end
			end
			if not found then
				selectedArticleId = filteredArticles[1].id
			end
		else
			selectedArticleId = nil
		end

		local activeArticle = nil
		for _, art in ipairs(filteredArticles) do
			if art.id == selectedArticleId then
				activeArticle = art
				break
			end
		end

		updateFace(activeArticle)

		-- Left Column: BBS-matching 45% filter bar & dispatches list
		ui.child("NewsListLeft", Vector2(leftWidth, 0), function()
			renderFilterBar()
			ui.spacing()
			newsTable.style.size = Vector2(ui.getContentRegion().x, 0)
			newsTable.items = filteredArticles
			newsTable.selectedItem = activeArticle
			newsTable:render()
		end)

		ui.sameLine()

		-- Right Column: BBS-matching details child with borders and padding
		ui.child("NewsDetailsComms", Vector2(0, 0), nil, commsChildFlags, function()
			if not activeArticle then
				ui.withFont(pionillium.details, function()
					local lineH = ui.getTextLineHeight()
					ui.icon(icons.comms, Vector2(lineH), colors.fontDim)
					ui.sameLine()
					ui.textColored(colors.fontDim, "INTERCAST WIRE SERVICE STANDBY")
				end)
				ui.separator()
				ui.spacing()
				ui.textColored(colors.fontDim, "Select a news bulletin from the left dispatch ledger to read the full report.")
				return
			end

			local catColor = getCategoryColor(activeArticle.category)

			-- Top Comms header line
			ui.withFont(pionillium.details, function()
				local lineH = ui.getTextLineHeight()
				ui.icon(icons.comms, Vector2(lineH), colors.uiPrimaryLight)
				ui.sameLine()
				ui.textColored(colors.uiPrimaryLight, string.format("INTERCAST WIRE SERVICE   ·   [%s BULLETIN]", activeArticle.category))
				if activeArticle.urgent then
					ui.sameLine()
					ui.textColored(colors.alertRed, "·  [FLASH]")
				end

				local rightText = "SUB-SPACE RELAY   ·   " .. activeArticle.date
				local avail = ui.getContentRegion().x
				local rightW = ui.calcTextSize(rightText).x
				if avail > rightW then
					ui.sameLine(avail - rightW)
				end
				ui.textColored(colors.fontDim, rightText)
			end)

			ui.separator()
			ui.spacing()

			-- Reader Body & Face layout
			local availableRegion = ui.getContentRegion()
			local faceWidth = math.min(widgetSizes.faceSize.x, availableRegion.x * 0.36)
			local textWidth = availableRegion.x - faceWidth - widgetSizes.itemSpacing.x

			ui.child("NewsArticleText", Vector2(textWidth, 0), function()
				-- Metadata line
				ui.withFont(pionillium.details, function()
					ui.textColored(colors.fontDim, string.format("TRANSMISSION DATE: %s   |   ORIGIN: %s", activeArticle.date, activeArticle.system))
					ui.textColored(colors.fontDim, string.format("REPORTING BUREAU: %s", activeArticle.bureau))
				end)

				ui.spacing()
				ui.separator()
				ui.spacing()

				-- Headline (wrapped in details view)
				ui.withFont(orbiteer.heading, function()
					ui.textWrapped(activeArticle.headline)
				end)

				ui.spacing()
				ui.separator()
				ui.spacing()

				-- Summary Lead
				ui.withFont(pionillium.heading, function()
					ui.textColored(colors.uiPrimaryLight, activeArticle.summary)
				end)

				ui.spacing()
				ui.separator()
				ui.spacing()

				-- Full Body Text
				ui.withFont(pionillium.body, function()
					ui.textWrapped(activeArticle.body)
				end)

				ui.spacing()
				ui.spacing()
				ui.separator()
				ui.spacing()

				-- InterCast Broadcast Covenant Notice
				ui.withFont(pionillium.details, function()
					ui.textColored(colors.fontDim, "INTERCAST BROADCAST COVENANT:")
					ui.textWrapped("InterCast wire transmissions are broadcast continuously across sub-space transponder relays. Commercial pilots may monitor regional dispatches in-flight via the cockpit telemetry ticker.")
				end)
			end)

			ui.sameLine(0, widgetSizes.itemSpacing.x)

			-- Correspondent Face / Organisation Badge
			ui.child("NewsFaceCol", Vector2(faceWidth, 0), function()
				if face then
					face:render()
				end
			end)
		end)
	end)
end

StationView:registerView({
	id = "interCast",
	name = "InterCast News",
	icon = icons.comms or icons.bbs,
	showView = true,
	draw = drawInterCastNews,
	refresh = function(self)
		local station = Game.player and Game.player:GetDockedWith()
		if station then
			updateFace()
		end
	end,
	debugReload = function()
		package.reimport('pigui.libs.table')
		package.reimport()
	end
})
