-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Game = require 'Game'
local Event = require 'Event'
local Space = require 'Space'
local SpaceStation = require 'SpaceStation'

local StationView = require 'pigui.views.station-view'
local Table = require 'pigui.libs.table'
local ChatForm = require 'pigui.libs.chat-form'
local PiImage = require 'pigui.libs.image'

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local l = Lang.GetResource("core")
local lui = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local icons = ui.theme.icons

local LY_IN_METERS = 9.4607304725808e15

local widgetSizes = ui.rescaleUI({
	chatButtonBase = Vector2(0, 22),
	chatButtonSize = Vector2(0, 22),
	itemSpacing = Vector2(14, 3),
	itemInnerSpacing = Vector2(6, 3),
	rowVerticalSpacing = Vector2(0, 3),
	marketHeight = 420,
	marketMinWidth = 960,
	minListWidth = 480,
	controlSpacing = Vector2(6, 6),
	filterComboWidth = 128,
	sortButtonSize = Vector2(24, 24),
	clearButtonWidth = 64,
}, Vector2(1920, 1080))

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local MISSION_ICONS = {
	assassination = true,
	combat = true,
	delivery = true,
	delivery_urgent = true,
	haul = true,
	haul_fast = true,
	scout_orbital = true,
	scout_surface = true,
	searchrescue = true,
	taxi = true,
	taxi_urgent = true,
}

local TRADE_ICONS = {
	goods_trader = true,
	second_hand = true,
}

local CATEGORIES = {
	{ id = "ALL",      label = lui.ALL },
	{ id = "MISSIONS", label = lui.MISSIONS },
	{ id = "SERVICES", label = lui.CATEGORY_SERVICES },
	{ id = "TRADE",    label = lui.CATEGORY_TRADE },
}

local SORT_MODES = {
	{ id = "TITLE",    label = lui.SORT_TITLE,    defaultAsc = true },
	{ id = "DISTANCE", label = lui.SORT_DISTANCE, defaultAsc = true },
	{ id = "DEADLINE", label = lui.SORT_DEADLINE, defaultAsc = true },
	{ id = "REWARD",   label = lui.SORT_REWARD,   defaultAsc = false },
}

local SORT_LABELS = {}
for i, mode in ipairs(SORT_MODES) do
	SORT_LABELS[i] = mode.label
end

local bulletinBoard
local chatForm
local activeRef
local activeAd
local searchText = ""
local categoryFilter = "ALL"
local sortIndex = 1
local sortAscending = SORT_MODES[1].defaultAsc

local images = {}

local function getAdCategory(ad)
	local icon = ad.icon
	if icon and MISSION_ICONS[icon] then
		return "MISSIONS"
	elseif icon and TRADE_ICONS[icon] then
		return "TRADE"
	end
	return "SERVICES"
end

local function getAdDistanceLy(ad)
	if not ad.location then
		return nil
	end
	if ad.location:isa("Body") then
		return Game.player:GetAltitudeRelTo(ad.location) / LY_IN_METERS
	elseif Game.system and ad.location:IsSameSystem(Game.system.path) then
		local body = ad.location.bodyIndex and Space.GetBody(ad.location.bodyIndex) or nil
		local alt = ad.dist or (body and Game.player:GetAltitudeRelTo(body)) or 0
		return alt / LY_IN_METERS
	else
		local playerSystem = Game.system or Game.player:GetHyperspaceTarget()
		return ad.location:DistanceTo(playerSystem)
	end
end

local function adActive(ref, ad)
	local station = Game.player:GetDockedWith()
	return not ((SpaceStation.adverts[station][ref] ~= nil and type(ad.isEnabled) == "function" and not ad.isEnabled(ref)) or Game.paused)
end

local function closeActiveComms()
	if chatForm then
		local station = Game.player and Game.player:GetDockedWith()
		if station and activeRef then
			station:UnlockAdvert(activeRef)
		end
		chatForm = nil
		activeRef = nil
		activeAd = nil
		if bulletinBoard then
			bulletinBoard.selectedItem = nil
		end
	end
end

