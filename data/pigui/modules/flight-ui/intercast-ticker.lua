-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui        = require 'pigui'
local gameView  = require 'pigui.views.game'
local InterCast = require 'modules.InterCast.InterCast'
local Game      = require 'Game'

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2
local Color = _G.Color

local selectedCategory = "ALL"
local expandedArticleId = nil

local CATEGORIES = {
	{ id = "ALL", label = "All" },
	{ id = "FRONTLINE", label = "Combat" },
	{ id = "HUMANITARIAN", label = "Relief" },
	{ id = "MARKET", label = "Market" },
	{ id = "POLITICS", label = "Politics" },
}

local function getCategoryColor(cat)
	if cat == "FRONTLINE" then
		return Color(255, 65, 65, 255)
	elseif cat == "HUMANITARIAN" then
		return Color(55, 220, 255, 255)
	elseif cat == "MARKET" then
		return Color(255, 185, 30, 255)
	elseif cat == "POLITICS" then
		return Color(215, 90, 255, 255)
	end
	return colors.fontDim
end

gameView.registerSidebarModule("intercast-news", {
	side = "right",
	priority = 20,
	showInHyperspace = false,
	icon = icons.bbs or icons.comms,
	tooltip = "InterCast News Wire",
	exclusive = true,

	debugReload = function()
		package.reimport()
	end,

	drawTitle = function()
		ui.textColored(colors.white, "InterCast Wire Dispatch")
	end,

	drawBody = function()
		local articles = InterCast.GetArticles(selectedCategory)
		if not articles or #articles == 0 then
			ui.textColored(colors.fontDim, "No active dispatches available for this category.")
			return
		end

		-- Category Filter Row
		local availW = ui.getContentRegion().x
		local numCats = #CATEGORIES
		local btnW = math.floor((availW - (numCats - 1) * 4) / numCats)

		ui.group(function()
			for i, cat in ipairs(CATEGORIES) do
				local isSel = (selectedCategory == cat.id)
				local btnStyle = isSel and { Button = colors.uiPrimary or colors.white, Text = colors.black } or {}
				ui.withStyleColors(btnStyle, function()
					if ui.button(cat.label .. "##CatBtn", Vector2(btnW, 26)) then
						selectedCategory = cat.id
						expandedArticleId = nil
					end
				end)
				if i < numCats then
					ui.sameLine(0, 4)
				end
			end
			ui.newLine()
		end)

		ui.separator()
		ui.spacing()

		-- Scrollable List of News Articles
		ui.child("##interCastSidebarList", Vector2(-1, -1), function()
			for _, art in ipairs(articles) do
				local catCol = getCategoryColor(art.category)
				local isExpanded = (expandedArticleId == art.id)

				ui.withID(art.id, function()
					ui.group(function()
						-- Flash / Hazard indicator
						if art.urgent then
							ui.textColored(Color(255, 55, 55, 255), "⚠ FLASH")
							ui.sameLine()
						end

						-- Category Badge & Date/Time
						ui.textColored(catCol, string.format("[%s]", art.category))
						ui.sameLine()
						local dtDisp = (art.date or "3200-01-01") .. (art.timeStr and (" " .. art.timeStr) or "")
						ui.textColored(colors.fontDim, dtDisp)
						ui.sameLine()
						if art.system then
							ui.textColored(colors.uiPrimaryLight, "• " .. art.system)
						end

						-- Headline Button to expand/collapse
						local titlePrefix = isExpanded and "▼ " or "▶ "
						if ui.button(titlePrefix .. art.headline .. "##Hdr", Vector2(-1, 0)) then
							if isExpanded then
								expandedArticleId = nil
							else
								expandedArticleId = art.id
							end
						end

						-- Expanded Story Body
						if isExpanded then
							ui.withStyleVars({ ChildRounding = 4.0 }, function()
								ui.child("##artDetail_" .. art.id, Vector2(-1, 0), nil, { "AutoResizeY", "Borders" }, function()
									ui.textColored(colors.fontDim, string.format("Source: %s", art.bureau or "InterCast Wire"))
									ui.separator()
									ui.spacing()

									ui.textWrapped(art.summary or "")
									ui.spacing()

									if art.body and art.body ~= "" then
										ui.textColored(colors.fontDim, "Full Dispatch:")
										ui.textWrapped(art.body)
										ui.spacing()
									end

									if ui.button("Collapse Dispatch##ColBtn", Vector2(140, 26)) then
										expandedArticleId = nil
									end
								end)
							end)
						end
					end)
				end)

				ui.spacing()
				ui.separator()
				ui.spacing()
			end
		end)
	end
})
