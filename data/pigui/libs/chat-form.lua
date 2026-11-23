-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Game = require 'Game'
local Space = require 'Space'

local CommodityWidget = require 'pigui.libs.commodity-market'
local Face = require 'pigui.libs.face'
local Vector2 = _G.Vector2
local Color = _G.Color

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local colors = ui.theme.colors
local icons = ui.theme.icons

local l = Lang.GetResource("ui-core")

local DECRYPT_DURATION = 0.30
local REPLY_DECRYPT_DURATION = 0.16
local CIPHER_GLYPHS = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F", "#", "@", "%", "&", "*" }

local function splitUtf8Chars(str)
	local chars = {}
	for ch in string.gmatch(str, "[\0-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	return chars
end

local ChatForm = {}

ChatForm.meta = {
	__index = ChatForm,
	class = "ChatForm",
}

function ChatForm.New (chatFunc, removeFunc, closeFunc, resizeFunc, ref, tabGroup, style)
	style = style or {}
	style.face = style.face or {}
	local now = ui.getTime()
	local form = {
		chatFunc = chatFunc,
		removeFunc = removeFunc,
		closeFunc = closeFunc,
		resizeFunc = resizeFunc,
		ref = ref,
		tabGroup = tabGroup,
		market = nil,
		navButton = function() end,
		openTime = now,
		messageStartTime = now,
		initialReveal = true,
		messageChars = {},
		style = {
			face = {
				size = style.face.size or ui.rescaleUI(Vector2(220, 296), Vector2(1920, 1080)),
				windowPadding = style.face.windowPadding or ui.rescaleUI(Vector2(4, 4), Vector2(1920, 1080)),
				itemSpacing = style.face.itemSpacing or ui.rescaleUI(Vector2(4, 4), Vector2(1920, 1080)),
				showCharInfo = style.face.showCharInfo == nil and true or style.face.showCharInfo,
				charInfoPadding = style.face.charInfoPadding or ui.rescaleUI(Vector2(8, 5), Vector2(1920, 1080)),
				charInfoBgColor = style.face.bgColor or Color(8, 11, 16, 225),
				orgFont = style.face.orgFont or pionillium.medium,
				nameFont = style.face.nameFont or orbiteer.medium,
				titleFont = style.face.titleFont or pionillium.details,
			},
			buttonSize = style.buttonSize or ui.rescaleUI(Vector2(240, 22), Vector2(1920, 1080)),
			titleFont = style.titleFont or orbiteer.heading,
			font = style.font or pionillium.body,
			marketSize = style.marketSize or ui.rescaleUI(Vector2(1080, 420), Vector2(1920, 1080)),
			fitMarketToPanel = style.fitMarketToPanel or false,
			showCommsHeader = style.showCommsHeader == nil and true or style.showCommsHeader,
		},
	}
	-- So that the font at least fits in the button in height
	form.style.buttonSize = Vector2(form.style.buttonSize.x, math.max(form.style.buttonSize.y, form.style.font.size + ui.theme.styles.ButtonPadding.y * 2))
	setmetatable(form, ChatForm.meta)
	form.chatFunc(form, 0)
	return form
end

function ChatForm:getDecryptedMessage (now)
	if not self.message or self.message == "" then
		return self.message, 1
	end

	local chars = self.messageChars
	local total = #chars
	if total == 0 then
		return self.message, 1
	end

	local revealStart = self.initialReveal and self.openTime or self.messageStartTime
	local duration = self.initialReveal and DECRYPT_DURATION or REPLY_DECRYPT_DURATION
	local progress = math.clamp((now - revealStart) / duration, 0, 1)
	if progress >= 1 then
		self.initialReveal = false
		return self.message, 1
	end

	local tick = math.floor(now * 55)
	local buf = {}

	for i = 1, total do
		local ch = chars[i]
		if ch == "\n" or ch == " " or ch == "\t" then
			buf[i] = ch
		else
			local threshold = (i / total) * 0.72 + ((i * 37) % 13) / 50
			if progress >= threshold then
				buf[i] = ch
			else
				buf[i] = CIPHER_GLYPHS[((i * 7 + tick) % #CIPHER_GLYPHS) + 1]
			end
		end
	end

	return table.concat(buf), progress
end

function ChatForm:renderCommsHeader (decryptProgress)
	local statusLabel = l.COMMS_CHANNEL_OPEN
	local statusColor = colors.econMajorImport or colors.font
	local clickedHangUp = false

	if decryptProgress < 1 then
		statusLabel = l.COMMS_DECRYPTING
		statusColor = colors.maneuver or colors.font
	end

	ui.withFont(pionillium.details, function()
		local lineH = ui.getTextLineHeight()
		ui.icon(icons.comms, Vector2(lineH), statusColor)
		ui.sameLine()
		ui.textColored(statusColor, statusLabel)
		ui.sameLine()

		local hangUpW = ui.calcTextSize(l.HANG_UP).x + ui.theme.styles.ButtonPadding.x * 2 + 8
		local protoText = l.COMMS_PROTOCOL
		local avail = ui.getContentRegion().x
		local protoW = ui.calcTextSize(protoText).x
		if avail > protoW + hangUpW + 12 then
			ui.addCursorPos(Vector2(avail - protoW - hangUpW - 8, 0))
			ui.textColored(colors.fontDim, protoText)
			ui.sameLine()
		elseif avail > hangUpW then
			ui.addCursorPos(Vector2(avail - hangUpW, 0))
		end
		if ui.button(l.HANG_UP .. "##headerHangUp", Vector2(hangUpW, lineH + 4), ui.theme.buttonColors.danger) then
			clickedHangUp = true
		end
	end)

	local barStart = ui.getCursorScreenPos()
	local barWidth = ui.getContentRegion().x
	local barHeight = math.max(2, ui.rescaleUI(Vector2(0, 2), Vector2(1920, 1080)).y)
	ui.addRectFilled(barStart, barStart + Vector2(barWidth, barHeight), colors.tableBackground, 0, ui.RoundCornersNone)
	if barWidth > 0 then
		ui.addRectFilled(barStart, barStart + Vector2(barWidth * decryptProgress, barHeight), statusColor, 0, ui.RoundCornersNone)
	end
	ui.dummy(Vector2(0, barHeight + ui.rescaleUI(Vector2(0, 6), Vector2(1920, 1080)).y))
	return clickedHangUp
end

function ChatForm:render ()
	local now = ui.getTime()
	local displayMessage, decryptProgress = self:getDecryptedMessage(now)

	ui.withFont(self.style.font.name, self.style.font.size, function()
		self.style.contentWidth = ui.getContentRegion().x

		local headerClosed = false
		if self.style.showCommsHeader then
			headerClosed = self:renderCommsHeader(decryptProgress)
		end
		if headerClosed then
			self:Close()
			return
		end

		local btnSize = self:getButtonSize()

		if self.market then
			-- Compact side-by-side layout when a market widget is embedded so the market and Hang Up button fit without scrolling
			local savedFaceSize = self.face and self.face.style and self.face.style.size
			local compactFaceSize = ui.rescaleUI(Vector2(138, 176), Vector2(1920, 1080))
			if self.face then
				self.face.style.size = compactFaceSize
				ui.columns(2, "##ChatMarketTopCols", false)
				ui.setColumnWidth(0, compactFaceSize.x + ui.rescaleUI(14, Vector2(1920, 1080)))
				self.face:render()
				self.face.style.size = savedFaceSize
				ui.nextColumn()
			end

			if self.title then
				ui.withFont(self.style.titleFont.name, self.style.titleFont.size, function()
					ui.textWrapped(self.title)
				end)
			end
			if displayMessage and displayMessage ~= "" then
				ui.spacing()
				ui.textWrapped(displayMessage)
				ui.spacing()
			end
			if self.options then
				local colW = ui.getContentRegion().x
				local optSize = Vector2(colW, self.style.buttonSize.y)
				for _, option in ipairs(self.options) do
					if ui.button(option[1], optSize) then
						if (option[2] == -1) then
							if self.face then ui.columns(1) end
							self:Close()
							return
						else
							self.chatFunc(self, option[2])
						end
					end
				end
			end

			if self.face then
				ui.columns(1)
			end
			ui.spacing()

			local remainingY = ui.getContentRegion().y - (btnSize.y + ui.rescaleUI(12, Vector2(1920, 1080)))
			local mHeight = self.style.fitMarketToPanel
				and math.max(ui.rescaleUI(220, Vector2(1920, 1080)), remainingY)
				or self.style.marketSize.y
			local mSize = self.style.fitMarketToPanel
				and Vector2(self.style.contentWidth, mHeight)
				or self.style.marketSize
			self.market:Render(mSize)
		else
			if self.title then
				ui.withFont(self.style.titleFont.name, self.style.titleFont.size, function()
					ui.pushTextWrapPos(self.style.contentWidth)
					ui.textWrapped(self.title)
					ui.popTextWrapPos()
				end)
			end

			if self.face then
				self.face:render()
			end

			if displayMessage then
				ui.spacing()
				ui.pushTextWrapPos(self.style.contentWidth)
				ui.textWrapped(displayMessage)
				ui.popTextWrapPos()
				ui.spacing()
			end

			if self.options then
				for _, option in ipairs(self.options) do
					if ui.button(option[1], btnSize) then
						if (option[2] == -1) then
							self:Close()
						else
							self.chatFunc(self, option[2])
						end
					end
				end
			end
		end

		self.navButton()

		if ui.button(l.HANG_UP, btnSize, ui.theme.buttonColors.danger) or ui.escapeKeyReleased(true) then
			if self.tabGroup then
				self.tabGroup.escapeConsumed = true
			end
			self:Close()
		end
	end)
end

function ChatForm:getButtonSize ()
	local w = (self.style.buttonSize.x <= 0 and self.style.contentWidth) or self.style.buttonSize.x
	return Vector2(w, self.style.buttonSize.y)
end

function ChatForm:SetTitle (title)
	self.title = title
end

function ChatForm:SetFace (character)
	self.face = Face.New(character, self.style.face)
end

function ChatForm:ClearFace()
	self.face = nil
end

function ChatForm:SetMessage (message)
	self.message = message
	self.messageChars = message and splitUtf8Chars(message) or {}
	self.messageStartTime = ui.getTime()
end

function ChatForm:AddOption (text, option)
	self.options = self.options or {}
	table.insert(self.options, { text, option })
end

function ChatForm:Clear ()
	self.title = nil
	self.message = nil
	self.messageChars = {}
	self.options = nil
	self.tradeFuncs = nil
	self.market = nil
end

local tradeFuncKeys = { "canTrade", "getStock", "getBuyPrice", "getSellPrice", "onClickBuy", "onClickSell", "canDisplayItem", "bought", "sold"}
function ChatForm:AddGoodsTrader (funcs)
	self.equipWidgetConfig = {
		stationColumns = { "icon", "name", "price", "stock" },
		shipColumns = { "icon", "name", "amount" },
	}

	local config = {}

	for _, key in ipairs(tradeFuncKeys) do
		if funcs[key] then
			config[key] = funcs[key]
		end
	end

	self.market = CommodityWidget.New("chatTrader", false, config)
	self.resizeFunc()
	self.market:Refresh()
end

function ChatForm:AddNavButton (target)
	self.navButton = function()
		if ui.button(l.SET_AS_TARGET, self:getButtonSize()) then
			if target:isa("Body") and target:IsDynamic() then
				Game.player:SetNavTarget(target)
				ui.playSfx("OK")
			elseif Game.system and target:IsSameSystem(Game.system.path) then
				if target.bodyIndex then
					Game.player:SetNavTarget(Space.GetBody(target.bodyIndex))
					ui.playSfx("OK")
				end
			elseif not Game.InHyperspace() then
				-- if a specific systembody is given, set the sector map to the correct star (if the system is multiple)
				Game.sectorView:SwitchToPath(target:IsBodyPath() and target:GetSystemBody().nearestJumpable.path or target:SystemOnly())
				ui.playBoinkNoise()
			end
		end
	end
end

function ChatForm:RemoveNavButton ()
	self.navButton = function() end
end

function ChatForm:Close ()
	self.closeFunc()
end

function ChatForm:GotoPolice ()
	self:Close()
	self.tabGroup:SwitchTo("police")
end

function ChatForm:RemoveAdvertOnClose()
	-- removing it now. has the same effect for the player, without requiring
	-- us to somehow hook the entire view being closed (eg switch back to worldview)
	if self.removeFunc then
		self.removeFunc()
	end
end

return ChatForm
