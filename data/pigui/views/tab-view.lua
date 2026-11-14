-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local ui = require 'pigui'
local lui = require 'Lang'.GetResource 'ui-core'
local StationSig = require 'pigui.libs.station-sig'

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2
local Color = _G.Color
local logWarning = _G.logWarning

local colors = ui.theme.colors

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)
local bigButtonSize = ui.rescaleUI(Vector2(36, 36))
local bigButtonFramePadding = ui.rescaleUI(Vector2(3, 3))
local bigButtonWindowPadding = ui.rescaleUI(Vector2(4, 4))
local bigButtonItemSpacing = ui.rescaleUI(Vector2(4, 4))
local bottomUiMargin = require 'pigui.modules.time-window'.window_height
local viewWindowPadding = ui.rescaleUI(Vector2(4, 6))

local PiGuiTabView = {}

local function drawTabWindow(_, fn)
	return fn()
end

function PiGuiTabView.New(viewName)
	local self = {
		name = viewName,
		currentTab = 1,
		prevTab = nil,
		animStartTime = 0,
		viewCount = 0,
		tabs = {},
		sigs = {},
		windowPadding = Vector2(0),
		renderTab = drawTabWindow
	}

	setmetatable(self, {
		__index = PiGuiTabView,
		class = "UI.PiGuiTabView",
	})

	return self
end

function PiGuiTabView:getSig(tab)
	if not self.sigs[tab.id] then
		local isEnc = false
		if tab.securityMode then
			isEnc = (tab.securityMode == "encryption")
		elseif self.name == "InfoView" then
			isEnc = true
		elseif tab.id == "police" or tab.id == "insuranceRebuy" or tab.id == "hangar" or tab.id == "universalCartographics" then
			isEnc = true
		end
		local mode = isEnc and "encryption" or "signature"
		local sig = StationSig.New(self.name .. "_" .. tab.id, mode)
		self.sigs[tab.id] = sig
	end
	return self.sigs[tab.id]
end

function PiGuiTabView.resize(self)
	local buttonH = bigButtonSize.y + bigButtonWindowPadding.y * 2.0

	self.viewWindowSize = Vector2(
		ui.screenWidth - viewWindowPadding.x * 2,
		ui.screenHeight - buttonH - bottomUiMargin - viewWindowPadding.y * 2)

	self.viewWindowPos = Vector2(
		viewWindowPadding.x,
		buttonH)

	self.buttonWindowPos = Vector2(
		viewWindowPadding.x,
		0)
end

function PiGuiTabView.registerView(self, view)
	local idx = self.tabs[view.id]
	if idx then self.tabs[idx] = view; return end

	table.insert(self.tabs, view)
	self.viewCount = self.viewCount + 1
	self.tabs[view.id] = self.viewCount
	self:resize()

	return view
end

function PiGuiTabView:refreshTab(i)
	local tab = self.tabs[i]
	if not tab then return end

	local sig = self:getSig(tab)
	sig:reset()

	local ok, err = ui.pcall(tab.refresh, tab)

	if not ok then
		tab.showView = false
		tab.err = err
	end
end

function PiGuiTabView:SwitchTo(id)
	for i, v in ipairs(self.tabs) do
		if v.id == id then
			if self.currentTab ~= i then
				self.prevTab = self.currentTab
				self.currentTab = i
				self.animStartTime = ui.getTime()
				self:refreshTab(i)
			end
			return
		end
	end
	print("View not found:", id)
end

local staticButtonFlags = ui.WindowFlags {"NoResize", "NoTitleBar", "NoMove", "NoFocusOnAppearing", "NoScrollbar", "NoScrollWithMouse"}
local vCenter = Vector2(0.5, 0.5)
local mainWindowFlags = ui.WindowFlags {"NoResize", "NoTitleBar"}