local function refresh()
	local station = Game.player and Game.player:GetDockedWith()
	local ads = station and SpaceStation.adverts[station] or nil
	bulletinBoard.items = {}

	local query = searchText and string.lower(searchText) or ""
	for _, ad in pairs(ads or {}) do
		local matchesCategory = (categoryFilter == "ALL") or (getAdCategory(ad) == categoryFilter)
		local matchesSearch = (query == "")
			or string.find(string.lower(ad.title or ""), query, 1, true)
			or string.find(string.lower(ad.description or ""), query, 1, true)

		if matchesCategory and matchesSearch then
			table.insert(bulletinBoard.items, ad)
		end
	end

	table.sort(bulletinBoard.items, bulletinBoard.funcs.sortingFunction)
	bulletinBoard.selectedItem = activeAd
end

local function compareByTitle(aAd, bAd, asc)
	local aTitle = aAd.title or ""
	local bTitle = bAd.title or ""
	if aTitle ~= bTitle then
		if asc then
			return aTitle < bTitle
		else
			return aTitle > bTitle
		end
	end
	local aDesc = aAd.description or ""
	local bDesc = bAd.description or ""
	if aDesc ~= bDesc then
		if asc then
			return aDesc < bDesc
		else
			return aDesc > bDesc
		end
	end
	return false
end

local function compareOptionalNumber(aVal, bVal, asc, aAd, bAd)
	if aVal == nil and bVal == nil then
		return compareByTitle(aAd, bAd, true)
	elseif aVal == nil then
		return false
	elseif bVal == nil then
		return true
	elseif aVal ~= bVal then
		if asc then
			return aVal < bVal
		else
			return aVal > bVal
		end
	end
	return compareByTitle(aAd, bAd, true)
end

