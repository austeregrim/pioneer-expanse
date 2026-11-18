-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'

local Event = require 'Event'
local Input = require 'Input'
local Module = require 'pigui.libs.module'
local utils = require 'utils'

local modalStack = {}

---@class UI.ModalWindow : UI.Module
---@field size Vector2?
---@field centered boolean?
---@field style table?
local ModalWindow = utils.class("UI.ModalWindow", Module)

local defaultModalFlags = ui.WindowFlags {"NoTitleBar", "NoResize", "AlwaysAutoResize", "NoMove"}

function ModalWindow.New(name, render, outerHandler, flags)
	local modalWin = {
		name = name,
		flags = flags or defaultModalFlags,
		stackIdx = -1,
		isOpen = false,
		popupRequested = false,
		render = render,
		outerHandler = outerHandler,
	}

	setmetatable(modalWin, {
		__index = ModalWindow,
		class = "UI.ModalWindow",
	})

	Module.Constructor(modalWin)

	return modalWin
end

function ModalWindow:open(...)
	if self.stackIdx < 0 then
		table.insert(modalStack, self)
		self.stackIdx = #modalStack
	end
	self.isOpen = false
	self.popupRequested = false

	self:message("onOpen", ...)
end

function ModalWindow:close(...)
	-- Not in the stack currently
	if self.stackIdx == -1 then
		return
	end

	for i=#modalStack, self.stackIdx, -1 do
		modalStack[i].stackIdx = -1
		modalStack[i].isOpen = false
		modalStack[i].popupRequested = false
		table.remove(modalStack, i)
	end

	self:message("onClose", ...)

	if #modalStack == 0 and ui.closeAllPopups then
		ui.closeAllPopups()
	end
end

function ModalWindow:onOpen() end

function ModalWindow:onClose() end

function ModalWindow:outerHandler(innerFn)
	innerFn()
end

local function drawModals(idx)
	if idx <= #modalStack then
		local win = modalStack[idx]

		if (not win.popupRequested) then
			win.popupRequested = true
			ui.openPopup(win.name)
		end

		win:update()

		if win.style then
			win.style:push()
		end

		local ok, err = ui.pcall(win.outerHandler, win, function ()
			if win.size then
				ui.setNextWindowSize(win.size, "Always")
			end

			if win.centered then
				ui.setNextWindowPosCenter("Always")
			end

			if ui.beginPopupModal(win.name, win.flags) then
				win.isOpen = true
				win:render()
				-- modal could close in handler
				if win.isOpen then
					drawModals(idx+1)
				else
					ui.closeCurrentPopup()
				end
				ui.endPopup()
			else
				-- If beginPopupModal failed even though the window was marked open,
				-- clean it up so it does not block the rest of the modal stack
				if win.isOpen then
					win:close()
					drawModals(idx)
				end
			end
		end)

		if win.style then
			win.style:pop()
		end

		if not ok then
			logWarning(err)
			win:close()
		end
	end

	if idx == #modalStack + 1 then
		for _,v in ipairs(ui.getModules('notification')) do
			v.draw()
		end
	end
end

function ModalWindow:topmost()
	return self.stackIdx == #modalStack
end

ui.registerModule('modal', function()
	if #modalStack == 0 and ui.isAnyModalOpen and ui.isAnyModalOpen() then
		ui.closeAllPopups()
	end
	drawModals(1)
end)

local function closeAllModals()
	for i = #modalStack, 1, -1 do
		local win = modalStack[i]
		if win then
			win.stackIdx = -1
			win.isOpen = false
			win.popupRequested = false
			table.remove(modalStack, i)
			win:message("onClose")
		end
	end
	modalStack = {}
	if ui.closeAllPopups then
		ui.closeAllPopups()
	end
	Input.EnableBindings(true)
end

Event.Register("onGameEnd", closeAllModals)
Event.Register("onEnterMainMenu", closeAllModals)

Event.Register("onPlayerShipDestroyed", function()
	for i = #modalStack, 1, -1 do
		local win = modalStack[i]
		if win and win.name and win.name ~= "Options" and win.name ~= "SaveGameWindow" then
			win:close()
		end
	end
end)

Event.Register("onPlayerUndocked", function()
	for i = #modalStack, 1, -1 do
		local win = modalStack[i]
		if win and win.name and win.name ~= "Options" and win.name ~= "SaveGameWindow" then
			win:close()
		end
	end
end)

Event.Register("onViewChanged", function(currView)
	if currView == "WorldView" or currView == "DeathView" then
		for i = #modalStack, 1, -1 do
			local win = modalStack[i]
			if win and win.name and win.name ~= "Options" and win.name ~= "SaveGameWindow" and win.name ~= "About" then
				win:close()
			end
		end
	end
end)

return ModalWindow
