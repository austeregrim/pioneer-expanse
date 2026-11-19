-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Lang = require 'Lang'
local Vector2 = _G.Vector2

local ui = require 'pigui'

local lui = Lang.GetResource("ui-core")

local gameView = require 'pigui.views.game'

local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors
local icons = ui.theme.icons

local flags = ui.WindowFlags { "NoDecoration", "NoFocusOnAppearing", "NoBringToFrontOnFocus" }

local function getConditionColor(condition)
	local sc = ui.theme.styleColors
	if condition == "SEVERE STORM" or condition == "DUST STORM" then
		return colors.alertBrightRed
	elseif condition == "STORM" or condition == "SNOW STORM" or condition == "WINDY" then
		return colors.alertYellow
	elseif condition == "RAIN" or condition == "OVERCAST" then
		return sc.accent_200
	elseif condition == "BREEZY" then
		return sc.gray_300
	end
	return sc.success_300
end

local function getTurbulenceLabelAndColor(turb)
	local sc = ui.theme.styleColors
	if turb >= 0.65 then
		return "SEVERE", colors.alertBrightRed
	elseif turb >= 0.38 then
		return "MOD", colors.alertYellow
	elseif turb >= 0.16 then
		return "LIGHT", sc.accent_200
	end
	return "CALM", sc.success_300
end

local function displayPlanetaryInfo()
	local player = Game.player

	if Game.CurrentView() ~= "WorldView" then
		ui.planetaryInfoHeight = 0
		return
	end

	local alt, vspd, latitude, longitude = player:GetGPS()
	if not alt then
		ui.planetaryInfoHeight = 0
		return
	end

	local frame = player.frameBody
	local weather = (frame and frame:IsPlanet() and frame.GetWeatherState) and frame:GetWeatherState(player) or nil
	local hasWeather = weather and weather.hasAtmosphere and weather.density > 0.005

	ui.withFont(pionillium.body, function()

		local width = gameView.rightSidebar.displaySize.x
		local lineCount = hasWeather and 5 or 3
		local height = ui.getTextLineHeightWithSpacing() * lineCount - ui.getItemSpacing().y
		local totalHeight = height + ui.getWindowPadding().y * 2
		ui.planetaryInfoHeight = totalHeight

		ui.setNextWindowSize(Vector2(width, totalHeight), "Always")
		ui.setNextWindowPos(ui.screenSize(), "Always", Vector2(1, 1))

		ui.window("PlanetaryInfo", flags, function()
			local label = Game.player.frameLabel

			if label then
				local sz = ui.calcTextSize(label)

				ui.addCursorPos(Vector2((ui.getContentRegion().x - sz.x) * 0.5, 0))
				ui.withStyleColors({ Text = ui.theme.styleColors.gray_300 }, function()
					ui.textShadowed(label)
				end)
			else
				ui.newLine()
			end

			ui.columns(2, "", false)

			local fmt = "%s %s"

			local orbit = player:GetOrbit()

			-- NOTE: these use em-dashes
			local ap = player.frameRotating and "—" or ui.Format.Distance(orbit.apogee)
			local pe = player.frameRotating and "—" or ui.Format.Distance(orbit.perigee)

			ui.textShadowed(fmt:format(ui.get_icon_glyph(icons.apoapsis), ap))
			ui.setItemTooltip(lui.HUD_ORBIT_APOAPSIS)

			ui.textShadowed(fmt:format(ui.get_icon_glyph(icons.periapsis), pe))
			ui.setItemTooltip(lui.HUD_ORBIT_PERIAPSIS)

			ui.nextColumn()

			ui.textShadowed(fmt:format(ui.get_icon_glyph(icons.latitude), ui.Format.Latitude(latitude)))
			ui.textShadowed(fmt:format(ui.get_icon_glyph(icons.longitude), ui.Format.Longitude(longitude)))

			if hasWeather then
				local headingInt = math.floor(weather.windHeading + 0.5) % 360
				local windInt = math.floor(weather.windSpeed + 0.5)
				local gustInt = math.floor(weather.gustSpeed + 0.5)
				local windText = (gustInt >= 3)
					and string.format("WIND %03d° %dm/s G%d", headingInt, windInt, gustInt)
					or string.format("WIND %03d° %dm/s", headingInt, windInt)

				local turbLabel, turbCol = getTurbulenceLabelAndColor(weather.turbulence)
				local condCol = getConditionColor(weather.condition)
				local draftOrShear = (weather.windShear >= 0.35)
					and string.format("SHEAR %d%%", math.floor(weather.windShear * 100 + 0.5))
					or string.format("DRAFT %+.1fm/s", weather.verticalDraft)

				local seasonStr = (weather.season and weather.season ~= "NONE") and ("  Season: " .. weather.season) or ""
				local tempC = (weather.localTempK or 288.0) - 273.15
				local lowKm = (weather.lowerCloudAlt or 0.0) * 0.001
				local highKm = (weather.upperCloudAlt or 0.0) * 0.001
				local weatherTooltip = string.format(
					"Condition: %s  Climate: %s%s\nAir Temp: %+.0f°C  Pressure: %.2f atm\nWind FROM: %03d° at %.1f m/s (Gusts %.1f m/s)\nVertical Draft: %+.1f m/s\nTurbulence: %s (%.0f%%)  Wind Shear: %.0f%%\nClouds: %.0f%% (Low %.1fkm %.0f%% / High %.1fkm %.0f%%)\nPrecip: %s (%.0f%%)  Storm Intensity: %.0f%%",
					weather.condition, weather.climate or "TEMPERATE", seasonStr,
					tempC, weather.pressure or 0.0,
					headingInt, weather.windSpeed, weather.gustSpeed,
					weather.verticalDraft,
					turbLabel, weather.turbulence * 100, weather.windShear * 100,
					weather.cloudCover * 100, lowKm, (weather.lowerCloudCover or 0.0) * 100, highKm, (weather.upperCloudCover or 0.0) * 100,
					weather.precipType, weather.precipIntensity * 100,
					weather.stormIntensity * 100
				)

				ui.nextColumn()

				ui.withStyleColors({ Text = condCol }, function()
					ui.textShadowed(weather.condition)
				end)
				ui.setItemTooltip(weatherTooltip)

				ui.textShadowed(windText)
				ui.setItemTooltip(weatherTooltip)

				ui.nextColumn()

				ui.withStyleColors({ Text = turbCol }, function()
					ui.textShadowed("TURB: " .. turbLabel)
				end)
				ui.setItemTooltip(weatherTooltip)

				ui.withStyleColors({ Text = (weather.windShear >= 0.55) and colors.alertYellow or ui.theme.styleColors.gray_300 }, function()
					ui.textShadowed(draftOrShear)
				end)
				ui.setItemTooltip(weatherTooltip)
			end

			ui.columns(1)

		end)

	end)
end

ui.registerModule("world-view", { id = "planetary-info", draw = displayPlanetaryInfo, debugReload = true })

return {}