bulletinBoard = Table.New("BulletinBoardTable", false, {
	columnCount = 1,
	initTable = function(self)
		ui.setColumnWidth(0, self.style.size.x)
	end,
	renderItem = function(self, item, key)
		if key == 1 then	-- Insert padding or Orbiteer gets cut off on the first bbs item.
			ui.dummy(Vector2(0, 0))
		end
		local icon = item.icon or "default"
		local region = ui.getContentRegion()

		if(images[icon] == nil) then
			images[icon] = PiImage.New("icons/bbs/" .. icon .. ".png")
		end

		local active = adActive(item.__ref, item)
		local isSelected = (activeAd == item)
		local isLockedOut = (chatForm ~= nil and not isSelected)

		local adTextColor = colors.font
		if isLockedOut then
			adTextColor = colors.fontDisabled
		elseif not active then
			adTextColor = colors.fontDisabled
		end

		ui.withFont(pionillium.heading, function()
			images[icon]:Draw(Vector2(ui.getTextLineHeight()))
		end)
		ui.sameLine(0, widgetSizes.itemInnerSpacing.x)

		ui.withStyleColorsAndVars({Text = adTextColor}, {ItemSpacing = widgetSizes.rowVerticalSpacing}, function()
			ui.withFont(pionillium.heading, function()
				ui.text(item.title)
			end)

			ui.withFont(pionillium.details, function()
				local textHeight = ui.getTextLineHeight()
				local iconSize = Vector2(textHeight)

				local maxDuration = textHeight * 6 + widgetSizes.itemSpacing.x
				local maxDistance = textHeight * 5 + widgetSizes.itemSpacing.x
				local maxReward = textHeight * 5

				if item.due then
					ui.sameLine(region.x - maxDuration - maxDistance - maxReward)
					ui.icon(icons.clock, iconSize, adTextColor)
					ui.sameLine()
					ui.text(ui.Format.Duration(item.due - Game.time, 3))
				end

				if item.location then
					ui.sameLine(region.x - maxDistance - maxReward)
					ui.icon(icons.distance, iconSize, adTextColor)
					ui.sameLine()

					if item.location:isa("Body") then
						local alt = Game.player:GetAltitudeRelTo(item.location)
						ui.text(ui.Format.Distance(alt))
					elseif Game.system and item.location:IsSameSystem(Game.system.path) then
						local alt = item.dist or Game.player:GetAltitudeRelTo(Space.GetBody(item.location.bodyIndex))
						ui.text(ui.Format.Distance(alt))
					else
						local playerSystem = Game.system or Game.player:GetHyperspaceTarget()
						ui.text(string.format("%0.2f %s", item.location:DistanceTo(playerSystem), lui.LY))
					end
				end

				if item.reward then
					ui.sameLine(region.x - maxReward)
					ui.icon(icons.money, iconSize, adTextColor)
					ui.sameLine()
					ui.text(ui.Format.Number(item.reward, 0))
				end
			end)

			ui.withFont(pionillium.body, function()
				ui.textWrapped(item.description)
				-- add a little bit of extra vertical space between rows
				ui.dummy(widgetSizes.rowVerticalSpacing)
			end)
			ui.nextColumn()
		end)

		if isLockedOut then
			return colors.tableHighlightDisabled
		end
		return active and colors.tableHighlight or colors.tableHighlightDisabled
	end,
	postRender = function()
		local tl = ui.getWindowPos()
		local size = ui.getWindowSize()

		if Game.paused then
			ui.addRectFilled(tl, tl + size, colors.uiBackground:opacity(0.4), 0, ui.RoundCornersNone)

			ui.withFont(orbiteer.heading, function()
				local textSize = ui.calcTextSize(l.PAUSED)
				local textPos = tl + (size - textSize) * 0.5
				local padding = ui.theme.styles.WindowPadding

				ui.addRectFilled(textPos - padding, textPos + textSize + padding, colors.uiSurface, padding.x, ui.RoundCornersAll)

				ui.addText(textPos, colors.font, l.PAUSED)
			end)
		end
	end,
	onClickItem = function(self, item, key)
		if chatForm then
			return
		end

		local station = Game.player:GetDockedWith()
		local ref = item.__ref
		local ad = SpaceStation.adverts[station][ref]

		-- TODO: if the player is watching the BBS while an ad expires, the ad
		-- will be grayed-out but not removed until the player clicks on
		-- something.
		if not ad then
			refresh()
			return
		end

		if Game.paused then
			return
		end

		local chatFunc = function (form, option)
			return ad.onChat(form, ref, option)
		end
		local removeFunc = function ()
			station:RemoveAdvert(ref)
			refresh()
		end
		local closeFunc = function ()
			closeActiveComms()
			refresh()
		end
		local resizeFunc = function ()
			if chatForm then
				chatForm.style.contentWidth = nil
				widgetSizes.chatButtonSize(widgetSizes.chatButtonBase.x, widgetSizes.chatButtonBase.y)
			end
		end

		activeRef = ref
		activeAd = ad
		bulletinBoard.selectedItem = ad
		station:LockAdvert(ref)

		chatForm = ChatForm.New(chatFunc, removeFunc, closeFunc, resizeFunc, ref, StationView, {
			buttonSize = widgetSizes.chatButtonSize,
			marketSize = Vector2(0, widgetSizes.marketHeight),
			fitMarketToPanel = true,
		})
		chatForm.resizeFunc()
	end,
	sortingFunction = function(s1, s2)
		local mode = SORT_MODES[sortIndex].id
		if mode == "DISTANCE" then
			return compareOptionalNumber(getAdDistanceLy(s1), getAdDistanceLy(s2), sortAscending, s1, s2)
		elseif mode == "DEADLINE" then
			return compareOptionalNumber(s1.due, s2.due, sortAscending, s1, s2)
		elseif mode == "REWARD" then
			return compareOptionalNumber(s1.reward, s2.reward, sortAscending, s1, s2)
		end

		return compareByTitle(s1, s2, sortAscending)
	end,
	iterator = ipairs
})

