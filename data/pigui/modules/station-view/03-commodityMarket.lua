-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local StationView = require 'pigui.views.station-view'
local CommodityWidget = require 'pigui.libs.commodity-market'
local StationSig = require 'pigui.libs.station-sig'

local ui = require 'pigui'
local l = Lang.GetResource("ui-core")

local commodityMarket = CommodityWidget.New("commodityMarket", false)
local stationSig = StationSig.New("commodityMarket")

local function render()
	stationSig:render(function()
		commodityMarket:Render()
	end)
end

StationView:registerView({
	id = "commodityMarket",
	name = l.COMMODITY_MARKET,
	icon = ui.theme.icons.market,
	showView = true,
	draw = render,
	refresh = function()
		stationSig:reset()
		commodityMarket:Refresh()
		commodityMarket.scrollReset = true
		commodityMarket.selectedItem = nil
	end,
	debugReload = function()
		package.reimport('pigui.libs.commodity-market')
		package.reimport('pigui.libs.station-sig')
		package.reimport()
	end
})
