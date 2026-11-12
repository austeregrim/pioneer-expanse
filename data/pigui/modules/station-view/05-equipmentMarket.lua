-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Game = require 'Game'
local StationView = require 'pigui.views.station-view'
local StationSig = require 'pigui.libs.station-sig'

local ui = require 'pigui'
local l = Lang.GetResource("ui-core")

local equipmentWidget = require 'pigui.libs.ship-equipment'.New("ShipInfo")
local stationSig = StationSig.New("equipmentMarket")

StationView:registerView({
	id = "equipmentMarketView",
	name = l.EQUIPMENT_MARKET,
	icon = ui.theme.icons.equipment,
	showView = true,
	draw = function()
		stationSig:render(function()
			equipmentWidget:draw()
		end)
	end,
	refresh = function()
		stationSig:reset()
		equipmentWidget.ship    = Game.player
		equipmentWidget.station = Game.player:GetDockedWith()
		equipmentWidget:refresh()
	end,
	debugReload = function()
		equipmentWidget:debugReload()
		package.reimport('pigui.libs.station-sig')
		package.reimport()
	end
})
