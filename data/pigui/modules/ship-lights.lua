-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Vector2 = _G.Vector2

local ui = require 'pigui'

local pionillium = ui.fonts.pionillium
local sc = ui.theme.styleColors

local flags = ui.WindowFlags { "NoDecoration", "NoMove", "NoSavedSettings", "NoFocusOnAppearing", "NoBringToFrontOnFocus" }

local offVariant = {
	normal  = sc.panel_800:opacity(0.82),
	hovered = sc.primary_700:opacity(0.92),
	active  = sc.primary_500
}

local beaconOnVariant = {
	normal  = sc.danger_500:opacity(0.88),
	hovered = sc.danger_300:opacity(0.95),
	active  = sc.warning_300
}

local forwardOnVariant = {
	normal  = sc.accent_600:opacity(0.90),
	hovered = sc.accent_400:opacity(0.96),
	active  = sc.accent_200
}

local landingOnVariant = {
	normal  = sc.warning_500:opacity(0.88),
	hovered = sc.warning_300:opacity(0.95),
	active  = sc.warning_100
}

local function displayShipLights()
	if Game.CurrentView() ~= "WorldView" then return end
	if Game.InHyperspace() then return end

	local player = Game.player
	if not player or not player.GetBeaconsEnabled then return end
	if player:GetFlightState() == "HYPERSPACE" then return end

	local beaconsOn = player:GetBeaconsEnabled()
	local forwardOn = player:GetForwardLightsEnabled()
	local landingOn = player:GetLandingLightsEnabled()

	ui.withFont(pionillium.body, function()
		local pad = Vector2(ui.rescaleUI(8), ui.rescaleUI(3))
		local btnH = ui.getTextLineHeight() + pad.y * 2
		local btnW = ui.calcTextSize("LDG").x + pad.x * 2 + ui.rescaleUI(4)
		local spacing = ui.getItemSpacing()
		local winPad = ui.getWindowPadding()
		local labelW = ui.calcTextSize("LIGHTS").x

		local totalW = labelW + spacing.x + btnW * 3 + spacing.x * 2 + winPad.x * 2
		local totalH = btnH + winPad.y * 2
		local bottomOffset = (ui.planetaryInfoHeight or 0) + ui.rescaleUI(4)

		ui.setNextWindowSize(Vector2(totalW, totalH), "Always")
		ui.setNextWindowPos(Vector2(ui.screenWidth, ui.screenHeight - bottomOffset), "Always", Vector2(1, 1))

		ui.withStyleColors({ WindowBg = sc.panel_900:opacity(0.78) }, function()
			ui.window("ShipLightsBar", flags, function()
				ui.withStyleColors({ Text = sc.gray_300 }, function()
					ui.alignTextToLineHeight(btnH)
					ui.textShadowed("LIGHTS")
				end)
				ui.sameLine()

				if ui.button("BCN##ship_lights_bcn", Vector2(btnW, btnH), beaconsOn and beaconOnVariant or offVariant,
					beaconsOn and "Beacon & Strobe Lights: ON (Click to disable)" or "Beacon & Strobe Lights: OFF (Click to enable)", pad) then
					player:ToggleBeacons()
					ui.playSfx("OK")
				end
				ui.sameLine()

				if ui.button("FWD##ship_lights_fwd", Vector2(btnW, btnH), forwardOn and forwardOnVariant or offVariant,
					forwardOn and "Forward Searchlight Beams: ON (Click to disable)" or "Forward Searchlight Beams: OFF (Click to enable)", pad) then
					player:ToggleForwardLights()
					ui.playSfx("OK")
				end
				ui.sameLine()

				if ui.button("LDG##ship_lights_ldg", Vector2(btnW, btnH), landingOn and landingOnVariant or offVariant,
					landingOn and "Landing Floodlight Beams: ON (Click to disable)" or "Landing Floodlight Beams: OFF (Click to enable)", pad) then
					player:ToggleLandingLights()
					ui.playSfx("OK")
				end
			end)
		end)
	end)
end

ui.registerModule("world-view", { id = "ship-lights", draw = displayShipLights, debugReload = true })

return {}
