-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Lang = require 'Lang'

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors
local styleColors = ui.theme.styleColors
local icons = ui.theme.icons

local l = Lang.GetResource("ui-core")

local VERIFICATION_DURATION = 0.30

local StationSig = {}
StationSig.__index = StationSig

local function computeKeyFingerprint(label)
	local h1 = 0x5A17
	local h2 = 0xC391
	for i = 1, #label do
		local b = string.byte(label, i)
		h1 = (h1 * 33 + b) % 0x10000
		h2 = (h2 * 131 + b + i) % 0x10000
	end
	return string.format("%04X-%04X", h1, h2)
end

function StationSig.New(id)
	local self = {
		id = id,
		startTime = ui.getTime(),
		keyFingerprint = "0000-0000",
	}
	return setmetatable(self, StationSig)
end

function StationSig:reset()
	self.startTime = ui.getTime()
	local station = Game.player and Game.player:GetDockedWith()
	local label = station and station.label or "STATION"
	self.keyFingerprint = computeKeyFingerprint(label)
end

function StationSig:render(drawContentFn)
	local now = ui.getTime()
	local frac = math.clamp((now - self.startTime) / VERIFICATION_DURATION, 0, 1)
	local verified = (frac >= 1)

	local statusLabel = verified and l.SIG_VERIFIED or l.SIG_VERIFYING
	local statusColor = verified and (styleColors.success_300 or colors.econMajorImport) or (colors.maneuver or colors.font)

	ui.withFont(pionillium.details, function()
		local lineH = ui.getTextLineHeight()
		ui.icon(icons.shield_other, Vector2(lineH), statusColor)
		ui.sameLine()
		ui.textColored(statusColor, statusLabel)
		ui.sameLine()

		local rightText = "KEY " .. self.keyFingerprint .. "  ·  " .. l.SIG_PROTOCOL
		local avail = ui.getContentRegion().x
		local rightW = ui.calcTextSize(rightText).x
		if avail > rightW then
			ui.addCursorPos(Vector2(avail - rightW, 0))
		end
		ui.textColored(colors.fontDim, rightText)
	end)

	local barStart = ui.getCursorScreenPos()
	local barWidth = ui.getContentRegion().x
	local barHeight = math.max(2, ui.rescaleUI(Vector2(0, 2), Vector2(1920, 1080)).y)
	ui.addRectFilled(barStart, barStart + Vector2(barWidth, barHeight), colors.tableBackground, 0, ui.RoundCornersNone)
	if barWidth > 0 then
		ui.addRectFilled(barStart, barStart + Vector2(barWidth * frac, barHeight), statusColor, 0, ui.RoundCornersNone)
	end
	ui.dummy(Vector2(0, barHeight + ui.rescaleUI(Vector2(0, 6), Vector2(1920, 1080)).y))

	local contentPos = ui.getCursorScreenPos()
	local contentSize = ui.getContentRegion()
	ui.child("##stationSigContent_" .. self.id, contentSize, drawContentFn)

	if not verified and contentSize.x > 0 and contentSize.y > 0 then
		ui.addRectFilled(contentPos, contentPos + contentSize, colors.windowBackground:opacity(0.40 * (1 - frac)), 0, ui.RoundCornersNone)
	end
end

return StationSig

