-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Game = require 'Game'
local ShipDef = require 'ShipDef'
local MusicPlayer = require 'modules.MusicPlayer'
local Lang = require 'Lang'
local Vector2 = _G.Vector2
local NewGameWindow = require("pigui.modules.new-game-window.class")

local lui = Lang.GetResource("ui-core")

local ui = require 'pigui'

local colors = ui.theme.colors
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer

local mainButtonSize = ui.rescaleUI(Vector2(400,46))
local mainButtonFont = pionillium.large

local function mainTextButton(label, tooltip, enabled, callback)
	local variant = not enabled and ui.theme.buttonColors.disabled or nil

	local button
	ui.withFont(mainButtonFont, function()
		button = ui.button(label, mainButtonSize, variant, tooltip)
	end)
	if button and enabled then
		callback()
	end
	return button
end --mainTextButton

local function showOptions()
	ui.optionsWindow:open()
end

local function showAbout()
	ui.aboutWindow:open()
end

local function quitGame()
	Engine.Quit()
end

local function continueGame()
	if Game.CanLoadGame('_exit') and ( Engine.GetAutosaveEnabled() or not Game.CanLoadGame('_quicksave') ) then
		Game.LoadGame("_exit")
	else
		Game.LoadGame('_quicksave')
	end
end

local function canContinue()
	return Game.CanLoadGame('_exit') or Game.CanLoadGame('_quicksave')
end

local hasMusicList = false -- required false at init, see showMainMenu() for usage

local function callModules(mode)
	for _,v in ipairs(ui.getModules(mode)) do
		v.draw()
	end
end

local overlayWindowFlags = ui.WindowFlags {"NoTitleBar", "NoResize", "NoFocusOnAppearing", "NoBringToFrontOnFocus", "AlwaysAutoResize"}
local mainMenuFlags = ui.WindowFlags{"NoTitleBar", "NoResize", "NoFocusOnAppearing", "NoBringToFrontOnFocus"}

local mainLogo = nil
local function getMainLogo()
	if not mainLogo then
		mainLogo = ui.loadTextureFromSVG(ui.dataDirPath({"icons", "logo.svg"}), 1024, 1024)
	end
	return mainLogo
end

local function showMainMenu()
	if not hasMusicList then
		hasMusicList = true
		MusicPlayer.rebuildSongList()
	end

	MusicPlayer.playRandomSongFromCategory("menu", true)

	local showContinue = canContinue()
	local buttons = 4

	local winPos = Vector2(ui.screenWidth - mainButtonSize.x - 100, ui.screenHeight/2 - (buttons * mainButtonSize.y)/2 - (2*mainButtonSize.y)/2 - 8)

	-- Logo where the title text previously was, sized to ~1/3 screen height
	local logo = getMainLogo()
	if logo then
		local logoDim = math.floor(ui.screenHeight / 3)
		local logoSize = Vector2(logoDim, logoDim)
		local logoPos = Vector2(ui.rescaleUI(110), ui.rescaleUI(40))
		ui.setNextWindowPos(logoPos, 'Always')
		ui.withStyleColorsAndVars({WindowBg = colors.transparent}, {WindowPadding = Vector2(0, 0)}, function()
			ui.window("mainMenuLogo", overlayWindowFlags, function()
				ui.image(logo, logoSize, Vector2(0.0, 0.0), Vector2(1.0, 1.0), colors.white)
			end)
		end)
	end

	-- Center "Pioneer: Expanse" title text to the screen
	local titleText = "Pioneer: Expanse"
	ui.withFont(orbiteer.xlarge, function()
		local textSize = ui.calcTextSize(titleText)
		local titleY = ui.rescaleUI(65)
		local titlePos = Vector2((ui.screenWidth - textSize.x) * 0.5, titleY)
		ui.setNextWindowPos(titlePos, 'Always')
		ui.withStyleColorsAndVars({WindowBg = colors.transparent}, {WindowPadding = Vector2(0, 0)}, function()
			ui.window("headingWindow", overlayWindowFlags, function()
				ui.text(titleText)
			end)
		end)
	end)
	if Engine.IsIntroZooming() then
		ui.setNextWindowPos(Vector2(0,0),'Always')
		ui.setNextWindowSize(Vector2(ui.screenWidth, ui.screenHeight), 'Always')
		ui.withStyleColors({WindowBg=colors.transparent}, function()
			ui.window("shipinfoWindow", overlayWindowFlags, function()
				local mn = Engine.GetIntroCurrentModelName()
				if mn then
					-- TODO: this is kind of hacky, Intro should use shipdefs instead of models...
					local sd = require 'utils'.to_array(ShipDef, function(def)
						return def.modelName == mn
					end)[1]
					if sd then
						ui.addFancyText(Vector2(ui.screenWidth / 3, ui.screenHeight / 5.0 * 4), ui.anchor.center, ui.anchor.bottom, {{text=sd.name, color=colors.white, font=orbiteer.medlarge}}, colors.transparent)
						ui.addFancyText(Vector2(ui.screenWidth / 3, ui.screenHeight / 5.0 * 4.02), ui.anchor.center, ui.anchor.top, {{text=lui[sd.shipClass:upper()], color=colors.white, font=orbiteer.medium}}, colors.transparent)
					end
				end
			end)
		end)
	end
	local build_text = Engine.version
	ui.withFont(orbiteer.medium,
		function()
			ui.setNextWindowPos(Vector2(ui.screenWidth - ui.calcTextSize(build_text).x * 1.2,ui.screenHeight - 50), 'Always')
			ui.withStyleColors({WindowBg = colors.transparent}, function()
				ui.window("buildLabel", overlayWindowFlags, function()
					ui.text(build_text)
				end)
			end)
		end)

	ui.setNextWindowPos(winPos,'Always')
	ui.setNextWindowSize(Vector2(0,0), 'Always')
	ui.withStyleColors({WindowBg = colors.lightBlackBackground}, function()
		ui.window("MainMenuButtons", mainMenuFlags, function()
			mainTextButton(lui.CONTINUE_GAME, nil, showContinue, continueGame)

			mainTextButton(lui.NEW_GAME, nil, true, function()
				NewGameWindow:setDebugMode(ui.ctrlHeld())
				NewGameWindow.mode = 'NEW_GAME'
				NewGameWindow:open();
			end)

			mainTextButton(lui.LOAD_GAME, nil, true, function()
				ui.saveLoadWindow.mode = "LOAD"
				ui.saveLoadWindow:open()
			end)

			mainTextButton(lui.OPTIONS, nil, true, showOptions)
			mainTextButton(lui.ABOUT, nil, true, showAbout)
			mainTextButton(lui.QUIT, nil, true, quitGame)
		end)
	end)

	callModules('mainMenu')
	callModules('modal')
	callModules('ui-timer')
end -- showMainMenu

ui.registerHandler('mainMenu', showMainMenu)
