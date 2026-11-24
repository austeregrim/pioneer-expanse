-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Event = require 'Event'
local Game = require 'Game'
local StationView = require 'pigui.views.station-view'
local Insurance = require 'modules.Insurance.Insurance'

local ui = require 'pigui'
local l = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local orbiteer = ui.fonts.orbiteer
local pionillium = ui.fonts.pionillium
local Vector2 = _G.Vector2

local equipmentWidget = require 'pigui.libs.ship-equipment'.New("ShipInfo")

StationView:registerView({
	id = "equipmentMarketView",
	name = l.EQUIPMENT_MARKET,
	icon = ui.theme.icons.equipment,
	securityMode = "encryption",
	showView = true,
	draw = function()
		if Insurance.HasClaim() then
			ui.withFont(orbiteer.title, function()
				ui.textColored(colors.alertRed, "OUTFITTING LOCKED // OPEN INSURANCE CLAIM PENDING")
			end)
			ui.separator()
			ui.spacing()
			ui.withFont(pionillium.body, function()
				ui.textWrapped("Outfitting and module sales are disabled on your temporary Insurance Starter Ship until your open insurance claim is settled. Visit the Insurance & SAR office to either rebuy your destroyed vessel or claim your payout and retain the starter ship.")
			end)
			ui.spacing()
			if ui.button("OPEN INSURANCE & SAR OFFICE##equipLock", Vector2(360, 40), ui.theme.buttonColors.default) then
				StationView:SwitchTo("insurance")
			end
			return
		end
		equipmentWidget:draw()
	end,
	refresh = function()
		equipmentWidget.ship    = Game.player
		equipmentWidget.station = Game.player:GetDockedWith()
		equipmentWidget.showShipNameEdit = true
		equipmentWidget:refresh()
	end,
	debugReload = function()
		equipmentWidget:debugReload()
		package.reimport()
	end
})

Event.Register("onShipTypeChanged", function(ship)
	if ship == Game.player then
		equipmentWidget.ship = Game.player
		equipmentWidget.station = Game.player:GetDockedWith()
		equipmentWidget:refresh()
	end
end)