local function renderFilterBar()
	ui.withStyleVars({ ItemSpacing = widgetSizes.controlSpacing }, function()
		local iconSize = Vector2(ui.getTextLineHeight())
		ui.icon(icons.search_lens, iconSize, colors.fontDim)
		ui.sameLine()

		local hasSearch = searchText and searchText ~= ""
		local inputWidth = ui.getContentRegion().x - (hasSearch and (widgetSizes.clearButtonWidth + widgetSizes.controlSpacing.x) or 0)
		ui.pushItemWidth(math.max(80, inputWidth))
		local updatedText, changed = ui.inputText("##searchText", searchText, lui.BBS_FILTER_HINT, {})
		ui.popItemWidth()
		if changed then
			searchText = updatedText
			refresh()
		end

		if hasSearch then
			ui.sameLine()
			if ui.button(lui.CLEAR, Vector2(widgetSizes.clearButtonWidth, 0)) then
				searchText = ""
				refresh()
			end
		end

		local btnPaddingX = ui.theme.styles.ButtonPadding.x * 2
		local pillsWidth = 0
		for i, cat in ipairs(CATEGORIES) do
			if i > 1 then
				ui.sameLine()
				pillsWidth = pillsWidth + widgetSizes.controlSpacing.x
			end
			pillsWidth = pillsWidth + ui.calcTextSize(cat.label).x + btnPaddingX
			local selected = (categoryFilter == cat.id)
			local btnVariant = selected and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button(cat.label, Vector2(0, 0), btnVariant) then
				if categoryFilter ~= cat.id then
					categoryFilter = cat.id
					refresh()
				end
			end
		end

		local sortLabelW = ui.calcTextSize(lui.SORT_BY).x
		local rightControlsW = sortLabelW + widgetSizes.filterComboWidth + widgetSizes.sortButtonSize.x + widgetSizes.controlSpacing.x * 2
		local availX = ui.getContentRegion().x
		if availX - pillsWidth >= rightControlsW + widgetSizes.controlSpacing.x then
			ui.sameLine(availX - rightControlsW)
		end

		ui.textColored(colors.fontDim, lui.SORT_BY)
		ui.sameLine()
		ui.pushItemWidth(widgetSizes.filterComboWidth)
		local sortChanged, newSortIdx = ui.combo("##bbsSort", sortIndex - 1, SORT_LABELS)
		ui.popItemWidth()
		if sortChanged then
			sortIndex = newSortIdx + 1
			sortAscending = SORT_MODES[sortIndex].defaultAsc
			refresh()
		end

		ui.sameLine()
		local dirIcon = sortAscending and icons.chevron_up or icons.chevron_down
		if ui.iconButton("##bbsSortDir", dirIcon, nil, ui.theme.buttonColors.default, widgetSizes.sortButtonSize) then
			sortAscending = not sortAscending
			refresh()
		end
	end)
	ui.separator()
end

local function renderCommsStandby()
	ui.withFont(pionillium.details, function()
		local lineH = ui.getTextLineHeight()
		ui.icon(icons.comms, Vector2(lineH), colors.fontDim)
		ui.sameLine()
		ui.textColored(colors.fontDim, lui.COMMS_STANDBY)
		ui.sameLine()
		local protoW = ui.calcTextSize(lui.COMMS_PROTOCOL).x
		local avail = ui.getContentRegion().x
		if avail > protoW then
			ui.addCursorPos(Vector2(avail - protoW, 0))
		end
		ui.textColored(colors.fontDim, lui.COMMS_PROTOCOL)
	end)
	ui.separator()
	ui.spacing()
	ui.textColored(colors.fontDim, lui.BBS_STANDBY_HINT)
end

local function renderBulletinBoard()
	if chatForm and not (Game.player and Game.player:GetDockedWith()) then
		closeActiveComms()
	end

	ui.withFont(pionillium.body, function()
		local region = ui.getContentRegion()
		local leftWidth = region.x * 0.45
		if chatForm and chatForm.market then
			leftWidth = math.max(widgetSizes.minListWidth, math.min(region.x * 0.38, region.x - widgetSizes.marketMinWidth))
		end

		ui.child("BulletinBoardLeft", Vector2(leftWidth, 0), function()
			renderFilterBar()
			bulletinBoard.style.size = Vector2(ui.getContentRegion().x, 0)
			bulletinBoard:render()
		end)
		ui.sameLine()

		ui.child("BulletinBoardComms", Vector2(0, 0), nil, commsChildFlags, function()
			if chatForm then
				chatForm:render()
			else
				renderCommsStandby()
			end
		end)
	end)
end

Event.Register("onShipUndocked", function(ship)
	if ship:IsPlayer() then
		closeActiveComms()
	end
end)

Event.Register("onGameEnd", closeActiveComms)

StationView:registerView({
	id = "bulletinBoard",
	name = lui.BULLETIN_BOARD,
	icon = ui.theme.icons.bbs,
	showView = true,
	draw = renderBulletinBoard,
	refresh = function ()
		closeActiveComms()
		refresh()
		bulletinBoard.scrollReset = true
	end,
	debugReload = function()
		closeActiveComms()
		package.reimport()
	end
})
