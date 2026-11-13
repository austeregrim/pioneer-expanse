-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game        = require 'Game'
local ui          = require 'pigui'
local StationView = require 'pigui.views.station-view'
local InterCast   = require 'modules.InterCast.InterCast'
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
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	buttonSizeBase = Vector2(64, 36),
}, Vector2(1920, 1080))

local selectedCategory = "ALL"
local selectedArticleId = nil
local face = nil
local stationSeed = false

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

local function drawInterCastNews()
	ui.withFont(orbiteer.title, function()
		ui.textColored(colors.uiPrimaryLight, "INTERSTELLAR BROADCAST NEWS (INTERCAST)")
	end)
	ui.textColored(colors.fontDim, "The Galaxy's Independent Sub-Space Wire Service & Frontier Chronicle")
	ui.separator()
	ui.spacing()

	-- Category filter bar
	ui.group(function()
		for i, cat in ipairs(CATEGORIES) do
			local isSelected = (selectedCategory == cat.id)
			local btnStyle = isSelected and { Button = colors.uiPrimaryLight, Text = colors.black } or {}

			ui.withStyleColors(btnStyle, function()
				if ui.button(cat.label, Vector2(140 * rescaleVector.x, widgetSizes.buttonSizeBase.y)) then
					selectedCategory = cat.id
					selectedArticleId = nil
				end
			end)

			if i < #CATEGORIES then
				ui.sameLine()
			end
		end
	end)

	ui.spacing()
	ui.separator()
	ui.spacing()

	local articleList = InterCast.GetArticles(selectedCategory)
	if #articleList == 0 then
		ui.text("No news bulletins currently on file for this category.")
		return
	end

	-- If no article selected, pick the first one
	if not selectedArticleId or selectedArticleId == "" then
		selectedArticleId = articleList[1].id
	end

	local activeArticle = nil
	for _, art in ipairs(articleList) do
		if art.id == selectedArticleId then
			activeArticle = art
			break
		end
	end
	if not activeArticle then
		activeArticle = articleList[1]
		selectedArticleId = activeArticle.id
	end

	ui.columns(2, "NewsColumns", false)
	ui.setColumnWidth(0, 480 * rescaleVector.x)

	-- Left Column: Article headlines list
	ui.child("HeadlineListScroll", Vector2(0, 0), function()
		for _, art in ipairs(articleList) do
			local isCurrent = (art.id == selectedArticleId)
			local catColor = getCategoryColor(art.category)

			ui.group(function()
				ui.textColored(catColor, string.format("[%s]  %s", art.category, art.date))
				if art.urgent then
					ui.sameLine()
					ui.textColored(colors.compareWorse, "[FLASH]")
				end

				ui.withFont(orbiteer.medlarge, function()
					if ui.selectable(art.headline .. "##" .. art.id, isCurrent, {}) then
						selectedArticleId = art.id
						ui.playSfx("OK")
					end
				end)

				ui.textColored(colors.fontDim, art.bureau)
			end)

			ui.spacing()
			ui.separator()
			ui.spacing()
		end
	end)

	ui.nextColumn()

	-- Right Column: Full Article Reader
	ui.child("ArticleReaderScroll", Vector2(0, 0), function()
		if not activeArticle then return end

		local catColor = getCategoryColor(activeArticle.category)

		ui.textColored(catColor, string.format("[%s BULLETIN]  |  DATE: %s", activeArticle.category, activeArticle.date))
		ui.textColored(colors.fontDim, string.format("TRANSMITTED VIA: %s  |  LOCATION: %s", activeArticle.bureau, activeArticle.system))
		ui.spacing()

		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.white, activeArticle.headline)
		end)

		ui.spacing()
		ui.separator()
		ui.spacing()

		ui.withFont(orbiteer.medlarge, function()
			ui.textColored(colors.uiPrimaryLight, activeArticle.summary)
		end)

		ui.spacing()
		ui.separator()
		ui.spacing()

		ui.textWrapped(activeArticle.body)

		ui.spacing()
		ui.spacing()
		ui.separator()
		ui.spacing()

		ui.textColored(colors.fontDim, "INTERCAST BROADCAST COVENANT:")
		ui.textWrapped("InterCast wire transmissions are broadcast continuously across sub-space transponder relays. Commercial pilots may monitor regional dispatches in-flight via the cockpit telemetry ticker.")
	end)

	ui.columns(1)
end

StationView:registerView({
	id = "interCast",
	name = "InterCast News",
	icon = icons.comms or icons.bbs,
	showView = true,
	draw = drawInterCastNews,
	refresh = function(self)
		local station = Game.player:GetDockedWith()
		if station then
			if stationSeed ~= station.seed then
				stationSeed = station.seed
				local rand = Rand.New(station.seed .. "-news")
				face = PiGuiFace.New(
					Character.New({ title = "NEWS CORRESPONDENT", org = "INTERCAST WIRE SERVICE", role = "journalist" }, rand),
					{ itemSpacing = widgetSizes.itemSpacing }
				)
			end
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

