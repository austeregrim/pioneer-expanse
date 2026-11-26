-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Event = require 'Event'
local Game = require 'Game'
local Gravity = require 'pigui.libs.gravity'
local gameView = require 'pigui.views.game'

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors
local icons = ui.theme.icons

local lui = require 'Lang'.GetResource("ui-core")

local Vector2 = _G.Vector2

local alreadyAlertedTemp = false
local alreadyAlertedFuel = false
local alreadyAlertedPres = false
local alreadyAlertedDescent = false
local alreadyAlertedImpact = false
local alreadyAlertedWindShear = false
local alreadyAlertedTurb = false
local alreadyAlertedStorm = false
local lastWindShearChimeTime = -1000
local lastTurbChimeTime = -1000
local lastStormChimeTime = -1000

Event.Register("onGameStart", function()
	alreadyAlertedTemp = false
	alreadyAlertedFuel = false
	alreadyAlertedPres = false
	alreadyAlertedDescent = false
	alreadyAlertedImpact = false
	alreadyAlertedWindShear = false
	alreadyAlertedTurb = false
	alreadyAlertedStorm = false
	lastWindShearChimeTime = -1000
	lastTurbChimeTime = -1000
	lastStormChimeTime = -1000
end)

local TWR_BLINK_PERIOD = 2.0
local TWR_HUD_WARNING_THRESHOLD = 1.1

-- Whether the nav target is on a planetary surface (ground starport or landed ship).
local function isNavTargetOnSurface(navTarget)
	if not navTarget then return false end

	if navTarget.type == "STARPORT_SURFACE" then
		return true
	end

	if navTarget:IsShip() then
		if navTarget:IsLanded() then
			return true
		end
		if navTarget:IsDocked() then
			local station = navTarget:GetDockedWith()
			return station and station.type == "STARPORT_SURFACE"
		end
	end

	return false
end

