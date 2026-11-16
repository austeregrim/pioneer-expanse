-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local ui = require 'pigui'

local l = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local Vector2 = _G.Vector2

local DEFAULT_DECRYPT_DURATION = 0.50

local CIPHER_GLYPHS = {
	"%", "&", "§", "#", "@", "?", "!", "/", "\\", "=", "+", "*",
	"0", "1", "<", ">", "[", "]", "{", "}", "~", "^", "X", "Z",
	"Δ", "Ω", "Ψ", "Σ", "Π", "λ", "θ", "ж", "ф", "Б", "Г", "Д"
}

local function splitUtf8Chars(str)
	if not str then return {} end
	local chars = {}
	for ch in string.gmatch(str, "[\0-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	return chars
end

local EncryptedText = {}
EncryptedText.__index = EncryptedText

function EncryptedText.New(initialText, duration)
	local self = {
		text = initialText or "",
		chars = splitUtf8Chars(initialText or ""),
		duration = duration or DEFAULT_DECRYPT_DURATION,
		startTime = ui.getTime(),
	}
	setmetatable(self, EncryptedText)
	return self
end

function EncryptedText:reset(newText)
	if newText ~= nil then
		self.text = newText
		self.chars = splitUtf8Chars(newText)
	end
	self.startTime = ui.getTime()
end

function EncryptedText:get(now)
	now = now or ui.getTime()
	if not self.text or self.text == "" then
		return "", 1, true
	end

	local total = #self.chars
	if total == 0 then
		return self.text, 1, true
	end

	local progress = math.clamp((now - self.startTime) / self.duration, 0, 1)
	if progress >= 1 then
		return self.text, 1, true
	end

	local tick = math.floor(now * 55)
	local buf = {}

	for i = 1, total do
		local ch = self.chars[i]
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

	return table.concat(buf), progress, false
end

function EncryptedText:renderCommsHeader(now, protocolName, statusLabelOverride)
	now = now or ui.getTime()
	local _, progress, isVerified = self:get(now)

	local statusLabel
	local statusColor
	if isVerified then
		statusLabel = statusLabelOverride or l.COMMS_CHANNEL_OPEN or "ENCRYPTED CHANNEL VERIFIED"
		statusColor = colors.econMajorImport or colors.uiPrimaryLight or colors.font
	else
		statusLabel = l.COMMS_DECRYPTING or "DECRYPTING COMMS..."
		statusColor = colors.maneuver or colors.font
	end

	ui.withFont(pionillium.details, function()
		local lineH = ui.getTextLineHeight()
		ui.icon(icons.comms, Vector2(lineH), statusColor)
		ui.sameLine()
		ui.textColored(statusColor, statusLabel)
		ui.sameLine()

		local protoText = protocolName or l.COMMS_PROTOCOL or "COMMS-SIG // 4096-BIT"
		local avail = ui.getContentRegion().x
		local protoW = ui.calcTextSize(protoText).x
		if avail > protoW then
			ui.addCursorPos(Vector2(avail - protoW, 0))
		end
		ui.textColored(colors.fontDim, protoText)
	end)

	local barStart = ui.getCursorScreenPos()
	local barWidth = ui.getContentRegion().x
	local barHeight = math.max(2, ui.rescaleUI(Vector2(0, 2), Vector2(1920, 1080)).y)
	ui.addRectFilled(barStart, barStart + Vector2(barWidth, barHeight), colors.tableBackground, 0, ui.RoundCornersNone)
	if barWidth > 0 then
		ui.addRectFilled(barStart, barStart + Vector2(barWidth * progress, barHeight), statusColor, 0, ui.RoundCornersNone)
	end
	ui.dummy(Vector2(0, barHeight + ui.rescaleUI(Vector2(0, 6), Vector2(1920, 1080)).y))
end

function EncryptedText:renderTextWrapped(now, font)
	local displayText = self:get(now)
	if font then
		ui.withFont(font, function()
			ui.textWrapped(displayText)
		end)
	else
		ui.textWrapped(displayText)
	end
end

return EncryptedText

