-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Game = require 'Game'
local Event = require 'Event'
local Space = require 'Space'
local SpaceStation = require 'SpaceStation'

local StationView = require 'pigui.views.station-view'
local Table = require 'pigui.libs.table'
local SortBar = require 'pigui.libs.sort-bar'
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
	{ id = "TITLE",    label = lui.SORT_TITLE,    defaultDir = 1 },
	{ id = "DISTANCE", label = lui.SORT_DISTANCE, defaultDir = 1 },
	{ id = "DEADLINE", label = lui.SORT_DEADLINE, defaultDir = 1 },
	{ id = "REWARD",   label = lui.SORT_REWARD,   defaultDir = -1 },
}

local bulletinBoard
local chatForm
local activeStation
local activeRef
local activeAd
local searchText = ""
local categoryFilter = "ALL"
local sortId = "TITLE"
local sortDir = 1

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
	if activeRef or chatForm then
		local station = activeStation or (Game.player and Game.player:GetDockedWith())
		if activeRef and SpaceStation.lockedAdvert == activeRef then
			if station and station:exists() then
				station:UnlockAdvert(activeRef)
			end
			if SpaceStation.lockedAdvert == activeRef then
				SpaceStation.lockedAdvert = nil
				SpaceStation.advertLockCount = 0
				SpaceStation.removeOnReleased = false
			end
		end
		chatForm = nil
		activeStation = nil
		activeRef = nil
		activeAd = nil
		if bulletinBoard then
			bulletinBoard.selectedItem = nil
		end
	end
end

local function refresh()
	local station = Game.player and Game.player:GetDockedWith()
	if station and station.CleanExpiredAdverts then
		station:CleanExpiredAdverts(Game.time)
	end
	local ads = station and SpaceStation.adverts[station] or nil
	bulletinBoard.items = {}

	local now = Game.time or 0
	local query = searchText and string.lower(searchText) or ""
	for _, ad in pairs(ads or {}) do
		local expired = (type(ad.due) == "number" and (ad.due - now) <= 0)
			or (type(ad.timeout) == "number" and (ad.timeout - now) <= 0)
		local matchesCategory = (categoryFilter == "ALL") or (getAdCategory(ad) == categoryFilter)
		local matchesSearch = (query == "")
			or string.find(string.lower(ad.title or ""), query, 1, true)
			or string.find(string.lower(ad.description or ""), query, 1, true)

		if not expired and matchesCategory and matchesSearch then
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

		local adTextColor = colors.font
		if not active then
			adTextColor = colors.fontDisabled
		elseif isSelected then
			adTextColor = colors.uiPrimaryLight
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
					ui.text(ui.Format.Duration(math.max(0, item.due - Game.time), 3))
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

		if isSelected then
			return colors.tableSelection
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
		local station = Game.player:GetDockedWith()
		local ref = item.__ref

		if chatForm and activeRef == ref and activeStation == station then
			return
		end

		if chatForm or activeRef or SpaceStation.lockedAdvert ~= nil then
			local prevRemoveOnReleased = SpaceStation.removeOnReleased
			closeActiveComms()
			if SpaceStation.lockedAdvert ~= nil then
				SpaceStation.lockedAdvert = nil
				SpaceStation.advertLockCount = 0
				SpaceStation.removeOnReleased = false
			end
			if prevRemoveOnReleased then
				refresh()
			end
		end

		local ad = station and SpaceStation.adverts[station] and SpaceStation.adverts[station][ref]

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

		activeStation = station
		activeRef = ref
		activeAd = ad
		bulletinBoard.selectedItem = ad
		station:LockAdvert(ref)

		local ok, form = pcall(ChatForm.New, chatFunc, removeFunc, closeFunc, resizeFunc, ref, StationView, {
			buttonSize = widgetSizes.chatButtonSize,
			marketSize = Vector2(0, widgetSizes.marketHeight),
			fitMarketToPanel = true,
		})
		if not ok then
			closeActiveComms()
			error(form, 0)
		end
		if activeRef ~= ref then
			return
		end
		chatForm = form
		chatForm.resizeFunc()
	end,
	sortingFunction = function(s1, s2)
		local asc = (sortDir > 0)
		if sortId == "DISTANCE" then
			return compareOptionalNumber(getAdDistanceLy(s1), getAdDistanceLy(s2), asc, s1, s2)
		elseif sortId == "DEADLINE" then
			return compareOptionalNumber(s1.due, s2.due, asc, s1, s2)
		elseif sortId == "REWARD" then
			return compareOptionalNumber(s1.reward, s2.reward, asc, s1, s2)
		end

		return compareByTitle(s1, s2, asc)
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

		for i, cat in ipairs(CATEGORIES) do
			if i > 1 then
				ui.sameLine()
			end
			local selected = (categoryFilter == cat.id)
			local btnVariant = selected and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
			if ui.button(cat.label, Vector2(0, 0), btnVariant) then
				if categoryFilter ~= cat.id then
					categoryFilter = cat.id
					refresh()
				end
			end
		end

		local newId, newDir, changed = SortBar.draw("BBSSort", SORT_MODES, sortId, sortDir)
		if changed then
			sortId = newId
			sortDir = newDir
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
	local station = Game.player and Game.player:GetDockedWith()
	if (chatForm or activeRef) and (not station or station ~= activeStation) then
		closeActiveComms()
	end

	local now = Game.time or 0
	if activeAd and ((type(activeAd.due) == "number" and (activeAd.due - now) <= 0)
		or (type(activeAd.timeout) == "number" and (activeAd.timeout - now) <= 0)) then
		local expiredRef = activeRef
		closeActiveComms()
		if station and expiredRef and SpaceStation.adverts[station] and SpaceStation.adverts[station][expiredRef] then
			station:RemoveAdvert(expiredRef)
		end
		refresh()
	end

	for _, item in ipairs(bulletinBoard.items or {}) do
		if (type(item.due) == "number" and (item.due - now) <= 0)
			or (type(item.timeout) == "number" and (item.timeout - now) <= 0) then
			refresh()
			break
		end
	end

	ui.withFont(pionillium.body, function()
		local region = ui.getContentRegion()
		local leftWidth = region.x * 0.45
		if chatForm and chatForm.market then
			leftWidth = math.max(widgetSizes.minListWidth, math.min(region.x * 0.38, region.x - widgetSizes.marketMinWidth))
		end

		ui.child("BulletinBoardLeft", Vector2(leftWidth, 0), nil, commsChildFlags, function()
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

local function onAdvertEvent(station)
	local docked = Game.player and Game.player:GetDockedWith()
	if docked and docked == station then
		refresh()
	end
end

Event.Register("onAdvertAdded", onAdvertEvent)
Event.Register("onAdvertRemoved", onAdvertEvent)
Event.Register("onAdvertChanged", onAdvertEvent)

Event.Register("onGameEnd", closeActiveComms)

StationView:registerView({
	id = "bulletinBoard",
	name = lui.BULLETIN_BOARD,
	icon = ui.theme.icons.bbs,
	securityMode = "encryption",
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