local function alarm ()
	local showingHudWarning = false

	--check hull temperature
	local t = Game.player:GetHullTemperature()
	if t and t > 0.8 and not alreadyAlertedTemp then
		ui.playSfx("alarm_emer", 1.0, 1.0)
		Engine.PlayCockpitVoice("temp_critical", 3, 12.0)
		alreadyAlertedTemp = true;
	end
	if t < 0.8 and alreadyAlertedTemp then
		alreadyAlertedTemp = false;
	end

	--check fuel level
	local remainingFuel = Game.player:GetRemainingDeltaV()
	local currentSpeed = Game.player:GetCurrentDeltaV()
	local maxDv = Game.player:GetMaxDeltaV()
	local warningRatio = remainingFuel - currentSpeed
	if warningRatio < (maxDv / 10) and not alreadyAlertedFuel then
		ui.playSfx("fuel_low", 1.0, 1.0)
		Engine.PlayCockpitVoice("fuel_low", 2, 20.0)
		alreadyAlertedFuel = true
	end
	if warningRatio > (maxDv / 10) and alreadyAlertedFuel then
		alreadyAlertedFuel = false
	end

	--check atmospheric pressure
	local frame = Game.player.frameBody
	if frame then
		local pressure = frame:GetAtmosphericState(Game.player)
		if pressure and pressure > 9 and not alreadyAlertedPres then
			ui.playSfx("alarm_generic1", 1.0, 1.0)
			alreadyAlertedPres = true
		end
		if not pressure or pressure < 9 and alreadyAlertedPres then
			alreadyAlertedPres = false
		end
	end

	--check descent speed
	if frame and not frame:IsDynamic() and frame.superType ~= 'STARPORT' then --we only need to check descent speed if we are approaching a celestial body
		local velocity = Game.player:GetVelocityRelTo(frame)
		local position = Game.player:GetPositionRelTo(frame)
		local altitude = Game.player:GetAltitudeRelTo(frame)
		local approach_speed = position:dot(velocity) / position:length() --perpendicular to horizon
		local recover_distance = Game.player:GetDistanceToZeroV(approach_speed,"forward") --braking distance basically

		local reticuleCircleRadius = math.min(ui.screenWidth, ui.screenHeight) / 8 -- required for icon placement
		local uiTextPos = Vector2(ui.screenWidth / 2, ui.screenHeight / 3 - 10) --sits just above HUD circle
		local uiPos = ui.pointOnClock(gameView.center, reticuleCircleRadius * 1.2 , 10) --left side of the reticule, above frame info
		local iconSize = Vector2(24, 24)

		local max_accel = Game.player:GetAcceleration("forward") --max acceleration axis of the ship, which is always forward with all Pioneer ships
		local up_accel = Game.player:GetAcceleration("up") --up acceleration

		local response_time_factor = 2 --Gives reponse time to player (seconds). Presence of atmosphere makes this time longer.
		--Higher the value, earlier the warning. Too high = annoying, too low = death, probably.

		local evasion_factor = 20
		--The lower the evasion_factor value, the higher altitude the descent rate alarm changes mode. Depends on planet radius.
		--6500000 / 20 = 325000
		--For example, above Earth, alarm changes mode at 325km altitude
		--This should be about where the planet/star becomes the player's horizon instead of a distant orb in space.

		local surface_gravity = frame.path:GetSystemBody().gravity --surface gravity of the body we need to avoid
		local body_radius = frame.path:GetSystemBody().radius --radius of the body we need to avoid

		--required to calculate periapsis radius
		local player_mass = Game.player.staticMass + Game.player.fuelMassLeft
		local eccentricity_vector = ((velocity:length()^2 - surface_gravity*player_mass/position:length())*position-position:dot(velocity)*velocity)/surface_gravity*player_mass
		local eccentricity = eccentricity_vector:length()
		local semi_major_axis = 1 / ((2 / position:length()) - (velocity:length()^2 / surface_gravity*player_mass))
		local periapsis_radius = semi_major_axis * (1 - eccentricity)

		--with the following formula, alert triggers if
		--approach speed is over 25 m/s
		--periapsis is below body surface (ignoring atmosphere and terrain)
		--if the approach speed keeps increasing under planetary gravity at max possible rate (V1^2 = V0^2 + 2*a*h; V1: final speed, V0: initial speed, a:acceleration(gravity), h:altitude), player has less than "response_time_factor" to start boosting upwards to avoid a crash (atmo ignored)
		--player is closer to the body than the altitude calculated via evasion_factor
		if approach_speed < -25 and periapsis_radius < body_radius and (altitude - recover_distance) / ((approach_speed^2 + 2*surface_gravity*recover_distance)^(1/2)) < response_time_factor and body_radius/altitude > evasion_factor and Game.player:GetCurrentAICommand() ~= "CMD_DOCK" then
			alreadyAlertedImpact = false
			if Game.CurrentView() == "WorldView" then
				showingHudWarning = true
				ui.addStyledText(uiTextPos, ui.anchor.center, ui.anchor.top, lui.HUD_WARNING_DESCENT_RATE, colors.alertRed, pionillium.large, nil, colors.lightBlackBackground)
			end
			if not alreadyAlertedDescent then
				ui.playSfx("alarm_descent", 0.75, 0.75)
				alreadyAlertedDescent = true
			end

		--with the following formula, alert triggers if
		--braking distance is longer than distance to the body (player can not decelerate before hitting the body)
		--player is still far enough away from the body
		elseif approach_speed < -25 and recover_distance > altitude and periapsis_radius < body_radius and body_radius/altitude <= evasion_factor and (periapsis_radius + (1/2)*max_accel*(altitude / -approach_speed)^2) >= body_radius then
			alreadyAlertedDescent = false
			if Game.CurrentView() == "WorldView" then
				showingHudWarning = true
				ui.addIcon(uiPos, icons.impact_warning, colors.alertYellow, iconSize, ui.anchor.center, ui.anchor.center, lui.HUD_WARNING_IMPACT)
			end
			if not alreadyAlertedImpact then
				ui.playSfx("impact_chime", 1.0, 1.0)
				alreadyAlertedImpact = true
			end

		--with the following formula, alert triggers if
		--player ship's acceleration rate would not allow them to avoid a collision by simply accelerating sideways
		--exact calculations require complex integrals, this alert is accurate enough but just a tiny bit on the pessimistic side for extra safety measures
		elseif approach_speed < -25 and recover_distance > altitude and periapsis_radius < body_radius and body_radius/altitude <= evasion_factor and (periapsis_radius + (1/2)*max_accel*(altitude / -approach_speed)^2) < body_radius and Game.CurrentView() == "WorldView" then
			showingHudWarning = true
			ui.addIcon(uiPos, icons.impact_warning, colors.alertRed, iconSize, ui.anchor.center, ui.anchor.center, lui.HUD_WARNING_IMPACT_IMMINENT)
		else -- clean up warning status so we can warn the player the next time they are in danger
			alreadyAlertedImpact = false
			alreadyAlertedDescent = false
		end
	end

	-- TWR destination warning
	if not showingHudWarning and Game.CurrentView() == "WorldView" and not ui.optionsWindow.isOpen then
		local upAccel = Game.player:GetAcceleration("up")
		local uiTextPos = Vector2(ui.screenWidth / 2, ui.screenHeight / 3 - 10)

		local navTarget = Game.player:GetNavTarget()
		if navTarget and isNavTargetOnSurface(navTarget) then
			local targetGravity = Gravity.GetSurfaceGravity(navTarget)
			if targetGravity then
				local targetTwr = upAccel / targetGravity
				if targetTwr < TWR_HUD_WARNING_THRESHOLD then
					showingHudWarning = true
					local twrBlink = math.fmod(ui.getTime(), TWR_BLINK_PERIOD) < TWR_BLINK_PERIOD / 2
					local textColor = twrBlink and colors.alertBrightRed or colors.alertRed
					local text = string.interp(lui.HUD_WARNING_TWR_DESTINATION, {
						value = ui.Format.TWR(targetTwr, 2),
					})
					ui.addStyledText(uiTextPos, ui.anchor.center, ui.anchor.top, text, textColor, pionillium.large, nil, colors.lightBlackBackground)
				end
			end
		end
	end

	-- Atmospheric weather advisories (soft aviation chimes + HUD callouts with hysteresis & cooldown)
	local weather = (Game.player.flightState == "FLYING" and frame and frame:IsPlanet() and frame.GetWeatherState) and frame:GetWeatherState(Game.player) or nil
	if weather and weather.hasAtmosphere and weather.density > 0.02 then
		local now = ui.getTime()
		local uiTextPos = Vector2(ui.screenWidth / 2, ui.screenHeight / 3 - 10)
		local canDrawHud = (Game.CurrentView() == "WorldView") and (not ui.optionsWindow.isOpen) and (not showingHudWarning)

		-- Wind shear caution below 12 km
		local windShearActive = (weather.windShear >= 0.55) and (weather.altitude < 12000)
		if windShearActive then
			if not alreadyAlertedWindShear and (now - lastWindShearChimeTime) >= 20.0 then
				ui.playSfx("weather_windshear", 0.75, 0.75)
				Engine.PlayCockpitVoice("wind_shear", 2, 20.0)
				lastWindShearChimeTime = now
			end
			alreadyAlertedWindShear = true
			if canDrawHud then
				showingHudWarning = true
				canDrawHud = false
				ui.addStyledText(uiTextPos, ui.anchor.center, ui.anchor.top, lui.HUD_WARNING_WIND_SHEAR, colors.alertYellow, pionillium.large, nil, colors.lightBlackBackground)
			end
		elseif weather.windShear < 0.35 or weather.altitude >= 12000 then
			alreadyAlertedWindShear = false
		end

		-- Severe turbulence caution
		if weather.turbulence >= 0.65 then
			if not alreadyAlertedTurb and (now - lastTurbChimeTime) >= 25.0 then
				ui.playSfx("weather_turbulence", 0.70, 0.70)
				Engine.PlayCockpitVoice("turbulence", 2, 25.0)
				lastTurbChimeTime = now
			end
			alreadyAlertedTurb = true
			if canDrawHud then
				showingHudWarning = true
				canDrawHud = false
				ui.addStyledText(uiTextPos, ui.anchor.center, ui.anchor.top, lui.HUD_WARNING_SEVERE_TURBULENCE, colors.alertYellow, pionillium.large, nil, colors.lightBlackBackground)
			end
		elseif weather.turbulence < 0.45 then
			alreadyAlertedTurb = false
		end

		-- Storm / dust storm advisory
		if weather.stormIntensity >= 0.60 then
			if not alreadyAlertedStorm and (now - lastStormChimeTime) >= 45.0 then
				ui.playSfx("weather_advisory", 0.65, 0.65)
				Engine.PlayCockpitVoice("storm_advisory", 1, 45.0)
				lastStormChimeTime = now
			end
			alreadyAlertedStorm = true
			if canDrawHud then
				showingHudWarning = true
				local isDust = (weather.precipType == "DUST")
				local text = isDust and lui.HUD_WARNING_DUST_STORM_ADVISORY or lui.HUD_WARNING_STORM_ADVISORY
				local col = isDust and colors.alertYellow or ui.theme.styleColors.accent_200
				ui.addStyledText(uiTextPos, ui.anchor.center, ui.anchor.top, text, col, pionillium.large, nil, colors.lightBlackBackground)
			end
		elseif weather.stormIntensity < 0.40 then
			alreadyAlertedStorm = false
		end
	else
		alreadyAlertedWindShear = false
		alreadyAlertedTurb = false
		alreadyAlertedStorm = false
	end

end

ui.registerModule("world-view", alarm)

return {}