function PiGuiTabView.renderTabView(self, refresh)
	if self.lastScreenWidth ~= ui.screenWidth or self.lastScreenHeight ~= ui.screenHeight then
		self.lastScreenWidth = ui.screenWidth
		self.lastScreenHeight = ui.screenHeight
		self:resize()
	end

	if not self.tabs[self.currentTab] then
		self.currentTab = 1
	end

	local tab = self.tabs[self.currentTab]
	if not tab then return end

	-- refresh the tab since we're swapping back to the view
	if refresh then
		self:refreshTab(self.currentTab)
	end

	local styleColors = {
		WindowBg = colors.windowBackground,
		Border = colors.windowFrame,
	}
	local styleVars = {
		WindowRounding = 0,
		WindowBorderSize = 1.0,
		WindowPadding = self.windowPadding,
	}

	if(tab.windows) then
		tab.windows:display()
	end

	if (tab.showView) then
		ui.withStyleColorsAndVars(styleColors, styleVars, function()
			ui.setNextWindowPos(self.viewWindowPos, "Always")
			ui.setNextWindowSize(self.viewWindowSize, "Always")
			ui.window(self.name .. "-Content", mainWindowFlags, function()
				local sig = self:getSig(tab)
				sig:render(function()
					self:renderTab(function()
						tab.showView, tab.err = ui.pcall(tab.draw, tab)
					end)
				end)
			end)
		end)
	end

	if (tab.err) then
		ui.setNextWindowPos(self.viewWindowPos + self.viewWindowSize * 0.5, "Always", vCenter)
		ui.setNextWindowSize(self.viewWindowSize * 0.6, "Always")
		ui.withStyleColorsAndVars(styleColors, styleVars, function()
			ui.window(self.name .. "-TabError", {"NoResize", "NoTitleBar"}, function()
				ui.withFont(ui.fonts.orbiteer.medlarge, function() ui.text(lui.AN_ERROR_HAS_OCCURRED) end)
				ui.withFont(ui.fonts.pionillium.medium, function()
					ui.spacing()
					ui.textWrapped(lui.PLEASE_REPORT_THIS_ERROR:interp {path = ui.userDirPath()})
					ui.spacing()
					ui.textLinkOpenURL("Open Pioneer: Expanse Issue Tracker on GitHub", "https://github.com/austeregrim/pioneer-expanse/issues")
					ui.spacing()
					ui.child("#TabErrorMsg", function()
						local err = tab.err
						if type(err) == "string" then err = err:gsub('\t', '        ') end
						ui.textWrapped(err)
					end)
				end)
			end)
		end)
	end

	-- Tab folder button bar: active tab smoothly expands with icon + title like a folder tab
	local now = ui.getTime()
	local animDuration = 0.16
	local animProgress = math.clamp((now - (self.animStartTime or 0)) / animDuration, 0, 1)
	local ease = 1 - (1 - animProgress) * (1 - animProgress)
	if animProgress >= 1 then
		self.prevTab = nil
	end

	local activeBorder = ui.theme.styleColors.primary_500 or colors.windowFrame
	local activeBg = ui.theme.styleColors.panel_900 or Color(10, 14, 20, 245)
	local activeVariant = {
		normal = activeBg,
		hovered = ui.theme.styleColors.primary_700 or activeBg,
		active = activeBg,
	}

	-- Calculate exact width required by the tab buttons so the window doesn't cover center navigation buttons
	local currentTabW = 0
	if self.tabs[self.currentTab] then
		ui.withFont(pionillium.medium, function()
			currentTabW = ui.calcTextSize(self.tabs[self.currentTab].name).x + 16 * rescaleVector.x
		end)
	end
	local prevTabW = 0
	if self.prevTab and self.tabs[self.prevTab] and animProgress < 1 then
		ui.withFont(pionillium.medium, function()
			prevTabW = ui.calcTextSize(self.tabs[self.prevTab].name).x + 16 * rescaleVector.x
		end)
	end
	local animatedExpansion = currentTabW * ease + prevTabW * (1 - ease)
	local buttonBarWidth = bigButtonSize.x * #self.tabs + bigButtonItemSpacing.x * (#self.tabs - 1) + bigButtonWindowPadding.x * 2 + animatedExpansion
	local buttonH = bigButtonSize.y + bigButtonWindowPadding.y * 2.0

	ui.setNextWindowSize(Vector2(buttonBarWidth, buttonH), "Always")
	ui.setNextWindowPos(self.buttonWindowPos or Vector2(viewWindowPadding.x, 0), "Always")
	ui.withStyleColorsAndVars({ WindowBg = colors.transparent }, { WindowPadding = bigButtonWindowPadding, ItemSpacing = bigButtonItemSpacing }, function()
		ui.window(self.name .. "-Buttons", staticButtonFlags, function()
			for i, v in ipairs(self.tabs) do
				local isActive = (i == self.currentTab)
				local isPrev = (i == self.prevTab and animProgress < 1)

				if isActive or isPrev then
					local iconH = bigButtonSize.y - bigButtonFramePadding.y * 2
					local textW = 0
					local textH = 0
					ui.withFont(pionillium.medium, function()
						textW = ui.calcTextSize(v.name).x
						textH = ui.getTextLineHeight()
					end)

					local fullW = bigButtonSize.x + textW + 16 * rescaleVector.x
					fullW = math.max(bigButtonSize.x, fullW)

					local btnW = bigButtonSize.x
					if isActive then
						btnW = bigButtonSize.x + (fullW - bigButtonSize.x) * ease
					elseif isPrev then
						btnW = bigButtonSize.x + (fullW - bigButtonSize.x) * (1 - ease)
					end

					local textColor = isActive and colors.uiPrimaryLight or colors.fontDim

					ui.withStyleColors({ Border = activeBorder }, function()
						ui.withStyleVars({ FrameBorderSize = 1.0, FramePadding = bigButtonFramePadding }, function()
							ui.button("##tabBtn_" .. v.id, Vector2(btnW, bigButtonSize.y), activeVariant, v.name)
						end)
					end)

					local minPos, maxPos = ui.getItemRect()

					ui.withClipRect(minPos, maxPos, function()
						-- 1. Draw the icon on the left: same size and color as original button
						local iconPos = Vector2(minPos.x + bigButtonFramePadding.x, minPos.y + bigButtonFramePadding.y)
						ui.addIconSimple(iconPos, v.icon, Vector2(iconH, iconH), colors.font)

						-- 2. Draw the text right-justified inside the expanded button with padding
						local rightMargin = 12 * rescaleVector.x
						if btnW > bigButtonSize.x + 8 * rescaleVector.x then
							ui.withFont(pionillium.medium, function()
								local textPos = Vector2(
									minPos.x + btnW - textW - rightMargin,
									minPos.y + (bigButtonSize.y - textH) * 0.5
								)
								ui.addText(textPos, textColor, v.name)
							end)
						end
					end)

					if isActive then
						ui.addRectFilled(minPos, Vector2(maxPos.x, minPos.y + 2), colors.uiPrimaryLight, 0, ui.RoundCornersNone)
					end
				else
					if ui.iconButton(v.id, v.icon, v.name, false, bigButtonSize, bigButtonFramePadding) then
						self:SwitchTo(v.id)
					end
				end

				if i < #self.tabs then
					ui.sameLine()
				end
			end
		end)
	end)

	if ui.ctrlHeld() and ui.isKeyReleased(ui.keys.delete) then
		if tab.debugReload then tab:debugReload() end
		-- refresh the (possibly) new tab
		self:refreshTab(self.currentTab)
	end
end

return PiGuiTabView
