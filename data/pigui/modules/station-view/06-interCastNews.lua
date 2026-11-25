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
local SystemPath  = require 'SystemPath'

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
local selectedDate = "ALL"
local selectedArticleId = nil
local searchText = ""
local face = nil
local lastFaceArticleId = nil

local CATEGORIES = {
	{ id = "ALL", label = "All News" },
	{ id = "FLAGGED", label = "! Important" },
	{ id = "FRONTLINE", label = "Frontline" },
	{ id = "HUMANITARIAN", label = "Humanitarian" },
	{ id = "MARKET", label = "Market Watch" },
	{ id = "POLITICS", label = "Politics" },
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

local function formatSystemWithDistance(art)
	if not art then return "Unknown" end
	local sysName = art.system or "Core Systems"
	local dist = nil

	if art.systemPath and Game.system then
		local ok, d = pcall(function() return art.systemPath:DistanceTo(Game.system) end)
		if ok and type(d) == "number" then dist = d end
	end

	if dist == nil and Game.system and sysName then
		if sysName == Game.system.name then
			dist = 0.0
		else
			local coreCoordinates = {
				["Sol"] = {0, 0, 0, 0},
				["Barnard's Star"] = {-1, 0, 0, 0},
				["Tau Ceti"] = {0, -2, -1, 0},
				["Wolf 359"] = {0, 0, 0, 0},
				["Ross 128"] = {0, 1, 0, 0},
				["Lalande 21185"] = {0, 0, 0, 0},
				["Epsilon Eridani"] = {1, -1, -1, 0},
				["Vega"] = {-3, -1, 1, 0},
				["Sirius"] = {1, 0, -1, 0},
			}
			local coords = coreCoordinates[sysName]
			if coords then
				local ok, path = pcall(SystemPath.New, coords[1], coords[2], coords[3], coords[4])
				if ok and path then
					local ok2, d = pcall(function() return path:DistanceTo(Game.system) end)
					if ok2 and type(d) == "number" then dist = d end
				end
			end
		end
	end

	if dist ~= nil then
		return string.format("%s (%.1fly)", sysName, dist)
	else
		return sysName
	end
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
			title = "Correspondent",
			org = "InterCast Wire Service",
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
		local isRead = InterCast.IsRead(art.id)
		local isFlagged = InterCast.IsFlagged(art.id)
		local region = ui.getContentRegion()

		-- Colors reflecting read vs unread vs selected status
		local headlineColor
		if isSelected then
			headlineColor = colors.uiPrimaryLight
		elseif not isRead then
			headlineColor = colors.white
		else
			headlineColor = Color(135, 150, 170, 190) -- Dimmed for read dispatches
		end

		local metaColor = isSelected and colors.uiPrimaryLight or (not isRead and Color(160, 185, 215, 230) or Color(100, 115, 135, 180))
		local iconColor = isSelected and colors.uiPrimaryLight or (not isRead and colors.uiPrimary or Color(90, 105, 125, 150))

		-- Line 1: Flag button + Status icon + Headline + Category Badge
		ui.withStyleVars({ ItemSpacing = widgetSizes.rowVerticalSpacing }, function()
			-- Exclamation Point Flag Toggle Button
			local flagBtnText = isFlagged and "!" or "·"
			local flagBtnStyle = isFlagged
				and { Button = Color(255, 190, 30, 220), Text = colors.black }
				or { Button = Color(25, 30, 42, 160), Text = not isRead and colors.uiPrimaryLight or Color(90, 105, 125, 160) }

			ui.withStyleColors(flagBtnStyle, function()
				if ui.button(flagBtnText .. "##flg" .. art.id, Vector2(22, 20)) then
					InterCast.ToggleFlagged(art.id)
				end
			end)
			if ui.isItemHovered() then
				ui.setTooltip(isFlagged and "Flagged as Important (!) — Click to unflag" or "Click to mark as Important (!)")
			end

			ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

			-- Dispatch Comms Icon (Bright for unread, dark for read)
			ui.icon(icons.comms, Vector2(ui.getTextLineHeight()), iconColor)
			ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

			-- Headline Text (single line, crisp)
			ui.withFont(pionillium.body, function()
				ui.textColored(headlineColor, art.headline)
			end)

			-- Category Badge (Right-aligned on Line 1)
			local catColor = getCategoryColor(art.category)
			local catText = "[" .. art.category .. "]"
			if art.urgent then catText = "[FLASH] " .. catText end
			local okDbg, DebugGalaxySim = pcall(require, 'modules.Debug.DebugGalaxySim')
			if okDbg and DebugGalaxySim and DebugGalaxySim.flags and DebugGalaxySim.flags.showNewsEffects then
				local fx = InterCast.GetArticleDebugEffects and InterCast.GetArticleDebugEffects(art)
				if fx and ((fx.stocks and #fx.stocks > 0) or (fx.commodities and #fx.commodities > 0) or fx.tax or fx.piracy) then
					catText = "[FX] " .. catText
				end
			end
			local catW = ui.calcTextSize(catText).x
			if region.x > catW + 40 then
				ui.sameLine(region.x - catW)
				ui.withFont(pionillium.details, function()
					ui.textColored(catColor, catText)
				end)
			end

			-- Line 2: Metadata (Clock + Date/Time, Location + System, Bureau)
			ui.withFont(pionillium.details, function()
				local textHeight = ui.getTextLineHeight()
				local iconSize = Vector2(textHeight)

				ui.dummy(Vector2(26, 0))
				ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

				ui.icon(icons.clock, iconSize, metaColor)
				ui.sameLine()
				local dtStr = art.timeStr and (art.date .. " " .. art.timeStr) or art.date
				ui.textColored(metaColor, dtStr)

				ui.sameLine(nil, 10)
				ui.icon(icons.distance, iconSize, metaColor)
				ui.sameLine()
				ui.textColored(metaColor, formatSystemWithDistance(art))

				ui.sameLine(nil, 10)
				ui.textColored(metaColor, "·  " .. (art.bureau or "InterCast Wire"))
			end)

			ui.nextColumn()
		end)

		return isSelected and colors.tableSelection or (isRead and Color(12, 15, 22, 160) or colors.tableHighlight)
	end,
	onClickItem = function(self, item, key)
		selectedArticleId = item.id
		InterCast.MarkRead(item.id)
	end,
})

local function renderFilterBar()
	ui.withStyleVars({ ItemSpacing = widgetSizes.controlSpacing }, function()
		-- Row 1: Search bar + Category tabs
		local iconSize = Vector2(ui.getTextLineHeight())
		ui.icon(icons.search_lens, iconSize, colors.fontDim)
		ui.sameLine()

		local hasSearch = searchText and searchText ~= ""
		local inputWidth = 180 * rescaleVector.x
		ui.pushItemWidth(inputWidth)
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

		ui.sameLine(nil, 8)

		for _, cat in ipairs(CATEGORIES) do
			local label = cat.label
			if cat.id == "FLAGGED" then
				local flgCount = InterCast.GetFlaggedCount()
				label = string.format("! Important (%d)", flgCount)
			end

			local selected = (selectedCategory == cat.id)
			local btnVariant = selected and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button(label .. "##CatBtn", Vector2(0, 0), btnVariant) then
				if selectedCategory ~= cat.id then
					selectedCategory = cat.id
					selectedArticleId = nil
					newsTable.scrollReset = true
				end
			end
			ui.sameLine()
		end
		ui.newLine()

		-- Row 2: Transmission Date Navigator Bar
		local uniqueDates = InterCast.GetUniqueDates()
		ui.withFont(pionillium.details, function()
			ui.textColored(colors.fontDim, "TRANSMISSION DATE:")
			ui.sameLine(nil, 6)

			local isAllDates = (selectedDate == "ALL")
			local allVariant = isAllDates and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button("ALL DATES##DateAll", Vector2(0, 0), allVariant) then
				selectedDate = "ALL"
				newsTable.scrollReset = true
			end

			for idx, d in ipairs(uniqueDates) do
				if idx <= 6 then -- Show up to 6 most recent unique dates as quick tabs
					ui.sameLine(nil, 4)
					local isSelDate = (selectedDate == d)
					local dVariant = isSelDate and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
					if ui.button(d .. "##Date" .. d, Vector2(0, 0), dVariant) then
						selectedDate = d
						newsTable.scrollReset = true
					end
				end
			end
		end)
	end)
end

local function drawInterCastNews()
	ui.withFont(pionillium.body, function()
		local region = ui.getContentRegion()
		local leftWidth = region.x * 0.45 -- Exact BBS 45% / 55% panel ratio

		-- Fetch and filter articles
		local allArticles = InterCast.GetArticles(selectedCategory == "FLAGGED" and "ALL" or selectedCategory)
		local filteredArticles = {}
		local query = searchText and string.lower(searchText) or ""
		for _, art in ipairs(allArticles) do
			local matchesCat = true
			if selectedCategory == "FLAGGED" then
				matchesCat = InterCast.IsFlagged(art.id)
			end

			local matchesDate = true
			if selectedDate ~= "ALL" then
				matchesDate = (art.date == selectedDate)
			end

			local matchesQuery = (query == "")
				or string.find(string.lower(art.headline or ""), query, 1, true)
				or string.find(string.lower(art.summary or ""), query, 1, true)
				or string.find(string.lower(art.bureau or ""), query, 1, true)
				or string.find(string.lower(art.system or ""), query, 1, true)

			if matchesCat and matchesDate and matchesQuery then
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

		if activeArticle then
			InterCast.MarkRead(activeArticle.id)
		end

		updateFace(activeArticle)

		local panelStyleColors = {
			WindowBg = ui.theme.styleColors.panel_900 or colors.windowBackground,
			Border = ui.theme.styleColors.primary_500 or colors.windowFrame,
		}

		ui.withStyleColors(panelStyleColors, function()
			-- Left Column: BBS-matching 45% filter bar & dispatches list
			ui.child("NewsListLeft", Vector2(leftWidth, 0), nil, commsChildFlags, function()
				local screenPos = ui.getCursorScreenPos()
				local font = pionillium.heading
				local frameSize = font.size + widgetSizes.itemSpacing.y * 2
				local iconSize = frameSize - 4
				local iconBg = ui.theme.buttonColors.selected.normal
				local titleBg = ui.theme.styleColors.panel_900 or colors.windowBackground
				local outlineCol = ui.theme.styleColors.primary_500 or colors.windowFrame

				ui.addRectFilled(screenPos, screenPos + Vector2(ui.getContentRegion().x, frameSize), titleBg, 0, ui.RoundCornersNone)
				ui.addRectFilled(screenPos, screenPos + Vector2(frameSize), iconBg, 0, ui.RoundCornersNone)
				ui.addRect(screenPos, screenPos + Vector2(ui.getContentRegion().x, frameSize), outlineCol, 0, ui.RoundCornersNone, 1.0)

				local iconPos = screenPos + Vector2(2, 2)
				ui.addIconSimple(iconPos, icons.bbs or icons.comms, Vector2(iconSize), colors.white)

				ui.withFont(font, function()
					ui.dummy(Vector2(frameSize))
					ui.sameLine()
					ui.alignTextToLineHeight()
					ui.textColored(colors.white, "Wire Dispatches")
				end)
				ui.spacing()
				ui.separator()
				ui.spacing()

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
				local screenPos = ui.getCursorScreenPos()
				local font = pionillium.heading
				local frameSize = font.size + widgetSizes.itemSpacing.y * 2
				local iconSize = frameSize - 4
				local iconBg = ui.theme.buttonColors.selected.normal
				local titleBg = ui.theme.styleColors.panel_900 or colors.windowBackground
				local outlineCol = ui.theme.styleColors.primary_500 or colors.windowFrame

				ui.addRectFilled(screenPos, screenPos + Vector2(ui.getContentRegion().x, frameSize), titleBg, 0, ui.RoundCornersNone)
				ui.addRectFilled(screenPos, screenPos + Vector2(frameSize), iconBg, 0, ui.RoundCornersNone)
				ui.addRect(screenPos, screenPos + Vector2(ui.getContentRegion().x, frameSize), outlineCol, 0, ui.RoundCornersNone, 1.0)

				local iconPos = screenPos + Vector2(2, 2)
				ui.addIconSimple(iconPos, icons.comms, Vector2(iconSize), colors.white)

				if not activeArticle then
					ui.withFont(font, function()
						ui.dummy(Vector2(frameSize))
						ui.sameLine()
						ui.alignTextToLineHeight()
						ui.textColored(colors.white, "InterCast Wire Service Standby")
					end)
					ui.spacing()
					ui.separator()
					ui.spacing()
					ui.textColored(colors.fontDim, "Select a news bulletin from the left dispatch ledger to read the full report.")
					return
				end

				-- Top Comms header line
				ui.withFont(font, function()
					ui.dummy(Vector2(frameSize))
					ui.sameLine()
					ui.alignTextToLineHeight()
					ui.textColored(colors.white, string.format("INTERCAST WIRE SERVICE   ·   [%s BULLETIN]", activeArticle.category))
					if activeArticle.urgent then
						ui.sameLine()
						ui.textColored(colors.alertRed, "·  [FLASH]")
					end

					local rightText = "SUB-SPACE RELAY   ·   " .. activeArticle.date .. (activeArticle.timeStr and (" " .. activeArticle.timeStr) or "")
					local avail = ui.getContentRegion().x
					local rightW = ui.calcTextSize(rightText).x
					if avail > rightW + frameSize + 10 then
						ui.sameLine(avail - rightW)
						ui.textColored(colors.fontDim, rightText)
					end
				end)

				ui.spacing()
				ui.separator()
				ui.spacing()

				-- Reader Body & Face layout
				local availableRegion = ui.getContentRegion()
				local faceWidth = math.min(widgetSizes.faceSize.x, availableRegion.x * 0.36)
				local textWidth = availableRegion.x - faceWidth - widgetSizes.itemSpacing.x

				ui.child("NewsArticleText", Vector2(textWidth, 0), function()
					-- Metadata line
					ui.withFont(pionillium.details, function()
						local dtHdr = activeArticle.date .. (activeArticle.timeStr and (" " .. activeArticle.timeStr) or "")
						ui.textColored(colors.fontDim, string.format("TRANSMISSION DATE: %s   |   ORIGIN: %s", dtHdr, formatSystemWithDistance(activeArticle)))
						ui.textColored(colors.fontDim, string.format("REPORTING BUREAU: %s", activeArticle.bureau))
					end)

					ui.spacing()
					ui.separator()
					ui.spacing()

					-- Headline with compact '!' Flag Toggle Button
					local isFlagged = InterCast.IsFlagged(activeArticle.id)
					local flagTooltip = isFlagged and "Flagged as important — Click to unmark" or "Mark important"
					local flagBtnStyle = isFlagged
						and {
							Button = Color(255, 190, 30, 220),
							ButtonHovered = Color(255, 205, 60, 240),
							ButtonActive = Color(220, 160, 20, 255),
							Text = colors.black
						}
						or {
							Button = Color(35, 42, 58, 200),
							ButtonHovered = Color(55, 65, 88, 220),
							ButtonActive = Color(25, 30, 42, 240),
							Text = colors.fontDim
						}

					ui.withStyleColors(flagBtnStyle, function()
						if ui.button("!##detailFlagBtn", Vector2(24, 24), nil, flagTooltip) then
							InterCast.ToggleFlagged(activeArticle.id)
						end
					end)
					ui.sameLine(0, widgetSizes.itemSpacing.x)
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

					-- Regional Commodity & Tax Impact Advisory Card if this system has an active crisis
					local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
					local sysCrisis = okMacro and MacroEngine and MacroEngine.GetCrisisForSystem(activeArticle.system)
					if sysCrisis then
						ui.spacing()
						ui.spacing()
						ui.child("CrisisEconCard", Vector2(textWidth, 90), nil, commsChildFlags, function()
							ui.textColored(colors.alertYellow, string.format("GALACTIC ECONOMIC INTELLIGENCE ADVISORY — %s SYSTEM:", string.upper(activeArticle.system)))
							ui.separator()
							if sysCrisis.type == "TARIFF_WAR" then
								ui.textColored(colors.white, "· Retaliatory Customs Tariffs: +25% to +40% Import Surcharge on High-Tech & Machinery.")
								ui.textColored(colors.white, "· System Tax Authority: Retaliatory import customs surcharge active (+10.0% system tax rate).")
							elseif sysCrisis.type == "BLOCKADE" then
								ui.textColored(colors.white, "· Naval Exclusion Zone: Starports offering +65% to +110% relief bounty to blockade runners.")
								ui.textColored(colors.white, "· System Tax Authority: Emergency naval blockade defense levy active (+5.0% system tax rate).")
							elseif sysCrisis.type == "OUTBREAK" then
								ui.textColored(colors.white, "· Medical Emergency: Vaccines, medicines, and air scrubbers purchasing at 2.2x to 2.8x standard margin.")
							elseif sysCrisis.type == "FAMINE" then
								ui.textColored(colors.white, "· Caloric Shortage: Starports paying 2.2x to 2.8x emergency tenders for grain, meat, and fertilizers.")
							elseif sysCrisis.type == "SUPPLY_GLUT" then
								ui.textColored(colors.white, "· Inventory Overhang: Spot raw ore and metal prices crushed -55% below baseline.")
								ui.textColored(colors.white, "· System Tax Authority: Emergency trade stimulus tax rebate (-2.0% tax relief).")
							elseif sysCrisis.type == "MINERAL_RUSH" then
								ui.textColored(colors.white, "· Mining Speculation: Mining machinery in surging demand; raw metal refiners actively buying.")
							else
								ui.textColored(colors.white, string.format("· Active Regional Crisis: %s (Severity Level %d)", sysCrisis.type, sysCrisis.severity or 1))
							end
						end)
					end

					-- Hidden Debug Details Overlay (toggled from Debug Screen -> News & Galaxy Sim)
					local okDbg, DebugGalaxySim = pcall(require, 'modules.Debug.DebugGalaxySim')
					if okDbg and DebugGalaxySim and DebugGalaxySim.flags and DebugGalaxySim.flags.showNewsEffects then
						local fx = InterCast.GetArticleDebugEffects and InterCast.GetArticleDebugEffects(activeArticle)
						if fx then
							ui.spacing()
							ui.child("NewsDebugEffectsCard", Vector2(textWidth, 0), nil, ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders', 'AutoResizeY' }, function()
								ui.textColored(colors.alertYellow, "[DEBUG] HIDDEN GALAXY & STOCK EFFECTS")
								ui.separator()
								ui.textColored(colors.fontDim, "Dispatch Source: " .. tostring(fx.source or "InterCast Wire"))
								if fx.crisis then
									ui.textColored(colors.uiPrimaryLight, string.format("Linked Crisis: %s in %s | Stage %d | Progress %.1f%% (+%.1f%%/day)",
										fx.crisis.type or "?", fx.crisis.system or "?", fx.crisis.severity or 1, fx.crisis.progress or 0, fx.crisis.progressRate or 0))
								end
								local hasAny = false
								if fx.stocks and #fx.stocks > 0 then
									hasAny = true
									ui.textColored(colors.white, "Affected Stocks:")
									for _, sf in ipairs(fx.stocks) do
										local dPct = sf.dailyDriftPct or 0
										local iPct = sf.instantPct or 0
										local col = ((dPct + iPct) >= 0) and colors.econProfit or colors.econLoss
										ui.textColored(col, string.format("  • %s (%s): Now %.2f Cr (Base %.2f) | %s",
											sf.ticker, sf.name or "", sf.currentPrice or 0, sf.basePrice or 0, sf.note or string.format("%+.2f%%/day", dPct)))
									end
								end
								if fx.commodities and #fx.commodities > 0 then
									hasAny = true
									ui.textColored(colors.white, "Affected Commodities:")
									for _, cf in ipairs(fx.commodities) do
										ui.textWrapped(string.format("  • %s: Buy %.2fx / Sell %.2fx (%s)",
											cf.label or "Commodities", cf.buyMult or 1.0, cf.sellMult or 1.0, cf.note or ""))
									end
								end
								if fx.tax then
									hasAny = true
									ui.textColored(colors.alertYellow, "Tax Modifier: " .. (fx.tax.note or string.format("%+.1f%%", fx.tax.rateDeltaPct or 0)))
								end
								if fx.piracy then
									hasAny = true
									ui.textColored(colors.alertRed, "Piracy / Security Modifier: " .. (fx.piracy.note or string.format("%+.1f%%", fx.piracy.threatDeltaPct or 0)))
								end
								if not hasAny and not fx.crisis then
									ui.textColored(colors.fontDim, "No mechanical modifiers (atmospheric wire dispatch).")
								end
							end)
						end
					end

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
	end)
end

StationView:registerView({
	id = "interCast",
	name = "InterCast News",
	icon = icons.comms or icons.bbs,
	securityMode = "signature",
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
